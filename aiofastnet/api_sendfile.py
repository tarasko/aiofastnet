import asyncio
import os

from .transport import Transport, SocketTransport


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

    if not isinstance(transport, Transport):
        return await loop.sendfile(transport, file, offset, count, fallback=False)

    if transport.is_closing():
        raise RuntimeError("Transport is closing")

    if isinstance(transport, SocketTransport):
        return await transport.sendfile(file, offset, count)

    raise NotImplementedError()
