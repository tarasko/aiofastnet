import ssl

from cpython.memoryview cimport PyMemoryView_FromMemory
from cpython.buffer cimport PyBUF_READ
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
        object _incoming
        bytearray _incoming_buf

        object _outgoing
        bytes _outgoing_data
        Py_ssize_t _write_max_size

        object ssl_object

    def __init__(self, ssl_context, bint server_side, str server_hostname,
                 Py_ssize_t read_buffer_size, Py_ssize_t write_max_size,
                 sock=None):
        SSLEngine.__init__(self, ssl_context, server_side, server_hostname)

        self._incoming = ssl.MemoryBIO()
        self._outgoing = ssl.MemoryBIO()
        self._incoming_buf = bytearray(read_buffer_size)
        self._outgoing_data = b""
        self._write_max_size = 64*1024

        self.ssl_object = ssl_context.wrap_bio(
            self._incoming,
            self._outgoing,
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
            raise

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
            raise

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
            if self.ssl_object.pending() == 0 and self._incoming.pending == 0:
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
                raise

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
        bytes_written[0] = 0
        if unlikely(data_len == 0):
            return SSLError.SSL_ERROR_NONE

        cdef Py_ssize_t available_for_writing = max(self._write_max_size - <Py_ssize_t>self._outgoing.pending, 0)
        if unlikely(available_for_writing == 0):
            return SSLError.SSL_ERROR_WANT_WRITE

        # Always let to write the whole TLS record to prevent records of non-optimal size.
        available_for_writing = max(16*1024, available_for_writing)

        # We need to limit writing size, because ssl.SSLObject.write just writes until all data is written,
        # and memory bio grows without limits

        cdef Py_ssize_t bytes_to_write = min(data_len, available_for_writing)
        data = PyMemoryView_FromMemory(data_ptr, bytes_to_write, PyBUF_READ)

        cdef:
            Py_ssize_t last_bytes_written
            SSLError ssl_error

        try:
            last_bytes_written = self.ssl_object.write(data)
            bytes_written[0] += last_bytes_written
            if unlikely(self._is_debug):
                _logger.debug("%r: SSLObject.write(data_len=%d)=%d", conn, bytes_to_write, last_bytes_written)
        except ssl.SSLError as exc:
            ssl_error = self._translate_ssl_error(exc)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSLObject.write(data_len=%d), %s", conn, data_len, ssl_error_name(ssl_error))

            if ssl_error in (SSLError.SSL_ERROR_WANT_READ, SSLError.SSL_ERROR_WANT_WRITE):
                return ssl_error

            raise

        if last_bytes_written < data_len:
            return SSLError.SSL_ERROR_WANT_WRITE

        return SSLError.SSL_ERROR_NONE

    cdef SSLError sendfile(self, conn, int fd, Py_ssize_t offset, Py_ssize_t count, Py_ssize_t* bytes_written) except SSLError.PYTHON_EXC:
        bytes_written[0] = 0
        raise NotImplementedError()

    cdef incoming_bio_get_write_buf(self, char **pp, Py_ssize_t *space):
        pp[0] = PyByteArray_AS_STRING(self._incoming_buf)
        space[0] = len(self._incoming_buf)

    cdef incoming_bio_produce(self, Py_ssize_t nbytes):
        if nbytes == 0:
            return
        self._incoming.write(PyBytes_FromStringAndSize(PyByteArray_AS_STRING(self._incoming_buf), nbytes))

    cdef int sendfile_available(self) except -1:
        return 0

    cdef allow_renegotiation(self):
        pass

    cdef int renegotiate(self) except -1:
        raise NotImplementedError("stdlib ssl.SSLObject does not expose renegotiation")

    cdef int outgoing_bio_reset(self) except -1:
        self._outgoing_data = b""
        while self._outgoing.pending:
            self._outgoing.read()
        return 1

    cdef Py_ssize_t outgoing_bio_pending(self) except -1:
        return PyBytes_GET_SIZE(self._outgoing_data) + self._outgoing.pending

    cdef Py_ssize_t outgoing_bio_get_data(self, char** pp) except -1:
        if self._outgoing.pending:
            if PyBytes_GET_SIZE(self._outgoing_data) == 0:
                self._outgoing_data = self._outgoing.read()
            else:
                self._outgoing_data += self._outgoing.read()

        pp[0] = PyBytes_AS_STRING(self._outgoing_data)
        return PyBytes_GET_SIZE(self._outgoing_data)

    cdef outgoing_bio_consume(self, Py_ssize_t nbytes):
        cdef Py_ssize_t pending = PyBytes_GET_SIZE(self._outgoing_data)
        if nbytes > pending:
            raise RuntimeError("outgoing BIO consume size exceeds pending data")
        if nbytes == pending:
            self._outgoing_data = b""
        else:
            self._outgoing_data = self._outgoing_data[nbytes:]
