#include "uring_backend.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <liburing.h>

/*
 * A from-scratch backend driven directly by liburing, with no compatibility
 * layer underneath it (unlike the asio-based test backend). Every op is
 * submitted once, as a single SQE; there is no "try a direct syscall first"
 * fallback path anywhere here - that optimization already lives in the
 * frontend's own _try_write() fast path (aiofastnet/transport.pyx), which
 * runs identically regardless of which backend is active.
 *
 * user_data tagging: every SQE we submit carries a 64-bit tag built from a
 * pointer to one of our own heap structs (always at least 16-byte aligned,
 * per glibc malloc) OR-ed with a 4-bit "kind" in the low bits, so a single
 * CQE dispatch switch can route directly to the right handler without a
 * lookup table.
 */

typedef enum {
    AIOFN_URING_KIND_IGNORE = 0, /* a cancel/remove op's own completion */
    AIOFN_URING_KIND_TIMER = 1,
    AIOFN_URING_KIND_SIGNAL = 2,
    AIOFN_URING_KIND_FD_READ = 3,
    AIOFN_URING_KIND_FD_WRITE = 4,
    AIOFN_URING_KIND_HANDLE_READ = 5,
    AIOFN_URING_KIND_HANDLE_WRITE = 6,
    AIOFN_URING_KIND_HANDLE_CONNECT = 7,
    AIOFN_URING_KIND_HANDLE_ACCEPT = 8,
} aiofn_uring_tag_kind_t;

#define AIOFN_URING_TAG_BITS 4u
#define AIOFN_URING_TAG_MASK 0xFu

static inline __u64 aiofn_uring_tag(void *ptr, aiofn_uring_tag_kind_t kind) {
    return ((__u64)(uintptr_t)ptr) | (__u64)kind;
}

static inline aiofn_uring_tag_kind_t aiofn_uring_tag_kind(__u64 ud) {
    return (aiofn_uring_tag_kind_t)(ud & AIOFN_URING_TAG_MASK);
}

static inline void *aiofn_uring_tag_ptr(__u64 ud) {
    return (void *)(uintptr_t)(ud & ~(__u64)AIOFN_URING_TAG_MASK);
}

/*
 * call_soon()/call_at() share aiofn_loop_action_t.backend_token, so
 * action_cancel() needs to tell the two kinds of wrapper it might point to
 * apart. Both start with this discriminant.
 */
typedef enum {
    AIOFN_URING_TOKEN_READY = 0,
    AIOFN_URING_TOKEN_TIMER = 1,
} aiofn_uring_token_kind_t;

/* Same-thread call_soon(): a plain intrusive FIFO list, no syscall involved. */
typedef struct aiofn_uring_ready_node {
    aiofn_uring_token_kind_t token_kind; /* AIOFN_URING_TOKEN_READY */
    aiofn_loop_action_t *action;         /* NULL once cancelled; node freed at drain */
    struct aiofn_uring_ready_node *next;
} aiofn_uring_ready_node_t;

/* call_at(): every timeout, however near, rides its own IORING_OP_TIMEOUT SQE.
   No heap: the kernel's own timeout list orders these for us, and run()'s
   wait never needs a computed "time until next timer" - it can always block
   indefinitely, because every pending deadline already has its own wakeup. */
typedef struct aiofn_uring_timer {
    aiofn_uring_token_kind_t token_kind; /* AIOFN_URING_TOKEN_TIMER */
    aiofn_loop_action_t *action;         /* NULL once cancelled */
    struct __kernel_timespec ts;         /* must outlive the SQE until submitted */
    int pending_sqes;                    /* timeout SQE, plus briefly a remove SQE */
} aiofn_uring_timer_t;

/*
 * Signals. sigprocmask()/signalfd only cover the calling thread's mask - a
 * signal sent to the process (os.kill(getpid(), ...)) can land on ANY thread
 * that hasn't blocked it, and a Python process routinely has other threads
 * around (pytest, thread-pool workers, ...) that never call into this
 * backend at all. A signalfd-based design is therefore unsafe here. Instead,
 * install a real sigaction() handler - process-wide regardless of which
 * thread receives the signal - that does the one thing async-signal-safe
 * code is allowed to do: write() the signal number to a self-pipe, which the
 * loop polls normally.
 */
#define AIOFN_URING_MAX_SIGNUM 64

typedef struct aiofn_uring_signal {
    aiofn_loop_signal_watch_t *watch;
    int signum;
    struct sigaction old_action;
} aiofn_uring_signal_t;

/* Reactor fd readiness: one persistent multishot poll per direction. Mirrors
   the frontend's own aiofn_loop_fd_watch_t, which already carries one token
   per direction for the same fd. */
typedef struct aiofn_uring_fd_watch {
    aiofn_loop_fd_watch_t *watch;
    int reading;
    int writing;
    int pending_sqes;
} aiofn_uring_fd_watch_t;

/* Proactor handle. The native fd is never dup()'d: unlike libuv/asio we do
   not wrap it in an owning object with its own close-on-destroy semantics,
   so there is nothing to compensate for. unwrap_handle() simply stops using
   the fd; the frontend closes it, exactly as the ABI requires. */
typedef struct aiofn_uring_handle {
    int fd;
    aiofn_loop_proactor_handle_kind_t kind;
    int socktype;
    aiofn_loop_proactor_handle_t *frontend;

    int unwrapped;
    int pending_sqes;

    aiofn_loop_read_alloc_fn read_alloc;
    aiofn_loop_read_callback_fn read_callback;
    aiofn_loop_recvfrom_callback_fn recvfrom_callback;
    void *read_callback_data;
    int reading;
    void *read_buf;
    struct sockaddr_storage recv_addr;
    struct iovec recv_iov;
    struct msghdr recv_msg;

    aiofn_loop_accept_callback_fn accept_callback;
    void *accept_callback_data;
    int accepting;

    aiofn_loop_proactor_op_t *write_op;
    struct msghdr write_msg; /* only used for a socket write with >1 buffer */

    aiofn_loop_proactor_op_t *sendto_op;
    aiofn_loop_proactor_op_t *connect_op;
    struct sockaddr_storage connect_addr;
    struct sockaddr_storage sendto_addr;
} aiofn_uring_handle_t;

typedef struct {
    aiofn_loop_backend_t backend;
    aiofn_reactor_backend_t reactor;
    aiofn_proactor_backend_t proactor;

    struct io_uring ring;
    int closed;
    int stop_requested;
    char last_error[256];

    aiofn_uring_ready_node_t *ready_head;
    aiofn_uring_ready_node_t *ready_tail;

    int signal_pipe_read;
    int signal_pipe_write;
    aiofn_uring_signal_t *signals_by_num[AIOFN_URING_MAX_SIGNUM];
} aiofn_uring_state_t;

/*
 * sigaction() handlers are plain C function pointers with no user-data slot,
 * so the handler needs some way to find the pipe to write to. Signals are
 * inherently process-global (only one handler can own a given signum at a
 * time; the ABI itself allows at most one watch per signal number), so at
 * most one backend instance's pipe is ever the active target at a time.
 */
static volatile int g_aiofn_uring_signal_pipe_write_fd = -1;

static void aiofn_uring_signal_handler(int signum) {
    int fd = g_aiofn_uring_signal_pipe_write_fd;
    if (fd >= 0) {
        unsigned char byte = (unsigned char)signum;
        ssize_t ignored_result = write(fd, &byte, 1);
        (void)ignored_result;
    }
}

static void aiofn_uring_set_error(aiofn_uring_state_t *state, const char *operation, int err) {
    snprintf(state->last_error, sizeof(state->last_error), "%s: %s", operation, strerror(err < 0 ? -err : err));
}

static struct io_uring_sqe *aiofn_uring_get_sqe(aiofn_uring_state_t *state) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&state->ring);
    if (sqe != NULL) {
        return sqe;
    }
    /* The submission queue is full; flush it so a freed slot becomes available. */
    io_uring_submit(&state->ring);
    return io_uring_get_sqe(&state->ring);
}

/* ---- call_soon / call_at / action_cancel ---- */

static aiofn_loop_status aiofn_uring_call_soon(void *data, aiofn_loop_action_t *action) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_ready_node_t *node = malloc(sizeof(*node));
    if (node == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }

    node->token_kind = AIOFN_URING_TOKEN_READY;
    node->action = action;
    node->next = NULL;

    if (state->ready_tail != NULL) {
        state->ready_tail->next = node;
    } else {
        state->ready_head = node;
    }
    state->ready_tail = node;

    action->backend_token = node;
    return AIOFN_LOOP_OK;
}

static void aiofn_uring_submit_timer(aiofn_uring_state_t *state, aiofn_uring_timer_t *timer) {
    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe == NULL) {
        /* Should not happen with a reasonably sized ring; nothing sane to do
           but drop the timer - the frontend has no synchronous failure path
           for call_at() to report through at this point. */
        return;
    }
    timer->pending_sqes++;
    io_uring_prep_timeout(sqe, &timer->ts, 0, IORING_TIMEOUT_ABS);
    io_uring_sqe_set_data64(sqe, aiofn_uring_tag(timer, AIOFN_URING_KIND_TIMER));
}

static aiofn_loop_status aiofn_uring_call_at(void *data, aiofn_loop_action_t *action, uint64_t deadline_ns) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_timer_t *timer = calloc(1, sizeof(*timer));
    if (timer == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }

    timer->token_kind = AIOFN_URING_TOKEN_TIMER;
    timer->action = action;
    timer->ts.tv_sec = (time_t)(deadline_ns / 1000000000ull);
    timer->ts.tv_nsec = (long)(deadline_ns % 1000000000ull);

    aiofn_uring_submit_timer(state, timer);

    action->backend_token = timer;
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_uring_action_cancel(void *data, aiofn_loop_action_t *action) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_token_kind_t *kind = (aiofn_uring_token_kind_t *)action->backend_token;
    action->backend_token = NULL;

    if (*kind == AIOFN_URING_TOKEN_READY) {
        aiofn_uring_ready_node_t *node = (aiofn_uring_ready_node_t *)kind;
        node->action = NULL; /* drained and freed the next time the ready list runs */
        return AIOFN_LOOP_OK;
    }

    aiofn_uring_timer_t *timer = (aiofn_uring_timer_t *)kind;
    timer->action = NULL;

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe != NULL) {
        timer->pending_sqes++;
        io_uring_prep_timeout_remove(sqe, aiofn_uring_tag(timer, AIOFN_URING_KIND_TIMER), 0);
        io_uring_sqe_set_data64(sqe, aiofn_uring_tag(NULL, AIOFN_URING_KIND_IGNORE));
    }
    return AIOFN_LOOP_OK;
}

static void aiofn_uring_timer_completed(aiofn_uring_timer_t *timer, int res) {
    (void)res;
    if (--timer->pending_sqes == 0) {
        if (timer->action != NULL) {
            aiofn_loop_action_t *action = timer->action;
            free(timer);
            action->backend_token = NULL;
            action->callback(action);
            return;
        }
        free(timer);
    }
}

static void aiofn_uring_drain_ready(aiofn_uring_state_t *state) {
    aiofn_uring_ready_node_t *node = state->ready_head;
    state->ready_head = NULL;
    state->ready_tail = NULL;

    while (node != NULL) {
        aiofn_uring_ready_node_t *next = node->next;
        aiofn_loop_action_t *action = node->action;
        free(node);
        if (action != NULL) {
            action->backend_token = NULL;
            action->callback(action);
        }
        node = next;
    }
}

/* ---- run / stop / close / now_ns ---- */

static uint64_t aiofn_uring_now_ns(void *data) {
    (void)data;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void aiofn_uring_dispatch_cqe(aiofn_uring_state_t *state, struct io_uring_cqe *cqe);

static aiofn_loop_status aiofn_uring_run(void *data) {
    aiofn_uring_state_t *state = data;
    state->stop_requested = 0;

    while (!state->stop_requested) {
        aiofn_uring_drain_ready(state);
        if (state->stop_requested) {
            break;
        }

        struct io_uring_cqe *cqe = NULL;
        struct __kernel_timespec zero_ts = {0, 0};
        int has_more_ready = state->ready_head != NULL;
        int ret = io_uring_submit_and_wait_timeout(&state->ring, &cqe, 1, has_more_ready ? &zero_ts : NULL, NULL);
        if (ret < 0 && ret != -ETIME && ret != -EINTR) {
            aiofn_uring_set_error(state, "io_uring_submit_and_wait_timeout", ret);
            return AIOFN_LOOP_ERROR;
        }

        unsigned head;
        unsigned count = 0;
        struct io_uring_cqe *c;
        io_uring_for_each_cqe(&state->ring, head, c) {
            aiofn_uring_dispatch_cqe(state, c);
            count++;
        }
        if (count > 0) {
            io_uring_cq_advance(&state->ring, count);
        }
    }
    return AIOFN_LOOP_OK;
}

static void aiofn_uring_stop(void *data) {
    aiofn_uring_state_t *state = data;
    state->stop_requested = 1;
}

static void aiofn_uring_close(void *data) {
    aiofn_uring_state_t *state = data;
    if (state->signal_pipe_write >= 0 && g_aiofn_uring_signal_pipe_write_fd == state->signal_pipe_write) {
        g_aiofn_uring_signal_pipe_write_fd = -1;
    }
    if (state->signal_pipe_read >= 0) {
        close(state->signal_pipe_read);
        close(state->signal_pipe_write);
        state->signal_pipe_read = -1;
        state->signal_pipe_write = -1;
    }
    io_uring_queue_exit(&state->ring);
    state->closed = 1;
}

/* ---- signals ---- */

static void aiofn_uring_issue_signal_pipe_poll(aiofn_uring_state_t *state) {
    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe == NULL) {
        return;
    }
    /* Single-shot, reissued after every completion - see the reactor fd poll
       for why (level-triggered semantics: keep re-checking, don't rely on a
       multishot registration to refire for data that's already sitting
       there unread). */
    io_uring_prep_poll_add(sqe, state->signal_pipe_read, POLLIN);
    io_uring_sqe_set_data64(sqe, aiofn_uring_tag(NULL, AIOFN_URING_KIND_SIGNAL));
}

static aiofn_loop_status aiofn_uring_ensure_signal_pipe(aiofn_uring_state_t *state) {
    if (state->signal_pipe_read >= 0) {
        return AIOFN_LOOP_OK;
    }

    int fds[2];
    if (pipe(fds) != 0) {
        aiofn_uring_set_error(state, "pipe", -errno);
        return AIOFN_LOOP_ERROR;
    }
    fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK);
    fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK);
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);

    state->signal_pipe_read = fds[0];
    state->signal_pipe_write = fds[1];
    g_aiofn_uring_signal_pipe_write_fd = fds[1];
    aiofn_uring_issue_signal_pipe_poll(state);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_uring_signal_watch(void *data, int signum, aiofn_loop_signal_watch_t *watch) {
    aiofn_uring_state_t *state = data;
    if (signum < 0 || signum >= AIOFN_URING_MAX_SIGNUM) {
        aiofn_uring_set_error(state, "signal_watch", -EINVAL);
        return AIOFN_LOOP_ERROR;
    }

    aiofn_loop_status status = aiofn_uring_ensure_signal_pipe(state);
    if (status != AIOFN_LOOP_OK) {
        return status;
    }

    aiofn_uring_signal_t *sig = calloc(1, sizeof(*sig));
    if (sig == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }
    sig->watch = watch;
    sig->signum = signum;

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = aiofn_uring_signal_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    if (sigaction(signum, &action, &sig->old_action) != 0) {
        aiofn_uring_set_error(state, "sigaction", -errno);
        free(sig);
        return AIOFN_LOOP_ERROR;
    }

    state->signals_by_num[signum] = sig;
    watch->backend_token = sig;
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_uring_signal_unwatch(void *data, aiofn_loop_signal_watch_t *watch) {
    (void)data;
    aiofn_uring_state_t *state = data;
    aiofn_uring_signal_t *sig = watch->backend_token;
    watch->backend_token = NULL;

    state->signals_by_num[sig->signum] = NULL;
    sigaction(sig->signum, &sig->old_action, NULL);
    free(sig);
    return AIOFN_LOOP_OK;
}

static void aiofn_uring_signal_pipe_completed(aiofn_uring_state_t *state, int res) {
    if (res >= 0) {
        unsigned char buf[64];
        ssize_t n;
        /* We own both ends of this pipe (unlike the frontend's self-pipe),
           so draining fully here is safe and correct. */
        while ((n = read(state->signal_pipe_read, buf, sizeof(buf))) > 0) {
            for (ssize_t i = 0; i < n; i++) {
                int signum = buf[i];
                if (signum < 0 || signum >= AIOFN_URING_MAX_SIGNUM) {
                    continue;
                }
                aiofn_uring_signal_t *sig = state->signals_by_num[signum];
                if (sig != NULL) {
                    sig->watch->callback(sig->watch->callback_data, signum);
                }
            }
        }
    }
    aiofn_uring_issue_signal_pipe_poll(state);
}

/* ---- reactor fd readiness ---- */

static void aiofn_uring_issue_fd_poll(aiofn_uring_state_t *state, aiofn_uring_fd_watch_t *fw, int is_read) {
    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe == NULL) {
        return;
    }
    fw->pending_sqes++;
    /* Single-shot, reissued after every completion (see
       aiofn_uring_fd_watch_completed) rather than multishot: multishot poll
       only refires on a fresh wakeup edge, not merely because the fd is
       still readable with old, unconsumed data. Consumers like the
       frontend's self-pipe do a bounded read per callback and rely on being
       re-notified while anything remains - genuine level-triggered
       semantics, which a fresh poll_add gets by re-checking current
       readiness on submission, not just waiting for a new edge. */
    io_uring_prep_poll_add(sqe, fw->watch->fd, is_read ? POLLIN : POLLOUT);
    io_uring_sqe_set_data64(sqe, aiofn_uring_tag(fw, is_read ? AIOFN_URING_KIND_FD_READ : AIOFN_URING_KIND_FD_WRITE));
}

static void aiofn_uring_maybe_free_fd_watch(aiofn_uring_fd_watch_t *fw) {
    if (!fw->reading && !fw->writing && fw->pending_sqes == 0) {
        free(fw);
    }
}

static aiofn_loop_status aiofn_uring_add_reader(void *data, aiofn_loop_fd_watch_t *watch) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_fd_watch_t *fw = watch->backend_read_token != NULL ? watch->backend_read_token
                                  : watch->backend_write_token != NULL ? watch->backend_write_token
                                                                        : NULL;
    if (fw == NULL) {
        fw = calloc(1, sizeof(*fw));
        if (fw == NULL) {
            return AIOFN_LOOP_NO_MEMORY;
        }
        fw->watch = watch;
    }
    fw->reading = 1;
    watch->backend_read_token = fw;
    aiofn_uring_issue_fd_poll(state, fw, 1);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_uring_add_writer(void *data, aiofn_loop_fd_watch_t *watch) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_fd_watch_t *fw = watch->backend_write_token != NULL ? watch->backend_write_token
                                  : watch->backend_read_token != NULL ? watch->backend_read_token
                                                                       : NULL;
    if (fw == NULL) {
        fw = calloc(1, sizeof(*fw));
        if (fw == NULL) {
            return AIOFN_LOOP_NO_MEMORY;
        }
        fw->watch = watch;
    }
    fw->writing = 1;
    watch->backend_write_token = fw;
    aiofn_uring_issue_fd_poll(state, fw, 0);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_uring_remove_reader(void *data, aiofn_loop_fd_watch_t *watch) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_fd_watch_t *fw = watch->backend_read_token;
    watch->backend_read_token = NULL;
    fw->reading = 0;

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe != NULL) {
        fw->pending_sqes++;
        io_uring_prep_cancel64(sqe, aiofn_uring_tag(fw, AIOFN_URING_KIND_FD_READ), 0);
        io_uring_sqe_set_data64(sqe, aiofn_uring_tag(NULL, AIOFN_URING_KIND_IGNORE));
    }
    aiofn_uring_maybe_free_fd_watch(fw);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_uring_remove_writer(void *data, aiofn_loop_fd_watch_t *watch) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_fd_watch_t *fw = watch->backend_write_token;
    watch->backend_write_token = NULL;
    fw->writing = 0;

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe != NULL) {
        fw->pending_sqes++;
        io_uring_prep_cancel64(sqe, aiofn_uring_tag(fw, AIOFN_URING_KIND_FD_WRITE), 0);
        io_uring_sqe_set_data64(sqe, aiofn_uring_tag(NULL, AIOFN_URING_KIND_IGNORE));
    }
    aiofn_uring_maybe_free_fd_watch(fw);
    return AIOFN_LOOP_OK;
}

static void aiofn_uring_fd_watch_completed(aiofn_uring_state_t *state, aiofn_uring_fd_watch_t *fw, int is_read, int res, unsigned flags) {
    (void)flags; /* always single-shot here; see aiofn_uring_issue_fd_poll */
    fw->pending_sqes--;

    int want = is_read ? fw->reading : fw->writing;
    if (res >= 0 && res != -ECANCELED && want) {
        fw->watch->callback(fw->watch->callback_data, is_read ? AIOFN_LOOP_FD_READ : AIOFN_LOOP_FD_WRITE);
    }

    /* Re-read after the callback: it may have reentrantly called
       remove_reader()/remove_writer() (see the read_start callback for the
       same pattern). */
    want = is_read ? fw->reading : fw->writing;
    if (want) {
        aiofn_uring_issue_fd_poll(state, fw, is_read);
    } else {
        aiofn_uring_maybe_free_fd_watch(fw);
    }
}

/* ---- proactor: handle wrap / unwrap ---- */

static void aiofn_uring_complete(aiofn_loop_proactor_op_t *op, aiofn_loop_status status, size_t transferred) {
    op->backend_token = NULL;
    op->status = status;
    op->transferred = transferred;
    op->callback(op);
}

static aiofn_loop_status aiofn_uring_wrap_handle(void *data, aiofn_loop_proactor_handle_t *frontend) {
    (void)data;
    aiofn_uring_handle_t *handle = calloc(1, sizeof(*handle));
    if (handle == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }

    handle->fd = (int)frontend->native_handle;
    handle->kind = frontend->kind;
    handle->socktype = frontend->socktype;
    handle->frontend = frontend;

    frontend->backend_token = handle;
    return AIOFN_LOOP_OK;
}

static void aiofn_uring_maybe_free_handle(aiofn_uring_handle_t *handle) {
    if (handle->unwrapped && handle->pending_sqes == 0) {
        free(handle);
    }
}

static aiofn_loop_status aiofn_uring_unwrap_handle(void *data, aiofn_loop_proactor_handle_t *frontend) {
    (void)data;
    aiofn_uring_handle_t *handle = frontend->backend_token;
    frontend->backend_token = NULL;
    handle->frontend = NULL;
    handle->unwrapped = 1;
    aiofn_uring_maybe_free_handle(handle);
    return AIOFN_LOOP_OK;
}

/* ---- proactor: connect ---- */

static aiofn_loop_status aiofn_uring_connect(
    void *data,
    aiofn_loop_proactor_handle_t *frontend,
    aiofn_loop_proactor_op_t *op,
    const void *address,
    size_t address_len
) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_handle_t *handle = frontend->backend_token;

    memcpy(&handle->connect_addr, address, address_len);
    handle->connect_op = op;
    op->backend_token = handle;

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe == NULL) {
        handle->connect_op = NULL;
        op->backend_token = NULL;
        return AIOFN_LOOP_NO_MEMORY;
    }
    handle->pending_sqes++;
    io_uring_prep_connect(sqe, handle->fd, (const struct sockaddr *)&handle->connect_addr, (socklen_t)address_len);
    io_uring_sqe_set_data64(sqe, aiofn_uring_tag(handle, AIOFN_URING_KIND_HANDLE_CONNECT));
    return AIOFN_LOOP_OK;
}

/* ---- proactor: write ---- */

static aiofn_loop_status aiofn_uring_write(
    void *data,
    aiofn_loop_proactor_handle_t *frontend,
    aiofn_loop_proactor_op_t *op,
    const aiofn_loop_buffer_t *buffers,
    size_t buffer_count
) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_handle_t *handle = frontend->backend_token;

    handle->write_op = op;
    op->backend_token = handle;

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe == NULL) {
        handle->write_op = NULL;
        op->backend_token = NULL;
        return AIOFN_LOOP_NO_MEMORY;
    }
    handle->pending_sqes++;
    /* aiofn_loop_buffer_t is layout-identical to struct iovec (see the ABI
       header); a partial completion here is fine - the frontend already
       consumes op->transferred and resubmits the remainder itself.

       send/sendmsg measurably outperform write/writev on sockets, so use
       them there; pipes (and other non-socket fds) don't support send(2) at
       all (ENOTSOCK), so they still go through write/writev. POLL_FIRST
       skips the initial "try the transfer, arm poll on EAGAIN" attempt in
       favor of waiting for readiness upfront - the same "unneeded read that
       returns EAGAIN" cost we traced back at the very start of this backend
       also applies to sends, and this flag is the direct fix for it. */
    if (handle->kind == AIOFN_LOOP_PROACTOR_HANDLE_SOCKET) {
        if (buffer_count == 1) {
            io_uring_prep_send(sqe, handle->fd, buffers[0].iov_base, buffers[0].iov_len, 0);
        } else {
            memset(&handle->write_msg, 0, sizeof(handle->write_msg));
            handle->write_msg.msg_iov = (struct iovec *)buffers;
            handle->write_msg.msg_iovlen = buffer_count;
            io_uring_prep_sendmsg(sqe, handle->fd, &handle->write_msg, 0);
        }
        sqe->ioprio |= IORING_RECVSEND_POLL_FIRST;
    } else {
        io_uring_prep_writev(sqe, handle->fd, (const struct iovec *)buffers, (unsigned)buffer_count, 0);
    }
    io_uring_sqe_set_data64(sqe, aiofn_uring_tag(handle, AIOFN_URING_KIND_HANDLE_WRITE));
    return AIOFN_LOOP_OK;
}

/* ---- proactor: sendto ---- */

static aiofn_loop_status aiofn_uring_sendto(
    void *data,
    aiofn_loop_proactor_handle_t *frontend,
    aiofn_loop_proactor_op_t *op,
    const void *buffer,
    size_t buffer_len,
    const void *address,
    size_t address_len
) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_handle_t *handle = frontend->backend_token;

    handle->sendto_op = op;
    op->backend_token = handle;

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe == NULL) {
        handle->sendto_op = NULL;
        op->backend_token = NULL;
        return AIOFN_LOOP_NO_MEMORY;
    }
    handle->pending_sqes++;
    if (address != NULL) {
        memcpy(&handle->sendto_addr, address, address_len);
        io_uring_prep_sendto(sqe, handle->fd, buffer, buffer_len, MSG_NOSIGNAL,
                              (const struct sockaddr *)&handle->sendto_addr, (socklen_t)address_len);
    } else {
        io_uring_prep_send(sqe, handle->fd, buffer, buffer_len, MSG_NOSIGNAL);
    }
    sqe->ioprio |= IORING_RECVSEND_POLL_FIRST;
    io_uring_sqe_set_data64(sqe, aiofn_uring_tag(handle, AIOFN_URING_KIND_HANDLE_WRITE));
    return AIOFN_LOOP_OK;
}

/* ---- proactor: cancel ---- */

static aiofn_loop_status aiofn_uring_cancel(void *data, aiofn_loop_proactor_op_t *op) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_handle_t *handle = op->backend_token;

    aiofn_uring_tag_kind_t kind;
    if (handle->write_op == op || handle->sendto_op == op) {
        kind = AIOFN_URING_KIND_HANDLE_WRITE;
    } else if (handle->connect_op == op) {
        kind = AIOFN_URING_KIND_HANDLE_CONNECT;
    } else {
        return AIOFN_LOOP_ERROR;
    }

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe == NULL) {
        return AIOFN_LOOP_ERROR;
    }
    handle->pending_sqes++;
    io_uring_prep_cancel64(sqe, aiofn_uring_tag(handle, kind), 0);
    io_uring_sqe_set_data64(sqe, aiofn_uring_tag(NULL, AIOFN_URING_KIND_IGNORE));
    return AIOFN_LOOP_OK;
}

static void aiofn_uring_handle_write_completed(aiofn_uring_state_t *state, aiofn_uring_handle_t *handle, int res) {
    handle->pending_sqes--;

    aiofn_loop_proactor_op_t *op = handle->write_op != NULL ? handle->write_op : handle->sendto_op;
    handle->write_op = NULL;
    handle->sendto_op = NULL;
    if (op == NULL) {
        aiofn_uring_maybe_free_handle(handle);
        return; /* cancelled before it started */
    }

    if (res < 0) {
        aiofn_uring_set_error(state, "write", res);
        aiofn_uring_complete(op, AIOFN_LOOP_ERROR, 0);
    } else {
        aiofn_uring_complete(op, AIOFN_LOOP_OK, (size_t)res);
    }
    aiofn_uring_maybe_free_handle(handle);
}

static void aiofn_uring_handle_connect_completed(aiofn_uring_state_t *state, aiofn_uring_handle_t *handle, int res) {
    handle->pending_sqes--;

    aiofn_loop_proactor_op_t *op = handle->connect_op;
    handle->connect_op = NULL;
    if (op == NULL) {
        aiofn_uring_maybe_free_handle(handle);
        return;
    }

    if (res < 0) {
        aiofn_uring_set_error(state, "connect", res);
        aiofn_uring_complete(op, AIOFN_LOOP_ERROR, 0);
    } else {
        aiofn_uring_complete(op, AIOFN_LOOP_OK, 0);
    }
    aiofn_uring_maybe_free_handle(handle);
}

/* ---- proactor: persistent reads ---- */

static void aiofn_uring_issue_read(aiofn_uring_state_t *state, aiofn_uring_handle_t *handle) {
    void *buf = NULL;
    size_t buf_len = 0;
    handle->read_alloc(handle->read_callback_data, 65536, &buf, &buf_len);
    if (buf == NULL) {
        handle->reading = 0;
        return;
    }
    handle->read_buf = buf;

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe == NULL) {
        handle->reading = 0;
        return;
    }
    handle->pending_sqes++;
    /* recv() measurably outperforms read() on sockets; pipes (and other
       non-socket fds) don't support recv(2) at all (ENOTSOC), so they still
       go through read(). POLL_FIRST: see aiofn_uring_write() for why. */
    if (handle->kind == AIOFN_LOOP_PROACTOR_HANDLE_SOCKET) {
        io_uring_prep_recv(sqe, handle->fd, buf, buf_len, 0);
        sqe->ioprio |= IORING_RECVSEND_POLL_FIRST;
    } else {
        io_uring_prep_read(sqe, handle->fd, buf, buf_len, 0);
    }
    io_uring_sqe_set_data64(sqe, aiofn_uring_tag(handle, AIOFN_URING_KIND_HANDLE_READ));
}

static aiofn_loop_status aiofn_uring_read_start(
    void *data,
    aiofn_loop_proactor_handle_t *frontend,
    aiofn_loop_read_alloc_fn alloc,
    aiofn_loop_read_callback_fn callback,
    void *callback_data
) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_handle_t *handle = frontend->backend_token;
    handle->read_alloc = alloc;
    handle->read_callback = callback;
    handle->read_callback_data = callback_data;
    handle->reading = 1;
    aiofn_uring_issue_read(state, handle);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_uring_read_stop(void *data, aiofn_loop_proactor_handle_t *frontend) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_handle_t *handle = frontend->backend_token;
    handle->reading = 0;

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe != NULL) {
        handle->pending_sqes++;
        io_uring_prep_cancel64(sqe, aiofn_uring_tag(handle, AIOFN_URING_KIND_HANDLE_READ), 0);
        io_uring_sqe_set_data64(sqe, aiofn_uring_tag(NULL, AIOFN_URING_KIND_IGNORE));
    }
    return AIOFN_LOOP_OK;
}

static void aiofn_uring_handle_read_completed(aiofn_uring_state_t *state, aiofn_uring_handle_t *handle, int res) {
    handle->pending_sqes--;
    void *buf = handle->read_buf;
    handle->read_buf = NULL;

    if (res == -ECANCELED) {
        aiofn_uring_maybe_free_handle(handle);
        return;
    }
    if (res < 0) {
        aiofn_uring_set_error(state, "read", res);
        handle->read_callback(handle->read_callback_data, AIOFN_LOOP_ERROR, buf, 0);
    } else {
        handle->read_callback(handle->read_callback_data, AIOFN_LOOP_OK, buf, (size_t)res);
    }

    if (handle->reading) {
        aiofn_uring_issue_read(state, handle);
    }
    aiofn_uring_maybe_free_handle(handle);
}

/* ---- proactor: persistent recvfrom ---- */

static void aiofn_uring_issue_recvfrom(aiofn_uring_state_t *state, aiofn_uring_handle_t *handle) {
    void *buf = NULL;
    size_t buf_len = 0;
    handle->read_alloc(handle->read_callback_data, 65536, &buf, &buf_len);
    if (buf == NULL) {
        handle->reading = 0;
        return;
    }
    handle->read_buf = buf;

    handle->recv_iov.iov_base = buf;
    handle->recv_iov.iov_len = buf_len;
    memset(&handle->recv_msg, 0, sizeof(handle->recv_msg));
    handle->recv_msg.msg_name = &handle->recv_addr;
    handle->recv_msg.msg_namelen = sizeof(handle->recv_addr);
    handle->recv_msg.msg_iov = &handle->recv_iov;
    handle->recv_msg.msg_iovlen = 1;

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe == NULL) {
        handle->reading = 0;
        return;
    }
    handle->pending_sqes++;
    io_uring_prep_recvmsg(sqe, handle->fd, &handle->recv_msg, 0);
    sqe->ioprio |= IORING_RECVSEND_POLL_FIRST;
    io_uring_sqe_set_data64(sqe, aiofn_uring_tag(handle, AIOFN_URING_KIND_HANDLE_READ));
}

static aiofn_loop_status aiofn_uring_recvfrom_start(
    void *data,
    aiofn_loop_proactor_handle_t *frontend,
    aiofn_loop_read_alloc_fn alloc,
    aiofn_loop_recvfrom_callback_fn callback,
    void *callback_data
) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_handle_t *handle = frontend->backend_token;
    handle->read_alloc = alloc;
    handle->recvfrom_callback = callback;
    handle->read_callback_data = callback_data;
    handle->reading = 1;
    aiofn_uring_issue_recvfrom(state, handle);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_uring_recvfrom_stop(void *data, aiofn_loop_proactor_handle_t *frontend) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_handle_t *handle = frontend->backend_token;
    handle->reading = 0;

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe != NULL) {
        handle->pending_sqes++;
        io_uring_prep_cancel64(sqe, aiofn_uring_tag(handle, AIOFN_URING_KIND_HANDLE_READ), 0);
        io_uring_sqe_set_data64(sqe, aiofn_uring_tag(NULL, AIOFN_URING_KIND_IGNORE));
    }
    return AIOFN_LOOP_OK;
}

/* Both read_start and recvfrom_start tag their SQEs as HANDLE_READ; dispatch
   to the right frontend callback by which one is currently set. */
static void aiofn_uring_handle_recv_completed(aiofn_uring_state_t *state, aiofn_uring_handle_t *handle, int res) {
    handle->pending_sqes--;
    void *buf = handle->read_buf;
    handle->read_buf = NULL;

    if (res == -ECANCELED) {
        aiofn_uring_maybe_free_handle(handle);
        return;
    }
    if (res < 0) {
        aiofn_uring_set_error(state, "recvmsg", res);
        handle->recvfrom_callback(handle->read_callback_data, AIOFN_LOOP_ERROR, buf, 0, NULL);
    } else {
        handle->recvfrom_callback(handle->read_callback_data, AIOFN_LOOP_OK, buf, (size_t)res,
                                   (const struct sockaddr *)&handle->recv_addr);
    }

    if (handle->reading) {
        aiofn_uring_issue_recvfrom(state, handle);
    }
    aiofn_uring_maybe_free_handle(handle);
}

/* ---- proactor: persistent accept ---- */

static void aiofn_uring_issue_accept(aiofn_uring_state_t *state, aiofn_uring_handle_t *handle) {
    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe == NULL) {
        return;
    }
    handle->pending_sqes++;
    io_uring_prep_multishot_accept(sqe, handle->fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    io_uring_sqe_set_data64(sqe, aiofn_uring_tag(handle, AIOFN_URING_KIND_HANDLE_ACCEPT));
}

static aiofn_loop_status aiofn_uring_accept_start(
    void *data,
    aiofn_loop_proactor_handle_t *frontend,
    aiofn_loop_accept_callback_fn callback,
    void *callback_data
) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_handle_t *handle = frontend->backend_token;
    handle->accept_callback = callback;
    handle->accept_callback_data = callback_data;
    handle->accepting = 1;
    aiofn_uring_issue_accept(state, handle);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_uring_accept_stop(void *data, aiofn_loop_proactor_handle_t *frontend) {
    aiofn_uring_state_t *state = data;
    aiofn_uring_handle_t *handle = frontend->backend_token;
    handle->accepting = 0;

    struct io_uring_sqe *sqe = aiofn_uring_get_sqe(state);
    if (sqe != NULL) {
        handle->pending_sqes++;
        io_uring_prep_cancel64(sqe, aiofn_uring_tag(handle, AIOFN_URING_KIND_HANDLE_ACCEPT), 0);
        io_uring_sqe_set_data64(sqe, aiofn_uring_tag(NULL, AIOFN_URING_KIND_IGNORE));
    }
    return AIOFN_LOOP_OK;
}

static void aiofn_uring_handle_accept_completed(aiofn_uring_state_t *state, aiofn_uring_handle_t *handle, int res, unsigned flags) {
    if (res >= 0 && handle->accepting) {
        int new_fd = res;
        struct sockaddr_storage peer_addr;
        socklen_t peer_len = sizeof(peer_addr);
        if (getpeername(new_fd, (struct sockaddr *)&peer_addr, &peer_len) != 0) {
            aiofn_uring_set_error(state, "getpeername", -errno);
            close(new_fd);
            handle->accept_callback(handle->accept_callback_data, AIOFN_LOOP_ERROR, NULL, NULL, 0);
        } else {
            aiofn_uring_handle_t *accepted = calloc(1, sizeof(*accepted));
            if (accepted == NULL) {
                close(new_fd);
                handle->accept_callback(handle->accept_callback_data, AIOFN_LOOP_NO_MEMORY, NULL, NULL, 0);
            } else {
                accepted->fd = new_fd;
                accepted->kind = AIOFN_LOOP_PROACTOR_HANDLE_SOCKET;
                accepted->socktype = SOCK_STREAM;

                aiofn_loop_proactor_handle_t accepted_frontend;
                accepted_frontend.native_handle = new_fd;
                accepted_frontend.kind = AIOFN_LOOP_PROACTOR_HANDLE_SOCKET;
                accepted_frontend.socktype = SOCK_STREAM;
                accepted_frontend.backend_token = accepted;

                handle->accept_callback(handle->accept_callback_data, AIOFN_LOOP_OK, &accepted_frontend,
                                         (const struct sockaddr *)&peer_addr, (size_t)peer_len);
            }
        }
    } else if (res < 0 && res != -ECANCELED) {
        aiofn_uring_set_error(state, "accept", res);
        handle->accept_callback(handle->accept_callback_data, AIOFN_LOOP_ERROR, NULL, NULL, 0);
    }

    if ((flags & IORING_CQE_F_MORE) == 0) {
        handle->pending_sqes--;
        if (handle->accepting) {
            aiofn_uring_issue_accept(state, handle);
        } else {
            aiofn_uring_maybe_free_handle(handle);
        }
    }
}

/* ---- CQE dispatch ---- */

static void aiofn_uring_dispatch_cqe(aiofn_uring_state_t *state, struct io_uring_cqe *cqe) {
    __u64 ud = cqe->user_data;
    aiofn_uring_tag_kind_t kind = aiofn_uring_tag_kind(ud);
    void *ptr = aiofn_uring_tag_ptr(ud);

    switch (kind) {
    case AIOFN_URING_KIND_IGNORE:
        break;
    case AIOFN_URING_KIND_TIMER:
        aiofn_uring_timer_completed((aiofn_uring_timer_t *)ptr, cqe->res);
        break;
    case AIOFN_URING_KIND_SIGNAL:
        (void)ptr;
        aiofn_uring_signal_pipe_completed(state, cqe->res);
        break;
    case AIOFN_URING_KIND_FD_READ:
        aiofn_uring_fd_watch_completed(state, (aiofn_uring_fd_watch_t *)ptr, 1, cqe->res, cqe->flags);
        break;
    case AIOFN_URING_KIND_FD_WRITE:
        aiofn_uring_fd_watch_completed(state, (aiofn_uring_fd_watch_t *)ptr, 0, cqe->res, cqe->flags);
        break;
    case AIOFN_URING_KIND_HANDLE_READ: {
        aiofn_uring_handle_t *handle = (aiofn_uring_handle_t *)ptr;
        if (handle->recvfrom_callback != NULL) {
            aiofn_uring_handle_recv_completed(state, handle, cqe->res);
        } else {
            aiofn_uring_handle_read_completed(state, handle, cqe->res);
        }
        break;
    }
    case AIOFN_URING_KIND_HANDLE_WRITE:
        aiofn_uring_handle_write_completed(state, (aiofn_uring_handle_t *)ptr, cqe->res);
        break;
    case AIOFN_URING_KIND_HANDLE_CONNECT:
        aiofn_uring_handle_connect_completed(state, (aiofn_uring_handle_t *)ptr, cqe->res);
        break;
    case AIOFN_URING_KIND_HANDLE_ACCEPT:
        aiofn_uring_handle_accept_completed(state, (aiofn_uring_handle_t *)ptr, cqe->res, cqe->flags);
        break;
    }
}

/* ---- backend construction / destruction ---- */

static const char *aiofn_uring_last_error(void *data) {
    aiofn_uring_state_t *state = data;
    /* Never NULL: the frontend's _check_status() decodes this string on
       every non-OK status without a NULL check, so any gap here (a call
       site that returned an error without calling aiofn_uring_set_error())
       would otherwise crash the process instead of raising a Python
       exception. */
    return state->last_error[0] == '\0' ? "unknown uring backend error" : state->last_error;
}

aiofn_loop_backend_t *aiofn_uring_backend_new(void) {
    aiofn_uring_state_t *state = calloc(1, sizeof(*state));
    if (state == NULL) {
        return NULL;
    }
    state->signal_pipe_read = -1;
    state->signal_pipe_write = -1;

    /* Every backend operation runs on the loop thread only (see the ABI's
       threading contract), so the modern single-issuer flags are always
       safe here: no locking, no cross-CPU wakeups, task work only runs when
       we explicitly ask for it via io_uring_submit_and_wait_timeout(). */
    struct io_uring_params params;
    memset(&params, 0, sizeof(params));
    params.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_COOP_TASKRUN;

    int result = io_uring_queue_init_params(256, &state->ring, &params);
    if (result < 0) {
        free(state);
        return NULL;
    }

    state->backend.struct_size = AIOFN_LOOP_BACKEND_CURRENT_SIZE;
    state->backend.state = state;
    state->backend.name = "uring";
    state->backend.run = aiofn_uring_run;
    state->backend.stop = aiofn_uring_stop;
    state->backend.close = aiofn_uring_close;
    state->backend.now_ns = aiofn_uring_now_ns;
    state->backend.call_soon = aiofn_uring_call_soon;
    state->backend.call_at = aiofn_uring_call_at;
    state->backend.action_cancel = aiofn_uring_action_cancel;

    state->reactor.struct_size = AIOFN_REACTOR_BACKEND_CURRENT_SIZE;
    state->reactor.add_reader = aiofn_uring_add_reader;
    state->reactor.remove_reader = aiofn_uring_remove_reader;
    state->reactor.add_writer = aiofn_uring_add_writer;
    state->reactor.remove_writer = aiofn_uring_remove_writer;
    state->backend.reactor = &state->reactor;

    state->proactor.struct_size = AIOFN_PROACTOR_BACKEND_CURRENT_SIZE;
    state->proactor.wrap_handle = aiofn_uring_wrap_handle;
    state->proactor.unwrap_handle = aiofn_uring_unwrap_handle;
    state->proactor.connect = aiofn_uring_connect;
    state->proactor.write = aiofn_uring_write;
    state->proactor.sendto = aiofn_uring_sendto;
    state->proactor.cancel = aiofn_uring_cancel;
    state->proactor.sendfile = NULL; /* optional per the ABI; not implemented here either */
    state->proactor.accept_start = aiofn_uring_accept_start;
    state->proactor.accept_stop = aiofn_uring_accept_stop;
    state->proactor.read_start = aiofn_uring_read_start;
    state->proactor.read_stop = aiofn_uring_read_stop;
    state->proactor.recvfrom_start = aiofn_uring_recvfrom_start;
    state->proactor.recvfrom_stop = aiofn_uring_recvfrom_stop;
    state->backend.proactor = &state->proactor;

    state->backend.signal_watch = aiofn_uring_signal_watch;
    state->backend.signal_unwatch = aiofn_uring_signal_unwatch;
    state->backend.last_error = aiofn_uring_last_error;
    return &state->backend;
}

void aiofn_uring_backend_free(aiofn_loop_backend_t *backend) {
    aiofn_uring_state_t *state = backend->state;
    if (!state->closed) {
        aiofn_uring_close(state);
    }
    free(state);
}
