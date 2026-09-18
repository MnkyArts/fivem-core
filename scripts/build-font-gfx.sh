#!/usr/bin/env bash
# Builds stream/barlow_condensed.gfx from the kit's Barlow Condensed woff2 (DESIGN §6.7).
#
# The Scaleform font library is generated with JPEXS FFDec (GPL, build-time tool only — it is NOT
# shipped): FFDec's Java font importer converts the TTF to a DefineFont2 tag and saves the movie
# with the GFX signature. Requirements: `woff2_decompress` (the `woff2` package) and a local FFDec
# jar, e.g. https://github.com/jindrapetrik/jpexs-decompiler (ffdec.jar).
#
#   FFDEC=/path/to/ffdec.jar scripts/build-font-gfx.sh
#
# Commit the regenerated stream/*.gfx; nothing here is needed at runtime.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
core="$(dirname "$here")"
FFDEC="${FFDEC:-ffdec.jar}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# weight, output stem, font name inside the library (the names RegisterFontId looks up)
build() {
    local weight="$1" stem="$2" name="$3"
    local src="$core/ui/src/kit/fonts/barlow-condensed-latin-${weight}-normal.woff2"
    cp "$src" "$tmp/$stem.woff2"
    woff2_decompress "$tmp/$stem.woff2"
    [ -f "$tmp/$stem.ttf" ] || { echo "woff2_decompress produced no TTF for $stem" >&2; exit 1; }
    java -cp "$FFDEC" "$here/font-to-gfx.java" "$tmp/$stem.ttf" "$name" "$core/stream/$stem.gfx"
    echo "wrote $core/stream/$stem.gfx"
}

build 600 barlow_condensed "Barlow Condensed"           # the band label
build 700 barlow_condensed_bold "Barlow Condensed Bold" # the key cap letter
