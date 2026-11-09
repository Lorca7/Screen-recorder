#!/bin/bash
#
# Builds "Screen Recorder.app" into ./dist.
#
#   ./Scripts/build-app.sh                  # release build for this Mac's architecture
#   ./Scripts/build-app.sh --universal      # one binary for Apple Silicon *and* Intel
#   ./Scripts/build-app.sh --debug
#   ./Scripts/build-app.sh --sign "Developer ID Application: Your Name (TEAMID)"
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="release"
SIGN_IDENTITY="-"            # ad-hoc signature by default
ARCH_FLAGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIGURATION="debug"; shift ;;
    --release) CONFIGURATION="release"; shift ;;
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64); shift ;;
    --sign) SIGN_IDENTITY="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

APP_NAME="Screen Recorder"
BUNDLE="dist/${APP_NAME}.app"

if [[ ${#ARCH_FLAGS[@]} -gt 0 ]]; then
  echo "==> Building ScreenRecorder ($CONFIGURATION, universal arm64 + x86_64)"
else
  echo "==> Building ScreenRecorder ($CONFIGURATION)"
fi
swift build -c "$CONFIGURATION" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --product ScreenRecorder

BIN_PATH="$(swift build -c "$CONFIGURATION" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --product ScreenRecorder --show-bin-path)"
BINARY="$BIN_PATH/ScreenRecorder"
if [[ ! -x "$BINARY" ]]; then
  echo "Build did not produce $BINARY" >&2
  exit 1
fi

echo "==> Assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/ScreenRecorder"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "==> Signing with identity: $SIGN_IDENTITY"
# A stable signature matters: macOS ties the Screen Recording permission to it, so an
# unsigned rebuild would ask for permission again.
codesign --force --timestamp=none --options runtime \
         --sign "$SIGN_IDENTITY" "$BUNDLE"
codesign --verify --verbose=1 "$BUNDLE" || true

echo "==> Architectures in the built binary:"
lipo -archs "$BUNDLE/Contents/MacOS/ScreenRecorder" || true

echo
echo "Built: $(pwd)/$BUNDLE"
echo "Run it with:  open \"$BUNDLE\""
echo
echo "The first launch will ask for Screen Recording permission (System Settings >"
echo "Privacy & Security > Screen & System Audio Recording). Grant it, then reopen the app."
