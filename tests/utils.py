import asyncio
from contextlib import asynccontextmanager
from dataclasses import dataclass
import importlib
import os
from logging import getLogger
from pathlib import Path
import ssl
import sys
from typing import Tuple, Optional, Union

import async_timeout
import pytest
from aiofastnet import create_connection, create_server

_logger = getLogger("tests.utils")

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


class EchoServerProtocol(asyncio.Protocol):
    def __init__(self, is_buffered: bool):
        self._is_buffered = is_buffered
        self._read_buffer = bytearray(b"X") * (128*1024)

    def is_buffered_protocol(self):
        return self._is_buffered

    def connection_made(self, transport):
        _logger.debug("EchoServer.connection_made")
        self.transport = transport
        ssl_protocol = self.transport.get_extra_info('ssl_protocol')
        if ssl_protocol is not None and hasattr(ssl_protocol, '_allow_renegotiation'):
            ssl_protocol._allow_renegotiation()

    def get_buffer(self, hint):
        return self._read_buffer

    def buffer_updated(self, bytes_read):
        _logger.debug("EchoServer.buffer_updated: received=%d", bytes_read)
        assert self._is_buffered
        self.transport.write(self._read_buffer[:bytes_read])

    def data_received(self, data):
        _logger.debug("EchoServer.data_received: %d", len(data))
        assert not self._is_buffered
        self.transport.write(data)

    def pause_writing(self):
        _logger.debug("EchoServer.pause_writing")

    def resume_writing(self):
        _logger.debug("EchoServer.resume_writing")

    def eof_received(self):
        _logger.debug("EchoServer.eof_received")


class AsyncClient(asyncio.Protocol):
    def __init__(self, is_buffered: bool):
        self._is_buffered = is_buffered
        self._closed = asyncio.get_running_loop().create_future()
        self._transport = None
        self._read_buffer = bytearray(b"X") * (256*1024)
        self._data = bytearray()
        self._readn_waiter: Optional[Tuple[int, asyncio.Future]] = None
        self._is_writing_paused = False
        self._write_resumed_fut = None
        self._new_data_ev = asyncio.Event()
        self._is_eof_received = False

    @property
    def transport(self):
        return self._transport

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
        self._transport = transport
        ssl_protocol = self._transport.get_extra_info('ssl_protocol')
        if ssl_protocol is not None and hasattr(ssl_protocol, '_allow_renegotiation'):
            ssl_protocol._allow_renegotiation()

    def data_received(self, data):
        assert not self._is_buffered
        self._data.extend(data)
        _logger.debug("AsyncClient.data_received: received=%d, total=%d", len(data), len(self._data))
        self._wakeup_waiters()
        self._new_data_ev.set()
        self._new_data_ev.clear()

    def get_buffer(self, hint):
        return self._read_buffer

    def buffer_updated(self, bytes_read):
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
        self._write_resumed_fut.set_result(None)
        self._write_resumed_fut = None

    def eof_received(self):
        self._is_eof_received = True

    def connection_lost(self, exc):
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
        self._transport.write(data)

    def write_in_lines(self, data: bytes, num_lines: int):
        parts = []
        part_sz = int(len(data) / num_lines)
        for i in range(num_lines - 1):
            parts.append(data[part_sz*i : part_sz*(i + 1)])
        already_added = sum(len(part) for part in parts)
        parts.append(data[already_added:])
        lens = [f"len={len(p)}" for p in parts]
        _logger.debug("AsyncClient.writelines(%s)", lens)
        self._transport.writelines(parts)

    async def readn(self, n: int, timeout=5.0) -> bytes:
        assert self._readn_waiter is None

        if n < 0:
            raise ValueError("n must be >= 0")
        if n == 0:
            return b""

        if len(self._data) >= n:
            res = self._data[:n]
            self.data = self._data[n:]
            return res

        self._readn_waiter = (n, asyncio.get_running_loop().create_future())
        if timeout is None:
            return await asyncio.shield(self._readn_waiter[1])
        else:
            async with async_timeout.timeout(timeout):
                return await asyncio.shield(self._readn_waiter[1])

    def close(self):
        self._transport.close()

    def abort(self):
        self._transport.abort()

    async def wait_closed(self):
        await asyncio.shield(self._closed)

    async def wait_write_resumed(self, timeout=1.0):
        if self._write_resumed_fut is None:
            return

        async with async_timeout.timeout(timeout):
            return await asyncio.shield(self._write_resumed_fut)

    async def wait_new_data(self, timeout=1.0):
        async with async_timeout.timeout(timeout):
            return await asyncio.shield(self._new_data_ev.wait())

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
    port: int
    host: str = "127.0.0.1"


@dataclass(frozen=True)
class ConnectionType:
    name: str
    server_ssl_context: Optional[ssl.SSLContext] = None
    client_ssl_context: Optional[ssl.SSLContext] = None


@asynccontextmanager
async def echo_server(host="127.0.0.1", port=0, ssl_context=None, is_buffered=False):
    loop = asyncio.get_running_loop()
    server = await create_server(
        loop,
        lambda: EchoServerProtocol(is_buffered),
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
async def echo_client(server_or_host, port=None, ssl_context=None, server_hostname=None, is_buffered=False):
    if isinstance(server_or_host, EchoServerHandle):
        host = server_or_host.host
        port = server_or_host.port
    else:
        host = server_or_host
        if port is None:
            raise ValueError("port must be provided when host is passed directly")

    loop = asyncio.get_running_loop()
    _, client = await create_connection(
        loop,
        lambda: AsyncClient(is_buffered),
        host=host,
        port=port,
        ssl=ssl_context,
        server_hostname=server_hostname,
    )
    try:
        yield client
    finally:
        client.close()
        try:
            await asyncio.wait_for(client.wait_closed(), timeout=1.0)
        except TimeoutError:
            # SSL close_notify can hang in edge cases (for example no payload).
            client.abort()


def make_test_ssl_contexts(cert_file: Union[str, Path], key_file: Union[str, Path]):
    cert_file = str(cert_file)
    key_file = str(key_file)

    server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_context.load_cert_chain(certfile=cert_file, keyfile=key_file)

    client_context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    client_context.check_hostname = False
    client_context.verify_mode = ssl.CERT_NONE
    return server_context, client_context
