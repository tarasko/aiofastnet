"""Multithreaded echo server example.

Starts one event loop per thread and binds all server sockets to the same port
with ``reuse_port=True`` so incoming connections are distributed across worker
threads by the kernel.
"""

import argparse
import asyncio
import concurrent.futures
import threading
from logging import getLogger, basicConfig, INFO
from examples.utils import EchoServer, build_ssl_contexts


_logger = getLogger(__name__)


class ServerThread(threading.Thread):
    def __init__(self, index, args, ssl_ctx, stop_event: threading.Event):
        super().__init__(name=f"echo-server-{index}")
        self.args = args
        self.ssl_ctx = ssl_ctx
        self.stop_event = stop_event
        self.result = concurrent.futures.Future()

    async def run_async(self):
        async with EchoServer(
                use_aiofastnet=True,
                server_ssl=self.ssl_ctx,
                host=self.args.host,
                port=self.args.port,
                reuse_port=True,
        ) as bound_port:
            _logger.info("listening thread=%s, host=%s, port=%s",
                threading.current_thread().name,
                self.args.host, bound_port,
            )
            await asyncio.to_thread(self.stop_event.wait)

    def run(self):
        try:
            asyncio.run(self.run_async())
            self.result.set_result(None)
        except BaseException as exc:
            self.result.set_exception(exc)
        finally:
            self.stop_event.set()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run a multithreaded echo server with one event loop per thread."
    )
    parser.add_argument("--host", default="127.0.0.1", help="Listen host")
    parser.add_argument("--port", type=int, default=9001, help="Listen port")
    parser.add_argument("--num-threads", type=int, default=4, help="Number of worker threads and listening sockets")
    parser.add_argument("--use-tls", action="store_true", help="Enable TLS using tests/test.crt and tests/test.key")
    args = parser.parse_args()

    if args.port <= 0 or args.port > 65535:
        parser.error("--port must be in range 1..65535")
    if args.num_threads <= 0:
        parser.error("--num-threads must be > 0")

    basicConfig(level=INFO)

    server_ssl, _ = build_ssl_contexts() if args.use_tls else (None, None)
    stop_event = threading.Event()

    threads = [ServerThread(index, args, server_ssl, stop_event)
               for index in range(args.num_threads)]

    for thread in threads:
        thread.start()

    try:
        for thread in threads:
            thread.join()
    except KeyboardInterrupt:
        stop_event.set()
        for thread in threads:
            thread.join()

    for t in threads:
        t.result.result()


if __name__ == "__main__":
    main()
