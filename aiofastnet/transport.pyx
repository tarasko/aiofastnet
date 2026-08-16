"""Shared transport, protocol, write request, and flow-control primitives."""

import asyncio
import collections
import io
import os
import socket
import stat
import sys
import warnings
from asyncio.trsock import TransportSocket
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

        self._pause_reading()

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

    cdef inline NoResult _pause_reading(self) except NoResult.EXC:
        if self._read_paused:
            return NoResult.OK

        self._read_paused = True
        try:
            self._stop_reading()
        except BaseException:
            self._read_paused = False
            raise

        if unlikely(self._is_debug):
            _logger.debug("%r pauses reading", self)

    cdef NoResult _start_reading(self) except NoResult.EXC:
        raise NotImplementedError()

    cdef NoResult _stop_reading(self) except NoResult.EXC:
        raise NotImplementedError()

    cpdef _force_close(self, exc):
        raise NotImplementedError()

    cdef inline NoResult _schedule_finalize_close(self, exc) except NoResult.EXC:
        self._finalizing_close = True
        self._loop.call_soon((<object>self)._finalize_close, exc)

    cpdef _finalize_close(self, exc):
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

    cdef inline NoResult _call_protocol_datagram_received(self, data, addr) except NoResult.EXC:
        try:
            self._protocol.datagram_received(data, addr)
        except (KeyboardInterrupt, SystemExit):
            raise
        except BaseException as exc:
            self._report_protocol_exception(
                exc, 'Fatal error: protocol.datagram_received() call failed.')

    cdef inline NoResult _call_protocol_error_received(self, exc) except NoResult.EXC:
        try:
            self._protocol.error_received(exc)
        except (KeyboardInterrupt, SystemExit):
            raise
        except BaseException as caught:
            self._report_protocol_exception(
                caught, 'Fatal error: protocol.error_received() call failed.')

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


cdef class FDTransport(Transport):
    """Base for transports that own a nonblocking file descriptor."""

    def __init__(self, loop, file):
        Transport.__init__(self, loop)

        self._file = file
        self._fileno_obj = file.fileno()
        self._fileno = self._fileno_obj
        self._is_socket = isinstance(file, socket.socket)

        if self._is_socket:
            file.setblocking(False)
            aiofn_set_nodelay(file)
            self._extra['socket'] = TransportSocket(file)
            aiofn_set_socket_extra_info(self._extra, file)
        else:
            os.set_blocking(self._fileno_obj, False)

    def __repr__(self):
        return '[{}]'.format(' '.join(self._get_fd_repr_info()))

    def __del__(self):
        if self._file is not None:
            warnings.warn(f"unclosed {self.__class__.__name__} for {self._file}", ResourceWarning, source=self)
            self._file.close()

    cdef inline list _get_fd_repr_info(self):
        info = [f'fd={self._fileno_obj}', self.__class__.__name__]
        if self._file is None:
            info.append('closed')
        elif self._closing:
            info.append('closing')
        return info

    cdef bint _should_report_fatal_error(self, exc) except -1:
        # syscalls on FD based transports may raise OSError.
        # Such exceptions should not be reported to the loop exception_handler
        return not isinstance(exc, OSError)

    cpdef _finalize_close(self, exc):
        try:
            self._call_protocol_connection_lost(exc)
        finally:
            self._file.close()
            self._file = None
            self._protocol = None


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


cdef class WritableTransport(FDTransport):
    """Transport base with write buffering and protocol flow control."""

    def __init__(self, loop, file):
        FDTransport.__init__(self, loop, file)
        self._watermarks = WriteWatermarks(loop)

        self._write_backlog = collections.deque()
        self._write_backlog_size = 0
        self._closed_write_count = 0

    cpdef close(self):
        self._check_thread("close")
        if self._closing:
            return

        self._closing = True
        self._pause_reading()
        if self._write_backlog_size == 0:
            self._schedule_finalize_close(None)

    cpdef Py_ssize_t get_write_buffer_size(self) except -1:
        self._check_thread("get_write_buffer_size")
        return self._get_write_buffer_size_nocheck()

    cpdef tuple get_write_buffer_limits(self):
        self._check_thread("get_write_buffer_limits")
        return self._watermarks.get_write_buffer_limits()

    cpdef set_write_buffer_limits(self, high=None, low=None):
        self._check_thread("set_write_buffer_limits")
        self._watermarks.set_write_buffer_limits(
            self,
            self._protocol,
            self._get_write_buffer_size_nocheck(),
            high,
            low,
        )

    cdef inline Py_ssize_t _get_write_buffer_size_nocheck(self) except -1:
        cdef Py_ssize_t total = self._write_backlog_size
        if self._protocol_aiofn:
            total += (<Protocol>self._protocol).get_local_write_buffer_size()

        return total

    cdef inline NoResult _maybe_pause_protocol(self) except NoResult.EXC:
        self._watermarks.maybe_pause_protocol(self, self._protocol, self._get_write_buffer_size_nocheck())

    cdef inline NoResult _maybe_resume_protocol(self) except NoResult.EXC:
        self._watermarks.maybe_resume_protocol(self, self._protocol, self._get_write_buffer_size_nocheck())

    cdef NoResult _clear_write_backlog(self, object exc) except NoResult.EXC:
        cdef SendFileRequest request

        for item in self._write_backlog:
            if isinstance(item, SendFileRequest):
                request = <SendFileRequest>item
                if request.waiter is not None and not request.waiter.done():
                    if exc is None:
                        request.waiter.cancel()
                    else:
                        request.waiter.set_exception(exc)

        self._write_backlog.clear()
        self._write_backlog_size = 0

    cdef NoResult _start_backlog_writing(self) except NoResult.EXC:
        raise NotImplementedError()

    cdef NoResult _stop_backlog_writing(self) except NoResult.EXC:
        raise NotImplementedError()


cdef class StreamTransport(WritableTransport):
    """Transport base implementing ordered byte-stream write queues."""

    def __init__(self, loop, file, server=None):
        WritableTransport.__init__(self, loop, file)

        self._server = server
        self._write_eof = False
        self._sendfile_compatible = False

    def __repr__(self):
        info = self._get_fd_repr_info()
        info.append(f'wbuf_size={self._write_backlog_size}')
        return '[{}]'.format(' '.join(info))

    def __del__(self):
        if self._file is not None:
            warnings.warn(f"unclosed {self.__class__.__name__} for {self._file}", ResourceWarning, source=self)
            self._file.close()
            if self._server is not None:
                self._server._detach(self)

    cdef NoResult _release_backend_resources(self) except NoResult.EXC:
        return NoResult.OK

    cpdef _finalize_close(self, exc):
        cdef object server

        try:
            self._call_protocol_connection_lost(exc)
        finally:
            server = self._server
            try:
                self._release_backend_resources()
            finally:
                try:
                    if self._file is not None:
                        self._file.close()
                finally:
                    self._file = None
                    self._protocol = None
                    if server is not None:
                        server._detach(self)
                        self._server = None

    cpdef write_nocheck(self, data):
        if not self.__pre_write_check("write"):
            return

        cdef:
            char *data_ptr
            Py_ssize_t data_len
            WriteRequest request

        try:
            if self._write_backlog_size == 0:
                aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
                if data_len == 0:
                    return

                request = self._try_write(data, data_ptr, data_len)
                if request is None:
                    return
            else:
                request = make_write_request(data)
                if request.size == 0:
                    return

            self.__append_request(request)
            self._start_backlog_writing()
            self._maybe_pause_protocol()
        except:
            self._handle_error('Fatal write error on transport')

    cpdef writelines_nocheck(self, list_of_data):
        if not self.__pre_write_check("writelines"):
            return

        cdef Py_ssize_t total_bytes_sent = 0

        try:
            if self._write_backlog_size == 0:
                if self._try_writelines(list_of_data, &total_bytes_sent):
                    return

            self.__append_lines_tail(list_of_data, total_bytes_sent)
            self._start_backlog_writing()
            self._maybe_pause_protocol()
        except:
            self._handle_error('Fatal write error on transport')

    cdef NoResult write_c(self, char *ptr, Py_ssize_t size) except NoResult.EXC:
        if not self.__pre_write_check("write_c"):
            return NoResult.OK

        if size <= 0:
            return NoResult.OK

        cdef WriteRequest request

        try:
            if self._write_backlog_size == 0:
                request = self._try_write(None, ptr, size)
                if request is None:
                    return NoResult.OK
            else:
                request = make_write_request_from_ptr(ptr, size)

            self.__append_request(request)
            self._start_backlog_writing()
            self._maybe_pause_protocol()
        except:
            self._handle_error('Fatal write error on transport')

    def sendfile(self, file, offset, count):
        self._check_thread("sendfile")

        # This private asyncio flag is also used by third-party libraries to
        # disable native sendfile and select their fallback implementation.
        if not self._sendfile_compatible:
            raise NotImplementedError()

        if self._write_eof:
            raise RuntimeError('Cannot call sendfile() after write_eof()')

        if self._closing or self._finalizing_close:
            raise RuntimeError("Transport is closing")

        cdef SendFileRequest request = make_sendfile_request(file, offset, count)
        if request.count == 0:
            return None

        try:
            if self._write_backlog_size == 0 and self._try_sendfile(request):
                return None

            if unlikely(self._is_debug):
                _logger.debug(
                    "%r: enqueue SendFileRequest(offset=%d,count=%d)",
                    self,
                    request.offset,
                    request.count,
                )

            self._write_backlog.append(request)
            self._write_backlog_size += request.count
            self._start_backlog_writing()
            self._maybe_pause_protocol()

            # I/O drivers never complete an operation from its initiating call,
            # so the waiter can be allocated after progress has been scheduled.
            request.waiter = self._loop.create_future()
            return request.waiter
        except:
            self._handle_error('Fatal sendfile error on transport')
            raise

    cdef WriteRequest _try_write(
        self,
        object data,
        char *ptr,
        Py_ssize_t size
    ):
        cdef Py_ssize_t bytes_sent = aiofn_write(self._fileno, ptr, size, self._is_socket)
        if unlikely(self._is_debug):
            _logger.debug("%r: aiofn_write(..., len=%d)=%d", self, size, bytes_sent)

        if bytes_sent == size:
            return None

        if bytes_sent > 0:
            ptr += bytes_sent
            size -= bytes_sent

        if data is None:
            return make_write_request_from_ptr(ptr, size)
        else:
            return make_write_request_tail(data, ptr, size)

    cdef bint _try_writelines(self, object list_of_data, Py_ssize_t *total_bytes_sent) except -1:
        cdef:
            WriteRequest request
            bint from_write_backlog = list_of_data is self._write_backlog
            char *data_ptr
            Py_ssize_t data_len
            Py_ssize_t bytes_sent = 0
            Py_ssize_t bytes_to_send = 0
            Py_ssize_t index = 0

        for item in list_of_data:
            if from_write_backlog:
                if isinstance(item, SendFileRequest):
                    break

                assert isinstance(item, WriteRequest)
                request = <WriteRequest>item
                data_ptr = request.ptr
                data_len = request.size
            else:
                aiofn_unpack_simple_buffer(item, &data_ptr, &data_len, 0)
                if unlikely(data_len == 0):
                    continue

            self._write_buffers[index].iov_base = data_ptr
            self._write_buffers[index].iov_len = data_len
            bytes_to_send += data_len
            if index < AIOFN_MAX_IOVEC - 1:
                index += 1
                continue

            bytes_sent = self._flush_iovecs(index + 1, total_bytes_sent)
            if bytes_sent != bytes_to_send:
                return False

            index = 0
            bytes_to_send = 0
            bytes_sent = 0

        if index:
            bytes_sent = self._flush_iovecs(index, total_bytes_sent)

        return bytes_sent == bytes_to_send

    cdef Py_ssize_t _flush_iovecs(self, Py_ssize_t iovecs_count, Py_ssize_t *total_bytes_sent) except -2:
        cdef Py_ssize_t bytes_sent = aiofn_writev(self._fileno, self._write_buffers, iovecs_count, self._is_socket)
        if unlikely(self._is_debug):
            _logger.debug(
                "%r: aiofn_writev(..., len(iovecs)=%d)=%d",
                self, iovecs_count, bytes_sent)

        if bytes_sent > 0:
            total_bytes_sent[0] += bytes_sent

        return bytes_sent

    cdef bint _try_sendfile(self, SendFileRequest request) except -1:
        raise NotImplementedError()

    cdef NoResult _consume_write_backlog(self, Py_ssize_t bytes_sent) except NoResult.EXC:
        cdef:
            Py_ssize_t request_size
            WriteRequest request

        assert 0 <= bytes_sent <= self._write_backlog_size
        self._write_backlog_size -= bytes_sent

        while bytes_sent:
            assert isinstance(self._write_backlog[0], WriteRequest)
            request = <WriteRequest>self._write_backlog[0]
            request_size = request.size
            if request_size <= bytes_sent:
                bytes_sent -= request_size
                self._write_backlog.popleft()
            else:
                request.ptr += bytes_sent
                request.size -= bytes_sent
                bytes_sent = 0

    cdef inline bint __pre_write_check(self, str meth) except -1:
        if self._write_eof:
            raise RuntimeError(f'Cannot call {meth}() after write_eof()')

        if unlikely(self._finalizing_close):
            if self._closed_write_count >= _log_threshold_for_connlost_writes:
                _logger.warning(f'{meth}() called after connection lost.')
            self._closed_write_count += 1
            return False

        return True

    cdef NoResult __append_request(self, WriteRequest request) except NoResult.EXC:
        self._write_backlog.append(request)
        self._write_backlog_size += request.size

    cdef NoResult __append_lines_tail(self, object list_of_data, Py_ssize_t bytes_sent) except NoResult.EXC:
        cdef:
            char *data_ptr
            Py_ssize_t data_len

        for data in list_of_data:
            aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
            if data_len <= bytes_sent:
                bytes_sent -= data_len
                continue

            if bytes_sent:
                self.__append_request(make_write_request_tail(data, data_ptr + bytes_sent, data_len - bytes_sent))
                bytes_sent = 0
            elif data_len:
                self.__append_request(make_write_request(data))


cdef class DatagramTransport(WritableTransport):
    """Transport base implementing message-oriented write queues."""

    def __init__(
        self,
        loop,
        file,
        object address,
        Py_ssize_t header_size,
    ):
        WritableTransport.__init__(self, loop, file)

        cdef:
            char raw_addr[256]
            unsigned int raw_addr_len = 0
            int family = file.family

        # Try to resolve address, aiofn_pyaddr_to_sockaddr fail if DNS lookup
        # is required. Address that we get, must already have been resolved
        if address is not None:
            aiofn_pyaddr_to_sockaddr(family, address, raw_addr, &raw_addr_len)
            self._address = address
        else:
            self._address = None
        self._datagram_header_size = header_size

        self._family = family
        self._has_connection = self._extra['peername'] is not None

    cpdef sendto_nocheck(self, data, addr):
        if self._address is not None:
            if addr is not None and addr != self._address:
                raise ValueError(
                    f'Invalid address: must be None or {self._address}')
            addr = self._address

        addr = self._validate_address(addr)

        if unlikely(self._finalizing_close and self._address is not None):
            if self._closed_write_count >= _log_threshold_for_connlost_writes:
                _logger.warning('socket.send() raised exception.')
            self._closed_write_count += 1
            return

        try:
            if self._write_backlog_size == 0:
                if self._try_sendto(data, addr):
                    return

            # Ensure that what we buffer is immutable.
            self._write_backlog.append((aiofn_maybe_copy_buffer(data), addr))
            self._write_backlog_size += len(data) + self._datagram_header_size
            self._start_backlog_writing()
            self._maybe_pause_protocol()
        except:
            self._handle_error('Fatal write error on datagram transport')

    cdef object _validate_address(self, object addr):
        cdef:
            char raw_addr[256]
            unsigned int raw_addr_len = 0

        if not self._has_connection:
            # Datagram endpoint creation resolves INET addresses; resolving here could block the event-loop thread.
            aiofn_pyaddr_to_sockaddr(self._family, addr, raw_addr, &raw_addr_len)

        return addr

    cdef bint _try_sendto(self, object data, object addr) except -1:
        cdef:
            char *buf_ptr
            Py_ssize_t buf_len
            Py_ssize_t bytes_sent
            char raw_addr[256]
            unsigned int raw_addr_len = 0
            void *raw_addr_ptr = NULL

        try:
            aiofn_unpack_simple_buffer(data, &buf_ptr, &buf_len, 0)
            if not self._has_connection:
                aiofn_pyaddr_to_sockaddr(self._family, addr, raw_addr, &raw_addr_len)
                raw_addr_ptr = raw_addr

            bytes_sent = aiofn_sendto(self._fileno, buf_ptr, buf_len, raw_addr_ptr, raw_addr_len)
            if unlikely(self._is_debug):
                _logger.debug("%r: aiofn_sendto(...,len=%d)=%d", self, buf_len, bytes_sent)
            if bytes_sent == -1:
                return False

            return True
        except (BlockingIOError, InterruptedError):
            return False
        except OSError as exc:
            self._call_protocol_error_received(exc)
            return True
