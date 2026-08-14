"""Shared transport, protocol, write request, and flow-control primitives."""

import asyncio
import sys
from logging import getLogger

import cython
from cpython.buffer cimport PyBUF_READ, PyBUF_WRITABLE
from cpython.bytes cimport *
from cpython.memoryview cimport PyMemoryView_FromMemory
from cpython.pythread cimport PyThread_get_thread_ident

from . import constants
from .utils cimport *


cdef:
    object _logger = getLogger('aiofastnet')


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
