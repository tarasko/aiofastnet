import asyncio

from aiofastnet import loop_factory, patch_loop
from aiofastnet.transport import Transport
from aiofastnet.wrapped_transport import (
    _AIOFASTNET_ORIGINAL_ATTR,
    _AIOFASTNET_PATCHED_ATTR,
)
from tests.utils import TestClient, TestServer, conn_type


async def test_patch_loop_is_idempotent():
    loop = asyncio.get_running_loop()

    patched = patch_loop(loop)
    patched_again = patch_loop(loop)

    assert patched is loop
    assert patched_again is loop
    originals = getattr(loop, _AIOFASTNET_ORIGINAL_ATTR)
    assert originals["create_connection"] is not loop.create_connection
    assert "create_connection" in getattr(loop, _AIOFASTNET_PATCHED_ATTR)


def test_loop_factory_sets_and_patches_current_loop():
    factory = loop_factory(asyncio.SelectorEventLoop)
    loop = factory()
    try:
        assert asyncio.get_event_loop() is loop
        assert "create_connection" in getattr(loop, _AIOFASTNET_PATCHED_ATTR)
    finally:
        loop.close()
        asyncio.set_event_loop(None)


async def test_patched_loop_connection_methods_use_aiofastnet_transport():
    loop = patch_loop(asyncio.get_running_loop())
    connected = loop.create_future()

    class EchoProtocol(asyncio.Protocol):
        def connection_made(self, transport):
            assert isinstance(transport, Transport)
            self.transport = transport
            connected.set_result(None)

        def data_received(self, data):
            self.transport.write(data)

    server = await loop.create_server(EchoProtocol, "127.0.0.1", 0)
    try:
        port = server.sockets[0].getsockname()[1]
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        await connected
        writer.write(b"hello")
        assert await reader.readexactly(5) == b"hello"
        writer.close()
        await writer.wait_closed()
    finally:
        server.close()
        await server.wait_closed()


async def test_transport_methods_mockable(conn_type):
    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, ct=conn_type) as client:
            orig_write = client.transport.write
            orig_writelines = client.transport.writelines

            setattr(client.transport, "write", 123)
            setattr(client.transport, "writelines", 123)

            client.transport.write = orig_write
            client.transport.writelines = orig_writelines
