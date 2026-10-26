#!/bin/sh
# Package the static library built by the Makefile's framework stage.
set -eu
case "${1:-}" in debug|release) profile=$1 ;; *) echo 'usage: build.sh debug|release' >&2; exit 2 ;; esac
repo=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
root="$repo/out/frameworks"
artifact="$root/$profile/HandshakeCore.xcframework"
mkdir -p "$root/$profile"
staging=$(mktemp -d "$root/$profile/staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
xcodebuild -create-xcframework -library "$repo/target/aarch64-apple-darwin/$profile/libhandshake_bridge.a" \
    -headers "$repo/handshake-bridge/include" -output "$staging/HandshakeCore.xcframework"
for file in libhandshake_bridge.a Headers/handshake_bridge.h Headers/module.modulemap; do
    [ -f "$staging/HandshakeCore.xcframework/macos-arm64/$file" ] || {
        echo "error: framework is missing $file" >&2; exit 1;
    }
done
# Keep unchanged framework files intact so Swift's incremental builds stay valid.
if [ ! -d "$artifact" ] || ! diff -qr "$staging/HandshakeCore.xcframework" "$artifact" >/dev/null; then
    rm -rf "$artifact"
    mv "$staging/HandshakeCore.xcframework" "$artifact"
fi
sh "$repo/macOS/HandshakeCorePackage/select.sh" "$profile"
echo "Prepared $profile framework at $artifact"
