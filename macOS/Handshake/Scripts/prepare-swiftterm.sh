#!/bin/sh
set -eu

checkout="${1:?usage: prepare-swiftterm.sh CHECKOUT}"
patch="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/SwiftTerm/device-pixel-glyph-origins.patch"
revision=464df5207fc2432e16c9a23abe538187196daf5f

if [ "$(git -C "$checkout" rev-parse HEAD)" != "$revision" ]; then
    echo 'SwiftTerm revision changed; review or remove the glyph-alignment backport.' >&2
    exit 1
fi

# Cached checkouts may already contain the patch. Never reset unexpected changes.
if git -C "$checkout" apply --reverse --check "$patch" 2>/dev/null; then
    exit 0
fi
git -C "$checkout" apply --check "$patch"
git -C "$checkout" apply "$patch"
