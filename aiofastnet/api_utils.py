import asyncio
import socket
import ssl
from logging import getLogger
from typing import Callable, Union, Optional, Tuple

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

            ssl_protocol_factory = lambda: ssl_transport.get_tls_protocol()

            create_connection = _get_original_loop_method(loop, "create_connection")
            loop_transport, ssl_protocol = await create_connection(
                ssl_protocol_factory, None, None, sock=sock)
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
