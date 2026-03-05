import ctypes.util
import sys
import os


if sys.version_info < (3, 14):
    dllist = None
    pass
else:
    dllist = ctypes.util.dllist


def _find_openssl_library_paths():
    # Make sure ssl module is loaded and libssl, libcrypto with it
    import ssl

    libssl_path = None
    libcrypto_path = None

    for dl in dllist():
        # Find libssl and libcrypto among loaded libraries.
        # Prefer those that were loaded from the python directory
        if "libssl" in dl:
            if libssl_path is None or "ython" in dl:
                libssl_path = os.path.normpath(dl)
        elif "libcrypto" in dl:
            if libcrypto_path is None or "ython" in dl:
                libcrypto_path = os.path.normpath(dl)

    if libssl_path is None or libcrypto_path is None:
        raise ImportError(
            "aiofastnet: failed to find loaded OpenSSL libraries via ctypes.util.dllist(); "
            f"libssl={libssl_path!r}, libcrypto={libcrypto_path!r}"
        )

    return libssl_path.encode(), libcrypto_path.encode()
