import asyncio
import socket
import ssl
import threading
from contextlib import asynccontextmanager
from functools import partial
from pathlib import Path

import aiofastnet
from .benchmark_protocol import ServerProtocol, ClientProtocol


def set_socket_sndbuf(sock: socket.socket, size: int) -> int:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, max(1, size // 2))
    return sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)


def build_ssl_contexts(enable_ktls=False) -> tuple[ssl.SSLContext, ssl.SSLContext]:
    PROJECT_ROOT = Path(__file__).resolve().parents[1]

    cert_file = PROJECT_ROOT / "tests" / "test.crt"
    key_file = PROJECT_ROOT / "tests" / "test.key"

    server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_ctx.load_cert_chain(certfile=str(cert_file), keyfile=str(key_file))
    if enable_ktls:
        server_ctx.options |= ssl.OP_ENABLE_KTLS
        server_ctx.set_ciphers("ECDHE-RSA-AES128-GCM-SHA256")
        server_ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        server_ctx.maximum_version = ssl.TLSVersion.TLSv1_2

    client_ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE
    if enable_ktls:
        client_ctx.options |= ssl.OP_ENABLE_KTLS
        client_ctx.set_ciphers("ECDHE-RSA-AES128-GCM-SHA256")
        client_ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        client_ctx.maximum_version = ssl.TLSVersion.TLSv1_2

    return server_ctx, client_ctx


@asynccontextmanager
async def EchoServer(use_aiofastnet,
                     server_ssl: ssl.SSLContext | None,
                     sndbuf_size: int | None=None):
    loop = asyncio.get_running_loop()
    create_server = partial(aiofastnet.create_server, loop) \
        if use_aiofastnet else loop.create_server

    server = await create_server(
        ServerProtocol,
        host="127.0.0.1",
        ssl=server_ssl
    )
    if sndbuf_size is not None:
        for server_sock in server.sockets:
            set_socket_sndbuf(server_sock, sndbuf_size)
    try:
        yield server.sockets[0].getsockname()[1]
    finally:
        server.close()
        await server.wait_closed()


@asynccontextmanager
async def EchoClient(use_aiofastnet,
                     port: int,
                     duration: float,
                     payload: bytes,
                     client_ssl: ssl.SSLContext | None,
                     sndbuf_size: int | None = None) -> ClientProtocol:
    loop = asyncio.get_running_loop()
    create_connection = partial(aiofastnet.create_connection, loop) \
        if use_aiofastnet else loop.create_connection

    transport, client = await create_connection(
        lambda: ClientProtocol(payload, duration, 0),
        host="127.0.0.1",
        port=port,
        ssl=client_ssl,
        server_hostname="127.0.0.1" if client_ssl is not None else None,
    )
    client_sock = transport.get_extra_info("socket")
    if client_sock is not None:
        if sndbuf_size is not None:
            set_socket_sndbuf(client_sock, sndbuf_size)
    try:
        yield client
    finally:
        transport.close()


async def run_pair(
    use_aiofastnet: bool,
    duration: float,
    payload: bytes,
    server_ssl: ssl.SSLContext | None,
    client_ssl: ssl.SSLContext | None,
    barrier: threading.Barrier | asyncio.Barrier | None,
    sndbuf_size: int | None = None
) -> int:
    async with EchoServer(use_aiofastnet, server_ssl, sndbuf_size) as server_port:
        async with EchoClient(use_aiofastnet, server_port, duration, payload, client_ssl, sndbuf_size) as client:
            if barrier is not None:
                if isinstance(barrier, asyncio.Barrier):
                    await barrier.wait()
                else:
                    barrier.wait()
            client.write_first_data()
            await client.closed
            return client.requests
