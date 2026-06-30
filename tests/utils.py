import asyncio
import socket
import weakref
from contextlib import asynccontextmanager, contextmanager, ExitStack
from dataclasses import dataclass
import os
from logging import getLogger
from pathlib import Path
import ssl
import sys
import tempfile
from typing import Tuple, Optional, Union, Any, List

import async_timeout
import pytest

import aiofastnet

_logger = getLogger("tests.utils")
# This is useful to verify tests against stdlib implementations
NO_AIOFN = os.environ.get('NO_AIOFN')


class SomeException(Exception):
    pass


def _set_socket_sndbuf(transport: asyncio.Transport, size: int) -> int:
    sock = transport.get_extra_info('socket')
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, max(1, size // 2))
    return sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)


async def sendfile(loop, *args, **kwargs):
    if NO_AIOFN:
        return await loop.sendfile(*args, **kwargs)
    else:
        return await aiofastnet.sendfile(loop, *args, **kwargs)


async def start_tls(loop, *args, **kwargs):
    if NO_AIOFN:
        return await loop.start_tls(*args, **kwargs)
    else:
        return await aiofastnet.start_tls(loop, *args, **kwargs)


async def create_connection(loop, *args, **kwargs):
    if NO_AIOFN:
        return await loop.create_connection(*args, **kwargs)
    else:
        return await aiofastnet.create_connection(loop, *args, **kwargs)


async def create_unix_connection(loop, *args, **kwargs):
    if NO_AIOFN:
        return await loop.create_unix_connection(*args, **kwargs)
    else:
        return await aiofastnet.create_unix_connection(loop, *args, **kwargs)


async def create_server(loop, *args, **kwargs):
    if NO_AIOFN:
        return await loop.create_server(*args, **kwargs)
    else:
        return await aiofastnet.create_server(loop, *args, **kwargs)


async def create_unix_server(loop, *args, **kwargs):
    if NO_AIOFN:
        return await loop.create_unix_server(*args, **kwargs)
    else:
        return await aiofastnet.create_unix_server(loop, *args, **kwargs)


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
        _logger.debug("EchoServer.connection_lost, exc=%s", exc)
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
        if isinstance(self.transport, aiofastnet.Transport):
            assert not self._is_buffered
        self._data.extend(data)
        _logger.debug("AsyncClient.data_received: received=%d, total=%d", len(data), len(self._data))
        self._wakeup_waiters()
        self._new_data_ev.set()
        self._new_data_ev.clear()

    def get_buffer(self, hint):
        return memoryview(self._read_buffer)

    def buffer_updated(self, bytes_read):
        if isinstance(self.transport, aiofastnet.Transport):
            assert self._is_buffered
        self._data += self._read_buffer[:bytes_read]
        _logger.debug("AsyncClient.buffer_updated: received=%d, total=%d", bytes_read, len(self._data))
        self._wakeup_waiters()
        self._new_data_ev.set()
        self._new_data_ev.clear()

    def pause_writing(self):
        _logger.debug("AsyncClient.pause_writing")
        self._is_writing_paused = True

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
        _logger.debug("AsyncClient.connection_lost, exc=%s", exc)
        if not self._closed.done():
            if exc is not None:
                self._closed.set_exception(exc)
            else:
                self._closed.set_result(None)
        if self._readn_waiter is not None:
            self._readn_waiter[1].set_exception(ConnectionResetError())
            self._readn_waiter = None
        if self._write_resumed_fut is not None:
            self._write_resumed_fut.set_exception(ConnectionResetError())
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
        if not self._is_writing_paused:
            return

        if self._write_resumed_fut is None:
            self._write_resumed_fut = asyncio.get_running_loop().create_future()

        async with async_timeout.timeout(timeout):
            return await asyncio.shield(self._write_resumed_fut)

    async def wait_new_data(self, timeout=1.0):
        async with async_timeout.timeout(timeout):
            return await asyncio.shield(self._new_data_ev.wait())

    async def start_tls(self, ssl_context, server_hostname="127.0.0.1",
                        ssl_handshake_timeout=None, ssl_shutdown_timeout=None):
        self.transport = await start_tls(
            asyncio.get_running_loop(),
            self.transport,
            self,
            ssl_context,
            server_side=False,
            server_hostname=server_hostname,
            ssl_handshake_timeout=ssl_handshake_timeout,
            ssl_shutdown_timeout=ssl_shutdown_timeout,
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


class ServerStartTLSProtocol(asyncio.Protocol):
    def __init__(self, protocol_factory, ssl_context, ssl_handshake_timeout=None, ssl_shutdown_timeout=None):
        self._protocol_factory = protocol_factory
        self._ssl_context = ssl_context
        self._ssl_handshake_timeout = ssl_handshake_timeout
        self._ssl_shutdown_timeout = ssl_shutdown_timeout
        self._protocol = None
        self._transport = None
        self._start_tls_task = None
        self._connection_made = False

    def connection_made(self, transport):
        self._transport = transport
        transport.pause_reading()
        self._protocol = self._protocol_factory()
        self._start_tls_task = asyncio.get_running_loop().create_task(self._start_tls())

    async def _start_tls(self):
        try:
            self._transport = await start_tls(
                asyncio.get_running_loop(),
                self._transport,
                self._protocol,
                self._ssl_context,
                server_side=True,
                ssl_handshake_timeout=self._ssl_handshake_timeout,
                ssl_shutdown_timeout=self._ssl_shutdown_timeout,
            )
        except Exception:
            _logger.exception("ServerStartTLSProtocol: unable to start TLS")
            if self._transport is not None:
                self._transport.close()
            return

        self._connection_made = True
        self._protocol.connection_made(self._transport)

    def connection_lost(self, exc):
        if self._start_tls_task is not None and not self._start_tls_task.done():
            self._start_tls_task.cancel()
        if self._connection_made:
            self._protocol.connection_lost(exc)


@dataclass(frozen=True)
class EchoServerHandle:
    server: asyncio.Server
    clients: set[Any]
    client_waiters: List[Any]
    port: Optional[int]
    host: str = "127.0.0.1"
    path: Optional[str] = None

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
            except ValueError:
                pass

        return next(iter(self.clients))()

@dataclass(frozen=True)
class ConnectionType:
    name: str
    server_ssl_context: Optional[ssl.SSLContext] = None
    client_ssl_context: Optional[ssl.SSLContext] = None

    def check_sendfile_supported(self):
        if os.name == "nt":
            proactor_loop = getattr(asyncio, "ProactorEventLoop", None)
            loop = asyncio.get_running_loop()
            if (
                    self.name == "tcp"
                    and not NO_AIOFN
                    and proactor_loop is not None
                    and isinstance(loop, proactor_loop)
            ):
                return
            pytest.skip("sendfile is not supported in Windows")

        if self.name in ("ssl_mbio", "ssl_mbio_fall", "ssl_sbio", "stls", "stls_fall"):
            pytest.skip("SSL_sendfile is not supported for non-kernel TLS")

        if self.name == "ktls" and sys.platform != "linux":
            pytest.skip("SSL_sendfile only works on Linux")

    @property
    def use_start_tls(self):
        return self.name in ("stls", "stls_fall")


def _make_ktls_conn_type():
    if aiofastnet.OPENSSL_DYN_LIBS is None:
        pytest.skip("kTLS is not available with standalone python")
    if sys.version_info < (3, 12):
        pytest.skip("kTLS tests require Python >= 3.12")
    if sys.platform != "linux":
        pytest.skip("kTLS is available only on Linux")

    server_context, client_context = make_test_ssl_contexts(
        "tests/test.crt", "tests/test.key", True
    )
    return ConnectionType("ktls", server_context, client_context)


def _make_ssl_sbio_conn_type():
    if aiofastnet.OPENSSL_DYN_LIBS is None:
        pytest.skip("Socket BIO is not available with standalone python")

    server_context, client_context = make_test_ssl_contexts(
        "tests/test.crt", "tests/test.key", False
    )
    server_context._aiofastnet_force_socket_bio = True
    client_context._aiofastnet_force_socket_bio = True
    return ConnectionType("ssl_sbio", server_context, client_context)


def _make_unix_conn_type():
    if os.name == "nt":
        pytest.skip("Unix sockets are not supported on Windows")

    return ConnectionType("unix", None, None)

@pytest.fixture
def ktls_conn_type():
    return _make_ktls_conn_type()


@pytest.fixture
def ssl_sbio_conn_type():
    return _make_ssl_sbio_conn_type()


@pytest.fixture(params=["tcp", "ktls"])
def sendfile_conn_type(request):
    return _make_conn_type_from_param(request)


@pytest.fixture(params=[
    "tcp",
    "unix",
    "ssl_mbio",
    "ssl_mbio_fall",
    "ssl_sbio",
    "stls",     # Use SSLTransport_Transport by using start_tls
    "stls_fall",     # Use SSLTransport_Transport with SSLEngineFallback
    "ktls",
])
def conn_type(request):
    return _make_conn_type_from_param(request)


@pytest.fixture(params=[
    "tcp",
    "ssl_mbio",
    "ssl_mbio_fall",
    "ssl_sbio",
    "stls",
    "stls_fall",
    "ktls",
])
def benchmark_conn_type(request):
    return _make_conn_type_from_param(request)


def _make_conn_type_from_param(request):
    if request.param == "tcp":
        return ConnectionType(name=request.param)
    elif request.param == "unix":
        return _make_unix_conn_type()
    elif request.param in ("ssl_mbio", "ssl_mbio_fall", "stls", "stls_fall"):
        server_context, client_context = make_test_ssl_contexts("tests/test.crt", "tests/test.key", False)
        if request.param in ("ssl_mbio_fall", "stls_fall"):
            server_context._aiofastnet_force_fallback_ssl = True
            client_context._aiofastnet_force_fallback_ssl = True
        return ConnectionType(request.param, server_context, client_context)
    elif request.param == "ssl_sbio":
        return _make_ssl_sbio_conn_type()
    elif request.param == "ktls":
        return _make_ktls_conn_type()
    else:
        raise ValueError(f"unknown connection type {request.param!r}")


@pytest.fixture(params=[
    "ssl_mbio",
    "ssl_mbio_fall",
    "ssl_sbio",
    "stls",     # Use SSLTransport_Transport by using start_tls
    "stls_fall",     # Use SSLTransport_Transport with SSLEngineFallback
    "ktls"
])
def ssl_conn_type(request):
    return _make_conn_type_from_param(request)


@pytest.fixture(params=["simple", "buffered"])
def buffered_protocol(request):
    return request.param == "buffered"


@asynccontextmanager
async def TestServer(protocol_factory=None,
                     host="127.0.0.1", port=0,
                     ct: ConnectionType=ConnectionType("tcp"),
                     is_buffered=False,
                     ssl_handshake_timeout=None,
                     ssl_shutdown_timeout=None):
    loop = asyncio.get_running_loop()
    clients = set()
    client_waiters = []
    if protocol_factory is None:
        def protocol_factory():
            return EchoServerProtocol(clients, client_waiters, is_buffered)

    with ExitStack() as stack:
        if ct.name == "unix":
            tmpdir = stack.enter_context(tempfile.TemporaryDirectory())
            path = os.path.join(tmpdir, "aiofastnet.sock")
            server = await create_unix_server(
                loop,
                protocol_factory,
                path=path,
                ssl=ct.server_ssl_context,
                ssl_handshake_timeout=ssl_handshake_timeout,
                ssl_shutdown_timeout=ssl_shutdown_timeout,
            )
        else:
            path = None
            if ct.use_start_tls:
                def server_protocol_factory():
                    return ServerStartTLSProtocol(
                        protocol_factory,
                        ct.server_ssl_context,
                        ssl_handshake_timeout=ssl_handshake_timeout,
                        ssl_shutdown_timeout=ssl_shutdown_timeout,
                    )

                server_ssl_context = None
                server_ssl_handshake_timeout = None
                server_ssl_shutdown_timeout = None
            else:
                server_protocol_factory = protocol_factory
                server_ssl_context = ct.server_ssl_context
                server_ssl_handshake_timeout = ssl_handshake_timeout
                server_ssl_shutdown_timeout = ssl_shutdown_timeout

            server = await create_server(
                loop,
                server_protocol_factory,
                host=host,
                port=port,
                ssl=server_ssl_context,
                ssl_handshake_timeout=server_ssl_handshake_timeout,
                ssl_shutdown_timeout=server_ssl_shutdown_timeout,
            )
        try:
            if ct.name == "unix":
                resolved_port = None
            else:
                resolved_port = server.sockets[0].getsockname()[1]
            yield EchoServerHandle(
                server=server,
                port=resolved_port,
                host=host,
                path=path,
                clients=clients,
                client_waiters=client_waiters,
            )
        finally:
            try:
                server.close()
            except AttributeError:
                # On windows proactor close() may cause:
                #   AttributeError: 'NoneType' object has no attribute '_stop_serving'
                # because loop has been already closed
                pass
            for w in client_waiters:
                if not w.done():
                    w.set_exception(RuntimeError("server finished"))
            client_waiters.clear()
            await server.wait_closed()


@asynccontextmanager
async def TestClient(server_or_host, port=None,
                     ct: ConnectionType=ConnectionType("tcp"),
                     server_hostname=None,
                     is_buffered=False,
                     protocol_factory=AsyncClient,
                     ssl_handshake_timeout=None,
                     ssl_shutdown_timeout=None):
    if isinstance(server_or_host, EchoServerHandle):
        host = server_or_host.host
        port = server_or_host.port
        path = server_or_host.path
    else:
        host = server_or_host
        path = None
        if port is None and ct.name != "unix":
            raise ValueError("port must be provided when host is passed directly")

    loop = asyncio.get_running_loop()
    transport = None
    client = None
    try:
        if ct.name == "unix":
            transport, client = await create_unix_connection(
                loop,
                lambda: protocol_factory(is_buffered),
                path=path if path is not None else host,
            )
        elif ct.use_start_tls:
            client = protocol_factory(is_buffered)
            transport, _ = await create_connection(
                loop,
                asyncio.Protocol,
                host=host,
                port=port,
            )
            transport = await start_tls(
                loop,
                transport,
                client,
                ct.client_ssl_context,
                server_side=False,
                server_hostname=server_hostname,
                ssl_handshake_timeout=ssl_handshake_timeout,
                ssl_shutdown_timeout=ssl_shutdown_timeout,
            )
            client.connection_made(transport)
        elif ct.client_ssl_context is None:
            transport, client = await create_connection(
                loop,
                lambda: protocol_factory(is_buffered),
                host=host,
                port=port,
            )
        else:
            transport, client = await create_connection(
                loop,
                lambda: protocol_factory(is_buffered),
                host=host,
                port=port,
                ssl=ct.client_ssl_context,
                server_hostname=server_hostname,
                ssl_handshake_timeout=ssl_handshake_timeout,
                ssl_shutdown_timeout=ssl_shutdown_timeout
            )

        yield client
    finally:
        if transport is not None:
            transport.abort()
            try:
                await client.wait_closed(1.0)
            except Exception:
                pass


def make_test_ssl_contexts(cert_file: Union[str, Path], key_file: Union[str, Path], enable_ktls=False):
    cert_file = str(cert_file)
    key_file = str(key_file)

    server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_context.load_cert_chain(certfile=cert_file, keyfile=key_file)
    server_context.minimum_version = ssl.TLSVersion.TLSv1_2
    server_context.maximum_version = ssl.TLSVersion.TLSv1_2
    server_context.set_ciphers("ECDHE-RSA-AES128-GCM-SHA256")
    if enable_ktls:
        server_context.options |= ssl.OP_ENABLE_KTLS

    client_context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    client_context.check_hostname = False
    client_context.verify_mode = ssl.CERT_NONE
    client_context.minimum_version = ssl.TLSVersion.TLSv1_2
    client_context.maximum_version = ssl.TLSVersion.TLSv1_2
    client_context.set_ciphers("ECDHE-RSA-AES128-GCM-SHA256")
    if enable_ktls:
        client_context.options |= ssl.OP_ENABLE_KTLS

    return server_context, client_context


@contextmanager
def exc_queue(excq=None):
    loop = asyncio.get_running_loop()
    old_handler = loop.get_exception_handler()
    exc_queue = [] if excq is None else excq
    def new_handler(loop, context):
        nonlocal exc_queue
        exc_queue.append(context)
    loop.set_exception_handler(new_handler)
    try:
        yield exc_queue
    finally:
        exc_queue.clear()
        loop.set_exception_handler(old_handler)
