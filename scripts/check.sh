#!/usr/bin/env bash
#
# core/scripts/check.sh [--full]  --  the offline gate before a deploy (DESIGN §27).
#
#   1. luac5.4 -p on every .lua in core (node_modules excluded)   -- syntax
#   2. fxlint core + core_example                                 -- rulebook, skipped if not installed
#   3. lua5.4 tests/run_tests.lua                                 -- loader + libs
#   4. lua5.4 tests/server_tests.lua                              -- server modules
#   5. cd ui && npm run build                                     -- core/html
#   6. --full: npm run build-storybook                            -- ui/storybook-static
#
# Stops at the first failure with a non-zero exit code. It runs no server and touches
# no game state -- a green run means the Lua contracts hold, not that the resource works
# in game (use the in-game checklist in README.md for that).

set -uo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CORE_DIR="$(dirname -- "$SCRIPT_DIR")"        # .../resources/core
readonly RESOURCES_DIR="$(dirname -- "$CORE_DIR")"     # .../resources
readonly EXAMPLE_DIR="$RESOURCES_DIR/core_example"

FULL=0
case "${1:-}" in
    --full) FULL=1 ;;
    '') ;;
    -h|--help) printf 'usage: %s [--full]\n' "$(basename -- "$0")"; exit 0 ;;
    *) printf 'check: unknown argument %s (expected --full)\n' "$1" >&2; exit 2 ;;
esac
readonly FULL

step()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
skip()  { printf '   -- skipped: %s\n' "$*"; }
fail()  { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

cd -- "$CORE_DIR" || fail "cannot cd to $CORE_DIR"

# --- 1. Lua syntax ----------------------------------------------------------

step '1/6  luac5.4 -p (every .lua in core)'
command -v luac5.4 >/dev/null 2>&1 || fail 'luac5.4 is not on PATH (pacman -S lua / apt-get install lua5.4)'

count=0
while IFS= read -r -d '' file; do
    luac5.4 -p -- "$file" || fail "syntax error in $file"
    count=$((count + 1))
done < <(find . -name node_modules -prune -o -name storybook-static -prune -o -name '*.lua' -print0)
printf '   %d file(s) parsed\n' "$count"

# --- 2. fxlint (local tooling only -- CI skips it) --------------------------

step '2/6  fxlint core + core_example'
if command -v fxlint >/dev/null 2>&1; then
    fxlint . || fail 'fxlint reported problems in core'
    if [ -d "$EXAMPLE_DIR" ]; then
        fxlint "$EXAMPLE_DIR" || fail 'fxlint reported problems in core_example'
    else
        skip "$EXAMPLE_DIR does not exist"
    fi
else
    skip 'fxlint is not on PATH (fivem-dev-kit/bin/fxlint) -- it is local tooling, CI does not run it'
fi

# --- 3. + 4. offline test suites --------------------------------------------

command -v lua5.4 >/dev/null 2>&1 || fail 'lua5.4 is not on PATH'

step '3/6  lua5.4 tests/run_tests.lua'
lua5.4 tests/run_tests.lua || fail 'tests/run_tests.lua'

step '4/6  lua5.4 tests/server_tests.lua'
if [ -f tests/server_tests.lua ]; then
    lua5.4 tests/server_tests.lua || fail 'tests/server_tests.lua'
else
    skip 'tests/server_tests.lua does not exist yet'
fi

# --- 5. UI build ------------------------------------------------------------

step '5/6  cd ui && npm run build'
command -v npm >/dev/null 2>&1 || fail 'npm is not on PATH (Node 22+)'
[ -d "$RESOURCES_DIR/node_modules" ] \
    || fail "no hoisted node_modules -- run 'cd $RESOURCES_DIR && npm install' first"
( cd ui && npm run build ) || fail 'npm run build (core/ui)'

# --- 6. Storybook build (--full) --------------------------------------------

step '6/6  cd ui && npm run build-storybook'
if [ "$FULL" -eq 1 ]; then
    ( cd ui && npm run build-storybook ) || fail 'npm run build-storybook (core/ui)'
else
    skip 'pass --full to build Storybook too'
fi

printf '\n\033[32mAll checks passed.\033[0m\n'
