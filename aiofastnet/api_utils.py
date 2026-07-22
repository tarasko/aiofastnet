# Portions of this file are derived from CPython's asyncio sources
# (notably asyncio.base_events and asyncio.selector_events).
# Copyright (c) Python Software Foundation.
# Licensed under the Python Software Foundation License Version 2.
# See LICENSES/PSF-2.0.txt and THIRD_PARTY_NOTICES for details.

import asyncio
import errno
import socket
import ssl
import weakref
from asyncio.trsock import TransportSocket
from logging import getLogger
from typing import Callable, Union, Optional, Tuple

from . import constants, openssl_compat
from .constants import SSL_TIMEOUT_DEFAULTS, SSL_BIO_SIZE_DEFAULTS
from .ssl_transport import SSLTransport_Socket, SSLTransport_Transport
from .transport import SocketTransport, aiofn_is_buffered_protocol
from .wrapped_transport import _should_fallback_to_asyncio, \
    _WrappedBufferedProtocol, _WrappedProtocol, _get_original_loop_method


_HAS_IPv6 = hasattr(socket, 'AF_INET6')
_logger = getLogger('aiofastnet')


def _is_asyncio_loop(loop: asyncio.AbstractEventLoop) -> bool:
    return type(loop).__module__.startswith("asyncio.")


def _validate_ssl_timeout(name: str, value: Optional[float], ssl_or_sslcontext: Optional[Union[bool, ssl.SSLContext]]) -> float:
    if value is not None and not ssl_or_sslcontext:
        raise ValueError(
            f'{name} is only meaningful with ssl')

    if value is not None and value <= 0:
        raise ValueError(f"{name} should be a positive number, got {value}")

    if value is None:
        return SSL_TIMEOUT_DEFAULTS[name]

    return value


def _validate_bio_size(name: str, value: Optional[int], ssl_or_sslcontext: Optional[Union[bool, ssl.SSLContext]]) -> int:
    if value is not None and not ssl_or_sslcontext:
        raise ValueError(
            f'{name} is only meaningful with ssl')

    if value is not None and value < 16384:
        raise ValueError(f"{name} should be a positive number >= 16384, got {value}")

    if value is None:
        return SSL_BIO_SIZE_DEFAULTS[name]

    return value


def _ssl_needs_fallback_engine(sslcontext: ssl.SSLContext) -> bool:
    return openssl_compat.OPENSSL_DYN_LIBS is None or getattr(sslcontext, "_aiofastnet_force_fallback_ssl", False)


async def _create_connection_transport(
        loop: asyncio.AbstractEventLoop,
        sock: socket.socket,
        protocol_factory: Callable[[], asyncio.BaseProtocol],
        ssl: Union[bool, ssl.SSLContext, None],
        server_hostname: Optional[str]=None,
        server_side: bool=False,
        ssl_handshake_timeout: Optional[float]=None,
        ssl_shutdown_timeout: Optional[float]=None,
        ssl_incoming_bio_size: Optional[int]=None,
        ssl_outgoing_bio_size: Optional[int]=None,
        server=None,
        wait_connected: bool=True
) -> Tuple[asyncio.Transport, asyncio.BaseProtocol]:
    sock.setblocking(False)

    # The following big nested if-else should set transport, protocol, and
    # optionally waiter variables
    waiter = None
    if _should_fallback_to_asyncio(loop):
        if ssl:
            protocol = protocol_factory()
            waiter = loop.create_future() if wait_connected else None
            sslcontext = None if isinstance(ssl, bool) else ssl

            ssl_transport = SSLTransport_Transport(
                loop, protocol, sslcontext,
                server_side,
                ssl_handshake_timeout,
                ssl_shutdown_timeout,
                ssl_incoming_bio_size,
                ssl_outgoing_bio_size,
                waiter=waiter,
                server_hostname=server_hostname
            )

            ssl_protocol_factory = ssl_transport.get_tls_protocol

            create_connection = _get_original_loop_method(loop, "create_connection")
            await create_connection(ssl_protocol_factory, None, None, sock=sock)

            transport = ssl_transport
        else:
            def wrapped_protocol_factory():
                user_protocol = protocol_factory()
                if aiofn_is_buffered_protocol(user_protocol):
                    return _WrappedBufferedProtocol(user_protocol)
                else:
                    return _WrappedProtocol(user_protocol)

            create_connection = _get_original_loop_method(loop, "create_connection")
            loop_transport, wrapped_protocol = await create_connection(
                wrapped_protocol_factory, None, None, sock=sock)

            # asyncio Transport needs _server in order to detach itself on disconnect
            if server is not None:
                loop_transport._server = server

            transport = wrapped_protocol._wrapped_transport
            protocol = wrapped_protocol._protocol
            wrapped_protocol._wrapped_transport = None
            if not wait_connected:
                transport = loop_transport
    else:
        protocol = protocol_factory()
        waiter = loop.create_future() if wait_connected else None
        if ssl:
            sslcontext = openssl_compat.create_transport_context(server_side, server_hostname) if isinstance(ssl, bool) else ssl
            if _ssl_needs_fallback_engine(sslcontext):
                transport = SSLTransport_Transport(
                    loop, protocol, sslcontext,
                    server_side,
                    ssl_handshake_timeout,
                    ssl_shutdown_timeout,
                    ssl_incoming_bio_size,
                    ssl_outgoing_bio_size,
                    waiter=waiter,
                    server_hostname=server_hostname,
                    server=server
                )
                SocketTransport(loop, sock, transport.get_tls_protocol())
            else:
                transport = SSLTransport_Socket(
                    loop, protocol, sslcontext,
                    server_side,
                    ssl_handshake_timeout,
                    ssl_shutdown_timeout,
                    ssl_incoming_bio_size,
                    ssl_outgoing_bio_size,
                    sock,
                    waiter=waiter,
                    server_hostname=server_hostname,
                    server=server
                )
        else:
            transport = SocketTransport(loop, sock, protocol,
                                        waiter=waiter, server=server)

    if waiter is not None:
        try:
            await waiter
        except:
            transport.close()
            # gh-109534: When an exception is raised by the SSLProtocol object the
            # exception set in this future can keep the protocol object alive and
            # cause a reference cycle.
            waiter = None
            raise

    return transport, protocol


def _check_ssl_socket(sock):
    if isinstance(sock, ssl.SSLSocket):
        raise TypeError("Socket cannot be of type SSLSocket")


async def _ensure_resolved(address, *,
                           family=0, type=socket.SOCK_STREAM,
                           proto=0, flags=0, loop):
    host, port = address[:2]
    info = _ipaddr_info(host, port, family, type, proto, *address[2:])
    if info is not None:
        # "host" is already a resolved IP.
        return [info]
    else:
        return await loop.getaddrinfo(host, port, family=family, type=type,
                                      proto=proto, flags=flags)


def _ipaddr_info(host, port, family, type, proto, flowinfo=0, scopeid=0):
    # Try to skip getaddrinfo if "host" is already an IP. Users might have
    # handled name resolution in their own code and pass in resolved IPs.
    if not hasattr(socket, 'inet_pton'):
        return

    if proto not in {0, socket.IPPROTO_TCP, socket.IPPROTO_UDP} or \
            host is None:
        return None

    if type == socket.SOCK_STREAM:
        proto = socket.IPPROTO_TCP
    elif type == socket.SOCK_DGRAM:
        proto = socket.IPPROTO_UDP
    else:
        return None

    if port is None:
        port = 0
    elif isinstance(port, bytes) and port == b'':
        port = 0
    elif isinstance(port, str) and port == '':
        port = 0
    else:
        # If port's a service name like "http", don't skip getaddrinfo.
        try:
            port = int(port)
        except (TypeError, ValueError):
            return None

    if family == socket.AF_UNSPEC:
        afs = [socket.AF_INET]
        if _HAS_IPv6:
            afs.append(socket.AF_INET6)
    else:
        afs = [family]

    if isinstance(host, bytes):
        host = host.decode('idna')
    if '%' in host:
        # Linux's inet_pton doesn't accept an IPv6 zone index after host,
        # like '::1%lo0'.
        return None

    for af in afs:
        try:
            socket.inet_pton(af, host)
            # The host has already been resolved.
            if _HAS_IPv6 and af == socket.AF_INET6:
                return af, type, proto, '', (host, port, flowinfo, scopeid)
            else:
                return af, type, proto, '', (host, port)
        except OSError:
            pass

    # "host" is not an IP address.
    return None


class Server(asyncio.AbstractServer):
    def __init__(self, loop, sockets, protocol_factory, ssl_context, backlog,
                 ssl_handshake_timeout, ssl_shutdown_timeout,
                 ssl_incoming_bio_size, ssl_outgoing_bio_size
                 ):
        self._loop = loop
        self._sockets = sockets
        # Weak references so we don't break Transport's ability to
        # detect abandoned transports
        self._clients = weakref.WeakSet()
        self._waiters = []
        self._protocol_factory = protocol_factory
        self._backlog = backlog
        self._ssl_context = ssl_context
        self._ssl_handshake_timeout = ssl_handshake_timeout
        self._ssl_shutdown_timeout = ssl_shutdown_timeout
        self._ssl_incoming_bio_size = ssl_incoming_bio_size
        self._ssl_outgoing_bio_size = ssl_outgoing_bio_size
        self._serving = False
        self._serving_forever_fut = None

    def __repr__(self):
        return f'<{self.__class__.__name__} sockets={self.sockets!r}>'

    def _attach(self, transport):
        assert self._sockets is not None
        self._clients.add(transport)

    def _detach(self, transport):
        self._clients.discard(transport)
        if len(self._clients) == 0 and self._sockets is None:
            self._wakeup()

    def _wakeup(self):
        waiters = self._waiters
        if waiters is None:
            return
        self._waiters = None
        for waiter in waiters:
            if not waiter.done():
                waiter.set_result(None)

    def _start_serving(self):
        if self._serving:
            return
        self._serving = True
        for sock in self._sockets:
            sock.listen(self._backlog)
            self._start_serving_one_listener(sock)

    def _start_serving_one_listener(self, listening_sock):
        self._loop.add_reader(listening_sock.fileno(), self._accept_connection, listening_sock)

    def _accept_connection(self, listening_sock):
        # This method is only called once for each event loop tick where the
        # listening socket has triggered an EVENT_READ. There may be multiple
        # connections waiting for an .accept() so it is called in a loop.
        # See https://bugs.python.org/issue27906 for more details.
        for _ in range(self._backlog + 1):
            try:
                conn, addr = listening_sock.accept()
                if self._loop.get_debug():
                    _logger.debug("%r got a new connection from %r: %r", self, addr, conn)
                conn.setblocking(False)
            except ConnectionAbortedError:
                # Discard connections that were aborted before accept().
                continue
            except (BlockingIOError, InterruptedError):
                # Early exit because of a signal or
                # the socket accept buffer is empty.
                return
            except OSError as exc:
                # There's nowhere to send the error, so just log it.
                if exc.errno in (errno.EMFILE, errno.ENFILE, errno.ENOBUFS, errno.ENOMEM):
                    # Some platforms (e.g. Linux keep reporting the FD as
                    # ready, so we remove the read handler temporarily.
                    # We'll try again in a while.
                    self._loop.call_exception_handler(
                        {
                            "message": "socket.accept() out of system resource",
                            "exception": exc,
                            "socket": TransportSocket(listening_sock),
                        }
                    )
                    listening_sock.remove_reader(listening_sock.fileno())
                    self._loop.call_later(constants.ACCEPT_RETRY_DELAY, self._start_serving_one_listener, listening_sock)
                else:
                    raise  # The event loop will catch, log and ignore it.
            else:
                asyncio.create_task(self._accept_connection2(conn))

    async def _accept_connection2(self, sock):
        # By the time _accept_connection2 is called, server can be already closed
        # In such case we just close socket and return
        if self._sockets is None:
            sock.close()
            return

        try:
            transport, _ = await _create_connection_transport(
                self._loop,
                sock,
                self._protocol_factory,
                self._ssl_context,
                server_hostname=None,
                server_side=True,
                ssl_handshake_timeout=self._ssl_handshake_timeout,
                ssl_shutdown_timeout=self._ssl_shutdown_timeout,
                ssl_incoming_bio_size=self._ssl_incoming_bio_size,
                ssl_outgoing_bio_size=self._ssl_outgoing_bio_size,
                server=self,
                wait_connected=False,
            )
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            sock.close()
            if self._loop.get_debug():
                context = {
                    "message": "Error on transport creation for incoming connection",
                    "exception": exc,
                }
                self._loop.call_exception_handler(context)

            return

        # After await _create_connection_transport the server can be already closed
        # Abort transport and return then.
        if self._sockets is None:
            transport.abort()
            return

        self._attach(transport)

    def get_loop(self):
        return self._loop

    def is_serving(self):
        return self._serving

    @property
    def sockets(self):
        if self._sockets is None:
            return ()
        return tuple(asyncio.trsock.TransportSocket(s) for s in self._sockets)

    def close(self):
        sockets = self._sockets
        if sockets is None:
            return
        self._sockets = None

        for sock in sockets:
            self._loop.remove_reader(sock.fileno())
            sock.close()

        self._serving = False

        if (self._serving_forever_fut is not None and
                not self._serving_forever_fut.done()):
            self._serving_forever_fut.cancel()
            self._serving_forever_fut = None

        if len(self._clients) == 0:
            self._wakeup()

    def close_clients(self):
        for transport in self._clients.copy():
            transport.close()

    def abort_clients(self):
        for transport in self._clients.copy():
            transport.abort()

    async def start_serving(self):
        self._start_serving()
        # Skip one loop iteration so that all 'loop.add_reader'
        # go through.
        await asyncio.sleep(0)

    async def serve_forever(self):
        if self._serving_forever_fut is not None:
            raise RuntimeError(
                f'server {self!r} is already being awaited on serve_forever()')
        if self._sockets is None:
            raise RuntimeError(f'server {self!r} is closed')

        self._start_serving()
        self._serving_forever_fut = self._loop.create_future()

        try:
            await self._serving_forever_fut
        except asyncio.CancelledError:
            try:
                self.close()
                await self.wait_closed()
            finally:
                raise
        finally:
            self._serving_forever_fut = None

    async def wait_closed(self):
        """Wait until server is closed and all connections are dropped.

        - If the server is not closed, wait.
        - If it is closed, but there are still active connections, wait.

        Anyone waiting here will be unblocked once both conditions
        (server is closed and all connections have been dropped)
        have become true, in either order.

        Historical note: In 3.11 and before, this was broken, returning
        immediately if the server was already closed, even if there
        were still active connections. An attempted fix in 3.12.0 was
        still broken, returning immediately if the server was still
        open and there were no active connections. Hopefully in 3.12.1
        we have it right.
        """
        # Waiters are unblocked by self._wakeup(), which is called
        # from two places: self.close() and self._detach(), but only
        # when both conditions have become true. To signal that this
        # has happened, self._wakeup() sets self._waiters to None.
        if self._waiters is None:
            return
        waiter = self._loop.create_future()
        self._waiters.append(waiter)
        await waiter
        

def _stop_serving(loop, sock):
    loop.remove_reader(sock.fileno())
    sock.close()
