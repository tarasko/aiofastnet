import asyncio
import os

from .transport import Transport, aiofn_is_buffered_protocol
from .utils import aiofn_validate_and_maybe_copy_buffer


def _should_fallback_to_asyncio(loop: asyncio.AbstractEventLoop) -> bool:
    if os.name != "nt":
        return False

    proactor_event_loop = getattr(asyncio, "ProactorEventLoop", None)
    if proactor_event_loop is None:
        return False

    return isinstance(loop, proactor_event_loop)


class _WrappedTransport(Transport):
    __slots__ = ('_transport',)

    def __init__(self, transport: asyncio.Transport):
        super().__init__()
        self._transport = transport

    def get_extra_info(self, name, default=None):
        return self._transport.get_extra_info(name, default)

    def is_closing(self):
        return self._transport.is_closing()

    def close(self):
        return self._transport.close()

    def set_protocol(self, protocol):
        if aiofn_is_buffered_protocol(protocol):
            wrapped_protocol = _WrappedBufferedProtocol(protocol)
        else:
            wrapped_protocol = _WrappedProtocol(protocol)
        self._transport.set_protocol(wrapped_protocol)

    def get_protocol(self):
        wrapped_protocol: _WrappedProtocolBase = self._transport.get_protocol()
        assert isinstance(wrapped_protocol, _WrappedProtocolBase), \
            "must be our protocol wrapper"
        return wrapped_protocol._protocol

    def is_reading(self):
        return self._transport.is_reading()

    def pause_reading(self):
        return self._transport.pause_reading()

    def resume_reading(self):
        return self._transport.resume_reading()

    def set_write_buffer_limits(self, high=None, low=None):
        return self._transport.set_write_buffer_limits(high, low)

    def get_write_buffer_size(self):
        return self._transport.get_write_buffer_size()

    def get_write_buffer_limits(self):
        return self._transport.get_write_buffer_limits()

    def write(self, data):
        return self._transport.write(aiofn_validate_and_maybe_copy_buffer(data))

    def writelines(self, list_of_data):
        lst = [aiofn_validate_and_maybe_copy_buffer(data)
               for data in list_of_data if data]
        self._transport.writelines(lst)

    def write_eof(self):
        return self._transport.write_eof()

    def can_write_eof(self):
        return self._transport.can_write_eof()

    def abort(self):
        return self._transport.abort()


class _WrappedProtocolBase(asyncio.BaseProtocol):
    __slots__ = ('_protocol', '_wrapped_transport')

    def __init__(self, protocol):
        self._protocol = protocol
        self._wrapped_transport = None

    def connection_made(self, transport):
        self._wrapped_transport = _WrappedTransport(transport)
        return self._protocol.connection_made(self._wrapped_transport)

    def connection_lost(self, exc):
        return self._protocol.connection_lost(exc)

    def pause_writing(self):
        return self._protocol.pause_writing()

    def resume_writing(self):
        return self._protocol.resume_writing()


class _WrappedProtocol(_WrappedProtocolBase, asyncio.Protocol):
    def data_received(self, data):
        return self._protocol.data_received(data)


class _WrappedBufferedProtocol(_WrappedProtocolBase, asyncio.BufferedProtocol):
    def get_buffer(self, sizehint):
        return self._protocol.get_buffer(sizehint)

    def buffer_updated(self, nbytes):
        return self._protocol.buffer_updated(nbytes)

