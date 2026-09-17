import asyncio

from cpython.pycapsule cimport PyCapsule_GetPointer, PyCapsule_New

from aiofastnet.loop_base import LoopBase
from aiofastnet.loop_backend cimport AIOFN_LOOP_BACKEND_CAPSULE_NAME, aiofn_loop_backend_t


cdef extern from "uring_backend.h":
    aiofn_loop_backend_t *aiofn_uring_backend_new(int busy_poll, int sqpoll) noexcept nogil
    void aiofn_uring_backend_free(aiofn_loop_backend_t *) noexcept nogil


cdef void _free_backend(object capsule) noexcept:
    cdef aiofn_loop_backend_t *backend = <aiofn_loop_backend_t *>PyCapsule_GetPointer(
        capsule, AIOFN_LOOP_BACKEND_CAPSULE_NAME)
    aiofn_uring_backend_free(backend)


class UringLoop(LoopBase, asyncio.AbstractEventLoop):
    pass


EventLoop = UringLoop


def new_event_loop(bint busy_poll=False, bint sqpoll=False):
    """Create an aiofastnet event loop backed directly by liburing.

    busy_poll=True spins on the completion queue instead of blocking in the
    kernel between events: no wake-up scheduling latency, at the cost of one
    CPU core pegged at 100% for as long as the loop runs, idle or not.

    sqpoll=True offloads SQE submission to a dedicated kernel polling
    thread (IORING_SETUP_SQPOLL), removing the submission-side syscall too.
    Independent of busy_poll; combine both for the fewest syscalls on the
    hot path. May need a newer kernel or elevated privileges depending on
    the host's io_uring restrictions.
    """
    cdef aiofn_loop_backend_t *backend = aiofn_uring_backend_new(busy_poll, sqpoll)
    if backend == NULL:
        if sqpoll:
            raise MemoryError(
                "could not initialize the uring backend with sqpoll=True "
                "(IORING_SETUP_SQPOLL may need a newer kernel or elevated "
                "privileges on this host)"
            )
        raise MemoryError("could not initialize the uring backend")

    try:
        capsule = PyCapsule_New(backend, AIOFN_LOOP_BACKEND_CAPSULE_NAME, _free_backend)
    except BaseException:
        aiofn_uring_backend_free(backend)
        raise

    return UringLoop(capsule)
