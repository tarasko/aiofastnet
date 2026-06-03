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

from aiofastnet.utils import aiofn_maybe_copy_buffer
from aiofastnet.transport import Transport
from tests.utils import TestClient, TestServer, \
    multiloop_event_loop_policy, make_test_ssl_contexts, ConnectionType, \
    AsyncClient, SomeException, exc_queue, _logger, conn_type, ssl_conn_type, start_tls, sendfile

event_loop_policy = multiloop_event_loop_policy()


@pytest.fixture(params=["simple", "buffered"])
def buffered_protocol(request):
    return request.param == "buffered"


@pytest.mark.parametrize("msg_size", [1, 2, 3, 4, 5, 6, 7, 8, 29, 64, 256 * 1024, 6 * 1024 * 1024])
async def test_echo(msg_size, conn_type, buffered_protocol):
    payload = b"x" * msg_size

    async with TestServer(ct=conn_type, is_buffered=buffered_protocol) as server:
        async with TestClient(server, ct=conn_type, is_buffered=buffered_protocol) as client:
            client.write(payload)
            echoed = await client.readn(msg_size)
            assert echoed == payload
            client.close()
            await client.wait_closed()


@pytest.mark.parametrize("msg_size", [1, 32, 64, 256 * 1024, 6 * 1024 * 1024, 20 * 1024 * 1024])
@pytest.mark.parametrize("num_lines", [1, 32, 4000])
async def test_echo_writelines(msg_size, num_lines, conn_type, buffered_protocol):
    payload = b"x" * msg_size

    async with TestServer(ct=conn_type, is_buffered=buffered_protocol) as server:
        async with TestClient(server, ct=conn_type, is_buffered=buffered_protocol) as client:
            client.write_in_lines(payload, num_lines)
            echoed = await client.readn(msg_size)
            assert echoed == payload


async def test_write_huge_close(conn_type):
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
            if conn_type.name != 'tcp':
                assert client.is_eof_received

        async with TestClient(server, ct=conn_type) as client:
            client.transport.writelines([payload, payload])
            with pytest.raises(ConnectionResetError):
                await client.readn(len(payload))

            assert client.transport.is_closing()

            # Asyncio simply skip writing if connection is closing
            client.transport.writelines([payload, payload])

            assert client.transport.get_write_buffer_size() == 0
            if conn_type.name != 'tcp':
                assert client.is_eof_received


async def test_write_huge_abort(conn_type):
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        pytest.skip("ProactorEventLoop has different semantics around exceptions from data_received")

    payload = b"p" * (20*1024*1024)

    class FaulyServerProtocol(asyncio.Protocol):
        def connection_made(self, transport):
            self.is_eof_received = False
            self.transport = transport

        def data_received(self, data):
            raise SomeException("data_recieved failed")

        def eof_received(self):
            self.is_eof_received = True
            _logger.debug("FaulyServerProtocol.eof_received() called")

        def connection_lost(self, exc):
            _logger.debug("FaulyServerProtocol.connection_lost(%s) called", str(exc))

    # Normally we would expect client to not have eof_received event if peer disconnect with abort.
    # This is definitely true only for TLS where eof_received mean graceful close_notify
    # However for TCP, eof_received happens when recv syscall returns with 0 bytes read.
    # When SocketTransport is waiting for both write_ready and read_ready, the behaviour
    # becomes flaky. If write_ready happens first, then send fails and we call connection_lost
    # immediately. If read_ready happens first, then we call eof_received.

    async with TestServer(FaulyServerProtocol, ct=conn_type) as server:
        async with TestClient(server, ct=conn_type) as client:
            client.transport.write(payload)
            with pytest.raises(ConnectionResetError):
                await client.readn(len(payload))

            assert client.transport.is_closing()

            # Asyncio simply skip writing if connection is closing
            client.transport.write(payload)

            assert client.transport.get_write_buffer_size() == 0
            if conn_type.name != 'tcp':
                assert not client.is_eof_received

        async with TestClient(server, ct=conn_type) as client:
            client.transport.writelines([payload, payload])
            with pytest.raises(ConnectionResetError):
                await client.readn(len(payload))

            assert client.transport.is_closing()

            # Asyncio simply skip writing if connection is closing
            client.transport.writelines([payload, payload])

            assert client.transport.get_write_buffer_size() == 0
            if conn_type.name != 'tcp':
                assert not client.is_eof_received


async def test_write_paused(conn_type):
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


async def test_writelines_paused(conn_type):
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


async def test_pause_reading(conn_type):
    payload = b"x" * (20*1024*1024)

    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, ct=conn_type) as client:
            client.transport.write(payload)
            assert client.transport.is_reading()
            client.transport.pause_reading()
            assert not client.transport.is_reading()
            with pytest.raises(asyncio.TimeoutError):
                await client.wait_new_data(0.3)
            client.transport.resume_reading()

            await client.wait_new_data(0.3)
            client.transport.pause_reading()

            with pytest.raises(asyncio.TimeoutError):
                await client.wait_new_data(0.3)

            client.transport.resume_reading()


async def test_ssl_renegotiate_midstream(ssl_conn_type):
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        pytest.skip("aiofastnet doesn't work with ProactorEventLoop")

    if ssl_conn_type.name == 'ktls':
        pytest.skip("kTLS doesn't support renegotiation")

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


async def test_ssl_selected_alpn_protocol(ssl_conn_type):
    ssl_conn_type.server_ssl_context.set_alpn_protocols(["h2", "http/1.1"])
    ssl_conn_type.client_ssl_context.set_alpn_protocols(["http/1.1", "h2"])

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            assert client_ssl_object.selected_alpn_protocol() == "h2"
            assert server_ssl_object.selected_alpn_protocol() == "h2"


async def test_ssl_selected_alpn_protocol_none(ssl_conn_type):
    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            assert client_ssl_object.selected_alpn_protocol() is None
            assert server_ssl_object.selected_alpn_protocol() is None


async def test_ssl_getpeercert_binary_form(ssl_conn_type):
    expected_der = ssl.PEM_cert_to_DER_cert(open("tests/test.crt", "r", encoding="ascii").read())

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            assert client_ssl_object.getpeercert(binary_form=True) == expected_der
            assert client_ssl_object.getpeercert(binary_form=False) == {}
            assert server_ssl_object.getpeercert(binary_form=True) is None


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
async def test_sendfile(conn_type, file_size, header_size, tail_size):
    conn_type.check_sendfile_supported()

    loop = asyncio.get_running_loop()
    header = b"h" * header_size
    payload = b"p" * file_size
    tail = b"t" * tail_size
    with TmpFromData(payload) as tmp:
        async with TestServer(ct=conn_type) as server:
            async with TestClient(server, ct=conn_type) as client:
                _logger.debug("Begin writing header(%d)", len(header))
                client.transport.write(header)
                _logger.debug("Call sendfile")
                await sendfile(loop, client.transport, tmp, offset=2, count=len(payload)-2)
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


async def test_sendfile_huge_error(conn_type):
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
                        await sendfile(loop, client.transport, tmp, offset=0, count=len(payload))
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
async def test_sendfile_win_not_implemented():
    loop = asyncio.get_running_loop()
    payload = b"p" * (1024)
    with TmpFromData(payload) as tmp:
        async with TestServer() as server:
            async with TestClient(server) as client:
                with pytest.raises(NotImplementedError):
                    await sendfile(loop, client.transport, tmp, offset=2, count=len(payload)-2)


async def test_sendfile_ssl_not_implemented(ssl_conn_type):
    if ssl_conn_type.name == 'ktls':
        pytest.skip("sendfile is supported by ktls")

    loop = asyncio.get_running_loop()
    payload = b"p" * (1024)
    with TmpFromData(payload) as tmp:
        async with TestServer(ct=ssl_conn_type) as server:
            async with TestClient(server, ct=ssl_conn_type) as client:
                with pytest.raises(NotImplementedError):
                    await sendfile(loop, client.transport, tmp, offset=2, count=len(payload)-2)


async def test_exc_eof_received(conn_type):
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        pytest.skip("aiofastnet doesn't work with ProactorEventLoop")

    class ClientRaiseEofReceived(AsyncClient):
        def eof_received(self):
            raise SomeException("eof_received")

    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, protocol_factory=ClientRaiseEofReceived, ct=conn_type, is_buffered=True) as client:
            with exc_queue() as excq:
                # Initiate disconnect from the server side
                server_client = await server.get_any_server_client()
                server_client.transport.close()

                with pytest.raises(SomeException, match="eof_received"):
                    await client.wait_closed()
                assert isinstance(excq[0]["exception"], SomeException)


async def test_exc_connection_made(conn_type):
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        pytest.skip("exceptions from connection_made has unspecified behavior in asyncio")

    class ClientRaiseConnectionMade(AsyncClient):
        def connection_made(self, transport):
            super().connection_made(transport)
            raise SomeException("connection_made")

    payload = b"x" * (20*1024*1024)

    async with TestServer(ct=conn_type) as server:
        with exc_queue() as excq:
            async with TestClient(server, protocol_factory=ClientRaiseConnectionMade, ct=conn_type, is_buffered=False) as client:
                assert isinstance(excq[0]["exception"], SomeException)
                client.transport.write(payload)
                reply = await client.readn(len(payload))
                assert reply == payload
                client.close()
                await client.wait_closed()


async def test_exc_pause_writing(conn_type):
    class ClientRaisePauseWriting(AsyncClient):
        def pause_writing(self):
            super().pause_writing()
            raise SomeException("pause_writing")

    payload = b"x" * 1024
    num_sent = 0

    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, protocol_factory=ClientRaisePauseWriting, ct=conn_type, is_buffered=False) as client:
            with exc_queue() as excq:
                while not client.is_writing_paused:
                    client.transport.write(payload)
                    num_sent += 1

                reply = await client.readn(len(payload) * num_sent)
                assert reply == (payload * num_sent)
                assert isinstance(excq[0]["exception"], SomeException)
                client.close()
                await client.wait_closed()


async def test_exc_resume_writing(conn_type):
    class ClientRaiseResumeWriting(AsyncClient):
        def resume_writing(self):
            super().resume_writing()
            raise SomeException("resume_writing")

    payload = b"x" * 1024
    num_sent = 0

    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, protocol_factory=ClientRaiseResumeWriting, ct=conn_type, is_buffered=False) as client:
            with exc_queue() as excq:
                while not client.is_writing_paused:
                    client.transport.write(payload)
                    num_sent += 1

                reply = await client.readn(len(payload) * num_sent)
                assert reply == (payload * num_sent)
                assert isinstance(excq[0]["exception"], SomeException)
                client.close()
                await client.wait_closed()


async def test_exc_all(conn_type):
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        pytest.skip("exceptions from connection_made has unspecified behavior in asyncio")

    # aiofastnet tries to preserve original un-documented behavior of asyncio
    # Exceptions from data callbacks: data_received, get_buffer, buffer_updated
    # shutdown connection.
    # Exceptions from flow control callbacks: connection_made, pause_writing, resume_writing
    # do not shut down connection
    # All exceptions are reported through loop exception callback

    payload = b"x" * (512*1024)

    class ClientRaiseDataReceived(AsyncClient):
        def data_received(self, data):
            raise SomeException("data_received")

    class ClientRaiseGetBuffer(AsyncClient):
        def get_buffer(self, hint):
            raise SomeException("get_buffer")

    class ClientRaiseBufferUpdated(AsyncClient):
        def buffer_updated(self, bytes_read):
            raise SomeException("buffer_updated")

    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, protocol_factory=ClientRaiseDataReceived, ct=conn_type, is_buffered=False) as client:
            with exc_queue() as excq:
                client.transport.write(payload)
                with pytest.raises(SomeException, match="data_received"):
                    await client.wait_closed()
                assert isinstance(excq[0]["exception"], SomeException)

        assert "closed" in repr(client.transport)

        async with TestClient(server, protocol_factory=ClientRaiseGetBuffer, ct=conn_type, is_buffered=True) as client:
            with exc_queue() as excq:
                client.transport.write(payload)
                with pytest.raises(SomeException, match="get_buffer"):
                    await client.wait_closed()
                assert isinstance(excq[0]["exception"], SomeException)

        assert "closed" in repr(client.transport)

        async with TestClient(server, protocol_factory=ClientRaiseBufferUpdated, ct=conn_type, is_buffered=True) as client:
            with exc_queue() as excq:
                client.transport.write(payload)
                with pytest.raises(SomeException, match="buffer_updated"):
                    await client.wait_closed()
                assert isinstance(excq[0]["exception"], SomeException)

        assert "closed" in repr(client.transport)


async def test_write_wrong_type(conn_type):
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


async def test_bad_buffer(conn_type):
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


async def test_maybe_copy():
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


async def test_contextvar(conn_type, buffered_protocol):
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
            reply = await client.readn(len(payload))

            # Initiate disconnect from the server side
            server_client = await server.get_any_server_client()
            server_client.transport.close()
            await client.wait_closed()

            # Every event loop does it differently
            # There is actually nothing to test here but I left this test anyway
            # because it highlights what each loop does with contextvars

            assert var_values[0] == ('connection_made', 'begin')


async def test_transport_base(conn_type):
    async with TestServer(ct=conn_type) as server:
        async with TestClient(server, ct=conn_type) as client:
            assert isinstance(client.transport, Transport)
            client.close()
            await client.wait_closed()


async def test_start_tls():
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
            except:
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
            except:
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


async def test_peername(conn_type):
    async with TestServer(ct=conn_type, is_buffered=buffered_protocol) as server:
        async with TestClient(server, ct=conn_type, is_buffered=buffered_protocol) as client:
            server_client = await server.get_any_server_client()
            client_peername = client.transport.get_extra_info('peername')
            client_sockname = client.transport.get_extra_info('sockname')
            server_peername = server_client.transport.get_extra_info('peername')
            server_sockname = server_client.transport.get_extra_info('sockname')
            assert client_peername == server_sockname
            assert server_peername == client_sockname


async def test_ssl_server_hostname_not_passed(ssl_conn_type):
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
            async with TestClient(server, ct=ssl_conn_type, server_hostname="") as client:
                pass


@pytest.mark.parametrize("timeout_name", [
    "ssl_shutdown_timeout",
    "ssl_handshake_timeout",
])
@pytest.mark.parametrize("timeout_value", [0, -1])
async def test_ssl_timeout_validation(ssl_conn_type, timeout_name, timeout_value):
    kwargs = {timeout_name: timeout_value}
    match = f"{timeout_name} should be a positive number"

    with pytest.raises(ValueError, match=match):
        async with TestServer(ct=ssl_conn_type, **kwargs) as server:
            pass

    async with TestServer(ct=ssl_conn_type) as server:
        with pytest.raises(ValueError, match=match):
            async with TestClient(server, ct=ssl_conn_type, **kwargs) as client:
                pass


async def test_ssl_handshake_timeout(ssl_conn_type):
    async with TestServer(ct=ssl_conn_type, ssl_handshake_timeout=0.01) as server:
        reader, writer = await asyncio.open_connection(server.host, server.port)
        try:
            with pytest.raises((asyncio.IncompleteReadError, ConnectionResetError)):
                await asyncio.wait_for(reader.readexactly(1), timeout=1.0)
        finally:
            writer.close()
            await writer.wait_closed()


async def test_ssl_shutdown_timeout(ssl_conn_type):
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
