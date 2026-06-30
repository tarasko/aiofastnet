import asyncio
import logging
import os
import ssl
import sys
from pathlib import Path

import pytest

import aiofastnet
from aiofastnet import openssl_compat
from tests.utils import TestServer, TestClient


def _import_ssl_engine_direct():
    if openssl_compat.OPENSSL_DYN_LIBS is None:
        pytest.skip("direct SSL engine is unavailable")

    try:
        from aiofastnet import ssl_engine_direct
    except ImportError as exc:
        pytest.skip(f"direct SSL engine is unavailable: {exc}")
    return ssl_engine_direct


def _test_cert_der():
    return ssl.PEM_cert_to_DER_cert(
        Path("tests/test.crt").read_text(encoding="ascii")
    )


class _Path:
    def __init__(self, exists):
        self._exists = exists

    def exists(self):
        return self._exists


class _InvalidSocket:
    def fileno(self):
        return -1


def test_openssl_discovery_resolves_real_libraries():
    libs = openssl_compat.OPENSSL_DYN_LIBS
    if libs is None:
        pytest.skip("OpenSSL dynamic libraries were not discovered")

    assert os.path.exists(libs.libssl)
    assert os.path.exists(libs.libcrypto)
    assert libs.libssl != libs.libcrypto
    assert "ssl" in os.path.basename(libs.libssl).lower()
    assert "crypto" in os.path.basename(libs.libcrypto).lower()


def test_ktls_kernel_module_not_loaded(monkeypatch, caplog):
    ssl_engine_direct = _import_ssl_engine_direct()

    monkeypatch.setattr(ssl_engine_direct, "Path", lambda path: _Path(False))
    monkeypatch.setattr(
        ssl_engine_direct,
        "_linux_kernel_at_least",
        lambda major, minor: pytest.fail("kernel version should not be checked"),
    )

    with caplog.at_level(logging.WARNING, logger="aiofastnet.ssl"):
        assert not ssl_engine_direct._ktls_prerequisites_available()

    assert "kernel module 'tls' is not loaded" in caplog.text
    assert "Falling back to memory BIO" in caplog.text


def test_ktls_kernel_too_old(monkeypatch, caplog):
    ssl_engine_direct = _import_ssl_engine_direct()

    monkeypatch.setattr(ssl_engine_direct, "Path", lambda path: _Path(True))
    monkeypatch.setattr(
        ssl_engine_direct, "_linux_kernel_at_least", lambda major, minor: False
    )

    with caplog.at_level(logging.WARNING, logger="aiofastnet.ssl"):
        assert not ssl_engine_direct._ktls_prerequisites_available()

    assert "Linux kernel version is < 5.19" in caplog.text
    assert "Falling back to memory BIO" in caplog.text


def test_ktls_openssl_too_old(monkeypatch, caplog):
    ssl_engine_direct = _import_ssl_engine_direct()

    monkeypatch.setattr(ssl_engine_direct, "Path", lambda path: _Path(True))
    monkeypatch.setattr(
        ssl_engine_direct, "_linux_kernel_at_least", lambda major, minor: True
    )
    monkeypatch.setattr(ssl_engine_direct.ssl, "OPENSSL_VERSION_INFO", (1, 1, 1, 0, 0))

    with caplog.at_level(logging.WARNING, logger="aiofastnet.ssl"):
        assert not ssl_engine_direct._ktls_prerequisites_available()

    assert "OpenSSL >= 3.0 is required" in caplog.text
    assert "Falling back to memory BIO" in caplog.text
    assert "Loaded libssl:" in caplog.text
    assert "Loaded libcrypto:" in caplog.text


@pytest.mark.skipif(
    not hasattr(ssl, "OP_ENABLE_KTLS"),
    reason="ssl.OP_ENABLE_KTLS is unavailable",
)
def test_ssl_engine_direct_uses_memory_bio_when_ktls_kernel_unavailable(monkeypatch):
    ssl_engine_direct = _import_ssl_engine_direct()

    monkeypatch.setattr(
        ssl_engine_direct, "_ktls_prerequisites_available", lambda: False
    )
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.options |= ssl.OP_ENABLE_KTLS

    ssl_engine_direct.SSLEngineDirect(
        context,
        False,
        None,
        1024,
        1024,
        sock=_InvalidSocket(),
    )


def test_ssl_engine_direct_get_channel_binding_before_handshake():
    ssl_engine_direct = _import_ssl_engine_direct()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    ssl_engine = ssl_engine_direct.SSLEngineDirect(
        context,
        False,
        None,
        1024,
        1024,
    )

    assert ssl_engine.get_channel_binding() is None


def test_ssl_engine_direct_get_channel_binding_rejects_unknown_type():
    ssl_engine_direct = _import_ssl_engine_direct()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    ssl_engine = ssl_engine_direct.SSLEngineDirect(
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
        ssl_engine.get_channel_binding("tls-exporter")


def test_ssl_engine_direct_certificate_chains_before_handshake():
    ssl_engine_direct = _import_ssl_engine_direct()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    ssl_engine = ssl_engine_direct.SSLEngineDirect(
        context,
        False,
        None,
        1024,
        1024,
    )

    if sys.version_info >= (3, 13):
        assert ssl_engine.get_verified_chain() == []
        assert ssl_engine.get_unverified_chain() == []
    assert ssl_engine.shared_ciphers() is None
    assert ssl_engine.session_reused is False


async def test_create_connection_propagates_ssl_engine_direct_init_exception(monkeypatch):
    ssl_engine_direct = _import_ssl_engine_direct()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    expected_error = RuntimeError("init hook boom")

    def boom():
        raise expected_error

    monkeypatch.setattr(ssl_engine_direct, "_set_sslobject_init_test_hook", boom)

    async with TestServer() as server:
        with pytest.raises(RuntimeError, match="init hook boom") as exc_info:
            await aiofastnet.create_connection(
                asyncio.get_running_loop(),
                asyncio.Protocol,
                server.host,
                server.port,
                ssl=context,
            )

    assert exc_info.value is expected_error


@pytest.mark.parametrize("server_hostname", ["", ".aiofastnet.org"])
def test_ssl_engine_direct_rejects_invalid_server_hostname(server_hostname):
    ssl_engine_direct = _import_ssl_engine_direct()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False

    with pytest.raises(
        ValueError,
        match="server_hostname cannot be an empty string or start with a leading dot",
    ):
        ssl_engine_direct.SSLEngineDirect(
            context,
            False,
            server_hostname,
            1024,
            1024,
        )


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
    if sys.version_info < (3, 13):
        pytest.skip("SSLObject get_verified_chain/get_unverified_chain only available since 3.13")

    expected_der = _test_cert_der()

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            assert client_ssl_object.get_unverified_chain() == [expected_der]
            assert client_ssl_object.get_verified_chain() == [expected_der]
            assert server_ssl_object.get_unverified_chain() == []
            assert server_ssl_object.get_verified_chain() == []


async def test_ssl_certificate_chains_with_client_auth(ssl_conn_type):
    if sys.version_info < (3, 13):
        pytest.skip("SSLObject get_verified_chain/get_unverified_chain only available since 3.13")

    expected_der = _test_cert_der()

    ssl_conn_type.server_ssl_context.verify_mode = ssl.CERT_REQUIRED
    ssl_conn_type.server_ssl_context.load_verify_locations(cafile="tests/test.crt")
    ssl_conn_type.client_ssl_context.load_cert_chain(
        certfile="tests/test.crt",
        keyfile="tests/test.key",
    )

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            assert client_ssl_object.get_unverified_chain() == [expected_der]
            assert server_ssl_object.get_unverified_chain() == [expected_der]


async def test_ssl_engine_connection_attributes(ssl_conn_type):
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
            assert client_ssl_object.session_reused is False
            assert server_ssl_object.session_reused is False


async def test_ssl_shared_ciphers(ssl_conn_type):
    expected_shared_ciphers = [
        ("ECDHE-RSA-AES128-GCM-SHA256", "TLSv1.2", 128),
    ]

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            client_shared_ciphers = client_ssl_object.shared_ciphers()
            if sys.version_info < (3, 10) and isinstance(client_ssl_object, ssl.SSLObject):
                if client_shared_ciphers is not None:
                    assert expected_shared_ciphers[0] in client_shared_ciphers
            else:
                assert client_shared_ciphers is None
            assert server_ssl_object.shared_ciphers() == expected_shared_ciphers


async def test_ssl_getpeercert_binary_form(ssl_conn_type):
    expected_der = _test_cert_der()

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            client_ssl_object = client.transport.get_extra_info("ssl_object")
            server_client = await server.get_any_server_client()
            server_ssl_object = server_client.transport.get_extra_info("ssl_object")

            assert client_ssl_object.getpeercert(binary_form=True) == expected_der
            assert client_ssl_object.getpeercert(binary_form=False) == {}
            assert server_ssl_object.getpeercert(binary_form=True) is None


async def test_ssl_getpeercert_decoded(ssl_conn_type):
    expected = ssl._ssl._test_decode_cert("tests/test.crt")
    ssl_conn_type.client_ssl_context.load_verify_locations("tests/test.crt")
    ssl_conn_type.client_ssl_context.verify_mode = ssl.CERT_REQUIRED

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            ssl_obj = client.transport.get_extra_info("ssl_object")

            assert ssl_obj.getpeercert() == expected


@pytest.mark.parametrize("server_hostname", ["aiofastnet.org", "127.0.0.1"])
async def test_ssl_hostname_verification(ssl_conn_type, server_hostname):
    ssl_conn_type.client_ssl_context.load_verify_locations("tests/test.crt")
    ssl_conn_type.client_ssl_context.check_hostname = True

    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type, server_hostname=server_hostname):
            pass


@pytest.mark.parametrize(
    ("server_hostname", "error"),
    [
        ("other.example", "ostname mismatch"),
        ("127.0.0.2", "IP address mismatch"),
    ],
)
async def test_ssl_hostname_verification_mismatch(
        ssl_conn_type, server_hostname, error):
    ssl_conn_type.client_ssl_context.load_verify_locations("tests/test.crt")
    ssl_conn_type.client_ssl_context.check_hostname = True

    async with TestServer(ct=ssl_conn_type) as server:
        with pytest.raises(ssl.SSLCertVerificationError, match=error):
            async with TestClient(server, ct=ssl_conn_type, server_hostname=server_hostname):
                pass


async def test_ssl_extra_info_object_methods_mockable(ssl_conn_type):
    async with TestServer(ct=ssl_conn_type) as server:
        async with TestClient(server, ct=ssl_conn_type) as client:
            ssl_obj = client.transport.get_extra_info('ssl_object')
            ssl_obj.compression = lambda: "zlib"
            assert ssl_obj.compression() == "zlib"
