"""Selector-based socket, datagram, and pipe transports.

The hierarchy is:

    SelectorTransport
    |-- SelectorReadPipeTransport
    `-- SelectorWritableTransport
        |-- SelectorDatagramTransport
        `-- SelectorStreamTransport
            |-- SelectorSocketTransport
            `-- SelectorWritePipeTransport
"""

import asyncio
import errno
import os
import socket
import stat
import sys
import warnings
from logging import getLogger
from typing import Optional

from asyncio.trsock import TransportSocket

from cpython.bytes cimport *
from cpython.ref cimport Py_XDECREF

from . import constants
from .transport cimport (
    DatagramWriter,
    FlowControlledWriter,
    SendFileRequestBase,
    StreamWriter,
    Transport,
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


cdef class SendFileRequest(SendFileRequestBase):
    """Mutable progress state for a sendfile operation queued with writes."""

    cdef:
        object fileno
        object offset
        object count


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


cdef class SelectorTransport(Transport):
    """Manage a nonblocking descriptor and its selector read registration."""

    cdef:
        object _file
        object _fileno_obj
        int _fileno
        bint _is_socket

    def __init__(self, loop, file, protocol):
        Transport.__init__(self, loop)
        self._file = file
        self._fileno_obj = file.fileno()
        self._fileno = self._fileno_obj
        self._is_socket = True
        if isinstance(file, socket.socket):
            file.setblocking(False)
        else:
            os.set_blocking(self._fileno_obj, False)

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

    cdef NoResult _stop_reading(self) except NoResult.EXC:
        self._loop.remove_reader(self._fileno_obj)

    cdef NoResult _start_reading(self) except NoResult.EXC:
        self._loop.add_reader(self._fileno_obj, self._read_ready)

    cpdef close(self):
        self.abort()

    # May be used by create_connection/create_server
    # Keep cpdef
    cpdef _force_close(self, exc):
        if self._finalizing_close:
            return
        if not self._closing:
            self._closing = True
            self._loop.remove_reader(self._fileno_obj)
        self._finalizing_close = True
        self._loop.call_soon(self._finalize_close, exc)

    def _read_ready(self):
        raise NotImplementedError()

    def _finalize_close(self, exc):
        try:
            self._call_protocol_connection_lost(exc)
        finally:
            self._file.close()
            self._file = None
            self._protocol = None



cdef class SelectorWritableTransport(SelectorTransport):
    """Manage transport lifecycle around a composed flow-controlled writer."""

    cdef FlowControlledWriter _writer

    def __init__(self, loop, file, protocol):
        SelectorTransport.__init__(self, loop, file, protocol)
        self._writer = None

    def __repr__(self):
        info = self._get_repr_info()
        info.append(f'wbuf_size={self._writer.backlog_size}')
        return '[{}]'.format(' '.join(info))

    cpdef tuple get_write_buffer_limits(self):
        self._check_thread("get_write_buffer_limits")
        return self._writer.get_write_buffer_limits()

    cpdef set_write_buffer_limits(self, high=None, low=None):
        self._check_thread("set_write_buffer_limits")
        self._writer.set_write_buffer_limits(high, low)

    cpdef close(self):
        self._check_thread("close")
        if self._closing:
            return
        self._closing = True
        self._loop.remove_reader(self._fileno_obj)
        if not self._writer.backlog:
            self._finalizing_close = True
            self._writer.clear(None)
            self._loop.call_soon(self._finalize_close, None)

    cpdef get_write_buffer_size(self):
        self._check_thread("get_write_buffer_size")
        return self._writer.get_write_buffer_size()

    cdef bint _should_report_fatal_error(self, exc) except -1:
        return not isinstance(exc, OSError)

    cpdef _force_close(self, exc):
        if self._finalizing_close:
            return
        self._writer.clear(exc)
        SelectorTransport._force_close(self, exc)


cdef class SelectorStreamTransport(SelectorWritableTransport):
    """Implement ordered byte-stream writes, writev, EOF, and sendfile queues."""

    cdef public bint _sendfile_compatible

    def __init__(self, loop, file, protocol):
        SelectorWritableTransport.__init__(self, loop, file, protocol)
        self._writer = SelectorStreamWriter(
            self,
            self._fileno,
            self._is_socket,
            self._fileno_obj,
        )
        self._sendfile_compatible = False

    cpdef write_nocheck(self, data):
        (<StreamWriter>self._writer).write_nocheck(data)

    cpdef writelines_nocheck(self, list_of_data):
        (<StreamWriter>self._writer).writelines_nocheck(list_of_data)

    cdef NoResult write_c(self, char *ptr, Py_ssize_t size) except NoResult.EXC:
        (<StreamWriter>self._writer).write_c(ptr, size)

    cpdef can_write_eof(self):
        return True

    cpdef write_eof(self):
        cdef StreamWriter writer = <StreamWriter>self._writer

        self._check_thread("write_eof")
        if self._closing or writer.eof:
            return
        writer.eof = True
        if not writer.backlog:
            self._write_eof_now()

    cdef NoResult _write_eof_now(self) except NoResult.EXC:
        raise NotImplementedError()

    cdef bint _try_write_backlog(self, Py_ssize_t *total_bytes_sent) except -1:
        cdef:
            StreamWriter writer = <StreamWriter>self._writer
            WriteRequest request
            Py_ssize_t bytes_sent = 0
            Py_ssize_t bytes_to_send = 0
            Py_ssize_t iovecs_count = 0

        for item in writer.backlog:
            if isinstance(item, SendFileRequest):
                break

            assert isinstance(item, WriteRequest)
            request = <WriteRequest>item
            writer.iovecs[iovecs_count].iov_base = request.ptr
            writer.iovecs[iovecs_count].iov_len = request.size
            bytes_to_send += request.size
            iovecs_count += 1

            if iovecs_count < AIOFN_MAX_IOVEC:
                continue

            bytes_sent = writer.flush_iovecs(iovecs_count, total_bytes_sent)
            if bytes_sent != bytes_to_send:
                return False

            iovecs_count = 0
            bytes_to_send = 0
            bytes_sent = 0

        if iovecs_count:
            bytes_sent = writer.flush_iovecs(iovecs_count, total_bytes_sent)

        return bytes_sent == bytes_to_send

    cdef inline NoResult _adjust_write_backlog(self, Py_ssize_t bytes_sent) except NoResult.EXC:
        (<StreamWriter>self._writer).consume(bytes_sent)

    cdef inline bint _try_sendfile_from_backlog_top(self) except -1:
        cdef SendFileRequest sendfile_req = <SendFileRequest>self._writer.backlog[0]

        orig_req_size = sendfile_req.count

        cdef bint all_sent = self._try_sendfile(sendfile_req)
        if all_sent:
            self._writer.backlog.popleft()
            if not sendfile_req.waiter.done():
                sendfile_req.waiter.set_result(None)
        self._writer.backlog_size -= <Py_ssize_t>(orig_req_size - sendfile_req.count)

        return all_sent

    cdef inline NoResult _flush_write_backlog(self) except NoResult.EXC:
        cdef:
            Py_ssize_t bytes_sent
            bint all_sent = True

        while self._writer.backlog and all_sent:
            if isinstance(self._writer.backlog[0], SendFileRequest):
                all_sent = self._try_sendfile_from_backlog_top()
            else:
                bytes_sent = 0
                all_sent = self._try_write_backlog(&bytes_sent)
                self._adjust_write_backlog(bytes_sent)

    def _write_ready(self):
        cdef StreamWriter writer = <StreamWriter>self._writer

        assert self._writer.backlog, 'Data should not be empty'
        if self._finalizing_close:
            return

        try:
            if unlikely(self._is_debug):
                _logger.debug("%r write_ready event, resume writing from backlog", self)
            self._flush_write_backlog()
        except:
            (<SelectorStreamWriter>self._writer).drop_writer()
            self._handle_error('Fatal write error on transport')
        else:
            self._writer.maybe_resume_protocol()
            if not self._writer.backlog:
                (<SelectorStreamWriter>self._writer).drop_writer()
                if self._closing:
                    self._finalizing_close = True
                    self._finalize_close(None)
                elif writer.eof:
                    self._write_eof_now()
        return NoResult.OK

    def sendfile(self, file, offset, count) -> Optional[asyncio.Future[None]]:
        cdef StreamWriter writer = <StreamWriter>self._writer

        self._check_thread("sendfile")

        # This is an undocumented feature in asyncio and uvloop
        # Some 3rdparty tests use it to disable native sendfile (for example aiohttp tests)
        if not self._sendfile_compatible:
            raise NotImplementedError()

        if writer.eof:
            raise RuntimeError('Cannot call sendfile() after write_eof()')

        if self._closing or self._finalizing_close:
            raise RuntimeError("Transport is closing")

        cdef SendFileRequest req = _make_send_file_request(file, offset, count)

        try:
            if not self._writer.backlog:
                if self._try_sendfile(req):
                    return None

            if unlikely(self._is_debug):
                _logger.debug("%r: enqueue SendFileRequest(offset=%d,count=%d)",
                              self, req.offset, req.count)

            self._writer.backlog.append(req)
            self._writer.backlog_size += <Py_ssize_t>req.count
            self._writer._ensure_progress()
            self._writer.maybe_pause_protocol()

            req.waiter = self._loop.create_future()
            return req.waiter
        except:
            self._handle_error('Fatal sendfile error on transport')
            raise

    cdef bint _try_sendfile(self, SendFileRequest req) except -1:
        raise NotImplementedError()


cdef class SelectorStreamWriter(StreamWriter):

    cdef:
        object fileobj
        bint write_ready_registered

    def __init__(
        self,
        Transport transport,
        int fd,
        bint is_socket,
        object fileobj,
    ):
        StreamWriter.__init__(self, transport, fd, is_socket)
        self.fileobj = fileobj
        self.write_ready_registered = False

    cdef NoResult _ensure_progress(self) except NoResult.EXC:
        if unlikely(self.transport._is_debug):
            _logger.debug(
                "%r: _ensure_progress called, conn_lost=%s, already_registered=%s",
                self.transport,
                self.transport._finalizing_close,
                self.write_ready_registered,
            )

        if self.transport._finalizing_close or self.write_ready_registered:
            return NoResult.OK

        self.write_ready_registered = True
        self.transport._loop.add_writer(
            self.fileobj, (<SelectorStreamTransport>self.transport)._write_ready)

    cdef NoResult drop_writer(self) except NoResult.EXC:
        if unlikely(self.transport._is_debug):
            _logger.debug("%r: drop_writer called", self.transport)

        if not self.write_ready_registered:
            return NoResult.OK

        self.write_ready_registered = False
        self.transport._loop.remove_writer(self.fileobj)

    cdef NoResult clear(self, object exc) except NoResult.EXC:
        self.drop_writer()
        FlowControlledWriter.clear(self, exc)
        return NoResult.OK


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

        self._loop.call_soon((<object>self)._call_protocol_connection_made)
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

    def _finalize_close(self, exc):
        try:
            SelectorTransport._finalize_close(self, exc)
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

    def __init__(self, loop, sock, protocol, address, waiter):
        cdef:
            char raw_addr[256]
            unsigned int raw_addr_len = 0
            int family = sock.family

        if address is not None:
            aiofn_pyaddr_to_sockaddr(family, address, raw_addr, &raw_addr_len)

        SelectorWritableTransport.__init__(self, loop, sock, protocol)

        self._extra['socket'] = TransportSocket(sock)
        aiofn_set_socket_extra_info(self._extra, sock)

        self._writer = SelectorDatagramWriter(
            self,
            self._fileno,
            self._fileno_obj,
            family,
            self._extra['peername'] is not None,
            address,
        )

        self._loop.call_soon((<object>self)._call_protocol_connection_made)
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

    cpdef sendto_nocheck(self, data, addr):
        (<DatagramWriter>self._writer).sendto_nocheck(data, addr)

    cpdef can_write_eof(self):
        return False

    cpdef write_eof(self):
        raise NotImplementedError()

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


cdef class SelectorDatagramWriter(DatagramWriter):

    cdef:
        object fileobj
        int fd
        int family
        bint has_connection
        bint write_ready_registered

    def __init__(
        self,
        Transport transport,
        int fd,
        object fileobj,
        int family,
        bint has_connection,
        object address,
    ):
        DatagramWriter.__init__(self, transport, address, 8)

        self.fileobj = fileobj
        self.fd = fd
        self.family = family
        self.has_connection = has_connection
        self.write_ready_registered = False

    cdef object _validate_address(self, object addr):
        cdef:
            char raw_addr[256]
            unsigned int raw_addr_len = 0

        if not self.has_connection:
            # Datagram endpoint creation resolves INET addresses; resolving here could block the event-loop thread.
            aiofn_pyaddr_to_sockaddr(self.family, addr, raw_addr, &raw_addr_len)
        return addr

    cdef bint _try_sendto(self, object data, object addr) except -1:
        cdef:
            SelectorDatagramTransport transport = <SelectorDatagramTransport>self.transport
            char *buf_ptr
            Py_ssize_t buf_len
            Py_ssize_t bytes_sent
            char raw_addr[256]
            unsigned int raw_addr_len = 0
            void *raw_addr_ptr = NULL

        try:
            aiofn_unpack_simple_buffer(data, &buf_ptr, &buf_len, 0)
            if not self.has_connection:
                aiofn_pyaddr_to_sockaddr(self.family, addr, raw_addr, &raw_addr_len)
                raw_addr_ptr = raw_addr

            bytes_sent = aiofn_sendto(self.fd, buf_ptr, buf_len, raw_addr_ptr, raw_addr_len)
            if unlikely(transport._is_debug):
                _logger.debug("%r: aiofn_sendto(...,len=%d)=%d", transport, buf_len, bytes_sent)
            if bytes_sent == -1:
                return False

            return True
        except (BlockingIOError, InterruptedError):
            return False
        except OSError as exc:
            transport._call_protocol_error_received(exc)
            return True

    cdef NoResult _ensure_progress(self) except NoResult.EXC:
        if unlikely(self.transport._is_debug):
            _logger.debug(
                "%r: _ensure_writer called, conn_lost=%s, already_registered=%s",
                self.transport,
                self.transport._finalizing_close,
                self.write_ready_registered,
            )

        if self.transport._finalizing_close or self.write_ready_registered:
            return NoResult.OK

        self.write_ready_registered = True
        self.transport._loop.add_writer(self.fileobj, self._write_ready)
        return NoResult.OK

    cdef NoResult drop_writer(self) except NoResult.EXC:
        if unlikely(self.transport._is_debug):
            _logger.debug("%r: _drop_writer called", self.transport)

        if not self.write_ready_registered:
            return NoResult.OK

        self.write_ready_registered = False
        self.transport._loop.remove_writer(self.fileobj)
        return NoResult.OK

    def _write_ready(self):
        cdef SelectorDatagramTransport transport = <SelectorDatagramTransport>self.transport

        try:
            if unlikely(transport._is_debug):
                _logger.debug("%r write_ready event, resume writing from backlog", transport)

            while self.backlog:
                data, addr = self.backlog[0]
                if not self._try_sendto(data, addr):
                    break

                self.backlog.popleft()
                self.backlog_size -= len(data) + self.header_size

            self.maybe_resume_protocol()
            if not self.backlog:
                self.drop_writer()
                if transport._closing:
                    transport._finalizing_close = True
                    transport._finalize_close(None)
        except:
            self.drop_writer()
            transport._handle_error('Fatal write error on datagram transport')

    cdef NoResult clear(self, object exc) except NoResult.EXC:
        self.drop_writer()
        FlowControlledWriter.clear(self, exc)
        return NoResult.OK


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

        self._loop.call_soon((<object>self)._call_protocol_connection_made)
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
        (<StreamWriter>self._writer).is_socket = False

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
        if self._writer.backlog:
            self._force_close(BrokenPipeError())
        else:
            self._force_close(None)

    cdef NoResult _write_eof_now(self) except NoResult.EXC:
        SelectorWritableTransport.close(self)
