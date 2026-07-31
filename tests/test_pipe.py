import asyncio
import os
import tempfile

import pytest

from aiofastnet.api_pipe import connect_read_pipe, connect_write_pipe
from aiofastnet.transport import SelectorReadPipeTransport, SelectorWritePipeTransport
from tests.utils import SomeException, exc_queue


class WritePipeProtocol(asyncio.Protocol):
    def __init__(self):
        self.closed = asyncio.get_running_loop().create_future()
        self.paused = False
        self.resumed = asyncio.Event()

    def pause_writing(self):
        self.paused = True

    def resume_writing(self):
        self.paused = False
        self.resumed.set()

    def connection_lost(self, exc):
        self.closed.set_result(exc)


async def test_read_pipe(selector_loop):
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    read_fd, write_fd = os.pipe()
    read_pipe = os.fdopen(read_fd, "rb", buffering=0)
    write_pipe = os.fdopen(write_fd, "wb", buffering=0)
    transport = None

    try:
        transport, _ = await connect_read_pipe(loop, lambda: protocol, read_pipe)
        assert transport.get_extra_info("pipe") is read_pipe
        assert transport.get_protocol() is protocol

        transport.pause_reading()
        assert not transport.is_reading()
        write_pipe.write(b"hello")
        read_task = asyncio.create_task(reader.readexactly(5))
        await asyncio.sleep(0)
        assert not read_task.done()

        transport.resume_reading()
        assert transport.is_reading()
        assert await read_task == b"hello"

        write_pipe.close()
        assert await reader.read() == b""
    finally:
        write_pipe.close()
        if transport is not None and not transport.is_closing():
            transport.close()
            await asyncio.sleep(0)
        if not read_pipe.closed:
            read_pipe.close()


async def test_write_pipe(selector_loop):
    loop = asyncio.get_running_loop()
    read_fd, write_fd = os.pipe()
    read_pipe = os.fdopen(read_fd, "rb", buffering=0)
    write_pipe = os.fdopen(write_fd, "wb", buffering=0)
    protocol = WritePipeProtocol()
    transport = None

    try:
        transport, _ = await connect_write_pipe(loop, lambda: protocol, write_pipe)
        assert transport.get_extra_info("pipe") is write_pipe
        assert transport.get_protocol() is protocol
        assert transport.can_write_eof()
        with tempfile.TemporaryFile() as file:
            with pytest.raises(NotImplementedError):
                transport.sendfile(file, 0, 1)

        transport.writelines((b"hel", b"lo"))
        assert read_pipe.read(5) == b"hello"

        transport.write_eof()
        assert await protocol.closed is None
        assert read_pipe.read(1) == b""
    finally:
        if transport is not None and not transport.is_closing():
            transport.close()
            await asyncio.sleep(0)
        write_pipe.close()
        read_pipe.close()


async def test_write_pipe_drains_before_close(selector_loop):
    loop = asyncio.get_running_loop()
    read_fd, write_fd = os.pipe()
    os.set_blocking(read_fd, False)
    read_pipe = os.fdopen(read_fd, "rb", buffering=0)
    write_pipe = os.fdopen(write_fd, "wb", buffering=0)
    protocol = WritePipeProtocol()
    transport = None
    payload = b"x" * (1024 * 1024)

    async def drain_pipe():
        received = bytearray()
        while True:
            try:
                data = read_pipe.read(256 * 1024)
            except BlockingIOError:
                await asyncio.sleep(0)
                continue
            if data is None:
                await asyncio.sleep(0)
                continue
            if not data:
                return bytes(received)
            received.extend(data)

    try:
        transport, _ = await connect_write_pipe(loop, lambda: protocol, write_pipe)
        transport.set_write_buffer_limits(high=1024, low=512)
        transport.write(payload)
        assert transport.get_write_buffer_size() > 0
        assert protocol.paused

        transport.write_eof()
        received = await asyncio.wait_for(drain_pipe(), 2)
        assert received == payload
        assert await protocol.closed is None
        assert not protocol.paused
    finally:
        if transport is not None and not transport.is_closing():
            transport.close()
            await asyncio.sleep(0)
        write_pipe.close()
        read_pipe.close()


async def test_write_pipe_peer_closed(selector_loop):
    loop = asyncio.get_running_loop()
    read_fd, write_fd = os.pipe()
    write_pipe = os.fdopen(write_fd, "wb", buffering=0)
    protocol = WritePipeProtocol()
    transport = None

    try:
        transport, _ = await connect_write_pipe(loop, lambda: protocol, write_pipe)
        os.close(read_fd)
        transport.write(b"hello")
        assert isinstance(await protocol.closed, BrokenPipeError)
    finally:
        if transport is not None and not transport.is_closing():
            transport.close()
            await asyncio.sleep(0)
        write_pipe.close()


async def test_pipe_transports_reject_regular_file_without_closing_it(selector_loop):
    loop = asyncio.get_running_loop()

    with tempfile.TemporaryFile() as file:
        with pytest.raises(ValueError, match="Pipe transport is for pipes/sockets only"):
            SelectorReadPipeTransport(loop, file, asyncio.Protocol(), None)
        assert not file.closed

    with tempfile.TemporaryFile() as file:
        with pytest.raises(ValueError, match="Pipe transport is only for pipes"):
            SelectorWritePipeTransport(loop, file, asyncio.Protocol(), None)
        assert not file.closed


async def test_read_pipe_eof_received_error_closes_transport(selector_loop):
    loop = asyncio.get_running_loop()

    class EofErrorProtocol(asyncio.Protocol):
        def __init__(self):
            self.closed = loop.create_future()

        def eof_received(self):
            raise SomeException("eof_received")

        def connection_lost(self, exc):
            self.closed.set_result(exc)

    read_fd, write_fd = os.pipe()
    read_pipe = os.fdopen(read_fd, "rb", buffering=0)
    write_pipe = os.fdopen(write_fd, "wb", buffering=0)
    protocol = EofErrorProtocol()
    transport = None

    try:
        transport, _ = await connect_read_pipe(loop, lambda: protocol, read_pipe)
        with exc_queue() as excq:
            write_pipe.close()
            exc = await protocol.closed
            assert isinstance(exc, SomeException)
            assert isinstance(excq[0]["exception"], SomeException)
    finally:
        write_pipe.close()
        if transport is not None and not transport.is_closing():
            transport.close()
            await asyncio.sleep(0)
        if not read_pipe.closed:
            read_pipe.close()
