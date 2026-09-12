#!/usr/bin/env bash
#
# core/scripts/new-plugin.sh <name>  --  scaffold a new core plugin (DESIGN §27).
#
# Copies core/templates/plugin to ../<name> (next to core, NOT inside it) and rewrites
# every placeholder in the copy:
#
#   my_plugin      -> <name>                (resource name, event prefixes, page id)
#   MyPluginPage   -> <CamelName>Page       (Vue component name, if the template uses one)
#   MY_PLUGIN      -> <UPPER_NAME>          (constants, if the template uses any)
#
# It never touches core itself and refuses to overwrite an existing resource.
#
# Usage:  core/scripts/new-plugin.sh shop_robbery

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CORE_DIR="$(dirname -- "$SCRIPT_DIR")"        # .../resources/core
readonly RESOURCES_DIR="$(dirname -- "$CORE_DIR")"     # .../resources
readonly TEMPLATE_DIR="$CORE_DIR/templates/plugin"
readonly CORE_NAME="$(basename -- "$CORE_DIR")"

die() { printf 'new-plugin: %s\n' "$*" >&2; exit 1; }

# --- arguments --------------------------------------------------------------

if [ "$#" -ne 1 ] || [ "$1" = '-h' ] || [ "$1" = '--help' ]; then
    printf 'usage: %s <name>\n' "$(basename -- "$0")" >&2
    printf '       name must match ^[a-z][a-z0-9_]*$ (FXServer resource name)\n' >&2
    exit 2
fi

readonly NAME="$1"

[[ "$NAME" =~ ^[a-z][a-z0-9_]*$ ]] \
    || die "invalid name '$NAME' -- lower-case letters, digits and underscores only, starting with a letter"

[ "$NAME" != "$CORE_NAME" ] || die "'$NAME' is the framework itself"
[ "$NAME" != 'my_plugin' ] || die "'my_plugin' is the placeholder the template uses -- pick a real name"

readonly TARGET_DIR="$RESOURCES_DIR/$NAME"

[ -d "$TEMPLATE_DIR" ] || die "template not found at $TEMPLATE_DIR"
[ ! -e "$TARGET_DIR" ] || die "$TARGET_DIR already exists -- delete it first or pick another name"

# --- derived placeholder values ---------------------------------------------

# shop_robbery -> ShopRobbery
CAMEL_NAME="$(printf '%s' "$NAME" | awk -F_ '{ for (i = 1; i <= NF; i++) printf toupper(substr($i, 1, 1)) substr($i, 2) }')"
# shop_robbery -> SHOP_ROBBERY
UPPER_NAME="$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]')"

# --- copy -------------------------------------------------------------------

cp -r -- "$TEMPLATE_DIR" "$TARGET_DIR"

# --- replace ----------------------------------------------------------------
# grep -I skips binaries; the long placeholders go first so `my_plugin` cannot eat them.

replaced=0
while IFS= read -r file; do
    [ -n "$file" ] || continue
    sed -i \
        -e "s/MyPluginPage/${CAMEL_NAME}Page/g" \
        -e "s/MY_PLUGIN/${UPPER_NAME}/g" \
        -e "s/my_plugin/${NAME}/g" \
        -- "$file"
    replaced=$((replaced + 1))
done < <(grep -rlI -e 'my_plugin' -e 'MyPluginPage' -e 'MY_PLUGIN' -- "$TARGET_DIR" || true)

# --- next steps -------------------------------------------------------------

cat <<EOF
Created $TARGET_DIR ($replaced file(s) rewritten).

Next steps:

  1. server.cfg -- start it after core:

       ensure $CORE_NAME
       ensure $NAME

  2. Set author, description and version in $NAME/fxmanifest.lua.

  3. Write the plugin:
       $NAME/shared/config.lua   the Config global (both VMs)
       $NAME/client/main.lua     keys/net/callbacks at file scope, registrations in Core.onReady
       $NAME/server/main.lua     Core.Net.on / Core.Callback.register / Core.Commands.register
       $NAME/locales/en.json     Core.Locale.t strings ({{var}} placeholders)

  4. Only if the plugin shows a page -- uncomment Core.UI.registerPage('$NAME', ...) in
     client/main.lua, then rebuild core's shell (it compiles every plugin page into it):

       cd $RESOURCES_DIR && npm install     # once, or after adding a ui dependency
       cd $CORE_DIR/ui && npm run build
       # then in the server console: refresh; restart $CORE_NAME

     Otherwise delete $NAME/ui -- a plugin without a page ships no UI files at all.

  5. refresh; ensure $NAME

See $NAME/README.md, $CORE_DIR/README.md and $CORE_DIR/DESIGN.md.
EOF
