import asyncio
import socket

import pytest

import aiofastnet


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


@pytest.mark.parametrize("patch_loop", [False, True])
async def test_create_datagram_endpoint_echo(all_loops, patch_loop):
    loop = asyncio.get_running_loop()
    server_transport, _ = await _create_datagram_endpoint(
        loop,
        patch_loop,
        EchoDatagramProtocol,
        local_addr=("127.0.0.1", 0),
        family=socket.AF_INET,
    )
    server_addr = server_transport.get_extra_info("sockname")

    client = ClientDatagramProtocol()
    client_transport, _ = await _create_datagram_endpoint(
        loop,
        patch_loop,
        lambda: client,
        remote_addr=server_addr,
        family=socket.AF_INET,
    )

    try:
        client_transport.sendto(b"hello")
        data, _ = await asyncio.wait_for(client.received, 2.0)
        assert data == b"hello"
    finally:
        client_transport.close()
        server_transport.close()
        await asyncio.sleep(0)


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
