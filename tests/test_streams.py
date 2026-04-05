import asyncio
from contextlib import asynccontextmanager

import pytest
from async_timeout import timeout

from aiofastnet import start_server, open_connection
from tests.utils import EchoServerHandle, conn_type, _logger, loop_debug


@asynccontextmanager
async def StreamEchoServer(host="127.0.0.1", port=0, ssl_context=None):
    loop = asyncio.get_running_loop()

    async def client_connection_cb(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        _logger.debug("SERVER: client connected")
        while True:
            data = await reader.read(1024)
            _logger.debug("SERVER: client got %d bytes", len(data))
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
        server.abort_clients()
        server.close()
        await server.wait_closed()


@pytest.mark.parametrize("msg_size", [1, 64, 256 * 1024, 6 * 1024 * 1024])
async def test_streams_echo(msg_size, conn_type):
    payload = b"x" * msg_size

    loop = asyncio.get_running_loop()
    async with StreamEchoServer(ssl_context=conn_type.server_ssl_context) as server:
        async with timeout(2.0):
            reader, writer = await open_connection(loop, host=server.host, port=server.port, ssl=conn_type.client_ssl_context)
            writer.write(payload)
            reply = await reader.readexactly(msg_size)
            assert payload == reply
            writer.close()
            await writer.wait_closed()


