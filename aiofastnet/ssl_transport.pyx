import asyncio
import os
import ssl
import warnings
from asyncio.trsock import TransportSocket
from logging import getLogger

from cpython.bytearray cimport PyByteArray_AS_STRING, PyByteArray_GET_SIZE
from cpython.bytes cimport PyBytes_FromStringAndSize
from cpython.object cimport PyObject
from cpython.buffer cimport PyBUF_WRITE
from cpython.memoryview cimport PyMemoryView_FromMemory
from cpython.pythread cimport PyThread_get_thread_ident
from posix.types cimport off_t

from . import constants
from .utils cimport (
    SSLProtocolState,
    AppProtocolState,
    aiofn_unpack_buffer,
    aiofn_validate_buffer,
    aiofn_maybe_copy_buffer,
    aiofn_maybe_copy_buffer_tail,
    aiofn_recv,
    aiofn_send,
    aiofn_allocate_bytes,
    aiofn_finalize_bytes,
    aiofn_set_nodelay,
    unlikely
)
from .ssl_object cimport (SSLObject, SSLError, ssl_error_name)
from .transport cimport Transport, Protocol, WriteWatermarks
from .transport import aiofn_is_buffered_protocol


cdef object _logger = getLogger('aiofastnet.tls')


def _create_transport_context(server_side, server_hostname):
    sslcontext = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    if not server_hostname:
        sslcontext.check_hostname = False
    return sslcontext


cdef class SendFileRequest:
    cdef:
        int fd
        off_t offset
        Py_ssize_t count
        object waiter

    def __len__(self):
        return self.count


cdef SendFileRequest _make_send_file_request(file, offset, count):
    cdef:
        int c_fd = file.fileno()
        off_t c_offset = offset

    if c_offset < 0:
        raise ValueError("offset must be non-negative")

    cdef:
        Py_ssize_t size = os.fstat(file.fileno()).st_size
        Py_ssize_t available = max(0, size - offset)
        size_t c_count

    if count is None:
        c_count = available
    else:
        c_count = min(<Py_ssize_t> count, available)

    cdef SendFileRequest self = <SendFileRequest>SendFileRequest.__new__(SendFileRequest)
    self.fd = c_fd
    self.offset = c_offset
    self.count = c_count
    self.waiter = asyncio.get_running_loop().create_future()
    return self


cdef class SSLTransportBase(Transport):
    cdef:
        object __weakref__
        object _loop
        unsigned long _thread_id
        bint _is_debug

        object _app_protocol
        bint _app_protocol_is_buffered
        bint _app_protocol_aiofn
        bint _app_protocol_connected
        dict _extra

        object _server

        bint _read_paused               # Is reading paused by the user
        bint _connection_lost_scheduled # Has connection_lost() already been scheduled?
        size_t _closed_write_count

        SSLObject _ssl_object
        list _write_backlog
        Py_ssize_t _write_backlog_size

        SSLProtocolState _state
        AppProtocolState _app_state
        object _ssl_handshake_complete_waiter
        object _ssl_handshake_timeout
        object _ssl_shutdown_timeout

        object _handshake_timeout_handle
        object _shutdown_timeout_handle
        object _ssl_layer_num

        bint _server_side
        str _server_hostname

    # Implement the following in the derived class

    cpdef is_reading(self):
        raise NotImplementedError()

    cpdef pause_reading(self):
        raise NotImplementedError()

    cpdef resume_reading(self):
        raise NotImplementedError()

    cpdef tuple get_write_buffer_limits(self):
        raise NotImplementedError()

    cpdef set_write_buffer_limits(self, high=None, low=None):
        raise NotImplementedError()

    cpdef get_write_buffer_size(self):
        raise NotImplementedError()

    cdef _get_sock_fd(self):
        """Return socket fd object, used only for __repr__"""
        raise NotImplementedError()

    cdef _is_closed(self):
        raise NotImplementedError()

    cdef _check_sendfile_supported(self):
        raise NotImplementedError()

    cdef bint _try_sendfile(self, SendFileRequest req) except -1:
        """
        Immediately try sendfile. Update req.offset and count if succeed.
        In case of error complete req.waiter with exception. Re-raise exception.
        Return True if the whole file has been sent. False - if sendfile has sent
        only part of the file and we need to wait until socket is ready for writing
        again.
        """
        raise NotImplementedError()

    cdef bint _flush_outgoing_bio(self) except -1:
        """
        Writes raw data to socket or underlying transport from outgoing BIO. 
        Returns True if write operations can continue (outgoing BIO can accept more data).
        True is also returned if memory bio is not used, is such case _flush_outgoing_bio is no-op. 
        """
        raise NotImplementedError()

    cdef bint _should_retry_after_want_write(self) except -1:
        """
        Return True if we should retry the last operation after we got 
        SSL_ERROR_WANT_WRITE. Tries to flush outgoing data before returning.
        """
        raise NotImplementedError()

    cdef bint _should_flush_outgoing_after_read(self) except -1:
        raise NotImplementedError()

    cdef _maybe_pause_protocol(self):
        raise NotImplementedError()

    cdef _maybe_resume_protocol(self):
        raise NotImplementedError()

    cpdef _force_close(self, exc):
        raise NotImplementedError()

    def __init__(self, loop, app_protocol, sslcontext,
                 waiter=None,
                 server_side=False,
                 server_hostname=None,
                 ssl_handshake_timeout=None,
                 ssl_shutdown_timeout=None,
                 ssl_incoming_bio_size=None,
                 ssl_outgoing_bio_size=None,
                 server=None,
                 sock=None):

        if ssl_handshake_timeout is None:
            ssl_handshake_timeout = constants.SSL_HANDSHAKE_TIMEOUT
        elif ssl_handshake_timeout <= 0:
            raise ValueError(
                f"ssl_handshake_timeout should be a positive number, got {ssl_handshake_timeout}")

        if ssl_shutdown_timeout is None:
            ssl_shutdown_timeout = constants.SSL_SHUTDOWN_TIMEOUT
        elif ssl_shutdown_timeout <= 0:
            raise ValueError(
                f"ssl_shutdown_timeout should be a positive number, got {ssl_shutdown_timeout}")

        if ssl_incoming_bio_size is None:
            ssl_incoming_bio_size = constants.SSL_INCOMING_BIO_SIZE
        else:
            ssl_incoming_bio_size = max(ssl_incoming_bio_size, 16*1024 + 256)

        if ssl_outgoing_bio_size is None:
            ssl_outgoing_bio_size = constants.SSL_OUTGOING_BIO_SIZE
        else:
            ssl_outgoing_bio_size = max(ssl_outgoing_bio_size, 16*1024 + 256)

        if server_side and not sslcontext:
            raise ValueError('Server side SSL needs a valid SSLContext')

        if not sslcontext or sslcontext is True:
            sslcontext = _create_transport_context(server_side, server_hostname)

        self._loop = loop
        self._thread_id = PyThread_get_thread_ident()
        self._is_debug = loop.get_debug()

        self._server = server

        self._read_paused = False
        self._connection_lost_scheduled = False
        self._closed_write_count = 0

        self._write_backlog = []
        self._write_backlog_size = 0
        self._ssl_handshake_complete_waiter = waiter
        self._ssl_handshake_timeout = ssl_handshake_timeout
        self._ssl_shutdown_timeout = ssl_shutdown_timeout
        self._handshake_timeout_handle = None
        self._shutdown_timeout_handle = None
        self._ssl_layer_num = 0
        self._server_side = server_side
        self._server_hostname = None if server_side else server_hostname
        self._state = SSLProtocolState.UNWRAPPED
        self._app_state = AppProtocolState.STATE_INIT

        self._set_protocol(app_protocol)

        self._ssl_object = SSLObject(
            sslcontext,
            server_side,
            self._server_hostname,
            ssl_incoming_bio_size,
            ssl_outgoing_bio_size,
            sock=sock
        )

        if self._server is not None:
            self._server._attach(self)

    def __repr__(self):
        sock_fd = self._get_sock_fd()
        if sock_fd is not None:
            info = [f"fd={sock_fd}"]
        else:
            info = ["fd=n/a"]

        info.append(self.__class__.__name__)
        if self._ssl_object.server_side:
            info.append("server")
        else:
            info.append("client")

        info.append(f"#{self._ssl_layer_num}")

        if self._is_closed() is None:
            info.append('closed')
        elif self.is_closing():
            info.append('closing')

        wbuf_size = self.get_local_write_buffer_size()
        info.append(f'wbuf_size={wbuf_size}')
        return '[{}]'.format(' '.join(info))

    cdef inline _set_protocol(self, protocol):
        self._app_protocol = protocol
        self._app_protocol_is_buffered = aiofn_is_buffered_protocol(protocol)
        self._app_protocol_aiofn = isinstance(protocol, Protocol)
        self._app_protocol_connected = True

    cpdef get_extra_info(self, name, default=None):
        self._check_thread("get_extra_info")
        if name == 'ssl_object':
            return self._ssl_object
        elif name == 'ssl_protocol':
            return self
        elif name == 'ssl_layer_num':
            return self._ssl_layer_num
        return self._extra.get(name, default)

    cpdef set_protocol(self, protocol):
        self._check_thread("set_protocol")
        self._set_protocol(protocol)

    cpdef get_protocol(self):
        self._check_thread("get_protocol")
        return self._app_protocol

    cpdef is_closing(self):
        self._check_thread("is_closing")
        return self._connection_lost_scheduled or self._state in (
            SSLProtocolState.FLUSHING,
            SSLProtocolState.SHUTDOWN,
            SSLProtocolState.UNWRAPPED
        )

    cpdef close(self):
        self._check_thread("close")
        if unlikely(self._is_debug):
            _logger.debug("%r: user called close()", self)
        self._start_shutdown()

    cpdef abort(self):
        self._check_thread("abort")
        if unlikely(self._is_debug):
            _logger.debug("%r: user called abort()", self)
        self._abort(None)

    def write_eof(self):
        self._check_thread("write_eof")
        raise NotImplementedError()

    def can_write_eof(self):
        return False

    # Underlying transport use this to take into account upstream write buffer
    # size when deciding to report pause_writing()/resume_writing()
    cpdef Py_ssize_t get_local_write_buffer_size(self) except -1:
        cdef Py_ssize_t total = 0
        for data in self._write_backlog:
            total += len(data)

        if self._app_protocol_aiofn and self._app_protocol is not None:
            total += (<Protocol> self._app_protocol).get_local_write_buffer_size()

        if self._ssl_object is not None and self._ssl_object.outgoing != NULL:
            total += self._ssl_object.outgoing_bio_pending()

        return total

    cdef inline _check_thread(self, meth):
        cdef unsigned long curr_thread_id = PyThread_get_thread_ident()
        if self._thread_id != curr_thread_id:
            raise RuntimeError(
                f"SSLTransport.{meth} called from a wrong thread: "
                f"transport thread id={self._thread_id}, "
                f"curr thread_id={curr_thread_id}"
            )

    cdef inline _set_state(self, SSLProtocolState new_state):
        cdef bint allowed = False

        if new_state == SSLProtocolState.UNWRAPPED:
            allowed = True
        elif self._state == SSLProtocolState.UNWRAPPED and new_state == SSLProtocolState.DO_HANDSHAKE:
            allowed = True
        elif self._state == SSLProtocolState.DO_HANDSHAKE and new_state == SSLProtocolState.WRAPPED:
            allowed = True
        elif self._state == SSLProtocolState.WRAPPED and new_state in (SSLProtocolState.FLUSHING, SSLProtocolState.SHUTDOWN, SSLProtocolState.DO_HANDSHAKE):
            allowed = True
        elif self._state == SSLProtocolState.FLUSHING and new_state == SSLProtocolState.SHUTDOWN:
            allowed = True

        if allowed:
            self._state = new_state
        else:
            raise RuntimeError(f'cannot switch state from {self._state} to {new_state}')

    cdef inline _start_handshake(self):
        self._set_state(SSLProtocolState.DO_HANDSHAKE)
        self._handshake_timeout_handle = self._loop.call_later(
            self._ssl_handshake_timeout, self._check_handshake_timeout)
        self._incoming_bio_updated()

    cdef inline _check_handshake_timeout(self):
        if self._state == SSLProtocolState.DO_HANDSHAKE:
            self._fatal_error(ConnectionAbortedError(
                f"SSL handshake is taking longer than {self._ssl_handshake_timeout} seconds: aborting the connection"))

    cdef _retry_ssl_read(self):
        if unlikely(self._is_debug):
            _logger.debug("%r: _retry_ssl_read event", self)

        if self._connection_lost_scheduled:
            return

        try:
            self._incoming_bio_updated()
        except BaseException as exc:
            self._fatal_error(exc, "Error occurred during read")

    cdef inline _do_handshake(self):
        cdef:
            int rc
            int ssl_error

        while True:
            rc = self._ssl_object.do_handshake()
            if rc == 1:
                if unlikely(self._is_debug):
                    _logger.debug("%r: SSL_do_handshake() = %d", self, rc)
                self._on_handshake_complete(None)
                self._flush_outgoing_bio()
                return

            ssl_error = self._ssl_object.get_error(rc)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSL_do_handshake() = %d, %s",
                              self, rc, ssl_error_name(ssl_error))

            if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                if self._should_retry_after_want_write():
                    continue
                else:
                    return

            if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                self._flush_outgoing_bio()
                return

            exc = self._ssl_object.make_exc_from_ssl_error(
                "ssl handshake failed", ssl_error)
            self._on_handshake_complete(exc)
            return

    cdef inline _on_handshake_complete(self, handshake_exc):
        if self._handshake_timeout_handle is not None:
            self._handshake_timeout_handle.cancel()
            self._handshake_timeout_handle = None

        if handshake_exc is not None:
            self._set_state(SSLProtocolState.UNWRAPPED)
            self._fatal_error(handshake_exc, 'SSL handshake failed')
            self._wakeup_waiter(handshake_exc)
            return

        self._set_state(SSLProtocolState.WRAPPED)

        _logger.debug("%r: %s", self, ssl.OPENSSL_VERSION)
        _logger.debug("%r: enable_ktls()=%x", self, self._ssl_object.enable_ktls())

        _logger.debug("%r: cipher %s", self, self._ssl_object.cipher())

        _logger.debug("%r: BIO_get_ktls_send(wbio)=%d",
                      self, self._ssl_object.ktls_send_enabled())

        _logger.debug("%r: BIO_get_ktls_recv(rbio)=%d",
                      self, self._ssl_object.ktls_recv_enabled())

        self._extra.update(
            peercert=self._ssl_object.getpeercert(),
            cipher=self._ssl_object.cipher(),
            compression=self._ssl_object.compression()
        )
        self._wakeup_waiter()
        if self._app_state == AppProtocolState.STATE_INIT:
            self._app_state = AppProtocolState.STATE_CON_MADE
            try:
                self._app_protocol.connection_made(self)
            except (KeyboardInterrupt, SystemExit):
                raise
            except Exception as exc:
                self._fatal_error_no_close(exc, "user connection_made raised an exception")
        self._loop.call_soon(self._retry_ssl_read)

    cpdef _do_read(self):
        if self._read_paused:
            return

        if self._app_protocol_is_buffered:
            self._do_read__buffered()
        else:
            self._do_read__copied()

        if self._should_flush_outgoing_after_read():
            # In case of renegotiation SSL_write may have failed earlier with SSL_WANT_READ_ERROR
            # The data is then pushed to _write_backlog, but no _write_ready is being waiter for,
            # because the non-blocking socket can still send more data without EGAIN
            self._flush_outgoing_bio()
            if self._write_backlog_size:
                self._flush_write_backlog()

    cdef inline _do_read__buffered(self):
        cdef:
            char* buf_ptr
            Py_ssize_t buf_len
            int last_bytes_read = 0
            Py_ssize_t total_bytes_read = 0
            int last_error = 0

        while True:
            if self._app_protocol_aiofn:
                app_buffer = (<Protocol>self._app_protocol).get_buffer_c(-1, &buf_ptr, &buf_len)
            else:
                app_buffer = self._app_protocol.get_buffer(-1)
                aiofn_unpack_buffer(app_buffer, &buf_ptr, &buf_len)

            if buf_len == 0:
                raise RuntimeError('get_buffer() returned an empty buffer')

            while buf_len > 0:
                last_bytes_read = self._ssl_object.read(buf_ptr, buf_len)
                if last_bytes_read <= 0:
                    last_error = self._ssl_object.get_error(last_bytes_read)
                    if unlikely(self._is_debug):
                        _logger.debug("%r: SSL_read(buf_len=%d)=%d, %s",
                                      self, buf_len, last_bytes_read,
                                      ssl_error_name(last_error))
                    break

                if unlikely(self._is_debug):
                    _logger.debug("%r: SSL_read(buf_len=%d)=%d",
                                  self, buf_len, last_bytes_read)

                buf_ptr += last_bytes_read
                buf_len -= last_bytes_read
                total_bytes_read += last_bytes_read

            if total_bytes_read > 0:
                if self._app_protocol_aiofn:
                    (<Protocol>self._app_protocol).buffer_updated(total_bytes_read)
                else:
                    self._app_protocol.buffer_updated(total_bytes_read)
                total_bytes_read = 0

            if buf_len == 0:
                if not self._read_paused:
                    continue
                else:
                    return

            if not self._should_retry_read(last_error) or self._read_paused:
                return

    cdef inline Py_ssize_t _pending_estimate(self) noexcept:
        # TODO: Supposed to be overriden
        return 128*1024

    cdef inline _do_read__copied(self):
        cdef:
            int bytes_read
            list data = None
            char* bytes_buffer_ptr
            bytes first_chunk = None, curr_chunk
            Py_ssize_t bytes_estimated
            PyObject* bytes_obj
            int last_error

        while True:
            while True:
                bytes_estimated = self._pending_estimate()
                bytes_obj = aiofn_allocate_bytes(bytes_estimated, &bytes_buffer_ptr)
                bytes_read = self._ssl_object.read(bytes_buffer_ptr, bytes_estimated)

                if bytes_read <= 0:
                    last_error = self._ssl_object.get_error(bytes_read)
                    if unlikely(self._is_debug):
                        _logger.debug("%r: SSL_read(buf_len=%d)=%d, %s",
                                      self, bytes_estimated, bytes_read,
                                      ssl_error_name(last_error))
                    curr_chunk = aiofn_finalize_bytes(bytes_obj, 0)
                    break

                if unlikely(self._is_debug):
                    _logger.debug("%r: SSL_read(buf_len=%d)=%d",
                                  self, bytes_estimated, bytes_read)
                curr_chunk = aiofn_finalize_bytes(bytes_obj, bytes_read)

                if first_chunk is None:
                    first_chunk = curr_chunk
                elif data is None:
                    data = [first_chunk, curr_chunk]
                else:
                    data.append(curr_chunk)

            user_data = None
            if data is not None:
                user_data = b''.join(data)
            elif first_chunk is not None:
                user_data = first_chunk

            if user_data is not None:
                if self._app_protocol_aiofn:
                    (<Protocol>self._app_protocol).data_received(user_data)
                else:
                    self._app_protocol.data_received(user_data)

            if not self._should_retry_read(last_error) or self._read_paused:
                return

    cdef inline _should_retry_read(self, int last_error):
        if last_error == SSLError.SSL_ERROR_WANT_READ:
            return False

        if last_error == SSLError.SSL_ERROR_WANT_WRITE:
            return self._should_retry_after_want_write()

        if last_error == SSLError.SSL_ERROR_ZERO_RETURN:
            self._call_eof_received()
            self._start_shutdown()
            return False

        # this may happen when socket BIO is used for reading and remote peer has
        # abruptly closed connection.
        # In such case OpenSSL reports SSL_ERROR_SYSCALL or a generic error
        # SSLError:
        #   library: 'SSL ROUTINES'
        #   reason: 'UNEXPECTED_EOF_WHILE_READING'
        #
        # To be consistent with TLS with memory BIO/TCP use,
        # we report connection_lost with ConnectionResetError()
        if last_error == SSLError.SSL_ERROR_SYSCALL:
            raise ConnectionResetError()

        exc = self._ssl_object.make_exc_from_ssl_error("SSL_read failed", last_error)
        if exc.reason == 'UNEXPECTED_EOF_WHILE_READING':
            raise ConnectionResetError() from exc
        else:
            raise exc

    cdef inline _start_shutdown(self):
        if self._state in (SSLProtocolState.FLUSHING, SSLProtocolState.SHUTDOWN, SSLProtocolState.UNWRAPPED):
            return

        if self._state == SSLProtocolState.DO_HANDSHAKE:
            self._abort(None)
            return

        self._set_state(SSLProtocolState.FLUSHING)
        self._shutdown_timeout_handle = self._loop.call_later(
            self._ssl_shutdown_timeout, self._check_shutdown_timeout)
        self._do_flush()

    cdef inline _check_shutdown_timeout(self):
        if self._state in (SSLProtocolState.FLUSHING, SSLProtocolState.SHUTDOWN):
            self._abort(asyncio.TimeoutError('SSL shutdown timed out'))

    cdef inline _do_read_into_void(self):
        cdef:
            bytearray buffer = bytearray(17 * 1024)
            int bytes_read
            int ssl_error

        while True:
            while True:
                bytes_read = self._ssl_object.read(
                    PyByteArray_AS_STRING(buffer),
                    PyByteArray_GET_SIZE(buffer))
                if bytes_read <= 0:
                    break

                if unlikely(self._is_debug):
                    _logger.debug("%r: SSL_read(buf_len=%d)=%d",
                                  self, PyByteArray_GET_SIZE(buffer), bytes_read)

            ssl_error = self._ssl_object.get_error(bytes_read)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSL_read(buf_len=%d, ...)=%d, %s",
                              self, PyByteArray_GET_SIZE(buffer),
                              bytes_read, ssl_error_name(ssl_error))

            if not self._should_retry_read(ssl_error):
                return

    cdef inline _do_flush(self):
        try:
            self._do_read_into_void()
        except BaseException as ex:
            self._on_shutdown_complete(ex)
        else:
            if self._write_backlog_size:
                self._flush_write_backlog()

            if self.get_local_write_buffer_size() == 0:
                self._set_state(SSLProtocolState.SHUTDOWN)
                self._do_shutdown()

    cdef inline _do_shutdown(self):
        cdef:
            int rc
            int ssl_error

        try:
            self._do_read_into_void()

            while True:
                rc = self._ssl_object.shutdown()

                # From openssl docs
                # Unlike most other function, returning 0 does not indicate an
                # error. SSL_get_error(3) should not get called, it may
                # misleadingly indicate an error even though no error occurred.
                # 0 - means we have successfully sent close_notify, but we still
                # expect peer to reply.

                if rc in (1, 0):
                    if unlikely(self._is_debug):
                        _logger.debug("%r: SSL_shutdown()=%d", self, rc)

                    self._flush_outgoing_bio()

                    if rc == 1:
                        self._on_shutdown_complete(None)
                    return

                ssl_error = self._ssl_object.get_error(rc)
                if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                    if self._should_retry_after_want_write():
                        continue
                    else:
                        return

                if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                    return

                raise self._ssl_object.make_exc_from_ssl_error(
                    "SSL_shutdown failed", ssl_error)
        except BaseException as exc:
            self._on_shutdown_complete(exc)

    cdef inline _on_shutdown_complete(self, shutdown_exc):
        if self._shutdown_timeout_handle is not None:
            self._shutdown_timeout_handle.cancel()
            self._shutdown_timeout_handle = None
        if shutdown_exc:
            self._fatal_error(shutdown_exc, 'Error occurred during shutdown')
        else:
            self._force_close(None)

    cdef inline _wakeup_waiter(self, exc=None):
        if self._ssl_handshake_complete_waiter is None:
            return
        if not self._ssl_handshake_complete_waiter.done():
            if exc is not None:
                self._ssl_handshake_complete_waiter.set_exception(exc)
            else:
                self._ssl_handshake_complete_waiter.set_result(None)

    cdef inline _abort(self, exc):
        if self._state != SSLProtocolState.UNWRAPPED:
            self._set_state(SSLProtocolState.UNWRAPPED)
        self._force_close(exc)

    cdef inline _process_eof(self):
        if unlikely(self._is_debug):
            _logger.debug("%r: received EOF", self)

        if self._state == SSLProtocolState.DO_HANDSHAKE:
            self._on_handshake_complete(ConnectionResetError)

        elif self._state == SSLProtocolState.WRAPPED or self._state == SSLProtocolState.FLUSHING:
            # We treat a low-level EOF as a critical situation similar to a
            # broken connection - just send whatever is in the buffer and
            # close. No application level eof_received() is called -
            # because we don't want the user to think that this is a
            # graceful shutdown triggered by SSL "close_notify".
            self._set_state(SSLProtocolState.SHUTDOWN)
            self._on_shutdown_complete(None)

        elif self._state == SSLProtocolState.SHUTDOWN:
            self._on_shutdown_complete(None)

    cdef _incoming_bio_updated(self):
        if self._state == SSLProtocolState.DO_HANDSHAKE:
            self._do_handshake()
        elif self._state == SSLProtocolState.WRAPPED:
            self._do_read()
        elif self._state == SSLProtocolState.FLUSHING:
            self._do_flush()
        elif self._state == SSLProtocolState.SHUTDOWN:
            self._do_shutdown()

    cdef inline _append_to_backlog(self, data, maybe_pause_protocol):
        if data:
            data = aiofn_maybe_copy_buffer(data)
            self._write_backlog.append(data)
            self._write_backlog_size += len(data)
            if maybe_pause_protocol:
                self._maybe_pause_protocol()

    async def sendfile(self, file, offset, count):
        self._check_thread("sendfile")
        self._check_sendfile_supported()

        if not self._is_protocol_ready():
            raise RuntimeError("Transport is closing")

        cdef SendFileRequest req = _make_send_file_request(file, offset, count)

        try:
            if not self._write_backlog:
                if self._try_sendfile(req):
                    return await req.waiter

            if unlikely(self._is_debug):
                _logger.debug("%r: enqueue SendFileRequest(offset=%d,count=%d)",
                              self, req.offset, req.count)

            self._write_backlog.append(req)
            self._write_backlog_size += req.count
            self._maybe_pause_protocol()

            return await req.waiter
        except BaseException as ex:
            self._fatal_error(ex, 'Fatal error on TLS transport')
            raise

    cdef write_c(self, char* data_ptr, Py_ssize_t data_len):
        if not self._is_protocol_ready() or data_len == 0:
            return

        try:
            if not self._write_backlog:
                tail = self._write_impl(None, data_ptr, data_len)
                self._flush_outgoing_bio()
                self._append_to_backlog(tail, True)
            else:
                self._append_to_backlog(PyBytes_FromStringAndSize(data_ptr, data_len), True)
        except BaseException as ex:
            self._fatal_error(ex, 'Fatal error on TLS transport')

    cpdef write(self, data):
        self._check_thread("write")
        aiofn_validate_buffer(data)
        self.write_nocheck(data)

    cpdef write_nocheck(self, data):
        if not self._is_protocol_ready():
            return

        cdef char* data_ptr
        cdef Py_ssize_t data_len

        try:
            if self._write_backlog_size:
                self._append_to_backlog(data, True)
                return

            aiofn_unpack_buffer(data, &data_ptr, &data_len)
            if data_len == 0:
                return

            tail = self._write_impl(data, data_ptr, data_len)
            self._flush_outgoing_bio()
            self._append_to_backlog(tail, True)
        except BaseException as ex:
            self._fatal_error(ex, 'Fatal error on TLS transport')

    cpdef writelines(self, list_of_data):
        self._check_thread("writelines")
        for data in list_of_data:
            aiofn_validate_buffer(data)
        self.writelines_nocheck(list_of_data)

    cpdef writelines_nocheck(self, list_of_data):
        if not self._is_protocol_ready():
            return

        if unlikely(self._write_backlog):
            for data in list_of_data:
                self._append_to_backlog(data, False)
            self._maybe_pause_protocol()
            return

        cdef:
            char* data_ptr
            Py_ssize_t data_len
            bint add_to_backlog = False
            Py_ssize_t data_cnt = len(list_of_data)
            Py_ssize_t idx

        try:
            for idx in range(len(list_of_data)):
                data = list_of_data[idx]
                if add_to_backlog:
                    self._append_to_backlog(data, False)
                    continue

                aiofn_unpack_buffer(data, &data_ptr, &data_len)
                if data_len == 0:
                    continue

                tail = self._write_impl(data, data_ptr, data_len)
                if tail is not None:
                    self._write_backlog.append(tail)
                    self._write_backlog_size += len(tail)
                    add_to_backlog = True

            self._flush_outgoing_bio()
            self._maybe_pause_protocol()
        except BaseException as ex:
            self._fatal_error(ex, 'Fatal error on TLS transport')

    cdef inline _flush_write_backlog(self):
        cdef:
            char* data_ptr
            Py_ssize_t data_len
            Py_ssize_t idx = 0
            Py_ssize_t items_completed = 0
            Py_ssize_t orig_req_size

        if self._state not in (SSLProtocolState.WRAPPED, SSLProtocolState.FLUSHING) or not self._write_backlog:
            return

        for idx in range(len(self._write_backlog)):
            data = self._write_backlog[idx]
            if isinstance(data, SendFileRequest):
                orig_req_size = (<SendFileRequest>data).count
                sendfile_completed = self._try_sendfile(data)
                self._write_backlog_size -= orig_req_size
                self._write_backlog_size += (<SendFileRequest>data).count
                if not sendfile_completed:
                    break
            else:
                aiofn_unpack_buffer(data, &data_ptr, &data_len)
                tail = self._write_impl(data, data_ptr, data_len)
                if tail is not None:
                    self._write_backlog_size -= len(data)
                    self._write_backlog[idx] = tail
                    self._write_backlog_size += len(tail)
                    break
            items_completed += 1
            self._write_backlog_size -= len(data)

        self._flush_outgoing_bio()
        if items_completed > 0:
            del self._write_backlog[:items_completed]

        self._maybe_resume_protocol()

    cdef inline _write_impl(self, data, char* data_ptr, Py_ssize_t data_len):
        cdef:
            int bytes_written
            int ssl_error

        while data_len != 0:
            bytes_written = self._ssl_object.write(data_ptr, data_len)
            if bytes_written > 0:
                if unlikely(self._is_debug):
                    _logger.debug("%r: SSL_write(..., data_len=%d)=%d", self, data_len, bytes_written)

                data_ptr += bytes_written
                data_len -= bytes_written

                if data_len == 0:
                    return None

                continue

            ssl_error = self._ssl_object.get_error(bytes_written)
            if unlikely(self._is_debug):
                _logger.debug("%r: SSL_write(..., data_len=%d)=%d, %s",
                              self, data_len, bytes_written,
                              ssl_error_name(ssl_error))

            if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                if self._should_retry_after_want_write():
                    continue
                else:
                    return aiofn_maybe_copy_buffer_tail(data, data_ptr, data_len)

            if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                return aiofn_maybe_copy_buffer_tail(data, data_ptr, data_len)

            # When socket BIO is used, SSL_write may fail with any of these.
            # Treat them as lost connection
            if ssl_error in (SSLError.SSL_ERROR_SYSCALL, SSLError.SSL_ERROR_ZERO_RETURN):
                raise ConnectionResetError()

            raise self._ssl_object.make_exc_from_ssl_error("SSL_write failed", ssl_error)

    cdef inline _call_eof_received(self):
        if self._app_state == AppProtocolState.STATE_CON_MADE:
            self._app_state = AppProtocolState.STATE_EOF
            try:
                keep_open = self._app_protocol.eof_received()
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as ex:
                self._fatal_error(ex, 'Error calling eof_received()')
            else:
                if keep_open:
                    _logger.warning('returning true from eof_received() has no effect when using ssl')

    cdef inline _clear_write_backlog(self, exc):
        cdef SendFileRequest req
        for data in self._write_backlog:
            if isinstance(data, SendFileRequest):
                _logger.debug("Found SendFileRequest in write_backlog")
                req = <SendFileRequest>data
                if not req.waiter.done():
                    req.waiter.set_exception(exc)
        self._write_backlog.clear()
        self._write_backlog_size = 0

    cdef inline bint _is_protocol_ready(self) except -1:
        if self._connection_lost_scheduled or self._state in (
            SSLProtocolState.FLUSHING,
            SSLProtocolState.SHUTDOWN,
            SSLProtocolState.UNWRAPPED
        ):
            if self._closed_write_count >= constants.LOG_THRESHOLD_FOR_CONNLOST_WRITES:
                _logger.warning('SSL connection is closed')
            self._closed_write_count += 1
            return False
        return True

    cdef inline _fatal_error(self, exc, message='Fatal error on transport'):
        self._force_close(exc)
        if isinstance(exc, OSError):
            if self._loop is not None and self._loop.get_debug():
                _logger.debug("%r: %s", self, message, exc_info=True)
        elif self._loop is not None and not isinstance(exc, asyncio.CancelledError):
            self._loop.call_exception_handler({
                'message': message,
                'exception': exc,
                'transport': self,
                'protocol': self,
            })

    cdef inline _fatal_error_no_close(self, exc, message='Fatal error on transport'):
        if isinstance(exc, OSError):
            if self._loop is not None and self._loop.get_debug():
                _logger.debug("%r: %s", self, message, exc_info=True)
        elif self._loop is not None:
            self._loop.call_exception_handler({
                'message': message,
                'exception': exc,
                'transport': self,
                'protocol': self,
            })

    def _allow_renegotiation(self):
        self._ssl_object.allow_renegotiation()

    # Used for testing only
    def _renegotiate(self):
        if self._state != SSLProtocolState.WRAPPED:
            raise RuntimeError(
                "renegotiation requires an active wrapped SSL connection")

        cipher = self._extra.get("cipher")
        if cipher is not None and len(cipher) >= 2 and cipher[1] == "TLSv1.3":
            raise NotImplementedError(
                "TLS 1.3 does not support classic SSL renegotiation")

        cdef:
            int rc
            int ssl_error

        try:
            rc = self._ssl_object.renegotiate()
            if unlikely(self._is_debug):
                _logger.debug("%r: SSL_renegotiate()=%d", self, rc)

            if rc != 1:
                raise RuntimeError(f"ssl renegotiation request failed")

            self._do_handshake()
        except Exception as ex:
            self._fatal_error(ex, "Fatal error on SSL renegotiation")


cdef class SSLTransport_Socket(SSLTransportBase):
    """
    Use socket send and receive data. Supports kTLS
    """


    cdef:
        object _sock            #
        object _sock_fd_obj     # Cache python object for int fd, loop add_reader/add_writer expects it
        int _sock_fd

        WriteWatermarks _write_watermarks

        # Are we registered for _write_ready in the event loop?
        bint _write_ready_registered

    def __init__(self, loop, sock, app_protocol, sslcontext,
                 *,
                 waiter=None,
                 server_side=False,
                 server_hostname=None,
                 ssl_handshake_timeout=None,
                 ssl_shutdown_timeout=None,
                 ssl_incoming_bio_size=None,
                 ssl_outgoing_bio_size=None,
                 server=None):
        self._sock = sock
        self._sock_fd_obj = sock.fileno()
        self._sock_fd = self._sock_fd_obj
        aiofn_set_nodelay(self._sock)

        SSLTransportBase.__init__(self, loop, app_protocol, sslcontext, waiter,
                                  server_side, server_hostname,
                                  ssl_handshake_timeout,
                                  ssl_shutdown_timeout,
                                  ssl_incoming_bio_size,
                                  ssl_outgoing_bio_size,
                                  server,
                                  sock)
        self._extra = {'socket': TransportSocket(sock), 'sslcontext': sslcontext}
        try:
            self._extra['sockname'] = sock.getsockname()
        except OSError:
            self._extra['sockname'] = None
        try:
            self._extra['peername'] = sock.getpeername()
        except OSError:
            self._extra['peername'] = None

        self._write_watermarks = WriteWatermarks(loop)

        self._loop.add_reader(self._sock_fd_obj, self._read_ready)
        self._start_handshake()

    def __del__(self):
        if self._sock is not None:
            warnings.warn(f"unclosed transport {self!r}", ResourceWarning, source=self)
            self._sock.close()
            if self._server is not None:
                self._server._detach(self)

    cpdef is_reading(self):
        self._check_thread("is_reading")
        return not self.is_closing() and not self._read_paused

    cpdef pause_reading(self):
        self._check_thread("pause_reading")
        if not self.is_reading():
            return
        self._read_paused = True
        self._loop.remove_reader(self._sock_fd_obj)
        if unlikely(self._is_debug):
            _logger.debug("%r: reading paused by user", self)

    cpdef resume_reading(self):
        self._check_thread("resume_reading")
        if self.is_closing() or not self._read_paused:
            return
        self._read_paused = False
        if unlikely(self._is_debug):
            _logger.debug("%r: reading resumed by user", self)
        self._loop.add_reader(self._sock_fd_obj, self._read_ready)

        # We need to also manually schedule _read_ready event because there
        # might be some leftover data in incoming BIO or openssl internal
        # read buffer. We can't rely only on _loop.add_reader, because if
        # socket has no data to read then we will get stuck.
        if self._state in (SSLProtocolState.WRAPPED, SSLProtocolState.FLUSHING, SSLProtocolState.SHUTDOWN):
            self._loop.call_soon(self._read_ready)

    cpdef tuple get_write_buffer_limits(self):
        self._check_thread("get_write_buffer_limits")
        return self._write_watermarks.get_write_buffer_limits()

    cpdef set_write_buffer_limits(self, high=None, low=None):
        self._check_thread("set_write_buffer_limits")
        self._write_watermarks.set_write_buffer_limits(
            self, self._app_protocol, self.get_write_buffer_size(), high, low)

    cpdef get_write_buffer_size(self):
        self._check_thread("get_write_buffer_size")
        cdef Py_ssize_t total = self._write_backlog_size
        if self._app_protocol_aiofn:
            total += (<Protocol>self._app_protocol).get_local_write_buffer_size()
        return total

    cdef bint _flush_outgoing_bio(self) except -1:
        """
        Writes raw data to socket for outgoing BIO. 
        Returns True if write operations can continue.
        True is also returned if memory bio is not used, is such case _flush_outgoing_bio is no-op. 
        """
        if self._ssl_object.outgoing == NULL:
            return True

        if self._write_ready_registered:
            return False

        cdef:
            char* ptr
            long sz
            bint had_successful_writes = False

        while True:
            sz = self._ssl_object.outgoing_bio_get_data(&ptr)
            if sz == 0:
                return True

            bytes_sent = aiofn_send(self._sock_fd, ptr, sz)
            if unlikely(self._is_debug):
                _logger.debug("%r: aiofn_send(...,len=%d)=%d", self, sz, bytes_sent)

            if bytes_sent < 0:
                self._ensure_writer()
                return had_successful_writes

            had_successful_writes = True
            self._ssl_object.outgoing_bio_consume(bytes_sent)
            if bytes_sent == sz:
                return True

            ptr += bytes_sent
            sz -= bytes_sent

    cdef bint _should_retry_after_want_write(self) except -1:
        """
        Return True if we should retry the last operation after we got SSL_ERROR_WANT_WRITE
        """
        if self._ssl_object.outgoing != NULL:
            return self._flush_outgoing_bio()
        else:
            self._ensure_writer()
            return False

    cdef bint _should_flush_outgoing_after_read(self) except -1:
        return not self._write_ready_registered

    cdef inline _ensure_writer(self):
        if self._connection_lost_scheduled or self._write_ready_registered:
            return
        self._write_ready_registered = True
        self._loop.add_writer(self._sock_fd_obj, self._write_ready)

    cdef inline _drop_writer(self):
        if self._sock is None or not self._write_ready_registered:
            return
        self._write_ready_registered = False
        self._loop.remove_writer(self._sock_fd_obj)

    def _write_ready(self):
        if unlikely(self._is_debug):
            _logger.debug("%r: _write_ready event", self)

        if self._connection_lost_scheduled:
            return

        try:
            self._drop_writer()
            self._flush_outgoing_bio()

            if self._state == SSLProtocolState.DO_HANDSHAKE:
                self._do_handshake()
            elif self._state == SSLProtocolState.WRAPPED:
                if self._write_backlog_size:
                    self._flush_write_backlog()
                else:
                    self._do_read()
            elif self._state == SSLProtocolState.FLUSHING:
                self._do_flush()
            elif self._state == SSLProtocolState.SHUTDOWN:
                self._do_shutdown()
        except BaseException as exc:
            self._fatal_error(exc, "Error occurred during write")

    cdef _check_sendfile_supported(self):
        if not self._ssl_object.sendfile_available() or \
            not self._ssl_object.ktls_send_enabled():
            raise NotImplementedError()

    cdef bint _try_sendfile(self, SendFileRequest req) except -1:
        while True:
            bytes_written = self._ssl_object.sendfile(req.fd, req.offset, req.count)
            if bytes_written >= 0:
                if unlikely(self._is_debug):
                    _logger.debug("%r: SSL_sendfile(..., offset=%d, size=%d) = %d", self,
                                  req.offset, req.count, bytes_written)

                req.offset += bytes_written
                req.count -= bytes_written
                if req.count == 0:
                    if not req.waiter.done():
                        req.waiter.set_result(None)
                    return True
                else:
                    continue
            else:
                ssl_error = self._ssl_object.get_error(bytes_written)
                if unlikely(self._is_debug):
                    _logger.debug("%r: SSL_sendfile(..., offset=%d, size=%d) = %d, %s",
                                  self, req.offset, req.count, bytes_written,
                                  ssl_error_name(ssl_error))

                if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                    self._ensure_writer()
                    return False
                elif ssl_error == SSLError.SSL_ERROR_WANT_READ:
                    return False

                # When socket BIO is used, SSL_sendfile may fail with SSL_ERROR_SYSCALL went peer close socket.
                # Treat it as lost connection.
                exc = ConnectionResetError() if ssl_error == SSLError.SSL_ERROR_SYSCALL else \
                    self._ssl_object.make_exc_from_ssl_error("SSL_sendfile failed", ssl_error)
                if not req.waiter.done():
                    req.waiter.set_exception(exc)

                raise exc

    cdef _read_ready(self):
        if unlikely(self._is_debug):
            _logger.debug("%r: _read_ready event", self)

        if self._connection_lost_scheduled:
            return

        cdef:
            char* buf_ptr
            Py_ssize_t buf_len
            Py_ssize_t bytes_read

        try:
            if self._ssl_object.incoming != NULL:
                while not self._read_paused:
                    self._ssl_object.incoming_bio_get_write_buf(&buf_ptr, &buf_len)
                    bytes_read = aiofn_recv(self._sock_fd, buf_ptr, buf_len)

                    if unlikely(self._is_debug):
                        _logger.debug("%r: aiofn_recv(...,len=%d)=%d", self, buf_len, bytes_read)

                    if bytes_read == -1:  # without exception this means EGAIN
                        return

                    if unlikely(bytes_read == 0):
                        self._process_eof()
                        return

                    self._ssl_object.incoming_bio_produce(bytes_read)
                    self._incoming_bio_updated()
            else:
                self._incoming_bio_updated()

        except BaseException as exc:
            self._fatal_error(exc, "Error occurred during read")

    cpdef _force_close(self, exc):
        if self._sock is None:
            return
        self._connection_lost_scheduled = True
        if self._write_backlog_size:
            self._clear_write_backlog(exc)
        self._drop_writer()
        self._loop.remove_reader(self._sock_fd_obj)
        self._loop.call_soon(self._call_connection_lost, exc)

    cdef _maybe_pause_protocol(self):
        self._write_watermarks.maybe_pause_protocol(self, self._app_protocol, self.get_write_buffer_size())

    cdef _maybe_resume_protocol(self):
        self._write_watermarks.maybe_resume_protocol(self, self._app_protocol, self.get_write_buffer_size())

    cdef _get_sock_fd(self):
        return self._sock_fd_obj

    cdef _is_closed(self):
        return self._sock is None

    cdef inline _call_connection_lost(self, exc):
        try:
            if self._app_protocol_connected and self._app_state in (AppProtocolState.STATE_CON_MADE, AppProtocolState.STATE_EOF):
                self._app_state = AppProtocolState.STATE_CON_LOST
                self._app_protocol.connection_lost(exc)
        finally:
            if self._sock is not None:
                self._sock.close()
                if unlikely(self._is_debug):
                    _logger.debug("%r: _sock.close() called", self)
            self._sock = None
            self._app_protocol = None
            self._loop = None
            server = self._server
            if server is not None:
                server._detach(self)
                self._server = None


cdef class SSLProtocol(Protocol, asyncio.BufferedProtocol):
    cdef:
        SSLTransport_Transport _ssl_transport

    def __init__(self, SSLTransport_Transport ssl_transport):
        self._ssl_transport = ssl_transport

    cpdef is_buffered_protocol(self):
        return True

    cpdef connection_made(self, transport):
        return self._ssl_transport.connection_made(transport)

    cpdef connection_lost(self, exc):
        # Break cyclic dependency
        ssl_transport = self._ssl_transport
        self._ssl_transport = None
        return ssl_transport.connection_lost(exc)

    cdef get_buffer_c(self, Py_ssize_t n, char** buf_ptr, Py_ssize_t* buf_len):
        return self._ssl_transport.get_buffer_c(n, buf_ptr, buf_len)

    cpdef get_buffer(self, Py_ssize_t n):
        return self._ssl_transport.get_buffer(n)

    cpdef buffer_updated(self, Py_ssize_t nbytes):
        self._ssl_transport.buffer_updated(nbytes)

    cpdef eof_received(self):
        self._ssl_transport.eof_received()

    cpdef pause_writing(self):
        self._ssl_transport.pause_writing()

    cpdef resume_writing(self):
        self._ssl_transport.resume_writing()

    cpdef Py_ssize_t get_local_write_buffer_size(self) except -1:
        return self._ssl_transport.get_local_write_buffer_size()


cdef class SSLTransport_Transport(SSLTransportBase):
    """
    Use downstream Transport to send and receive data
    """
    cdef:
        object _transport
        object _sock_fd_obj
        bint _is_aiofn_transport

    def __init__(self,
                 loop,
                 app_protocol,
                 sslcontext,
                 *,
                 waiter=None,
                 server_side=False,
                 server_hostname=None,
                 call_connection_made=True,
                 ssl_handshake_timeout=None,
                 ssl_shutdown_timeout=None,
                 ssl_incoming_bio_size=None,
                 ssl_outgoing_bio_size=None,
                 server=None):
        self._transport = None
        self._sock_fd_obj = None
        self._is_aiofn_transport = False

        # SSL-specific extra info. More info are set when the handshake
        # completes.
        self._extra = dict(sslcontext=sslcontext)

        SSLTransportBase.__init__(self, loop, app_protocol, sslcontext, waiter,
                                  server_side, server_hostname,
                                  ssl_handshake_timeout,
                                  ssl_shutdown_timeout,
                                  ssl_incoming_bio_size,
                                  ssl_outgoing_bio_size,
                                  server,
                                  None)
        if call_connection_made:
            self._app_state = AppProtocolState.STATE_INIT
        else:
            self._app_state = AppProtocolState.STATE_CON_MADE

    cpdef get_tls_protocol(self):
        return SSLProtocol(self)

    cdef inline connection_made(self, transport):
        """Called when the low-level connection is made.

        Start the SSL handshake.
        """
        self._transport = transport
        self._sock_fd_obj = transport.get_extra_info('socket').fileno()
        self._is_aiofn_transport = isinstance(transport, Transport)
        underlying_ssl_layer_num = self._transport.get_extra_info('ssl_layer_num')
        if underlying_ssl_layer_num is not None:
            self._ssl_layer_num = underlying_ssl_layer_num + 1
        self._start_handshake()

    cdef inline connection_lost(self, exc):
        """Called when the low-level connection is lost or closed.

        The argument is an exception object or None (the latter
        meaning a regular EOF is received or the connection was
        aborted or closed).
        """
        self._connection_lost_scheduled = True
        if self._write_backlog_size:
            self._clear_write_backlog(exc)
        self._ssl_object.outgoing_bio_reset()

        if self._state != SSLProtocolState.DO_HANDSHAKE:
            if self._app_state == AppProtocolState.STATE_CON_MADE or \
                    self._app_state == AppProtocolState.STATE_EOF:
                self._app_state = AppProtocolState.STATE_CON_LOST
                self._loop.call_soon(self._app_protocol.connection_lost, exc)
        self._set_state(SSLProtocolState.UNWRAPPED)
        self._transport = None

        # Decrease ref counters to user instances to avoid cyclic references
        # between user protocol, SSLProtocol and SSLTransport.
        # This helps to deallocate useless objects asap.
        self._transport = None
        self._app_protocol = None
        self._wakeup_waiter(exc)

        if self._shutdown_timeout_handle:
            self._shutdown_timeout_handle.cancel()
            self._shutdown_timeout_handle = None
        if self._handshake_timeout_handle:
            self._handshake_timeout_handle.cancel()
            self._handshake_timeout_handle = None

    cdef inline get_buffer_c(self, Py_ssize_t n, char** buf_ptr, Py_ssize_t* buf_len):
        self._ssl_object.incoming_bio_get_write_buf(buf_ptr, buf_len)

    cdef inline get_buffer(self, Py_ssize_t n):
        cdef:
            char* buf_ptr
            Py_ssize_t buf_len

        self._ssl_object.incoming_bio_get_write_buf(&buf_ptr, &buf_len)
        return PyMemoryView_FromMemory(buf_ptr, buf_len, PyBUF_WRITE)

    cdef inline buffer_updated(self, Py_ssize_t nbytes):
        if unlikely(self._is_debug):
            _logger.debug("%r: buffer_updated(%d)", self, nbytes)

        self._ssl_object.incoming_bio_produce(nbytes)
        self._incoming_bio_updated()

    cdef inline eof_received(self):
        if unlikely(self._is_debug):
            _logger.debug("%r: received EOF", self)

        if self._state == SSLProtocolState.DO_HANDSHAKE:
            self._on_handshake_complete(ConnectionResetError)

        elif self._state == SSLProtocolState.WRAPPED or self._state == SSLProtocolState.FLUSHING:
            # We treat a low-level EOF as a critical situation similar to a
            # broken connection - just send whatever is in the buffer and
            # close. No application level eof_received() is called -
            # because we don't want the user to think that this is a
            # graceful shutdown triggered by SSL "close_notify".
            self._set_state(SSLProtocolState.SHUTDOWN)
            self._on_shutdown_complete(None)

        elif self._state == SSLProtocolState.SHUTDOWN:
            self._on_shutdown_complete(None)

    cdef inline pause_writing(self):
        self._app_protocol.pause_writing()

    cdef inline resume_writing(self):
        self._app_protocol.resume_writing()

    cpdef get_extra_info(self, name, default=None):
        value = SSLTransportBase.get_extra_info(self, name)
        if value is not None:
            return value

        if self._transport is None:
            return default

        return self._transport.get_extra_info(name, default)

    cpdef is_reading(self):
        self._check_thread("is_reading")
        return self._transport.is_reading()

    cpdef pause_reading(self):
        self._check_thread("pause_reading")
        self._read_paused = True
        self._transport.pause_reading()

    cpdef resume_reading(self):
        self._check_thread("resume_reading")
        if self._read_paused:
            self._read_paused = False
            self._loop.call_soon(self.buffer_updated, 0)
        self._transport.resume_reading()

    cpdef set_write_buffer_limits(self, high=None, low=None):
        self._check_thread("set_write_buffer_limits")
        if self._transport is not None:
            self._transport.set_write_buffer_limits(high, low)

    cpdef tuple get_write_buffer_limits(self):
        self._check_thread("get_write_buffer_limits")
        if self._transport is not None:
            return self._transport.get_write_buffer_limits()
        else:
            return 0, 0

    cpdef get_write_buffer_size(self):
        self._check_thread("get_write_buffer_size")
        if self._transport is not None:
            return self._transport.get_write_buffer_size()
        else:
            return 0

    cdef bint _flush_outgoing_bio(self) except -1:
        """
        Writes raw data to socket for outgoing BIO. 
        Returns True if write operations can continue.
        True is also returned if memory bio is not used, is such case _flush_outgoing_bio is no-op. 
        """
        cdef:
            char* ptr
            long sz

        sz = self._ssl_object.outgoing_bio_get_data(&ptr)
        if sz == 0:
            return True

        if self._is_aiofn_transport:
            (<Transport> self._transport).write_c(ptr, sz)
        else:
            self._transport.write(PyBytes_FromStringAndSize(ptr, sz))

        self._ssl_object.outgoing_bio_consume(sz)
        if unlikely(self._is_debug):
            _logger.debug("%r: flushed %d bytes from outgoing BIO", self, sz)

        return True

    cdef bint _should_retry_after_want_write(self) except -1:
        """
        Return True if we should retry the last operation after we got SSL_ERROR_WANT_WRITE
        """
        return self._flush_outgoing_bio()

    cdef bint _should_flush_outgoing_after_read(self) except -1:
        return True

    cdef _maybe_pause_protocol(self):
        # We rely on the underlying protocol watermarks checking
        pass

    cdef _maybe_resume_protocol(self):
        # We rely on the underlying protocol watermarks checking
        pass

    cpdef _force_close(self, exc):
        # underlying transport will call connection_lost
        if self._transport is not None:
            self._transport._force_close(exc)

    cdef _get_sock_fd(self):
        return self._sock_fd_obj

    cdef _is_closed(self):
        return self._transport is None


