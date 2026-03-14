import asyncio
import socket

from .transport import Transport as aiofn_Transport
from .wrapped_transport import _WrappedTransport, _should_fallback_to_asyncio


class _AioSendfileFallbackProtocol(asyncio.Protocol):
    def __init__(self, loop, transport):
        self._loop = loop
        self._transport = transport
        self._proto = transport.get_protocol()
        self._should_resume_reading = transport.is_reading()
        self._should_resume_writing = self._is_transport_write_paused(transport)

        transport.pause_reading()
        transport.set_protocol(self)
        self._write_ready_fut = loop.create_future() if self._should_resume_writing else None

    @staticmethod
    def _is_transport_write_paused(transport) -> bool:
        try:
            _, high = transport.get_write_buffer_limits()
        except Exception:
            return False

        return transport.get_write_buffer_size() > high

    async def drain(self):
        if self._transport.is_closing():
            raise ConnectionError("Connection closed by peer")
        fut = self._write_ready_fut
        if fut is None:
            return
        await fut

    def connection_made(self, transport):
        raise RuntimeError("Invalid state: connection should have been established already.")

    def connection_lost(self, exc):
        if self._write_ready_fut is not None:
            if exc is None:
                self._write_ready_fut.set_exception(ConnectionError("Connection is closed by peer"))
            else:
                self._write_ready_fut.set_exception(exc)
        self._proto.connection_lost(exc)

    def pause_writing(self):
        if self._write_ready_fut is not None:
            return
        self._write_ready_fut = self._loop.create_future()

    def resume_writing(self):
        if self._write_ready_fut is None:
            return
        self._write_ready_fut.set_result(False)
        self._write_ready_fut = None

    def data_received(self, data):
        raise RuntimeError("Invalid state: reading should be paused")

    def eof_received(self):
        raise RuntimeError("Invalid state: reading should be paused")

    async def restore(self):
        self._transport.set_protocol(self._proto)
        if self._should_resume_reading:
            self._transport.resume_reading()
        if self._write_ready_fut is not None:
            self._write_ready_fut.cancel()
        if self._should_resume_writing:
            self._proto.resume_writing()


def _check_sendfile_params(sock, file, offset, count):
    if 'b' not in getattr(file, 'mode', 'b'):
        raise ValueError("file should be opened in binary mode")
    if sock is not None and sock.type != socket.SOCK_STREAM:
        raise ValueError("only SOCK_STREAM type sockets are supported")
    if count is not None:
        if not isinstance(count, int):
            raise TypeError(
                "count must be a positive integer (got {!r})".format(count))
        if count <= 0:
            raise ValueError(
                "count must be a positive integer (got {!r})".format(count))
    if not isinstance(offset, int):
        raise TypeError(
            "offset must be a non-negative integer (got {!r})".format(offset))
    if offset < 0:
        raise ValueError(
            "offset must be a non-negative integer (got {!r})".format(offset))


async def sendfile(loop: asyncio.AbstractEventLoop,
                   transport,
                   file,
                   offset=0,
                   count=None,
                   *,
                   fallback=True):
    if isinstance(transport, _WrappedTransport):
        transport = transport._transport

    if _should_fallback_to_asyncio(loop) or not isinstance(transport, aiofn_Transport):
        return await loop.sendfile(transport, file, offset, count, fallback=fallback)

    if transport.is_closing():
        raise RuntimeError("Transport is closing")

    sock = transport.get_extra_info('socket')
    _check_sendfile_params(sock, file, offset, count)

    if not fallback:
        raise asyncio.SendfileNotAvailableError(
            f"native sendfile is not available for transport {transport!r}")

    if offset:
        file.seek(offset)

    blocksize = min(count, 16384) if count else 16384
    buf = bytearray(blocksize)
    total_sent = 0
    proto = _AioSendfileFallbackProtocol(loop, transport)
    try:
        while True:
            if count:
                blocksize = min(count - total_sent, blocksize)
                if blocksize <= 0:
                    return total_sent
            view = memoryview(buf)[:blocksize]
            read = await loop.run_in_executor(None, file.readinto, view)
            if not read:
                return total_sent
            transport.write(view[:read])
            await proto.drain()
            total_sent += read
    finally:
        if total_sent > 0 and hasattr(file, 'seek'):
            file.seek(offset + total_sent)
        await proto.restore()
