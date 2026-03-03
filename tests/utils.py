import asyncio
from contextlib import asynccontextmanager
from dataclasses import dataclass
import importlib
import os
from pathlib import Path
import ssl
import sys

import pytest
from aiofastnet import create_connection, create_server

def multiloop_event_loop_policy():
    """
    Returns a pytest fixture function named `event_loop_policy` (by assignment in the test module).

    Usage in a test module:
        from tests.utils import make_event_loop_policy_fixture
        event_loop_policy = make_event_loop_policy_fixture()

    Notes:
    - On Windows, uvloop isn't used (by default) and we return the appropriate asyncio policy.
    - On non-Windows, params are ("asyncio", "uvloop")
    """
    # Decide params at factory creation time (import-time for that module)
    uvloop = None
    winloop = None
    if os.name == "nt":
        # Winloop doesn't work with python 3.9
        if sys.version_info >= (3, 10):
            params = ("asyncio", "winloop")
        else:
            params = ("asyncio", )
        winloop = importlib.import_module("winloop")
    else:
        params = ("asyncio", "uvloop")
        uvloop = importlib.import_module("uvloop")

    @pytest.fixture(params=params)
    def event_loop_policy(request):
        name = request.param

        if name == "asyncio":
            if os.name == "nt":
                if sys.version_info >= (3, 10):
                    return asyncio.DefaultEventLoopPolicy()
                else:
                    return asyncio.WindowsSelectorEventLoopPolicy()
            else:
                return asyncio.DefaultEventLoopPolicy()
        elif name == "uvloop":
            return uvloop.EventLoopPolicy()
        elif name == "winloop":
            return winloop.EventLoopPolicy()
        else:
            raise AssertionError(f"unknown loop: {name!r}")

    return event_loop_policy


class EchoServerProtocol(asyncio.Protocol):
    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        self.transport.write(data)


class _ReadNClientProtocol(asyncio.Protocol):
    def __init__(self, closed: asyncio.Future):
        self._closed = closed
        self._transport = None
        self._buffer = bytearray()
        self._waiters = []

    def connection_made(self, transport):
        self._transport = transport
        self._drain_waiters()

    def data_received(self, data):
        self._buffer.extend(data)
        self._drain_waiters()

    def connection_lost(self, exc):
        if exc and not self._closed.done():
            self._closed.set_exception(exc)
        elif not self._closed.done():
            self._closed.set_result(None)
        self._drain_waiters()

    def write(self, data: bytes):
        if self._transport is None:
            raise RuntimeError("connection is not established")
        self._transport.write(data)

    async def readn(self, n: int) -> bytes:
        if n < 0:
            raise ValueError("n must be >= 0")
        if n == 0:
            return b""

        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self._waiters.append((n, fut))
        self._drain_waiters()
        return await fut

    def close(self):
        if self._transport is not None:
            self._transport.close()

    def _drain_waiters(self):
        if not self._waiters:
            return

        alive = []
        for n, fut in self._waiters:
            if fut.done():
                continue

            if len(self._buffer) >= n:
                data = bytes(self._buffer[:n])
                del self._buffer[:n]
                fut.set_result(data)
                continue

            if self._closed.done():
                fut.set_exception(ConnectionError("connection closed before enough bytes were received"))
                continue

            alive.append((n, fut))

        self._waiters = alive


class EchoClient:
    def __init__(self, transport: asyncio.BaseTransport, protocol: _ReadNClientProtocol):
        self._transport = transport
        self._protocol = protocol

    def write(self, data: bytes):
        self._protocol.write(data)

    async def readn(self, n: int) -> bytes:
        return await self._protocol.readn(n)

    def close(self):
        self._protocol.close()

    def abort(self):
        self._transport.abort()


@dataclass(frozen=True)
class EchoServerHandle:
    server: asyncio.Server
    port: int
    host: str = "127.0.0.1"


@dataclass(frozen=True)
class ConnectionType:
    name: str
    server_ssl_context: ssl.SSLContext | None = None
    client_ssl_context: ssl.SSLContext | None = None


@asynccontextmanager
async def echo_server(host="127.0.0.1", port=0, ssl_context=None):
    loop = asyncio.get_running_loop()
    server = await create_server(
        loop,
        EchoServerProtocol,
        host=host,
        port=port,
        ssl=ssl_context,
    )
    try:
        resolved_port = server.sockets[0].getsockname()[1]
        yield EchoServerHandle(server=server, port=resolved_port, host=host)
    finally:
        server.close()
        await server.wait_closed()


@asynccontextmanager
async def echo_client(server_or_host, port=None, ssl_context=None, server_hostname=None):
    if isinstance(server_or_host, EchoServerHandle):
        host = server_or_host.host
        port = server_or_host.port
    else:
        host = server_or_host
        if port is None:
            raise ValueError("port must be provided when host is passed directly")

    loop = asyncio.get_running_loop()
    closed = loop.create_future()
    transport, protocol = await create_connection(
        loop,
        lambda: _ReadNClientProtocol(closed),
        host=host,
        port=port,
        ssl=ssl_context,
        server_hostname=server_hostname,
    )
    client = EchoClient(transport, protocol)
    try:
        yield client
    finally:
        client.close()
        try:
            await asyncio.wait_for(asyncio.shield(closed), timeout=1.0)
        except TimeoutError:
            # SSL close_notify can hang in edge cases (for example no payload).
            client.abort()
            await asyncio.shield(closed)


def make_test_ssl_contexts(cert_file: str | Path, key_file: str | Path):
    cert_file = str(cert_file)
    key_file = str(key_file)

    server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_context.load_cert_chain(certfile=cert_file, keyfile=key_file)

    client_context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    client_context.check_hostname = False
    client_context.verify_mode = ssl.CERT_NONE
    return server_context, client_context


def make_test_connection_types(cert_file: str | Path, key_file: str | Path):
    server_context, client_context = make_test_ssl_contexts(cert_file, key_file)
    return (
        ConnectionType(name="tcp"),
        ConnectionType(
            name="ssl",
            server_ssl_context=server_context,
            client_ssl_context=client_context,
        ),
    )
