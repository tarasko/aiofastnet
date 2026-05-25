# kTLS / BIO Investigation Notes

## Goal

Find a TLS transport design that keeps the batching advantage of `SSLProtocol`
with `static_mem_bio`, while also allowing:

- direct socket access
- kTLS for normal reads/writes
- `SSL_sendfile()`

The most promising direction is a custom fd-backed BIO with batching plus kTLS
support, instead of the current direct-socket `TlsTransport`.


## Current Implementations

### `SSLProtocol`

- Uses custom `static_mem_bio`
- OpenSSL encrypts/decrypts in userspace
- `SocketTransport` sends/receives encrypted bytes
- Main advantage: batching. OpenSSL can emit multiple TLS records into the
  outgoing BIO, and the transport can flush a larger chunk at once.

### `TlsTransport`

- Uses direct socket-based `SSL*` (`SSL_set_fd()`)
- Non-blocking socket
- kTLS can be enabled on the real connection
- `SSL_sendfile` symbol is available
- Main problem: OpenSSL appears to perform many 16 KB read/write syscalls,
  which hurts throughput


## Measured Results

Benchmark lives in `examples/benchmark`.

Observed relative performance:

1. `SSLProtocol` with `static_mem_bio` is about `1.5x` faster than
   `TlsTransport` without kTLS.
2. `TlsTransport` without kTLS is about `1.5x` faster than `TlsTransport`
   with kTLS enabled.

So for the current workload:

- mem-BIO batching wins over direct socket TLS
- enabling kTLS makes the direct-socket path slower, not faster


## What Was Checked

- `tls` kernel module is loaded
- `SSL_OP_ENABLE_KTLS` is set
- OpenSSL appears to be built with kTLS support
- `BIO_get_ktls_send(wbio)` becomes `1` for some working cipher setups
- `perf` shows `ktls_read_n` is reached internally when kTLS is enabled
- socket send buffer is large (`SNDBUF = 256 KB`)
- writes do not normally hit `EAGAIN`


## Important Cipher Finding

kTLS did **not** activate for:

- `ECDHE-RSA-AES256-GCM-SHA384`

kTLS **did** activate for:

- `ECDHE-RSA-AES128-GCM-SHA256`

So on this setup, `AES128-GCM` is the known-good kTLS cipher and
`AES256-GCM` appears unsupported or unsupported by this exact OpenSSL/kernel
combination.


## Environment-Specific Findings

Observed environment:

- Ubuntu 24.04
- Linux kernel `6.8.0`

Observed behavior on this machine:

- TLS 1.3 did not appear to activate kTLS in testing
- TLS 1.2 also did not activate kTLS for every cipher
- the currently known-good combination is:
  - `TLSv1.2`
  - `ECDHE-RSA-AES128-GCM-SHA256`
- the following combination did **not** activate kTLS:
  - `TLSv1.2`
  - `ECDHE-RSA-AES256-GCM-SHA384`

Interpretation:

- generic online summaries of Linux/NGINX/OpenSSL kTLS support are broader
  than what is actually usable on this exact Ubuntu/OpenSSL/kernel build
- the effective compatibility matrix must be treated as environment-specific


## Observations From `perf` / `strace`

- With kTLS enabled, `recvmsg` appears expensive
- `perf` does not show obvious bottlenecks in aiofastnet code
- `strace` shows many `write` syscalls around 16 KB
- This happens even when `SSL_MODE_ENABLE_PARTIAL_WRITE` is not set
- So OpenSSL socket-based TLS still appears to operate at record granularity
  in a way that is unfavorable for this benchmark

Current hypothesis:

- the workload is dominated by syscall / I/O path shape
- not by crypto cost
- mem-BIO batching beats direct-socket TLS because it reduces flush overhead
- kTLS can lose if kernel-path overhead is larger than the saved userspace
  crypto cost


## What Was Learned About OpenSSL / kTLS

### `SSL_sendfile`

- `SSL_sendfile()` appears tied to active kTLS on the live connection
- It is not just ordinary BIO output
- OpenSSL docs and `openssl s_server` documentation imply it is used only when
  kTLS is enabled

Implication:

- static mem BIO + ordinary OpenSSL userspace TLS will not directly get
  `SSL_sendfile`

### BIO control path

OpenSSL local headers show private/internal BIO control codes related to kTLS:

- `BIO_CTRL_SET_KTLS_SEND`
- `BIO_CTRL_SET_KTLS_SEND_CTRL_MSG`
- `BIO_CTRL_CLEAR_KTLS_CTRL_MSG`
- `BIO_CTRL_GET_KTLS_SEND`
- `BIO_CTRL_GET_KTLS_RECV`
- `BIO_CTRL_SET_KTLS_TX_ZEROCOPY_SENDFILE`

This strongly suggests:

- OpenSSL distinguishes app-data vs TLS control-message sending through
  `BIO_ctrl()`, not through extra flags on `BIO_write()`
- a custom BIO may be able to participate in kTLS if it implements the BIO
  control contract OpenSSL expects
- OpenSSL likely does **not** require the exact built-in socket BIO type,
  but it probably does rely on those internal BIO controls

Important caution:

- these kTLS BIO controls are internal/private OpenSSL interface
- they are not a stable public contract


## Design Conclusion So Far

The best next experiment is likely:

- a custom fd-backed BIO
- with explicit batching/coalescing behavior
- with a real socket fd underneath
- with support for the OpenSSL kTLS BIO control operations
- and optionally `SSL_sendfile()`

Why this is promising:

- preserves the batching advantage seen with `static_mem_bio`
- still exposes a real socket for kTLS
- may allow OpenSSL to use kTLS / `SSL_sendfile`
- avoids the current direct-socket `TlsTransport` problem of many small
  syscalls

Why this is preferable to teaching `static_mem_bio` kTLS:

- kTLS is real kernel state attached to a real TCP socket
- a pure memory BIO cannot truthfully host that state
- the socket needs to remain in the path somewhere


## Ideas Not Pursued Yet

- custom buffering BIO layered above a real socket BIO
- replacing `TlsTransport` with a custom socket BIO implementation entirely
- TX-only hybrid where normal app writes use batched BIO path and file sends use
  kTLS directly

TX-only hybrid was considered risky because:

- keeping OpenSSL TX state and kernel TX state aligned would be difficult
- sequence numbers / alerts / shutdown semantics become dangerous if two
  separate transmit mechanisms are active


## Practical Resume Point

If resuming this work later, start by re-checking:

1. current `ssl_object.pyx`
2. current `ssl_protocol.pyx`
3. current `tls_transport.pyx`
4. OpenSSL compat bindings for:
   - `SSL_sendfile`
   - `BIO_get_ktls_send`
   - `BIO_get_ktls_recv`
   - `SSL_get_wbio`
   - `SSL_get_rbio`
   - `BIO_socket_nbio`

Then investigate a new custom BIO design rather than further tuning the
current direct-socket `TlsTransport`.
