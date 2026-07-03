# Portions of this file are derived from CPython's asyncio sources
# (notably asyncio.base_events and asyncio.selector_events).
# Copyright (c) Python Software Foundation.
# Licensed under the Python Software Foundation License Version 2.
# See LICENSES/PSF-2.0.txt and THIRD_PARTY_NOTICES for details.

import asyncio
import ssl

from .ssl_transport import SSLTransport_Transport
from .api_utils import _validate_ssl_timeout, _validate_bio_size
from .wrapped_transport import _WrappedTransport


async def start_tls(loop: asyncio.AbstractEventLoop,
                    transport, protocol, sslcontext, *,
                    server_side=False,
                    server_hostname=None,
                    ssl_handshake_timeout=None,
                    ssl_shutdown_timeout=None,
                    ssl_incoming_bio_size=None,
                    ssl_outgoing_bio_size=None
                    ) -> asyncio.Transport:
    """Upgrade transport to TLS.

    Return new transport that *protocol* should start using
    immediately.
    """
    if isinstance(transport, _WrappedTransport):
        transport = transport._transport

    if not isinstance(sslcontext, ssl.SSLContext):
        raise TypeError(
            f'sslcontext is expected to be an instance of ssl.SSLContext, '
            f'got {sslcontext!r}')

    ssl_handshake_timeout = _validate_ssl_timeout("ssl_handshake_timeout", ssl_handshake_timeout, sslcontext)
    ssl_shutdown_timeout = _validate_ssl_timeout("ssl_shutdown_timeout", ssl_shutdown_timeout, sslcontext)
    ssl_incoming_bio_size = _validate_bio_size("ssl_incoming_bio_size", ssl_incoming_bio_size, ssl)
    ssl_outgoing_bio_size = _validate_bio_size("ssl_outgoing_bio_size", ssl_outgoing_bio_size, ssl)

    waiter = loop.create_future()
    ssl_transport = SSLTransport_Transport(
        loop, protocol, sslcontext,
        server_side,
        ssl_handshake_timeout,
        ssl_shutdown_timeout,
        ssl_incoming_bio_size,
        ssl_outgoing_bio_size,
        waiter=waiter,
        server_hostname=server_hostname,
        call_connection_made=False,
        )
    ssl_protocol = ssl_transport.get_tls_protocol()

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

    return ssl_transport
