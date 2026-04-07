#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_WEB_DIR="$ROOT_DIR/apps/macos/stage-live2d"
BUILD_PATH="${BUILD_PATH:-$ROOT_DIR/apps/macos/.build}"
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
PRODUCT="KinkoClaw"
BIN="$BUILD_PATH/arm64-apple-macosx/$BUILD_CONFIG/$PRODUCT"
LOG_FILE="${LOG_FILE:-/tmp/kinkoclaw-debug.log}"
MODULE_CACHE_PATH="${MODULE_CACHE_PATH:-$BUILD_PATH/clang-module-cache}"

if [[ ! -d "$STAGE_WEB_DIR/node_modules" ]]; then
  echo "Installing stage dependencies..."
  pnpm install --dir "$STAGE_WEB_DIR"
fi

echo "Stopping old $PRODUCT instances..."
killall -q "$PRODUCT" 2>/dev/null || true
sleep 1

echo "Building stage runtime..."
pnpm --dir "$STAGE_WEB_DIR" build

echo "Building $PRODUCT..."
rm -rf "$BUILD_PATH"
mkdir -p "$MODULE_CACHE_PATH"
(
  cd "$ROOT_DIR/apps/macos"
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_PATH" \
    swift build -c "$BUILD_CONFIG" --product "$PRODUCT" --build-path "$BUILD_PATH" --arch arm64
)

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: expected binary not found at $BIN" >&2
  exit 1
fi

if [[ "${KINKOCLAW_BACKGROUND:-0}" == "1" ]]; then
  echo "Launching visible debug binary in background..."
  KINKOCLAW_FORCE_VISIBLE=1 nohup "$BIN" >"$LOG_FILE" 2>&1 &
  PID=$!
  echo "Started $PRODUCT (PID $PID)"
  echo "Log: $LOG_FILE"
else
  echo "Launching visible debug binary in foreground..."
  KINKOCLAW_FORCE_VISIBLE=1 exec "$BIN"
fi
