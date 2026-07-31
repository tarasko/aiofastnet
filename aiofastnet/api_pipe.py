# Portions of this file are derived from CPython's asyncio sources
# (notably asyncio.unix_events).
# Copyright (c) Python Software Foundation.
# Licensed under the Python Software Foundation License Version 2.
# See LICENSES/PSF-2.0.txt and THIRD_PARTY_NOTICES for details.

import os

from .api_utils import _logger
from .transport import SelectorReadPipeTransport, SelectorWritePipeTransport
from .wrapped_transport import _get_original_loop_method, _should_fallback_to_asyncio, _WrappedProtocol


async def _connect_pipe_asyncio(loop, method_name, protocol_factory, pipe):
    def wrapped_protocol_factory():
        return _WrappedProtocol(protocol_factory())

    connect_pipe = _get_original_loop_method(loop, method_name)
    _transport, protocol = await connect_pipe(wrapped_protocol_factory, pipe)
    wrapped_transport = protocol._wrapped_transport
    user_protocol = protocol._protocol
    protocol._wrapped_transport = None
    return wrapped_transport, user_protocol


async def connect_read_pipe(loop, protocol_factory, pipe):
    if _should_fallback_to_asyncio(loop):
        return await _connect_pipe_asyncio(loop, "connect_read_pipe", protocol_factory, pipe)
    if os.name == "nt":
        raise NotImplementedError("Selector event loops do not support pipes on Windows")

    protocol = protocol_factory()
    waiter = loop.create_future()
    transport = SelectorReadPipeTransport(loop, pipe, protocol, waiter)

    try:
        await waiter
    except:
        transport.close()
        raise

    if loop.get_debug():
        _logger.debug("Read pipe %r connected: (%r, %r)", pipe.fileno(), transport, protocol)
    return transport, protocol


async def connect_write_pipe(loop, protocol_factory, pipe):
    if _should_fallback_to_asyncio(loop):
        return await _connect_pipe_asyncio(loop, "connect_write_pipe", protocol_factory, pipe)
    if os.name == "nt":
        raise NotImplementedError("Selector event loops do not support pipes on Windows")

    protocol = protocol_factory()
    waiter = loop.create_future()
    transport = SelectorWritePipeTransport(loop, pipe, protocol, waiter)

    try:
        await waiter
    except:
        transport.close()
        raise

    if loop.get_debug():
        _logger.debug("Write pipe %r connected: (%r, %r)", pipe.fileno(), transport, protocol)
    return transport, protocol
