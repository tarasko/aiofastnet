import logging
import ssl

import pytest

from aiofastnet import ssl_object
from tests.utils import TestServer, TestClient, ssl_conn_type


class _Path:
    def __init__(self, exists):
        self._exists = exists

    def exists(self):
        return self._exists


class _InvalidSocket:
    def fileno(self):
        return -1


def test_ktls_kernel_module_not_loaded(monkeypatch, caplog):
    monkeypatch.setattr(ssl_object, "Path", lambda path: _Path(False))
    monkeypatch.setattr(
        ssl_object,
        "_linux_kernel_at_least",
        lambda major, minor: pytest.fail("kernel version should not be checked"),
    )

    with caplog.at_level(logging.WARNING, logger="aiofastnet.ssl"):
        assert not ssl_object._ktls_prerequisites_available()

    assert "kernel module 'tls' is not loaded" in caplog.text
    assert "Falling back to memory BIO" in caplog.text


def test_ktls_kernel_too_old(monkeypatch, caplog):
    monkeypatch.setattr(ssl_object, "Path", lambda path: _Path(True))
    monkeypatch.setattr(
        ssl_object, "_linux_kernel_at_least", lambda major, minor: False
    )

    with caplog.at_level(logging.WARNING, logger="aiofastnet.ssl"):
        assert not ssl_object._ktls_prerequisites_available()

    assert "Linux kernel version is < 5.19" in caplog.text
    assert "Falling back to memory BIO" in caplog.text


def test_ktls_openssl_too_old(monkeypatch, caplog):
    monkeypatch.setattr(ssl_object, "Path", lambda path: _Path(True))
    monkeypatch.setattr(
        ssl_object, "_linux_kernel_at_least", lambda major, minor: True
    )
    monkeypatch.setattr(ssl_object.ssl, "OPENSSL_VERSION_INFO", (1, 1, 1, 0, 0))

    with caplog.at_level(logging.WARNING, logger="aiofastnet.ssl"):
        assert not ssl_object._ktls_prerequisites_available()

    assert "OpenSSL >= 3.0 is required" in caplog.text
    assert "Falling back to memory BIO" in caplog.text
    assert "Loaded libssl:" in caplog.text
    assert "Loaded libcrypto:" in caplog.text


@pytest.mark.skipif(
    not hasattr(ssl, "OP_ENABLE_KTLS"),
    reason="ssl.OP_ENABLE_KTLS is unavailable",
)
def test_ssl_object_uses_memory_bio_when_ktls_kernel_unavailable(monkeypatch):
    monkeypatch.setattr(
        ssl_object, "_ktls_prerequisites_available", lambda: False
    )
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.options |= ssl.OP_ENABLE_KTLS

    ssl_object.SSLObject(
        context,
        False,
        None,
        1024,
        1024,
        sock=_InvalidSocket(),
    )


def test_ssl_get_channel_binding_before_handshake():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    ssl_obj = ssl_object.SSLObject(
        context,
        False,
        None,
        1024,
        1024,
    )

    assert ssl_obj.get_channel_binding() is None


def test_ssl_get_channel_binding_rejects_unknown_type():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    ssl_obj = ssl_object.SSLObject(
        context,
        False,
        None,
        1024,
        1024,
    )

    with pytest.raises(
        ValueError,
        match="'tls-exporter' channel binding type not implemented",
    ):
        ssl_obj.get_channel_binding("tls-exporter")


def test_ssl_certificate_chains_before_handshake():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    ssl_obj = ssl_object.SSLObject(
        context,
        False,
        None,
        1024,
        1024,
    )

    assert ssl_obj.get_verified_chain() == []
    assert ssl_obj.get_unverified_chain() == []


async def test_ssl_selected_alpn_protocol(ssl_conn_type):
    ssl_conn_type.server_ssl_context.set_alpn_protocols(["h2", "http/1.1"])
    ssl_conn_type.client_ssl_context.set_alpn_protocols(["http/1.1", "h2"])

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            assert client_ssl_object.selected_alpn_protocol() == "h2"
            assert server_ssl_object.selected_alpn_protocol() == "h2"


async def test_ssl_selected_alpn_protocol_none(ssl_conn_type):
    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            assert client_ssl_object.selected_alpn_protocol() is None
            assert server_ssl_object.selected_alpn_protocol() is None


async def test_ssl_get_channel_binding(ssl_conn_type):
    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            client_binding = client_ssl_object.get_channel_binding()
            server_binding = server_ssl_object.get_channel_binding("tls-unique")

            assert isinstance(client_binding, bytes)
            assert client_binding
            assert server_binding == client_binding


async def test_ssl_certificate_chains(ssl_conn_type):
    expected_der = ssl.PEM_cert_to_DER_cert(
        open("tests/test.crt", "r", encoding="ascii").read())

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            assert client_ssl_object.get_unverified_chain() == [expected_der]
            assert client_ssl_object.get_verified_chain() == [expected_der]
            assert server_ssl_object.get_unverified_chain() == []
            assert server_ssl_object.get_verified_chain() == []


async def test_ssl_object_connection_attributes(ssl_conn_type):
    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            assert client_ssl_object.version() == "TLSv1.2"
            assert server_ssl_object.version() == client_ssl_object.version()
            assert client_ssl_object.context is ssl_conn_type.client_ssl_context
            assert server_ssl_object.context is ssl_conn_type.server_ssl_context
            expected_server_hostname = (
                None if ssl_conn_type.use_start_tls else server.host
            )
            assert client_ssl_object.server_hostname == expected_server_hostname
            assert server_ssl_object.server_hostname is None
            assert client_ssl_object.server_side is False
            assert server_ssl_object.server_side is True


async def test_ssl_getpeercert_binary_form(ssl_conn_type):
    expected_der = ssl.PEM_cert_to_DER_cert(open("tests/test.crt", "r", encoding="ascii").read())

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            assert client_ssl_object.getpeercert(binary_form=True) == expected_der
            assert client_ssl_object.getpeercert(binary_form=False) == {}
            assert server_ssl_object.getpeercert(binary_form=True) is None
