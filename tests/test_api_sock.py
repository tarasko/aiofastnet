import asyncio
import os
import socket
import tempfile
from contextlib import asynccontextmanager

import pytest

import aiofastnet


@asynccontextmanager
async def TcpSocketPair():
    loop = asyncio.get_running_loop()
    listener = socket.socket()
    server = None
    client = socket.socket()
    listener.setblocking(False)
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    client.setblocking(False)
    try:
        accept_result, _ = await asyncio.gather(
            aiofastnet.sock_accept(loop, listener),
            aiofastnet.sock_connect(loop, client, ("localhost", listener.getsockname()[1])),
        )
        server, _address = accept_result
        listener.close()
        yield server, client
    finally:
        client.close()
        listener.close()
        if server is not None:
            server.close()


@asynccontextmanager
async def UdpSocketPair():
    with tempfile.TemporaryDirectory(prefix="aiofn-", dir="/tmp") as tmpdir:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        server.setblocking(False)
        client.setblocking(False)
        server.bind(os.path.join(tmpdir, "server.sock"))
        client.bind(os.path.join(tmpdir, "client.sock"))
        try:
            yield server, client
        finally:
            server.close()
            client.close()


async def test_sock_connect_accept_sendall_recv(all_loops):
    loop = asyncio.get_running_loop()
    async with TcpSocketPair() as (server, client):
        client.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
        payload = b"data" * (256 * 1024)

        async def receive_all():
            received = bytearray()
            while len(received) < len(payload):
                received.extend(await aiofastnet.sock_recv(loop, server, 64 * 1024))
            return received

        _, received = await asyncio.gather(
            aiofastnet.sock_sendall(loop, client, payload),
            receive_all(),
        )
        assert received == payload

        buffer = bytearray(16)
        server.send(b"into")
        count = await aiofastnet.sock_recv_into(loop, client, buffer)
        assert buffer[:count] == b"into"


async def test_sock_sendto_recvfrom(all_loops):
    loop = asyncio.get_running_loop()
    async with UdpSocketPair() as (server, client):
        sent = await aiofastnet.sock_sendto(loop, client, b"first", server.getsockname())
        assert sent == 5
        data, address = await aiofastnet.sock_recvfrom(loop, server, 64)
        assert data == b"first"
        assert address == client.getsockname()

        await aiofastnet.sock_sendto(loop, client, b"second", server.getsockname())
        buffer = bytearray(64)
        (count, address) = await aiofastnet.sock_recvfrom_into(loop, server, buffer)
        assert buffer[:count] == b"second"
        assert address == client.getsockname()


async def test_sock_recv_cancellation_does_not_consume_later_data(selector_loop):
    loop = asyncio.get_running_loop()
    async with TcpSocketPair() as (server, client):
        task = asyncio.create_task(aiofastnet.sock_recv(loop, server, 1))
        await asyncio.sleep(0)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

        client.send(b"x")
        assert await asyncio.wait_for(aiofastnet.sock_recv(loop, server, 1), 1) == b"x"


async def test_patch_loop_patches_sock_methods(all_loops):
    loop = aiofastnet.patch_loop(asyncio.get_running_loop())
    async with TcpSocketPair() as (server, client):
        await loop.sock_sendall(client, b"patched")
        assert await loop.sock_recv(server, 64) == b"patched"
