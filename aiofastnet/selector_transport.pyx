"""Selector-based socket, datagram, and pipe transports.

Writable selector transports inherit the shared stream/datagram transport
bases directly.
"""

import errno
import os
import socket
import stat
import sys
from logging import getLogger

from cpython.bytes cimport *
from cpython.ref cimport Py_XDECREF

from . import constants
from .transport cimport (
    DatagramTransport,
    FDTransport,
    SendFileRequest,
    StreamTransport,
    WritableTransport,
    WriteRequest,
)
from .utils cimport *

from .utils import aiofn_set_result_unless_cancelled as _set_result_unless_cancelled_callback


cdef:
    object _logger = getLogger('aiofastnet')
    object _os_sendfile = getattr(os, "sendfile", None)
    Py_ssize_t _data_received_max_size = constants.DATA_RECEIVED_MAX_SIZE
    Py_ssize_t _datagram_received_max_size = constants.DATAGRAM_RECEIVED_MAX_SIZE
    Py_ssize_t _max_read_bytes_per_cycle_hint = constants.MAX_READ_BYTES_PER_CYCLE_HINT


cdef class SelectorStreamTransport(StreamTransport):
    """Implement ordered byte-stream writes, writev, EOF, and sendfile queues."""

    cdef:
        bint _write_ready_registered

    def __init__(self, loop, file, protocol, server=None):
        StreamTransport.__init__(self, loop, file, server)
        self._set_protocol(protocol)
        self._write_ready_registered = False

    cdef NoResult _stop_reading(self) except NoResult.EXC:
        self._loop.remove_reader(self._fileno_obj)

    cdef NoResult _start_reading(self) except NoResult.EXC:
        self._loop.add_reader(self._fileno_obj, self._read_ready)

    cdef bint _should_report_fatal_error(self, exc) except -1:
        return not isinstance(exc, OSError)

    cpdef _force_close(self, exc):
        if self._finalizing_close:
            return

        self._closing = True
        self._pause_reading()
        self._stop_write_ready()
        self._clear_write_backlog(exc)
        self._schedule_finalize_close(exc)

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
        raise NotImplementedError()

    def _write_ready(self):
        if unlikely(self._is_debug):
            _logger.debug("%r write_ready event, resume writing from backlog", self)

        if self._finalizing_close:
            return

        cdef:
            Py_ssize_t bytes_sent
            bint all_sent = True

        try:
            while self._write_backlog_size > 0 and all_sent:
                if isinstance(self._write_backlog[0], SendFileRequest):
                    all_sent = self._try_sendfile_from_backlog_top()
                else:
                    bytes_sent = 0
                    all_sent = self._try_writelines(self._write_backlog, &bytes_sent)
                    self._consume_write_backlog(bytes_sent)
        except:
            self._handle_error('Fatal write error on transport')
        else:
            self._maybe_resume_protocol()

            if self._write_backlog_size == 0:
                self._stop_write_ready()
                if self._closing:
                    if not self._finalizing_close:
                        self._schedule_finalize_close(None)
                elif self._write_eof:
                    self._write_eof_now()

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

    cdef NoResult _ensure_progress(self) except NoResult.EXC:
        if unlikely(self._is_debug):
            _logger.debug(
                "%r: _ensure_progress called, conn_lost=%s, already_registered=%s",
                self,
                self._finalizing_close,
                self._write_ready_registered,
            )

        if self._finalizing_close or self._write_ready_registered:
            return NoResult.OK

        self._write_ready_registered = True
        self._loop.add_writer(self._fileno_obj, self._write_ready)

    cdef NoResult _stop_write_ready(self) except NoResult.EXC:
        if unlikely(self._is_debug):
            _logger.debug("%r: stop write-ready notifications", self)

        if not self._write_ready_registered:
            return NoResult.OK

        self._write_ready_registered = False
        self._loop.remove_writer(self._fileno_obj)

    cdef bint _try_sendfile(self, SendFileRequest request) except -1:
        """Return whether the request completed without waiting for write readiness."""
        if _os_sendfile is None:
            raise NotImplementedError()

        try:
            while request.count:
                bytes_sent = _os_sendfile(self._fileno, request.fd, request.offset, request.count)
                if unlikely(self._is_debug):
                    _logger.debug(
                        "%r: os.sendfile(offset=%d,count=%d)=%d",
                        self,
                        request.offset,
                        request.count,
                        bytes_sent,
                    )

                if bytes_sent == 0:
                    request.count = 0
                    break

                request.offset += bytes_sent
                request.count -= bytes_sent

            return True
        except BlockingIOError:
            return False
        except ConnectionResetError:
            raise
        except OSError as exc:
            # macOS reports a reset socket as ENOTCONN instead of ECONNRESET.
            if sys.platform == "darwin" and exc.errno == 57:
                raise ConnectionResetError()
            raise


cdef class SelectorSocketTransport(SelectorStreamTransport):
    """Provide bidirectional stream transport behavior for a socket."""

    def __init__(self, loop, sock, protocol, waiter=None, server=None):
        SelectorStreamTransport.__init__(self, loop, sock, protocol, server)
        self._sendfile_compatible = os.name != 'nt'

        self._loop.call_soon((<object>self)._call_protocol_connection_made)
        # only start reading when connection_made() has been called
        self._loop.call_soon(self._loop.add_reader,
                             self._fileno_obj, self._read_ready)
        if waiter is not None:
            # only wake up the waiter when connection_made() has been called
            self._loop.call_soon(_set_result_unless_cancelled_callback, waiter, None)

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
            Py_ssize_t total_bytes_read = 0

        while total_bytes_read < _max_read_bytes_per_cycle_hint:
            if self._finalizing_close:
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

            total_bytes_read += bytes_read

            self._call_protocol_buffer_updated(bytes_read)

            if bytes_read < buf_len:
                return NoResult.OK

            # Protocol may have been switched from buffered to simple
            if not self._protocol_buffered:
                return NoResult.OK

    cdef inline NoResult _read_ready__data_received(self) except NoResult.EXC:
        cdef:
            Py_ssize_t bytes_read
            Py_ssize_t total_bytes_read = 0
            bytes data

        while total_bytes_read < _max_read_bytes_per_cycle_hint:
            if self._finalizing_close:
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

            total_bytes_read += bytes_read

            self._call_protocol_data_received(data)

            if bytes_read < _data_received_max_size:
                return NoResult.OK

            # Protocol may have been switched from simple to buffered
            if self._protocol_buffered:
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

    cdef NoResult _write_eof_now(self) except NoResult.EXC:
        self._file.shutdown(socket.SHUT_WR)
        if unlikely(self._is_debug):
            _logger.debug("%r: shutdown(SHUT_WR) done", self)


cdef class SelectorDatagramTransport(DatagramTransport):
    """Provide message-oriented send and receive behavior for a datagram socket."""

    cdef:
        int _family
        bint _has_connection
        bint _write_ready_registered

    def __init__(self, loop, sock, protocol, address, waiter):
        cdef:
            char raw_addr[256]
            unsigned int raw_addr_len = 0
            int family = sock.family

        if address is not None:
            aiofn_pyaddr_to_sockaddr(family, address, raw_addr, &raw_addr_len)

        DatagramTransport.__init__(self, loop, sock, address, 8)
        self._family = family
        self._write_ready_registered = False

        self._set_protocol(protocol)
        self._has_connection = self._extra['peername'] is not None

        self._loop.call_soon((<object>self)._call_protocol_connection_made)
        # only start reading when connection_made() has been called
        self._loop.call_soon(self._loop.add_reader,
                             self._fileno_obj, self._read_ready)
        # only wake up the waiter when connection_made() has been called
        self._loop.call_soon(_set_result_unless_cancelled_callback, waiter, None)

    def __repr__(self):
        info = self._get_fd_repr_info()
        info.append(f'wbuf_size={self._write_backlog_size}')
        return '[{}]'.format(' '.join(info))

    cdef NoResult _stop_reading(self) except NoResult.EXC:
        self._loop.remove_reader(self._fileno_obj)

    cdef NoResult _start_reading(self) except NoResult.EXC:
        self._loop.add_reader(self._fileno_obj, self._read_ready)

    cdef bint _should_report_fatal_error(self, exc) except -1:
        return not isinstance(exc, OSError)

    cpdef _force_close(self, exc):
        if self._finalizing_close:
            return

        self._closing = True
        self._pause_reading()
        self._stop_write_ready()
        self._clear_write_backlog(exc)
        self._schedule_finalize_close(exc)

    cpdef _finalize_close(self, exc):
        try:
            self._call_protocol_connection_lost(exc)
        finally:
            self._file.close()
            self._file = None
            self._protocol = None

    def _read_ready(self):
        cdef:
            PyObject* buffer
            char* buf_ptr
            char raw_addr[256]
            unsigned int raw_addr_len = sizeof(raw_addr)
            Py_ssize_t bytes_read
            object data

        if self._finalizing_close:
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

    cpdef can_write_eof(self):
        return False

    cpdef write_eof(self):
        raise NotImplementedError()

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

    cdef NoResult _ensure_progress(self) except NoResult.EXC:
        if unlikely(self._is_debug):
            _logger.debug(
                "%r: _ensure_progress called, conn_lost=%s, already_registered=%s",
                self,
                self._finalizing_close,
                self._write_ready_registered,
            )

        if self._finalizing_close or self._write_ready_registered:
            return NoResult.OK

        self._write_ready_registered = True
        self._loop.add_writer(self._fileno_obj, self._write_ready)

    cdef NoResult _stop_write_ready(self) except NoResult.EXC:
        if unlikely(self._is_debug):
            _logger.debug("%r: stop write-ready notifications", self)

        if not self._write_ready_registered:
            return NoResult.OK

        self._write_ready_registered = False
        self._loop.remove_writer(self._fileno_obj)

    def _write_ready(self):
        try:
            if unlikely(self._is_debug):
                _logger.debug("%r write_ready event, resume writing from backlog", self)

            while self._write_backlog_size > 0:
                data, addr = self._write_backlog[0]
                if not self._try_sendto(data, addr):
                    break

                self._write_backlog.popleft()
                self._write_backlog_size -= len(data) + self._datagram_header_size

            self._maybe_resume_protocol()

            if self._write_backlog_size == 0:
                self._stop_write_ready()

                # A reentrant close from resume_writing() may already have
                # scheduled finalization.
                if self._closing and not self._finalizing_close:
                    self._schedule_finalize_close(None)
        except:
            self._stop_write_ready()
            self._handle_error('Fatal write error on datagram transport')


cdef class SelectorReadPipeTransport(FDTransport):
    """Provide the read side of a unidirectional pipe transport."""

    def __init__(self, loop, pipe, protocol, waiter):
        mode = os.fstat(pipe.fileno()).st_mode
        if not (stat.S_ISFIFO(mode) or
                stat.S_ISSOCK(mode) or
                stat.S_ISCHR(mode)):
            raise ValueError("Pipe transport is for pipes/sockets only.")

        FDTransport.__init__(self, loop, pipe)
        self._set_protocol(protocol)
        self._extra['pipe'] = pipe

        self._loop.call_soon((<object>self)._call_protocol_connection_made)
        # only start reading when connection_made() has been called
        self._loop.call_soon(self._loop.add_reader,
                             self._fileno_obj, self._read_ready)
        # only wake up the waiter when connection_made() has been called
        self._loop.call_soon(_set_result_unless_cancelled_callback, waiter, None)

    cdef NoResult _stop_reading(self) except NoResult.EXC:
        self._loop.remove_reader(self._fileno_obj)

    cdef NoResult _start_reading(self) except NoResult.EXC:
        self._loop.add_reader(self._fileno_obj, self._read_ready)

    cpdef close(self):
        self.abort()

    cpdef _force_close(self, exc):
        if self._finalizing_close:
            return

        if not self._closing:
            self._closing = True
            self._loop.remove_reader(self._fileno_obj)
        self._schedule_finalize_close(exc)

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

    cpdef _finalize_close(self, exc):
        try:
            self._call_protocol_connection_lost(exc)
        finally:
            self._file.close()
            self._file = None
            self._protocol = None


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

        self._loop.call_soon((<object>self)._call_protocol_connection_made)

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
        if self._write_backlog_size > 0:
            self._force_close(BrokenPipeError())
        else:
            self._force_close(None)

    cdef NoResult _write_eof_now(self) except NoResult.EXC:
        SelectorStreamTransport.close(self)
