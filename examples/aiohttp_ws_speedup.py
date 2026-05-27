import argparse
import asyncio
import platform

import uvloop
from aiohttp import ClientSession, WSMsgType, web
from time import time

import aiofastnet
from examples.utils import build_ssl_contexts


async def websocket_handler(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    async for msg in ws:
        if msg.type == WSMsgType.BINARY:
            if msg.data == 'close':
                await ws.close()
            else:
                await ws.send_bytes(msg.data)
        elif msg.type == WSMsgType.ERROR:
            print('ws connection closed with exception %s' %
                  ws.exception())

    print('websocket connection closed')

    return ws


async def run_client(url: str, data: bytes, duration: float, ssl_context):
    async with ClientSession() as session:
        async with session.ws_connect(url, ssl_context=ssl_context) as ws:
            print("Client connected")
            # send request
            cnt = 0
            start_time = time()
            await ws.send_bytes(data)

            while True:
                msg = await ws.receive()
                if msg.type == WSMsgType.BINARY:
                    cnt += 1
                    if time() - start_time >= duration:
                        await ws.close()
                        return int(cnt/duration)

                    await ws.send_bytes(data)
                else:
                    if msg.type == WSMsgType.CLOSE:
                        await ws.close()
                    elif msg.type == WSMsgType.ERROR:
                        print(f"Error during receive {ws.exception()}")
                    elif msg.type == WSMsgType.CLOSED:
                        pass

                    break


async def main(args):
    if args.ssl:
        server_ctx, client_ctx = build_ssl_contexts()
    else:
        server_ctx, client_ctx = None, None

    server = web.Server(websocket_handler)
    runner = web.ServerRunner(server)
    await runner.setup()
    site = web.TCPSite(runner, 'localhost', args.port, ssl_context=server_ctx)
    await site.start()

    print(f"{'SSL' if args.ssl else 'TCP'} server started on port {args.port}")
    rps = await run_client(f"{'wss' if args.ssl else 'ws'}://localhost:{args.port}/", b"x"*args.msg_size, args.duration, client_ctx)
    print(f"RPS: {rps}")



if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Echo round-trip benchmark over loopback for aiohttp websockets")
    parser.add_argument("--uvloop", action="store_true", help="Turn on uvloop")
    parser.add_argument("--aiofastnet", action="store_true", help="Turn on aiofastnet")
    parser.add_argument("--ssl", action="store_true", help="Use ssl")
    parser.add_argument("--port", default=8080, type=int, help="Server port")
    parser.add_argument("--msg-size", type=int, default=256, help="Comma-separated message sizes in bytes")
    parser.add_argument("--duration", type=float, default=5.0, help="Benchmark duration in seconds" )
    args = parser.parse_args()

    if args.uvloop:
        uvloop.install()

    if args.aiofastnet:
        pyver = platform.python_version_tuple()
        if (int(pyver[0]), int(pyver[1])) >= (3, 14):
            asyncio.run(main(args), loop_factory=aiofastnet.loop_factory())
        else:
            aiofastnet.install_policy()
            asyncio.run(main(args))
    else:
        asyncio.run(main(args))
