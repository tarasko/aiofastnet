import asyncio
import os
import platform
import socket
import tempfile

import pytest

import aiofastnet
from tests.utils import (
    SocketPair,
    TestClient,
    TestServer,
)


class DatagramQueueProtocol(asyncio.DatagramProtocol):
    def __init__(self):
        self.received = asyncio.Queue()

    def datagram_received(self, data, addr):
        self.received.put_nowait((data, addr))


@pytest.mark.skipif(platform.system() != "Linux",
                    reason="(AF_UNIX, SOCK_DGRAM) can reliably reproduce EAGAIN for writing only on linux")
async def test_datagram_write_ready_after_eagain(selector_loop, conn_type_udp):
    async with SocketPair(conn_type_udp) as (server, client):
        assert not client.transport.can_write_eof()

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


async def test_datagram_ready_after_close(selector_loop, conn_type_udp):
    async with SocketPair(conn_type_udp) as (_server, client):
        client.transport.close()
        client.transport._read_ready()


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


async def test_datagram_sendto_rejects_hostname(selector_loop):
    loop = asyncio.get_running_loop()
    transport, _protocol = await aiofastnet.create_datagram_endpoint(
        loop,
        asyncio.DatagramProtocol,
        local_addr=("127.0.0.1", 0),
    )
    try:
        with pytest.raises(ValueError, match="DNS lookup is required"):
            transport.sendto(b"hello", ("localhost", 12345))
        with pytest.raises(ValueError, match="socket family mismatch"):
            transport.sendto(b"hello", "/tmp/aiofastnet.sock")
    finally:
        transport.close()


@pytest.mark.skipif(os.name == "nt" or not hasattr(socket, "AF_UNIX"), reason="Unix datagram sockets are not supported")
async def test_unix_datagram_addresses(selector_loop):
    loop = asyncio.get_running_loop()
    # macOS allows only 103 pathname bytes in sockaddr_un; pytest's tmp_path can exceed that before the socket filename is appended.
    with tempfile.TemporaryDirectory(prefix="aiofn-", dir="/tmp") as tmpdir:
        server_path = os.path.join(tmpdir, "server.sock")
        client_path = os.path.join(tmpdir, "client.sock")
        server_transport, server_protocol = await aiofastnet.create_datagram_endpoint(
            loop,
            DatagramQueueProtocol,
            local_addr=server_path,
            family=socket.AF_UNIX,
        )
        client_transport, client_protocol = await aiofastnet.create_datagram_endpoint(
            loop,
            DatagramQueueProtocol,
            local_addr=client_path,
            remote_addr=server_path,
            family=socket.AF_UNIX,
        )
        try:
            client_transport.sendto(b"hello")
            data, addr = await asyncio.wait_for(server_protocol.received.get(), 1)
            assert data == b"hello"
            assert addr == client_path
            server_transport.sendto(b"response", addr)
            assert await asyncio.wait_for(client_protocol.received.get(), 1) == (b"response", server_path)
        finally:
            client_transport.close()
            server_transport.close()
