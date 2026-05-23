# Portions of this file are derived from CPython sources.
# Copyright (c) Python Software Foundation.
# Licensed under the Python Software Foundation License Version 2.
# See LICENSES/PSF-2.0.txt and THIRD_PARTY_NOTICES for details.

import ctypes
import ctypes.util
import sys
import os


if sys.version_info >= (3, 14):
    dllist = ctypes.util.dllist
else:
    if os.name == "nt":
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

        # gh-145307: We defer loading psapi.dll until _get_module_handles is called.
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

    elif os.name == "posix" and sys.platform in {"darwin", "ios", "tvos", "watchos"}:
        from ctypes.macholib.dyld import dyld_find as _dyld_find

        _libc = ctypes.CDLL(ctypes.util.find_library("c"))
        _dyld_get_image_name = _libc["_dyld_get_image_name"]
        _dyld_get_image_name.restype = ctypes.c_char_p

        def dllist():
            """Return a list of loaded shared libraries in the current process."""
            num_images = _libc._dyld_image_count()
            libraries = [os.fsdecode(name) for i in range(num_images)
                         if (name := _dyld_get_image_name(i)) is not None]

            return libraries

    elif (os.name == "posix" and sys.platform not in {"darwin", "ios", "tvos", "watchos"}):
        if hasattr((_libc := ctypes.CDLL(None)), "dl_iterate_phdr"):
            class _dl_phdr_info(ctypes.Structure):
                _fields_ = [
                    ("dlpi_addr", ctypes.c_void_p),
                    ("dlpi_name", ctypes.c_char_p),
                    ("dlpi_phdr", ctypes.c_void_p),
                    ("dlpi_phnum", ctypes.c_ushort),
                ]

            _dl_phdr_callback = ctypes.CFUNCTYPE(
                ctypes.c_int,
                ctypes.POINTER(_dl_phdr_info),
                ctypes.c_size_t,
                ctypes.POINTER(ctypes.py_object),
            )

            @_dl_phdr_callback
            def _info_callback(info, _size, data):
                libraries = data.contents.value
                name = os.fsdecode(info.contents.dlpi_name)
                libraries.append(name)
                return 0

            _dl_iterate_phdr = _libc["dl_iterate_phdr"]
            _dl_iterate_phdr.argtypes = [
                _dl_phdr_callback,
                ctypes.POINTER(ctypes.py_object),
            ]
            _dl_iterate_phdr.restype = ctypes.c_int

            def dllist():
                """Return a list of loaded shared libraries in the current process."""
                libraries = []
                _dl_iterate_phdr(_info_callback,
                                 ctypes.byref(
                                     ctypes.py_object(libraries)))
                return libraries
    else:
        raise ImportError(f"unsupported platform {os.name}-{sys.platform}")


def find_openssl_library_paths():
    # Make sure ssl module is loaded and libssl, libcrypto with it
    import ssl

    libssl_path = None
    libcrypto_path = None

    for dl in dllist():
        if not dl:
            continue

        # Find libssl and libcrypto among loaded libraries.
        # There could be multiple loaded ssl libraries.
        # Prefer those that were loaded from the python directory, since it is
        # what ssl module was build against.
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

