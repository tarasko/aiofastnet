import asyncio
import inspect
import logging
import os
import signal
import socket
import sys
import threading
import traceback
import warnings
import weakref

from asyncio import format_helpers
from concurrent.futures import ThreadPoolExecutor

from .api_connect_accepted_socket import connect_accepted_socket
from .api_create_connection import create_connection
from .api_create_datagram_endpoint import create_datagram_endpoint
from .api_create_server import create_server
from .api_create_unix_connection import create_unix_connection
from .api_create_unix_server import create_unix_server
from .api_pipe import connect_read_pipe, connect_write_pipe
from .api_sendfile import sendfile
from .api_start_tls import start_tls
from .loop_backend cimport (
    AIOFN_LOOP_BACKEND_CAPSULE_NAME,
    AIOFN_LOOP_BACKEND_MIN_SIZE,
    AIOFN_LOOP_CALLBACK_SUCCESS,
    AIOFN_LOOP_FD_READ,
    AIOFN_LOOP_FD_WRITE,
    AIOFN_LOOP_OK,
    aiofn_loop_backend,
    aiofn_loop_callback_status,
    aiofn_loop_fd_watch,
    aiofn_loop_status,
    aiofn_loop_timer,
)
from .utils cimport Callback, NoResult, unlikely

from cpython.contextvars cimport PyContext_CopyCurrent, PyContext_Enter, PyContext_Exit
from cpython.object cimport Py_EQ, Py_GE, Py_GT, Py_LE, Py_LT, Py_NE
from cpython.pycapsule cimport PyCapsule_CheckExact, PyCapsule_GetPointer
from cpython.pythread cimport PyThread_get_thread_ident
from cpython.ref cimport Py_DECREF, Py_INCREF
from libc.stdint cimport uint32_t, uint64_t

cdef:
    const char *_CAPSULE_NAME = AIOFN_LOOP_BACKEND_CAPSULE_NAME
    bint _FORMAT_CALLBACK_HAS_DEBUG = sys.version_info >= (3, 13)
    bint _PY311 = sys.version_info >= (3, 11)
    bint _PY314 = sys.version_info >= (3, 14)
    object _logger = logging.getLogger("asyncio")

cdef:
    aio_Future = asyncio.Future
    aio_Task = asyncio.Task


cdef class LoopBase


cdef class Handle:
    # Use create_handle to construct instances

    cdef:
        object __weakref__
        object _callback
        object _args
        object _context
        LoopBase _loop
        object _source_traceback
        object _repr
        bint _cancelled
        bint _is_c_callback
        double _when
        aiofn_loop_timer *_timer_token

    cdef inline NoResult _init(self, callback, args, LoopBase loop, context, double when) except NoResult.EXC:
        self._callback = callback
        self._args = args
        self._is_c_callback = isinstance(callback, Callback)
        if self._is_c_callback:
            assert not args
        self._context = context or PyContext_CopyCurrent()
        self._loop = loop
        self._cancelled = False
        self._repr = None
        if loop._debug:
            self._source_traceback = format_helpers.extract_stack(sys._getframe(1))
        else:
            self._source_traceback = None
        self._when = when
        self._timer_token = NULL

    def __repr__(self):
        cdef list info
        if self._repr is not None:
            return self._repr
        info = [self.__class__.__name__]
        if self._cancelled:
            info.append("cancelled")
        if self._when != 0:
            info.append(f"when={self._when}")
        if self._callback is not None:
            info.append(self._format_callback_source())
        if self._source_traceback:
            frame = self._source_traceback[len(self._source_traceback) - 1]
            info.append(f"created at {frame[0]}:{frame[1]}")
        return "<{}>".format(" ".join(info))

    cpdef object get_context(self):
        return self._context

    cpdef cancel(self):
        cdef aiofn_loop_timer *timer = self._timer_token
        if not self._cancelled:
            if timer != NULL:
                self._timer_token = NULL
                self._loop._backend_cancel_timer(timer)
            self._cancelled = True
            if self._loop._debug:
                self._repr = repr(self)
            self._callback = None
            self._args = None

    cpdef bint cancelled(self):
        return self._cancelled

    cdef inline NoResult _run(self) except NoResult.EXC:
        cdef object exc = None

        PyContext_Enter(self._context)
        try:
            if self._is_c_callback:
                (<Callback>self._callback).run()
            else:
                self._callback(*self._args)
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as caught:
            exc = caught
        finally:
            PyContext_Exit(self._context)

        if unlikely(exc is not None):
            context = {
                "message": f"Exception in callback {self._format_callback_source()}",
                "exception": exc,
                "handle": self,
            }
            if self._source_traceback:
                context["source_traceback"] = self._source_traceback
            self._loop.call_exception_handler(context)
        return NoResult.OK

    cdef inline object _format_callback_source(self):
        if _FORMAT_CALLBACK_HAS_DEBUG:
            return format_helpers._format_callback_source(self._callback, self._args, debug=self._loop.get_debug())
        return format_helpers._format_callback_source(self._callback, self._args)


cdef class TimerHandle(Handle):
    # Use create_timer_handle to construct instances

    def __hash__(self):
        return hash(self._when)

    def __richcmp__(self, other, int op):
        cdef:
            TimerHandle handle
            bint equal
        if not isinstance(other, TimerHandle):
            return NotImplemented
        handle = other
        equal = (self._when == handle._when and self._callback == handle._callback and self._args == handle._args and
                 self._cancelled == handle._cancelled)
        if op == Py_LT:
            return self._when < handle._when
        if op == Py_LE:
            return self._when < handle._when or equal
        if op == Py_EQ:
            return equal
        if op == Py_NE:
            return not equal
        if op == Py_GT:
            return self._when > handle._when
        if op == Py_GE:
            return self._when > handle._when or equal
        return NotImplemented

    cpdef double when(self):
        return self._when


cdef inline Handle create_handle(callback, args, LoopBase loop, context=None):
    cdef Handle self = <Handle>Handle.__new__(Handle)
    self._init(callback, args, loop, context, 0.0)
    return self


cdef inline TimerHandle create_timer_handle(callback, args, LoopBase loop, double when, context=None):
    cdef TimerHandle self = <TimerHandle>TimerHandle.__new__(TimerHandle)
    self._init(callback, args, loop, context, when)
    return self


cdef inline object fileobj_to_fd(fileobj):
    if isinstance(fileobj, int):
        fd = fileobj
    else:
        try:
            fd = fileobj.fileno()
        except (AttributeError, TypeError, ValueError):
            raise ValueError(f"Invalid file object: {fileobj!r}") from None
    if fd < 0:
        raise ValueError(f"Invalid file descriptor: {fd}")
    return fd


cdef class _FDCallbacks:
    cdef:
        LoopBase loop
        int fd
        aiofn_loop_fd_watch *watch
        Handle reader
        Handle writer

        # Retain the registered objects so their finalizers cannot close and allow reuse of the watched fd.
        object reader_fileobj
        object writer_fileobj

    def __init__(self, loop, fd):
        self.loop = loop
        self.fd = fd
        self.watch = NULL
        self.reader = None
        self.writer = None
        self.reader_fileobj = None
        self.writer_fileobj = None

    cdef inline uint32_t events(self) noexcept:
        cdef uint32_t events = 0
        if self.reader is not None:
            events |= AIOFN_LOOP_FD_READ
        if self.writer is not None:
            events |= AIOFN_LOOP_FD_WRITE
        return events


cdef void _handle_callback(void *callback_data, aiofn_loop_callback_status status) noexcept with gil:
    cdef:
        Handle handle = <Handle>callback_data
        LoopBase loop = handle._loop
    try:
        handle._timer_token = NULL
        if status == AIOFN_LOOP_CALLBACK_SUCCESS and not handle._cancelled:
            loop._run_handle(handle)
    except BaseException as exc:
        loop._backend_failed(exc)
    finally:
        Py_DECREF(handle)

cdef void _fd_ready_callback(void *callback_data, uint32_t events) noexcept with gil:
    cdef _FDCallbacks callbacks = <_FDCallbacks>callback_data
    try:
        callbacks.loop._fd_ready(callbacks, events)
    except BaseException as exc:
        callbacks.loop._backend_failed(exc)


def _run_until_complete_cb(future):
    if not future.cancelled():
        exc = future.exception()
        if isinstance(exc, (SystemExit, KeyboardInterrupt)):
            return
    future.get_loop().stop()


cdef class LoopBase:
    """Asyncio event loop frontend driven by an ``aiofn_loop_backend``."""

    cdef:
        object __weakref__
        aiofn_loop_backend *_backend
        object _backend_owner
        str _backend_name
        object _backend_fatal_error
        dict _backend_fd_callbacks
        dict _backend_signal_handlers
        object _backend_signal_reader
        object _backend_signal_writer
        int _backend_old_wakeup_fd

        bint _closed
        bint _debug
        uint64_t _thread_id
        public double slow_callback_duration

        object _task_factory
        object _exception_handler
        object _default_executor
        bint _executor_shutdown_called

        object _asyncgens
        bint _asyncgens_shutdown_called
        bint _coroutine_origin_tracking_enabled
        int _coroutine_origin_tracking_saved_depth
        Handle _current_handle

    connect_accepted_socket = connect_accepted_socket
    connect_read_pipe = connect_read_pipe
    connect_write_pipe = connect_write_pipe
    create_connection = create_connection
    create_datagram_endpoint = create_datagram_endpoint
    create_server = create_server
    create_unix_connection = create_unix_connection
    create_unix_server = create_unix_server
    sendfile = sendfile
    start_tls = start_tls

    def __init__(self, backend):
        cdef aiofn_loop_backend *backend_ptr

        if not PyCapsule_CheckExact(backend):
            raise TypeError("backend must be an aiofastnet loop backend capsule")

        backend_ptr = <aiofn_loop_backend *>PyCapsule_GetPointer(backend, _CAPSULE_NAME)
        if backend_ptr.struct_size < AIOFN_LOOP_BACKEND_MIN_SIZE:
            raise ValueError("loop backend structure is too small")

        if (backend_ptr.state == NULL or backend_ptr.run == NULL or backend_ptr.stop == NULL or backend_ptr.close == NULL or
                backend_ptr.now_ns == NULL or backend_ptr.call_soon == NULL or backend_ptr.call_soon_threadsafe == NULL or
                backend_ptr.call_at == NULL or backend_ptr.timer_cancel == NULL or backend_ptr.fd_watch == NULL or
                backend_ptr.fd_update == NULL or backend_ptr.fd_unwatch == NULL):
            raise ValueError("loop backend is missing a required operation")

        self._backend = backend_ptr
        self._backend_owner = backend
        assert backend_ptr.name != NULL
        self._backend_name = backend_ptr.name.decode("utf-8", "replace")
        self._backend_fatal_error = None
        self._backend_fd_callbacks = {}
        self._backend_signal_handlers = {}
        self._backend_signal_reader = None
        self._backend_signal_writer = None
        self._backend_old_wakeup_fd = -1
        self._closed = False
        self._debug = bool(os.environ.get("PYTHONASYNCIODEBUG"))
        self._thread_id = 0
        self.slow_callback_duration = 0.1
        self._task_factory = None
        self._exception_handler = None
        self._default_executor = None
        self._executor_shutdown_called = False
        self._asyncgens = weakref.WeakSet()
        self._asyncgens_shutdown_called = False
        self._coroutine_origin_tracking_enabled = False
        self._coroutine_origin_tracking_saved_depth = 0
        self._current_handle = None

    def __repr__(self):
        return "<{}.{} backend={!r} running={} closed={} debug={}>".format(
            self.__class__.__module__, self.__class__.__name__, self._backend_name, self.is_running(), self.is_closed(), self.get_debug()
        )

    cdef inline object _backend_error(self, str operation):
        cdef const char *detail = NULL
        if self._backend.last_error != NULL:
            detail = self._backend.last_error(self._backend.state)
        if detail != NULL:
            return RuntimeError(f"{operation} failed: {detail.decode('utf-8', 'replace')}")
        return RuntimeError(f"{operation} failed in {self._backend_name} backend")

    cdef inline NoResult _backend_schedule(self, object handle, bint threadsafe) except NoResult.EXC:
        cdef aiofn_loop_status status
        Py_INCREF(handle)
        if threadsafe:
            status = self._backend.call_soon_threadsafe(self._backend.state, _handle_callback, <void *>handle)
        else:
            status = self._backend.call_soon(self._backend.state, _handle_callback, <void *>handle)
        if status != AIOFN_LOOP_OK:
            Py_DECREF(handle)
            raise self._backend_error("call_soon_threadsafe" if threadsafe else "call_soon")
        return NoResult.OK

    cdef inline aiofn_loop_timer *_backend_schedule_at(self, object handle, uint64_t deadline_ns) except NULL:
        cdef:
            aiofn_loop_timer *timer = NULL
            aiofn_loop_status status
        Py_INCREF(handle)
        status = self._backend.call_at(self._backend.state, _handle_callback, <void *>handle, deadline_ns, &timer)
        if status != AIOFN_LOOP_OK:
            Py_DECREF(handle)
            raise self._backend_error("call_at")
        return timer

    cdef inline NoResult _backend_cancel_timer(self, aiofn_loop_timer *timer) except NoResult.EXC:
        cdef aiofn_loop_status status = self._backend.timer_cancel(self._backend.state, timer)
        if status != AIOFN_LOOP_OK:
            raise self._backend_error("timer_cancel")
        return NoResult.OK

    cdef inline aiofn_loop_fd_watch *_backend_watch(self, int fd, uint32_t events, object callback_data) except NULL:
        cdef:
            aiofn_loop_fd_watch *watch = NULL
            aiofn_loop_status status
        Py_INCREF(callback_data)
        status = self._backend.fd_watch(self._backend.state, fd, events, _fd_ready_callback, <void *>callback_data, &watch)
        if status != AIOFN_LOOP_OK:
            Py_DECREF(callback_data)
            raise self._backend_error("fd_watch")
        return watch

    cdef inline NoResult _backend_update_watch(self, aiofn_loop_fd_watch *watch, uint32_t events) except NoResult.EXC:
        cdef aiofn_loop_status status = self._backend.fd_update(self._backend.state, watch, events)
        if status != AIOFN_LOOP_OK:
            raise self._backend_error("fd_update")
        return NoResult.OK

    cdef inline NoResult _backend_unwatch(self, aiofn_loop_fd_watch *watch, object callback_data) except NoResult.EXC:
        cdef aiofn_loop_status status = self._backend.fd_unwatch(self._backend.state, watch)
        if status != AIOFN_LOOP_OK:
            raise self._backend_error("fd_unwatch")
        Py_DECREF(callback_data)
        return NoResult.OK

    cdef inline aiofn_loop_status _backend_run(self) noexcept:
        cdef aiofn_loop_status status
        with nogil:
            status = self._backend.run(self._backend.state)
        return status

    cdef inline NoResult _check_closed(self) except NoResult.EXC:
        if self._closed:
            raise RuntimeError("Event loop is closed")
        return NoResult.OK

    cdef inline NoResult _check_running(self) except NoResult.EXC:
        if self._thread_id != 0:
            raise RuntimeError("This event loop is already running")
        if asyncio.events._get_running_loop() is not None:
            raise RuntimeError("Cannot run the event loop while another loop is running")
        return NoResult.OK

    cdef inline NoResult _check_thread(self) except NoResult.EXC:
        if self._thread_id != 0 and self._thread_id != <uint64_t>PyThread_get_thread_ident():
            raise RuntimeError("Non-thread-safe operation invoked on an event loop other than the current one")
        return NoResult.OK

    cdef inline NoResult _check_callback(self, object callback, object method) except NoResult.EXC:
        if asyncio.iscoroutine(callback) or inspect.iscoroutinefunction(callback):
            raise TypeError(f"coroutines cannot be used with {method}()")
        if not callable(callback):
            raise TypeError(f"a callable object was expected by {method}(), got {callback!r}")
        return NoResult.OK

    cpdef is_running(self):
        return self._thread_id != 0

    cpdef is_closed(self):
        return bool(self._closed)

    def get_debug(self):
        return bool(self._debug)

    def set_debug(self, enabled):
        self._debug = bool(enabled)
        if self._thread_id != 0:
            self.call_soon_threadsafe(self._set_coroutine_origin_tracking, self._debug)

    cpdef _set_coroutine_origin_tracking(self, enabled):
        enabled = bool(enabled)
        if enabled == self._coroutine_origin_tracking_enabled:
            return
        if enabled:
            self._coroutine_origin_tracking_saved_depth = sys.get_coroutine_origin_tracking_depth()
            sys.set_coroutine_origin_tracking_depth(10)
        else:
            sys.set_coroutine_origin_tracking_depth(self._coroutine_origin_tracking_saved_depth)
        self._coroutine_origin_tracking_enabled = enabled

    def create_future(self):
        return aio_Future(loop=self)

    def create_task(self, coro, *, name=None, context=None, eager_start=None):
        self._check_closed()
        kwargs = {}
        if name is not None:
            kwargs["name"] = name
        if _PY311 and context is not None:
            kwargs["context"] = context
        if _PY314 and eager_start is not None:
            kwargs["eager_start"] = eager_start
        if self._task_factory is not None:
            return self._task_factory(self, coro, **kwargs)
        return aio_Task(coro, loop=self, **kwargs)

    def set_task_factory(self, factory):
        if factory is not None and not callable(factory):
            raise TypeError("task factory must be a callable or None")
        self._task_factory = factory

    def get_task_factory(self):
        return self._task_factory

    def run_until_complete(self, future):
        self._check_closed()
        self._check_running()
        new_task = not asyncio.isfuture(future)
        future = asyncio.ensure_future(future, loop=self)
        if new_task:
            future._log_destroy_pending = False
        future.add_done_callback(_run_until_complete_cb)
        try:
            self.run_forever()
        except BaseException:
            if new_task and future.done() and not future.cancelled():
                future.exception()
            raise
        finally:
            future.remove_done_callback(_run_until_complete_cb)
        if not future.done():
            raise RuntimeError("Event loop stopped before Future completed.")
        return future.result()

    cdef inline NoResult _run_handle(self, Handle handle) except NoResult.EXC:
        cdef double started

        if unlikely(self._debug):
            started = self.time()
            self._current_handle = handle
            try:
                handle._run()
            finally:
                self._current_handle = None
            duration = self.time() - started
            if duration >= self.slow_callback_duration:
                _logger.warning("Executing %s took %.3f seconds", handle, duration)
        else:
            handle._run()
        return NoResult.OK

    cdef inline NoResult _backend_failed(self, object exc) except NoResult.EXC:
        if self._backend_fatal_error is None:
            self._backend_fatal_error = exc
        self._backend.stop(self._backend.state)
        return NoResult.OK

    def call_soon(self, callback, *args, context=None):
        self._check_closed()
        if self._debug:
            self._check_thread()
            self._check_callback(callback, "call_soon")
        handle = create_handle(callback, args, self, context)
        self._backend_schedule(handle, False)
        return handle

    def call_soon_threadsafe(self, callback, *args, context=None):
        self._check_closed()
        if self._debug:
            self._check_callback(callback, "call_soon_threadsafe")
        handle = create_handle(callback, args, self, context)
        self._backend_schedule(handle, True)
        return handle

    def call_later(self, delay, callback, *args, context=None):
        if delay is None:
            raise TypeError("delay must not be None")
        return self.call_at(self.time() + max(0, delay), callback, *args, context=context)

    def call_at(self, when, callback, *args, context=None):
        self._check_closed()
        if self._debug:
            self._check_thread()
            self._check_callback(callback, "call_at")
        handle = create_timer_handle(callback, args, self, when, context)
        deadline_ns = max(0, int(when * 1_000_000_000))
        handle._timer_token = self._backend_schedule_at(handle, deadline_ns)
        return handle

    cpdef double time(self):
        return self._backend.now_ns(self._backend.state) / 1_000_000_000

    cpdef stop(self):
        if self.is_closed():
            return
        self.call_soon(self._stop_backend)

    cpdef _stop_backend(self):
        self._backend.stop(self._backend.state)

    cpdef run_forever(self):
        self._check_closed()
        self._check_running()
        self._backend_fatal_error = None
        self._thread_id = <uint64_t>PyThread_get_thread_ident()
        self._set_coroutine_origin_tracking(self._debug)
        old_hooks = sys.get_asyncgen_hooks()
        self._setup_signal_wakeup()
        asyncio.events._set_running_loop(self)
        sys.set_asyncgen_hooks(firstiter=self._asyncgen_firstiter_hook, finalizer=self._asyncgen_finalizer_hook)
        try:
            status = self._backend_run()
        finally:
            sys.set_asyncgen_hooks(*old_hooks)
            asyncio.events._set_running_loop(None)
            self._teardown_signal_wakeup()
            self._set_coroutine_origin_tracking(False)
            self._thread_id = 0
        if self._backend_fatal_error is not None:
            raise self._backend_fatal_error
        if status != AIOFN_LOOP_OK:
            raise self._backend_error("run")

    cpdef close(self):
        if self.is_running():
            raise RuntimeError("Cannot close a running event loop")
        if self.is_closed():
            return
        self._teardown_signal_wakeup()
        for sig in tuple(self._backend_signal_handlers):
            self.remove_signal_handler(sig)
        for fd in tuple(self._backend_fd_callbacks):
            self._remove_fd(fd)
        self._backend.close(self._backend.state)
        self._closed = True
        self._executor_shutdown_called = True
        executor = self._default_executor
        if executor is not None:
            self._default_executor = None
            executor.shutdown(wait=False)

    def add_reader(self, fileobj, callback, *args):
        self._set_fd_callback(fileobj, callback, args, True)

    def remove_reader(self, fileobj):
        return self._clear_fd_callback(fileobj, True)

    def add_writer(self, fileobj, callback, *args):
        self._set_fd_callback(fileobj, callback, args, False)

    def remove_writer(self, fileobj):
        return self._clear_fd_callback(fileobj, False)

    cdef inline NoResult _set_fd_callback(self, object fileobj, object callback, tuple args, bint reader) except NoResult.EXC:
        cdef:
            Handle handle
            _FDCallbacks callbacks
            uint32_t new_events, old_events

        self._check_closed()
        if self._debug:
            self._check_thread()
            self._check_callback(callback, "add_reader" if reader else "add_writer")
        fd = fileobj_to_fd(fileobj)
        callbacks = self._backend_fd_callbacks.get(fd)
        old_events = callbacks.events() if callbacks is not None else 0
        if callbacks is None:
            callbacks = _FDCallbacks(self, fd)
            self._backend_fd_callbacks[fd] = callbacks
        handle = create_handle(callback, args, self)
        if reader:
            if callbacks.reader is not None:
                callbacks.reader.cancel()
            callbacks.reader = handle
            callbacks.reader_fileobj = fileobj
        else:
            if callbacks.writer is not None:
                callbacks.writer.cancel()
            callbacks.writer = handle
            callbacks.writer_fileobj = fileobj
        new_events = callbacks.events()
        try:
            if old_events:
                self._backend_update_watch(callbacks.watch, new_events)
            else:
                callbacks.watch = self._backend_watch(fd, new_events, callbacks)
        except BaseException:
            self._backend_fd_callbacks.pop(fd, None)
            raise
        return NoResult.OK

    cdef inline bint _clear_fd_callback(self, object fileobj, bint reader) except -1:
        cdef:
            Handle handle
            _FDCallbacks callbacks
            uint32_t events

        if self.is_closed():
            return False
        fd = fileobj_to_fd(fileobj)
        callbacks = self._backend_fd_callbacks.get(fd)
        if callbacks is None:
            return False
        handle = callbacks.reader if reader else callbacks.writer
        if handle is None:
            return False
        handle.cancel()
        if reader:
            callbacks.reader = None
            callbacks.reader_fileobj = None
        else:
            callbacks.writer = None
            callbacks.writer_fileobj = None
        events = callbacks.events()
        if events:
            self._backend_update_watch(callbacks.watch, events)
        else:
            self._remove_fd(fd)
        return True

    cdef inline NoResult _remove_fd(self, int fd) except NoResult.EXC:
        cdef _FDCallbacks callbacks
        callbacks = self._backend_fd_callbacks.pop(fd)
        self._backend_unwatch(callbacks.watch, callbacks)
        callbacks.watch = NULL
        return NoResult.OK

    cdef inline NoResult _fd_ready(self, _FDCallbacks callbacks, uint32_t events) except NoResult.EXC:
        cdef:
            Handle reader = callbacks.reader
            Handle writer = callbacks.writer
        if events & AIOFN_LOOP_FD_READ and reader is not None:
            self._run_handle(reader)
        if events & AIOFN_LOOP_FD_WRITE and writer is not None and callbacks.writer is writer:
            self._run_handle(writer)
        return NoResult.OK

    async def sock_recv(self, sock, n):
        future = self.create_future()
        def ready():
            try:
                data = sock.recv(n)
            except (BlockingIOError, InterruptedError):
                return
            except BaseException as exc:
                self.remove_reader(sock)
                future.set_exception(exc)
            else:
                self.remove_reader(sock)
                future.set_result(data)
        self.add_reader(sock, ready)
        return await future

    async def sock_recv_into(self, sock, buf):
        future = self.create_future()
        def ready():
            try:
                count = sock.recv_into(buf)
            except (BlockingIOError, InterruptedError):
                return
            except BaseException as exc:
                self.remove_reader(sock)
                future.set_exception(exc)
            else:
                self.remove_reader(sock)
                future.set_result(count)
        self.add_reader(sock, ready)
        return await future

    async def sock_sendall(self, sock, data):
        view = memoryview(data).cast("B")
        future = self.create_future()
        sent = 0
        def ready():
            nonlocal sent
            try:
                sent += sock.send(view[sent:])
            except (BlockingIOError, InterruptedError):
                return
            except BaseException as exc:
                self.remove_writer(sock)
                future.set_exception(exc)
                return
            if sent == len(view):
                self.remove_writer(sock)
                future.set_result(None)
        self.add_writer(sock, ready)
        return await future

    async def sock_accept(self, sock):
        future = self.create_future()
        def ready():
            try:
                conn, address = sock.accept()
                conn.setblocking(False)
            except (BlockingIOError, InterruptedError):
                return
            except BaseException as exc:
                self.remove_reader(sock)
                future.set_exception(exc)
            else:
                self.remove_reader(sock)
                future.set_result((conn, address))
        self.add_reader(sock, ready)
        return await future

    async def sock_connect(self, sock, address):
        try:
            sock.connect(address)
            return
        except (BlockingIOError, InterruptedError):
            pass
        future = self.create_future()
        def ready():
            error = sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
            self.remove_writer(sock)
            if error:
                future.set_exception(OSError(error, f"Connect call failed {address}"))
            else:
                future.set_result(None)
        self.add_writer(sock, ready)
        await future

    async def sock_recvfrom(self, sock, bufsize):
        future = self.create_future()
        def ready():
            try:
                result = sock.recvfrom(bufsize)
            except (BlockingIOError, InterruptedError):
                return
            except BaseException as exc:
                self.remove_reader(sock)
                future.set_exception(exc)
            else:
                self.remove_reader(sock)
                future.set_result(result)
        self.add_reader(sock, ready)
        return await future

    async def sock_recvfrom_into(self, sock, buf, nbytes=0):
        if not nbytes:
            nbytes = len(buf)
        future = self.create_future()
        def ready():
            try:
                result = sock.recvfrom_into(buf, nbytes)
            except (BlockingIOError, InterruptedError):
                return
            except BaseException as exc:
                self.remove_reader(sock)
                future.set_exception(exc)
            else:
                self.remove_reader(sock)
                future.set_result(result)
        self.add_reader(sock, ready)
        return await future

    async def sock_sendto(self, sock, data, address):
        future = self.create_future()
        def ready():
            try:
                result = sock.sendto(data, address)
            except (BlockingIOError, InterruptedError):
                return
            except BaseException as exc:
                self.remove_writer(sock)
                future.set_exception(exc)
            else:
                self.remove_writer(sock)
                future.set_result(result)
        self.add_writer(sock, ready)
        return await future

    def get_exception_handler(self):
        return self._exception_handler

    def set_exception_handler(self, handler):
        if handler is not None and not callable(handler):
            raise TypeError(f"A callable object or None is expected, got {handler!r}")
        self._exception_handler = handler

    def default_exception_handler(self, context):
        message = context.get("message") or "Unhandled exception in event loop"
        exception = context.get("exception")
        exc_info = (type(exception), exception, exception.__traceback__) if exception is not None else False
        if "source_traceback" not in context and self._current_handle is not None and self._current_handle._source_traceback:
            context["handle_traceback"] = self._current_handle._source_traceback
        lines = [message]
        for key in sorted(context):
            if key in {"message", "exception"}:
                continue
            value = context[key]
            if key == "source_traceback":
                value = "Object created at (most recent call last):\n" + "".join(traceback.format_list(value)).rstrip()
            elif key == "handle_traceback":
                value = "Handle created at (most recent call last):\n" + "".join(traceback.format_list(value)).rstrip()
            else:
                try:
                    value = repr(value)
                except (SystemExit, KeyboardInterrupt):
                    raise
                except BaseException as exc:
                    value = f"Exception in __repr__ {exc!r}; value type: {type(value)!r}"
            lines.append(f"{key}: {value}")
        _logger.error("\n".join(lines), exc_info=exc_info)

    def call_exception_handler(self, context):
        handler = self._exception_handler
        if handler is None:
            try:
                self.default_exception_handler(context)
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException:
                _logger.error("Exception in default exception handler", exc_info=True)
            return
        try:
            thing = context.get("task") or context.get("future") or context.get("handle")
            ctx = thing.get_context() if thing is not None and hasattr(thing, "get_context") else None
            if ctx is not None and hasattr(ctx, "run"):
                ctx.run(handler, self, context)
            else:
                handler(self, context)
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            try:
                self.default_exception_handler({
                    "message": "Unhandled error in exception handler",
                    "exception": exc,
                    "context": context,
                })
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException:
                _logger.error("Exception in default exception handler while handling an unexpected error in custom exception handler", exc_info=True)

    def run_in_executor(self, executor, func, *args):
        self._check_closed()
        if self._debug:
            self._check_callback(func, "run_in_executor")
        if executor is None:
            executor = self._default_executor
            if self._executor_shutdown_called:
                raise RuntimeError("Executor shutdown has been called")
            if executor is None:
                executor = ThreadPoolExecutor(thread_name_prefix="aiofastnet")
                self._default_executor = executor
        return asyncio.wrap_future(executor.submit(func, *args), loop=self)

    def set_default_executor(self, executor):
        if not isinstance(executor, ThreadPoolExecutor):
            raise TypeError("executor must be ThreadPoolExecutor instance")
        self._default_executor = executor

    async def shutdown_default_executor(self, timeout=None):
        self._executor_shutdown_called = True
        executor = self._default_executor
        if executor is None:
            return
        future = self.create_future()
        thread = threading.Thread(target=self._do_shutdown_executor, args=(executor, future))
        thread.start()
        try:
            await future
        finally:
            thread.join(timeout)
        if thread.is_alive():
            warnings.warn(f"The executor did not finish joining within {timeout} seconds.", RuntimeWarning, stacklevel=2)
            executor.shutdown(wait=False)

    def _do_shutdown_executor(self, executor, future):
        try:
            executor.shutdown(wait=True)
            self.call_soon_threadsafe(future.set_result, None)
        except BaseException as exc:
            self.call_soon_threadsafe(future.set_exception, exc)

    async def getaddrinfo(self, host, port, *, family=0, type=0, proto=0, flags=0):
        return await self.run_in_executor(None, socket.getaddrinfo, host, port, family, type, proto, flags)

    async def getnameinfo(self, sockaddr, flags=0):
        return await self.run_in_executor(None, socket.getnameinfo, sockaddr, flags)

    def _asyncgen_finalizer_hook(self, agen):
        self._asyncgens.discard(agen)
        if not self._closed:
            self.call_soon_threadsafe(self.create_task, agen.aclose())

    def _asyncgen_firstiter_hook(self, agen):
        if self._asyncgens_shutdown_called:
            warnings.warn(f"asynchronous generator {agen!r} was scheduled after loop.shutdown_asyncgens() call", ResourceWarning, source=self)
        self._asyncgens.add(agen)

    async def shutdown_asyncgens(self):
        self._asyncgens_shutdown_called = True
        if not self._asyncgens:
            return
        generators = list(self._asyncgens)
        self._asyncgens.clear()
        results = await asyncio.gather(*[agen.aclose() for agen in generators], return_exceptions=True)
        for result, agen in zip(results, generators):
            if isinstance(result, Exception):
                self.call_exception_handler({
                    "message": f"an error occurred during closing of asynchronous generator {agen!r}",
                    "exception": result,
                    "asyncgen": agen,
                })

    cdef inline NoResult _setup_signal_wakeup(self) except NoResult.EXC:
        if threading.current_thread() is not threading.main_thread() or self._backend_signal_reader is not None:
            return NoResult.OK
        reader, writer = socket.socketpair()
        reader.setblocking(False)
        writer.setblocking(False)
        self._backend_signal_reader = reader
        self._backend_signal_writer = writer
        self.add_reader(reader, self._read_signal_wakeup)
        self._backend_old_wakeup_fd = signal.set_wakeup_fd(writer.fileno())
        return NoResult.OK

    cdef inline NoResult _teardown_signal_wakeup(self) except NoResult.EXC:
        reader = self._backend_signal_reader
        if reader is None:
            return NoResult.OK
        signal.set_wakeup_fd(self._backend_old_wakeup_fd)
        self.remove_reader(reader)
        reader.close()
        self._backend_signal_writer.close()
        self._backend_signal_reader = None
        self._backend_signal_writer = None
        self._backend_old_wakeup_fd = -1
        return NoResult.OK

    def _read_signal_wakeup(self):
        while True:
            try:
                data = self._backend_signal_reader.recv(4096)
            except (BlockingIOError, InterruptedError):
                break
            if not data:
                break
            for signum in data:
                handle = self._backend_signal_handlers.get(signum)
                if handle is not None and not handle.cancelled():
                    self._run_handle(handle)

    def add_signal_handler(self, sig, callback, *args):
        if threading.current_thread() is not threading.main_thread():
            raise RuntimeError("set_wakeup_fd only works in main thread")

        self._check_signal(sig)
        self._check_callback(callback, "add_signal_handler")

        old = self._backend_signal_handlers.get(sig)
        if old is not None:
            old.cancel()
        self._backend_signal_handlers[sig] = create_handle(callback, args, self)
        signal.signal(sig, lambda signum, frame: None)
        signal.siginterrupt(sig, False)

    def remove_signal_handler(self, sig):
        self._check_signal(sig)
        handle = self._backend_signal_handlers.pop(sig, None)
        if handle is None:
            return False
        handle.cancel()
        signal.signal(sig, signal.default_int_handler if sig == signal.SIGINT else signal.SIG_DFL)
        return True

    cdef inline NoResult _check_signal(self, object sig) except NoResult.EXC:
        if not isinstance(sig, int):
            raise TypeError(f"sig must be an int, not {sig!r}")
        if not 1 <= sig < signal.NSIG:
            raise ValueError(f"sig {sig} out of range(1, {signal.NSIG})")
        return NoResult.OK

    async def subprocess_shell(self, protocol_factory, cmd, *, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                               stderr=asyncio.subprocess.PIPE, universal_newlines=False, shell=True, bufsize=0, encoding=None, errors=None,
                               text=None, **kwargs):
        raise NotImplementedError("subprocesses are not supported")

    async def subprocess_exec(self, protocol_factory, program, *args, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                              stderr=asyncio.subprocess.PIPE, universal_newlines=False, shell=False, bufsize=0, encoding=None, errors=None,
                              text=None, **kwargs):
        raise NotImplementedError("subprocesses are not supported")


def backend_capsule_name():
    """Return the PyCapsule name expected by :class:`LoopBase`."""
    return _CAPSULE_NAME.decode("ascii")
