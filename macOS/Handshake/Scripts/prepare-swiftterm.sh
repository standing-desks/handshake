#!/bin/sh
set -eu

checkout="${1:?usage: prepare-swiftterm.sh CHECKOUT}"
patch="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/SwiftTerm/device-pixel-glyph-origins.patch"
revision=464df5207fc2432e16c9a23abe538187196daf5f

if [ "$(git -C "$checkout" rev-parse HEAD)" != "$revision" ]; then
    echo 'SwiftTerm revision changed; review the glyph and history integration patches.' >&2
    exit 1
fi

# Cached checkouts may already contain a patch. Never reset unexpected changes.
apply_patch() {
    if git -C "$checkout" apply --reverse --check "$1" 2>/dev/null; then
        return
    fi
    git -C "$checkout" apply --check "$1"
    git -C "$checkout" apply "$1"
}
apply_patch "$patch"
patch="$(dirname -- "$patch")/background-history.patch"
apply_patch "$patch"
source="$(dirname -- "$patch")/TerminalDisplayHistory.swift"
destination="$checkout/Sources/SwiftTerm/TerminalDisplayHistory.swift"
stamp="$checkout/.handshake-history-source.sha256"
if [ -f "$destination" ] && ! cmp -s "$source" "$destination"; then
    actual=$(shasum -a 256 "$destination" | cut -d ' ' -f 1)
    if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$actual" ]; then
        echo 'SwiftTerm history integration has unexpected changes.' >&2
        exit 1
    fi
fi
if ! cmp -s "$source" "$destination"; then
    cp "$source" "$destination"
fi
shasum -a 256 "$source" | cut -d ' ' -f 1 > "$stamp"
