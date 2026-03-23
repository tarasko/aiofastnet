# NOTE: this CAPI Module uses _socket.socket not socket.socket...
from .socket cimport (
    socket,
    import_socket,
    PyLong_FromSocket_t
)
from socket import error

# Modified from asyncio.trsock, minus the deprecated stuff.

import_socket()

cdef class TransportSocket:
    
    def __init__(self, socket sock) -> None:
        self._sock = sock

    @property
    def family(self):
        return self._sock.family

    @property
    def type(self):
        return self._sock.type

    @property
    def proto(self):
        return self._sock.proto

    cpdef object fileno(self):
        return PyLong_FromSocket_t(self._sock.fileno)
    
    cpdef object dup(self): # -> socket.socket
        return self._sock.dup()

    cpdef object get_inheritable(self):
        return self._sock.get_inheritable()

    cpdef object shutdown(self, object how): # -> None
        # CPython Comment: asyncio doesn't currently provide a high-level transport API
        # to shutdown the connection.
        self._sock.shutdown(how)

    def __repr__(self):
        cdef object s
        s = (
            f"<TransportSocket fd={self.fileno()}, "
            f"family={self.family!s}, type={self.type!s}, "
            f"proto={self.proto}"
        )

        if self._sock.fileno != -1:
            try:
                laddr = self.getsockname()
                if laddr:
                    s = f"{s}, laddr={laddr}"
            except error:
                pass
            try:
                raddr = self.getpeername()
                if raddr:
                    s = f"{s}, raddr={raddr}"
            except error:
                pass

        return f"{s}>"

    def __getstate__(self):
        raise TypeError("Cannot serialize TransportSocket object")

    # Unoptimizable
    def getsockopt(self, *args, **kwargs):
        return self._sock.getsockopt(*args, **kwargs)

    def setsockopt(self, *args, **kwargs):
        self._sock.setsockopt(*args, **kwargs)

    cpdef object getpeername(self):
        return self._sock.getpeername(self._sock)

    cpdef object getsockname(self):
        return self._sock.getsockname()

    cpdef object getsockbyname(self):
        return self._sock.getsockbyname()

    cpdef object settimeout(self, float value):
        if value == 0:
            return
        raise ValueError(
            'settimeout(): only 0 timeout is allowed on transport sockets')

    cpdef float gettimeout(self):
        return 0.0
    
    cpdef object setblocking(self, object flag):
        if not flag:
            return
        raise ValueError(
            'setblocking(): transport sockets cannot be blocking')




