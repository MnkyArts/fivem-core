return function(H)
    local check, eq, newServer, printed, stubs, suite =
        H.check, H.eq, H.newServer, H.printed, H.stubs, H.suite

--- server/ui_plugins.lua (DESIGN §38.4): the start-up validation of a UI plugin's
--- manifest, its files and the two fxmanifest globs only the server can see.
local function suiteUIPlugins()
    suite('ui plugins')
    stubs.resetServer()
    stubs.resetNui()
    stubs.resourceStates = { core = 'started' }
    local env = newServer()
    stubs.loadFile(env, 'shared/ui_manifest.lua')
    stubs.loadFile(env, 'server/ui_plugins.lua')

    --- Declares one fake resource; `opts` overrides the manifest and the globs.
    local function fake(name, opts)
        opts = opts or {}
        local manifest = { id = name, apiVersion = 1, entry = 'plugin.abc.js',
            css = { 'plugin.def.css' }, build = 'abc123', load = 'eager' }
        for key, value in pairs(opts.manifest or {}) do manifest[key] = value end
        stubs.resourceStates[name] = 'started'
        stubs.resourceMeta[name] = {
            core_ui = { opts.dir or 'ui/dist' },
            file = opts.files or { 'ui/dist/**' },
            client_script = opts.clientScripts or { 'client/*.lua' },
        }
        local raw = opts.raw                       -- `false` means "on disk but unreadable"
        if raw == nil then raw = stubs.json.encode(manifest) end
        local files = { ['ui/dist/manifest.json'] = raw }
        if not opts.noEntry then files['ui/dist/plugin.abc.js'] = '// code' end
        if not opts.noCss then files['ui/dist/plugin.def.css'] = '.a{}' end
        stubs.resourceFiles[name] = files
        stubs.triggerOn(env, 'onResourceStart', 0, name)
    end

    fake('inventory')
    check(printed('inventory: UI plugin ok (build abc123, 1 css)') ~= nil,
        'a healthy plugin prints one ok line')

    stubs.resourceMeta.plain = {}
    stubs.resourceStates.plain = 'started'
    local before = #stubs.printed
    stubs.triggerOn(env, 'onResourceStart', 0, 'plain')
    eq(#stubs.printed, before, 'a resource without core_ui is never probed')

    fake('nomanifest', { raw = false })
    check(printed('nomanifest: ui/dist/manifest.json is missing') ~= nil,
        'a missing manifest names the resource and the file')

    fake('mismatch', { manifest = { id = 'something_else' } })
    check(printed("mismatch: ui/dist/manifest.json: 'id' must be the resource name") ~= nil,
        'an id that is not the resource name is refused')

    fake('oldapi', { manifest = { apiVersion = 2 } })
    check(printed('[incompatible]') ~= nil, 'a foreign apiVersion is reported as incompatible')

    fake('missingfile', { noEntry = true })
    check(printed('missingfile: ui/dist/plugin.abc.js is listed in manifest.json but not on disk') ~= nil,
        'an entry that is not on disk is an error')

    fake('unpacked', { files = { 'locales/*.json' } })
    check(printed("unpacked: no files {} entry covers 'ui/dist'") ~= nil,
        'a dir no files {} glob covers is an error')
    fake('packedwide', { files = { '**' } })
    check(printed("packedwide: no files {} entry covers") == nil,
        "a '**' glob covers everything")

    fake('overlap', { clientScripts = { 'ui/dist/**.js' } })
    check(printed("overlap: client_script 'ui/dist/**.js' overlaps 'ui/dist'") ~= nil,
        'a client_script glob inside the dir is a warning')
    fake('luaglob', { clientScripts = { '**/*.lua' } })
    check(printed("luaglob: client_script") == nil,
        'a glob that can only match .lua never reaches a dist and is ignored')
    check(printed('luaglob: UI plugin ok') ~= nil, 'so that plugin is simply healthy')

    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

    return suiteUIPlugins
end
