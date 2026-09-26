fx_version 'cerulean'
game 'gta5'
node_version '22'   -- server-side Node runtime for server/db_pg.js (DESIGN §33); FXServer ships 16 (default) and 22
-- Direct native functions for core's own Lua, client and server (DESIGN §30.4): a native call skips the
-- generated Lua wrapper and the generic invoke context. UNDER EVALUATION (PLAN.md N8) — remove this one
-- line, `refresh`, `restart core` to go back; core's Lua is written to behave the same either way.
use_experimental_fxv2_oal 'yes'

author 'MnkyArts'
description 'Framework core: shared APIs (player, money, factions, vehicles, interactions, markers, UI) for GTA-Online-style RP servers'
version '1.0.0'

shared_scripts { 'import.lua', 'shared/config.lua', 'shared/ui_manifest.lua', 'shared/ui_forms.lua' }

client_scripts {
    'client/api.lua', 'shared/hooks.lua', 'client/world.lua', 'client/zones.lua', 'client/controls.lua', 'client/interiors_data.lua', 'client/interiors.lua', 'client/markers.lua', 'client/textlabels.lua', 'client/blips.lua',
    'client/interactions.lua', 'client/ui.lua', 'client/ui_plugins.lua', 'client/vehicles.lua', 'client/raycast.lua',
    'client/spawn.lua', 'client/player.lua', 'client/context.lua', 'client/actions.lua',
    'client/worldsync.lua', 'client/doors.lua', 'client/environment.lua', 'client/stats.lua', 'client/weapons.lua',
    'client/remote.lua', 'client/ui_remote.lua', 'client/hudfeed.lua', 'client/chat.lua',
    'client/main.lua',
}

server_scripts {
    'server/api.lua', 'shared/hooks.lua', 'server/db.lua', 'server/db_mysql.lua', 'server/db_pg.js', 'server/db_pg.lua',
    'server/notify.lua', 'server/perms.lua', 'server/player.lua', 'server/playergrid.lua',
    'server/money.lua', 'server/factions.lua', 'server/vehicles.lua',
    'server/getters.lua', 'server/globals.lua', 'server/services.lua', 'server/worldsync.lua', 'server/doors.lua',
    'server/environment.lua', 'server/cron.lua', 'server/stats.lua', 'server/weapons.lua', 'server/remote.lua',
    'server/ui.lua', 'server/ui_plugins.lua', 'server/chat.lua', 'server/http.lua', 'server/webhook.lua', 'server/security.lua',
    'server/admin.lua', 'server/main.lua',
}

ui_page 'html/index.html'

files { 'import.lua', 'shared/config.lua', 'shared/ui_manifest.lua', 'lib/**/shared.lua', 'lib/**/client.lua', 'locales/*.json', 'html/**' }
