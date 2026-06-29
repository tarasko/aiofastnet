import asyncio
import os
import ssl
import sys
import warnings
from asyncio.trsock import TransportSocket
from logging import getLogger
from typing import Optional

from cpython.bytearray cimport PyByteArray_AS_STRING, PyByteArray_GET_SIZE, PyByteArray_FromStringAndSize
from cpython.bytes cimport PyBytes_FromStringAndSize
from cpython.object cimport PyObject
from cpython.buffer cimport PyBUF_WRITE, PyBUF_WRITABLE
from cpython.memoryview cimport PyMemoryView_FromMemory
from cpython.pythread cimport PyThread_get_thread_ident
from cpython.ref cimport Py_XDECREF
from posix.types cimport off_t

from . import constants
from .utils cimport (
    SSLProtocolState,
    AppProtocolState,
    aiofn_unpack_simple_buffer,
    aiofn_validate_buffer,
    aiofn_maybe_copy_buffer,
    aiofn_maybe_copy_buffer_tail,
    aiofn_recv,
    aiofn_send,
    aiofn_allocate_bytes,
    aiofn_finalize_bytes,
    aiofn_set_nodelay,
    aiofn_add_info_and_reraise,
    unlikely
)
from .ssl_engine cimport SSLEngine, SSLError, ssl_error_name
from .transport cimport Transport, Protocol, WriteWatermarks
from . import ssl_engine_direct, ssl_engine_fallback
from .transport import aiofn_is_buffered_protocol
from .openssl_compat import OPENSSL_DYN_LIBS, create_transport_context


cdef object _logger = getLogger('aiofastnet.ssl')
cdef size_t LOG_THRESHOLD_FOR_CONNLOST_WRITES = constants.LOG_THRESHOLD_FOR_CONNLOST_WRITES
cdef Py_ssize_t DATA_RECEIVED_MAX_SIZE = constants.DATA_RECEIVED_MAX_SIZE


def _log_ktls_deactivation_reason(conn) -> None:
    # Give the user a clue for a cause that cannot be detected before the handshake.
    _logger.warning(
        "%r: Kernel TLS was not enabled PROBABLY because OpenSSL was built on a machine with an old linux kernel (<5.19)",
        conn)
    if OPENSSL_DYN_LIBS is None:
        _logger.warning("%r: OpenSSL dynamic libraries were not discovered; using stdlib SSL fallback", conn)
        return
    _logger.warning("%r: Loaded libssl: %s", conn, OPENSSL_DYN_LIBS.libssl)
    _logger.warning("%r: Loaded libcrypto: %s", conn, OPENSSL_DYN_LIBS.libcrypto)


cdef bint _use_fallback_ssl_engine = (
    os.environ.get("AIOFN_FORCE_FALLBACK") is not None or
    OPENSSL_DYN_LIBS is None
)


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
    self.waiter = None
    return self


cdef class SSLTransportBase(Transport):
    cdef:
        object __weakref__
        unsigned long _thread_id
        object _loop
        object _sock_fd_obj             # Initialized early, used in repr
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

        SSLEngine _ssl_object
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

        public bint _sendfile_compatible
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

    cpdef Py_ssize_t get_write_buffer_size(self) except -1:
        raise NotImplementedError()

    cdef _is_closed(self):
        raise NotImplementedError()

    cdef bint _try_sendfile(self, SendFileRequest req) except -1:
        """
        Immediately try sendfile. Update req.offset and count if succeed.
        Re-raise any sendfile exception.
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

    def __init__(self,
                 loop, app_protocol, sslcontext,
                 bint server_side,
                 double ssl_handshake_timeout,
                 double ssl_shutdown_timeout,
                 Py_ssize_t ssl_incoming_bio_size,
                 Py_ssize_t ssl_outgoing_bio_size,
                 waiter: Optional[asyncio.Future]=None,
                 server_hostname: Optional[str]=None,
                 server=None,
                 sock=None):
        self._thread_id = PyThread_get_thread_ident()

        assert loop is not None
        self._loop = loop
        self._sock_fd_obj = sock.fileno() if sock is not None else None
        self._is_debug = loop.get_debug()

        assert ssl_handshake_timeout > 0
        assert ssl_shutdown_timeout > 0
        assert ssl_incoming_bio_size > 0
        assert ssl_outgoing_bio_size > 0

        if server_side and not sslcontext:
            raise ValueError('Server side SSL needs a valid SSLContext')

        if not sslcontext or sslcontext is True:
            sslcontext = create_transport_context(server_side, server_hostname)

        self._extra = {'sslcontext': sslcontext}
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
        self._sendfile_compatible = False
        self._server_side = server_side
        self._server_hostname = None if server_side else server_hostname
        self._state = SSLProtocolState.UNWRAPPED
        self._app_state = AppProtocolState.STATE_INIT

        self._set_protocol(app_protocol)

        if _use_fallback_ssl_engine:
            self._ssl_object = ssl_engine_fallback.SSLEngineFallback(
                sslcontext,
                server_side,
                self._server_hostname,
                ssl_incoming_bio_size,
                ssl_outgoing_bio_size,
                sock=sock
            )
        else:
            self._ssl_object = ssl_engine_direct.SSLEngineDirect(
                sslcontext,
                server_side,
                self._server_hostname,
                ssl_incoming_bio_size,
                ssl_outgoing_bio_size,
                sock=sock
            )

        if self._server is not None:
            self._server._attach(self)

        if self._is_debug and OPENSSL_DYN_LIBS is not None:
            _logger.debug("%r: libssl: %s", self, OPENSSL_DYN_LIBS.libssl)
            _logger.debug("%r: libcrypto: %s", self, OPENSSL_DYN_LIBS.libcrypto)
            _logger.debug("%r: %s", self, ssl.OPENSSL_VERSION)
            _logger.info("%r: SSL_sendfile loaded=%d", self, self._ssl_object.sendfile_available())
        elif self._is_debug:
            _logger.debug("%r: using stdlib SSL fallback engine", self)
            _logger.debug("%r: %s", self, ssl.OPENSSL_VERSION)

    def __repr__(self):
        if self._sock_fd_obj is not None:
            info = [f"fd={self._sock_fd_obj}"]
        else:
            info = ["fd=n/a"]

        info.append(self.__class__.__name__)
        if self._server_side:
            info.append("server")
        else:
            info.append("client")

        info.append(f"#{self._ssl_layer_num}")

        if self._is_closed():
            info.append('closed')
        else:
            if self.is_closing():
                info.append('closing')
            info.append(f'wbuf_size={self._write_backlog_size}')
        return '[{}]'.format(' '.join(info))

    cdef inline _set_protocol(self, protocol):
        self._app_protocol = protocol
        self._app_protocol_is_buffered = aiofn_is_buffered_protocol(protocol)
        self._app_protocol_aiofn = isinstance(protocol, Protocol)
        self._app_protocol_connected = True

    cpdef get_extra_info(self, name, default=None):
        self._check_thread("get_extra_info")
        if name == 'ssl_object':
            return self._ssl_object.get_ssl_object()
        elif name == 'ssl_protocol':
            return self
        elif name == 'ssl_layer_num':
            return self._ssl_layer_num
        elif name == 'ssl_incoming_use_membio':
            return bool(self._ssl_object.ssl_incoming_use_membio())
        elif name == 'ssl_outgoing_use_membio':
            return bool(self._ssl_object.ssl_outgoing_use_membio())
        elif name == 'ktls_send_enabled':
            return bool(self._ssl_object.ktls_send_enabled())
        elif name == 'ktls_recv_enabled':
            return bool(self._ssl_object.ktls_recv_enabled())
        return self._extra.get(name, default)

    cpdef set_protocol(self, protocol):
        self._check_thread("set_protocol")
        self._set_protocol(protocol)

    cpdef get_protocol(self):
        self._check_thread("get_protocol")
        return self._app_protocol

    cpdef is_closing(self):
        return self._connection_lost_scheduled or self._state in (
            SSLProtocolState.FLUSHING,
            SSLProtocolState.SHUTDOWN,
            SSLProtocolState.UNWRAPPED
        )

    cpdef close(self):
        self._check_thread("close")
        if unlikely(self._is_debug):
            _logger.debug("%r: user called close()", self)
        try:
            self._start_shutdown()
        except:
            self._handle_error("Error occurred during shutdown")

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

        if self._ssl_object is not None and self._ssl_object.ssl_outgoing_use_membio():
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
        elif self._state == SSLProtocolState.WRAPPED and new_state in (
            SSLProtocolState.FLUSHING,
            SSLProtocolState.SHUTDOWN,
            SSLProtocolState.DO_HANDSHAKE,
        ):
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
        try:
            if self._state == SSLProtocolState.DO_HANDSHAKE:
                raise ConnectionAbortedError(
                        f"SSL handshake is taking longer than {self._ssl_handshake_timeout} seconds: "
                        "aborting the connection")
        except:
            self._handle_error('SSL handshake failed')

    cdef _retry_ssl_read(self):
        if unlikely(self._is_debug):
            _logger.debug("%r: _retry_ssl_read event", self)

        if self._connection_lost_scheduled:
            return

        try:
            self._incoming_bio_updated()
        except:
            self._handle_error("Error occurred during read")

    cdef inline _do_handshake(self):
        cdef SSLError ssl_error

        while True:
            ssl_error = self._ssl_object.do_handshake(self)
            if ssl_error == SSLError.SSL_ERROR_NONE:
                self._on_handshake_complete(None)
                self._flush_outgoing_bio()
                return

            if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                if self._should_retry_after_want_write():
                    continue
                else:
                    return

            if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                self._flush_outgoing_bio()
                return

            raise RuntimeError(f"unexpected SSL_do_handshake error: {ssl_error_name(ssl_error)}")

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

        ssl_object = self._ssl_object.get_ssl_object()

        _logger.debug("%r: cipher %s", self, ssl_object.cipher())
        _logger.debug("%r: KTLS SEND: %s",
                      self, 'enabled' if self._ssl_object.ktls_send_enabled() else 'disabled')
        _logger.debug("%r: KTLS RECV: %s",
                      self, 'enabled' if self._ssl_object.ktls_recv_enabled() else 'disabled')

        if self._ssl_object.ktls_requested and (
            (not self._ssl_object.ssl_incoming_use_membio() and not self._ssl_object.ktls_recv_enabled()) or
            (not self._ssl_object.ssl_outgoing_use_membio() and not self._ssl_object.ktls_send_enabled())
        ):
            _log_ktls_deactivation_reason(self)

        self._sendfile_compatible = self._ssl_object.sendfile_available() and self._ssl_object.ktls_send_enabled()

        self._extra.update(
            peercert=ssl_object.getpeercert(),
            cipher=ssl_object.cipher(),
            compression=ssl_object.compression()
        )
        self._wakeup_waiter()
        self._call_protocol_connection_made()
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
            Py_ssize_t last_bytes_read = 0
            Py_ssize_t total_bytes_read = 0
            SSLError last_error = SSLError.SSL_ERROR_NONE

        while True:
            app_buffer = self._call_protocol_get_buffer(&buf_ptr, &buf_len)

            last_error = self._ssl_object.read(self, buf_ptr, buf_len, &last_bytes_read)
            buf_len -= last_bytes_read
            total_bytes_read += last_bytes_read

            if total_bytes_read > 0:
                self._call_protocol_buffer_updated(total_bytes_read)
                total_bytes_read = 0

            if buf_len == 0:
                if not self._read_paused:
                    continue
                else:
                    return

            if not self._should_retry_read(last_error) or self._read_paused:
                return

    cdef inline _do_read__copied(self):
        cdef:
            Py_ssize_t bytes_read
            char* bytes_buffer_ptr = NULL
            PyObject* bytes_obj = NULL
            SSLError last_error = SSLError.SSL_ERROR_NONE
            Py_ssize_t total_bytes_read

        while True:
            bytes_obj = aiofn_allocate_bytes(DATA_RECEIVED_MAX_SIZE, &bytes_buffer_ptr)
            total_bytes_read = 0

            try:
                last_error = self._ssl_object.read(self, bytes_buffer_ptr, DATA_RECEIVED_MAX_SIZE, &bytes_read)
                total_bytes_read += bytes_read
            except:
                Py_XDECREF(bytes_obj)
                raise

            data = aiofn_finalize_bytes(bytes_obj, total_bytes_read)
            bytes_obj = NULL # Just to mark that it doesn't have any valid object anymore
            self._call_protocol_data_received(data)

            if self._read_paused:
                return

            if total_bytes_read < DATA_RECEIVED_MAX_SIZE and not self._should_retry_read(last_error):
                return

    cdef inline bint _should_retry_read(self, SSLError last_error) except -1:
        if last_error == SSLError.SSL_ERROR_WANT_READ:
            return False

        if last_error == SSLError.SSL_ERROR_WANT_WRITE:
            return self._should_retry_after_want_write()

        if last_error == SSLError.SSL_ERROR_ZERO_RETURN:
            self._call_protocol_eof_received()
            self._start_shutdown()
            return False

        raise RuntimeError(f"unexpected SSL_read error: {ssl_error_name(last_error)}")

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

    cdef inline _handle_error(self, message):
        _, exc, _ = sys.exc_info()

        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise

        if self._state == SSLProtocolState.DO_HANDSHAKE:
            self._on_handshake_complete(exc)
            return

        if self._state in (SSLProtocolState.FLUSHING, SSLProtocolState.SHUTDOWN):
            self._on_shutdown_complete(exc)
            return

        message = getattr(exc, constants.EXC_INFO_ATTR, message)
        self._fatal_error(exc, message)

    cdef inline _do_read_into_void(self):
        cdef:
            bytearray buffer = PyByteArray_FromStringAndSize(NULL, 16 * 1024)
            Py_ssize_t bytes_read
            SSLError ssl_error

        while True:
            ssl_error = self._ssl_object.read(self, PyByteArray_AS_STRING(buffer), PyByteArray_GET_SIZE(buffer), &bytes_read)
            if ssl_error == SSLError.SSL_ERROR_NONE:
                continue

            if not self._should_retry_read(ssl_error):
                return

    cdef inline _do_flush(self):
        self._do_read_into_void()
        if self._write_backlog_size:
            self._flush_write_backlog()

        if self.get_local_write_buffer_size() == 0:
            self._set_state(SSLProtocolState.SHUTDOWN)
            self._do_shutdown()

    cdef inline _do_shutdown(self):
        cdef SSLError ssl_error

        self._do_read_into_void()

        while True:
            ssl_error = self._ssl_object.shutdown(self)
            if ssl_error == SSLError.SSL_ERROR_NONE:
                self._flush_outgoing_bio()
                self._on_shutdown_complete(None)
                return

            if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                if self._should_retry_after_want_write():
                    continue
                else:
                    return

            if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                self._flush_outgoing_bio()
                return

            raise RuntimeError(f"unexpected SSL_shutdown error: {ssl_error_name(ssl_error)}")

    cdef inline _on_shutdown_complete(self, shutdown_exc):
        if self._shutdown_timeout_handle is not None:
            self._shutdown_timeout_handle.cancel()
            self._shutdown_timeout_handle = None
        if shutdown_exc is not None:
            message = getattr(shutdown_exc, constants.EXC_INFO_ATTR, 'Error occurred during shutdown')
            self._fatal_error(shutdown_exc, message)
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

    def sendfile(self, file, offset, count) -> Optional[asyncio.Future[None]]:
        self._check_thread("sendfile")

        # This is an undocumented feature in asyncio and uvloop
        # Some 3rdparty tests use it to disable native sendfile (for example aiohttp tests)
        if not self._sendfile_compatible:
            raise NotImplementedError()

        if not self._is_protocol_ready():
            raise RuntimeError("Transport is closing")

        cdef SendFileRequest req = _make_send_file_request(file, offset, count)

        try:
            if self._write_backlog_size == 0:
                if self._try_sendfile(req):
                    return None

            if unlikely(self._is_debug):
                _logger.debug("%r: enqueue SendFileRequest(offset=%d,count=%d)",
                              self, req.offset, req.count)

            self._write_backlog.append(req)
            self._write_backlog_size += req.count
            self._maybe_pause_protocol()

            req.waiter = self._loop.create_future()
            return req.waiter
        except:
            self._handle_error('Fatal error on TLS transport')
            raise

    cdef write_c(self, char* data_ptr, Py_ssize_t data_len):
        if not self._is_protocol_ready() or data_len == 0:
            return

        try:
            if self._write_backlog_size == 0:
                tail = self._write_impl(None, data_ptr, data_len)
                self._flush_outgoing_bio()
                self._append_to_backlog(tail, True)
            else:
                self._append_to_backlog(PyBytes_FromStringAndSize(data_ptr, data_len), True)
        except:
            self._handle_error('Fatal error on TLS transport')

    def write(self, data):
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

            aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
            if data_len == 0:
                return

            tail = self._write_impl(data, data_ptr, data_len)
            self._flush_outgoing_bio()
            self._append_to_backlog(tail, True)
        except:
            self._handle_error('Fatal error on TLS transport')

    def writelines(self, list_of_data):
        self._check_thread("writelines")
        for data in list_of_data:
            aiofn_validate_buffer(data)
        self.writelines_nocheck(list_of_data)

    cpdef writelines_nocheck(self, list_of_data):
        if not self._is_protocol_ready():
            return

        if unlikely(self._write_backlog_size):
            for data in list_of_data:
                self._append_to_backlog(data, False)
            self._maybe_pause_protocol()
            return

        cdef:
            char* data_ptr
            Py_ssize_t data_len
            bint add_to_backlog = False
            Py_ssize_t idx

        try:
            for idx, data in enumerate(list_of_data):
                if add_to_backlog:
                    self._append_to_backlog(data, False)
                    continue

                aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
                if data_len == 0:
                    continue

                tail = self._write_impl(data, data_ptr, data_len)
                if tail is not None:
                    self._write_backlog.append(tail)
                    self._write_backlog_size += len(tail)
                    add_to_backlog = True

            self._flush_outgoing_bio()
            self._maybe_pause_protocol()
        except:
            self._handle_error('Fatal error on TLS transport')

    cdef inline _flush_write_backlog(self):
        cdef:
            char* data_ptr
            Py_ssize_t data_len
            Py_ssize_t idx = 0
            Py_ssize_t items_completed = 0
            Py_ssize_t orig_req_size

        if self._state not in (SSLProtocolState.WRAPPED, SSLProtocolState.FLUSHING) or self._write_backlog_size == 0:
            return

        for idx, data in enumerate(self._write_backlog):
            if isinstance(data, SendFileRequest):
                orig_req_size = (<SendFileRequest>data).count
                sendfile_completed = self._try_sendfile(data)
                self._write_backlog_size -= orig_req_size
                self._write_backlog_size += (<SendFileRequest>data).count
                if not sendfile_completed:
                    break
                if not (<SendFileRequest>data).waiter.done():
                    (<SendFileRequest>data).waiter.set_result(None)
            else:
                aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
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
        cdef Py_ssize_t bytes_written
        cdef SSLError ssl_error

        while True:
            ssl_error = self._ssl_object.write(self, data_ptr, data_len, &bytes_written)

            if ssl_error == SSLError.SSL_ERROR_NONE:
                return

            data_ptr += bytes_written
            data_len -= bytes_written

            if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                if self._should_retry_after_want_write():
                    continue
                else:
                    return aiofn_maybe_copy_buffer_tail(data, data_ptr, data_len)

            if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                return aiofn_maybe_copy_buffer_tail(data, data_ptr, data_len)

    cdef inline _call_protocol_connection_made(self):
        if self._app_state == AppProtocolState.STATE_INIT:
            self._app_state = AppProtocolState.STATE_CON_MADE
            try:
                return self._app_protocol.connection_made(self)
            except (KeyboardInterrupt, SystemExit):
                raise
            except Exception as exc:
                self._fatal_error_no_close(exc, "user connection_made raised an exception")

    cdef inline _call_protocol_get_buffer(self, char** buf_ptr, Py_ssize_t* buf_len):
        try:
            if self._app_protocol_aiofn:
                app_buffer = (<Protocol> self._app_protocol).get_buffer_c(-1, buf_ptr, buf_len)
            else:
                app_buffer = self._app_protocol.get_buffer(-1)
                aiofn_unpack_simple_buffer(app_buffer, buf_ptr, buf_len, PyBUF_WRITABLE)

            if buf_len[0] == 0:
                raise RuntimeError('get_buffer() returned an empty buffer')

            return app_buffer
        except:
            aiofn_add_info_and_reraise('Fatal error: protocol.get_buffer() call failed.')

    cdef inline _call_protocol_buffer_updated(self, Py_ssize_t bytes_read):
        try:
            if self._app_protocol_aiofn:
                return (<Protocol> self._app_protocol).buffer_updated(bytes_read)
            else:
                return self._app_protocol.buffer_updated(bytes_read)
        except:
            aiofn_add_info_and_reraise('Fatal error: protocol.buffer_updated() call failed.')

    cdef inline _call_protocol_data_received(self, data):
        if data is not None:
            try:
                return self._app_protocol.data_received(data)
            except:
                aiofn_add_info_and_reraise('Fatal error: protocol.data_received() call failed.')

    cdef inline _call_protocol_eof_received(self):
        if self._app_state == AppProtocolState.STATE_CON_MADE:
            self._app_state = AppProtocolState.STATE_EOF
            try:
                keep_open = self._app_protocol.eof_received()
            except:
                aiofn_add_info_and_reraise('Error calling eof_received()')
            else:
                if keep_open:
                    _logger.warning('returning true from eof_received() has no effect when using ssl')

    cdef inline _clear_write_backlog(self, exc):
        cdef SendFileRequest req
        for data in self._write_backlog:
            if isinstance(data, SendFileRequest):
                req = <SendFileRequest>data
                if req.waiter is not None and not req.waiter.done():
                    req.waiter.set_exception(exc)
        self._write_backlog.clear()
        self._write_backlog_size = 0

    cdef inline bint _is_protocol_ready(self) except -1:
        if self._connection_lost_scheduled or self._state in (
            SSLProtocolState.FLUSHING,
            SSLProtocolState.SHUTDOWN,
            SSLProtocolState.UNWRAPPED
        ):
            if self._closed_write_count >= LOG_THRESHOLD_FOR_CONNLOST_WRITES:
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

    # Used for testing only
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

        cdef int rc

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
        WriteWatermarks _write_watermarks

        # Are we registered for _write_ready in the event loop?
        bint _write_ready_registered

        # Has any sys write failed with EAGAIN during current _write_ready run
        bint _write_had_eagain

        object _sock
        object _sock_fd_obj
        int _sock_fd

    def __init__(self, loop, app_protocol, sslcontext,
                 bint server_side,
                 double ssl_handshake_timeout,
                 double ssl_shutdown_timeout,
                 Py_ssize_t ssl_incoming_bio_size,
                 Py_ssize_t ssl_outgoing_bio_size,
                 sock,
                 waiter=None,
                 server_hostname=None,
                 server=None):
        SSLTransportBase.__init__(self,
                                  loop, app_protocol, sslcontext,
                                  server_side,
                                  ssl_handshake_timeout,
                                  ssl_shutdown_timeout,
                                  ssl_incoming_bio_size,
                                  ssl_outgoing_bio_size,
                                  waiter,
                                  server_hostname,
                                  server,
                                  sock)

        self._extra['socket'] = TransportSocket(sock)
        try:
            self._extra['sockname'] = sock.getsockname()
        except OSError:
            self._extra['sockname'] = None
        try:
            self._extra['peername'] = sock.getpeername()
        except OSError:
            self._extra['peername'] = None

        self._write_watermarks = WriteWatermarks(loop)

        self._write_ready_registered = False
        self._write_had_eagain = False

        self._sock = sock
        self._sock_fd_obj = self._sock.fileno()
        self._sock_fd = self._sock_fd_obj
        aiofn_set_nodelay(self._sock)

        self._loop.add_reader(self._sock_fd_obj, self._read_ready)
        self._start_handshake()

    def __del__(self):
        # Should not use repr.
        # Should assume that the object may have not been properly contructed (exception raise by __init__)

        if self._sock is not None:
            warnings.warn(f"deleting unclosed {self.__class__.__name__} for {self._sock}", ResourceWarning, source=self)
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

    cpdef Py_ssize_t get_write_buffer_size(self) except -1:
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
        if not self._ssl_object.ssl_outgoing_use_membio():
            return True

        if self._write_had_eagain:
            return False

        cdef:
            char* ptr
            long sz
            Py_ssize_t bytes_sent
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
        if self._ssl_object.ssl_outgoing_use_membio():
            return self._flush_outgoing_bio()
        else:
            self._ensure_writer()
            return False

    cdef bint _should_flush_outgoing_after_read(self) except -1:
        return not self._write_ready_registered

    cdef inline _ensure_writer(self):
        if unlikely(self._is_debug):
            _logger.debug("%r: _ensure_writer called", self)

        self._write_had_eagain = True
        if self._connection_lost_scheduled or self._write_ready_registered:
            return
        self._write_ready_registered = True
        self._loop.add_writer(self._sock_fd_obj, self._write_ready)

    cdef inline _drop_writer(self):
        if unlikely(self._is_debug):
            _logger.debug("%r: _drop_writer called", self)

        if self._sock is None or not self._write_ready_registered:
            return
        self._write_ready_registered = False
        self._loop.remove_writer(self._sock_fd_obj)

    def _write_ready(self):
        if unlikely(self._is_debug):
            _logger.debug("%r: _write_ready event", self)

        if self._connection_lost_scheduled:
            return

        # Reset _write_had_eagain
        # If any system write fails with EAGAIN it suppose to call _ensure_writer
        # _ensure_writer will set _write_had_eagain = True
        # At the end of _write_ready we deregister if nobody has set _write_had_eagain
        self._write_had_eagain = False

        try:
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

            if not self._write_had_eagain:
                self._drop_writer()
        except:
            self._handle_error("Error occurred during write")

    cdef bint _try_sendfile(self, SendFileRequest req) except -1:
        """
        Return True if finished, False if must wait for write ready event.

        Caller is always responsible for:
        * handling exceptions, including closing the transport when appropriate;
        * completing req.waiter when the request finishes or fails.
        """

        cdef:
            Py_ssize_t bytes_written
            SSLError ssl_error

        while True:
            ssl_error = self._ssl_object.sendfile(self, req.fd, req.offset, req.count, &bytes_written)
            req.offset += bytes_written
            req.count -= bytes_written

            if ssl_error == SSLError.SSL_ERROR_NONE:
                return True

            if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                if self._should_retry_after_want_write():
                    continue
                return False

            if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                return False

            raise RuntimeError(f"unexpected SSL_sendfile error: {ssl_error_name(ssl_error)}")

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
            if self._ssl_object.ssl_incoming_use_membio():
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
        except:
            self._handle_error("Error occurred during read")

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
        cdef SSLTransport_Transport ssl_transport = self._ssl_transport
        if ssl_transport is None:
            return
        return ssl_transport.connection_made(transport)

    cpdef connection_lost(self, exc):
        # Break cyclic dependency
        cdef SSLTransport_Transport ssl_transport = self._ssl_transport
        if ssl_transport is None:
            return
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
        bint _is_aiofn_transport

    def __init__(self,
                 loop, app_protocol, sslcontext,
                 bint server_side,
                 double ssl_handshake_timeout,
                 double ssl_shutdown_timeout,
                 Py_ssize_t ssl_incoming_bio_size,
                 Py_ssize_t ssl_outgoing_bio_size,
                 waiter=None,
                 server_hostname=None,
                 server=None,
                 call_connection_made=True,
                 ):
        SSLTransportBase.__init__(self,
                                  loop, app_protocol, sslcontext,
                                  server_side,
                                  ssl_handshake_timeout,
                                  ssl_shutdown_timeout,
                                  ssl_incoming_bio_size,
                                  ssl_outgoing_bio_size,
                                  waiter,
                                  server_hostname,
                                  server)

        self._transport = None
        self._is_aiofn_transport = False

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
        _logger.debug("%r: connection_lost(%s)", self, exc)

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
        try:
            self._incoming_bio_updated()
        except:
            self._handle_error("Error occurred during read")

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

    cpdef Py_ssize_t get_write_buffer_size(self) except -1:
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
            if self._is_debug:
                _logger.debug("%r: force close on underlying transport", self)
            self._transport._force_close(exc)

    cdef _is_closed(self):
        return self._transport is None
