aiofastnet
==========

``aiofastnet`` provides highly optimized ``asyncio``
`loop.create_connection <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.create_connection>`_
and
`loop.create_server <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.create_server>`_
implementations.
It is a drop-in replacement for the standard ``asyncio`` functions for
performance-sensitive networking code.

Internally, it reimplements parts of CPython's transport/SSL stack with Cython
and C to reduce overhead on hot I/O paths, especially for protocol libraries
that spend significant CPU time in transport and SSL plumbing.

Installation
============

``aiofastnet`` requires Python 3.9 or greater and is available on PyPI::

    $ pip install aiofastnet

Basic Usage
============

Use it similarly to stdlib ``asyncio`` APIs by passing the running loop:

.. code-block:: python

   import asyncio
   import aiofastnet

   loop = asyncio.get_running_loop()
   # Instead of
   # transport, protocol = await loop.create_connection(...)
   transport, protocol = await aiofastnet.create_connection(loop, ...)

   # Instead of
   # server = await loop.create_server(...)
   server = await aiofastnet.create_server(loop, ...)

Benchmark
============

The benchmark below compares echo round-trips over loopback for TCP and SSL.
The exact gains depend on workload, message sizes, and how much time your
application spends in transport/SSL overhead.
Benchmark source:
`examples/benchmark.py <https://github.com/tarasko/aiofastnet/blob/master/examples/benchmark.py>`_

.. image:: https://raw.githubusercontent.com/tarasko/aiofastnet/master/examples/benchmark.png
    :target: https://github.com/tarasko/websocket-benchmark/blob/master
    :align: center

Why to use aiofastnet?
======================

- **Lower transport and SSL overhead**. ``aiofastnet`` reimplements the expensive
  parts of CPython's transport and SSL stack in Cython/C, so more CPU time is
  spent in your protocol logic instead of framework plumbing. Python libraries
  often pay a large premium for SSL-heavy workloads; ``aiofastnet`` uses OpenSSL more directly
  and avoids several extra buffer copies present in standard ``asyncio`` and
  ``uvloop`` SSL paths to reduce that cost.
- **Clearer and safer ``write()`` / ``writelines()`` behavior**. ``aiofastnet``
  tries to push data to the socket before returning. If the socket can not
  accept everything immediately, only ``bytes`` and ``memoryview`` objects
  backed by ``bytes`` are retained without copying; everything else, including
  ``bytearray`` and ``memoryview`` objects backed by other exporters, is
  copied before being queued. This makes it safe to reuse application write
  buffers after ``write()`` or ``writelines()`` returns.
- **Better backpressure semantics for SSL transports**. ``get_write_buffer_size()``
  reports total queued output across the whole stack, and
  ``set_write_buffer_limits()`` applies to the whole stack as well, so flow
  control reflects what is actually buffered for transmission.
- **Useful for library authors, not only applications**. If you build WebSocket,
  HTTP, RPC, database, proxy, message-broker, or custom binary protocol
  libraries, your users can get better throughput and lower CPU cost without
  changing your public API.
- **Drop-in replacement** for ``loop.create_connection()`` and
  ``loop.create_server()``. You keep the standard ``asyncio``
  transport/protocol model and your existing integration points.
- **No ecosystem lock-in**. You do not need to migrate to another concurrency
  framework or ask users to rewrite their code around non-stdlib primitives.

In short: if your library already fits ``asyncio``'s transport/protocol model
and performance matters, ``aiofastnet`` lets you keep the same architecture
while replacing one of the most expensive layers underneath it.


When Not To Use aiofastnet
==========================

``aiofastnet`` is not always the right choice:

- If your workload is dominated by very short-lived connections.
  ``aiofastnet`` focuses on optimizing the data path after a connection
  is established; it does not primarily optimize connection setup cost.
  In workloads where connections are created and torn down quickly, you
  should expect little or no performance gain compared to standard
  ``asyncio``.
- If targeting Windows ``ProactorEventLoop`` is itself a requirement.
  On ``ProactorEventLoop``, ``aiofastnet`` falls back to ``asyncio``'s
  native connection and server implementation underneath, so you do not
  get ``aiofastnet``'s custom transport implementation on that loop.


Platform Compatibility
======================

``aiofastnet`` is built and tested on Linux, macOS, and Windows.

On Windows it works with ``SelectorEventLoop`` and ``winloop``.
With ``ProactorEventLoop`` it falls back to ``asyncio``'s native
connection and server implementation underneath, because the proactor
loop does not provide ``add_reader()`` / ``add_writer()`` hooks
required by ``aiofastnet``'s transport implementation. For transports
created through ``aiofastnet``, a compatibility wrapper preserves the
documented ``write()`` / ``writelines()`` buffer-safety behavior.


Contributing / Building From Source
===================================

Contributions are welcome!

1. Fork and clone the repository::

    $ git clone git@github.com:tarasko/aiofastnet.git
    $ cd aiofastnet

2. Create a virtual environment and activate it::

    $ python3 -m venv aiofn-dev
    $ source aiofn-dev/bin/activate


3. Install development dependencies::

    $ pip install -r requirements-test.txt

4. Build in place and run tests::

    $ python setup.py build_ext --inplace
    $ pytest -s -v

    # Run specific test with debug logs enabled
    $ pytest -s -v -k test_echo[asyncio-ssl-buffered-32-64] --log-cli-level DEBUG

5. Run the benchmark::

    $ python -m examples.benchmark
