import logging
import socket
import warnings

from asyncio.trsock import TransportSocket
from libc.stdint cimport int64_t

from . import constants
from .loop_backend cimport (
    AIOFN_LOOP_OK,
    aiofn_loop_buffer_init,
    aiofn_loop_buffer_t,
    aiofn_loop_file_handle_t,
    aiofn_loop_proactor_op_t,
    aiofn_loop_status,
    sockaddr,
)
from .loop_base cimport ProactorContext, ProactorSocket
from .transport cimport (
    DatagramTransport,
    SendFileRequest,
    StreamTransport,
    WritableTransport,
    WriteRequest,
)
from .utils cimport (
    NoResult,
    aiofn_allocate_bytes,
    aiofn_finalize_bytes,
    aiofn_pyaddr_to_sockaddr,
    aiofn_sendto,
    aiofn_set_nodelay,
    aiofn_set_socket_extra_info,
    aiofn_sockaddr_to_pyaddr,
    aiofn_unpack_simple_buffer,
    unlikely,
)

from .utils import aiofn_set_result_unless_cancelled

from cpython.object cimport PyObject
from cpython.ref cimport Py_XDECREF


cdef:
    object _logger = logging.getLogger("asyncio")
    Py_ssize_t _data_received_max_size = constants.DATA_RECEIVED_MAX_SIZE
    Py_ssize_t _datagram_received_max_size = constants.DATAGRAM_RECEIVED_MAX_SIZE


cdef class ProactorSocketTransport(StreamTransport):
    """Stream transport driven directly by a LoopBase proactor backend."""

    cdef:
        ProactorSocket _proactor_socket
        object _file
        int _fileno
        object _server

        object _read_buffer
        PyObject *_read_bytes

        size_t _write_submitted_size
        aiofn_loop_proactor_op_t _write_op
        aiofn_loop_buffer_t _write_buffers[256]

        object _close_exc
        public bint _sendfile_compatible

    def __init__(self, ProactorContext context, loop, sock, protocol, waiter=None, server=None):
        aiofn_set_nodelay(sock)
        sock.setblocking(False)

        self._file = sock
        self._fileno = sock.fileno()
        self._server = server

        StreamTransport.__init__(self, loop, self._fileno, True)
        self._set_protocol(protocol)

        self._read_buffer = None
        self._read_bytes = NULL
        # The scheduled initializer starts reading and then delivers connection_made().
        self._read_paused = True

        self._write_submitted_size = 0
        self._write_op.callback = _write_callback_trampoline
        self._write_op.callback_data = <void *>self
        self._write_op.backend_token = NULL
        self._write_op.status = AIOFN_LOOP_OK
        self._write_op.transferred = 0

        self._close_exc = None
        self._sendfile_compatible = context.proactor.sendfile != NULL

        self._extra['socket'] = TransportSocket(sock)
        aiofn_set_socket_extra_info(self._extra, sock)

        self._proactor_socket = context.wrap_socket(sock)
        assert self._proactor_socket.owner is None
        self._proactor_socket.owner = self

        self._loop.call_soon((<object>self)._initialize)
        if waiter is not None:
            self._loop.call_soon(aiofn_set_result_unless_cancelled, waiter, None)

    def __repr__(self):
        info = [f'fd={self._fileno}', self.__class__.__name__]
        if self._file is None:
            info.append('closed')
        elif self._closing:
            info.append('closing')
        info.append(f'wbuf_size={self._write_backlog_size}')
        return '[{}]'.format(' '.join(info))

    def __del__(self):
        if self._file is not None:
            warnings.warn(f"unclosed {self.__class__.__name__} for {self._file}", ResourceWarning, source=self)
            self._file.close()

    def __dealloc__(self):
        Py_XDECREF(self._read_bytes)
        self._read_bytes = NULL

    cpdef _initialize(self):
        if self._closing:
            return
        try:
            self.resume_reading()
        except:
            self._handle_error('Fatal read error on proactor socket transport')
            return

        self._call_protocol_connection_made()

    cdef NoResult _start_reading(self) except NoResult.EXC:
        self._proactor_socket.context.check_status(self._proactor_socket.context.proactor.read_start(
            self._proactor_socket.context.backend.state,
            &self._proactor_socket.backend_sock,
            _read_alloc_trampoline,
            _read_callback_trampoline,
            <void *>self,
        ))

    cdef NoResult _stop_reading(self) except NoResult.EXC:
        self._proactor_socket.context.check_status(self._proactor_socket.context.proactor.read_stop(
            self._proactor_socket.context.backend.state,
            &self._proactor_socket.backend_sock,
        ))
        self._release_read_buffer()

    cdef NoResult _allocate_read_buffer(self, void **buffer, size_t *buffer_len) except NoResult.EXC:
        cdef:
            char *data
            Py_ssize_t data_len

        # libuv may invoke its allocation callback for an EAGAIN read without
        # subsequently invoking the read callback. Release that unused buffer
        # before supplying the next one.
        self._release_read_buffer()

        if self._protocol_buffered:
            self._read_buffer = self._call_protocol_get_buffer(&data, &data_len)
        else:
            self._read_bytes = aiofn_allocate_bytes(_data_received_max_size, &data)
            data_len = _data_received_max_size

        buffer[0] = data
        buffer_len[0] = <size_t>data_len
        return NoResult.OK

    cdef inline void _release_read_buffer(self) noexcept:
        Py_XDECREF(self._read_bytes)
        self._read_bytes = NULL
        self._read_buffer = None

    cdef NoResult _read_completed(self, aiofn_loop_status status, size_t bytes_read) except NoResult.EXC:
        cdef:
            PyObject *bytes_obj
            object buffer
            object data
            object keep_open

        if status != AIOFN_LOOP_OK:
            self._release_read_buffer()
            self._proactor_socket.context.check_status(status)

        if bytes_read == 0:
            self._release_read_buffer()
            keep_open = self._call_protocol_eof_received()
            if keep_open:
                self.pause_reading()
            else:
                self.close()
            return NoResult.OK

        if self._read_bytes == NULL:
            buffer = self._read_buffer
            self._read_buffer = None
            self._call_protocol_buffer_updated(<Py_ssize_t>bytes_read)
        else:
            bytes_obj = self._read_bytes
            self._read_bytes = NULL
            data = aiofn_finalize_bytes(bytes_obj, <Py_ssize_t>bytes_read)
            self._call_protocol_data_received(data)
        return NoResult.OK

    def sendfile(self, file, offset, count):
        self._check_thread("sendfile")

        # Some third-party tests use this private asyncio flag to disable the
        # native path and exercise their fallback implementation.
        if not self._sendfile_compatible:
            raise NotImplementedError()

        return self._sendfile(file, offset, count)

    cpdef can_write_eof(self):
        return True

    cpdef write_eof(self):
        self._check_thread("write_eof")
        if self._closing or self._write_eof:
            return
        self._write_eof = True
        if self._write_backlog_size == 0:
            self._write_eof_now()

    cdef NoResult _write_eof_now(self) except NoResult.EXC:
        self._file.shutdown(socket.SHUT_WR)
        if unlikely(self._is_debug):
            _logger.debug("%r: shutdown(SHUT_WR) done", self)
        return NoResult.OK

    cpdef close(self):
        self._check_thread("close")
        if self._closing:
            return

        self.pause_reading()
        self._closing = True
        if self._write_backlog_size == 0:
            assert self._write_submitted_size == 0
            self._finalizing_close = True
            self._schedule_finalize_close()

    cpdef _force_close(self, exc):
        if self._finalizing_close:
            return

        self.pause_reading()
        self._closing = True
        self._finalizing_close = True
        self._close_exc = exc

        if self._write_submitted_size == 0:
            self._clear_write_backlog(exc)
            self._schedule_finalize_close()

    cdef inline NoResult _schedule_finalize_close(self) except NoResult.EXC:
        self._loop.call_soon((<object>self)._finalize_close, self._close_exc)

    def _finalize_close(self, exc):
        cdef:
            object server

        assert self._read_paused
        assert self._write_submitted_size == 0
        try:
            self._call_protocol_connection_lost(exc)
        finally:
            server = self._server
            try:
                self._proactor_socket.context.unwrap_socket(self._proactor_socket)
            finally:
                self._proactor_socket.owner = None
                self._proactor_socket = None
                if self._file is not None:
                    self._file.close()
                    self._file = None
                self._protocol = None
                self._close_exc = None
                if server is not None:
                    server._detach(self)
                    self._server = None

    cdef NoResult _ensure_progress(self) except NoResult.EXC:
        if self._write_submitted_size == 0:
            if isinstance(self._write_backlog[0], SendFileRequest):
                self._submit_sendfile()
            else:
                self._submit_write()
        return NoResult.OK

    cdef bint _try_sendfile(self, SendFileRequest request) except -1:
        return False

    cdef NoResult _submit_write(self) except NoResult.EXC:
        cdef:
            WriteRequest request
            size_t buffer_count = 0
            size_t submitted_size = 0

        assert self._write_submitted_size == 0
        assert self._write_backlog_size > 0

        for request_obj in self._write_backlog:
            if isinstance(request_obj, SendFileRequest):
                break

            assert isinstance(request_obj, WriteRequest)
            request = <WriteRequest>request_obj
            aiofn_loop_buffer_init(&self._write_buffers[buffer_count], request.ptr, <size_t>request.size)
            submitted_size += <size_t>request.size
            buffer_count += 1
            if buffer_count == 256:
                break

        self._write_submitted_size = submitted_size
        self._write_op.backend_token = NULL
        self._write_op.status = AIOFN_LOOP_OK
        self._write_op.transferred = 0
        try:
            if unlikely(self._is_debug):
                if buffer_count == 1:
                    _logger.debug("%r: async_write(..., len=%d)", self, submitted_size)
                else:
                    _logger.debug(
                        "%r: async_writev(..., len(iovecs)=%d, len=%d)",
                        self,
                        buffer_count,
                        submitted_size,
                    )

            self._proactor_socket.context.check_status(
                self._proactor_socket.context.proactor.write(
                    self._proactor_socket.context.backend.state,
                    &self._proactor_socket.backend_sock,
                    &self._write_op,
                    &self._write_buffers[0],
                    buffer_count,
                ))
        except BaseException:
            self._write_submitted_size = 0
            raise
        return NoResult.OK

    cdef NoResult _submit_sendfile(self) except NoResult.EXC:
        cdef SendFileRequest request = <SendFileRequest>self._write_backlog[0]

        assert self._write_submitted_size == 0
        assert request.count > 0

        self._write_submitted_size = <size_t>request.count
        self._write_op.backend_token = NULL
        self._write_op.status = AIOFN_LOOP_OK
        self._write_op.transferred = 0
        try:
            if unlikely(self._is_debug):
                _logger.debug("%r: async_sendfile(offset=%d, count=%d)", self, request.offset, request.count)

            self._proactor_socket.context.check_status(
                self._proactor_socket.context.proactor.sendfile(
                    self._proactor_socket.context.backend.state,
                    &self._proactor_socket.backend_sock,
                    &self._write_op,
                    <aiofn_loop_file_handle_t>request.native_handle,
                    request.offset,
                    <size_t>request.count,
                ))
        except BaseException:
            self._write_submitted_size = 0
            raise
        return NoResult.OK

    cdef NoResult _write_completed(self, aiofn_loop_status status, size_t bytes_sent) except NoResult.EXC:
        cdef:
            SendFileRequest sendfile_request

        assert self._write_submitted_size > 0

        if unlikely(self._is_debug):
            _logger.debug("%r: write_completed(error_code=%d, transferred=%d)", self, status, bytes_sent)

        if self._finalizing_close:
            self._write_submitted_size = 0
            self._clear_write_backlog(self._close_exc)
            self._schedule_finalize_close()
            return NoResult.OK

        if status != AIOFN_LOOP_OK:
            self._write_submitted_size = 0
            self._proactor_socket.context.check_status(status)

        assert bytes_sent <= self._write_submitted_size

        if isinstance(self._write_backlog[0], SendFileRequest):
            sendfile_request = <SendFileRequest>self._write_backlog[0]
            if bytes_sent == 0:
                self._write_backlog_size -= sendfile_request.count
                sendfile_request.count = 0
            else:
                sendfile_request.offset += <int64_t>bytes_sent
                sendfile_request.count -= <Py_ssize_t>bytes_sent
                self._write_backlog_size -= <Py_ssize_t>bytes_sent

            if sendfile_request.count == 0:
                self._write_backlog.popleft()
                if not sendfile_request.waiter.done():
                    sendfile_request.waiter.set_result(None)
        else:
            assert bytes_sent > 0
            self._consume_write_backlog(<Py_ssize_t>bytes_sent)

        self._write_submitted_size = 0

        if self._write_backlog_size > 0:
            self._ensure_progress()

        self._maybe_resume_protocol()
        if self._write_backlog_size == 0:
            if self._closing:
                self._finalizing_close = True
                self._schedule_finalize_close()
            elif self._write_eof:
                self._write_eof_now()
        return NoResult.OK

    cdef NoResult _clear_write_backlog(self, object exc) except NoResult.EXC:
        assert self._write_submitted_size == 0
        WritableTransport._clear_write_backlog(self, exc)
        return NoResult.OK


cdef class ProactorDatagramTransport(DatagramTransport):
    """Datagram transport driven directly by a LoopBase proactor backend."""

    cdef:
        ProactorSocket _proactor_socket
        object _file
        int _fileno
        int _family
        bint _has_connection

        PyObject *_read_bytes

        bint _send_pending
        aiofn_loop_proactor_op_t _send_op

        object _close_exc

    def __init__(self, ProactorContext context, loop, sock, protocol, address, waiter=None):
        sock.setblocking(False)

        self._file = sock
        self._fileno = sock.fileno()
        self._family = sock.family

        DatagramTransport.__init__(self, loop, address, 8)
        self._set_protocol(protocol)

        self._read_bytes = NULL
        # The scheduled initializer starts receiving and then delivers connection_made().
        self._read_paused = True

        self._extra['socket'] = TransportSocket(sock)
        aiofn_set_socket_extra_info(self._extra, sock)

        self._has_connection = self._extra['peername'] is not None
        self._send_pending = False
        self._send_op.callback = _sendto_callback_trampoline
        self._send_op.callback_data = <void *>self
        self._send_op.backend_token = NULL
        self._send_op.status = AIOFN_LOOP_OK
        self._send_op.transferred = 0

        self._close_exc = None

        self._proactor_socket = context.wrap_socket(sock)
        assert self._proactor_socket.owner is None
        self._proactor_socket.owner = self

        self._loop.call_soon((<object>self)._initialize)
        if waiter is not None:
            self._loop.call_soon(aiofn_set_result_unless_cancelled, waiter, None)

    def __repr__(self):
        info = [f'fd={self._fileno}', self.__class__.__name__]
        if self._file is None:
            info.append('closed')
        elif self._closing:
            info.append('closing')
        info.append(f'wbuf_size={self._write_backlog_size}')
        return '[{}]'.format(' '.join(info))

    def __del__(self):
        if self._file is not None:
            warnings.warn(f"unclosed {self.__class__.__name__} for {self._file}", ResourceWarning, source=self)
            self._file.close()

    def __dealloc__(self):
        Py_XDECREF(self._read_bytes)
        self._read_bytes = NULL

    cpdef _initialize(self):
        if self._closing:
            return
        try:
            self.resume_reading()
        except:
            self._handle_error('Fatal read error on proactor datagram transport')
            return

        self._call_protocol_connection_made()

    cdef NoResult _start_reading(self) except NoResult.EXC:
        self._proactor_socket.context.check_status(self._proactor_socket.context.proactor.recvfrom_start(
            self._proactor_socket.context.backend.state,
            &self._proactor_socket.backend_sock,
            _recvfrom_alloc_trampoline,
            _recvfrom_callback_trampoline,
            <void *>self,
        ))

    cdef NoResult _stop_reading(self) except NoResult.EXC:
        self._proactor_socket.context.check_status(self._proactor_socket.context.proactor.recvfrom_stop(
            self._proactor_socket.context.backend.state,
            &self._proactor_socket.backend_sock,
        ))
        self._release_read_buffer()

    cdef NoResult _allocate_read_buffer(self, void **buffer, size_t *buffer_len) except NoResult.EXC:
        cdef char *data

        # libuv may request a buffer for an EAGAIN read without delivering a
        # receive callback. Release that unused buffer before supplying another.
        self._release_read_buffer()

        self._read_bytes = aiofn_allocate_bytes(_datagram_received_max_size, &data)
        buffer[0] = data
        buffer_len[0] = <size_t>_datagram_received_max_size
        return NoResult.OK

    cdef inline void _release_read_buffer(self) noexcept:
        Py_XDECREF(self._read_bytes)
        self._read_bytes = NULL

    cdef NoResult _recvfrom_completed(
        self,
        aiofn_loop_status status,
        size_t bytes_read,
        const sockaddr *address,
    ) except NoResult.EXC:
        cdef:
            PyObject *bytes_obj
            object data
            object py_address

        if status != AIOFN_LOOP_OK:
            self._release_read_buffer()
            try:
                self._proactor_socket.context.check_status(status)
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as exc:
                self._call_protocol_error_received(exc)
            return NoResult.OK

        assert self._read_bytes != NULL
        assert address != NULL

        bytes_obj = self._read_bytes
        self._read_bytes = NULL
        data = aiofn_finalize_bytes(bytes_obj, <Py_ssize_t>bytes_read)

        # Proactor datagram transports currently wrap only INET sockets, whose
        # conversion does not require a sockaddr length.
        py_address = aiofn_sockaddr_to_pyaddr(<void *>address, 0)
        self._call_protocol_datagram_received(data, py_address)
        return NoResult.OK

    cpdef can_write_eof(self):
        return False

    cpdef write_eof(self):
        raise NotImplementedError()

    cpdef close(self):
        self._check_thread("close")
        if self._closing:
            return

        self.pause_reading()
        self._closing = True
        if self._write_backlog_size == 0:
            assert not self._send_pending
            self._finalizing_close = True
            self._schedule_finalize_close()

    cpdef _force_close(self, exc):
        if self._finalizing_close:
            return

        self.pause_reading()
        self._closing = True
        self._finalizing_close = True
        self._close_exc = exc

        if not self._send_pending:
            self._clear_write_backlog(exc)
            self._schedule_finalize_close()

    cdef inline NoResult _schedule_finalize_close(self) except NoResult.EXC:
        self._loop.call_soon((<object>self)._finalize_close, self._close_exc)

    def _finalize_close(self, exc):
        assert self._read_paused
        assert not self._send_pending
        try:
            self._call_protocol_connection_lost(exc)
        finally:
            try:
                self._proactor_socket.context.unwrap_socket(self._proactor_socket)
            finally:
                self._proactor_socket.owner = None
                self._proactor_socket = None
                if self._file is not None:
                    self._file.close()
                    self._file = None
                self._protocol = None
                self._close_exc = None

    cdef object _validate_address(self, object addr):
        cdef:
            char raw_address[256]
            unsigned int raw_address_len = 0

        if not self._has_connection:
            # Endpoint creation resolves INET addresses; resolving here would
            # block the event-loop thread.
            aiofn_pyaddr_to_sockaddr(self._family, addr, raw_address, &raw_address_len)
        return addr

    cdef bint _try_sendto(self, object data, object addr) except -1:
        cdef:
            char *buffer
            Py_ssize_t buffer_len
            Py_ssize_t bytes_sent
            char raw_address[256]
            unsigned int raw_address_len = 0
            void *raw_address_ptr = NULL

        try:
            aiofn_unpack_simple_buffer(data, &buffer, &buffer_len, 0)
            if not self._has_connection:
                aiofn_pyaddr_to_sockaddr(self._family, addr, raw_address, &raw_address_len)
                raw_address_ptr = raw_address

            bytes_sent = aiofn_sendto(self._fileno, buffer, buffer_len, raw_address_ptr, raw_address_len)
            if unlikely(self._is_debug):
                _logger.debug("%r: aiofn_sendto(...,len=%d)=%d", self, buffer_len, bytes_sent)
            if bytes_sent == -1:
                return False

            return True
        except (BlockingIOError, InterruptedError):
            return False
        except OSError as exc:
            self._call_protocol_error_received(exc)
            return True

    cdef NoResult _ensure_progress(self) except NoResult.EXC:
        if not self._send_pending:
            self._submit_sendto()
        return NoResult.OK

    cdef NoResult _submit_sendto(self) except NoResult.EXC:
        cdef:
            object data
            object address
            char *buffer
            Py_ssize_t buffer_len
            char raw_address[256]
            unsigned int raw_address_len = 0
            void *raw_address_ptr = NULL

        assert self._write_backlog_size > 0
        assert not self._send_pending

        data, address = self._write_backlog[0]
        aiofn_unpack_simple_buffer(data, &buffer, &buffer_len, 0)
        if not self._has_connection:
            aiofn_pyaddr_to_sockaddr(self._family, address, raw_address, &raw_address_len)
            raw_address_ptr = raw_address

        self._send_pending = True
        self._send_op.backend_token = NULL
        self._send_op.status = AIOFN_LOOP_OK
        self._send_op.transferred = 0
        try:
            if unlikely(self._is_debug):
                _logger.debug("%r: async_sendto(..., len=%d)", self, buffer_len)

            self._proactor_socket.context.check_status(
                self._proactor_socket.context.proactor.sendto(
                    self._proactor_socket.context.backend.state,
                    &self._proactor_socket.backend_sock,
                    &self._send_op,
                    buffer,
                    <size_t>buffer_len,
                    raw_address_ptr,
                    raw_address_len,
                ))
        except BaseException:
            self._send_pending = False
            raise
        return NoResult.OK

    cdef NoResult _sendto_completed(self, aiofn_loop_status status, size_t bytes_sent) except NoResult.EXC:
        cdef:
            object data
            object address
            object send_error = None

        assert self._send_pending
        assert self._write_backlog_size > 0

        if unlikely(self._is_debug):
            _logger.debug("%r: sendto_completed(error_code=%d, transferred=%d)", self, status, bytes_sent)

        if self._finalizing_close:
            self._send_pending = False
            self._clear_write_backlog(self._close_exc)
            self._schedule_finalize_close()
            return NoResult.OK

        if status != AIOFN_LOOP_OK:
            try:
                self._proactor_socket.context.check_status(status)
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as exc:
                send_error = exc

        data, address = self._write_backlog.popleft()
        self._write_backlog_size -= len(data) + self._datagram_header_size
        self._send_pending = False

        if send_error is None:
            assert bytes_sent == <size_t>len(data)
        else:
            self._call_protocol_error_received(send_error)

        if self._finalizing_close:
            self._clear_write_backlog(self._close_exc)
            return NoResult.OK

        if self._write_backlog_size > 0:
            self._ensure_progress()

        self._maybe_resume_protocol()
        if self._write_backlog_size == 0 and self._closing:
            self._finalizing_close = True
            self._schedule_finalize_close()
        return NoResult.OK

    cdef NoResult _clear_write_backlog(self, object exc) except NoResult.EXC:
        assert not self._send_pending
        WritableTransport._clear_write_backlog(self, exc)
        return NoResult.OK


cdef void _recvfrom_alloc_trampoline(
    void *callback_data,
    size_t suggested_size,
    void **buffer,
    size_t *buffer_len,
) noexcept with gil:
    cdef ProactorDatagramTransport transport = <ProactorDatagramTransport>callback_data
    try:
        transport._allocate_read_buffer(buffer, buffer_len)
    except BaseException:
        buffer[0] = NULL
        buffer_len[0] = 0
        try:
            transport._handle_error('Fatal read buffer allocation error on proactor datagram transport')
        except BaseException as exc:
            transport._proactor_socket.context.backend_failed(exc)


cdef void _recvfrom_callback_trampoline(
    void *callback_data,
    aiofn_loop_status status,
    void *buffer,
    size_t bytes_read,
    const sockaddr *address,
) noexcept with gil:
    cdef ProactorDatagramTransport transport = <ProactorDatagramTransport>callback_data
    try:
        transport._recvfrom_completed(status, bytes_read, address)
    except BaseException:
        try:
            transport._handle_error('Fatal read error on proactor datagram transport')
        except BaseException as exc:
            transport._proactor_socket.context.backend_failed(exc)


cdef void _sendto_callback_trampoline(aiofn_loop_proactor_op_t *op) noexcept with gil:
    cdef ProactorDatagramTransport transport = <ProactorDatagramTransport>op.callback_data

    try:
        transport._sendto_completed(op.status, op.transferred)
    except BaseException:
        try:
            transport._handle_error('Fatal write error on proactor datagram transport')
        except BaseException as exc:
            transport._proactor_socket.context.backend_failed(exc)


cdef void _read_alloc_trampoline(
    void *callback_data,
    size_t suggested_size,
    void **buffer,
    size_t *buffer_len,
) noexcept with gil:
    cdef ProactorSocketTransport transport = <ProactorSocketTransport>callback_data
    try:
        transport._allocate_read_buffer(buffer, buffer_len)
    except BaseException:
        buffer[0] = NULL
        buffer_len[0] = 0
        try:
            transport._handle_error('Fatal read buffer allocation error on proactor socket transport')
        except BaseException as exc:
            transport._proactor_socket.context.backend_failed(exc)


cdef void _read_callback_trampoline(
    void *callback_data,
    aiofn_loop_status status,
    void *buffer,
    size_t bytes_read,
) noexcept with gil:
    cdef ProactorSocketTransport transport = <ProactorSocketTransport>callback_data
    try:
        transport._read_completed(status, bytes_read)
    except BaseException:
        try:
            transport._handle_error('Fatal read error on proactor socket transport')
        except BaseException as exc:
            transport._proactor_socket.context.backend_failed(exc)


cdef void _write_callback_trampoline(aiofn_loop_proactor_op_t *op) noexcept with gil:
    cdef ProactorSocketTransport transport = <ProactorSocketTransport>op.callback_data

    try:
        transport._write_completed(op.status, op.transferred)
    except BaseException:
        try:
            transport._handle_error('Fatal write error on proactor socket transport')
        except BaseException as exc:
            transport._proactor_socket.context.backend_failed(exc)
