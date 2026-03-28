#!/usr/bin/env python3
import argparse
import asyncio
import socket
import ssl
import sys
import threading
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import aiofastnet
from examples.benchmark_protocol import ClientProtocol, ServerProtocol


HOST = "127.0.0.1"
DEFAULT_DURATION = 10.0
DEFAULT_MESSAGE_SIZE = 256
DEFAULT_PAIRS = 2


def build_ssl_contexts() -> tuple[ssl.SSLContext, ssl.SSLContext]:
    cert_file = PROJECT_ROOT / "tests" / "test.crt"
    key_file = PROJECT_ROOT / "tests" / "test.key"

    server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_ctx.load_cert_chain(certfile=str(cert_file), keyfile=str(key_file))

    client_ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE

    return server_ctx, client_ctx


def create_bound_socket() -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((HOST, 0))
    return sock


async def run_server(
    port_holder: list[int],
    ready_event: threading.Event,
    stop_event: threading.Event,
    server_ssl: ssl.SSLContext | None,
) -> None:
    loop = asyncio.get_running_loop()
    sock = create_bound_socket()
    server = await aiofastnet.create_server(
        loop,
        ServerProtocol,
        sock=sock,
        ssl=server_ssl,
    )
    try:
        port_holder.append(server.sockets[0].getsockname()[1])
        ready_event.set()
        await asyncio.to_thread(stop_event.wait)
    finally:
        server.close()
        await server.wait_closed()


async def run_client(
    port: int,
    duration: float,
    payload: bytes,
    client_ssl: ssl.SSLContext | None,
) -> int:
    loop = asyncio.get_running_loop()
    protocol = ClientProtocol(payload, duration)
    transport, _ = await aiofastnet.create_connection(
        loop,
        lambda: protocol,
        host=HOST,
        port=port,
        ssl=client_ssl,
        server_hostname=HOST if client_ssl is not None else None,
    )
    try:
        await protocol.closed
        return protocol.requests
    finally:
        transport.close()


async def run_pair(
    duration: float,
    payload: bytes,
    pair_id: int,
    server_ssl: ssl.SSLContext | None,
    client_ssl: ssl.SSLContext | None,
    *,
    use_thread_sync: bool,
) -> int:
    stop_event = threading.Event()
    ready_event = threading.Event()
    port_holder: list[int] = []

    server_task = asyncio.create_task(
        run_server(port_holder, ready_event, stop_event, server_ssl),
        name=f"benchmark-server-{pair_id}",
    )

    try:
        if use_thread_sync:
            await asyncio.to_thread(ready_event.wait)
        else:
            while not port_holder:
                await asyncio.sleep(0)

        return await run_client(port_holder[0], duration, payload, client_ssl)
    finally:
        stop_event.set()
        await server_task


async def run_single_loop(
    duration: float,
    payload: bytes,
    pairs: int,
    server_ssl: ssl.SSLContext | None,
    client_ssl: ssl.SSLContext | None,
) -> int:
    results = await asyncio.gather(
        *(
            run_pair(
                duration,
                payload,
                pair_id=index,
                server_ssl=server_ssl,
                client_ssl=client_ssl,
                use_thread_sync=False,
            )
            for index in range(pairs)
        )
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
            results[index] = asyncio.run(
                run_pair(
                    duration,
                    payload,
                    pair_id=index,
                    server_ssl=server_ssl,
                    client_ssl=client_ssl,
                    use_thread_sync=True,
                )
            )
        except BaseException as exc:
            errors[index] = exc

    threads = [
        threading.Thread(
            target=thread_main,
            args=(index,),
            name=f"echo-pair-{index}",
        )
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
        default=DEFAULT_DURATION,
        help="Benchmark duration in seconds for each client",
    )
    parser.add_argument(
        "--message-size",
        type=int,
        default=DEFAULT_MESSAGE_SIZE,
        help="Echo payload size in bytes",
    )
    parser.add_argument(
        "--pairs",
        type=int,
        default=DEFAULT_PAIRS,
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
    if args.message_size <= 0:
        parser.error("--message-size must be > 0")
    if args.pairs <= 0:
        parser.error("--pairs must be > 0")

    return args


def main() -> None:
    args = parse_args()
    payload = b"x" * args.message_size
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
        f"message_size={args.message_size} total_requests={total_requests} total_rps={total_rps:.2f}"
    )


if __name__ == "__main__":
    main()
