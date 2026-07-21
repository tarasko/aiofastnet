## Description

Read README.md for project description.

# Code style

* Max line width: 150
* Keep `api_<api_name>.py` files structurally close to the corresponding
  `asyncio` implementation so upstream changes remain easy to merge.
  Move genuinely common code to `api_utils.py` when useful, but keep changes
  limited to what is necessary: no added typing, no broad refactoring, and no
  function renaming. Minor local renames are fine when they adapt copied code to
  aiofastnet conventions, such as `logger` -> `_logger` or `self` -> `loop`.
  Fallback code for unsupported event loop implementations, such as proactor
  loops, is acceptable.
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
