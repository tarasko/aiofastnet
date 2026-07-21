import asyncio
import socket

import pytest

import aiofastnet
from tests.utils import (
    ConnectionType,
    TestClient,
    TestServer,
    UDP_MAX_PAYLOAD_SIZE,
)


async def _create_datagram_endpoint(loop, patch_loop, *args, **kwargs):
    if patch_loop:
        aiofastnet.patch_loop(loop)
        return await loop.create_datagram_endpoint(*args, **kwargs)
    return await aiofastnet.create_datagram_endpoint(loop, *args, **kwargs)


class EchoDatagramProtocol(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        self.transport.sendto(data, addr)


class ClientDatagramProtocol(asyncio.DatagramProtocol):
    def __init__(self):
        self.received = asyncio.get_running_loop().create_future()
        self.errors = []
        self.paused = False
        self.resumed = False

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if not self.received.done():
            self.received.set_result((data, addr))

    def error_received(self, exc):
        self.errors.append(exc)

    def pause_writing(self):
        self.paused = True

    def resume_writing(self):
        self.resumed = True


class RaiseOnceDatagramProtocol(asyncio.DatagramProtocol):
    def __init__(self, exc):
        self.transport = None
        self.exc = exc
        self._raised = False

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if not self._raised:
            self._raised = True
            raise self.exc
        self.transport.sendto(data, addr)


class RaisingErrorDatagramProtocol(ClientDatagramProtocol):
    def __init__(self, exc):
        super().__init__()
        self.exc = exc

    def error_received(self, exc):
        raise self.exc


@pytest.mark.parametrize("patch_loop", [False, True])
async def test_create_datagram_endpoint_echo(all_loops, patch_loop):
    loop = asyncio.get_running_loop()
    if patch_loop:
        aiofastnet.patch_loop(loop)

    async with TestServer(ct=ConnectionType("udp")) as server:
        async with TestClient(server, ct=ConnectionType("udp")) as client:
            client.write(b"hello")
            assert await client.readn(5) == b"hello"
            assert await server.get_any_server_client() is not None


async def test_datagram_rejects_different_address(all_loops):
    loop = asyncio.get_running_loop()
    server_transport, _ = await aiofastnet.create_datagram_endpoint(
        loop,
        EchoDatagramProtocol,
        local_addr=("127.0.0.1", 0),
        family=socket.AF_INET,
    )
    server_addr = server_transport.get_extra_info("sockname")

    client = ClientDatagramProtocol()
    client_transport, _ = await aiofastnet.create_datagram_endpoint(
        loop,
        lambda: client,
        remote_addr=server_addr,
        family=socket.AF_INET,
    )

    try:
        with pytest.raises(ValueError, match="Invalid address"):
            client_transport.sendto(
                b"hello",
                ("127.0.0.1", server_addr[1] + 1),
            )
    finally:
        client_transport.close()
        server_transport.close()
        await asyncio.sleep(0)


async def test_datagram_transport_is_not_eof_writable(all_loops):
    loop = asyncio.get_running_loop()
    transport, _ = await aiofastnet.create_datagram_endpoint(
        loop,
        EchoDatagramProtocol,
        local_addr=("127.0.0.1", 0),
        family=socket.AF_INET,
    )

    try:
        assert transport.can_write_eof() is False
        with pytest.raises(NotImplementedError):
            transport.write_eof()
    finally:
        transport.abort()
        await asyncio.sleep(0)


async def test_datagram_received_exception_does_not_close_transport(all_loops):
    loop = asyncio.get_running_loop()
    received_exception = loop.create_future()
    old_exception_handler = loop.get_exception_handler()

    def exception_handler(loop, context):
        if not received_exception.done():
            received_exception.set_result(context)

    loop.set_exception_handler(exception_handler)

    server_transport, _ = await aiofastnet.create_datagram_endpoint(
        loop,
        lambda: RaiseOnceDatagramProtocol(RuntimeError("datagram failed")),
        local_addr=("127.0.0.1", 0),
    )
    server_addr = server_transport.get_extra_info("sockname")
    client = ClientDatagramProtocol()
    client_transport, _ = await aiofastnet.create_datagram_endpoint(
        loop,
        lambda: client,
        remote_addr=server_addr,
    )

    try:
        client_transport.sendto(b"first")
        context = await asyncio.wait_for(received_exception, 1.0)
        assert isinstance(context["exception"], RuntimeError)
        assert context["message"] == (
            "Fatal error: protocol.datagram_received() call failed."
        )

        client_transport.sendto(b"second")
        data, _ = await asyncio.wait_for(client.received, 1.0)
        assert data == b"second"
    finally:
        loop.set_exception_handler(old_exception_handler)
        client_transport.close()
        server_transport.close()
        await asyncio.sleep(0)


async def test_error_received_exception_does_not_close_transport(all_loops):
    loop = asyncio.get_running_loop()
    received_exception = loop.create_future()
    old_exception_handler = loop.get_exception_handler()

    def exception_handler(loop, context):
        if not received_exception.done():
            received_exception.set_result(context)

    loop.set_exception_handler(exception_handler)

    server_transport, _ = await aiofastnet.create_datagram_endpoint(
        loop,
        EchoDatagramProtocol,
        local_addr=("127.0.0.1", 0),
    )
    server_addr = server_transport.get_extra_info("sockname")
    client = RaisingErrorDatagramProtocol(RuntimeError("error handler failed"))
    client_transport, _ = await aiofastnet.create_datagram_endpoint(
        loop,
        lambda: client,
        remote_addr=server_addr,
    )

    try:
        client_transport.sendto(b"x" * (UDP_MAX_PAYLOAD_SIZE + 1))
        context = await asyncio.wait_for(received_exception, 1.0)
        assert isinstance(context["exception"], RuntimeError)
        assert context["message"] == (
            "Fatal error: protocol.error_received() call failed."
        )

        client_transport.sendto(b"hello")
        data, _ = await asyncio.wait_for(client.received, 1.0)
        assert data == b"hello"
    finally:
        loop.set_exception_handler(old_exception_handler)
        client_transport.close()
        server_transport.close()
        await asyncio.sleep(0)
