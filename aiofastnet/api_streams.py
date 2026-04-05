from asyncio.streams import StreamReader, StreamWriter, StreamReaderProtocol
from .api_create_server import create_server
from .api_create_connection import create_connection

_DEFAULT_LIMIT = 2 ** 16 # 64 KiB


async def open_connection(loop, host=None, port=None, *,
                          limit=_DEFAULT_LIMIT, **kwds):
    """A wrapper for create_connection() returning a (reader, writer) pair.

    The reader returned is a StreamReader instance; the writer is a
    StreamWriter instance.

    The arguments are all the usual arguments to create_connection()
    except protocol_factory; most common are positional host and port,
    with various optional keyword arguments following.

    Additional optional keyword arguments is limit (to set the buffer limit
    passed to the StreamReader).
    """
    kwds.pop("loop", None)
    reader = StreamReader(limit=limit, loop=loop)
    protocol = StreamReaderProtocol(reader, loop=loop)
    transport, _ = await create_connection(
        loop, lambda: protocol, host, port, **kwds)
    writer = StreamWriter(transport, protocol, reader, loop)
    return reader, writer


async def start_server(loop, client_connected_cb, host=None, port=None, *,
                       limit=_DEFAULT_LIMIT, **kwds):
    """Start a socket server, call back for each client connected.

    The first parameter, `client_connected_cb`, takes two parameters:
    client_reader, client_writer.  client_reader is a StreamReader
    object, while client_writer is a StreamWriter object.  This
    parameter can either be a plain callback function or a coroutine;
    if it is a coroutine, it will be automatically converted into a
    Task.

    The rest of the arguments are all the usual arguments to
    loop.create_server() except protocol_factory; most common are
    positional host and port, with various optional keyword arguments
    following.  The return value is the same as loop.create_server().

    Additional optional keyword argument is limit (to set the buffer
    limit passed to the StreamReader).

    The return value is the same as loop.create_server(), i.e. a
    Server object which can be used to stop the service.
    """
    def factory():
        reader = StreamReader(limit=limit, loop=loop)
        protocol = StreamReaderProtocol(reader, client_connected_cb,
                                        loop=loop)
        return protocol

    return await create_server(loop, factory, host, port, **kwds)
