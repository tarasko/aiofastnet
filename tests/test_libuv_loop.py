import asyncio
import os
import socket

import pytest

from tests.utils import ConnectionType, TestServer

pytestmark = pytest.mark.skipif(os.name != "posix", reason="the libuv reference backend is Unix-only")


@pytest.fixture
def libuv_loop():
    from aiofastnet.libuv_loop import new_event_loop

    loop = new_event_loop()
    try:
        yield loop
    finally:
        loop.close()


def test_proactor_sock_connect_recv_sendall(libuv_loop):
    async def exchange():
        async with TestServer(ct=ConnectionType("tcp")) as server:
            client = socket.socket()
            client.setblocking(False)
            try:
                await libuv_loop.sock_connect(client, (server.host, server.port))
                for _ in range(1000):
                    await libuv_loop.sock_sendall(client, b"hello")
                    assert await libuv_loop.sock_recv(client, 5) == b"hello"
            finally:
                client.close()

    libuv_loop.run_until_complete(exchange())


def test_proactor_sock_recv_into(libuv_loop):
    async def receive_into():
        async with TestServer(ct=ConnectionType("tcp")) as server:
            client = socket.socket()
            client.setblocking(False)
            try:
                await libuv_loop.sock_connect(client, (server.host, server.port))
                await libuv_loop.sock_sendall(client, b"data!")
                buffer = bytearray(5)
                assert await libuv_loop.sock_recv_into(client, buffer) == 5
                assert buffer == b"data!"
            finally:
                client.close()

    libuv_loop.run_until_complete(receive_into())


def test_libuv_loop_is_standalone_extension_type(libuv_loop):
    assert not isinstance(libuv_loop, asyncio.BaseEventLoop)
    assert isinstance(libuv_loop, asyncio.AbstractEventLoop)
