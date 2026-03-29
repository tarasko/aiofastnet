#!/usr/bin/env python3

# Make 8 secure client-server pairs running on the same event loop
# python -m examples.benchmark_threaded --pairs 8 --use-tls --no-thread
# Result: mode=single-loop tls=True pairs=8 duration=2.000s message_size=256 total_requests=57413 total_rps=28706.50

# Make 8 secure client-server pairs, each pair running in its own loop in its own thread.
# GIL is disabled, all cores are fully utilized
# python -X gil=0 -m examples.benchmark_threaded --pairs 8 --use-tls
# Result: mode=threaded tls=True pairs=8 duration=2.000s message_size=256 total_requests=166993 total_rps=83496.50

# Make 8 secure client-server pairs, each pair running in its own loop in its own thread.
# GIL is enabled and it kills all performance.
# python -X gil=1 -m examples.benchmark_threaded --pairs 64 --use-tls
# Result: mode=threaded tls=True pairs=8 duration=2.000s message_size=256 total_requests=29511 total_rps=14755.50

import argparse
import asyncio
import ssl
import threading

from .utils import build_ssl_contexts, run_pair


async def run_single_loop(
    duration: float,
    payload: bytes,
    pairs: int,
    server_ssl: ssl.SSLContext | None,
    client_ssl: ssl.SSLContext | None,
) -> int:
    barrier = asyncio.Barrier(pairs)
    results = await asyncio.gather(
        *(run_pair(True, duration, payload, server_ssl, client_ssl, barrier)
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
    barrier = threading.Barrier(pairs)

    def thread_main(index: int) -> None:
        try:
            results[index] = asyncio.run(
                run_pair(True, duration, payload, server_ssl, client_ssl, barrier))
        except BaseException as exc:
            errors[index] = exc

    threads = [
        threading.Thread(target=thread_main, args=(index,), name=f"echo-pair-{index}")
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
        default=2.0,
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
    server_ssl, client_ssl = (
        build_ssl_contexts() if args.use_tls else (None, None))

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
