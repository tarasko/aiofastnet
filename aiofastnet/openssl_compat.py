# Portions of this file are derived from CPython sources.
# Copyright (c) Python Software Foundation.
# Licensed under the Python Software Foundation License Version 2.
# See LICENSES/PSF-2.0.txt and THIRD_PARTY_NOTICES for details.

import os
from dataclasses import dataclass

import _ssl

_ssl_module_path = getattr(_ssl, '__file__', None)
if _ssl_module_path is None:
    raise ImportError(
        "aiofastnet requires Python distribution that is dynamically "
        "linked against OpenSSL. It seems your Python is linked "
        "statically against OpenSSL (this is common for uv virtual "
        "envs)"
    )


@dataclass(frozen=True)
class OpenSSLDynLibs:
    libssl: str
    libcrypto: str

    @property
    def libssl_path(self) -> bytes:
        return self.libssl.encode()

    @property
    def libcrypto_path(self) -> bytes:
        return self.libcrypto.encode()


if os.name == "nt":
    import ctypes

    # Listing loaded DLLs on Windows relies on the following APIs:
    # https://learn.microsoft.com/windows/win32/api/psapi/nf-psapi-enumprocessmodules
    # https://learn.microsoft.com/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulefilenamew
    from ctypes import wintypes

    _kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    _get_current_process = _kernel32["GetCurrentProcess"]
    _get_current_process.restype = wintypes.HANDLE

    _k32_get_module_file_name = _kernel32["GetModuleFileNameW"]
    _k32_get_module_file_name.restype = wintypes.DWORD
    _k32_get_module_file_name.argtypes = (
        wintypes.HMODULE,
        wintypes.LPWSTR,
        wintypes.DWORD,
    )

    # gh-145307: Defer loading psapi.dll until _get_module_handles is called.
    # Loading additional DLLs at startup for functionality that may never be
    # used is wasteful.
    _enum_process_modules = None

    def _get_module_filename(module: wintypes.HMODULE):
        name = (wintypes.WCHAR * 32767)()  # UNICODE_STRING_MAX_CHARS
        if _k32_get_module_file_name(module, name, len(name)):
            return name.value
        return None

    def _get_module_handles():
        global _enum_process_modules
        if _enum_process_modules is None:
            _psapi = ctypes.WinDLL('psapi', use_last_error=True)
            _enum_process_modules = _psapi["EnumProcessModules"]
            _enum_process_modules.restype = wintypes.BOOL
            _enum_process_modules.argtypes = (
                wintypes.HANDLE,
                ctypes.POINTER(wintypes.HMODULE),
                wintypes.DWORD,
                wintypes.LPDWORD,
            )

        process = _get_current_process()
        space_needed = wintypes.DWORD()
        n = 1024
        while True:
            modules = (wintypes.HMODULE * n)()
            if not _enum_process_modules(process,
                                         modules,
                                         ctypes.sizeof(modules),
                                         ctypes.byref(space_needed)):
                err = ctypes.get_last_error()
                msg = ctypes.FormatError(err).strip()
                raise ctypes.WinError(err,
                                      f"EnumProcessModules failed: {msg}")
            n = space_needed.value // ctypes.sizeof(wintypes.HMODULE)
            if n <= len(modules):
                return modules[:n]

    def dllist():
        """Return a list of loaded shared libraries in the current process."""
        modules = _get_module_handles()
        libraries = [name for h in modules
                     if (name := _get_module_filename(h)) is not None]
        return libraries

    def _find_openssl_library_paths() -> OpenSSLDynLibs:
        libssl_path: str | None = None
        libcrypto_path: str | None = None

        loaded_libs = dllist()
        dl: str
        for dl in loaded_libs:
            if not dl:
                continue

            # Find libssl and libcrypto among loaded libraries.
            # There could be multiple loaded ssl libraries.
            # Prefer those that were loaded from the python directory, since it
            # is what ssl module was build against.
            if "libssl" in dl:
                if libssl_path is None or "ython" in dl:
                    libssl_path = os.path.normpath(dl)
            elif "libcrypto" in dl:
                if libcrypto_path is None or "ython" in dl:
                    libcrypto_path = os.path.normpath(dl)

        if libssl_path is None or libcrypto_path is None:
            raise ImportError(
                "aiofastnet could not locate OpenSSL dynamic libs among "
                "loaded libraries. It could be that your Python is linked "
                "statically "
                "against OpenSSL (this is common for uv virtual envs)"
            )

        return OpenSSLDynLibs(libssl_path, libcrypto_path)

elif os.name == "posix":
    def _find_openssl_library_paths() -> OpenSSLDynLibs:
        from .utils import aiofn_get_openssl_library_paths

        try:
            openssl_library_paths = aiofn_get_openssl_library_paths(
                _ssl_module_path)
        except OSError as exc:
            raise ImportError(
                "aiofastnet could not identify the OpenSSL dynamic libraries "
                "used by Python's _ssl module"
            ) from exc

        libssl_path, libcrypto_path = openssl_library_paths
        return OpenSSLDynLibs(libssl_path, libcrypto_path)

else:
    raise ImportError(f"unsupported platform {os.name}")


OPENSSL_DYN_LIBS = _find_openssl_library_paths()
