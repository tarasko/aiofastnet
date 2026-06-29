import os
import ssl
from dataclasses import dataclass

import _ssl
from typing import Optional

_ssl_module_path = getattr(_ssl, '__file__', None)


@dataclass(frozen=True)
class OpenSSLDynLibs:
    libssl: str
    libcrypto: str

    @property
    def libssl_path(self) -> bytes:
        return self.libssl.encode()

    @property
    def libcrypto_path(self) -> bytes:
        return self.libcrypto.encode()


if os.name == "nt":
    from .utils_win import aiofn_get_openssl_library_paths
elif os.name == "posix":
    from .utils_posix import aiofn_get_openssl_library_paths
else:
    raise ImportError(f"unsupported platform {os.name}")


def _find_openssl_library_paths() -> Optional[OpenSSLDynLibs]:
    if os.environ.get("AIOFN_FORCE_FALLBACK") is not None or _ssl_module_path is None:
        return None

    try:
        openssl_library_paths = aiofn_get_openssl_library_paths(
            _ssl_module_path)
    except OSError as exc:
        raise ImportError(
            "aiofastnet could not identify the OpenSSL dynamic libraries "
            "used by Python's _ssl module"
        ) from exc

    libssl_path, libcrypto_path = openssl_library_paths
    return OpenSSLDynLibs(libssl_path, libcrypto_path)


OPENSSL_DYN_LIBS = _find_openssl_library_paths()


def create_transport_context(server_side, server_hostname):
    sslcontext = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    if not server_hostname:
        sslcontext.check_hostname = False
    return sslcontext
