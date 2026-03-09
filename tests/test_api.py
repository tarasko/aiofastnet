from unittest.mock import AsyncMock

import pytest

import aiofastnet.api as api


@pytest.mark.asyncio
async def test_create_connection_falls_back_to_loop_create_connection_on_windows_proactor(monkeypatch):
    class FakeProactorEventLoop:
        def __init__(self):
            self.create_connection = AsyncMock(return_value=("transport", "protocol"))

    monkeypatch.setattr(api, "_IS_WINDOWS", True)
    monkeypatch.setattr(api.asyncio, "ProactorEventLoop", FakeProactorEventLoop, raising=False)

    loop = FakeProactorEventLoop()

    result = await api.create_connection(
        loop,
        lambda: object(),
        host="127.0.0.1",
        port=1234,
        ssl=None,
        happy_eyeballs_delay=0.25,
        interleave=1,
        all_errors=True,
    )

    assert result == ("transport", "protocol")
    loop.create_connection.assert_awaited_once()
    assert loop.create_connection.await_args.kwargs == {
        "host": "127.0.0.1",
        "port": 1234,
        "ssl": None,
        "family": 0,
        "proto": 0,
        "flags": 0,
        "sock": None,
        "local_addr": None,
        "server_hostname": None,
        "ssl_handshake_timeout": None,
        "ssl_shutdown_timeout": None,
        "happy_eyeballs_delay": 0.25,
        "interleave": 1,
        "all_errors": True,
    }


@pytest.mark.asyncio
async def test_create_server_falls_back_to_loop_create_server_on_windows_proactor(monkeypatch):
    class FakeProactorEventLoop:
        def __init__(self):
            self.create_server = AsyncMock(return_value="server")

    monkeypatch.setattr(api, "_IS_WINDOWS", True)
    monkeypatch.setattr(api.asyncio, "ProactorEventLoop", FakeProactorEventLoop, raising=False)

    loop = FakeProactorEventLoop()

    result = await api.create_server(
        loop,
        lambda: object(),
        host="127.0.0.1",
        port=4321,
        backlog=256,
        start_serving=False,
    )

    assert result == "server"
    loop.create_server.assert_awaited_once()
    assert loop.create_server.await_args.kwargs == {
        "host": "127.0.0.1",
        "port": 4321,
        "family": api.socket.AF_UNSPEC,
        "flags": api.socket.AI_PASSIVE,
        "sock": None,
        "backlog": 256,
        "ssl": None,
        "reuse_address": None,
        "reuse_port": None,
        "keep_alive": None,
        "ssl_handshake_timeout": None,
        "ssl_shutdown_timeout": None,
        "start_serving": False,
    }
