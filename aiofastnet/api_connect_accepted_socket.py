# Portions of this file are derived from CPython's asyncio sources
# (notably asyncio.base_events and asyncio.selector_events).
# Copyright (c) Python Software Foundation.
# Licensed under the Python Software Foundation License Version 2.
# See LICENSES/PSF-2.0.txt and THIRD_PARTY_NOTICES for details.

import socket

from .api_utils import _check_non_ssl_socket, _create_connection_transport, _logger, _validate_bio_size, _validate_ssl_timeout


async def connect_accepted_socket(
    loop,
    protocol_factory,
    sock,
    *,
    ssl=None,
    ssl_handshake_timeout=None,
    ssl_shutdown_timeout=None,
    ssl_incoming_bio_size=None,
    ssl_outgoing_bio_size=None,
):
    if sock.type != socket.SOCK_STREAM:
        raise ValueError(f"A Stream Socket was expected, got {sock!r}")

    ssl_handshake_timeout = _validate_ssl_timeout("ssl_handshake_timeout", ssl_handshake_timeout, ssl)
    ssl_shutdown_timeout = _validate_ssl_timeout("ssl_shutdown_timeout", ssl_shutdown_timeout, ssl)
    ssl_incoming_bio_size = _validate_bio_size("ssl_incoming_bio_size", ssl_incoming_bio_size, ssl)
    ssl_outgoing_bio_size = _validate_bio_size("ssl_outgoing_bio_size", ssl_outgoing_bio_size, ssl)

    _check_non_ssl_socket(sock)

    transport, protocol = await _create_connection_transport(
        loop, sock, protocol_factory, ssl, "",
        server_side=True,
        ssl_handshake_timeout=ssl_handshake_timeout,
        ssl_shutdown_timeout=ssl_shutdown_timeout,
        ssl_incoming_bio_size=ssl_incoming_bio_size,
        ssl_outgoing_bio_size=ssl_outgoing_bio_size,
    )
    if loop.get_debug():
        # Get the socket from the transport because SSL transport closes
        # the old socket and creates a new SSL socket
        sock = transport.get_extra_info("socket")
        _logger.debug("%r handled: (%r, %r)", sock, transport, protocol)
    return transport, protocol
