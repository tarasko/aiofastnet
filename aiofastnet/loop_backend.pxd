from libc.stddef cimport size_t
from libc.stdint cimport int32_t, uint32_t, uint64_t


cdef extern from "loop_backend.h":
    ctypedef int32_t aiofn_loop_status

    enum:
        AIOFN_LOOP_OK
        AIOFN_LOOP_ERROR
        AIOFN_LOOP_NO_MEMORY
        AIOFN_LOOP_NOT_SUPPORTED
        AIOFN_LOOP_FD_READ
        AIOFN_LOOP_FD_WRITE
        AIOFN_LOOP_BACKEND_MIN_SIZE
        AIOFN_REACTOR_BACKEND_MIN_SIZE
        AIOFN_PROACTOR_BACKEND_MIN_SIZE

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

    ctypedef struct aiofn_reactor_backend_t:
        size_t struct_size
        aiofn_loop_status (*add_reader)(void *, aiofn_loop_fd_watch_t *) noexcept nogil
        aiofn_loop_status (*remove_reader)(void *, aiofn_loop_fd_watch_t *) noexcept nogil
        aiofn_loop_status (*add_writer)(void *, aiofn_loop_fd_watch_t *) noexcept nogil
        aiofn_loop_status (*remove_writer)(void *, aiofn_loop_fd_watch_t *) noexcept nogil

    ctypedef struct aiofn_loop_buffer_t:
        void *iov_base
        size_t iov_len

    void aiofn_loop_buffer_init(aiofn_loop_buffer_t *, void *, size_t) noexcept nogil

    ctypedef struct aiofn_loop_proactor_socket_t:
        int fd
        void *backend_token

    ctypedef struct aiofn_loop_proactor_op_t

    ctypedef void (*aiofn_loop_proactor_callback_fn)(aiofn_loop_proactor_op_t *) noexcept nogil

    ctypedef struct aiofn_loop_proactor_op_t:
        aiofn_loop_proactor_callback_fn callback
        void *callback_data
        void *backend_token
        aiofn_loop_status status
        size_t transferred

    ctypedef struct aiofn_proactor_backend_t:
        size_t struct_size
        aiofn_loop_status (*wrap_socket)(void *, aiofn_loop_proactor_socket_t *) noexcept nogil
        aiofn_loop_status (*unwrap_socket)(void *, aiofn_loop_proactor_socket_t *) noexcept nogil
        aiofn_loop_status (*connect)(void *, aiofn_loop_proactor_socket_t *, aiofn_loop_proactor_op_t *, const void *, size_t) noexcept nogil
        aiofn_loop_status (*read)(void *, aiofn_loop_proactor_socket_t *, aiofn_loop_proactor_op_t *, void *, size_t) noexcept nogil
        aiofn_loop_status (*write)(void *, aiofn_loop_proactor_socket_t *, aiofn_loop_proactor_op_t *, const aiofn_loop_buffer_t *, size_t) noexcept nogil
        aiofn_loop_status (*cancel)(void *, aiofn_loop_proactor_op_t *) noexcept nogil

    ctypedef struct aiofn_loop_backend_t:
        size_t struct_size
        void *state
        const char *name
        const aiofn_reactor_backend_t *reactor
        const aiofn_proactor_backend_t *proactor

        aiofn_loop_status (*run)(void *) noexcept nogil
        void (*stop)(void *) noexcept nogil
        void (*close)(void *) noexcept nogil

        uint64_t (*now_ns)(void *) noexcept nogil

        aiofn_loop_status (*call_soon)(void *, aiofn_loop_action_t *) noexcept nogil
        aiofn_loop_status (*call_at)(void *, aiofn_loop_action_t *, uint64_t) noexcept nogil
        aiofn_loop_status (*action_cancel)(void *, aiofn_loop_action_t *) noexcept nogil

        aiofn_loop_status (*signal_watch)(void *, int, aiofn_loop_signal_watch_t *) noexcept nogil
        aiofn_loop_status (*signal_unwatch)(void *, aiofn_loop_signal_watch_t *) noexcept nogil

        const char *(*last_error)(void *) noexcept nogil
