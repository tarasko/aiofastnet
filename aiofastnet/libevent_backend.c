#include "libevent_backend.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <event2/event.h>

typedef struct aiofn_libevent_watch {
    struct event *read_event;
    struct event *write_event;
    uint32_t events;
    aiofn_loop_fd_ready_fn callback;
    void *callback_data;
} aiofn_libevent_watch_t;

typedef struct aiofn_libevent_signal {
    struct event *event;
    aiofn_loop_signal_fn callback;
    void *callback_data;
} aiofn_libevent_signal_t;

typedef struct aiofn_libevent_state {
    aiofn_loop_backend_t backend;
    struct event_base *base;
    int closed;
    char last_error[256];
} aiofn_libevent_state_t;

static void aiofn_libevent_on_action(evutil_socket_t fd, short flags, void *data) {
    aiofn_loop_action_t *action = data;
    struct event *event = action->backend_token;
    (void)fd;
    (void)flags;
    action->backend_token = NULL;
    event_free(event);
    action->callback(action);
}

static void aiofn_libevent_on_fd(evutil_socket_t fd, short flags, void *data) {
    aiofn_libevent_watch_t *watch = data;
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

static void aiofn_libevent_on_signal(evutil_socket_t signum, short flags, void *data) {
    aiofn_libevent_signal_t *signal_watch = data;
    (void)flags;
    signal_watch->callback(signal_watch->callback_data, (int)signum);
}

static aiofn_loop_status aiofn_libevent_run(void *data) {
    aiofn_libevent_state_t *state = data;
    int result = event_base_loop(state->base, EVLOOP_NO_EXIT_ON_EMPTY);
    if (result < 0) {
        snprintf(state->last_error, sizeof(state->last_error), "event_base_loop failed");
        return AIOFN_LOOP_ERROR;
    }
    return AIOFN_LOOP_OK;
}

static void aiofn_libevent_stop(void *data) {
    aiofn_libevent_state_t *state = data;
    event_base_loopbreak(state->base);
}

static void aiofn_libevent_close(void *data) {
    aiofn_libevent_state_t *state = data;

    if (state->closed) {
        return;
    }
    state->closed = 1;
}

static uint64_t aiofn_libevent_now_ns(void *data) {
    struct timespec now;
    (void)data;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}

static aiofn_loop_status aiofn_libevent_schedule(void *data, aiofn_loop_action_t *action) {
    aiofn_libevent_state_t *state = data;
    struct event *event;

    if (state->closed) {
        snprintf(state->last_error, sizeof(state->last_error), "backend is closed");
        return AIOFN_LOOP_ERROR;
    }
    event = event_new(state->base, -1, 0, aiofn_libevent_on_action, action);
    if (event == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }
    action->backend_token = event;
    event_active(event, EV_TIMEOUT, 0);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_call_at(
    void *data,
    aiofn_loop_action_t *action,
    uint64_t deadline_ns
) {
    aiofn_libevent_state_t *state = data;
    struct event *event;
    struct timeval delay;
    uint64_t now_ns;
    uint64_t delay_ns;

    if (state->closed) {
        snprintf(state->last_error, sizeof(state->last_error), "backend is closed");
        return AIOFN_LOOP_ERROR;
    }
    event = evtimer_new(state->base, aiofn_libevent_on_action, action);
    if (event == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }

    now_ns = aiofn_libevent_now_ns(state);
    delay_ns = deadline_ns > now_ns ? deadline_ns - now_ns : 0;
    delay.tv_sec = (time_t)(delay_ns / UINT64_C(1000000000));
    delay.tv_usec = (suseconds_t)((delay_ns % UINT64_C(1000000000)) / UINT64_C(1000));
    if (event_add(event, &delay) != 0) {
        event_free(event);
        snprintf(state->last_error, sizeof(state->last_error), "event_add(timer) failed");
        return AIOFN_LOOP_ERROR;
    }
    action->backend_token = event;
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_action_cancel(void *data, aiofn_loop_action_t *action) {
    aiofn_libevent_state_t *state = data;
    struct event *event = action->backend_token;

    if (event == NULL) {
        return AIOFN_LOOP_INVALID_ARGUMENT;
    }
    if (event_del(event) != 0) {
        snprintf(state->last_error, sizeof(state->last_error), "event_del(action) failed");
        return AIOFN_LOOP_ERROR;
    }
    action->backend_token = NULL;
    event_free(event);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_fd_watch(
    void *data,
    int fd,
    uint32_t events,
    aiofn_loop_fd_ready_fn callback,
    void *callback_data,
    aiofn_loop_fd_watch_t **watch_out
) {
    aiofn_libevent_state_t *state = data;
    aiofn_libevent_watch_t *watch;
    *watch_out = NULL;
    watch = calloc(1, sizeof(*watch));
    if (watch == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }
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
    *watch_out = (aiofn_loop_fd_watch_t *)watch;
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_fd_update(void *data, aiofn_loop_fd_watch_t *opaque_watch, uint32_t events) {
    aiofn_libevent_state_t *state = data;
    aiofn_libevent_watch_t *watch = (aiofn_libevent_watch_t *)opaque_watch;

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

static aiofn_loop_status aiofn_libevent_fd_unwatch(void *data, aiofn_loop_fd_watch_t *opaque_watch) {
    aiofn_libevent_watch_t *watch = (aiofn_libevent_watch_t *)opaque_watch;
    (void)data;
    event_del(watch->read_event);
    event_del(watch->write_event);
    event_free(watch->read_event);
    event_free(watch->write_event);
    free(watch);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_signal_watch(
    void *data,
    int signum,
    aiofn_loop_signal_fn callback,
    void *callback_data,
    aiofn_loop_signal_watch_t **watch_out
) {
    aiofn_libevent_state_t *state = data;
    aiofn_libevent_signal_t *signal_watch;

    *watch_out = NULL;
    if (signum <= 0) {
        return AIOFN_LOOP_INVALID_ARGUMENT;
    }
    signal_watch = calloc(1, sizeof(*signal_watch));
    if (signal_watch == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }
    signal_watch->callback = callback;
    signal_watch->callback_data = callback_data;
    signal_watch->event = evsignal_new(state->base, signum, aiofn_libevent_on_signal, signal_watch);
    if (signal_watch->event == NULL) {
        free(signal_watch);
        return AIOFN_LOOP_NO_MEMORY;
    }
    if (event_add(signal_watch->event, NULL) != 0) {
        event_free(signal_watch->event);
        free(signal_watch);
        snprintf(state->last_error, sizeof(state->last_error), "event_add(signal) failed");
        return AIOFN_LOOP_ERROR;
    }
    *watch_out = (aiofn_loop_signal_watch_t *)signal_watch;
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_signal_unwatch(void *data, aiofn_loop_signal_watch_t *opaque_watch) {
    aiofn_libevent_signal_t *signal_watch = (aiofn_libevent_signal_t *)opaque_watch;
    (void)data;
    event_del(signal_watch->event);
    event_free(signal_watch->event);
    free(signal_watch);
    return AIOFN_LOOP_OK;
}

static const char *aiofn_libevent_last_error(void *data) {
    aiofn_libevent_state_t *state = data;
    return state->last_error[0] == '\0' ? NULL : state->last_error;
}

aiofn_loop_backend_t *aiofn_libevent_backend_new(void) {
    aiofn_libevent_state_t *state = calloc(1, sizeof(*state));
    if (state == NULL) {
        return NULL;
    }
    state->base = event_base_new();
    if (state->base == NULL) {
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
    state->backend.call_at = aiofn_libevent_call_at;
    state->backend.action_cancel = aiofn_libevent_action_cancel;
    state->backend.fd_watch = aiofn_libevent_fd_watch;
    state->backend.fd_update = aiofn_libevent_fd_update;
    state->backend.fd_unwatch = aiofn_libevent_fd_unwatch;
    state->backend.last_error = aiofn_libevent_last_error;
    state->backend.signal_watch = aiofn_libevent_signal_watch;
    state->backend.signal_unwatch = aiofn_libevent_signal_unwatch;
    return &state->backend;

error:
    if (state->base != NULL) {
        event_base_free(state->base);
    }
    free(state);
    return NULL;
}

void aiofn_libevent_backend_free(aiofn_loop_backend_t *backend) {
    aiofn_libevent_state_t *state;
    if (backend == NULL) {
        return;
    }
    state = backend->state;
    if (!state->closed) {
        aiofn_libevent_close(state);
    }
    event_base_free(state->base);
    free(state);
}
