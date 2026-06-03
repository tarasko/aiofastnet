import asyncio
import importlib
import os
import sys
import warnings

import pytest


@pytest.fixture
def all_loops():
    """Opt an async test into all platform event loop factories."""


@pytest.fixture
def selector_loop():
    """Opt an async test into the selector loop on Windows."""


def _selector_loop_factories():
    if os.name == "nt":
        return {
            "asyncio_sel": asyncio.WindowsSelectorEventLoopPolicy().new_event_loop,
        }
    return {"asyncio": asyncio.new_event_loop}


def _selector_loop_policies():
    if os.name == "nt":
        return {
            "asyncio_sel": asyncio.WindowsSelectorEventLoopPolicy(),
        }
    return {"asyncio": asyncio.DefaultEventLoopPolicy()}


def _platform_loop_factories():
    if os.name == "nt":
        factories = {
            "asyncio_sel": asyncio.WindowsSelectorEventLoopPolicy().new_event_loop,
            "asyncio_pro": asyncio.WindowsProactorEventLoopPolicy().new_event_loop,
        }
        if sys.version_info >= (3, 10):
            try:
                winloop = importlib.import_module("winloop")
            except ImportError:
                pass
            else:
                factories["winloop"] = winloop.EventLoopPolicy().new_event_loop
        return factories

    factories = {"asyncio": asyncio.new_event_loop}
    try:
        uvloop = importlib.import_module("uvloop")
    except ImportError:
        pass
    else:
        factories["uvloop"] = uvloop.new_event_loop
    return factories


def _platform_loop_policies():
    if os.name == "nt":
        policies = {
            "asyncio_sel": asyncio.WindowsSelectorEventLoopPolicy(),
            "asyncio_pro": asyncio.WindowsProactorEventLoopPolicy(),
        }
        if sys.version_info >= (3, 10):
            try:
                winloop = importlib.import_module("winloop")
            except ImportError:
                pass
            else:
                policies["winloop"] = winloop.EventLoopPolicy()
        return policies

    policies = {"asyncio": asyncio.DefaultEventLoopPolicy()}
    try:
        uvloop = importlib.import_module("uvloop")
    except ImportError:
        pass
    else:
        policies["uvloop"] = uvloop.EventLoopPolicy()
    return policies


def _requested_loop_fixtures(item):
    fixture_names = set(getattr(item, "fixturenames", ()) or ())
    fixture_info = getattr(item, "_fixtureinfo", None)
    if fixture_info is not None:
        fixture_names.update(fixture_info.argnames)
        fixture_names.update(fixture_info.names_closure)
    return fixture_names


class _LegacyEventLoopPolicyPlugin:
    @pytest.fixture
    def event_loop_policy(self, request):
        if hasattr(request, "param"):
            return request.param
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            return asyncio.get_event_loop_policy()


def pytest_configure(config):
    if not hasattr(config.hook, "pytest_asyncio_loop_factories"):
        config.pluginmanager.register(
            _LegacyEventLoopPolicyPlugin(),
            "aiofastnet-legacy-event-loop-policy",
        )


@pytest.hookimpl(optionalhook=True)
def pytest_asyncio_loop_factories(config, item):
    fixture_names = _requested_loop_fixtures(item)

    if "all_loops" in fixture_names:
        return _platform_loop_factories()
    if "selector_loop" in fixture_names:
        return _selector_loop_factories()
    return {"asyncio": asyncio.new_event_loop}


def pytest_generate_tests(metafunc):
    if hasattr(metafunc.config.hook, "pytest_asyncio_loop_factories"):
        return

    fixture_names = _requested_loop_fixtures(metafunc.definition)
    if "all_loops" in fixture_names:
        policies = _platform_loop_policies()
    elif "selector_loop" in fixture_names:
        policies = _selector_loop_policies()
    else:
        return

    if "event_loop_policy" not in metafunc.fixturenames:
        metafunc.fixturenames.append("event_loop_policy")
    metafunc.parametrize(
        "event_loop_policy",
        list(policies.values()),
        ids=list(policies.keys()),
        indirect=True,
    )
