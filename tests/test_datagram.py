import platform

import pytest

from tests.utils import (
    SocketPair,
    TestClient,
    TestServer,
)


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

