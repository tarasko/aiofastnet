## Description

Read README.md for project description.

# Code style

* Max line width: 150
* In Cython, do not give side-effect-only helpers fake return types such as `int except -1`.
  Use a no-result helper signature instead, unless the returned value is meaningful to callers.

# Troubleshooting

* When investigating hangs, flaky async behavior, SSL issues, or failing tests,
  run the focused pytest command with `--asyncio-debug --log-cli-level DEBUG`.
  Example: `pytest -s -v -k 'test_name_or_param' --asyncio-debug --log-cli-level DEBUG`.
  aiofastnet logs OpenSSL calls, socket syscalls, and important transport state
  transitions at DEBUG level.

# Test Connection Types

Defined in `tests/utils.py`; keep this list in sync with the fixtures.

* `tcp`: plain TCP transport.
* `unix`: Unix-domain socket transport; skipped on Windows.
* `ssl_mbio`: TLS over socket transport using memory BIO.
* `ssl_mbio_fall`: same shape as `ssl_mbio`, but forces `SSLEngineFallback`.
* `ssl_sbio`: TLS over socket transport using socket BIO where available.
* `stls`: server uses TLS from `create_server(ssl=...)`; client starts plain TCP and then calls `start_tls()`.
* `ktls`: Linux Kernel TLS path; requires supported Python/OpenSSL/kernel setup.
