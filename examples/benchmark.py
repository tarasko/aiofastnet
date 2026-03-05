#!/usr/bin/env python3
import argparse
import asyncio
import ssl
from functools import partial
from pathlib import Path
import aiofastnet


class ServerProtocol(asyncio.BufferedProtocol):
    def __init__(self, read_buf_size: int = 262144):
        self._transport = None
        self._read_buf = bytearray(read_buf_size)

    def connection_made(self, transport):
        self._transport = transport

    def get_buffer(self, sizehint):
        return self._read_buf

    def buffer_updated(self, nbytes):
        if nbytes > 0:
            # bytearray slicing creates a copy, so write is safe.
            self._transport.write(self._read_buf[:nbytes])


class ClientProtocol(asyncio.BufferedProtocol):
    WARMUP_REQUESTS = 10

    def __init__(self, payload: bytes, duration: float):
        self._payload = payload
        self._payload_size = len(payload)
        self._duration = duration
        self._loop = asyncio.get_running_loop()

        self._transport = None
        self._read_buf = bytearray(262144)
        self._received_for_reply = 0
        self._deadline = 0.0
        self._stop_handle = None
        self._stopped = False
        self._warmup_left = self.WARMUP_REQUESTS
        self._measuring = False

        self.requests = 0
        self.done = self._loop.create_future()
        self.closed = self._loop.create_future()

    def connection_made(self, transport):
        self._transport = transport
        self._transport.write(self._payload)

    def get_buffer(self, sizehint):
        return self._read_buf

    def buffer_updated(self, nbytes):
        if nbytes <= 0 or self._stopped:
            return

        self._received_for_reply += nbytes
        while self._received_for_reply >= self._payload_size:
            self._received_for_reply -= self._payload_size

            if not self._measuring:
                self._warmup_left -= 1
                if self._warmup_left <= 0:
                    self._measuring = True
                    self.requests = 0
                    self._deadline = self._loop.time() + self._duration
                    self._stop_handle = self._loop.call_at(self._deadline, self._stop)
                self._transport.write(self._payload)
                continue

            self.requests += 1
            if self._loop.time() >= self._deadline:
                self._stop()
                return

            self._transport.write(self._payload)

    def connection_lost(self, exc):
        if self._stop_handle is not None:
            self._stop_handle.cancel()
            self._stop_handle = None

        if not self.done.done():
            if exc is None:
                self.done.set_result(None)
            else:
                self.done.set_exception(exc)

        if not self.closed.done():
            if exc is None:
                self.closed.set_result(None)
            else:
                self.closed.set_exception(exc)

    def _stop(self):
        self._stopped = True
        if not self.done.done():
            self.done.set_result(None)


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


async def run_benchmark(args, backend: str, transport_kind: str):
    loop = asyncio.get_running_loop()
    host = "127.0.0.1"
    port = 0

    if backend == "asyncio":
        create_server = loop.create_server
        create_connection = loop.create_connection
    else:
        create_server = partial(aiofastnet.create_server, loop)
        create_connection = partial(aiofastnet.create_connection, loop)

    payload = b"x" * args.message_size

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

        await client_proto.done
        rps = client_proto.requests / args.duration

        print(f"{transport_kind}-{backend}: {rps:.2f}")

        transport.close()
        try:
            await asyncio.wait_for(client_proto.closed, timeout=2.0)
        except TimeoutError:
            transport.abort()
    finally:
        server.close()
        await server.wait_closed()


def parse_args():
    parser = argparse.ArgumentParser(description="Echo round-trip benchmark over loopback.")
    parser.add_argument("--message-size", type=int, default=256, help="Message size in bytes")
    parser.add_argument("--transport", default="tcp,ssl", help="Comma-separated transport types (tcp,ssl)")
    parser.add_argument("--backend", default="asyncio,aiofastnet", help="Comma-separated backends (asyncio,aiofastnet)")
    parser.add_argument("--duration", type=float, default=2.0, help="Benchmark duration in seconds" )
    args = parser.parse_args()

    if args.message_size <= 0:
        parser.error("--message-size must be > 0")
    if args.duration <= 0:
        parser.error("--duration must be > 0")

    args.transports = args.transport.split(",")
    args.backends = args.backend.split(",")

    return args


async def run_all_benchmarks(args):
    print(f"message_size={args.message_size}")
    print(f"duration={args.duration:.3f}s")

    for transport_kind in args.transports:
        for backend in args.backends:
            await run_benchmark(args, backend, transport_kind)


def main():
    asyncio.run(run_all_benchmarks(parse_args()))


if __name__ == "__main__":
    main()
