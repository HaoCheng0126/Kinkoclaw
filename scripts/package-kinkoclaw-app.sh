#!/usr/bin/env bash
set -euo pipefail

# Build and bundle KinkoClaw into a minimal menu bar .app.
# Outputs to dist/KinkoClaw.app

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="KinkoClaw"
PRODUCT="KinkoClaw"
APP_ROOT="${APP_ROOT:-$ROOT_DIR/dist/${APP_NAME}.app}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/apps/macos/.build}"
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
BUNDLE_ID="${BUNDLE_ID:-ai.openclaw.kinkoclaw.debug}"
PKG_VERSION="$(cd "$ROOT_DIR" && node -p "require('./package.json').version" 2>/dev/null || echo "0.0.0")"
BUILD_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(cd "$ROOT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BUILD_NUMBER=$(cd "$ROOT_DIR" && git rev-list --count HEAD 2>/dev/null || echo "0")
APP_VERSION="${APP_VERSION:-$PKG_VERSION}"
APP_BUILD="${APP_BUILD:-$GIT_BUILD_NUMBER}"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
BUILD_PATH="$BUILD_ROOT/${BUILD_ARCH}-apple-macosx"
BIN_PATH="$BUILD_PATH/$BUILD_CONFIG/$PRODUCT"
INFO_PLIST_SRC="$ROOT_DIR/apps/macos/Sources/KinkoClaw/Resources/Info.plist"
ICON_SRC="$ROOT_DIR/apps/macos/Sources/KinkoClaw/Resources/KinkoClaw.icns"
STAGE_WEB_DIR="$ROOT_DIR/apps/macos/stage-live2d"

if [[ ! -f "$INFO_PLIST_SRC" ]]; then
  echo "ERROR: Info.plist template missing at $INFO_PLIST_SRC" >&2
  exit 1
fi

if [[ ! -f "$ICON_SRC" ]]; then
  echo "ERROR: icon missing at $ICON_SRC" >&2
  exit 1
fi

if [[ -f "$STAGE_WEB_DIR/package.json" ]]; then
  if [[ ! -d "$STAGE_WEB_DIR/node_modules" ]]; then
    echo "📥 Installing KinkoClaw Live2D stage dependencies"
    pnpm install --dir "$STAGE_WEB_DIR" --frozen-lockfile
  fi

  echo "🎭 Building KinkoClaw Live2D stage"
  pnpm --dir "$STAGE_WEB_DIR" build
fi

echo "🔨 Building $PRODUCT ($BUILD_CONFIG) [$BUILD_ARCH]"
(
  cd "$ROOT_DIR/apps/macos"
  swift build -c "$BUILD_CONFIG" --product "$PRODUCT" --build-path "$BUILD_PATH" --arch "$BUILD_ARCH"
)

if [[ ! -f "$BIN_PATH" ]]; then
  echo "ERROR: expected binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "🧹 Cleaning old app bundle"
rm -rf "$APP_ROOT"
mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources" "$APP_ROOT/Contents/Frameworks"

echo "📄 Copying Info.plist template"
cp "$INFO_PLIST_SRC" "$APP_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$APP_ROOT/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "$APP_ROOT/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD}" "$APP_ROOT/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :OpenClawBuildTimestamp ${BUILD_TS}" "$APP_ROOT/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :OpenClawGitCommit ${GIT_COMMIT}" "$APP_ROOT/Contents/Info.plist" || true

echo "🚚 Copying binary"
cp "$BIN_PATH" "$APP_ROOT/Contents/MacOS/$APP_NAME"
chmod +x "$APP_ROOT/Contents/MacOS/$APP_NAME"
/usr/bin/codesign --remove-signature "$APP_ROOT/Contents/MacOS/$APP_NAME" 2>/dev/null || true

echo "📦 Copying Swift 6.2 compatibility libraries"
SWIFT_COMPAT_LIB="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib"
if [[ -f "$SWIFT_COMPAT_LIB" ]]; then
  cp "$SWIFT_COMPAT_LIB" "$APP_ROOT/Contents/Frameworks/"
  chmod +x "$APP_ROOT/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
fi

echo "🖼  Copying app icon"
cp "$ICON_SRC" "$APP_ROOT/Contents/Resources/KinkoClaw.icns"

echo "📦 Copying KinkoClaw stage resources"
KINKOCLAW_BUNDLE="$BUILD_PATH/$BUILD_CONFIG/OpenClaw_KinkoClaw.bundle"
if [[ -d "$KINKOCLAW_BUNDLE" ]]; then
  cp -R "$KINKOCLAW_BUNDLE" "$APP_ROOT/Contents/Resources/OpenClaw_KinkoClaw.bundle"
else
  echo "WARN: KinkoClaw resource bundle not found at $KINKOCLAW_BUNDLE" >&2
fi

echo "⏹  Stopping any running $APP_NAME"
killall -q "$APP_NAME" 2>/dev/null || true

echo "🔏 Signing bundle"
"$ROOT_DIR/scripts/codesign-mac-app.sh" "$APP_ROOT"

echo "✅ Bundle ready at $APP_ROOT"
