import asyncio

import pytest
from tests.utils import (
    AsyncClient,
    TestClient,
    TestServer,
    UDP_MAX_PAYLOAD_SIZE,
    exc_queue,
)


class RaiseOnceDatagramProtocol(asyncio.DatagramProtocol):
    def __init__(self, exc):
        self.transport = None
        self.exc = exc
        self._raised = False

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if not self._raised:
            self._raised = True
            raise self.exc
        self.transport.sendto(data, addr)


class RaisingErrorDatagramProtocol(AsyncClient):
    def __init__(self, exc):
        super().__init__()
        self.exc = exc

    def error_received(self, exc):
        raise self.exc


async def wait_exception_context(excq):
    async with asyncio.timeout(1.0):
        while not excq:
            await asyncio.sleep(0)
    return excq[0]


async def test_datagram_rejects_different_address(all_loops, conn_type_udp):
    async with TestServer(ct=conn_type_udp) as server:
        async with TestClient(server, ct=conn_type_udp) as client:
            server_addr = client.transport.get_extra_info("peername")
            assert server_addr is not None

            with pytest.raises(ValueError, match="Invalid address"):
                client.transport.sendto(
                    b"hello",
                    ("127.0.0.1", server_addr[1] + 1),
                )


async def test_datagram_transport_is_not_eof_writable(all_loops, conn_type_udp):
    async with TestServer(ct=conn_type_udp) as server:
        async with TestClient(server, ct=conn_type_udp) as client:
            assert client.transport.can_write_eof() is False
            with pytest.raises(NotImplementedError):
                client.transport.write_eof()


async def test_datagram_received_exception_does_not_close_transport(all_loops, conn_type_udp):
    with exc_queue() as excq:
        async with TestServer(lambda: RaiseOnceDatagramProtocol(RuntimeError("datagram failed")),
                              ct=conn_type_udp) as server:
            async with TestClient(server, ct=conn_type_udp) as client:
                client.transport.sendto(b"first")

                context = await wait_exception_context(excq)
                assert isinstance(context["exception"], RuntimeError)
                assert context["message"] == (
                    "Fatal error: protocol.datagram_received() call failed."
                )

                client.transport.sendto(b"second")
                assert await client.readn(6) == b"second"


async def test_error_received_exception_does_not_close_transport(all_loops, conn_type_udp):
    with exc_queue() as excq:
        client_protocol = RaisingErrorDatagramProtocol(RuntimeError("error handler failed"))
        async with TestServer(ct=conn_type_udp) as server:
            async with TestClient(server, ct=conn_type_udp,
                                  protocol_factory=lambda: client_protocol) as client:
                client.transport.sendto(b"x" * (UDP_MAX_PAYLOAD_SIZE + 1))

                context = await wait_exception_context(excq)
                assert isinstance(context["exception"], RuntimeError)
                assert context["message"] == (
                    "Fatal error: protocol.error_received() call failed."
                )

                client.transport.sendto(b"hello")
                assert await client.readn(5) == b"hello"
