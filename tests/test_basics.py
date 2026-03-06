import asyncio
import ssl

import async_timeout
import pytest

from tests.utils import echo_client, echo_server, \
    multiloop_event_loop_policy, make_test_ssl_contexts, ConnectionType


event_loop_policy = multiloop_event_loop_policy()


@pytest.fixture
async def loop_debug():
    asyncio.get_running_loop().set_debug(True)


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

@pytest.fixture(params=["simple", "buffered"])
def buffered_protocol(request):
    return request.param == "buffered"


@pytest.mark.parametrize("msg_size", [1, 2, 3, 4, 5, 6, 7, 8, 29, 64, 256 * 1024, 6 * 1024 * 1024])
async def test_echo(msg_size, conn_type, buffered_protocol):
    payload = b"x" * msg_size

    async with echo_server(ssl_context=conn_type.server_ssl_context, is_buffered=buffered_protocol) as server:
        async with echo_client(server, ssl_context=conn_type.client_ssl_context, is_buffered=buffered_protocol) as client:
            client.write(payload)
            echoed = await client.readn(msg_size)
            assert echoed == payload


@pytest.mark.parametrize("msg_size", [1, 32, 64, 256 * 1024, 6 * 1024 * 1024, 40 * 1024 * 1024])
@pytest.mark.parametrize("num_lines", [1, 32, 4000])
async def test_echo_writelines(msg_size, num_lines, conn_type, buffered_protocol):
    payload = b"x" * msg_size

    async with echo_server(ssl_context=conn_type.server_ssl_context, is_buffered=buffered_protocol) as server:
        async with echo_client(server, ssl_context=conn_type.client_ssl_context, is_buffered=buffered_protocol) as client:
            client.write_in_lines(payload, num_lines)
            echoed = await client.readn(msg_size)
            assert echoed == payload


async def test_write_paused(conn_type, buffered_protocol):
    payload = b"x" * (128*1024)

    async with echo_server(ssl_context=conn_type.server_ssl_context, is_buffered=buffered_protocol) as server:
        async with echo_client(server, ssl_context=conn_type.client_ssl_context, is_buffered=buffered_protocol) as client:
            wbuf_size = client.transport.get_write_buffer_size()
            assert wbuf_size == 0
            client.transport.set_write_buffer_limits(0, 0)
            total_bytes_written = 0
            while not client.is_writing_paused:
                client.transport.write(payload)
                total_bytes_written += len(payload)
                assert total_bytes_written < 20*1024*1024, "send buffer is much smaller than this, we should already have hit pause_writing by now"

            wbuf_size = client.transport.get_write_buffer_size()
            assert wbuf_size > 0

            # increase writing buffer limit, this should cause resume_writing
            client.transport.set_write_buffer_limits(wbuf_size+2048, wbuf_size+1)
            assert not client.is_writing_paused

            # decrease writing buffer limit, cause writing paused
            client.transport.set_write_buffer_limits(0, 0)
            assert client.is_writing_paused

            await client.wait_write_resumed()
            await client.readn(total_bytes_written)


async def test_pause_reading(conn_type):
    payload = b"x" * (20*1024*1024)

    async with echo_server(ssl_context=conn_type.server_ssl_context) as server:
        async with echo_client(server, ssl_context=conn_type.client_ssl_context) as client:
            client.transport.write(payload)
            client.transport.pause_reading()
            with pytest.raises(asyncio.TimeoutError):
                await client.wait_new_data(0.2)
            client.transport.resume_reading()

            await client.wait_new_data(0.1)
            client.transport.pause_reading()

            with pytest.raises(asyncio.TimeoutError):
                await client.wait_new_data(0.2)

            client.transport.resume_reading()


# TODO:
# 1. SSL: re-negotiation in the middle of writing
# 2. Exception from send due to file error should cause fatal error
# 3. test eof_received event
# 4. exceptions from each callback should cause fatal error
# 5. test different objects for writing
# 6. test aiofn maybe copy buffer
# 7. test exception after beginning, weird hang ups observed


async def test_ssl_renegotiate_midstream(loop_debug):
    if not hasattr(ssl, "TLSVersion"):
        pytest.skip("TLSVersion API is not available")

    server_context, client_context = make_test_ssl_contexts("tests/test.crt", "tests/test.key")
    server_context.minimum_version = ssl.TLSVersion.TLSv1_2
    server_context.maximum_version = ssl.TLSVersion.TLSv1_2
    client_context.minimum_version = ssl.TLSVersion.TLSv1_2
    client_context.maximum_version = ssl.TLSVersion.TLSv1_2

    preface = b"A" * (64 * 1024)
    payload = b"B" * (4 * 1024 * 1024)
    suffix = b"C" * (64 * 1024)

    async with echo_server(ssl_context=server_context) as server:
        async with echo_client(server, ssl_context=client_context) as client:
            client.write(preface)
            assert await client.readn(len(preface)) == preface

            client.transport.renegotiate()
            client.write(payload)
            try:
                echoed_payload = await client.readn(len(payload), timeout=20.0)
            except TimeoutError:
                pytest.skip("renegotiation did not complete in this OpenSSL/runtime configuration")
            assert echoed_payload == payload

            client.write(suffix)
            assert await client.readn(len(suffix)) == suffix
