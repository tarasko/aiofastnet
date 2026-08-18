import asyncio

from cpython.pycapsule cimport PyCapsule_GetPointer, PyCapsule_New

from aiofastnet.loop_base import LoopBase
from aiofastnet.loop_backend cimport AIOFN_LOOP_BACKEND_CAPSULE_NAME, aiofn_loop_backend_t


cdef extern from "uring_backend.h":
    aiofn_loop_backend_t *aiofn_uring_backend_new() noexcept nogil
    void aiofn_uring_backend_free(aiofn_loop_backend_t *) noexcept nogil


cdef void _free_backend(object capsule) noexcept:
    cdef aiofn_loop_backend_t *backend = <aiofn_loop_backend_t *>PyCapsule_GetPointer(
        capsule, AIOFN_LOOP_BACKEND_CAPSULE_NAME)
    aiofn_uring_backend_free(backend)


class UringLoop(LoopBase, asyncio.AbstractEventLoop):
    pass


EventLoop = UringLoop


def new_event_loop():
    """Create an aiofastnet event loop backed directly by liburing."""
    cdef aiofn_loop_backend_t *backend = aiofn_uring_backend_new()
    if backend == NULL:
        raise MemoryError("could not initialize the uring backend")

    try:
        capsule = PyCapsule_New(backend, AIOFN_LOOP_BACKEND_CAPSULE_NAME, _free_backend)
    except BaseException:
        aiofn_uring_backend_free(backend)
        raise

    return UringLoop(capsule)
