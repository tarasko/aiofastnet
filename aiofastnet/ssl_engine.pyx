import asyncio
import ssl


cdef class SSLEngine:
    def __init__(self, ssl_context, bint server_side, str server_hostname):
        if not server_side and ssl_context.check_hostname and not server_hostname:
            raise ValueError("SSLContext.check_hostname requires server_hostname")

        self.ssl_context = ssl_context
        self.server_hostname = server_hostname
        self.server_side = server_side
        self.ktls_requested = (ssl_context.options & getattr(ssl, "OP_ENABLE_KTLS", 0)) != 0

        try:
            self._is_debug = asyncio.get_running_loop().get_debug()
        except RuntimeError:
            self._is_debug = False

    cdef int ktls_send_enabled(self) noexcept:
        return 0

    cdef int ktls_recv_enabled(self) noexcept:
        return 0

    cdef bint ssl_incoming_use_membio(self) noexcept:
        return False

    cdef bint ssl_outgoing_use_membio(self) noexcept:
        return False

    cdef get_ssl_object(self):
        raise NotImplementedError()

    cdef SSLError do_handshake(self, conn) except SSLError.PYTHON_EXC:
        raise NotImplementedError()

    cdef SSLError shutdown(self, conn) except SSLError.PYTHON_EXC:
        raise NotImplementedError()

    cdef SSLError read(self, conn, char *buf, Py_ssize_t buf_len, Py_ssize_t* bytes_read) except SSLError.PYTHON_EXC:
        raise NotImplementedError()

    cdef SSLError write(self, conn, char *data_ptr, Py_ssize_t data_len, Py_ssize_t* bytes_written) except SSLError.PYTHON_EXC:
        raise NotImplementedError()

    cdef SSLError sendfile(self, conn, int fd, Py_ssize_t offset, Py_ssize_t count, Py_ssize_t* bytes_written) except SSLError.PYTHON_EXC:
        raise NotImplementedError()

    cdef incoming_bio_get_write_buf(self, char **pp, Py_ssize_t *space):
        raise NotImplementedError()

    cdef incoming_bio_produce(self, Py_ssize_t nbytes):
        raise NotImplementedError()

    cdef int sendfile_available(self) except -1:
        raise NotImplementedError()

    cdef allow_renegotiation(self):
        raise NotImplementedError()

    cdef int renegotiate(self) except -1:
        raise NotImplementedError()

    cdef int outgoing_bio_reset(self) except -1:
        raise NotImplementedError()

    cdef Py_ssize_t outgoing_bio_pending(self) except -1:
        raise NotImplementedError()

    cdef Py_ssize_t outgoing_bio_get_data(self, char** pp) except -1:
        raise NotImplementedError()

    cdef outgoing_bio_consume(self, Py_ssize_t nbytes):
        raise NotImplementedError()


cdef ssl_error_name(int err):
    return SSLError(err).name
