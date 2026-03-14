import asyncio
import socket
import ssl
from logging import getLogger
from typing import Optional

from cpython.contextvars cimport *
from cpython.buffer cimport *
from cpython.bytes cimport *
from cpython.bytearray cimport *
from cpython.memoryview cimport *
from cpython.unicode cimport *

from . import constants
from .utils cimport (
    aiofn_unpack_buffer,
    aiofn_validate_buffer,
    aiofn_maybe_copy_buffer,
    aiofn_maybe_copy_buffer_tail,
    aiofn_allocate_bytes,
    aiofn_finalize_bytes
)
from .transport cimport Transport, Protocol, aiofn_is_buffered_protocol
from .ssl_object cimport SSLObject, SSLError, ssl_error_name

from .openssl cimport SSL_RECEIVED_SHUTDOWN


cdef:
    Py_ssize_t SSL_READ_BUFFER_SIZE = 128 * 1024
    Py_ssize_t SSL_WRITE_BUFFER_SIZE = 128 * 1024

    # Number of seconds to wait for SSL handshake to complete
    # The default timeout matches that of Nginx.
    float SSL_HANDSHAKE_TIMEOUT = 60.0

    # Number of seconds to wait for SSL shutdown to complete
    # The default timeout mimics lingering_time
    float SSL_SHUTDOWN_TIMEOUT = 30.0


cpdef enum SSLProtocolState:
    UNWRAPPED = 0
    DO_HANDSHAKE = 1
    WRAPPED = 2
    FLUSHING = 3
    SHUTDOWN = 4



cdef enum AppProtocolState:
    # This tracks the state of app protocol (https://git.io/fj59P):
    #
    #     INIT -cm-> CON_MADE [-dr*->] [-er-> EOF?] -cl-> CON_LOST
    #
    # * cm: connection_made()
    # * dr: data_received()
    # * er: eof_received()
    # * cl: connection_lost()

    STATE_INIT = 0
    STATE_CON_MADE = 1
    STATE_EOF = 2
    STATE_CON_LOST = 3


cdef object _logger = getLogger('aiofastnet.ssl')


cdef inline _create_transport_context(server_side, server_hostname):
    # Client side may pass ssl=True to use a default
    # context; in that case the sslcontext passed is None.
    # The default is secure for client connections.
    # Python 3.4+: use up-to-date strong settings.
    sslcontext = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    if not server_hostname:
        sslcontext.check_hostname = False
    return sslcontext


cdef class SSLTransport(Transport):
    cdef:
        SSLProtocol _ssl_protocol

    def __init__(self, SSLProtocol ssl_protocol):
        self._ssl_protocol = ssl_protocol

    def get_extra_info(self, name, default=None):
        return self._ssl_protocol._get_extra_info(name, default)

    def set_protocol(self, protocol):
        self._ssl_protocol._set_app_protocol(protocol)

    def get_protocol(self):
        return self._ssl_protocol._get_app_protocol()

    def is_reading(self):
        return self._ssl_protocol._get_tcp_transport().is_reading()

    def pause_reading(self):
        """Pause the receiving end.

        No data will be passed to the protocol's data_received()
        method until resume_reading() is called.
        """
        self._ssl_protocol.pause_reading()

    def resume_reading(self):
        """Resume the receiving end.

        Data received will once again be passed to the protocol's
        data_received() method.
        """
        self._ssl_protocol.resume_reading()

    def set_write_buffer_limits(self, high=None, low=None):
        """Set the high- and low-water limits for write flow control.

        These two values control when to call the protocol's
        pause_writing() and resume_writing() methods.  If specified,
        the low-water limit must be less than or equal to the
        high-water limit.  Neither value can be negative.

        The defaults are implementation-specific.  If only the
        high-water limit is given, the low-water limit defaults to an
        implementation-specific value less than or equal to the
        high-water limit.  Setting high to zero forces low to zero as
        well, and causes pause_writing() to be called whenever the
        buffer becomes non-empty.  Setting low to zero causes
        resume_writing() to be called only once the buffer is empty.
        Use of zero for either limit is generally sub-optimal as it
        reduces opportunities for doing I/O and computation
        concurrently.
        """
        self._ssl_protocol._get_tcp_transport().set_write_buffer_limits(high, low)

    def get_write_buffer_limits(self):
        return self._ssl_protocol._get_tcp_transport().get_write_buffer_limits()

    def get_write_buffer_size(self):
        """Return the current size of the write buffers."""
        return self._ssl_protocol._get_tcp_transport().get_write_buffer_size()

    cpdef write(self, data):
        """Write some data bytes to the transport.

        This does not block; it buffers the data and arranges for it
        to be sent out asynchronously.
        """
        self._ssl_protocol.write(data)

    cpdef writelines(self, list_of_data):
        """Write a list (or any iterable) of data bytes to the transport.

        The default implementation concatenates the arguments and
        calls write() on the result.
        """
        self._ssl_protocol.writelines(list_of_data)

    cdef write_c(self, char* ptr, Py_ssize_t sz):
        self._ssl_protocol.write_c(ptr, sz)

    def write_eof(self):
        """Close the write end after flushing buffered data.

        This raises :exc:`NotImplementedError` right now.
        """
        raise NotImplementedError()

    def can_write_eof(self):
        """Return True if this transport supports write_eof(), False if not."""
        return False

    def is_closing(self):
        return self._ssl_protocol._is_closing()

    def close(self):
        """Close the transport.

        Buffered data will be flushed asynchronously.  No more data
        will be received.  After all buffered data is flushed, the
        protocol's connection_lost() method will (eventually) called
        with None as its argument.
        """
        self._ssl_protocol._start_shutdown()

    def abort(self):
        """Close the transport immediately.

        Buffered data will be lost.  No more data will be received.
        The protocol's connection_lost() method will (eventually) be
        called with None as its argument.
        """
        self._ssl_protocol._abort(None)


cdef class SSLProtocol(Protocol):
    """SSL protocol.

    Implementation of SSL on top of a socket using incoming and outgoing
    buffers which are ssl.MemoryBIO objects.
    """

    cdef:
        bint _server_side
        str _server_hostname
        object _ssl_context
        SSLObject _ssl_object

        dict _extra
        list _write_backlog

        object _loop
        SSLTransport _app_transport

        Transport _transport
        object _ssl_handshake_timeout
        object _ssl_shutdown_timeout
        object _ssl_handshake_complete_waiter
        object _ssl_layer_num

        SSLProtocolState _state
        size_t _conn_lost
        AppProtocolState _app_state

        object _app_protocol
        bint _app_protocol_is_buffered
        bint _app_protocol_aiofn

        object _handshake_start_time
        object _handshake_timeout_handle
        object _shutdown_timeout_handle

        bint _reading_paused
        bint _is_debug

    def __init__(self,
                 loop,
                 app_protocol,
                 sslcontext,
                 ssl_handshake_complete_waiter=None,
                 server_side=False, server_hostname=None,
                 call_connection_made=True,
                 ssl_handshake_timeout=None,
                 ssl_shutdown_timeout=None):
        if ssl_handshake_timeout is None:
            ssl_handshake_timeout = SSL_HANDSHAKE_TIMEOUT
        elif ssl_handshake_timeout <= 0:
            raise ValueError(
                f"ssl_handshake_timeout should be a positive number, "
                f"got {ssl_handshake_timeout}")
        if ssl_shutdown_timeout is None:
            ssl_shutdown_timeout = SSL_SHUTDOWN_TIMEOUT
        elif ssl_shutdown_timeout <= 0:
            raise ValueError(
                f"ssl_shutdown_timeout should be a positive number, "
                f"got {ssl_shutdown_timeout}")

        if server_side and not sslcontext:
            raise ValueError('Server side SSL needs a valid SSLContext')

        if not sslcontext or sslcontext == True:
            sslcontext = _create_transport_context(server_side, server_hostname)

        self._server_side = server_side
        self._server_hostname = None if server_side else server_hostname
        self._ssl_context = sslcontext
        self._ssl_object = None
        # SSL-specific extra info. More info are set when the handshake
        # completes.
        self._extra = dict(sslcontext=sslcontext)

        # App data write buffering
        self._write_backlog = []

        self._loop = loop
        self._set_app_protocol(app_protocol)
        self._app_transport = None
        # transport, ex: SelectorSocketTransport
        self._transport = None
        self._ssl_handshake_timeout = ssl_handshake_timeout
        self._ssl_shutdown_timeout = ssl_shutdown_timeout
        self._ssl_handshake_complete_waiter = ssl_handshake_complete_waiter
        self._ssl_layer_num = 0

        self._state = UNWRAPPED
        self._conn_lost = 0  # Set when connection_lost called
        if call_connection_made:
            self._app_state = STATE_INIT
        else:
            self._app_state = STATE_CON_MADE
        self._reading_paused = False
        self._is_debug = loop.get_debug()

    def __repr__(self):
        sock: Optional[socket.socket] = self._transport.get_extra_info("socket") \
            if self._transport is not None else None
        if sock is not None:
            info = [f"fd={sock.fileno()}"]
        else:
            info = [f"fd=n/a"]

        info.append(self.__class__.__name__)
        if self._server_side:
            info.append("server")
        else:
            info.append("client")

        info.append(f"#{self._ssl_layer_num}")

        wbuf_size = self.get_local_write_buffer_size()
        info.append(f'wbuf_size={wbuf_size}')
        return '[{}]'.format(' '.join(info))

    cpdef is_buffered_protocol(self):
        return True

    cpdef _set_app_protocol(self, app_protocol):
        self._app_protocol = app_protocol
        self._app_protocol_is_buffered = aiofn_is_buffered_protocol(app_protocol)
        self._app_protocol_aiofn = isinstance(app_protocol, Protocol)

    cpdef _get_app_protocol(self):
        return self._app_protocol

    cpdef get_app_transport(self):
        if self._app_transport is None:
            self._app_transport = SSLTransport(self)
        return self._app_transport

    cdef inline Transport _get_tcp_transport(self):
        return self._transport

    def connection_made(self, transport):
        """Called when the low-level connection is made.

        Start the SSL handshake.
        """
        self._transport = transport
        underlying_ssl_layer_num = self._transport.get_extra_info('ssl_layer_num')
        if underlying_ssl_layer_num is not None:
            self._ssl_layer_num = underlying_ssl_layer_num + 1
        self._start_handshake()

    def connection_lost(self, exc):
        """Called when the low-level connection is lost or closed.

        The argument is an exception object or None (the latter
        meaning a regular EOF is received or the connection was
        aborted or closed).
        """
        self._write_backlog.clear()
        self._ssl_object.outgoing_bio_reset()

        self._conn_lost += 1

        if self._state != DO_HANDSHAKE:
            if self._app_state == STATE_CON_MADE or \
                    self._app_state == STATE_EOF:
                self._app_state = STATE_CON_LOST
                self._loop.call_soon(self._app_protocol.connection_lost, exc)
        self._set_state(UNWRAPPED)
        self._transport = None

        # Decrease ref counters to user instances to avoid cyclic references
        # between user protocol, SSLProtocol and SSLTransport.
        # This helps to deallocate useless objects asap.
        # If not done then some tests like test_create_connection_memory_leak
        # will fail.
        self._app_transport = None
        self._app_protocol = None
        self._wakeup_waiter(exc)

        if self._shutdown_timeout_handle:
            self._shutdown_timeout_handle.cancel()
            self._shutdown_timeout_handle = None
        if self._handshake_timeout_handle:
            self._handshake_timeout_handle.cancel()
            self._handshake_timeout_handle = None

    cdef get_buffer_c(self, Py_ssize_t n, char** buf_ptr, Py_ssize_t* buf_len):
        self._ssl_object.incoming_bio_get_write_buf(buf_ptr, buf_len)

    cpdef buffer_updated(self, Py_ssize_t nbytes):
        self._ssl_object.incoming_bio_produce(nbytes)

        if self._is_debug:
            _logger.debug("%r: buffer_updated(%d)", self, nbytes)

        if self._state == DO_HANDSHAKE:
            self._do_handshake()

        elif self._state == WRAPPED:
            self._do_read()

        elif self._state == FLUSHING:
            self._do_flush()

        elif self._state == SHUTDOWN:
            self._do_shutdown()

    # Underlying transport use this to take into account upstream write buffer
    # size when deciding to report pause_writing()/resume_writing()
    cpdef Py_ssize_t get_local_write_buffer_size(self) except -1:
        cdef Py_ssize_t total = 0
        for data in self._write_backlog:
            total += len(data)

        if self._app_protocol_aiofn:
            total += (<Protocol> self._app_protocol).get_local_write_buffer_size()

        if self._ssl_object is not None:
            total += self._ssl_object.outgoing_bio_pending()

        return total

    def eof_received(self):
        """Called when the other end of the low-level stream
        is half-closed.

        If this returns a false value (including None), the transport
        will close itself.  If it returns a true value, closing the
        transport is up to the protocol.
        """
        try:
            if self._is_debug:
                _logger.debug("%r: received EOF", self)

            if self._state == DO_HANDSHAKE:
                self._on_handshake_complete(ConnectionResetError)

            elif self._state == WRAPPED or self._state == FLUSHING:
                # We treat a low-level EOF as a critical situation similar to a
                # broken connection - just send whatever is in the buffer and
                # close. No application level eof_received() is called -
                # because we don't want the user to think that this is a
                # graceful shutdown triggered by SSL "close_notify".
                self._set_state(SHUTDOWN)
                self._on_shutdown_complete(None)

            elif self._state == SHUTDOWN:
                self._on_shutdown_complete(None)

        except Exception:
            self._transport.close()
            raise

    cdef inline _wakeup_waiter(self, exc=None):
        if (self._ssl_handshake_complete_waiter is not None and
                not self._ssl_handshake_complete_waiter.done()):
            if exc is not None:
                self._ssl_handshake_complete_waiter.set_exception(exc)
            else:
                self._ssl_handshake_complete_waiter.set_result(None)

    cdef inline _get_extra_info(self, name, default=None):
        if name == "ssl_object":
            return self._ssl_object
        elif name == "ssl_protocol":
            return self
        elif name == "ssl_layer_num":
            return self._ssl_layer_num
        elif name in self._extra:
            return self._extra[name]
        elif self._transport is not None:
            return self._transport.get_extra_info(name, default)
        else:
            return default

    cdef inline _set_state(self, SSLProtocolState new_state):
        cdef bint allowed = False

        if self._is_debug:
            _logger.debug("%r: change state to %s", self, SSLProtocolState(new_state).name)

        if new_state == UNWRAPPED:
            allowed = True

        elif self._state == UNWRAPPED and new_state == DO_HANDSHAKE:
            allowed = True

        elif self._state == DO_HANDSHAKE and new_state == WRAPPED:
            allowed = True

        # User requested re-negotiate
        elif self._state == WRAPPED and new_state == DO_HANDSHAKE:
            allowed = True

        elif self._state == WRAPPED and new_state == FLUSHING:
            allowed = True

        elif self._state == WRAPPED and new_state == SHUTDOWN:
            allowed = True

        elif self._state == FLUSHING and new_state == SHUTDOWN:
            allowed = True

        if allowed:
            self._state = new_state

        else:
            raise RuntimeError(
                'cannot switch state from {} to {}'.format(
                    self._state, new_state))

    # Handshake flow

    cdef inline _start_handshake(self):
        if self._is_debug:
            _logger.debug("%r: starts SSL handshake", self)
            self._handshake_start_time = self._loop.time()
        else:
            self._handshake_start_time = None

        self._set_state(DO_HANDSHAKE)

        # start handshake timeout count down
        self._handshake_timeout_handle = \
            self._loop.call_later(self._ssl_handshake_timeout,
                                  self._check_handshake_timeout)

        try:
            self._ssl_object = SSLObject(
                self._ssl_context,
                self._server_side,
                self._server_hostname,
                SSL_READ_BUFFER_SIZE,
                SSL_WRITE_BUFFER_SIZE
            )
        except Exception as ex:
            self._on_handshake_complete(ex)
        else:
            self._do_handshake()

    cdef inline _check_handshake_timeout(self):
        if self._state == DO_HANDSHAKE:
            msg = (
                f"SSL handshake is taking longer than "
                f"{self._ssl_handshake_timeout} seconds: "
                f"aborting the connection"
            )
            self._fatal_error(ConnectionAbortedError(msg))

    cdef inline _do_handshake(self):
        cdef:
            int rc
            int ssl_error

        while True:
            rc = self._ssl_object.do_handshake()
            if rc == 1:
                if self._is_debug:
                    _logger.debug("%r: SSL_do_handshake()=%d", self, rc)
                self._on_handshake_complete(None)
                self._maybe_send_outgoing(True)
                return

            # Since our outgoing bio has limited capacity we may get
            # SSL_ERROR_WANT_WRITE. Handshake does not need much space, but for
            # correctness-sake we need flush and re-try
            ssl_error = self._ssl_object.get_error(rc)
            if self._is_debug:
                _logger.debug("%r: SSL_do_handshake()=%d, %s",
                              self, rc, ssl_error_name(ssl_error))

            if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                self._maybe_send_outgoing(True)
                continue

            if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                self._maybe_send_outgoing(True)
                return

            self._on_handshake_complete(self._ssl_object.make_exc_from_ssl_error("ssl handshake failed", ssl_error))
            return

    cdef inline _on_handshake_complete(self, handshake_exc):
        if self._handshake_timeout_handle is not None:
            self._handshake_timeout_handle.cancel()
            self._handshake_timeout_handle = None

        try:
            if handshake_exc is None:
                self._set_state(WRAPPED)
            else:
                raise handshake_exc
        except Exception as exc:
            self._set_state(UNWRAPPED)
            if isinstance(exc, ssl.CertificateError):
                msg = 'SSL handshake failed on verifying the certificate'
            else:
                msg = 'SSL handshake failed'
            self._fatal_error(exc, msg)
            self._wakeup_waiter(exc)
            return

        if self._is_debug:
            dt = self._loop.time() - self._handshake_start_time
            _logger.debug("%r: SSL handshake took %.1f ms", self, dt * 1e3)

        # Add extra info that becomes available after handshake.
        # TODO: add compression
        self._extra.update(
            peercert=self._ssl_object.getpeercert(),
            cipher=self._ssl_object.cipher(),
            compression=self._ssl_object.compression()
        )
        if self._app_state == STATE_INIT:
            self._app_state = STATE_CON_MADE
            try:
                self._app_protocol.connection_made(self.get_app_transport())
            except (SystemExit, KeyboardInterrupt):
                raise
            except Exception as exc:
                self._fatal_error_no_close(exc, "user connection_made raised an exception")
        self._wakeup_waiter()

        # We should wakeup user code before sending the first data below. In
        # case of `start_tls()`, the user can only get the SSLTransport in the
        # wakeup callback, because `connection_made()` is not called again.
        # We should schedule the first data later than the wakeup callback so
        # that the user get a chance to e.g. check ALPN with the transport
        # before having to handle the first data.
        self._loop.call_soon(self._do_read)

    # Shutdown flow

    cdef inline bint _is_closing(self) noexcept:
        return self._state in (FLUSHING, SHUTDOWN, UNWRAPPED)

    cdef inline _start_shutdown(self):
        if self._state in (FLUSHING, SHUTDOWN, UNWRAPPED):
            return
        # we don't need the context for _abort or the timeout, because
        # TCP transport._force_close() should be able to call
        # connection_lost() in the right context
        if self._state == DO_HANDSHAKE:
            self._abort(None)
        else:
            self._set_state(FLUSHING)
            self._shutdown_timeout_handle = \
                self._loop.call_later(self._ssl_shutdown_timeout,
                                      lambda: self._check_shutdown_timeout())
            self._do_flush()

    cdef inline _check_shutdown_timeout(self):
        if self._state in (FLUSHING, SHUTDOWN):
            self._abort(asyncio.TimeoutError('SSL shutdown timed out'))

    cdef inline _do_read_into_void(self):
        """Consume and discard incoming application data.

        If close_notify is received for the first time, call eof_received.
        """
        cdef:
            bytearray buffer = PyByteArray_FromStringAndSize(NULL, 16*1024)
            size_t bytes_read
            int rc = 1
        while rc == 1:
            rc = self._ssl_object.read_ex(
                PyByteArray_AS_STRING(buffer),
                PyByteArray_GET_SIZE(buffer),
                &bytes_read
            )

            if rc == 1 and self._is_debug:
                _logger.debug("%r: SSL_read_ex(buf_len=%d, bytes_read=%d)=%d",
                              self, PyByteArray_GET_SIZE(buffer), bytes_read, rc)

        cdef int ssl_error = self._ssl_object.get_error(rc)
        if self._is_debug:
            _logger.debug("%r: SSL_read_ex(buf_len=%d, ...)=%d, %s",
                          self, PyByteArray_GET_SIZE(buffer),
                          rc, ssl_error_name(ssl_error))

        if ssl_error in (SSLError.SSL_ERROR_WANT_READ, SSLError.SSL_ERROR_WANT_WRITE):
            return

        if ssl_error == SSLError.SSL_ERROR_ZERO_RETURN:
            self._call_eof_received()
            return

        raise self._ssl_object.make_exc_from_ssl_error("SSL_read_ex failed", ssl_error)

    cdef inline _do_flush(self):
        """Flush the write backlog, discarding new data received.

        We don't send close_notify in FLUSHING because we still want to send
        the remaining data over SSL, even if we received a close_notify. Also,
        no application-level resume_writing() or pause_writing() will be called
        in FLUSHING, as we could fully manage the flow control internally.
        """
        try:
            self._do_read_into_void()
            self._flush_write_backlog()
        except Exception as ex:
            self._on_shutdown_complete(ex)
        else:
            if not self.get_local_write_buffer_size():
                self._set_state(SHUTDOWN)
                self._do_shutdown()

    cdef inline _do_shutdown(self):
        """Send close_notify and wait for the same from the peer."""
        cdef:
            int rc
            int err_code

        try:
            # we must skip all application data (if any) before unwrap
            self._do_read_into_void()

            while True:
                rc = self._ssl_object.shutdown()
                if self._is_debug and rc in (1, 0):
                    _logger.debug("%r: SSL_shutdown()=%d", self, rc)

                if rc == 1:
                    self._maybe_send_outgoing(True)
                    self._on_shutdown_complete(None)
                    return

                # From openssl docs
                # Unlike most other function, returning 0 does not indicate an
                # error. SSL_get_error(3) should not get called, it may
                # misleadingly indicate an error even though no error occurred.
                if rc == 0:
                    self._maybe_send_outgoing(True)
                    return

                err_code = self._ssl_object.get_error(rc)

                if self._is_debug:
                    _logger.debug("%r: SSL_shutdown()=%d, %s",
                                  self, rc, ssl_error_name(err_code))

                # Re-try shutdown because outgoing bio has no space left
                if err_code == SSLError.SSL_ERROR_WANT_WRITE:
                    self._maybe_send_outgoing(True)
                    continue

                if err_code == SSLError.SSL_ERROR_WANT_READ:
                    self._maybe_send_outgoing(True)
                    return

                raise self._ssl_object.make_exc_from_ssl_error("SSL_shutdown failed", err_code)
        except Exception as ex:
            self._on_shutdown_complete(ex)

    cdef inline _on_shutdown_complete(self, shutdown_exc):
        if self._shutdown_timeout_handle is not None:
            self._shutdown_timeout_handle.cancel()
            self._shutdown_timeout_handle = None

        # we don't need the context here because TCP transport.close() should
        # be able to call connection_made() in the right context
        if shutdown_exc:
            self._fatal_error(shutdown_exc, 'Error occurred during shutdown')
        else:
            self._transport.close()

    cdef inline _abort(self, exc):
        self._set_state(UNWRAPPED)
        if self._transport is not None:
            self._transport._force_close(exc)

    # Outgoing flow

    cdef inline write(self, data):
        """Write some data bytes to the transport.

        This does not block; it buffers the data and arranges for it
        to be sent out asynchronously.
        """
        if not self._is_protocol_ready():
            return

        aiofn_validate_buffer(data)

        cdef:
            char * data_ptr
            Py_ssize_t data_len

        try:
            if self._write_backlog:
                if data:
                    self._write_backlog.append(aiofn_maybe_copy_buffer(data))
                return

            aiofn_unpack_buffer(data, &data_ptr, &data_len)
            if data_len == 0:
                return

            tail = self._write_impl(data, data_ptr, data_len, True)
            if tail is not None:
                self._write_backlog.append(tail)
                if self._is_debug:
                    _logger.debug("%r: appended %d bytes to write_backlog", self, len(tail))
                return
        except Exception as ex:
            self._fatal_error(ex, 'Fatal error on SSL protocol')

    cdef inline write_c(self, char* data_ptr, Py_ssize_t data_len):
        if not self._is_protocol_ready():
            return

        if data_len == 0:
            return

        try:
            if self._write_backlog:
                self._write_backlog.append(PyBytes_FromStringAndSize(data_ptr, data_len))
                return

            tail = self._write_impl(None, data_ptr, data_len, True)
            if tail is not None:
                self._write_backlog.append(tail)
                return
        except Exception as ex:
            self._fatal_error(ex, 'Fatal error on SSL protocol')

    cdef inline writelines(self, list_of_data):
        """
        Write a list (or any iterable) of data bytes to the transport.
        """
        if not self._is_protocol_ready():
            return

        for data in list_of_data:
            aiofn_validate_buffer(data)

        cdef:
            char* data_ptr
            Py_ssize_t data_len
            bint add_to_backlog = False
            Py_ssize_t data_cnt = len(list_of_data)
            Py_ssize_t idx
            bint is_last

        try:
            if self._write_backlog:
                self._write_backlog.extend(aiofn_maybe_copy_buffer(data)
                                           for data in list_of_data if data)
                return

            for idx in range(data_cnt):
                data = list_of_data[idx]
                if add_to_backlog:
                    if len(data) > 0:
                        self._write_backlog.append(aiofn_maybe_copy_buffer(data))
                    continue

                aiofn_unpack_buffer(data, &data_ptr, &data_len)
                if data_len == 0:
                    continue

                is_last = idx == (data_cnt - 1)
                tail = self._write_impl(data, data_ptr, data_len, is_last)
                if tail is not None:
                    self._write_backlog.append(tail)
                    add_to_backlog = True
        except Exception as ex:
            self._fatal_error(ex, 'Fatal error on SSL protocol')

    cdef inline pause_reading(self):
        self._reading_paused = True
        self._transport.pause_reading()

    cdef inline resume_reading(self):
        if self._reading_paused:
            self._reading_paused = False
            self._loop.call_soon(self._do_read)
        self._transport.resume_reading()

    cpdef pause_writing(self):
        self._app_protocol.pause_writing()

    cpdef resume_writing(self):
        self._app_protocol.resume_writing()

    cdef inline bint _is_protocol_ready(self) except -1:
        if self._state in (FLUSHING, SHUTDOWN, UNWRAPPED):
            if self._conn_lost >= constants.LOG_THRESHOLD_FOR_CONNLOST_WRITES:
                _logger.warning('SSL connection is closed')
            self._conn_lost += 1
            return False
        else:
            return True

    cdef inline _flush_write_backlog(self):
        if self._state not in (WRAPPED, FLUSHING):
            return

        cdef:
            Py_ssize_t backlog_size = len(self._write_backlog)
            char * data_ptr
            Py_ssize_t data_len
            bint add_to_backlog = False
            Py_ssize_t idx = 0
            Py_ssize_t items_completed = 0

        if backlog_size == 0:
            return

        try:
            for idx in range(len(self._write_backlog)):
                data = self._write_backlog[idx]
                aiofn_unpack_buffer(data, &data_ptr, &data_len)
                # Data was validated and cleared from empty objects in write/writelines

                tail = self._write_impl(data, data_ptr, data_len, True)
                if tail is not None:
                    self._write_backlog[idx] = tail
                    break
                else:
                    items_completed += 1
            del self._write_backlog[:items_completed]
        except Exception as ex:
            self._fatal_error(ex, 'Fatal error on SSL protocol')

    cdef inline _write_impl(self, data, char* data_ptr, Py_ssize_t data_len, bint is_last):
        """
        Do SSL_write, if outgoing BIO reach threshold size flush it to the 
        underlying protocol. If is_last=True, flush in the end regardless.
        If SSL_write returns SSL_ERROR_WANT_READ, materialize and return 
        remaining unsent part of the buffer. 
        On success return None.
        """
        cdef:
            size_t bytes_written
            int rc = 1
            int ssl_error

        while data_len != 0:
            # SSL_write_ex behave differently from non-blocking write syscall
            # If outgoing memory bio has some space, but doesn't have enough space
            # SSL_write_ex returns 0 and SSL_ERROR_WANT_WRITE is set.
            #
            # In such case we flush outgoing buffer and restart SSL_write_ex with
            # exactly same data_ptr, data_len.
            #
            # It is very confusing but bytes_written in such case may be > 16K
            # because SSL_write_ex, despite previously returning error,
            # has stored some of its processed data from the last step in its
            # own internal buffer.
            #
            # outgoing buffer in such case may receive 2 SSL records with one
            # SSL_write_ex call.
            rc = self._ssl_object.write_ex(data_ptr, data_len, &bytes_written)

            if rc:
                if self._is_debug:
                    _logger.debug("%r: SSL_write_ex(..., %d, %d) = %d", self,
                                  data_len, bytes_written, rc)

                # Success path, we wrote all or some data
                if data_len == <Py_ssize_t>bytes_written:
                    self._maybe_send_outgoing(is_last)
                    return None

                # Not all data was written, this is most likely because outgoing
                # static BIO ran out of memory or full SSL record was written
                # (if SSL_ENABLE_PARTIAL_WRITE is set)
                data_ptr += bytes_written
                data_len -= bytes_written
                self._maybe_send_outgoing(False)
            else:
                ssl_error = self._ssl_object.get_error(rc)

                if self._is_debug:
                    _logger.debug("%r: SSL_write_ex(..., %d, %d)=%d, %s",
                                  self, data_len, bytes_written, rc,
                                  ssl_error_name(ssl_error))

                # On any error we always need to flush outgoing BIO
                self._maybe_send_outgoing(True)

                # Since outgoing BIO is a static memory it may simply run out
                # of capacity
                if ssl_error == SSLError.SSL_ERROR_WANT_WRITE:
                    continue

                # This is rare but still possible. SSL may refuse to send data
                # because of re-negotiation. Materialize and return remaining
                # data. We will proceed when new data arrives and re-negotiation
                # is complete
                if ssl_error == SSLError.SSL_ERROR_WANT_READ:
                    return aiofn_maybe_copy_buffer_tail(data, data_ptr,
                                                        data_len)

                # Consider any other error as fatal, _write_impl caller will
                # initiate disconnect.
                raise self._ssl_object.make_exc_from_ssl_error(
                    "SSL_write_ex failed", ssl_error)

    cdef inline _maybe_send_outgoing(self, bint is_last):
        # We call _maybe_send_outgoing if there MAY be some data to send,
        # Upstream logic doesn't check itself if there are actually some data
        # to send

        cdef:
            char* ptr
            long sz = self._ssl_object.outgoing_bio_get_data(&ptr)

        if sz <= 0:
            return

        if sz < SSL_WRITE_BUFFER_SIZE and not is_last:
            return

        self._transport.write_c(ptr, sz)
        if self._is_debug:
            _logger.debug("%r: wrote %d bytes to the underlying transport: is_last=%d", self, sz, is_last)

        self._ssl_object.outgoing_bio_consume(sz)

    # Incoming flow

    cpdef _do_read(self):
        if self._state not in (WRAPPED, FLUSHING):
            return
        try:
            if not self._reading_paused:
                if self._app_protocol_is_buffered:
                    self._do_read__buffered()
                else:
                    self._do_read__copied()

                self._maybe_send_outgoing(True)
                if self._write_backlog:
                    self._flush_write_backlog()
        except Exception as ex:
            self._fatal_error(ex, 'Fatal error on SSL protocol')

    cdef inline _do_read__buffered(self):
        cdef:
            char* buf_ptr
            Py_ssize_t buf_len

        if self._app_protocol_aiofn:
            app_buffer = (<Protocol>self._app_protocol).get_buffer_c(-1, &buf_ptr, &buf_len)
        else:
            app_buffer = self._app_protocol.get_buffer(-1)
            aiofn_unpack_buffer(app_buffer, &buf_ptr, &buf_len)

        if buf_len == 0:
            raise RuntimeError('get_buffer() returned an empty buffer')

        cdef:
            size_t last_bytes_read
            Py_ssize_t total_bytes_read = 0
            int rc = 0

        while buf_len > 0:
            rc = self._ssl_object.read_ex(buf_ptr, buf_len, &last_bytes_read)

            if not rc:
                break
            buf_ptr += last_bytes_read
            buf_len -= last_bytes_read
            total_bytes_read += last_bytes_read
            if self._is_debug:
                _logger.debug("%r: SSL_read_ex(buf_len=%d, bytes_read=%d)=%d",
                              self, buf_len, last_bytes_read, rc)


        cdef int last_error = self._ssl_object.get_error(rc)
        if self._is_debug:
            _logger.debug("%r: SSL_read_ex(buf_len=%d, bytes_read=%d)=%d, %s",
                          self, buf_len, last_bytes_read, rc,
                          ssl_error_name(last_error))

        if total_bytes_read > 0:
            if self._app_protocol_aiofn:
                (<Protocol>self._app_protocol).buffer_updated(total_bytes_read)
            else:
                self._app_protocol.buffer_updated(total_bytes_read)

        # It could be that buffer_update user handler paused reading
        # But we do have extra data in the incoming BIO or in SSL object.
        # We could not read it because user provided buffer was too small.
        # Schedule _do_read immediately, and check in _do_read that reading is
        # not paused.
        # For resume_reading() check if we have some pending data for reading
        # and
        if buf_len == 0:
            self._loop.call_soon(self._do_read)
            return

        self._post_read(last_error)

    cdef inline _do_read__copied(self):
        cdef:
            size_t bytes_read
            list data = None
            PyObject* bytes_obj
            char* bytes_buffer_ptr
            bytes first_chunk = None, curr_chunk
            Py_ssize_t bytes_estimated
            int rc

        while True:
            bytes_estimated = (self._ssl_object.pending() +
                               self._ssl_object.incoming_bio_pending() +
                               256)
            bytes_estimated = max(1024, bytes_estimated)

            bytes_obj = aiofn_allocate_bytes(bytes_estimated, &bytes_buffer_ptr)
            rc = self._ssl_object.read_ex(
                bytes_buffer_ptr,
                bytes_estimated,
                &bytes_read)

            if not rc:
                curr_chunk = aiofn_finalize_bytes(bytes_obj, 0)
                break
            else:
                curr_chunk = aiofn_finalize_bytes(bytes_obj, bytes_read)

            if self._is_debug:
                _logger.debug("%r: SSL_read_ex(buf_len=%d, bytes_read=%d)=%d",
                              self, bytes_estimated, bytes_read, rc)

            if first_chunk is None:
                first_chunk = curr_chunk
            elif data is None:
                data = [first_chunk, curr_chunk]
            else:
                data.append(curr_chunk)

        cdef int last_error = self._ssl_object.get_error(rc)
        if self._is_debug:
            _logger.debug("%r: SSL_read_ex(buf_len=%d, bytes_read=%d)=%d, %s",
                          self, bytes_estimated, bytes_read, rc,
                          ssl_error_name(last_error))

        user_data = None
        if data is not None:
            user_data = b''.join(data)
        elif first_chunk is not None:
            user_data = first_chunk

        if user_data is not None:
            if self._app_protocol_aiofn:
                (<Protocol>self._app_protocol).data_received(user_data)
            else:
                self._app_protocol.data_received(user_data)

        self._post_read(last_error)

    cdef inline _post_read(self, int last_error):
        if last_error in (SSLError.SSL_ERROR_WANT_READ, SSLError.SSL_ERROR_WANT_WRITE):
            return

        if last_error == SSLError.SSL_ERROR_ZERO_RETURN:
            if self._ssl_object.get_shutdown() & SSL_RECEIVED_SHUTDOWN:
                # close_notify
                self._call_eof_received()
                self._start_shutdown()
                return

        raise self._ssl_object.make_exc_from_ssl_error("SSL_read_ex failed", last_error)

    cdef inline _call_eof_received(self):
        if self._app_state == STATE_CON_MADE:
            self._app_state = STATE_EOF
            try:
                keep_open = self._app_protocol.eof_received()
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as ex:
                self._fatal_error(ex, 'Error calling eof_received()')
            else:
                if keep_open:
                    _logger.warning('returning true from eof_received() '
                                       'has no effect when using ssl')

    cdef inline _fatal_error(self, exc, message='Fatal error on transport'):
        self._abort(exc)

        if isinstance(exc, OSError):
            if self._loop.get_debug():
                _logger.debug("%r: %s", self, message, exc_info=True)
        elif not isinstance(exc, asyncio.CancelledError):
            self._loop.call_exception_handler({
                'message': message,
                'exception': exc,
                'transport': self._transport,
                'protocol': self,
            })

    cdef inline _fatal_error_no_close(self, exc, message='Fatal error on transport'):
        if isinstance(exc, OSError):
            if self._loop.get_debug():
                _logger.debug("%r: %s", self, message, exc_info=True)
        else:
            self._loop.call_exception_handler({
                'message': message,
                'exception': exc,
                'transport': self._transport,
                'protocol': self,
            })

    # Used for testing only
    def _allow_renegotiation(self):
        self._ssl_object.allow_renegotiation()

    # Used for testing only
    def _renegotiate(self):
        if self._state != WRAPPED:
            raise RuntimeError(
                "renegotiation requires an active wrapped SSL connection")

        cipher = self._extra.get("cipher")
        if cipher is not None and len(cipher) >= 2 and cipher[1] == "TLSv1.3":
            raise NotImplementedError(
                "TLS 1.3 does not support classic SSL renegotiation")

        cdef:
            int rc
            int ssl_error

        try:
            rc = self._ssl_object.renegotiate()
            if rc != 1:
                raise RuntimeError(f"ssl renegotiation request failed")

            self._do_handshake()
        except Exception as ex:
            self._fatal_error(ex, "Fatal error on SSL renegotiation")
