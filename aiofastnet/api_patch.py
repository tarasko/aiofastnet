from __future__ import annotations

import asyncio
import sys
import types
import warnings
from typing import Callable, Optional

from .api_create_connection import create_connection
from .api_create_server import create_server
from .api_sendfile import sendfile
from .api_start_tls import start_tls
from .wrapped_transport import (
    _AIOFASTNET_ORIGINAL_ATTR,
    _AIOFASTNET_PATCHED_ATTR,
)


_PATCHED_METHODS = (
    "create_connection",
    "create_server",
    "start_tls",
    "sendfile",
)


def _bind_create_connection(loop):
    async def create_connection_wrapper(self, protocol_factory, *args, **kwargs):
        return await create_connection(self, protocol_factory, *args, **kwargs)

    return types.MethodType(create_connection_wrapper, loop)


def _bind_create_server(loop):
    async def create_server_wrapper(self, protocol_factory, *args, **kwargs):
        return await create_server(self, protocol_factory, *args, **kwargs)

    return types.MethodType(create_server_wrapper, loop)


def _bind_start_tls(loop):
    async def start_tls_wrapper(self, transport, protocol, sslcontext, *args, **kwargs):
        return await start_tls(self, transport, protocol, sslcontext, *args, **kwargs)

    return types.MethodType(start_tls_wrapper, loop)


def _bind_sendfile(loop):
    async def sendfile_wrapper(self, transport, file, offset=0, count=None, *, fallback=True):
        return await sendfile(self, transport, file, offset, count, fallback=fallback)

    return types.MethodType(sendfile_wrapper, loop)


_BINDERS = {
    "create_connection": _bind_create_connection,
    "create_server": _bind_create_server,
    "start_tls": _bind_start_tls,
    "sendfile": _bind_sendfile,
}


def patch_loop(
        loop: Optional[asyncio.AbstractEventLoop] = None,
        *,
        strict: bool = True,
) -> asyncio.AbstractEventLoop:
    """Patch an event loop so its networking methods use aiofastnet.

    Parameters:
        loop: Event loop to patch. If omitted, the currently running loop is
            patched.
        strict: If true, raise an exception when a method cannot be patched. If
            false, leave unpatchable methods unchanged.

    The loop's ``create_connection``, ``create_server``, ``start_tls``, and
    ``sendfile`` methods are replaced.

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
        try:
            setattr(loop, _AIOFASTNET_ORIGINAL_ATTR, originals)
        except (AttributeError, TypeError) as exc:
            if strict:
                raise TypeError(f"cannot store aiofastnet patch state on {loop!r}") from exc
            return loop

    patched = getattr(loop, _AIOFASTNET_PATCHED_ATTR, None)
    if patched is None:
        patched = set()
        try:
            setattr(loop, _AIOFASTNET_PATCHED_ATTR, patched)
        except (AttributeError, TypeError) as exc:
            if strict:
                raise TypeError(f"cannot store aiofastnet patch state on {loop!r}") from exc
            return loop

    for name in _PATCHED_METHODS:
        if name in patched:
            continue
        if name not in originals:
            originals[name] = getattr(loop, name)
        try:
            setattr(loop, name, _BINDERS[name](loop))
        except (AttributeError, TypeError) as exc:
            if strict:
                raise TypeError(f"cannot patch {name} on {loop!r}") from exc
            continue
        patched.add(name)

    return loop


def loop_factory(
        base_factory: Optional[Callable[[], asyncio.AbstractEventLoop]] = None,
        *,
        strict: bool = True,
) -> Callable[[], asyncio.AbstractEventLoop]:
    """Return a loop factory that creates loops patched with aiofastnet.

    Parameters:
        base_factory: Callable used to create the underlying event loop. If
            omitted, ``asyncio.new_event_loop`` is used. Pass a third-party loop
            factory such as ``uvloop.new_event_loop`` to patch that loop type.
        strict: Forwarded to ``patch_loop``. If true, loop creation fails when
            the loop cannot be patched.

    The returned callable is intended for ``asyncio.run(..., loop_factory=...)``
    and ``asyncio.Runner(loop_factory=...)``. It sets the newly created loop as
    the current loop, matching ``Runner``'s loop factory contract.
    """
    def factory():
        loop = base_factory() if base_factory is not None else asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        return patch_loop(loop, strict=strict)

    return factory


def install_policy(
        base_policy: Optional[asyncio.AbstractEventLoopPolicy] = None,
        *,
        strict: bool = True,
) -> asyncio.AbstractEventLoopPolicy:
    """Install a legacy event loop policy that patches newly created loops.

    Parameters:
        base_policy: Policy to delegate to for actual loop creation and current
            loop storage. If omitted, the current policy is used.
        strict: Forwarded to ``patch_loop`` for each newly created loop.

    This is a compatibility API for applications that still configure asyncio
    through event loop policies. Policies are deprecated in Python 3.14 and are
    scheduled for removal in Python 3.16; prefer ``loop_factory`` for new code.

    Returns the installed policy object.
    """
    if sys.version_info >= (3, 14):
        warnings.warn(
            "asyncio event loop policies are deprecated in Python 3.14; "
            "prefer aiofastnet.loop_factory()",
            DeprecationWarning,
            stacklevel=2,
        )
    with warnings.catch_warnings():
        warnings.filterwarnings(
            "ignore",
            message="'.*event_loop_policy' is deprecated",
            category=DeprecationWarning,
        )
        if base_policy is None:
            base_policy = asyncio.get_event_loop_policy()

    with warnings.catch_warnings():
        warnings.filterwarnings(
            "ignore",
            message="'.*EventLoopPolicy' is deprecated",
            category=DeprecationWarning,
        )
        base_policy_cls = getattr(asyncio, "DefaultEventLoopPolicy", None)

        if base_policy_cls is None:
            raise RuntimeError(
                "asyncio event loop policies are not available; "
                "use aiofastnet.loop_factory() instead"
            )

        class _PatchedEventLoopPolicy(base_policy_cls):
            def __init__(self, base_policy, strict):
                self._base_policy = base_policy
                self._strict = strict

            def get_event_loop(self):
                return self._base_policy.get_event_loop()

            def set_event_loop(self, loop):
                return self._base_policy.set_event_loop(loop)

            def new_event_loop(self):
                loop = self._base_policy.new_event_loop()
                return patch_loop(loop, strict=self._strict)

    policy = _PatchedEventLoopPolicy(base_policy, strict)
    with warnings.catch_warnings():
        warnings.filterwarnings(
            "ignore",
            message="'.*event_loop_policy' is deprecated",
            category=DeprecationWarning,
        )
        asyncio.set_event_loop_policy(policy)
    return policy
