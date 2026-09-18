-- fx_beta — integration fixture, NOT a deployable resource (core DESIGN §38.15).
-- Read by `coreUI()` while ui/tests/build-fixtures.mjs builds it: the `core_ui` opt-in, a
-- `files` glob that packs ui/dist and no `client_script` glob that could reach into it.

fx_version 'cerulean'
game 'gta5'

author 'core tests'
description 'fx_beta — UI plugin fixture'
version '1.0.0'

dependency 'core'

core_ui 'ui/dist'

files {
    'ui/dist/**',
}
