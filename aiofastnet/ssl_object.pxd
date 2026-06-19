from .openssl cimport SSL_CTX, BIO, SSL, X509, OPENSSL_STACK
from libc.stdint cimport uint64_t


cpdef enum SSLError:
    SSL_ERROR_NONE = 0
    SSL_ERROR_SSL = 1
    SSL_ERROR_WANT_READ = 2
    SSL_ERROR_WANT_WRITE = 3
    SSL_ERROR_SYSCALL = 5
    SSL_ERROR_ZERO_RETURN = 6


cdef class SSLObject:
    # Wraps raw openssl pointers and provide some methods of ssl.SSLObject that may be
    # interesting for the user.

    # To allow mocking in user tests
    cdef dict __dict__

    cdef:
        object ssl_ctx_py
        SSL_CTX* ssl_ctx
        bytearray incoming_buf
        bytearray outgoing_buf
        BIO* incoming
        BIO* outgoing
        SSL* ssl

    # Exposed to the end user

    cdef:
        readonly str server_hostname
        readonly bint server_side
        readonly bint ktls_requested

    cpdef object version(self)
    cpdef tuple cipher(self)
    cpdef object shared_ciphers(self)
    cpdef object getpeercert(self, binary_form=*)
    cpdef list get_verified_chain(self)
    cpdef list get_unverified_chain(self)
    cpdef object get_channel_binding(self, str cb_type=*)
    cpdef str compression(self)
    cpdef object selected_alpn_protocol(self)
    cpdef bint socket_bio_enabled(self)
    cpdef int ktls_send_enabled(self)
    cpdef int ktls_recv_enabled(self)

    # Used by SSLProtocol
    # These methods wrap SSL* operations
    cdef inline int get_error(self, int ret) noexcept
    cdef inline int do_handshake(self) noexcept
    cdef inline int shutdown(self) noexcept
    cdef inline int read(self, void *buf, size_t num) noexcept
    cdef inline int write(self, const void *buf, size_t num) noexcept
    cdef inline Py_ssize_t pending(self) noexcept
    cdef inline allow_renegotiation(self)
    cdef inline int renegotiate(self) noexcept
    cdef inline int sendfile_available(self) noexcept
    cdef inline int sendfile(self, int fd, Py_ssize_t offset, size_t size) noexcept

    # These methods wrape BIO* operations
    cdef inline int outgoing_bio_reset(self) noexcept
    cdef inline Py_ssize_t outgoing_bio_pending(self) except -1
    cdef inline Py_ssize_t outgoing_bio_get_data(self, char** pp) noexcept
    cdef inline outgoing_bio_consume(self, Py_ssize_t nbytes)

    cdef inline Py_ssize_t incoming_bio_pending(self) except -1
    cdef inline incoming_bio_get_write_buf(self, char **pp, Py_ssize_t *space)
    cdef inline incoming_bio_produce(self, Py_ssize_t nbytes)

    cdef inline make_exc_from_ssl_error(self, str descr, int err_code)

    # Implementation details
    cdef inline bytes _certificate_to_der(self, X509* certificate)
    cdef inline list _certificate_chain_to_der(self, OPENSSL_STACK* chain)
    cdef inline _exc_from_err_last_error(self, str descr)
    cdef inline _copy_hostflags_from_ctx_to_ssl(self)
    cdef inline _configure_hostname(self)
    cdef inline _decode_certificate(self, X509* certificate)


cdef ssl_error_name(int err)
