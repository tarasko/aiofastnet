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
import ssl
from pathlib import Path

import pytest

import aiofastnet

PROJECT_ROOT = Path(__file__).resolve().parents[1]
CERT_FILE = PROJECT_ROOT / "tests" / "test.crt"
KEY_FILE = PROJECT_ROOT / "tests" / "test.key"

HOST = "127.0.0.1"
# Number of echo round-trips performed per benchmarked run.
ROUNDS = 200
# Message payload sizes (bytes) exercised by the benchmarks.
MSG_SIZES = [256, 16384]


def build_ssl_contexts():
    server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_ctx.load_cert_chain(certfile=str(CERT_FILE), keyfile=str(KEY_FILE))

    tls_version = ssl.TLSVersion.TLSv1_2
    cipher = "ECDHE-RSA-AES128-GCM-SHA256"
    server_ctx.set_ciphers(cipher)
    server_ctx.minimum_version = tls_version
    server_ctx.maximum_version = tls_version

    client_ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE
    client_ctx.set_ciphers(cipher)
    client_ctx.minimum_version = tls_version
    client_ctx.maximum_version = tls_version

    return server_ctx, client_ctx


class EchoServerProtocol(asyncio.Protocol):
    def connection_made(self, transport):
        self._transport = transport

    def data_received(self, data):
        self._transport.write(data)


class EchoClientProtocol(asyncio.Protocol):
    def __init__(self, payload: bytes, rounds: int, done: asyncio.Future):
        self._payload = payload
        self._remaining = rounds
        self._received = 0
        self._done = done
        self._transport = None

    def connection_made(self, transport):
        self._transport = transport
        self._transport.write(self._payload)

    def data_received(self, data):
        self._received += len(data)
        if self._received < len(self._payload):
            return

        self._received -= len(self._payload)
        self._remaining -= 1
        if self._remaining <= 0:
            self._transport.close()
            if not self._done.done():
                self._done.set_result(None)
        else:
            self._transport.write(self._payload)

    def connection_lost(self, exc):
        if not self._done.done():
            if exc is None:
                self._done.set_result(None)
            else:
                self._done.set_exception(exc)


async def run_echo(use_aiofastnet: bool, payload: bytes, rounds: int, ssl_ctxs):
    loop = asyncio.get_running_loop()
    server_ssl, client_ssl = ssl_ctxs if ssl_ctxs is not None else (None, None)

    if use_aiofastnet:
        server = await aiofastnet.create_server(
            loop, EchoServerProtocol, host=HOST, port=0, ssl=server_ssl
        )
    else:
        server = await loop.create_server(
            EchoServerProtocol, host=HOST, port=0, ssl=server_ssl
        )

    port = server.sockets[0].getsockname()[1]
    done = loop.create_future()

    def client_factory():
        return EchoClientProtocol(payload, rounds, done)

    server_hostname = HOST if client_ssl is not None else None

    try:
        if use_aiofastnet:
            transport, _ = await aiofastnet.create_connection(
                loop, client_factory, host=HOST, port=port,
                ssl=client_ssl, server_hostname=server_hostname,
            )
        else:
            transport, _ = await loop.create_connection(
                client_factory, host=HOST, port=port,
                ssl=client_ssl, server_hostname=server_hostname,
            )
        try:
            await done
        finally:
            transport.close()
    finally:
        server.close()
        await server.wait_closed()


def run_sync(use_aiofastnet: bool, payload: bytes, rounds: int, ssl_ctxs):
    asyncio.run(run_echo(use_aiofastnet, payload, rounds, ssl_ctxs))


@pytest.fixture(scope="module")
def ssl_ctxs():
    return build_ssl_contexts()


@pytest.mark.parametrize("msg_size", MSG_SIZES)
@pytest.mark.parametrize("use_aiofastnet", [False, True], ids=["native", "aiofastnet"])
def test_tcp_echo(benchmark, use_aiofastnet, msg_size):
    payload = b"x" * msg_size
    benchmark(run_sync, use_aiofastnet, payload, ROUNDS, None)


@pytest.mark.parametrize("msg_size", MSG_SIZES)
@pytest.mark.parametrize("use_aiofastnet", [False, True], ids=["native", "aiofastnet"])
def test_ssl_echo(benchmark, use_aiofastnet, msg_size, ssl_ctxs):
    payload = b"x" * msg_size
    benchmark(run_sync, use_aiofastnet, payload, ROUNDS, ssl_ctxs)
