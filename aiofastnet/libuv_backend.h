#ifndef AIOFASTNET_LIBUV_BACKEND_H
#define AIOFASTNET_LIBUV_BACKEND_H

#include "loop_backend.h"

aiofn_loop_backend_t *aiofn_libuv_backend_new(void);
void aiofn_libuv_backend_free(aiofn_loop_backend_t *backend);

#endif
