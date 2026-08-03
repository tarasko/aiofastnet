#ifndef AIOFASTNET_LIBEVENT_BACKEND_H
#define AIOFASTNET_LIBEVENT_BACKEND_H

#include "loop_backend.h"

aiofn_loop_backend *aiofn_libevent_backend_new(void);
void aiofn_libevent_backend_free(aiofn_loop_backend *backend);

#endif
