from __future__ import annotations

import asyncio
import warnings
from functools import partial
from typing import Callable, Optional

from .api_create_connection import create_connection
from .api_create_unix_connection import create_unix_connection
from .api_create_server import create_server
from .api_sendfile import sendfile
from .api_start_tls import start_tls
from .wrapped_transport import (
    _AIOFASTNET_ORIGINAL_ATTR,
    _AIOFASTNET_PATCHED_ATTR,
)


_PATCHABLE_METHODS = {
    "create_connection": create_connection,
    "create_unix_connection": create_unix_connection,
    "create_server": create_server,
    "start_tls": start_tls,
    "sendfile": sendfile,
}


def patch_loop(
        loop: Optional[asyncio.AbstractEventLoop] = None,
) -> asyncio.AbstractEventLoop:
    """Patch an event loop so its networking methods use aiofastnet.

    Parameters:
        loop: Event loop to patch. If omitted, the currently running loop is
            patched.

    The loop's ``create_connection``, ``create_unix_connection``,
    ``create_server``, ``start_tls``, and ``sendfile`` methods are replaced
    when the loop exposes them.

    The patch is idempotent. Original loop methods are retained on the loop so
    aiofastnet's compatibility fallbacks, such as Windows ProactorEventLoop
    wrapping, can call the underlying asyncio implementation without recursing
    back into the patched aiofastnet method.
    """
    if loop is None:
        loop = asyncio.get_running_loop()

    originals = getattr(loop, _AIOFASTNET_ORIGINAL_ATTR, None)
    if originals is None:
        originals = {}
        setattr(loop, _AIOFASTNET_ORIGINAL_ATTR, originals)

    patched = getattr(loop, _AIOFASTNET_PATCHED_ATTR, None)
    if patched is None:
        patched = set()
        setattr(loop, _AIOFASTNET_PATCHED_ATTR, patched)

    for name, aiofn_method in _PATCHABLE_METHODS.items():
        if name in patched:
            continue
        originals[name] = getattr(loop, name)
        setattr(loop, name, partial(aiofn_method, loop))
        patched.add(name)

    return loop


def loop_factory(
        base_factory: Optional[Callable[[], asyncio.AbstractEventLoop]] = None,
) -> Callable[[], asyncio.AbstractEventLoop]:
    """Return a loop factory that creates loops patched with aiofastnet.

    Parameters:
        base_factory: Callable used to create the underlying event loop. If
            omitted, ``asyncio.new_event_loop`` is used. Pass a third-party
            loop factory such as ``uvloop.new_event_loop`` to patch that loop
            type.

    The returned callable is intended for
    ``asyncio.run(..., loop_factory=...)`` and
    ``asyncio.Runner(loop_factory=...)``. It sets the newly created loop as the
    current loop, matching ``Runner``'s loop factory contract.
    """
    def factory():
        if base_factory is not None:
            loop = base_factory()
        else:
            loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        return patch_loop(loop)

    return factory


def install_policy(
        base_policy: Optional[asyncio.AbstractEventLoopPolicy] = None,
) -> asyncio.AbstractEventLoopPolicy:
    """Install a legacy event loop policy that patches newly created loops.

    Parameters:
        base_policy: Policy to delegate to for actual loop creation and current
            loop storage. If omitted, the current policy is used.

    This is a compatibility API for applications that still configure asyncio
    through event loop policies. Policies are deprecated in Python 3.14 and are
    scheduled for removal in Python 3.16; prefer ``loop_factory`` for new code.

    Returns the installed policy object.
    """
    with warnings.catch_warnings():
        warnings.filterwarnings(
            "ignore",
            message="'.*is deprecated",
            category=DeprecationWarning,
        )
        if base_policy is None:
            base_policy = asyncio.get_event_loop_policy()

        class _PatchedEventLoopPolicy(asyncio.AbstractEventLoopPolicy):
            _base_policy: asyncio.AbstractEventLoopPolicy

            def __init__(self, base_policy):
                self._base_policy = base_policy

            def get_event_loop(self):
                return self._base_policy.get_event_loop()

            def set_event_loop(self, loop):
                return self._base_policy.set_event_loop(loop)

            def new_event_loop(self):
                loop = self._base_policy.new_event_loop()
                return patch_loop(loop)

        policy = _PatchedEventLoopPolicy(base_policy)
        asyncio.set_event_loop_policy(policy)
    return policy
