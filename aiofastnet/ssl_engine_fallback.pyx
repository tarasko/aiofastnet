import ssl

from cpython.bytearray cimport PyByteArray_AS_STRING
from cpython.bytes cimport PyBytes_AS_STRING, PyBytes_GET_SIZE, PyBytes_FromStringAndSize
from libc.limits cimport INT_MAX
from libc.string cimport memcpy

from .ssl_engine cimport SSLEngine, SSLError, ssl_error_name
from .utils cimport unlikely

import logging

cdef object _logger = logging.getLogger('aiofastnet.ssl')


cdef class SSLEngineFallback(SSLEngine):
    cdef:
        object ssl_object
        object incoming
        object outgoing
        bytearray incoming_buf
        bytes outgoing_data

    def __init__(self, ssl_context, bint server_side, str server_hostname,
                 Py_ssize_t read_buffer_size, Py_ssize_t write_buffer_size,
                 sock=None):
        SSLEngine.__init__(self, ssl_context, server_side, server_hostname)

        self.incoming = ssl.MemoryBIO()
        self.outgoing = ssl.MemoryBIO()
        self.incoming_buf = bytearray(read_buffer_size)
        self.outgoing_data = b""
        self.ssl_object = ssl_context.wrap_bio(
            self.incoming,
            self.outgoing,
            server_side=server_side,
            server_hostname=server_hostname,
        )

    cdef inline SSLError _translate_ssl_error(self, exc) except SSLError.PYTHON_EXC:
        if isinstance(exc, ssl.SSLWantReadError):
            return SSLError.SSL_ERROR_WANT_READ
        if isinstance(exc, ssl.SSLWantWriteError):
            return SSLError.SSL_ERROR_WANT_WRITE
        if isinstance(exc, ssl.SSLZeroReturnError):
            return SSLError.SSL_ERROR_ZERO_RETURN
        if isinstance(exc, ssl.SSLSyscallError):
            raise ConnectionResetError() from exc
        raise exc

    cdef int ktls_send_enabled(self) noexcept:
        return 0

    cdef int ktls_recv_enabled(self) noexcept:
        return 0

    cdef bint ssl_incoming_use_membio(self) noexcept:
        return True

    cdef bint ssl_outgoing_use_membio(self) noexcept:
        return True

    cdef object get_ssl_object(self):
        return self.ssl_object

    cdef SSLError do_handshake(self, conn) except SSLError.PYTHON_EXC:
        try:
            self.ssl_object.do_handshake()
        except ssl.SSLError as exc:
            ssl_error = self._translate_ssl_error(exc)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSLObject.do_handshake(), %s", conn, ssl_error_name(ssl_error))
            if ssl_error in (SSLError.SSL_ERROR_WANT_READ, SSLError.SSL_ERROR_WANT_WRITE):
                return ssl_error
            raise RuntimeError(f"unexpected SSLObject.do_handshake error: {ssl_error_name(ssl_error)}") from exc

        if unlikely(self._is_debug):
            _logger.debug("%r: SSLObject.do_handshake() complete", conn)
        return SSLError.SSL_ERROR_NONE

    cdef SSLError shutdown(self, conn) except SSLError.PYTHON_EXC:
        try:
            self.ssl_object.unwrap()
        except ssl.SSLError as exc:
            ssl_error = self._translate_ssl_error(exc)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSLObject.unwrap(), %s", conn, ssl_error_name(ssl_error))
            if ssl_error in (SSLError.SSL_ERROR_WANT_READ, SSLError.SSL_ERROR_WANT_WRITE):
                return ssl_error
            if ssl_error == SSLError.SSL_ERROR_ZERO_RETURN:
                return SSLError.SSL_ERROR_NONE
            raise RuntimeError(f"unexpected SSLObject.unwrap error: {ssl_error_name(ssl_error)}") from exc

        if unlikely(self._is_debug):
            _logger.debug("%r: SSLObject.unwrap() complete", conn)
        return SSLError.SSL_ERROR_NONE

    cdef SSLError read(self, conn, char *buf, Py_ssize_t buf_len, Py_ssize_t* bytes_read) except SSLError.PYTHON_EXC:
        cdef:
            bytes data
            Py_ssize_t data_len
            int read_len
            SSLError ssl_error

        bytes_read[0] = 0
        while buf_len != 0:
            if self.ssl_object.pending() == 0 and self.incoming.pending == 0:
                return SSLError.SSL_ERROR_WANT_READ

            read_len = INT_MAX if buf_len > INT_MAX else <int>buf_len
            try:
                data = self.ssl_object.read(read_len)
            except ssl.SSLError as exc:
                ssl_error = self._translate_ssl_error(exc)
                if unlikely(self._is_debug):
                    _logger.debug("%r: SSLObject.read(buf_len=%d), %s", conn, read_len, ssl_error_name(ssl_error))
                if ssl_error in (
                    SSLError.SSL_ERROR_WANT_READ,
                    SSLError.SSL_ERROR_WANT_WRITE,
                    SSLError.SSL_ERROR_ZERO_RETURN,
                ):
                    return ssl_error
                raise RuntimeError(f"unexpected SSLObject.read error: {ssl_error_name(ssl_error)}") from exc

            data_len = PyBytes_GET_SIZE(data)
            if data_len == 0:
                return SSLError.SSL_ERROR_ZERO_RETURN

            if unlikely(self._is_debug):
                _logger.debug("%r: SSLObject.read(buf_len=%d)=%d", conn, read_len, data_len)

            memcpy(buf, PyBytes_AS_STRING(data), data_len)
            bytes_read[0] += data_len
            buf += data_len
            buf_len -= data_len

        return SSLError.SSL_ERROR_NONE

    cdef SSLError write(self, conn, char *data_ptr, Py_ssize_t data_len, Py_ssize_t* bytes_written) except SSLError.PYTHON_EXC:
        cdef:
            bytes data
            Py_ssize_t last_bytes_written
            SSLError ssl_error

        bytes_written[0] = 0
        while data_len != 0:
            data = PyBytes_FromStringAndSize(data_ptr, data_len)
            try:
                last_bytes_written = self.ssl_object.write(data)
            except ssl.SSLError as exc:
                ssl_error = self._translate_ssl_error(exc)
                if unlikely(self._is_debug):
                    _logger.debug("%r: SSLObject.write(data_len=%d), %s", conn, data_len, ssl_error_name(ssl_error))
                if ssl_error in (SSLError.SSL_ERROR_WANT_READ, SSLError.SSL_ERROR_WANT_WRITE):
                    return ssl_error
                raise RuntimeError(f"unexpected SSLObject.write error: {ssl_error_name(ssl_error)}") from exc

            if last_bytes_written <= 0:
                raise RuntimeError("SSLObject.write made no progress")

            if unlikely(self._is_debug):
                _logger.debug("%r: SSLObject.write(data_len=%d)=%d", conn, data_len, last_bytes_written)

            bytes_written[0] += last_bytes_written
            data_ptr += last_bytes_written
            data_len -= last_bytes_written

        return SSLError.SSL_ERROR_NONE

    cdef SSLError sendfile(self, conn, int fd, Py_ssize_t offset, Py_ssize_t count, Py_ssize_t* bytes_written) except SSLError.PYTHON_EXC:
        bytes_written[0] = 0
        raise NotImplementedError()

    cdef incoming_bio_get_write_buf(self, char **pp, Py_ssize_t *space):
        pp[0] = PyByteArray_AS_STRING(self.incoming_buf)
        space[0] = len(self.incoming_buf)

    cdef incoming_bio_produce(self, Py_ssize_t nbytes):
        if nbytes == 0:
            return
        self.incoming.write(PyBytes_FromStringAndSize(PyByteArray_AS_STRING(self.incoming_buf), nbytes))

    cdef int sendfile_available(self) except -1:
        return 0

    cdef allow_renegotiation(self):
        pass

    cdef int renegotiate(self) except -1:
        raise NotImplementedError("stdlib ssl.SSLObject does not expose renegotiation")

    cdef int outgoing_bio_reset(self) except -1:
        self.outgoing_data = b""
        while self.outgoing.pending:
            self.outgoing.read()
        return 1

    cdef Py_ssize_t outgoing_bio_pending(self) except -1:
        return PyBytes_GET_SIZE(self.outgoing_data) + self.outgoing.pending

    cdef Py_ssize_t outgoing_bio_get_data(self, char** pp) except -1:
        if PyBytes_GET_SIZE(self.outgoing_data) == 0 and self.outgoing.pending:
            self.outgoing_data = self.outgoing.read()

        pp[0] = PyBytes_AS_STRING(self.outgoing_data)
        return PyBytes_GET_SIZE(self.outgoing_data)

    cdef outgoing_bio_consume(self, Py_ssize_t nbytes):
        cdef Py_ssize_t pending = PyBytes_GET_SIZE(self.outgoing_data)
        if nbytes > pending:
            raise RuntimeError("outgoing BIO consume size exceeds pending data")
        if nbytes == pending:
            self.outgoing_data = b""
        else:
            self.outgoing_data = self.outgoing_data[nbytes:]
