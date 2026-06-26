import asyncio
import socket
from contextlib import asynccontextmanager
import os
import tempfile

import pytest
from async_timeout import timeout

from aiofastnet import (
    open_connection,
    start_server,
)

if hasattr(socket, 'AF_UNIX'):
    from aiofastnet import (
        open_unix_connection,
        start_unix_server,
    )

from tests.utils import EchoServerHandle, _logger


@asynccontextmanager
async def StreamEchoServer(host="127.0.0.1", port=0, ssl_context=None):
    loop = asyncio.get_running_loop()

    async def client_connection_cb(reader: asyncio.StreamReader,
                                   writer: asyncio.StreamWriter):
        _logger.debug("SERVER: connected")
        while True:
            data = await reader.read(1024)
            _logger.debug("SERVER: got %d bytes", len(data))
            if not data:
                break
            writer.write(data)

        writer.close()
        await writer.wait_closed()
        _logger.debug("SERVER: client connection closed")

    server = await start_server(
        loop,
        client_connection_cb,
        host=host,
        port=port,
        ssl=ssl_context,
    )

    try:
        resolved_port = server.sockets[0].getsockname()[1]
        yield EchoServerHandle(server=server, port=resolved_port, host=host,
                               clients=None, client_waiters=None)
    finally:
        if hasattr(server, "abort_clients"):
            server.abort_clients()
        server.close()
        await server.wait_closed()


@asynccontextmanager
async def UnixStreamEchoServer():
    loop = asyncio.get_running_loop()

    async def client_connection_cb(reader: asyncio.StreamReader,
                                   writer: asyncio.StreamWriter):
        _logger.debug("SERVER: connected")
        while True:
            data = await reader.read(1024)
            _logger.debug("SERVER: got %d bytes", len(data))
            if not data:
                break
            writer.write(data)

        writer.close()
        await writer.wait_closed()
        _logger.debug("SERVER: client connection closed")

    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, "aiofastnet.sock")
        server = await start_unix_server(
            loop, client_connection_cb, path=path)
        try:
            yield path
        finally:
            if hasattr(server, "abort_clients"):
                server.abort_clients()
            server.close()
            await server.wait_closed()


@pytest.mark.parametrize("msg_size", [1, 64, 256 * 1024, 6 * 1024 * 1024])
async def test_streams_echo(msg_size, conn_type):
    payload = b"x" * msg_size

    loop = asyncio.get_running_loop()
    async with StreamEchoServer(
            ssl_context=conn_type.server_ssl_context) as server:
        async with timeout(4.0):
            reader, writer = await open_connection(
                loop, host=server.host, port=server.port,
                ssl=conn_type.client_ssl_context)
            writer.write(payload)
            reply = await reader.readexactly(msg_size)
            assert payload == reply
            writer.close()
            await writer.wait_closed()


@pytest.mark.skipif(os.name == "nt",
                    reason="Unix sockets are not supported on Windows")
@pytest.mark.parametrize("msg_size", [1, 64, 256 * 1024, 6 * 1024 * 1024])
async def test_unix_streams_echo(msg_size):
    payload = b"x" * msg_size

    loop = asyncio.get_running_loop()
    async with UnixStreamEchoServer() as path:
        async with timeout(4.0):
            reader, writer = await open_unix_connection(loop, path=path)
            writer.write(payload)
            reply = await reader.readexactly(msg_size)
            assert payload == reply
            writer.close()
            await writer.wait_closed()
