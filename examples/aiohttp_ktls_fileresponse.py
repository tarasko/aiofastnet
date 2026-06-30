# This example shows how you can enable aiohttp to send static files over secure connection using Kernel TLS on Linux.
# All you need is:
# * enable aiofastnet with aiofastnet.install_policy()
# * add ssl.OP_ENABLE_KTLS to ssl_context.options
# * load kernel tls module with 'sudo modprobe tls' if not loaded yet.

# Make sure you have a relatively new Linux kernel (>5.1) and proper OpenSSL build (>3.0).
# OpenSSL should have been build on a machine with Linux kernel >5.1.
# Check README.md for details


import argparse
import asyncio
import pathlib
import ssl
import tempfile
from logging import basicConfig
import uvloop

from aiohttp import web

import aiofastnet

FILE_SIZE = 4 * 1024 * 1024 * 1024
STATIC_DIR = pathlib.Path(tempfile.gettempdir()) / "aiohttp-ktls-static"
HUGE_FILE = STATIC_DIR / "huge.bin"


def make_huge_file() -> pathlib.Path:
    STATIC_DIR.mkdir(parents=True, exist_ok=True)
    if not HUGE_FILE.exists() or HUGE_FILE.stat().st_size != FILE_SIZE:
        with HUGE_FILE.open("wb") as f:
            f.truncate(FILE_SIZE)
    return HUGE_FILE


def make_ssl_context(*, enable_ktls: bool) -> ssl.SSLContext:
    here = pathlib.Path(__file__).parent / ".." / "tests"
    ssl_context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ssl_context.load_cert_chain(here / "test.crt", here / "test.key")

    if enable_ktls:
        ssl_context.options |= ssl.OP_ENABLE_KTLS

    return ssl_context


async def huge_file(request: web.Request) -> web.FileResponse:
    return web.FileResponse(make_huge_file())


def make_app() -> web.Application:
    app = web.Application()
    app.router.add_get("/huge.bin", huge_file)
    return app


async def main(args) -> None:
    huge_path = make_huge_file()

    if args.asyncio_debug:
        asyncio.get_running_loop().set_debug(True)

    runner = web.AppRunner(make_app())
    await runner.setup()

    site = web.TCPSite(runner, args.host, args.port, ssl_context=make_ssl_context(enable_ktls=args.ktls))

    try:
        await site.start()

        print(f"Serving {huge_path} ({FILE_SIZE} bytes)")
        print(f"Download link: https://{args.host}:{args.port}/huge.bin")

        await asyncio.Event().wait()
    finally:
        await runner.cleanup()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description=(
            "Serve a huge file through aiohttp.web.FileResonse"
        )
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--uvloop", action="store_true", help="Use uvloop")
    parser.add_argument("--ktls", action="store_true", help="Enable KTLS on SSLContext")
    parser.add_argument("--aiofastnet", action="store_true", help="Use aiofastnet")
    parser.add_argument("--asyncio-debug", action="store_true", help="Enable loop debugging")
    parser.add_argument("--level", type=str, default="INFO", help="Logging level")

    args = parser.parse_args()

    if args.uvloop:
        uvloop.install()

    if args.aiofastnet:
        aiofastnet.install_policy()

    basicConfig(level=args.level)

    asyncio.run(main(args))