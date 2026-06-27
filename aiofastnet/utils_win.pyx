from cpython.mem cimport PyMem_Free, PyMem_Malloc
from cpython.unicode cimport PyUnicode_FromWideChar
from libc.stddef cimport wchar_t
import os


cdef extern from "windows.h":
    ctypedef void* HANDLE
    ctypedef void* HMODULE
    ctypedef int BOOL
    ctypedef unsigned long DWORD

    HANDLE GetCurrentProcess()
    DWORD GetLastError()
    DWORD GetModuleFileNameW(HMODULE module, wchar_t* filename, DWORD size)


cdef extern from "psapi.h":
    BOOL EnumProcessModules(
        HANDLE process,
        HMODULE* modules,
        DWORD modules_size,
        DWORD* needed,
    )


cdef void aiofn_raise_windows_error(const char* function_name) except *:
    raise OSError(
        <int>GetLastError(),
        f"{function_name.decode('ascii')} failed",
    )


cdef list aiofn_get_loaded_library_paths():
    cdef:
        HANDLE process = GetCurrentProcess()
        HMODULE* modules = NULL
        DWORD needed = 0
        DWORD modules_size
        DWORD module_count
        DWORD i
        DWORD filename_len
        DWORD n = 1024
        wchar_t filename[32767]
        list paths

    while True:
        modules_size = n * sizeof(HMODULE)
        modules = <HMODULE*>PyMem_Malloc(modules_size)
        if modules == NULL:
            raise MemoryError()

        try:
            if not EnumProcessModules(process, modules, modules_size, &needed):
                aiofn_raise_windows_error(b"EnumProcessModules")

            if needed <= modules_size:
                module_count = needed // sizeof(HMODULE)
                paths = []

                for i in range(module_count):
                    filename_len = GetModuleFileNameW(
                        modules[i],
                        filename,
                        sizeof(filename) // sizeof(wchar_t),
                    )
                    if filename_len == 0:
                        aiofn_raise_windows_error(b"GetModuleFileNameW")

                    paths.append(
                        PyUnicode_FromWideChar(filename, filename_len))

                return paths

            n = needed // sizeof(HMODULE)
            if needed % sizeof(HMODULE):
                n += 1
        finally:
            PyMem_Free(modules)
            modules = NULL


cpdef tuple aiofn_get_openssl_library_paths(str ssl_module_path):
    cdef:
        str libssl_path = None
        str libcrypto_path = None
        str dl
        str dl_lower

    for dl in aiofn_get_loaded_library_paths():
        if not dl:
            continue

        dl_lower = dl.lower()
        if "libssl" in dl_lower:
            if libssl_path is None or "ython" in dl_lower:
                libssl_path = os.path.normpath(dl)
        elif "libcrypto" in dl_lower:
            if libcrypto_path is None or "ython" in dl_lower:
                libcrypto_path = os.path.normpath(dl)

    if libssl_path is None or libcrypto_path is None:
        raise OSError(
            "could not locate OpenSSL dynamic libs among loaded libraries")

    return libssl_path, libcrypto_path
