cdef class Transport:
    cdef write_c(self, char* ptr, Py_ssize_t sz)
    cpdef write(self, data)
    cpdef writelines(self, list_of_data)


cdef class Protocol:
    cpdef is_buffered_protocol(self)
    cdef get_buffer_c(self, Py_ssize_t hint, char** buf, Py_ssize_t* buf_len)
    cpdef get_buffer(self, Py_ssize_t hint)
    cpdef buffer_updated(self, Py_ssize_t bytes_read)
    cpdef data_received(self, bytes data)
    cpdef Py_ssize_t get_local_write_buffer_size(self) except -1


cpdef aiofn_is_buffered_protocol(protocol)
