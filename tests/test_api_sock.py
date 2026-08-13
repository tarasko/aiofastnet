import asyncio
import os
import socket
import sys
import tempfile
from contextlib import asynccontextmanager

import pytest

import aiofastnet
from aiofastnet.api_sock import _wrap_sock_ready_handler


async def test_wrap_sock_ready_handler_skips_done_future(selector_loop):
    future = asyncio.get_running_loop().create_future()
    future.set_result("already done")

    def handler():
        raise AssertionError("handler must not be called")

    assert _wrap_sock_ready_handler(future, handler) is None
    assert future.result() == "already done"


async def test_wrap_sock_ready_handler_allows_handler_to_complete_future(selector_loop):
    future = asyncio.get_running_loop().create_future()

    def handler():
        future.set_result("done")

    assert _wrap_sock_ready_handler(future, handler) is None
    assert future.result() == "done"


@pytest.mark.parametrize("exc_type", [BlockingIOError, InterruptedError])
async def test_wrap_sock_ready_handler_ignores_retryable_error(selector_loop, exc_type):
    future = asyncio.get_running_loop().create_future()

    def handler():
        raise exc_type()

    assert _wrap_sock_ready_handler(future, handler) is None
    assert not future.done()


@pytest.mark.parametrize("exc", [OSError("socket error"), asyncio.CancelledError()])
async def test_wrap_sock_ready_handler_sets_exception(selector_loop, exc):
    future = asyncio.get_running_loop().create_future()

    def handler():
        raise exc

    assert _wrap_sock_ready_handler(future, handler) is None
    assert future.done()
    assert future.exception() is exc


async def test_wrap_sock_ready_handler_rejects_error_after_completion(selector_loop):
    future = asyncio.get_running_loop().create_future()

    def handler():
        future.set_result("done")
        raise OSError("late error")

    with pytest.raises(AssertionError):
        _wrap_sock_ready_handler(future, handler)
    assert future.result() == "done"


async def test_sock_connect_refused(selector_loop):
    # Test socket becoming write-ready but with SO_ERROR set to error.

    loop = asyncio.get_running_loop()
    unavailable_server = socket.socket()
    unavailable_server.bind(("127.0.0.1", 0))
    client = socket.socket()
    client.setblocking(False)
    try:
        # On macos SO_ERROR reports ETIMEDOUT
        with pytest.raises((ConnectionRefusedError, TimeoutError)):
            await aiofastnet.sock_connect(loop, client, unavailable_server.getsockname())
    finally:
        client.close()
        unavailable_server.close()


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
    if hasattr(socket, "AF_UNIX"):
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
    else:
        if sys.version_info < (3, 11):
            pytest.skip("Datagram sock_ methods are missing in asyncio loop on windows prior to 3.11")

        server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        server.setblocking(False)
        client.setblocking(False)
        server.bind(("127.0.0.1", 0))
        client.bind(("127.0.0.1", 0))
        try:
            yield server, client
        finally:
            server.close()
            client.close()


@pytest.mark.parametrize("buffered_read", [False, True], ids=["simple", "buffered"])
async def test_sock_connect_accept_sendall_recv(all_loops, buffered_read):
    loop = asyncio.get_running_loop()

    async def recv(sock):
        if buffered_read:
            ba = bytearray(64*1024)
            count = await aiofastnet.sock_recv_into(loop, sock, ba)
            return bytes(memoryview(ba)[:count])
        else:
            return await aiofastnet.sock_recv(loop, sock, 64*1024)

    async with TcpSocketPair() as (server, client):
        client.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
        payload_1 = b"b" * (64 * 1024)
        payload_2 = b"c" * (64 * 1024)
        payload_3 = b"a"
        total_len = len(payload_1) + len(payload_2) + len(payload_3)

        async def sendall():
            await aiofastnet.sock_sendall(loop, client, payload_1)
            await aiofastnet.sock_sendall(loop, client, payload_2)
            await aiofastnet.sock_sendall(loop, client, payload_3)

        async def receive_all():
            data = bytearray()
            while len(data) < total_len:
                data.extend(await recv(server))
            return data

        _, received = await asyncio.gather(
            sendall(),
            receive_all(),
        )
        assert received == payload_1 + payload_2 + payload_3


@pytest.mark.parametrize("buffered_read", [False, True], ids=["simple", "buffered"])
async def test_sock_sendto_recvfrom(all_loops, buffered_read):
    loop = asyncio.get_running_loop()
    
    async def readfrom(sock):
        if buffered_read:
            ba = bytearray(64*1024)
            count, address = await aiofastnet.sock_recvfrom_into(loop, sock, ba)
            return bytes(memoryview(ba)[:count]), address
        else:
            count, address = await aiofastnet.sock_recvfrom(loop, sock, 64*1024)
            return count, address

    async with UdpSocketPair() as (server, client):
        client.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)

        sent = await aiofastnet.sock_sendto(loop, client, b"first", server.getsockname())
        assert sent == 5
        data, address = await readfrom(server)
        assert data == b"first"
        assert address == client.getsockname()

        # Defer sending, cause EAGAIN on reading
        send_task = loop.create_task(aiofastnet.sock_sendto(loop, client, b"second", server.getsockname()))
        data, address = await readfrom(server)
        assert data == b"second"
        assert address == client.getsockname()
        await send_task

        # Cause EAGAIN from sendto,
        # works reliably only on linux with AF_UNIX, SOCK_DGRAM
        # other systems just report success and drop data
        if sys.platform == "linux":
            payload = b"x" * (4 * 1024)

            async def sendto():
                await aiofastnet.sock_sendto(loop, client, payload, server.getsockname())
                await aiofastnet.sock_sendto(loop, client, payload, server.getsockname())

            # Tasks are not eager so sendto will start only after readfrom could not complete immediately
            send_task = loop.create_task(sendto())
            data, _ = await readfrom(server)
            assert data == payload
            data, _ = await readfrom(server)
            assert data == payload
            await send_task


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
