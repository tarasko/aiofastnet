import asyncio

from cpython.pycapsule cimport PyCapsule_GetPointer, PyCapsule_New

from .loop_base import LoopBase
from .loop_backend cimport AIOFN_LOOP_BACKEND_CAPSULE_NAME, aiofn_loop_backend


cdef extern from "libevent_backend.h":
    aiofn_loop_backend *aiofn_libevent_backend_new() noexcept nogil
    void aiofn_libevent_backend_free(aiofn_loop_backend *) noexcept nogil


cdef const char *_CAPSULE_NAME = AIOFN_LOOP_BACKEND_CAPSULE_NAME


cdef void _free_backend(object capsule) noexcept:
    cdef aiofn_loop_backend *backend = <aiofn_loop_backend *>PyCapsule_GetPointer(capsule, _CAPSULE_NAME)
    if backend != NULL:
        aiofn_libevent_backend_free(backend)


class EventLoop(LoopBase, asyncio.AbstractEventLoop):
    __slots__ = ()


def new_event_loop():
    """Create an aiofastnet event loop backed by the system libevent."""
    cdef aiofn_loop_backend *backend = aiofn_libevent_backend_new()
    if backend == NULL:
        raise MemoryError("could not initialize the libevent backend")
    capsule = PyCapsule_New(backend, _CAPSULE_NAME, _free_backend)
    try:
        return EventLoop(capsule)
    except BaseException:
        # The capsule destructor owns the backend after PyCapsule_New succeeds.
        del capsule
        raise
