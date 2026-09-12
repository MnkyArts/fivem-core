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

-- No `files {}` for the UI. If this plugin has a page, `ui/src` is compiled into core's own
-- shell bundle when core/ui is built (DESIGN.md §7.4) — players download core/html only.
-- List files here only for assets the CEF must fetch from THIS resource (images, sounds).

-- `Core.Locale.t` reads `locales/<lang>.json` with LoadResourceFile (DESIGN.md §26), so every
-- locale file of this plugin has to be listed here.
files {
    'locales/*.json',
}
