import socket

from .api_connect_accepted_socket import connect_accepted_socket
from .api_create_connection import create_connection
from .api_create_datagram_endpoint import create_datagram_endpoint
from .api_create_server import create_server
from .api_create_unix_connection import create_unix_connection
from .api_create_unix_server import create_unix_server
from .api_patch import install_policy, loop_factory, patch_loop
from .api_pipe import connect_read_pipe, connect_write_pipe
from .api_sendfile import sendfile
from .api_start_tls import start_tls
from .api_streams import (
    open_connection,
    start_server,
)
from .openssl_compat import OPENSSL_DYN_LIBS
from .transport import Protocol, Transport, aiofn_is_buffered_protocol

__all__ = [
    'OPENSSL_DYN_LIBS',
    'Protocol',
    'Transport',
    'aiofn_is_buffered_protocol',
    'connect_accepted_socket',
    'connect_read_pipe',
    'connect_write_pipe',
    'create_connection',
    'create_datagram_endpoint',
    'create_server',
    'create_unix_connection',
    'create_unix_server',
    'install_policy',
    'loop_factory',
    'open_connection',
    'patch_loop',
    'sendfile',
    'start_server',
    'start_tls',
]

if hasattr(socket, 'AF_UNIX'):
    from .api_streams import (
        open_unix_connection as open_unix_connection,
    )
    from .api_streams import (
        start_unix_server as start_unix_server,
    )

    __all__.extend((
        'open_unix_connection',
        'start_unix_server',
    ))


__version__ = "1.0.5"
__author__ = "Taras Kozlov"
