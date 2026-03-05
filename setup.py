import os
import sys

from Cython.Build import cythonize
from setuptools import Extension, setup

vi = sys.version_info
if vi < (3, 9):
    raise RuntimeError('aiofastnet requires Python 3.9 or greater')

if os.name == 'nt':
    base_libraries = ["Ws2_32"]
else:
    base_libraries = []


extensions = [
    Extension("aiofastnet.utils", ["aiofastnet/utils.pyx"],
              libraries=base_libraries),
    Extension("aiofastnet.transport", ["aiofastnet/transport.pyx"],
              libraries=base_libraries),
    Extension("aiofastnet.sslproto", ["aiofastnet/ssl_protocol.pyx", "aiofastnet/static_mem_bio.c", "aiofastnet/openssl_compat.c"],
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
