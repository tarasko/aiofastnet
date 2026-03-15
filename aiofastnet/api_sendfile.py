import asyncio

from .transport import Transport as aiofn_Transport, SelectorSocketTransport
from .wrapped_transport import _WrappedTransport


async def sendfile(loop: asyncio.AbstractEventLoop,
                   transport,
                   file,
                   offset=0,
                   count=None,
                   *,
                   fallback=True):
    # For _WrappedTransports (ProactorEventLoop is used) use loop.sendfile
    # For aiofastnet SelectorSocketTransport use loop.sock_sendfile
    # Anything else raise NotImplementedError()
    # Maybe I will improve it in the future but for now,
    # user must be prepared for NotImplementedError().

    if isinstance(transport, _WrappedTransport):
        transport = transport._transport

    if not isinstance(transport, aiofn_Transport):
        try:
            return await loop.sendfile(transport, file, offset, count, fallback=False)
        except RuntimeError as exc:
            if "fallback is disabled" in str(exc):
                raise NotImplementedError()
            else:
                raise

    if transport.is_closing():
        raise RuntimeError("Transport is closing")

    if isinstance(transport, SelectorSocketTransport):
        return await transport.sendfile(file, offset, count)

    raise NotImplementedError()
