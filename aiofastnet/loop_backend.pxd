from libc.stddef cimport size_t
from libc.stdint cimport int32_t, uint32_t, uint64_t


cdef extern from "loop_backend.h":
    ctypedef int32_t aiofn_loop_status

    enum:
        AIOFN_LOOP_OK
        AIOFN_LOOP_ERROR
        AIOFN_LOOP_NO_MEMORY
        AIOFN_LOOP_INVALID_ARGUMENT
        AIOFN_LOOP_NOT_SUPPORTED
        AIOFN_LOOP_FD_READ
        AIOFN_LOOP_FD_WRITE
        AIOFN_LOOP_BACKEND_MIN_SIZE

    const char *AIOFN_LOOP_BACKEND_CAPSULE_NAME

    ctypedef struct aiofn_loop_action_t

    ctypedef void (*aiofn_loop_callback_fn)(aiofn_loop_action_t *) noexcept nogil

    ctypedef struct aiofn_loop_action_t:
        aiofn_loop_callback_fn callback
        void *callback_data
        void *backend_token

    ctypedef void (*aiofn_loop_fd_ready_fn)(void *, uint32_t) noexcept nogil

    ctypedef struct aiofn_loop_fd_watch_t:
        int fd
        aiofn_loop_fd_ready_fn callback
        void *callback_data
        void *backend_read_token
        void *backend_write_token

    ctypedef void (*aiofn_loop_signal_fn)(void *, int) noexcept nogil

    ctypedef struct aiofn_loop_signal_watch_t:
        aiofn_loop_signal_fn callback
        void *callback_data
        void *backend_token

    ctypedef struct aiofn_loop_backend_t:
        size_t struct_size
        void *state
        const char *name
        aiofn_loop_status (*run)(void *) noexcept nogil
        void (*stop)(void *) noexcept nogil
        void (*close)(void *) noexcept nogil
        uint64_t (*now_ns)(void *) noexcept nogil
        aiofn_loop_status (*call_soon)(void *, aiofn_loop_action_t *) noexcept nogil
        aiofn_loop_status (*call_at)(void *, aiofn_loop_action_t *, uint64_t) noexcept nogil
        aiofn_loop_status (*action_cancel)(void *, aiofn_loop_action_t *) noexcept nogil
        aiofn_loop_status (*add_reader)(void *, aiofn_loop_fd_watch_t *) noexcept nogil
        aiofn_loop_status (*remove_reader)(void *, aiofn_loop_fd_watch_t *) noexcept nogil
        aiofn_loop_status (*add_writer)(void *, aiofn_loop_fd_watch_t *) noexcept nogil
        aiofn_loop_status (*remove_writer)(void *, aiofn_loop_fd_watch_t *) noexcept nogil
        const char *(*last_error)(void *) noexcept nogil
        aiofn_loop_status (*signal_watch)(void *, int, aiofn_loop_signal_watch_t *) noexcept nogil
        aiofn_loop_status (*signal_unwatch)(void *, aiofn_loop_signal_watch_t *) noexcept nogil
        aiofn_loop_status (*after_fork)(void *) noexcept nogil
