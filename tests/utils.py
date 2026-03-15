import asyncio
import socket
import weakref
from collections import deque
from contextlib import asynccontextmanager, contextmanager
from dataclasses import dataclass
import importlib
import os
from logging import getLogger
from pathlib import Path
import ssl
import sys
from typing import Tuple, Optional, Union, Any, List

import async_timeout
import pytest
from aiofastnet import create_connection, create_server, \
    Transport as aiofn_Transport, start_tls

_logger = getLogger("tests.utils")


class TestException(Exception):
    pass


def _set_socket_sndbuf(transport: asyncio.Transport, size: int) -> int:
    sock = transport.get_extra_info('socket')
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, max(1, size // 2))
    return sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)


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
            params = ("asyncio_sel", "asyncio_pro", "winloop")
        else:
            params = ("asyncio_sel", "asyncio_pro",)
        winloop = importlib.import_module("winloop")
    else:
        params = ("asyncio", "uvloop")
        uvloop = importlib.import_module("uvloop")

    @pytest.fixture(params=params)
    def event_loop_policy(request):
        name = request.param

        if name == "asyncio":
            return asyncio.DefaultEventLoopPolicy()
        elif name == "asyncio_sel":
            return asyncio.WindowsSelectorEventLoopPolicy()
        elif name == "asyncio_pro":
            return asyncio.WindowsProactorEventLoopPolicy()
        elif name == "uvloop":
            return uvloop.EventLoopPolicy()
        elif name == "winloop":
            return winloop.EventLoopPolicy()
        else:
            raise AssertionError(f"unknown loop: {name!r}")

    return event_loop_policy


class EchoServerProtocol(asyncio.Protocol, asyncio.BufferedProtocol):
    def __init__(self, clients: set, client_waiters: List[Any], is_buffered: bool):
        self.transport = None
        self._clients = clients
        self._client_waiters = client_waiters
        self._is_buffered = is_buffered
        self._read_buffer = bytearray(b"X") * (128*1024)

    def is_buffered_protocol(self):
        return self._is_buffered

    def connection_made(self, transport):
        _logger.debug("EchoServer.connection_made")
        self._clients.add(weakref.ref(self))
        self.transport = transport
        ssl_protocol = self.transport.get_extra_info('ssl_protocol')
        if ssl_protocol is not None and hasattr(ssl_protocol, '_allow_renegotiation'):
            ssl_protocol._allow_renegotiation()
        for w in self._client_waiters:
            if not w.done():
                w.set_result(None)
        self._client_waiters.clear()

    def connection_lost(self, exc):
        _logger.debug("EchoServer.connection_lost")
        self._clients.remove(weakref.ref(self))

    def get_buffer(self, hint):
        return memoryview(self._read_buffer)

    def buffer_updated(self, bytes_read):
        _logger.debug("EchoServer.buffer_updated: received=%d", bytes_read)
        self.transport.write(self._read_buffer[:bytes_read])

    def data_received(self, data):
        _logger.debug("EchoServer.data_received: %d", len(data))
        self.transport.write(data)

    def pause_writing(self):
        _logger.debug("EchoServer.pause_writing")

    def resume_writing(self):
        _logger.debug("EchoServer.resume_writing")

    def eof_received(self):
        _logger.debug("EchoServer.eof_received")


class AsyncClient(asyncio.Protocol, asyncio.BufferedProtocol):
    def __init__(self, is_buffered: bool):
        self.transport = None
        self._ssl_layer = 0
        self._is_buffered = is_buffered
        self._closed = asyncio.get_running_loop().create_future()
        self._read_buffer = bytearray(b"X") * (256*1024)
        self._data = bytearray()
        self._readn_waiter: Optional[Tuple[int, asyncio.Future]] = None
        self._is_writing_paused = False
        self._write_resumed_fut = None
        self._new_data_ev = asyncio.Event()
        self._is_eof_received = False

    @property
    def is_writing_paused(self):
        return self._is_writing_paused

    @property
    def is_eof_received(self):
        return self._is_eof_received

    def is_buffered_protocol(self):
        return self._is_buffered

    def connection_made(self, transport):
        _logger.debug("AsyncClient.connection_made")
        self.transport = transport
        effective_sndbuf = _set_socket_sndbuf(transport, 128*1024)
        _logger.debug("AsyncClient SNDBUF set: %s", effective_sndbuf)
        ssl_protocol = self.transport.get_extra_info('ssl_protocol')
        if ssl_protocol is not None and hasattr(ssl_protocol, '_allow_renegotiation'):
            ssl_protocol._allow_renegotiation()

    def data_received(self, data):
        if isinstance(self.transport, aiofn_Transport):
            assert not self._is_buffered
        self._data.extend(data)
        _logger.debug("AsyncClient.data_received: received=%d, total=%d", len(data), len(self._data))
        self._wakeup_waiters()
        self._new_data_ev.set()
        self._new_data_ev.clear()

    def get_buffer(self, hint):
        return memoryview(self._read_buffer)

    def buffer_updated(self, bytes_read):
        if isinstance(self.transport, aiofn_Transport):
            assert self._is_buffered
        self._data += self._read_buffer[:bytes_read]
        _logger.debug("AsyncClient.buffer_updated: received=%d, total=%d", bytes_read, len(self._data))
        self._wakeup_waiters()
        self._new_data_ev.set()
        self._new_data_ev.clear()

    def pause_writing(self):
        _logger.debug("AsyncClient.pause_writing")
        self._is_writing_paused = True
        self._write_resumed_fut = asyncio.get_running_loop().create_future()

    def resume_writing(self):
        _logger.debug("AsyncClient.resume_writing")
        self._is_writing_paused = False
        if self._write_resumed_fut is not None:
            self._write_resumed_fut.set_result(None)
            self._write_resumed_fut = None

    def eof_received(self):
        self._is_eof_received = True
        _logger.debug("AsyncClient.eof_received")

    def connection_lost(self, exc):
        _logger.debug("AsyncClient.connection_lost")
        if not self._closed.done():
            if exc is not None:
                self._closed.set_exception(exc)
            else:
                self._closed.set_result(None)
        if self._readn_waiter is not None:
            self._readn_waiter[1].set_exception(RuntimeError("connection closed"))
            self._readn_waiter = None
        if self._write_resumed_fut is not None:
            self._write_resumed_fut.set_exception(RuntimeError("connection closed"))
            self._write_resumed_fut = None

    def write(self, data: bytes):
        _logger.debug("AsyncClient.write(len=%d)", len(data))
        self.transport.write(data)

    def write_in_lines(self, data: bytes, num_lines: int):
        parts = []
        part_sz = int(len(data) / num_lines)
        for i in range(num_lines - 1):
            parts.append(data[part_sz*i : part_sz*(i + 1)])
        already_added = sum(len(part) for part in parts)
        parts.append(data[already_added:])
        lens = [f"len={len(p)}" for p in parts]
        _logger.debug("AsyncClient.writelines(%s)", lens)
        self.transport.writelines(parts)

    async def readn(self, n: int, timeout=1.0) -> bytes:
        assert self._readn_waiter is None

        if n < 0:
            raise ValueError("n must be >= 0")
        if n == 0:
            return b""

        if len(self._data) >= n:
            res = self._data[:n]
            self._data = self._data[n:]
            return res

        self._readn_waiter = (n, asyncio.get_running_loop().create_future())
        if timeout is None:
            return await asyncio.shield(self._readn_waiter[1])
        else:
            async with async_timeout.timeout(timeout):
                return await asyncio.shield(self._readn_waiter[1])

    def close(self):
        self.transport.close()

    def abort(self):
        self.transport.abort()

    async def wait_closed(self, timeout=1.0):
        async with async_timeout.timeout(timeout):
            await asyncio.shield(self._closed)

    async def wait_write_resumed(self, timeout=1.0):
        if self._write_resumed_fut is None:
            return

        async with async_timeout.timeout(timeout):
            return await asyncio.shield(self._write_resumed_fut)

    async def wait_new_data(self, timeout=1.0):
        async with async_timeout.timeout(timeout):
            return await asyncio.shield(self._new_data_ev.wait())

    async def start_tls(self, ssl_context):
        self.transport = await start_tls(
            asyncio.get_running_loop(),
            self.transport,
            self,
            ssl_context,
            server_side=False, server_hostname="127.0.0.1"
        )
        _logger.debug("Client start_tls #%d completed", self._ssl_layer)
        self._ssl_layer += 1

    def _wakeup_waiters(self):
        if self._readn_waiter is None:
            return

        if len(self._data) < self._readn_waiter[0]:
            return

        n, fut = self._readn_waiter
        fut.set_result(self._data[:n])
        self._data = self._data[n:]
        self._readn_waiter = None


@dataclass(frozen=True)
class EchoServerHandle:
    server: asyncio.Server
    clients: set[Any]
    client_waiters: List[Any]
    port: int
    host: str = "127.0.0.1"

    async def get_any_server_client(self, timeout=1.0) -> EchoServerProtocol:
        if self.clients:
            return next(iter(self.clients))()

        fut = asyncio.get_running_loop().create_future()
        self.client_waiters.append(fut)
        # No need to shield, because it is only awaiter and if
        # it is canceled so be it, we don't need this future anymore anyway.
        try:
            async with async_timeout.timeout(timeout):
                await fut
        finally:
            try:
                self.client_waiters.remove(fut)
            except:
                pass

        return next(iter(self.clients))()

@dataclass(frozen=True)
class ConnectionType:
    name: str
    server_ssl_context: Optional[ssl.SSLContext] = None
    client_ssl_context: Optional[ssl.SSLContext] = None


@asynccontextmanager
async def TestServer(protocol_factory=None, host="127.0.0.1", port=0, ssl_context=None, is_buffered=False):
    loop = asyncio.get_running_loop()
    clients = set()
    client_waiters = []
    if protocol_factory is None:
        protocol_factory = lambda: EchoServerProtocol(clients, client_waiters, is_buffered)
    server = await create_server(
        loop,
        protocol_factory,
        host=host,
        port=port,
        ssl=ssl_context,
    )
    try:
        resolved_port = server.sockets[0].getsockname()[1]
        yield EchoServerHandle(server=server, port=resolved_port, host=host, clients=clients, client_waiters=client_waiters)
    finally:
        server.close()
        for w in client_waiters:
            if not w.done():
                w.set_exception(RuntimeError("server finished"))
        client_waiters.clear()
        await server.wait_closed()


@asynccontextmanager
async def TestClient(server_or_host, port=None, ssl_context=None, server_hostname=None, is_buffered=False, protocol_factory=AsyncClient):
    if isinstance(server_or_host, EchoServerHandle):
        host = server_or_host.host
        port = server_or_host.port
    else:
        host = server_or_host
        if port is None:
            raise ValueError("port must be provided when host is passed directly")

    loop = asyncio.get_running_loop()
    transport, client = await create_connection(
        loop,
        lambda: protocol_factory(is_buffered),
        host=host,
        port=port,
        ssl=ssl_context,
        server_hostname=server_hostname,
    )
    try:
        yield client
    finally:
        transport.abort()
        try:
            await client.wait_closed(1.0)
        except (TestException, ConnectionResetError, BrokenPipeError):
            pass

def make_test_ssl_contexts(cert_file: Union[str, Path], key_file: Union[str, Path]):
    cert_file = str(cert_file)
    key_file = str(key_file)

    server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_context.load_cert_chain(certfile=cert_file, keyfile=key_file)

    client_context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    client_context.check_hostname = False
    client_context.verify_mode = ssl.CERT_NONE
    return server_context, client_context


@contextmanager
def exc_queue():
    loop = asyncio.get_running_loop()
    old_handler = loop.get_exception_handler()
    exc_queue = []
    def new_handler(loop, context):
        nonlocal exc_queue
        exc_queue.append(context)
    loop.set_exception_handler(new_handler)
    try:
        yield exc_queue
    finally:
        exc_queue.clear()
        loop.set_exception_handler(old_handler)
