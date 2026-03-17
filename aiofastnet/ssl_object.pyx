import threading

from .openssl cimport *
from .openssl_compat import find_openssl_library_paths

from cpython.object cimport PyObject
from cpython.bytes cimport PyBytes_FromStringAndSize, PyBytes_AS_STRING
from cpython.bytearray cimport (
    PyByteArray_FromStringAndSize,
    PyByteArray_AS_STRING,
    PyByteArray_GET_SIZE
)
from cpython.unicode cimport PyUnicode_FromString, PyUnicode_FromStringAndSize

import os
import ssl
import tempfile
import logging

cdef object _logger = logging.getLogger('aiofastnet.ssl')
cdef bint _openssl_loaded = False
cdef object _openssl_load_lock = threading.Lock()


cdef load_openssl():
    global _openssl_loaded
    global _openssl_load_lock

    cdef:
        bytes ssl_lib_name
        bytes crypto_lib_name
        const char* ssl_lib_ptr
        const char* crypto_lib_ptr
        const char* missing_lib

    with _openssl_load_lock:
        if _openssl_loaded:
            return

        ssl_lib_name, crypto_lib_name = find_openssl_library_paths()
        _logger.info("Found libssl: %s", ssl_lib_name.decode())
        _logger.info("Found libcrypto: %s", crypto_lib_name.decode())

        if init_openssl_compat(ssl_lib_name, crypto_lib_name) != 1:
            missing_lib = openssl_compat_last_error()
            if missing_lib != NULL:
                raise ImportError(
                    f"aiofastnet: failed to initialize OpenSSL compatibility layer; "
                    f"missing symbol: {PyUnicode_FromString(missing_lib)}; "
                    f"ssl_lib={ssl_lib_name.decode()}, crypto_lib={crypto_lib_name.decode()}")
            raise ImportError("aiofastnet: failed to initialize OpenSSL compatibility layer")

        _logger.info("OpenSSL: SSL_sendfile loaded=%d", SSL_sendfile_available())
        _openssl_loaded = True


ctypedef struct PySSLContextHack:
    PyObject ob_base
    SSL_CTX* ctx


cdef SSL_CTX* _get_ssl_ctx_ptr(object py_ctx) except NULL:
    # Minimal runtime sanity check (still not foolproof)
    if not isinstance(py_ctx, ssl.SSLContext):
        raise TypeError("expected ssl.SSLContext")

    # A memory layout hack to extract SSL_CTX* ptr from python SSLContext object.
    #
    # I intentionally mirror ONLY the initial prefix of CPython's PySSLContext:
    # PyObject_HEAD + SSL_CTX *ctx
    #
    # This is NOT ABI-stable and may break across Python versions/build options.
    # I know it is ugly, but who cares, in some million years the sun will destroy
    # all life on earth, so everything is meaningless anyway.
    #
    # The guys from python are reluctant to expose it directly:
    # https://bugs.python.org/issue43902
    return (<PySSLContextHack*> <PyObject*> py_ctx).ctx


cdef int _print_error_cb(const char* str, size_t len, void* u) noexcept nogil:
    with gil:
        logger = <object><PyObject*>u
        err_str = PyUnicode_FromStringAndSize(str, len)
        logger.error(err_str)


cdef _log_error_queue():
    cdef void* u = <PyObject*>_logger
    ERR_print_errors_cb(&_print_error_cb, u)


cdef unsigned long _err_last_error():
    cdef unsigned long err_code = ERR_peek_last_error()
    ERR_clear_error()
    return err_code


cdef Py_ssize_t _bio_pending(BIO* bio) except -1:
    cdef int pending = BIO_pending(bio)
    if pending < 0:
        raise RuntimeError("unable to get pending len from BIO")
    return pending


cdef class SSLObject:
    def __init__(self, ssl_context, bint server_side, str server_hostname,
                 Py_ssize_t read_buffer_size, Py_ssize_t write_buffer_size,
                 sock=None):
        ERR_clear_error()

        self.ssl_ctx_py = ssl_context
        self.ssl_ctx = _get_ssl_ctx_ptr(ssl_context)

        self.incoming_buf = None
        self.outgoing_buf = None
        self.incoming = NULL
        self.outgoing = NULL

        self.ssl = SSL_new(self.ssl_ctx)
        if self.ssl == NULL:
            raise MemoryError("Unable to allocate SSL object")

        self.server_hostname = server_hostname
        self.server_side = server_side

        if sock is None:
            self.incoming_buf = PyByteArray_FromStringAndSize(
                NULL, read_buffer_size)
            self.outgoing_buf = PyByteArray_FromStringAndSize(
                NULL, write_buffer_size)

            self.incoming = BIO_new_static_mem(
                PyByteArray_AS_STRING(self.incoming_buf),
                <size_t>PyByteArray_GET_SIZE(self.incoming_buf)
            )
            self.outgoing = BIO_new_static_mem(
                PyByteArray_AS_STRING(self.outgoing_buf),
                <size_t>PyByteArray_GET_SIZE(self.outgoing_buf)
            )

            if self.incoming == NULL or self.outgoing == NULL or self.ssl == NULL:
                if self.incoming != NULL:
                    BIO_free(self.incoming)
                    self.incoming = NULL
                if self.outgoing != NULL:
                    BIO_free(self.outgoing)
                    self.outgoing = NULL
                if self.ssl != NULL:
                    SSL_free(self.ssl)
                    self.ssl = NULL
                raise MemoryError("Unable to initialize OpenSSL objects")

            SSL_set_bio(self.ssl, self.incoming, self.outgoing)
            BIO_set_nbio(self.incoming, 1)
            BIO_set_nbio(self.outgoing, 1)
        else:
            if SSL_set_fd(self.ssl, sock.fileno()) != 1:
                SSL_free(self.ssl)
                self.ssl = NULL
                raise ssl.SSLError("SSL_set_fd failed")
            SSL_set_options(self.ssl, SSL_OP_ENABLE_KTLS)

        if server_side:
            SSL_set_accept_state(self.ssl)
        else:
            SSL_set_connect_state(self.ssl)

        cdef:
            X509_VERIFY_PARAM* ssl_verification_params
            X509_VERIFY_PARAM* ssl_ctx_verification_params
            unsigned int ssl_ctx_host_flags

        ssl_verification_params = SSL_get0_param(self.ssl)
        ssl_ctx_verification_params = SSL_CTX_get0_param(self.ssl_ctx)
        ssl_ctx_host_flags = X509_VERIFY_PARAM_get_hostflags(ssl_ctx_verification_params)
        X509_VERIFY_PARAM_set_hostflags(ssl_verification_params, ssl_ctx_host_flags)

        SSL_set_mode(self.ssl,
                     SSL_MODE_AUTO_RETRY | SSL_MODE_ENABLE_PARTIAL_WRITE)

        if self.server_hostname is not None:
            self._configure_hostname()

    def __dealloc__(self):
        # Free SSL and its BIO
        SSL_free(self.ssl)

    cpdef tuple cipher(self):
        cdef const SSL_CIPHER* c = SSL_get_current_cipher(self.ssl)

        cdef const char* name = SSL_CIPHER_get_name(c)
        name_obj = PyUnicode_FromString(name) if name != NULL else None

        cdef const char* protocol = SSL_CIPHER_get_version(c)
        protocol_obj = PyUnicode_FromString(protocol) if name != NULL else None

        cdef int bits = SSL_CIPHER_get_bits(c, NULL)

        return (name_obj, protocol_obj, bits)

    cpdef object getpeercert(self, binary_form=False):
        if SSL_is_init_finished(self.ssl) != 1:
            raise ssl.SSLError("SSL_is_init_finished failed")

        cdef X509* peer_cert = SSL_get_peer_certificate(self.ssl)
        if peer_cert == NULL:
            return None

        cdef int verification = self.ssl_ctx_py.verify_mode
        try:
            if binary_form:
                return self._certificate_to_der(peer_cert)
            return self._decode_certificate(peer_cert) if verification & SSL_VERIFY_PEER else dict()
        finally:
            X509_free(peer_cert)

    # TODO: I don't think people would need this.
    # For now I return None but if somebody asks can be made compatible with
    # python implementation
    cpdef str compression(self):
        return None

    cpdef object selected_alpn_protocol(self):
        cdef const unsigned char* protocol = NULL
        cdef unsigned int protocol_len = 0

        SSL_get0_alpn_selected(self.ssl, &protocol, &protocol_len)
        if protocol == NULL or protocol_len == 0:
            return None

        return PyUnicode_FromStringAndSize(<const char*>protocol, protocol_len)

    cpdef int ktls_send_enabled(self):
        return BIO_get_ktls_send(SSL_get_wbio(self.ssl))

    cdef inline make_exc_from_ssl_error(self, str descr, int err_code):
        assert err_code != SSL_ERROR_NONE, "check logic"

        if err_code == SSL_ERROR_WANT_READ:
            return ssl.SSLWantReadError(descr)
        elif err_code == SSL_ERROR_WANT_WRITE:
            return ssl.SSLWantWriteError(descr)
        elif err_code == SSL_ERROR_ZERO_RETURN:
            return ssl.SSLZeroReturnError(descr)
        elif err_code == SSL_ERROR_SYSCALL:
            return ssl.SSLSyscallError(descr)
        elif err_code == SSL_ERROR_SSL:
            return self._exc_from_err_last_error(descr)
        else:
            return ssl.SSLError(f"{descr}, unknown error_code={err_code}")

    cdef inline _exc_from_err_last_error(self, str descr):
        cdef unsigned long last_error = _err_last_error()
        cdef int lib = ERR_GET_LIB(last_error)
        cdef const char * lib_ptr
        cdef const char * reason_ptr
        cdef const char * verify_ptr

        _log_error_queue()

        lib_ptr = ERR_lib_error_string(last_error)
        lib_name = PyUnicode_FromString(lib_ptr) if lib_ptr != NULL else f"UNKNOWN_{lib}"
        lib_name = lib_name.upper()
        reason_ptr = ERR_reason_error_string(last_error)
        reason_name = PyUnicode_FromString(
            reason_ptr) if reason_ptr != NULL else ""
        reason_name = reason_name.upper().replace(" ", "_")

        if reason_name == "CERTIFICATE_VERIFY_FAILED":
            assert self.server_hostname is not None
            verify_code = SSL_get_verify_result(self.ssl)
            verify_ptr = X509_verify_cert_error_string(verify_code)
            txt = PyUnicode_FromString(verify_ptr) if verify_ptr != NULL else ""
            str_error = f"[{lib_name}: {reason_name}] {descr}: {txt}"
            exc = ssl.SSLCertVerificationError()
            exc.verify_code = verify_code
            exc.verify_message = txt
        else:
            str_error = f"[{lib_name}: {reason_name}] {descr}"
            exc = ssl.SSLError()
        exc.strerror = str_error
        exc.library = lib_name
        exc.reason = reason_name
        return exc

    cdef inline _configure_hostname(self):
        if not self.server_hostname or self.server_hostname.startswith("."):
            raise ValueError("server_hostname cannot be an empty string or start with a leading dot.")

        cdef bytes server_hostname_b = self.server_hostname.encode()
        cdef char* server_hostname_ptr = PyBytes_AS_STRING(server_hostname_b)

        cdef ASN1_OCTET_STRING* ip = a2i_IPADDRESS(PyBytes_AS_STRING(server_hostname_b))
        if ip == NULL:
            ERR_clear_error()

        cdef X509_VERIFY_PARAM* ssl_verification_params
        try:
            # Only send SNI extension for non-IP hostnames
            if ip == NULL:
                if not SSL_set_tlsext_host_name(self.ssl, server_hostname_ptr):
                    _log_error_queue()
                    ERR_clear_error()
                    raise ssl.SSLError("SSL_set_tlsext_host_name failed")

            if self.ssl_ctx_py.check_hostname:
                ssl_verification_params = SSL_get0_param(self.ssl)
                if ip == NULL:
                    if not X509_VERIFY_PARAM_set1_host(ssl_verification_params, server_hostname_ptr, len(server_hostname_b)):
                        raise ssl.SSLError("X509_VERIFY_PARAM_set1_host failed")
                else:
                    if not X509_VERIFY_PARAM_set1_ip(ssl_verification_params, ASN1_STRING_get0_data(ip), ASN1_STRING_length(ip)):
                        raise ssl.SSLError("X509_VERIFY_PARAM_set1_host failed")
        finally:
            if ip != NULL:
                ASN1_OCTET_STRING_free(ip)

    cdef inline bytes _certificate_to_der(self, X509* certificate):
        cdef int der_len = i2d_X509(certificate, NULL)
        cdef bytes der
        cdef unsigned char* p

        if der_len <= 0:
            raise ssl.SSLError("i2d_X509 failed")

        der = PyBytes_FromStringAndSize(NULL, der_len)
        if der is None:
            raise MemoryError()

        p = <unsigned char*>PyBytes_AS_STRING(der)
        if i2d_X509(certificate, &p) != der_len:
            raise ssl.SSLError("i2d_X509 produced invalid DER size")

        return der

    cdef inline _decode_certificate(self, X509* certificate):
        cdef bytes der = self._certificate_to_der(certificate)
        cdef str path = ""

        pem = ssl.DER_cert_to_PEM_cert(der)
        tmp = tempfile.NamedTemporaryFile(mode="w", delete=False, encoding="ascii")
        try:
            tmp.write(pem)
            tmp.close()
            path = tmp.name
            return ssl._ssl._test_decode_cert(path)
        finally:
            if path:
                os.unlink(path)

    cdef inline int get_error(self, int ret) noexcept:
        return SSL_get_error(self.ssl, ret)

    cdef int do_handshake(self) noexcept:
        return SSL_do_handshake(self.ssl)

    cdef int get_shutdown(self) noexcept:
        return SSL_get_shutdown(self.ssl)

    cdef int shutdown(self) noexcept:
        return SSL_shutdown(self.ssl)

    cdef int read_ex(self, void *buf, size_t num, size_t *bytes_read) noexcept:
        return SSL_read_ex(self.ssl, buf, num, bytes_read)

    cdef int write_ex(self, const void *buf, size_t num, size_t *bytes_written) noexcept:
        return SSL_write_ex(self.ssl, buf, num, bytes_written)

    cdef Py_ssize_t pending(self) noexcept:
        return <Py_ssize_t>SSL_pending(self.ssl)

    cdef inline int outgoing_bio_reset(self) noexcept:
        return BIO_reset(self.outgoing)

    cdef Py_ssize_t outgoing_bio_pending(self) except -1:
        return _bio_pending(self.outgoing)

    cdef Py_ssize_t outgoing_bio_get_data(self, char** pp) noexcept:
        return <Py_ssize_t>BIO_get_mem_data(self.outgoing, pp)

    cdef outgoing_bio_consume(self, Py_ssize_t nbytes):
        if BIO_static_mem_consume(self.outgoing, <size_t>nbytes) != 1:
            raise RuntimeError("BIO_static_mem_consume(outgoing) failed")

    cdef Py_ssize_t incoming_bio_pending(self) except -1:
        return _bio_pending(self.incoming)

    cdef incoming_bio_get_write_buf(self, char **pp, Py_ssize_t *space):
        cdef size_t sz = 0
        cdef int rc = BIO_static_mem_get_write_buf(self.incoming, pp, &sz)
        if rc != 1:
            raise RuntimeError("incoming BIO: unable to get writable buffer")
        if sz == 0:
            raise RuntimeError("incoming BIO: no writable capacity")
        space[0] = sz

    cdef incoming_bio_produce(self, Py_ssize_t nbytes):
        if BIO_static_mem_produce(self.incoming, <size_t>nbytes) != 1:
            raise RuntimeError("incoming BIO: unable to publish received bytes")

    cdef void allow_renegotiation(self) noexcept:
        cdef:
            int SSL_OP_ALLOW_CLIENT_RENEGOTIATION = (1 << 8)
            int SSL_OP_ALLOW_UNSAFE_LEGACY_RENEGOTIATION = (1 << 18)

        SSL_set_options(
            self.ssl,
            SSL_OP_ALLOW_CLIENT_RENEGOTIATION |
            SSL_OP_ALLOW_UNSAFE_LEGACY_RENEGOTIATION
        )

    cdef int renegotiate(self) noexcept:
        return SSL_renegotiate(self.ssl)


cdef ssl_error_name(int err):
    return SSLError(err).name
