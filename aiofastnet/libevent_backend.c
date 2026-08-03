#include "libevent_backend.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <event2/event.h>

typedef struct aiofn_libevent_state aiofn_libevent_state;

typedef struct aiofn_libevent_call {
    aiofn_loop_completion_fn callback;
    void *callback_data;
    struct aiofn_libevent_call *next;
} aiofn_libevent_call;

typedef struct aiofn_libevent_timer {
    aiofn_libevent_state *state;
    struct event *event;
    aiofn_loop_completion_fn callback;
    void *callback_data;
    struct aiofn_libevent_timer *previous;
    struct aiofn_libevent_timer *next;
} aiofn_libevent_timer;

typedef struct aiofn_libevent_watch {
    aiofn_libevent_state *state;
    struct event *read_event;
    struct event *write_event;
    uint32_t events;
    aiofn_loop_fd_ready_fn callback;
    void *callback_data;
    struct aiofn_libevent_watch *previous;
    struct aiofn_libevent_watch *next;
} aiofn_libevent_watch;

struct aiofn_libevent_state {
    aiofn_loop_backend backend;
    struct event_base *base;
    struct event *wakeup_event;
    int wakeup_reader;
    int wakeup_writer;
    pthread_mutex_t calls_lock;
    aiofn_libevent_call *calls_head;
    aiofn_libevent_call *calls_tail;
    aiofn_libevent_timer *timers;
    aiofn_libevent_watch *watches;
    int closed;
    char last_error[256];
};

static void aiofn_libevent_timer_unlink(aiofn_libevent_timer *timer) {
    if (timer->previous != NULL) {
        timer->previous->next = timer->next;
    } else {
        timer->state->timers = timer->next;
    }
    if (timer->next != NULL) {
        timer->next->previous = timer->previous;
    }
}

static void aiofn_libevent_watch_unlink(aiofn_libevent_watch *watch) {
    if (watch->previous != NULL) {
        watch->previous->next = watch->next;
    } else {
        watch->state->watches = watch->next;
    }
    if (watch->next != NULL) {
        watch->next->previous = watch->previous;
    }
}

static void aiofn_libevent_wake(aiofn_libevent_state *state) {
    const unsigned char byte = 0;
    ssize_t result;
    do {
        result = write(state->wakeup_writer, &byte, sizeof(byte));
    } while (result < 0 && errno == EINTR);
    /* EAGAIN means an existing unread byte already guarantees a wakeup. */
}

static void aiofn_libevent_on_wakeup(evutil_socket_t fd, short flags, void *data) {
    aiofn_libevent_state *state = data;
    aiofn_libevent_call *call;
    aiofn_libevent_call *calls;
    unsigned char buffer[256];
    ssize_t result;
    (void)flags;

    do {
        result = read(fd, buffer, sizeof(buffer));
    } while (result > 0 || (result < 0 && errno == EINTR));

    pthread_mutex_lock(&state->calls_lock);
    calls = state->calls_head;
    state->calls_head = NULL;
    state->calls_tail = NULL;
    pthread_mutex_unlock(&state->calls_lock);

    while (calls != NULL) {
        call = calls;
        calls = calls->next;
        call->callback(call->callback_data, AIOFN_LOOP_CALLBACK_SUCCESS);
        free(call);
    }
}

static void aiofn_libevent_on_timer(evutil_socket_t fd, short flags, void *data) {
    aiofn_libevent_timer *timer = data;
    (void)fd;
    (void)flags;
    aiofn_libevent_timer_unlink(timer);
    event_free(timer->event);
    timer->callback(timer->callback_data, AIOFN_LOOP_CALLBACK_SUCCESS);
    free(timer);
}

static void aiofn_libevent_on_fd(evutil_socket_t fd, short flags, void *data) {
    aiofn_libevent_watch *watch = data;
    uint32_t events = 0;
    (void)fd;
    if ((flags & EV_READ) != 0) {
        events |= AIOFN_LOOP_FD_READ;
    }
    if ((flags & EV_WRITE) != 0) {
        events |= AIOFN_LOOP_FD_WRITE;
    }
    watch->callback(watch->callback_data, events);
}

static aiofn_loop_status aiofn_libevent_run(void *data) {
    aiofn_libevent_state *state = data;
    int result = event_base_loop(state->base, EVLOOP_NO_EXIT_ON_EMPTY);
    if (result < 0) {
        snprintf(state->last_error, sizeof(state->last_error), "event_base_loop failed");
        return AIOFN_LOOP_ERROR;
    }
    return AIOFN_LOOP_OK;
}

static void aiofn_libevent_stop(void *data) {
    aiofn_libevent_state *state = data;
    event_base_loopbreak(state->base);
}

static void aiofn_libevent_close(void *data) {
    aiofn_libevent_state *state = data;
    aiofn_libevent_call *call;
    aiofn_libevent_timer *timer;
    aiofn_libevent_watch *watch;

    if (state->closed) {
        return;
    }
    state->closed = 1;
    event_del(state->wakeup_event);

    pthread_mutex_lock(&state->calls_lock);
    call = state->calls_head;
    state->calls_head = NULL;
    state->calls_tail = NULL;
    pthread_mutex_unlock(&state->calls_lock);
    while (call != NULL) {
        aiofn_libevent_call *next = call->next;
        call->callback(call->callback_data, AIOFN_LOOP_CALLBACK_CANCELLED);
        free(call);
        call = next;
    }

    while (state->timers != NULL) {
        timer = state->timers;
        aiofn_libevent_timer_unlink(timer);
        event_del(timer->event);
        event_free(timer->event);
        timer->callback(timer->callback_data, AIOFN_LOOP_CALLBACK_CANCELLED);
        free(timer);
    }
    while (state->watches != NULL) {
        watch = state->watches;
        aiofn_libevent_watch_unlink(watch);
        event_del(watch->read_event);
        event_del(watch->write_event);
        event_free(watch->read_event);
        event_free(watch->write_event);
        free(watch);
    }
}

static uint64_t aiofn_libevent_now_ns(void *data) {
    struct timespec now;
    (void)data;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}

static aiofn_loop_status aiofn_libevent_schedule(void *data, aiofn_loop_completion_fn callback, void *callback_data) {
    aiofn_libevent_state *state = data;
    aiofn_libevent_call *call = malloc(sizeof(*call));
    if (call == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }
    call->callback = callback;
    call->callback_data = callback_data;
    call->next = NULL;

    pthread_mutex_lock(&state->calls_lock);
    if (state->closed) {
        pthread_mutex_unlock(&state->calls_lock);
        free(call);
        return AIOFN_LOOP_ERROR;
    }
    if (state->calls_tail == NULL) {
        state->calls_head = call;
    } else {
        state->calls_tail->next = call;
    }
    state->calls_tail = call;
    pthread_mutex_unlock(&state->calls_lock);
    aiofn_libevent_wake(state);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_call_at(
    void *data,
    aiofn_loop_completion_fn callback,
    void *callback_data,
    uint64_t deadline_ns,
    aiofn_loop_timer **timer_out
) {
    aiofn_libevent_state *state = data;
    aiofn_libevent_timer *timer;
    struct timeval delay;
    uint64_t now_ns;
    uint64_t delay_ns;

    *timer_out = NULL;
    timer = calloc(1, sizeof(*timer));
    if (timer == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }
    timer->state = state;
    timer->callback = callback;
    timer->callback_data = callback_data;
    timer->event = evtimer_new(state->base, aiofn_libevent_on_timer, timer);
    if (timer->event == NULL) {
        free(timer);
        return AIOFN_LOOP_NO_MEMORY;
    }

    now_ns = aiofn_libevent_now_ns(state);
    delay_ns = deadline_ns > now_ns ? deadline_ns - now_ns : 0;
    delay.tv_sec = (time_t)(delay_ns / UINT64_C(1000000000));
    delay.tv_usec = (suseconds_t)((delay_ns % UINT64_C(1000000000)) / UINT64_C(1000));
    if (event_add(timer->event, &delay) != 0) {
        event_free(timer->event);
        free(timer);
        snprintf(state->last_error, sizeof(state->last_error), "event_add(timer) failed");
        return AIOFN_LOOP_ERROR;
    }
    timer->next = state->timers;
    if (state->timers != NULL) {
        state->timers->previous = timer;
    }
    state->timers = timer;
    *timer_out = (aiofn_loop_timer *)timer;
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_timer_cancel(void *data, aiofn_loop_timer *opaque_timer) {
    aiofn_libevent_timer *timer = (aiofn_libevent_timer *)opaque_timer;
    (void)data;
    aiofn_libevent_timer_unlink(timer);
    event_del(timer->event);
    event_free(timer->event);
    timer->callback(timer->callback_data, AIOFN_LOOP_CALLBACK_CANCELLED);
    free(timer);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_fd_watch(
    void *data,
    int fd,
    uint32_t events,
    aiofn_loop_fd_ready_fn callback,
    void *callback_data,
    aiofn_loop_fd_watch **watch_out
) {
    aiofn_libevent_state *state = data;
    aiofn_libevent_watch *watch;
    *watch_out = NULL;
    watch = calloc(1, sizeof(*watch));
    if (watch == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }
    watch->state = state;
    watch->events = events;
    watch->callback = callback;
    watch->callback_data = callback_data;
    watch->read_event = event_new(state->base, fd, EV_READ | EV_PERSIST, aiofn_libevent_on_fd, watch);
    watch->write_event = event_new(state->base, fd, EV_WRITE | EV_PERSIST, aiofn_libevent_on_fd, watch);
    if (watch->read_event == NULL || watch->write_event == NULL) {
        if (watch->read_event != NULL) {
            event_free(watch->read_event);
        }
        if (watch->write_event != NULL) {
            event_free(watch->write_event);
        }
        free(watch);
        return AIOFN_LOOP_NO_MEMORY;
    }
    if (((events & AIOFN_LOOP_FD_READ) != 0 && event_add(watch->read_event, NULL) != 0) ||
            ((events & AIOFN_LOOP_FD_WRITE) != 0 && event_add(watch->write_event, NULL) != 0)) {
        event_del(watch->read_event);
        event_del(watch->write_event);
        event_free(watch->read_event);
        event_free(watch->write_event);
        free(watch);
        snprintf(state->last_error, sizeof(state->last_error), "event_add(fd) failed");
        return AIOFN_LOOP_ERROR;
    }
    watch->next = state->watches;
    if (state->watches != NULL) {
        state->watches->previous = watch;
    }
    state->watches = watch;
    *watch_out = (aiofn_loop_fd_watch *)watch;
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_fd_update(void *data, aiofn_loop_fd_watch *opaque_watch, uint32_t events) {
    aiofn_libevent_state *state = data;
    aiofn_libevent_watch *watch = (aiofn_libevent_watch *)opaque_watch;

    /* Add new interests first so changing direction never removes the fd completely. */
    if ((events & AIOFN_LOOP_FD_READ) != 0 && (watch->events & AIOFN_LOOP_FD_READ) == 0) {
        if (event_add(watch->read_event, NULL) != 0) {
            snprintf(state->last_error, sizeof(state->last_error), "event_add(read fd) failed");
            return AIOFN_LOOP_ERROR;
        }
        watch->events |= AIOFN_LOOP_FD_READ;
    }
    if ((events & AIOFN_LOOP_FD_WRITE) != 0 && (watch->events & AIOFN_LOOP_FD_WRITE) == 0) {
        if (event_add(watch->write_event, NULL) != 0) {
            snprintf(state->last_error, sizeof(state->last_error), "event_add(write fd) failed");
            return AIOFN_LOOP_ERROR;
        }
        watch->events |= AIOFN_LOOP_FD_WRITE;
    }
    if ((events & AIOFN_LOOP_FD_READ) == 0 && (watch->events & AIOFN_LOOP_FD_READ) != 0) {
        if (event_del(watch->read_event) != 0) {
            snprintf(state->last_error, sizeof(state->last_error), "event_del(read fd) failed");
            return AIOFN_LOOP_ERROR;
        }
        watch->events &= ~AIOFN_LOOP_FD_READ;
    }
    if ((events & AIOFN_LOOP_FD_WRITE) == 0 && (watch->events & AIOFN_LOOP_FD_WRITE) != 0) {
        if (event_del(watch->write_event) != 0) {
            snprintf(state->last_error, sizeof(state->last_error), "event_del(write fd) failed");
            return AIOFN_LOOP_ERROR;
        }
        watch->events &= ~AIOFN_LOOP_FD_WRITE;
    }
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_fd_unwatch(void *data, aiofn_loop_fd_watch *opaque_watch) {
    aiofn_libevent_watch *watch = (aiofn_libevent_watch *)opaque_watch;
    (void)data;
    aiofn_libevent_watch_unlink(watch);
    event_del(watch->read_event);
    event_del(watch->write_event);
    event_free(watch->read_event);
    event_free(watch->write_event);
    free(watch);
    return AIOFN_LOOP_OK;
}

static const char *aiofn_libevent_last_error(void *data) {
    aiofn_libevent_state *state = data;
    return state->last_error[0] == '\0' ? NULL : state->last_error;
}

static int aiofn_libevent_make_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        return -1;
    }
    flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
        return -1;
    }
    return 0;
}

aiofn_loop_backend *aiofn_libevent_backend_new(void) {
    aiofn_libevent_state *state = calloc(1, sizeof(*state));
    int wakeup[2] = {-1, -1};
    if (state == NULL) {
        return NULL;
    }
    state->wakeup_reader = -1;
    state->wakeup_writer = -1;
    if (pthread_mutex_init(&state->calls_lock, NULL) != 0) {
        free(state);
        return NULL;
    }
    state->base = event_base_new();
    if (state->base == NULL || socketpair(AF_UNIX, SOCK_STREAM, 0, wakeup) != 0 || aiofn_libevent_make_nonblocking(wakeup[0]) != 0 ||
            aiofn_libevent_make_nonblocking(wakeup[1]) != 0) {
        goto error;
    }
    state->wakeup_reader = wakeup[0];
    state->wakeup_writer = wakeup[1];
    state->wakeup_event = event_new(state->base, state->wakeup_reader, EV_READ | EV_PERSIST, aiofn_libevent_on_wakeup, state);
    if (state->wakeup_event == NULL || event_add(state->wakeup_event, NULL) != 0) {
        goto error;
    }

    state->backend.struct_size = AIOFN_LOOP_BACKEND_CURRENT_SIZE;
    state->backend.state = state;
    state->backend.name = "libevent";
    state->backend.run = aiofn_libevent_run;
    state->backend.stop = aiofn_libevent_stop;
    state->backend.close = aiofn_libevent_close;
    state->backend.now_ns = aiofn_libevent_now_ns;
    state->backend.call_soon = aiofn_libevent_schedule;
    state->backend.call_soon_threadsafe = aiofn_libevent_schedule;
    state->backend.call_at = aiofn_libevent_call_at;
    state->backend.timer_cancel = aiofn_libevent_timer_cancel;
    state->backend.fd_watch = aiofn_libevent_fd_watch;
    state->backend.fd_update = aiofn_libevent_fd_update;
    state->backend.fd_unwatch = aiofn_libevent_fd_unwatch;
    state->backend.last_error = aiofn_libevent_last_error;
    return &state->backend;

error:
    if (state->wakeup_event != NULL) {
        event_free(state->wakeup_event);
    }
    if (wakeup[0] >= 0) {
        close(wakeup[0]);
    }
    if (wakeup[1] >= 0) {
        close(wakeup[1]);
    }
    if (state->base != NULL) {
        event_base_free(state->base);
    }
    pthread_mutex_destroy(&state->calls_lock);
    free(state);
    return NULL;
}

void aiofn_libevent_backend_free(aiofn_loop_backend *backend) {
    aiofn_libevent_state *state;
    if (backend == NULL) {
        return;
    }
    state = backend->state;
    if (!state->closed) {
        aiofn_libevent_close(state);
    }
    event_free(state->wakeup_event);
    close(state->wakeup_reader);
    close(state->wakeup_writer);
    event_base_free(state->base);
    pthread_mutex_destroy(&state->calls_lock);
    free(state);
}
