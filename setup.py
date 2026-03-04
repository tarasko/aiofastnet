import os
import subprocess
import sys
from pathlib import Path

from Cython.Build import cythonize
from setuptools import Extension, setup

vi = sys.version_info
if vi < (3, 9):
    raise RuntimeError('aiofastnet requires Python 3.9 or greater')


def _find_macos_openssl_prefix():
    # Python 3.9/3.10 use openssl 1.1.x.
    openssl_package = "openssl@1.1" if vi < (3, 11) else "openssl@3"

    try:
        out = subprocess.check_output(
            ["brew", "--prefix", openssl_package],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None

    assert out, "could not find OpenSSL"
    return out


if sys.platform == "darwin":
    openssl_prefix = _find_macos_openssl_prefix()
    openssl_include_dirs = [str(Path(openssl_prefix) / "include")]
    openssl_link_dirs = [str(Path(sys.prefix) / "lib")]
else:
    openssl_include_dirs = []
    openssl_link_dirs = []

openssl_libraries = ["ssl", "crypto"]
if os.name == 'nt':
    base_libraries = ["Ws2_32"]
else:
    base_libraries = []


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
