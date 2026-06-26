import asyncio
import errno
import os
import socket
import stat

from .api_utils import _start_serving, Server, _logger, _validate_ssl_timeout, _validate_bio_size


async def create_unix_server(
        self, protocol_factory, path=None, *,
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

    ssl_handshake_timeout = _validate_ssl_timeout("ssl_handshake_timeout", ssl_handshake_timeout, ssl)
    ssl_shutdown_timeout = _validate_ssl_timeout("ssl_shutdown_timeout", ssl_shutdown_timeout, ssl)
    ssl_incoming_bio_size = _validate_bio_size("ssl_incoming_bio_size", ssl_incoming_bio_size, ssl)
    ssl_outgoing_bio_size = _validate_bio_size("ssl_outgoing_bio_size", ssl_outgoing_bio_size, ssl)

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
        except:
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

    if cleanup_socket:
        path = sock.getsockname()
        # Check for abstract socket. `str` and `bytes` paths are supported.
        if path[0] not in (0, '\x00'):
            try:
                self._unix_server_sockets[sock] = os.stat(path).st_ino
            except FileNotFoundError:
                pass

    sock.setblocking(False)
    server = Server(self, [sock], protocol_factory,
                    ssl, backlog, ssl_handshake_timeout,
                    ssl_shutdown_timeout,
                    ssl_incoming_bio_size,
                    ssl_outgoing_bio_size)
    if start_serving:
        _start_serving()
        # Skip one loop iteration so that all 'loop.add_reader'
        # go through.
        await asyncio.sleep(0)

    return server
