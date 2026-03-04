import os
import subprocess
import sys
from pathlib import Path
import ssl as py_ssl

from Cython.Build import cythonize
from setuptools import Extension, setup

vi = sys.version_info
if vi < (3, 9):
    raise RuntimeError('aiofastnet requires Python 3.9 or greater')


if os.name == 'nt':
    base_libraries = ["Ws2_32"]
else:
    base_libraries = []

openssl_libraries = ["ssl", "crypto"]

def _brew_prefix(formula: str):
    try:
        out = subprocess.check_output(
            ["brew", "--prefix", formula],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return out or None


def _openssl_major_from_prefix(prefix: str):
    openssl_bin = str(Path(prefix) / "bin" / "openssl")
    try:
        out = subprocess.check_output(
            [openssl_bin, "version"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None

    # Example output: "OpenSSL 1.1.1w  11 Sep 2023" or "OpenSSL 3.3.1 ..."
    parts = out.split()
    if len(parts) < 2:
        return None
    version = parts[1]
    major = version.split(".", 1)[0]
    return int(major) if major.isdigit() else None


def _find_macos_openssl_prefixes():
    # Keep 3.9/3.10 away from openssl@3 unless no alternative is available.
    if vi <= (3, 10):
        formulas = ("openssl", "openssl@1.1", "openssl@3")
    else:
        formulas = ("openssl@3", "openssl", "openssl@1.1")

    prefixes = []
    for formula in formulas:
        out = _brew_prefix(formula)
        if not out or out in prefixes:
            continue
        prefixes.append(out)

    if not prefixes:
        return prefixes

    # Prefer a Homebrew OpenSSL with the same major version Python is using at runtime.
    py_openssl_major = py_ssl.OPENSSL_VERSION_INFO[0]
    matching = [p for p in prefixes if _openssl_major_from_prefix(p) == py_openssl_major]
    if matching:
        return matching + [p for p in prefixes if p not in matching]
    return prefixes


if sys.platform == "darwin":
    openssl_prefixes = _find_macos_openssl_prefixes()
    assert openssl_prefixes, "could not find OpenSSL"
    openssl_include_dirs = [str(Path(p) / "include") for p in openssl_prefixes]
    openssl_link_dirs = [str(Path(sys.prefix) / "lib")]
    # openssl_link_dirs = [str(Path(p) / "lib") for p in openssl_prefixes]
else:
    openssl_include_dirs = []
    openssl_link_dirs = []

extensions = [
    Extension("aiofastnet.utils", ["aiofastnet/utils.pyx"],
              libraries=base_libraries),
    Extension("aiofastnet.transport", ["aiofastnet/transport.pyx"],
              libraries=base_libraries),
    Extension("aiofastnet.sslproto", ["aiofastnet/sslproto.pyx", "aiofastnet/static_mem_bio.c", "aiofastnet/certdecode.c"],
              libraries=base_libraries + openssl_libraries,
              include_dirs=openssl_include_dirs,
              library_dirs=openssl_link_dirs),
    Extension("aiofastnet.sslproto_stdlib", ["aiofastnet/sslproto_stdlib.pyx"],
              libraries=base_libraries),
]

build_wheel = any(cmd in sys.argv for cmd in ("bdist_wheel",))

setup(
    ext_modules=cythonize(
        extensions,
        compiler_directives={
            'language_level': vi[0],
            'freethreading_compatible': True,
            'profile': False,
            'nonecheck': False,
            'boundscheck': False,
            'wraparound': False,
            'initializedcheck': False,
            'optimize.use_switch': False,
            'cdivision': True
        },
        annotate=True,
        gdb_debug=False,
    ),
    include_package_data=True,
)
