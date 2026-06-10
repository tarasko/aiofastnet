import logging
import ssl

import pytest

from aiofastnet import ssl_object


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
