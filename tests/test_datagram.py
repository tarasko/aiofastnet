import asyncio
import platform

import pytest
from tests.utils import (
    AsyncClient,
    TestClient,
    TestServer,
    UDP_MAX_PAYLOAD_SIZE,
    exc_queue, SocketPair,
)


async def test_datagram_write_ready_after_eagain(selector_loop, conn_type_udp):
    if platform.system() != "Linux":
        pytest.skip("(AF_UNIX, SOCK_DGRAM) can reliably reproduce EAGAIN for writing only on linux")

    async with SocketPair(conn_type_udp) as (server, client):
        filler = b"x" * (16 * 1024)
        total_size_sent = 0
        for _ in range(1024):
            client.write(filler)
            total_size_sent += len(filler)
            if client.transport.get_write_buffer_size():
                break
        else:
            assert False, "Unix datagram socket did not produce EAGAIN"

        # Add more, so that there will be write ready - EAGAIN at least a few times.
        target_size = total_size_sent * 4
        for _ in range(1024):
            client.write(filler)
            total_size_sent += len(filler)
            if total_size_sent >= target_size:
                break

        assert client.is_writing_paused

        marker = b"queued after EAGAIN"
        client.write(marker)

        await server.readn(total_size_sent)

        data = await server.readn(None)
        assert data == marker
        assert client.transport.get_write_buffer_size() == 0


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


async def test_datagram_received_exception_does_not_close_transport(selector_loop, conn_type_udp):
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

    with exc_queue() as excq:
        async with TestServer(lambda: RaiseOnceDatagramProtocol(RuntimeError("datagram failed")),
                              ct=conn_type_udp) as server:
            async with TestClient(server, ct=conn_type_udp) as client:
                client.transport.sendto(b"first")

                client.transport.sendto(b"second")
                assert await client.readn(6) == b"second"

        assert isinstance(excq[0]["exception"], RuntimeError)
        assert excq[0]["message"] == "Fatal error: protocol.datagram_received() call failed."


async def test_error_received_exception_does_not_close_transport(selector_loop, conn_type_udp):
    class RaisingErrorDatagramProtocol(AsyncClient):
        def __init__(self, exc):
            super().__init__()
            self.exc = exc

        def error_received(self, exc):
            raise self.exc

    with exc_queue() as excq:
        client_protocol = RaisingErrorDatagramProtocol(RuntimeError("error handler failed"))
        async with TestServer(ct=conn_type_udp) as server:
            async with TestClient(server, ct=conn_type_udp,
                                  protocol_factory=lambda: client_protocol) as client:
                client.transport.sendto(b"x" * (UDP_MAX_PAYLOAD_SIZE + 1))

                client.transport.sendto(b"hello")
                assert await client.readn(5) == b"hello"

        assert isinstance(excq[0]["exception"], RuntimeError)
        assert excq[0]["message"] == "Fatal error: protocol.error_received() call failed."
