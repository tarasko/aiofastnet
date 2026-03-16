import asyncio
import ssl

from .ssl_protocol import SSLProtocol
from .wrapped_transport import _WrappedTransport


async def start_tls(loop: asyncio.AbstractEventLoop,
                    transport, protocol, sslcontext, *,
                    server_side=False,
                    server_hostname=None,
                    ssl_handshake_timeout=None,
                    ssl_shutdown_timeout=None) -> asyncio.Transport:
    """Upgrade transport to TLS.

    Return new transport that *protocol* should start using
    immediately.
    """
    if isinstance(transport, _WrappedTransport):
        transport = transport._transport

    if ssl is None:
        raise RuntimeError('Python ssl module is not available')

    if not isinstance(sslcontext, ssl.SSLContext):
        raise TypeError(
            f'sslcontext is expected to be an instance of ssl.SSLContext, '
            f'got {sslcontext!r}')

    waiter = loop.create_future()
    ssl_protocol = SSLProtocol(
        loop, protocol, sslcontext, waiter,
        server_side, server_hostname,
        call_connection_made=False,
        ssl_handshake_timeout=ssl_handshake_timeout,
        ssl_shutdown_timeout=ssl_shutdown_timeout,
        )

    # Pause early so that "ssl_protocol.data_received()" doesn't
    # have a chance to get called before "ssl_protocol.connection_made()".
    transport.pause_reading()

    transport.set_protocol(ssl_protocol)
    conmade_cb = loop.call_soon(ssl_protocol.connection_made, transport)
    resume_cb = loop.call_soon(transport.resume_reading)

    try:
        await waiter
    except BaseException:
        transport.close()
        conmade_cb.cancel()
        resume_cb.cancel()
        raise

    return ssl_protocol.get_app_transport()
