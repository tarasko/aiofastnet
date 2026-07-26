import asyncio
import os
import socket
import ssl
from collections.abc import Awaitable, Sequence
from typing import (
    Any,
    BinaryIO,
    Callable,
    TypeVar,
)
from typing import (
    Protocol as TypingProtocol,
)

from .openssl_compat import OpenSSLDynLibs as OpenSSLDynLibs
from .transport import (
    Protocol as Protocol,
)
from .transport import (
    Transport as Transport,
)
from .transport import (
    aiofn_is_buffered_protocol as aiofn_is_buffered_protocol,
)

_ProtocolT = TypeVar("_ProtocolT", bound=asyncio.BaseProtocol)
_DatagramProtocolT = TypeVar("_DatagramProtocolT", bound=asyncio.DatagramProtocol)
_Address = tuple[str | bytes, int]
_Host = str | bytes | Sequence[str | bytes] | None

class _EventLoopPolicy(TypingProtocol):
    def get_event_loop(self) -> asyncio.AbstractEventLoop: ...
    def set_event_loop(
        self,
        loop: asyncio.AbstractEventLoop | None,
    ) -> None: ...
    def new_event_loop(self) -> asyncio.AbstractEventLoop: ...

OPENSSL_DYN_LIBS: OpenSSLDynLibs | None
__version__: str
__author__: str

async def create_connection(
    loop: asyncio.AbstractEventLoop,
    protocol_factory: Callable[[], _ProtocolT],
    host: str | bytes | None = ...,
    port: int | str | None = ...,
    *,
    ssl: bool | ssl.SSLContext | None = ...,
    family: int = ...,
    proto: int = ...,
    flags: int = ...,
    sock: socket.socket | None = ...,
    local_addr: _Address | None = ...,
    server_hostname: str | None = ...,
    ssl_handshake_timeout: float | None = ...,
    ssl_shutdown_timeout: float | None = ...,
    ssl_incoming_bio_size: int | None = ...,
    ssl_outgoing_bio_size: int | None = ...,
    happy_eyeballs_delay: float | None = ...,
    interleave: int | None = ...,
    all_errors: bool = ...,
) -> tuple[asyncio.Transport, _ProtocolT]: ...

async def connect_accepted_socket(
    loop: asyncio.AbstractEventLoop,
    protocol_factory: Callable[[], _ProtocolT],
    sock: socket.socket,
    *,
    ssl: bool | ssl.SSLContext | None = ...,
    ssl_handshake_timeout: float | None = ...,
    ssl_shutdown_timeout: float | None = ...,
    ssl_incoming_bio_size: int | None = ...,
    ssl_outgoing_bio_size: int | None = ...,
) -> tuple[asyncio.Transport, _ProtocolT]: ...

async def create_datagram_endpoint(
    loop: asyncio.AbstractEventLoop,
    protocol_factory: Callable[[], _DatagramProtocolT],
    local_addr: _Address | None = ...,
    remote_addr: _Address | None = ...,
    *,
    family: int = ...,
    proto: int = ...,
    flags: int = ...,
    reuse_port: bool | None = ...,
    allow_broadcast: bool | None = ...,
    sock: socket.socket | None = ...,
) -> tuple[asyncio.DatagramTransport, _DatagramProtocolT]: ...

async def create_unix_connection(
    loop: asyncio.AbstractEventLoop,
    protocol_factory: Callable[[], _ProtocolT],
    path: str | bytes | os.PathLike[str] | os.PathLike[bytes] | None = ...,
    *,
    ssl: bool | ssl.SSLContext | None = ...,
    sock: socket.socket | None = ...,
    server_hostname: str | None = ...,
    ssl_handshake_timeout: float | None = ...,
    ssl_shutdown_timeout: float | None = ...,
    ssl_incoming_bio_size: int | None = ...,
    ssl_outgoing_bio_size: int | None = ...,
) -> tuple[asyncio.Transport, _ProtocolT]: ...

async def create_server(
    loop: asyncio.AbstractEventLoop,
    protocol_factory: Callable[[], asyncio.BaseProtocol],
    host: _Host = ...,
    port: int | str | None = ...,
    *,
    family: int = ...,
    flags: int = ...,
    sock: socket.socket | None = ...,
    backlog: int = ...,
    ssl: ssl.SSLContext | None = ...,
    reuse_address: bool | None = ...,
    reuse_port: bool | None = ...,
    keep_alive: bool | None = ...,
    ssl_handshake_timeout: float | None = ...,
    ssl_shutdown_timeout: float | None = ...,
    ssl_incoming_bio_size: int | None = ...,
    ssl_outgoing_bio_size: int | None = ...,
    start_serving: bool = ...,
) -> asyncio.Server: ...

async def create_unix_server(
    loop: asyncio.AbstractEventLoop,
    protocol_factory: Callable[[], asyncio.BaseProtocol],
    path: str | bytes | os.PathLike[str] | os.PathLike[bytes] | None = ...,
    *,
    sock: socket.socket | None = ...,
    backlog: int = ...,
    ssl: ssl.SSLContext | None = ...,
    ssl_handshake_timeout: float | None = ...,
    ssl_shutdown_timeout: float | None = ...,
    ssl_incoming_bio_size: int | None = ...,
    ssl_outgoing_bio_size: int | None = ...,
    start_serving: bool = ...,
    cleanup_socket: bool = ...,
) -> asyncio.Server: ...

async def open_connection(
    loop: asyncio.AbstractEventLoop,
    host: str | bytes | None = ...,
    port: int | str | None = ...,
    *,
    limit: int = ...,
    **kwds: Any,
) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]: ...

async def open_unix_connection(
    loop: asyncio.AbstractEventLoop,
    path: str | bytes | os.PathLike[str] | os.PathLike[bytes] | None = ...,
    *,
    limit: int = ...,
    **kwds: Any,
) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]: ...

async def start_server(
    loop: asyncio.AbstractEventLoop,
    client_connected_cb: Callable[
        [asyncio.StreamReader, asyncio.StreamWriter],
        Awaitable[None] | None,
    ],
    host: _Host = ...,
    port: int | str | None = ...,
    *,
    limit: int = ...,
    **kwds: Any,
) -> asyncio.Server: ...

async def start_unix_server(
    loop: asyncio.AbstractEventLoop,
    client_connected_cb: Callable[
        [asyncio.StreamReader, asyncio.StreamWriter],
        Awaitable[None] | None,
    ],
    path: str | bytes | os.PathLike[str] | os.PathLike[bytes] | None = ...,
    *,
    limit: int = ...,
    **kwds: Any,
) -> asyncio.Server: ...

async def start_tls(
    loop: asyncio.AbstractEventLoop,
    transport: asyncio.BaseTransport,
    protocol: asyncio.BaseProtocol,
    sslcontext: ssl.SSLContext,
    *,
    server_side: bool = ...,
    server_hostname: str | None = ...,
    ssl_handshake_timeout: float | None = ...,
    ssl_shutdown_timeout: float | None = ...,
    ssl_incoming_bio_size: int | None = ...,
    ssl_outgoing_bio_size: int | None = ...,
) -> asyncio.Transport: ...

async def sendfile(
    loop: asyncio.AbstractEventLoop,
    transport: asyncio.BaseTransport,
    file: BinaryIO,
    offset: int = ...,
    count: int | None = ...,
    *,
    fallback: bool = ...,
) -> None: ...

def patch_loop(
    loop: asyncio.AbstractEventLoop | None = ...,
) -> asyncio.AbstractEventLoop: ...

def loop_factory(
    base_factory: Callable[[], asyncio.AbstractEventLoop] | None = ...,
) -> Callable[[], asyncio.AbstractEventLoop]: ...

def install_policy(
    base_policy: _EventLoopPolicy | None = ...,
) -> _EventLoopPolicy: ...
