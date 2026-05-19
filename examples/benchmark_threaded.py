#!/usr/bin/env python3

import argparse
import asyncio
import ssl
import sys
import threading
from pathlib import Path
import psutil

import matplotlib.pyplot as plt
from matplotlib.ticker import ScalarFormatter

from examples.utils import build_ssl_contexts, run_pair


async def run_single_loop(
    duration: float,
    payload: bytes,
    pairs: int,
    server_ssl: ssl.SSLContext | None,
    client_ssl: ssl.SSLContext | None,
) -> int:
    barrier = asyncio.Barrier(pairs)
    results = await asyncio.gather(
        *(
            run_pair(True, duration, payload, server_ssl, client_ssl, barrier)
            for _ in range(pairs)
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
    barrier = threading.Barrier(pairs)

    def thread_main(index: int) -> None:
        try:
            results[index] = asyncio.run(
                run_pair(True, duration, payload, server_ssl, client_ssl, barrier)
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


def plot_results(
    pairs_list: list[int],
    single_loop_rps: list[float],
    threaded_rps: list[float],
    duration: float,
    msg_size: int,
    use_tls: bool,
    save_plot: bool,
    logical_cpus: int,
    physical_cores: int,
) -> None:
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.plot(pairs_list, single_loop_rps, marker="o", linewidth=2, label="single-loop")
    ax.plot(pairs_list, threaded_rps, marker="o", linewidth=2, label="thread+loop per server/client")
    ax.set_title("Free-threaded Python Scaling Benchmark")
    ax.set_xlabel("Number of client/server pairs")
    ax.set_ylabel("Requests per second")
    ax.set_xscale("log", base=2)
    ax.set_xticks(pairs_list)
    ax.xaxis.set_major_formatter(ScalarFormatter())
    ax.grid(alpha=0.25)
    ax.legend()
    fig.suptitle(
        f"Echo benchmark | Python {sys.version.split()[0]}\n"
        f"duration={duration:.3f}s | msg_size={msg_size} | tls={use_tls}\n"
        f"physical cores={physical_cores} | logical cores={logical_cpus}"
    )
    fig.tight_layout()
    if save_plot:
        output_path = Path(__file__).with_name("benchmark_threaded.png")
        fig.savefig(output_path, dpi=150)
        print(f"saved plot to {output_path}")
    else:
        plt.show()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare single-loop and multithreaded echo scaling."
    )
    parser.add_argument(
        "--pairs",
        default="1,2,4,8,16,32",
        help="Comma-separated numbers of client/server pairs to benchmark",
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
        "--use-tls",
        action="store_true",
        help="Use TLS for all client/server connections",
    )
    parser.add_argument(
        "--save-plot",
        action="store_true",
        help="Save plot to examples/benchmark_threaded.png",
    )
    parser.add_argument(
        "--no-plot",
        action="store_true",
        help="Disable plotting",
    )
    args = parser.parse_args()

    if args.duration <= 0:
        parser.error("--duration must be > 0")
    if args.msg_size <= 0:
        parser.error("--msg-size must be > 0")

    args.pairs_list = [int(part.strip()) for part in args.pairs.split(",") if part.strip()]
    if not args.pairs_list:
        parser.error("--pairs must contain at least one integer")
    if any(pairs <= 0 for pairs in args.pairs_list):
        parser.error("--pairs must contain integers > 0")

    return args


def main() -> None:
    args = parse_args()
    payload = b"x" * args.msg_size
    server_ssl, client_ssl = build_ssl_contexts() if args.use_tls else (None, None)
    logical_cpus = psutil.cpu_count(logical=True)
    physical_cores = psutil.cpu_count(logical=False)

    single_loop_rps: list[float] = []
    threaded_rps: list[float] = []

    print(f"pairs={','.join(str(pairs) for pairs in args.pairs_list)}")
    print(f"duration={args.duration:.3f}s")
    print(f"msg_size={args.msg_size}")
    print(f"tls={args.use_tls}")
    print(f"python={sys.version.split()[0]}")

    for pairs in args.pairs_list:
        single_loop_requests = asyncio.run(
            run_single_loop(
                args.duration,
                payload,
                pairs,
                server_ssl,
                client_ssl,
            )
        )
        single_loop_value = single_loop_requests / args.duration
        single_loop_rps.append(single_loop_value)
        print(f"single-loop pairs={pairs}: {single_loop_value:.2f} rps")

        threaded_requests = run_threaded(
            args.duration,
            payload,
            pairs,
            server_ssl,
            client_ssl,
        )
        threaded_value = threaded_requests / args.duration
        threaded_rps.append(threaded_value)
        print(f"threaded pairs={pairs}: {threaded_value:.2f} rps")

    if not args.no_plot:
        plot_results(
            args.pairs_list,
            single_loop_rps,
            threaded_rps,
            args.duration,
            args.msg_size,
            args.use_tls,
            args.save_plot,
            logical_cpus,
            physical_cores,
        )


if __name__ == "__main__":
    main()
