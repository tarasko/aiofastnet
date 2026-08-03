"""Native transports and protocols.

The transport hierarchy is:

    Transport
    |-- SelectorTransport
    |   |-- SelectorReadPipeTransport
    |   `-- SelectorWritableTransport
    |       |-- SelectorDatagramTransport
    |       `-- SelectorStreamTransport
    |           |-- SelectorSocketTransport
    |           `-- SelectorWritePipeTransport
    `-- SSLTransportBase
        |-- SSLTransport_Socket
        `-- SSLTransport_Transport

Transport owns loop/thread/debug state and the validated public write methods.
SelectorTransport owns descriptor, protocol, read-readiness, and connection
lifecycle state. SelectorWritableTransport adds state shared by all writable
selector transports. SelectorStreamTransport implements ordered byte-stream writes.
"""

import collections
import errno
import os
import socket
import stat
import sys
import warnings
import asyncio
from typing import Optional

from asyncio.trsock import TransportSocket
from logging import getLogger

import cython
from cpython.ref cimport Py_XDECREF
from cpython.memoryview cimport PyMemoryView_FromMemory
from cpython.buffer cimport PyBUF_READ, PyBUF_WRITABLE
from cpython.bytes cimport *
from cpython.pythread cimport PyThread_get_thread_ident

from . import constants
from .utils import aiofn_set_result_unless_cancelled as _set_result_unless_cancelled_callback

from .utils cimport *


cdef:
    object _logger = getLogger('aiofastnet')
    object _os_sendfile = getattr(os, "sendfile", None)
    Py_ssize_t _data_received_max_size = constants.DATA_RECEIVED_MAX_SIZE
    Py_ssize_t _datagram_received_max_size = constants.DATAGRAM_RECEIVED_MAX_SIZE
    Py_ssize_t _max_reads_per_socket_per_cycle = constants.MAX_READS_PER_SOCKET_PER_CYCLE
    size_t _log_threshold_for_connlost_writes = constants.LOG_THRESHOLD_FOR_CONNLOST_WRITES


cdef class Transport:
    """Internal transport interface implemented by aiofastnet transports."""

    def __init__(self, loop):
        assert loop is not None
        self._loop = loop
        self._thread_id = PyThread_get_thread_ident()
        self._is_debug = loop.get_debug()

    cdef inline NoResult _check_thread(self, meth) except NoResult.EXC:
        cdef unsigned long curr_thread_id = PyThread_get_thread_ident()
        if self._thread_id != curr_thread_id:
            raise RuntimeError(
                f"{self.__class__.__name__}.{meth} called from a wrong thread: "
                f"transport thread id={self._thread_id}, "
                f"curr thread_id={curr_thread_id}"
            )

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


cdef class SendFileRequest:
    """Mutable progress state for a sendfile operation queued with writes."""

    cdef:
        object fileno
        object offset
        object count
        object waiter


cdef SendFileRequest _make_send_file_request(file, offset, count):
    cdef SendFileRequest req = <SendFileRequest>SendFileRequest.__new__(SendFileRequest)
    req.fileno = file.fileno()
    req.offset = offset
    if count is None:
        req.count = max(0, os.fstat(file.fileno()).st_size - offset)
    else:
        req.count = count
    req.waiter = None
    return req


@cython.no_gc
cdef class WriteRequest:
    """Own an immutable write buffer and its current unsent memory range."""

    cdef:
        object data
        char* ptr
        Py_ssize_t size


cdef WriteRequest _make_write_request(object data):
    cdef WriteRequest req = <WriteRequest>WriteRequest.__new__(WriteRequest)
    req.data = aiofn_maybe_copy_buffer(data)
    aiofn_unpack_simple_buffer(req.data, &req.ptr, &req.size, 0)
    return req


cdef WriteRequest _make_write_request_from_ptr(char* ptr, Py_ssize_t size):
    cdef WriteRequest req = <WriteRequest>WriteRequest.__new__(WriteRequest)
    req.data = PyBytes_FromStringAndSize(ptr, size)
    req.ptr = PyBytes_AS_STRING(req.data)
    req.size = size
    return req


cdef WriteRequest _make_write_request_tail(object data, char* ptr, Py_ssize_t size):
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


cdef class SelectorTransport(Transport):
    """Manage common selector descriptor, protocol, read, and close state."""

    cdef:
        object _protocol
        bint _protocol_buffered
        bint _protocol_aiofn
        bint _protocol_connected
        dict _extra

        object _file
        object _fileno_obj
        int _fileno
        bint _is_socket

        bint _read_paused

        bint _connection_lost_scheduled
        bint _closing

    def __init__(self, loop, file, protocol):
        Transport.__init__(self, loop)
        self._extra = {}
        self._file = file
        self._fileno_obj = file.fileno()
        self._fileno = self._fileno_obj
        self._is_socket = True
        if isinstance(file, socket.socket):
            file.setblocking(False)
        else:
            os.set_blocking(self._fileno_obj, False)

        self._read_paused = False

        self._connection_lost_scheduled = False
        self._closing = False

        self.set_protocol(protocol)

    cdef inline list _get_repr_info(self):
        info = [f'fd={self._fileno_obj}', self.__class__.__name__]
        if self._file is None:
            info.append('closed')
        elif self._closing:
            info.append('closing')
        return info

    def __repr__(self):
        return '[{}]'.format(' '.join(self._get_repr_info()))

    def __del__(self):
        if self._file is not None:
            warnings.warn(f"unclosed {self.__class__.__name__} for {self._file}", ResourceWarning, source=self)
            self._file.close()

    cpdef set_protocol(self, protocol):
        self._check_thread("set_protocol")
        self._protocol = protocol
        self._protocol_buffered = aiofn_is_buffered_protocol(protocol)
        self._protocol_aiofn = isinstance(protocol, Protocol)
        self._protocol_connected = True

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

        self._loop.remove_reader(self._fileno_obj)
        self._read_paused = True

        if unlikely(self._is_debug):
            _logger.debug("%r pauses reading", self)

    cpdef resume_reading(self):
        self._check_thread("resume_reading")
        if self._closing or not self._read_paused:
            return

        self._loop.add_reader(self._fileno_obj, self._read_ready)
        self._read_paused = False

        if unlikely(self._is_debug):
            _logger.debug("%r resumes reading", self)

    cpdef abort(self):
        self._check_thread("abort")
        self._force_close(None)

    cpdef close(self):
        self.abort()

    cdef inline NoResult _fatal_error(self, exc, message='Fatal error on transport') except NoResult.EXC:
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

    # May be used by create_connection/create_server
    # Keep cpdef
    cpdef _force_close(self, exc):
        if self._connection_lost_scheduled:
            return
        if not self._closing:
            self._closing = True
            self._loop.remove_reader(self._fileno_obj)
        self._connection_lost_scheduled = True
        self._loop.call_soon(self._call_connection_lost, exc)

    cdef inline NoResult _call_protocol_data_received(self, data) except NoResult.EXC:
        try:
            if self._protocol_aiofn:
                (<Protocol> self._protocol).data_received(data)
            else:
                self._protocol.data_received(data)
        except:
            aiofn_add_info_and_reraise('Fatal error: protocol.data_received() call failed.')

    cdef inline _call_protocol_eof_received(self):
        try:
            return self._protocol.eof_received()
        except:
            aiofn_add_info_and_reraise('Fatal error: protocol.eof_received() call failed.')

    def _call_connection_lost(self, exc):
        try:
            if self._protocol_connected:
                self._protocol.connection_lost(exc)
        finally:
            self._file.close()
            self._file = None
            self._protocol = None

    cdef inline NoResult _handle_error(self, message) except NoResult.EXC:
        _, exc, _ = sys.exc_info()

        if unlikely(self._is_debug):
            _logger.debug("%r: _handle_error(%s), exc=%s", self, message, exc)

        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise

        message = getattr(exc, constants.EXC_INFO_ATTR, message)
        self._fatal_error(exc, message)

cdef class SelectorWritableTransport(SelectorTransport):
    """Manage write backlog, readiness, flow control, and close state.

    Subclasses provide the actual stream write or datagram send operations.
    """

    cdef:
        WriteWatermarks _write_watermarks

        object _write_backlog
        Py_ssize_t _write_backlog_size
        bint _write_ready_registered
        size_t _closed_write_count

        public bint _sendfile_compatible

    def __init__(self, loop, file, protocol):
        SelectorTransport.__init__(self, loop, file, protocol)
        self._write_backlog = collections.deque()
        self._write_backlog_size = 0
        self._write_ready_registered = False
        self._closed_write_count = 0

        self._write_watermarks = WriteWatermarks(loop)
        self._sendfile_compatible = False

    def __repr__(self):
        info = self._get_repr_info()
        info.append(f'wbuf_size={self._write_backlog_size}')
        return '[{}]'.format(' '.join(info))

    cpdef tuple get_write_buffer_limits(self):
        self._check_thread("get_write_buffer_limits")
        return self._write_watermarks.get_write_buffer_limits()

    cpdef set_write_buffer_limits(self, high=None, low=None):
        self._check_thread("set_write_buffer_limits")
        self._write_watermarks.set_write_buffer_limits(
            self, self._protocol, self.get_write_buffer_size(), high, low)

    cpdef close(self):
        self._check_thread("close")
        if self._closing:
            return
        self._closing = True
        self._loop.remove_reader(self._fileno_obj)
        if self._write_backlog_size == 0:
            self._connection_lost_scheduled = True
            self._drop_writer()
            self._loop.call_soon(self._call_connection_lost, None)

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

    cdef inline NoResult _maybe_resume_protocol(self) except NoResult.EXC:
        self._write_watermarks.maybe_resume_protocol(self, self._protocol, self._get_write_buffer_size_nocheck())

    cdef inline NoResult _ensure_writer(self) except NoResult.EXC:
        if unlikely(self._is_debug):
            _logger.debug("%r: _ensure_writer called, conn_lost=%s, already_registered=%s",
                          self, self._connection_lost_scheduled, self._write_ready_registered)

        if self._connection_lost_scheduled or self._write_ready_registered:
            return NoResult.OK
        self._write_ready_registered = True
        self._loop.add_writer(self._fileno_obj, self._write_ready)

    cdef inline NoResult _drop_writer(self) except NoResult.EXC:
        if unlikely(self._is_debug):
            _logger.debug("%r: _drop_writer called", self)

        if not self._write_ready_registered:
            return NoResult.OK
        self._write_ready_registered = False
        self._loop.remove_writer(self._fileno_obj)

    def _write_ready(self):
        raise NotImplementedError()

    cdef bint _should_report_fatal_error(self, exc) except -1:
        return not isinstance(exc, OSError)

    cpdef _force_close(self, exc):
        if self._connection_lost_scheduled:
            return
        if self._write_backlog:
            self._clear_write_backlog(exc)
            self._drop_writer()
        SelectorTransport._force_close(self, exc)

    cdef inline NoResult _clear_write_backlog(self, exc) except NoResult.EXC:
        cdef SendFileRequest req
        for data in self._write_backlog:
            if isinstance(data, SendFileRequest):
                req = <SendFileRequest>data
                if req.waiter is not None and not req.waiter.done():
                    req.waiter.set_exception(exc)
        self._write_backlog.clear()
        self._write_backlog_size = 0


cdef class SelectorStreamTransport(SelectorWritableTransport):
    """Implement ordered byte-stream writes, writev, EOF, and sendfile queues."""

    cdef:
        bint _eof
        aiofn_iovec _iovecs[256]

    def __init__(self, loop, file, protocol):
        SelectorWritableTransport.__init__(self, loop, file, protocol)
        self._eof = False

    cpdef write_nocheck(self, data):
        if self._eof:
            raise RuntimeError('Cannot call write() after write_eof()')
        if not data:
            return

        if unlikely(self._connection_lost_scheduled):
            if self._closed_write_count >= _log_threshold_for_connlost_writes:
                _logger.warning('write() called after connection lost.')
            self._closed_write_count += 1
            return

        cdef:
            char* data_ptr
            Py_ssize_t data_len
            WriteRequest req

        try:
            if self._write_backlog_size == 0:
                aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
                req = self._write_one(data, data_ptr, data_len)
                if req is None:
                    return

                # Not all was written; register write handler.
                self._ensure_writer()
            else:
                req = _make_write_request(data)

            self._write_backlog.append(req)
            self._write_backlog_size += req.size
            self._maybe_pause_protocol()
        except:
            self._handle_error('Fatal write error on transport')

    cdef inline Py_ssize_t _flush_iovecs(self, Py_ssize_t num_iovecs, Py_ssize_t* total_bytes_sent) except -2:
        cdef Py_ssize_t bytes_sent = aiofn_writev(self._fileno, self._iovecs, num_iovecs, self._is_socket)
        if unlikely(self._is_debug):
            _logger.debug("%r: aiofn_writev(..., len(iovecs)=%d)=%d", self, num_iovecs, bytes_sent)
        if bytes_sent > 0:
            total_bytes_sent[0] += bytes_sent
        return bytes_sent

    cdef inline bint _try_write_list_of_data(self, list_of_data, Py_ssize_t* total_bytes_sent) except -1:
        """
        Send as much data as possible from list_of_data, store actual number of bytes sent into total_bytes_sent.
        Return True if all data from list_of_data were sent or False otherwise.
        list_of_data may contain SendFileRequest object. If this is the case it will be treated as the actual end 
        of the list. If all data before SendFileRequest is successfully sent then True is returned.
        """

        cdef:
            char* data_ptr
            Py_ssize_t data_len
            Py_ssize_t bytes_sent = 0
            Py_ssize_t bytes_to_send = 0
            Py_ssize_t idx = 0

        for data in list_of_data:
            # Optimization: if it is a direct write from writelines than do not do somewhat expensive testing
            # for data types. Just do aiofn_unpack_simple_buffer.
            if list_of_data is self._write_backlog:
                if isinstance(data, WriteRequest):
                    data_ptr = (<WriteRequest>data).ptr
                    data_len = (<WriteRequest>data).size
                elif isinstance(data, SendFileRequest):
                    break
                else:
                    assert False, "unsupported type in the _write_backlog, must be either SendFileRequest or WriteRequest"
            else:
                aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)

            if unlikely(data_len == 0):
                continue

            self._iovecs[idx].iov_base = data_ptr
            self._iovecs[idx].iov_len = data_len
            bytes_to_send += data_len
            if idx < AIOFN_MAX_IOVEC - 1:
                idx += 1
                continue

            # Intermediate flush, because we ran out of iovecs
            bytes_sent = self._flush_iovecs(idx + 1, total_bytes_sent)
            if bytes_sent != bytes_to_send:
                return False

            idx = 0
            bytes_to_send = 0
            bytes_sent = 0

        # Final flush
        if idx > 0:
            bytes_sent = self._flush_iovecs(idx, total_bytes_sent)

        return bytes_sent == bytes_to_send

    cdef inline NoResult _add_list_of_data_tail_to_backlog(self, list_of_data, Py_ssize_t total_bytes_sent) except NoResult.EXC:
        cdef:
            char* data_ptr
            Py_ssize_t data_len
            WriteRequest req

        for data in list_of_data:
            aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
            if data_len <= total_bytes_sent:
                total_bytes_sent -= data_len
                continue
            elif total_bytes_sent <= 0:
                req = _make_write_request(data)
                self._write_backlog.append(req)
                self._write_backlog_size += req.size
            else:
                data_ptr += total_bytes_sent
                data_len -= total_bytes_sent
                total_bytes_sent = 0
                req = _make_write_request_tail(data, data_ptr, data_len)
                self._write_backlog.append(req)
                self._write_backlog_size += req.size

        if self._write_backlog_size > 0:
            self._ensure_writer()
            self._maybe_pause_protocol()

    cpdef writelines_nocheck(self, list_of_data):
        if self._eof:
            raise RuntimeError('Cannot call writelines() after write_eof()')

        if unlikely(self._connection_lost_scheduled):
            if self._closed_write_count >= _log_threshold_for_connlost_writes:
                _logger.warning('writelines() called after connection lost.')
            self._closed_write_count += 1
            return

        cdef Py_ssize_t total_bytes_sent = 0

        try:
            if self._write_backlog_size == 0:
                if self._try_write_list_of_data(list_of_data, &total_bytes_sent):
                    return

            self._add_list_of_data_tail_to_backlog(list_of_data, total_bytes_sent)
        except:
            self._handle_error('Fatal write error on transport')

    cdef NoResult write_c(self, char* ptr, Py_ssize_t sz) except NoResult.EXC:
        cdef WriteRequest req

        if sz <= 0:
            return NoResult.OK

        if unlikely(self._connection_lost_scheduled):
            if self._closed_write_count >= _log_threshold_for_connlost_writes:
                _logger.warning('write_c() called after connection lost.')
            self._closed_write_count += 1
            return NoResult.OK

        try:
            if self._write_backlog_size == 0:
                req = self._write_one(None, ptr, sz)
                if req is None:
                    return NoResult.OK

                # Not all was written; register write handler.
                self._ensure_writer()
            else:
                req = _make_write_request_from_ptr(ptr, sz)

            self._write_backlog.append(req)
            self._write_backlog_size += req.size
            self._maybe_pause_protocol()
        except:
            self._handle_error('Fatal write error on transport')

    cpdef can_write_eof(self):
        return True

    cpdef write_eof(self):
        self._check_thread("write_eof")
        if self._closing or self._eof:
            return
        self._eof = True
        if self._write_backlog_size == 0:
            self._write_eof_now()

    cdef NoResult _write_eof_now(self) except NoResult.EXC:
        raise NotImplementedError()

    cdef inline WriteRequest _write_one(self, object data, char* data_ptr, Py_ssize_t data_len):
        """
        Returns None if all data has been sent, or remaining data
        """
        cdef Py_ssize_t bytes_sent

        bytes_sent = aiofn_write(self._fileno, data_ptr, data_len, self._is_socket)
        if unlikely(self._is_debug):
            _logger.debug("%r aiofn_write(...,len=%d)=%d", self,
                          data_len, bytes_sent)

        if bytes_sent == data_len:
            return None

        if bytes_sent > 0:
            data_ptr += bytes_sent
            data_len -= bytes_sent

        if data is None:
            return _make_write_request_from_ptr(data_ptr, data_len)
        else:
            return _make_write_request_tail(data, data_ptr, data_len)

    cdef inline NoResult _adjust_write_backlog(self, Py_ssize_t bytes_sent) except NoResult.EXC:
        cdef:
            Py_ssize_t data_len
            WriteRequest req

        if bytes_sent > 0:
            self._write_backlog_size -= bytes_sent

        while bytes_sent > 0:
            req = <WriteRequest>self._write_backlog[0]
            data_len = req.size
            if data_len <= bytes_sent:
                bytes_sent -= data_len
                self._write_backlog.popleft()
                if unlikely(self._is_debug):
                    _logger.debug("%r: wrote backlog item of %d bytes", self, data_len)
            else:
                req.ptr += bytes_sent
                req.size -= bytes_sent
                if unlikely(self._is_debug):
                    _logger.debug("%r: partially wrote backlog item of %d bytes", self, bytes_sent)
                break

    cdef inline bint _try_sendfile_from_backlog_top(self) except -1:
        cdef SendFileRequest sendfile_req = <SendFileRequest>self._write_backlog[0]

        orig_req_size = sendfile_req.count

        cdef bint all_sent = self._try_sendfile(sendfile_req)
        if all_sent:
            self._write_backlog.popleft()
            if not sendfile_req.waiter.done():
                sendfile_req.waiter.set_result(None)
        self._write_backlog_size -= <Py_ssize_t>(orig_req_size - sendfile_req.count)

        return all_sent

    cdef inline NoResult _flush_write_backlog(self) except NoResult.EXC:
        cdef:
            Py_ssize_t bytes_sent
            bint all_sent = True

        while self._write_backlog_size != 0 and all_sent:
            if isinstance(self._write_backlog[0], SendFileRequest):
                all_sent = self._try_sendfile_from_backlog_top()
            else:
                bytes_sent = 0
                all_sent = self._try_write_list_of_data(self._write_backlog, &bytes_sent)
                self._adjust_write_backlog(bytes_sent)

    def _write_ready(self):
        assert self._write_backlog, 'Data should not be empty'
        if self._connection_lost_scheduled:
            return

        try:
            if unlikely(self._is_debug):
                _logger.debug("%r write_ready event, resume writing from backlog", self)
            self._flush_write_backlog()
        except:
            self._drop_writer()
            self._handle_error('Fatal write error on transport')
        else:
            self._maybe_resume_protocol()
            if self._write_backlog_size == 0:
                self._drop_writer()
                if self._closing:
                    self._connection_lost_scheduled = True
                    self._call_connection_lost(None)
                elif self._eof:
                    self._write_eof_now()

    def sendfile(self, file, offset, count) -> Optional[asyncio.Future[None]]:
        self._check_thread("sendfile")

        # This is an undocumented feature in asyncio and uvloop
        # Some 3rdparty tests use it to disable native sendfile (for example aiohttp tests)
        if not self._sendfile_compatible:
            raise NotImplementedError()

        if self._eof:
            raise RuntimeError('Cannot call sendfile() after write_eof()')

        if self._closing or self._connection_lost_scheduled:
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
            self._write_backlog_size += <Py_ssize_t>req.count
            self._ensure_writer()
            self._maybe_pause_protocol()

            req.waiter = self._loop.create_future()
            return req.waiter
        except:
            self._handle_error('Fatal sendfile error on transport')
            raise

    cdef bint _try_sendfile(self, SendFileRequest req) except -1:
        raise NotImplementedError()


cdef class SelectorSocketTransport(SelectorStreamTransport):
    """Provide bidirectional stream transport behavior for a socket."""

    cdef:
        object _server

    def __init__(self, loop, sock, protocol, waiter=None, server=None):
        aiofn_set_nodelay(sock)
        SelectorStreamTransport.__init__(self, loop, sock, protocol)
        self._server = server
        self._extra['socket'] = TransportSocket(sock)
        aiofn_set_socket_extra_info(self._extra, sock)
        self._sendfile_compatible = os.name != 'nt'

        self._loop.call_soon(self._protocol.connection_made, self)
        # only start reading when connection_made() has been called
        self._loop.call_soon(self._loop.add_reader,
                             self._fileno_obj, self._read_ready)
        if waiter is not None:
            # only wake up the waiter when connection_made() has been called
            self._loop.call_soon(_set_result_unless_cancelled_callback, waiter, None)

    def __del__(self):
        if self._file is not None:
            warnings.warn(f"unclosed {self.__class__.__name__} for {self._file}", ResourceWarning, source=self)
            self._file.close()
            if self._server is not None:
                self._server._detach(self)

    def _call_connection_lost(self, exc):
        try:
            SelectorTransport._call_connection_lost(self, exc)
        finally:
            server = self._server
            if server is not None:
                server._detach(self)
                self._server = None

    def _read_ready(self):
        try:
            if self._protocol_buffered:
                self._read_ready__get_buffer()
            else:
                self._read_ready__data_received()
        except:
            self._handle_error('Fatal read error on socket transport')

    cdef inline NoResult _read_ready__get_buffer(self) except NoResult.EXC:
        cdef:
            object buf
            char* buf_ptr
            Py_ssize_t buf_len
            Py_ssize_t bytes_read
            Py_ssize_t idx

        for idx in range(_max_reads_per_socket_per_cycle):
            if self._connection_lost_scheduled:
                return NoResult.OK

            if self._read_paused:
                return NoResult.OK

            buf = self._call_protocol_get_buffer(&buf_ptr, &buf_len)

            bytes_read = aiofn_read(self._fileno, buf_ptr, buf_len, self._is_socket)
            if unlikely(self._is_debug):
                _logger.debug("%r: aiofn_read(,len=%d) = %d", self, buf_len, bytes_read)

            if bytes_read == -1:    # without exception this means EGAIN
                return NoResult.OK

            if bytes_read == 0:
                self._read_ready__on_eof()
                return NoResult.OK

            self._call_protocol_buffer_updated(bytes_read)

            if bytes_read < buf_len:
                return NoResult.OK

            # Protocol may have been switched from buffered to simple
            if not self._protocol_buffered:
                return NoResult.OK

        return NoResult.OK

    cdef inline NoResult _read_ready__data_received(self) except NoResult.EXC:
        cdef:
            Py_ssize_t bytes_read
            bytes data
            Py_ssize_t idx

        for idx in range(_max_reads_per_socket_per_cycle):
            if self._connection_lost_scheduled:
                return NoResult.OK

            if self._read_paused:
                return NoResult.OK

            data = aiofn_simple_read(self._fileno, _data_received_max_size, &bytes_read, self._is_socket)

            if unlikely(self._is_debug):
                _logger.debug("%r: aiofn_read(...,len=%d)=%d", self, _data_received_max_size, bytes_read)

            if bytes_read == -1:    # without exception this means EGAIN
                return NoResult.OK

            if bytes_read == 0:
                self._read_ready__on_eof()
                return NoResult.OK

            self._call_protocol_data_received(data)

            if bytes_read < _data_received_max_size:
                return NoResult.OK

            # Protocol may have been switched from simple to buffered
            if self._protocol_buffered:
                return NoResult.OK

        return NoResult.OK

    cdef inline NoResult _read_ready__on_eof(self) except NoResult.EXC:
        if self._loop.get_debug():
            _logger.debug("%r received EOF", self)

        keep_open = self._call_protocol_eof_received()

        if keep_open:
            # We're keeping the connection open so the
            # protocol can write more, but we still can't
            # receive more, so remove the reader callback.
            self._loop.remove_reader(self._fileno_obj)
        else:
            self.close()

    cdef inline _call_protocol_get_buffer(self, char** buf_ptr, Py_ssize_t* buf_len):
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

    cdef NoResult _write_eof_now(self) except NoResult.EXC:
        self._file.shutdown(socket.SHUT_WR)
        if unlikely(self._is_debug):
            _logger.debug("%r: shutdown(SHUT_WR) done", self)

    cdef bint _try_sendfile(self, SendFileRequest req) except -1:
        """
        Return True if finished, False if must wait for write ready event.

        Caller is always responsible for:
        * handling exceptions, including closing the transport when appropriate;
        * completing req.waiter when the request finishes or fails.
        """
        if _os_sendfile is None:
            raise NotImplementedError()

        try:
            while req.count:
                bytes_sent = _os_sendfile(self._fileno_obj, req.fileno,
                                          req.offset, req.count)
                if unlikely(self._is_debug):
                    _logger.debug("%r: os.sendfile(offset=%d,count=%d)=%d",
                                  self, req.offset, req.count, bytes_sent)
                if bytes_sent == 0:
                    req.count = 0
                    break
                req.offset += bytes_sent
                req.count -= bytes_sent

            return True
        except BlockingIOError:
            return False
        except ConnectionResetError:
            raise
        except OSError as exc:
            # Patch MacOS error code
            if sys.platform == "darwin" and exc.errno == 57:
                raise ConnectionResetError()
            else:
                raise


cdef class SelectorDatagramTransport(SelectorWritableTransport):
    """Provide message-oriented send and receive behavior for a datagram socket."""

    cdef:
        object _address
        Py_ssize_t _header_size
        bint _has_connection

    def __init__(self, loop, sock, protocol, address, waiter):
        SelectorWritableTransport.__init__(self, loop, sock, protocol)
        self._extra['socket'] = TransportSocket(sock)
        aiofn_set_socket_extra_info(self._extra, sock)

        self._address = address or None
        self._header_size = 8
        self._has_connection = self._extra['peername'] is not None

        self._loop.call_soon(self._protocol.connection_made, self)
        # only start reading when connection_made() has been called
        self._loop.call_soon(self._loop.add_reader,
                             self._fileno_obj, self._read_ready)
        # only wake up the waiter when connection_made() has been called
        self._loop.call_soon(_set_result_unless_cancelled_callback, waiter, None)

    def _read_ready(self):
        cdef:
            PyObject* buffer
            char* buf_ptr
            char raw_addr[256]
            unsigned int raw_addr_len = sizeof(raw_addr)
            Py_ssize_t bytes_read
            object data

        if self._connection_lost_scheduled:
            return

        if unlikely(self._read_paused):
            return

        try:
            buffer = aiofn_allocate_bytes(_datagram_received_max_size, &buf_ptr)

            try:
                bytes_read = aiofn_recvfrom(self._fileno, buf_ptr, _datagram_received_max_size,
                                            <void*>raw_addr, &raw_addr_len)
                data = aiofn_finalize_bytes(buffer, max(bytes_read, 0))
                buffer = NULL
            except:
                Py_XDECREF(buffer)
                raise

            if unlikely(self._is_debug):
                _logger.debug("%r: aiofn_recvfrom(...,len=%d)=%d", self, _datagram_received_max_size, bytes_read)

            if bytes_read == -1:
                return

            addr = aiofn_sockaddr_to_pyaddr(<void*>raw_addr, raw_addr_len)
        except OSError as exc:
            self._call_protocol_error_received(exc)
            return
        except (KeyboardInterrupt, SystemExit):
            raise
        except BaseException:
            self._handle_error('Fatal read error on datagram transport')
            return

        self._call_protocol_datagram_received(data, addr)

    def _write_ready(self):
        try:
            if unlikely(self._is_debug):
                _logger.debug("%r write_ready event, resume writing from backlog", self)

            while self._write_backlog:
                data, addr = self._write_backlog[0]
                if not self._sendto_impl(data, addr):
                    break

                self._write_backlog.popleft()
                self._write_backlog_size -= len(data) + self._header_size

            self._maybe_resume_protocol()
            if not self._write_backlog:
                self._drop_writer()
                if self._closing:
                    self._connection_lost_scheduled = True
                    self._call_connection_lost(None)
        except:
            self._drop_writer()
            self._handle_error('Fatal write error on datagram transport')

    cpdef sendto_nocheck(self, data, addr):
        if self._address is not None:
            if addr is not None and addr != self._address:
                raise ValueError(
                    f'Invalid address: must be None or {self._address}')
            addr = self._address

        if unlikely(self._connection_lost_scheduled and self._address):
            if self._closed_write_count >= _log_threshold_for_connlost_writes:
                _logger.warning('socket.send() raised exception.')
            self._closed_write_count += 1
            return

        try:
            if self._write_backlog_size == 0:
                if self._sendto_impl(data, addr):
                    return

            # Ensure that what we buffer is immutable.
            self._write_backlog.append((aiofn_maybe_copy_buffer(data), addr))
            self._write_backlog_size += len(data) + self._header_size
            self._ensure_writer()
            self._maybe_pause_protocol()
        except:
            self._handle_error('Fatal write error on datagram transport')

    cpdef can_write_eof(self):
        return False

    cpdef write_eof(self):
        raise NotImplementedError()

    cdef inline bint _sendto_impl(self, data, addr) except -1:
        cdef:
            char* buf_ptr
            Py_ssize_t buf_len
            Py_ssize_t bytes_sent
            char raw_addr[256]
            unsigned int raw_addr_len = 0
            void* raw_addr_ptr = NULL

        try:
            aiofn_unpack_simple_buffer(data, &buf_ptr, &buf_len, 0)
            if not self._has_connection:
                if not aiofn_pyaddr_to_sockaddr(addr, raw_addr, &raw_addr_len):
                    bytes_sent = self._file.sendto(data, addr)
                    if unlikely(self._is_debug):
                        _logger.debug("%r: socket.sendto(...,len=%d)=%d", self, buf_len, bytes_sent)
                    return True
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
        except BaseException as exc:
            self._report_protocol_exception(
                exc, 'Fatal error: protocol.error_received() call failed.')


cdef class SelectorReadPipeTransport(SelectorTransport):
    """Provide the read side of a unidirectional pipe transport."""

    def __init__(self, loop, pipe, protocol, waiter):
        mode = os.fstat(pipe.fileno()).st_mode
        if not (stat.S_ISFIFO(mode) or
                stat.S_ISSOCK(mode) or
                stat.S_ISCHR(mode)):
            raise ValueError("Pipe transport is for pipes/sockets only.")

        SelectorTransport.__init__(self, loop, pipe, protocol)
        self._extra['pipe'] = pipe
        self._is_socket = False

        self._loop.call_soon(self._protocol.connection_made, self)
        # only start reading when connection_made() has been called
        self._loop.call_soon(self._loop.add_reader,
                             self._fileno_obj, self._read_ready)
        # only wake up the waiter when connection_made() has been called
        self._loop.call_soon(_set_result_unless_cancelled_callback, waiter, None)

    def _read_ready(self):
        cdef:
            Py_ssize_t bytes_read
            bytes data

        try:
            data = aiofn_simple_read(self._fileno, _data_received_max_size, &bytes_read, False)

            if bytes_read == -1:  # without exception this means EGAIN
                return

            if bytes_read == 0:
                if unlikely(self._is_debug):
                    _logger.info("%r was closed by peer", self)
                self._call_protocol_eof_received()
                self._force_close(None)
                return

            self._call_protocol_data_received(data)
        except:
            self._handle_error('Fatal read error on pipe transport')

    cdef bint _should_report_fatal_error(self, exc) except -1:
        return not (isinstance(exc, OSError) and exc.errno == errno.EIO)


cdef class SelectorWritePipeTransport(SelectorStreamTransport):
    """Provide the write side of a pipe using stream backlog and flow control."""

    def __init__(self, loop, pipe, protocol, waiter):
        pipe_stat = os.fstat(pipe.fileno())
        mode = pipe_stat.st_mode
        is_char = stat.S_ISCHR(mode)
        is_fifo = stat.S_ISFIFO(mode)
        is_socket = stat.S_ISSOCK(mode)
        if not (is_char or is_fifo or is_socket):
            raise ValueError("Pipe transport is only for "
                             "pipes, sockets and character devices")

        SelectorStreamTransport.__init__(self, loop, pipe, protocol)
        self._extra['pipe'] = pipe
        self._is_socket = False

        self._loop.call_soon(self._protocol.connection_made, self)

        # On AIX, the reader trick (to be notified when the read end of the
        # socket is closed) only works for sockets. On other platforms it
        # works for pipes and sockets. (Exception: OS X 10.4?  Issue #19294.)
        # On macOS, the trick misfires for named FIFOs (but not for pipes
        # created with os.pipe(), which have st_nlink == 0): the write end
        # polls as readable whenever unread data sits in the FIFO, and no
        # event is delivered when the read end is closed, so it can only
        # ever report a false disconnection (gh-145030). The same xnu
        # behaviour applies on iOS/tvOS/watchOS (sys.platform is not
        # "darwin" there).
        is_named_fifo_on_apple = (
            sys.platform in {"darwin", "ios", "tvos", "watchos"}
            and is_fifo and pipe_stat.st_nlink > 0)
        if is_socket or (is_fifo
                         and not sys.platform.startswith("aix")
                         and not is_named_fifo_on_apple):
            # only start reading when connection_made() has been called
            self._loop.call_soon(self._loop.add_reader,
                                 self._fileno_obj, self._read_ready)

        # only wake up the waiter when connection_made() has been called
        self._loop.call_soon(_set_result_unless_cancelled_callback, waiter, None)

    def _read_ready(self):
        # Pipe was closed by peer.
        if unlikely(self._is_debug):
            _logger.info("%r was closed by peer", self)
        if self._write_backlog:
            self._force_close(BrokenPipeError())
        else:
            self._force_close(None)

    cdef NoResult _write_eof_now(self) except NoResult.EXC:
        SelectorWritableTransport.close(self)
