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

typedef uint32_t aiofn_loop_callback_status;
enum {
    AIOFN_LOOP_CALLBACK_SUCCESS = 0,
    AIOFN_LOOP_CALLBACK_CANCELLED = 1
};

typedef struct aiofn_loop_timer aiofn_loop_timer;
typedef struct aiofn_loop_fd_watch aiofn_loop_fd_watch;

typedef void (*aiofn_loop_completion_fn)(
    void *callback_data,
    aiofn_loop_callback_status status
);

typedef void (*aiofn_loop_fd_ready_fn)(
    void *callback_data,
    uint32_t events
);

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
     * the native loop and additional resources such as a thread-safe callback
     * queue, wakeup watcher, or ASIO work guard. Aiofastnet never dereferences
     * this pointer. It is owned by the adapter and must remain valid until
     * close() returns.
     */
    void *state;

    /* Static, UTF-8 backend name used in diagnostics. */
    const char *name;

    /*
     * Block until stop() is requested or an unrecoverable backend error
     * occurs. It must not return merely because no user work is registered.
     */
    aiofn_loop_status (*run)(void *state);

    /* Called from the loop thread. Causes the active run() call to return. */
    void (*stop)(void *state);

    /*
     * Release watches and native timers, and invoke every pending scheduled or
     * timed completion with CANCELLED. close() is called only while run() is
     * inactive and must not free state. All completions happen before close()
     * returns and no callback or callback data is used afterward.
     */
    void (*close)(void *state);

    /* Monotonic time in nanoseconds. This is the clock used by call_at(). */
    uint64_t (*now_ns)(void *state);

    /*
     * Schedule callback on the loop thread. callback must not be called inline.
     * Calls made from the loop thread are delivered in FIFO order. On success,
     * ownership of callback_data transfers to the backend; on failure, it
     * remains with the caller.
     */
    aiofn_loop_status (*call_soon)(
        void *state,
        aiofn_loop_completion_fn callback,
        void *callback_data
    );

    /*
     * Thread-safe form of call_soon(). It may be called from any thread and
     * must arrange for callback to run on the loop thread. Calls made
     * sequentially from one thread are delivered in FIFO order.
     */
    aiofn_loop_status (*call_soon_threadsafe)(
        void *state,
        aiofn_loop_completion_fn callback,
        void *callback_data
    );

    /*
     * Schedule callback once at an absolute deadline on the now_ns() clock and
     * store a backend-owned cancellation token in timer_out. A deadline at or
     * before now is still deferred. Ownership of callback_data transfers on
     * success. On failure, it remains with the caller and *timer_out is set to
     * NULL. On expiry, the timer token becomes invalid before callback is
     * called with SUCCESS.
     */
    aiofn_loop_status (*call_at)(
        void *state,
        aiofn_loop_completion_fn callback,
        void *callback_data,
        uint64_t deadline_ns,
        aiofn_loop_timer **timer_out
    );

    /*
     * Cancel a callback registered by call_at(). On success, timer becomes
     * invalid and the adapter calls the completion exactly once with CANCELLED,
     * either before returning or later on the loop thread. A successful
     * cancellation can never complete with SUCCESS. Cancellation is requested
     * only from the loop thread.
     */
    aiofn_loop_status (*timer_cancel)(void *state, aiofn_loop_timer *timer);

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
        aiofn_loop_fd_watch **watch_out
    );

    /* Replace the complete interest mask of an existing watch. */
    aiofn_loop_status (*fd_update)(
        void *state,
        aiofn_loop_fd_watch *watch,
        uint32_t events
    );

    /*
     * Remove an existing watch. On success, its callback will not be called
     * later, the adapter no longer accesses callback_data, and watch becomes
     * invalid. Removal is requested only from the loop thread.
     */
    aiofn_loop_status (*fd_unwatch)(void *state, aiofn_loop_fd_watch *watch);

    /*
     * Optional diagnostic for the most recent failed operation on the loop
     * thread. The returned UTF-8 string remains valid until the next backend
     * operation. It may be NULL when no detail is available.
     */
    const char *(*last_error)(void *state);
} aiofn_loop_backend;

#define AIOFN_LOOP_BACKEND_FIELD_END(field) \
    (offsetof(aiofn_loop_backend, field) + sizeof(((aiofn_loop_backend *)0)->field))

#define AIOFN_LOOP_BACKEND_HAS_FIELD(backend, field) \
    ((backend)->struct_size >= AIOFN_LOOP_BACKEND_FIELD_END(field))

#define AIOFN_LOOP_BACKEND_MIN_SIZE AIOFN_LOOP_BACKEND_FIELD_END(last_error)
#define AIOFN_LOOP_BACKEND_CURRENT_SIZE AIOFN_LOOP_BACKEND_MIN_SIZE

#ifdef __cplusplus
}
#endif

#endif
