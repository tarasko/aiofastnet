import asyncio
import socket

import pytest
from aiofastnet import create_connection, create_server

from tests.utils import echo_client, echo_server, make_test_connection_types, \
    multiloop_event_loop_policy, make_test_ssl_contexts, ConnectionType

event_loop_policy = multiloop_event_loop_policy()

@pytest.fixture
async def loop_debug():
    asyncio.get_running_loop().set_debug(True)


@pytest.fixture(params=["tcp", "ssl"])
def conn_type(request):
    if request.param == "tcp":
        return ConnectionType(name="tcp")
    else:
        server_context, client_context = make_test_ssl_contexts("tests/test.crt", "tests/test.key")
        return ConnectionType(
            name="ssl",
            server_ssl_context=server_context,
            client_ssl_context=client_context,
        )

@pytest.fixture(params=["simple", "buffered"])
def buffered_protocol(request):
    return request.param == "buffered"


@pytest.mark.parametrize("msg_size", [1, 2, 3, 4, 5, 6, 7, 8, 29, 64, 256 * 1024, 6 * 1024 * 1024])
async def test_echo(msg_size, conn_type, buffered_protocol):
    payload = b"x" * msg_size

    async with echo_server(ssl_context=conn_type.server_ssl_context, is_buffered=buffered_protocol) as server:
        async with echo_client(server, ssl_context=conn_type.client_ssl_context, is_buffered=buffered_protocol) as client:
            client.write(payload)
            echoed = await client.readn(msg_size)
            assert echoed == payload


@pytest.mark.parametrize("msg_size", [1, 32, 64, 256 * 1024, 6 * 1024 * 1024, 40 * 1024 * 1024])
@pytest.mark.parametrize("num_lines", [1, 32, 4000])
async def test_echo_writelines(msg_size, num_lines, conn_type, buffered_protocol):
    payload = b"x" * msg_size

    async with echo_server(ssl_context=conn_type.server_ssl_context, is_buffered=buffered_protocol) as server:
        async with echo_client(server, ssl_context=conn_type.client_ssl_context, is_buffered=buffered_protocol) as client:
            client.write_in_lines(payload, num_lines)
            echoed = await client.readn(msg_size)
            assert echoed == payload


class _SinkServerProtocol(asyncio.Protocol):
    def data_received(self, data):
        pass


class _FlowControlClientProtocol(asyncio.Protocol):
    def __init__(self, connected: asyncio.Future, closed: asyncio.Future, paused: asyncio.Future, resumed: asyncio.Future):
        self.transport = None
        self._connected = connected
        self._closed = closed
        self._paused = paused
        self._resumed = resumed
        self.pause_calls = 0
        self.resume_calls = 0

    def connection_made(self, transport):
        self.transport = transport
        sock = transport.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 * 1024)
        self.transport.set_write_buffer_limits(high=16 * 1024, low=8 * 1024)
        if not self._connected.done():
            self._connected.set_result(None)

    def pause_writing(self):
        self.pause_calls += 1
        if not self._paused.done():
            self._paused.set_result(None)

    def resume_writing(self):
        self.resume_calls += 1
        if not self._resumed.done():
            self._resumed.set_result(None)

    def connection_lost(self, exc):
        if exc and not self._closed.done():
            self._closed.set_exception(exc)
        elif not self._closed.done():
            self._closed.set_result(None)


async def test_client_flow_control_callbacks(conn_type):
    loop = asyncio.get_running_loop()
    server = await create_server(
        loop,
        _SinkServerProtocol,
        host="127.0.0.1",
        port=0,
        ssl=conn_type.server_ssl_context,
    )

    connected = loop.create_future()
    closed = loop.create_future()
    paused = loop.create_future()
    resumed = loop.create_future()

    transport = None
    try:
        port = server.sockets[0].getsockname()[1]
        transport, protocol = await create_connection(
            loop,
            lambda: _FlowControlClientProtocol(connected, closed, paused, resumed),
            host="127.0.0.1",
            port=port,
            ssl=conn_type.client_ssl_context,
        )
        await asyncio.wait_for(connected, timeout=5.0)

        chunk = b"x" * (64 * 1024)
        for _ in range(1024):
            transport.write(chunk)
            if paused.done():
                break
        await asyncio.wait_for(paused, timeout=5.0)

        await asyncio.wait_for(resumed, timeout=5.0)

        assert protocol.pause_calls >= 1
        assert protocol.resume_calls >= 1
    finally:
        if transport is not None:
            transport.close()
            try:
                await asyncio.wait_for(asyncio.shield(closed), timeout=1.0)
            except TimeoutError:
                transport.abort()
                await asyncio.shield(closed)
        server.close()
        await server.wait_closed()
