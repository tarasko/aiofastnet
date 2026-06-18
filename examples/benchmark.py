#!/usr/bin/env python3
import argparse
import asyncio
import logging
import math
import socket
import sys
from logging import basicConfig
from pathlib import Path

import matplotlib.pyplot as plt

import aiofastnet
from examples.utils import build_ssl_contexts, run_pair, set_socket_sndbuf

try:
    import uvloop
except ImportError:
    uvloop = None


async def run_benchmark(args, loop_kind: str, use_aiofastnet: bool, transport_kind: str, msg_size: int):
    if args.asyncio_debug:
        asyncio.get_running_loop().set_debug(True)

    payload = b"x" * msg_size

    server_ssl_ctx, client_ssl_ctx = build_ssl_contexts(enable_ktls=False) \
        if transport_kind == "ssl" else (None, None)

    requests = await run_pair(
        use_aiofastnet,
        args.duration,
        payload,
        not args.simple,
        server_ssl_ctx,
        client_ssl_ctx,
        None,
        args.sndbuf_size,
    )
    rps = requests/args.duration
    print(f"{transport_kind}-{loop_kind}-{'aiofastnet' if use_aiofastnet else 'native'}-{msg_size}: {rps:.2f}")

    return rps


def _plot_results(
    results: dict[str, dict[int, dict[str, float]]],
    msg_sizes: list[int],
    python_version: str,
    aiofastnet_version: str,
    sndbuf_size: int,
    uvloop_version: str,
    save_plot: bool,
) -> None:
    transports = [transport for transport in ("ssl", "tcp") if transport in results]
    if not transports:
        return

    variants = _collect_variants(results)
    if not variants:
        return

    fig, axes = _plot_absolute_results(results, transports, msg_sizes, variants)
    fig.suptitle(
        f"Echo Round-Trip Benchmark | Python {python_version}\naiofastnet-{aiofastnet_version} | "
        f"uvloop-{uvloop_version} | SO_SNDBUF={sndbuf_size}"
    )
    fig.tight_layout()

    if save_plot:
        output_path = Path(__file__).with_name("benchmark.png")
        fig.savefig(output_path, dpi=150)
        print(f"saved plot to {output_path}")

    heatmap_fig = _plot_speedup_heatmap(results, transports, msg_sizes)
    if heatmap_fig is not None:
        heatmap_fig.suptitle("aiofastnet speedup over native")
        heatmap_fig.tight_layout()
        if save_plot:
            output_path = Path(__file__).with_name("benchmark_speedup.png")
            heatmap_fig.savefig(output_path, dpi=150)
            print(f"saved plot to {output_path}")
    else:
        print("skipped speedup heatmap: need both native and aiofastnet results for at least one loop")

    if not save_plot:
        plt.show()


def _collect_variants(results: dict[str, dict[int, dict[str, float]]]) -> list[str]:
    preferred = ["asyncio", "asyncio+aiofastnet", "uvloop", "uvloop+aiofastnet"]
    seen = set()
    variants = []

    for variant in preferred:
        if any(variant in by_variant for by_msg in results.values() for by_variant in by_msg.values()):
            variants.append(variant)
            seen.add(variant)

    for by_msg in results.values():
        for by_variant in by_msg.values():
            for variant in by_variant:
                if variant not in seen:
                    variants.append(variant)
                    seen.add(variant)

    return variants


def _plot_absolute_results(
    results: dict[str, dict[int, dict[str, float]]],
    transports: list[str],
    msg_sizes: list[int],
    variants: list[str],
):
    rows = len(msg_sizes)
    cols = len(transports)
    fig_width = max(6.0, 3.6 * cols)
    fig_height = max(3.2, 2.8 * rows)
    fig, axes = plt.subplots(rows, cols, figsize=(fig_width, fig_height), squeeze=False)

    for row, msg_size in enumerate(msg_sizes):
        for col, transport in enumerate(transports):
            ax = axes[row][col]
            values_by_variant = results.get(transport, {}).get(msg_size, {})
            local_variants = [variant for variant in variants if variant in values_by_variant]
            values = [values_by_variant[variant] for variant in local_variants]

            if values:
                bars = ax.bar(range(len(local_variants)), values, color=_variant_colors(local_variants))
                ax.set_ylim(0, max(values) * 1.18)
                _annotate_bars(ax, bars, values)
            else:
                ax.set_ylim(0, 1)
                ax.text(0.5, 0.5, "no data", ha="center", va="center", transform=ax.transAxes)

            ax.set_title(f"{transport.upper()}, {_format_msg_size(msg_size)}")
            ax.set_xticks(range(len(local_variants)))
            ax.set_xticklabels([_format_variant(variant) for variant in local_variants], rotation=25, ha="right")
            ax.grid(axis="y", alpha=0.25)

            if col == 0:
                ax.set_ylabel("round-trips/sec")

    return fig, axes


def _plot_speedup_heatmap(
    results: dict[str, dict[int, dict[str, float]]],
    transports: list[str],
    msg_sizes: list[int],
):
    row_labels = []
    heatmap_data = []

    for transport in transports:
        for loop_kind in ("asyncio", "uvloop"):
            native_key = loop_kind
            aiofastnet_key = f"{loop_kind}+aiofastnet"
            row = []
            has_pair = False

            for msg_size in msg_sizes:
                values = results.get(transport, {}).get(msg_size, {})
                native = values.get(native_key)
                aiofastnet = values.get(aiofastnet_key)
                if native and aiofastnet:
                    row.append(aiofastnet / native)
                    has_pair = True
                else:
                    row.append(math.nan)

            if has_pair:
                row_labels.append(f"{transport.upper()} {loop_kind}")
                heatmap_data.append(row)

    if not heatmap_data:
        return None

    fig_width = max(6.0, 1.5 * len(msg_sizes) + 3.0)
    fig_height = max(2.6, 0.55 * len(row_labels) + 1.6)
    fig, ax = plt.subplots(figsize=(fig_width, fig_height))
    finite_values = [value for row in heatmap_data for value in row if not math.isnan(value)]
    vmin = min(1.0, min(finite_values))
    vmax = max(finite_values)
    if vmin == vmax:
        vmax = vmin + 0.01
    image = ax.imshow(heatmap_data, cmap="YlGn", aspect="auto", vmin=vmin, vmax=vmax)

    ax.set_xticks(range(len(msg_sizes)))
    ax.set_xticklabels([_format_msg_size(msg_size) for msg_size in msg_sizes])
    ax.set_yticks(range(len(row_labels)))
    ax.set_yticklabels(row_labels)

    for row_idx, row in enumerate(heatmap_data):
        for col_idx, value in enumerate(row):
            if math.isnan(value):
                label = "-"
            else:
                label = f"{value:.2f}x"
            ax.text(col_idx, row_idx, label, ha="center", va="center", color="black")

    fig.colorbar(image, ax=ax, label="speedup")
    return fig


def _format_msg_size(size: int) -> str:
    if size >= 1024 and size % 1024 == 0:
        return f"{size // 1024} KiB"
    if size >= 1000:
        return f"{size / 1000:g} KB"
    return f"{size} B"


def _format_variant(variant: str) -> str:
    return variant.replace("+", "\n+")


def _variant_colors(variants: list[str]) -> list[str]:
    colors = {
        "asyncio": "#4c78a8",
        "asyncio+aiofastnet": "#72b7b2",
        "uvloop": "#f58518",
        "uvloop+aiofastnet": "#54a24b",
    }
    return [colors.get(variant, "#b279a2") for variant in variants]


def _format_rps(value: float) -> str:
    if value >= 1000:
        return f"{value / 1000:.1f}k"
    return f"{value:.0f}"


def _annotate_bars(ax, bars, values: list[float]) -> None:
    y_max = max(values)
    offset = y_max * 0.025 if y_max > 0 else 0.1
    for bar, value in zip(bars, values):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + offset,
            _format_rps(value),
            ha="center",
            va="bottom",
            fontsize=8,
        )


def main():
    parser = argparse.ArgumentParser(description="Echo round-trip benchmark over loopback.")
    parser.add_argument("--msg-sizes", default="256,8192,32768,100000", help="Comma-separated message sizes in bytes")
    parser.add_argument("--loops", default="asyncio,uvloop", help="Comma-separated event loops (asyncio,uvloop)")
    parser.add_argument(
        "--variant",
        default="native,aiofastnet",
        help="Comma-separated backend variants (native,aiofastnet)",
    )
    parser.add_argument("--transport", default="ssl,tcp", help="Comma-separated transport types (tcp,ssl)")
    parser.add_argument("--duration", type=float, default=5.0, help="Benchmark duration in seconds" )
    parser.add_argument(
        "--sndbuf-size",
        type=int,
        default=256*1024,
        help="Socket SO_SNDBUF value to request",
    )
    parser.add_argument("--simple", action="store_true", help="Use simple protocol instead of buffered")
    parser.add_argument("--save-plot", action="store_true", help="Save plot to examples/benchmark.png")
    parser.add_argument("--no-plot", action="store_true", help="Disable plotting")
    parser.add_argument("--asyncio-debug", action="store_true", help="Enable loop debug")
    args = parser.parse_args()

    if args.duration <= 0:
        parser.error("--duration must be > 0")
    if args.sndbuf_size <= 0:
        parser.error("--sndbuf-size must be > 0")


    args.transports = [transport.strip() for transport in args.transport.split(",") if transport.strip()]
    args.loops = [loop_name.strip() for loop_name in args.loops.split(",") if loop_name.strip()]
    args.variants = [kind.strip() for kind in args.variant.split(",") if kind.strip()]
    args.msg_sizes = [int(part.strip()) for part in args.msg_sizes.split(",") if part.strip()]
    if any(msg_size <= 0 for msg_size in args.msg_sizes):
        parser.error("--msg-sizes must contain integers > 0")

    SUPPORTED_LOOPS = ["asyncio", "uvloop"]
    unknown_loops = [loop_name for loop_name in args.loops if loop_name not in SUPPORTED_LOOPS]
    if unknown_loops:
        parser.error(f"Unknown --loops values: {unknown_loops}. Valid: {SUPPORTED_LOOPS}")

    if any(loop_name == "uvloop" for loop_name in args.loops) and uvloop is None:
        parser.error("uvloop variant requested but uvloop is not installed")

    all_results: dict[str, dict[int, dict[str, float]]] = {}
    aiofastnet_version = getattr(aiofastnet, "__version__", "unknown")
    uvloop_version = getattr(uvloop, "__version__", "not installed")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe_sock:
        effective_sndbuf = set_socket_sndbuf(probe_sock, args.sndbuf_size)

    print(f"msg_sizes={','.join(str(x) for x in args.msg_sizes)}")
    print(f"loops={','.join(args.loops)}")
    print(f"duration={args.duration:.3f}s")
    print(f"python={sys.version.split()[0]}")
    print(f"aiofastnet={aiofastnet_version}")
    print(f"uvloop={uvloop_version}")
    print(f"SNDBUF={effective_sndbuf})")

    for transport_kind in args.transports:
        all_results[transport_kind] = {}
        for msg_size in args.msg_sizes:
            all_results[transport_kind][msg_size] = {}
            for loop_kind in args.loops:
                for variant in args.variants:
                    use_aiofastnet = variant == "aiofastnet"
                    loop_factory = uvloop.Loop if loop_kind == "uvloop" else asyncio.SelectorEventLoop
                    rps = asyncio.run(
                        run_benchmark(args, loop_kind, use_aiofastnet, transport_kind, msg_size),
                        loop_factory=loop_factory,
                    )
                    name = f"{loop_kind}{'+aiofastnet' if use_aiofastnet else ''}"
                    all_results[transport_kind][msg_size][name] = rps

    if not args.no_plot:
        _plot_results(
            all_results,
            args.msg_sizes,
            sys.version.split()[0],
            aiofastnet_version,
            effective_sndbuf,
            uvloop_version,
            args.save_plot,
        )


if __name__ == "__main__":
    basicConfig(level=logging.WARNING)
    main()
