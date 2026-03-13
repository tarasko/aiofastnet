import os
import sys

from Cython.Build import cythonize
from setuptools import Extension, setup

vi = sys.version_info
if vi < (3, 9):
    raise RuntimeError('aiofastnet requires Python 3.9 or greater')

if os.name == 'nt':
    libs = ["Ws2_32"]
else:
    libs = []


pkg_extensions = [
    Extension("aiofastnet.utils", ["aiofastnet/utils.pyx"], libraries=libs),
    Extension("aiofastnet.transport", ["aiofastnet/transport.pyx"], libraries=libs),
    Extension("aiofastnet.ssl_object", ["aiofastnet/ssl_object.pyx", "aiofastnet/static_mem_bio.c", "aiofastnet/openssl_compat.c"], libraries=libs),
    Extension("aiofastnet.ssl_protocol", ["aiofastnet/ssl_protocol.pyx"], libraries=libs),
    Extension("examples.benchmark_protocol", ["examples/benchmark_protocol.pyx"], libraries=libs),
]

example_extensions = [
    Extension("examples.benchmark_protocol", ["examples/benchmark_protocol.pyx"]),
]

build_wheel = any(cmd in sys.argv for cmd in ("bdist_wheel",))
extensions = (pkg_extensions + example_extensions) if not build_wheel and os.name != 'nt' else pkg_extensions

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
        },
        annotate=True,
        gdb_debug=False,
    ),
    include_package_data=True,
)
