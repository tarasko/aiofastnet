import asyncio
import socket
import ssl
import threading
from contextlib import asynccontextmanager
from pathlib import Path

import aiofastnet
from .benchmark_protocol import ClientProtocol, ServerProtocol


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
    server_ctx.set_ciphers(cipher)
    server_ctx.minimum_version = tls_version
    server_ctx.maximum_version = tls_version

    client_ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE
    client_ctx.set_ciphers(cipher)
    client_ctx.minimum_version = tls_version
    client_ctx.maximum_version = tls_version

    if enable_ktls:
        server_ctx.options |= ssl.OP_ENABLE_KTLS
        client_ctx.options |= ssl.OP_ENABLE_KTLS

    return server_ctx, client_ctx


@asynccontextmanager
async def EchoServer(use_aiofastnet,
                     server_ssl: ssl.SSLContext | None,
                     is_buffered: bool = True,
                     sndbuf_size: int | None = None,
                     host: str = "127.0.0.1",
                     port: int = 0,
                     reuse_port: bool | None = None):
    loop = asyncio.get_running_loop()

    if use_aiofastnet:
        server = await aiofastnet.create_server(
            loop,
            lambda: ServerProtocol(is_buffered=is_buffered),
            host=host,
            port=port,
            ssl=server_ssl,
            reuse_port=reuse_port,
        )
    else:
        server = await loop.create_server(
            lambda: ServerProtocol(is_buffered=is_buffered),
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
                     is_buffered: bool = True,
                     sndbuf_size: int | None = None,
                     host: str = "127.0.0.1"
                     ) -> ClientProtocol:
    loop = asyncio.get_running_loop()

    if use_aiofastnet:
        transport, client = await aiofastnet.create_connection(
            loop,
            lambda: ClientProtocol(payload, duration, is_buffered, 0),
            host=host,
            port=port,
            ssl=client_ssl,
            server_hostname=host if client_ssl is not None else None
        )
    else:
        transport, client = await loop.create_connection(
            lambda: ClientProtocol(payload, duration, is_buffered, 0),
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


@asynccontextmanager
async def DatagramEchoServer(use_aiofastnet,
                             sndbuf_size: int | None = None,
                             host: str = "127.0.0.1",
                             port: int = 0):
    loop = asyncio.get_running_loop()

    if use_aiofastnet:
        transport, _protocol = await aiofastnet.create_datagram_endpoint(
            loop,
            ServerProtocol,
            local_addr=(host, port),
        )
    else:
        transport, _protocol = await loop.create_datagram_endpoint(
            ServerProtocol,
            local_addr=(host, port),
        )

    server_sock = transport.get_extra_info("socket")
    if server_sock is not None and sndbuf_size is not None:
        set_socket_sndbuf(server_sock, sndbuf_size)
    try:
        yield transport.get_extra_info("sockname")[1]
    finally:
        transport.close()


@asynccontextmanager
async def DatagramEchoClient(use_aiofastnet,
                             port: int,
                             duration: float,
                             payload: bytes,
                             sndbuf_size: int | None = None,
                             host: str = "127.0.0.1") -> ClientProtocol:
    loop = asyncio.get_running_loop()

    if use_aiofastnet:
        transport, client = await aiofastnet.create_datagram_endpoint(
            loop,
            lambda: ClientProtocol(payload, duration, False, 0, True),
            remote_addr=(host, port),
        )
    else:
        transport, client = await loop.create_datagram_endpoint(
            lambda: ClientProtocol(payload, duration, False, 0, True),
            remote_addr=(host, port),
        )

    client_sock = transport.get_extra_info("socket")
    if client_sock is not None and sndbuf_size is not None:
        set_socket_sndbuf(client_sock, sndbuf_size)
    try:
        yield client
    finally:
        transport.close()


async def run_pair(
    use_aiofastnet: bool,
    duration: float,
    payload: bytes,
    is_buffered: bool,
    server_ssl: ssl.SSLContext | None,
    client_ssl: ssl.SSLContext | None,
    barrier: threading.Barrier | asyncio.Barrier | None,
    sndbuf_size: int | None = None,
    transport_kind: str = "tcp",
) -> int:
    if transport_kind == "udp":
        server_context = DatagramEchoServer(use_aiofastnet, sndbuf_size)

        def client_context_factory(server_port):
            return DatagramEchoClient(use_aiofastnet, server_port, duration, payload, sndbuf_size)
    else:
        server_context = EchoServer(use_aiofastnet, server_ssl, is_buffered, sndbuf_size)

        def client_context_factory(server_port):
            return EchoClient(use_aiofastnet, server_port, duration, payload, client_ssl, is_buffered, sndbuf_size)

    async with server_context as server_port:
        async with client_context_factory(server_port) as client:
            if barrier is not None:
                if isinstance(barrier, asyncio.Barrier):
                    await barrier.wait()
                else:
                    barrier.wait()
            client.write_first_data()
            await client.closed
            return client.requests
