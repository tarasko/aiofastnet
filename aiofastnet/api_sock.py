import socket

from .api_utils import _check_non_ssl_socket, _check_nonblocking_socket, _ensure_resolved
from .wrapped_transport import _get_original_loop_method, _should_fallback_to_asyncio


def _ensure_fd_no_transport(loop, py_sock):
    fd = py_sock.fileno()
    # asyncio rejects descriptors already owned by a transport; without this check, add_reader/add_writer would replace its callback.
    ensure = getattr(loop, "_ensure_fd_no_transport", None)
    if ensure is not None:
        ensure(fd)
    return fd


def _wrap_sock_ready_handler(future, fn):
    # This nice utility helps us to centralized error handling when socket readiness is reported.
    # We can unit-test this function, instead of trying to simulate various errors for each api
    # This greatly improves coverage
    if future.done():
        return

    try:
        fn()
    except (BlockingIOError, InterruptedError):
        return
    except BaseException as exc:
        assert not future.done() # If fn set result on future it should be the very last operation
        future.set_exception(exc)


async def sock_connect(loop, py_sock, address):
    _check_non_ssl_socket(py_sock)
    _check_nonblocking_socket(py_sock)

    if py_sock.family == socket.AF_INET or (hasattr(socket, "AF_INET6") and py_sock.family == socket.AF_INET6):
        resolved = await _ensure_resolved(
            address,
            family=py_sock.family,
            type=py_sock.type,
            proto=py_sock.proto,
            loop=loop,
        )
        _, _, _, _, address = resolved[0]

    if _should_fallback_to_asyncio(loop):
        # Windows ConnectEx requires a numeric address, so resolve hostnames before delegating to the proactor implementation.
        return await _get_original_loop_method(loop, "sock_connect")(py_sock, address)

    #   For a nonblocking socket, the initial connect(address) has three relevant outcomes:
    #
    #   1. Immediate success
    #
    #   py_sock.connect(address)  # returns None
    #
    #   The connection is complete. There is no deferred error to retrieve, so checking SO_ERROR is unnecessary.
    #
    #   2. Connection is in progress
    #   connect() raises one of the retryable exceptions, normally:
    #   - BlockingIOError with EINPROGRESS, EWOULDBLOCK, or sometimes EALREADY
    #   - InterruptedError with EINTR
    #
    #   This does not mean the connection failed. The kernel continues connecting asynchronously.
    #   When the socket later becomes writable, writability only means the connection attempt finished—not that it succeeded. At that point:
    #
    #   error = py_sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
    #
    #   determines the result:
    #   - 0: connection succeeded
    #   - nonzero: connection failed, for example ECONNREFUSED, ETIMEDOUT, or ENETUNREACH
    #
    #   This is why the ready handler checks SO_ERROR.
    #
    #   3. Immediate failure
    #   connect() raises another OSError directly, such as:
    #   - invalid address
    #   - unsupported address family
    #   - bad file descriptor
    #   - permission failure
    #   - some immediately detectable routing errors

    try:
        return py_sock.connect(address)
    except (BlockingIOError, InterruptedError):
        pass

    fd = _ensure_fd_no_transport(loop, py_sock)
    future = loop.create_future()

    def ready():
        error = py_sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
        if error:
            future.set_exception(OSError(error, f"Connect call failed {address}"))
        else:
            future.set_result(None)

    loop.add_writer(fd, lambda: _wrap_sock_ready_handler(future, ready))

    future.add_done_callback(lambda _: loop.remove_writer(fd))
    return await future


async def sock_accept(loop, py_sock):
    if _should_fallback_to_asyncio(loop):
        return await _get_original_loop_method(loop, "sock_accept")(py_sock)

    _check_non_ssl_socket(py_sock)
    _check_nonblocking_socket(py_sock)

    def _do_accept():
        conn, address = py_sock.accept()
        conn.setblocking(False)
        return conn, address

    try:
        return _do_accept()
    except (BlockingIOError, InterruptedError):
        pass

    fd = _ensure_fd_no_transport(loop, py_sock)
    future = loop.create_future()

    def ready():
        future.set_result(_do_accept())

    loop.add_reader(fd, lambda: _wrap_sock_ready_handler(future, ready))
    future.add_done_callback(lambda _: loop.remove_reader(fd))

    return await future


async def sock_recv(loop, py_sock, n):
    if _should_fallback_to_asyncio(loop):
        return await _get_original_loop_method(loop, "sock_recv")(py_sock, n)

    _check_non_ssl_socket(py_sock)
    _check_nonblocking_socket(py_sock)

    try:
        return py_sock.recv(n)
    except (BlockingIOError, InterruptedError):
        pass

    fd = _ensure_fd_no_transport(loop, py_sock)
    future = loop.create_future()

    def ready():
        future.set_result(py_sock.recv(n))

    loop.add_reader(fd, lambda: _wrap_sock_ready_handler(future, ready))

    future.add_done_callback(lambda _: loop.remove_reader(fd))
    return await future


async def sock_recv_into(loop, py_sock, buf, **kwargs):
    if _should_fallback_to_asyncio(loop):
        return await _get_original_loop_method(loop, "sock_recv_into")(py_sock, buf, **kwargs)

    _check_non_ssl_socket(py_sock)
    _check_nonblocking_socket(py_sock)

    try:
        return py_sock.recv_into(buf, **kwargs)
    except (BlockingIOError, InterruptedError):
        pass

    fd = _ensure_fd_no_transport(loop, py_sock)
    future = loop.create_future()

    def ready():
        future.set_result(py_sock.recv_into(buf, **kwargs))

    loop.add_reader(fd, lambda: _wrap_sock_ready_handler(future, ready))

    future.add_done_callback(lambda _: loop.remove_reader(fd))
    return await future


async def sock_recvfrom(loop, py_sock, bufsize):
    if _should_fallback_to_asyncio(loop):
        return await _get_original_loop_method(loop, "sock_recvfrom")(py_sock, bufsize)

    _check_non_ssl_socket(py_sock)
    _check_nonblocking_socket(py_sock)

    try:
        return py_sock.recvfrom(bufsize)
    except (BlockingIOError, InterruptedError):
        pass

    fd = _ensure_fd_no_transport(loop, py_sock)
    future = loop.create_future()

    def ready():
        future.set_result(py_sock.recvfrom(bufsize))

    loop.add_reader(fd, lambda: _wrap_sock_ready_handler(future, ready))

    future.add_done_callback(lambda _: loop.remove_reader(fd))
    return await future


async def sock_recvfrom_into(loop, py_sock, buf, **kwargs):
    if _should_fallback_to_asyncio(loop):
        return await _get_original_loop_method(loop, "sock_recvfrom_into")(py_sock, buf, **kwargs)

    _check_non_ssl_socket(py_sock)
    _check_nonblocking_socket(py_sock)

    try:
        return py_sock.recvfrom_into(buf, **kwargs)
    except (BlockingIOError, InterruptedError):
        pass

    fd = _ensure_fd_no_transport(loop, py_sock)
    future = loop.create_future()

    def ready():
        future.set_result(py_sock.recvfrom_into(buf, **kwargs))

    loop.add_reader(fd, lambda: _wrap_sock_ready_handler(future, ready))

    future.add_done_callback(lambda _: loop.remove_reader(fd))
    return await future


async def sock_sendto(loop, py_sock, data, address):
    if _should_fallback_to_asyncio(loop):
        return await _get_original_loop_method(loop, "sock_sendto")(py_sock, data, address)

    _check_non_ssl_socket(py_sock)
    _check_nonblocking_socket(py_sock)

    try:
        return py_sock.sendto(data, address)
    except (BlockingIOError, InterruptedError):
        pass

    fd = _ensure_fd_no_transport(loop, py_sock)
    future = loop.create_future()

    def ready():
        future.set_result(py_sock.sendto(data, address))

    loop.add_writer(fd, lambda: _wrap_sock_ready_handler(future, ready))

    future.add_done_callback(lambda _: loop.remove_writer(fd))
    return await future


async def sock_sendall(loop, py_sock, data):
    if _should_fallback_to_asyncio(loop):
        return await _get_original_loop_method(loop, "sock_sendall")(py_sock, data)

    _check_non_ssl_socket(py_sock)
    _check_nonblocking_socket(py_sock)

    try:
        sent = py_sock.send(data)
    except (BlockingIOError, InterruptedError):
        sent = 0

    if sent == len(data):
        return

    view = memoryview(data).cast("B")
    future = loop.create_future()

    def ready():
        nonlocal sent
        sent += py_sock.send(view[sent:])
        if sent == len(view):
            future.set_result(None)

    fd = _ensure_fd_no_transport(loop, py_sock)
    loop.add_writer(fd, lambda: _wrap_sock_ready_handler(future, ready))
    future.add_done_callback(lambda _: loop.remove_writer(fd))
    return await future
