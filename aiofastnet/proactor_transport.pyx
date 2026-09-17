import logging
import os
import stat

from libc.stdint cimport int64_t

from . import constants
from .loop_backend cimport (
    AIOFN_LOOP_OK,
    aiofn_loop_file_handle_t,
    aiofn_loop_proactor_op_t,
    aiofn_loop_status,
    sockaddr,
)
from .loop_base cimport ProactorContext, ProactorHandle
from .transport cimport (
    DatagramTransport,
    FDTransport,
    Protocol,
    SendFileRequest,
    StreamTransport,
    WriteRequest,
    make_write_request_tail,
)
from .utils cimport (
    AIOFN_MAX_IOVEC,
    NoResult,
    aiofn_add_info_and_reraise,
    aiofn_allocate_bytes,
    aiofn_finalize_bytes,
    aiofn_pyaddr_to_sockaddr,
    aiofn_sockaddr_to_pyaddr,
    aiofn_unpack_simple_buffer,
)

from .utils import aiofn_set_result_unless_cancelled

from cython cimport unlikely
from cpython.buffer cimport Py_buffer, PyBuffer_Release, PyObject_GetBuffer, PyBUF_WRITABLE
from cpython.object cimport PyObject
from cpython.ref cimport Py_XDECREF


cdef:
    object _logger = logging.getLogger("asyncio")
    Py_ssize_t _data_received_max_size = constants.DATA_RECEIVED_MAX_SIZE
    Py_ssize_t _datagram_received_max_size = constants.DATAGRAM_RECEIVED_MAX_SIZE


cdef class ProactorSocketTransport(StreamTransport):
    """Stream transport driven directly by a LoopBase proactor backend."""

    cdef:
        ProactorHandle _proactor_handle

        object _read_buffer
        Py_buffer _read_view
        bint _read_view_acquired
        PyObject *_read_bytes
        object _pending_read_data
        size_t _pending_read_size
        bint _read_result_pending
        bint _read_started
        bint _read_stopping
        aiofn_loop_proactor_op_t _read_stop_op

        size_t _write_submitted_size
        aiofn_loop_proactor_op_t _write_op

        # True when the backend implements a native async sendfile op. False
        # when sendfile is instead falling back to the reactor write-readiness
        # path below (see _try_sendfile/_start_backlog_writing/_write_ready).
        bint _sendfile_native

        object _close_exc
        bint _close_scheduled

    def __init__(self, ProactorContext context, loop, sock, protocol, waiter=None, server=None, bint is_pipe=False):
        StreamTransport.__init__(self, loop, sock, protocol, server)

        self._read_buffer = None
        self._read_view_acquired = False
        self._read_bytes = NULL
        self._pending_read_data = None
        self._pending_read_size = 0
        self._read_result_pending = False
        self._read_started = False
        self._read_stopping = False
        self._read_stop_op.callback = _read_stop_callback_trampoline
        self._read_stop_op.callback_data = <void *>self
        self._read_stop_op.backend_token = NULL
        self._read_stop_op.status = AIOFN_LOOP_OK
        self._read_stop_op.transferred = 0
        # The scheduled initializer starts reading and then delivers connection_made().
        self._read_paused = True

        self._write_submitted_size = 0
        self._write_op.callback = _write_callback_trampoline
        self._write_op.callback_data = <void *>self
        self._write_op.backend_token = NULL
        self._write_op.status = AIOFN_LOOP_OK
        self._write_op.transferred = 0

        self._close_exc = None
        self._close_scheduled = False
        self._sendfile_native = context.proactor.sendfile != NULL
        # No native async sendfile op: fall back to the same write-readiness
        # driven os.sendfile() loop selector transports use, as long as this
        # backend also exposes a reactor (add_writer/remove_writer) to wait on.
        self._sendfile_compatible = not is_pipe and (self._sendfile_native or context.backend.reactor != NULL)

        if is_pipe:
            self._proactor_handle = context.wrap_pipe(sock)
        else:
            self._proactor_handle = context.wrap_socket(sock)
        assert self._proactor_handle.owner is None
        self._proactor_handle.owner = self

        self._loop.call_soon((<object>self)._initialize)
        if waiter is not None:
            self._loop.call_soon(aiofn_set_result_unless_cancelled, waiter, None)

    def __dealloc__(self):
        self._release_read_buffer()

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
        if self._read_stopping:
            return NoResult.OK

        if self._read_result_pending:
            self._deliver_read_result(self._pending_read_size)
            if self._read_paused or self._closing:
                return NoResult.OK

        assert not self._read_started
        self._read_started = True
        try:
            self._proactor_handle.context.check_status(self._proactor_handle.context.proactor.read_start(
                self._proactor_handle.context.backend.state,
                &self._proactor_handle.backend_handle,
                _read_alloc_trampoline,
                _read_callback_trampoline,
                <void *>self,
            ))
        except BaseException:
            self._read_started = False
            raise

    cdef NoResult _stop_reading(self) except NoResult.EXC:
        if not self._read_started or self._read_stopping:
            return NoResult.OK

        self._read_stopping = True
        self._read_stop_op.backend_token = NULL
        self._read_stop_op.status = AIOFN_LOOP_OK
        self._read_stop_op.transferred = 0
        try:
            self._proactor_handle.context.check_status(self._proactor_handle.context.proactor.read_stop(
                self._proactor_handle.context.backend.state,
                &self._proactor_handle.backend_handle,
                &self._read_stop_op,
            ))
        except BaseException:
            self._read_stopping = False
            raise

    cdef NoResult _allocate_read_buffer(self, void **buffer, size_t *buffer_len) except NoResult.EXC:
        cdef:
            char *data = NULL
            Py_ssize_t data_len

        # libuv may invoke its allocation callback for an EAGAIN read without
        # subsequently invoking the read callback. Release that unused buffer
        # before supplying the next one.
        self._release_read_buffer()

        if self._protocol_buffered:
            try:
                if self._protocol_aiofn:
                    self._read_buffer = (<Protocol>self._protocol).get_buffer(-1)
                else:
                    self._read_buffer = self._protocol.get_buffer(-1)
                PyObject_GetBuffer(self._read_buffer, &self._read_view, PyBUF_WRITABLE)
                self._read_view_acquired = True
                data = <char *>self._read_view.buf
                data_len = self._read_view.len
                if data_len == 0:
                    raise RuntimeError('get_buffer() returned an empty buffer')
            except:
                self._release_read_buffer()
                aiofn_add_info_and_reraise('Fatal error: protocol.get_buffer() call failed.')
        else:
            self._read_bytes = aiofn_allocate_bytes(_data_received_max_size, &data)
            data_len = _data_received_max_size

        buffer[0] = data
        buffer_len[0] = <size_t>data_len
        return NoResult.OK

    cdef inline void _release_read_buffer(self) noexcept:
        if self._read_view_acquired:
            PyBuffer_Release(&self._read_view)
            self._read_view_acquired = False
        Py_XDECREF(self._read_bytes)
        self._read_bytes = NULL
        self._read_buffer = None

    cdef NoResult _read_completed(self, aiofn_loop_status status, size_t bytes_read) except NoResult.EXC:
        if status != AIOFN_LOOP_OK:
            self._release_read_buffer()
            self._proactor_handle.context.check_status(status)

        if self._closing:
            self._release_read_buffer()
            return NoResult.OK

        if self._read_stopping or self._read_paused:
            assert not self._read_result_pending
            self._read_result_pending = True
            self._pending_read_size = bytes_read
            if bytes_read == 0:
                self._release_read_buffer()
            elif self._read_bytes != NULL:
                self._pending_read_data = aiofn_finalize_bytes(self._read_bytes, <Py_ssize_t>bytes_read)
                self._read_bytes = NULL
            return NoResult.OK

        self._deliver_read_result(bytes_read)

    cdef NoResult _deliver_read_result(self, size_t bytes_read) except NoResult.EXC:
        cdef:
            PyObject *bytes_obj
            object buffer
            object data
            object keep_open

        self._read_result_pending = False
        self._pending_read_size = 0

        if bytes_read == 0:
            self._pending_read_data = None
            self._release_read_buffer()
            keep_open = self._call_protocol_eof_received()
            if keep_open:
                self.pause_reading()
            else:
                self.close()
            return NoResult.OK

        if self._pending_read_data is not None:
            data = self._pending_read_data
            self._pending_read_data = None
            self._call_protocol_data_received(data)
        elif self._read_bytes == NULL:
            buffer = self._read_buffer
            if self._read_view_acquired:
                PyBuffer_Release(&self._read_view)
                self._read_view_acquired = False
            self._read_buffer = None
            self._call_protocol_buffer_updated(<Py_ssize_t>bytes_read)
        else:
            bytes_obj = self._read_bytes
            self._read_bytes = NULL
            data = aiofn_finalize_bytes(bytes_obj, <Py_ssize_t>bytes_read)
            self._call_protocol_data_received(data)

    cdef NoResult _read_stop_completed(self, aiofn_loop_status status) except NoResult.EXC:
        assert self._read_stopping
        self._read_stopping = False
        self._read_started = False

        if status != AIOFN_LOOP_OK:
            self._release_read_buffer()
            self._pending_read_data = None
            self._read_result_pending = False
            self._proactor_handle.context.check_status(status)

        if not self._read_result_pending:
            self._release_read_buffer()

        if self._closing:
            self._pending_read_data = None
            self._read_result_pending = False
            self._release_read_buffer()
            self._maybe_schedule_finalize_close()
        elif not self._read_paused:
            self._start_reading()

    cdef inline NoResult _maybe_schedule_finalize_close(self) except NoResult.EXC:
        if (self._closing and not self._close_scheduled and not self._read_started and not self._read_stopping
                and self._write_submitted_size == 0 and not self._write_ready_registered):
            self._close_scheduled = True
            self._schedule_finalize_close(self._close_exc)

    cpdef close(self):
        self._check_thread("close")
        if self._closing:
            return

        self._closing = True
        self._close_exc = None
        self._pause_reading()
        if self._write_backlog_size == 0:
            self._maybe_schedule_finalize_close()

    cpdef _force_close(self, exc):
        if self._finalizing_close:
            return

        # A synchronous read-stop completion can schedule finalization while
        # _pause_reading() is still on the stack.
        self._finalizing_close = True
        self._close_exc = exc

        if not self._closing:
            self._closing = True
            self._pause_reading()

        if self._write_ready_registered:
            self._stop_backlog_writing()

        if self._write_submitted_size == 0:
            self._clear_write_backlog(exc)
            self._maybe_schedule_finalize_close()

    cdef NoResult _release_backend_resources(self) except NoResult.EXC:
        assert self._read_paused
        assert not self._read_started
        assert not self._read_stopping
        assert self._write_submitted_size == 0
        assert not self._write_ready_registered

        self._pending_read_data = None
        self._read_result_pending = False
        self._release_read_buffer()
        try:
            self._proactor_handle.context.unwrap_handle(self._proactor_handle)
        finally:
            self._proactor_handle.owner = None
            self._proactor_handle = None
            self._close_exc = None

    cdef NoResult _start_backlog_writing(self) except NoResult.EXC:
        if isinstance(self._write_backlog[0], SendFileRequest) and not self._sendfile_native:
            # No native async sendfile op on this backend: wait for write
            # readiness through the reactor instead, exactly like a selector
            # transport would, and drive it via the inherited _write_ready().
            if not self._write_ready_registered and not self._finalizing_close:
                self._write_ready_registered = True
                self._loop.add_writer(self._fileno_obj, self._write_ready)
            return NoResult.OK

        if self._write_submitted_size == 0:
            if isinstance(self._write_backlog[0], SendFileRequest):
                self._submit_sendfile()
            else:
                self._submit_write()

    def _write_ready(self):
        # Only ever reached while draining a SendFileRequest without native
        # backend support (see _start_backlog_writing); regular writes always
        # go through the proactor's own async write() and never register here.
        if unlikely(self._is_debug):
            _logger.debug("%r: sendfile write_ready event", self)

        if self._finalizing_close:
            return

        cdef bint all_sent = True

        try:
            while (all_sent and self._write_backlog_size > 0
                   and isinstance(self._write_backlog[0], SendFileRequest)):
                all_sent = self._try_sendfile_from_backlog_top()
        except:
            self._handle_error('Fatal sendfile error on transport')
            return

        self._maybe_resume_protocol()

        if self._write_backlog_size == 0 or not isinstance(self._write_backlog[0], SendFileRequest):
            self._stop_backlog_writing()
            if self._write_backlog_size > 0:
                self._start_backlog_writing()
            elif self._closing:
                self._maybe_schedule_finalize_close()
            elif self._write_eof:
                self._write_eof_now()

    # cdef WriteRequest _try_write(self, object data, char *ptr, Py_ssize_t size):
    #     return make_write_request_tail(data, ptr, size)

    cdef bint _try_sendfile(self, SendFileRequest request) except -1:
        if self._sendfile_native:
            return False
        return StreamTransport._try_sendfile(self, request)

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
            self._write_buffers[buffer_count].iov_base = request.ptr
            self._write_buffers[buffer_count].iov_len = request.size
            submitted_size += <size_t>request.size
            buffer_count += 1
            if buffer_count == AIOFN_MAX_IOVEC:
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

            self._proactor_handle.context.check_status(
                self._proactor_handle.context.proactor.write(
                    self._proactor_handle.context.backend.state,
                    &self._proactor_handle.backend_handle,
                    &self._write_op,
                    self._write_buffers,
                    buffer_count,
                ))
        except BaseException:
            self._write_submitted_size = 0
            raise

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

            self._proactor_handle.context.check_status(
                self._proactor_handle.context.proactor.sendfile(
                    self._proactor_handle.context.backend.state,
                    &self._proactor_handle.backend_handle,
                    &self._write_op,
                    <aiofn_loop_file_handle_t>request.native_handle,
                    request.offset,
                    <size_t>request.count,
                ))
        except BaseException:
            self._write_submitted_size = 0
            raise

    cdef NoResult _write_completed(self, aiofn_loop_status status, size_t bytes_sent) except NoResult.EXC:
        cdef:
            SendFileRequest sendfile_request

        assert self._write_submitted_size > 0

        if unlikely(self._is_debug):
            _logger.debug("%r: write_completed(error_code=%d, transferred=%d)", self, status, bytes_sent)

        if self._finalizing_close:
            self._write_submitted_size = 0
            self._clear_write_backlog(self._close_exc)
            self._maybe_schedule_finalize_close()
            return NoResult.OK

        if status != AIOFN_LOOP_OK:
            self._write_submitted_size = 0
            self._proactor_handle.context.check_status(status)

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
            self._start_backlog_writing()

        self._maybe_resume_protocol()
        if self._write_backlog_size == 0:
            if self._closing:
                self._maybe_schedule_finalize_close()
            elif self._write_eof:
                self._write_eof_now()


cdef class ProactorWritePipeTransport(ProactorSocketTransport):
    """Write-side pipe transport driven by a LoopBase proactor backend."""

    def __init__(self, ProactorContext context, loop, pipe, protocol, waiter=None):
        pipe_stat = os.fstat(pipe.fileno())
        mode = pipe_stat.st_mode
        if not (stat.S_ISCHR(mode) or stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode)):
            raise ValueError("Pipe transport is only for pipes, sockets and character devices")

        ProactorSocketTransport.__init__(self, context, loop, pipe, protocol, waiter, is_pipe=True)
        self._extra['pipe'] = pipe

    cpdef _initialize(self):
        if not self._closing:
            self._call_protocol_connection_made()


cdef class ProactorReadPipeTransport(FDTransport):
    """Read-side pipe transport driven by a LoopBase proactor backend."""

    cdef:
        ProactorHandle _proactor_handle
        PyObject *_read_bytes
        object _pending_read_data
        bint _read_result_pending
        bint _read_started
        bint _read_stopping
        aiofn_loop_proactor_op_t _read_stop_op
        object _close_exc
        bint _close_scheduled

    def __init__(self, ProactorContext context, loop, pipe, protocol, waiter=None):
        mode = os.fstat(pipe.fileno()).st_mode
        if not (stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode) or stat.S_ISCHR(mode)):
            raise ValueError("Pipe transport is for pipes/sockets only.")

        FDTransport.__init__(self, loop, pipe)
        self._set_protocol(protocol)
        self._extra['pipe'] = pipe

        self._read_bytes = NULL
        self._pending_read_data = None
        self._read_result_pending = False
        self._read_started = False
        self._read_stopping = False
        self._read_stop_op.callback = _pipe_read_stop_callback_trampoline
        self._read_stop_op.callback_data = <void *>self
        self._read_stop_op.backend_token = NULL
        self._read_stop_op.status = AIOFN_LOOP_OK
        self._read_stop_op.transferred = 0
        self._close_exc = None
        self._close_scheduled = False
        self._read_paused = True

        self._proactor_handle = context.wrap_pipe(pipe)
        assert self._proactor_handle.owner is None
        self._proactor_handle.owner = self

        self._loop.call_soon((<object>self)._initialize)
        if waiter is not None:
            self._loop.call_soon(aiofn_set_result_unless_cancelled, waiter, None)

    def __dealloc__(self):
        self._release_read_buffer()

    cpdef _initialize(self):
        if self._closing:
            return

        try:
            self.resume_reading()
        except:
            self._handle_error('Fatal read error on proactor pipe transport')
            return

        self._call_protocol_connection_made()

    cpdef close(self):
        self.abort()

    cdef NoResult _start_reading(self) except NoResult.EXC:
        if self._read_stopping:
            return NoResult.OK

        if self._read_result_pending:
            self._deliver_read_result()
            if self._read_paused or self._closing:
                return NoResult.OK

        assert not self._read_started
        self._read_started = True
        try:
            self._proactor_handle.context.check_status(self._proactor_handle.context.proactor.read_start(
                self._proactor_handle.context.backend.state,
                &self._proactor_handle.backend_handle,
                _pipe_read_alloc_trampoline,
                _pipe_read_callback_trampoline,
                <void *>self,
            ))
        except BaseException:
            self._read_started = False
            raise

    cdef NoResult _stop_reading(self) except NoResult.EXC:
        if not self._read_started or self._read_stopping:
            return NoResult.OK

        self._read_stopping = True
        self._read_stop_op.backend_token = NULL
        self._read_stop_op.status = AIOFN_LOOP_OK
        self._read_stop_op.transferred = 0
        try:
            self._proactor_handle.context.check_status(self._proactor_handle.context.proactor.read_stop(
                self._proactor_handle.context.backend.state,
                &self._proactor_handle.backend_handle,
                &self._read_stop_op,
            ))
        except BaseException:
            self._read_stopping = False
            raise

    cdef NoResult _allocate_read_buffer(self, void **buffer, size_t *buffer_len) except NoResult.EXC:
        cdef char *data

        # libuv may request a buffer for an EAGAIN read without delivering a
        # read callback. Release that unused buffer before supplying another.
        self._release_read_buffer()

        self._read_bytes = aiofn_allocate_bytes(_data_received_max_size, &data)
        buffer[0] = data
        buffer_len[0] = <size_t>_data_received_max_size

    cdef inline void _release_read_buffer(self) noexcept:
        Py_XDECREF(self._read_bytes)
        self._read_bytes = NULL

    cdef NoResult _read_completed(self, aiofn_loop_status status, size_t bytes_read) except NoResult.EXC:
        cdef:
            PyObject *bytes_obj
            object data

        if status != AIOFN_LOOP_OK:
            self._release_read_buffer()
            self._proactor_handle.context.check_status(status)

        if self._closing:
            self._release_read_buffer()
            return NoResult.OK

        assert self._read_bytes != NULL
        bytes_obj = self._read_bytes
        self._read_bytes = NULL
        if bytes_read == 0:
            Py_XDECREF(bytes_obj)
            data = None
        else:
            data = aiofn_finalize_bytes(bytes_obj, <Py_ssize_t>bytes_read)

        if self._read_stopping or self._read_paused:
            assert not self._read_result_pending
            self._pending_read_data = data
            self._read_result_pending = True
            return NoResult.OK

        self._deliver_read_data(data)

    cdef NoResult _deliver_read_result(self) except NoResult.EXC:
        cdef object data = self._pending_read_data
        self._pending_read_data = None
        self._read_result_pending = False
        self._deliver_read_data(data)

    cdef NoResult _deliver_read_data(self, object data) except NoResult.EXC:
        if data is None:
            if unlikely(self._is_debug):
                _logger.info("%r was closed by peer", self)

            self._call_protocol_eof_received()
            self._force_close(None)
        else:
            self._call_protocol_data_received(data)

    cdef NoResult _read_stop_completed(self, aiofn_loop_status status) except NoResult.EXC:
        assert self._read_stopping
        self._read_stopping = False
        self._read_started = False

        if status != AIOFN_LOOP_OK:
            self._pending_read_data = None
            self._read_result_pending = False
            self._release_read_buffer()
            self._proactor_handle.context.check_status(status)

        if not self._read_result_pending:
            self._release_read_buffer()

        if self._closing:
            self._pending_read_data = None
            self._read_result_pending = False
            self._release_read_buffer()
            self._maybe_schedule_finalize_close()
        elif not self._read_paused:
            self._start_reading()

    cdef inline NoResult _maybe_schedule_finalize_close(self) except NoResult.EXC:
        if self._closing and not self._close_scheduled and not self._read_started and not self._read_stopping:
            self._close_scheduled = True
            self._schedule_finalize_close(self._close_exc)

    cpdef _force_close(self, exc):
        if self._finalizing_close:
            return

        # A synchronous read-stop completion can schedule finalization while
        # _pause_reading() is still on the stack.
        self._finalizing_close = True
        self._close_exc = exc

        if not self._closing:
            self._closing = True
            self._pause_reading()

        self._maybe_schedule_finalize_close()

    cpdef _finalize_close(self, exc):
        assert self._read_paused
        assert not self._read_started
        assert not self._read_stopping

        self._pending_read_data = None
        self._read_result_pending = False
        self._release_read_buffer()
        try:
            self._call_protocol_connection_lost(exc)
        finally:
            try:
                self._proactor_handle.context.unwrap_handle(self._proactor_handle)
            finally:
                self._proactor_handle.owner = None
                self._proactor_handle = None
                if self._file is not None:
                    self._file.close()
                    self._file = None
                self._protocol = None


cdef class ProactorDatagramTransport(DatagramTransport):
    """Datagram transport driven directly by a LoopBase proactor backend."""

    cdef:
        ProactorHandle _proactor_handle
        int _family
        bint _has_connection

        PyObject *_read_bytes
        object _pending_read_data
        object _pending_read_address
        bint _read_result_pending
        bint _read_started
        bint _read_stopping
        aiofn_loop_proactor_op_t _read_stop_op

        bint _send_pending
        aiofn_loop_proactor_op_t _send_op

        object _close_exc
        bint _close_scheduled

    def __init__(self, ProactorContext context, loop, sock, protocol, address, waiter=None):
        DatagramTransport.__init__(self, loop, sock, protocol, address, 8)

        self._read_bytes = NULL
        self._pending_read_data = None
        self._pending_read_address = None
        self._read_result_pending = False
        self._read_started = False
        self._read_stopping = False
        self._read_stop_op.callback = _recvfrom_stop_callback_trampoline
        self._read_stop_op.callback_data = <void *>self
        self._read_stop_op.backend_token = NULL
        self._read_stop_op.status = AIOFN_LOOP_OK
        self._read_stop_op.transferred = 0
        # The scheduled initializer starts receiving and then delivers connection_made().
        self._read_paused = True

        self._send_pending = False
        self._send_op.callback = _sendto_callback_trampoline
        self._send_op.callback_data = <void *>self
        self._send_op.backend_token = NULL
        self._send_op.status = AIOFN_LOOP_OK
        self._send_op.transferred = 0

        self._close_exc = None
        self._close_scheduled = False

        self._proactor_handle = context.wrap_socket(sock)
        assert self._proactor_handle.owner is None
        self._proactor_handle.owner = self

        self._loop.call_soon((<object>self)._initialize)
        if waiter is not None:
            self._loop.call_soon(aiofn_set_result_unless_cancelled, waiter, None)

    def __dealloc__(self):
        self._release_read_buffer()

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
        if self._read_stopping:
            return NoResult.OK

        if self._read_result_pending:
            self._deliver_recvfrom_result()
            if self._read_paused or self._closing:
                return NoResult.OK

        assert not self._read_started
        self._read_started = True
        try:
            self._proactor_handle.context.check_status(self._proactor_handle.context.proactor.recvfrom_start(
                self._proactor_handle.context.backend.state,
                &self._proactor_handle.backend_handle,
                _recvfrom_alloc_trampoline,
                _recvfrom_callback_trampoline,
                <void *>self,
            ))
        except BaseException:
            self._read_started = False
            raise

    cdef NoResult _stop_reading(self) except NoResult.EXC:
        if not self._read_started or self._read_stopping:
            return NoResult.OK

        self._read_stopping = True
        self._read_stop_op.backend_token = NULL
        self._read_stop_op.status = AIOFN_LOOP_OK
        self._read_stop_op.transferred = 0
        try:
            self._proactor_handle.context.check_status(self._proactor_handle.context.proactor.recvfrom_stop(
                self._proactor_handle.context.backend.state,
                &self._proactor_handle.backend_handle,
                &self._read_stop_op,
            ))
        except BaseException:
            self._read_stopping = False
            raise

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
                self._proactor_handle.context.check_status(status)
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

        if self._closing:
            return NoResult.OK

        if self._read_stopping or self._read_paused:
            assert not self._read_result_pending
            self._pending_read_data = data
            self._pending_read_address = py_address
            self._read_result_pending = True
            return NoResult.OK

        self._call_protocol_datagram_received(data, py_address)
        return NoResult.OK

    cdef NoResult _deliver_recvfrom_result(self) except NoResult.EXC:
        cdef:
            object data = self._pending_read_data
            object address = self._pending_read_address

        self._pending_read_data = None
        self._pending_read_address = None
        self._read_result_pending = False
        self._call_protocol_datagram_received(data, address)

    cdef NoResult _read_stop_completed(self, aiofn_loop_status status) except NoResult.EXC:
        assert self._read_stopping
        self._read_stopping = False
        self._read_started = False

        if status != AIOFN_LOOP_OK:
            self._pending_read_data = None
            self._pending_read_address = None
            self._read_result_pending = False
            self._release_read_buffer()
            self._proactor_handle.context.check_status(status)

        if not self._read_result_pending:
            self._release_read_buffer()

        if self._closing:
            self._pending_read_data = None
            self._pending_read_address = None
            self._read_result_pending = False
            self._release_read_buffer()
            self._maybe_schedule_finalize_close()
        elif not self._read_paused:
            self._start_reading()

    cdef inline NoResult _maybe_schedule_finalize_close(self) except NoResult.EXC:
        if (self._closing and not self._close_scheduled and not self._read_started and not self._read_stopping
                and not self._send_pending):
            self._close_scheduled = True
            self._schedule_finalize_close(self._close_exc)

    cpdef close(self):
        self._check_thread("close")
        if self._closing:
            return

        self._closing = True
        self._close_exc = None
        self._pause_reading()
        if self._write_backlog_size == 0:
            self._maybe_schedule_finalize_close()

    cpdef _force_close(self, exc):
        if self._finalizing_close:
            return

        # A synchronous read-stop completion can schedule finalization while
        # _pause_reading() is still on the stack.
        self._finalizing_close = True
        self._close_exc = exc

        if not self._closing:
            self._closing = True
            self._pause_reading()

        if not self._send_pending:
            self._clear_write_backlog(exc)
            self._maybe_schedule_finalize_close()

    cpdef _finalize_close(self, exc):
        assert self._read_paused
        assert not self._read_started
        assert not self._read_stopping
        assert not self._send_pending
        self._pending_read_data = None
        self._pending_read_address = None
        self._read_result_pending = False
        self._release_read_buffer()
        try:
            self._call_protocol_connection_lost(exc)
        finally:
            try:
                self._proactor_handle.context.unwrap_handle(self._proactor_handle)
            finally:
                self._proactor_handle.owner = None
                self._proactor_handle = None
                if self._file is not None:
                    self._file.close()
                    self._file = None
                self._protocol = None
                self._close_exc = None

    cdef NoResult _start_backlog_writing(self) except NoResult.EXC:
        if not self._send_pending:
            self._submit_sendto()

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

            self._proactor_handle.context.check_status(
                self._proactor_handle.context.proactor.sendto(
                    self._proactor_handle.context.backend.state,
                    &self._proactor_handle.backend_handle,
                    &self._send_op,
                    buffer,
                    <size_t>buffer_len,
                    raw_address_ptr,
                    raw_address_len,
                ))
        except BaseException:
            self._send_pending = False
            raise

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
            self._maybe_schedule_finalize_close()
            return NoResult.OK

        if status != AIOFN_LOOP_OK:
            try:
                self._proactor_handle.context.check_status(status)
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
            self._start_backlog_writing()

        self._maybe_resume_protocol()
        if self._write_backlog_size == 0 and self._closing:
            self._maybe_schedule_finalize_close()


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
            transport._proactor_handle.context.backend_failed(exc)


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
            transport._proactor_handle.context.backend_failed(exc)


cdef void _recvfrom_stop_callback_trampoline(aiofn_loop_proactor_op_t *op) noexcept with gil:
    cdef ProactorDatagramTransport transport = <ProactorDatagramTransport>op.callback_data
    try:
        transport._read_stop_completed(op.status)
    except BaseException:
        try:
            transport._handle_error('Fatal read-stop error on proactor datagram transport')
        except BaseException as exc:
            transport._proactor_handle.context.backend_failed(exc)


cdef void _sendto_callback_trampoline(aiofn_loop_proactor_op_t *op) noexcept with gil:
    cdef ProactorDatagramTransport transport = <ProactorDatagramTransport>op.callback_data

    try:
        transport._sendto_completed(op.status, op.transferred)
    except BaseException:
        try:
            transport._handle_error('Fatal write error on proactor datagram transport')
        except BaseException as exc:
            transport._proactor_handle.context.backend_failed(exc)


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
            transport._proactor_handle.context.backend_failed(exc)


cdef void _pipe_read_alloc_trampoline(
    void *callback_data,
    size_t suggested_size,
    void **buffer,
    size_t *buffer_len,
) noexcept with gil:
    cdef ProactorReadPipeTransport transport = <ProactorReadPipeTransport>callback_data
    try:
        transport._allocate_read_buffer(buffer, buffer_len)
    except BaseException:
        buffer[0] = NULL
        buffer_len[0] = 0
        try:
            transport._handle_error('Fatal read buffer allocation error on proactor pipe transport')
        except BaseException as exc:
            transport._proactor_handle.context.backend_failed(exc)


cdef void _pipe_read_callback_trampoline(
    void *callback_data,
    aiofn_loop_status status,
    void *buffer,
    size_t bytes_read,
) noexcept with gil:
    cdef ProactorReadPipeTransport transport = <ProactorReadPipeTransport>callback_data
    try:
        transport._read_completed(status, bytes_read)
    except BaseException:
        try:
            transport._handle_error('Fatal read error on proactor pipe transport')
        except BaseException as exc:
            transport._proactor_handle.context.backend_failed(exc)


cdef void _pipe_read_stop_callback_trampoline(aiofn_loop_proactor_op_t *op) noexcept with gil:
    cdef ProactorReadPipeTransport transport = <ProactorReadPipeTransport>op.callback_data
    try:
        transport._read_stop_completed(op.status)
    except BaseException:
        try:
            transport._handle_error('Fatal read-stop error on proactor pipe transport')
        except BaseException as exc:
            transport._proactor_handle.context.backend_failed(exc)


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
            transport._proactor_handle.context.backend_failed(exc)


cdef void _read_stop_callback_trampoline(aiofn_loop_proactor_op_t *op) noexcept with gil:
    cdef ProactorSocketTransport transport = <ProactorSocketTransport>op.callback_data
    try:
        transport._read_stop_completed(op.status)
    except BaseException:
        try:
            transport._handle_error('Fatal read-stop error on proactor socket transport')
        except BaseException as exc:
            transport._proactor_handle.context.backend_failed(exc)


cdef void _write_callback_trampoline(aiofn_loop_proactor_op_t *op) noexcept with gil:
    cdef ProactorSocketTransport transport = <ProactorSocketTransport>op.callback_data

    try:
        transport._write_completed(op.status, op.transferred)
    except BaseException:
        try:
            transport._handle_error('Fatal write error on proactor socket transport')
        except BaseException as exc:
            transport._proactor_handle.context.backend_failed(exc)
