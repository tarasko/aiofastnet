import os
import subprocess
import sys
from pathlib import Path

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

def _find_macos_openssl_prefixes():
    prefixes = []
    for formula in ("openssl", "openssl@3"):
        try:
            out = subprocess.check_output(
                ["brew", "--prefix", formula],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            continue
        if out and out not in prefixes:
            prefixes.append(out)
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
