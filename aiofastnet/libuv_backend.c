#include "libuv_backend.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <assert.h>

#include <uv.h>

typedef struct aiofn_libuv_socket aiofn_libuv_socket_t;

struct aiofn_libuv_socket {
    // handle must remain first: callbacks cast libuv handles back to this type.
    uv_tcp_t handle;
    aiofn_loop_proactor_socket_t *frontend;

    aiofn_loop_proactor_op_t *read_op;
    void *read_buffer;
    size_t read_buffer_len;

    uv_write_t write_request;
    aiofn_loop_proactor_op_t *write_op;
    size_t write_transferred;

    uv_connect_t connect_request;
    aiofn_loop_proactor_op_t *connect_op;
    struct sockaddr_storage connect_address;
};

typedef struct aiofn_libuv_state {
    aiofn_loop_backend_t backend;
    aiofn_reactor_backend_t reactor;
    aiofn_proactor_backend_t proactor;

    uv_loop_t loop;
    int closed;
    char last_error[256];
} aiofn_libuv_state_t;

static void aiofn_libuv_set_error(aiofn_libuv_state_t *state, const char *operation, int error) {
    snprintf(state->last_error, sizeof(state->last_error), "%s: %s", operation, uv_strerror(error));
}


static void aiofn_libuv_free_handle(uv_handle_t *handle) {
    // Casting here just to highlight that we free aiofn_libuv_socket_t
    // It has the same address as handle.
    free((aiofn_libuv_socket_t *)handle);
}

static void aiofn_libuv_complete(
    aiofn_loop_proactor_op_t *op,
    aiofn_loop_status status,
    size_t transferred
) {
    op->backend_token = NULL;
    op->status = status;
    op->transferred = transferred;
    op->callback(op);
}


static void aiofn_libuv_on_action(uv_timer_t *timer) {
    aiofn_loop_action_t *action = timer->data;
    timer->data = NULL;
    action->backend_token = NULL;
    uv_timer_stop(timer);
    uv_close((uv_handle_t *)timer, aiofn_libuv_free_handle);
    action->callback(action);
}


static void aiofn_libuv_on_fd(uv_poll_t *poll, int status, int events) {
    aiofn_loop_fd_watch_t *watch = poll->data;
    uint32_t ready = 0;
    if (status < 0) {
        if (watch->backend_read_token == poll) {
            ready |= AIOFN_LOOP_FD_READ;
        }
        if (watch->backend_write_token == poll) {
            ready |= AIOFN_LOOP_FD_WRITE;
        }
    }
    if ((events & UV_READABLE) != 0 || (events & UV_DISCONNECT) != 0) {
        ready |= AIOFN_LOOP_FD_READ;
    }
    if ((events & UV_WRITABLE) != 0) {
        ready |= AIOFN_LOOP_FD_WRITE;
    }
    if (ready != 0) {
        watch->callback(watch->callback_data, ready);
    }
}


static void aiofn_libuv_on_signal(uv_signal_t *signal, int signum) {
    aiofn_loop_signal_watch_t *watch = signal->data;
    watch->callback(watch->callback_data, signum);
}


static aiofn_loop_status aiofn_libuv_run(void *data) {
    aiofn_libuv_state_t *state = data;
    uv_run(&state->loop, UV_RUN_DEFAULT);
    return AIOFN_LOOP_OK;
}


static void aiofn_libuv_stop(void *data) {
    aiofn_libuv_state_t *state = data;
    uv_stop(&state->loop);
}


static void aiofn_libuv_close(void *data) {
    aiofn_libuv_state_t *state = data;
    /* uv_close() defers handle destruction until the loop dispatches close callbacks. */
    uv_run(&state->loop, UV_RUN_DEFAULT);
    int result = uv_loop_close(&state->loop);
    if (result != 0) {
        aiofn_libuv_set_error(state, "uv_loop_close", result);
    } else {
        state->closed = 1;
    }
}


static uint64_t aiofn_libuv_now_ns(void *data) {
    (void)data;
    return uv_hrtime();
}


static aiofn_loop_status aiofn_libuv_schedule(
    aiofn_libuv_state_t *state,
    aiofn_loop_action_t *action,
    uint64_t delay_ns
) {
    uv_timer_t *timer = malloc(sizeof(*timer));
    int result;
    if (timer == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }

    result = uv_timer_init(&state->loop, timer);
    if (result != 0) {
        aiofn_libuv_set_error(state, "uv_timer_init", result);
        free(timer);
        return AIOFN_LOOP_ERROR;
    }

    timer->data = action;
    action->backend_token = timer;

    result = uv_timer_start(timer, aiofn_libuv_on_action, (uint64_t)((delay_ns + 999999) / 1000000), 0);
    if (result != 0) {
        aiofn_libuv_set_error(state, "uv_timer_start", result);
        action->backend_token = NULL;
        uv_close((uv_handle_t *)timer, aiofn_libuv_free_handle);
        return AIOFN_LOOP_ERROR;
    }
    return AIOFN_LOOP_OK;
}


static aiofn_loop_status aiofn_libuv_call_soon(void *data, aiofn_loop_action_t *action) {
    return aiofn_libuv_schedule(data, action, 0);
}


static aiofn_loop_status aiofn_libuv_call_at(void *data, aiofn_loop_action_t *action, uint64_t deadline_ns) {
    uint64_t now = aiofn_libuv_now_ns(data);
    return aiofn_libuv_schedule(data, action, deadline_ns > now ? deadline_ns - now : 0);
}


static aiofn_loop_status aiofn_libuv_action_cancel(void *data, aiofn_loop_action_t *action) {
    aiofn_libuv_state_t *state = data;
    uv_timer_t *timer = action->backend_token;
    int result = uv_timer_stop(timer);
    if (result != 0 && result != UV_EINVAL) {
        aiofn_libuv_set_error(state, "uv_timer_stop", result);
        return AIOFN_LOOP_ERROR;
    }
    action->backend_token = NULL;
    timer->data = NULL;
    uv_close((uv_handle_t *)timer, aiofn_libuv_free_handle);
    return AIOFN_LOOP_OK;
}


/* Proactor socket wrapping and operation callbacks. */
static aiofn_loop_status aiofn_libuv_wrap_socket(void *data, aiofn_loop_proactor_socket_t *frontend) {
    aiofn_libuv_state_t *state = data;
    aiofn_libuv_socket_t *socket = calloc(1, sizeof(*socket));
    int native_fd;
    int result;

    if (socket == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }

    // socket duplication is necessary because libuv doesn't have a function
    // to detach socket from uv_tcp_t. Only uv_close, which is closing socket.
    native_fd = dup(frontend->fd);
    if (native_fd < 0) {
        aiofn_libuv_set_error(state, "dup", -errno);
        free(socket);
        return AIOFN_LOOP_ERROR;
    }

    result = uv_tcp_init(&state->loop, &socket->handle);
    if (result < 0) {
        aiofn_libuv_set_error(state, "uv_tcp_init", result);
        close(native_fd);
        free(socket);
        return AIOFN_LOOP_ERROR;
    }

    result = uv_tcp_open(&socket->handle, native_fd);
    if (result < 0) {
        aiofn_libuv_set_error(state, "uv_tcp_open", result);
        close(native_fd);
        // aiofn_libuv_free_handle will free socket object
        uv_close((uv_handle_t *)&socket->handle, aiofn_libuv_free_handle);
        return AIOFN_LOOP_ERROR;
    }

    socket->frontend = frontend;
    frontend->backend_token = socket;
    return AIOFN_LOOP_OK;

}


static aiofn_loop_status aiofn_libuv_unwrap_socket(void *data, aiofn_loop_proactor_socket_t *frontend) {
    (void)data;

    aiofn_libuv_socket_t *socket = frontend->backend_token;
    frontend->backend_token = NULL;
    socket->frontend = NULL;
    uv_close((uv_handle_t *)&socket->handle, aiofn_libuv_free_handle);
    return AIOFN_LOOP_OK;
}


static void aiofn_libuv_alloc_read(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buffer) {
    (void)suggested_size;

    aiofn_libuv_socket_t *socket = (aiofn_libuv_socket_t *)handle;
    buffer->base = socket->read_buffer;
    buffer->len = socket->read_buffer_len;
}


static void aiofn_libuv_on_read(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buffer) {
    aiofn_libuv_socket_t *socket = (aiofn_libuv_socket_t *)stream;
    aiofn_loop_proactor_op_t *op = socket->read_op;
    (void)buffer;

    assert(op != NULL);

    // From libuv docs:
    // nread might be 0, which does not indicate an error or EOF.
    // This is equivalent to EAGAIN or EWOULDBLOCK under read(2).
    if (nread == 0) {
        return;
    }

    socket->read_op = NULL;

    if (nread > 0) {
        aiofn_libuv_complete(op, AIOFN_LOOP_OK, (size_t)nread);
        if (socket->read_op != NULL) {
            return;
        }
    }

    uv_read_stop(stream);

    if (nread == UV_EOF) {
        aiofn_libuv_complete(op, AIOFN_LOOP_OK, 0);
        return;
    }

    if (nread < 0) {
        aiofn_libuv_set_error((aiofn_libuv_state_t *)stream->loop->data, "uv_read", (int)nread);
        aiofn_libuv_complete(op, AIOFN_LOOP_ERROR, 0);
    }
}


static aiofn_loop_status aiofn_libuv_read(void *data, aiofn_loop_proactor_socket_t *frontend,
                                          aiofn_loop_proactor_op_t *op, void *buffer, size_t buffer_len) {
    aiofn_libuv_socket_t *socket = frontend->backend_token;
    int result;

    assert(socket->read_op == NULL);

    socket->read_op = op;
    socket->read_buffer = buffer;
    socket->read_buffer_len = buffer_len;
    op->backend_token = socket;

    result = uv_read_start((uv_stream_t *)&socket->handle, aiofn_libuv_alloc_read, aiofn_libuv_on_read);
    if (result != 0) {
        socket->read_op = NULL;
        op->backend_token = NULL;
        aiofn_libuv_set_error((aiofn_libuv_state_t *)data, "uv_read_start", result);
        return AIOFN_LOOP_ERROR;
    }
    return AIOFN_LOOP_OK;
}


static void aiofn_libuv_on_write(uv_write_t *request, int status) {
    aiofn_libuv_socket_t *socket = request->data;
    aiofn_loop_proactor_op_t *op = socket->write_op;
    socket->write_op = NULL;
    if (status == 0) {
        aiofn_libuv_complete(op, AIOFN_LOOP_OK, socket->write_transferred);
    } else {
        aiofn_libuv_set_error((aiofn_libuv_state_t *)socket->handle.loop->data, "uv_write", status);
        aiofn_libuv_complete(op, AIOFN_LOOP_ERROR, 0);
    }
}


static aiofn_loop_status aiofn_libuv_write(void *data, aiofn_loop_proactor_socket_t *frontend,
                                           aiofn_loop_proactor_op_t *op,
                                           const aiofn_loop_buffer_t *buffers, size_t buffer_count) {
    aiofn_libuv_socket_t *socket = frontend->backend_token;
    int result;

    socket->write_transferred = 0;
    for (size_t index = 0; index < buffer_count; index++) {
        socket->write_transferred += buffers[index].iov_len;
    }

    socket->write_op = op;
    op->backend_token = socket;
    socket->write_request.data = socket;

    result = uv_write(&socket->write_request, (uv_stream_t *)&socket->handle, (const uv_buf_t *)buffers,
                      (unsigned)buffer_count, aiofn_libuv_on_write);
    if (result != 0) {
        socket->write_op = NULL;
        op->backend_token = NULL;
        aiofn_libuv_set_error((aiofn_libuv_state_t *)data, "uv_write", result);
        return AIOFN_LOOP_ERROR;
    }
    return AIOFN_LOOP_OK;
}


static void aiofn_libuv_on_connect(uv_connect_t *request, int status) {
    aiofn_libuv_socket_t *socket = request->data;
    aiofn_loop_proactor_op_t *op = socket->connect_op;
    socket->connect_op = NULL;
    if (status == 0) {
        aiofn_libuv_complete(op, AIOFN_LOOP_OK, 0);
    } else {
        aiofn_libuv_set_error((aiofn_libuv_state_t *)socket->handle.loop->data, "uv_connect", status);
        aiofn_libuv_complete(op, AIOFN_LOOP_ERROR, 0);
    }
}


static aiofn_loop_status aiofn_libuv_connect(
    void *data,
    aiofn_loop_proactor_socket_t *frontend,
    aiofn_loop_proactor_op_t *op,
    const void *address,
    size_t address_len
) {
    aiofn_libuv_socket_t *socket = frontend->backend_token;
    int result;
    if (address_len > sizeof(struct sockaddr_storage)) {
        return AIOFN_LOOP_ERROR;
    }

    memcpy(&socket->connect_address, address, address_len);
    socket->connect_op = op;
    op->backend_token = socket;
    socket->connect_request.data = socket;

    result = uv_tcp_connect(&socket->connect_request, &socket->handle,
                            (const struct sockaddr *)&socket->connect_address, aiofn_libuv_on_connect);
    if (result != 0) {
        socket->connect_op = NULL;
        op->backend_token = NULL;
        aiofn_libuv_set_error((aiofn_libuv_state_t *)data, "uv_tcp_connect", result);
        return AIOFN_LOOP_ERROR;
    }
    return AIOFN_LOOP_OK;
}


static aiofn_loop_status aiofn_libuv_cancel_proactor(void *data, aiofn_loop_proactor_op_t *op) {
    aiofn_libuv_state_t *state = data;
    aiofn_libuv_socket_t *socket;
    int result;
    socket = op->backend_token;
    if (socket->read_op == op) {
        uv_read_stop((uv_stream_t *)&socket->handle);
        socket->read_op = NULL;
        aiofn_libuv_set_error(state, "uv_read", UV_ECANCELED);
        aiofn_libuv_complete(op, AIOFN_LOOP_ERROR, 0);
        return AIOFN_LOOP_OK;
    }
    if (socket->write_op == op) {
        result = uv_cancel((uv_req_t *)&socket->write_request);
        if (result != 0) {
            aiofn_libuv_set_error(state, "uv_cancel(write)", result);
            return AIOFN_LOOP_ERROR;
        }
        return AIOFN_LOOP_OK;
    }
    if (socket->connect_op == op) {
        result = uv_cancel((uv_req_t *)&socket->connect_request);
        if (result != 0) {
            aiofn_libuv_set_error(state, "uv_cancel(connect)", result);
            return AIOFN_LOOP_ERROR;
        }
        return AIOFN_LOOP_OK;
    }
    return AIOFN_LOOP_ERROR;
}


/* Reactor fd readiness operations. */
static aiofn_loop_status aiofn_libuv_add_poll(
    void *data,
    aiofn_loop_fd_watch_t *watch,
    void **token,
    int events,
    const char *operation
) {
    aiofn_libuv_state_t *state = data;
    /* libuv permits only one uv_poll_t per fd, so share the writer poll handle. */
    uv_poll_t *poll = *token;
    int result;
    if (poll == NULL) {
        poll = watch->backend_read_token != NULL ? watch->backend_read_token : watch->backend_write_token;
    }

    if (poll != NULL) {
        result = uv_poll_start(poll, UV_READABLE | UV_WRITABLE, aiofn_libuv_on_fd);
        if (result != 0) {
            aiofn_libuv_set_error(state, operation, result);
            return AIOFN_LOOP_ERROR;
        }
        *token = poll;
        return AIOFN_LOOP_OK;
    }

    poll = calloc(1, sizeof(*poll));
    if (poll == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }

    result = uv_poll_init(&state->loop, poll, watch->fd);
    if (result == 0) {
        poll->data = watch;
        result = uv_poll_start(poll, events, aiofn_libuv_on_fd);
    }
    if (result != 0) {
        aiofn_libuv_set_error(state, operation, result);
        if (poll->loop != NULL) {
            uv_close((uv_handle_t *)poll, aiofn_libuv_free_handle);
        } else {
            free(poll);
        }
        return AIOFN_LOOP_ERROR;
    }
    *token = poll;
    return AIOFN_LOOP_OK;
}


static aiofn_loop_status aiofn_libuv_add_reader(void *data, aiofn_loop_fd_watch_t *watch) {
    return aiofn_libuv_add_poll(data, watch, &watch->backend_read_token, UV_READABLE, "uv_poll_start(reader)");
}


static aiofn_loop_status aiofn_libuv_add_writer(void *data, aiofn_loop_fd_watch_t *watch) {
    return aiofn_libuv_add_poll(data, watch, &watch->backend_write_token, UV_WRITABLE, "uv_poll_start(writer)");
}


static aiofn_loop_status aiofn_libuv_remove_poll(void *data, void **token, int remaining_events) {
    aiofn_libuv_state_t *state = data;
    uv_poll_t *poll = *token;
    int result = uv_poll_stop(poll);
    if (result != 0) {
        aiofn_libuv_set_error(state, "uv_poll_stop", result);
        return AIOFN_LOOP_ERROR;
    }

    *token = NULL;
    if (remaining_events != 0) {
        result = uv_poll_start(poll, remaining_events, aiofn_libuv_on_fd);
        if (result != 0) {
            aiofn_libuv_set_error(state, "uv_poll_start(remove)", result);
            return AIOFN_LOOP_ERROR;
        }
        return AIOFN_LOOP_OK;
    }
    poll->data = NULL;
    uv_close((uv_handle_t *)poll, aiofn_libuv_free_handle);
    return AIOFN_LOOP_OK;
}


static aiofn_loop_status aiofn_libuv_remove_reader(void *data, aiofn_loop_fd_watch_t *watch) {
    return aiofn_libuv_remove_poll(
        data,
        &watch->backend_read_token,
        watch->backend_write_token != NULL ? UV_WRITABLE : 0
    );
}


static aiofn_loop_status aiofn_libuv_remove_writer(void *data, aiofn_loop_fd_watch_t *watch) {
    return aiofn_libuv_remove_poll(
        data,
        &watch->backend_write_token,
        watch->backend_read_token != NULL ? UV_READABLE : 0
    );
}


/* Signal operations. */
static aiofn_loop_status aiofn_libuv_signal_watch(
    void *data,
    int signum,
    aiofn_loop_signal_watch_t *watch
) {
    aiofn_libuv_state_t *state = data;
    uv_signal_t *signal = calloc(1, sizeof(*signal));
    int result;
    if (signal == NULL) {
        return AIOFN_LOOP_NO_MEMORY;
    }

    result = uv_signal_init(&state->loop, signal);
    if (result == 0) {
        signal->data = watch;
        result = uv_signal_start(signal, aiofn_libuv_on_signal, signum);
    }
    if (result != 0) {
        aiofn_libuv_set_error(state, "uv_signal_start", result);
        if (signal->loop != NULL) {
            uv_close((uv_handle_t *)signal, aiofn_libuv_free_handle);
        } else {
            free(signal);
        }
        return AIOFN_LOOP_ERROR;
    }
    watch->backend_token = signal;
    return AIOFN_LOOP_OK;
}


static aiofn_loop_status aiofn_libuv_signal_unwatch(void *data, aiofn_loop_signal_watch_t *watch) {
    aiofn_libuv_state_t *state = data;
    uv_signal_t *signal = watch->backend_token;
    int result = uv_signal_stop(signal);
    if (result != 0) {
        aiofn_libuv_set_error(state, "uv_signal_stop", result);
        return AIOFN_LOOP_ERROR;
    }
    watch->backend_token = NULL;
    signal->data = NULL;
    uv_close((uv_handle_t *)signal, aiofn_libuv_free_handle);
    return AIOFN_LOOP_OK;
}


static const char *aiofn_libuv_last_error(void *data) {
    aiofn_libuv_state_t *state = data;
    return state->last_error[0] == '\0' ? NULL : state->last_error;
}


/* Backend construction and destruction. */
aiofn_loop_backend_t *aiofn_libuv_backend_new(void) {
    aiofn_libuv_state_t *state = calloc(1, sizeof(*state));
    int result;
    if (state == NULL) {
        return NULL;
    }

    result = uv_loop_init(&state->loop);
    if (result != 0) {
        free(state);
        return NULL;
    }

    state->loop.data = state;

    state->backend.struct_size = AIOFN_LOOP_BACKEND_CURRENT_SIZE;
    state->backend.state = state;
    state->backend.name = "libuv";
    state->backend.run = aiofn_libuv_run;
    state->backend.stop = aiofn_libuv_stop;
    state->backend.close = aiofn_libuv_close;
    state->backend.now_ns = aiofn_libuv_now_ns;
    state->backend.call_soon = aiofn_libuv_call_soon;
    state->backend.call_at = aiofn_libuv_call_at;
    state->backend.action_cancel = aiofn_libuv_action_cancel;

    state->reactor.struct_size = AIOFN_REACTOR_BACKEND_CURRENT_SIZE;
    state->reactor.add_reader = aiofn_libuv_add_reader;
    state->reactor.remove_reader = aiofn_libuv_remove_reader;
    state->reactor.add_writer = aiofn_libuv_add_writer;
    state->reactor.remove_writer = aiofn_libuv_remove_writer;
    state->backend.reactor = &state->reactor;

    state->proactor.struct_size = AIOFN_PROACTOR_BACKEND_CURRENT_SIZE;
    state->proactor.wrap_socket = aiofn_libuv_wrap_socket;
    state->proactor.unwrap_socket = aiofn_libuv_unwrap_socket;
    state->proactor.connect = aiofn_libuv_connect;
    state->proactor.read = aiofn_libuv_read;
    state->proactor.write = aiofn_libuv_write;
    state->proactor.cancel = aiofn_libuv_cancel_proactor;
    state->backend.proactor = &state->proactor;

    state->backend.last_error = aiofn_libuv_last_error;
    state->backend.signal_watch = aiofn_libuv_signal_watch;
    state->backend.signal_unwatch = aiofn_libuv_signal_unwatch;
    return &state->backend;
}


void aiofn_libuv_backend_free(aiofn_loop_backend_t *backend) {
    aiofn_libuv_state_t *state = backend->state;
    if (!state->closed) {
        uv_loop_close(&state->loop);
    }
    free(state);
}
