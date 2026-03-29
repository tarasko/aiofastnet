#!/usr/bin/env python3
import argparse
import asyncio
import concurrent.futures
import threading
from examples.utils import EchoClient, build_ssl_contexts


class ClientThread(threading.Thread):
    def __init__(self, index, args, ssl_ctx, message):
        super().__init__(name=f"echo-client-{index}",)
        self.args = args
        self.ssl_ctx = ssl_ctx
        self.message = message
        self.result = concurrent.futures.Future()

    def run(self):
        try:
            self.result.set_result(asyncio.run(self.run_async()))
        except BaseException as exc:
            self.result.set_exception(exc)

    async def run_async(self):
        async with EchoClient(
            use_aiofastnet=True,
            host=self.args.host,
            port=self.args.port,
            client_ssl=self.ssl_ctx,
            duration=self.args.duration,
            payload=self.message,
        ) as client:
            client.write_first_data()
            await client.closed
            return client.requests


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run multithreaded echo clients with one event loop per thread."
    )
    parser.add_argument("--host", default="127.0.0.1", help="Server host")
    parser.add_argument("--port", type=int, default=9001, help="Server port")
    parser.add_argument("--num-threads", type=int, default=16, help="Number of client threads to run in parallel")
    parser.add_argument("--duration", type=float, default=20.0, help="Benchmark duration in seconds for each client")
    parser.add_argument("--msg-size", type=int, default=256, help="Echo payload size in bytes")
    parser.add_argument("--use-tls", action="store_true", help="Enable TLS for client connections")
    args = parser.parse_args()

    if args.port <= 0 or args.port > 65535:
        parser.error("--port must be in range 1..65535")
    if args.num_threads <= 0:
        parser.error("--num-threads must be > 0")
    if args.duration <= 0:
        parser.error("--duration must be > 0")
    if args.msg_size <= 0:
        parser.error("--msg-size must be > 0")

    payload = b"x" * args.msg_size
    _, client_ssl = build_ssl_contexts() if args.use_tls else (None, None)

    threads = [ClientThread(index, args, client_ssl, payload)
               for index in range(args.num_threads)]

    for thread in threads:
        thread.start()

    for thread in threads:
        thread.join()

    total_requests = sum(t.result.result() for t in threads)
    total_rps = total_requests / args.duration
    print(
        f"host={args.host} port={args.port} tls={args.use_tls} "
        f"num_threads={args.num_threads} duration={args.duration:.3f}s "
        f"message_size={args.msg_size} total_requests={total_requests} total_rps={total_rps:.2f}"
    )


if __name__ == "__main__":
    main()
