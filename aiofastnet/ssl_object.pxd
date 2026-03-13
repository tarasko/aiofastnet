from .openssl cimport SSL_CTX, BIO, SSL, X509


cdef class SSLObject:
    # Wraps raw openssl pointers and provide some methods that may be
    # interesting for the user.
    #
    # Provided methods:
    # * getpeercert()
    # * cipher()
    # * compression()

    cdef:
        object ssl_ctx_py
        SSL_CTX* ssl_ctx
        bytearray incoming_buf
        bytearray outgoing_buf
        BIO* incoming
        BIO* outgoing
        SSL* ssl
        str server_hostname

    # Exposed to the end user
    cpdef tuple cipher(self)
    cpdef dict getpeercert(self, binary_form=*)
    cpdef str compression(self)

    # Used by SSLProtocol
    # These methods wrap SSL* operations
    cdef inline int get_error(self, int ret) noexcept
    cdef inline int do_handshake(self) noexcept
    cdef inline int get_shutdown(self) noexcept
    cdef inline int shutdown(self) noexcept
    cdef inline int read_ex(self, void *buf, size_t num, size_t *bytes_read) noexcept
    cdef inline int write_ex(self, const void *buf, size_t num, size_t *bytes_written) noexcept
    cdef inline Py_ssize_t pending(self) noexcept
    cdef inline void allow_renegotiation(self) noexcept
    cdef inline int renegotiate(self) noexcept

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
    cdef inline _exc_from_err_last_error(self, str descr)
    cdef inline _configure_hostname(self)
    cdef inline _decode_certificate(self, X509* certificate)

