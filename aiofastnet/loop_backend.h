#ifndef AIOFASTNET_LOOP_BACKEND_H
#define AIOFASTNET_LOOP_BACKEND_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#include <winsock2.h>
#else
#include <sys/socket.h>
#include <sys/uio.h>
#endif

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
    AIOFN_LOOP_NOT_SUPPORTED = 3
};


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


typedef void (*aiofn_loop_signal_fn)(
    void *callback_data,
    int signum
);

/*
 * Frontend-owned storage for one persistent signal watch. The frontend
 * initializes callback and callback_data. The backend stores its native
 * registration token in backend_token while the watch is active.
 */
typedef struct {
    aiofn_loop_signal_fn callback;
    void *callback_data;
    void *backend_token;
} aiofn_loop_signal_watch_t;

struct aiofn_reactor_backend;
typedef struct aiofn_reactor_backend aiofn_reactor_backend_t;

struct aiofn_proactor_backend;
typedef struct aiofn_proactor_backend aiofn_proactor_backend_t;

/*
* Every backend operation is called from the event-loop thread. No backend
* operation is invoked concurrently from another thread. Backends do not
* need to protect their internal structures from multi-threaded access.
*
* A frontend callback may invoke backend operations before it
* returns. The backend must therefore permit same-thread reentrancy.
* A callback may remove and destroy the action or watch that invoked it.
* The backend must not dereference that action or watch after the callback returns.
*
* LoopBase validates public arguments and enforces backend lifecycle rules before
* making a call. Consequently, backend operations may assume that state and
* pointer arguments are valid, calls are made in the permitted lifecycle state,
* and add/remove operations have valid matching registrations. Backends still
* must handle failures reported by the native loop library.
*/
typedef struct {
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
     * Notify the backend that an action registered by call_soon() or call_at()
     * was cancelled. User-visible cancellation is owned by the frontend, which
     * will never execute a cancelled action. On success, the backend clears
     * backend_token and synchronously guarantees that it will neither invoke
     * callback nor access action later, allowing the frontend to release it
     * immediately. It does not call callback.
     */
    aiofn_loop_status (*action_cancel)(void *state, aiofn_loop_action_t *action);

    /*
     * Add a persistent watch for signum. The frontend owns watch and keeps it
     * alive until signal_unwatch() succeeds. The callback runs during normal
     * event dispatch, never directly from an OS signal handler and never inline
     * from signal_watch(). There is at most one watch for each signal number.
     * Aiofastnet retains ownership of callback_data.
     */
    aiofn_loop_status (*signal_watch)(
        void *state,
        int signum,
        aiofn_loop_signal_watch_t *watch
    );

    /*
     * Remove a signal watch. On success, its callback will not be called
     * later, the adapter no longer accesses callback_data, watch becomes
     * invalid, and the process-level disposition for signum is restored to
     * what it was before signal_watch().
     */
    aiofn_loop_status (*signal_unwatch)(
        void *state,
        aiofn_loop_signal_watch_t *watch
    );

    /* Optional readiness-based socket interface; NULL means unsupported. */
    const aiofn_reactor_backend_t *reactor;

    /* Optional completion-based socket interface; NULL means unsupported. */
    const aiofn_proactor_backend_t *proactor;

    /*
     * Optional diagnostic for the most recent failed operation. The returned
     * UTF-8 string remains valid until the next backend operation. It may be
     * NULL when no detail is available.
     */
    const char *(*last_error)(void *state);
} aiofn_loop_backend_t;

#define AIOFN_LOOP_FIELD_END(type_name, field) \
    (offsetof(type_name, field) + sizeof(((type_name *)0)->field))

#define AIOFN_LOOP_BACKEND_MIN_SIZE AIOFN_LOOP_FIELD_END(aiofn_loop_backend_t, last_error)
#define AIOFN_LOOP_BACKEND_CURRENT_SIZE AIOFN_LOOP_FIELD_END(aiofn_loop_backend_t, last_error)

#ifdef __cplusplus
}
#endif

#include "loop_backend_reactor.h"
#include "loop_backend_proactor.h"

#endif
