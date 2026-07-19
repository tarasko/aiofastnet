aiofastnet Release History
=================================

.. contents::
   :depth: 1
   :local:

0.20.0
------------------

* Performance improvements from @river-walras in SSL fallback engine.
* Fix potential hangups in SSLEngineFallback for some specific ssl MemoryBIO sizes.
* Simplify logic by always using SSLTransport_Transport when ssl fallback engine is used.

0.19.0
------------------

* aiofastnet now works with uv standalone python; ssl layer is slightly slower than when regular python is used
but it is still faster than ssl layer in asyncio and uvloop.

0.18.0
------------------

* Fixed potential error in create_connection on python < 3.11 due to missing ExceptionGroup
* Fixed NotImplementError from sendfile when used on windows with proactor loop and tcp transport
* Added unix sockets primitives: create_unix_connection, create_unix_server, open_unix_connection, start_unix_server
* Refactored OpenSSL libs lookup, made it possible to work with memray

0.17.0
------------------

* Various minor optimizations for the hot path, refactor exception handling

0.16.0
------------------

* Optimize syscall usage, tune SocketTransport performance for simple protocols

0.15.0
------------------

* Tune simple buffer read path in SocketTransport for better performance

0.14.0
------------------

* Optimized simple buffer read path in SocketTransport, do not copy memory
* Harden logic against rare exceptions

0.13.0
------------------

* Added some missing attributes and methods to SSLObject
* Fixed sendfile(count=None) not sending file at all for TCP case, added test
* Fixed sendfile infinite loop in case of oversized count value, added test
* Optimized simple buffer read path in SocketTransport
* Fixed Protocol.eof_received() returning True closed transport anyway on Windows

0.12.0
------------------

* Added undocumented, but used by 3rdparties Transport._sendfile_compatible attribute

0.11.0
------------------

* Added type annotations for the public API

0.10.0
------------------

* Optimized bytes object creation for data_received in simple protocols
* Fall back to memory bio early if kTLS is requested, but prerequisites are not satisfied

0.9.0
------------------

* Fail with a clean ImportError when importing aiofastnet by python with statically linked openssl
* Improve compatibility with older OpenSSL versions
* Export OPENSSL_DYN_LIBS for testing and verification

0.8.0
------------------

* Fixed Protocol.get_buffer not requiring PyBUF_WRITABLE from user buffer
* Cleaned up nogil usage, harden logic against multithreading misuse by user code.
* Fixed potential double-free error in SSLObject.__init__
* Fixed potential hangups on invalid ssl_handshake_timeout and ssl_shutdown_timeout values

0.7.0
------------------

* Add loop monkey-patching via install_policy, loop_factory, patch_loop
* Allow mocking transport.write and writelines methods

0.6.0
------------------

* Reimplement SSL layer to work directly with a socket instead of through transport by default.
* Add Kernel TLS support.
* Add unlikely for debug branches and other rare branches

0.5.0
------------------

* Add missing write_nocheck and writelines_nocheck to WrappedTransport

0.4.0
------------------

* Build for windows arm64
* Add write_nocheck, writelines_nocheck, write_c to the Transport interface

0.3.0
------------------

* Add open_connection and start_server API
* Add ssl_incoming_bio_size and ssl_outgoing_bio_size to API

0.2.0
------------------

* Officially support free threaded python. All extensions modules are free threading compatible.
* Add free threaded benchmark, free threaded echo server and client examples
* Update README

0.1.0
------------------

**First release**
* Contains optimized versions of create_connectio, create_server, start_tls and sendfile
