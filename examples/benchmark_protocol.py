import asyncio
import cython

if cython.compiled:
    from cython.cimports.aiofastnet.transport import Protocol, Transport
else:
    from aiofastnet.transport import Protocol, Transport


@cython.cclass
class ServerProtocol(Protocol, asyncio.BufferedProtocol):
    _transport: object
    _read_buf: bytearray
    _aiofn_transport: cython.bint
    _is_buffered: cython.bint

    def __init__(self, read_buf_size: cython.int = 262144,
                 is_buffered: cython.bint = True):
        self._transport = None
        self._read_buf = bytearray(read_buf_size)
        self._aiofn_transport = False
        self._is_buffered = is_buffered

    @cython.ccall
    def is_buffered_protocol(self):
        return self._is_buffered

    def connection_made(self, transport):
        self._transport = transport
        self._aiofn_transport = isinstance(transport, Transport)

    @cython.ccall
    def get_buffer(self, sizehint: cython.Py_ssize_t):
        return self._read_buf

    @cython.ccall
    def buffer_updated(self, nbytes: cython.Py_ssize_t):
        if nbytes > 0:
            data = memoryview(self._read_buf)[:nbytes]
            if self._aiofn_transport:
                cython.cast(Transport, self._transport).write_nocheck(data)
            else:
                self._transport.write(data)

    def data_received(self, data):
        if self._aiofn_transport:
            cython.cast(Transport, self._transport).write_nocheck(data)
        else:
            self._transport.write(data)


@cython.cclass
class ClientProtocol(Protocol, asyncio.BufferedProtocol):
    _payload: bytes
    _duration: cython.float
    _loop: object
    _is_buffered: cython.bint

    _transport: object
    _read_buf: bytearray
    _received_for_reply: cython.int
    _deadline: cython.float
    _warmup_left: cython.int
    _measuring: cython.bint

    requests = cython.declare(cython.int, visibility="readonly")
    closed = cython.declare(object, visibility="readonly")

    def __init__(self, payload: bytes, duration: cython.float,
                 is_buffered: cython.bint = True,
                 warmup_rounds: cython.int = 10):
        self._payload = payload
        self._duration = duration
        self._loop = asyncio.get_running_loop()
        self._is_buffered = is_buffered

        self._transport = None
        self._read_buf = bytearray(262144)
        self._received_for_reply = 0
        self._deadline = 0.0
        self._warmup_left = warmup_rounds
        self._measuring = False

        self.requests = 0
        self.closed = self._loop.create_future()

    @cython.ccall
    def is_buffered_protocol(self):
        return self._is_buffered

    def connection_made(self, transport):
        self._transport = transport

    @cython.ccall
    def write_first_data(self):
        self._write()

    @cython.ccall
    def get_buffer(self, sizehint: cython.Py_ssize_t):
        return self._read_buf

    @cython.ccall
    def buffer_updated(self, nbytes: cython.Py_ssize_t):
        self._received_for_reply += nbytes
        if self._received_for_reply < len(self._payload):
            return

        self._received_for_reply -= len(self._payload)
        self._write()

    def data_received(self, data):
        self._received_for_reply += len(data)
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

    @cython.cfunc
    def _write(self):
        if self._measuring:
            if cython.cast(cython.float, self._loop.time()) >= self._deadline:
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
            cython.cast(Transport, self._transport).write_nocheck(self._payload)
        else:
            self._transport.write(self._payload)
