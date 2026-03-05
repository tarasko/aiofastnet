import os
import sys
from pathlib import Path


def _pick_library(base_dir: Path, prefix: str, suffix: str):
    if not base_dir.exists():
        return None
    candidates = sorted(base_dir.glob(f"{prefix}*{suffix}*"))
    if not candidates:
        return None
    for p in candidates:
        name = p.name
        if ".so." in name or ".dylib." in name:
            return str(p)
    return str(candidates[0])


def _find_openssl_library_paths():
    if sys.platform == "darwin":
        if sys.version_info < (3, 11):
            return "libssl.dylib.1", "libcrypto.dylib.1"
        else:
            return "libssl.dylib.3", "libcrypto.dylib.3"
    elif sys.platform in ("linux", "aix", "freebsd"):
        if sys.version_info < (3, 11):
            return "libssl.so.1", "libcrypto.so.1"
        else:
            return "libssl.so.3", "libcrypto.so.3"
    elif sys.platform == "win32":
        if sys.version_info < (3, 11):
            return "libssl-3.dll", "libcrypto-3.dll"
        else:
            return "libssl-1.dll", "libcrypto-1.dll"
    else:
        return ImportError(f"unsupported platform: {sys.platform}")

    # roots = []
    # for root in (
    #     Path(sys.prefix) / "libs",
    #     Path(getattr(sys, "base_prefix", sys.prefix)) / "libs",
    #     Path(sys.prefix) / "lib",
    #     Path(getattr(sys, "base_prefix", sys.prefix)) / "lib",
    # ):
    #     if root not in roots:
    #         roots.append(root)
    #
    # if os.name == "nt":
    #     ssl_suffix = ".dll"
    #     crypto_suffix = ".dll"
    # elif sys.platform == "darwin":
    #     ssl_suffix = ".dylib"
    #     crypto_suffix = ".dylib"
    # else:
    #     ssl_suffix = ".so"
    #     crypto_suffix = ".so"
    #
    # ssl_path = None
    # crypto_path = None
    # for root in roots:
    #     if ssl_path is None:
    #         ssl_path = _pick_library(root, "libssl", ssl_suffix)
    #     if crypto_path is None:
    #         crypto_path = _pick_library(root, "libcrypto", crypto_suffix)
    #     if ssl_path is not None and crypto_path is not None:
    #         break
    #
    # if ssl_path is None or crypto_path is None:
    #     raise ImportError(
    #         "aiofastnet: could not find OpenSSL libraries "
    #         f"(ssl={ssl_path!r}, crypto={crypto_path!r}) in roots={roots!r}"
    #     )
    #
    # return ssl_path, crypto_path
