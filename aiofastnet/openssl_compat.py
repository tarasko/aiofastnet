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
        return b"libssl.dylib", b"libcrypto.dylib"
    elif sys.platform in ("linux", "aix", "freebsd"):
        return b"libssl.so", b"libcrypto.so"
    elif sys.platform == "win32":
        if sys.version_info < (3, 11):
            return b"libssl-3.dll", b"libcrypto-3.dll"
        else:
            return b"libssl-1.dll", b"libcrypto-1.dll"
    else:
        return ImportError(f"unsupported platform: {sys.platform}")
