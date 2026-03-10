from .system cimport *

cpdef aiofn_validate_buffer(object buffer)
cdef aiofn_unpack_buffer(object buffer, char** ptr_out, Py_ssize_t* size_out)
cdef object aiofn_maybe_copy_buffer(object buffer)
cpdef object aiofn_validate_and_maybe_copy_buffer(object buffer)
cdef object aiofn_maybe_copy_buffer_tail(object buffer, char* ptr, Py_ssize_t sz)
cdef Py_ssize_t aiofn_recv(int sockfd, void* buf, Py_ssize_t len) except? -1
cdef Py_ssize_t aiofn_send(int sockfd, void* buf, Py_ssize_t len) except? -1
cdef Py_ssize_t aiofn_writev(int sockfd, aiofn_iovec* iov, Py_ssize_t iovcnt) except? -1
