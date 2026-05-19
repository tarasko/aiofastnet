from .system cimport *

cpdef enum SSLProtocolState:
    UNWRAPPED = 0
    DO_HANDSHAKE = 1
    WRAPPED = 2
    FLUSHING = 3
    SHUTDOWN = 4


cdef enum AppProtocolState:
    # This tracks the state of app protocol (https://git.io/fj59P):
    #
    #     INIT -cm-> CON_MADE [-dr*->] [-er-> EOF?] -cl-> CON_LOST
    #
    # * cm: connection_made()
    # * dr: data_received()
    # * er: eof_received()
    # * cl: connection_lost()

    STATE_INIT = 0
    STATE_CON_MADE = 1
    STATE_EOF = 2
    STATE_CON_LOST = 3


cdef aiofn_set_result_unless_cancelled(fut, result)
cdef aiofn_set_nodelay(sock)
cpdef aiofn_validate_buffer(object buffer)
cdef aiofn_unpack_buffer(object buffer, char** ptr_out, Py_ssize_t* size_out)
cpdef object aiofn_maybe_copy_buffer(object buffer)
cpdef object aiofn_validate_and_maybe_copy_buffer(object buffer)
cdef object aiofn_maybe_copy_buffer_tail(object buffer, char* ptr, Py_ssize_t sz)
cdef Py_ssize_t aiofn_recv(int sockfd, void* buf, Py_ssize_t len) except? -1 nogil
cdef Py_ssize_t aiofn_send(int sockfd, void* buf, Py_ssize_t len) except? -1 nogil
cdef Py_ssize_t aiofn_writev(int sockfd, aiofn_iovec* iov, Py_ssize_t iovcnt) except? -1 nogil

cdef extern from *:
    cdef bint unlikely(bint val) noexcept
    cdef bint likely(bint val) noexcept
