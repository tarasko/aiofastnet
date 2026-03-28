#!/usr/bin/env python3
import argparse
import asyncio
import ssl
import sys
from threading import Thread
from contextlib import asynccontextmanager
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import aiofastnet
from examples.benchmark_protocol import ClientProtocol, ServerProtocol


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
async def EchoServer(server_ssl: ssl.SSLContext | None):
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
async def EchoClient(port: int, duration: float, payload: bytes, client_ssl: ssl.SSLContext | None) -> ClientProtocol:
    loop = asyncio.get_running_loop()
    protocol = ClientProtocol(payload, duration)
    transport, client = await aiofastnet.create_connection(
        loop,
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
) -> int:
    async with EchoServer(server_ssl) as server_port:
        async with EchoClient(server_port, duration, payload, client_ssl) as client:
            await client.closed
            return client.requests


async def run_single_loop(
    duration: float,
    payload: bytes,
    pairs: int,
    server_ssl: ssl.SSLContext | None,
    client_ssl: ssl.SSLContext | None,
) -> int:
    results = await asyncio.gather(
        *(run_pair(duration, payload, server_ssl, client_ssl)
          for _ in range(pairs))
    )
    return sum(results)


def run_threaded(
    duration: float,
    payload: bytes,
    pairs: int,
    server_ssl: ssl.SSLContext | None,
    client_ssl: ssl.SSLContext | None,
) -> int:
    results = [0] * pairs
    errors: list[BaseException | None] = [None] * pairs

    def thread_main(index: int) -> None:
        try:
            results[index] = asyncio.run(run_pair(duration, payload, server_ssl, client_ssl))
        except BaseException as exc:
            errors[index] = exc

    threads = [
        Thread(target=thread_main, args=(index,), name=f"echo-pair-{index}")
        for index in range(pairs)
    ]

    for thread in threads:
        thread.start()

    for thread in threads:
        thread.join()

    for exc in errors:
        if exc is not None:
            raise exc

    return sum(results)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Free-threading echo benchmark with two dedicated server/client pairs."
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=10.0,
        help="Benchmark duration in seconds for each client",
    )
    parser.add_argument(
        "--msg-size",
        type=int,
        default=256,
        help="Echo payload size in bytes",
    )
    parser.add_argument(
        "--pairs",
        type=int,
        default=8,
        help="Number of client/server pairs to run",
    )
    parser.add_argument(
        "--no-threads",
        action="store_true",
        help="Run all client/server pairs on the main event loop",
    )
    parser.add_argument(
        "--use-tls",
        action="store_true",
        help="Use TLS for all client/server connections",
    )
    args = parser.parse_args()

    if args.duration <= 0:
        parser.error("--duration must be > 0")
    if args.msg_size <= 0:
        parser.error("--msg-size must be > 0")
    if args.pairs <= 0:
        parser.error("--pairs must be > 0")

    return args


def main() -> None:
    args = parse_args()
    payload = b"x" * args.msg_size
    server_ssl, client_ssl = (build_ssl_contexts() if args.use_tls else (None, None))

    if args.no_threads:
        total_requests = asyncio.run(
            run_single_loop(
                args.duration,
                payload,
                args.pairs,
                server_ssl,
                client_ssl,
            )
        )
        mode = "single-loop"
    else:
        total_requests = run_threaded(
            args.duration,
            payload,
            args.pairs,
            server_ssl,
            client_ssl,
        )
        mode = "threaded"

    total_rps = total_requests / args.duration
    print(
        f"mode={mode} tls={args.use_tls} pairs={args.pairs} duration={args.duration:.3f}s "
        f"message_size={args.msg_size} total_requests={total_requests} total_rps={total_rps:.2f}"
    )


if __name__ == "__main__":
    main()
