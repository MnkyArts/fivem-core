fx_version 'cerulean'
game 'gta5'
-- Direct native functions for core's own Lua, client and server (DESIGN §30.4): a native call skips the
-- generated Lua wrapper and the generic invoke context. UNDER EVALUATION (PLAN.md N8) — remove this one
-- line, `refresh`, `restart core` to go back; core's Lua is written to behave the same either way.
use_experimental_fxv2_oal 'yes'

-- DESIGN §56: the relational database runs in its own resource; `ensure core` starts it first
dependency 'core_db'

author 'MnkyArts'
description 'Framework core: shared APIs (player, money, factions, vehicles, interactions, markers, UI) for GTA-Online-style RP servers'
version '1.0.0'

shared_scripts { 'import.lua', 'shared/config.lua', 'shared/ui_manifest.lua', 'shared/ui_forms.lua',
    'shared/scene_codec.lua', 'shared/scene_motion.lua' }

client_scripts {
    'client/api.lua', 'shared/hooks.lua', 'client/adminstate.lua', 'client/world.lua', 'client/zones.lua', 'client/controls.lua', 'client/interiors_data.lua', 'client/interiors.lua', 'client/markers.lua', 'client/textlabels.lua', 'client/blips.lua',
    'client/interactions.lua', 'client/ui.lua', 'client/ui_plugins.lua', 'client/settings.lua', 'client/vehicles.lua', 'client/raycast.lua',
    'client/spawn.lua',
    -- §55 Core.Scene: ORDER IS LOAD-BEARING (each file asserts its predecessor; scene.lua clears CoreSceneRuntime last)
    'client/scene_cache.lua', 'client/scene_focus.lua', 'client/scene_mat_assets.lua', 'client/scene_materializer.lua',
    'client/scene_kinds.lua',
    'client/scene_fx.lua', 'client/scene_world.lua', 'client/scene_movers.lua', 'client/scene_promote.lua', 'client/scene_audio.lua',
    'client/scene_voice.lua', 'client/maps_preview.lua', 'client/maps.lua', 'client/scene.lua',
    'client/player.lua', 'client/context.lua', 'client/actions.lua',
    'client/worldsync.lua', 'client/doors.lua', 'client/environment.lua', 'client/stats.lua', 'client/weapons.lua',
    'client/remote.lua', 'client/ui_remote.lua', 'client/hudfeed.lua', 'client/chat.lua',
    'client/main.lua',
}

server_scripts {
    'server/api.lua', 'shared/hooks.lua', 'server/db.lua',
    'server/audit.lua', 'server/bans_identity.lua', 'server/bans.lua',
    -- server/player_store.lua hands its table to server/player.lua (one-shot global): keep them adjacent
    'server/notify.lua', 'server/perms.lua', 'server/buckets.lua', 'server/player_store.lua', 'server/player.lua',
    'server/playergrid.lua',
    'server/money.lua', 'server/factions.lua', 'server/vehicles.lua', 'server/vehicles_park.lua', 'server/vehicles_fleet.lua',
    'server/getters.lua', 'server/globals.lua', 'server/settings.lua', 'server/adminapi.lua', 'server/adminapi_dispatch.lua', 'server/services.lua', 'server/worldsync.lua', 'server/doors.lua',
    'server/environment.lua', 'server/cron.lua',
    'server/maps_types.lua', 'server/maps_runtime.lua', 'server/maps.lua', 'server/maps_apply.lua',
    -- §55 Core.Scene: ORDER IS LOAD-BEARING (each file asserts its predecessor)
    'server/scene_kinds.lua', 'server/scene_index.lua', 'server/scene_interest.lua', 'server/scene_gated.lua',
    'server/scene_flush.lua',
    'server/scene_store.lua', 'server/scene.lua', 'server/scene_promote.lua', 'server/scene_promote_api.lua',
    'server/scene_audio.lua', 'server/scene_voice.lua',
    'server/stats.lua', 'server/weapons.lua', 'server/remote.lua',
    'server/ui.lua', 'server/ui_plugins.lua', 'server/chat.lua', 'server/http.lua', 'server/webhook.lua', 'server/security.lua',
    'server/admin.lua', 'server/main.lua',
}

ui_page 'html/index.html'

files { 'import.lua', 'shared/config.lua', 'shared/ui_manifest.lua', 'lib/**/shared.lua', 'lib/**/client.lua', 'locales/*.json', 'html/**' }
