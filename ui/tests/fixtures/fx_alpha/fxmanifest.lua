-- fx_alpha — integration fixture, NOT a deployable resource (core DESIGN §38.15).
--
-- It exists so `ui/tests/build-fixtures.mjs` can build a plugin with the REAL `coreUI()` Vite plugin
-- and `ui/tests/nui-serve.mjs` can serve it from its own origin, exactly like FiveM would. The
-- manifest is here because `coreUI()` reads it (`core_ui` + a `files` glob covering ui/dist, and no
-- `client_script` glob that could reach into it) and warns when it is missing.

fx_version 'cerulean'
game 'gta5'

author 'core tests'
description 'fx_alpha — cross-origin UI plugin fixture'
version '1.0.0'

dependency 'core'

core_ui 'ui/dist'

files {
    'ui/dist/**',
}
