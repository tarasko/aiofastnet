import asyncio
import os
import tempfile

import pytest

from aiofastnet.transport import SelectorReadPipeTransport, SelectorWritePipeTransport
from aiofastnet.wrapped_transport import _WrappedTransport
from tests.utils import NO_AIOFN, AsyncClient, SocketPair, SomeException, exc_queue


@pytest.fixture
def native_pipe_loop(selector_loop):
    if os.name == "nt":
        pytest.skip("the Windows selector loop does not support pipes")


@pytest.mark.parametrize("msg_size", [1, 1024 * 1024])
async def test_pipe(all_loops, conn_type_pipe, msg_size):
    async with SocketPair(conn_type_pipe) as (reader, writer):
        assert reader.transport.get_extra_info("pipe") is not None
        assert writer.transport.get_extra_info("pipe") is not None
        assert reader.transport.get_protocol() is reader
        assert writer.transport.get_protocol() is writer
        assert writer.transport.can_write_eof()
        if os.name == "nt" and not NO_AIOFN:
            assert isinstance(reader.transport, _WrappedTransport)
            assert isinstance(writer.transport, _WrappedTransport)

        payload = b"p" * msg_size
        writer.write(payload)
        result = await reader.readn(len(payload))
        assert payload == result

        reader.transport.pause_reading()
        read_task = asyncio.create_task(reader.readn(5))
        writer.write_in_lines(b"hello", 2)
        await asyncio.sleep(0)
        assert not read_task.done()

        reader.transport.resume_reading()
        assert await read_task == b"hello"

        writer.transport.write_eof()
        await writer.wait_closed()
        await reader.wait_closed()
        assert reader.is_eof_received


async def test_write_pipe_drains_before_close(native_pipe_loop, conn_type_pipe):
    payload = b"x" * (1024 * 1024)

    async with SocketPair(conn_type_pipe) as (reader, writer):
        reader.transport.pause_reading()
        writer.transport.set_write_buffer_limits(high=1024, low=512)
        writer.write(payload)
        assert writer.transport.get_write_buffer_size() > 0
        assert writer.is_writing_paused

        writer.transport.write_eof()
        reader.transport.resume_reading()
        assert await reader.readn(len(payload), timeout=2) == payload
        await writer.wait_closed()
        assert not writer.is_writing_paused


@pytest.mark.parametrize("with_backlog", [False, True])
async def test_write_pipe_peer_closed(native_pipe_loop, conn_type_pipe, with_backlog):
    async with SocketPair(conn_type_pipe) as (reader, writer):
        if with_backlog:
            reader.transport.pause_reading()
            writer.write(b"x" * (1024 * 1024))
            assert writer.transport.get_write_buffer_size() > 0

        reader.abort()
        await reader.wait_closed()

        if with_backlog:
            with pytest.raises(BrokenPipeError):
                await writer.wait_closed()
        else:
            await writer.wait_closed()


async def test_write_pipe_sendfile_not_supported(native_pipe_loop, conn_type_pipe):
    async with SocketPair(conn_type_pipe) as (_reader, writer):
        with tempfile.TemporaryFile() as file:
            with pytest.raises(NotImplementedError):
                writer.transport.sendfile(file, 0, 1)


async def test_pipe_transports_reject_regular_file_without_closing_it(native_pipe_loop):
    loop = asyncio.get_running_loop()

    with tempfile.TemporaryFile() as file:
        with pytest.raises(ValueError, match="Pipe transport is for pipes/sockets only"):
            SelectorReadPipeTransport(loop, file, asyncio.Protocol(), None)
        assert not file.closed

    with tempfile.TemporaryFile() as file:
        with pytest.raises(ValueError, match="Pipe transport is only for pipes"):
            SelectorWritePipeTransport(loop, file, asyncio.Protocol(), None)
        assert not file.closed


async def test_read_pipe_eof_received_error_closes_transport(native_pipe_loop, conn_type_pipe):
    class EofErrorClient(AsyncClient):
        def eof_received(self):
            raise SomeException("eof_received")

    async with SocketPair(conn_type_pipe, server_protocol_factory=EofErrorClient) as (reader, writer):
        with exc_queue() as excq:
            writer.close()
            with pytest.raises(SomeException):
                await reader.wait_closed()
            assert isinstance(excq[0]["exception"], SomeException)
