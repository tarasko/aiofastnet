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
from typing import Union, List

import pytest

import aiofastnet
from tests.utils import ConnectionType, TestServer, TestClient, _set_socket_sndbuf

# Message payload sizes (bytes) + num of rounds exercised by the benchmarks.
MSG_SIZES = [(256, 200), (1024*1024, 10)]
MSG_SIZE_IDS = ["small", "large"]


class ServerProtocol(asyncio.Protocol):
    def __init__(self, msg_size, is_buffered):
        self._msg_size = msg_size
        self._is_buffered = is_buffered
        self._pending = 0
        self._buffer = bytearray(128*1024) if is_buffered else None

    def is_buffered_protocol(self):
        return self._is_buffered

    def connection_made(self, transport):
        self.transport = transport

    def get_buffer(self, hint):
        return self._buffer

    def buffer_updated(self, bytes_read):
        self._pending += bytes_read
        while self._pending >= self._msg_size:
            self.transport.write(b"done")
            self._pending -= self._msg_size

    def data_received(self, data):
        self._pending += len(data)
        while self._pending >= self._msg_size:
            self.transport.write(b"done")
            self._pending -= self._msg_size


class EchoClientProtocol(asyncio.Protocol):
    def __init__(self, payload: Union[bytes, List[bytes]] , rounds: int, is_buffered: bool):
        self._payload = payload
        self._remaining = rounds
        self._is_buffered = is_buffered
        self._received = 0
        self._transport = None
        self._done = None
        self._read_buffer = bytearray(b"X") * (128*1024) if is_buffered else None

    def is_buffered_protocol(self):
        return self._is_buffered

    def connection_made(self, transport: aiofastnet.Transport):
        self._transport = transport
        _set_socket_sndbuf(self._transport, 128*1024)
        self._done = asyncio.get_running_loop().create_future()

    def write(self):
        if isinstance(self._payload, list):
            self._transport.writelines(self._payload)
        else:
            self._transport.write(self._payload)

    def connection_lost(self, exc):
        if self._done is not None:
            if exc is None:
                self._done.set_result(None)
            else:
                self._done.set_exception(exc)

    def get_buffer(self, hint):
        return memoryview(self._read_buffer)

    def buffer_updated(self, bytes_read):
        self._account_received(bytes_read)

    def data_received(self, data):
        self._account_received(len(data))

    def _account_received(self, sz):
        self._received += sz
        if self._received < 4:
            return

        self._received -= 4
        self._remaining -= 1
        if self._remaining <= 0:
            self._transport.close()
        else:
            self.write()

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


async def run_echo(payload: bytes, rounds: int, ct: ConnectionType, buffered_protocol: bool):
    def client_factory(is_buffered: bool):
        return EchoClientProtocol(payload, rounds, is_buffered)

    async with TestServer(lambda: ServerProtocol(len(payload), buffered_protocol), ct=ct) as server:
        async with TestClient(server, ct=ct, is_buffered=buffered_protocol, protocol_factory=client_factory) as client:
            client.write()
            await client.wait_closed()


def run_sync(payload: bytes, rounds: int, ct: ConnectionType, buffered_protocol: bool):
    asyncio.run(run_echo(payload, rounds, ct, buffered_protocol))


@pytest.mark.parametrize("msg_size", MSG_SIZES, ids=MSG_SIZE_IDS)
def test_benchmark_write(benchmark, conn_type, buffered_protocol, msg_size):
    payload = b"x" * msg_size[0]
    rounds = msg_size[1]
    benchmark(run_sync, payload, rounds, conn_type, buffered_protocol)

