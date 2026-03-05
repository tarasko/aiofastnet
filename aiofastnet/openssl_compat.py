import ctypes.util
import os


def _find_openssl_library_paths():
    import ssl

    libssl_path = None
    libcrypto_path = None

    for lib in ctypes.util.dllist():
        if not lib:
            continue
        # Find libssl and libcrypto among loaded libraries.
        # Prefer those that were loaded from the python directory
        if "libssl" in lib:
            if libssl_path is None or "ython" in lib:
                libssl_path = os.path.normpath(lib)
        elif "libcrypto" in lib:
            if libcrypto_path is None or "ython" in lib:
                libcrypto_path = os.path.normpath(lib)

    if libssl_path is None or libcrypto_path is None:
        raise ImportError(
            "aiofastnet: failed to find loaded OpenSSL libraries via ctypes.util.dllist(); "
            f"libssl={libssl_path!r}, libcrypto={libcrypto_path!r}"
        )

    return libssl_path.encode(), libcrypto_path.encode()
