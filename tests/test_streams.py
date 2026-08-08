import asyncio
import os
import socket

import pytest
from async_timeout import timeout

from aiofastnet import (
    open_connection,
)

if hasattr(socket, 'AF_UNIX'):
    from aiofastnet import (
        open_unix_connection,
    )

from tests.utils import StreamEchoServer, UnixStreamEchoServer


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
