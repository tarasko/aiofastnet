#ifndef AIOFASTNET_LOOP_BACKEND_H
#define AIOFASTNET_LOOP_BACKEND_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* PyCapsule name accepted by the current SelectorLoopBase constructor. */
#define AIOFN_LOOP_BACKEND_CAPSULE_NAME "aiofastnet.loop_backend"

/* Fixed-width typedefs keep the ABI independent of a compiler's enum layout. */
typedef int32_t aiofn_loop_status;
enum {
    AIOFN_LOOP_OK = 0,
    AIOFN_LOOP_ERROR = 1,
    AIOFN_LOOP_NO_MEMORY = 2,
    AIOFN_LOOP_INVALID_ARGUMENT = 3,
    AIOFN_LOOP_NOT_SUPPORTED = 4
};

typedef uint32_t aiofn_loop_fd_events;
enum {
    AIOFN_LOOP_FD_READ = 1u << 0,
    AIOFN_LOOP_FD_WRITE = 1u << 1
};

typedef struct aiofn_loop_fd_watch aiofn_loop_fd_watch_t;
typedef struct aiofn_loop_signal_watch aiofn_loop_signal_watch_t;
typedef struct aiofn_loop_action aiofn_loop_action_t;

typedef void (*aiofn_loop_callback_fn)(aiofn_loop_action_t *action);

/*
 * Frontend-owned storage shared with the backend for one-shot callbacks and
 * timers. The frontend initializes callback and callback_data. The backend
 * stores its native cancellation token in backend_token while the action is
 * pending and clears it before invoking callback or successfully cancelling it.
 */
typedef struct aiofn_loop_action {
    aiofn_loop_callback_fn callback;
    void *callback_data;
    void *backend_token;
} aiofn_loop_action_t;

typedef void (*aiofn_loop_fd_ready_fn)(
    void *callback_data,
    uint32_t events
);

typedef void (*aiofn_loop_signal_fn)(
    void *callback_data,
    int signum
);

/*
* Every backend operation is called from the event-loop thread. No backend
* operation is invoked concurrently from another thread. Backends do not
* need to protect their internal structures from multi-threaded access.
*
* A frontend callback may invoke backend operations before it
* returns. The backend must therefore permit same-thread reentrancy.
* A callback may remove and destroy the action or watch that invoked it.
* The backend must not dereference that action or watch after the callback returns.
*/
typedef struct aiofn_loop_backend {
    /*
     * End offset of the last field provided by the adapter. Initialize this
     * with AIOFN_LOOP_BACKEND_CURRENT_SIZE from the header used to build the
     * adapter. New fields are appended and read only when covered by this size.
     */
    size_t struct_size;

    /*
     * Opaque adapter instance passed as the first argument to every backend
     * operation. It may point directly to a native loop, such as a libevent
     * event_base or libev ev_loop, or to an adapter-owned wrapper containing
     * the native loop and additional resources such as an ASIO work guard.
     * Aiofastnet never dereferences this pointer. It is owned by the adapter
     * and must remain valid until close() returns.
     */
    void *state;

    /* Static, UTF-8 backend name used in diagnostics. */
    const char *name;

    /*
     * Block until stop() is requested or an unrecoverable backend error
     * occurs. It must not return merely because no user work is registered.
     */
    aiofn_loop_status (*run)(void *state);

    /* Causes the active run() call to return. */
    void (*stop)(void *state);

    /*
     * Release backend-global resources. The frontend first cancels every
     * action and removes every fd and signal watch, so no callback or frontend
     * pointer remains registered when close() is called. close() is called
     * only while run() is inactive and must not free state.
     */
    void (*close)(void *state);

    /* Monotonic time in nanoseconds. This is the clock used by call_at(). */
    uint64_t (*now_ns)(void *state);

    /*
     * Schedule action. action->callback must not be called inline. Successive
     * calls are delivered in FIFO order. On success, the backend borrows action
     * until completion or action_cancel() succeeds and stores a non-NULL native
     * token in action->backend_token. On failure, it does not retain action and
     * leaves backend_token NULL.
     */
    aiofn_loop_status (*call_soon)(
        void *state,
        aiofn_loop_action_t *action
    );

    /*
     * Schedule action once at an absolute deadline on the now_ns() clock. A
     * deadline at or before now is still deferred. The ownership and token
     * rules are the same as call_soon().
     */
    aiofn_loop_status (*call_at)(
        void *state,
        aiofn_loop_action_t *action,
        uint64_t deadline_ns
    );

    /*
     * Cancel an action registered by call_soon() or call_at(). On success, the
     * backend clears backend_token and synchronously guarantees that it will
     * neither invoke callback nor access action later. It does not call callback;
     * the frontend unlinks and releases the action after this returns.
     */
    aiofn_loop_status (*action_cancel)(void *state, aiofn_loop_action_t *action);

    /*
     * Add a persistent, level-triggered readiness watch and store a
     * backend-owned cancellation token in watch_out. An fd has at most one
     * watch; READ and WRITE interests may be combined. Aiofastnet retains
     * ownership of callback_data. On failure, the adapter does not retain it
     * and *watch_out is set to NULL.
     */
    aiofn_loop_status (*fd_watch)(
        void *state,
        int fd,
        uint32_t events,
        aiofn_loop_fd_ready_fn callback,
        void *callback_data,
        aiofn_loop_fd_watch_t **watch_out
    );

    /* Replace the complete interest mask of an existing watch. */
    aiofn_loop_status (*fd_update)(
        void *state,
        aiofn_loop_fd_watch_t *watch,
        uint32_t events
    );

    /*
     * Remove an existing watch. On success, its callback will not be called
     * later, the adapter no longer accesses callback_data, and watch becomes
     * invalid.
     */
    aiofn_loop_status (*fd_unwatch)(void *state, aiofn_loop_fd_watch_t *watch);

    /*
     * Optional diagnostic for the most recent failed operation. The returned
     * UTF-8 string remains valid until the next backend operation. It may be
     * NULL when no detail is available.
     */
    const char *(*last_error)(void *state);

    /*
     * Add a persistent watch for signum and store a backend-owned token in
     * watch_out. The callback runs during normal event dispatch, never directly
     * from an OS signal handler and never inline from signal_watch(). There is
     * at most one watch for each signal number. Aiofastnet retains ownership of
     * callback_data. On failure, the adapter does not retain it and *watch_out
     * is set to NULL.
     */
    aiofn_loop_status (*signal_watch)(
        void *state,
        int signum,
        aiofn_loop_signal_fn callback,
        void *callback_data,
        aiofn_loop_signal_watch_t **watch_out
    );

    /*
     * Remove a signal watch. On success, its callback will not be called
     * later, the adapter no longer accesses callback_data, and watch becomes
     * invalid.
     */
    aiofn_loop_status (*signal_unwatch)(
        void *state,
        aiofn_loop_signal_watch_t *watch
    );
} aiofn_loop_backend_t;

#define AIOFN_LOOP_BACKEND_FIELD_END(field) \
    (offsetof(aiofn_loop_backend_t, field) + sizeof(((aiofn_loop_backend_t *)0)->field))

#define AIOFN_LOOP_BACKEND_HAS_FIELD(backend, field) \
    ((backend)->struct_size >= AIOFN_LOOP_BACKEND_FIELD_END(field))

#define AIOFN_LOOP_BACKEND_MIN_SIZE AIOFN_LOOP_BACKEND_FIELD_END(signal_unwatch)
#define AIOFN_LOOP_BACKEND_CURRENT_SIZE AIOFN_LOOP_BACKEND_MIN_SIZE

#ifdef __cplusplus
}
#endif

#endif
