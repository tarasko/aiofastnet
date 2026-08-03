# Native loop boundary, draft 0

This note proposes the C boundary between `SelectorLoopBase` and a native event loop adapter. It is intentionally not a public header yet.

## Division of responsibility

`SelectorLoopBase` owns all Python and asyncio behavior:

- Python `Handle` and `TimerHandle` objects, cancellation, contexts, and exception handling;
- stable callback data passed opaquely through the backend;
- reader and writer callbacks associated with each file descriptor;
- transports, protocols, streams, tasks, futures, signals, executors, and DNS fallback;
- conversion between asyncio's floating-point seconds and the boundary's integer nanoseconds.

The native adapter owns only:

- the native loop instance and its run/stop lifecycle;
- scheduling and ordering of `call_soon()` and `call_soon_threadsafe()` callbacks;
- the loop's monotonic clock and native timers;
- persistent file-descriptor readiness watches;
- the queue and wakeup mechanism needed for cross-thread scheduling.

The interface contains no `PyObject *`, and the adapter never calls the Python C API. Callback data may refer to an aiofastnet-owned wrapper that retains Python state; the accompanying function pointer is responsible for entering the Python runtime and releasing that state when necessary.

Subprocesses, native signal handling, asynchronous DNS, filesystem events, and native stream abstractions are not part of this boundary. Unix signals can initially use Python's wakeup fd registered as an ordinary readable fd.

## Proposed C interface

The canonical draft declaration is in [`aiofastnet/loop_backend.h`](../aiofastnet/loop_backend.h).

## Required semantics

Except for `call_soon_threadsafe()`, all operations are called from the thread currently running the Python event loop. Backend callbacks are serialized on that same thread. A backend callback must never escape an exception or long-jump through native loop frames.

There is no attach phase. The backend `state` is fully initialized before the `aiofn_loop_backend` struct is passed to `SelectorLoopBase`. Each scheduling or watch operation carries its own typed callback function and opaque context pointer, and `close()` performs final cleanup while leaving ownership of `state` with the adapter.

`run()` gives control to the native backend until `stop()` is requested or an unrecoverable backend error occurs. The adapter must keep `run()` alive even when no user fd or timer is registered. There is no single-poll mode in the common ABI; an adapter uses its native long-running driver.

`call_soon()` and `call_soon_threadsafe()` transfer an `aiofn_loop_completion_fn` and opaque `callback_data` to the backend. The backend owns the scheduling queue and later calls `callback(callback_data, AIOFN_LOOP_CALLBACK_SUCCESS)` on the loop thread. It must never call the completion inline. Calls submitted sequentially from one thread are delivered in FIFO order, but the backend is otherwise free to choose its native scheduling phase and queue implementation.

On successful scheduling, the backend takes ownership of `callback_data` and must call the completion exactly once. `SUCCESS` requests normal execution, while `CANCELLED` releases the context without executing user code. Cancelling a `call_soon()` handle may be lazy: the backend can still complete it with `SUCCESS`, whose aiofastnet trampoline observes the cancelled Python handle and skips its callback. During `close()`, the adapter completes every item remaining in its scheduling queue and every outstanding timer with `CANCELLED`.

`call_soon_threadsafe()` makes the adapter responsible for both cross-thread queuing and waking the native loop. Implementations can use an eventfd or pipe plus a native queue, an async watcher, ASIO `post()`, a Tokio channel or task, or an equivalent facility. The adapter stores the function and context pointers but never interprets the context or manipulates Python objects.

The fd adapter calls `callback(callback_data, events)` immediately when readiness is reported. The function executes the current Python reader and/or writer handle before returning to the native backend. It must not route the handle through `call_soon()` or add another native scheduling round trip. This keeps the transport read and write paths on the native readiness callback's critical path.

If READ and WRITE are reported together, `SelectorLoopBase` snapshots the registrations and invokes the reader first. It must revalidate the watch and writer registration after the reader returns because the reader may close the fd, remove the writer, or replace either callback. A callback installed during readiness dispatch is not eligible for the event currently being dispatched.

An fd watch is persistent until updated or removed. `fd_watch()` returns an opaque backend-native token used by `fd_update()` and `fd_unwatch()`. On successful removal, the adapter guarantees that it will no longer access the callback or context, even if its native library completes cancellation asynchronously. The adapter must reproduce level-triggered behavior even if its native loop uses edge-triggered or one-shot readiness internally. Hangup and error notifications are reported as whichever of READ and WRITE are currently requested; the aiofastnet callback performs the socket operation and observes EOF or the concrete socket error.

`call_at()` returns an opaque backend-native timer token used for cancellation. On expiry, the token becomes invalid before the adapter calls the completion with `SUCCESS`. On successful cancellation, the token becomes invalid immediately and the adapter calls the completion exactly once with `CANCELLED`. That completion may occur during `timer_cancel()` or later on the loop thread, matching native APIs such as ASIO whose cancelled timer handler is still delivered. `close()` must deliver any outstanding cancelled completion before returning.

Slow-callback measurement does not require an aiofastnet scheduling queue. Completion and fd-ready functions use the same aiofastnet handle-execution helper, so debug timing and exception handling wrap scheduled, timed, reader, and writer callbacks. Measurement must use an uncached monotonic clock because a backend's loop clock may be cached for an entire native iteration.

`struct_size` permits fields to be appended compatibly without a separate ABI version. An adapter sets it to `AIOFN_LOOP_BACKEND_CURRENT_SIZE` from the header it was built against. Aiofastnet checks it against the permanently stable `AIOFN_LOOP_BACKEND_MIN_SIZE`, then uses `AIOFN_LOOP_BACKEND_HAS_FIELD()` before reading any later field. Existing fields are never removed, reordered, given a new signature, or assigned incompatible semantics; replacements are appended under new names. The caller's `aiofn_loop_backend` struct itself need not have a long lifetime because aiofastnet copies the covered fields during construction. The adapter's `state`, function code, and backend name must remain valid through `close()`.

## Deliberate choices and deferred questions

- The native backend owns `call_soon()` scheduling. Aiofastnet has neither a ready queue nor an ID-to-handle registry.
- Per-operation typed function pointers and opaque contexts replace a loop-wide callback table and attach phase.
- Cancellation uses opaque backend-native tokens, matching the object or handle model of common native loops without forcing an integer lookup table.
- `call_soon_threadsafe()` is a separate required operation because cross-thread queueing and wakeup belong to the native adapter under this ownership model.
- `run()` has no mode argument. Single-poll APIs are not uniform across native loops and are not required for `run_until_complete()`, signals, or slow-callback measurement.
- Timers use absolute unsigned nanoseconds. This avoids floating-point and unit ambiguity at the ABI while leaving epoch selection to the backend.
- The adapter owns all of its allocations. Passing Python allocators is unnecessary for correctness and can be added later as optional construction data without putting the Python C API in the adapter.
- The draft has generic status values and an optional diagnostic string. Before freezing a public ABI, error propagation should be revisited to decide whether syscall error numbers need a separate, portable field.
- Fork recovery is not included yet. If native backends need it, an optional `after_fork_child()` operation can be appended with a capability bit without changing the core scheduling interface.
- Ownership of `state` stays with the adapter. The current construction API accepts a `PyCapsule` named by
  `AIOFN_LOOP_BACKEND_CAPSULE_NAME`, copies the covered backend fields, and retains the capsule as the adapter owner until `close()` returns. This capsule is
  construction glue only; backend operations do not use the Python C API.
