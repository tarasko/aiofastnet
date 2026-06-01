from .socket cimport socket

cdef class TransportSocket:
    cdef socket _sock

    cpdef object fileno(self)
    cpdef object dup(self) # -> socket.socket
    cpdef object get_inheritable(self)
    cpdef object shutdown(self, object how)
    cpdef object getpeername(self)
    cpdef object getsockname(self)
    cpdef object getsockbyname(self)
    cpdef object settimeout(self, float value)
    cpdef float gettimeout(self)
    cpdef object setblocking(self, object flag)
