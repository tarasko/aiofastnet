#ifndef AIOFASTNET_URING_BACKEND_H
#define AIOFASTNET_URING_BACKEND_H

#include "../aiofastnet/loop_backend.h"

#ifdef __cplusplus
extern "C" {
#endif

aiofn_loop_backend_t *aiofn_uring_backend_new(void);
void aiofn_uring_backend_free(aiofn_loop_backend_t *backend);

#ifdef __cplusplus
}
#endif

#endif
