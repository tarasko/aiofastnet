aiofastnet Release History
=================================

.. contents::
   :depth: 1
   :local:

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
