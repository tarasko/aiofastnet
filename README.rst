aiofastnet
==========

``aiofastnet`` provides highly optimized ``asyncio``
`loop.create_connection <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.create_connection>`_
and
`loop.create_server <https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.create_server>`_
implementations.
It is a drop-in replacement for the standard ``asyncio`` functions.

Internally, it reimplements parts of CPython's transport/SSL stack with Cython
and C to reduce overhead on hot I/O paths.

Basic Usage
-----------

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
----------

.. image:: https://raw.githubusercontent.com/tarasko/aiofastnet/master/examples/benchmark.png
    :target: https://github.com/tarasko/websocket-benchmark/blob/master
    :align: center

Why to use aiofastnet?
----------------------

If you maintain a high-level networking library, ``aiofastnet`` gives you a
way to make the hot path faster without redesigning your library around a new
runtime or custom socket layer.

- Drop-in replacement for ``loop.create_connection()`` and
  ``loop.create_server()``. You keep the standard ``asyncio``
  transport/protocol model and your existing integration points.
- Lower transport and TLS overhead. ``aiofastnet`` reimplements the expensive
  parts of CPython's transport and SSL stack in Cython/C, so more CPU time is
  spent in your protocol logic instead of framework plumbing.
- Useful for library authors, not only applications. If you build WebSocket,
  HTTP, RPC, database, proxy, message-broker, or custom binary protocol
  libraries, your users can get better throughput and lower CPU cost without
  changing your public API.
- Clearer and safer ``write()`` / ``writelines()`` behavior. ``aiofastnet``
  attempts to push user data to the socket before returning. If the socket can
  not accept everything immediately, immutable buffers can be retained without
  copying, while mutable buffers such as ``bytearray`` and mutable
  ``memoryview`` objects are copied before being queued. This makes it safe to
  reuse application write buffers after ``write()`` or ``writelines()``
  returns.
- No ecosystem lock-in. You do not need to migrate to another concurrency
  framework or ask users to rewrite their code around non-stdlib primitives.
- Especially attractive when TLS matters. Python libraries often pay a large
  premium for SSL-heavy workloads; ``aiofastnet`` is designed to reduce that
  cost.

In short: if your library already fits ``asyncio``'s transport/protocol model
and performance matters, ``aiofastnet`` lets you keep the same architecture
while replacing one of the most expensive layers underneath it.


Status
------

This project is focused on performance-sensitive ``asyncio`` networking and is
implemented specifically for CPython.
