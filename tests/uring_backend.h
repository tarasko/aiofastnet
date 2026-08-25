#ifndef AIOFASTNET_URING_BACKEND_H
#define AIOFASTNET_URING_BACKEND_H

#include "../aiofastnet/loop_backend.h"

#ifdef __cplusplus
extern "C" {
#endif

// busy_poll: never block in the kernel waiting for completions - spin
// instead, trading one fully-pegged CPU core for the lowest possible
// completion latency. See aiofn_uring_run_busy_poll() in uring_backend.c.
//
// sqpoll: offload SQE submission to a dedicated kernel polling thread
// (IORING_SETUP_SQPOLL), removing the submission-side enter() syscall too.
// Independent of busy_poll - combine both for the fewest syscalls on the
// hot path. May require a newer kernel or elevated privileges; returns
// NULL on failure like any other init error.
aiofn_loop_backend_t *aiofn_uring_backend_new(int busy_poll, int sqpoll);
void aiofn_uring_backend_free(aiofn_loop_backend_t *backend);

#ifdef __cplusplus
}
#endif

#endif
