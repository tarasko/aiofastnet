from cpython.object cimport PyObject, PyTypeObject
from cpython.time cimport PyTime_t
from libc.stdint cimport uintptr_t


# Copied from pywepoll.

cdef extern from *:
    """
/* from socketmodule.h */
#define PySocket_MODULE_NAME    "_socket"
#define PySocket_CAPI_NAME      "CAPI"
#define PySocket_CAPSULE_NAME   PySocket_MODULE_NAME "." PySocket_CAPI_NAME

#ifdef MS_WINDOWS
/* typedef SOCKET SOCKET_T; */
// Only 1 change required so that we can ignore winsock.
typedef uintptr_t SOCKET_T;
#       ifdef MS_WIN64
#               define SIZEOF_SOCKET_T 8
#       else
#               define SIZEOF_SOCKET_T 4
#       endif
#else
typedef int SOCKET_T;
#       define SIZEOF_SOCKET_T 4
#endif

#if SIZEOF_SOCKET_T <= 4
#define PyLong_FromSocket_t(fd) PyLong_FromLong((SOCKET_T)(fd))
#define PyLong_AsSocket_t(fd) (SOCKET_T)PyLong_AsLong(fd)
#else
#define PyLong_FromSocket_t(fd) PyLong_FromLongLong((SOCKET_T)(fd))
#define PyLong_AsSocket_t(fd) (SOCKET_T)PyLong_AsLongLong(fd)
#endif

/* Didn't need to recast the entire object only the parts that are useful */
typedef struct {
    PyObject_HEAD
    SOCKET_T sock_fd;
    int sock_family;
    int sock_type;
    int sock_proto;
    PyObject* (*errorhandler)();
    _PyTime_t sock_timeout;
} PySocketSockObject;

typedef struct  {
    PyTypeObject *Sock_Type;
    PyObject *error;
    PyObject *timeout_error;
} PySocketModule_APIObject;

/* ==== CYTHON PORT ==== */

PySocketModule_APIObject* __cython_socket_api;

/* Attempts to make pywepoll threadsafe */
PySocketModule_APIObject* cimport_socket(){
    return (PySocketModule_APIObject*)PyCapsule_Import(PySocket_CAPSULE_NAME, 0);
}

int import_socket(){
    /* PySocketModule_ImportModuleAndAPI Macro was not required 
     * we need the import to block incase of failure */ 
    __cython_socket_api = PyCapsule_Import(PySocket_CAPSULE_NAME, 0);
    return __cython_socket_api != NULL;
}


static inline int SocketType_CheckExact(PyObject* obj) {
    if (__cython_socket_api != NULL){
        return Py_IS_TYPE(obj, __cython_socket_api->Sock_Type);    
    }
    PyErr_SetString(PyExc_ImportError, "Required CPython Capsule _socket.CAPI was not imported");
    return -1;
}

static inline int SocketType_Check(PyObject* obj) {
    return SocketType_CheckExact(obj) || PyObject_TypeCheck(obj,  __cython_socket_api->Sock_Type);
}

static inline int Socket_GetFileDescriptor(PyObject* sock, uintptr_t *fd){
    if (!SocketType_Check(sock)){
        PyErr_SetString(PyExc_TypeError, "socket type is required");
        return -1;
    }
    *fd = ((PySocketSockObject*)sock)->sock_fd;
    return 0;
}
    """
    ctypedef uintptr_t SOCKET_T # NOTE: Size Varies by how it's compiled.

    ctypedef struct PySocketSockObject:
        SOCKET_T sock_fd # Socket file descriptor
        int sock_family       # Address family, e.g., AF_INET
        int sock_type         # Socket type, e.g., SOCK_STREAM
        int sock_proto        # Protocol type, usually 0
        PyObject* (*errorhandler)() except NULL # Error handler; checks
                                         #   errno, returns NULL and
                                         #   sets a Python exception
        PyTime_t sock_timeout       # Operation timeout in seconds
                                        # 0.0 means non-blocking
    
    ctypedef struct PySocketModule_APIObject:
        PyTypeObject *Sock_Type
        PyObject *error
        PyObject *timeout_error
    
    int Socket_GetFileDescriptor(object sock, uintptr_t *fd)

    # Global
    PySocketModule_APIObject* __cython_socket_api 

    ctypedef class _socket.socket [object PySocketSockObject, check_size ignore]:
        cdef:
            # Reason for making the majortiy of these constant is to prevent fiddling
            # with sockets from python's end.

            @property
            cdef inline const int family(self):
                return self.sock_family
            
            @property
            cdef inline const int type(self):
                return self.sock_type
            
            @property
            cdef inline PyTime_t timeout(self):
                return self.sock_timeout

            @property
            cdef inline int proto(self):
                return self.sock_proto
            
            @property
            cdef inline SOCKET_T fileno(self):
                return self.sock_fd

    int import_socket() except 0
    # imports _socket.CAPI this function is important to import first thing after cimport is finished
    
    int SocketType_CheckExact(object obj) except -1
    # checks if python type matches _socket.socket exactly
    # - 0 if False
    # - 1 if True 
    # - -1 if CAPI did not import raises ImportError

    int SocketType_Check(object obj) except -1
    # checks if python type is socket.socket or a subclass 
    # - 0 if False
    # - 1 if True 
    # - -1 if object is NULL

    PySocketModule_APIObject* cimport_socket() except NULL

    object PyLong_FromSocket_t(SOCKET_T fd)
    SOCKET_T PyLong_AsSocket_t(object fd)
