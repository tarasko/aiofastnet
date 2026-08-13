from .utils cimport NoResult


cdef class Transport:
    """
    Base class for aiofastnet transports.
    """

    cdef:
        # Python customization hooks used by tests and applications.
        dict __dict__
        object __weakref__

        # Event-loop affinity and cached runtime configuration.
        object _loop
        unsigned long _thread_id
        bint _is_debug

        # Application protocol and cached properties used for fast dispatch.
        object _protocol
        bint _protocol_buffered
        bint _protocol_aiofn

        # Protocol lifecycle. connection_lost() is owed while connected is set;
        # eof_received() must be delivered at most once.
        bint _protocol_connected
        bint _protocol_eof_received

        # User-visible metadata returned by get_extra_info().
        dict _extra

        # Reading has been explicitly paused by the application.
        bint _read_paused

        # Graceful close was requested; queued writes may still be draining.
        bint _closing

        # Terminal close has started; final cleanup is pending or complete.
        bint _finalizing_close

    cdef inline NoResult _check_thread(self, meth) except NoResult.EXC
    cdef inline NoResult _set_protocol(self, protocol) except NoResult.EXC

    cpdef set_protocol(self, protocol)
    cpdef get_protocol(self)
    cpdef get_extra_info(self, name, default=*)
    cpdef is_closing(self)
    cpdef is_reading(self)
    cpdef pause_reading(self)
    cpdef resume_reading(self)
    cpdef abort(self)

    # aiofastnet extension,
    # skip checks for thread-safety and data types
    cpdef sendto_nocheck(self, data, addr)
    cpdef write_nocheck(self, data)
    cpdef writelines_nocheck(self, list_of_data)
    cdef NoResult write_c(self, char* ptr, Py_ssize_t sz) except NoResult.EXC

    cdef NoResult _start_reading(self) except NoResult.EXC
    cdef NoResult _stop_reading(self) except NoResult.EXC

    cpdef _force_close(self, exc)

    cdef NoResult _fatal_error(self, exc, message=*) except NoResult.EXC
    cdef NoResult _report_protocol_exception(self, exc, message) except NoResult.EXC
    cdef bint _should_report_fatal_error(self, exc) except -1
    cdef NoResult _handle_error(self, message) except NoResult.EXC

    # Protocol dispatch helpers normally let callback exceptions propagate. They
    # may attach callback-specific context to the active exception before re-raising it.
    cpdef _call_protocol_connection_made(self)
    cdef NoResult _call_protocol_connection_lost(self, exc) except NoResult.EXC
    cdef inline NoResult _call_protocol_data_received(self, data) except NoResult.EXC
    cdef object _call_protocol_eof_received(self)
    cdef inline object _call_protocol_get_buffer(self, char** buf_ptr, Py_ssize_t* buf_len)
    cdef inline NoResult _call_protocol_buffer_updated(self, Py_ssize_t bytes_read) except NoResult.EXC


cdef class Protocol:
    cpdef is_buffered_protocol(self)

    # Speedups for buffered protocols
    cdef NoResult get_buffer_c(self, Py_ssize_t hint, char** buf, Py_ssize_t* buf_len) except NoResult.EXC
    cpdef get_buffer(self, Py_ssize_t hint)
    cpdef buffer_updated(self, Py_ssize_t bytes_read)
    cpdef data_received(self, data)

    # Helper for more accurate write buffer size estimation
    cpdef Py_ssize_t get_local_write_buffer_size(self) except -1


cdef class WriteRequest:
    cdef:
        object data
        char *ptr
        Py_ssize_t size


cdef WriteRequest make_write_request(object data)
cdef WriteRequest make_write_request_from_ptr(char *ptr, Py_ssize_t size)
cdef WriteRequest make_write_request_tail(object data, char *ptr, Py_ssize_t size)


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

    cdef inline NoResult _set_write_buffer_limits(self, high, low) except NoResult.EXC


cpdef aiofn_is_buffered_protocol(protocol)
