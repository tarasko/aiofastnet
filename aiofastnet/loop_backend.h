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

typedef uint32_t aiofn_loop_fd_events;
enum {
    AIOFN_LOOP_FD_READ = 1u << 0,
    AIOFN_LOOP_FD_WRITE = 1u << 1
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
typedef struct {
    int fd;
    aiofn_loop_fd_ready_fn callback;
    void *callback_data;
    void *backend_read_token;
    void *backend_write_token;
} aiofn_loop_fd_watch_t;

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

/*
 * Optional readiness-based socket operations. The frontend owns each watch;
 * the reactor stores its native registration tokens in that same object.
 * struct_size permits appending operations without changing the meaning of
 * existing fields. The interface object must remain valid until backend close.
 */
typedef struct {
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

/*
 * Frontend-owned native socket wrapper used by proactor operations. For an
 * accept operation, the frontend supplies an empty wrapper with socktype set;
 * the backend fills fd/backend_token on successful completion and owns any
 * native resources until the wrapper is unwrapped.
 */
typedef struct {
    int fd;
    int socktype;
    void *backend_token;
} aiofn_loop_proactor_socket_t;

/*
 * Platform-native file handle used by proactor file operations. It contains a
 * POSIX file descriptor on Unix and a Windows HANDLE cast through intptr_t.
 */
typedef intptr_t aiofn_loop_file_handle_t;


typedef struct aiofn_loop_proactor_op aiofn_loop_proactor_op_t;

/*
 * Platform-native scatter-gather buffer. Keeping this representation
 * identical to iovec/WSABUF lets proactor backends pass frontend-owned arrays
 * directly to native APIs without allocating and copying descriptors.
 */
#if defined(_WIN32)
typedef struct
{
    ULONG iov_len;
    CHAR* iov_base;
} aiofn_loop_buffer_t;
#else
typedef struct iovec aiofn_loop_buffer_t;
#endif

static inline void aiofn_loop_buffer_init(aiofn_loop_buffer_t *buffer, void *base, size_t len) {
#if defined(_WIN32)
    buffer->iov_base = (CHAR *)base;
    buffer->iov_len = (ULONG)len;
#else
    buffer->iov_base = base;
    buffer->iov_len = len;
#endif
}

typedef void (*aiofn_loop_proactor_callback_fn)(aiofn_loop_proactor_op_t *op);

typedef void (*aiofn_loop_read_alloc_fn)(
    void *callback_data,
    size_t suggested_size,
    void **buffer,
    size_t *buffer_len
);

typedef void (*aiofn_loop_read_callback_fn)(
    void *callback_data,
    aiofn_loop_status status,
    void *buffer,
    size_t bytes_read
);

typedef void (*aiofn_loop_recvfrom_callback_fn)(
    void *callback_data,
    aiofn_loop_status status,
    void *buffer,
    size_t bytes_read,
    const struct sockaddr *address
);

typedef void (*aiofn_loop_accept_callback_fn)(
    void *callback_data,
    aiofn_loop_status status,
    aiofn_loop_proactor_socket_t *accepted_socket,
    const void *address,
    size_t address_len
);

/*
 * Frontend-owned one-shot operation. The backend fills status and transferred
 * before invoking callback, clears backend_token before the callback, and must
 * not access this object after the callback returns.
 */
typedef struct aiofn_loop_proactor_op {
    aiofn_loop_proactor_callback_fn callback;
    void *callback_data;
    void *backend_token;
    aiofn_loop_status status;
    size_t transferred;
} aiofn_loop_proactor_op_t;

/*
 * Proactor interface. Each operation is called from the loop thread, just
 * like the common backend interface. A socket may have at most one
 * active stream read, one active datagram read, and one pending output
 * operation (write, sendto, or sendfile); an input and output operation may
 * overlap. The shared allocation callback supplies data buffers; datagram
 * callbacks receive the source address from backend-owned storage. Initiating
 * functions must not invoke completion, read, or accept callbacks inline;
 * callbacks run only after control returns to the backend event loop.
 */
typedef struct {
    size_t struct_size;

    /* Wrap an existing nonblocking socket into a native proactor handle.
       All async operations require already wrapped proactor handle and not a native socket.
    */
    aiofn_loop_status (*wrap_socket)(void *state, aiofn_loop_proactor_socket_t *socket);

    /*
     * Stop using the native socket handle and release backend resources.
     * This does not close the frontend-owned socket or its fd.
     */
    aiofn_loop_status (*unwrap_socket)(void *state, aiofn_loop_proactor_socket_t *socket);

    /* Start an asynchronous connect operation. */
    aiofn_loop_status (*connect)(
        void *state,
        aiofn_loop_proactor_socket_t *socket,
        aiofn_loop_proactor_op_t *op,
        const void *address,
        size_t address_len
    );

    /* Start persistent asynchronous stream reads. A successful callback with
       zero bytes signals stream EOF. */
    aiofn_loop_status (*read_start)(
        void *state,
        aiofn_loop_proactor_socket_t *socket,
        aiofn_loop_read_alloc_fn alloc,
        aiofn_loop_read_callback_fn callback,
        void *callback_data
    );

    /* Stop persistent stream reads. */
    aiofn_loop_status (*read_stop)(
        void *state,
        aiofn_loop_proactor_socket_t *socket
    );

    /* Start the socket's one pending asynchronous scatter-gather write. The
       frontend keeps buffers and their referenced memory alive through the
       completion callback; the backend must not access them afterwards. */
    aiofn_loop_status (*write)(
        void *state,
        aiofn_loop_proactor_socket_t *socket,
        aiofn_loop_proactor_op_t *op,
        const aiofn_loop_buffer_t *buffers,
        size_t buffer_count
    );

    /* Cancel one pending connect, write, sendto, or sendfile operation. */
    aiofn_loop_status (*cancel)(void *state, aiofn_loop_proactor_op_t *op);

    /* Start persistent asynchronous datagram receives. alloc supplies the
       data buffer; the backend supplies source-address storage to callback. */
    aiofn_loop_status (*recvfrom_start)(
        void *state,
        aiofn_loop_proactor_socket_t *socket,
        aiofn_loop_read_alloc_fn alloc,
        aiofn_loop_recvfrom_callback_fn callback,
        void *callback_data
    );

    /* Stop persistent asynchronous datagram receives. */
    aiofn_loop_status (*recvfrom_stop)(
        void *state,
        aiofn_loop_proactor_socket_t *socket
    );

    /* Start one asynchronous datagram send to the supplied native address.
       The address is valid only for the duration of this call; the backend
       must copy it if the native operation retains address storage. */
    aiofn_loop_status (*sendto)(
        void *state,
        aiofn_loop_proactor_socket_t *socket,
        aiofn_loop_proactor_op_t *op,
        const void *buffer,
        size_t buffer_len,
        const void *address,
        size_t address_len
    );

    /*
     * Start persistent asynchronous accepts. On each successful callback the
     * backend transfers ownership of the accepted native handle to the
     * frontend. The address pointer is valid only during the callback.
     */
    aiofn_loop_status (*accept_start)(
        void *state,
        aiofn_loop_proactor_socket_t *listener,
        aiofn_loop_accept_callback_fn callback,
        void *callback_data
    );

    /* Stop persistent asynchronous accepts. */
    aiofn_loop_status (*accept_stop)(
        void *state,
        aiofn_loop_proactor_socket_t *listener
    );

    /*
     * Start one asynchronous file transfer on a stream socket. The frontend
     * keeps file valid until completion. The backend must not close it, change
     * its file position, or transfer more than count bytes. A successful
     * completion may be partial; op->transferred reports the number of bytes
     * sent. The frontend supplies a positive count and an explicit nonnegative
     * offset.
     */
    aiofn_loop_status (*sendfile)(
        void *state,
        aiofn_loop_proactor_socket_t *socket,
        aiofn_loop_proactor_op_t *op,
        aiofn_loop_file_handle_t file,
        int64_t offset,
        size_t count
    );
} aiofn_proactor_backend_t;

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

} aiofn_loop_backend_t;

#define AIOFN_LOOP_BACKEND_FIELD_END(field) \
    (offsetof(aiofn_loop_backend_t, field) + sizeof(((aiofn_loop_backend_t *)0)->field))

#define AIOFN_LOOP_BACKEND_HAS_FIELD(backend, field) \
    ((backend)->struct_size >= AIOFN_LOOP_BACKEND_FIELD_END(field))

#define AIOFN_REACTOR_BACKEND_FIELD_END(field) \
    (offsetof(aiofn_reactor_backend_t, field) + sizeof(((aiofn_reactor_backend_t *)0)->field))

#define AIOFN_REACTOR_BACKEND_HAS_FIELD(reactor, field) \
    ((reactor)->struct_size >= AIOFN_REACTOR_BACKEND_FIELD_END(field))

#define AIOFN_REACTOR_BACKEND_MIN_SIZE AIOFN_REACTOR_BACKEND_FIELD_END(remove_writer)
#define AIOFN_REACTOR_BACKEND_CURRENT_SIZE AIOFN_REACTOR_BACKEND_FIELD_END(remove_writer)

#define AIOFN_PROACTOR_BACKEND_FIELD_END(field) \
    (offsetof(aiofn_proactor_backend_t, field) + sizeof(((aiofn_proactor_backend_t *)0)->field))

#define AIOFN_PROACTOR_BACKEND_HAS_FIELD(proactor, field) \
    ((proactor)->struct_size >= AIOFN_PROACTOR_BACKEND_FIELD_END(field))

#define AIOFN_PROACTOR_BACKEND_MIN_SIZE AIOFN_PROACTOR_BACKEND_FIELD_END(cancel)
#define AIOFN_PROACTOR_BACKEND_CURRENT_SIZE AIOFN_PROACTOR_BACKEND_FIELD_END(sendfile)

#define AIOFN_LOOP_BACKEND_MIN_SIZE AIOFN_LOOP_BACKEND_FIELD_END(signal_unwatch)
#define AIOFN_LOOP_BACKEND_CURRENT_SIZE AIOFN_LOOP_BACKEND_FIELD_END(signal_unwatch)

#ifdef __cplusplus
}
#endif

#endif
