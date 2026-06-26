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

from .api_utils import _is_asyncio_loop, _check_ssl_socket, _logger, _HAS_IPv6, _ensure_resolved, \
    _validate_ssl_timeout, _validate_bio_size, Server
from .ssl_transport import SSLTransport_Transport
from .transport import (aiofn_is_buffered_protocol)
from .wrapped_transport import (
    _WrappedProtocol, _WrappedBufferedProtocol,
    _should_fallback_to_asyncio, _get_original_loop_method
)


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

    ssl_handshake_timeout = _validate_ssl_timeout("ssl_handshake_timeout", ssl_handshake_timeout, ssl)
    ssl_shutdown_timeout = _validate_ssl_timeout("ssl_shutdown_timeout", ssl_shutdown_timeout, ssl)
    ssl_incoming_bio_size = _validate_bio_size("ssl_incoming_bio_size", ssl_incoming_bio_size, ssl)
    ssl_outgoing_bio_size = _validate_bio_size("ssl_outgoing_bio_size", ssl_outgoing_bio_size, ssl)

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
            ssl_handshake_timeout, ssl_shutdown_timeout,
            ssl_incoming_bio_size, ssl_outgoing_bio_size,
            **kwargs)

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
        ssl_outgoing_bio_size,
    )
    if start_serving:
        server._start_serving()
        # Skip one loop iteration so that all 'loop.add_reader'
        # go through.
        await asyncio.sleep(0)

    if loop.get_debug():
        _logger.info("%r is serving", server)
    return server


async def _create_server_fallback(loop,
                                  protocol_factory,
                                  ssl,
                                  ssl_handshake_timeout,
                                  ssl_shutdown_timeout,
                                  ssl_incoming_bio_size,
                                  ssl_outgoing_bio_size,
                                  **kwargs
):
    if ssl:
        sslcontext = None if isinstance(ssl, bool) else ssl

        def ssl_protocol_factory():
            protocol = protocol_factory()
            server_side = True
            tls_transport = SSLTransport_Transport(
                loop, protocol, sslcontext,
                server_side,
                ssl_handshake_timeout,
                ssl_shutdown_timeout,
                ssl_incoming_bio_size,
                ssl_outgoing_bio_size
            )
            return tls_transport.get_tls_protocol()

        create_server = _get_original_loop_method(loop, "create_server")
        return await create_server(ssl_protocol_factory, **kwargs)
    else:
        def wrapped_protocol_factory():
            user_protocol = protocol_factory()
            if aiofn_is_buffered_protocol(user_protocol):
                return _WrappedBufferedProtocol(user_protocol)
            else:
                return _WrappedProtocol(user_protocol)

        create_server = _get_original_loop_method(loop, "create_server")
        return await create_server(wrapped_protocol_factory, **kwargs)


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


