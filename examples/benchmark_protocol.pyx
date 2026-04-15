import asyncio
from aiofastnet.transport cimport Protocol, Transport


cdef class ServerProtocol(Protocol, asyncio.BufferedProtocol):
    cdef:
        object _transport
        bytearray _read_buf
        bint _aiofn_transport

    def __init__(self, read_buf_size: int = 262144):
        self._transport = None
        self._read_buf = bytearray(read_buf_size)
        self._aiofn_transport = False

    def connection_made(self, transport):
        self._transport = transport
        self._aiofn_transport = isinstance(transport, Transport)

    cpdef get_buffer(self, Py_ssize_t sizehint):
        return self._read_buf

    cpdef buffer_updated(self, Py_ssize_t nbytes):
        if nbytes > 0:
            # bytearray slicing creates a copy, so write is safe.
            if self._aiofn_transport:
                (<Transport>self._transport).write_unsafe(memoryview(self._read_buf)[:nbytes])
            else:
                self._transport.write_unsafe(memoryview(self._read_buf)[:nbytes])


cdef class ClientProtocol(Protocol, asyncio.BufferedProtocol):
    cdef:
        bytes _payload
        float _duration
        object _loop
        object _transport
        bytearray _read_buf
        int _received_for_reply
        float _deadline
        int _warmup_left
        bint _measuring

        readonly int requests
        readonly object closed

    def __init__(self, payload: bytes, duration: float, warmup_rounds: int=10):
        self._payload = payload
        self._duration = duration
        self._loop = asyncio.get_running_loop()

        self._transport = None
        self._read_buf = bytearray(262144)
        self._received_for_reply = 0
        self._deadline = 0.0
        self._warmup_left = warmup_rounds
        self._measuring = False

        self.requests = 0
        self.closed = self._loop.create_future()

    def connection_made(self, transport):
        self._transport = transport

    cpdef write_first_data(self):
        self._write()

    cpdef get_buffer(self, Py_ssize_t sizehint):
        return self._read_buf

    cpdef buffer_updated(self, Py_ssize_t nbytes):
        self._received_for_reply += nbytes
        if self._received_for_reply < len(self._payload):
            return

        self._received_for_reply -= len(self._payload)
        self._write()

    def connection_lost(self, exc):
        if not self.closed.done():
            if exc is None:
                self.closed.set_result(None)
            else:
                self.closed.set_exception(exc)

    cdef _write(self):
        if self._measuring:
            if <float>self._loop.time() >= self._deadline:
                self._transport.close()
                return
            self.requests += 1
        else:
            self._warmup_left -= 1
            if self._warmup_left <= 0:
                self._measuring = True
                self.requests = 0
                self._deadline = self._loop.time() + self._duration

        if isinstance(self._transport, Transport):
            (<Transport>self._transport).write_unsafe(self._payload)
        else:
            self._transport.write_unsafe(self._payload)