from libc.stdint cimport int8_t, uint64_t


cdef extern from "pthread.h":

    int pthread_atfork(
        void (*prepare)(),
        void (*parent)(),
        void (*child)())


cdef extern from "includes/fork_handler.h":

    uint64_t MAIN_THREAD_ID
    int8_t MAIN_THREAD_ID_SET
    ctypedef void (*OnForkHandler)()
    void handleAtFork()
    void setForkHandler(OnForkHandler handler)
    void resetForkHandler()
    void setMainThreadID(uint64_t id)