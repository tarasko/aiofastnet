import asyncio
import ssl

import async_timeout
import pytest

from tests.utils import echo_client, echo_server, \
    make_test_ssl_contexts, ConnectionType, \
    run_on_all_loops


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
def test_echo(run_on_all_loops, msg_size, conn_type, buffered_protocol):
    return run_on_all_loops(_test_echo(msg_size, conn_type, buffered_protocol))


async def _test_echo(msg_size, conn_type, buffered_protocol):
    payload = b"x" * msg_size

    async with echo_server(ssl_context=conn_type.server_ssl_context, is_buffered=buffered_protocol) as server:
        async with echo_client(server, ssl_context=conn_type.client_ssl_context, is_buffered=buffered_protocol) as client:
            client.write(payload)
            echoed = await client.readn(msg_size)
            assert echoed == payload


@pytest.mark.parametrize("msg_size", [1, 32, 64, 256 * 1024, 6 * 1024 * 1024, 20 * 1024 * 1024])
@pytest.mark.parametrize("num_lines", [1, 32, 4000])
def test_echo_writelines(run_on_all_loops, msg_size, num_lines, conn_type, buffered_protocol):
    return run_on_all_loops(_test_echo_writelines(msg_size, num_lines, conn_type, buffered_protocol))


async def _test_echo_writelines(msg_size, num_lines, conn_type, buffered_protocol):
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

            await client.wait_new_data(0.2)
            client.transport.pause_reading()

            with pytest.raises(asyncio.TimeoutError):
                await client.wait_new_data(0.2)

            client.transport.resume_reading()


# TODO:
# Exception from send due to file error should cause fatal error
# exceptions from each callback should cause fatal error
# Graceful disconnect should flush all data
# test different objects for writing
# test aiofn maybe copy buffer
# test eof_received event


async def test_ssl_renegotiate_midstream():
    if not hasattr(ssl, "TLSVersion"):
        pytest.skip("TLSVersion API is not available")

    server_context, client_context = make_test_ssl_contexts("tests/test.crt", "tests/test.key")
    server_context.minimum_version = ssl.TLSVersion.TLSv1_2
    server_context.maximum_version = ssl.TLSVersion.TLSv1_2
    client_context.minimum_version = ssl.TLSVersion.TLSv1_2
    client_context.maximum_version = ssl.TLSVersion.TLSv1_2

    preface = b"A" * (4 * 1024)
    payload = b"B" * (4 * 1024)
    suffix = b"C" * (4 * 1024)

    async with echo_server(ssl_context=server_context) as server:
        async with echo_client(server, ssl_context=client_context) as client:

            client.write(preface)
            assert await client.readn(len(preface)) == preface

            client.transport.get_extra_info('ssl_protocol')._renegotiate()
            wbuf_size = client.transport.get_write_buffer_size()
            client.write(payload)
            wbuf_size_2 = client.transport.get_write_buffer_size()
            assert wbuf_size + len(payload) == wbuf_size_2
            echoed_payload = await client.readn(len(payload), timeout=1.0)
            assert echoed_payload == payload

            client.write(suffix)
            assert await client.readn(len(suffix)) == suffix
