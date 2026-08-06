#include "libevent_backend.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <event2/event.h>

typedef struct aiofn_libevent_state {
    aiofn_loop_backend_t backend;
    aiofn_reactor_backend_t reactor;
    struct event_base *base;
    char last_error[256];
} aiofn_libevent_state_t;

static void aiofn_libevent_on_action(evutil_socket_t fd, short flags, void *data) {
    (void)fd;
    (void)flags;

    aiofn_loop_action_t *action = data;
    struct event *event = action->backend_token;
    action->backend_token = NULL;
    event_free(event);
    action->callback(action);
}

static void aiofn_libevent_on_fd(evutil_socket_t fd, short flags, void *data) {
    (void)fd;

    aiofn_loop_fd_watch_t *watch = data;
    uint32_t events = 0;
    if ((flags & EV_READ) != 0) {
        events |= AIOFN_LOOP_FD_READ;
    }
    if ((flags & EV_WRITE) != 0) {
        events |= AIOFN_LOOP_FD_WRITE;
    }
    watch->callback(watch->callback_data, events);
}

static void aiofn_libevent_on_signal(evutil_socket_t signum, short flags, void *data) {
    aiofn_loop_signal_watch_t *signal_watch = data;
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

    event_base_free(state->base);
    state->base = NULL;
}

static uint64_t aiofn_libevent_now_ns(void *data) {
    struct timespec now;
    (void)data;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}

static aiofn_loop_status aiofn_libevent_call_soon(void *data, aiofn_loop_action_t *action) {
    aiofn_libevent_state_t *state = data;
    struct event *event;

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

    if (event_del(event) != 0) {
        snprintf(state->last_error, sizeof(state->last_error), "event_del(action) failed");
        return AIOFN_LOOP_ERROR;
    }
    action->backend_token = NULL;
    event_free(event);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_fd_watch_direction(
    void *data,
    short events,
    aiofn_loop_fd_watch_t *watch,
    void **backend_token
) {
    aiofn_libevent_state_t *state = data;
    struct event *event = event_new(state->base, watch->fd, events | EV_PERSIST, aiofn_libevent_on_fd, watch);

    if (event == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }
    if (event_add(event, NULL) != 0) {
        event_free(event);
        snprintf(state->last_error, sizeof(state->last_error), "event_add(fd) failed");
        return AIOFN_LOOP_ERROR;
    }
    *backend_token = event;
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_add_reader(void *data, aiofn_loop_fd_watch_t *watch) {
    return aiofn_libevent_fd_watch_direction(data, EV_READ, watch, &watch->backend_read_token);
}

static aiofn_loop_status aiofn_libevent_fd_unwatch_direction(void *data, void **backend_token) {
    aiofn_libevent_state_t *state = data;
    struct event *event = *backend_token;

    if (event_del(event) != 0) {
        snprintf(state->last_error, sizeof(state->last_error), "event_del(fd) failed");
        return AIOFN_LOOP_ERROR;
    }
    *backend_token = NULL;
    event_free(event);
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_remove_reader(void *data, aiofn_loop_fd_watch_t *watch) {
    return aiofn_libevent_fd_unwatch_direction(data, &watch->backend_read_token);
}

static aiofn_loop_status aiofn_libevent_add_writer(void *data, aiofn_loop_fd_watch_t *watch) {
    return aiofn_libevent_fd_watch_direction(data, EV_WRITE, watch, &watch->backend_write_token);
}

static aiofn_loop_status aiofn_libevent_remove_writer(void *data, aiofn_loop_fd_watch_t *watch) {
    return aiofn_libevent_fd_unwatch_direction(data, &watch->backend_write_token);
}

static aiofn_loop_status aiofn_libevent_signal_watch(
    void *data,
    int signum,
    aiofn_loop_signal_watch_t *watch
) {
    aiofn_libevent_state_t *state = data;
    struct event *event;

    event = evsignal_new(state->base, signum, aiofn_libevent_on_signal, watch);
    if (event == NULL) {
        watch->backend_token = NULL;
        return AIOFN_LOOP_NO_MEMORY;
    }
    if (event_add(event, NULL) != 0) {
        event_free(event);
        watch->backend_token = NULL;
        snprintf(state->last_error, sizeof(state->last_error), "event_add(signal) failed");
        return AIOFN_LOOP_ERROR;
    }
    watch->backend_token = event;
    return AIOFN_LOOP_OK;
}

static aiofn_loop_status aiofn_libevent_signal_unwatch(void *data, aiofn_loop_signal_watch_t *watch) {
    aiofn_libevent_state_t *state = data;
    struct event *event = watch->backend_token;
    if (event_del(event) != 0) {
        snprintf(state->last_error, sizeof(state->last_error), "event_del(signal) failed");
        return AIOFN_LOOP_ERROR;
    }
    event_free(event);
    watch->backend_token = NULL;
    return AIOFN_LOOP_OK;
}

static const char *aiofn_libevent_last_error(void *data) {
    aiofn_libevent_state_t *state = data;
    return state->last_error[0] == '\0' ? NULL : state->last_error;
}

aiofn_loop_backend_t *aiofn_libevent_backend_new(void) {
    /* Use calloc because it also initializes memory to zero */
    aiofn_libevent_state_t *state = calloc(1, sizeof(*state));
    struct event_config *config = NULL;

    if (state == NULL) {
        return NULL;
    }
    config = event_config_new();
    if (config == NULL) {
        goto error;
    }
    if (event_config_set_flag(config, EVENT_BASE_FLAG_NOLOCK) != 0) {
        goto error;
    }
    state->base = event_base_new_with_config(config);
    if (state->base == NULL) {
        goto error;
    }
    event_config_free(config);
    config = NULL;

    state->backend.struct_size = AIOFN_LOOP_BACKEND_CURRENT_SIZE;
    state->backend.state = state;
    state->backend.name = "libevent";
    state->backend.run = aiofn_libevent_run;
    state->backend.stop = aiofn_libevent_stop;
    state->backend.close = aiofn_libevent_close;
    state->backend.now_ns = aiofn_libevent_now_ns;
    state->backend.call_soon = aiofn_libevent_call_soon;
    state->backend.call_at = aiofn_libevent_call_at;
    state->backend.action_cancel = aiofn_libevent_action_cancel;
    state->reactor.struct_size = AIOFN_REACTOR_BACKEND_CURRENT_SIZE;
    state->reactor.add_reader = aiofn_libevent_add_reader;
    state->reactor.remove_reader = aiofn_libevent_remove_reader;
    state->reactor.add_writer = aiofn_libevent_add_writer;
    state->reactor.remove_writer = aiofn_libevent_remove_writer;
    state->backend.reactor = &state->reactor;
    state->backend.last_error = aiofn_libevent_last_error;
    state->backend.signal_watch = aiofn_libevent_signal_watch;
    state->backend.signal_unwatch = aiofn_libevent_signal_unwatch;
    return &state->backend;

error:
    if (config != NULL) {
        event_config_free(config);
    }
    if (state->base != NULL) {
        event_base_free(state->base);
    }
    free(state);
    return NULL;
}

void aiofn_libevent_backend_free(aiofn_loop_backend_t *backend) {
    aiofn_libevent_state_t *state;
    state = backend->state;
    /* EventLoop construction may fail before LoopBase.close() is reached. */
    if (state->base != NULL) {
        event_base_free(state->base);
    }
    free(state);
}
