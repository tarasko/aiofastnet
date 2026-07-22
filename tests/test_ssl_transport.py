import asyncio
import socket

import pytest

from aiofastnet import openssl_compat, Protocol
from aiofastnet import ssl_transport as aiofn_ssl_transport
from tests.utils import make_test_ssl_contexts, TestServer, TestClient


async def test_ssl_transport_init_exc(selector_loop, monkeypatch, ssl_sbio_conn_type):
    if openssl_compat.OPENSSL_DYN_LIBS is None:
        pytest.skip("SSLTransport_Socket works only with SSLEngineDirect")

    def boom(transport):
        if not transport.get_extra_info('ssl_object').server_side:
            raise RuntimeError("post handshake hook boom")

    monkeypatch.setattr(aiofn_ssl_transport, "_ssl_socket_post_handshake_test_hook", boom)

    async with TestServer(ct=ssl_sbio_conn_type) as server:
        with pytest.raises(RuntimeError, match="post handshake hook boom"):
            async with TestClient(server, ct=ssl_sbio_conn_type) as client:
                await client.transport.wait_disconnected()
                pass


async def test_ssl_socket_transport_repr_does_not_call_protocol_buffer_size(selector_loop):
    if openssl_compat.OPENSSL_DYN_LIBS is None:
        pytest.skip("SSLTransport_Socket works only with SSLEngineDirect")

    class BadBufferSizeProtocol(Protocol):
        def connection_made(self, transport):
            self.transport = transport

        def get_local_write_buffer_size(self):
            raise RuntimeError("get_local_write_buffer_size")

    loop = asyncio.get_running_loop()
    _, client_context = make_test_ssl_contexts("tests/test.crt", "tests/test.key", False)
    sock, peer = socket.socketpair()
    transport = None
    try:
        sock.setblocking(False)
        transport = aiofn_ssl_transport.SSLTransport_Socket(
            loop,
            BadBufferSizeProtocol(),
            client_context,
            False,
            1.0,
            1.0,
            256 * 1024,
            256 * 1024,
            sock,
        )
        assert "SSLTransport_Socket" in repr(transport)
    finally:
        if transport is not None:
            transport.abort()
            await asyncio.sleep(0)
        peer.close()


async def test_ssl_protocol_ignores_late_connection_made_after_connection_lost(selector_loop):
    class DummyProtocol(asyncio.Protocol):
        pass

    class DummySocket:
        def fileno(self):
            return -1

    class DummyTransport(asyncio.Transport):
        def get_extra_info(self, name, default=None):
            if name == "socket":
                return DummySocket()
            return default

    loop = asyncio.get_running_loop()
    _, client_context = make_test_ssl_contexts("tests/test.crt", "tests/test.key", False)
    waiter = loop.create_future()
    ssl_transport = aiofn_ssl_transport.SSLTransport_Transport(
        loop,
        DummyProtocol(),
        client_context,
        False,
        1.0,
        1.0,
        256 * 1024,
        256 * 1024,
        waiter=waiter,
        server_hostname="aiofastnet.org",
        call_connection_made=False,
    )
    ssl_protocol = ssl_transport.get_tls_protocol()

    ssl_protocol.connection_lost(ConnectionResetError())
    ssl_protocol.connection_made(DummyTransport())
