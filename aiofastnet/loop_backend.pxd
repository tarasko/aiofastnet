from libc.stddef cimport size_t
from libc.stdint cimport int32_t, uint32_t, uint64_t


cdef extern from "loop_backend.h":
    ctypedef int32_t aiofn_loop_status
    ctypedef uint32_t aiofn_loop_callback_status

    enum:
        AIOFN_LOOP_OK
        AIOFN_LOOP_CALLBACK_SUCCESS
        AIOFN_LOOP_FD_READ
        AIOFN_LOOP_FD_WRITE
        AIOFN_LOOP_BACKEND_MIN_SIZE

    const char *AIOFN_LOOP_BACKEND_CAPSULE_NAME

    ctypedef struct aiofn_loop_timer:
        pass

    ctypedef struct aiofn_loop_fd_watch:
        pass

    ctypedef void (*aiofn_loop_completion_fn)(void *, aiofn_loop_callback_status) noexcept nogil
    ctypedef void (*aiofn_loop_fd_ready_fn)(void *, uint32_t) noexcept nogil

    ctypedef struct aiofn_loop_backend:
        size_t struct_size
        void *state
        const char *name
        aiofn_loop_status (*run)(void *) noexcept nogil
        void (*stop)(void *) noexcept nogil
        void (*close)(void *) noexcept nogil
        uint64_t (*now_ns)(void *) noexcept nogil
        aiofn_loop_status (*call_soon)(void *, aiofn_loop_completion_fn, void *) noexcept nogil
        aiofn_loop_status (*call_soon_threadsafe)(void *, aiofn_loop_completion_fn, void *) noexcept nogil
        aiofn_loop_status (*call_at)(void *, aiofn_loop_completion_fn, void *, uint64_t, aiofn_loop_timer **) noexcept nogil
        aiofn_loop_status (*timer_cancel)(void *, aiofn_loop_timer *) noexcept nogil
        aiofn_loop_status (*fd_watch)(void *, int, uint32_t, aiofn_loop_fd_ready_fn, void *, aiofn_loop_fd_watch **) noexcept nogil
        aiofn_loop_status (*fd_update)(void *, aiofn_loop_fd_watch *, uint32_t) noexcept nogil
        aiofn_loop_status (*fd_unwatch)(void *, aiofn_loop_fd_watch *) noexcept nogil
        const char *(*last_error)(void *) noexcept nogil
