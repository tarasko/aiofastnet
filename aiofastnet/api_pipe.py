# Portions of this file are derived from CPython's asyncio sources
# (notably asyncio.unix_events).
# Copyright (c) Python Software Foundation.
# Licensed under the Python Software Foundation License Version 2.
# See LICENSES/PSF-2.0.txt and THIRD_PARTY_NOTICES for details.

import os

from .api_utils import _logger, _wait_and_close_transport_on_exc
from .selector_transport import SelectorReadPipeTransport, SelectorWritePipeTransport
from .wrapped_transport import _get_original_loop_method, _WrappedProtocol


async def _connect_pipe_asyncio(loop, method_name, protocol_factory, pipe):
    def wrapped_protocol_factory():
        return _WrappedProtocol(protocol_factory())

    connect_pipe = _get_original_loop_method(loop, method_name)
    _transport, protocol = await connect_pipe(wrapped_protocol_factory, pipe)
    wrapped_transport = protocol._wrapped_transport
    user_protocol = protocol._protocol
    protocol._wrapped_transport = None
    return wrapped_transport, user_protocol


def _get_proactor_context(loop):
    # Only LoopBase exposes this method; other loops continue using their
    # native Windows pipe implementation or aiofastnet's selector transports.
    get_proactor_context = getattr(loop, "get_proactor_context", None)
    if get_proactor_context is not None:
        return get_proactor_context()
    return None


async def connect_read_pipe(loop, protocol_factory, pipe):
    proactor_context = _get_proactor_context(loop)
    if proactor_context is None and os.name == "nt":
        return await _connect_pipe_asyncio(loop, "connect_read_pipe", protocol_factory, pipe)

    protocol = protocol_factory()
    waiter = loop.create_future()
    if proactor_context is None:
        transport = SelectorReadPipeTransport(loop, pipe, protocol, waiter)
    else:
        from .proactor_transport import ProactorReadPipeTransport

        transport = ProactorReadPipeTransport(proactor_context, loop, pipe, protocol, waiter)

    await _wait_and_close_transport_on_exc(waiter, transport)

    if loop.get_debug():
        _logger.debug("%r: read pipe connected: %r", transport, protocol)
    return transport, protocol


async def connect_write_pipe(loop, protocol_factory, pipe):
    proactor_context = _get_proactor_context(loop)
    if proactor_context is None and os.name == "nt":
        return await _connect_pipe_asyncio(loop, "connect_write_pipe", protocol_factory, pipe)

    protocol = protocol_factory()
    waiter = loop.create_future()
    if proactor_context is None:
        transport = SelectorWritePipeTransport(loop, pipe, protocol, waiter)
    else:
        from .proactor_transport import ProactorWritePipeTransport

        transport = ProactorWritePipeTransport(proactor_context, loop, pipe, protocol, waiter)

    await _wait_and_close_transport_on_exc(waiter, transport)

    if loop.get_debug():
        _logger.debug("%r: write pipe connected: %r", transport, protocol)
    return transport, protocol
