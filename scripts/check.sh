#!/usr/bin/env bash
#
# core/scripts/check.sh [--full]  --  the offline gate before a deploy (DESIGN §27, §38.15).
#
#   1. luac5.4 -p on every .lua in core (node_modules excluded)   -- syntax
#   2. fxlint core + core_example                                 -- rulebook, skipped if not installed
#   3. the test database: lua5.4 tests/db_tests.lua               -- Core.DB over the bridge (DESIGN §56.10)
#   4. lua5.4 tests/run_tests.lua + the client/admin/scene suites -- loader, libs, chat, interiors, UI, §41–§55
#   5. lua5.4 tests/server_tests.lua                              -- server modules
#   6. node --test ../core_db/tests/*.test.mjs                    -- core_db: pool, queue, migrations, helpers
#   7. node --test (chat model, ui/tests/unit, ui/sdk/tests)      -- runtime + SDK units
#   8. vue-tsc --noEmit -p ui/tsconfig.json                       -- the shell and the SDK type-check
#   9. gen-kit-types --check + check-plugins.mjs                  -- generated artefacts, every plugin
#  10. cd ui && npm run build                                     -- core/html
#  11. --full: run-browser-suites.mjs + npm run build-storybook   -- shell/kit/runtime suites, stories
#
# Steps 3-6 need the THROWAWAY test database (DESIGN §56.10.1: CORE_TEST_PG_URL, default
# postgres://core_test:core_test@127.0.0.1:5432/core_test -- never the production database) and the
# core_db resource next to core. Create the database once with `scripts/test-db.sh up`.
#
# Stops at the first failure with a non-zero exit code. It runs no server and touches
# no game state -- a green run means the Lua contracts hold, not that the resource works
# in game (use the in-game checklist in README.md for that).

set -uo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CORE_DIR="$(dirname -- "$SCRIPT_DIR")"        # .../resources/core
readonly RESOURCES_DIR="$(dirname -- "$CORE_DIR")"     # .../resources
readonly EXAMPLE_DIR="$RESOURCES_DIR/core_example"
readonly CORE_DB_DIR="$RESOURCES_DIR/core_db"
readonly TEST_DB_HINT='the test database is needed -- run scripts/test-db.sh up (CORE_TEST_PG_URL overrides the URL)'

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

# A suite that hangs is worse than one that fails: every long step gets a ceiling when
# `timeout` exists (it does on Linux and in CI; a missing one just runs unguarded).
if command -v timeout >/dev/null 2>&1; then
    cap() { timeout "$@"; }
else
    cap() { shift; "$@"; }
fi

cd -- "$CORE_DIR" || fail "cannot cd to $CORE_DIR"

# --- 1. Lua syntax ----------------------------------------------------------

step '1/11  luac5.4 -p (every .lua in core)'
command -v luac5.4 >/dev/null 2>&1 || fail 'luac5.4 is not on PATH (pacman -S lua / apt-get install lua5.4)'

count=0
while IFS= read -r -d '' file; do
    luac5.4 -p -- "$file" || fail "syntax error in $file"
    count=$((count + 1))
done < <(find . -name node_modules -prune -o -name storybook-static -prune -o -name '*.lua' -print0)
printf '   %d file(s) parsed\n' "$count"

# --- 2. fxlint (local tooling only -- CI skips it) --------------------------

step '2/11  fxlint core + core_example'
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

# --- 3. the test database (DESIGN §56.10) ------------------------------------

command -v lua5.4 >/dev/null 2>&1 || fail 'lua5.4 is not on PATH'
command -v node >/dev/null 2>&1 || fail 'node is not on PATH (Node 22+): the Lua suites reach Postgres through core_db/tests/bridge.mjs'
[ -d "$CORE_DB_DIR" ] || fail "$CORE_DB_DIR does not exist -- core depends on the core_db resource (DESIGN §56.1)"

step '3/11  the test database: lua5.4 tests/db_tests.lua'
printf '   Postgres-backed suites follow; %s\n' "$TEST_DB_HINT"
lua5.4 tests/db_tests.lua || fail "tests/db_tests.lua -- if the database is unreachable: $TEST_DB_HINT"

# --- 4. + 5. offline Lua suites ---------------------------------------------

step '4/11  lua5.4 tests/run_tests.lua + the client suites'
lua5.4 tests/run_tests.lua || fail 'tests/run_tests.lua'
for suite in geometry client_zones client_actions context_streaming hooks ui_forms; do
    lua5.4 tests/${suite}_tests.lua || fail "tests/${suite}_tests.lua"
done
lua5.4 tests/client_chat_tests.lua || fail 'tests/client_chat_tests.lua'
lua5.4 tests/client_interiors_tests.lua || fail 'tests/client_interiors_tests.lua'
# §38.4/§38.9: the focus stack, plugin discovery, ui_request dispatch, the patch queue.
if [ -f tests/client_ui_tests.lua ]; then
    lua5.4 tests/client_ui_tests.lua || fail 'tests/client_ui_tests.lua'
else
    skip 'tests/client_ui_tests.lua does not exist yet'
fi
# §41–§53 (admin platform): libs, services and the map runtime, one suite per module.
for suite in db_legacy raycast schema settings perms buckets audit bans targets admin_api registry_caller client_registry_caller client_adminstate callback maps maps_store client_maps chat_hook \
             scene_codec scene_motion scene_server scene_index scene_interest client_scene_cache client_scene_mat client_scene_kinds \
             scene_audio scene_voice scene_promote scene_attach scene_parked; do
    if [ -f "tests/${suite}_tests.lua" ]; then
        lua5.4 "tests/${suite}_tests.lua" || fail "tests/${suite}_tests.lua"
    else
        skip "tests/${suite}_tests.lua does not exist yet"
    fi
done

step '5/11  lua5.4 tests/server_tests.lua'
if [ -f tests/server_tests.lua ]; then
    lua5.4 tests/server_tests.lua || fail 'tests/server_tests.lua'
else
    skip 'tests/server_tests.lua does not exist yet'
fi

# --- 6. + 7. Node unit tests ------------------------------------------------

command -v npm >/dev/null 2>&1 || fail 'npm is not on PATH (Node 22+)'
[ -d "$RESOURCES_DIR/node_modules" ] \
    || fail "no hoisted node_modules -- run 'cd $RESOURCES_DIR && npm install' first"

step '6/11  node --test ../core_db/tests/*.test.mjs (the core_db resource)'
# a shell glob of FILES (never the directory: node would run it as a module); they need the test database too
cap 900 node --test "$CORE_DB_DIR"/tests/*.test.mjs || fail "node --test core_db/tests -- $TEST_DB_HINT"

step '7/11  node --test (chat model, ui/tests/unit, ui/sdk/tests)'
node --test ui/tests/chat-model.test.js || fail 'chat presentation helpers'
# GLOBS, never a directory: this Node runs a positional directory as a module instead of
# searching it. The .ts files run on Node's type stripping (DESIGN §38.15).
( cd ui && cap 900 node --test 'tests/unit/**/*.test.ts' 'sdk/tests/*.test.mjs' ) \
    || fail 'node --test (ui/tests/unit + ui/sdk/tests)'

# --- 8. TypeScript ----------------------------------------------------------

step '8/11  vue-tsc --noEmit (the shell + the SDK)'
( cd ui && cap 600 npx vue-tsc --noEmit -p tsconfig.json ) || fail 'vue-tsc -p ui/tsconfig.json'

# --- 9. generated artefacts + every UI plugin -------------------------------

step '9/11  generated kit types + every plugin manifest'
node ui/scripts/gen-kit-types.mjs --check || fail 'ui/sdk/src/client.d.ts is stale -- run `node ui/scripts/gen-kit-types.mjs`'
node ui/scripts/check-plugins.mjs || fail 'ui/scripts/check-plugins.mjs (a UI plugin does not validate)'

# --- 10. UI build ------------------------------------------------------------

step '10/11  cd ui && npm run build'
( cd ui && npm run build ) || fail 'npm run build (core/ui)'

# --- 11. browser suites + Storybook (--full) ---------------------------------

step '11/11  browser suites + Storybook (--full)'
if [ "$FULL" -eq 1 ]; then
    # Builds the fixture plugins, serves one origin per resource (FiveM's headers) and runs
    # shell-, kit- and runtime-regression through agent-browser, all in one process tree.
    if command -v agent-browser >/dev/null 2>&1; then
        cap 1800 node ui/tests/run-browser-suites.mjs || fail 'ui/tests/run-browser-suites.mjs'
    else
        skip 'agent-browser is not on PATH -- the three browser suites need it'
    fi
    ( cd ui && npm run build-storybook ) || fail 'npm run build-storybook (core/ui)'
else
    skip 'pass --full for the browser suites and Storybook'
fi

printf '\n\033[32mAll checks passed.\033[0m\n'
