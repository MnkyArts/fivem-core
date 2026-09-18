#!/usr/bin/env bash
# Builds stream/core_hint.gfx — the world prompt's key hint as ONE Scaleform movie (DESIGN §6.7).
#
# Like build-font-gfx.sh this drives JPEXS FFDec (GPL, build-time tool only — it is NOT shipped):
# scripts/hint-to-gfx.java assembles the shapes, embeds both Barlow Condensed weights as
# DefineFont3, compiles scripts/hint.as with FFDec's ActionScript2Parser and saves the movie with
# the GFX signature. Requirements: `woff2_decompress` (the `woff2` package) and a local FFDec jar
# WITH its lib/ next to it, e.g. https://github.com/jindrapetrik/jpexs-decompiler.
#
#   FFDEC=/path/to/ffdec.jar scripts/build-hint-gfx.sh
#
# A preview a stock Flash 8 player (or Ruffle) can show — the same tags with the plain SWF
# signature plus one trailing SET_HINT call — is written next to it on request:
#
#   PREVIEW=/tmp/out scripts/build-hint-gfx.sh
#   PREVIEW=/tmp/out PREVIEW_NAME=hint_left \
#     PREVIEW_CALL="SET_HINT('E', 'Pick up Bandage', false, true, false);" scripts/build-hint-gfx.sh
#
# Commit the regenerated stream/core_hint.gfx; nothing here is needed at runtime.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
core="$(dirname "$here")"
FFDEC="${FFDEC:-ffdec.jar}"
[ -f "$FFDEC" ] || { echo "FFDec jar not found: $FFDEC (set FFDEC=/path/to/ffdec.jar)" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# the two weights the hint draws with: 600 for the band label, 700 for the key cap letter
for weight in 600 700; do
    src="$core/ui/src/kit/fonts/barlow-condensed-latin-${weight}-normal.woff2"
    [ -f "$src" ] || { echo "font not found: $src" >&2; exit 1; }
    cp "$src" "$tmp/bc$weight.woff2"
    woff2_decompress "$tmp/bc$weight.woff2"
    [ -f "$tmp/bc$weight.ttf" ] || { echo "woff2_decompress produced no TTF for $weight" >&2; exit 1; }
done

preview=""
if [ -n "${PREVIEW:-}" ]; then
    mkdir -p "$PREVIEW"
    preview="$PREVIEW/${PREVIEW_NAME:-hint_preview}.swf"
fi

java -cp "$FFDEC:$(dirname "$FFDEC")/lib/*" "$here/hint-to-gfx.java" \
    "$here/hint.as" "$tmp/bc600.ttf" "$tmp/bc700.ttf" "$core/stream/core_hint.gfx" \
    "$preview" "${PREVIEW_CALL:-}"

echo "wrote $core/stream/core_hint.gfx"
