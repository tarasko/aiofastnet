import asyncio
import warnings

from aiofastnet import install_policy, loop_factory, patch_loop
from aiofastnet.transport import Transport
from aiofastnet.wrapped_transport import (
    _AIOFASTNET_ORIGINAL_ATTR,
    _AIOFASTNET_PATCHED_ATTR,
)
from tests.utils import TestClient, TestServer


async def test_patch_loop_is_idempotent():
    loop = asyncio.get_running_loop()

    patched = patch_loop()
    patched_again = patch_loop(loop)

    assert asyncio.get_running_loop() is loop

    assert patched is loop
    assert patched_again is loop
    originals = getattr(loop, _AIOFASTNET_ORIGINAL_ATTR)
    assert originals["create_connection"] is not loop.create_connection
    assert "create_connection" in getattr(loop, _AIOFASTNET_PATCHED_ATTR)
    if hasattr(loop, "create_unix_connection"):
        assert originals["create_unix_connection"] is not \
            loop.create_unix_connection
        assert "create_unix_connection" in getattr(
            loop, _AIOFASTNET_PATCHED_ATTR)


def test_loop_factory_sets_and_patches_current_loop():
    factory = loop_factory(asyncio.SelectorEventLoop)
    loop = factory()
    try:
        assert asyncio.get_event_loop() is loop
        assert "create_connection" in getattr(loop, _AIOFASTNET_PATCHED_ATTR)
    finally:
        loop.close()
        asyncio.set_event_loop(None)


def test_install_policy_patches_new_loops_and_can_restore_policy():
    with warnings.catch_warnings():
        warnings.filterwarnings(
            "ignore",
            message="'.*event_loop_policy' is deprecated",
            category=DeprecationWarning,
        )
        original_policy = asyncio.get_event_loop_policy()

        policy = install_policy()
        policy = install_policy(original_policy)
        assert asyncio.get_event_loop_policy() is policy

        loop = None
        try:
            loop = policy.new_event_loop()
            assert "create_connection" in getattr(
                loop, _AIOFASTNET_PATCHED_ATTR)
            policy.set_event_loop(loop)
            assert policy.get_event_loop() is loop
        finally:
            if loop is not None:
                loop.close()
            asyncio.set_event_loop(None)
            asyncio.set_event_loop_policy(original_policy)


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
