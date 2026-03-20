aiofastnet
==========

.. image:: https://img.shields.io/github/actions/workflow/status/tarasko/aiofastnet/run-tests.yml?branch=master
    :target: https://github.com/tarasko/aiofastnet/actions/workflows/run-tests.yml?query=branch%3Amaster
    :alt: Test status

.. image:: https://badge.fury.io/py/aiofastnet.svg
    :target: https://pypi.org/project/aiofastnet
    :alt: Latest PyPI package version

``aiofastnet`` provides drop-in optimized replacements for:

- `loop.create_connection() <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.create_connection>`_
- `loop.create_server() <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.create_server>`_
- `loop.start_tls() <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.start_tls>`_
- `loop.sendfile() <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.sendfile>`_

If your library or application already uses the ``asyncio`` transport/protocol
model, ``aiofastnet`` lets you keep the same architecture while replacing one of
the most expensive layers underneath it.

Benchmark
=========

The benchmark below compares echo round-trips over loopback for TCP and SSL.
The exact gains depend on workload, message sizes, CPU, OpenSSL version, and how
much of your total runtime is spent in transport/SSL plumbing.

Benchmark source:
`examples/benchmark.py <https://github.com/tarasko/aiofastnet/blob/master/examples/benchmark.py>`_

.. image:: https://raw.githubusercontent.com/tarasko/aiofastnet/master/examples/benchmark.png
    :target: https://github.com/tarasko/websocket-benchmark/blob/master
    :align: center

In these benchmarks, ``aiofastnet`` is up to 2.2x faster than standard
``asyncio``.

Why Use aiofastnet
===================

- **Faster hot path**. Transport and SSL internals are reimplemented in Cython/C
  to reduce overhead on long-lived connections.
- **Drop-in API**. Keep using the standard ``asyncio`` transport/protocol model
  and familiar loop-level networking operations.
- **Works with the event loop you already use**. ``aiofastnet`` works with
  stock ``asyncio`` loops, ``uvloop``, and ``winloop``.
- **Particularly strong for SSL-heavy workloads**. ``aiofastnet`` uses OpenSSL
  more directly and avoids extra copies in the data path.
- **Write buffer safety**. If the socket cannot accept everything immediately,
  only ``bytes`` and ``memoryview`` objects backed by ``bytes`` are retained
  without copying. Other objects, including ``bytearray`` and non-``bytes``
  exporters, are copied before being queued.
  This is different from asyncio behavior when Transport can send junk after
  ``write()`` / ``writelines()`` returns and user has modified the underlying
  buffer content.
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
