import pytest
from tests.utils import multiloop_event_loop_policy


event_loop_policy = multiloop_event_loop_policy()


@pytest.mark.parametrize("msg_size", [0, 1, 2, 3, 4, 5, 6, 7, 8, 29, 64, 256 * 1024, 6*1024*1024])
async def test_echo(msg_size):
    pass
