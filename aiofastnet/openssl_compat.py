import ctypes.util
import sys
from pathlib import Path


def _find_openssl_library_paths():
    libssl_path = None
    libcrypto_path = None

    for lib in ctypes.util.dllist():
        if not lib:
            continue
        p = Path(lib).resolve(strict=False)
        s = str(p)
        if "libssl" in s and libssl_path is None:
            libssl_path = s
        elif "libcrypto" in s and libcrypto_path is None:
            libcrypto_path = s
        if libssl_path is not None and libcrypto_path is not None:
            break

    if libssl_path is None or libcrypto_path is None:
        raise ImportError(
            "aiofastnet: failed to find loaded OpenSSL libraries via ctypes.util.dllist(); "
            f"libssl={libssl_path!r}, libcrypto={libcrypto_path!r}"
        )

    return libssl_path.encode(), libcrypto_path.encode()
