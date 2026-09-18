-- Fixture resource for the @core/ui build tests. Not a real resource; never deployed.
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'core'

client_scripts { 'client/*.lua' }

-- The two lines DESIGN §38.3 asks of a UI plugin: the opt-in key and the files that reach the CEF.
core_ui 'ui/dist'
files {
    'ui/dist/**',
}
