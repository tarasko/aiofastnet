cdef class Transport:
    """
    Base class for aiofastnet transports.
    """
    # aiofastnet extension,
    # skip checks for thread-safety and data types
    cpdef write_nocheck(self, data)
    cpdef writelines_nocheck(self, list_of_data)
    cdef write_c(self, char* ptr, Py_ssize_t sz)


cdef class Protocol:
    cpdef is_buffered_protocol(self)
    cdef get_buffer_c(self, Py_ssize_t hint, char** buf, Py_ssize_t* buf_len)
    cpdef get_buffer(self, Py_ssize_t hint)
    cpdef buffer_updated(self, Py_ssize_t bytes_read)
    cpdef data_received(self, bytes data)
    cpdef Py_ssize_t get_local_write_buffer_size(self) except -1


cdef class WriteWatermarks:
    cdef:
        object _loop
        Py_ssize_t _high_water
        Py_ssize_t _low_water
        bint _paused

    cpdef tuple get_write_buffer_limits(self)
    cpdef set_write_buffer_limits(self, transport, app_protocol,
                                  Py_ssize_t write_buffer_size,
                                  high=*, low=*)
    cpdef maybe_pause_protocol(self, transport, app_protocol, Py_ssize_t write_buffer_size)
    cpdef maybe_resume_protocol(self, transport, app_protocol, Py_ssize_t write_buffer_size)

    cdef inline _set_write_buffer_limits(self, high, low)


cpdef aiofn_is_buffered_protocol(protocol)