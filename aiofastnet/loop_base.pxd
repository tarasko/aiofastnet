from .loop_backend cimport (
    aiofn_loop_backend_t,
    aiofn_loop_native_handle_t,
    aiofn_loop_proactor_handle_t,
    aiofn_proactor_backend_t,
    aiofn_loop_status,
)
from .utils cimport NoResult


cdef class ProactorContext:
    cdef:
        object loop
        aiofn_loop_backend_t *backend
        const aiofn_proactor_backend_t *proactor
        dict handles

    cdef inline NoResult check_status(self, aiofn_loop_status status) except NoResult.EXC
    cdef inline NoResult backend_failed(self, object exc) except NoResult.EXC
    cdef inline ProactorHandle wrap_socket(self, object sock)
    cdef inline ProactorHandle wrap_pipe(self, object pipe)
    cdef inline ProactorHandle _wrap_handle(
        self,
        aiofn_loop_native_handle_t native_handle,
        int kind,
        int socktype,
    )
    cdef inline NoResult unwrap_handle(self, ProactorHandle handle) except NoResult.EXC
    cdef NoResult close(self) except NoResult.EXC


cdef class ProactorHandle:
    cdef:
        ProactorContext context
        object owner
        aiofn_loop_proactor_handle_t backend_handle
