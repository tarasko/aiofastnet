from cpython.bytes cimport PyBytes_FromObject, PyBytes_FromStringAndSize, PyBytes_GET_SIZE
from cpython.buffer cimport PyObject_GetBuffer, PyBuffer_Release, PyBUF_SIMPLE
from libc cimport errno


cdef extern from "Python.h":
    PyObject *PyMemoryView_GET_BASE(PyObject *mview)
    int PyBytes_Check(PyObject *o)


cpdef aiofn_validate_buffer(buffer):
    if not isinstance(buffer, (bytes, bytearray, memoryview)):
        raise TypeError(f"data: expecting a bytes-like instance, "
                        f"got {type(buffer).__name__}")


cdef aiofn_unpack_buffer(object bytes_like_obj, char** ptr_out, Py_ssize_t* size_out):
    if bytes_like_obj is None:
        ptr_out[0] = NULL
        size_out[0] = 0
        return

    cdef Py_buffer pybuf
    PyObject_GetBuffer(bytes_like_obj, &pybuf, PyBUF_SIMPLE)
    ptr_out[0] = <char*>pybuf.buf
    size_out[0] = pybuf.len
    # We can already release because we still keep the reference to the message
    PyBuffer_Release(&pybuf)


cpdef object aiofn_maybe_copy_buffer(object buffer):
    if isinstance(buffer, bytes):
        return buffer

    cdef:
        PyObject* obj
        bint is_bytes = False
    if isinstance(buffer, memoryview):
        obj = PyMemoryView_GET_BASE(<PyObject*>buffer)
        is_bytes = obj != NULL and PyBytes_Check(obj)
        if is_bytes:
            return buffer

    return PyBytes_FromObject(buffer)


cpdef object aiofn_validate_and_maybe_copy_buffer(object buffer):
    aiofn_maybe_copy_buffer(buffer)
    return aiofn_maybe_copy_buffer(buffer)


cdef object aiofn_maybe_copy_buffer_tail(object buffer, char* ptr, Py_ssize_t sz):
    # Do not copy bytes content, it is safe to make a memory view
    if isinstance(buffer, bytes):
        return memoryview(buffer)[PyBytes_GET_SIZE(buffer) - sz:]

    cdef:
        bint is_bytes
        PyObject* obj
        memoryview mv

    if isinstance(buffer, memoryview):
        obj = PyMemoryView_GET_BASE(<PyObject*>buffer)
        is_bytes = obj != NULL and PyBytes_Check(obj)
        if is_bytes:
            mv = <memoryview>buffer
            return mv[len(mv) - sz:]

    return PyBytes_FromStringAndSize(ptr, sz)


cdef Py_ssize_t aiofn_recv(int sockfd, void* buf, Py_ssize_t len) except? -1:
    cdef:
        ssize_t bytes_read
        int last_error

    while True:
        bytes_read = recv(sockfd, buf, len, 0)
        if bytes_read >= 0:
            return bytes_read

        last_error = aiofn_get_last_error()
        if last_error in (AIOFN_EWOULDBLOCK, AIOFN_EAGAIN):
            return bytes_read

        if not AIOFN_IS_WINDOWS and last_error == errno.EINTR:
            continue

        aiofn_set_exc_from_error(last_error)

        return bytes_read


cdef Py_ssize_t aiofn_send(int sockfd, void* buf, Py_ssize_t len) except? -1:
    cdef:
        ssize_t bytes_sent
        int last_error

    while True:
        bytes_sent = send(sockfd, buf, len, 0)
        if bytes_sent > 0:
            return bytes_sent

        if bytes_sent == -1:
            last_error = aiofn_get_last_error()
            if last_error in (AIOFN_EWOULDBLOCK, AIOFN_EAGAIN):
                return bytes_sent

            if not AIOFN_IS_WINDOWS and last_error == errno.EINTR:
                continue

            aiofn_set_exc_from_error(last_error)
            return bytes_sent

        if bytes_sent == 0:
            # This should never happen, but who knows?
            # May be len is 0?
            raise RuntimeError(f"send syscall has sent 0 bytes and did not indicate any error, buf_len={len}")


cdef Py_ssize_t aiofn_writev(int sockfd, aiofn_iovec* iov, Py_ssize_t iovcnt) except? -1:
    cdef:
        ssize_t bytes_sent
        int last_error

    while True:
        bytes_sent = aiofn_writev_sys(sockfd, iov, iovcnt)

        if bytes_sent > 0:
            return bytes_sent

        if bytes_sent == -1:
            last_error = aiofn_get_last_error()
            if last_error in (AIOFN_EWOULDBLOCK, AIOFN_EAGAIN):
                return bytes_sent

            if not AIOFN_IS_WINDOWS and last_error == errno.EINTR:
                continue

            aiofn_set_exc_from_error(last_error)
            return bytes_sent

        if bytes_sent == 0:
            # This should never happen, but who knows?
            # May be len is 0?
            raise RuntimeError(f"writev syscall has sent 0 bytes and did not indicate any error")
