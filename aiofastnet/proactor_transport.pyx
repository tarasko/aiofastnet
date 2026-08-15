import logging
import os
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
)
from .loop_base cimport ProactorContext, ProactorSocket
from .transport cimport (
    FlowControlledWriter,
    SendFileRequestBase,
    StreamWriter,
    Transport,
    WriteRequest,
)
from .utils cimport (
    NoResult,
    aiofn_allocate_bytes,
    aiofn_finalize_bytes,
    aiofn_set_nodelay,
    aiofn_set_socket_extra_info,
    unlikely,
)

from .utils import aiofn_set_result_unless_cancelled

from cpython.object cimport PyObject
from cpython.ref cimport Py_XDECREF


cdef:
    object _logger = logging.getLogger("asyncio")
    Py_ssize_t _data_received_max_size = constants.DATA_RECEIVED_MAX_SIZE


cdef class SendFileRequest(SendFileRequestBase):
    """Own one file transfer and its remaining byte range."""

    cdef:
        object file
        aiofn_loop_file_handle_t handle
        int64_t offset
        Py_ssize_t count


cdef SendFileRequest make_sendfile_request(file, offset, count):

    cdef:
        int64_t native_offset = offset
        Py_ssize_t available
        Py_ssize_t native_count
        SendFileRequest request

    if native_offset < 0:
        raise ValueError("offset must be non-negative")

    available = max(0, os.fstat(file.fileno()).st_size - offset)
    if count is None:
        native_count = available
    else:
        if count < 0:
            raise ValueError("count must be non-negative")
        native_count = min(count, available)

    request = <SendFileRequest>SendFileRequest.__new__(SendFileRequest)
    request.file = file
    request.handle = <aiofn_loop_file_handle_t>file.fileno()
    request.offset = native_offset
    request.count = native_count
    request.waiter = None
    return request


cdef class ProactorSocketTransport(Transport):
    """Stream transport driven directly by a LoopBase proactor backend."""

    cdef:
        ProactorSocket _proactor_socket
        object _file
        int _fileno
        object _server

        object _read_buffer
        PyObject *_read_bytes

        StreamWriter _writer

        object _close_exc
        public bint _sendfile_compatible

    def __init__(self, ProactorContext context, loop, sock, protocol, waiter=None, server=None):
        Transport.__init__(self, loop)
        aiofn_set_nodelay(sock)
        sock.setblocking(False)

        self._file = sock
        self._fileno = sock.fileno()
        self._server = server
        self._set_protocol(protocol)

        self._read_buffer = None
        self._read_bytes = NULL
        # The scheduled initializer starts reading and then delivers connection_made().
        self._read_paused = True

        self._writer = ProactorStreamWriter(self, self._fileno, True)

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
        info.append(f'wbuf_size={self._writer.backlog_size}')
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

    cpdef tuple get_write_buffer_limits(self):
        self._check_thread("get_write_buffer_limits")
        return self._writer.get_write_buffer_limits()

    cpdef set_write_buffer_limits(self, high=None, low=None):
        self._check_thread("set_write_buffer_limits")
        self._writer.set_write_buffer_limits(high, low)

    cpdef get_write_buffer_size(self):
        self._check_thread("get_write_buffer_size")
        return self._writer.get_write_buffer_size()

    cpdef write_nocheck(self, data):
        self._writer.write_nocheck(data)

    cpdef writelines_nocheck(self, list_of_data):
        self._writer.writelines_nocheck(list_of_data)

    cdef NoResult write_c(self, char *ptr, Py_ssize_t size) except NoResult.EXC:
        self._writer.write_c(ptr, size)

    def sendfile(self, file, offset, count):
        cdef:
            ProactorStreamWriter writer = <ProactorStreamWriter>self._writer
            SendFileRequest request

        self._check_thread("sendfile")

        # Some third-party tests use this private asyncio flag to disable the
        # native path and exercise their fallback implementation.
        if not self._sendfile_compatible:
            raise NotImplementedError()

        if writer.eof:
            raise RuntimeError('Cannot call sendfile() after write_eof()')
        if self._closing or self._finalizing_close:
            raise RuntimeError("Transport is closing")

        request = make_sendfile_request(file, offset, count)
        if request.count == 0:
            return None

        try:
            if unlikely(self._is_debug):
                _logger.debug("%r: enqueue SendFileRequest(offset=%d,count=%d)", self, request.offset, request.count)

            writer.backlog.append(request)
            writer.backlog_size += request.count
            writer._ensure_progress()
            writer.maybe_pause_protocol()

            # Backend callbacks are never invoked from the initiating call, so
            # the waiter can be allocated after successful submission.
            request.waiter = self._loop.create_future()
            return request.waiter
        except:
            self._handle_error('Fatal sendfile error on proactor socket transport')
            raise

    cpdef can_write_eof(self):
        return True

    cpdef write_eof(self):
        self._check_thread("write_eof")
        if self._closing or self._writer.eof:
            return
        self._writer.eof = True
        if not self._writer.backlog:
            self._write_eof_now()

    cdef NoResult _write_eof_now(self) except NoResult.EXC:
        self._file.shutdown(socket.SHUT_WR)
        if unlikely(self._is_debug):
            _logger.debug("%r: shutdown(SHUT_WR) done", self)
        return NoResult.OK

    cpdef close(self):
        cdef ProactorStreamWriter writer = <ProactorStreamWriter>self._writer

        self._check_thread("close")
        if self._closing:
            return

        self.pause_reading()
        self._closing = True
        if not writer.backlog:
            assert writer.submitted_size == 0
            self._finalizing_close = True
            self._schedule_finalize_close()

    cpdef _force_close(self, exc):
        cdef ProactorStreamWriter writer = <ProactorStreamWriter>self._writer

        if self._finalizing_close:
            return

        self.pause_reading()
        self._closing = True
        self._finalizing_close = True
        self._close_exc = exc

        if writer.submitted_size == 0:
            writer.clear(exc)
            self._schedule_finalize_close()

    cdef inline NoResult _schedule_finalize_close(self) except NoResult.EXC:
        self._loop.call_soon((<object>self)._finalize_close, self._close_exc)

    def _finalize_close(self, exc):
        cdef:
            ProactorStreamWriter writer = <ProactorStreamWriter>self._writer
            object server

        assert self._read_paused
        assert writer.submitted_size == 0
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


cdef class ProactorStreamWriter(StreamWriter):

    cdef:
        size_t submitted_size
        aiofn_loop_proactor_op_t op
        aiofn_loop_buffer_t buffers[256]

    def __init__(self, Transport transport, int fd, bint is_socket):
        StreamWriter.__init__(self, transport, fd, is_socket)

        self.submitted_size = 0
        self.op.callback = _write_callback_trampoline
        self.op.callback_data = <void *>self
        self.op.backend_token = NULL
        self.op.status = AIOFN_LOOP_OK
        self.op.transferred = 0

    cdef NoResult _ensure_progress(self) except NoResult.EXC:
        cdef ProactorSocketTransport transport = <ProactorSocketTransport>self.transport

        if self.submitted_size == 0:
            if isinstance(self.backlog[0], SendFileRequest):
                self._submit_sendfile(transport)
            else:
                self._submit_write(transport)
        return NoResult.OK

    cdef NoResult _submit_write(self, ProactorSocketTransport transport) except NoResult.EXC:
        cdef:
            WriteRequest request
            size_t buffer_count = 0
            size_t submitted_size = 0

        assert self.submitted_size == 0
        assert self.backlog

        for request_obj in self.backlog:
            if isinstance(request_obj, SendFileRequest):
                break

            assert isinstance(request_obj, WriteRequest)
            request = <WriteRequest>request_obj
            aiofn_loop_buffer_init(&self.buffers[buffer_count], request.ptr, <size_t>request.size)
            submitted_size += <size_t>request.size
            buffer_count += 1
            if buffer_count == 256:
                break

        self.submitted_size = submitted_size
        self.op.backend_token = NULL
        self.op.status = AIOFN_LOOP_OK
        self.op.transferred = 0
        try:
            if unlikely(transport._is_debug):
                if buffer_count == 1:
                    _logger.debug("%r: async_write(..., len=%d)", transport, submitted_size)
                else:
                    _logger.debug(
                        "%r: async_writev(..., len(iovecs)=%d, len=%d)",
                        transport,
                        buffer_count,
                        submitted_size,
                    )

            transport._proactor_socket.context.check_status(
                transport._proactor_socket.context.proactor.write(
                    transport._proactor_socket.context.backend.state,
                    &transport._proactor_socket.backend_sock,
                    &self.op,
                    &self.buffers[0],
                    buffer_count,
                ))
        except BaseException:
            self.submitted_size = 0
            raise
        return NoResult.OK

    cdef NoResult _submit_sendfile(self, ProactorSocketTransport transport) except NoResult.EXC:
        cdef SendFileRequest request = <SendFileRequest>self.backlog[0]

        assert self.submitted_size == 0
        assert request.count > 0

        self.submitted_size = <size_t>request.count
        self.op.backend_token = NULL
        self.op.status = AIOFN_LOOP_OK
        self.op.transferred = 0
        try:
            if unlikely(transport._is_debug):
                _logger.debug("%r: async_sendfile(offset=%d, count=%d)", transport, request.offset, request.count)

            transport._proactor_socket.context.check_status(
                transport._proactor_socket.context.proactor.sendfile(
                    transport._proactor_socket.context.backend.state,
                    &transport._proactor_socket.backend_sock,
                    &self.op,
                    request.handle,
                    request.offset,
                    <size_t>request.count,
                ))
        except BaseException:
            self.submitted_size = 0
            raise
        return NoResult.OK

    cdef NoResult _write_completed(self, aiofn_loop_status status, size_t bytes_sent) except NoResult.EXC:
        cdef:
            ProactorSocketTransport transport = <ProactorSocketTransport>self.transport
            SendFileRequest sendfile_request

        assert self.submitted_size > 0

        if unlikely(transport._is_debug):
            _logger.debug("%r: write_completed(error_code=%d, transferred=%d)", transport, status, bytes_sent)

        if transport._finalizing_close:
            self.submitted_size = 0
            self.clear(transport._close_exc)
            transport._schedule_finalize_close()
            return NoResult.OK

        if status != AIOFN_LOOP_OK:
            self.submitted_size = 0
            transport._proactor_socket.context.check_status(status)

        assert bytes_sent <= self.submitted_size

        if isinstance(self.backlog[0], SendFileRequest):
            sendfile_request = <SendFileRequest>self.backlog[0]
            if bytes_sent == 0:
                self.backlog_size -= sendfile_request.count
                sendfile_request.count = 0
            else:
                sendfile_request.offset += <int64_t>bytes_sent
                sendfile_request.count -= <Py_ssize_t>bytes_sent
                self.backlog_size -= <Py_ssize_t>bytes_sent

            if sendfile_request.count == 0:
                self.backlog.popleft()
                if not sendfile_request.waiter.done():
                    sendfile_request.waiter.set_result(None)
        else:
            assert bytes_sent > 0
            self.consume(<Py_ssize_t>bytes_sent)

        self.submitted_size = 0

        if self.backlog:
            self._ensure_progress()

        self.maybe_resume_protocol()
        if not self.backlog:
            if transport._closing:
                transport._finalizing_close = True
                transport._schedule_finalize_close()
            elif self.eof:
                transport._write_eof_now()
        return NoResult.OK

    cdef NoResult clear(self, object exc) except NoResult.EXC:
        assert self.submitted_size == 0
        FlowControlledWriter.clear(self, exc)
        return NoResult.OK


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
    cdef:
        ProactorStreamWriter writer = <ProactorStreamWriter>op.callback_data
        ProactorSocketTransport transport = <ProactorSocketTransport>writer.transport

    try:
        writer._write_completed(op.status, op.transferred)
    except BaseException:
        try:
            transport._handle_error('Fatal write error on proactor socket transport')
        except BaseException as exc:
            transport._proactor_socket.context.backend_failed(exc)
