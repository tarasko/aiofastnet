#ifndef AIOFASTNET_LOOP_BACKEND_REACTOR_H
#define AIOFASTNET_LOOP_BACKEND_REACTOR_H

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t aiofn_loop_fd_events;
enum {
    AIOFN_LOOP_FD_READ = 1u << 0,
    AIOFN_LOOP_FD_WRITE = 1u << 1
};

typedef void (*aiofn_loop_fd_ready_fn)(
    void *callback_data,
    uint32_t events
);

/*
 * Frontend-owned storage shared by the independent read and write watches for
 * one fd. The frontend initializes fd, callback, and callback_data. The backend
 * stores non-NULL native tokens for active directions and clears each token
 * when that direction is removed. A backend with one combined registration
 * may store the same native pointer in both token fields.
 */
typedef struct aiofn_loop_fd_watch {
    int fd;
    aiofn_loop_fd_ready_fn callback;
    void *callback_data;
    void *backend_read_token;
    void *backend_write_token;
} aiofn_loop_fd_watch_t;

/*
 * Optional readiness-based socket operations. The frontend owns each watch;
 * the reactor stores its native registration tokens in that same object.
 * struct_size permits appending operations without changing the meaning of
 * existing fields. The interface object must remain valid until backend close.
 */
typedef struct aiofn_reactor_backend {
    size_t struct_size;

    /* Add persistent, level-triggered read readiness; do not call inline. */
    aiofn_loop_status (*add_reader)(void *state, aiofn_loop_fd_watch_t *watch);

    /* Remove read readiness and clear watch->backend_read_token. */
    aiofn_loop_status (*remove_reader)(void *state, aiofn_loop_fd_watch_t *watch);

    /* Add persistent, level-triggered write readiness; do not call inline. */
    aiofn_loop_status (*add_writer)(void *state, aiofn_loop_fd_watch_t *watch);

    /* Remove write readiness and clear watch->backend_write_token. */
    aiofn_loop_status (*remove_writer)(void *state, aiofn_loop_fd_watch_t *watch);
} aiofn_reactor_backend_t;

#define AIOFN_REACTOR_BACKEND_MIN_SIZE AIOFN_LOOP_FIELD_END(aiofn_reactor_backend_t, remove_writer)
#define AIOFN_REACTOR_BACKEND_CURRENT_SIZE AIOFN_LOOP_FIELD_END(aiofn_reactor_backend_t, remove_writer)

#ifdef __cplusplus
}
#endif

#endif
