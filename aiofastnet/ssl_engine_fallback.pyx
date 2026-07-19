import ssl
import collections

from cpython.memoryview cimport PyMemoryView_FromMemory
from cpython.buffer cimport PyBUF_READ, PyBUF_WRITE
from cpython.bytearray cimport PyByteArray_AS_STRING
from cpython.bytes cimport PyBytes_AS_STRING, PyBytes_GET_SIZE

from .ssl_engine cimport SSLEngine, SSLError, ssl_error_name
from .utils cimport unlikely

import logging

cdef:
    _logger = logging.getLogger('aiofastnet.ssl')
    _zero = 0
    _ssl_want_read_exc = ssl.SSLWantReadError
    _ssl_want_write_exc = ssl.SSLWantWriteError
    _ssl_zero_return_exc = ssl.SSLZeroReturnError
    _ssl_syscall_exc = ssl.SSLSyscallError
    _ssl_error_exc = ssl.SSLError


cdef class SSLEngineFallback(SSLEngine):
    cdef:
        object _incoming
        bytearray _incoming_buf

        object _outgoing
        object _outgoing_chunks
        Py_ssize_t _outgoing_offset
        Py_ssize_t _outgoing_size
        Py_ssize_t _write_max_size_hint

        object ssl_object

    def __init__(self, ssl_context, bint server_side, str server_hostname,
                 Py_ssize_t read_buffer_size, Py_ssize_t write_max_size_hint,
                 sock=None):
        SSLEngine.__init__(self, ssl_context, server_side, server_hostname)

        self._incoming = ssl.MemoryBIO()
        self._outgoing = ssl.MemoryBIO()
        self._incoming_buf = bytearray(read_buffer_size)
        self._outgoing_chunks = collections.deque()
        self._outgoing_offset = 0
        self._outgoing_size = 0
        self._write_max_size_hint = write_max_size_hint

        self.ssl_object = ssl_context.wrap_bio(
            self._incoming,
            self._outgoing,
            server_side=server_side,
            server_hostname=server_hostname,
        )

    cdef inline SSLError _translate_ssl_error(self, exc) except SSLError.PYTHON_EXC:
        if isinstance(exc, _ssl_want_read_exc):
            return SSLError.SSL_ERROR_WANT_READ
        elif isinstance(exc, _ssl_want_write_exc):
            return SSLError.SSL_ERROR_WANT_WRITE
        elif isinstance(exc, _ssl_zero_return_exc):
            return SSLError.SSL_ERROR_ZERO_RETURN
        elif isinstance(exc, _ssl_syscall_exc):
            raise ConnectionResetError() from exc
        else:
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
        except _ssl_error_exc as exc:
            ssl_error = self._translate_ssl_error(exc)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSLObject.do_handshake(), %s", conn, ssl_error_name(ssl_error))
            if ssl_error in (SSLError.SSL_ERROR_WANT_READ, SSLError.SSL_ERROR_WANT_WRITE):
                return ssl_error
            raise
        finally:
            self._drain_outgoing_bio_to_queue()

        if unlikely(self._is_debug):
            _logger.debug("%r: SSLObject.do_handshake() complete", conn)
        return SSLError.SSL_ERROR_NONE

    cdef SSLError shutdown(self, conn) except SSLError.PYTHON_EXC:
        try:
            self.ssl_object.unwrap()
        except _ssl_error_exc as exc:
            ssl_error = self._translate_ssl_error(exc)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSLObject.unwrap(), %s", conn, ssl_error_name(ssl_error))
            if ssl_error in (SSLError.SSL_ERROR_WANT_READ, SSLError.SSL_ERROR_WANT_WRITE):
                return ssl_error
            if ssl_error == SSLError.SSL_ERROR_ZERO_RETURN:
                return SSLError.SSL_ERROR_NONE
            raise
        finally:
            self._drain_outgoing_bio_to_queue()

        if unlikely(self._is_debug):
            _logger.debug("%r: SSLObject.unwrap() complete", conn)
        return SSLError.SSL_ERROR_NONE

    cdef SSLError read(self, conn, char *buf, Py_ssize_t buf_len, Py_ssize_t* total_bytes_read) except SSLError.PYTHON_EXC:
        cdef:
            Py_ssize_t bytes_read = 0
            SSLError ssl_error

        total_bytes_read[0] = 0
        try:
            while buf_len != 0:
                if <Py_ssize_t>self.ssl_object.pending() == 0 and <Py_ssize_t>self._incoming.pending == 0:
                    return SSLError.SSL_ERROR_WANT_READ

                try:
                    # This reads no more than TLS record size(16 Kb) per call, even if bigger buffer is passed
                    # Limitation of the underlying SSL_read call.
                    # It is ok to pass 0 as the first argument, ssl_object.read ignores it when buffer is provided
                    # explicitly
                    bytes_read = self.ssl_object.read(_zero, PyMemoryView_FromMemory(buf, buf_len, PyBUF_WRITE))
                    if unlikely(self._is_debug):
                        _logger.debug("%r: SSLObject.read(0, buffer(sz=%d))=%d", conn, buf_len, bytes_read)
                except _ssl_error_exc as exc:
                    ssl_error = self._translate_ssl_error(exc)
                    if unlikely(self._is_debug):
                        _logger.debug("%r: SSLObject.read(0, buffer(sz=%d)), %s",
                                      conn, buf_len, ssl_error_name(ssl_error))
                    if ssl_error in (
                        SSLError.SSL_ERROR_WANT_READ,
                        SSLError.SSL_ERROR_WANT_WRITE,
                        SSLError.SSL_ERROR_ZERO_RETURN,
                    ):
                        return ssl_error
                    raise

                if bytes_read == 0:
                    return SSLError.SSL_ERROR_ZERO_RETURN

                total_bytes_read[0] += bytes_read
                buf += bytes_read
                buf_len -= bytes_read
        finally:
            self._drain_outgoing_bio_to_queue()

        return SSLError.SSL_ERROR_NONE

    cdef SSLError write(self, conn, char *data_ptr, Py_ssize_t data_len, Py_ssize_t* bytes_written) except SSLError.PYTHON_EXC:
        bytes_written[0] = 0
        if unlikely(data_len == 0):
            return SSLError.SSL_ERROR_NONE

        cdef Py_ssize_t available_for_writing = max(self._write_max_size_hint - self._outgoing_size, 0)
        if unlikely(available_for_writing == 0):
            return SSLError.SSL_ERROR_WANT_WRITE

        # Always let to write the whole TLS record to prevent records of non-optimal size.
        # Round up to the nearest 16 kb boundary
        # 16384 - max TLS record payload size.
        # Introducing a constant here for 16384 make cython generate unnecessary checks
        available_for_writing = ((available_for_writing + 16384 - 1) // 16384) * 16384

        # We need to limit writing size, because ssl.SSLObject.write just writes until all data is written,
        # and memory bio grows without limits

        cdef Py_ssize_t bytes_to_write = min(data_len, available_for_writing)
        data = PyMemoryView_FromMemory(data_ptr, bytes_to_write, PyBUF_READ)

        cdef:
            Py_ssize_t last_bytes_written
            SSLError ssl_error

        try:
            # Contrary to ssl_object.read, ssl_object.write writes everything at once even if data is bigger than
            # TLS record size (16 KB)
            last_bytes_written = self.ssl_object.write(data)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSLObject.write(data_len=%d)=%d", conn, bytes_to_write, last_bytes_written)
            bytes_written[0] += last_bytes_written
        except _ssl_error_exc as exc:
            ssl_error = self._translate_ssl_error(exc)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSLObject.write(data_len=%d), %s", conn, data_len, ssl_error_name(ssl_error))

            if ssl_error in (SSLError.SSL_ERROR_WANT_READ, SSLError.SSL_ERROR_WANT_WRITE):
                return ssl_error

            raise
        finally:
            self._drain_outgoing_bio_to_queue()

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
        self._incoming.write(PyMemoryView_FromMemory(PyByteArray_AS_STRING(self._incoming_buf), nbytes, PyBUF_READ))

    cdef allow_renegotiation(self):
        pass

    cdef int renegotiate(self) except -1:
        raise NotImplementedError("stdlib ssl.SSLObject does not expose renegotiation")

    cdef outgoing_bio_reset(self):
        self._outgoing_chunks.clear()
        self._outgoing_offset = 0
        self._outgoing_size = 0
        while self._outgoing.pending:
            self._outgoing.read()

    cdef Py_ssize_t outgoing_bio_pending(self) except -1:
        return self._outgoing_size

    cdef Py_ssize_t outgoing_bio_get_data(self, char** pp) except -1:
        cdef bytes chunk

        if self._outgoing_size == 0:
            pp[0] = NULL
            return 0

        chunk = <bytes>self._outgoing_chunks[0]
        pp[0] = PyBytes_AS_STRING(chunk) + self._outgoing_offset
        return PyBytes_GET_SIZE(chunk) - self._outgoing_offset

    cdef outgoing_bio_consume(self, Py_ssize_t nbytes):
        cdef:
            bytes chunk
            Py_ssize_t chunk_size
            Py_ssize_t remaining

        if nbytes > self._outgoing_size:
            raise RuntimeError("outgoing BIO consume size exceeds pending data")

        self._outgoing_size -= nbytes
        while nbytes != 0:
            chunk = self._outgoing_chunks[0]
            chunk_size = PyBytes_GET_SIZE(chunk)
            remaining = chunk_size - self._outgoing_offset

            if nbytes < remaining:
                self._outgoing_offset += nbytes
                return

            nbytes -= remaining
            self._outgoing_chunks.popleft()
            self._outgoing_offset = 0

    cdef inline _drain_outgoing_bio_to_queue(self):
        cdef:
            bytes chunk
            Py_ssize_t chunk_size

        if self._outgoing.pending:
            chunk = self._outgoing.read()
            chunk_size = PyBytes_GET_SIZE(chunk)
            if chunk_size != 0:
                self._outgoing_chunks.append(chunk)
                self._outgoing_size += chunk_size
