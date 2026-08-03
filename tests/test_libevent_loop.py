import asyncio
import contextvars
import os
import socket
import sys
import threading

import pytest

pytestmark = pytest.mark.skipif(os.name != "posix", reason="the libevent reference backend is Unix-only")


@pytest.fixture
def libevent_loop():
    from aiofastnet.libevent_loop import new_event_loop

    loop = new_event_loop()
    try:
        yield loop
    finally:
        loop.close()


def test_run_until_complete_and_timer_cancel(libevent_loop):
    called = []

    async def main():
        timer = libevent_loop.call_later(3600, called.append, "cancelled")
        timer.cancel()
        libevent_loop.call_soon(called.append, "soon")
        await asyncio.sleep(0.01)
        return "done"

    assert libevent_loop.run_until_complete(main()) == "done"
    assert called == ["soon"]


def test_loop_is_standalone_extension_type(libevent_loop):
    assert not isinstance(libevent_loop, asyncio.BaseEventLoop)
    assert isinstance(libevent_loop, asyncio.AbstractEventLoop)

    asyncio.set_event_loop(libevent_loop)
    try:
        assert asyncio.get_event_loop() is libevent_loop
    finally:
        asyncio.set_event_loop(None)


@pytest.mark.skipif(sys.version_info < (3, 11), reason="asyncio.Runner was added in Python 3.11")
def test_asyncio_runner_lifecycle():
    from aiofastnet.libevent_loop import new_event_loop

    async def main():
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(None, sum, [1, 2, 3])
        task = loop.create_task(asyncio.sleep(0, result=result), name="native-loop-task")
        return await task

    with asyncio.Runner(loop_factory=new_event_loop) as runner:
        assert runner.run(main()) == 6


def test_native_handle_compatibility(libevent_loop):
    value = contextvars.ContextVar("value", default="unset")
    called = []
    value.set("captured")

    def callback():
        called.append(value.get())
        value.set("callback")

    handle = libevent_loop.call_soon(callback)
    explicit_context = contextvars.copy_context()
    explicit_context.run(value.set, "explicit")
    libevent_loop.call_soon(lambda: called.append(value.get()), context=explicit_context)
    value.set("caller")

    first = libevent_loop.call_at(libevent_loop.time() + 3600, lambda: None)
    second = libevent_loop.call_at(first.when() + 1, lambda: None)
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

    libevent_loop.call_soon(libevent_loop.stop)
    libevent_loop.run_forever()
    assert called == ["captured", "explicit"]
    assert value.get() == "caller"


def test_native_handle_reports_callback_exception(libevent_loop):
    contexts = []
    libevent_loop.set_exception_handler(lambda loop, context: contexts.append(context))

    def fail():
        raise RuntimeError("callback failed")

    handle = libevent_loop.call_soon(fail)
    libevent_loop.call_soon(libevent_loop.stop)
    libevent_loop.run_forever()

    assert contexts[0]["handle"] is handle
    assert isinstance(contexts[0]["exception"], RuntimeError)
    assert contexts[0]["message"].startswith("Exception in callback")


def test_call_soon_threadsafe_wakes_loop(libevent_loop):
    called = []

    def submit():
        libevent_loop.call_soon_threadsafe(called.append, "thread")
        libevent_loop.call_soon_threadsafe(libevent_loop.stop)

    thread = threading.Thread(target=submit)
    thread.start()
    libevent_loop.run_forever()
    thread.join()

    assert called == ["thread"]


def test_fd_readiness_calls_reader_directly(libevent_loop):
    reader, writer = socket.socketpair()
    try:
        reader.setblocking(False)
        called = []

        def on_readable():
            called.append(reader.recv(1))
            libevent_loop.call_soon(called.append, "deferred")
            libevent_loop._stop_backend()

        libevent_loop.add_reader(reader, on_readable)
        writer.send(b"x")
        libevent_loop.run_forever()

        assert called == [b"x"]

        libevent_loop.call_soon(libevent_loop.stop)
        libevent_loop.run_forever()
        assert called == [b"x", "deferred"]
        assert libevent_loop.remove_reader(reader)
    finally:
        reader.close()
        writer.close()


def test_reader_can_cancel_simultaneously_ready_writer(libevent_loop):
    reader, writer = socket.socketpair()
    try:
        reader.setblocking(False)
        called = []

        def on_readable():
            called.append("read")
            reader.recv(1)
            assert libevent_loop.remove_writer(reader)
            libevent_loop.call_soon(libevent_loop.stop)

        def on_writable():
            called.append("write")

        libevent_loop.add_reader(reader, on_readable)
        libevent_loop.add_writer(reader, on_writable)
        writer.send(b"x")
        libevent_loop.run_forever()

        # libevent does not define the order of simultaneously active events, but
        # deleting the writer from the reader callback suppresses a pending call.
        assert called[-1] == "read"
        assert libevent_loop.remove_reader(reader)
    finally:
        reader.close()
        writer.close()


def test_aiofastnet_socket_transport(libevent_loop):
    peer, client = socket.socketpair()
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
        done = libevent_loop.create_future()
        transport = None

        def echo():
            peer.send(peer.recv(1024))

        libevent_loop.add_reader(peer, echo)
        try:
            transport, _protocol = await libevent_loop.create_connection(lambda: ClientProtocol(done), sock=client)
            assert await done == b"request"
        finally:
            if transport is None:
                client.close()
            else:
                transport.close()
            libevent_loop.remove_reader(peer)
            await asyncio.sleep(0)

    try:
        libevent_loop.run_until_complete(run_client())
    finally:
        peer.close()
