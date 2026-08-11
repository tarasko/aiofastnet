from cpython.object cimport PyObject


cdef enum NoResult:
    # Side-effect-only Cython helpers use EXC as their exception sentinel. The
    # generated C caller checks the value, while the Cython caller ignores it.
    # This helps to remove unnecessary incref/decref on Py_NONE objects when
    # function doesn't return any value.
    EXC = -1
    OK = 0


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


cpdef aiofn_set_result_unless_cancelled(fut, result)
cdef NoResult aiofn_set_nodelay(sock) except NoResult.EXC
cpdef aiofn_set_socket_extra_info(object extra, object sock)

cpdef aiofn_validate_buffer(object buffer)
cdef NoResult aiofn_unpack_simple_buffer(object buffer, char** ptr_out, Py_ssize_t* size_out, int flags) except NoResult.EXC
cpdef object aiofn_maybe_copy_buffer(object buffer)
cpdef object aiofn_validate_and_maybe_copy_buffer(object buffer)
cdef object aiofn_maybe_copy_buffer_tail(object buffer, char* ptr, Py_ssize_t sz)

cdef object aiofn_sockaddr_to_pyaddr(void* addr, unsigned int addr_len)
cdef NoResult aiofn_pyaddr_to_sockaddr(int family, object addr, void* raw_addr, unsigned int* raw_addr_len) except NoResult.EXC

cdef Py_ssize_t aiofn_read(int fd, void* buf, Py_ssize_t len, bint is_socket) except -2
cdef Py_ssize_t aiofn_write(int fd, void* buf, Py_ssize_t len, bint is_socket) except -2
cdef Py_ssize_t aiofn_writev(int sockfd, aiofn_iovec* iov, Py_ssize_t iovcnt, bint is_socket) except -2

cdef Py_ssize_t aiofn_recvfrom(int sockfd, void* buf, Py_ssize_t len, void* addr, unsigned int* addr_len) except -2
cdef Py_ssize_t aiofn_sendto(int sockfd, void* buf, Py_ssize_t len, void* raw_addr, unsigned int raw_addr_len) except -2

cdef bytes aiofn_simple_read(int fd, Py_ssize_t max_size, Py_ssize_t* bytes_read, bint is_socket)

cdef NoResult aiofn_add_info_and_reraise(info) except NoResult.EXC


cdef extern from "pythread.h":
    unsigned long PyThread_get_thread_ident()


cdef extern from *:
    cdef bint unlikely(bint val) noexcept
    cdef bint likely(bint val) noexcept


cdef extern from *:
    """
    static inline PyObject* aiofn_allocate_bytes(Py_ssize_t sz, char** ptr)
    {
        PyObject* obj = PyBytes_FromStringAndSize(NULL, sz);
        if (obj == NULL)
        {
            *ptr = NULL;
        }
        else
        {
            *ptr = PyBytes_AS_STRING(obj);
        }
        return obj;
    }

    static inline PyObject* aiofn_finalize_bytes(PyObject* obj, Py_ssize_t new_size)
    {
        if (new_size == 0)
        {
            Py_DECREF(obj);
            Py_RETURN_NONE;
        }
        _PyBytes_Resize(&obj, new_size);
        return obj;
    }

    static inline int aiofn_resize_bytes(PyObject** obj, Py_ssize_t new_size, char** ptr)
    {
        if (_PyBytes_Resize(obj, new_size) < 0)
        {
            *ptr = NULL;
            return -1;
        }
        *ptr = PyBytes_AS_STRING(*obj);
        return 0;
    }

    #if defined(_WIN32)
        #include <winsock2.h>

        // Memory layout is compatible with WSABUF
        typedef struct
        {
            ULONG iov_len;
            CHAR* iov_base;
        } aiofn_iovec;
    #else
        #include <sys/uio.h>
        typedef struct iovec aiofn_iovec;
    #endif

    #define AIOFN_MAX_IOVEC 256
    """

    PyObject* aiofn_allocate_bytes(Py_ssize_t sz, char** buf) except NULL
    bytes aiofn_finalize_bytes(PyObject* obj, Py_ssize_t sz)
    int aiofn_resize_bytes(PyObject** obj, Py_ssize_t sz, char** buf) except -1

    cdef const int AIOFN_MAX_IOVEC

    ctypedef struct aiofn_iovec:
        void* iov_base
        size_t iov_len
