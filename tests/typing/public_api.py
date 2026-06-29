import asyncio
import ssl
from typing import BinaryIO, Callable, Optional

from typing_extensions import assert_type

import aiofastnet


class ClientProtocol(asyncio.Protocol):
    pass


async def check_public_api(
    loop: asyncio.AbstractEventLoop,
    ssl_context: ssl.SSLContext,
    transport: asyncio.Transport,
    protocol: asyncio.Protocol,
    file: BinaryIO,
) -> None:
    connection_transport, connection_protocol = await aiofastnet.create_connection(
        loop,
        ClientProtocol,
        "localhost",
        443,
        ssl=ssl_context,
    )
    assert_type(connection_transport, asyncio.Transport)
    assert_type(connection_protocol, ClientProtocol)

    server = await aiofastnet.create_server(
        loop,
        ClientProtocol,
        "localhost",
        443,
        ssl=ssl_context,
    )
    assert_type(server, asyncio.Server)

    reader, writer = await aiofastnet.open_connection(
        loop,
        "localhost",
        443,
        ssl=ssl_context,
    )
    assert_type(reader, asyncio.StreamReader)
    assert_type(writer, asyncio.StreamWriter)

    stream_server = await aiofastnet.start_server(
        loop,
        lambda reader, writer: None,
        "localhost",
        443,
        ssl=ssl_context,
    )
    assert_type(stream_server, asyncio.Server)

    tls_transport = await aiofastnet.start_tls(
        loop,
        transport,
        protocol,
        ssl_context,
    )
    assert_type(tls_transport, asyncio.Transport)

    assert_type(
        await aiofastnet.sendfile(loop, transport, file),
        None,
    )
    assert_type(
        aiofastnet.patch_loop(loop),
        asyncio.AbstractEventLoop,
    )
    assert_type(
        aiofastnet.loop_factory(),
        Callable[[], asyncio.AbstractEventLoop],
    )
    policy = aiofastnet.install_policy()
    assert_type(policy.get_event_loop(), asyncio.AbstractEventLoop)
    assert_type(policy.new_event_loop(), asyncio.AbstractEventLoop)

    assert_type(aiofastnet.aiofn_is_buffered_protocol(protocol), bool)
    assert_type(aiofastnet.Protocol(), aiofastnet.Protocol)
    assert_type(aiofastnet.Transport(), aiofastnet.Transport)
    assert_type(aiofastnet.OPENSSL_DYN_LIBS, Optional[aiofastnet.OpenSSLDynLibs])
