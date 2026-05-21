import asyncio
import os

from .transport import Transport
from .wrapped_transport import _WrappedTransport


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
    if os.name == "nt":
        raise NotImplementedError()

    if isinstance(transport, Transport) and not isinstance(transport, _WrappedTransport):
        return await transport.sendfile(file, offset, count)
    else:
        return await loop.sendfile(transport, file, offset, count)
