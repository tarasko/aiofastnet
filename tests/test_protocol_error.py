import asyncio
import gc
import os
import warnings

import pytest

from tests.utils import AsyncClient, SomeException, TestServer, TestClient, exc_queue


async def test_exc_eof_received(all_loops, conn_type):
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


async def test_exc_connection_made(all_loops, conn_type):
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


async def test_exc_pause_writing(all_loops, conn_type):
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


async def test_exc_resume_writing(all_loops, conn_type):
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


async def test_exc_all(all_loops, conn_type):
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


@pytest.mark.parametrize("exc", [SystemExit, KeyboardInterrupt], ids=["sys", "ctrlc"])
@pytest.mark.parametrize("meth", ["connection_made", "connection_lost", "pause_writing", "resume_writing", "data_received", "get_buffer", "buffer_updated", "eof_received"])
def test_system_exit_not_reported(conn_type, exc, meth):
    class ServerProtocol:
        def connection_made(self, transport):
            self.transport = transport

        def data_received(self, data):
            self.transport.write(data)
            if meth == "eof_received":
                self.transport.close()

    class ClientRaiseException(AsyncClient):
        def connection_made(self, transport):
            if meth == "connection_made":
                raise exc(42)
            super().connection_made(transport)

        def connection_lost(self, e):
            if meth == "connection_lost":
                raise exc(42)
            super().connection_lost(e)

        def pause_writing(self):
            if meth == "pause_writing":
                raise exc(42)
            super().pause_writing()

        def resume_writing(self):
            if meth == "resume_writing":
                raise exc(42)
            super().resume_writing()

        def data_received(self, data):
            if meth == "data_received":
                raise exc(42)
            super().data_received(data)

        def get_buffer(self, hint):
            if meth == "get_buffer":
                raise exc(42)
            return super().get_buffer(hint)

        def buffer_updated(self, bytes_read):
            if meth == "buffer_updated":
                raise exc(42)
            return super().buffer_updated(bytes_read)

        def eof_received(self):
            if meth == "eof_received":
                raise exc(42)
            return super().eof_received()

        def is_buffered_protocol(self):
            return meth in ("get_buffer", "buffer_updated")

    payload = b"x" * (64*1024)
    excq = []
    async def run():
        asyncio.get_running_loop().set_debug(True)
        with exc_queue(excq):
            async with TestServer(protocol_factory=ServerProtocol, ct=conn_type) as server:
                async with TestClient(server,
                                      protocol_factory=ClientRaiseException,
                                      ct=conn_type,
                                      is_buffered=False) as client:
                    if meth in ('pause_writing', 'resume_writing'):
                        while not client.is_writing_paused:
                            client.transport.write(payload)
                    else:
                        client.transport.write(payload)
                    await asyncio.sleep(0.1)

    if meth in ("connection_made", "connection_lost") and conn_type.name in (
        "ssl_mbio",
        "ssl_sbio",
        "ktls",
    ):
        with warnings.catch_warnings():
            warnings.filterwarnings(
                "ignore",
                message=r"deleting unclosed SSLTransport_Socket",
                category=ResourceWarning,
            )
            with pytest.raises(exc):
                asyncio.run(run())
            gc.collect()
    else:
        with pytest.raises(exc):
            asyncio.run(run())

    assert excq == []
