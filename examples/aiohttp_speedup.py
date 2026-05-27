import asyncio

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


async def main():
    server_ctx, client_ctx = build_ssl_contexts()

    server = web.Server(websocket_handler)
    runner = web.ServerRunner(server)
    await runner.setup()
    site = web.TCPSite(runner, 'localhost', 8080, ssl_context=server_ctx)
    await site.start()

    print("Server started")
    rps = await run_client("wss://localhost:8080/", b"x"*256, 5, client_ctx)
    print(f"RPS: {rps}")


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


if __name__ == "__main__":
    uvloop.install()
    aiofastnet.install_policy()
    asyncio.run(main())
