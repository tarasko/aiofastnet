import asyncio
import os

import pytest

from tests.utils import AsyncClient, SomeException, TestServer, TestClient, exc_queue, conn_type


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


def test_system_exit_data_received_not_reported(conn_type):
    contexts = []
    payload = b"x" * (512*1024)

    class ClientRaiseDataReceived(AsyncClient):
        def data_received(self, data):
            raise SystemExit(42)

    async def run():
        loop = asyncio.get_running_loop()
        old_handler = loop.get_exception_handler()
        loop.set_exception_handler(lambda loop, context: contexts.append(context))
        try:
            async with TestServer(ct=conn_type) as server:
                async with TestClient(server, protocol_factory=ClientRaiseDataReceived, ct=conn_type,
                                      is_buffered=False) as client:
                    client.transport.write(payload)
                    await asyncio.sleep(0.1)
                    assert contexts == []
        finally:
            loop.set_exception_handler(old_handler)

    with pytest.raises(SystemExit):
        asyncio.run(run())

    assert contexts == []
