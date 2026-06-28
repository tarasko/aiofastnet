#!/usr/bin/env bash
#
# Build a static, symbol-hidden OpenSSL for bundling into aiofastnet.
#
# PoC scope: macOS arm64 (Apple Silicon). Produces libssl.a + libcrypto.a and
# headers under build/openssl/, which setup.py picks up when
# AIOFASTNET_BUNDLED_OPENSSL=1 is set.
#
# We build with `no-shared` (static only) and `-fvisibility=hidden` so the
# OpenSSL symbols do not get re-exported from aiofastnet's extension and cannot
# collide with the interpreter's own (statically embedded) OpenSSL. On macOS the
# two-level namespace already isolates the copies; hidden visibility is belt-and
# -suspenders and is what the cryptography wheels rely on cross-platform.

set -euo pipefail

OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.6}"
OPENSSL_SHA256="${OPENSSL_SHA256:-}"   # optional integrity check, set to verify

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build/openssl-build"
PREFIX="${REPO_ROOT}/build/openssl"

TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${TARBALL}"

# Pick the OpenSSL Configure target from the host arch (PoC: macOS only).
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  TARGET="darwin64-arm64-cc" ;;
  Darwin-x86_64) TARGET="darwin64-x86_64-cc" ;;
  *)
    echo "build_openssl.sh: unsupported host $(uname -s)-$(uname -m) (PoC is macOS-only)" >&2
    exit 1
    ;;
esac

if [[ -f "${PREFIX}/lib/libssl.a" && -f "${PREFIX}/lib/libcrypto.a" ]]; then
  echo "Static OpenSSL already present at ${PREFIX} -- skipping build."
  echo "  (delete ${PREFIX} to force a rebuild)"
  exit 0
fi

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ ! -f "${TARBALL}" ]]; then
  echo "Downloading ${URL}"
  curl -fL --retry 3 -o "${TARBALL}" "${URL}"
fi

if [[ -n "${OPENSSL_SHA256}" ]]; then
  echo "${OPENSSL_SHA256}  ${TARBALL}" | shasum -a 256 -c -
fi

SRC_DIR="${BUILD_DIR}/openssl-${OPENSSL_VERSION}"
rm -rf "${SRC_DIR}"
tar xzf "${TARBALL}"
cd "${SRC_DIR}"

# no-shared:    static archives only
# no-tests/-docs/-apps trims build time; we only need libssl/libcrypto + headers
# no-engine/no-legacy keep the surface small (we use standard TLS only)
./Configure "${TARGET}" \
  no-shared no-tests no-docs no-apps \
  no-engine no-legacy \
  -fvisibility=hidden \
  --prefix="${PREFIX}" \
  --openssldir="${PREFIX}/ssl"

make -j"$(sysctl -n hw.ncpu)"
# install_sw = libraries + headers, skip docs/html
make install_sw

echo
echo "Static OpenSSL installed to ${PREFIX}"
ls -la "${PREFIX}/lib/"libssl.a "${PREFIX}/lib/"libcrypto.a 2>/dev/null \
  || ls -la "${PREFIX}"/lib*/libssl.a "${PREFIX}"/lib*/libcrypto.a
