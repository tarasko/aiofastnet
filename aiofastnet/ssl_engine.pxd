cpdef enum SSLError:
    PYTHON_EXC = -1
    SSL_ERROR_NONE = 0
    SSL_ERROR_SSL = 1
    SSL_ERROR_WANT_READ = 2
    SSL_ERROR_WANT_WRITE = 3
    SSL_ERROR_SYSCALL = 5
    SSL_ERROR_ZERO_RETURN = 6


cdef class SSLEngine:
    cdef dict __dict__

    cdef:
        readonly object ssl_ctx_py
        readonly str server_hostname
        readonly bint server_side
        readonly bint ktls_requested
        bint _is_debug

    cdef int ktls_send_enabled(self) noexcept
    cdef int ktls_recv_enabled(self) noexcept
    cdef bint ssl_incoming_use_membio(self) noexcept
    cdef bint ssl_outgoing_use_membio(self) noexcept

    cdef object get_ssl_object(self)

    cdef SSLError do_handshake(self, conn) except SSLError.PYTHON_EXC
    cdef SSLError shutdown(self, conn) except SSLError.PYTHON_EXC
    cdef SSLError read(self, conn, char *buf, Py_ssize_t buf_len, Py_ssize_t* bytes_read) except SSLError.PYTHON_EXC
    cdef SSLError write(self, conn, char *data_ptr, Py_ssize_t data_len, Py_ssize_t* bytes_written) except SSLError.PYTHON_EXC
    cdef SSLError sendfile(self, conn, int fd, Py_ssize_t offset, Py_ssize_t count, Py_ssize_t* bytes_written) except SSLError.PYTHON_EXC

    cdef incoming_bio_get_write_buf(self, char **pp, Py_ssize_t *space)
    cdef incoming_bio_produce(self, Py_ssize_t nbytes)

    cdef bint sendfile_available(self) noexcept
    cdef allow_renegotiation(self)
    cdef int renegotiate(self) except -1

    cdef outgoing_bio_reset(self)
    cdef Py_ssize_t outgoing_bio_pending(self) except -1
    cdef Py_ssize_t outgoing_bio_get_data(self, char** pp) except -1
    cdef outgoing_bio_consume(self, Py_ssize_t nbytes)


cdef ssl_error_name(int err)
