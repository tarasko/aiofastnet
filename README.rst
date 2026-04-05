aiofastnet
==========

.. image:: https://img.shields.io/github/actions/workflow/status/tarasko/aiofastnet/run-tests.yml?branch=master&label=tests
    :target: https://github.com/tarasko/aiofastnet/actions/workflows/run-tests.yml?query=branch%3Amaster
    :alt: Test status

.. image:: https://badge.fury.io/py/aiofastnet.svg
    :target: https://pypi.org/project/aiofastnet
    :alt: Latest PyPI package version

.. image:: https://img.shields.io/pypi/dm/aiofastnet.svg
    :target: https://pypistats.org/packages/aiofastnet
    :alt: Downloads count


``aiofastnet`` provides drop-in optimized replacements for asyncio's:

- `loop.create_connection() <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.create_connection>`_
- `loop.open_connection() <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.open_connection>`_
- `loop.create_server() <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.create_server>`_
- `loop.start_server() <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.start_server>`_
- `loop.start_tls() <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.start_tls>`_
- `loop.sendfile() <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.sendfile>`_

If your library or application already uses the ``asyncio`` streams or transport/protocol
model, ``aiofastnet`` lets you keep the same architecture while replacing one of
the most expensive layers underneath it.

Benchmark
=========

The benchmark below compares echo round-trips over loopback for TCP and SSL.
The exact gains depend on workload, message sizes, CPU, OpenSSL version, and how
much of your total runtime is spent in transport/SSL plumbing.

.. image:: https://raw.githubusercontent.com/tarasko/aiofastnet/master/examples/benchmark.png
    :target: https://github.com/tarasko/aiofastnet/master/examples/benchmark.png
    :align: center

Source: `examples/benchmark.py <https://github.com/tarasko/aiofastnet/blob/master/examples/benchmark.py>`_

In these benchmarks, ``aiofastnet`` is up to 2.2x faster than standard
``asyncio``.

``aiofastnet`` is fully compatible with free-threaded Python builds and scales
as expected when multiple event loops run in parallel across multiple threads.

.. image:: https://raw.githubusercontent.com/tarasko/aiofastnet/master/examples/benchmark_threaded.png
    :target: https://github.com/tarasko/aiofastnet/blob/master/examples/benchmark_threaded.png
    :align: center

Source: `examples/benchmark_threaded.py <https://github.com/tarasko/aiofastnet/blob/master/examples/benchmark_threaded.py>`_

Why Use aiofastnet
===================

- **Faster hot path**. Transport and SSL internals are reimplemented in Cython/C
  to reduce overhead on long-lived connections.
- **Drop-in API**. Keep using the standard ``asyncio`` streams or transport/protocol model
  and familiar loop-level networking operations.
- **Works with the event loop you already use**. ``aiofastnet`` works with
  stock ``asyncio`` loops, ``uvloop``, and ``winloop``.
- **Particularly strong for SSL-heavy workloads**. ``aiofastnet`` uses OpenSSL
  more directly and avoids extra copies in the data path.
- **Safer transport write() / writelines() behavior**. If the socket cannot accept
  everything immediately, only ``bytes`` and ``memoryview`` objects backed by
  ``bytes`` are retained without copying. Other objects, including
  ``bytearray`` and non-``bytes`` exporters, are copied before being queued.
  Unlike standard ``asyncio`` transports, this avoids sending corrupted data if
  application code modifies the underlying buffer after ``write()`` /
  ``writelines()`` returns.
- **Better SSL backpressure semantics**. Buffer sizes and write limits reflect
  what is actually queued across the stack.
- **Works for library authors**. WebSocket, HTTP, RPC, proxy, database, broker,
  and custom protocol libraries can expose the same API while giving users a
  faster transport layer.

Quickstart
==========

Install from PyPI::

    $ pip install aiofastnet

``aiofastnet`` requires Python 3.9 or greater.

The API mirrors stdlib ``asyncio``. Pass the running loop and use your existing
protocol factory:

.. code-block:: python

   import asyncio
   import aiofastnet

   class EchoClientProtocol(asyncio.Protocol):
       def connection_made(self, transport):
           self.transport = transport
           self.transport.write(b"hello")

       def data_received(self, data):
           print("received:", data)
           self.transport.close()

   async def main():
       loop = asyncio.get_running_loop()

       transport, protocol = await aiofastnet.create_connection(
           loop,
           EchoClientProtocol,
           "127.0.0.1",
           9000,
       )

       await asyncio.sleep(0.1)

   asyncio.run(main())

For servers, replace ``loop.create_server(...)`` with
``aiofastnet.create_server(loop, ...)`` in the same way.

``aiofastnet`` also exposes ``start_tls`` and ``sendfile``:

.. code-block:: python

   transport = await aiofastnet.start_tls(
       loop,
       transport,
       protocol,
       ssl_context,
       server_side=False,
       server_hostname="example.com",
   )

   await aiofastnet.sendfile(transport, fileobj)

When aiofastnet Is a Good Fit
=============================

``aiofastnet`` is most attractive when you already rely on ``asyncio``'s
transport/protocol APIs and one or more of these are true:

- You have long-lived TCP or TLS connections.
- You run protocol-heavy services where transport overhead is visible in CPU
  profiles.
- You maintain a library and want better performance without changing your
  public API.
- You care about consistent ``write()`` / ``writelines()`` buffer behavior.
- You want SSL flow control to reflect the whole buffered stack, not only part
  of it.

When Not To Use aiofastnet
==========================

``aiofastnet`` is not the right default for every networking project:

- If your workload is dominated by very short-lived connections, you should
  expect little or no gain. ``aiofastnet`` focuses on optimizing the data path
  after connection establishment.

Platform Compatibility
======================

``aiofastnet`` is built and tested on Linux, macOS, and Windows. It works with
the standard ``asyncio`` event loop, ``uvloop``, and ``winloop``.

On Windows it works with ``SelectorEventLoop`` and ``winloop``.
With ``ProactorEventLoop`` it falls back to ``asyncio``'s native connection and
server implementation, because the proactor loop does not provide the
``add_reader()`` / ``add_writer()`` hooks required by ``aiofastnet``'s custom
transport implementation. For transports created through ``aiofastnet``, a
compatibility wrapper preserves the documented ``write()`` /
``writelines()`` buffer-safety behavior.

Free-Threaded Python
====================

``aiofastnet`` is compatible with free-threaded Python builds such as
``python3.14t``. The extension modules are built to work without forcing the
legacy GIL back on, so separate event loops may run in separate threads.

The repository includes several free-threading examples:

- `examples/benchmark_threaded.py <https://github.com/tarasko/aiofastnet/blob/master/examples/benchmark_threaded.py>`_ runs multiple echo client/server pairs in
  parallel to compare single-loop and multi-threaded execution.
- `examples/echo_server_threaded.py <https://github.com/tarasko/aiofastnet/blob/master/examples/echo_server_threaded.py>`_ starts one listening echo server per
  thread on the same port with ``reuse_port=True`` so the kernel can distribute
  incoming connections across worker threads.
- `examples/echo_client_threaded.py <https://github.com/tarasko/aiofastnet/blob/master/examples/echo_client_threaded.py>`_ starts one echo client per thread and
  drives them in parallel against the shared server port.

Transport objects remain thread-affine. Methods such as ``write()``,
``writelines()``, ``close()``, ``pause_reading()``, and similar transport
operations must be called from the same thread that established the connection.
Calling transport methods directly from a different thread raises
``RuntimeError``.

This matches the general ``asyncio`` model: loops and loop-owned objects are
not meant to be used concurrently from arbitrary threads. ``aiofastnet`` does
not add internal transport locking for cross-thread access.

To use ``aiofastnet`` correctly with multithreading:

- Create a separate event loop in each worker thread.
- Create connections and servers inside the loop thread that will own them.
- Keep all direct transport interaction on that same thread.
- If another thread needs to send data or close a transport, schedule that work
  onto the owning loop with ``loop.call_soon_threadsafe(...)`` instead of
  touching the transport directly.

In other words, free-threaded Python lets multiple loops make progress in
parallel, but each individual connection is still owned by exactly one loop and
one thread.

Building From Source
====================

1. Clone the repository::

    $ git clone git@github.com:tarasko/aiofastnet.git
    $ cd aiofastnet

2. Create and activate a virtual environment::

    $ python3 -m venv aiofn-dev
    $ source aiofn-dev/bin/activate

3. Install test dependencies::

    $ pip install -r requirements-test.txt

4. Build extensions in place and run tests::

    $ python setup.py build_ext --inplace
    $ pytest -s -v

5. Run the benchmark::

    $ python -m examples.benchmark

Contributing
============

Contributions are welcome.
