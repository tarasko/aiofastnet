#!/usr/bin/env python3
import argparse
import asyncio
import socket
import ssl
import sys
from functools import partial
from pathlib import Path

import matplotlib.pyplot as plt
import aiofastnet
from aiofastnet import create_connection

from examples.benchmark_protocol import ServerProtocol, ClientProtocol

try:
    import uvloop
except ImportError:
    uvloop = None


def _set_socket_sndbuf(sock: socket.socket, size: int) -> int:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, max(1, size // 2))
    return sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)


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


async def run_benchmark(args, loop_kind: str, use_aiofastnet: bool, transport_kind: str, msg_size: int):
    loop = asyncio.get_running_loop()
    host = "127.0.0.1"
    port = 0

    if use_aiofastnet:
        create_server = partial(aiofastnet.create_server, loop)
        create_connection = partial(create_connection, loop)
    else:
        create_server = loop.create_server
        create_connection = loop.create_connection

    payload = b"x" * msg_size

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
    for server_sock in server.sockets:
        _set_socket_sndbuf(server_sock, args.sndbuf_size)

    client_proto = ClientProtocol(payload, args.duration)
    try:
        bound_port = server.sockets[0].getsockname()[1]
        transport, _ = await create_connection(
            lambda: client_proto,
            host=host,
            port=bound_port,
            ssl=client_ssl_ctx,
        )
        client_sock = transport.get_extra_info("socket")
        if client_sock is not None:
            _set_socket_sndbuf(client_sock, args.sndbuf_size)

        try:
            await client_proto.closed
        except TimeoutError:
            transport.abort()
    finally:
        server.close()
        await server.wait_closed()

    rps = client_proto.requests / args.duration
    print(f"{transport_kind}-{loop_kind}-{'aiofastnet' if use_aiofastnet else 'native'}-{msg_size}: {rps:.2f}")

    return rps


def _plot_results(
    results: dict[str, dict[int, dict[str, float]]],
    msg_sizes: list[int],
    python_version: str,
    sndbuf_size: int,
    uvloop_version: str,
    save_plot: bool,
) -> None:
    transports = [transport for transport in ("ssl", "tcp") if transport in results]
    if not transports:
        return

    fig, axes = plt.subplots(len(transports), 1, figsize=(10, 4.5 * len(transports)))
    if len(transports) == 1:
        axes = [axes]

    variants = []
    for t, r_t in results.items():
        for mz, r_mz in r_t.items():
            variants = list(r_mz.keys())
    x_positions = list(range(len(msg_sizes)))
    width = 0.5 / len(variants)

    for ax, transport in zip(axes, transports):
        y_max = max(
            (val for mz, r_mz in results[transport].items() for
             v, val in r_mz.items()), default=0.0)
        y_limit = y_max * 1.1 if y_max > 0 else 1.0
        for i, variant in enumerate(variants):
            bars_x = [x + (i - (len(variants) - 1) / 2) * width for x in x_positions]
            bars_y = [results.get(transport, {}).get(msg_size, {}).get(variant, 0.0) for msg_size in msg_sizes]
            ax.bar(bars_x, bars_y, width=width, label=variant)
        ax.set_title(f"{transport.upper()} benchmark")
        ax.set_xlabel("Message size (bytes)")
        ax.set_xticks(x_positions)
        ax.set_xticklabels([str(msg_size) for msg_size in msg_sizes])
        ax.set_ylim(0, y_limit)
        ax.grid(axis="y", alpha=0.25)
        ax.legend(title="Backend")

    axes[0].set_ylabel("Requests per second")
    fig.suptitle(f"Echo Round-Trip Benchmark | Python {python_version} | uvloop-{uvloop_version} | SO_SNDBUF={sndbuf_size}")
    fig.tight_layout()
    if save_plot:
        output_path = Path(__file__).with_name("benchmark.png")
        fig.savefig(output_path, dpi=150)
        print(f"saved plot to {output_path}")
    else:
        plt.show()


def main():
    parser = argparse.ArgumentParser(description="Echo round-trip benchmark over loopback.")
    parser.add_argument(
        "--msg-sizes",
        default="256,8192,32768,100000",
        help="Comma-separated message sizes in bytes",
    )
    parser.add_argument(
        "--loops",
        default="asyncio,uvloop",
        help="Comma-separated event loops (asyncio,uvloop)",
    )
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
        default=65536,
        help="Socket SO_SNDBUF value to request",
    )
    parser.add_argument("--save-plot", action="store_true", help="Save plot to examples/benchmark.png")
    parser.add_argument("--no-plot", action="store_true", help="Disable plotting")
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
    uvloop_version = getattr(uvloop, "__version__", "not installed")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe_sock:
        effective_sndbuf = _set_socket_sndbuf(probe_sock, args.sndbuf_size)

    print(f"msg_sizes={','.join(str(x) for x in args.msg_sizes)}")
    print(f"loops={','.join(args.loops)}")
    print(f"duration={args.duration:.3f}s")
    print(f"python={sys.version.split()[0]}")
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
                    rps = asyncio.run(run_benchmark(args, loop_kind, use_aiofastnet, transport_kind, msg_size), loop_factory=loop_factory)
                    name = f"{loop_kind}{'+aiofastnet' if use_aiofastnet else ''}"
                    all_results[transport_kind][msg_size][name] = rps

    if not args.no_plot:
        _plot_results(
            all_results,
            args.msg_sizes,
            sys.version.split()[0],
            effective_sndbuf,
            uvloop_version,
            args.save_plot,
        )


if __name__ == "__main__":
    main()
