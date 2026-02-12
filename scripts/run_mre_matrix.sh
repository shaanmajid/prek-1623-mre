#!/usr/bin/env bash
set -euo pipefail

PLATFORM="${PLATFORM:?PLATFORM is required}"
INSTALL_METHOD="${INSTALL_METHOD:?INSTALL_METHOD is required}"
PREK_VERSION="${PREK_VERSION:-0.3.2}"
IMAGE="${IMAGE:-node:24-alpine}"
TIMEOUT_SECS="${TIMEOUT_SECS:-90}"
SOURCES="${SOURCES:-github pypi tuna aliyun tencent pip auto}"
REPEATS="${REPEATS:-1}"
AUTO_REPEATS="${AUTO_REPEATS:-5}"

RESULTS_DIR="${RESULTS_DIR:-$PWD/results}"
mkdir -p "$RESULTS_DIR"

case "$INSTALL_METHOD" in
  npm)
    INSTALL_CMD="npm i -g @j178/prek@${PREK_VERSION} >/dev/null"
    PREK_CMD="prek"
    ;;
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

OUT_CSV="$RESULTS_DIR/${PLATFORM//\//-}_${INSTALL_METHOD}.csv"

docker run --platform "$PLATFORM" --rm \
  -w /tmp/node \
  -e INSTALL_CMD="$INSTALL_CMD" \
  -e PREK_CMD="$PREK_CMD" \
  -e INSTALL_METHOD="$INSTALL_METHOD" \
  -e PLATFORM="$PLATFORM" \
  -e SOURCES="$SOURCES" \
  -e TIMEOUT_SECS="$TIMEOUT_SECS" \
  -v "$RESULTS_DIR:/results" \
  --entrypoint sh \
  "$IMAGE" -lc '
set -euo pipefail

apk add --no-cache git python3 py3-pip curl >/dev/null
sh -lc "$INSTALL_CMD"

if ! sh -lc "$PREK_CMD --version" >/tmp/prek-version.out 2>/tmp/prek-version.err; then
  echo "failed to run prek after install" >&2
  cat /tmp/prek-version.err >&2 || true
  exit 3
fi

CSV_FILE="/results/${PLATFORM//\//-}_${INSTALL_METHOD}.csv"
printf "platform,install_method,source,iteration,selected_source,rc,uv_exec,link_type,uv_version,error_sig\n" > "$CSV_FILE"

for src in $SOURCES; do
  runs="$REPEATS"
  if [ "$src" = "auto" ]; then
    runs="$AUTO_REPEATS"
  fi

  i=1
  while [ "$i" -le "$runs" ]; do
    rm -rf /root/.cache/prek /tmp/node/.git /tmp/node/.pre-commit-config.yaml

    git init -q /tmp/node
    cat > /tmp/node/.pre-commit-config.yaml <<"EOCFG"
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
EOCFG
    echo "ok" > /tmp/node/good.txt
    git -C /tmp/node add .pre-commit-config.yaml good.txt

    if [ "$src" = "auto" ]; then
      if timeout "$TIMEOUT_SECS" env RUST_LOG="prek::languages::python::uv=trace" sh -lc "$PREK_CMD run" >/tmp/run.out 2>/tmp/run.err; then
        rc=0
      else
        rc=$?
      fi
    else
      if timeout "$TIMEOUT_SECS" env PREK_UV_SOURCE="$src" env RUST_LOG="prek::languages::python::uv=trace" sh -lc "$PREK_CMD run" >/tmp/run.out 2>/tmp/run.err; then
        rc=0
      else
        rc=$?
      fi
    fi

    selected_source="explicit:${src}"
    if [ "$src" = "auto" ]; then
      selected_source="$(sed -n 's/.*Selected uv source source=//p' /tmp/run.err | tail -n1)"
      if [ -z "$selected_source" ]; then
        selected_source="auto:unknown"
      fi
    fi

    uv_exec="missing"
    link_type="missing"
    uv_version="none"
    if [ -f /root/.cache/prek/tools/uv/uv ]; then
      if /root/.cache/prek/tools/uv/uv --version >/tmp/uv.out 2>/tmp/uv.err; then
        uv_exec="ok"
        uv_version="$(head -n1 /tmp/uv.out)"
      else
        uv_exec="fail"
        uv_version="exec_fail"
      fi

      ldd_out="$(ldd /root/.cache/prek/tools/uv/uv 2>&1 || true)"
      if echo "$ldd_out" | grep -q "ld-musl"; then
        link_type="musl"
      elif echo "$ldd_out" | grep -q "ld-linux"; then
        link_type="glibc"
      else
        link_type="unknown"
      fi
    fi

    error_sig="ok"
    if [ "$rc" -eq 124 ]; then
      error_sig="timeout"
    elif grep -q "Dynamic loader not found" /tmp/run.err 2>/dev/null; then
      error_sig="dynamic_loader_missing"
    elif grep -q "Failed to install hook" /tmp/run.err 2>/dev/null; then
      error_sig="hook_install_failed"
    elif [ "$rc" -ne 0 ]; then
      error_sig="run_failed"
    fi

    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "$PLATFORM" "$INSTALL_METHOD" "$src" "$i" "$selected_source" "$rc" "$uv_exec" "$link_type" "$uv_version" "$error_sig" \
      >> "$CSV_FILE"

    i=$((i + 1))
  done
done
'

echo "wrote $OUT_CSV"
