#!/bin/bash
# Build Xone3D.app as a native arm64 macOS app.
# Requires: Xcode command-line tools + Homebrew libusb.
#     xcode-select --install
#     brew install libusb
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Checking libusb (pkg-config)…"
if ! pkg-config --exists libusb-1.0; then
    echo "libusb not found. Run:  brew install libusb" >&2
    # Help pkg-config find Homebrew on Apple Silicon:
    export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    pkg-config --exists libusb-1.0 || { echo "Still not found." >&2; exit 1; }
fi

echo "==> swift build (release)…"
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
# Swift 6 / Xcode 16 default to the new "Swift Build" (XCBuild) engine, which
# fails to initialize on this kind of package ("Unknown error parsing property
# list"). Force the legacy native engine when it's available; fall back for
# older toolchains that don't know the flag (they already use native).
# On Apple Silicon a plain build is already arm64 — no --arch needed.
if swift build --help 2>/dev/null | grep -q -- '--build-system'; then
    swift build -c release --build-system native
else
    swift build -c release
fi

BIN=".build/release/Xone3D"
APP="Xone3D.app"
echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Xone3D"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc code signing (lets Gatekeeper run it locally)…"
codesign --force --deep --sign - "$APP" || echo "   (codesign skipped/failed — app still runs locally)"

echo
echo "Done:  $(pwd)/${APP}"
echo "Run it:   open ./Xone3D.app       (or double-click in Finder)"
echo "If macOS blocks it: right-click → Open, or"
echo "  xattr -dr com.apple.quarantine ./Xone3D.app"
