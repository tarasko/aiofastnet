## Description

Optimized versions of Python 3 asyncio create_connection, create_server loop methods

The project contains very efficient re-implementation of SelectSocketTransport and SSLProtocol 
using Cython and sometimes a pure C code.

create_connection, create_server are defined in aiofastnet/api.py

sslproto.pyx - hack python SSLContext to get raw SSL_CTX*, it works with openssl api directly after that.

sslproto_stdlib.pyx - is just for reference, I will delete it soon, but now it's good for comparison between
stdlib ssl and whatever is in sslproto.pyx.

