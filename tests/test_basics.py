import asyncio
import os
import ssl
from _contextvars import ContextVar

import pytest

import aiofastnet
from aiofastnet import start_tls
from aiofastnet.utils import aiofn_maybe_copy_buffer
from aiofastnet.transport import Transport
from tests.utils import TestClient, TestServer, \
    multiloop_event_loop_policy, make_test_ssl_contexts, ConnectionType, \
    AsyncClient, TestException, exc_queue, _logger

event_loop_policy = multiloop_event_loop_policy()


@pytest.fixture
async def loop_debug():
    asyncio.get_running_loop().set_debug(True)


@pytest.fixture(params=["tcp", "ssl"])
def conn_type(request):
    if request.param == "tcp":
        return ConnectionType(name="tcp")
    else:
        server_context, client_context = make_test_ssl_contexts("tests/test.crt", "tests/test.key")
        return ConnectionType(
            name="ssl",
            server_ssl_context=server_context,
            client_ssl_context=client_context,
        )

@pytest.fixture(params=["simple", "buffered"])
def buffered_protocol(request):
    return request.param == "buffered"


@pytest.mark.parametrize("msg_size", [1, 2, 3, 4, 5, 6, 7, 8, 29, 64, 256 * 1024, 6 * 1024 * 1024])
async def test_echo(msg_size, conn_type, buffered_protocol):
    payload = b"x" * msg_size

    async with TestServer(ssl_context=conn_type.server_ssl_context, is_buffered=buffered_protocol) as server:
        async with TestClient(server, ssl_context=conn_type.client_ssl_context, is_buffered=buffered_protocol) as client:
            client.write(payload)
            echoed = await client.readn(msg_size)
            assert echoed == payload


@pytest.mark.parametrize("msg_size", [1, 32, 64, 256 * 1024, 6 * 1024 * 1024, 20 * 1024 * 1024])
@pytest.mark.parametrize("num_lines", [1, 32, 4000])
async def test_echo_writelines(msg_size, num_lines, conn_type, buffered_protocol):
    payload = b"x" * msg_size

    async with TestServer(ssl_context=conn_type.server_ssl_context, is_buffered=buffered_protocol) as server:
        async with TestClient(server, ssl_context=conn_type.client_ssl_context, is_buffered=buffered_protocol) as client:
            client.write_in_lines(payload, num_lines)
            echoed = await client.readn(msg_size)
            assert echoed == payload


async def test_write_paused(conn_type):
    payload = b"x" * (1024)

    async with TestServer(ssl_context=conn_type.server_ssl_context) as server:
        async with TestClient(server, ssl_context=conn_type.client_ssl_context) as client:
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


async def test_writelines_paused(conn_type):
    msg1 = b"a" * 256 
    msg2 = b"b" * 256 * 2
    msg3 = b"c" * 256 * 3

    total_batch_size = len(msg1) + len(msg2) + len(msg3)

    async with TestServer(ssl_context=conn_type.server_ssl_context) as server:
        async with TestClient(server, ssl_context=conn_type.client_ssl_context) as client:
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
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        pytest.skip("aiofastnet doesn't work with ProactorEventLoop")

    payload = b"x" * (20*1024*1024)

    async with TestServer(ssl_context=conn_type.server_ssl_context) as server:
        async with TestClient(server, ssl_context=conn_type.client_ssl_context) as client:
            client.transport.write(payload)
            client.transport.pause_reading()
            with pytest.raises(asyncio.TimeoutError):
                await client.wait_new_data(0.2)
            client.transport.resume_reading()

            await client.wait_new_data(0.2)
            client.transport.pause_reading()

            with pytest.raises(asyncio.TimeoutError):
                await client.wait_new_data(0.2)

            client.transport.resume_reading()


async def test_ssl_renegotiate_midstream():
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        pytest.skip("aiofastnet doesn't work with ProactorEventLoop")

    server_context, client_context = make_test_ssl_contexts("tests/test.crt", "tests/test.key")
    server_context.minimum_version = ssl.TLSVersion.TLSv1_2
    server_context.maximum_version = ssl.TLSVersion.TLSv1_2
    client_context.minimum_version = ssl.TLSVersion.TLSv1_2
    client_context.maximum_version = ssl.TLSVersion.TLSv1_2

    preface = b"A" * (4 * 1024)
    payload = b"B" * (4 * 1024)
    suffix = b"C" * (4 * 1024)

    async with TestServer(ssl_context=server_context) as server:
        async with TestClient(server, ssl_context=client_context) as client:

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


async def test_exc_eof_received(conn_type):
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        pytest.skip("aiofastnet doesn't work with ProactorEventLoop")

    class ClientRaiseEofReceived(AsyncClient):
        def eof_received(self):
            raise TestException("eof_received")

    async with TestServer(ssl_context=conn_type.server_ssl_context) as server:
        async with TestClient(server, protocol_factory=ClientRaiseEofReceived, ssl_context=conn_type.client_ssl_context, is_buffered=True) as client:
            with exc_queue() as excq:
                # Initiate disconnect from the server side
                server_client = await server.get_any_server_client()
                server_client.transport.close()

                with pytest.raises(TestException, match="eof_received"):
                    await client.wait_closed()
                assert isinstance(excq[0]["exception"], TestException)


async def test_exc_connection_made(conn_type):
    if os.name == 'nt' and isinstance(asyncio.get_running_loop(), asyncio.ProactorEventLoop):
        pytest.skip("exceptions from connection_made has unspecified behavior in asyncio")

    class ClientRaiseConnectionMade(AsyncClient):
        def connection_made(self, transport):
            super().connection_made(transport)
            raise TestException("connection_made")

    payload = b"x" * (20*1024*1024)

    async with TestServer(ssl_context=conn_type.server_ssl_context) as server:
        with exc_queue() as excq:
            async with TestClient(server, protocol_factory=ClientRaiseConnectionMade, ssl_context=conn_type.client_ssl_context, is_buffered=False) as client:
                assert isinstance(excq[0]["exception"], TestException)
                client.transport.write(payload)
                reply = await client.readn(len(payload))
                assert reply == payload
                client.close()
                await client.wait_closed()


async def test_exc_pause_writing(conn_type):
    class ClientRaisePauseWriting(AsyncClient):
        def pause_writing(self):
            super().pause_writing()
            raise TestException("pause_writing")

    payload = b"x" * 1024
    num_sent = 0

    async with TestServer(ssl_context=conn_type.server_ssl_context) as server:
        async with TestClient(server, protocol_factory=ClientRaisePauseWriting, ssl_context=conn_type.client_ssl_context, is_buffered=False) as client:
            with exc_queue() as excq:
                while not client.is_writing_paused:
                    client.transport.write(payload)
                    num_sent += 1

                reply = await client.readn(len(payload) * num_sent)
                assert reply == (payload * num_sent)
                assert isinstance(excq[0]["exception"], TestException)
                client.close()
                await client.wait_closed()


async def test_exc_resume_writing(loop_debug, conn_type):
    class ClientRaiseResumeWriting(AsyncClient):
        def resume_writing(self):
            super().resume_writing()
            raise TestException("resume_writing")

    payload = b"x" * 1024
    num_sent = 0

    async with TestServer(ssl_context=conn_type.server_ssl_context) as server:
        async with TestClient(server, protocol_factory=ClientRaiseResumeWriting, ssl_context=conn_type.client_ssl_context, is_buffered=False) as client:
            with exc_queue() as excq:
                while not client.is_writing_paused:
                    client.transport.write(payload)
                    num_sent += 1

                reply = await client.readn(len(payload) * num_sent)
                assert reply == (payload * num_sent)
                assert isinstance(excq[0]["exception"], TestException)
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

    payload = b"x" * (20*1024*1024)

    class ClientRaiseDataReceived(AsyncClient):
        def data_received(self, data):
            raise TestException("data_received")

    class ClientRaiseGetBuffer(AsyncClient):
        def get_buffer(self, hint):
            raise TestException("get_buffer")

    class ClientRaiseBufferUpdated(AsyncClient):
        def buffer_updated(self, bytes_read):
            raise TestException("buffer_updated")

    async with TestServer(ssl_context=conn_type.server_ssl_context) as server:
        async with TestClient(server, protocol_factory=ClientRaiseDataReceived, ssl_context=conn_type.client_ssl_context, is_buffered=False) as client:
            with exc_queue() as excq:
                client.transport.write(payload)
                with pytest.raises(TestException, match="data_received"):
                    await client.wait_closed()
                assert isinstance(excq[0]["exception"], TestException)

        async with TestClient(server, protocol_factory=ClientRaiseGetBuffer, ssl_context=conn_type.client_ssl_context, is_buffered=True) as client:
            with exc_queue() as excq:
                client.transport.write(payload)
                with pytest.raises(TestException, match="get_buffer"):
                    await client.wait_closed()
                assert isinstance(excq[0]["exception"], TestException)

        async with TestClient(server, protocol_factory=ClientRaiseBufferUpdated, ssl_context=conn_type.client_ssl_context, is_buffered=True) as client:
            with exc_queue() as excq:
                client.transport.write(payload)
                with pytest.raises(TestException, match="buffer_updated"):
                    await client.wait_closed()
                assert isinstance(excq[0]["exception"], TestException)


async def test_write_wrong_type(conn_type):
    async with TestServer(ssl_context=conn_type.server_ssl_context) as server:
        async with TestClient(server, ssl_context=conn_type.client_ssl_context) as client:
            with pytest.raises(TypeError):
                client.transport.write(42)

            with pytest.raises(TypeError):
                client.transport.writelines([42])

            with pytest.raises(TypeError):
                client.transport.writelines(42)


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


    async with TestServer(ssl_context=conn_type.server_ssl_context, is_buffered=buffered_protocol) as server:
        async with TestClient(server, protocol_factory=Client, ssl_context=conn_type.client_ssl_context, is_buffered=buffered_protocol) as client:
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
    async with TestServer(ssl_context=conn_type.server_ssl_context) as server:
        async with TestClient(server, ssl_context=conn_type.client_ssl_context) as client:
            assert isinstance(client.transport, Transport)
            client.close()
            await client.wait_closed()


async def test_start_tls(loop_debug):
    server_ssl_context, client_ssl_context = make_test_ssl_contexts(
        "tests/test.crt", "tests/test.key")

    test_msg = b"hello world!"
    tls_upgrade_cmd = b"start_tls"
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
            elif data == close_cmd:
                self._transport.close()
            else:
                self._transport.write(data)

        async def _start_tls(self):
            try:
                self._transport = await aiofastnet.start_tls(
                    self._loop,
                    self._transport,
                    self,
                    server_ssl_context,
                    server_side=True)
                _logger.debug("Server(%d): start_tls completed", self._gen)
                self._gen += 1
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

            client.transport.write(test_msg)
            reply = await client.readn(len(test_msg))
            assert reply == test_msg

            client.transport.write(tls_upgrade_cmd)
            reply = await client.readn(len(tls_upgrade_cmd))
            assert reply == tls_upgrade_cmd
            await client.start_tls(client_ssl_context)

            client.transport.write(test_msg)
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


# Exception from send due to file error should cause fatal error
# Graceful disconnect should flush all data
