import asyncio
import socket
import ssl
from logging import getLogger
from typing import Callable, Union, Optional, Tuple

from .ssl_protocol import SSLProtocol
from .transport import SocketTransport, aiofn_is_buffered_protocol
from .wrapped_transport import _should_fallback_to_asyncio, \
    _WrappedBufferedProtocol, _WrappedProtocol


_HAS_IPv6 = hasattr(socket, 'AF_INET6')
_logger = getLogger('aiofastnet')


def _is_asyncio_loop(loop: asyncio.AbstractEventLoop) -> bool:
    return type(loop).__module__.startswith("asyncio.")


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
        server=None
) -> Tuple[asyncio.Transport, asyncio.BaseProtocol]:
    sock.setblocking(False)

    # The following big nested if-else should set transport, protocol, and
    # optionally waiter variables
    waiter = None
    if _should_fallback_to_asyncio(loop):
        if ssl:
            protocol = protocol_factory()
            waiter = loop.create_future()
            sslcontext = None if isinstance(ssl, bool) else ssl

            ssl_protocol_factory = lambda: SSLProtocol(
                loop, protocol, sslcontext, waiter,
                server_side, server_hostname,
                ssl_handshake_timeout=ssl_handshake_timeout,
                ssl_shutdown_timeout=ssl_shutdown_timeout,
                ssl_incoming_bio_size=ssl_incoming_bio_size,
                ssl_outgoing_bio_size=ssl_outgoing_bio_size
            )
            loop_transport, ssl_protocol = await loop.create_connection(
                ssl_protocol_factory, None, None, sock=sock)
            transport = ssl_protocol.get_app_transport()
        else:
            def wrapped_protocol_factory():
                user_protocol = protocol_factory()
                if aiofn_is_buffered_protocol(user_protocol):
                    return _WrappedBufferedProtocol(user_protocol)
                else:
                    return _WrappedProtocol(user_protocol)

            loop_transport, wrapped_protocol = await loop.create_connection(
                wrapped_protocol_factory, None, None, sock=sock)
            transport = wrapped_protocol._wrapped_transport
            protocol = wrapped_protocol._protocol
            wrapped_protocol._wrapped_transport = None

        # Ugly but I don't know how else to attach conventional transport
        # to my Server object
        if server is not None:
            loop_transport._server = server
            server._attach(loop_transport)
    else:
        protocol = protocol_factory()
        waiter = loop.create_future()
        if ssl:
            sslcontext = None if isinstance(ssl, bool) else ssl

            ssl_protocol = SSLProtocol(
                loop, protocol, sslcontext, waiter,
                server_side, server_hostname,
                ssl_handshake_timeout=ssl_handshake_timeout,
                ssl_shutdown_timeout=ssl_shutdown_timeout
            )
            SocketTransport(loop, sock, ssl_protocol, server=server)
            transport = ssl_protocol.get_app_transport()
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
