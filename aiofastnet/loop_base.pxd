from .loop_backend cimport (
    aiofn_loop_backend_t,
    aiofn_loop_proactor_socket_t,
    aiofn_proactor_backend_t,
    aiofn_loop_status,
)
from .utils cimport NoResult


cdef class ProactorContext:
    cdef:
        object loop
        aiofn_loop_backend_t *backend
        const aiofn_proactor_backend_t *proactor
        dict sockets

    cdef inline NoResult check_status(self, aiofn_loop_status status) except NoResult.EXC
    cdef inline NoResult backend_failed(self, object exc) except NoResult.EXC
    cdef inline ProactorSocket wrap_socket(self, object sock)
    cdef inline NoResult unwrap_socket(self, ProactorSocket sock) except NoResult.EXC
    cdef NoResult close(self) except NoResult.EXC


cdef class ProactorSocket:
    cdef:
        ProactorContext context
        object owner
        bint write_in_progress
        aiofn_loop_proactor_socket_t backend_sock
