from concurrent.futures import ThreadPoolExecutor

import pytest

from tests.utils import TestServer, TestClient, conn_type


async def test_wrong_thread_assert(conn_type):
    payload = b"x"

    with ThreadPoolExecutor(max_workers=1) as executor:
        async with TestServer(ssl_context=conn_type.server_ssl_context) as server:
            async with TestClient(server, ssl_context=conn_type.client_ssl_context) as client:
                with pytest.raises(AssertionError):
                    executor.submit(client.transport.get_extra_info, "socket").result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.set_protocol, None).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.get_protocol).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.is_reading).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.pause_reading).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.resume_reading).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.set_write_buffer_limits).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.get_write_buffer_limits).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.get_write_buffer_size).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.write, payload).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.writelines, [payload, payload]).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.write_eof).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.is_closing).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.close).result()

                with pytest.raises(AssertionError):
                    executor.submit(client.transport.abort).result()
