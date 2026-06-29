from .ssl_engine cimport SSLEngine, SSLError


cdef class SSLEngineFallback(SSLEngine):
    cdef:
        object ssl_object
        object incoming
        object outgoing
        bytearray incoming_buf
        bytes outgoing_data
        readonly str server_hostname
        readonly bint server_side
        bint _is_debug

    cdef inline SSLError _translate_ssl_error(self, exc) except SSLError.PYTHON_EXC
