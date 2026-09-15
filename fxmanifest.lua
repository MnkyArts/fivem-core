fx_version 'cerulean'
game 'gta5'
node_version '22'   -- server-side Node runtime for server/db_pg.js (DESIGN §33); FXServer ships 16 (default) and 22

author 'MnkyArts'
description 'Framework core: shared APIs (player, money, factions, vehicles, interactions, markers, UI) for GTA-Online-style RP servers'
version '1.0.0'

shared_scripts { 'import.lua', 'shared/config.lua' }

client_scripts {
    'client/api.lua', 'client/world.lua', 'client/interiors_data.lua', 'client/interiors.lua', 'client/markers.lua', 'client/textlabels.lua', 'client/blips.lua',
    'client/interactions.lua', 'client/ui.lua', 'client/vehicles.lua', 'client/raycast.lua',
    'client/spawn.lua', 'client/player.lua',
    'client/worldsync.lua', 'client/doors.lua', 'client/environment.lua', 'client/stats.lua', 'client/weapons.lua',
    'client/remote.lua', 'client/ui_remote.lua', 'client/hudfeed.lua', 'client/chat.lua',
    'client/main.lua',
}

server_scripts {
    'server/api.lua', 'server/db.lua', 'server/db_mysql.lua', 'server/db_pg.js', 'server/db_pg.lua',
    'server/notify.lua', 'server/perms.lua', 'server/player.lua',
    'server/money.lua', 'server/factions.lua', 'server/vehicles.lua',
    'server/getters.lua', 'server/globals.lua', 'server/services.lua', 'server/worldsync.lua', 'server/doors.lua',
    'server/environment.lua', 'server/cron.lua', 'server/stats.lua', 'server/weapons.lua', 'server/remote.lua',
    'server/ui.lua', 'server/chat.lua', 'server/http.lua', 'server/webhook.lua', 'server/security.lua',
    'server/admin.lua', 'server/main.lua',
}

ui_page 'html/index.html'

files { 'import.lua', 'shared/config.lua', 'lib/**/shared.lua', 'lib/**/client.lua', 'locales/*.json', 'html/**' }
