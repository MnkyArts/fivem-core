-- Plugin skeleton for the `core` framework (see DESIGN.md §1).
-- Copy this folder next to `core`, rename it, and replace every `my_plugin` placeholder.

fx_version 'cerulean'
game 'gta5'

author 'you'
description 'my_plugin — a core plugin'
version '1.0.0'

-- core must be started before this resource; `@core/import.lua` pulls in the shared API.
dependency 'core'

shared_scripts {
    '@core/import.lua',
    'shared/config.lua',
}

client_scripts {
    'client/*.lua',
}

server_scripts {
    'server/*.lua',
}

-- The UI opt-in (DESIGN.md §38.4): core reads ui/dist/manifest.json from THIS resource and the CEF
-- imports the module from https://cfx-nui-my_plugin/ui/dist/. Build it with `npm run build` in ui/.
-- Delete this line (and the ui/ folder) if the plugin shows no page.
core_ui 'ui/dist'

-- Only files listed here are packed for the client, and the CEF can fetch nothing else: without the
-- ui/dist glob the build succeeds and the game serves a 404. Never let a `client_scripts` glob
-- reach into ui/dist — FiveM serves those files as garbage.
-- `Core.Locale.t` reads `locales/<lang>.json` with LoadResourceFile (DESIGN.md §26), so every
-- locale file of this plugin has to be listed here. Add assets the CEF must fetch from this
-- resource (images, sounds) the same way.
files {
    'locales/*.json',
    'ui/dist/**',
}
