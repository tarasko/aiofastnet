# Portions of this file are derived from CPython's asyncio sources
# (notably asyncio.base_events and asyncio.selector_events).
# Copyright (c) Python Software Foundation.
# Licensed under the Python Software Foundation License Version 2.
# See LICENSES/PSF-2.0.txt and THIRD_PARTY_NOTICES for details.

import collections
import errno
import itertools
import os
import socket
import asyncio
import sys
import weakref

from . import constants
from .api_utils import _is_asyncio_loop, _create_connection_transport, \
    _check_ssl_socket, _logger, _HAS_IPv6, _ensure_resolved
from .ssl_protocol import SSLProtocol
from .transport import (aiofn_is_buffered_protocol)
from .wrapped_transport import (
    _WrappedProtocol, _WrappedBufferedProtocol,
    _should_fallback_to_asyncio
)

from asyncio.trsock import TransportSocket


async def create_server(
        loop: asyncio.AbstractEventLoop,
        protocol_factory, host=None, port=None,
        *,
        family=socket.AF_UNSPEC,
        flags=socket.AI_PASSIVE,
        sock=None,
        backlog=100,
        ssl=None,
        reuse_address=None,
        reuse_port=None,
        keep_alive=None,
        ssl_handshake_timeout=None,
        ssl_shutdown_timeout=None,
        ssl_incoming_bio_size=None,
        ssl_outgoing_bio_size=None,
        start_serving=True):
    """Create a TCP server.

    The host parameter can be a string, in that case the TCP server is
    bound to host and port.

    The host parameter can also be a sequence of strings and in that case
    the TCP server is bound to all hosts of the sequence. If a host
    appears multiple times (possibly indirectly e.g. when hostnames
    resolve to the same IP address), the server is only bound once to that
    host.

    Return a Server object which can be used to stop the service.

    This method is a coroutine.
    """
    if isinstance(ssl, bool):
        raise TypeError('ssl argument must be an SSLContext or None')

    if ssl_handshake_timeout is not None and ssl is None:
        raise ValueError(
            'ssl_handshake_timeout is only meaningful with ssl')

    if ssl_shutdown_timeout is not None and ssl is None:
        raise ValueError(
            'ssl_shutdown_timeout is only meaningful with ssl')

    if _should_fallback_to_asyncio(loop):
        kwargs = {
            'host': host,
            'port': port,
            'family': family,
            'flags': flags,
            'sock': sock,
            'backlog': backlog,
            'reuse_address': reuse_address,
            'reuse_port': reuse_port,
            'start_serving': start_serving
        }
        if sys.version_info >= (3, 13) and _is_asyncio_loop(loop):
            kwargs['keep_alive'] = keep_alive

        return await _create_server_fallback(
            loop, protocol_factory, ssl,
            ssl_handshake_timeout, ssl_shutdown_timeout, **kwargs)

    if sock is not None:
        _check_ssl_socket(sock)

    if host is not None or port is not None:
        if sock is not None:
            raise ValueError(
                'host/port and sock can not be specified at the same time')

        if reuse_address is None:
            reuse_address = os.name == "posix" and sys.platform != "cygwin"
        sockets = []
        if host == '':
            hosts = [None]
        elif (isinstance(host, str) or
              not isinstance(host, collections.abc.Iterable)):
            hosts = [host]
        else:
            hosts = host

        fs = [_create_server_getaddrinfo(loop, host, port, family=family, flags=flags)
              for host in hosts]
        infos = await asyncio.gather(*fs)
        infos = set(itertools.chain.from_iterable(infos))

        completed = False
        try:
            for res in infos:
                af, socktype, proto, canonname, sa = res
                try:
                    sock = socket.socket(af, socktype, proto)
                except socket.error:
                    # Assume it's a bad family/type/protocol combination.
                    if loop.get_debug():
                        _logger.warning('create_server() failed to create '
                                        'socket.socket(%r, %r, %r)',
                                        af, socktype, proto, exc_info=True)
                    continue
                sockets.append(sock)
                if reuse_address:
                    sock.setsockopt(
                        socket.SOL_SOCKET, socket.SO_REUSEADDR, True)
                # Since Linux 6.12.9, SO_REUSEPORT is not allowed
                # on other address families than AF_INET/AF_INET6.
                if reuse_port and af in (socket.AF_INET, socket.AF_INET6):
                    _set_reuseport(sock)
                if keep_alive:
                    sock.setsockopt(
                        socket.SOL_SOCKET, socket.SO_KEEPALIVE, True)
                # Disable IPv4/IPv6 dual stack support (enabled by
                # default on Linux) which makes a single socket
                # listen on both address families.
                if (_HAS_IPv6 and
                        af == socket.AF_INET6 and
                        hasattr(socket, 'IPPROTO_IPV6')):
                    sock.setsockopt(socket.IPPROTO_IPV6,
                                    socket.IPV6_V6ONLY,
                                    True)
                try:
                    sock.bind(sa)
                except OSError as err:
                    msg = ('error while attempting '
                           'to bind on address %r: %s'
                           % (sa, str(err).lower()))
                    if err.errno == errno.EADDRNOTAVAIL:
                        # Assume the family is not enabled (bpo-30945)
                        sockets.pop()
                        sock.close()
                        if loop.get_debug():
                            _logger.warning(msg)
                        continue
                    raise OSError(err.errno, msg) from None

            if not sockets:
                raise OSError('could not bind on any address out of %r'
                              % ([info[4] for info in infos],))

            completed = True
        finally:
            if not completed:
                for sock in sockets:
                    sock.close()
    else:
        if sock is None:
            raise ValueError('Neither host/port nor sock were specified')
        if sock.type != socket.SOCK_STREAM:
            raise ValueError(f'A Stream Socket was expected, got {sock!r}')
        sockets = [sock]

    for sock in sockets:
        sock.setblocking(False)

    server = Server(
        loop, sockets, protocol_factory,
        ssl, backlog,
        ssl_handshake_timeout,
        ssl_shutdown_timeout,
        ssl_incoming_bio_size,
        ssl_outgoing_bio_size
    )
    if start_serving:
        server._start_serving()
        # Skip one loop iteration so that all 'loop.add_reader'
        # go through.
        await asyncio.sleep(0)

    if loop.get_debug():
        _logger.info("%r is serving", server)
    return server


class Server(asyncio.AbstractServer):
    def __init__(self, loop, sockets, protocol_factory, ssl_context, backlog,
                 ssl_handshake_timeout, ssl_shutdown_timeout,
                 ssl_incoming_bio_size, ssl_outgoing_bio_size):
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
            _start_serving(
                self._loop,
                self._protocol_factory, sock, self._ssl_context,
                self, self._backlog,
                self._ssl_handshake_timeout,
                self._ssl_shutdown_timeout,
                self._ssl_incoming_bio_size,
                self._ssl_outgoing_bio_size)

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
            _stop_serving(self._loop, sock)

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


async def _create_server_fallback(loop,
                                  protocol_factory,
                                  ssl,
                                  ssl_handshake_timeout,
                                  ssl_shutdown_timeout,
                                  **kwargs
):
    if ssl:
        sslcontext = None if isinstance(ssl, bool) else ssl

        def ssl_protocol_factory():
            protocol = protocol_factory()
            return SSLProtocol(
                loop, protocol, sslcontext,
                server_side=True,
                ssl_handshake_timeout=ssl_handshake_timeout,
                ssl_shutdown_timeout=ssl_shutdown_timeout
            )

        return await loop.create_server(ssl_protocol_factory, **kwargs)
    else:
        def wrapped_protocol_factory():
            user_protocol = protocol_factory()
            if aiofn_is_buffered_protocol(user_protocol):
                return _WrappedBufferedProtocol(user_protocol)
            else:
                return _WrappedProtocol(user_protocol)

        return await loop.create_server(wrapped_protocol_factory, **kwargs)


def _accept_connection(
        loop, protocol_factory, sock,
        sslcontext, server,
        backlog,
        ssl_handshake_timeout,
        ssl_shutdown_timeout,
        ssl_incoming_bio_size,
        ssl_outgoing_bio_size,
):
    # This method is only called once for each event loop tick where the
    # listening socket has triggered an EVENT_READ. There may be multiple
    # connections waiting for an .accept() so it is called in a loop.
    # See https://bugs.python.org/issue27906 for more details.
    for _ in range(backlog + 1):
        try:
            conn, addr = sock.accept()
            if loop.get_debug():
                _logger.debug("%r got a new connection from %r: %r",
                              server, addr, conn)
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
            if exc.errno in (errno.EMFILE, errno.ENFILE,
                             errno.ENOBUFS, errno.ENOMEM):
                # Some platforms (e.g. Linux keep reporting the FD as
                # ready, so we remove the read handler temporarily.
                # We'll try again in a while.
                loop.call_exception_handler({
                    'message': 'socket.accept() out of system resource',
                    'exception': exc,
                    'socket': TransportSocket(sock),
                })
                loop.remove_reader(sock.fileno())
                loop.call_later(constants.ACCEPT_RETRY_DELAY,
                                _start_serving,
                                loop, protocol_factory, sock, sslcontext, server,
                                backlog,
                                ssl_handshake_timeout,
                                ssl_shutdown_timeout,
                                ssl_incoming_bio_size,
                                ssl_outgoing_bio_size,
                                )
            else:
                raise  # The event loop will catch, log and ignore it.
        else:
            accept = _accept_connection2(
                loop, protocol_factory, conn, sslcontext, server,
                ssl_handshake_timeout, ssl_shutdown_timeout,
                ssl_incoming_bio_size, ssl_outgoing_bio_size)
            asyncio.create_task(accept)


async def _accept_connection2(
        loop,
        protocol_factory,
        sock,
        sslcontext, server,
        ssl_handshake_timeout,
        ssl_shutdown_timeout,
        ssl_incoming_bio_size,
        ssl_outgoing_bio_size):
    protocol = None
    transport = None
    try:
        transport, protocol = await _create_connection_transport(
            loop, sock, protocol_factory, sslcontext,
            server_hostname=None, server_side=True,
            ssl_handshake_timeout=ssl_handshake_timeout,
            ssl_shutdown_timeout=ssl_shutdown_timeout,
            ssl_incoming_bio_size=ssl_incoming_bio_size,
            ssl_outgoing_bio_size=ssl_outgoing_bio_size,
            server=server
        )
    except (SystemExit, KeyboardInterrupt):
        raise
    except BaseException as exc:
        if loop.get_debug():
            context = {
                'message':
                    'Error on transport creation for incoming connection',
                'exception': exc,
            }
            if protocol is not None:
                context['protocol'] = protocol
            if transport is not None:
                context['transport'] = transport
            loop.call_exception_handler(context)


def _start_serving(loop, protocol_factory, sock,
                   sslcontext, server, backlog,
                   ssl_handshake_timeout,
                   ssl_shutdown_timeout,
                   ssl_incoming_bio_size,
                   ssl_outgoing_bio_size
                   ):
    loop.add_reader(sock.fileno(), _accept_connection, loop,
                    protocol_factory, sock, sslcontext, server, backlog,
                    ssl_handshake_timeout, ssl_shutdown_timeout,
                    ssl_incoming_bio_size, ssl_outgoing_bio_size)


def _set_reuseport(sock):
    if not hasattr(socket, 'SO_REUSEPORT'):
        raise ValueError('reuse_port not supported by socket module')
    else:
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except OSError:
            raise ValueError('reuse_port not supported by socket module, '
                             'SO_REUSEPORT defined but not implemented.')


async def _create_server_getaddrinfo(loop, host, port, family, flags):
    infos = await _ensure_resolved((host, port), family=family,
                                   type=socket.SOCK_STREAM,
                                   flags=flags, loop=loop)
    if not infos:
        raise OSError(f'getaddrinfo({host!r}) returned empty list')
    return infos


def _stop_serving(loop, sock):
    loop.remove_reader(sock.fileno())
    sock.close()
