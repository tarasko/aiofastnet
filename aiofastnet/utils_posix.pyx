import os

from posix.dlfcn cimport RTLD_NOW, dlclose, dlerror, dlopen, dlsym


cdef extern from *:
    """
#ifndef _GNU_SOURCE
    #define _GNU_SOURCE
#endif
    """


cdef extern from "<dlfcn.h>" nogil:
    ctypedef struct Dl_info:
        const char* dli_fname
        void* dli_fbase
        const char* dli_sname
        void* dli_saddr

    int dladdr(const void* addr, Dl_info* info)


cdef object aiofn_dlerror_message():
    cdef char* message = dlerror()
    if message == NULL:
        return "unknown error"
    return os.fsdecode(message)


cpdef object aiofn_get_openssl_library_paths(str ssl_module_path):
    cdef:
        bytes ssl_module_path_b = os.fsencode(ssl_module_path)
        void* handle
        void* addr
        Dl_info info
        object libssl_path
        object libcrypto_path

    handle = dlopen(ssl_module_path_b, RTLD_NOW)
    if handle == NULL:
        raise OSError(
            f"dlopen({ssl_module_path!r}) failed: "
            f"{aiofn_dlerror_message()}")

    try:
        addr = dlsym(handle, b"SSL_new")
        if addr == NULL:
            raise OSError(
                f"dlsym('SSL_new') failed: {aiofn_dlerror_message()}")

        if dladdr(addr, &info) == 0 or info.dli_fname == NULL:
            raise OSError("dladdr('SSL_new') failed")
        libssl_path = os.path.normpath(os.fsdecode(info.dli_fname))

        addr = dlsym(handle, b"BIO_new")
        if addr == NULL:
            raise OSError(
                f"dlsym('BIO_new') failed: {aiofn_dlerror_message()}")

        if dladdr(addr, &info) == 0 or info.dli_fname == NULL:
            raise OSError("dladdr('BIO_new') failed")
        libcrypto_path = os.path.normpath(os.fsdecode(info.dli_fname))

        return libssl_path, libcrypto_path
    finally:
        dlclose(handle)
