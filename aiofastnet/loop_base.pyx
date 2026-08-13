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
from .api_sock import (
    sock_accept,
    sock_connect,
    sock_recv,
    sock_recv_into,
    sock_recvfrom,
    sock_recvfrom_into,
    sock_sendall,
    sock_sendto
)
from .loop_backend cimport (
    AIOFN_LOOP_BACKEND_CAPSULE_NAME,
    AIOFN_LOOP_BACKEND_MIN_SIZE,
    AIOFN_REACTOR_BACKEND_MIN_SIZE,
    AIOFN_PROACTOR_BACKEND_MIN_SIZE,
    AIOFN_LOOP_FD_READ,
    AIOFN_LOOP_FD_WRITE,
    AIOFN_LOOP_NOT_SUPPORTED,
    AIOFN_LOOP_NO_MEMORY,
    AIOFN_LOOP_OK,
    aiofn_loop_backend_t,
    aiofn_proactor_backend_t,
    aiofn_reactor_backend_t,
    aiofn_loop_action_t,
    aiofn_loop_fd_watch_t,
    aiofn_loop_signal_watch_t,
    aiofn_loop_status,
)
from .utils cimport (
    NoResult,
    unlikely,
)

from .utils import DNSLookupRequired

from cpython.contextvars cimport PyContext_CopyCurrent, PyContext_Enter, PyContext_Exit
from cpython.object cimport Py_EQ, Py_GE, Py_GT, Py_LE, Py_LT, Py_NE
from cpython.pycapsule cimport PyCapsule_CheckExact, PyCapsule_GetPointer
from cpython.ref cimport Py_DECREF, Py_INCREF
from cpython.pythread cimport (
    WAIT_LOCK,
    PyThread_acquire_lock,
    PyThread_allocate_lock,
    PyThread_free_lock,
    PyThread_get_thread_ident,
    PyThread_release_lock,
    PyThread_type_lock,
)
from libc.errno cimport EAGAIN, EINTR, errno
from libc.stdint cimport uint32_t, uint64_t, uint8_t
from posix.unistd cimport close as posix_close, dup as posix_dup, read as posix_read, write as posix_write

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
cdef class _SelfPipe
cdef class Handle:
    # Use create_handle to construct instances

    cdef:
        object __weakref__

        object _callback
        object _args
        object _context
        LoopBase _loop
        double _when

        bint _is_cancelled

        # If True then this Handle has been registered through backend's call_soon, call_at
        # Such handles are added to the loop._pending_handles linked list.
        # They must be removed from the list upon completion or cancellation
        bint _is_pending
        aiofn_loop_action_t _action

        object _repr
        object _source_traceback

        # Handles created by call_soon and call_at are chained via linked list.
        # This is done in order to keep track of them and properly destroy them when loop.close() is called
        # Loop doesn't use a regular container for like list because inserting and deleting is more expensive
        # with list then just assigning a reference.
        Handle _pending_previous
        Handle _pending_next

    cdef inline NoResult _init(self, callback, args, LoopBase loop, context, double when) except NoResult.EXC:
        self._callback = callback
        self._args = args if args else None
        self._context = PyContext_CopyCurrent() if context is None else context
        self._loop = loop
        self._when = when

        self._is_cancelled = False

        self._is_pending = False
        self._action.callback = _action_callback
        self._action.callback_data = <void *>self
        self._action.backend_token = NULL

        self._repr = None
        if loop._debug:
            self._source_traceback = format_helpers.extract_stack(sys._getframe(1))
        else:
            self._source_traceback = None
        self._pending_previous = None
        self._pending_next = None

    def __repr__(self):
        cdef list info
        if self._repr is not None:
            return self._repr
        info = [self.__class__.__name__]
        if self._is_cancelled:
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
        if not self._is_cancelled:
            self._is_cancelled = True
            if self._loop._debug:
                self._repr = repr(self)
            self._callback = None
            self._args = None
            if self._is_pending:
                self._loop._check_status(self._loop._backend.action_cancel(self._loop._backend.state, &self._action))
                self._loop._unlink_handle(self)

    cpdef bint cancelled(self):
        return self._is_cancelled

    cdef inline NoResult _run(self) except NoResult.EXC:
        if unlikely(self._is_cancelled):
            return NoResult.OK

        cdef:
            bint debug = self._loop._debug
            double started = self._loop.time() if debug else 0.0

        # In some scenarios user callback can cause removal of the last reference to this particular Handle
        # For example: remove_reader, remove_writer set corresponding Handle reference in _FDCallbacks to None
        # When calling _fd_callback.writer._run() cython does not increase refcnt of writer.
        # So we do it manually here before calling user callback
        cdef Handle life_extender = self

        self._loop._current_handle_source_traceback = self._source_traceback
        try:
            PyContext_Enter(self._context)
            try:
                if self._args is None:
                    self._callback()
                else:
                    self._callback(*self._args)
            finally:
                PyContext_Exit(self._context)

            if unlikely(debug):
                duration = self._loop.time() - started
                if duration >= self._loop.slow_callback_duration:
                    _logger.warning("Executing %s took %.3f seconds", self, duration)
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            if unlikely(exc is not None):
                context = {
                    "message": f"Exception in callback {self._format_callback_source()}",
                    "exception": exc,
                    "handle": self,
                }
                if self._source_traceback:
                    context["source_traceback"] = self._source_traceback
                self._loop.call_exception_handler(context)
        finally:
            self._loop._current_handle_source_traceback = None

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
                 self._is_cancelled == handle._is_cancelled)
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


cdef inline object _fileobj_to_fileno_obj(fileobj):
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
        aiofn_loop_fd_watch_t watch
        Handle reader
        Handle writer

        # Retain the registered objects so their finalizers cannot close and allow reuse of the watched fd.
        object reader_fileobj
        object writer_fileobj

    def __init__(self, loop, fd):
        self.loop = loop
        self.watch.fd = fd
        self.watch.callback = _fd_ready_callback
        self.watch.callback_data = <void *>self
        self.watch.backend_read_token = NULL
        self.watch.backend_write_token = NULL
        self.reader = None
        self.writer = None
        self.reader_fileobj = None
        self.writer_fileobj = None


cdef class _SignalCallback:
    cdef:
        LoopBase loop
        Handle handle
        aiofn_loop_signal_watch_t watch
        int signum

    def __init__(self, LoopBase loop, int signum, Handle handle):
        self.loop = loop
        self.handle = handle
        self.watch.callback = _signal_callback
        self.watch.callback_data = <void *>self
        self.watch.backend_token = NULL
        self.signum = signum


cdef void _threadsafe_ready_callback(void *callback_data, uint32_t events) noexcept with gil:
    cdef _SelfPipe self_pipe = <_SelfPipe>callback_data
    try:
        if events & AIOFN_LOOP_FD_READ:
            self_pipe.process(True)
    except BaseException as exc:
        self_pipe.loop._backend_failed(exc)


cdef class _SelfPipe:
    cdef:
        LoopBase loop
        PyThread_type_lock lifecycle_lock
        aiofn_loop_fd_watch_t watch
        int reader
        int writer

    def __cinit__(self):
        self.watch.backend_read_token = NULL
        self.watch.backend_write_token = NULL
        self.reader = -1
        self.writer = -1
        self.lifecycle_lock = PyThread_allocate_lock()
        if self.lifecycle_lock == NULL:
            raise MemoryError()

    def __init__(self, LoopBase loop):
        self.loop = loop
        reader, writer = os.pipe()
        self.reader = reader
        self.writer = writer
        try:
            os.set_blocking(reader, False)
            os.set_blocking(writer, False)
            os.set_inheritable(reader, False)
            os.set_inheritable(writer, False)
            self.watch.fd = reader
            self.watch.callback = _threadsafe_ready_callback
            self.watch.callback_data = <void *>self
            loop._check_status(loop._reactor.add_reader(loop._backend.state, &self.watch))
        except:
            posix_close(self.reader)
            posix_close(self.writer)
            self.reader = -1
            self.writer = -1
            raise

    def __dealloc__(self):
        if self.reader >= 0:
            posix_close(self.reader)
            self.reader = -1
        if self.writer >= 0:
            posix_close(self.writer)
            self.writer = -1
        if self.lifecycle_lock != NULL:
            PyThread_free_lock(self.lifecycle_lock)
            self.lifecycle_lock = NULL

    cdef inline NoResult acquire(self) except NoResult.EXC:
        cdef int acquired
        with nogil:
            acquired = PyThread_acquire_lock(self.lifecycle_lock, WAIT_LOCK)
        if not acquired:
            raise RuntimeError("could not acquire event loop lifecycle lock")
        return NoResult.OK

    cdef inline NoResult release(self) except NoResult.EXC:
        with nogil:
            PyThread_release_lock(self.lifecycle_lock)
        return NoResult.OK

    cdef inline NoResult submit(self, Handle handle) except NoResult.EXC:
        cdef:
            void *handle_ptr
            Py_ssize_t bytes_written
            int last_error

        handle_ptr = <void *>handle
        Py_INCREF(handle)
        while True:
            with nogil:
                bytes_written = posix_write(self.writer, &handle_ptr, sizeof(handle_ptr))
            if bytes_written >= 0:
                break

            last_error = errno
            if last_error == EINTR:
                continue

            Py_DECREF(handle)
            if last_error == EAGAIN:
                raise RuntimeError("call_soon_threadsafe failed: callback pipe is full")

            raise OSError(last_error, os.strerror(last_error))

        if bytes_written != sizeof(handle_ptr):
            Py_DECREF(handle)
            raise RuntimeError("call_soon_threadsafe failed: partial pointer write")

        return NoResult.OK

    cdef inline Py_ssize_t process(self, bint execute) except -1:
        cdef:
            void *handles[256]
            Handle handle
            Py_ssize_t bytes_read
            Py_ssize_t handle_count
            Py_ssize_t idx
            int last_error

        while True:
            with nogil:
                bytes_read = posix_read(self.reader, handles, sizeof(handles))
            if bytes_read >= 0:
                break
            last_error = errno
            if last_error == EINTR:
                continue
            if last_error == EAGAIN:
                return 0
            raise OSError(last_error, os.strerror(last_error))

        if bytes_read == 0:
            return 0
        if bytes_read % <Py_ssize_t>sizeof(handles[0]) != 0:
            raise RuntimeError("call_soon_threadsafe pipe returned a partial pointer")
        handle_count = bytes_read // <Py_ssize_t>sizeof(handles[0])
        for idx in range(handle_count):
            handle = <Handle>handles[idx]
            try:
                if execute:
                    handle._run()
            finally:
                Py_DECREF(handle)
        return handle_count

    cdef inline NoResult close(self) except NoResult.EXC:
        if self.watch.backend_read_token != NULL:
            self.loop._check_status(self.loop._reactor.remove_reader(self.loop._backend.state, &self.watch))

        while self.process(False) != 0:
            pass

        posix_close(self.reader)
        posix_close(self.writer)
        self.reader = -1
        self.writer = -1
        return NoResult.OK


cdef void _action_callback(aiofn_loop_action_t *action) noexcept with gil:
    cdef:
        Handle handle = <Handle>action.callback_data
        LoopBase loop = handle._loop
    try:
        loop._unlink_handle(handle)
        handle._run()
    except BaseException as exc:
        loop._backend_failed(exc)


cdef class _ProactorContext:
    cdef inline NoResult check_status(self, aiofn_loop_status status) except NoResult.EXC:
        (<LoopBase>self.loop)._check_status(status)
        return NoResult.OK

    cdef inline NoResult backend_failed(self, object exc) except NoResult.EXC:
        (<LoopBase>self.loop)._backend_failed(exc)
        return NoResult.OK

    cdef inline _ProactorSocket wrap_socket(self, object sock):
        cdef:
            int fd = _fileobj_to_fileno_obj(sock)
            _ProactorSocket result = self.sockets.get(fd)

        if result is None:
            result = <_ProactorSocket>_ProactorSocket.__new__(_ProactorSocket)
            result.context = self
            result.owner = None
            result.read_in_progress = False
            result.write_in_progress = False
            result.backend_sock.fd = fd
            result.backend_sock.socktype = <int>sock.type
            result.backend_sock.backend_token = NULL

            self.check_status(self.proactor.wrap_socket(self.backend.state, &result.backend_sock))
            self.sockets[fd] = result

        return result

    cdef inline NoResult unwrap_socket(self, _ProactorSocket sock) except NoResult.EXC:
        if not sock.read_in_progress and not sock.write_in_progress and sock.backend_sock.backend_token != NULL:
            self.check_status(self.proactor.unwrap_socket(self.backend.state, &sock.backend_sock))
            self.sockets.pop(sock.backend_sock.fd, None)
            sock.owner = None
        return NoResult.OK

    cdef NoResult close(self) except NoResult.EXC:
        cdef _ProactorSocket sock

        for socket_obj in tuple(self.sockets.values()):
            sock = <_ProactorSocket>socket_obj
            self.check_status(self.proactor.unwrap_socket(self.backend.state, &sock.backend_sock))
            sock.owner = None
        self.sockets = None
        return NoResult.OK


cdef class _ProactorSocket:
    pass


cdef void _fd_ready_callback(void *callback_data, uint32_t events) noexcept with gil:
    cdef _FDCallbacks callbacks = <_FDCallbacks>callback_data
    try:
        if events & AIOFN_LOOP_FD_READ and callbacks.reader is not None:
            callbacks.reader._run()
        if events & AIOFN_LOOP_FD_WRITE and callbacks.writer is not None:
            callbacks.writer._run()
    except BaseException as exc:
        callbacks.loop._backend_failed(exc)


cdef void _signal_callback(void *callback_data, int signum) noexcept with gil:
    cdef _SignalCallback callback = <_SignalCallback>callback_data
    try:
        if signum == callback.signum:
            callback.handle._run()
    except BaseException as exc:
        callback.loop._backend_failed(exc)


def _run_until_complete_cb(future):
    if not future.cancelled():
        exc = future.exception()
        if isinstance(exc, (SystemExit, KeyboardInterrupt)):
            return
    future.get_loop().stop()


cdef class LoopBase:
    """Asyncio event loop frontend driven by an ``aiofn_loop_backend_t``."""

    cdef:
        object __weakref__

        aiofn_loop_backend_t *_backend
        const aiofn_reactor_backend_t *_reactor
        _ProactorContext _proactor_context
        object _backend_owner
        str _backend_name
        object _backend_fatal_error

        dict _fd_callbacks      # Dict[Fileno, _FDCallbacks]
        dict _signal_handlers   # Dict[Signal, _SignalCallback]

        # An intrusive list of callbacks registered in the backend with call_soon and call_at.
        # * it keeps each Handle alive while the backend retains a pointer to its embedded aiofn_loop_action_t.
        #   The caller may immediately discard the returned Python handle.
        # * it lets LoopBase.close() enumerate pending actions, call action_cancel(), and release backend-native
        #   resources before closing the backend.
        # * this simplifies backend implementation as it does not have to keep a list of active events
        Handle _pending_handles

        # Lets exception reports raised indirectly during a callback include where that callback's handle was scheduled.
        object _current_handle_source_traceback

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

        # Self-pipe is used to implement call_soon_threadsafe
        # Another thread creates Handle object and push its pointer into the write side of the pipe
        # Loop thread receives read ready event, read from pipe, immediately run received Handle and discard it.
        # The Handle is not pushed through the usual call_soon machinery.
        _SelfPipe _self_pipe

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

    sock_accept = sock_accept
    sock_connect = sock_connect
    sock_recv = sock_recv
    sock_recv_into = sock_recv_into
    sock_recvfrom = sock_recvfrom
    sock_recvfrom_into = sock_recvfrom_into
    sock_sendall = sock_sendall
    sock_sendto = sock_sendto

    def __init__(self, backend):
        cdef:
            aiofn_loop_backend_t *backend_ptr
            const aiofn_proactor_backend_t *proactor
            _ProactorContext proactor_context

        if not PyCapsule_CheckExact(backend):
            raise TypeError("backend must be an aiofastnet loop backend capsule")

        backend_ptr = <aiofn_loop_backend_t *>PyCapsule_GetPointer(backend, _CAPSULE_NAME)
        if backend_ptr.struct_size < AIOFN_LOOP_BACKEND_MIN_SIZE:
            raise ValueError("loop backend structure is too small")

        if (backend_ptr.state == NULL or backend_ptr.run == NULL or backend_ptr.stop == NULL or backend_ptr.close == NULL or
                backend_ptr.now_ns == NULL or backend_ptr.call_soon == NULL or backend_ptr.call_at == NULL or
                backend_ptr.action_cancel == NULL or
                backend_ptr.signal_watch == NULL or
                backend_ptr.signal_unwatch == NULL):
            raise ValueError("loop backend is missing a required operation")
        if backend_ptr.reactor != NULL:
            if backend_ptr.reactor.struct_size < AIOFN_REACTOR_BACKEND_MIN_SIZE:
                raise ValueError("loop backend reactor structure is too small")
            if (backend_ptr.reactor.add_reader == NULL or backend_ptr.reactor.remove_reader == NULL or
                    backend_ptr.reactor.add_writer == NULL or backend_ptr.reactor.remove_writer == NULL):
                raise ValueError("loop backend reactor is missing a required operation")

        self._backend = backend_ptr
        self._reactor = backend_ptr.reactor
        proactor = backend_ptr.proactor
        if proactor != NULL:
            if proactor.struct_size < AIOFN_PROACTOR_BACKEND_MIN_SIZE:
                raise ValueError("loop backend proactor structure is too small")
            if (proactor.wrap_socket == NULL or proactor.unwrap_socket == NULL or
                    proactor.connect == NULL or proactor.read_start == NULL or proactor.read_stop == NULL or
                    proactor.recvfrom_start == NULL or proactor.recvfrom_stop == NULL or
                    proactor.write == NULL or proactor.cancel == NULL):
                raise ValueError("loop backend proactor is missing a required operation")

            proactor_context = <_ProactorContext>_ProactorContext.__new__(_ProactorContext)
            proactor_context.loop = self
            proactor_context.backend = backend_ptr
            proactor_context.proactor = proactor
            proactor_context.sockets = {}
            self._proactor_context = proactor_context
        else:
            self._proactor_context = None
        self._backend_owner = backend
        assert backend_ptr.name != NULL
        self._backend_name = backend_ptr.name.decode("utf-8", "replace")
        self._backend_fatal_error = None
        self._fd_callbacks = {}
        self._signal_handlers = {}
        self._pending_handles = None
        self._current_handle_source_traceback = None
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
        self._self_pipe = _SelfPipe(self)

    def __repr__(self):
        return "<{}.{} backend={!r} running={} closed={} debug={}>".format(
            self.__class__.__module__, self.__class__.__name__, self._backend_name, self.is_running(), self.is_closed(), self.get_debug()
        )

    cdef inline NoResult _check_status(self, aiofn_loop_status status) except NoResult.EXC:
        if status == AIOFN_LOOP_OK:
            return NoResult.OK

        if self._backend.last_error != NULL:
            message = self._backend.last_error(self._backend.state).decode("utf-8", "replace")
        else:
            message = f"{self._backend_name} backend error {status}"

        if status == AIOFN_LOOP_NO_MEMORY:
            raise MemoryError(message)
        elif status == AIOFN_LOOP_NOT_SUPPORTED:
            raise NotImplementedError(message)
        else:
            raise RuntimeError(message)

    cdef inline void _link_handle(self, Handle handle) noexcept:
        handle._pending_next = self._pending_handles
        if self._pending_handles is not None:
            self._pending_handles._pending_previous = handle
        self._pending_handles = handle
        handle._is_pending = True

    cdef inline void _unlink_handle(self, Handle handle) noexcept:
        if handle._is_pending:
            if handle._pending_previous is None:
                self._pending_handles = handle._pending_next
            else:
                handle._pending_previous._pending_next = handle._pending_next
            if handle._pending_next is not None:
                handle._pending_next._pending_previous = handle._pending_previous
            handle._pending_previous = None
            handle._pending_next = None
            handle._is_pending = False

    cdef inline NoResult _check_closed(self) except NoResult.EXC:
        if self._closed:
            raise RuntimeError("Event loop is closed")
        return NoResult.OK

    cdef inline NoResult _check_running(self) except NoResult.EXC:
        if self._thread_id != 0:
            raise RuntimeError("This event loop is already running")
        if asyncio.events._get_running_loop() is not None:
            raise RuntimeError("Cannot run the event loop while another loop is running")

    cdef inline NoResult _check_thread(self) except NoResult.EXC:
        if self._thread_id != 0 and self._thread_id != <uint64_t>PyThread_get_thread_ident():
            raise RuntimeError("Non-thread-safe operation invoked on an event loop other than the current one")

    cdef inline NoResult _check_callback(self, object callback, object method) except NoResult.EXC:
        if asyncio.iscoroutine(callback) or inspect.iscoroutinefunction(callback):
            raise TypeError(f"coroutines cannot be used with {method}()")
        if not callable(callback):
            raise TypeError(f"a callable object was expected by {method}(), got {callback!r}")

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

    cdef inline NoResult _backend_failed(self, object exc) except NoResult.EXC:
        if self._backend_fatal_error is None:
            self._backend_fatal_error = exc
        self._backend.stop(self._backend.state)
        return NoResult.OK

    def call_soon(self, callback, *args, context=None):
        cdef Handle handle

        self._check_closed()
        if self._debug:
            self._check_thread()
            self._check_callback(callback, "call_soon")
        handle = create_handle(callback, args, self, context)
        self._check_status(self._backend.call_soon(self._backend.state, &handle._action))
        self._link_handle(handle)
        return handle

    def call_soon_threadsafe(self, callback, *args, context=None):
        cdef Handle handle

        self._self_pipe.acquire()
        try:
            self._check_closed()
            if self._debug:
                self._check_callback(callback, "call_soon_threadsafe")
            handle = create_handle(callback, args, self, context)
            self._self_pipe.submit(handle)
            return handle
        finally:
            self._self_pipe.release()

    def call_later(self, delay, callback, *args, context=None):
        if delay is None:
            raise TypeError("delay must not be None")
        return self.call_at(self.time() + max(0, delay), callback, *args, context=context)

    def call_at(self, when, callback, *args, context=None):
        cdef:
            Handle handle
            uint64_t deadline_ns

        self._check_closed()
        if self._debug:
            self._check_thread()
            self._check_callback(callback, "call_at")
        handle = create_timer_handle(callback, args, self, when, context)
        deadline_ns = max(0, int(when * 1_000_000_000))
        self._check_status(self._backend.call_at(self._backend.state, &handle._action, deadline_ns))
        self._link_handle(handle)
        return handle

    cpdef double time(self):
        return self._backend.now_ns(self._backend.state) / 1_000_000_000

    cpdef stop(self):
        if self._closed:
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
        asyncio.events._set_running_loop(self)
        sys.set_asyncgen_hooks(firstiter=self._asyncgen_firstiter_hook, finalizer=self._asyncgen_finalizer_hook)
        try:
            with nogil:
                status = self._backend.run(self._backend.state)
        finally:
            sys.set_asyncgen_hooks(*old_hooks)
            asyncio.events._set_running_loop(None)
            self._set_coroutine_origin_tracking(False)
            self._thread_id = 0
        if self._backend_fatal_error is not None:
            raise self._backend_fatal_error
        self._check_status(status)

    cpdef close(self):
        cdef:
            _FDCallbacks fd_callback
            _SignalCallback signal_callback

        self._self_pipe.acquire()
        try:
            if self.is_running():
                raise RuntimeError("Cannot close a running event loop")
            if self._closed:
                return
            # Prevent new thread-safe submissions before backend cleanup starts.
            self._closed = True
        finally:
            self._self_pipe.release()

        self._self_pipe.close()

        for signal_callback in self._signal_handlers.values():
            self._check_status(self._backend.signal_unwatch(self._backend.state, &signal_callback.watch))
        self._signal_handlers = None

        for fd_callback in self._fd_callbacks.values():
            self._remove_fd(fd_callback)
        self._fd_callbacks = None

        if self._proactor_context is not None:
            self._proactor_context.close()
            self._proactor_context = None

        while self._pending_handles is not None:
            # Handle.cancel unlinks handle from _pending_handles
            self._pending_handles.cancel()

        self._backend.close(self._backend.state)

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

    def get_proactor_context(self):
        return self._proactor_context

    cdef inline NoResult _set_fd_callback(self, object fileobj, object callback, tuple args, bint reader) except NoResult.EXC:
        self._check_closed()
        if self._debug:
            self._check_thread()
            self._check_callback(callback, "add_reader" if reader else "add_writer")

        cdef:
            fileno_obj = _fileobj_to_fileno_obj(fileobj)
            _FDCallbacks callbacks = self._fd_callbacks.get(fileno_obj)
            bint created = False

        if callbacks is None:
            callbacks = _FDCallbacks(self, fileno_obj)
            self._fd_callbacks[fileno_obj] = callbacks
            created = True

        cdef Handle handle = create_handle(callback, args, self)
        try:
            if reader:
                if callbacks.reader is not None:
                    callbacks.reader.cancel()
                    callbacks.reader = handle
                    callbacks.reader_fileobj = fileobj
                else:
                    callbacks.reader = handle
                    callbacks.reader_fileobj = fileobj
                    self._check_status(self._reactor.add_reader(self._backend.state, &callbacks.watch))
            else:
                if callbacks.writer is not None:
                    callbacks.writer.cancel()
                    callbacks.writer = handle
                    callbacks.writer_fileobj = fileobj
                else:
                    callbacks.writer = handle
                    callbacks.writer_fileobj = fileobj
                    self._check_status(self._reactor.add_writer(self._backend.state, &callbacks.watch))
        except BaseException:
            if reader:
                callbacks.reader = None
                callbacks.reader_fileobj = None
            else:
                callbacks.writer = None
                callbacks.writer_fileobj = None

            if created:
                self._fd_callbacks.pop(fileno_obj, None)
            raise
        return NoResult.OK

    cdef inline bint _clear_fd_callback(self, object fileobj, bint reader) except -1:
        if self._closed:
            return False

        cdef:
            fd = _fileobj_to_fileno_obj(fileobj)
            _FDCallbacks callbacks = <_FDCallbacks>self._fd_callbacks.get(fd)

        if callbacks is None:
            return False

        if reader:
            if callbacks.reader is None:
                return False
            self._check_status(self._reactor.remove_reader(self._backend.state, &callbacks.watch))
            callbacks.reader = None
            callbacks.reader_fileobj = None
        else:
            if callbacks.writer is None:
                return False
            self._check_status(self._reactor.remove_writer(self._backend.state, &callbacks.watch))
            callbacks.writer = None
            callbacks.writer_fileobj = None

        if callbacks.reader is None and callbacks.writer is None:
            self._fd_callbacks.pop(fd, None)

        return True

    cdef inline NoResult _remove_fd(self, _FDCallbacks callbacks) except NoResult.EXC:
        if callbacks.reader is not None:
            self._check_status(self._reactor.remove_reader(self._backend.state, &callbacks.watch))
            callbacks.reader = None
            callbacks.reader_fileobj = None

        if callbacks.writer is not None:
            self._check_status(self._reactor.remove_writer(self._backend.state, &callbacks.watch))
            callbacks.writer = None
            callbacks.writer_fileobj = None

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

        if "source_traceback" not in context and self._current_handle_source_traceback:
            context["handle_traceback"] = self._current_handle_source_traceback

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

    def add_signal_handler(self, sig, callback, *args):
        self._check_signal(sig)
        self._check_callback(callback, "add_signal_handler")
        if threading.current_thread() is not threading.main_thread():
            raise RuntimeError("add_signal_handler() can only be called from the main thread")
        self._check_thread()
        self._check_closed()

        cdef:
            Handle handle = create_handle(callback, args, self)
            _SignalCallback signal_callback = self._signal_handlers.get(sig)

        if signal_callback is not None:
            signal_callback.handle.cancel()
            signal_callback.handle = handle
            return

        signal_callback = _SignalCallback(self, sig, handle)
        self._signal_handlers[sig] = signal_callback

        try:
            self._check_status(self._backend.signal_watch(self._backend.state, sig, &signal_callback.watch))
        except:
            self._signal_handlers.pop(sig, None)
            raise

    def remove_signal_handler(self, sig):
        self._check_signal(sig)
        self._check_thread()
        self._check_closed()

        cdef _SignalCallback signal_callback = self._signal_handlers.get(sig)
        if signal_callback is None:
            return False

        self._check_status(self._backend.signal_unwatch(self._backend.state, &signal_callback.watch))
        self._signal_handlers.pop(sig, None)
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
