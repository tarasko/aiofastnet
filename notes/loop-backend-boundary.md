# Native loop boundary, draft 0

This note proposes the C boundary between `SelectorLoopBase` and a native event loop adapter. It is intentionally not a public header yet.

## Division of responsibility

`SelectorLoopBase` owns all Python and asyncio behavior:

- Python `Handle` and `TimerHandle` objects, cancellation, contexts, and exception handling;
- the pending-action list and lifetime of storage borrowed by the backend;
- reader and writer callbacks associated with each file descriptor;
- transports, protocols, streams, tasks, futures, executors, and DNS fallback;
- conversion between asyncio's floating-point seconds and the boundary's integer nanoseconds.

The native adapter owns only:

- the native loop instance and its run/stop lifecycle;
- scheduling and ordering of `call_soon()` callbacks;
- the loop's monotonic clock and native timers;
- persistent file-descriptor readiness watches;
- persistent native signal watches;

The interface contains no `PyObject *`, and the adapter never calls the Python C API. An `aiofn_loop_action_t` is embedded in an aiofastnet-owned handle. Its opaque `callback_data` may refer back to Python state; the `callback` function is responsible for entering the Python runtime.

Subprocesses, asynchronous DNS, filesystem events, and native stream abstractions are not part of this boundary.

## Proposed C interface

The canonical draft declaration is in [`aiofastnet/loop_backend.h`](../aiofastnet/loop_backend.h).

## Required semantics

All operations are serialized by `SelectorLoopBase`; a foreign thread never invokes the backend, and an adapter needs no synchronization for access through this API. Operations called reentrantly from a backend callback are still on the same event-loop thread. While `run()` is active, operations and callbacks occur only on the thread that entered it. A backend callback must never escape an exception or long-jump through native loop frames. No backend operation is active or can begin after `close()` starts.

There is no attach phase. The backend `state` is fully initialized before the `aiofn_loop_backend_t` struct is passed to `SelectorLoopBase`. Scheduling operations receive a complete frontend-owned action, watch operations carry their own typed callback and opaque context pointer, and `close()` performs final cleanup while leaving ownership of `state` with the adapter.

`run()` gives control to the native backend until `stop()` is requested or an unrecoverable backend error occurs. The adapter must keep `run()` alive even when no user fd or timer is registered. There is no single-poll mode in the common ABI; an adapter uses its native long-running driver.

`call_soon()` receives a pointer to a frontend-owned `aiofn_loop_action_t` embedded directly in a `Handle`. The backend stores its native cancellation token in `action->backend_token`, owns the scheduling queue, and later calls `action->callback(action)` on the loop thread. It must clear `backend_token` before invoking the callback and must never invoke it inline. Calls are delivered in FIFO order, but the backend is otherwise free to choose its native scheduling phase and queue implementation.

On successful scheduling, the backend borrows the action until callback invocation or cancellation; `SelectorLoopBase` keeps its containing handle alive in an intrusive pending list. Cancelling any backend-pending handle calls `action_cancel()`, giving the backend an opportunity to release its native scheduling resources immediately. User-visible cancellation remains a frontend property: a cancelled handle never executes user code. `action_cancel()` synchronously removes either a scheduled callback or timer and guarantees that the backend will never access the action again. It clears `backend_token` but does not invoke `callback`; the frontend then unlinks and releases the handle.

`SelectorLoopBase.call_soon_threadsafe()` writes an owned handle pointer to a private nonblocking pipe. The read end is registered as a persistent backend fd watch. Its readiness callback executes a bounded batch immediately on the loop thread, and closing the loop cancels every handle still in the pipe. The pipe is therefore both the cross-thread queue and wakeup mechanism; adapters implement no cross-thread operation.

The fd adapter calls `callback(callback_data, events)` immediately when readiness is reported. The function executes the current Python reader and/or writer handle before returning to the native backend. It must not route the handle through `call_soon()` or add another native scheduling round trip. This keeps the transport read and write paths on the native readiness callback's critical path.

If READ and WRITE are reported together, `SelectorLoopBase` snapshots the registrations and invokes the reader first. It must revalidate the watch and writer registration after the reader returns because the reader may close the fd, remove the writer, or replace either callback. A callback installed during readiness dispatch is not eligible for the event currently being dispatched.

One frontend-owned `aiofn_loop_fd_watch_t` is embedded in the `_FDCallbacks` object for each fd. It contains the fd, so all four operations receive the same complete watch object. Read and write readiness are registered and removed independently through `add_reader()`, `remove_reader()`, `add_writer()`, and `remove_writer()`; there is no interest-mask update operation. These names intentionally match the Python event-loop API. The same watch pointer is passed for both directions. Its callback may report both directions together so a backend with one combined native registration can dispatch a single safe frontend call.

Each successful registration stores a non-NULL backend-native token in the corresponding watch field and each successful removal clears it. After both directions are removed, the adapter guarantees that it will no longer access the watch, callback, or context, even if its native library completes cancellation asynchronously. The adapter must reproduce level-triggered behavior even if its native loop uses edge-triggered or one-shot readiness internally. Hangup and error notifications are reported as whichever of READ and WRITE are currently requested; the aiofastnet callback performs the socket operation and observes EOF or the concrete socket error.

A signal watch is persistent until removed. `signal_watch()` returns an opaque backend-native token used by `signal_unwatch()`. The adapter must deliver the callback on the loop thread during normal event dispatch, never from the asynchronous OS signal handler. There is at most one watch for each signal number. On successful removal, the adapter guarantees that it will no longer access the callback or context. `SelectorLoopBase` owns signal-number validation, Python handles, handler replacement, and restoration of the Python-visible default disposition.

`after_fork()` reinitializes native state inherited by a child process while preserving registered actions and watches. The loop must be open and inactive, and it must be the first backend operation in the child. The operation is present at the ABI boundary, but `LoopBase` does not invoke it yet because frontend-owned locks, the threadsafe pipe, executors, and thread state also need a defined child-reset policy.

`call_at()` uses the same action representation and cancellation operation as `call_soon()`. The only difference is its absolute deadline. An adapter for a library with asynchronous cancellation must detach the frontend action synchronously and may retain a separate native object until that library reports cancellation; it cannot retain or later complete the frontend action after `action_cancel()` succeeds.

Before calling backend `close()`, `SelectorLoopBase` removes all fd and signal watches and cancels every action in its pending list. The backend therefore needs no registry solely for close-time cleanup, and `close()` receives no live frontend callback pointers. A backend may still maintain native bookkeeping when its underlying library requires it for another reason.

Slow-callback measurement does not require an aiofastnet scheduling queue. Action and fd-ready callbacks use the same aiofastnet handle-execution helper, so debug timing and exception handling wrap scheduled, timed, reader, and writer callbacks. Measurement must use an uncached monotonic clock because a backend's loop clock may be cached for an entire native iteration.

`struct_size` permits fields to be appended compatibly without a separate ABI version. An adapter sets it to `AIOFN_LOOP_BACKEND_CURRENT_SIZE` from the header it was built against. Aiofastnet checks it against the permanently stable `AIOFN_LOOP_BACKEND_MIN_SIZE`, then uses `AIOFN_LOOP_BACKEND_HAS_FIELD()` before reading any later field. Existing fields are never removed, reordered, given a new signature, or assigned incompatible semantics; replacements are appended under new names. The caller's `aiofn_loop_backend_t` struct itself need not have a long lifetime because aiofastnet copies the covered fields during construction. The adapter's `state`, function code, and backend name must remain valid through `close()`.

## Deliberate choices and deferred questions

- The native backend owns `call_soon()` scheduling. Aiofastnet has neither a ready queue nor an ID-to-handle registry.
- An action embedded in each frontend handle combines completion state and the opaque backend-native token without forcing an integer lookup table or a second adapter wrapper.
- The frontend-owned fd watch is shared by separate read and write registrations. Backends whose native API uses one interest mask aggregate those registrations internally.
- Signal watches keep per-operation typed function pointers and opaque contexts; there is no loop-wide callback table or attach phase.
- `call_soon_threadsafe()` is implemented entirely by `SelectorLoopBase` with a private pointer pipe, so adapters are never entered from foreign threads.
- `run()` has no mode argument. Single-poll APIs are not uniform across native loops and are not required for `run_until_complete()`, signals, or slow-callback measurement.
- Timers use absolute unsigned nanoseconds. This avoids floating-point and unit ambiguity at the ABI while leaving epoch selection to the backend.
- The adapter owns its native allocations; the embedded action storage remains frontend-owned. Passing Python allocators is unnecessary for correctness and can be added later as optional construction data without putting the Python C API in the adapter.
- The draft has generic status values and an optional diagnostic string. Before freezing a public ABI, error propagation should be revisited to decide whether syscall error numbers need a separate, portable field.
- The ABI includes `after_fork()`, but frontend fork recovery is not wired up yet.
- Ownership of `state` stays with the adapter. The current construction API accepts a `PyCapsule` named by
  `AIOFN_LOOP_BACKEND_CAPSULE_NAME`, copies the covered backend fields, and retains the capsule as the adapter owner until `close()` returns. This capsule is
  construction glue only; backend operations do not use the Python C API.
