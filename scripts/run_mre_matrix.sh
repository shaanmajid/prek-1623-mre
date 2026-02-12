#!/usr/bin/env bash
set -euo pipefail

PLATFORM="${PLATFORM:?PLATFORM is required}"
INSTALL_METHOD="${INSTALL_METHOD:?INSTALL_METHOD is required}"
UV_SOURCE="${UV_SOURCE:?UV_SOURCE is required}"
ITERATION="${ITERATION:?ITERATION is required}"
PREK_VERSION="${PREK_VERSION:-0.3.2}"
IMAGE="${IMAGE:-alpine:3.20}"
TIMEOUT_SECS="${TIMEOUT_SECS:-90}"

RESULTS_DIR="${RESULTS_DIR:-$PWD/results}"
mkdir -p "$RESULTS_DIR"

case "$INSTALL_METHOD" in
  pip)
    INSTALL_CMD="python3 -m pip install --no-cache-dir --break-system-packages prek==${PREK_VERSION} >/dev/null"
    PREK_CMD="prek"
    ;;
  binary)
    case "$PLATFORM" in
      linux/amd64)
        ARTIFACT="prek-x86_64-unknown-linux-musl.tar.gz"
        MEMBER="prek-x86_64-unknown-linux-musl/prek"
        ;;
      linux/arm64)
        ARTIFACT="prek-aarch64-unknown-linux-musl.tar.gz"
        MEMBER="prek-aarch64-unknown-linux-musl/prek"
        ;;
      *)
        echo "Unsupported platform for binary install: $PLATFORM" >&2
        exit 2
        ;;
    esac
    INSTALL_CMD="curl -LsSf https://github.com/j178/prek/releases/download/v${PREK_VERSION}/${ARTIFACT} | tar -xz -C /usr/local/bin --strip-components=1 ${MEMBER}"
    PREK_CMD="prek"
    ;;
  installer)
    INSTALL_CMD="curl -LsSf https://github.com/j178/prek/releases/download/v${PREK_VERSION}/prek-installer.sh -o /tmp/prek-installer.sh && PREK_NO_MODIFY_PATH=1 sh /tmp/prek-installer.sh >/tmp/prek-install.log 2>&1"
    PREK_CMD="/root/.local/bin/prek"
    ;;
  *)
    echo "Unknown INSTALL_METHOD: $INSTALL_METHOD" >&2
    exit 2
    ;;
esac

SAFE_PLATFORM="${PLATFORM//\//-}"
SAFE_SOURCE="${UV_SOURCE//\//-}"
OUT_CSV="$RESULTS_DIR/${SAFE_PLATFORM}_${INSTALL_METHOD}_${SAFE_SOURCE}_${ITERATION}.csv"

docker run --platform "$PLATFORM" --rm \
  -w /tmp/node \
  -v "$PWD/scripts:/scripts:ro" \
  -v "$RESULTS_DIR:/results" \
  -e INSTALL_CMD="$INSTALL_CMD" \
  -e PREK_CMD="$PREK_CMD" \
  -e INSTALL_METHOD="$INSTALL_METHOD" \
  -e PLATFORM="$PLATFORM" \
  -e SAFE_PLATFORM="$SAFE_PLATFORM" \
  -e UV_SOURCE="$UV_SOURCE" \
  -e ITERATION="$ITERATION" \
  -e TIMEOUT_SECS="$TIMEOUT_SECS" \
  --entrypoint sh \
  "$IMAGE" -c 'sh /scripts/run_mre_matrix_inner.sh'

echo "wrote $OUT_CSV"
