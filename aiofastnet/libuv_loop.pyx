import asyncio

from cpython.pycapsule cimport PyCapsule_GetPointer, PyCapsule_New

from .loop_base import LoopBase
from .loop_backend cimport AIOFN_LOOP_BACKEND_CAPSULE_NAME, aiofn_loop_backend_t


cdef extern from "libuv_backend.h":
    aiofn_loop_backend_t *aiofn_libuv_backend_new() noexcept nogil
    void aiofn_libuv_backend_free(aiofn_loop_backend_t *) noexcept nogil


cdef void _free_backend(object capsule) noexcept:
    cdef aiofn_loop_backend_t *backend = <aiofn_loop_backend_t *>PyCapsule_GetPointer(
        capsule, AIOFN_LOOP_BACKEND_CAPSULE_NAME)
    aiofn_libuv_backend_free(backend)


class EventLoop(LoopBase, asyncio.AbstractEventLoop):
    pass


def new_event_loop():
    """Create an aiofastnet event loop backed by the system libuv."""
    cdef aiofn_loop_backend_t *backend = aiofn_libuv_backend_new()
    if backend == NULL:
        raise MemoryError("could not initialize the libuv backend")

    try:
        capsule = PyCapsule_New(backend, AIOFN_LOOP_BACKEND_CAPSULE_NAME, _free_backend)
    except BaseException:
        aiofn_libuv_backend_free(backend)
        raise

    return EventLoop(capsule)
