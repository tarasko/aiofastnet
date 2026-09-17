#ifndef AIOFASTNET_LOOP_BACKEND_PROACTOR_H
#define AIOFASTNET_LOOP_BACKEND_PROACTOR_H

#ifdef __cplusplus
extern "C" {
#endif

// Platform-native descriptor: a POSIX fd, Windows SOCKET, or Windows HANDLE.
typedef intptr_t aiofn_loop_native_handle_t;
typedef int32_t aiofn_loop_proactor_handle_kind_t;
enum {
    AIOFN_LOOP_PROACTOR_HANDLE_SOCKET = 1,
    AIOFN_LOOP_PROACTOR_HANDLE_PIPE = 2
};

// Frontend-owned native handle wrapper used by proactor operations. socktype
// is SOCK_STREAM or SOCK_DGRAM for sockets and zero for pipes. For an accept
// successful accept callback, the backend supplies an initialized socket
// wrapper. Its storage is valid only for the callback; the frontend copies the
// value into persistent storage and later passes that copy to unwrap_handle().
typedef struct {
    aiofn_loop_native_handle_t native_handle;
    aiofn_loop_proactor_handle_kind_t kind;
    int socktype;
    void *backend_token;
} aiofn_loop_proactor_handle_t;

// Platform-native file handle used by proactor file operations. It contains a
// POSIX file descriptor on Unix and a Windows HANDLE cast through intptr_t.
typedef intptr_t aiofn_loop_file_handle_t;

// Platform-native scatter-gather buffer. Keeping this representation
// identical to iovec/WSABUF lets proactor backends pass frontend-owned arrays
// directly to native APIs without allocating and copying descriptors.
#if defined(_WIN32)
typedef struct
{
    ULONG iov_len;
    CHAR* iov_base;
} aiofn_loop_buffer_t;
#else
typedef struct iovec aiofn_loop_buffer_t;
#endif

// Frontend-owned one-shot operation. The backend fills status and transferred
// before invoking callback, clears backend_token before the callback, and must
// not access this object after the callback returns.
typedef struct aiofn_loop_proactor_op aiofn_loop_proactor_op_t;
typedef void (*aiofn_loop_proactor_callback_fn)(aiofn_loop_proactor_op_t *op);
typedef struct aiofn_loop_proactor_op {
    aiofn_loop_proactor_callback_fn callback;
    void *callback_data;
    void *backend_token;
    aiofn_loop_status status;
    size_t transferred;
} aiofn_loop_proactor_op_t;

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
    aiofn_loop_proactor_handle_t *accepted_socket,
    const void *address,
    size_t address_len
);

// Proactor interface. Each operation is called from the loop thread, just
// like the common backend interface. A handle may have at most one active
// stream read or datagram read and one pending output
// operation (write, sendto, or sendfile); an input and output operation may
// overlap. The shared allocation callback supplies data buffers; datagram
// callbacks receive the source address from backend-owned storage. Except for
// the stop-completion callbacks documented on read_stop() and
// recvfrom_stop(), initiating functions must not invoke completion, read
// allocation, read completion, or accept callbacks inline; callbacks run only
// after control returns to the backend event loop.
typedef struct aiofn_proactor_backend {
    size_t struct_size;

    // Wrap an existing nonblocking socket or pipe into a native proactor
    // handle. All async operations require an already wrapped handle.
    aiofn_loop_status (*wrap_handle)(void *state, aiofn_loop_proactor_handle_t *handle);

    // Stop using the native handle and release backend resources. This does
    // not close the socket, pipe, or native handle. Front-end will take care of closing it.
    aiofn_loop_status (*unwrap_handle)(void *state, aiofn_loop_proactor_handle_t *handle);

    // Start an asynchronous connect operation on a stream socket.
    aiofn_loop_status (*connect)(
        void *state,
        aiofn_loop_proactor_handle_t *socket,
        aiofn_loop_proactor_op_t *op,
        const void *address,
        size_t address_len
    );

    // Start the handle's one pending asynchronous scatter-gather write. The
    // frontend keeps buffers and their referenced memory alive through the
    // completion callback; the backend must not access them afterwards.
    aiofn_loop_status (*write)(
        void *state,
        aiofn_loop_proactor_handle_t *handle,
        aiofn_loop_proactor_op_t *op,
        const aiofn_loop_buffer_t *buffers,
        size_t buffer_count
    );

    // Start one asynchronous datagram send to the supplied native address.
    // The address is valid only for the duration of this call; the backend
    // must copy it if the native operation retains address storage.
    aiofn_loop_status (*sendto)(
        void *state,
        aiofn_loop_proactor_handle_t *socket,
        aiofn_loop_proactor_op_t *op,
        const void *buffer,
        size_t buffer_len,
        const void *address,
        size_t address_len
    );

    // Cancel one pending connect, write, sendto, or sendfile operation.
    aiofn_loop_status (*cancel)(void *state, aiofn_loop_proactor_op_t *op);

    // Start one asynchronous file transfer on a stream socket. The frontend
    // keeps file valid until completion. The backend must not close it, change
    // its file position, or transfer more than count bytes. A successful
    // completion may be partial; op->transferred reports the number of bytes
    // sent. The frontend supplies a positive count and an explicit nonnegative
    // offset.
    aiofn_loop_status (*sendfile)(
        void *state,
        aiofn_loop_proactor_handle_t *socket,
        aiofn_loop_proactor_op_t *op,
        aiofn_loop_file_handle_t file,
        int64_t offset,
        size_t count
    );

    // Start persistent asynchronous accepts. On each successful callback the
    // backend transfers ownership of the accepted native handle to the
    // frontend. The address pointer is valid only during the callback.
    aiofn_loop_status (*accept_start)(
        void *state,
        aiofn_loop_proactor_handle_t *listener,
        aiofn_loop_accept_callback_fn callback,
        void *callback_data
    );

    // Stop persistent asynchronous accepts.
    aiofn_loop_status (*accept_stop)(
        void *state,
        aiofn_loop_proactor_handle_t *listener
    );

    // Start persistent asynchronous reads on a stream socket or pipe. A
    // successful callback with zero bytes signals stream EOF. A non-NULL
    // buffer returned by alloc remains borrowed until the backend passes it
    // to the read callback, invokes a later alloc callback after completing
    // an unreported empty read, or completes read_stop(). The backend must
    // stop accessing the old buffer before entering any of those callbacks.
    aiofn_loop_status (*read_start)(
        void *state,
        aiofn_loop_proactor_handle_t *handle,
        aiofn_loop_read_alloc_fn alloc,
        aiofn_loop_read_callback_fn callback,
        void *callback_data
    );

    // Asynchronously stop persistent reads on a stream socket or pipe.
    // On success:
    //
    // - no new allocation callback is invoked;
    // - the already-issued read may invoke its read callback at most once;
    // - that read callback, when present, precedes stop_op->callback; and
    // - stop_op->callback is invoked exactly once, after the backend can no
    //   longer invoke either read callback or access callback_data or any
    //   buffer returned by the allocation callback.
    //
    // The frontend initializes stop_op->callback and callback_data. If the
    // stop remains pending, the backend stores a non-NULL cancellation token
    // in backend_token. Before invoking the callback, it fills status, sets
    // transferred to zero, and clears backend_token. A backend that
    // synchronously quiesces the read may invoke the stop callback inline;
    // otherwise it invokes it later from the backend event loop. The frontend
    // must therefore be ready for completion before making this call.
    //
    // Callback invocation establishes quiescence regardless of status. The
    // frontend must not call read_start() or unwrap_handle() before it runs,
    // but may do so from the callback. The backend must not access stop_op or
    // the frontend handle after invoking the callback. It may retain detached
    // private bookkeeping for native cancellation completions, but that state
    // must no longer refer to frontend callbacks or buffers. On immediate
    // failure the backend does not invoke or retain stop_op and leaves
    // backend_token NULL.
    aiofn_loop_status (*read_stop)(
        void *state,
        aiofn_loop_proactor_handle_t *handle,
        aiofn_loop_proactor_op_t *stop_op
    );

    // Start persistent asynchronous datagram receives. alloc supplies the
    // data buffer under the same borrowing rules as read_start(); the backend
    // supplies source-address storage to callback.
    aiofn_loop_status (*recvfrom_start)(
        void *state,
        aiofn_loop_proactor_handle_t *socket,
        aiofn_loop_read_alloc_fn alloc,
        aiofn_loop_recvfrom_callback_fn callback,
        void *callback_data
    );

    // Asynchronously stop persistent datagram receives. It has the same completion, ordering,
    // and ownership contract as read_stop(). A receive callback delivered
    // after this call retains its datagram boundary and source address, whose
    // storage remains valid only for that callback.
    aiofn_loop_status (*recvfrom_stop)(
        void *state,
        aiofn_loop_proactor_handle_t *socket,
        aiofn_loop_proactor_op_t *stop_op
    );
} aiofn_proactor_backend_t;

#define AIOFN_PROACTOR_BACKEND_MIN_SIZE AIOFN_LOOP_FIELD_END(aiofn_proactor_backend_t, recvfrom_stop)
#define AIOFN_PROACTOR_BACKEND_CURRENT_SIZE AIOFN_LOOP_FIELD_END(aiofn_proactor_backend_t, recvfrom_stop)

#ifdef __cplusplus
}
#endif

#endif
