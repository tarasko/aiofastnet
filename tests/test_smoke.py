import asyncio
import socket
import sys
import tempfile
import os
import ssl
import threading
from _contextvars import ContextVar
from contextlib import contextmanager

import pytest

import aiofastnet
from aiofastnet import openssl_compat
from aiofastnet.utils import aiofn_maybe_copy_buffer
from aiofastnet.transport import Protocol, SocketTransport, Transport
from aiofastnet.ssl_transport import SSLTransport_Socket, SSLTransport_Transport
from tests.utils import TestClient, TestServer, \
    make_test_ssl_contexts, AsyncClient, SomeException, _logger, \
    start_tls, sendfile, UDP_MAX_PAYLOAD_SIZE


@pytest.mark.parametrize("msg_size", [1, 2, 3, 4, 5, 6, 7, 8, 29, 64, 256 * 1024, 6 * 1024 * 1024])
async def test_echo(all_loops, msg_size, conn_type_plus_udp, buffered_protocol):
    if conn_type_plus_udp.name == "udp":
        if msg_size > UDP_MAX_PAYLOAD_SIZE:
            pytest.skip("UDP datagram payload exceeds the portable IPv4 limit")
        if buffered_protocol:
            pytest.skip("UDP datagram protocol is always simple")

    payload = b"x" * msg_size

    async with TestServer(ct=conn_type_plus_udp, is_buffered=buffered_protocol) as server:
        async with TestClient(server, ct=conn_type_plus_udp, is_buffered=buffered_protocol) as client:
            client.write(payload)
            echoed = await client.readn(msg_size)
            assert echoed == payload
            client.close()
            await client.wait_closed()


async def test_ktls_enabled(ktls_conn_type):
    async with TestServer(ct=ktls_conn_type) as server:
        async with TestClient(server, ct=ktls_conn_type) as client:
            server_client = await server.get_any_server_client()

            assert not client.transport.get_extra_info("ssl_incoming_use_membio")
            assert not client.transport.get_extra_info("ssl_outgoing_use_membio")
            assert client.transport.get_extra_info("ktls_send_enabled")
            assert client.transport.get_extra_info("ktls_recv_enabled")
            assert not server_client.transport.get_extra_info("ssl_incoming_use_membio")
            assert not server_client.transport.get_extra_info("ssl_outgoing_use_membio")
            assert server_client.transport.get_extra_info("ktls_send_enabled")
            assert server_client.transport.get_extra_info("ktls_recv_enabled")


async def test_ssl_sbio_enabled(selector_loop, ssl_sbio_conn_type):
    async with TestServer(ct=ssl_sbio_conn_type) as server:
        async with TestClient(server, ct=ssl_sbio_conn_type) as client:
            server_client = await server.get_any_server_client()

            assert not client.transport.get_extra_info("ssl_incoming_use_membio")
            assert not client.transport.get_extra_info("ssl_outgoing_use_membio")
            assert not client.transport.get_extra_info("ktls_send_enabled")
            assert not client.transport.get_extra_info("ktls_recv_enabled")
            assert not server_client.transport.get_extra_info("ssl_incoming_use_membio")
            assert not server_client.transport.get_extra_info("ssl_outgoing_use_membio")
            assert not server_client.transport.get_extra_info("ktls_send_enabled")
            assert not server_client.transport.get_extra_info("ktls_recv_enabled")


async def test_ssl_membio_enabled(selector_loop, ssl_conn_type):
    expected = ssl_conn_type.name in ("ssl_mbio", "ssl_mbio_fall", "stls")

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            server_client = await server.get_any_server_client()

            assert client.transport.get_extra_info("ssl_incoming_use_membio") is expected
            assert client.transport.get_extra_info("ssl_outgoing_use_membio") is expected
            assert server_client.transport.get_extra_info("ssl_incoming_use_membio") is expected
            assert server_client.transport.get_extra_info("ssl_outgoing_use_membio") is expected


@pytest.mark.parametrize("msg_size", [1, 32, 64, 256 * 1024, 6 * 1024 * 1024, 20 * 1024 * 1024])
@pytest.mark.parametrize("num_lines", [1, 32, 4000])
async def test_echo_writelines(all_loops, msg_size, num_lines, conn_type, buffered_protocol):
    payload = b"x" * msg_size

    async with TestServer(ct=conn_type, is_buffered=buffered_protocol) as server:
        async with TestClient(server, ct=conn_type, is_buffered=buffered_protocol) as client:
            client.write_in_lines(payload, num_lines)
            echoed = await client.readn(msg_size, 4.0)
            assert echoed == payload


async def test_write_huge_close(all_loops, conn_type):
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop) and sys.version_info < (3, 11):
        pytest.skip("ProactorEventLoop in 3.9 and 3.10 had issues with connection closing")

    payload = b"p" * (20*1024*1024)

    class ImpatientServerProtocol(asyncio.Protocol):
        def connection_made(self, transport):
            self.is_eof_received = False
            self.transport = transport

        def data_received(self, data):
            if self.transport.can_write_eof():
                self.transport.write_eof()
            self.transport.close()

        def eof_received(self):
            self.is_eof_received = True
            _logger.debug("ImpatientServerProtocol.eof_received() called")

        def connection_lost(self, exc):
            _logger.debug("ImpatientServerProtocol.connection_lost(%s) called", str(exc))

    async with TestServer(ImpatientServerProtocol, ct=conn_type) as server:
        async with TestClient(server, ct=conn_type) as client:
            client.transport.write(payload)
            with pytest.raises(ConnectionResetError):
                await client.readn(len(payload))

            assert client.transport.is_closing()

            # Asyncio simply skip writing if connection is closing
            client.transport.write(payload)

            # Read notes about eof_received flakiness in test_write_huge_abort

            assert client.transport.get_write_buffer_size() == 0
            if conn_type.name not in ('tcp', 'unix'):
                assert client.is_eof_received

        async with TestClient(server, ct=conn_type) as client:
            client.transport.writelines([payload, payload])
            with pytest.raises(ConnectionResetError):
                await client.readn(len(payload))

            assert client.transport.is_closing()

            # Asyncio simply skip writing if connection is closing
            client.transport.writelines([payload, payload])

            assert client.transport.get_write_buffer_size() == 0
            if conn_type.name not in ('tcp', 'unix'):
                assert client.is_eof_received


async def test_write_huge_abort(all_loops, conn_type):
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        pytest.skip("ProactorEventLoop has different semantics around exceptions from data_received")

    payload = b"p" * (20*1024*1024)

    class FaultyServerProtocol(asyncio.Protocol):
        def connection_made(self, transport):
            self.is_eof_received = False
            self.transport = transport

        def data_received(self, data):
            raise SomeException("data_recieved failed")

        def eof_received(self):
            self.is_eof_received = True
            _logger.debug("FaultyServerProtocol.eof_received() called")

        def connection_lost(self, exc):
            _logger.debug("FaultyServerProtocol.connection_lost(%s) called", str(exc))

    # Normally we would expect client to not have eof_received event if peer disconnect with abort.
    # This is definitely true only for TLS where eof_received mean graceful close_notify
    # However for TCP, eof_received happens when recv syscall returns with 0 bytes read.
    # When SocketTransport is waiting for both write_ready and read_ready, the behaviour
    # becomes flaky. If write_ready happens first, then send fails and we call connection_lost
    # immediately. If read_ready happens first, then we call eof_received.

    async with TestServer(FaultyServerProtocol, ct=conn_type) as server:
        async with TestClient(server, ct=conn_type) as client:
            client.transport.write(payload)
            with pytest.raises(ConnectionResetError):
                await client.readn(len(payload))

            assert client.transport.is_closing()

            # Asyncio simply skip writing if connection is closing
            client.transport.write(payload)

            assert client.transport.get_write_buffer_size() == 0
            if conn_type.name not in ('tcp', 'unix'):
                assert not client.is_eof_received

        async with TestClient(server, ct=conn_type) as client:
            client.transport.writelines([payload, payload])
            with pytest.raises(ConnectionResetError):
                await client.readn(len(payload))

            assert client.transport.is_closing()

            # Asyncio simply skip writing if connection is closing
            client.transport.writelines([payload, payload])

            assert client.transport.get_write_buffer_size() == 0
            if conn_type.name not in ('tcp', 'unix'):
                assert not client.is_eof_received


async def test_write_paused(all_loops, conn_type):
    payload = b"x" * 1024

    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, ct=conn_type) as client:
            wbuf_size = client.transport.get_write_buffer_size()
            assert wbuf_size == 0
            total_bytes_written = 0
            while not client.is_writing_paused:
                client.transport.write(payload)
                total_bytes_written += len(payload)
                assert total_bytes_written < 20*1024*1024, "send buffer is much smaller than this, we should already have hit pause_writing by now"

            wbuf_size = client.transport.get_write_buffer_size()
            assert wbuf_size > 0

            _logger.debug("test_write_paused: %d total bytes was sent before pause_writing event, wbuf_size=%d", 
                          total_bytes_written, wbuf_size)

            # increase writing buffer limit, this should cause resume_writing on our transports
            client.transport.set_write_buffer_limits(wbuf_size + 2048, wbuf_size + 1)

            low, high = client.transport.get_write_buffer_limits()
            assert high == wbuf_size + 2048
            assert low == wbuf_size + 1

            # asyncio tcp implementations do not notify pause_writing/resume_writing from set_write_buffer_limits()
            # asyncio ssl implementation does. 
            if not (os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop)):
                assert not client.is_writing_paused

                # decrease writing buffer limit, cause writing paused
                client.transport.set_write_buffer_limits(wbuf_size-2048, 0)
                assert client.is_writing_paused

            await client.wait_write_resumed()
            await client.readn(total_bytes_written)


async def test_writelines_paused(all_loops, conn_type):
    msg1 = b"a" * 256 
    msg2 = b"b" * 256 * 2
    msg3 = b"c" * 256 * 3

    total_batch_size = len(msg1) + len(msg2) + len(msg3)

    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, ct=conn_type) as client:
            wbuf_size = client.transport.get_write_buffer_size()
            assert wbuf_size == 0
            total_bytes_written = 0
            while not client.is_writing_paused:
                client.transport.writelines([msg1, msg2, msg3])
                total_bytes_written += total_batch_size
                assert total_bytes_written < 20*1024*1024, "send buffer is much smaller than this, we should already have hit pause_writing by now"
            
            _logger.debug("test_writelines_paused: %d total bytes was sent before pause_writing event, wbuf_size=%d", 
                          total_bytes_written, client.transport.get_write_buffer_size())

            wbuf_size = client.transport.get_write_buffer_size()
            assert wbuf_size > 0

            # asyncio tcp implementations do not notify pause_writing/resume_writing from set_write_buffer_limits()
            # asyncio ssl implementation does. 
            if not (os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop)):
                # increase writing buffer limit, this should cause resume_writing
                client.transport.set_write_buffer_limits(wbuf_size+2048, wbuf_size+1)
                assert not client.is_writing_paused

                # decrease writing buffer limit, cause writing paused
                client.transport.set_write_buffer_limits(wbuf_size-2048, 0)
                assert client.is_writing_paused

            await client.wait_write_resumed()
            await client.readn(total_bytes_written)


async def test_pause_reading(all_loops, conn_type):
    payload = b"x" * (20*1024*1024)

    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, ct=conn_type) as client:
            client.transport.write(payload)
            assert client.transport.is_reading()

            # pause_reading is idempotent
            client.transport.pause_reading()
            client.transport.pause_reading()
            assert not client.transport.is_reading()

            with pytest.raises(asyncio.TimeoutError):
                await client.wait_new_data(0.3)

            # resume_reading is idempotent
            client.transport.resume_reading()
            client.transport.resume_reading()

            await client.wait_new_data(0.3)
            client.transport.pause_reading()

            with pytest.raises(asyncio.TimeoutError):
                await client.wait_new_data(0.3)

            client.transport.resume_reading()


async def test_pause_reading_from_read_callback(all_loops, conn_type, buffered_protocol):
    payload = b"x" * (3 * 256 * 1024)

    class PauseFromReadCallbackClient(AsyncClient):
        def __init__(self):
            super().__init__()
            self.first_read = asyncio.get_running_loop().create_future()
            self.read_callback_count = 0

        def _pause_once(self):
            self.read_callback_count += 1
            if self.read_callback_count == 1:
                self.transport.pause_reading()
                self.first_read.set_result(len(self._data))

        def data_received(self, data):
            super().data_received(data)
            self._pause_once()

        def buffer_updated(self, bytes_read):
            super().buffer_updated(bytes_read)
            self._pause_once()

    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, ct=conn_type, protocol_factory=PauseFromReadCallbackClient, is_buffered=buffered_protocol) as client:
            client.write(payload)

            first_read_size = await asyncio.wait_for(client.first_read, timeout=1.0)
            assert 0 < first_read_size < len(payload)
            assert not client.transport.is_reading()

            # The socket should still have data ready. Even if _read_ready() is
            # invoked directly while paused, it must not read more data.
            # client.transport._read_ready()
            await asyncio.sleep(0.1)
            assert len(client._data) == first_read_size
            assert client.read_callback_count == 1

            client.transport.resume_reading()
            assert await client.readn(len(payload), timeout=4.0) == payload
            assert client.read_callback_count > 1


async def test_eof_received_keep_open(all_loops):
    loop = asyncio.get_running_loop()
    server_protocol_created = loop.create_future()
    server_received = loop.create_future()

    class HalfCloseServer(asyncio.Protocol):
        def connection_made(self, transport):
            self.transport = transport
            server_protocol_created.set_result(self)

        def data_received(self, data):
            if not server_received.done():
                server_received.set_result(data)

    class KeepOpenClient(AsyncClient):
        def eof_received(self):
            super().eof_received()
            self.transport.write(b"client-after-eof")
            self.transport.close()
            return True

    async with TestServer(HalfCloseServer) as server:
        async with TestClient(server, protocol_factory=KeepOpenClient) as client:
            server_client = await server_protocol_created
            server_client.transport.write(b"server-before-eof")
            server_client.transport.write_eof()

            assert await client.readn(len(b"server-before-eof")) == b"server-before-eof"
            assert await asyncio.wait_for(server_received, timeout=1.0) == b"client-after-eof"
            await client.wait_closed()
            assert client.is_eof_received


async def test_socket_transport_repr_does_not_call_protocol_buffer_size(selector_loop):
    class BadBufferSizeProtocol(Protocol):
        def connection_made(self, transport):
            self.transport = transport

        def get_local_write_buffer_size(self):
            raise RuntimeError("get_local_write_buffer_size")

    loop = asyncio.get_running_loop()
    sock, peer = socket.socketpair()
    transport = None
    try:
        sock.setblocking(False)
        transport = SocketTransport(loop, sock, BadBufferSizeProtocol())
        assert "SocketTransport" in repr(transport)
        await asyncio.sleep(0)
    finally:
        if transport is not None:
            transport.abort()
            await asyncio.sleep(0)
        peer.close()


async def test_ssl_socket_transport_repr_does_not_call_protocol_buffer_size(selector_loop):
    if openssl_compat.OPENSSL_DYN_LIBS is None:
        pytest.skip("SSLTransport_Socket works only with SSLEngineDirect")

    class BadBufferSizeProtocol(Protocol):
        def connection_made(self, transport):
            self.transport = transport

        def get_local_write_buffer_size(self):
            raise RuntimeError("get_local_write_buffer_size")

    loop = asyncio.get_running_loop()
    server_context, client_context = make_test_ssl_contexts("tests/test.crt", "tests/test.key", False)
    sock, peer = socket.socketpair()
    transport = None
    try:
        sock.setblocking(False)
        transport = SSLTransport_Socket(
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
    ssl_transport = SSLTransport_Transport(
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


async def test_ssl_renegotiate_midstream(all_loops, ssl_conn_type):
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        pytest.skip("aiofastnet doesn't work with ProactorEventLoop")

    if ssl_conn_type.name == 'ktls':
        pytest.skip("kTLS doesn't support renegotiation")

    if ssl_conn_type.name == "ssl_mbio_fall":
        pytest.skip("fallback SSL engine doesn't support renegotiation")

    if aiofastnet.OPENSSL_DYN_LIBS is None:
        pytest.skip("Renegotiate is not available in standalone python")

    preface = b"A" * (4 * 1024)
    payload = b"B" * (4 * 1024)
    suffix = b"C" * (4 * 1024)

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:

            client.write(preface)
            assert await client.readn(len(preface)) == preface

            client.transport.get_extra_info('ssl_protocol')._renegotiate()
            wbuf_size = client.transport.get_write_buffer_size()
            client.write(payload)
            wbuf_size_2 = client.transport.get_write_buffer_size()
            assert wbuf_size + len(payload) == wbuf_size_2
            echoed_payload = await client.readn(len(payload), timeout=1.0)
            assert echoed_payload == payload

            client.write(suffix)
            assert await client.readn(len(suffix)) == suffix


@contextmanager
def TmpFromData(data):
    with tempfile.TemporaryFile() as tmp:
        tmp.write(data)
        tmp.flush()
        tmp.seek(0)
        try:
            yield tmp
        finally:
            pass


@pytest.mark.parametrize("file_size", [64, 3 * 1024 * 1024])
@pytest.mark.parametrize("header_size", [64, 256 * 1024])
@pytest.mark.parametrize("tail_size", [64, 256 * 1024])
async def test_sendfile(all_loops, sendfile_conn_type, file_size, header_size, tail_size):
    sendfile_conn_type.check_sendfile_supported()
    loop = asyncio.get_running_loop()
    header = b"h" * header_size
    payload = b"p" * file_size
    tail = b"t" * tail_size
    with TmpFromData(payload) as tmp:
        async with TestServer(ct=sendfile_conn_type) as server:
            async with TestClient(server, ct=sendfile_conn_type) as client:
                _logger.debug("Begin writing header(%d)", len(header))
                client.transport.write(header)
                _logger.debug("Call sendfile")
                await sendfile(loop, client.transport, tmp, offset=2, count=len(payload)-2, fallback=False)
                assert client.transport.is_reading()
                _logger.debug("Begin writing tail(%d)", len(tail))
                client.transport.write(tail)

                reply = await client.readn(len(header))
                assert reply == header
                _logger.debug("Header successfully read")

                reply = await client.readn(len(payload) - 2)
                assert reply == payload[2:]
                _logger.debug("Payload successfully read")

                await asyncio.sleep(0.1)
                reply = await client.readn(len(tail))
                assert reply == tail

                client.transport._sendfile_compatible = False
                with pytest.raises(NotImplementedError):
                    await sendfile(loop, client.transport, tmp, offset=2, count=len(payload)-2, fallback=False)


@pytest.mark.parametrize("count", [None, 1024])
async def test_sendfile_to_eof(all_loops, conn_type, count):
    conn_type.check_sendfile_supported()

    loop = asyncio.get_running_loop()
    payload = b"payload"
    with TmpFromData(payload) as tmp:
        async with TestServer(ct=conn_type) as server:
            async with TestClient(server, ct=conn_type) as client:
                await sendfile(loop, client.transport, tmp, offset=2, count=count, fallback=False)
                assert await client.readn(len(payload) - 2, timeout=1.0) == payload[2:]


async def test_sendfile_huge_error(all_loops, conn_type):
    conn_type.check_sendfile_supported()

    loop = asyncio.get_running_loop()
    payload = b"p" * (20*1024*1024)

    class FaultyServerProtocol(asyncio.Protocol):
        def connection_made(self, transport):
            self.transport = transport

        def data_received(self, data):
            self.transport.abort()

    class Client(AsyncClient):
        def pause_writing(self):
            pass

        def resume_writing(self):
            pass

    with TmpFromData(payload) as tmp:
        async with TestServer(FaultyServerProtocol, ct=conn_type) as server:
            async with TestClient(server, ct=conn_type, protocol_factory=Client) as client:

                # SSL_sendfile may return that suddenly all data is successfully sent when peer close connection
                # So we can't reliably assert exception.
                # But for a regular sendfile we can
                if conn_type.name == 'ktls':
                    try:
                        await sendfile(loop, client.transport, tmp, offset=0, count=len(payload), fallback=False)
                        await client.wait_closed()
                        # OpenSSL 3.0 may report peer-abort KTLS SSL_sendfile() syscall failures as
                        # [SSL: UNINITIALIZED], fixed/changed in later OpenSSL, so the test accepts it only for
                        # that failure case.
                    except (ConnectionResetError, BrokenPipeError, ssl.SSLError):
                        pass
                else:
                    with pytest.raises((ConnectionResetError, BrokenPipeError)):
                        await sendfile(loop, client.transport, tmp, offset=0, count=len(payload))

                with pytest.raises(RuntimeError, match="is closing"):
                    await sendfile(loop, client.transport, tmp, offset=0, count=len(payload))


@pytest.mark.skipif(os.name != "nt", reason="Windows-only test")
async def test_sendfile_win_not_implemented(selector_loop):
    loop = asyncio.get_running_loop()
    payload = b"p" * (1024)
    with TmpFromData(payload) as tmp:
        async with TestServer() as server:
            async with TestClient(server) as client:
                with pytest.raises(NotImplementedError):
                    await sendfile(loop, client.transport, tmp, offset=2, count=len(payload)-2, fallback=False)


async def test_sendfile_ssl_not_implemented(all_loops, ssl_conn_type):
    if ssl_conn_type.name == 'ktls':
        pytest.skip("sendfile is supported by ktls")

    loop = asyncio.get_running_loop()
    payload = b"p" * (1024)
    with TmpFromData(payload) as tmp:
        async with TestServer(ct=ssl_conn_type) as server:
            async with TestClient(server, ct=ssl_conn_type) as client:
                with pytest.raises(NotImplementedError):
                    await sendfile(loop, client.transport, tmp, offset=2, count=len(payload)-2, fallback=False)


async def test_write_wrong_type(all_loops, conn_type):
    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, ct=conn_type) as client:
            with pytest.raises(TypeError):
                client.write(None)

            client.write(b"")       # No-op

            with pytest.raises(TypeError):
                client.transport.write(42)

            with pytest.raises(TypeError):
                client.transport.writelines([42])

            with pytest.raises(TypeError):
                client.transport.writelines(42)

    if os.name != 'nt' or not isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        assert "closed" in repr(client.transport)

    # Check that we can write after transport is closed, it is no-op
    for i in range(10):
        client.transport.write(b"abcd")


async def test_bad_buffer(all_loops, conn_type):
    class ClientWithReadonlyBuffer(AsyncClient):
        def get_buffer(self, hint):
            return b"1" * 16 * 1024

    class ClientWithEmptyBuffer(AsyncClient):
        def get_buffer(self, hint):
            return bytearray()

    class ClientWithNoneBuffer(AsyncClient):
        def get_buffer(self, hint):
            return bytearray()

    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, ct=conn_type, is_buffered=True, protocol_factory=ClientWithReadonlyBuffer) as client:
            client.write(b"1234")
            with pytest.raises((BufferError, TypeError)):
                await client.wait_closed()

        async with TestClient(server, ct=conn_type, is_buffered=True, protocol_factory=ClientWithEmptyBuffer) as client:
            client.write(b"1234")
            with pytest.raises(RuntimeError, match="empty buffer"):
                await client.wait_closed()

        async with TestClient(server, ct=conn_type, is_buffered=True, protocol_factory=ClientWithNoneBuffer) as client:
            client.write(b"1234")
            with pytest.raises(RuntimeError, match="empty buffer"):
                await client.wait_closed()


async def test_maybe_copy(all_loops):
    bytes_obj = bytes(b"abcd")
    assert aiofn_maybe_copy_buffer(bytes_obj) is bytes_obj

    mv_bytes_obj = memoryview(bytes_obj)
    mv_bytes_obj_copy = aiofn_maybe_copy_buffer(mv_bytes_obj)
    assert mv_bytes_obj_copy is mv_bytes_obj

    mv_bytes_obj = mv_bytes_obj[1:]
    mv_bytes_obj_copy = aiofn_maybe_copy_buffer(mv_bytes_obj)
    assert mv_bytes_obj_copy is mv_bytes_obj

    ba_obj = bytearray(b"abcd")
    ba_obj_copy = aiofn_maybe_copy_buffer(ba_obj)
    assert ba_obj_copy is not ba_obj
    assert isinstance(ba_obj_copy, bytes)
    assert ba_obj_copy == ba_obj

    mv_ba_obj = memoryview(ba_obj)
    mv_ba_obj_copy = aiofn_maybe_copy_buffer(mv_ba_obj)
    assert mv_ba_obj_copy is not mv_ba_obj
    assert isinstance(mv_ba_obj_copy, bytes)
    assert mv_ba_obj_copy == ba_obj


async def test_contextvar(all_loops, conn_type, buffered_protocol):
    payload = b"x" * 6*1024*1024

    var = ContextVar('var')
    var.set('begin')

    var_values = []

    class Client(AsyncClient):
        def connection_made(self, transport):
            var_values.append(('connection_made', var.get()))
            var.set('connection_made')
            return super().connection_made(transport)

        def data_received(self, data):
            var_values.append(('data_received', var.get()))
            var.set('data_received')
            return super().data_received(data)

        def get_buffer(self, hint):
            var_values.append(('get_buffer', var.get()))
            var.set('get_buffer')
            return super().get_buffer(hint)

        def buffer_updated(self, bytes_read):
            var_values.append(('buffer_updated', var.get()))
            var.set('buffer_updated')
            return super().buffer_updated(bytes_read)

        def pause_writing(self):
            var_values.append(('pause_writing', var.get()))
            var.set('pause_writing')
            return super().pause_writing()

        def resume_writing(self):
            var_values.append(('resume_writing', var.get()))
            var.set('resume_writing')
            return super().resume_writing()

        def eof_received(self):
            var_values.append(('eof_received', var.get()))
            var.set('eof_received')
            return super().eof_received()

        def connection_lost(self, exc):
            var_values.append(('connection_lost', var.get()))
            var.set('connection_lost')
            return super().connection_lost(exc)


    async with TestServer(ct=conn_type, is_buffered=buffered_protocol) as server:
        async with TestClient(server, protocol_factory=Client, ct=conn_type, is_buffered=buffered_protocol) as client:
            assert var.get() == "begin"
            client.write(payload)
            await client.readn(len(payload))

            # Initiate disconnect from the server side
            server_client = await server.get_any_server_client()
            server_client.transport.close()
            await client.wait_closed()

            # Every event loop does it differently
            # There is actually nothing to test here but I left this test anyway
            # because it highlights what each loop does with contextvars

            assert var_values[0] == ('connection_made', 'begin')


async def test_transport_base(all_loops, conn_type_plus_udp):
    async with TestServer(ct=conn_type_plus_udp) as server:
        async with TestClient(server, ct=conn_type_plus_udp) as client:
            assert isinstance(client.transport, Transport)
            client.close()
            await client.wait_closed()


async def test_start_tls(all_loops):
    server_ssl_context, client_ssl_context = make_test_ssl_contexts(
        "tests/test.crt", "tests/test.key")

    test_msg = b"hello world!"
    test_msg_2 = b"hello world! #2"
    tls_upgrade_cmd = b"start_tls"
    tls_upgrade_and_push_cmd = b"start_tls_and_push"
    close_cmd = b"close"

    class ServerTlsUpgrade(asyncio.Protocol):
        def __init__(self, gen=0):
            self._gen = gen

        def connection_made(self, transport):
            self._transport = transport
            self._loop = asyncio.get_running_loop()
            _logger.debug("Server(%d): connection_made", self._gen)

        def data_received(self, data):
            _logger.debug("Server(%d): data_received, %s", self._gen, data)
            if data == tls_upgrade_cmd:
                self._transport.write(data)
                self._loop.create_task(self._start_tls())
            elif data == tls_upgrade_and_push_cmd:
                self._transport.write(data)
                self._loop.create_task(self._start_tls_and_push())
            elif data == close_cmd:
                self._transport.close()
            else:
                self._transport.write(data)

        async def _start_tls(self):
            try:
                self._transport = await start_tls(
                    self._loop,
                    self._transport,
                    self,
                    server_ssl_context,
                    server_side=True)
                _logger.debug("Server(%d): start_tls completed", self._gen)
                self._gen += 1
            except Exception:
                _logger.exception("Server: unable to start_tls")

        async def _start_tls_and_push(self):
            try:
                self._transport = await start_tls(
                    self._loop,
                    self._transport,
                    self,
                    server_ssl_context,
                    server_side=True)
                _logger.debug("Server(%d): start_tls completed", self._gen)
                self._gen += 1
                self._transport.write(test_msg)
            except Exception:
                _logger.exception("Server: unable to start_tls")

        def connection_lost(self, exc):
            _logger.debug("Server(%d): connection_lost", self._gen)

    async with TestServer(ServerTlsUpgrade) as server:
        async with TestClient(server, is_buffered=False) as client:
            # Upgrade TLS 3 times, so at the end we have TLS over TLS over TLS
            # For each layer send test message and verify echo response
            # At the end ask server to disconnect us gracefully
            # Verify that client has had eof_received event

            client.transport.write(test_msg)
            reply = await client.readn(len(test_msg))
            assert reply == test_msg

            client.transport.write(tls_upgrade_cmd)
            reply = await client.readn(len(tls_upgrade_cmd))
            assert reply == tls_upgrade_cmd
            await client.start_tls(client_ssl_context)

            client.transport.write(test_msg_2)
            reply = await client.readn(len(test_msg_2))
            assert reply == test_msg_2

            client.transport.write(tls_upgrade_and_push_cmd)
            reply = await client.readn(len(tls_upgrade_and_push_cmd))
            assert reply == tls_upgrade_and_push_cmd
            await client.start_tls(client_ssl_context)

            reply = await client.readn(len(test_msg))
            assert reply == test_msg

            client.transport.write(tls_upgrade_cmd)
            reply = await client.readn(len(tls_upgrade_cmd))
            assert reply == tls_upgrade_cmd
            await client.start_tls(client_ssl_context)

            client.transport.write(test_msg)
            reply = await client.readn(len(test_msg))
            assert reply == test_msg

            client.transport.write(close_cmd)
            await client.wait_closed()
            assert client.is_eof_received


async def test_peername(all_loops, conn_type_plus_udp):
    async with TestServer(ct=conn_type_plus_udp) as server:
        async with TestClient(server, ct=conn_type_plus_udp) as client:
            server_client = await server.get_any_server_client()
            client_peername = client.transport.get_extra_info('peername')
            client_sockname = client.transport.get_extra_info('sockname')
            server_peername = server_client.transport.get_extra_info('peername')
            server_sockname = server_client.transport.get_extra_info('sockname')
            assert client_peername == server_sockname
            if conn_type_plus_udp.name == "udp":
                assert server_peername is None
                return
            assert server_peername == client_sockname


async def test_ssl_server_hostname_not_passed(all_loops, ssl_conn_type):
    # In stdlib:
    #   - SSLContext.wrap_socket(check_hostname=True, server_hostname=None) -> ValueError
    #   - SSLContext.wrap_socket(check_hostname=True, server_hostname="") -> ValueError
    #   - SSLContext.wrap_bio(check_hostname=True, server_hostname=None) -> succeeds, no hostname match
    #   - SSLContext.wrap_bio(check_hostname=True, server_hostname="") -> ValueError for empty hostname
    #   - asyncio.start_tls(check_hostname=True, server_hostname=None) -> succeeds, no hostname match
    #   - asyncio.start_tls(check_hostname=True, server_hostname="") -> succeeds, no hostname match, because asyncio converts "" to None

    # aiofastnet is intentionally consistent and rigorous here.
    # If check_hostname=True and not server_hostname -> ValueError always
    # This may potentially break some code, if it happens, we can relax it

    async with TestServer(ct=ssl_conn_type) as server:
        ssl_conn_type.client_ssl_context.check_hostname = True
        with pytest.raises(ValueError, match="check_hostname requires server_hostname"):
            async with TestClient(server, ct=ssl_conn_type, server_hostname=""):
                pass


@pytest.mark.parametrize("timeout_name", [
    "ssl_shutdown_timeout",
    "ssl_handshake_timeout",
])
@pytest.mark.parametrize("timeout_value", [0, -1])
async def test_ssl_timeout_validation(all_loops, ssl_conn_type, timeout_name, timeout_value):
    kwargs = {timeout_name: timeout_value}
    match = f"{timeout_name} should be a positive number"

    with pytest.raises(ValueError, match=match):
        async with TestServer(ct=ssl_conn_type, **kwargs) as server:
            pass

    async with TestServer(ct=ssl_conn_type) as server:
        with pytest.raises(ValueError, match=match):
            async with TestClient(server, ct=ssl_conn_type, **kwargs):
                pass


async def test_ssl_handshake_timeout(all_loops, ssl_conn_type):
    async with TestServer(ct=ssl_conn_type, ssl_handshake_timeout=0.01) as server:
        reader, writer = await asyncio.open_connection(server.host, server.port)
        try:
            with pytest.raises((asyncio.IncompleteReadError, ConnectionResetError)):
                await asyncio.wait_for(reader.readexactly(1), timeout=1.0)
        finally:
            writer.close()
            await writer.wait_closed()


async def test_ssl_shutdown_timeout(all_loops, ssl_conn_type):
    loop = asyncio.get_running_loop()
    made = loop.create_future()
    lost = loop.create_future()

    class ServerProtocol(asyncio.Protocol):
        def connection_made(self, transport):
            self.transport = transport
            made.set_result(transport)

        def connection_lost(self, exc):
            if not lost.done():
                lost.set_result(exc)

    stop_client = threading.Event()

    def blocking_client():
        raw_sock = socket.create_connection(("127.0.0.1", server.port))
        try:
            ssl_sock = ssl_conn_type.client_ssl_context.wrap_socket(
                raw_sock,
                server_hostname="127.0.0.1",
            )
        except:
            raw_sock.close()
            raise

        with ssl_sock:
            stop_client.wait(1.0)

    async with TestServer(
        ServerProtocol,
        ct=ssl_conn_type,
        ssl_shutdown_timeout=0.01,
    ) as server:
        client_fut = loop.run_in_executor(None, blocking_client)
        try:
            transport = await asyncio.wait_for(made, timeout=1.0)
            transport.close()
            await asyncio.wait_for(lost, timeout=1.0)
        finally:
            stop_client.set()
            await client_fut


# Exception from send due to file error should cause fatal error
# Graceful disconnect should flush all data
