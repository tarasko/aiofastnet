# Portions of this file are derived from CPython's asyncio sources
# (notably asyncio.selector_events).
# Copyright (c) Python Software Foundation.
# Licensed under the Python Software Foundation License Version 2.
# See LICENSES/PSF-2.0.txt and THIRD_PARTY_NOTICES for details.

import socket

from .api_utils import _check_non_ssl_socket, _ensure_resolved, _check_nonblocking_socket
from .wrapped_transport import _get_original_loop_method, _should_fallback_to_asyncio


def _ensure_fd_no_transport(loop, py_sock):
    fd = py_sock.fileno()
    # asyncio rejects descriptors already owned by a transport; without this check, add_reader/add_writer would replace its callback.
    ensure = getattr(loop, "_ensure_fd_no_transport", None)
    if ensure is not None:
        ensure(fd)
    return fd


def _set_result(future, result):
    if not future.done():
        future.set_result(result)


def _set_exception(future, exc):
    if not future.done():
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

    try:
        py_sock.connect(address)
        return
    except (BlockingIOError, InterruptedError):
        pass

    future = loop.create_future()

    def ready():
        if future.done():
            return

        try:
            error = py_sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
            if error:
                raise OSError(error, f"Connect call failed {address}")
        except BaseException as exc:
            _set_exception(future, exc)
        else:
            _set_result(future, None)

    fd = _ensure_fd_no_transport(loop, py_sock)
    loop.add_writer(fd, ready)
    future.add_done_callback(lambda _: loop.remove_writer(fd))
    return await future


async def sock_accept(loop, py_sock):
    if _should_fallback_to_asyncio(loop):
        return await _get_original_loop_method(loop, "sock_accept")(py_sock)

    _check_non_ssl_socket(py_sock)
    _check_nonblocking_socket(py_sock)

    def _do_accept():
        try:
            conn, address = py_sock.accept()
            conn.setblocking(False)
            return conn, address
        except (BlockingIOError, InterruptedError):
            return None

    result = _do_accept()
    if result is not None:
        return result

    future = loop.create_future()

    def ready():
        if future.done():
            return
        try:
            result = _do_accept()
            if result is not None:
                _set_result(future, result)
        except BaseException as exc:
            _set_exception(future, exc)

    fd = _ensure_fd_no_transport(loop, py_sock)
    loop.add_reader(fd, ready)
    future.add_done_callback(lambda _: loop.remove_reader(fd))
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
        if future.done():
            return
        try:
            sent += py_sock.send(view[sent:])
        except (BlockingIOError, InterruptedError):
            return
        except BaseException as exc:
            _set_exception(future, exc)
            return
        if sent == len(view):
            _set_result(future, None)

    fd = _ensure_fd_no_transport(loop, py_sock)
    loop.add_writer(fd, ready)
    future.add_done_callback(lambda _: loop.remove_writer(fd))
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

    future = loop.create_future()

    def ready():
        if future.done():
            return
        try:
            data = py_sock.recv(n)
        except (BlockingIOError, InterruptedError):
            return
        except BaseException as exc:
            _set_exception(future, exc)
        else:
            _set_result(future, data)

    fd = _ensure_fd_no_transport(loop, py_sock)
    loop.add_reader(fd, ready)
    future.add_done_callback(lambda _: loop.remove_reader(fd))
    return await future


async def sock_recv_into(loop, py_sock, buf):
    if _should_fallback_to_asyncio(loop):
        return await _get_original_loop_method(loop, "sock_recv_into")(py_sock, buf)

    _check_non_ssl_socket(py_sock)
    _check_nonblocking_socket(py_sock)

    try:
        return py_sock.recv_into(buf)
    except (BlockingIOError, InterruptedError):
        pass

    future = loop.create_future()

    def ready():
        if future.done():
            return
        try:
            count = py_sock.recv_into(buf)
        except (BlockingIOError, InterruptedError):
            return
        except BaseException as exc:
            _set_exception(future, exc)
        else:
            _set_result(future, count)

    fd = _ensure_fd_no_transport(loop, py_sock)
    loop.add_reader(fd, ready)
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

    future = loop.create_future()

    def ready():
        if future.done():
            return
        try:
            result = py_sock.recvfrom(bufsize)
        except (BlockingIOError, InterruptedError):
            return
        except BaseException as exc:
            _set_exception(future, exc)
        else:
            _set_result(future, result)

    fd = _ensure_fd_no_transport(loop, py_sock)
    loop.add_reader(fd, ready)
    future.add_done_callback(lambda _: loop.remove_reader(fd))
    return await future


async def sock_recvfrom_into(loop, py_sock, buf, nbytes=0):
    if _should_fallback_to_asyncio(loop):
        return await _get_original_loop_method(loop, "sock_recvfrom_into")(py_sock, buf, nbytes)

    _check_non_ssl_socket(py_sock)
    _check_nonblocking_socket(py_sock)

    if not nbytes:
        nbytes = len(buf)
    try:
        return py_sock.recvfrom_into(buf, nbytes)
    except (BlockingIOError, InterruptedError):
        pass

    future = loop.create_future()

    def ready():
        if future.done():
            return
        try:
            result = py_sock.recvfrom_into(buf, nbytes)
        except (BlockingIOError, InterruptedError):
            return
        except BaseException as exc:
            _set_exception(future, exc)
        else:
            _set_result(future, result)

    fd = _ensure_fd_no_transport(loop, py_sock)
    loop.add_reader(fd, ready)
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

    future = loop.create_future()

    def ready():
        if future.done():
            return
        try:
            result = py_sock.sendto(data, address)
        except (BlockingIOError, InterruptedError):
            return
        except BaseException as exc:
            _set_exception(future, exc)
        else:
            _set_result(future, result)

    fd = _ensure_fd_no_transport(loop, py_sock)
    loop.add_writer(fd, ready)
    future.add_done_callback(lambda _: loop.remove_writer(fd))
    return await future
