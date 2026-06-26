# Portions of this file are derived from CPython's asyncio sources
# (notably asyncio.base_events and asyncio.selector_events).
# Copyright (c) Python Software Foundation.
# Licensed under the Python Software Foundation License Version 2.
# See LICENSES/PSF-2.0.txt and THIRD_PARTY_NOTICES for details.

import os
import socket


from .api_utils import _create_connection_transport, _validate_ssl_timeout, _validate_bio_size


async def create_unix_connection(
        loop, protocol_factory, path=None, *,
        ssl=None, sock=None,
        server_hostname=None,
        ssl_handshake_timeout=None,
        ssl_shutdown_timeout=None,
        ssl_incoming_bio_size=None,
        ssl_outgoing_bio_size=None,
):
    if os.name == 'nt':
        raise NotImplementedError()

    assert server_hostname is None or isinstance(server_hostname, str)
    if ssl:
        if server_hostname is None:
            raise ValueError(
                'you have to pass server_hostname when using ssl')
    else:
        if server_hostname is not None:
            raise ValueError('server_hostname is only meaningful with ssl')

    ssl_handshake_timeout = _validate_ssl_timeout("ssl_handshake_timeout", ssl_handshake_timeout, ssl)
    ssl_shutdown_timeout = _validate_ssl_timeout("ssl_shutdown_timeout", ssl_shutdown_timeout, ssl)
    ssl_incoming_bio_size = _validate_bio_size("ssl_incoming_bio_size", ssl_incoming_bio_size, ssl)
    ssl_outgoing_bio_size = _validate_bio_size("ssl_outgoing_bio_size", ssl_outgoing_bio_size, ssl)

    if path is not None:
        if sock is not None:
            raise ValueError(
                'path and sock can not be specified at the same time')

        path = os.fspath(path)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0)
        try:
            sock.setblocking(False)
            await loop.sock_connect(sock, path)
        except:
            sock.close()
            raise

    else:
        if sock is None:
            raise ValueError('no path and sock were specified')
        if (sock.family != socket.AF_UNIX or
                sock.type != socket.SOCK_STREAM):
            raise ValueError(
                f'A UNIX Domain Stream Socket was expected, got {sock!r}')
        sock.setblocking(False)

    transport, protocol = await _create_connection_transport(
        loop, sock, protocol_factory, ssl, server_hostname,
        ssl_handshake_timeout=ssl_handshake_timeout,
        ssl_shutdown_timeout=ssl_shutdown_timeout,
        ssl_incoming_bio_size=ssl_incoming_bio_size,
        ssl_outgoing_bio_size=ssl_outgoing_bio_size,
    )
    return transport, protocol
