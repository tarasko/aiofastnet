# aiofastnet

[![Test status](https://img.shields.io/github/actions/workflow/status/tarasko/aiofastnet/run-tests.yml?branch=master&label=tests)](https://github.com/tarasko/aiofastnet/actions/workflows/run-tests.yml?query=branch%3Amaster)
[![Latest PyPI package version](https://badge.fury.io/py/aiofastnet.svg)](https://pypi.org/project/aiofastnet)
[![Downloads count](https://img.shields.io/pypi/dm/aiofastnet.svg)](https://pypistats.org/packages/aiofastnet)

`aiofastnet` provides drop-in optimized replacements for asyncio's:

- [`loop.create_connection()`](https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.create_connection)
- [`loop.open_connection()`](https://docs.python.org/3/library/asyncio-stream.html#asyncio.open_connection)
- [`loop.create_server()`](https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.create_server)
- [`loop.start_server()`](https://docs.python.org/3/library/asyncio-stream.html#asyncio.start_server)
- [`loop.start_tls()`](https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.start_tls)
- [`loop.sendfile()`](https://docs.python.org/3/library/asyncio-eventloop.html#asyncio.loop.sendfile)

If your library or application already uses the `asyncio` streams or transport/protocol
model, `aiofastnet` lets you keep the same architecture while replacing one of
the most expensive layers underneath it.

## Benchmark

The benchmark below compares echo round-trips over loopback for TCP and SSL.
The exact gains depend on workload, message sizes, CPU, OpenSSL version, and how
much of your total runtime is spent in transport/SSL plumbing.

[![Benchmark](https://raw.githubusercontent.com/tarasko/aiofastnet/master/examples/benchmark.png)](https://github.com/tarasko/aiofastnet/blob/master/examples/benchmark.png)

Source: [examples/benchmark.py](https://github.com/tarasko/aiofastnet/blob/master/examples/benchmark.py)

In these benchmarks, `aiofastnet` is up to 2.2x faster than standard
`asyncio`.

`aiofastnet` is fully compatible with free-threaded Python builds and scales
as expected when multiple event loops run in parallel across multiple threads.

[![Threaded benchmark](https://raw.githubusercontent.com/tarasko/aiofastnet/master/examples/benchmark_threaded.png)](https://github.com/tarasko/aiofastnet/blob/master/examples/benchmark_threaded.png)

Source: [examples/benchmark_threaded.py](https://github.com/tarasko/aiofastnet/blob/master/examples/benchmark_threaded.py)

## Why Use aiofastnet

- **Faster hot path**. Transport and SSL internals are reimplemented in Cython/C
  to reduce overhead on long-lived connections.
- **Drop-in API**. Keep using the standard `asyncio` streams or transport/protocol model
  and familiar loop-level networking operations.
- **Works with the event loop you already use**. `aiofastnet` works with
  stock `asyncio` loops, `uvloop`, and `winloop`.
- **Particularly strong for SSL-heavy workloads**. `aiofastnet` uses OpenSSL
  more directly and avoids extra copies in the data path.
- **Kernel TLS support on Linux**. Native `sendfile` for TLS connections through `SSL_sendfile`. 
- **Safer transport write() / writelines() behavior**. If the socket cannot accept
  everything immediately, only `bytes` and `memoryview` objects backed by
  `bytes` are retained without copying. Other objects, including
  `bytearray` and non-`bytes` exporters, are copied before being queued.
  Unlike standard `asyncio` transports, this avoids sending corrupted data if
  application code modifies the underlying buffer after `write()` /
  `writelines()` returns.
- **Better SSL backpressure semantics**. Buffer sizes and write limits reflect
  what is actually queued across the stack.
- **Works for library authors**. WebSocket, HTTP, RPC, proxy, database, broker,
  and custom protocol libraries can expose the same API while giving users a
  faster transport layer.

## Quickstart

Install from PyPI:

```console
$ pip install aiofastnet
```

`aiofastnet` requires Python 3.9 or greater.

The API mirrors stdlib `asyncio`. Pass the running loop and use your existing
protocol factory:

```python
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
```

For servers, replace `loop.create_server(...)` with
`aiofastnet.create_server(loop, ...)` in the same way.

`aiofastnet` also exposes `start_tls` and `sendfile`:

```python
transport = await aiofastnet.start_tls(
    loop,
    transport,
    protocol,
    ssl_context,
    server_side=False,
    server_hostname="example.com",
)

await aiofastnet.sendfile(transport, fileobj)
```

## When aiofastnet Is a Good Fit

`aiofastnet` is most attractive when you already rely on `asyncio`'s
transport/protocol APIs and one or more of these are true:

- You have long-lived TCP or TLS connections.
- You run protocol-heavy services where transport overhead is visible in CPU
  profiles.
- You maintain a library and want better performance without changing your
  public API.
- You care about consistent `write()` / `writelines()` buffer behavior.
- You want SSL flow control to reflect the whole buffered stack, not only part
  of it.

## When Not To Use aiofastnet

`aiofastnet` is not the right default for every networking project:

- If your workload is dominated by very short-lived connections, you should
  expect little or no gain. `aiofastnet` focuses on optimizing the data path
  after connection establishment.

## Platform Compatibility

`aiofastnet` is built and tested on Linux, macOS, and Windows. It works with
the standard `asyncio` event loop, `uvloop`, and `winloop`.

On Windows it works with `SelectorEventLoop` and `winloop`.
With `ProactorEventLoop` it falls back to `asyncio`'s native connection and
server implementation, because the proactor loop does not provide the
`add_reader()` / `add_writer()` hooks required by `aiofastnet`'s custom
transport implementation. For transports created through `aiofastnet`, a
compatibility wrapper preserves the documented `write()` /
`writelines()` buffer-safety behavior.

## Kernel TLS Support on Linux

On Linux, `aiofastnet` can use OpenSSL's Kernel TLS support for TLS
connections. Kernel TLS is beneficial if any of the following is true:

* Static files need to be sent over TLS connection and `sendfile()` can be used.
In that case the kernel can read data directly instead of forcing the application to 
copy file contents through userspace.
* Some high-end NICs support hardware TLS offload. This leads to huge CPU savings.

If you only sent regular data (not static files) and do not have high-end NIC with TLS offload, 
enabling Kernel TLS will only slightly decrease performance. CPU cost-wise it doesn't matter where encryption/decryption
happens, but the kernel `tls` module has to do extra bookkeeping. Also, aiofastnet can batch data and reduce amount of 
syscalls when Kernel TLS is not used. 

Kernel TLS requires support from all of these layers:

- A Linux kernel with KTLS support enabled.
- The `tls` kernel module loaded.
- OpenSSL built with KTLS support on a machine with suitable kernel headers.
- An `ssl.SSLContext` with `ssl.OP_ENABLE_KTLS` enabled.
- A TLS version and cipher suite supported by the kernel TLS implementation.

To load the kernel module:

```console
$ sudo modprobe tls
```

To enable KTLS on Python SSL contexts (available in Python 3.12+):

```python
import ssl

server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
server_context.options |= ssl.OP_ENABLE_KTLS

client_context = ssl.create_default_context()
client_context.options |= ssl.OP_ENABLE_KTLS
```

The OpenSSL library used by Python must itself have KTLS support. Python
distributions often ship their own `libssl` and `libcrypto`, and those
libraries may have been built on older systems where KTLS was not available.
That can be true even when the host running your program has a newer kernel.

Check which OpenSSL Python is using:

```console
$ python -c "import ssl; print(ssl.OPENSSL_VERSION); print(ssl._ssl.__file__)"
```

If your Python distribution bundles an older or non-KTLS OpenSSL, one practical
option is to locate the bundled `libssl` and `libcrypto` files and replace them
with symbolic links to a newer system OpenSSL build that supports KTLS. This is
often useful with Conda Python, which commonly ships its own OpenSSL libraries
inside the environment.

KTLS support by kernel version is outline [here.](https://delthas.fr/blog/2023/kernel-tls/)

## Free-Threaded Python

`aiofastnet` is compatible with free-threaded Python builds such as
`python3.14t`. The extension modules are built to work without forcing the
legacy GIL back on, so separate event loops may run in separate threads.

The repository includes several free-threading examples:

- [examples/benchmark_threaded.py](https://github.com/tarasko/aiofastnet/blob/master/examples/benchmark_threaded.py) runs multiple echo client/server pairs in
  parallel to compare single-loop and multi-threaded execution.
- [examples/echo_server_threaded.py](https://github.com/tarasko/aiofastnet/blob/master/examples/echo_server_threaded.py) starts one listening echo server per
  thread on the same port with `reuse_port=True` so the kernel can distribute
  incoming connections across worker threads.
- [examples/echo_client_threaded.py](https://github.com/tarasko/aiofastnet/blob/master/examples/echo_client_threaded.py) starts one echo client per thread and
  drives them in parallel against the shared server port.

Transport objects remain thread-affine. Methods such as `write()`,
`writelines()`, `close()`, `pause_reading()`, and similar transport
operations must be called from the same thread that established the connection.
Calling transport methods directly from a different thread raises
`RuntimeError`.

This matches the general `asyncio` model: loops and loop-owned objects are
not meant to be used concurrently from arbitrary threads. `aiofastnet` does
not add internal transport locking for cross-thread access.

To use `aiofastnet` correctly with multithreading:

- Create a separate event loop in each worker thread.
- Create connections and servers inside the loop thread that will own them.
- Keep all direct transport interaction on that same thread.
- If another thread needs to send data or close a transport, schedule that work
  onto the owning loop with `loop.call_soon_threadsafe(...)` instead of
  touching the transport directly.

In other words, free-threaded Python lets multiple loops make progress in
parallel, but each individual connection is still owned by exactly one loop and
one thread.

## Building From Source

1. Clone the repository:

   ```console
   $ git clone git@github.com:tarasko/aiofastnet.git
   $ cd aiofastnet
   ```

2. Create and activate a virtual environment:

   ```console
   $ python3 -m venv aiofn-dev
   $ source aiofn-dev/bin/activate
   ```

3. Install test dependencies:

   ```console
   $ pip install -r requirements-test.txt
   ```

4. Build extensions in place and run tests:

   ```console
   $ python setup.py build_ext --inplace
   $ pytest -s -v
   ```

5. Run the benchmark:

   ```console
   $ python -m examples.benchmark
   ```

6. Run tests:

   ```console
   $ pytest -s -v
   $ pytest -s -v -k test_echo[uvloop-tcp-buffered-6291456] --asyncio-debug --log-cli-level DEBUG
   ```

## Contributing

Contributions are welcome.
