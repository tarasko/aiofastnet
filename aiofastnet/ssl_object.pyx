import asyncio

from .openssl cimport (
    ASN1_OCTET_STRING,
    ASN1_OCTET_STRING_free,
    ASN1_STRING_get0_data,
    ASN1_STRING_length,
    BIO,
    BIO_free,
    BIO_get_ktls_recv,
    BIO_get_ktls_send,
    BIO_get_mem_data,
    BIO_pending,
    BIO_reset,
    BIO_set_nbio,
    BIO_new_static_mem,
    BIO_static_mem_consume,
    BIO_static_mem_get_write_buf,
    BIO_static_mem_produce,
    ERR_GET_LIB,
    ERR_clear_error,
    ERR_lib_error_string,
    ERR_peek_last_error,
    ERR_print_errors_cb,
    ERR_reason_error_string,
    SSL,
    SSL_CIPHER,
    SSL_CIPHER_get_bits,
    SSL_CIPHER_get_name,
    SSL_CIPHER_get_version,
    SSL_CTX,
    SSL_CTX_get0_param,
    SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER,
    SSL_MODE_AUTO_RETRY,
    SSL_MODE_ENABLE_PARTIAL_WRITE,
    SSL_OP_ENABLE_KTLS,
    SSL_OP_IGNORE_UNEXPECTED_EOF,
    SSL_clear_options,
    SSL_do_handshake,
    SSL_free,
    SSL_get0_alpn_selected,
    SSL_get0_param,
    SSL_get_current_cipher,
    SSL_get_error,
    SSL_get_finished,
    SSL_get0_verified_chain,
    SSL_get_ciphers,
    SSL_get_client_ciphers,
    SSL_get_peer_finished,
    SSL_get_peer_cert_chain,
    SSL_get_peer_certificate,
    SSL_get_version,
    SSL_pending,
    SSL_get_rbio,
    SSL_get_verify_result,
    SSL_get_wbio,
    SSL_new,
    SSL_read,
    SSL_renegotiate,
    SSL_sendfile,
    SSL_set_accept_state,
    SSL_set_bio,
    SSL_set_connect_state,
    SSL_set_fd,
    SSL_set_mode,
    SSL_set_options,
    SSL_set_options_available,
    SSL_set_read_ahead,
    SSL_set_tlsext_host_name,
    SSL_shutdown,
    SSL_session_reused,
    SSL_write,
    X509,
    X509_VERIFY_PARAM,
    X509_VERIFY_PARAM_get_hostflags,
    X509_VERIFY_PARAM_set1_host,
    X509_VERIFY_PARAM_set1_ip,
    X509_VERIFY_PARAM_set_hostflags,
    X509_free,
    X509_verify_cert_error_string,
    OPENSSL_STACK,
    OPENSSL_sk_num,
    OPENSSL_sk_value,
    a2i_IPADDRESS,
    i2d_X509,
    init_openssl_compat,
    openssl_compat_last_error,
)
from .utils cimport unlikely
from .openssl_compat import OPENSSL_DYN_LIBS

from cpython.object cimport PyObject
from cpython.bytes cimport PyBytes_FromStringAndSize, PyBytes_AS_STRING
from cpython.bytearray cimport (
    PyByteArray_FromStringAndSize,
    PyByteArray_AS_STRING,
    PyByteArray_GET_SIZE
)
from cpython.unicode cimport PyUnicode_FromString, PyUnicode_FromStringAndSize
from libc.limits cimport INT_MAX

import os
import platform
import re
import ssl
import sys
import tempfile
import logging
from pathlib import Path

cdef object _logger = logging.getLogger('aiofastnet.ssl')


def _set_sslobject_init_test_hook():
    pass


def _linux_kernel_at_least(major: int, minor: int) -> bool:
    if platform.system() != "Linux":
        return False

    match = re.match(r"^(\d+)\.(\d+)", platform.release())
    if match is None:
        return False

    current = tuple(map(int, match.groups()))
    return current >= (major, minor)


def _ktls_prerequisites_available() -> bool:
    if not Path("/sys/module/tls").exists():
        _logger.warning(
            "Kernel TLS was requested but is unavailable because kernel module "
            "'tls' is not loaded; load it with 'sudo modprobe tls'. "
            "Falling back to memory BIO.")
        return False

    if not _linux_kernel_at_least(5, 19):
        _logger.warning(
            "Kernel TLS was requested but is unavailable because the Linux "
            "kernel version is < 5.19. Falling back to memory BIO.")
        return False

    if ssl.OPENSSL_VERSION_INFO[:3] < (3, 0, 0):
        _logger.warning(
            "Kernel TLS was requested but is unavailable because OpenSSL "
            "version is too old; OpenSSL >= 3.0 is required. "
            "Falling back to memory BIO.")
        _logger.warning("Loaded libssl: %s", OPENSSL_DYN_LIBS.libssl)
        _logger.warning("Loaded libcrypto: %s", OPENSSL_DYN_LIBS.libcrypto)
        return False

    return True


cdef _init_openssl():
    if init_openssl_compat(OPENSSL_DYN_LIBS.libssl_path, OPENSSL_DYN_LIBS.libcrypto_path) != 1:
        missing_lib = openssl_compat_last_error()
        if missing_lib != NULL:
            raise ImportError(
                f"aiofastnet: failed to initialize OpenSSL compatibility layer; "
                f"missing symbol: {PyUnicode_FromString(missing_lib)}; "
                f"ssl_lib={OPENSSL_DYN_LIBS.libssl}, crypto_lib={OPENSSL_DYN_LIBS.libcrypto}")
        raise ImportError("aiofastnet: failed to initialize OpenSSL compatibility layer")


_init_openssl()


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


cdef int _print_error_cb(const char* str, size_t len, void* u) noexcept:
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

        if not server_side and ssl_context.check_hostname and not server_hostname:
            raise ValueError("SSLContext.check_hostname requires server_hostname")

        self.ssl_ctx_py = ssl_context
        self.ssl_ctx = _get_ssl_ctx_ptr(ssl_context)

        self.incoming_buf = None
        self.outgoing_buf = None
        self.incoming = NULL
        self.outgoing = NULL
        self.ssl = NULL

        self.server_hostname = server_hostname
        self.server_side = server_side

        cdef bint force_socket_bio = getattr(ssl_context, "_aiofastnet_force_socket_bio", False)

        self.ktls_requested = (ssl_context.options & getattr(ssl, "OP_ENABLE_KTLS", 0)) != 0

        # force_socket_bio is only used for testing, tests should not use it together with OP_ENABLE_KTLS
        assert not self.ktls_requested or (self.ktls_requested and not force_socket_bio)

        try:
            self._is_debug = asyncio.get_running_loop().get_debug()
        except RuntimeError:
            self._is_debug = False

        cdef bint ktls_prerequisites_available = (
            _ktls_prerequisites_available() if self.ktls_requested else False
        )
        cdef bint enable_ktls = (
            SSL_set_options_available() and
            self.ktls_requested and
            ktls_prerequisites_available
        )
        cdef bint use_socket_bio = (
            sock is not None and
            (force_socket_bio or enable_ktls)
        )

        cdef BIO* incoming = NULL
        cdef BIO* outgoing = NULL

        try:
            self.ssl = SSL_new(self.ssl_ctx)
            if self.ssl == NULL:
                raise MemoryError("Unable to allocate SSL object")

            # Some Python 3.9/OpenSSL combinations inherit this option from
            # SSLContext. Clear it per connection so an unclean TCP EOF remains
            # an error, matching the behavior seen with newer Python versions.
            if sys.version_info[:2] < (3, 10):
                SSL_clear_options(self.ssl, SSL_OP_IGNORE_UNEXPECTED_EOF)

            if use_socket_bio:
                if SSL_set_fd(self.ssl, sock.fileno()) != 1:
                    raise ssl.SSLError("SSL_set_fd failed")
                if enable_ktls:
                    SSL_set_options(self.ssl, SSL_OP_ENABLE_KTLS)
            else:
                self.incoming_buf = PyByteArray_FromStringAndSize(
                    NULL, read_buffer_size)
                incoming = BIO_new_static_mem(
                    PyByteArray_AS_STRING(self.incoming_buf),
                    <size_t> PyByteArray_GET_SIZE(self.incoming_buf)
                )
                if incoming == NULL:
                    raise MemoryError("Unable to initialize incoming mem BIO")

                self.outgoing_buf = PyByteArray_FromStringAndSize(
                    NULL, write_buffer_size)
                outgoing = BIO_new_static_mem(
                    PyByteArray_AS_STRING(self.outgoing_buf),
                    <size_t> PyByteArray_GET_SIZE(self.outgoing_buf)
                )
                if outgoing == NULL:
                    raise MemoryError("Unable to initialize outgoing mem BIO")

                BIO_set_nbio(incoming, 1)
                BIO_set_nbio(outgoing, 1)

                # Internal test hook: used to force an exception after SSL/BIO
                # allocation so the constructor cleanup path stays covered.
                _set_sslobject_init_test_hook()

                # From this moment on SSL object owns BIOs and will deallocate them
                SSL_set_bio(self.ssl, incoming, outgoing)
                self.incoming = incoming
                self.outgoing = outgoing
                incoming = NULL
                outgoing = NULL

                # Both _do_read__copied and _do_read_buffered call SSL_read in the loop
                # until all data is consumed from the incoming BIO. Setting read_ahead to 1
                # may cause SSL to over-consume data from incoming BIO and cache it internally,
                # thus grow its internal buffers
                # Single call to SSL_read can't return more than 16 KB regardless of this setting

                SSL_set_read_ahead(self.ssl, 0)

            SSL_set_mode(self.ssl, SSL_MODE_AUTO_RETRY | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER | SSL_MODE_ENABLE_PARTIAL_WRITE)
        except:
            if incoming != NULL:
                BIO_free(incoming)
            if outgoing != NULL:
                BIO_free(outgoing)

            raise

        if server_side:
            SSL_set_accept_state(self.ssl)
        else:
            SSL_set_connect_state(self.ssl)

        self._copy_hostflags_from_ctx_to_ssl()

        if self.server_hostname is not None:
            self._configure_hostname()

    def __dealloc__(self):
        # Free SSL and its BIO
        if self.ssl != NULL:
            SSL_free(self.ssl)
            self.ssl = NULL

    @property
    def context(self):
        return self.ssl_ctx_py

    @property
    def session_reused(self):
        return SSL_session_reused(self.ssl) != 0

    cpdef object version(self):
        cdef const char* version = SSL_get_version(self.ssl)
        return PyUnicode_FromString(version) if version != NULL else None

    cpdef tuple cipher(self):
        cdef const SSL_CIPHER* c = SSL_get_current_cipher(self.ssl)

        cdef const char* name = SSL_CIPHER_get_name(c)
        name_obj = PyUnicode_FromString(name) if name != NULL else None

        cdef const char* protocol = SSL_CIPHER_get_version(c)
        protocol_obj = PyUnicode_FromString(protocol) if name != NULL else None

        cdef int bits = SSL_CIPHER_get_bits(c, NULL)

        return (name_obj, protocol_obj, bits)

    cpdef object shared_ciphers(self):
        cdef:
            OPENSSL_STACK* server_ciphers = SSL_get_ciphers(self.ssl)
            OPENSSL_STACK* client_ciphers = SSL_get_client_ciphers(self.ssl)
            const SSL_CIPHER* server_cipher
            const SSL_CIPHER* client_cipher
            int server_count
            int client_count
            int server_index
            int client_index
            list result

        if server_ciphers == NULL or client_ciphers == NULL:
            return None

        server_count = OPENSSL_sk_num(server_ciphers)
        client_count = OPENSSL_sk_num(client_ciphers)
        result = []

        for server_index in range(server_count):
            server_cipher = <const SSL_CIPHER*>OPENSSL_sk_value(
                server_ciphers, server_index)
            for client_index in range(client_count):
                client_cipher = <const SSL_CIPHER*>OPENSSL_sk_value(
                    client_ciphers, client_index)
                if server_cipher == client_cipher:
                    result.append((
                        PyUnicode_FromString(SSL_CIPHER_get_name(server_cipher)),
                        PyUnicode_FromString(SSL_CIPHER_get_version(server_cipher)),
                        SSL_CIPHER_get_bits(server_cipher, NULL),
                    ))
                    break

        return result

    cpdef object getpeercert(self, binary_form=False):
        cdef X509* peer_cert = SSL_get_peer_certificate(self.ssl)
        if peer_cert == NULL:
            return None

        cdef int verification = self.ssl_ctx_py.verify_mode
        try:
            if binary_form:
                return self._certificate_to_der(peer_cert)
            return self._decode_certificate(
                peer_cert) if verification != ssl.CERT_NONE else dict()
        finally:
            X509_free(peer_cert)

    cpdef list get_verified_chain(self):
        return self._certificate_chain_to_der(
            SSL_get0_verified_chain(self.ssl))

    cpdef list get_unverified_chain(self):
        cdef:
            OPENSSL_STACK* chain = SSL_get_peer_cert_chain(self.ssl)
            X509* peer_cert = NULL
            list result = self._certificate_chain_to_der(chain)

        # OpenSSL omits the peer leaf from the server-side chain.
        if self.server_side and chain != NULL:
            peer_cert = SSL_get_peer_certificate(self.ssl)
            if peer_cert != NULL:
                try:
                    result.insert(0, self._certificate_to_der(peer_cert))
                finally:
                    X509_free(peer_cert)

        return result

    cpdef object get_channel_binding(self, str cb_type="tls-unique"):
        cdef:
            char buf[128]
            size_t length
            bint session_reused

        if cb_type != "tls-unique":
            raise ValueError(
                f"'{cb_type}' channel binding type not implemented")

        # Match CPython's RFC 5929 tls-unique selection rule.
        session_reused = SSL_session_reused(self.ssl) != 0
        if session_reused ^ (not self.server_side):
            length = SSL_get_finished(self.ssl, buf, sizeof(buf))
        else:
            length = SSL_get_peer_finished(self.ssl, buf, sizeof(buf))

        if length == 0:
            return None
        return PyBytes_FromStringAndSize(buf, length)

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

    cpdef bint socket_bio_enabled(self):
        return self.incoming == NULL or self.outgoing == NULL

    cpdef int ktls_send_enabled(self):
        return BIO_get_ktls_send(SSL_get_wbio(self.ssl))

    cpdef int ktls_recv_enabled(self):
        return BIO_get_ktls_recv(SSL_get_rbio(self.ssl))

    cdef SSLError get_error(self, int ret) noexcept:
        return <SSLError>SSL_get_error(self.ssl, ret)

    cdef int do_handshake(self) noexcept:
        return SSL_do_handshake(self.ssl)

    cdef int shutdown(self) noexcept:
        return SSL_shutdown(self.ssl)

    cdef inline SSLError read(self, conn, char *buf, Py_ssize_t buf_len, Py_ssize_t* bytes_read) except PYTHON_EXC:
        cdef:
            int rc
            int read_len
            SSLError ssl_error

        bytes_read[0] = 0
        while buf_len != 0:
            if buf_len > INT_MAX:
                read_len = INT_MAX
            else:
                read_len = <int>buf_len
            rc = SSL_read(self.ssl, buf, read_len)
            if rc > 0:
                if unlikely(self._is_debug):
                    _logger.debug("%r: SSL_read(buf_len=%d)=%d", conn, read_len, rc)

                bytes_read[0] += rc
                buf += rc
                buf_len -= rc
                continue

            ssl_error = <SSLError>self.get_error(rc)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSL_read(buf_len=%d)=%d, %s", conn, read_len, rc, ssl_error_name(ssl_error))

            if ssl_error in (
                SSLError.SSL_ERROR_WANT_READ,
                SSLError.SSL_ERROR_WANT_WRITE,
                SSLError.SSL_ERROR_ZERO_RETURN,
            ):
                return ssl_error

            if unlikely(ssl_error == SSLError.SSL_ERROR_SYSCALL):
                raise ConnectionResetError()

            exc = self.make_exc_from_ssl_error("SSL_read failed", ssl_error)
            if getattr(exc, "reason", None) == "UNEXPECTED_EOF_WHILE_READING":
                raise ConnectionResetError() from exc
            raise exc

        return SSL_ERROR_NONE

    cdef inline SSLError write(self, conn, char *data_ptr, Py_ssize_t data_len, Py_ssize_t* bytes_written) except PYTHON_EXC:
        cdef:
            Py_ssize_t last_bytes_written
            SSLError ssl_error

        bytes_written[0] = 0
        while data_len != 0:
            last_bytes_written = SSL_write(self.ssl, data_ptr, data_len)
            if last_bytes_written > 0:
                if unlikely(self._is_debug):
                    _logger.debug("%r: SSL_write(..., data_len=%d)=%d", conn, data_len, last_bytes_written)

                bytes_written[0] += last_bytes_written
                data_ptr += last_bytes_written
                data_len -= last_bytes_written

                continue

            ssl_error = <SSLError>self.get_error(last_bytes_written)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSL_write(..., data_len=%d)=%d, %s",
                              conn, data_len, last_bytes_written,
                              ssl_error_name(ssl_error))

            if unlikely(ssl_error == SSLError.SSL_ERROR_SSL):
                raise self.make_exc_from_ssl_error("SSL_write failed", ssl_error)

            # When socket BIO is used, SSL_write may fail with any of these.
            # Treat them as lost connection
            if unlikely(ssl_error in (SSLError.SSL_ERROR_SYSCALL, SSLError.SSL_ERROR_ZERO_RETURN)):
                raise ConnectionResetError()

            return ssl_error

        return SSL_ERROR_NONE

    cdef Py_ssize_t pending(self) noexcept:
        return <Py_ssize_t>SSL_pending(self.ssl)

    cdef int outgoing_bio_reset(self) noexcept:
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

    cdef allow_renegotiation(self):
        if not SSL_set_options_available():
            raise RuntimeError("SSL_set_options is not available")

        cdef:
            uint64_t SSL_OP_ALLOW_CLIENT_RENEGOTIATION = (<uint64_t>1) << 8
            uint64_t SSL_OP_ALLOW_UNSAFE_LEGACY_RENEGOTIATION = (<uint64_t>1) << 18

        SSL_set_options(
            self.ssl,
            SSL_OP_ALLOW_CLIENT_RENEGOTIATION |
            SSL_OP_ALLOW_UNSAFE_LEGACY_RENEGOTIATION
        )

    cdef int renegotiate(self) noexcept:
        return SSL_renegotiate(self.ssl)

    cdef int sendfile_available(self) noexcept:
        return <void*>SSL_sendfile != NULL

    cdef int sendfile(self, int fd, Py_ssize_t offset, size_t size) noexcept:
        return SSL_sendfile(self.ssl, fd, offset, size, 0)

    cdef make_exc_from_ssl_error(self, str descr, int err_code):
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

    cdef _exc_from_err_last_error(self, str descr):
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

    cdef _copy_hostflags_from_ctx_to_ssl(self):
        cdef:
            X509_VERIFY_PARAM* ssl_verification_params
            X509_VERIFY_PARAM* ssl_ctx_verification_params
            unsigned int ssl_ctx_host_flags

        ssl_verification_params = SSL_get0_param(self.ssl)
        ssl_ctx_verification_params = SSL_CTX_get0_param(self.ssl_ctx)
        ssl_ctx_host_flags = X509_VERIFY_PARAM_get_hostflags(ssl_ctx_verification_params)
        X509_VERIFY_PARAM_set_hostflags(ssl_verification_params, ssl_ctx_host_flags)

    cdef _configure_hostname(self):
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

    cdef bytes _certificate_to_der(self, X509* certificate):
        cdef int der_len = i2d_X509(certificate, NULL)
        cdef bytes der
        cdef unsigned char* p

        if der_len <= 0:
            raise ssl.SSLError("i2d_X509 failed")

        der = PyBytes_FromStringAndSize(NULL, der_len)

        p = <unsigned char*>PyBytes_AS_STRING(der)
        if i2d_X509(certificate, &p) != der_len:
            raise ssl.SSLError("i2d_X509 produced invalid DER size")

        return der

    cdef list _certificate_chain_to_der(
            self, OPENSSL_STACK* chain):
        cdef:
            int index
            int length
            X509* certificate
            list result = []

        if chain == NULL:
            return result

        length = OPENSSL_sk_num(chain)
        if length < 0:
            raise ssl.SSLError("OPENSSL_sk_num failed")

        for index in range(length):
            certificate = <X509*>OPENSSL_sk_value(chain, index)
            if certificate == NULL:
                raise ssl.SSLError("OPENSSL_sk_value failed")
            result.append(self._certificate_to_der(certificate))

        return result

    cdef _decode_certificate(self, X509* certificate):
        cdef bytes der = self._certificate_to_der(certificate)
        cdef str path = None

        pem = ssl.DER_cert_to_PEM_cert(der)
        try:
            # _test_decode_cert() only accepts a path. Close the file before
            # reopening it so this also works on Windows.
            with tempfile.NamedTemporaryFile(
                    mode="w", delete=False, encoding="ascii") as tmp:
                path = tmp.name
                tmp.write(pem)
            return ssl._ssl._test_decode_cert(path)
        finally:
            if path:
                os.unlink(path)


cdef ssl_error_name(int err):
    return SSLError(err).name
