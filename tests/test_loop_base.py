import asyncio
import contextvars
import os
import signal
import socket
import sys
import threading

import pytest

from tests.utils import ConnectionType, TestServer

pytestmark = pytest.mark.skipif(os.name != "posix", reason="the libuv test backend is Unix-only")


def _tcp_socketpair():
    # Use TCP descriptors because epoll rejects AF_UNIX socketpair descriptors here.
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    client = socket.socket()
    client.connect(listener.getsockname())
    server, _address = listener.accept()
    listener.close()
    return server, client


@pytest.fixture
def libuv_loop():
    from tests.libuv_loop import new_event_loop

    loop = new_event_loop()
    try:
        yield loop
    finally:
        loop.close()


def test_run_until_complete_and_timer_cancel(libuv_loop):
    called = []

    async def main():
        timer = libuv_loop.call_later(3600, called.append, "cancelled")
        timer.cancel()
        libuv_loop.call_soon(called.append, "soon")
        await asyncio.sleep(0.01)
        return "done"

    assert libuv_loop.run_until_complete(main()) == "done"
    assert called == ["soon"]


def test_loop_is_standalone_extension_type(libuv_loop):
    assert not isinstance(libuv_loop, asyncio.BaseEventLoop)
    assert isinstance(libuv_loop, asyncio.AbstractEventLoop)

    asyncio.set_event_loop(libuv_loop)
    try:
        assert asyncio.get_event_loop() is libuv_loop
    finally:
        asyncio.set_event_loop(None)


@pytest.mark.skipif(sys.version_info < (3, 11), reason="asyncio.Runner was added in Python 3.11")
def test_asyncio_runner_lifecycle():
    from tests.libuv_loop import new_event_loop

    async def main():
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(None, sum, [1, 2, 3])
        task = loop.create_task(asyncio.sleep(0, result=result), name="native-loop-task")
        return await task

    with asyncio.Runner(loop_factory=new_event_loop) as runner:
        assert runner.run(main()) == 6


def test_native_handle_compatibility(libuv_loop):
    value = contextvars.ContextVar("value", default="unset")
    called = []
    value.set("captured")

    def callback():
        called.append(value.get())
        value.set("callback")

    handle = libuv_loop.call_soon(callback)
    explicit_context = contextvars.copy_context()
    explicit_context.run(value.set, "explicit")
    libuv_loop.call_soon(lambda: called.append(value.get()), context=explicit_context)
    value.set("caller")

    first = libuv_loop.call_at(libuv_loop.time() + 3600, lambda: None)
    second = libuv_loop.call_at(first.when() + 1, lambda: None)
    try:
        assert type(handle) is not type(first)
        assert isinstance(first, type(handle))
        assert not hasattr(handle, "when")
        assert handle != object()
        assert handle.get_context()[value] == "captured"
        assert not handle.cancelled()
        assert first < second
        assert first.when() < second.when()
        assert hash(first) == hash(first.when())
    finally:
        first.cancel()
        second.cancel()

    libuv_loop.call_soon(libuv_loop.stop)
    libuv_loop.run_forever()
    assert called == ["captured", "explicit"]
    assert value.get() == "caller"


def test_native_handle_reports_callback_exception(libuv_loop):
    contexts = []
    libuv_loop.set_exception_handler(lambda loop, context: contexts.append(context))

    def fail():
        raise RuntimeError("callback failed")

    handle = libuv_loop.call_soon(fail)
    libuv_loop.call_soon(libuv_loop.stop)
    libuv_loop.run_forever()

    assert contexts[0]["handle"] is handle
    assert isinstance(contexts[0]["exception"], RuntimeError)
    assert contexts[0]["message"].startswith("Exception in callback")


def test_call_soon_threadsafe_wakes_loop(libuv_loop):
    called = []

    def submit():
        libuv_loop.call_soon_threadsafe(called.append, "thread")
        libuv_loop.call_soon_threadsafe(libuv_loop.stop)

    thread = threading.Thread(target=submit)
    thread.start()
    libuv_loop.run_forever()
    thread.join()

    assert called == ["thread"]


def test_call_soon_pipe_capacity_is_reported(libuv_loop):
    for submitted in range(100_000):
        try:
            libuv_loop.call_soon_threadsafe(lambda: None)
        except RuntimeError as exc:
            assert str(exc) == "call_soon_threadsafe failed: callback pipe is full"
            break
    else:
        pytest.fail("the callback pipe did not reach its finite capacity")

    assert submitted > 0


def test_call_soon_preserves_order(libuv_loop):
    called = []
    for value in range(1_000):
        libuv_loop.call_soon(called.append, value)
    libuv_loop.call_soon(libuv_loop.stop)

    libuv_loop.run_forever()
    assert called == list(range(1_000))


def test_cancel_removes_scheduled_action(libuv_loop):
    called = []
    handle = libuv_loop.call_soon(called.append, True)
    handle.cancel()
    libuv_loop.call_soon(libuv_loop.stop)

    libuv_loop.run_forever()
    assert called == []


def test_call_soon_threadsafe_preserves_order_across_pipe_batches(libuv_loop):
    called = []
    for value in range(1_000):
        libuv_loop.call_soon_threadsafe(called.append, value)
    libuv_loop.call_soon_threadsafe(libuv_loop.stop)

    libuv_loop.run_forever()
    assert called == list(range(1_000))


def test_close_cancels_calls_still_in_pipe(libuv_loop):
    called = []
    libuv_loop.call_soon_threadsafe(called.append, True)
    libuv_loop.close()
    assert called == []


def test_close_cancels_pending_backend_actions(libuv_loop):
    called = []
    soon = libuv_loop.call_soon(called.append, "soon")
    timer = libuv_loop.call_later(3600, called.append, "timer")

    libuv_loop.close()

    assert called == []
    assert soon.cancelled()
    assert timer.cancelled()


def test_fd_readiness_calls_reader_directly(libuv_loop):
    reader, writer = _tcp_socketpair()
    try:
        reader.setblocking(False)
        called = []

        def on_readable():
            called.append(reader.recv(1))
            libuv_loop.call_soon(called.append, "deferred")
            libuv_loop._stop_backend()

        libuv_loop.add_reader(reader, on_readable)
        writer.send(b"x")
        libuv_loop.run_forever()

        assert called[0] == b"x"

        libuv_loop.call_soon(libuv_loop.stop)
        libuv_loop.run_forever()
        assert called == [b"x", "deferred"]
        assert libuv_loop.remove_reader(reader)
    finally:
        reader.close()
        writer.close()


def test_native_signal_handler_runs_directly_and_can_remove_itself(libuv_loop):
    called = []

    def on_signal():
        called.append("signal")
        assert libuv_loop.remove_signal_handler(signal.SIGUSR1)
        libuv_loop.call_soon(called.append, "deferred")
        libuv_loop._stop_backend()

    libuv_loop.add_signal_handler(signal.SIGUSR1, on_signal)
    os.kill(os.getpid(), signal.SIGUSR1)
    libuv_loop.run_forever()

    assert called[0] == "signal"
    assert not libuv_loop.remove_signal_handler(signal.SIGUSR1)

    libuv_loop.call_soon(libuv_loop.stop)
    libuv_loop.run_forever()
    assert called == ["signal", "deferred"]


def test_native_signal_handler_can_be_replaced(libuv_loop):
    called = []
    libuv_loop.add_signal_handler(signal.SIGUSR1, called.append, "old")
    libuv_loop.add_signal_handler(signal.SIGUSR1, called.append, "new")
    os.kill(os.getpid(), signal.SIGUSR1)
    libuv_loop.call_later(1, libuv_loop.stop)
    libuv_loop.run_forever()

    assert called == ["new"]
    assert libuv_loop.remove_signal_handler(signal.SIGUSR1)


def test_reader_can_cancel_simultaneously_ready_writer(libuv_loop):
    reader, writer = _tcp_socketpair()
    try:
        reader.setblocking(False)
        called = []

        def on_readable():
            called.append("read")
            reader.recv(1)
            assert libuv_loop.remove_writer(reader)
            libuv_loop.call_soon(libuv_loop.stop)

        def on_writable():
            called.append("write")

        libuv_loop.add_reader(reader, on_readable)
        libuv_loop.add_writer(reader, on_writable)
        writer.send(b"x")
        libuv_loop.run_forever()

        # libuv does not define the order of simultaneously active events, but
        # deleting the writer from the reader callback suppresses a pending call.
        assert called[-1] == "read"
        assert libuv_loop.remove_reader(reader)
    finally:
        reader.close()
        writer.close()


def test_aiofastnet_socket_transport(libuv_loop):
    peer, client = _tcp_socketpair()
    peer.setblocking(False)
    client.setblocking(False)

    class ClientProtocol(asyncio.Protocol):
        def __init__(self, done):
            self.done = done

        def connection_made(self, transport):
            self.transport = transport
            transport.write(b"request")

        def data_received(self, data):
            self.done.set_result(data)

    async def run_client():
        done = libuv_loop.create_future()
        transport = None

        def echo():
            peer.send(peer.recv(1024))

        libuv_loop.add_reader(peer, echo)
        try:
            transport, _protocol = await libuv_loop.create_connection(lambda: ClientProtocol(done), sock=client)
            assert await done == b"request"
        finally:
            if transport is None:
                client.close()
            else:
                transport.close()
            libuv_loop.remove_reader(peer)
            await asyncio.sleep(0)

    try:
        libuv_loop.run_until_complete(run_client())
    finally:
        peer.close()


def test_proactor_sock_connect_recv_sendall(libuv_loop):
    async def exchange():
        async with TestServer(ct=ConnectionType("tcp")) as server:
            client = socket.socket()
            client.setblocking(False)
            try:
                await libuv_loop.sock_connect(client, (server.host, server.port))
                for _ in range(1000):
                    await libuv_loop.sock_sendall(client, b"hello")
                    assert await libuv_loop.sock_recv(client, 5) == b"hello"
            finally:
                client.close()

    libuv_loop.run_until_complete(exchange())


def test_proactor_sock_recv_into(libuv_loop):
    async def receive_into():
        async with TestServer(ct=ConnectionType("tcp")) as server:
            client = socket.socket()
            client.setblocking(False)
            try:
                await libuv_loop.sock_connect(client, (server.host, server.port))
                await libuv_loop.sock_sendall(client, b"data!")
                buffer = bytearray(5)
                assert await libuv_loop.sock_recv_into(client, buffer) == 5
                assert buffer == b"data!"
            finally:
                client.close()

    libuv_loop.run_until_complete(receive_into())


def test_loop_base_is_standalone_extension_type(libuv_loop):
    assert not isinstance(libuv_loop, asyncio.BaseEventLoop)
    assert isinstance(libuv_loop, asyncio.AbstractEventLoop)
