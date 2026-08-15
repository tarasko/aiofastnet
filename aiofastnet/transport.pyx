"""Shared transport, protocol, write request, and flow-control primitives."""

import asyncio
import collections
import io
import os
import stat
import sys
from logging import getLogger

import cython
from cpython.buffer cimport PyBUF_READ, PyBUF_WRITABLE
from cpython.bytes cimport *
from cpython.memoryview cimport PyMemoryView_FromMemory
from cpython.pythread cimport PyThread_get_thread_ident

from . import constants
from .utils cimport *


if sys.platform == "win32":
    import msvcrt
else:
    msvcrt = None


cdef:
    object _logger = getLogger('aiofastnet')
    size_t _log_threshold_for_connlost_writes = constants.LOG_THRESHOLD_FOR_CONNLOST_WRITES


cdef class Transport:
    """Internal transport interface implemented by aiofastnet transports."""

    def __init__(self, loop):
        assert loop is not None
        self._loop = loop
        self._thread_id = PyThread_get_thread_ident()
        self._is_debug = loop.get_debug()

        self._protocol = None
        self._protocol_buffered = False
        self._protocol_aiofn = False
        self._protocol_connected = False
        self._protocol_eof_received = False

        self._extra = {}

        self._read_paused = False
        self._closing = False
        self._finalizing_close = False

    cdef inline NoResult _check_thread(self, meth) except NoResult.EXC:
        cdef unsigned long curr_thread_id = PyThread_get_thread_ident()
        if self._thread_id != curr_thread_id:
            raise RuntimeError(
                f"{self.__class__.__name__}.{meth} called from a wrong thread: "
                f"transport thread id={self._thread_id}, "
                f"curr thread_id={curr_thread_id}"
            )

    cdef inline NoResult _set_protocol(self, protocol) except NoResult.EXC:
        self._protocol = protocol
        self._protocol_buffered = aiofn_is_buffered_protocol(protocol)
        self._protocol_aiofn = isinstance(protocol, Protocol)
        return NoResult.OK

    cpdef set_protocol(self, protocol):
        self._check_thread("set_protocol")
        self._set_protocol(protocol)

    cpdef get_protocol(self):
        self._check_thread("get_protocol")
        return self._protocol

    cpdef get_extra_info(self, name, default=None):
        self._check_thread("get_extra_info")
        return self._extra.get(name, default)

    cpdef is_closing(self):
        self._check_thread("is_closing")
        return self._closing

    cpdef is_reading(self):
        self._check_thread("is_reading")
        return not self._closing and not self._read_paused

    cpdef pause_reading(self):
        self._check_thread("pause_reading")
        if self._closing or self._read_paused:
            return

        self._read_paused = True
        try:
            self._stop_reading()
        except BaseException:
            self._read_paused = False
            raise

        if unlikely(self._is_debug):
            _logger.debug("%r pauses reading", self)

    cpdef resume_reading(self):
        self._check_thread("resume_reading")
        if self._closing or not self._read_paused:
            return

        self._read_paused = False
        try:
            self._start_reading()
        except BaseException:
            self._read_paused = True
            raise

        if unlikely(self._is_debug):
            _logger.debug("%r resumes reading", self)

    cpdef abort(self):
        self._check_thread("abort")
        self._force_close(None)

    cdef NoResult _start_reading(self) except NoResult.EXC:
        raise NotImplementedError()

    cdef NoResult _stop_reading(self) except NoResult.EXC:
        raise NotImplementedError()

    cpdef _force_close(self, exc):
        raise NotImplementedError()

    cdef NoResult _fatal_error(self, exc, message='Fatal error on transport') except NoResult.EXC:
        if self._should_report_fatal_error(exc):
            self._report_protocol_exception(exc, message)
        elif unlikely(self._is_debug):
            _logger.debug("%r: %s", self, message, exc_info=True)

        self._force_close(exc)

    cdef inline NoResult _report_protocol_exception(self, exc, message) except NoResult.EXC:
        self._loop.call_exception_handler({
            'message': message,
            'exception': exc,
            'transport': self,
            'protocol': self._protocol,
        })

    cdef bint _should_report_fatal_error(self, exc) except -1:
        return True

    cdef NoResult _handle_error(self, message) except NoResult.EXC:
        _, exc, _ = sys.exc_info()

        if unlikely(self._is_debug):
            _logger.debug("%r: _handle_error(%s), exc=%s", self, message, exc)

        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise

        message = getattr(exc, constants.EXC_INFO_ATTR, message)
        self._fatal_error(exc, message)

    cpdef _call_protocol_connection_made(self):
        if self._protocol_connected or self._finalizing_close:
            return

        self._protocol_connected = True
        self._protocol.connection_made(self)

    cdef NoResult _call_protocol_connection_lost(self, exc) except NoResult.EXC:
        if self._protocol_connected:
            self._protocol_connected = False
            self._protocol.connection_lost(exc)
        return NoResult.OK

    cdef inline NoResult _call_protocol_data_received(self, data) except NoResult.EXC:
        try:
            if self._protocol_aiofn:
                (<Protocol> self._protocol).data_received(data)
            else:
                self._protocol.data_received(data)
        except:
            aiofn_add_info_and_reraise('Fatal error: protocol.data_received() call failed.')

    cdef object _call_protocol_eof_received(self):
        if not self._protocol_connected or self._protocol_eof_received:
            return None

        self._protocol_eof_received = True
        try:
            return self._protocol.eof_received()
        except:
            aiofn_add_info_and_reraise('Fatal error: protocol.eof_received() call failed.')

    cdef inline object _call_protocol_get_buffer(self, char** buf_ptr, Py_ssize_t* buf_len):
        try:
            if self._protocol_aiofn:
                buf = (<Protocol> self._protocol).get_buffer_c(-1, buf_ptr, buf_len)
            else:
                buf = self._protocol.get_buffer(-1)
                aiofn_unpack_simple_buffer(buf, buf_ptr, buf_len, PyBUF_WRITABLE)

            if buf_len[0] == 0:
                raise RuntimeError('get_buffer() returned an empty buffer')

            return buf
        except:
            aiofn_add_info_and_reraise('Fatal error: protocol.get_buffer() call failed.')

    cdef inline NoResult _call_protocol_buffer_updated(self, Py_ssize_t bytes_read) except NoResult.EXC:
        try:
            if self._protocol_aiofn:
                (<Protocol> self._protocol).buffer_updated(bytes_read)
            else:
                self._protocol.buffer_updated(bytes_read)
        except:
            aiofn_add_info_and_reraise('Fatal error: protocol.buffer_updated() call failed.')

    def write(self, data):
        self._check_thread("write")
        aiofn_validate_buffer(data)
        self.write_nocheck(data)

    def writelines(self, list_of_data):
        self._check_thread("writelines")
        if list_of_data:
            for data in list_of_data:
                aiofn_validate_buffer(data)
        else:
            return

        self.writelines_nocheck(list_of_data)

    def sendto(self, data, addr=None):
        self._check_thread("sendto")
        aiofn_validate_buffer(data)
        self.sendto_nocheck(data, addr)

    cpdef write_nocheck(self, data):
        raise NotImplementedError()

    cpdef writelines_nocheck(self, list_of_data):
        raise NotImplementedError()

    cpdef sendto_nocheck(self, data, addr):
        raise NotImplementedError()

    cdef NoResult write_c(self, char* ptr, Py_ssize_t sz) except NoResult.EXC:
        self.write(PyMemoryView_FromMemory(ptr, sz, PyBUF_READ))

    async def sendfile(self, file, offset, count):
        raise NotImplementedError()


cdef class Protocol:
    """Optional Cython protocol interface for avoiding Python method dispatch."""

    cpdef is_buffered_protocol(self):
        return None

    cpdef Py_ssize_t get_local_write_buffer_size(self) except -1:
        return 0

    cpdef get_buffer(self, Py_ssize_t hint):
        raise NotImplementedError()

    cdef NoResult get_buffer_c(self, Py_ssize_t hint, char** buf_ptr, Py_ssize_t* buf_len) except NoResult.EXC:
        buffer = self.get_buffer(hint)
        aiofn_unpack_simple_buffer(buffer, buf_ptr, buf_len, PyBUF_WRITABLE)

    cpdef buffer_updated(self, Py_ssize_t bytes_read):
        raise NotImplementedError()

    cpdef data_received(self, data):
        raise NotImplementedError()


cpdef aiofn_is_buffered_protocol(protocol):
    try:
        ret = getattr(protocol, 'is_buffered_protocol')()
        if ret is not None:
            return ret
    except AttributeError:
        pass

    return isinstance(protocol, asyncio.BufferedProtocol)


@cython.no_gc
cdef class WriteRequest:
    """Own an immutable write buffer and its current unsent memory range."""


cdef class SendFileRequest:
    """Mutable progress state for a file transfer queued with writes."""

    def __len__(self):
        return self.count


cdef SendFileRequest make_sendfile_request(file, offset, count):
    cdef:
        int fd
        object file_stat
        object available
        SendFileRequest request

    if "b" not in getattr(file, "mode", "b"):
        raise ValueError("file should be opened in binary mode")

    if not isinstance(offset, int):
        raise TypeError(f"offset must be a non-negative integer (got {offset!r})")
    if offset < 0:
        raise ValueError(f"offset must be a non-negative integer (got {offset!r})")

    if count is not None:
        if not isinstance(count, int):
            raise TypeError(f"count must be a positive integer (got {count!r})")
        if count <= 0:
            raise ValueError(f"count must be a positive integer (got {count!r})")

    try:
        fd = file.fileno()
    except (AttributeError, io.UnsupportedOperation) as exc:
        raise asyncio.SendfileNotAvailableError("not a regular file") from exc

    try:
        file_stat = os.fstat(fd)
    except OSError as exc:
        raise asyncio.SendfileNotAvailableError("not a regular file") from exc

    if not stat.S_ISREG(file_stat.st_mode):
        raise asyncio.SendfileNotAvailableError("not a regular file")

    available = max(0, file_stat.st_size - offset)
    if count is not None:
        available = min(count, available)

    request = <SendFileRequest>SendFileRequest.__new__(SendFileRequest)
    request.file = file
    request.fd = fd

    if sys.platform == "win32":
        # The proactor ABI uses a Windows HANDLE, not Python's CRT descriptor.
        request.native_handle = msvcrt.get_osfhandle(fd)
    else:
        request.native_handle = fd

    request.offset = offset
    request.count = available
    request.waiter = None
    return request


cdef WriteRequest make_write_request(object data):
    cdef WriteRequest req = <WriteRequest>WriteRequest.__new__(WriteRequest)
    req.data = aiofn_maybe_copy_buffer(data)
    aiofn_unpack_simple_buffer(req.data, &req.ptr, &req.size, 0)
    return req


cdef WriteRequest make_write_request_from_ptr(char* ptr, Py_ssize_t size):
    cdef WriteRequest req = <WriteRequest>WriteRequest.__new__(WriteRequest)
    req.data = PyBytes_FromStringAndSize(ptr, size)
    req.ptr = PyBytes_AS_STRING(req.data)
    req.size = size
    return req


cdef WriteRequest make_write_request_tail(object data, char* ptr, Py_ssize_t size):
    cdef WriteRequest req = <WriteRequest>WriteRequest.__new__(WriteRequest)
    req.data = aiofn_maybe_copy_buffer_tail(data, ptr, size)
    aiofn_unpack_simple_buffer(req.data, &req.ptr, &req.size, 0)
    return req


cdef class WriteWatermarks:
    """Track write-buffer limits and protocol pause/resume state."""

    def __init__(self, loop):
        self._loop = loop
        self._set_write_buffer_limits(None, None)
        self._paused = False

    cpdef tuple get_write_buffer_limits(self):
        return (self._low_water, self._high_water)

    cpdef set_write_buffer_limits(self, transport, app_protocol, Py_ssize_t write_buffer_size, high=None, low=None):
        self._set_write_buffer_limits(high, low)
        self.maybe_pause_protocol(transport, app_protocol, write_buffer_size)
        self.maybe_resume_protocol(transport, app_protocol, write_buffer_size)

    cpdef maybe_pause_protocol(self, transport, app_protocol, Py_ssize_t write_buffer_size):
        if write_buffer_size <= self._high_water:
            return
        if not self._paused:
            self._paused = True
            try:
                app_protocol.pause_writing()
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.pause_writing() failed',
                    'exception': exc,
                    'transport': transport,
                    'protocol': app_protocol,
                })

    cpdef maybe_resume_protocol(self, transport, app_protocol, Py_ssize_t write_buffer_size):
        if self._paused and write_buffer_size <= self._low_water:
            self._paused = False
            try:
                app_protocol.resume_writing()
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.resume_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': app_protocol,
                })

    cdef inline NoResult _set_write_buffer_limits(self, high, low) except NoResult.EXC:
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


cdef class FlowControlledWriter:
    """Manage write buffering and protocol flow control for one transport."""

    def __init__(self, Transport transport):
        self.transport = transport
        self._watermarks = WriteWatermarks(transport._loop)

        self.backlog = collections.deque()
        self.backlog_size = 0
        self.closed_write_count = 0

    cdef Py_ssize_t get_write_buffer_size(self) except -1:
        cdef Py_ssize_t total = self.backlog_size

        if self.transport._protocol_aiofn:
            total += (<Protocol>self.transport._protocol).get_local_write_buffer_size()

        return total

    cdef tuple get_write_buffer_limits(self):
        return self._watermarks.get_write_buffer_limits()

    cdef NoResult set_write_buffer_limits(self, high, low) except NoResult.EXC:
        self._watermarks.set_write_buffer_limits(
            self.transport,
            self.transport._protocol,
            self.get_write_buffer_size(),
            high,
            low,
        )

    cdef inline NoResult maybe_pause_protocol(self) except NoResult.EXC:
        self._watermarks.maybe_pause_protocol(
            self.transport, self.transport._protocol, self.get_write_buffer_size())

    cdef inline NoResult maybe_resume_protocol(self) except NoResult.EXC:
        self._watermarks.maybe_resume_protocol(
            self.transport, self.transport._protocol, self.get_write_buffer_size())

    cdef NoResult clear(self, object exc) except NoResult.EXC:
        cdef SendFileRequest request

        for item in self.backlog:
            if isinstance(item, SendFileRequest):
                request = <SendFileRequest>item
                if request.waiter is not None and not request.waiter.done():
                    if exc is None:
                        request.waiter.cancel()
                    else:
                        request.waiter.set_exception(exc)

        self.backlog.clear()
        self.backlog_size = 0

    cdef NoResult _ensure_progress(self) except NoResult.EXC:
        raise NotImplementedError()


cdef class StreamWriter(FlowControlledWriter):
    """Implement ordered byte-stream writes independently of the I/O driver."""

    def __init__(self, Transport transport, int fd, bint is_socket):
        FlowControlledWriter.__init__(self, transport)

        self.fd = fd
        self.is_socket = is_socket
        self.eof = False

    cdef NoResult write_nocheck(self, object data) except NoResult.EXC:
        if not self._pre_write_check("write"):
            return NoResult.OK

        cdef:
            char *data_ptr
            Py_ssize_t data_len
            WriteRequest request

        try:
            if self.backlog_size == 0:
                aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
                if data_len == 0:
                    return NoResult.OK

                request = self.try_write(data, data_ptr, data_len)
                if request is None:
                    return NoResult.OK
            else:
                request = make_write_request(data)
                if request.size == 0:
                    return NoResult.OK

            self.append_request(request)
            self._ensure_progress()
            self.maybe_pause_protocol()
        except:
            self.transport._handle_error('Fatal write error on transport')

    cdef NoResult writelines_nocheck(self, object list_of_data) except NoResult.EXC:
        if not self._pre_write_check("writelines"):
            return NoResult.OK

        cdef Py_ssize_t total_bytes_sent = 0

        try:
            if self.backlog_size == 0:
                if self.try_writelines(list_of_data, &total_bytes_sent):
                    return NoResult.OK

            self.append_lines_tail(list_of_data, total_bytes_sent)
            self._ensure_progress()
            self.maybe_pause_protocol()
        except:
            self.transport._handle_error('Fatal write error on transport')

    cdef NoResult write_c(self, char *ptr, Py_ssize_t size) except NoResult.EXC:
        if not self._pre_write_check("write_c"):
            return NoResult.OK

        if size <= 0:
            return NoResult.OK

        cdef WriteRequest request

        try:
            if not self.backlog:
                request = self.try_write(None, ptr, size)
                if request is None:
                    return NoResult.OK
            else:
                request = make_write_request_from_ptr(ptr, size)

            self.append_request(request)
            self._ensure_progress()
            self.maybe_pause_protocol()
        except:
            self.transport._handle_error('Fatal write error on transport')

    cdef object sendfile(self, file, offset, count):
        if self.eof:
            raise RuntimeError('Cannot call sendfile() after write_eof()')

        if self.transport._closing or self.transport._finalizing_close:
            raise RuntimeError("Transport is closing")

        cdef SendFileRequest request = make_sendfile_request(file, offset, count)
        if request.count == 0:
            return None

        try:
            if not self.backlog and self._try_sendfile(request):
                return None

            if unlikely(self.transport._is_debug):
                _logger.debug(
                    "%r: enqueue SendFileRequest(offset=%d,count=%d)",
                    self.transport,
                    request.offset,
                    request.count,
                )

            self.backlog.append(request)
            self.backlog_size += request.count
            self._ensure_progress()
            self.maybe_pause_protocol()

            # I/O drivers never complete an operation from its initiating call,
            # so the waiter can be allocated after progress has been scheduled.
            request.waiter = self.transport._loop.create_future()
            return request.waiter
        except:
            self.transport._handle_error('Fatal sendfile error on transport')
            raise

    cdef NoResult append_request(self, WriteRequest request) except NoResult.EXC:
        self.backlog.append(request)
        self.backlog_size += request.size

    cdef NoResult append_lines_tail(self, object list_of_data, Py_ssize_t bytes_sent) except NoResult.EXC:
        cdef:
            char *data_ptr
            Py_ssize_t data_len

        for data in list_of_data:
            aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
            if data_len <= bytes_sent:
                bytes_sent -= data_len
                continue

            if bytes_sent:
                self.append_request(make_write_request_tail(data, data_ptr + bytes_sent, data_len - bytes_sent))
                bytes_sent = 0
            elif data_len:
                self.append_request(make_write_request(data))

    cdef WriteRequest try_write(
        self,
        object data,
        char *ptr,
        Py_ssize_t size
    ):
        cdef Py_ssize_t bytes_sent = aiofn_write(self.fd, ptr, size, self.is_socket)
        if unlikely(self.transport._is_debug):
            _logger.debug("%r: aiofn_write(..., len=%d)=%d", self.transport, size, bytes_sent)

        if bytes_sent == size:
            return None

        if bytes_sent > 0:
            ptr += bytes_sent
            size -= bytes_sent

        if data is None:
            return make_write_request_from_ptr(ptr, size)
        else:
            return make_write_request_tail(data, ptr, size)

    cdef bint try_writelines(self, object list_of_data, Py_ssize_t *total_bytes_sent) except -1:
        cdef:
            char *data_ptr
            Py_ssize_t data_len
            Py_ssize_t bytes_sent = 0
            Py_ssize_t bytes_to_send = 0
            Py_ssize_t index = 0

        for data in list_of_data:
            aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
            if unlikely(data_len == 0):
                continue

            self.iovecs[index].iov_base = data_ptr
            self.iovecs[index].iov_len = data_len
            bytes_to_send += data_len
            if index < AIOFN_MAX_IOVEC - 1:
                index += 1
                continue

            bytes_sent = self.flush_iovecs(index + 1, total_bytes_sent)
            if bytes_sent != bytes_to_send:
                return False

            index = 0
            bytes_to_send = 0
            bytes_sent = 0

        if index:
            bytes_sent = self.flush_iovecs(index, total_bytes_sent)

        return bytes_sent == bytes_to_send

    cdef Py_ssize_t flush_iovecs(self, Py_ssize_t iovecs_count, Py_ssize_t *total_bytes_sent) except -2:
        cdef Py_ssize_t bytes_sent = aiofn_writev(self.fd, self.iovecs, iovecs_count, self.is_socket)
        if unlikely(self.transport._is_debug):
            _logger.debug(
                "%r: aiofn_writev(..., len(iovecs)=%d)=%d",
                self.transport, iovecs_count, bytes_sent)

        if bytes_sent > 0:
            total_bytes_sent[0] += bytes_sent

        return bytes_sent

    cdef bint _try_sendfile(self, SendFileRequest request) except -1:
        raise NotImplementedError()

    cdef NoResult consume(self, Py_ssize_t bytes_sent) except NoResult.EXC:
        cdef:
            Py_ssize_t request_size
            WriteRequest request

        assert 0 <= bytes_sent <= self.backlog_size
        self.backlog_size -= bytes_sent

        while bytes_sent:
            assert isinstance(self.backlog[0], WriteRequest)
            request = <WriteRequest>self.backlog[0]
            request_size = request.size
            if request_size <= bytes_sent:
                bytes_sent -= request_size
                self.backlog.popleft()
            else:
                request.ptr += bytes_sent
                request.size -= bytes_sent
                bytes_sent = 0
        return NoResult.OK

    cdef inline bint _pre_write_check(self, str meth) except -1:
        if self.eof:
            raise RuntimeError(f'Cannot call {meth}() after write_eof()')

        if unlikely(self.transport._finalizing_close):
            if self.closed_write_count >= _log_threshold_for_connlost_writes:
                _logger.warning(f'{meth}() called after connection lost.')
            self.closed_write_count += 1
            return False

        return True


cdef class DatagramWriter(FlowControlledWriter):
    """Implement message queueing independently of the datagram I/O driver."""

    def __init__(
        self,
        Transport transport,
        object address,
        Py_ssize_t header_size,
    ):
        FlowControlledWriter.__init__(self, transport)

        self.address = address or None
        self.header_size = header_size

    cdef NoResult sendto_nocheck(self, object data, object addr) except NoResult.EXC:
        if self.address is not None:
            if addr is not None and addr != self.address:
                raise ValueError(
                    f'Invalid address: must be None or {self.address}')
            addr = self.address

        addr = self._validate_address(addr)

        if unlikely(self.transport._finalizing_close and self.address is not None):
            if self.closed_write_count >= _log_threshold_for_connlost_writes:
                _logger.warning('socket.send() raised exception.')
            self.closed_write_count += 1
            return NoResult.OK

        try:
            if not self.backlog:
                if self._try_sendto(data, addr):
                    return NoResult.OK

            # Ensure that what we buffer is immutable.
            self.backlog.append((aiofn_maybe_copy_buffer(data), addr))
            self.backlog_size += len(data) + self.header_size
            self._ensure_progress()
            self.maybe_pause_protocol()
        except:
            self.transport._handle_error('Fatal write error on datagram transport')

        return NoResult.OK

    cdef object _validate_address(self, object addr):
        raise NotImplementedError()

    cdef bint _try_sendto(self, object data, object addr) except -1:
        raise NotImplementedError()
