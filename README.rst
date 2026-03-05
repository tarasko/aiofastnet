aiofastnet
==========

``aiofastnet`` provides highly optimized ``asyncio`` loop
``create_connection`` and ``create_server`` implementations.
It is a drop-in replacement for the standard ``asyncio`` functions.

Internally, it reimplements parts of CPython's transport/SSL stack with Cython
and C to reduce overhead on hot I/O paths.

Basic Usage
-----------

Use it similarly to stdlib ``asyncio`` APIs by passing the running loop:

.. code-block:: python

   import asyncio
   from aiofastnet import create_connection, create_server

   class Echo(asyncio.Protocol):
       def connection_made(self, transport):
           self.transport = transport

       def data_received(self, data):
           self.transport.write(data)

   async def main():
       loop = asyncio.get_running_loop()

       server = await create_server(loop, Echo, host="127.0.0.1", port=9000)
       transport, protocol = await create_connection(
           loop, Echo, host="127.0.0.1", port=9000
       )

       transport.close()
       server.close()
       await server.wait_closed()

   asyncio.run(main())

Status
------

This project is focused on performance-sensitive ``asyncio`` networking and is
implemented specifically for CPython.
