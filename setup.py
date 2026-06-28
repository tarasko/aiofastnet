import os
import sys
from typing import List

from Cython.Build import cythonize
from setuptools import Extension, setup

vi = sys.version_info
if vi < (3, 9):
    raise RuntimeError('aiofastnet requires Python 3.9 or greater')

if os.name == 'nt':
    libs = ["Ws2_32", "Psapi"]
else:
    libs = []


def _consume_build_ext_flag(flag: str) -> bool:
    if "build_ext" not in sys.argv:
        return False

    try:
        sys.argv.remove(flag)
    except ValueError:
        return False
    return True


with_annotate = _consume_build_ext_flag("--with-annotate")
with_debug = _consume_build_ext_flag("--with-debug")
with_examples = _consume_build_ext_flag("--with-examples")
with_coverage = _consume_build_ext_flag("--with-coverage")
dev = _consume_build_ext_flag("--dev")
if dev:
    with_annotate = True
    with_examples = True


macros = [("CYTHON_TRACE", "1"),
          ("CYTHON_TRACE_NOGIL", "1"),
          ("CYTHON_USE_SYS_MONITORING", "0")] if with_coverage else None


if os.name == 'nt' and with_debug:
    extra_compile_args = ['/Zi']
    extra_link_args = ['/DEBUG']
else:
    extra_compile_args = None
    extra_link_args = None


def make_extension(name: str, sources: List[str]) -> Extension:
    return Extension(name, sources,
                     libraries=libs,
                     define_macros=macros,
                     extra_compile_args=extra_compile_args,
                     extra_link_args=extra_link_args)


# Statically link a bundled OpenSSL into the ssl_object extension so aiofastnet
# works on Python distributions whose _ssl is statically linked / has no
# discoverable libssl (e.g. uv's python-build-standalone). See
# scripts/build_openssl.sh and aiofastnet/openssl_bundled.c.
#
# Controlled by AIOFASTNET_BUNDLED_OPENSSL: "1" forces it on, "0" forces it off.
# When unset, it is auto-enabled if (a) the *building* interpreter's _ssl is
# statically linked (so the borrow backend cannot work at runtime) and (b) a
# pre-built static OpenSSL is present at the prefix below -- so a plain
# `setup.py build_ext` works after running scripts/build_openssl.sh.
_openssl_prefix = os.environ.get(
    "AIOFASTNET_OPENSSL_PREFIX",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "build", "openssl"),
)


def _static_openssl_present() -> bool:
    lib_dir = os.path.join(_openssl_prefix, "lib")
    return (os.path.exists(os.path.join(lib_dir, "libssl.a")) and
            os.path.exists(os.path.join(lib_dir, "libcrypto.a")))


def _interpreter_ssl_is_static() -> bool:
    # Mirrors aiofastnet/openssl_compat.py: a builtin _ssl (no __file__) has no
    # separate libssl to borrow at runtime.
    try:
        import _ssl
    except ImportError:
        return False
    return getattr(_ssl, "__file__", None) is None


_bundled_env = os.environ.get("AIOFASTNET_BUNDLED_OPENSSL")
if _bundled_env is None:
    bundled_openssl = _interpreter_ssl_is_static() and _static_openssl_present()
    if bundled_openssl:
        print("setup.py: auto-enabling bundled OpenSSL (static _ssl interpreter "
              f"and static OpenSSL found at {_openssl_prefix})")
else:
    bundled_openssl = _bundled_env == "1"


def make_ssl_object_extension() -> Extension:
    sources = [
        "aiofastnet/ssl_object.pyx",
        "aiofastnet/static_mem_bio.c",
        "aiofastnet/openssl_compat.c",
    ]
    if not bundled_openssl:
        return make_extension("aiofastnet.ssl_object", sources)

    openssl_prefix = _openssl_prefix
    include_dir = os.path.join(openssl_prefix, "include")
    lib_dir = os.path.join(openssl_prefix, "lib")
    libssl = os.path.join(lib_dir, "libssl.a")
    libcrypto = os.path.join(lib_dir, "libcrypto.a")
    for path in (include_dir, libssl, libcrypto):
        if not os.path.exists(path):
            raise RuntimeError(
                f"AIOFASTNET_BUNDLED_OPENSSL=1 but {path!r} is missing; "
                f"build static OpenSSL first (scripts/build_openssl.sh) or set "
                f"AIOFASTNET_OPENSSL_PREFIX")

    return Extension(
        "aiofastnet.ssl_object",
        sources + ["aiofastnet/openssl_bundled.c"],
        libraries=libs,
        # libssl depends on libcrypto -> list libssl first.
        define_macros=(macros or []) + [("AIOFASTNET_BUNDLED_OPENSSL", "1")],
        include_dirs=[include_dir],
        extra_objects=[libssl, libcrypto],
        extra_compile_args=(extra_compile_args or []) + ["-fvisibility=hidden"],
        extra_link_args=extra_link_args,
    )


extensions = [
    make_extension("aiofastnet.utils", ["aiofastnet/utils.pyx"]),
    make_extension("aiofastnet.transport", ["aiofastnet/transport.pyx"]),
    make_ssl_object_extension(),
    make_extension(
        "aiofastnet.ssl_transport",
        ["aiofastnet/ssl_transport.pyx"],
    ),
]

if os.name == 'posix':
    extensions.append(
        make_extension(
            "aiofastnet.utils_posix",
            ["aiofastnet/utils_posix.pyx"],
        )
    )
elif os.name == 'nt':
    extensions.append(
        make_extension(
            "aiofastnet.utils_win",
            ["aiofastnet/utils_win.pyx"],
        )
    )

if with_examples:
    extensions.append(
        make_extension(
            "examples.benchmark_protocol",
            ["examples/benchmark_protocol.py"],
        )
    )

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
            'linetrace': with_coverage
        },
        annotate=with_annotate,
        gdb_debug=with_debug,
    ),
    include_package_data=True,
)
