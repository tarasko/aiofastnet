from .openssl cimport SSL_CTX, BIO, SSL, X509, OPENSSL_STACK
from .ssl_engine cimport SSLEngine, SSLError
from libc.stdint cimport uint64_t


cdef class SSLEngineDirect(SSLEngine):
    # Wraps raw openssl pointers and provide some methods of ssl.SSLObject that may be
    # interesting for the user.

    cdef:
        object ssl_ctx_py
        SSL_CTX* ssl_ctx
        bytearray incoming_buf
        bytearray outgoing_buf
        BIO* incoming
        BIO* outgoing
        SSL* ssl

    cdef:
        bint _is_debug

    cdef:
        readonly str server_hostname
        readonly bint server_side

    cpdef object version(self)
    cpdef tuple cipher(self)
    cpdef object shared_ciphers(self)
    cpdef object getpeercert(self, binary_form=*)
    cpdef list get_verified_chain(self)
    cpdef list get_unverified_chain(self)
    cpdef object get_channel_binding(self, str cb_type=*)
    cpdef str compression(self)
    cpdef object selected_alpn_protocol(self)
    cpdef Py_ssize_t pending(self) except -1

    # Implementation details
    cdef inline _make_exc_from_ssl_error(self, str descr, int err_code)
    cdef inline bytes _certificate_to_der(self, X509* certificate)
    cdef inline list _certificate_chain_to_der(self, OPENSSL_STACK* chain)
    cdef inline _exc_from_err_last_error(self, str descr)
    cdef inline _copy_hostflags_from_ctx_to_ssl(self)
    cdef inline _configure_hostname(self)
    cdef inline _decode_certificate(self, X509* certificate)
