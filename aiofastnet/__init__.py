# Fail early if python distribution is statically linked against OpenSSL
from .openssl_compat import OPENSSL_DYN_LIBS

from .api_streams import open_connection, start_server
from .api_create_server import create_server
from .api_create_connection import create_connection
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
    'open_connection',
    'start_server',
    'create_server',
    'create_connection',
    'start_tls',
    'sendfile',
    'loop_factory',
    'patch_loop',
    'install_policy',
    'Transport',
    'Protocol',
    'aiofn_is_buffered_protocol'
]

__version__ = "0.16.0"
__author__ = "Taras Kozlov"
