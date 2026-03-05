import ctypes.util
import os
import psutil

def _find_openssl_library_paths():
    # Make sure ssl module is loaded and libssl, libcrypto with it
    import ssl

    libssl_path = None
    libcrypto_path = None

    for mm in psutil.Process().memory_maps():
        # Find libssl and libcrypto among loaded libraries.
        # Prefer those that were loaded from the python directory
        if "libssl" in mm.path:
            if libssl_path is None or "ython" in mm.path:
                libssl_path = os.path.normpath(mm.path)
        elif "libcrypto" in mm.path:
            if libcrypto_path is None or "ython" in mm.path:
                libcrypto_path = os.path.normpath(mm.path)

    if libssl_path is None or libcrypto_path is None:
        raise ImportError(
            "aiofastnet: failed to find loaded OpenSSL libraries via ctypes.util.dllist(); "
            f"libssl={libssl_path!r}, libcrypto={libcrypto_path!r}"
        )

    return libssl_path.encode(), libcrypto_path.encode()
