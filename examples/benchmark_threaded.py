#!/usr/bin/env python3

import argparse
import asyncio
import ssl
import sys
import threading
from collections.abc import Callable
from pathlib import Path
import psutil

import matplotlib.pyplot as plt
from matplotlib.ticker import ScalarFormatter

import aiofastnet
from examples.utils import build_ssl_contexts, run_pair

try:
    import uvloop
except ImportError:
    uvloop = None


LoopFactory = Callable[[], asyncio.AbstractEventLoop]


async def run_single_loop(
    duration: float,
    payload: bytes,
    pairs: int,
    use_aiofastnet: bool,
    server_ssl: ssl.SSLContext | None,
    client_ssl: ssl.SSLContext | None,
) -> int:
    barrier = asyncio.Barrier(pairs)
    results = await asyncio.gather(
        *(
            run_pair(use_aiofastnet, duration, payload, True, server_ssl, client_ssl, barrier)
            for _ in range(pairs)
        )
    )
    return sum(results)


def run_with_loop_factory(coro, loop_factory: LoopFactory):
    loop = loop_factory()
    try:
        asyncio.set_event_loop(loop)
        return loop.run_until_complete(coro)
    finally:
        try:
            loop.run_until_complete(loop.shutdown_asyncgens())
            loop.run_until_complete(loop.shutdown_default_executor())
        finally:
            asyncio.set_event_loop(None)
            loop.close()


def run_threaded(
    duration: float,
    payload: bytes,
    pairs: int,
    loop_factory: LoopFactory,
    use_aiofastnet: bool,
    server_ssl: ssl.SSLContext | None,
    client_ssl: ssl.SSLContext | None,
) -> int:
    results = [0] * pairs
    errors: list[BaseException | None] = [None] * pairs
    barrier = threading.Barrier(pairs)

    def thread_main(index: int) -> None:
        try:
            results[index] = run_with_loop_factory(
                run_pair(use_aiofastnet, duration, payload, True, server_ssl, client_ssl, barrier),
                loop_factory,
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
    single_loop_results: dict[str, list[float]],
    threaded_results: dict[str, list[float]],
    duration: float,
    msg_size: int,
    use_tls: bool,
    save_plot: bool,
    logical_cpus: int,
    physical_cores: int,
) -> None:
    fig, (threaded_ax, single_ax) = plt.subplots(2, 1, figsize=(10, 8), sharex=True)
    colors = plt.rcParams["axes.prop_cycle"].by_key()["color"]
    handles = []
    labels = []

    for index, (label, values) in enumerate(single_loop_results.items()):
        color = colors[index % len(colors)]
        (line,) = threaded_ax.plot(pairs_list, threaded_results[label], marker="o", linewidth=2, color=color, label=label)
        single_ax.plot(pairs_list, values, marker="o", linewidth=2, color=color, label=label)
        handles.append(line)
        labels.append(label)

    threaded_ax.set_title("One event loop per thread")
    single_ax.set_title("Single event loop")
    single_ax.set_xlabel("Number of client/server pairs")

    for ax in (single_ax, threaded_ax):
        ax.set_ylabel("Requests per second")
        ax.set_xscale("log", base=2)
        ax.set_xticks(pairs_list)
        ax.xaxis.set_major_formatter(ScalarFormatter())
        ax.yaxis.set_major_formatter(ScalarFormatter())
        ax.grid(alpha=0.25)

    fig.suptitle(
        f"{'SSL' if use_tls else 'TCP'} Echo Benchmark | Python {sys.version.split()[0]} | msg_size={msg_size}\n"
        f"physical cores={physical_cores} | logical cores={logical_cpus}"
    )
    fig.legend(handles, labels, loc="lower center", ncol=min(len(labels), 4))
    fig.tight_layout(rect=(0, 0.06, 1, 0.94))
    if save_plot:
        suffix = "tls" if use_tls else "tcp"
        output_path = Path(__file__).with_name(f"benchmark_threaded_{suffix}.png")
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
        "--loops",
        default="asyncio,uvloop",
        help="Comma-separated event loops, any of (asyncio,uvloop)",
    )
    parser.add_argument(
        "--variant",
        default="native,aiofastnet",
        help="Comma-separated backend variants, any of (native,aiofastnet)",
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
        help="Save plot to examples/benchmark_threaded_tcp.png or examples/benchmark_threaded_tls.png",
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

    supported_loops = ["asyncio", "uvloop"]
    supported_variants = ["native", "aiofastnet"]
    args.loops = [loop_name.strip() for loop_name in args.loops.split(",") if loop_name.strip()]
    args.variants = [variant.strip() for variant in args.variant.split(",") if variant.strip()]

    unknown_loops = [loop_name for loop_name in args.loops if loop_name not in supported_loops]
    if unknown_loops:
        parser.error(f"Unknown --loops values: {unknown_loops}. Valid: {supported_loops}")
    unknown_variants = [variant for variant in args.variants if variant not in supported_variants]
    if unknown_variants:
        parser.error(f"Unknown --variant values: {unknown_variants}. Valid: {supported_variants}")
    if any(loop_name == "uvloop" for loop_name in args.loops) and uvloop is None:
        parser.error("uvloop requested but uvloop is not installed")

    return args


def make_loop_factory(loop_kind: str) -> LoopFactory:
    if loop_kind == "uvloop":
        return uvloop.new_event_loop
    return asyncio.new_event_loop


def make_result_label(loop_kind: str, variant: str) -> str:
    if variant == "native":
        return loop_kind
    return f"{loop_kind}+{variant}"


def main() -> None:
    args = parse_args()
    payload = b"x" * args.msg_size
    server_ssl, client_ssl = build_ssl_contexts() if args.use_tls else (None, None)
    logical_cpus = psutil.cpu_count(logical=True)
    physical_cores = psutil.cpu_count(logical=False)

    single_loop_results: dict[str, list[float]] = {}
    threaded_results: dict[str, list[float]] = {}
    aiofastnet_version = aiofastnet.__version__
    uvloop_version = getattr(uvloop, "__version__", "not installed")

    print(f"pairs={','.join(str(pairs) for pairs in args.pairs_list)}")
    print(f"loops={','.join(args.loops)}")
    print(f"variants={','.join(args.variants)}")
    print(f"duration={args.duration:.3f}s")
    print(f"msg_size={args.msg_size}")
    print(f"tls={args.use_tls}")
    print(f"python={sys.version.split()[0]}")
    print(f"aiofastnet={aiofastnet_version}")
    print(f"uvloop={uvloop_version}")

    for loop_kind in args.loops:
        loop_factory = make_loop_factory(loop_kind)
        for variant in args.variants:
            use_aiofastnet = variant == "aiofastnet"
            label = make_result_label(loop_kind, variant)
            single_loop_results[label] = []
            threaded_results[label] = []

            for pairs in args.pairs_list:
                single_loop_requests = run_with_loop_factory(
                    run_single_loop(
                        args.duration,
                        payload,
                        pairs,
                        use_aiofastnet,
                        server_ssl,
                        client_ssl,
                    ),
                    loop_factory,
                )
                single_loop_value = single_loop_requests / args.duration
                single_loop_results[label].append(single_loop_value)
                print(f"{label} single-loop pairs={pairs}: {single_loop_value:.2f} rps")

                threaded_requests = run_threaded(
                    args.duration,
                    payload,
                    pairs,
                    loop_factory,
                    use_aiofastnet,
                    server_ssl,
                    client_ssl,
                )
                threaded_value = threaded_requests / args.duration
                threaded_results[label].append(threaded_value)
                print(f"{label} threaded pairs={pairs}: {threaded_value:.2f} rps")

    if not args.no_plot:
        plot_results(
            args.pairs_list,
            single_loop_results,
            threaded_results,
            args.duration,
            args.msg_size,
            args.use_tls,
            args.save_plot,
            logical_cpus,
            physical_cores,
        )


if __name__ == "__main__":
    main()
