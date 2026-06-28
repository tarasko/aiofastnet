import os
import ssl
from dataclasses import dataclass

import _ssl


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


def find_openssl_library_paths():
    """Discover the libssl/libcrypto that Python's ``_ssl`` is dynamically linked
    against, so aiofastnet can reuse the interpreter's OpenSSL (the *borrow*
    backend).

    Returns an :class:`OpenSSLDynLibs`, or ``None`` when the interpreter's
    OpenSSL cannot be borrowed -- e.g. ``_ssl`` is statically linked / has no
    discoverable shared libssl, as is the case for uv's python-build-standalone
    distributions. In that case aiofastnet falls back to its own bundled,
    statically linked OpenSSL (when the extension was compiled with it).
    """
    ssl_module_path = getattr(_ssl, "__file__", None)
    if ssl_module_path is None:
        # _ssl is a builtin (statically linked into the interpreter); there is no
        # separate libssl to discover.
        return None
    try:
        libssl_path, libcrypto_path = aiofn_get_openssl_library_paths(
            ssl_module_path)
    except OSError:
        return None
    return OpenSSLDynLibs(libssl_path, libcrypto_path)


# Resolved once at import. ``None`` when the interpreter's OpenSSL cannot be
# borrowed (the bundled backend, if compiled in, is used instead). The actual
# borrow-vs-bundled decision is made in ssl_object.pyx, which can query the
# compiled-in bundled availability.
BORROW_LIBS = find_openssl_library_paths()

# Public, always-valid descriptor. On the bundled backend we expose a
# descriptive placeholder so logging and ``aiofastnet.OPENSSL_DYN_LIBS`` keep
# working.
OPENSSL_DYN_LIBS = BORROW_LIBS if BORROW_LIBS is not None else OpenSSLDynLibs(
    "<bundled-static-openssl>", "<bundled-static-openssl>")


def create_transport_context(server_side, server_hostname):
    sslcontext = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    if not server_hostname:
        sslcontext.check_hostname = False
    return sslcontext
