import asyncio
import ssl
import sys
import threading
from contextlib import asynccontextmanager
from functools import partial
from pathlib import Path

from .benchmark_protocol import ServerProtocol, ClientProtocol

import aiofastnet


PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


def build_ssl_contexts() -> tuple[ssl.SSLContext, ssl.SSLContext]:
    cert_file = PROJECT_ROOT / "tests" / "test.crt"
    key_file = PROJECT_ROOT / "tests" / "test.key"

    server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_ctx.load_cert_chain(certfile=str(cert_file), keyfile=str(key_file))

    client_ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    return server_ctx, client_ctx


@asynccontextmanager
async def EchoServer(use_aiofastnet, server_ssl: ssl.SSLContext | None):
    loop = asyncio.get_running_loop()
    server = await aiofastnet.create_server(
        loop,
        ServerProtocol,
        host="127.0.0.1",
        ssl=server_ssl
    )
    try:
        yield server.sockets[0].getsockname()[1]
    finally:
        server.close()
        await server.wait_closed()


@asynccontextmanager
async def EchoClient(use_aiofastnet, port: int, duration: float, payload: bytes, client_ssl: ssl.SSLContext | None) -> ClientProtocol:
    loop = asyncio.get_running_loop()
    protocol = ClientProtocol(payload, duration, 0)
    create_connection = partial(aiofastnet.create_connection, loop) \
        if use_aiofastnet else loop.create_connection

    transport, client = await create_connection(
        lambda: protocol,
        host="127.0.0.1",
        port=port,
        ssl=client_ssl,
        server_hostname="127.0.0.1" if client_ssl is not None else None,
    )
    try:
        yield client
    finally:
        transport.close()


async def run_pair(
    duration: float,
    payload: bytes,
    server_ssl: ssl.SSLContext | None,
    client_ssl: ssl.SSLContext | None,
    barrier: threading.Barrier | asyncio.Barrier | None,
) -> int:
    async with EchoServer(True, server_ssl) as server_port:
        async with EchoClient(True, server_port, duration, payload, client_ssl) as client:
            if barrier is not None:
                if isinstance(barrier, asyncio.Barrier):
                    await barrier.wait()
                else:
                    barrier.wait()
            client.write_first_data()
            await client.closed
            return client.requests
