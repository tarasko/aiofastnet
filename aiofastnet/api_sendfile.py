import asyncio

from .transport import Transport
from .wrapped_transport import _WrappedTransport, _get_original_loop_method


async def sendfile(loop: asyncio.AbstractEventLoop,
                   transport,
                   file,
                   offset=0,
                   count=None,
                   *,
                   fallback=True):
    """
    Send a file to a transport using native sendfile when available.
    Ignores fallback argument. Always raises NotImplementedError if native
    sendfile is not available.
    """
    if isinstance(transport, _WrappedTransport):
        if not getattr(transport, "_sendfile_compatible", True):
            raise NotImplementedError()
        
        loop_sendfile = _get_original_loop_method(loop, "sendfile")
        return await loop_sendfile(
            transport._transport, file, offset, count, fallback=fallback)

    elif isinstance(transport, Transport):
        fut = transport.sendfile(file, offset, count)
        if fut is not None:
            return await fut
        else:
            return None

    else:
        loop_sendfile = _get_original_loop_method(loop, "sendfile")
        return await loop_sendfile(
            transport, file, offset, count, fallback=fallback)
