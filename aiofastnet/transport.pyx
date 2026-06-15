import collections
import os
import socket
import sys
import warnings
import asyncio
from typing import Optional

import cython
from asyncio.trsock import TransportSocket
from logging import getLogger

from cpython.memoryview cimport PyMemoryView_FromMemory
from cpython.buffer cimport PyBUF_READ, PyBUF_WRITABLE
from cpython.bytes cimport *
from cpython.pythread cimport PyThread_get_thread_ident

from . import constants

from .utils cimport *


cdef object _logger = getLogger('aiofastnet')
cdef object _DATA_RECEIVED_MAX_SIZE = 256 * 1024


cdef class Transport:
    def write(self, data):
        raise NotImplementedError()

    def writelines(self, list_of_data):
        raise NotImplementedError()

    cpdef write_nocheck(self, data):
        raise NotImplementedError()

    cpdef writelines_nocheck(self, list_of_data):
        raise NotImplementedError()

    cdef write_c(self, char* ptr, Py_ssize_t sz):
        self.write(PyMemoryView_FromMemory(ptr, sz, PyBUF_READ))

    async def sendfile(self, file, offset, count):
        raise NotImplementedError()


cdef class Protocol:
    cpdef is_buffered_protocol(self):
        return None

    cpdef Py_ssize_t get_local_write_buffer_size(self) except -1:
        return 0

    cpdef get_buffer(self, Py_ssize_t hint):
        raise NotImplementedError()

    cdef get_buffer_c(self, Py_ssize_t hint, char** buf_ptr, Py_ssize_t* buf_len):
        buffer = self.get_buffer(hint)
        aiofn_unpack_simple_buffer(buffer, buf_ptr, buf_len, PyBUF_WRITABLE)

    cpdef buffer_updated(self, Py_ssize_t bytes_read):
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
    cdef:
        object file
        object offset
        object count
        object waiter


cdef _make_send_file_request(file, offset, count):
    cdef SendFileRequest req = <SendFileRequest>SendFileRequest.__new__(SendFileRequest)
    req.file = file
    req.offset = offset
    if count is None:
        req.count = max(0, os.fstat(file.fileno()).st_size - offset)
    else:
        req.count = count
    req.waiter = None
    return req


cdef class WriteWatermarks:
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

    cdef inline _set_write_buffer_limits(self, high, low):
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


cdef class SocketTransport(Transport):
    cdef:
        object __weakref__
        unsigned long _thread_id
        object _loop
        object _protocol
        bint _protocol_buffered
        bint _protocol_aiofn
        bint _protocol_connected
        dict _extra
        WriteWatermarks _write_watermarks

        object _server
        object _sock
        object _sock_fd_obj
        int _sock_fd

        object _write_backlog
        Py_ssize_t _write_backlog_size
        bint _write_ready_registered
        bint _connection_lost_scheduled
        size_t _closed_write_count
        bint _closing
        bint _read_paused

        public bint _sendfile_compatible

        bint _eof
        bint _is_debug

        aiofn_iovec _iovecs[256]

    def __init__(self, loop, sock, protocol, waiter=None, extra=None, server=None):
        self._thread_id = PyThread_get_thread_ident()
        assert loop is not None
        self._loop = loop
        self.set_protocol(protocol)
        self._write_watermarks = WriteWatermarks(loop)
        self._extra = {} if extra is None else extra
        self._extra['socket'] = TransportSocket(sock)
        try:
            self._extra['sockname'] = sock.getsockname()
        except OSError:
            self._extra['sockname'] = None
        if 'peername' not in self._extra:
            try:
                self._extra['peername'] = sock.getpeername()
            except socket.error:
                self._extra['peername'] = None
        self._server = server
        self._sock = sock
        self._sock_fd_obj = sock.fileno()
        self._sock_fd = self._sock_fd_obj
        self._write_backlog = collections.deque()
        self._write_backlog_size = 0
        self._write_ready_registered = False
        self._connection_lost_scheduled = False
        self._closed_write_count = 0
        self._closing = False  # Set when close() called.
        self._read_paused = False  # Set when pause_reading() called

        if self._server is not None:
            self._server._attach(self)

        self._sendfile_compatible = os.name != 'nt'

        self._eof = False
        self._is_debug = loop.get_debug()

        aiofn_set_nodelay(self._sock)

        self._loop.call_soon(self._protocol.connection_made, self)
        # only start reading when connection_made() has been called
        self._loop.call_soon(self._loop.add_reader,
                             self._sock_fd_obj, self._read_ready)
        if waiter is not None:
            # only wake up the waiter when connection_made() has been called
            self._loop.call_soon(aiofn_set_result_unless_cancelled, waiter, None)

    def __repr__(self):
        info = [f'fd={self._sock_fd_obj}', 'SocketTransport']
        if self._sock is None:
            info.append('closed')
        elif self._closing:
            info.append('closing')
        # test if the transport was closed
        if self._loop is not None and not self._loop.is_closed():
            bufsize = self.get_write_buffer_size()
            info.append(f'wbuf_size={bufsize}')
        return '[{}]'.format(' '.join(info))

    def __del__(self):
        if self._sock is not None:
            warnings.warn(f"unclosed transport {self!r}", ResourceWarning, source=self)
            self._sock.close()
            if self._server is not None:
                self._server._detach(self)

    cdef inline _check_thread(self, meth):
        cdef unsigned long curr_thread_id = PyThread_get_thread_ident()
        if self._thread_id != curr_thread_id:
            raise RuntimeError(
                f"SocketTransport.{meth} called from a wrong thread: "
                f"transport thread id={self._thread_id}, "
                f"curr thread_id={curr_thread_id}"
            )

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

    cpdef tuple get_write_buffer_limits(self):
        self._check_thread("get_write_buffer_limits")
        return self._write_watermarks.get_write_buffer_limits()

    cpdef set_write_buffer_limits(self, high=None, low=None):
        self._check_thread("set_write_buffer_limits")
        self._write_watermarks.set_write_buffer_limits(
            self, self._protocol, self.get_write_buffer_size(), high, low)

    cpdef abort(self):
        self._check_thread("abort")
        self._force_close(None)

    cpdef is_closing(self):
        self._check_thread("is_closing")
        return self._closing

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
            _logger.debug("%r pauses reading", self)

    cpdef resume_reading(self):
        self._check_thread("resume_reading")
        if self._closing or not self._read_paused:
            return
        self._read_paused = False

        if not self.is_reading():
            return
        self._loop.add_reader(self._sock_fd_obj, self._read_ready)

        if unlikely(self._is_debug):
            _logger.debug("%r resumes reading", self)

    cpdef close(self):
        self._check_thread("close")
        if self._closing:
            return
        self._closing = True
        self._loop.remove_reader(self._sock_fd_obj)
        if not self._write_backlog:
            self._connection_lost_scheduled = True
            self._drop_writer()
            self._loop.call_soon(self._call_connection_lost, None)

    cpdef get_write_buffer_size(self):
        self._check_thread("get_write_buffer_size")
        cdef Py_ssize_t total = self._write_backlog_size

        if isinstance(self._protocol, Protocol):
            total += (<Protocol>self._protocol).get_local_write_buffer_size()

        return total

    def _read_ready(self):
        if self._protocol_buffered:
            self._read_ready__get_buffer()
        else:
            self._read_ready__data_received()

    cdef inline _read_ready__get_buffer(self):
        cdef:
            object buf
            char* buf_ptr
            Py_ssize_t buf_len
            Py_ssize_t bytes_read

        while True:
            if self._connection_lost_scheduled:
                return

            if self._read_paused:
                return

            try:
                if self._protocol_aiofn:
                    buf = (<Protocol>self._protocol).get_buffer_c(-1, &buf_ptr, &buf_len)
                else:
                    buf = self._protocol.get_buffer(-1)
                    aiofn_unpack_simple_buffer(buf, &buf_ptr, &buf_len, PyBUF_WRITABLE)

                if buf_len == 0:
                    raise RuntimeError('get_buffer() returned an empty buffer')
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException as exc:
                self._fatal_error(
                    exc, 'Fatal error: protocol.get_buffer() call failed.')
                return

            try:
                bytes_read = aiofn_recv(self._sock_fd, buf_ptr, buf_len)
                if unlikely(self._is_debug):
                    _logger.debug("%r: aiofn_recv(,len=%d) = %d", self, buf_len, bytes_read)
                if bytes_read == -1:    # without exception this means EGAIN
                    return
            except BaseException as exc:
                self._fatal_error(exc, 'Fatal read error on socket transport')
                return

            if bytes_read == 0:
                self._read_ready__on_eof()
                return

            try:
                if self._protocol_aiofn:
                    buf = (<Protocol>self._protocol).buffer_updated(bytes_read)
                else:
                    buf = self._protocol.buffer_updated(bytes_read)
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException as exc:
                self._fatal_error(
                    exc, 'Fatal error: protocol.buffer_updated() call failed.')

    cdef inline _read_ready__data_received(self):
        if self._connection_lost_scheduled:
            return
        try:
            # Already a good wrapper, returns bytes object.
            # Exactly what we need for non-buffered protocols
            data = self._sock.recv(_DATA_RECEIVED_MAX_SIZE)
            if unlikely(self._is_debug):
                _logger.debug("%r: _sock.recv() = bytes(len=%d)",
                              self, len(data))
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            self._fatal_error(exc, 'Fatal read error on socket transport')
            return

        if not data:
            self._read_ready__on_eof()
            return

        try:
            self._protocol.data_received(data)
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            self._fatal_error(
                exc, 'Fatal error: protocol.data_received() call failed.')

    cdef inline _read_ready__on_eof(self):
        if self._loop.get_debug():
            _logger.debug("%r received EOF", self)

        try:
            keep_open = self._protocol.eof_received()
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            self._fatal_error(
                exc, 'Fatal error: protocol.eof_received() call failed.')
            return

        if keep_open:
            # We're keeping the connection open so the
            # protocol can write more, but we still can't
            # receive more, so remove the reader callback.
            self._loop.remove_reader(self._sock_fd_obj)
        else:
            self.close()

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

    cpdef write_nocheck(self, data):
        if self._eof:
            raise RuntimeError('Cannot call write() after write_eof()')
        if not data:
            return

        if unlikely(self._connection_lost_scheduled):
            if self._closed_write_count >= constants.LOG_THRESHOLD_FOR_CONNLOST_WRITES:
                _logger.warning('socket.send() raised exception.')
            self._closed_write_count += 1
            return

        cdef:
            char* data_ptr
            Py_ssize_t data_len, data_len_init = 0
            Py_ssize_t bytes_sent

        if not self._write_backlog:
            aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
            data = self._write_one_handle_exc(data, data_ptr, data_len)
            if data is None:
                return

            # Not all was written; register write handler.
            self._ensure_writer()
        else:
            data = aiofn_maybe_copy_buffer(data)

        self._write_backlog.append(data)
        self._write_backlog_size += len(data)
        self._maybe_pause_protocol()

    cdef inline Py_ssize_t _flush_iovecs(self, Py_ssize_t num_iovecs, Py_ssize_t* total_bytes_sent) except -2:
        cdef Py_ssize_t bytes_sent = aiofn_writev(self._sock_fd, self._iovecs, num_iovecs)
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
            if isinstance(data, SendFileRequest):
                break

            aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
            if data_len == 0:
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

    cdef inline _add_list_of_data_tail_to_backlog(self, list_of_data, Py_ssize_t total_bytes_sent):
        cdef:
            char* data_ptr
            Py_ssize_t data_len

        for data in list_of_data:
            aiofn_unpack_simple_buffer(data, &data_ptr, &data_len, 0)
            if data_len <= total_bytes_sent:
                total_bytes_sent -= data_len
                continue
            elif total_bytes_sent <= 0:
                data = aiofn_maybe_copy_buffer(data)
                self._write_backlog.append(data)
                self._write_backlog_size += len(data)
            else:
                data_ptr += total_bytes_sent
                data_len -= total_bytes_sent
                total_bytes_sent = 0
                data = aiofn_maybe_copy_buffer_tail(
                    data, data_ptr, data_len)
                self._write_backlog.append(data)
                self._write_backlog_size += len(data)

        if self._write_backlog_size > 0:
            self._ensure_writer()
            self._maybe_pause_protocol()

    cpdef writelines_nocheck(self, list_of_data):
        if self._eof:
            raise RuntimeError('Cannot call writelines() after write_eof()')

        if unlikely(self._connection_lost_scheduled):
            if self._closed_write_count >= constants.LOG_THRESHOLD_FOR_CONNLOST_WRITES:
                _logger.warning('socket.send() raised exception.')
            self._closed_write_count += 1
            return

        cdef Py_ssize_t total_bytes_sent = 0

        try:
            if self._write_backlog_size == 0:
                if self._try_write_list_of_data(list_of_data, &total_bytes_sent):
                    return

            self._add_list_of_data_tail_to_backlog(list_of_data, total_bytes_sent)
        except BaseException as exc:
            self._fatal_error(exc, 'Fatal write error on socket transport')

    cdef write_c(self, char* ptr, Py_ssize_t sz):
        if sz <= 0:
            return

        if unlikely(self._connection_lost_scheduled):
            if self._closed_write_count >= constants.LOG_THRESHOLD_FOR_CONNLOST_WRITES:
                _logger.warning('socket.send() raised exception.')
            self._closed_write_count += 1
            return

        if not self._write_backlog:
            data = self._write_one_handle_exc(None, ptr, sz)
            if data is None:
                return

            # Not all was written; register write handler.
            self._ensure_writer()
        else:
            data = PyBytes_FromStringAndSize(ptr, sz)

        self._write_backlog.append(data)
        self._write_backlog_size += len(data)
        self._maybe_pause_protocol()

    cpdef can_write_eof(self):
        return True

    cpdef write_eof(self):
        self._check_thread("write_eof")
        if self._closing or self._eof:
            return
        self._eof = True
        if not self._write_backlog:
            self._sock.shutdown(socket.SHUT_WR)
            if unlikely(self._is_debug):
                _logger.debug("%r: shutdown(SHUT_WR) done", self)

    cdef inline _write_one_handle_exc(self, object data, char* data_ptr, Py_ssize_t data_len):
        """
        Returns None if all data has been sent, or remaining data
        """
        cdef Py_ssize_t bytes_sent

        while True:
            try:
                bytes_sent = aiofn_send(self._sock_fd, data_ptr, data_len)
                if unlikely(self._is_debug):
                    _logger.debug("%r aiofn_send(...,len=%d)=%d", self,
                                  data_len, bytes_sent)
            except BaseException as exc:
                self._fatal_error(exc, 'Fatal write error on socket transport')
                return
            else:
                if bytes_sent == data_len:
                    return None

                if bytes_sent == -1:
                    return aiofn_maybe_copy_buffer_tail(data, data_ptr, data_len)

                data_ptr += bytes_sent
                data_len -= bytes_sent

    cdef inline _adjust_write_backlog(self, Py_ssize_t bytes_sent):
        cdef:
            char* data_ptr
            Py_ssize_t data_len

        if bytes_sent > 0:
            self._write_backlog_size -= bytes_sent

        while bytes_sent > 0:
            data = self._write_backlog[0]
            data_len = len(data)
            if data_len <= bytes_sent:
                bytes_sent -= data_len
                self._write_backlog.popleft()
                if unlikely(self._is_debug):
                    _logger.debug("%r: wrote backlog item of %d bytes", self, data_len)
            else:
                self._write_backlog[0] = data[bytes_sent:]
                if unlikely(self._is_debug):
                    _logger.debug("%r: partially wrote backlog item of %d bytes", self, bytes_sent, data_len)
                break

    cdef inline _try_sendfile_from_backlog_top(self):
        cdef:
            SendFileRequest sendfile_req = <SendFileRequest>self._write_backlog[0]
            Py_ssize_t orig_req_size = sendfile_req.count

        cdef bint all_sent = self._try_sendfile(sendfile_req)
        if all_sent:
            self._write_backlog.popleft()
            if not sendfile_req.waiter.done():
                sendfile_req.waiter.set_result(None)
        self._write_backlog_size -= orig_req_size - sendfile_req.count

        return all_sent

    cdef inline _flush_write_backlog(self):
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

    cpdef _write_ready(self):
        assert self._write_backlog, 'Data should not be empty'
        if self._connection_lost_scheduled:
            return

        try:
            if unlikely(self._is_debug):
                _logger.debug("%r write_ready event, resume writing from backlog", self)
            self._flush_write_backlog()
        except BaseException as exc:
            self._drop_writer()
            self._clear_write_backlog(exc)
            self._fatal_error(exc, 'Fatal write error on socket transport')
        else:
            self._maybe_resume_protocol()
            if not self._write_backlog:
                self._drop_writer()
                if self._closing:
                    self._connection_lost_scheduled = True
                    self._call_connection_lost(None)
                elif self._eof:
                    self._sock.shutdown(socket.SHUT_WR)
                    if unlikely(self._is_debug):
                        _logger.debug("%r: shutdown(SHUT_WR) done", self)

    cpdef _call_connection_lost(self, exc):
        try:
            if self._protocol_connected:
                self._protocol.connection_lost(exc)
        finally:
            self._sock.close()
            self._sock = None
            self._protocol = None
            server = self._server
            if server is not None:
                server._detach(self)
                self._server = None

    cdef inline _maybe_pause_protocol(self):
        self._write_watermarks.maybe_pause_protocol(self, self._protocol, self.get_write_buffer_size())

    cdef inline _maybe_resume_protocol(self):
        self._write_watermarks.maybe_resume_protocol(self, self._protocol, self.get_write_buffer_size())

    cdef inline _ensure_writer(self):
        if unlikely(self._is_debug):
            _logger.debug("%r: _ensure_writer called", self)

        if self._connection_lost_scheduled or self._write_ready_registered:
            return
        self._write_ready_registered = True
        self._loop.add_writer(self._sock_fd_obj, self._write_ready)

    cdef inline _drop_writer(self):
        if unlikely(self._is_debug):
            _logger.debug("%r: _drop_writer called", self)

        if not self._write_ready_registered:
            return
        self._write_ready_registered = False
        self._loop.remove_writer(self._sock_fd_obj)

    def sendfile(self, file, offset, count) -> Optional[asyncio.Future[None]]:
        # TODO: Add _fatal_error and terminate transport on exception
        # TODO: Add relevant tests

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
            if not self._write_backlog:
                if self._try_sendfile(req):
                    return None

            if unlikely(self._is_debug):
                _logger.debug("%r: enqueue SendFileRequest(offset=%d,count=%d)",
                              self, req.offset, req.count)

            self._write_backlog.append(req)
            self._write_backlog_size += req.count
            self._ensure_writer()
            self._maybe_pause_protocol()

            req.waiter = self._loop.create_future()
            return req.waiter
        except BaseException as exc:
            self._fatal_error(exc, 'Fatal write error on socket transport')
            raise

    cdef inline bint _try_sendfile(self, SendFileRequest req) except -1:
        """
        Return True if finished, False if must wait for write ready event.

        Caller is always responsible for:
        * handling exceptions, including closing the transport when appropriate;
        * completing req.waiter when the request finishes or fails.
        """
        try:
            while req.count:
                bytes_sent = os.sendfile(self._sock_fd_obj, req.file.fileno(),
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
        except AttributeError:
            raise NotImplementedError()
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

    cdef inline _fatal_error(self, exc, message='Fatal error on transport'):
        # Should be called from exception handler only.
        if isinstance(exc, OSError):
            if self._loop.get_debug():
                _logger.debug("%r: %s", self, message, exc_info=True)
        else:
            self._loop.call_exception_handler({
                'message': message,
                'exception': exc,
                'transport': self,
                'protocol': self._protocol,
            })
        self._force_close(exc)

    # May be used by create_connection/create_server
    # Keep cpdef
    cpdef _force_close(self, exc):
        if self._connection_lost_scheduled:
            return
        if self._write_backlog:
            self._clear_write_backlog(exc)
            self._drop_writer()
        if not self._closing:
            self._closing = True
            self._loop.remove_reader(self._sock_fd_obj)
        self._connection_lost_scheduled = True
        self._loop.call_soon(self._call_connection_lost, exc)

    cdef inline _clear_write_backlog(self, exc):
        cdef SendFileRequest req
        for data in self._write_backlog:
            if isinstance(data, SendFileRequest):
                req = <SendFileRequest>data
                if req.waiter is not None and not req.waiter.done():
                    req.waiter.set_exception(exc)
        self._write_backlog.clear()
        self._write_backlog_size = 0
