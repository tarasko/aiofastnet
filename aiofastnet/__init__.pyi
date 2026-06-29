import asyncio
import os
import socket
import ssl
from typing import (
    Any,
    Awaitable,
    BinaryIO,
    Callable,
    Optional,
    Protocol as TypingProtocol,
    Sequence,
    Tuple,
    TypeVar,
    Union,
)

from .openssl_compat import OpenSSLDynLibs as OpenSSLDynLibs
from .transport import (
    Protocol as Protocol,
    Transport as Transport,
    aiofn_is_buffered_protocol as aiofn_is_buffered_protocol,
)

_ProtocolT = TypeVar("_ProtocolT", bound=asyncio.BaseProtocol)
_Address = Tuple[Union[str, bytes], int]
_Host = Optional[Union[str, bytes, Sequence[Union[str, bytes]]]]

class _EventLoopPolicy(TypingProtocol):
    def get_event_loop(self) -> asyncio.AbstractEventLoop: ...
    def set_event_loop(
        self,
        loop: Optional[asyncio.AbstractEventLoop],
    ) -> None: ...
    def new_event_loop(self) -> asyncio.AbstractEventLoop: ...

OPENSSL_DYN_LIBS: Optional[OpenSSLDynLibs]
__version__: str
__author__: str

async def create_connection(
    loop: asyncio.AbstractEventLoop,
    protocol_factory: Callable[[], _ProtocolT],
    host: Optional[Union[str, bytes]] = ...,
    port: Optional[Union[int, str]] = ...,
    *,
    ssl: Optional[Union[bool, ssl.SSLContext]] = ...,
    family: int = ...,
    proto: int = ...,
    flags: int = ...,
    sock: Optional[socket.socket] = ...,
    local_addr: Optional[_Address] = ...,
    server_hostname: Optional[str] = ...,
    ssl_handshake_timeout: Optional[float] = ...,
    ssl_shutdown_timeout: Optional[float] = ...,
    ssl_incoming_bio_size: Optional[int] = ...,
    ssl_outgoing_bio_size: Optional[int] = ...,
    happy_eyeballs_delay: Optional[float] = ...,
    interleave: Optional[int] = ...,
    all_errors: bool = ...,
) -> Tuple[asyncio.Transport, _ProtocolT]: ...

async def create_unix_connection(
    loop: asyncio.AbstractEventLoop,
    protocol_factory: Callable[[], _ProtocolT],
    path: Optional[Union[str, bytes, os.PathLike[str], os.PathLike[bytes]]] = ...,
    *,
    ssl: Optional[Union[bool, ssl.SSLContext]] = ...,
    sock: Optional[socket.socket] = ...,
    server_hostname: Optional[str] = ...,
    ssl_handshake_timeout: Optional[float] = ...,
    ssl_shutdown_timeout: Optional[float] = ...,
    ssl_incoming_bio_size: Optional[int] = ...,
    ssl_outgoing_bio_size: Optional[int] = ...,
) -> Tuple[asyncio.Transport, _ProtocolT]: ...

async def create_server(
    loop: asyncio.AbstractEventLoop,
    protocol_factory: Callable[[], asyncio.BaseProtocol],
    host: _Host = ...,
    port: Optional[Union[int, str]] = ...,
    *,
    family: int = ...,
    flags: int = ...,
    sock: Optional[socket.socket] = ...,
    backlog: int = ...,
    ssl: Optional[ssl.SSLContext] = ...,
    reuse_address: Optional[bool] = ...,
    reuse_port: Optional[bool] = ...,
    keep_alive: Optional[bool] = ...,
    ssl_handshake_timeout: Optional[float] = ...,
    ssl_shutdown_timeout: Optional[float] = ...,
    ssl_incoming_bio_size: Optional[int] = ...,
    ssl_outgoing_bio_size: Optional[int] = ...,
    start_serving: bool = ...,
) -> asyncio.Server: ...

async def create_unix_server(
    loop: asyncio.AbstractEventLoop,
    protocol_factory: Callable[[], asyncio.BaseProtocol],
    path: Optional[Union[str, bytes, os.PathLike[str], os.PathLike[bytes]]] = ...,
    *,
    sock: Optional[socket.socket] = ...,
    backlog: int = ...,
    ssl: Optional[ssl.SSLContext] = ...,
    ssl_handshake_timeout: Optional[float] = ...,
    ssl_shutdown_timeout: Optional[float] = ...,
    ssl_incoming_bio_size: Optional[int] = ...,
    ssl_outgoing_bio_size: Optional[int] = ...,
    start_serving: bool = ...,
    cleanup_socket: bool = ...,
) -> asyncio.Server: ...

async def open_connection(
    loop: asyncio.AbstractEventLoop,
    host: Optional[Union[str, bytes]] = ...,
    port: Optional[Union[int, str]] = ...,
    *,
    limit: int = ...,
    **kwds: Any,
) -> Tuple[asyncio.StreamReader, asyncio.StreamWriter]: ...

async def open_unix_connection(
    loop: asyncio.AbstractEventLoop,
    path: Optional[Union[str, bytes, os.PathLike[str], os.PathLike[bytes]]] = ...,
    *,
    limit: int = ...,
    **kwds: Any,
) -> Tuple[asyncio.StreamReader, asyncio.StreamWriter]: ...

async def start_server(
    loop: asyncio.AbstractEventLoop,
    client_connected_cb: Callable[
        [asyncio.StreamReader, asyncio.StreamWriter],
        Optional[Awaitable[None]],
    ],
    host: _Host = ...,
    port: Optional[Union[int, str]] = ...,
    *,
    limit: int = ...,
    **kwds: Any,
) -> asyncio.Server: ...

async def start_unix_server(
    loop: asyncio.AbstractEventLoop,
    client_connected_cb: Callable[
        [asyncio.StreamReader, asyncio.StreamWriter],
        Optional[Awaitable[None]],
    ],
    path: Optional[Union[str, bytes, os.PathLike[str], os.PathLike[bytes]]] = ...,
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
    server_hostname: Optional[str] = ...,
    ssl_handshake_timeout: Optional[float] = ...,
    ssl_shutdown_timeout: Optional[float] = ...,
    ssl_incoming_bio_size: Optional[int] = ...,
    ssl_outgoing_bio_size: Optional[int] = ...,
) -> asyncio.Transport: ...

async def sendfile(
    loop: asyncio.AbstractEventLoop,
    transport: asyncio.BaseTransport,
    file: BinaryIO,
    offset: int = ...,
    count: Optional[int] = ...,
    *,
    fallback: bool = ...,
) -> None: ...

def patch_loop(
    loop: Optional[asyncio.AbstractEventLoop] = ...,
) -> asyncio.AbstractEventLoop: ...

def loop_factory(
    base_factory: Optional[Callable[[], asyncio.AbstractEventLoop]] = ...,
) -> Callable[[], asyncio.AbstractEventLoop]: ...

def install_policy(
    base_policy: Optional[_EventLoopPolicy] = ...,
) -> _EventLoopPolicy: ...
