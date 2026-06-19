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

import pytest

import aiofastnet
from tests.utils import ConnectionType, TestServer, TestClient

# Number of echo round-trips performed per benchmarked run.
ROUNDS = 200
# Message payload sizes (bytes) exercised by the benchmarks.
MSG_SIZES = [256, 16384]


class EchoClientProtocol(asyncio.Protocol):
    def __init__(self, payload: bytes, rounds: int, is_buffered: bool):
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
        self._done = asyncio.get_running_loop().create_future()

    def start_benchmark(self):
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
        if self._received < len(self._payload):
            return

        self._received -= len(self._payload)
        self._remaining -= 1
        if self._remaining <= 0:
            self._transport.close()
        else:
            self._transport.write(self._payload)

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

    async with TestServer(ct=ct, is_buffered=buffered_protocol) as server:
        async with TestClient(server, ct=ct, is_buffered=buffered_protocol, protocol_factory=client_factory) as client:
            client.start_benchmark()
            await client.wait_closed()


def run_sync(payload: bytes, rounds: int, ct: ConnectionType, buffered_protocol: bool):
    asyncio.run(run_echo(payload, rounds, ct, buffered_protocol))


@pytest.mark.parametrize("msg_size", MSG_SIZES)
def test_echo_write(benchmark, conn_type, buffered_protocol, msg_size):
    payload = b"x" * msg_size
    benchmark(run_sync, payload, ROUNDS, conn_type, buffered_protocol)

