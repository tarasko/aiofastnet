import collections
import logging
import socket
import warnings

from asyncio.trsock import TransportSocket

from . import constants
from .loop_backend cimport (
    AIOFN_LOOP_OK,
    aiofn_loop_buffer_init,
    aiofn_loop_buffer_t,
    aiofn_loop_proactor_op_t,
    aiofn_loop_status,
)
from .loop_base cimport ProactorContext, ProactorSocket
from .transport cimport (
    Protocol,
    Transport,
    WriteRequest,
    WriteWatermarks,
    make_write_request,
    make_write_request_from_ptr,
    make_write_request_tail,
)
from .utils cimport (
    NoResult,
    aiofn_allocate_bytes,
    aiofn_finalize_bytes,
    aiofn_iovec,
    aiofn_set_nodelay,
    aiofn_set_socket_extra_info,
    aiofn_unpack_simple_buffer,
    aiofn_write,
    aiofn_writev,
    unlikely,
)

from .utils import aiofn_set_result_unless_cancelled

from cpython.object cimport PyObject
from cpython.ref cimport Py_XDECREF


cdef:
    object _logger = logging.getLogger("asyncio")
    Py_ssize_t _data_received_max_size = constants.DATA_RECEIVED_MAX_SIZE
    size_t _log_threshold_for_connlost_writes = constants.LOG_THRESHOLD_FOR_CONNLOST_WRITES


cdef class ProactorSocketTransport(Transport):
    """Stream transport driven directly by a LoopBase proactor backend."""

    cdef:
        ProactorSocket _proactor_socket
        object _file
        int _fileno
        object _server

        object _read_buffer
        PyObject *_read_bytes

        WriteWatermarks _write_watermarks
        object _write_backlog
        Py_ssize_t _write_backlog_size
        size_t _write_submitted_size
        aiofn_loop_proactor_op_t _write_op
        aiofn_loop_buffer_t _write_buffers[256]

        bint _eof
        size_t _closed_write_count
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

        self._write_watermarks = WriteWatermarks(loop)
        self._write_backlog = collections.deque()
        self._write_backlog_size = 0
        self._write_submitted_size = 0
        self._write_op.callback = _proactor_transport_write_callback
        self._write_op.callback_data = <void *>self
        self._write_op.backend_token = NULL
        self._write_op.status = AIOFN_LOOP_OK
        self._write_op.transferred = 0

        self._eof = False
        self._closed_write_count = 0
        self._close_exc = None
        self._sendfile_compatible = False

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
            _proactor_transport_read_alloc,
            _proactor_transport_read_callback,
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

    cdef inline NoResult _release_read_buffer(self) except NoResult.EXC:
        Py_XDECREF(self._read_bytes)
        self._read_bytes = NULL
        self._read_buffer = None
        return NoResult.OK

    cdef NoResult _read_completed(self, aiofn_loop_status status, size_t bytes_read) except NoResult.EXC:
        cdef:
            PyObject *bytes_obj
            object buffer
            object data
            object keep_open

        if status != AIOFN_LOOP_OK:
            self._release_read_buffer()
            try:
                self._proactor_socket.context.check_status(status)
            except BaseException as exc:
                self._fatal_error(exc, 'Fatal read error on proactor socket transport')
            return NoResult.OK

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
        return self._write_watermarks.get_write_buffer_limits()

    cpdef set_write_buffer_limits(self, high=None, low=None):
        self._check_thread("set_write_buffer_limits")
        self._write_watermarks.set_write_buffer_limits(
            self, self._protocol, self._get_write_buffer_size_nocheck(), high, low)

    cpdef get_write_buffer_size(self):
        self._check_thread("get_write_buffer_size")
        return self._get_write_buffer_size_nocheck()

    cdef inline Py_ssize_t _get_write_buffer_size_nocheck(self) except -1:
        cdef Py_ssize_t total = self._write_backlog_size
        if self._protocol_aiofn:
            total += (<Protocol>self._protocol).get_local_write_buffer_size()
        return total

    cdef inline NoResult _maybe_pause_protocol(self) except NoResult.EXC:
        self._write_watermarks.maybe_pause_protocol(self, self._protocol, self._get_write_buffer_size_nocheck())
        return NoResult.OK

    cdef inline NoResult _maybe_resume_protocol(self) except NoResult.EXC:
        self._write_watermarks.maybe_resume_protocol(self, self._protocol, self._get_write_buffer_size_nocheck())
        return NoResult.OK

    cdef inline NoResult _append_write_request(self, WriteRequest request) except NoResult.EXC:
        if request.size:
            self._write_backlog.append(request)
            self._write_backlog_size += request.size
        return NoResult.OK

    cdef inline NoResult _append_write(self, object data) except NoResult.EXC:
        self._append_write_request(make_write_request(data))
        return NoResult.OK

    cdef inline NoResult _append_write_tail(self, object data, char *ptr, Py_ssize_t size) except NoResult.EXC:
        self._append_write_request(make_write_request_tail(data, ptr, size))
        return NoResult.OK

    cpdef write_nocheck(self, data):
        if self._eof:
            raise RuntimeError('Cannot call write() after write_eof()')
        if not data:
            return

        if unlikely(self._finalizing_close):
            if self._closed_write_count >= _log_threshold_for_connlost_writes:
                _logger.warning('write() called after connection lost.')
            self._closed_write_count += 1
            return

        cdef:
            char *data_ptr
            Py_ssize_t data_len
            Py_ssize_t bytes_sent = 0

        try:
            if self._write_backlog_size == 0:
                assert self._write_submitted_size == 0
                aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
                bytes_sent = aiofn_write(self._fileno, data_ptr, data_len, True)
                if unlikely(self._is_debug):
                    _logger.debug("%r: aiofn_write(..., len=%d)=%d", self, data_len, bytes_sent)
                if bytes_sent == data_len:
                    return
                if bytes_sent < 0:
                    bytes_sent = 0

                self._append_write_tail(data, data_ptr + bytes_sent, data_len - bytes_sent)
            else:
                self._append_write(data)

            if self._write_submitted_size == 0:
                self._submit_write()
            self._maybe_pause_protocol()
        except:
            self._handle_error('Fatal write error on proactor socket transport')

    cdef inline Py_ssize_t _writev(self, size_t buffer_count) except -2:
        cdef Py_ssize_t bytes_sent = aiofn_writev(
            self._fileno,
            <aiofn_iovec *>&self._write_buffers[0],
            <Py_ssize_t>buffer_count,
            True,
        )
        if unlikely(self._is_debug):
            _logger.debug("%r: aiofn_writev(..., len(iovecs)=%d)=%d", self, buffer_count, bytes_sent)
        return bytes_sent

    cdef inline bint _try_write_lines(self, object list_of_data, Py_ssize_t *total_bytes_sent) except -1:
        cdef:
            char *data_ptr
            Py_ssize_t data_len
            Py_ssize_t bytes_sent = 0
            Py_ssize_t bytes_to_send = 0
            size_t buffer_count = 0

        for data in list_of_data:
            aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
            if unlikely(data_len == 0):
                continue

            aiofn_loop_buffer_init(&self._write_buffers[buffer_count], data_ptr, <size_t>data_len)
            bytes_to_send += data_len
            buffer_count += 1
            if buffer_count < 256:
                continue

            bytes_sent = self._writev(buffer_count)
            if bytes_sent > 0:
                total_bytes_sent[0] += bytes_sent
            if bytes_sent != bytes_to_send:
                return False

            bytes_sent = 0
            bytes_to_send = 0
            buffer_count = 0

        if buffer_count:
            bytes_sent = self._writev(buffer_count)
            if bytes_sent > 0:
                total_bytes_sent[0] += bytes_sent

        return bytes_sent == bytes_to_send

    cdef inline NoResult _append_write_lines_tail(
        self,
        object list_of_data,
        Py_ssize_t total_bytes_sent,
    ) except NoResult.EXC:
        cdef:
            char *data_ptr
            Py_ssize_t data_len

        for data in list_of_data:
            aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
            if data_len <= total_bytes_sent:
                total_bytes_sent -= data_len
                continue
            if total_bytes_sent:
                self._append_write_tail(data, data_ptr + total_bytes_sent, data_len - total_bytes_sent)
                total_bytes_sent = 0
            elif data_len:
                self._append_write(data)
        return NoResult.OK

    cpdef writelines_nocheck(self, list_of_data):
        if self._eof:
            raise RuntimeError('Cannot call writelines() after write_eof()')

        if unlikely(self._finalizing_close):
            if self._closed_write_count >= _log_threshold_for_connlost_writes:
                _logger.warning('writelines() called after connection lost.')
            self._closed_write_count += 1
            return

        cdef Py_ssize_t total_bytes_sent = 0

        try:
            if self._write_backlog_size == 0:
                assert self._write_submitted_size == 0
                if self._try_write_lines(list_of_data, &total_bytes_sent):
                    return

            self._append_write_lines_tail(list_of_data, total_bytes_sent)
            if self._write_backlog and self._write_submitted_size == 0:
                self._submit_write()
            self._maybe_pause_protocol()
        except:
            self._handle_error('Fatal write error on proactor socket transport')

    cdef NoResult write_c(self, char *ptr, Py_ssize_t size) except NoResult.EXC:
        if size <= 0:
            return NoResult.OK

        if unlikely(self._finalizing_close):
            if self._closed_write_count >= _log_threshold_for_connlost_writes:
                _logger.warning('write_c() called after connection lost.')
            self._closed_write_count += 1
            return NoResult.OK

        cdef Py_ssize_t bytes_sent = 0

        try:
            if self._write_backlog_size == 0:
                assert self._write_submitted_size == 0
                bytes_sent = aiofn_write(self._fileno, ptr, size, True)
                if unlikely(self._is_debug):
                    _logger.debug("%r: aiofn_write(..., len=%d)=%d", self, size, bytes_sent)
                if bytes_sent == size:
                    return NoResult.OK
                if bytes_sent < 0:
                    bytes_sent = 0

            self._append_write_request(make_write_request_from_ptr(ptr + bytes_sent, size - bytes_sent))
            if self._write_submitted_size == 0:
                self._submit_write()
            self._maybe_pause_protocol()
        except:
            self._handle_error('Fatal write error on proactor socket transport')
        return NoResult.OK

    cdef NoResult _submit_write(self) except NoResult.EXC:
        cdef:
            WriteRequest request
            size_t buffer_count = 0
            size_t submitted_size = 0

        assert self._write_submitted_size == 0
        assert self._write_backlog

        for request_obj in self._write_backlog:
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
            self._proactor_socket.context.check_status(self._proactor_socket.context.proactor.write(
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

    cdef inline NoResult _adjust_write_backlog(self, size_t bytes_sent) except NoResult.EXC:
        cdef WriteRequest request

        assert 0 < bytes_sent <= self._write_submitted_size
        self._write_backlog_size -= <Py_ssize_t>bytes_sent
        while bytes_sent:
            request = <WriteRequest>self._write_backlog[0]
            if <size_t>request.size <= bytes_sent:
                bytes_sent -= <size_t>request.size
                self._write_backlog.popleft()
            else:
                request.ptr += bytes_sent
                request.size -= <Py_ssize_t>bytes_sent
                bytes_sent = 0
        self._write_submitted_size = 0
        return NoResult.OK

    cdef NoResult _write_completed(self, aiofn_loop_status status, size_t bytes_sent) except NoResult.EXC:
        assert self._write_submitted_size > 0

        if self._finalizing_close:
            self._write_submitted_size = 0
            self._clear_write_backlog()
            self._schedule_finalize_close()
            return NoResult.OK

        if status != AIOFN_LOOP_OK:
            self._write_submitted_size = 0
            try:
                self._proactor_socket.context.check_status(status)
            except BaseException as exc:
                self._fatal_error(exc, 'Fatal write error on proactor socket transport')
            return NoResult.OK

        self._adjust_write_backlog(bytes_sent)
        if self._write_backlog:
            self._submit_write()

        self._maybe_resume_protocol()
        if not self._write_backlog:
            if self._closing:
                self._finalizing_close = True
                self._schedule_finalize_close()
            elif self._eof:
                self._write_eof_now()
        return NoResult.OK

    cdef inline NoResult _clear_write_backlog(self) except NoResult.EXC:
        assert self._write_submitted_size == 0
        self._write_backlog.clear()
        self._write_backlog_size = 0
        return NoResult.OK

    cpdef can_write_eof(self):
        return True

    cpdef write_eof(self):
        self._check_thread("write_eof")
        if self._closing or self._eof:
            return
        self._eof = True
        if not self._write_backlog:
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
        if not self._write_backlog:
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
            self._clear_write_backlog()
            self._schedule_finalize_close()

    cdef inline NoResult _schedule_finalize_close(self) except NoResult.EXC:
        self._loop.call_soon((<object>self)._finalize_close, self._close_exc)

    def _finalize_close(self, exc):
        cdef object server

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


cdef void _proactor_transport_read_alloc(
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


cdef void _proactor_transport_read_callback(
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


cdef void _proactor_transport_write_callback(aiofn_loop_proactor_op_t *op) noexcept with gil:
    cdef ProactorSocketTransport transport = <ProactorSocketTransport>op.callback_data
    try:
        transport._write_completed(op.status, op.transferred)
    except BaseException:
        try:
            transport._handle_error('Fatal write error on proactor socket transport')
        except BaseException as exc:
            transport._proactor_socket.context.backend_failed(exc)
