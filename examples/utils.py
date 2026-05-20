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

    tls_version = ssl.TLSVersion.TLSv1_2
    cipher = "ECDHE-RSA-AES128-GCM-SHA256"
    if enable_ktls:
        server_ctx.options |= ssl.OP_ENABLE_KTLS
        server_ctx.set_ciphers(cipher)
        server_ctx.minimum_version = tls_version
        server_ctx.maximum_version = tls_version

    client_ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE
    if enable_ktls:
        client_ctx.options |= ssl.OP_ENABLE_KTLS
        client_ctx.set_ciphers(cipher)
        client_ctx.minimum_version = tls_version
        client_ctx.maximum_version = tls_version

    return server_ctx, client_ctx


@asynccontextmanager
async def EchoServer(use_aiofastnet,
                     server_ssl: ssl.SSLContext | None,
                     sndbuf_size: int | None = None,
                     host: str = "127.0.0.1",
                     port: int = 0,
                     reuse_port: bool | None = None,
                     ssl_merge_transports=False):
    loop = asyncio.get_running_loop()

    if use_aiofastnet:
        server = await aiofastnet.create_server(
            loop,
            ServerProtocol,
            host=host,
            port=port,
            ssl=server_ssl,
            reuse_port=reuse_port,
            ssl_merge_transports=ssl_merge_transports
        )
    else:
        server = await loop.create_server(
            ServerProtocol,
            host=host,
            port=port,
            ssl=server_ssl,
            reuse_port=reuse_port,
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
                     sndbuf_size: int | None = None,
                     host: str = "127.0.0.1",
                     ssl_merge_transports=False) -> ClientProtocol:
    loop = asyncio.get_running_loop()

    if use_aiofastnet:
        transport, client = await aiofastnet.create_connection(
            loop,
            lambda: ClientProtocol(payload, duration, 0),
            host=host,
            port=port,
            ssl=client_ssl,
            server_hostname=host if client_ssl is not None else None,
            ssl_merge_transports=ssl_merge_transports
        )
    else:
        transport, client = await loop.create_connection(
            lambda: ClientProtocol(payload, duration, 0),
            host=host,
            port=port,
            ssl=client_ssl,
            server_hostname=host if client_ssl is not None else None,
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
    sndbuf_size: int | None = None,
    ssl_merge_transports: bool = False
) -> int:
    async with EchoServer(use_aiofastnet, server_ssl, sndbuf_size, ssl_merge_transports=ssl_merge_transports) as server_port:
        async with EchoClient(use_aiofastnet, server_port, duration, payload, client_ssl, sndbuf_size, ssl_merge_transports=ssl_merge_transports) as client:
            if barrier is not None:
                if isinstance(barrier, asyncio.Barrier):
                    await barrier.wait()
                else:
                    barrier.wait()
            client.write_first_data()
            await client.closed
            return client.requests
