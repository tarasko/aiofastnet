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
    SSL_METHOD,
    X509_STORE,
    aiofn_bundled_openssl_available,
    init_openssl_compat_bundled,
    aiofn_bundled_set_server_alpn,
    SSL_CTX_new,
    TLS_method,
    SSL_CTX_free,
    SSL_CTX_set_verify,
    SSL_CTX_set_options,
    aiofn_SSL_CTX_set_min_proto_version,
    aiofn_SSL_CTX_set_max_proto_version,
    SSL_CTX_get_cert_store,
    X509_STORE_add_cert,
    d2i_X509,
    SSL_CTX_use_certificate_chain_file,
    SSL_CTX_use_PrivateKey_file,
    SSL_CTX_check_private_key,
    SSL_CTX_set_cipher_list,
    SSL_CTX_set_alpn_protos,
    SSL_CTX_load_verify_locations,
    X509_VERIFY_PARAM_set_flags,
    SSL_CTX_get0_certificate,
)
from cpython.pycapsule cimport (
    PyCapsule_New,
    PyCapsule_GetPointer,
    PyCapsule_IsValid,
)
from .openssl_compat import OPENSSL_DYN_LIBS, BORROW_LIBS

from cpython.object cimport PyObject
from cpython.bytes cimport PyBytes_FromStringAndSize, PyBytes_AS_STRING
from cpython.bytearray cimport (
    PyByteArray_FromStringAndSize,
    PyByteArray_AS_STRING,
    PyByteArray_GET_SIZE
)
from cpython.unicode cimport PyUnicode_FromString, PyUnicode_FromStringAndSize

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


# Selected OpenSSL backend. "borrow" reuses the interpreter's OpenSSL (the
# SSL_CTX is shared from the Python ssl.SSLContext); "bundled" uses aiofastnet's
# own statically linked OpenSSL and builds its own SSL_CTX.
BACKEND = None
cdef bint _BACKEND_BUNDLED = False


cdef _init_openssl():
    global BACKEND, _BACKEND_BUNDLED

    if BORROW_LIBS is not None:
        if init_openssl_compat(OPENSSL_DYN_LIBS.libssl_path, OPENSSL_DYN_LIBS.libcrypto_path) != 1:
            missing_lib = openssl_compat_last_error()
            if missing_lib != NULL:
                raise ImportError(
                    f"aiofastnet: failed to initialize OpenSSL compatibility layer; "
                    f"missing symbol: {PyUnicode_FromString(missing_lib)}; "
                    f"ssl_lib={OPENSSL_DYN_LIBS.libssl}, crypto_lib={OPENSSL_DYN_LIBS.libcrypto}")
            raise ImportError("aiofastnet: failed to initialize OpenSSL compatibility layer")
        BACKEND = "borrow"
        return

    if aiofn_bundled_openssl_available():
        if init_openssl_compat_bundled() != 1:
            missing_lib = openssl_compat_last_error()
            detail = (f"; {PyUnicode_FromString(missing_lib)}"
                      if missing_lib != NULL else "")
            raise ImportError(
                f"aiofastnet: failed to initialize bundled OpenSSL backend{detail}")
        BACKEND = "bundled"
        _BACKEND_BUNDLED = True
        return

    raise ImportError(
        "aiofastnet requires a Python distribution that is dynamically linked "
        "against OpenSSL. Your Python appears to be statically linked against "
        "OpenSSL (common for uv's python-build-standalone), and this aiofastnet "
        "build does not include a bundled OpenSSL. Either use a dynamically "
        "linked Python, or install an aiofastnet build with bundled OpenSSL.")


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


# ---------------------------------------------------------------------------
# Bundled backend: build our own SSL_CTX from the caller's ssl.SSLContext.
#
# Used only when aiofastnet runs on its statically linked OpenSSL (e.g. uv
# python-build-standalone), where the interpreter's OpenSSL SSL_CTX cannot be
# borrowed. The built SSL_CTX is cached on the Python context inside a PyCapsule
# whose destructor frees it, so it is reused across connections.
# ---------------------------------------------------------------------------

cdef bytes _CAP_NAME_B = b"aiofastnet.bundled_ssl_ctx"
cdef const char* _CAP_NAME = _CAP_NAME_B


cdef void _bundled_ctx_capsule_destructor(object cap) noexcept:
    if not PyCapsule_IsValid(cap, _CAP_NAME):
        return
    cdef void* p = PyCapsule_GetPointer(cap, _CAP_NAME)
    if p != NULL:
        SSL_CTX_free(<SSL_CTX*>p)


cdef _bundled_ssl_error(str descr):
    cdef unsigned long e = ERR_peek_last_error()
    cdef const char* reason = ERR_reason_error_string(e) if e != 0 else NULL
    msg = PyUnicode_FromString(reason) if reason != NULL else ""
    ERR_clear_error()
    return ssl.SSLError(f"aiofastnet bundled backend: {descr}: {msg}")


cdef int _tls_version_to_openssl(object v):
    # ssl.TLSVersion enum values match OpenSSL version constants; the negative
    # MINIMUM_SUPPORTED / MAXIMUM_SUPPORTED sentinels map to 0 ("auto").
    cdef long iv = int(v)
    if iv < 0:
        return 0
    return <int>iv


cdef int _verify_mode_to_openssl(object verify_mode):
    # ssl.VerifyMode (CERT_NONE=0, CERT_OPTIONAL=1, CERT_REQUIRED=2) is NOT the
    # same as OpenSSL's SSL_VERIFY_* bit flags. Map it the way CPython's ssl
    # module does, otherwise the server never sends a CertificateRequest
    # (SSL_VERIFY_PEER is required) and the client never aborts on a bad cert.
    # SSL_VERIFY_NONE=0, SSL_VERIFY_PEER=0x01, SSL_VERIFY_FAIL_IF_NO_PEER_CERT=0x02
    cdef int vm = int(verify_mode)
    if vm == 0:        # CERT_NONE
        return 0
    elif vm == 1:      # CERT_OPTIONAL
        return 0x01
    else:              # CERT_REQUIRED
        return 0x01 | 0x02


cdef bytes _encode_alpn(object protocols):
    cdef bytearray buf = bytearray()
    cdef bytes b
    for proto in protocols:
        b = proto.encode("ascii") if isinstance(proto, str) else bytes(proto)
        if len(b) == 0 or len(b) > 255:
            raise ValueError(f"invalid ALPN protocol: {proto!r}")
        buf.append(len(b))
        buf += b
    return bytes(buf)


cdef _bundled_add_ca_der(SSL_CTX* ctx, bytes der):
    cdef const unsigned char* p = <const unsigned char*>PyBytes_AS_STRING(der)
    cdef X509* x = d2i_X509(NULL, &p, <long>len(der))
    if x == NULL:
        ERR_clear_error()
        return
    cdef X509_STORE* store = SSL_CTX_get_cert_store(ctx)
    # Duplicate adds return an error we deliberately ignore.
    X509_STORE_add_cert(store, x)
    ERR_clear_error()
    X509_free(x)


cdef _bundled_load_verify_locations(SSL_CTX* ctx, tuple args, dict kwargs):
    cafile = kwargs.get("cafile")
    capath = kwargs.get("capath")
    if cafile is None and len(args) >= 1:
        cafile = args[0]
    if capath is None and len(args) >= 2:
        capath = args[1]
    # cadata is already covered by get_ca_certs() on the Python context.

    cdef bytes caf = os.fsencode(cafile) if cafile is not None else None
    cdef bytes cap = os.fsencode(capath) if capath is not None else None
    cdef const char* caf_p = <const char*>caf if caf is not None else NULL
    cdef const char* cap_p = <const char*>cap if cap is not None else NULL
    if caf_p == NULL and cap_p == NULL:
        return
    if SSL_CTX_load_verify_locations(ctx, caf_p, cap_p) != 1:
        # May already be present via get_ca_certs(); don't hard-fail.
        ERR_clear_error()


cdef _bundled_load_cert_chain(SSL_CTX* ctx, tuple args, dict kwargs):
    certfile = kwargs.get("certfile")
    keyfile = kwargs.get("keyfile")
    password = kwargs.get("password")
    if certfile is None and len(args) >= 1:
        certfile = args[0]
    if keyfile is None and len(args) >= 2:
        keyfile = args[1]
    if password is None and len(args) >= 3:
        password = args[2]

    if certfile is None:
        raise ssl.SSLError(
            "aiofastnet bundled backend: load_cert_chain requires a certfile")
    if password is not None:
        raise NotImplementedError(
            "aiofastnet bundled backend: password-protected private keys are "
            "not supported yet")

    cdef bytes cf = os.fsencode(certfile)
    if SSL_CTX_use_certificate_chain_file(ctx, <const char*>cf) != 1:
        raise _bundled_ssl_error("use_certificate_chain_file failed")

    keypath = keyfile if keyfile is not None else certfile
    cdef bytes kf = os.fsencode(keypath)
    # SSL_FILETYPE_PEM == 1
    if SSL_CTX_use_PrivateKey_file(ctx, <const char*>kf, 1) != 1:
        raise _bundled_ssl_error("use_PrivateKey_file failed")
    if SSL_CTX_check_private_key(ctx) != 1:
        raise _bundled_ssl_error("private key does not match certificate")


cdef _bundled_set_ciphers(SSL_CTX* ctx, object cipherlist):
    cdef bytes cb = cipherlist.encode()
    if SSL_CTX_set_cipher_list(ctx, <const char*>cb) != 1:
        raise _bundled_ssl_error("set_cipher_list failed")


cdef _bundled_set_alpn(SSL_CTX* ctx, object protocols):
    cdef bytes wire = _encode_alpn(protocols)
    cdef const unsigned char* p = <const unsigned char*>PyBytes_AS_STRING(wire)
    cdef unsigned int wlen = <unsigned int>len(wire)
    # SSL_CTX_set_alpn_protos returns 0 on success (advertised by clients).
    if SSL_CTX_set_alpn_protos(ctx, p, wlen) != 0:
        raise _bundled_ssl_error("SSL_CTX_set_alpn_protos failed")
    # Server-side selection callback (takes ownership of a copy of the list).
    if aiofn_bundled_set_server_alpn(ctx, p, wlen) != 1:
        raise ssl.SSLError(
            "aiofastnet bundled backend: failed to install server ALPN callback")


cdef _bundled_replay(SSL_CTX* ctx, tuple entry):
    cdef str method = entry[0]
    cdef tuple args = entry[1]
    cdef dict kwargs = entry[2]
    if method == "load_verify_locations":
        _bundled_load_verify_locations(ctx, args, kwargs)
    elif method == "load_cert_chain":
        _bundled_load_cert_chain(ctx, args, kwargs)
    elif method == "set_ciphers":
        _bundled_set_ciphers(ctx, args[0])
    elif method == "set_alpn_protocols":
        _bundled_set_alpn(ctx, args[0])


cdef SSL_CTX* _build_bundled_ctx(object py_ctx) except NULL:
    cdef SSL_CTX* ctx = SSL_CTX_new(TLS_method())
    cdef unsigned long vflags
    if ctx == NULL:
        raise MemoryError("aiofastnet bundled backend: SSL_CTX_new failed")
    try:
        aiofn_SSL_CTX_set_min_proto_version(
            ctx, _tls_version_to_openssl(py_ctx.minimum_version))
        aiofn_SSL_CTX_set_max_proto_version(
            ctx, _tls_version_to_openssl(py_ctx.maximum_version))
        SSL_CTX_set_options(ctx, <uint64_t>int(py_ctx.options))
        SSL_CTX_set_verify(ctx, _verify_mode_to_openssl(py_ctx.verify_mode), NULL)

        # Certificate-verification flags (CRL checking, X509_STRICT, ...).
        # NOTE: other context state that cannot be read back from a plain
        # ssl.SSLContext -- post_handshake_auth, custom hostflags, sni/verify
        # callbacks -- is not reproduced by the bundled backend yet.
        vflags = <unsigned long>int(py_ctx.verify_flags)
        if vflags:
            X509_VERIFY_PARAM_set_flags(SSL_CTX_get0_param(ctx), vflags)

        # Trust anchors readable from any SSLContext (covers system CAs loaded by
        # ssl.create_default_context() and any cadata).
        for der in py_ctx.get_ca_certs(binary_form=True):
            _bundled_add_ca_der(ctx, der)

        # Replay config that cannot be read back from a plain SSLContext.
        config = getattr(py_ctx, "_aiofastnet_config", None)
        if config:
            for entry in config:
                _bundled_replay(ctx, entry)
        return ctx
    except:
        SSL_CTX_free(ctx)
        raise


cdef _bundled_missing_server_cert_error():
    return ssl.SSLError(
        "aiofastnet bundled backend: the server SSLContext has no certificate. "
        "On this Python (statically linked OpenSSL), aiofastnet cannot read a "
        "certificate loaded into a plain ssl.SSLContext. Create the context with "
        "aiofastnet.SSLContext(...) and call load_cert_chain() on it so aiofastnet "
        "can replay it onto its own SSL_CTX.")


cdef tuple _bundled_ctx_signature(object py_ctx):
    # Cheap snapshot of everything that feeds the bundled SSL_CTX, so the cache
    # is rebuilt when the Python context is mutated after first use.
    #
    #  * recorded config only grows by append -> its length detects new
    #    load_cert_chain / load_verify_locations / set_ciphers /
    #    set_alpn_protocols calls on an aiofastnet.SSLContext.
    #  * cert_store_stats() is a cheap C-level count that detects trust-store
    #    mutations (load_verify_locations / load_default_certs) on a *plain*
    #    ssl.SSLContext, which are not recorded.
    config = getattr(py_ctx, "_aiofastnet_config", None)
    cdef dict stats = py_ctx.cert_store_stats()
    return (
        int(py_ctx.verify_mode),
        bool(py_ctx.check_hostname),
        int(py_ctx.minimum_version),
        int(py_ctx.maximum_version),
        int(py_ctx.options),
        int(py_ctx.verify_flags),
        stats.get("x509", 0),
        stats.get("x509_ca", 0),
        stats.get("crl", 0),
        len(config) if config is not None else 0,
    )


def aiofn_preflight_server_context(ssl_context):
    """Validate a server-side SSLContext at server-creation time.

    On the bundled backend this eagerly builds (and caches) the SSL_CTX and
    ensures it carries a certificate, so a misconfiguration surfaces as a clear
    error from create_server()/start_server() instead of an opaque per-connection
    connection reset. No-op on the borrow backend (where the interpreter's own
    SSL_CTX is shared and already carries whatever was loaded).
    """
    if not _BACKEND_BUNDLED or ssl_context is None:
        return
    cap = _ensure_bundled_ctx(ssl_context)
    cdef SSL_CTX* ctx = <SSL_CTX*>PyCapsule_GetPointer(cap, _CAP_NAME)
    if SSL_CTX_get0_certificate(ctx) == NULL:
        raise _bundled_missing_server_cert_error()


cdef object _ensure_bundled_ctx(object py_ctx):
    # Return a PyCapsule that owns the bundled SSL_CTX for py_ctx, (re)building
    # and caching it on the context whenever its configuration signature changes.
    sig = _bundled_ctx_signature(py_ctx)
    cap = getattr(py_ctx, "_aiofastnet_bundled_ctx", None)
    cached_sig = getattr(py_ctx, "_aiofastnet_bundled_sig", None)
    if (cap is not None and PyCapsule_IsValid(cap, _CAP_NAME)
            and cached_sig == sig):
        return cap

    cdef SSL_CTX* ctx = _build_bundled_ctx(py_ctx)
    cap = PyCapsule_New(<void*>ctx, _CAP_NAME, _bundled_ctx_capsule_destructor)
    try:
        py_ctx._aiofastnet_bundled_ctx = cap
        py_ctx._aiofastnet_bundled_sig = sig
    except (AttributeError, TypeError):
        # Couldn't cache on the context; the SSLObject keeps the capsule alive.
        pass
    return cap


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
        if _BACKEND_BUNDLED:
            # Build/reuse our own SSL_CTX from the caller's config. Keep a
            # reference to the owning capsule so the SSL_CTX outlives this object
            # even if it could not be cached on the Python context.
            cap = _ensure_bundled_ctx(ssl_context)
            self._bundled_ctx_cap = cap
            self.ssl_ctx = <SSL_CTX*>PyCapsule_GetPointer(cap, _CAP_NAME)
            if server_side and SSL_CTX_get0_certificate(self.ssl_ctx) == NULL:
                # Defense in depth: create_server() preflights this, but a server
                # with no certificate can otherwise only fail deep inside the
                # handshake with an opaque error.
                raise _bundled_missing_server_cert_error()
        else:
            self.ssl_ctx = _get_ssl_ctx_ptr(ssl_context)

        self.ssl = NULL
        self.incoming_buf = None
        self.outgoing_buf = None
        self.incoming = NULL
        self.outgoing = NULL

        self.server_hostname = server_hostname
        self.server_side = server_side

        cdef bint force_socket_bio = getattr(ssl_context, "_aiofastnet_force_socket_bio", False)

        self.ktls_requested = (ssl_context.options & getattr(ssl, "OP_ENABLE_KTLS", 0)) != 0

        # force_socket_bio is only used for testing, tests should not use it together with OP_ENABLE_KTLS
        assert not self.ktls_requested or (self.ktls_requested and not force_socket_bio)

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

    cdef int get_error(self, int ret) noexcept:
        return SSL_get_error(self.ssl, ret)

    cdef int do_handshake(self) noexcept:
        return SSL_do_handshake(self.ssl)

    cdef int shutdown(self) noexcept:
        return SSL_shutdown(self.ssl)

    cdef inline int read(self, void *buf, size_t num) noexcept:
        return SSL_read(self.ssl, buf, num)

    cdef inline int write(self, const void *buf, size_t num) noexcept:
        return SSL_write(self.ssl, buf, num)

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
