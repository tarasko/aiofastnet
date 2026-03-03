import pytest

from tests.utils import echo_client, echo_server, make_test_connection_types, \
    multiloop_event_loop_policy, make_test_ssl_contexts, ConnectionType

event_loop_policy = multiloop_event_loop_policy()


@pytest.fixture(params=["tcp", "ssl"])
def conn_type(request):
    if request.param == "tcp":
        return ConnectionType(name="tcp")
    else:
        server_context, client_context = make_test_ssl_contexts("tests/test.crt", "tests/test.key")
        return ConnectionType(
            name="ssl",
            server_ssl_context=server_context,
            client_ssl_context=client_context,
        )


@pytest.mark.parametrize("msg_size", [1, 2, 3, 4, 5, 6, 7, 8, 29, 64, 256 * 1024, 6 * 1024 * 1024])
async def test_echo(msg_size, conn_type):
    payload = b"x" * msg_size

    async with echo_server(ssl_context=conn_type.server_ssl_context) as server:
        async with echo_client(server, ssl_context=conn_type.client_ssl_context) as client:
            client.write(payload)
            echoed = await client.readn(msg_size)
            assert echoed == payload
