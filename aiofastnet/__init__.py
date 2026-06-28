import socket

from .openssl_compat import OPENSSL_DYN_LIBS
from ._sslcontext import SSLContext

from .api_streams import (
    open_connection,
    start_server,
)

from .api_create_server import create_server
from .api_create_connection import create_connection
from .api_create_unix_connection import create_unix_connection
from .api_create_unix_server import create_unix_server
from .api_start_tls import start_tls
from .api_sendfile import sendfile
from .api_patch import loop_factory, patch_loop, install_policy

from .transport import (
    Transport,
    Protocol,
    aiofn_is_buffered_protocol
)

__all__ = [
    'OPENSSL_DYN_LIBS',
    'SSLContext',
    'open_connection',
    'start_server',
    'create_server',
    'create_connection',
    'create_unix_connection',
    'create_unix_server',
    'start_tls',
    'sendfile',
    'loop_factory',
    'patch_loop',
    'install_policy',
    'Transport',
    'Protocol',
    'aiofn_is_buffered_protocol',
]

if hasattr(socket, 'AF_UNIX'):
    from .api_streams import (  # noqa: F401
        open_unix_connection as open_unix_connection,
        start_unix_server as start_unix_server,
    )

    __all__.extend((
        'open_unix_connection',
        'start_unix_server',
    ))


__version__ = "0.18.0"
__author__ = "Taras Kozlov"
