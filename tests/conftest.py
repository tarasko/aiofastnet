import asyncio
import importlib
import os
import sys

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


@pytest.hookimpl(optionalhook=True)
def pytest_asyncio_loop_factories(config, item):
    fixture_names = set(getattr(item, "fixturenames", ()) or ())
    fixture_info = getattr(item, "_fixtureinfo", None)
    if fixture_info is not None:
        fixture_names.update(fixture_info.argnames)
        fixture_names.update(fixture_info.names_closure)

    if "all_loops" in fixture_names:
        return _platform_loop_factories()
    if "selector_loop" in fixture_names:
        return _selector_loop_factories()
    return {"asyncio": asyncio.new_event_loop}
