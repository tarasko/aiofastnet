"""CodSpeed benchmarks for aiofastnet.

These benchmarks measure the cost of a fixed number of echo round-trips over a
loopback connection, comparing the native asyncio transport against the
aiofastnet transport for both plain TCP and TLS.

Unlike the throughput benchmarks in ``examples/benchmark.py`` (which run for a
fixed duration and report round-trips/sec), these run a fixed, deterministic
number of round-trips so they can be measured with CodSpeed's CPU simulation
instrument.
"""

import asyncio
import os
import tempfile
from typing import Union, List

import pytest

if os.name == "nt":
    pytest.skip("CodSpeed benchmarks are not run on Windows", allow_module_level=True)

import aiofastnet
import uvloop
from tests.utils import ConnectionType, TestServer, TestClient, _set_socket_sndbuf

# Message payload sizes (bytes) + num of rounds exercised by the benchmarks.
MSG_SIZES = [(256, 200), (1024*1024, 10)]
MSG_SIZE_IDS = ["small", "large"]


@pytest.fixture
def asyncio_debug(request):
    value = request.config.getoption("asyncio_debug")
    if value is None:
        value = request.config.getini("asyncio_debug")
    if isinstance(value, bool):
        return value
    return value == "true"



class ServerProtocol(asyncio.Protocol):
    def __init__(self, msg_size, is_buffered, all_server_clients):
        self._all_server_clients = all_server_clients
        self._msg_size = msg_size
        self._is_buffered = is_buffered
        self._pending = 0
        self._buffer = bytearray(32*1024) if is_buffered else None
        self._client = None

    def is_buffered_protocol(self):
        return self._is_buffered

    def connection_made(self, transport):
        self.transport = transport
        self._all_server_clients.append(self)

    def connection_lost(self, exc):
        self.transport = None
        self._all_server_clients.remove(self)

    def get_buffer(self, hint):
        return self._buffer

    def buffer_updated(self, bytes_read):
        self._pending += bytes_read
        while self._pending >= self._msg_size:
            asyncio.get_running_loop().call_soon(self._client.write)
            self._pending -= self._msg_size

    def data_received(self, data):
        self._pending += len(data)
        while self._pending >= self._msg_size:
            asyncio.get_running_loop().call_soon(self._client.write)
            self._pending -= self._msg_size

    def set_client(self, client):
        self._client = client


class ClientProtocol(asyncio.BufferedProtocol):
    def __init__(self, payload: Union[bytes, List[bytes]], rounds: int):
        self._payload = payload
        self._remaining = rounds + 1
        self._transport = None
        self._done = None
        self._read_buffer = bytearray(b"X") * (128*1024)

    def connection_made(self, transport: aiofastnet.Transport):
        self._transport = transport
        _set_socket_sndbuf(self._transport, 128*1024)
        self._done = asyncio.get_running_loop().create_future()

    def write(self):
        self._remaining -= 1
        if self._remaining <= 0:
            self._transport.close()
            return

        self.write_impl()

    def write_impl(self):
        if isinstance(self._payload, list):
            self._transport.writelines(self._payload)
        else:
            self._transport.write(self._payload)

    def connection_lost(self, exc):
        if self._done is not None and not self._done.done():
            if exc is None:
                self._done.set_result(None)
            else:
                self._done.set_exception(exc)

    def get_buffer(self, hint):
        return self._read_buffer

    def buffer_updated(self, bytes_read):
        pass


    async def start_tls(self, ssl_context, server_hostname="127.0.0.1",
                        ssl_handshake_timeout=None, ssl_shutdown_timeout=None):
        self._transport = await aiofastnet.start_tls(
            asyncio.get_running_loop(),
            self._transport,
            self,
            ssl_context,
            server_side=False,
            server_hostname=server_hostname,
            ssl_handshake_timeout=ssl_handshake_timeout,
            ssl_shutdown_timeout=ssl_shutdown_timeout,
        )

    async def wait_closed(self):
        await self._done


class SendfileClientProtocol(ClientProtocol):
    def __init__(self, file, payload_size: int, rounds: int):
        super().__init__(b"", rounds)
        self._file = file
        self._payload_size = payload_size

    def write_impl(self):
        self._transport.sendfile(
            self._file,
            offset=0,
            count=self._payload_size,
        )


async def run_server_client(client_factory, payload_size, ct: ConnectionType, is_server_buffered):
    all_server_clients = []

    async with TestServer(lambda: ServerProtocol(payload_size, is_server_buffered, all_server_clients), ct=ct) as server:
        async with TestClient(server, ct=ct, is_buffered=True, protocol_factory=client_factory) as client:
            while not all_server_clients:
                await asyncio.sleep(0)
            all_server_clients[0].set_client(client)
            client.write()
            await client.wait_closed()


def run_in_loop(client_factory, payload_size, ct, is_server_buffered, asyncio_debug):
    uvloop.run(
        run_server_client(client_factory, payload_size, ct, is_server_buffered),
        debug=asyncio_debug,
    )


@pytest.mark.parametrize("msg_size", MSG_SIZES, ids=MSG_SIZE_IDS)
def test_benchmark_write(benchmark, conn_type, buffered_protocol, msg_size, asyncio_debug):
    payload_size, rounds = msg_size
    payload = b"x" * payload_size

    def client_factory(is_buffered: bool):
        return ClientProtocol(payload, rounds)

    benchmark(run_in_loop, client_factory, payload_size, conn_type, buffered_protocol, asyncio_debug)


@pytest.mark.parametrize("msg_size", MSG_SIZES, ids=MSG_SIZE_IDS)
def test_benchmark_writelines(benchmark, conn_type, msg_size, asyncio_debug):
    payload_size, rounds = msg_size
    payload = [b"x" * int(payload_size/256)] * 256

    def client_factory(is_buffered: bool):
        return ClientProtocol(payload, rounds)

    benchmark(run_in_loop, client_factory, payload_size, conn_type, True, asyncio_debug)


@pytest.mark.parametrize("msg_size", MSG_SIZES, ids=MSG_SIZE_IDS)
def test_benchmark_sendfile(benchmark, sendfile_conn_type, msg_size, asyncio_debug):
    payload_size = msg_size[0]
    rounds = msg_size[1]
    with tempfile.TemporaryFile() as file:
        file.write(b"x" * payload_size)
        file.flush()

        def client_factory(is_buffered: bool):
            return SendfileClientProtocol(file, payload_size, rounds)

        benchmark(run_in_loop, client_factory, payload_size, sendfile_conn_type, True, asyncio_debug)
