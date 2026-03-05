#!/usr/bin/env python3
import argparse
import asyncio
import ssl
from functools import partial
from pathlib import Path

import matplotlib.pyplot as plt
import aiofastnet

from examples.benchmark_protocol import ServerProtocol, ClientProtocol

try:
    import uvloop
except ImportError:
    uvloop = None


VARIANTS = {
    "asyncio": ("asyncio", False),
    "asyncio+aiofastnet": ("asyncio", True),
    "uvloop": ("uvloop", False),
    "uvloop+aiofastnet": ("uvloop", True),
}


def _build_ssl_contexts() -> tuple[ssl.SSLContext, ssl.SSLContext]:
    project_root = Path(__file__).resolve().parents[1]
    cert_file = project_root / "tests" / "test.crt"
    key_file = project_root / "tests" / "test.key"

    if not cert_file.exists() or not key_file.exists():
        raise FileNotFoundError(
            f"Missing cert or key: cert={cert_file}, key={key_file}"
        )

    server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_ctx.load_cert_chain(certfile=str(cert_file), keyfile=str(key_file))

    client_ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_NONE
    return server_ctx, client_ctx


async def run_benchmark(args, variant: str, use_aiofastnet: bool, transport_kind: str):
    loop = asyncio.get_running_loop()
    host = "127.0.0.1"
    port = 0

    if use_aiofastnet:
        create_server = partial(aiofastnet.create_server, loop)
        create_connection = partial(aiofastnet.create_connection, loop)
    else:
        create_server = loop.create_server
        create_connection = loop.create_connection

    payload = b"x" * args.msg_size

    server_ssl_ctx = None
    client_ssl_ctx = None
    if transport_kind == "ssl":
        server_ssl_ctx, client_ssl_ctx = _build_ssl_contexts()

    server = await create_server(
        ServerProtocol,
        host=host,
        port=port,
        ssl=server_ssl_ctx,
    )

    client_proto = ClientProtocol(payload, args.duration)
    try:
        bound_port = server.sockets[0].getsockname()[1]
        transport, _ = await create_connection(
            lambda: client_proto,
            host=host,
            port=bound_port,
            ssl=client_ssl_ctx,
        )

        try:
            await client_proto.closed
        except TimeoutError:
            transport.abort()
    finally:
        server.close()
        await server.wait_closed()

    rps = client_proto.requests / args.duration
    print(f"{transport_kind}-{variant}: {rps:.2f}")

    return rps


def parse_args():
    parser = argparse.ArgumentParser(description="Echo round-trip benchmark over loopback.")
    parser.add_argument("--msg-size", type=int, default=256, help="Message size in bytes")
    parser.add_argument("--transport", default="tcp,ssl", help="Comma-separated transport types (tcp,ssl)")
    parser.add_argument(
        "--variant",
        default="asyncio,asyncio+aiofastnet,uvloop,uvloop+aiofastnet",
        help="Comma-separated variants",
    )
    parser.add_argument("--duration", type=float, default=10.0, help="Benchmark duration in seconds" )
    parser.add_argument("--no-plot", action="store_true", help="Disable plotting")
    args = parser.parse_args()

    if args.msg_size <= 0:
        parser.error("--msg-size must be > 0")
    if args.duration <= 0:
        parser.error("--duration must be > 0")

    args.transports = args.transport.split(",")
    args.variants = args.variant.split(",")

    unknown_variants = [variant for variant in args.variants if variant not in VARIANTS]
    if unknown_variants:
        parser.error(f"Unknown --variant values: {unknown_variants}. Valid: {list(VARIANTS)}")

    if any(VARIANTS[variant][0] == "uvloop" for variant in args.variants) and uvloop is None:
        parser.error("uvloop variant requested but uvloop is not installed")

    return args


async def run_all_benchmarks(args, variant: str, use_aiofastnet: bool):
    results: dict[str, float] = {}

    for transport_kind in args.transports:
        rps = await run_benchmark(args, variant, use_aiofastnet, transport_kind)
        results[transport_kind] = rps

    return results


def _plot_results(results: dict[str, dict[str, float]], variants: list[str]) -> None:
    transports = ["tcp", "ssl"]
    width = 0.05
    x_positions = list(range(len(transports)))

    fig, ax = plt.subplots(figsize=(8, 5))
    for i, variant in enumerate(variants):
        bars_x = [x + (i - (len(variants) - 1) / 2) * width for x in x_positions]
        bars_y = [results.get(transport, {}).get(variant, 0.0) for transport in transports]
        ax.bar(bars_x, bars_y, width=width, label=variant)

    ax.set_title("Echo Round-Trip Benchmark")
    ax.set_xlabel("Transport")
    ax.set_ylabel("Requests per second")
    ax.set_xticks(x_positions)
    ax.set_xticklabels(transports)
    ax.legend(title="Backend")
    ax.grid(axis="y", alpha=0.25)
    fig.tight_layout()
    plt.show()


def main():
    args = parse_args()
    all_results: dict[str, dict[str, float]] = {}

    print(f"msg_size={args.msg_size}")
    print(f"duration={args.duration:.3f}s")

    for transport_kind in args.transports:
        all_results[transport_kind] = {}
        for variant in args.variants:
            loop_kind, use_aiofastnet = VARIANTS[variant]
            if loop_kind == "uvloop":
                asyncio.set_event_loop(uvloop.Loop())
            else:
                asyncio.set_event_loop(asyncio.SelectorEventLoop())

            rps = asyncio.run(run_benchmark(args, variant, use_aiofastnet, transport_kind))
            all_results[transport_kind][variant] = rps

    if not args.no_plot:
        _plot_results(all_results, args.variants)


if __name__ == "__main__":
    main()
