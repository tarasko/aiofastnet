import asyncio
import socket
import ssl
import warnings
from asyncio.trsock import TransportSocket
from logging import getLogger

from cpython.bytearray cimport PyByteArray_AS_STRING, PyByteArray_GET_SIZE
from cpython.buffer cimport PyBUF_WRITE
from cpython.bytes cimport PyBytes_FromStringAndSize, PyBytes_AS_STRING
from cpython.memoryview cimport PyMemoryView_FromMemory

from . import constants
from .utils cimport (
    aiofn_unpack_buffer,
    aiofn_validate_buffer,
    aiofn_maybe_copy_buffer,
    aiofn_maybe_copy_buffer_tail
)
from .transport cimport Transport, Protocol
from .transport import aiofn_is_buffered_protocol
from .ssl_object cimport SSLObject, SSLError, load_openssl, ssl_error_name
from .openssl cimport SSL_RECEIVED_SHUTDOWN


cdef object _logger = getLogger('aiofastnet.tls')


def _set_result_unless_cancelled(fut, result):
    if fut.cancelled():
        return
    fut.set_result(result)


def _create_transport_context(server_side, server_hostname):
    sslcontext = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    if not server_hostname:
        sslcontext.check_hostname = False
    return sslcontext


cdef _set_nodelay(sock):
    if hasattr(socket, 'TCP_NODELAY'):
        if (sock.family in {socket.AF_INET, socket.AF_INET6} and
                sock.type == socket.SOCK_STREAM and
                sock.proto == socket.IPPROTO_TCP):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)


cpdef enum TLSState:
    UNWRAPPED = 0
    DO_HANDSHAKE = 1
    WRAPPED = 2
    FLUSHING = 3
    SHUTDOWN = 4


cdef enum AppProtocolState:
    STATE_INIT = 0
    STATE_CON_MADE = 1
    STATE_EOF = 2
    STATE_CON_LOST = 3


cdef class TlsTransport(Transport):
    cdef:
        object __weakref__
        object _loop
        object _app_protocol
        bint _app_protocol_is_buffered
        bint _app_protocol_aiofn
        bint _protocol_connected
        bint _protocol_paused
        Py_ssize_t _high_water
        Py_ssize_t _low_water
        dict _extra

        object _sock
        object _server
        object _sock_fd_obj
        int _sock_fd
        bint _closing
        bint _paused
        bint _writer_active
        bint _write_wanted
        bint _is_debug

        SSLObject _ssl_object
        list _write_backlog
        Py_ssize_t _write_backlog_size

        TLSState _state
        AppProtocolState _app_state
        size_t _conn_lost
        object _ssl_handshake_complete_waiter
        object _ssl_handshake_timeout
        object _ssl_shutdown_timeout
        object _handshake_timeout_handle
        object _shutdown_timeout_handle
        object _ssl_layer_num

        bint _server_side
        str _server_hostname

    def __init__(self, loop, sock, app_protocol, sslcontext,
                 waiter=None, *,
                 server_side=False,
                 server_hostname=None,
                 ssl_handshake_timeout=None,
                 ssl_shutdown_timeout=None,
                 server=None):
        load_openssl()

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

        if server_side and not sslcontext:
            raise ValueError('Server side SSL needs a valid SSLContext')

        if not sslcontext or sslcontext is True:
            sslcontext = _create_transport_context(server_side, server_hostname)

        self._loop = loop
        self._sock = sock
        self._server = server
        self._sock_fd_obj = sock.fileno()
        self._sock_fd = self._sock_fd_obj
        self._extra = {'socket': TransportSocket(sock), 'sslcontext': sslcontext}
        try:
            self._extra['sockname'] = sock.getsockname()
        except OSError:
            self._extra['sockname'] = None
        try:
            self._extra['peername'] = sock.getpeername()
        except OSError:
            self._extra['peername'] = None

        self._write_backlog = []
        self._write_backlog_size = 0
        self._ssl_handshake_complete_waiter = waiter
        self._ssl_handshake_timeout = ssl_handshake_timeout
        self._ssl_shutdown_timeout = ssl_shutdown_timeout
        self._handshake_timeout_handle = None
        self._shutdown_timeout_handle = None
        self._ssl_layer_num = 0
        self._conn_lost = 0
        self._closing = False
        self._paused = False
        self._writer_active = False
        self._write_wanted = False
        self._is_debug = loop.get_debug()
        self._server_side = server_side
        self._server_hostname = None if server_side else server_hostname
        self._state = UNWRAPPED
        self._app_state = STATE_INIT

        self._set_protocol(app_protocol)
        self._set_write_buffer_limits()

        self._ssl_object = SSLObject(
            sslcontext,
            server_side,
            self._server_hostname,
            constants.SSL_INCOMING_BIO_SIZE,
            constants.SSL_OUTGOING_BIO_SIZE,
            sock=sock
        )

        if self._server is not None:
            self._server._attach(self)

        _set_nodelay(self._sock)
        self._loop.add_reader(self._sock_fd_obj, self._read_ready)
        self._start_handshake()

    def __repr__(self):
        info = [f'fd={self._sock_fd_obj}', 'TlsTransport']
        info.append('server' if self._server_side else 'client')
        if self._sock is None:
            info.append('closed')
        elif self._closing:
            info.append('closing')
        if self._loop is not None and not self._loop.is_closed():
            info.append(f'wbuf_size={self.get_write_buffer_size()}')
        return '[{}]'.format(' '.join(info))

    def __del__(self):
        if self._sock is not None:
            warnings.warn(f"unclosed transport {self!r}", ResourceWarning, source=self)
            self._sock.close()
            if self._server is not None:
                self._server._detach(self)

    cdef inline _set_protocol(self, protocol):
        self._app_protocol = protocol
        self._app_protocol_is_buffered = aiofn_is_buffered_protocol(protocol)
        self._app_protocol_aiofn = isinstance(protocol, Protocol)
        self._protocol_connected = True

    cpdef set_protocol(self, protocol):
        self._set_protocol(protocol)

    cpdef get_protocol(self):
        return self._app_protocol

    cpdef get_extra_info(self, name, default=None):
        if name == 'ssl_object':
            return self._ssl_object
        elif name == 'ssl_protocol':
            return self
        elif name == 'ssl_layer_num':
            return self._ssl_layer_num
        return self._extra.get(name, default)

    cpdef tuple get_write_buffer_limits(self):
        return (self._low_water, self._high_water)

    cpdef set_write_buffer_limits(self, high=None, low=None):
        self._set_write_buffer_limits(high, low)
        self._maybe_pause_protocol()
        self._maybe_resume_protocol()

    cpdef get_write_buffer_size(self):
        cdef Py_ssize_t total = self._write_backlog_size
        if self._app_protocol_aiofn:
            total += (<Protocol>self._app_protocol).get_local_write_buffer_size()
        return total

    cpdef is_closing(self):
        return self._closing or self._state in (FLUSHING, SHUTDOWN, UNWRAPPED)

    cpdef is_reading(self):
        return not self.is_closing() and not self._paused

    cpdef pause_reading(self):
        if not self.is_reading():
            return
        self._paused = True
        self._loop.remove_reader(self._sock_fd_obj)

    cpdef resume_reading(self):
        if self._sock is None or self._closing or not self._paused:
            return
        self._paused = False
        self._loop.add_reader(self._sock_fd_obj, self._read_ready)
        if self._state in (WRAPPED, FLUSHING, SHUTDOWN):
            self._loop.call_soon(self._read_ready)

    cpdef close(self):
        if self._is_debug:
            _logger.debug("%r: user called close()", self)
        self._start_shutdown()

    cpdef abort(self):
        self._abort(None)

    def write_eof(self):
        raise NotImplementedError()

    def can_write_eof(self):
        return False

    cdef inline _ensure_writer(self):
        if self._sock is None or self._writer_active:
            return
        self._writer_active = True
        self._loop.add_writer(self._sock_fd_obj, self._write_ready)

    cdef inline _drop_writer(self):
        if self._sock is None or not self._writer_active:
            return
        self._writer_active = False
        self._loop.remove_writer(self._sock_fd_obj)

    cdef inline _set_state(self, TLSState new_state):
        cdef bint allowed = False

        if new_state == UNWRAPPED:
            allowed = True
        elif self._state == UNWRAPPED and new_state == DO_HANDSHAKE:
            allowed = True
        elif self._state == DO_HANDSHAKE and new_state == WRAPPED:
            allowed = True
        elif self._state == WRAPPED and new_state in (FLUSHING, SHUTDOWN, DO_HANDSHAKE):
            allowed = True
        elif self._state == FLUSHING and new_state == SHUTDOWN:
            allowed = True

        if allowed:
            self._state = new_state
        else:
            raise RuntimeError(f'cannot switch state from {self._state} to {new_state}')

    cdef inline _start_handshake(self):
        self._set_state(DO_HANDSHAKE)
        self._handshake_timeout_handle = self._loop.call_later(
            self._ssl_handshake_timeout, self._check_handshake_timeout)
        self._do_handshake()

    cdef inline _check_handshake_timeout(self):
        if self._state == DO_HANDSHAKE:
            self._fatal_error(ConnectionAbortedError(
                f"SSL handshake is taking longer than {self._ssl_handshake_timeout} seconds: aborting the connection"))

    cdef inline _do_handshake(self):
        cdef int rc
        cdef int ssl_error

        while True:
            rc = self._ssl_object.do_handshake()
            if rc == 1:
                self._write_wanted = False
                self._drop_writer()
                self._on_handshake_complete(None)
                return

            ssl_error = self._ssl_object.get_error(rc)
            if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                self._write_wanted = True
                self._ensure_writer()
                return
            if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                self._write_wanted = False
                self._drop_writer()
                return

            self._on_handshake_complete(
                self._ssl_object.make_exc_from_ssl_error("ssl handshake failed", ssl_error))
            return

    cdef inline _on_handshake_complete(self, handshake_exc):
        if self._handshake_timeout_handle is not None:
            self._handshake_timeout_handle.cancel()
            self._handshake_timeout_handle = None

        try:
            if handshake_exc is None:
                self._set_state(WRAPPED)
            else:
                raise handshake_exc
        except Exception as exc:
            self._set_state(UNWRAPPED)
            self._fatal_error(exc, 'SSL handshake failed')
            self._wakeup_waiter(exc)
            return

        self._extra.update(
            peercert=self._ssl_object.getpeercert(),
            cipher=self._ssl_object.cipher(),
            compression=self._ssl_object.compression()
        )
        _logger.info("%r: BIO_get_ktls_send(wbio)=%d", self, self._ssl_object.ktls_send_enabled())
        self._wakeup_waiter()
        if self._app_state == STATE_INIT:
            self._app_state = STATE_CON_MADE
            try:
                self._app_protocol.connection_made(self)
            except (KeyboardInterrupt, SystemExit):
                raise
            except Exception as exc:
                self._fatal_error_no_close(exc, "user connection_made raised an exception")
        self._loop.call_soon(self._read_ready)

    cdef inline _wakeup_waiter(self, exc=None):
        if self._ssl_handshake_complete_waiter is None:
            return
        if not self._ssl_handshake_complete_waiter.done():
            if exc is not None:
                self._ssl_handshake_complete_waiter.set_exception(exc)
            else:
                self._ssl_handshake_complete_waiter.set_result(None)

    cdef inline _start_shutdown(self):
        if self._state in (FLUSHING, SHUTDOWN, UNWRAPPED):
            return
        self._closing = True
        if self._state == DO_HANDSHAKE:
            self._abort(None)
        else:
            self._set_state(FLUSHING)
            self._shutdown_timeout_handle = self._loop.call_later(
                self._ssl_shutdown_timeout, self._check_shutdown_timeout)
            self._do_flush()

    cdef inline _check_shutdown_timeout(self):
        if self._state in (FLUSHING, SHUTDOWN):
            self._abort(asyncio.TimeoutError('SSL shutdown timed out'))

    cdef inline _do_read_into_void(self):
        cdef:
            bytearray buffer = bytearray(16 * 1024)
            size_t bytes_read
            int rc
            int ssl_error

        while True:
            rc = self._ssl_object.read_ex(
                PyByteArray_AS_STRING(buffer),
                PyByteArray_GET_SIZE(buffer),
                &bytes_read)
            if rc == 1:
                self._write_wanted = False
                self._drop_writer()
                continue

            ssl_error = self._ssl_object.get_error(rc)
            if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                self._write_wanted = True
                self._ensure_writer()
                return
            if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                self._write_wanted = False
                self._drop_writer()
                return
            if ssl_error == SSLError.SSL_ERROR_ZERO_RETURN:
                self._call_eof_received()
                return
            raise self._ssl_object.make_exc_from_ssl_error("SSL_read_ex failed", ssl_error)

    cdef inline _do_flush(self):
        try:
            self._do_read_into_void()
            self._flush_write_backlog()
        except Exception as ex:
            self._on_shutdown_complete(ex)
        else:
            if self.get_write_buffer_size() == 0:
                self._set_state(SHUTDOWN)
                self._do_shutdown()

    cdef inline _do_shutdown(self):
        cdef int rc
        cdef int err_code

        try:
            self._do_read_into_void()
            while True:
                rc = self._ssl_object.shutdown()
                if rc == 1:
                    self._write_wanted = False
                    self._drop_writer()
                    self._on_shutdown_complete(None)
                    return
                if rc == 0:
                    self._write_wanted = False
                    self._drop_writer()
                    return

                err_code = self._ssl_object.get_error(rc)
                if err_code == SSLError.SSL_ERROR_WANT_WRITE:
                    self._write_wanted = True
                    self._ensure_writer()
                    return
                if err_code == SSLError.SSL_ERROR_WANT_READ:
                    self._write_wanted = False
                    self._drop_writer()
                    return

                raise self._ssl_object.make_exc_from_ssl_error("SSL_shutdown failed", err_code)
        except Exception as ex:
            self._on_shutdown_complete(ex)

    cdef inline _on_shutdown_complete(self, shutdown_exc):
        if self._shutdown_timeout_handle is not None:
            self._shutdown_timeout_handle.cancel()
            self._shutdown_timeout_handle = None

        if shutdown_exc:
            self._fatal_error(shutdown_exc, 'Error occurred during shutdown')
        else:
            self._force_close(None)

    cdef inline _abort(self, exc):
        if self._state != UNWRAPPED:
            self._set_state(UNWRAPPED)
        self._force_close(exc)

    def _read_ready(self):
        if self._conn_lost or self._sock is None:
            return
        if self._state == DO_HANDSHAKE:
            self._do_handshake()
        elif self._state == WRAPPED:
            self._do_read()
        elif self._state == FLUSHING:
            self._do_flush()
        elif self._state == SHUTDOWN:
            self._do_shutdown()

    def _write_ready(self):
        if self._conn_lost or self._sock is None:
            return
        if self._state == DO_HANDSHAKE:
            self._do_handshake()
        elif self._state == WRAPPED:
            if self._write_backlog:
                self._flush_write_backlog()
            else:
                self._do_read()
        elif self._state == FLUSHING:
            self._do_flush()
        elif self._state == SHUTDOWN:
            self._do_shutdown()

        if not self._write_wanted and not self._write_backlog:
            self._drop_writer()

    cpdef write(self, data):
        if not self._is_protocol_ready():
            return
        aiofn_validate_buffer(data)

        cdef char* data_ptr
        cdef Py_ssize_t data_len

        try:
            if self._write_backlog:
                if data:
                    self._write_backlog.append(aiofn_maybe_copy_buffer(data))
                    self._write_backlog_size += len(data)
                    self._maybe_pause_protocol()
                return

            aiofn_unpack_buffer(data, &data_ptr, &data_len)
            if data_len == 0:
                return

            tail = self._write_impl(data, data_ptr, data_len)
            if tail is not None:
                self._write_backlog.append(tail)
                self._write_backlog_size += len(tail)
                self._maybe_pause_protocol()
        except BaseException as ex:
            self._fatal_error(ex, 'Fatal error on TLS transport')

    cdef write_c(self, char* data_ptr, Py_ssize_t data_len):
        if not self._is_protocol_ready() or data_len == 0:
            return

        try:
            if self._write_backlog:
                data = PyBytes_FromStringAndSize(data_ptr, data_len)
                self._write_backlog.append(data)
                self._write_backlog_size += len(data)
                self._maybe_pause_protocol()
                return

            tail = self._write_impl(None, data_ptr, data_len)
            if tail is not None:
                self._write_backlog.append(tail)
                self._write_backlog_size += len(tail)
                self._maybe_pause_protocol()
        except BaseException as ex:
            self._fatal_error(ex, 'Fatal error on TLS transport')

    cpdef writelines(self, list_of_data):
        if not self._is_protocol_ready():
            return

        for data in list_of_data:
            aiofn_validate_buffer(data)

        cdef char* data_ptr
        cdef Py_ssize_t data_len
        cdef bint add_to_backlog = False
        cdef Py_ssize_t idx

        try:
            if self._write_backlog:
                for data in list_of_data:
                    if data:
                        data = aiofn_maybe_copy_buffer(data)
                        self._write_backlog.append(data)
                        self._write_backlog_size += len(data)
                self._maybe_pause_protocol()
                return

            for idx in range(len(list_of_data)):
                data = list_of_data[idx]
                if add_to_backlog:
                    if len(data) > 0:
                        data = aiofn_maybe_copy_buffer(data)
                        self._write_backlog.append(data)
                        self._write_backlog_size += len(data)
                    continue

                aiofn_unpack_buffer(data, &data_ptr, &data_len)
                if data_len == 0:
                    continue

                tail = self._write_impl(data, data_ptr, data_len)
                if tail is not None:
                    self._write_backlog.append(tail)
                    self._write_backlog_size += len(tail)
                    add_to_backlog = True

            self._maybe_pause_protocol()
        except BaseException as ex:
            self._fatal_error(ex, 'Fatal error on TLS transport')

    cdef inline _flush_write_backlog(self):
        cdef char* data_ptr
        cdef Py_ssize_t data_len
        cdef Py_ssize_t idx = 0
        cdef Py_ssize_t items_completed = 0

        if self._state not in (WRAPPED, FLUSHING) or not self._write_backlog:
            return

        for idx in range(len(self._write_backlog)):
            data = self._write_backlog[idx]
            aiofn_unpack_buffer(data, &data_ptr, &data_len)
            tail = self._write_impl(data, data_ptr, data_len)
            if tail is not None:
                self._write_backlog_size -= len(data)
                self._write_backlog[idx] = tail
                self._write_backlog_size += len(tail)
                break
            items_completed += 1
            self._write_backlog_size -= len(data)

        if items_completed > 0:
            del self._write_backlog[:items_completed]
        self._maybe_resume_protocol()

    cdef inline _write_impl(self, data, char* data_ptr, Py_ssize_t data_len):
        cdef size_t bytes_written
        cdef int rc
        cdef int ssl_error

        while data_len != 0:
            rc = self._ssl_object.write_ex(data_ptr, data_len, &bytes_written)
            if rc:
                if self._is_debug:
                    _logger.debug("%r: SSL_write_ex(..., %d, %d) = %d", self,
                                  data_len, bytes_written, rc)

                self._write_wanted = False
                if data_len == <Py_ssize_t>bytes_written:
                    self._drop_writer()
                    return None
                data_ptr += bytes_written
                data_len -= bytes_written
                continue

            ssl_error = self._ssl_object.get_error(rc)
            if self._is_debug:
                _logger.debug("%r: SSL_write_ex(..., %d, %d)=%d, %s",
                              self, data_len, bytes_written, rc,
                              ssl_error_name(ssl_error))

            if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                self._write_wanted = True
                self._ensure_writer()
                return aiofn_maybe_copy_buffer_tail(data, data_ptr, data_len)
            if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                self._write_wanted = False
                self._drop_writer()
                return aiofn_maybe_copy_buffer_tail(data, data_ptr, data_len)

            raise self._ssl_object.make_exc_from_ssl_error("SSL_write_ex failed", ssl_error)

        self._write_wanted = False
        self._drop_writer()
        return None

    cpdef _do_read(self):
        if self._state not in (WRAPPED, FLUSHING):
            return
        try:
            if not self._paused:
                if self._app_protocol_is_buffered:
                    self._do_read__buffered()
                else:
                    self._do_read__copied()
                if self._write_backlog:
                    self._flush_write_backlog()
        except Exception as ex:
            self._fatal_error(ex, 'Fatal error on TLS transport')

    cdef inline _do_read__buffered(self):
        cdef char* buf_ptr
        cdef Py_ssize_t buf_len
        cdef size_t last_bytes_read = 0
        cdef Py_ssize_t total_bytes_read = 0
        cdef int rc = 0

        if self._app_protocol_aiofn:
            app_buffer = (<Protocol>self._app_protocol).get_buffer_c(-1, &buf_ptr, &buf_len)
        else:
            app_buffer = self._app_protocol.get_buffer(-1)
            aiofn_unpack_buffer(app_buffer, &buf_ptr, &buf_len)

        if buf_len == 0:
            raise RuntimeError('get_buffer() returned an empty buffer')

        while buf_len > 0:
            rc = self._ssl_object.read_ex(buf_ptr, buf_len, &last_bytes_read)
            if not rc:
                break
            self._write_wanted = False
            buf_ptr += last_bytes_read
            buf_len -= last_bytes_read
            total_bytes_read += last_bytes_read
            if self._is_debug:
                _logger.debug("%r: SSL_read_ex(buf_len=%d, bytes_read=%d)=%d",
                              self, buf_len, last_bytes_read, rc)

        cdef int last_error = self._ssl_object.get_error(rc)
        if self._is_debug:
            _logger.debug("%r: SSL_read_ex(buf_len=%d, bytes_read=%d)=%d, %s",
                          self, buf_len, last_bytes_read, rc,
                          ssl_error_name(last_error))

        if total_bytes_read > 0:
            if self._app_protocol_aiofn:
                (<Protocol>self._app_protocol).buffer_updated(total_bytes_read)
            else:
                self._app_protocol.buffer_updated(total_bytes_read)

        if buf_len == 0:
            self._loop.call_soon(self._read_ready)
            return

        self._post_read(last_error)

    cdef inline _do_read__copied(self):
        cdef size_t bytes_read = 0
        cdef list data = None
        cdef char* bytes_buffer_ptr
        cdef bytes first_chunk = None, curr_chunk
        cdef Py_ssize_t bytes_estimated
        cdef int rc = 0
        cdef object bytes_obj

        while True:
            bytes_estimated = max(1024, self._ssl_object.pending() + 256)
            bytes_obj = PyBytes_FromStringAndSize(NULL, bytes_estimated)
            bytes_buffer_ptr = PyBytes_AS_STRING(bytes_obj)
            rc = self._ssl_object.read_ex(bytes_buffer_ptr, bytes_estimated, &bytes_read)
            if not rc:
                curr_chunk = bytes_obj[:0]
                break

            if self._is_debug:
                _logger.debug("%r: SSL_read_ex(buf_len=%d, bytes_read=%d)=%d",
                              self, bytes_estimated, bytes_read, rc)

            self._write_wanted = False
            curr_chunk = bytes_obj[:bytes_read]
            if first_chunk is None:
                first_chunk = curr_chunk
            elif data is None:
                data = [first_chunk, curr_chunk]
            else:
                data.append(curr_chunk)

        cdef int last_error = self._ssl_object.get_error(rc)
        if self._is_debug:
            _logger.debug("%r: SSL_read_ex(buf_len=%d, bytes_read=%d)=%d, %s",
                          self, bytes_estimated, bytes_read, rc,
                          ssl_error_name(last_error))

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

        self._post_read(last_error)

    cdef inline _post_read(self, int last_error):
        if last_error == SSLError.SSL_ERROR_WANT_READ:
            self._write_wanted = False
            self._drop_writer()
            return
        if last_error == SSLError.SSL_ERROR_WANT_WRITE:
            self._write_wanted = True
            self._ensure_writer()
            return
        if last_error == SSLError.SSL_ERROR_ZERO_RETURN:
            if self._ssl_object.get_shutdown() & SSL_RECEIVED_SHUTDOWN:
                self._call_eof_received()
                self._start_shutdown()
                return
        raise self._ssl_object.make_exc_from_ssl_error("SSL_read_ex failed", last_error)

    cdef inline _call_eof_received(self):
        if self._app_state == STATE_CON_MADE:
            self._app_state = STATE_EOF
            try:
                keep_open = self._app_protocol.eof_received()
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as ex:
                self._fatal_error(ex, 'Error calling eof_received()')
            else:
                if keep_open:
                    _logger.warning('returning true from eof_received() has no effect when using ssl')

    cpdef _call_connection_lost(self, exc):
        try:
            if self._protocol_connected and self._app_state in (STATE_CON_MADE, STATE_EOF):
                self._app_state = STATE_CON_LOST
                self._app_protocol.connection_lost(exc)
        finally:
            if self._sock is not None:
                self._sock.close()
            self._sock = None
            self._ssl_object = None
            self._app_protocol = None
            self._loop = None
            server = self._server
            if server is not None:
                server._detach(self)
                self._server = None

    def _force_close(self, exc):
        if self._sock is None:
            return
        self._closing = True
        self._conn_lost += 1
        self._drop_writer()
        self._loop.remove_reader(self._sock_fd_obj)
        self._loop.call_soon(self._call_connection_lost, exc)

    cdef inline bint _is_protocol_ready(self) except -1:
        if self._state in (FLUSHING, SHUTDOWN, UNWRAPPED):
            if self._conn_lost >= constants.LOG_THRESHOLD_FOR_CONNLOST_WRITES:
                _logger.warning('SSL connection is closed')
            self._conn_lost += 1
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

    cdef inline _maybe_pause_protocol(self):
        cdef Py_ssize_t size = self.get_write_buffer_size()
        if size <= self._high_water:
            return
        if not self._protocol_paused:
            self._protocol_paused = True
            try:
                self._app_protocol.pause_writing()
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.pause_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self._app_protocol,
                })

    cdef inline _maybe_resume_protocol(self):
        if self._protocol_paused and self.get_write_buffer_size() <= self._low_water:
            self._protocol_paused = False
            try:
                self._app_protocol.resume_writing()
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.resume_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self._app_protocol,
                })

    cdef inline _set_write_buffer_limits(self, high=None, low=None):
        if high is None:
            if low is None:
                high = 64 * 1024
            else:
                high = 4 * low
        if low is None:
            low = high // 4

        if not high >= low >= 0:
            raise ValueError(f'high ({high!r}) must be >= low ({low!r}) must be >= 0')
        self._high_water = high
        self._low_water = low
