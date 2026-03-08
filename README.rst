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



Status
------

This project is focused on performance-sensitive ``asyncio`` networking and is
implemented specifically for CPython.
