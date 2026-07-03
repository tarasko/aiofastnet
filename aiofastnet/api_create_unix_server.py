# Portions of this file are derived from CPython's asyncio sources
# (notably asyncio.base_events and asyncio.selector_events).
# Copyright (c) Python Software Foundation.
# Licensed under the Python Software Foundation License Version 2.
# See LICENSES/PSF-2.0.txt and THIRD_PARTY_NOTICES for details.

import asyncio
import errno
import os
import socket
import stat

from .api_utils import (
    Server, _logger, _validate_ssl_timeout, _validate_bio_size
)


class UnixServer(Server):
    def __init__(self, *args, cleanup_path=None, cleanup_inode=None, **kwargs):
        super().__init__(*args, **kwargs)
        self._cleanup_path = cleanup_path
        self._cleanup_inode = cleanup_inode

    def close(self):
        cleanup_path = self._cleanup_path
        cleanup_inode = self._cleanup_inode
        self._cleanup_path = None
        self._cleanup_inode = None

        super().close()

        if cleanup_path is None:
            return

        try:
            st = os.stat(cleanup_path)
        except FileNotFoundError:
            return
        if stat.S_ISSOCK(st.st_mode) and st.st_ino == cleanup_inode:
            os.remove(cleanup_path)


async def create_unix_server(
        loop, protocol_factory, path=None, *,
        sock=None, backlog=100, ssl=None,
        ssl_handshake_timeout=None,
        ssl_shutdown_timeout=None,
        ssl_incoming_bio_size=None,
        ssl_outgoing_bio_size=None,
        start_serving=True, cleanup_socket=True):
    if os.name == 'nt':
        raise NotImplementedError()

    if isinstance(ssl, bool):
        raise TypeError('ssl argument must be an SSLContext or None')

    ssl_handshake_timeout = _validate_ssl_timeout(
        "ssl_handshake_timeout", ssl_handshake_timeout, ssl)
    ssl_shutdown_timeout = _validate_ssl_timeout(
        "ssl_shutdown_timeout", ssl_shutdown_timeout, ssl)
    ssl_incoming_bio_size = _validate_bio_size(
        "ssl_incoming_bio_size", ssl_incoming_bio_size, ssl)
    ssl_outgoing_bio_size = _validate_bio_size(
        "ssl_outgoing_bio_size", ssl_outgoing_bio_size, ssl)

    if path is not None:
        if sock is not None:
            raise ValueError(
                'path and sock can not be specified at the same time')

        path = os.fspath(path)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

        # Check for abstract socket. `str` and `bytes` paths are supported.
        if path[0] not in (0, '\x00'):
            try:
                if stat.S_ISSOCK(os.stat(path).st_mode):
                    os.remove(path)
            except FileNotFoundError:
                pass
            except OSError as err:
                # Directory may have permissions only to create socket.
                _logger.error('Unable to check or remove stale UNIX socket '
                              '%r: %r', path, err)

        try:
            sock.bind(path)
        except OSError as exc:
            sock.close()
            if exc.errno == errno.EADDRINUSE:
                # Let's improve the error message by adding
                # with what exact address it occurs.
                msg = f'Address {path!r} is already in use'
                raise OSError(errno.EADDRINUSE, msg) from None
            else:
                raise
        except BaseException:
            sock.close()
            raise
    else:
        if sock is None:
            raise ValueError(
                'path was not specified, and no sock specified')

        if (sock.family != socket.AF_UNIX or
                sock.type != socket.SOCK_STREAM):
            raise ValueError(
                f'A UNIX Domain Stream Socket was expected, got {sock!r}')

    cleanup_path = None
    cleanup_inode = None
    if cleanup_socket:
        sockname = sock.getsockname()
        # Check for abstract socket. `str` and `bytes` paths are supported.
        if sockname[0] not in (0, '\x00'):
            try:
                cleanup_path = sockname
                cleanup_inode = os.stat(sockname).st_ino
            except FileNotFoundError:
                pass

    sock.setblocking(False)
    server = UnixServer(loop, [sock], protocol_factory,
                        ssl, backlog, ssl_handshake_timeout,
                        ssl_shutdown_timeout,
                        ssl_incoming_bio_size,
                        ssl_outgoing_bio_size,
                        cleanup_path=cleanup_path,
                        cleanup_inode=cleanup_inode)
    if start_serving:
        server._start_serving()
        # Skip one loop iteration so that all 'loop.add_reader'
        # go through.
        await asyncio.sleep(0)

    return server
