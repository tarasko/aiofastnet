import asyncio
import gc
import socket
import warnings

import pytest

from aiofastnet import openssl_compat
from aiofastnet import ssl_transport as aiofn_ssl_transport
from tests.utils import make_test_ssl_contexts


async def test_ssl_socket_transport_init_exception_after_start_handshake_does_not_own_socket(selector_loop, monkeypatch):
    if openssl_compat.OPENSSL_DYN_LIBS is None:
        pytest.skip("SSLTransport_Socket works only with SSLEngineDirect")

    expected_error = RuntimeError("post handshake hook boom")

    def boom():
        raise expected_error

    monkeypatch.setattr(aiofn_ssl_transport, "_ssl_socket_post_handshake_test_hook", boom)

    loop = asyncio.get_running_loop()
    _, client_context = make_test_ssl_contexts("tests/test.crt", "tests/test.key", False)
    sock, peer = socket.socketpair()
    try:
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always", ResourceWarning)
            with pytest.raises(RuntimeError, match="post handshake hook boom"):
                aiofn_ssl_transport.SSLTransport_Socket(
                    loop,
                    asyncio.Protocol(),
                    client_context,
                    False,
                    1.0,
                    1.0,
                    256 * 1024,
                    256 * 1024,
                    sock,
                )
            gc.collect()

        assert not [warning for warning in caught if "deleting unclosed SSLTransport_Socket" in str(warning.message)]
    finally:
        sock.close()
        peer.close()

