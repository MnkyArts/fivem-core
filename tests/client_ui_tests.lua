--[[
    core/tests/client_ui_tests.lua — the offline suite for the client UI platform.

        lua5.4 tests/client_ui_tests.lua    (from the resource directory, or from tests/)

    Same harness as server_tests.lua: every native and runtime helper comes from
    tests/stubs.lua, so this proves the pure Lua contracts of DESIGN §38 (manifest
    validation, discovery, the focus stack, the patch queue, feeds and both request
    directions) — never in-game behaviour. Exit code is 1 when anything fails.

    One client VM per suite: import.lua, shared/config.lua, shared/ui_manifest.lua,
    then client/api.lua, client/ui.lua, client/ui_plugins.lua, client/ui_remote.lua
    in manifest order. The world-prompt suite (DESIGN §6.7) runs a second loader that
    loads client/interactions.lua between api.lua and ui.lua, the way the manifest does.
]]

local here = (arg and arg[0] or 'tests/client_ui_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
local stubs = dofile(here .. '/stubs.lua')

local passed, failed, suiteName = 0, 0, '?'
local failures = {}

local function suite(name)
    suiteName = name
end

local function show(v)
    if type(v) == 'string' then return ('%q'):format(v) end
    return tostring(v)
end

local function check(cond, label, detail)
    if cond then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    local line = ('FAIL  [%s] %s'):format(suiteName, label)
    if detail then line = line .. '\n        ' .. detail end
    failures[#failures + 1] = line
    print(line)
    return false
end

local function eq(actual, expected, label)
    return check(actual == expected, label,
        ('expected %s, got %s'):format(show(expected), show(actual)))
end

--- The most recent printed line containing `needle`, or nil.
local function printed(needle)
    for i = #stubs.printed, 1, -1 do
        if stubs.printed[i]:find(needle, 1, true) then return stubs.printed[i] end
    end
    return nil
end

--- The last NUI message, or the last one of `action`.
local function lastMessage(action)
    for i = #stubs.nuiMessages, 1, -1 do
        if not action or stubs.nuiMessages[i].action == action then return stubs.nuiMessages[i] end
    end
    return nil
end

--- 'page:open|focus|page:close' — the actions of every message since `from`, joined.
local function actionsSince(from)
    local out = {}
    for i = from, #stubs.nuiMessages do out[#out + 1] = stubs.nuiMessages[i].action end
    return table.concat(out, '|')
end

--- The focus stack keys of the last `focus` message ('page:shop|modal:confirm').
local function stackKeys()
    local message = lastMessage('focus')
    if not message or type(message.stack) ~= 'table' then return '?' end
    local keys = {}
    for i = 1, #message.stack do keys[i] = message.stack[i].key end
    return table.concat(keys, '|')
end

local CLIENT_FILES <const> = {
    'client/api.lua', 'client/ui.lua', 'client/ui_plugins.lua', 'client/ui_remote.lua',
}

--- A fresh core client VM with the UI files loaded and a clean NUI harness.
local function newClient()
    stubs.newWorld()
    stubs.clear()
    stubs.resetNui()
    stubs.resourceStates = { core = 'started' }
    stubs.tick(1000)
    local env = stubs.newEnv('client', 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    stubs.loadFile(env, 'shared/ui_manifest.lua')
    for i = 1, #CLIENT_FILES do stubs.loadFile(env, CLIENT_FILES[i]) end
    return env, env.Core
end

--- Runs `fn` as if it came through exports.core:call from `resource` (so
--- Registry.getCaller() reports it), then restores the previous caller.
local function asPlugin(Core, resource, fn, ...)
    Core.Registry.setCaller(resource)
    local ok, err = pcall(fn, ...)
    Core.Registry.setCaller(nil)
    if not ok then error(err, 0) end
end

--------------------------------------------------------------------------------
-- suites
--------------------------------------------------------------------------------

--- shared/ui_manifest.lua (DESIGN §38.4): the pure rules, one by one.
local function suiteManifest()
    suite('ui manifest')
    local env = newClient()
    local M = env.UIManifest
    eq(M.API_VERSION, 1, 'this core implements UI API 1')

    eq(M.dirOk('ui/dist'), true, 'a relative folder is accepted')
    eq(M.dirOk('ui/../secret'), false, "'..' is refused")
    eq(M.dirOk('/ui/dist'), false, 'an absolute path is refused')
    eq(M.dirOk('https://evil.example/x'), false, 'a URL is refused')
    eq(M.dirOk('ui/dist/'), false, 'a trailing slash is refused')
    eq(M.dirOk(''), false, 'an empty folder is refused')
    eq(M.dirOk(42), false, 'a non-string is refused')

    local function manifest(extra)
        local m = { id = 'inventory', apiVersion = 1, entry = 'plugin.a81f3c.js',
            css = { 'plugin.982ca1.css' }, build = 'a81f3c982c', load = 'eager',
            preload = {}, pages = { 'inventory', 'inventory_hotbar' } }
        for key, value in pairs(extra or {}) do
            if value == '<nil>' then value = nil end
            m[key] = value
        end
        return m
    end
    local function bad(extra, label)
        local ok, err = M.validate('inventory', manifest(extra), 'ui/dist')
        return check(ok == false and type(err) == 'string', label, tostring(err))
    end

    local ok, norm = M.validate('inventory', manifest(), 'ui/dist')
    eq(ok, true, 'a well-formed manifest validates')
    eq(norm.entry, 'plugin.a81f3c.js', 'the entry survives normalisation')
    eq(#norm.css, 1, 'the stylesheet list survives')
    eq(#norm.pages, 2, 'the page list survives')
    eq(norm.id, 'inventory', 'the id is the resource name')
    local _, stamped = M.validate('inventory', manifest({ sdk = '1.0.0', vue = '3.5.42' }), 'ui/dist')
    eq(stamped.sdk, '1.0.0', 'the sdk stamp survives for the diagnostics panel')
    eq(stamped.vue, '3.5.42', 'and so does the vue version')
    local _, unstamped = M.validate('inventory', manifest({ vue = string.rep('v', 33) }), 'ui/dist')
    eq(unstamped.vue, nil, 'an over-long stamp is dropped, never an error')

    local _, defaults = M.validate('inventory', manifest({ load = '<nil>', css = '<nil>',
        preload = '<nil>', pages = '<nil>', build = '<nil>' }), 'ui/dist')
    eq(defaults.load, 'eager', 'load defaults to eager')
    eq(#defaults.css, 0, 'css defaults to an empty list')
    eq(#defaults.preload, 0, 'preload defaults to an empty list')
    eq(defaults.build, '', 'build defaults to an empty string')

    local idOk, idErr = M.validate('inventory', manifest({ id = 'Inventory' }), 'ui/dist')
    eq(idOk, false, 'the id must match the resource exactly, case included')
    check((idErr or ''):find('must be the resource name', 1, true) ~= nil,
        'the id error names the rule', idErr)

    local verOk, verErr, verState = M.validate('inventory', manifest({ apiVersion = 2 }), 'ui/dist')
    eq(verOk, false, 'a foreign apiVersion is refused')
    eq(verState, 'incompatible', 'and reported as incompatible, not failed')
    check((verErr or ''):find('API 2', 1, true) and (verErr or ''):find('provides 1', 1, true),
        'the version error names both numbers', verErr)
    bad({ apiVersion = '1' }, 'a non-integer apiVersion is refused')

    bad({ entry = 'plugin.txt' }, 'an entry that is not .js/.mjs is refused')
    bad({ entry = '../plugin.js' }, "an entry with '..' is refused")
    bad({ entry = '/plugin.js' }, 'an absolute entry is refused')
    bad({ entry = 'plugin a.js' }, 'an entry outside the charset is refused')
    eq((M.validate('inventory', manifest({ entry = 'chunks/main.mjs' }), 'ui/dist')), true,
        '.mjs is a valid entry')

    local nineCss = {}
    for i = 1, 9 do nineCss[i] = ('a%d.css'):format(i) end
    bad({ css = nineCss }, 'at most 8 stylesheets')
    bad({ css = { 'plugin.js' } }, 'a css entry must end in .css')
    bad({ css = 'plugin.css' }, 'css must be an array')
    local preloads = {}
    for i = 1, 17 do preloads[i] = ('chunks/c%d.js'):format(i) end
    bad({ preload = preloads }, 'at most 16 preloads')
    bad({ build = string.rep('x', 65) }, 'build is at most 64 characters')
    bad({ load = 'later' }, 'load is eager or lazy')
    eq(select(2, M.validate('inventory', manifest({ load = 'lazy' }), 'ui/dist')).load, 'lazy',
        'lazy is accepted')
    bad({ pages = { 'ok', 'not an id' } }, 'every page id is a plain id')
    bad({ pages = 'inventory' }, 'pages must be an array')

    local longName = string.rep('a', 226) .. '.js'
    bad({ entry = longName }, 'a file over the 255-char vfs limit is refused')
    eq((M.validate('inventory', manifest({ entry = longName }))), true,
        'the same name fits when no dir is prepended')

    eq((M.validate('inventory', 'not a table', 'ui/dist')), false, 'a non-object manifest is refused')
    eq((M.validate(nil, manifest(), 'ui/dist')), false, 'validate() needs a resource name')
end

--- Declares one fake UI-plugin resource for the metadata/file natives.
local function fakePlugin(name, opts)
    opts = opts or {}
    stubs.resourceStates[name] = 'started'
    stubs.resourceMeta[name] = { core_ui = { opts.dir or 'ui/dist' } }
    if opts.noKey then stubs.resourceMeta[name] = {} end
    local body = opts.raw
    if body == nil then
        body = stubs.json.encode(opts.manifest or { id = name, apiVersion = 1,
            entry = 'plugin.abc123.js', css = { 'plugin.def456.css' }, build = 'abc123',
            load = 'eager', preload = {}, pages = { name } })
    end
    stubs.resourceFiles[name] = { [(opts.dir or 'ui/dist') .. '/manifest.json'] = body }
end

--- client/ui_plugins.lua (DESIGN §38.4): discovery, generations, replay, ui_plugin.
local function suiteDiscovery()
    suite('ui plugins')
    local env, Core = newClient()
    local UI = Core.UI
    local ready, failedHook = {}, {}
    Core.on('uiPluginReady', function(id) ready[#ready + 1] = id end)
    Core.on('uiPluginFailed', function(id, err) failedHook[#failedHook + 1] = id .. ': ' .. tostring(err) end)

    -- a resource without core_ui is never probed
    stubs.resourceStates.plain = 'started'
    stubs.triggerOn(env, 'onClientResourceStart', 0, 'plain')
    eq(#stubs.nuiOf('plugin:register'), 0, 'a resource without core_ui is never probed')
    eq(#UI.plugins(), 0, 'and never appears in the plugin list')

    -- an unreadable manifest is a loud, one-line error naming the resource and the fix
    fakePlugin('broken', { raw = false })
    stubs.triggerOn(env, 'onClientResourceStart', 0, 'broken')
    local line = printed('broken: ui/dist/manifest.json is not readable')
    check(line ~= nil, 'an unreadable manifest names the resource and the file', line)
    check(line ~= nil and line:find('npm run build in broken/ui', 1, true) ~= nil,
        'and the fix', line)
    check(line ~= nil and line:find("files {}", 1, true) ~= nil, 'and the files {} rule', line)
    eq(#stubs.nuiOf('plugin:register'), 0, 'a broken manifest is never sent to the shell')
    eq(UI.plugins()[1].state, 'failed', 'but it is listed as failed')
    check(#failedHook == 1, 'and fires uiPluginFailed')

    -- a good manifest registers once, with its base URL and generation 1
    fakePlugin('inventory')
    stubs.triggerOn(env, 'onClientResourceStart', 0, 'inventory')
    local reg = lastMessage('plugin:register')
    eq(reg and reg.id, 'inventory', 'a valid plugin is registered')
    eq(reg and reg.generation, 1, 'the first activation is generation 1')
    eq(reg and reg.base, 'https://cfx-nui-inventory/ui/dist/', 'base is the cfx-nui origin of its dir')
    eq(reg and reg.manifest and reg.manifest.entry, 'plugin.abc123.js', 'the normalised manifest travels')
    eq(reg and reg.dev, nil, 'no dev override without Config.UI.Dev')
    eq(UI.isPluginReady('inventory'), false, 'registered is not ready')

    -- the shell answers: ready, with the generation it was given
    stubs.nui('ui_plugin', { id = 'inventory', generation = 1, state = 'ready', ms = 38,
        pages = { 'inventory', 'inventory_hotbar' } })
    eq(UI.isPluginReady('inventory'), true, 'ui_plugin ready flips the state')
    eq(ready[1], 'inventory', 'and fires uiPluginReady')
    check(printed('inventory: UI plugin ready in 38 ms (2 pages)') ~= nil, 'and prints one line')
    stubs.nui('ui_plugin', { id = 'inventory', generation = 99, state = 'failed', error = 'stale' })
    eq(UI.isPluginReady('inventory'), true, 'a stale generation is ignored')

    -- stop drops it; the next start is generation 2
    stubs.triggerOn(env, 'onResourceStop', 0, 'inventory')
    eq(lastMessage('plugin:unregister').id, 'inventory', 'a stop unregisters the plugin')
    eq(UI.isPluginReady('inventory'), false, 'and forgets its state')
    stubs.triggerOn(env, 'onClientResourceStart', 0, 'inventory')
    eq(lastMessage('plugin:register').generation, 2, 'the generation survives the stop')

    -- ui_ready replays every plugin BEFORE the pages
    UI.registerPage('inventory_page', { type = 'page' })
    local from = #stubs.nuiMessages + 1
    stubs.nui('ui_ready', {})
    local order = actionsSince(from)
    local devAt = order:find('dev:set', 1, true)
    local pluginAt = order:find('plugin:register', 1, true)
    local pageAt = order:find('page:register', 1, true)
    check(devAt and pluginAt and pageAt and devAt < pluginAt and pluginAt < pageAt,
        'ui_ready replays dev:set, then plugins, then pages', order)
    eq(lastMessage('plugin:register').generation, 2, 'the replay keeps the generation')

    --- How often `res` was registered, and its last registration.
    local function registrationsOf(res)
        local count, last = 0, nil
        for _, message in ipairs(stubs.nuiOf('plugin:register')) do
            if message.id == res then count, last = count + 1, message end
        end
        return count, last
    end

    -- core's own start pass must not re-register what onClientResourceStart found
    fakePlugin('twice')
    stubs.triggerOn(env, 'onClientResourceStart', 0, 'twice')
    eq((registrationsOf('twice')), 1, 'a fresh resource registers once')
    stubs.tick(1)                       -- the one-shot startup scan runs here
    local count, last = registrationsOf('twice')
    eq(count, 1, "core's start pass skips a resource that is already registered")
    eq(last.generation, 1, 'so no generation is burned')

    -- /uidev pins a dev origin for the SESSION: a restart must keep it
    env.Config.UI.Dev.Enabled = true
    local uidev = env.__vm.commands.uidev
    check(uidev ~= nil, '/uidev is registered')
    uidev.fn(0, { 'twice', 'http://localhost:5173' })
    last = lastMessage('plugin:register')
    eq(last.dev and last.dev.origin, 'http://localhost:5173', '/uidev re-registers with the origin')
    eq(last.generation, 2, 'as a new activation')
    stubs.triggerOn(env, 'onResourceStop', 0, 'twice')
    stubs.triggerOn(env, 'onClientResourceStart', 0, 'twice')
    last = lastMessage('plugin:register')
    eq(last.dev and last.dev.origin, 'http://localhost:5173', 'a restart keeps the dev origin')
    eq(last.generation, 3, 'with the next generation')
    for _, row in ipairs(UI.plugins()) do
        if row.id == 'twice' then
            eq(row.dev, 'http://localhost:5173', 'Core.UI.plugins() shows the pinned dev origin')
        end
    end
    uidev.fn(0, { 'twice', 'off' })
    eq(lastMessage('plugin:register').dev, nil, '/uidev off drops back to the built bundle')
    for _, row in ipairs(UI.plugins()) do
        if row.id == 'twice' then eq(row.dev, nil, 'and the row shows no origin again') end
    end
    uidev.fn(0, { 'twice', 'http://evil.example:80' })
    check(printed('is not a localhost origin') ~= nil, 'a non-localhost origin is refused')
    eq(lastMessage('plugin:register').dev, nil, 'and changes nothing')
    env.Config.UI.Dev.Enabled = false
    uidev.fn(0, { 'twice', 'http://localhost:5173' })
    check(printed('/uidev needs Config.UI.Dev.Enabled') ~= nil, 'production never reads Config.UI.Dev')
end

--- client/ui.lua focus stack (DESIGN §38.9) and the page registration rules.
local function suiteFocus()
    suite('ui focus stack')
    local env, Core = newClient()
    local UI = Core.UI
    stubs.nui('ui_ready', {})

    -- registerPage: owner travels, 'modal' is a type, script/style are gone
    asPlugin(Core, 'shop', function()
        eq(UI.registerPage('shop', { type = 'page', keepInput = true }), true, 'a page registers')
        eq(UI.registerPage('shop_confirm', { type = 'modal' }), true, "'modal' is a page type")
        eq(UI.registerPage('shop_hud', { type = 'overlay' }), true, 'an overlay registers')
        eq(UI.registerPage('shop_legacy', { type = 'page', script = 'ui/dist/page.js' }), false,
            'script is refused')
        eq(UI.registerPage('shop_legacy2', { type = 'page', style = 'ui/dist/page.css' }), false,
            'style is refused')
    end)
    local reg = stubs.nuiOf('page:register')
    eq(reg[1].owner, 'shop', 'page:register names the owning resource')
    eq(reg[1].script, nil, 'page:register no longer carries a script URL')
    eq(reg[2].type, 'modal', 'the modal type reaches the shell')
    eq(#reg, 3, 'a refused registration sends nothing')
    check(printed('DESIGN §38') ~= nil, 'the refusal points at the contract')

    UI.open('shop_hud')
    eq(stubs.nuiFocus.focus, false, 'an overlay takes no focus')
    eq(stackKeys(), '', 'and adds no stack entry')

    UI.open('shop', { gold = 1 })
    eq(stubs.nuiFocus.focus, true, 'a page takes focus')
    eq(stubs.nuiFocus.cursor, true, 'with the cursor')
    eq(stubs.nuiFocus.keepInput, true, 'and its own keepInput')
    eq(stackKeys(), 'page:shop', 'the page is the only stack entry')
    eq(lastMessage('focus').stack[1].owner, 'shop', 'the entry names the owner')
    eq(lastMessage('focus').stack[1].layer, 'page', 'and its layer')

    UI.open('shop_confirm')
    eq(stackKeys(), 'page:shop|modal:shop_confirm', 'a modal stacks above the page')
    eq(stubs.nuiFocus.keepInput, false, 'the TOP entry decides keepInput')
    asPlugin(Core, 'shop', function() UI.registerPage('shop_confirm2', { type = 'modal', keepInput = true }) end)
    UI.open('shop_confirm2')
    eq(stackKeys(), 'page:shop|modal:shop_confirm|modal:shop_confirm2', 'two modals stack in open order')
    eq(stubs.nuiFocus.keepInput, true, 'and the new top decides again')
    UI.open('shop_confirm')
    eq(stackKeys(), 'page:shop|modal:shop_confirm|modal:shop_confirm2',
        're-opening an open modal only changes its props')

    local alertResult
    env.CreateThread(function() alertResult = UI.alert({ message = 'sure?' }) end)
    eq(stackKeys(), 'page:shop|modal:shop_confirm|modal:shop_confirm2|system:alert',
        'a built-in sits above every plugin modal')
    eq(stubs.nuiFocus.keepInput, false, 'a system modal never keeps game input')
    stubs.nui('alert_result', { id = lastMessage('alert:open').id, confirmed = true })
    stubs.tick(1)
    eq(alertResult, true, 'the built-in resolves with its answer')
    eq(stackKeys(), 'page:shop|modal:shop_confirm|modal:shop_confirm2', 'and hands focus back below')

    UI.close()
    eq(stackKeys(), 'page:shop|modal:shop_confirm', 'close(nil) closes the TOP modal')
    UI.close()
    eq(stackKeys(), 'page:shop', 'then the next one')
    eq(stubs.nuiFocus.keepInput, true, "and restores the page's keepInput")
    UI.close()
    eq(stackKeys(), '', 'then the page')
    eq(stubs.nuiFocus.focus, false, 'an empty stack releases focus')

    -- chat (§23) is the lowest layer and never survives anything above it
    UI['chat.setTyping'](true)
    eq(stackKeys(), 'chat', 'chat typing is a stack entry')
    eq(stubs.nuiFocus.focus, true, 'it holds the keyboard')
    eq(stubs.nuiFocus.cursor, false, 'never the cursor')
    UI.open('shop_confirm')
    eq(UI['chat.isTyping'](), false, 'a modal drops chat typing')
    eq(stackKeys(), 'modal:shop_confirm', 'and takes the stack alone')

    -- a different exclusive page replaces the whole layer
    asPlugin(Core, 'bank', function() UI.registerPage('bank', { type = 'page' }) end)
    UI.open('bank')
    eq(stackKeys(), 'page:bank', 'opening another page closes every plugin modal')
    eq(UI.isOpen('shop_confirm'), false, 'the modal really closed')
    eq(UI.isOpen('bank'), true, 'isOpen covers the page')
    UI.close()

    -- §31: hiding the shell closes system modal, plugin modals and the page
    UI.open('shop')
    UI.open('shop_confirm')
    local hiddenAlert
    env.CreateThread(function() hiddenAlert = UI.alert({ message = 'x' }) end)
    eq(stackKeys(), 'page:shop|modal:shop_confirm|system:alert', 'all three kinds are open')
    UI.hide('test')
    stubs.tick(1)
    eq(stackKeys(), '', 'hiding the shell empties the stack')
    eq(hiddenAlert, false, 'the hidden built-in resolves like ESC')
    eq(stubs.nuiFocus.focus, false, 'and focus is released')
    UI.show('test')

    -- the watchdog never touches focus that is correct
    local calls = #stubs.nuiFocus.calls
    stubs.tick(600)
    eq(#stubs.nuiFocus.calls, calls, 'the watchdog is quiet while the stack is empty')
    UI.open('shop')
    UI.open('shop_confirm')
    calls = #stubs.nuiFocus.calls
    stubs.tick(600)
    eq(#stubs.nuiFocus.calls, calls, 'and never steals focus a modal still holds')

    -- a stopping resource takes its page and its modal with it
    eq(stackKeys(), 'page:shop|modal:shop_confirm', 'page + modal of one owner')
    stubs.triggerOn(env, 'onResourceStop', 0, 'shop')
    eq(stackKeys(), '', 'the registry sweep closes both')
    eq(stubs.nuiFocus.focus, false, 'and releases focus')
    eq(UI.isOpen('shop'), false, 'the page is gone')
    eq(UI.registerPage('shop', { type = 'page' }), true, 'its id is free again')
end

--- UI.update / UI.patch: the queue, the ordering rule and the replay copy (§38.10).
local function suitePatch()
    suite('ui patch queue')
    local env, Core = newClient()
    local UI = Core.UI
    stubs.nui('ui_ready', {})
    asPlugin(Core, 'shop', function() UI.registerPage('shop', { type = 'page' }) end)
    UI.open('shop', { gold = 10, slots = { { id = 'a' }, { id = 'b' } }, meta = { tier = 1 } })

    local from = #stubs.nuiMessages + 1
    eq(UI.update('shop', { gold = 11 }), true, 'update accepts a partial')
    eq(UI.update('shop', { silver = 3 }), true, 'a second update queues too')
    eq(UI.patch('shop', 'meta.tier', 2), true, 'patch accepts a deep path')
    eq(#stubs.nuiMessages, from - 1, 'nothing leaves synchronously')
    stubs.tick(1)
    local patch = lastMessage('page:patch')
    eq(#patch.ops, 3, 'three ops coalesce into ONE page:patch')
    eq(patch.ops[1].p, 'gold', 'the first op keeps its order')
    eq(patch.ops[1].v, 11, 'and its value')
    eq(patch.ops[3].p, 'meta.tier', 'a deep path travels as written')
    eq(#stubs.nuiOf('page:patch'), 1, 'exactly one message per tick')

    from = #stubs.nuiMessages + 1
    UI.update('shop', { gold = 12 })
    UI.send('shop', 'ping', {})
    eq(actionsSince(from), 'page:patch|page:event', 'any other message flushes the queue first')

    -- the replay copy: ui_ready must re-open with CURRENT state
    UI.patch('shop', 'slots.1.id', 'z')
    UI.patch('shop', 'deep.a.b', 7)
    UI.patch('shop', 'silver', nil)
    stubs.tick(1)
    local del = lastMessage('page:patch')
    eq(del.ops[#del.ops].p, 'silver', 'the delete is the last op')
    eq(del.ops[#del.ops].v, nil, 'a delete carries no value')
    stubs.nui('ui_ready', {})
    local reopened
    for _, message in ipairs(stubs.nuiOf('page:open')) do
        if message.id == 'shop' then reopened = message end
    end
    eq(reopened and reopened.props.gold, 12, 'the replay copy has the merged value')
    eq(reopened and reopened.props.silver, nil, 'and lost the deleted key')
    eq(reopened and reopened.props.slots[1].id, 'z', 'a 1-based index is that very list element')
    eq(reopened and reopened.props.slots[2].id, 'b', 'the rest of the list is untouched')
    eq(reopened and reopened.props.deep.a.b, 7, 'intermediate tables are created on the way')
    eq(reopened and reopened.props.meta.tier, 2, 'the deep value is current')

    -- more than 64 ops in one tick: one snapshot instead
    from = #stubs.nuiMessages + 1
    for i = 1, 65 do UI.patch('shop', 'bulk' .. i, i) end
    stubs.tick(1)
    local snapshot = lastMessage('page:open')
    eq(snapshot.id, 'shop', 'an overflowing queue leaves as one page:open')
    eq(snapshot.props.bulk65, 65, 'the snapshot carries every applied op')
    eq(actionsSince(from), 'page:open', 'and nothing else')

    -- validation: ownership, paths and values
    from = #stubs.nuiMessages + 1
    asPlugin(Core, 'thief', function()
        eq(UI.update('shop', { gold = 0 }), false, 'a foreign resource may not update a page')
        eq(UI.patch('shop', 'gold', 0), false, 'nor patch it')
    end)
    check(printed("does not own that page") ~= nil, 'and is told why')
    eq(UI.update('nope', { a = 1 }), false, 'an unregistered page is refused')
    eq(UI.update('shop', 'no'), false, 'a non-table partial is refused')
    eq(UI.update('shop', { ['bad key'] = 1 }), false, 'a key outside [%w_%-] is refused')
    eq(UI.patch('shop', 'a..b', 1), false, 'an empty path segment is refused')
    eq(UI.patch('shop', 'a.b.c.d.e.f.g.h.i', 1), false, 'more than 8 segments is refused')
    eq(UI.patch('shop', '', 1), false, 'an empty path is refused')
    eq(UI.patch('shop', 'a', print), false, 'a function value is refused')
    stubs.tick(1)
    eq(actionsSince(from), '', 'a refused write queues nothing')
end

--- The two path rules of §38.10 (R1 list element, R2 map key) and the hole warning.
local function suitePaths()
    suite('ui patch paths')
    local env, Core = newClient()
    local UI = Core.UI
    stubs.nui('ui_ready', {})
    UI.registerPage('p', { type = 'page' })

    --- Opens 'p' with `props`, applies `path` = `value`, and returns the replay copy.
    local function apply(props, path, value)
        UI.open('p', props)
        eq(UI.patch('p', path, value), true, 'patch ' .. path)
        stubs.tick(1)
        stubs.nui('ui_ready', {})
        local out
        for _, message in ipairs(stubs.nuiOf('page:open')) do
            if message.id == 'p' then out = message end
        end
        return out and out.props
    end

    -- R1: a list indexed 1..#t+1
    local props = apply({ list = { 'a', 'b', 'c' } }, 'list.2', 'B')
    eq(props.list[2], 'B', 'R1: an in-range index writes that very element')
    eq(#props.list, 3, 'and the list keeps its length')
    props = apply({ list = { 'a', 'b' } }, 'list.3', 'c')
    eq(props.list[3], 'c', 'R1: #t + 1 appends')
    eq(#props.list, 3, 'and the list grew by one')
    props = apply({ list = {} }, 'list.1', 'first')
    eq(props.list[1], 'first', 'R1: an empty table takes index 1')

    -- R2: map keys
    props = apply({ map = {} }, 'map.12', 'v')
    eq(props.map['12'], 'v', 'R2: an empty table + an out-of-range index is a STRING key')
    eq(props.map[12], nil, 'and not an integer key')
    props = apply({ map = { name = 'x' } }, 'map.12', 'v')
    eq(props.map['12'], 'v', 'R2: a map with string keys takes the string key')
    props = apply({ map = { [7] = 'seven', name = 'x' } }, 'map.7', 'SEVEN')
    eq(props.map[7], 'SEVEN', 'R2: an existing integer key in a sparse map wins')
    eq(props.map['7'], nil, 'and no string twin is created')

    -- out of range on a NON-EMPTY list: applied as a map key, warned once
    local before = #stubs.printed
    props = apply({ list = { 'a', 'b' } }, 'list.9', 'far')
    eq(props.list['9'], 'far', 'an out-of-range index falls back to the string key')
    eq(props.list[1], 'a', 'and the list itself is untouched')
    check(printed('the index is outside the list') ~= nil, 'and it warns')
    local lines = #stubs.printed - before
    UI.patch('p', 'list.9', 'far again')
    eq(#stubs.printed - before, lines, 'the same page and path warns only once')

    -- deleting the last element vs. the middle
    props = apply({ list = { 'a', 'b', 'c' } }, 'list.3', nil)
    eq(#props.list, 2, 'deleting the last element shrinks the list')
    check(printed('deleting in the middle') == nil, 'and never warns')
    props = apply({ list = { 'a', 'b', 'c' } }, 'list.1', nil)
    eq(props.list[1], nil, 'deleting in the middle still applies')
    check(printed('deleting in the middle of a list leaves a hole') ~= nil, 'but warns')

    -- F2: a page that is not showing is a silent no-op
    UI.registerPage('closed', { type = 'page' })
    before = #stubs.printed
    local from = #stubs.nuiMessages + 1
    eq(UI.update('closed', { a = 1 }), false, 'update on a page that is not open returns false')
    eq(UI.patch('closed', 'a', 1), false, 'patch too')
    stubs.tick(1)
    eq(actionsSince(from), '', 'and nothing goes on the wire')
    eq(#stubs.printed, before, 'silently: no log line either')
    UI.open('closed')
    eq(UI.update('closed', { a = 1 }), true, 'the same call works once it is open')
    UI.registerPage('ovl', { type = 'overlay' })
    UI.open('ovl')
    eq(UI.update('ovl', { a = 1 }), true, 'an overlay counts as showing')
    asPlugin(Core, 'thief', function()
        eq(UI.update('closed', { a = 2 }), false, 'a foreign owner is still refused')
    end)
    check(printed('does not own that page') ~= nil, 'and still says why')

    -- F7: page state comes from trusted Lua — type-checked, not size-bounded
    UI.open('p', {})
    eq(UI.update('p', { blob = string.rep('x', 40000) }), true, 'a long string is accepted')
    local wide = {}
    for i = 1, 400 do wide['k' .. i] = i end
    eq(UI.update('p', { wide = wide }), true, 'a wide table is accepted')
    eq(UI.patch('p', 'deep', wide), true, 'patch accepts it too')
    eq(UI.update('p', { fn = print }), false, 'but a function is still refused')
    eq(UI.feed('dash', { blob = string.rep('x', 40000) }), false, 'feed values stay bounded')
end

--- UI.feed / UI.isFeedActive: coalescing, one timer, subscriber presence (§38.10).
local function suiteFeed()
    suite('ui feeds')
    local env, Core = newClient()
    local UI = Core.UI
    stubs.nui('ui_ready', {})

    asPlugin(Core, 'speedo', function()
        eq(UI.feed({ speed = 100 }), true, 'feed defaults to the calling resource')
        eq(UI.feed({ speed = 132, rpm = 0.7 }), true, 'a second write coalesces')
    end)
    eq(UI.feed('dash', { gear = 4 }), true, 'an explicit channel is accepted')
    eq(#stubs.nuiOf('feed'), 0, 'nothing leaves synchronously')
    stubs.tick(50)
    local feed = lastMessage('feed')
    eq(feed.c.speedo.speed, 132, 'the latest value per key wins')
    eq(feed.c.speedo.rpm, 0.7, 'every key of the channel rides along')
    eq(feed.c.dash.gear, 4, 'and every dirty channel rides ONE message')
    eq(#stubs.nuiOf('feed'), 1, 'exactly one feed message')
    stubs.tick(1000)
    eq(#stubs.nuiOf('feed'), 1, 'no timer runs while nothing is dirty')
    UI.feed('dash', { gear = 5 })
    stubs.tick(50)
    eq(#stubs.nuiOf('feed'), 2, 'the next write arms the timer again')
    eq(lastMessage('feed').c.speedo, nil, 'a clean channel is not re-sent')

    eq(UI.isFeedActive('speedo'), false, 'nothing subscribes by default')
    stubs.nui('ui_feed', { channel = 'speedo', active = true })
    eq(UI.isFeedActive('speedo'), true, 'ui_feed reports the first subscriber')
    asPlugin(Core, 'speedo', function()
        eq(UI.isFeedActive(), true, 'isFeedActive defaults to the calling resource')
    end)
    stubs.nui('ui_feed', { channel = 'speedo', active = false })
    eq(UI.isFeedActive('speedo'), false, 'and the last unsubscribe')
    stubs.nui('ui_feed', { channel = 'speedo', active = true })
    stubs.nui('ui_ready', {})
    eq(UI.isFeedActive('speedo'), false, 'a shell reload clears every subscription')
    stubs.nui('ui_feed', { channel = 'speedo', active = true })
    stubs.triggerOn(env, 'onResourceStop', 0, 'speedo')
    eq(UI.isFeedActive('speedo'), false, 'a stopping resource drops its channel')

    eq(UI.feed('bad channel', { a = 1 }), false, 'a channel outside [%w_%-] is refused')
    eq(UI.feed('dash', 'x'), false, 'values must be a table')
    eq(UI.feed('dash', { ['bad key'] = 1 }), false, 'a key outside [%w_%-] is refused')
    eq(UI.feed('dash', { fn = print }), false, 'a function value is refused')
end

--- NUI → Lua requests (`ui_request`, held cb) and Lua → NUI (`UI.request`), §38.8.
local function suiteRequests()
    suite('ui requests')
    local env, Core = newClient()
    local UI = Core.UI
    stubs.nui('ui_ready', {})

    asPlugin(Core, 'shop', function()
        eq(UI.onRequest('shop:buy', function(data) return { bought = data.item, ok = true } end), true,
            'onRequest accepts a handler')
        eq(UI.onRequest('shop:boom', function() error('kaboom') end), true, 'and a failing one')
        eq(UI.onRequest('shop:weird', function() return { fn = print } end), true, 'and an unsendable one')
        eq(UI.onRequest('shop:slow', function() env.Wait(20000) return { late = true } end), true,
            'and a slow one')
        eq(UI.onRequest('bad name!', print), false, 'a name outside the charset is refused')
        eq(UI.onRequest('shop:x', 'not callable'), false, 'a non-callable handler is refused')
    end)

    local answer = stubs.nui('ui_request', { c = 'shop', n = 'shop:buy', d = { item = 'bread' } })
    eq(answer.ok, true, 'a handler answers its channel')
    eq(answer.data.bought, 'bread', 'with the payload it was given')

    answer = stubs.nui('ui_request', { c = 'shop', n = 'shop:boom', d = {} })
    eq(answer.ok, false, 'a throwing handler answers an error')
    eq(answer.error.code, 'handler_error', 'with the handler_error code')
    check((answer.error.message or ''):find('kaboom', 1, true) ~= nil, 'and the message')

    answer = stubs.nui('ui_request', { c = 'shop', n = 'shop:weird', d = {} })
    eq(answer.ok, false, 'a result that cannot be encoded is an error')
    eq(answer.error.code, 'bad_result', 'with the bad_result code')

    eq(stubs.nui('ui_request', { c = 'shop', n = 'shop:missing' }).error.code, 'no_handler',
        'an unknown name answers no_handler')
    eq(stubs.nui('ui_request', { c = 'nobody', n = 'shop:buy' }).error.code, 'no_handler',
        'an unknown channel answers no_handler')
    eq(stubs.nui('ui_request', { c = 'bad channel', n = 'shop:buy' }).error.code, 'bad_request',
        'a malformed channel answers bad_request')
    eq(stubs.nui('ui_request', { c = 'shop', n = 'bad name!' }).error.code, 'bad_request',
        'a malformed name answers bad_request')
    eq(stubs.nui('ui_request', { c = 'shop', n = 'shop:buy', d = 'x' }).error.code, 'bad_request',
        'a non-table payload answers bad_request')

    -- a slow handler: the timeout answers, the late return must not answer twice
    local first, answers = stubs.nui('ui_request', { c = 'shop', n = 'shop:slow', d = {} })
    eq(first, nil, 'a yielding handler holds the cb open')
    stubs.tick(10001)
    eq(#answers, 1, 'the timeout answers exactly once')
    eq(answers[1].error.code, 'timeout', 'with the timeout code')
    stubs.tick(20000)
    eq(#answers, 1, 'the late handler return does not answer a second time')

    -- the owner stops while a request is in flight
    local _, stopping = stubs.nui('ui_request', { c = 'shop', n = 'shop:slow', d = {} })
    stubs.triggerOn(env, 'onResourceStop', 0, 'shop')
    eq(#stopping, 1, 'a stopping resource answers its held requests')
    eq(stopping[1].error.code, 'resource_stopped', 'with resource_stopped')
    eq(stubs.nui('ui_request', { c = 'shop', n = 'shop:buy' }).error.code, 'no_handler',
        'and its handlers are gone')
    stubs.tick(30000)

    -- offRequest
    asPlugin(Core, 'shop2', function()
        UI.onRequest('ping', function() return 'pong' end)
        eq(UI.offRequest('ping'), true, 'offRequest removes a handler')
        eq(UI.offRequest('ping'), false, 'and refuses a second time')
    end)
    eq(stubs.nui('ui_request', { c = 'shop2', n = 'ping' }).error.code, 'no_handler',
        'a removed handler is unreachable')

    -- Lua -> NUI
    UI.registerPage('shop_page', { type = 'page' })
    local ok, value
    env.CreateThread(function() ok, value = UI.request('shop_page', 'refresh', { a = 1 }) end)
    local request = lastMessage('page:request')
    eq(request.name, 'refresh', 'UI.request sends page:request')
    eq(request.id, 'shop_page', 'to the page it names')
    check(request.rid ~= nil, 'with a request id')
    stubs.nui('ui_response', { rid = 99999, ok = true, data = {} })
    eq(ok, nil, 'an unknown rid is ignored')
    stubs.nui('ui_response', { rid = request.rid, ok = true, data = { n = 5 } })
    stubs.tick(1)
    eq(ok, true, 'the answer resolves the await')
    eq(value and value.n, 5, 'with the data the shell sent')

    env.CreateThread(function() ok, value = UI.request('shop_page', 'refresh') end)
    stubs.tick(10001)
    eq(ok, false, 'a silent shell times the request out')
    eq(value, 'timeout', 'with the timeout code')

    env.CreateThread(function() ok, value = UI.request('shop_page', 'refresh') end)
    stubs.nui('ui_ready', {})
    stubs.tick(1)
    eq(value, 'shell_reloaded', 'a shell reload fails every pending request')

    env.CreateThread(function() ok, value = UI.request('shop_page', 'refresh', nil, 60000) end)
    stubs.tick(30001)
    eq(value, 'timeout', 'a caller timeout is clamped to Config.UI.RequestMaxMs')

    eq(select(2, UI.request('nope', 'refresh')), 'no_target', 'an unknown target is refused')
    eq(select(2, UI.request('shop_page', 'bad name!')), 'bad_request', 'a bad name is refused')

    -- the seam is core-internal: a plugin must not reach it through the export
    local call = stubs.exports.core and stubs.exports.core.call
    check(type(call) == 'function', 'the call export exists')
    eq(call('plugin', 'UI', 'isFeedActive', 'dash'), false, 'Core.UI is reachable from a plugin')
    local reached = pcall(call, 'plugin', 'UIInternal', 'send', { action = 'x' })
    eq(reached, false, 'Core.UIInternal is blocked through the export')
    eq(select(2, pcall(call, 'plugin', 'UIInternal', 'send', {})):find('internal to core', 1, true) ~= nil,
        true, 'and says so')

    local fresh, freshCore = newClient()
    freshCore.UI.registerPage('later', { type = 'page' })
    eq(select(2, freshCore.UI.request('later', 'refresh')), 'not_ready',
        'a shell that never loaded answers not_ready')
    eq(fresh.Core.UI.isFeedActive('x'), false, 'a fresh VM has no subscriptions')
end

--- server/ui.lua → client/ui_remote.lua: the update/patch ops of core:client:ui.
local function suiteServerForward()
    suite('ui server forward')
    local env, Core = newClient()
    local UI = Core.UI
    stubs.nui('ui_ready', {})
    UI.registerPage('shop', { type = 'page' })
    UI.open('shop', { gold = 1 })

    stubs.triggerOn(env, 'core:client:ui', 65535, 'update', { 'shop', { gold = 9 } })
    stubs.tick(1)
    local patch = lastMessage('page:patch')
    eq(patch.ops[1].p, 'gold', 'the server can update a page')
    eq(patch.ops[1].v, 9, 'with its own value')
    stubs.triggerOn(env, 'core:client:ui', 65535, 'patch', { 'shop', 'meta.tier', 3 })
    stubs.tick(1)
    patch = lastMessage('page:patch')
    eq(patch.ops[1].p, 'meta.tier', 'the server can patch a page')
    eq(patch.ops[1].v, 3, 'with its own value')
    stubs.triggerOn(env, 'core:client:ui', 65535, 'patch', { 'shop', 'meta.tier' })
    stubs.tick(1)
    eq(lastMessage('page:patch').ops[1].v, nil, 'and delete a key by leaving the value out')
    stubs.triggerOn(env, 'core:client:ui', 65535, 'nope', { 'shop' })
    check(printed('unknown op nope') ~= nil, 'an op outside the allow-list is refused')
end

--------------------------------------------------------------------------------
-- world prompts (DESIGN §6.7): the projection thread, the whole set message and
-- the core_interact target
--------------------------------------------------------------------------------

--- A fresh client VM with interactions loaded in MANIFEST order: client/api.lua,
--- client/interactions.lua, client/ui.lua — ui.lua AFTER interactions.lua, because
--- project()'s sends go through the UIInternal.worldPromptBatch seam ui.lua fills in.
--- The projection thread is the one legitimate per-frame loop (Wait(0) while dots are
--- on screen), which never settles the stubs scheduler — stubs.tick() would hit its
--- 20000-step 'busy loop' guard the moment a send succeeds — so this loader CAPTURES
--- the two coroutines interactions.lua creates instead of handing them to the
--- scheduler; the suite resumes them one frame at a time (one frame = one resume)
--- and advances the virtual clock with stubs.tick() only while no frame is pending.
--- Frame order is the file's own creation order: [1] projection, [2] scan.
--- `renderer` pins Config.Interactions.WorldPrompt.Renderer, `hint` its Hint ('sprites' keeps the
--- DrawSprite + HUD text hint the native suite asserts), `focusRadius` its FocusRadius — all three
--- are read as <const> when interactions.lua loads, so they must be set before that.
local function newInteractionsClient(renderer, hint, focusRadius)
    stubs.newWorld()
    stubs.clear()
    stubs.resetNui()
    stubs.resourceStates = { core = 'started' }
    stubs.peds[stubs.clientSrc] = 101
    stubs.coords[101] = stubs.vector3(0.0, 0.0, 0.0)
    stubs.tick(1000)
    local env = stubs.newEnv('client', 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    -- the NUI suites pin the shell renderer; the scaleform suite takes the shipped default
    local wp = env.Config.Interactions.WorldPrompt
    if renderer then wp.Renderer = renderer end
    if hint then wp.Hint = hint end
    if focusRadius then wp.FocusRadius = focusRadius end
    stubs.loadFile(env, 'shared/ui_manifest.lua')
    stubs.loadFile(env, 'client/api.lua')
    local frame = {}
    local realCreateThread = env.CreateThread
    env.CreateThread = function(fn)
        local co = coroutine.create(fn)
        frame[#frame + 1] = co
        local ok, err = coroutine.resume(co)  -- the engine starts a thread to its first Wait
        if not ok then
            stubs.failures[#stubs.failures + 1] = tostring(err)
            print('[stubs] thread error: ' .. tostring(err))
        end
        return co
    end
    stubs.loadFile(env, 'client/interactions.lua')
    env.CreateThread = realCreateThread
    stubs.loadFile(env, 'client/ui.lua')
    return env, env.Core, frame
end

--- Deep copy of every worldprompts:set message so far, one item-array per message.
--- SendNUIMessage logs the REUSED WP_SENT table by reference, so an un-copied list
--- would show every "message" with the latest state (they are all one table).
local function wpSets()
    local out = {}
    for _, message in ipairs(stubs.nuiOf('worldprompts:set')) do
        local items = {}
        for i, item in ipairs(message.items) do
            items[i] = { id = item.id, x = item.x, y = item.y, focused = item.focused,
                disabled = item.disabled, keys = item.keys, label = item.label,
                icon = item.icon, description = item.description }
        end
        out[#out + 1] = items
    end
    return out
end

--- One projection frame: advances the virtual clock by `ms` (default 40 — past
--- WP_FOCUS_MS, so every frame a suite does not say otherwise is a PROJECTION frame,
--- DESIGN §6.7) and resumes the captured coroutine; a crashed thread is recorded like
--- the scheduler would. A smaller step is what drives the cadence checks below.
local function wpFrame(co, ms)
    stubs.tick(ms or 40)
    if not co or coroutine.status(co) == 'dead' then return false end
    local ok, err = coroutine.resume(co)
    if not ok then
        stubs.failures[#stubs.failures + 1] = tostring(err)
        print('[stubs] thread error: ' .. tostring(err))
    end
    return ok
end

--- The world-prompt suite: whole-set transport, focus, the disabled flag, the
--- text-UI replacement and the core_interact press (DESIGN §6.7).
local function suiteWorldPrompts()
    suite('world prompts')
    local env, Core, frame = newInteractionsClient('nui')
    local I = Core.Interactions
    local projection, scan = frame[1], frame[2]
    check(projection ~= nil and scan ~= nil and frame[3] == nil,
        'interactions.lua created exactly the projection + scan threads')
    stubs.nui('ui_ready', {})        -- the shell announced itself: worldPromptBatch sends now

    -- in reach AND looked at: focused, not disabled, and never a text-UI pill.
    -- The scan side holds regardless of the seam; the message checks are guarded,
    -- because client/ui.lua:102 (worldPromptBatch) currently calls the GLOBAL
    -- `send` (the local is declared 30 lines below), so every send errors and
    -- kills the projection thread in game — reported to the orchestrator.
    local interacted = {}
    local id = I.add({
        coords = stubs.vector3(1.0, 0.0, 0.0),
        radius = 2.0,
        label = 'Pick up Bandage',
        worldPrompt = { icon = 'hand', description = 'Bandage' },
        onInteract = function(ctx) interacted[#interacted + 1] = ctx end,
    })
    check(id ~= nil, 'the worldPrompt interaction registered', tostring(id))
    stubs.projectWorld = function() return true, 0.5, 0.5 end
    wpFrame(scan)                    -- one scan pass: ped at 1 m, entry active, prompt slot filled
    eq(#stubs.nuiOf('textui:show'), 0, 'the world prompt REPLACES the text-UI pill (no enter pill)')
    wpFrame(projection)              -- one projection pass
    local sets = wpSets()
    if #sets == 0 then
        -- everything below in THIS VM consumes the landed message, so it is all
        -- seam-dependent; the later VMs re-test what survives without a message
        check(false, 'the first changed frame sends worldprompts:set',
            'no message: client/ui.lua:104 calls the global send inside worldPromptBatch')
    else
        eq(#sets, 1, 'the first changed frame sends exactly one whole set')
        local item = sets[1][1]
        check(item ~= nil, 'the set carries the entry', 'items = ' .. tostring(#sets[1]))
        if item then
            eq(item.id, id, 'the item carries the interaction id')
            eq(item.focused, true, 'the dot the reticle is on is focused')
            eq(item.disabled, false, 'the ped is within the radius: not disabled')
            eq(item.keys, 'E', 'the display key travels')
            eq(item.label, 'Pick up Bandage', 'the label travels')
            eq(item.icon, 'hand', 'the sanitized icon travels')
            eq(item.description, 'Bandage', 'the sanitized description travels')
            eq(item.x, 0.5, 'the projected x')
            eq(item.y, 0.5, 'the projected y')
        end

        -- unchanged frame (same projection, same focus): no second set, frame by frame
        local before = #stubs.nuiOf('worldprompts:set')
        for _ = 1, 3 do wpFrame(projection) end
        eq(#stubs.nuiOf('worldprompts:set'), before, 'an unchanged frame sends nothing')

        -- setLabel: the next projection pass carries the new label
        eq(I.setLabel(id, 'New'), true, 'setLabel accepts its own entry')
        wpFrame(projection)
        local labelled = wpSets()
        item = labelled[#labelled] and labelled[#labelled][1] or nil
        if not item then
            check(false, 'setLabel changes the next message label',
                'no message after the rename: client/ui.lua:104 calls the global send inside worldPromptBatch')
        else
            eq(item.label, 'New', 'setLabel changes the next message label')
        end

        -- off-centre projection: d = (0.9 - 0.5)^2 = 0.16 > FocusRadius^2 0.0225
        stubs.projectWorld = function() return true, 0.5, 0.9 end
        wpFrame(projection)
        item = wpSets()[#wpSets()][1]
        eq(item and item.focused, false, 'a dot far from the reticle is not focused')

        -- beyond the radius but inside promptRange: still sent, as a disabled dot
        stubs.projectWorld = function() return true, 0.5, 0.5 end  -- re-centre: the focus test
        stubs.coords[101] = stubs.vector3(5.0, 0.0, 0.0)
        wpFrame(scan)                -- re-scan at 4 m: the entry stops being active, stays prompted
        wpFrame(projection)
        local outSets = wpSets()
        item = outSets[#outSets] and outSets[#outSets][1] or nil
        if not item then
            check(false, 'the out-of-reach dot is still sent, disabled',
                'no message after the walk-out: client/ui.lua:104 calls the global send inside worldPromptBatch')
        else
            eq(item.disabled, true, 'farther than the radius: disabled')
            eq(item.focused, true, 'the only candidate is still the looked-at one (lock cap)')
        end

        -- walked out of promptRange: an empty set clears the shell
        local countBefore = #stubs.nuiOf('worldprompts:set')
        stubs.coords[101] = stubs.vector3(100.0, 0.0, 0.0)
        wpFrame(scan)
        wpFrame(projection)
        local cleared = wpSets()
        if #cleared == countBefore then
            check(false, 'an empty set clears the shell',
                'no clear message: client/ui.lua:104 calls the global send inside worldPromptBatch')
        else
            eq(#cleared, countBefore + 1, 'the clear is its own message')
            eq(#cleared[#cleared], 0, 'an empty set clears the shell')
        end
    end

    -- a projection that NEVER succeeds: the item is absent from the message
    env, Core, frame = newInteractionsClient('nui')
    I = Core.Interactions
    projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.projectWorld = function() return false end
    id = I.add({ coords = stubs.vector3(1.0, 0.0, 0.0), radius = 2.0, label = 'Hidden dot', worldPrompt = true })
    wpFrame(scan)
    wpFrame(projection)
    local hidden = wpSets()
    if #hidden == 0 then
        check(false, 'the empty projection still reports the set',
            'no worldprompts:set at all: client/ui.lua:104 calls the global send inside worldPromptBatch')
    else
        eq(#hidden[#hidden], 0, 'a failed projection leaves the item out of the message')
    end

    -- core_interact: the press runs the looked-at entry's onInteract, cooldown included
    env, Core, frame = newInteractionsClient('nui')
    I = Core.Interactions
    projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.projectWorld = function() return true, 0.5, 0.5 end
    interacted = {}
    id = I.add({
        coords = stubs.vector3(1.0, 0.0, 0.0),
        radius = 2.0,
        label = 'Pick up Bandage',
        worldPrompt = true,
        onInteract = function(ctx) interacted[#interacted + 1] = ctx end,
    })
    wpFrame(scan)
    wpFrame(projection)
    local cmd = env.__vm.commands.core_interact
    check(cmd ~= nil, 'core_interact is registered')
    cmd.fn(0, {})
    eq(#interacted, 1, 'the press runs the focused entry onInteract')
    eq(interacted[1] and interacted[1].id, id, 'the callback gets the fresh ctx id')
    eq(interacted[1] and interacted[1].distance, 1.0, 'with the current distance')
    cmd.fn(0, {})
    eq(#interacted, 1, 'the 500 ms cooldown refuses the immediate second press')
    stubs.tick(600)                  -- advance the virtual clock past the cooldown
    cmd.fn(0, {})
    eq(#interacted, 2, 'a press after the cooldown fires again')

    -- regression: an entry WITHOUT worldPrompt keeps its bottom pill
    env, Core, frame = newInteractionsClient('nui')
    I = Core.Interactions
    projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.projectWorld = function() return true, 0.5, 0.5 end
    I.add({ coords = stubs.vector3(1.0, 0.0, 0.0), radius = 2.0, label = 'Plain' })
    wpFrame(scan)                    -- activate: no worldPrompt → the text UI
    wpFrame(projection)              -- consumes ui_ready forceSend with the (empty) world set
    local pill = lastMessage('textui:show')
    eq(#stubs.nuiOf('textui:show'), 1, 'an entry without worldPrompt still shows the text UI')
    eq(pill and pill.key, 'E', 'the pill carries the display key')
    eq(pill and pill.text, 'Plain', 'and the label')
    local worldSets = wpSets()
    eq(#stubs.nuiOf('worldprompts:set'), 1, 'the world layer only ever saw the ui_ready empty set')
    if #worldSets == 0 then
        check(false, 'a plain entry never reaches the world-prompt layer',
            'no worldprompts:set at all: client/ui.lua:104 calls the global send inside worldPromptBatch')
    else
        check(#worldSets[#worldSets] == 0, 'a plain entry never reaches the world-prompt layer',
            'items = ' .. tostring(#worldSets[#worldSets]))
    end
end

--------------------------------------------------------------------------------
-- native world prompt renderer (the shipped default): sprites + HUD text drawn
-- in the render thread, zero NUI messages (DESIGN §6.7)
--------------------------------------------------------------------------------

local function suiteWorldPromptsNative()
    suite('world prompts native')
    -- Hint = 'sprites': this suite owns the DrawSprite + HUD text hint, which is also what
    -- 'scaleform' falls back to while the movie loads (the movie itself: suiteWorldPromptsScaleform)
    local env, Core, frame = newInteractionsClient(nil, 'sprites')
    local I = Core.Interactions
    local projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    -- two entries: the first projects dead centre (focused), the second off the reticle (idle)
    local calls = 0
    stubs.projectWorld = function()
        calls = calls + 1
        if calls % 2 == 1 then return true, 0.5, 0.5 end
        return true, 0.8, 0.4
    end
    local hintId = I.add({ coords = stubs.vector3(1.0, 0.0, 0.0), radius = 2.0, label = 'Pick up Bandage',
        worldPrompt = true, onInteract = function() end })
    I.add({ coords = stubs.vector3(2.0, 0.0, 0.0), radius = 2.0, label = 'Idle crate', worldPrompt = true })
    wpFrame(scan)
    wpFrame(projection)

    check(#stubs.nuiOf('worldprompts:set') == 0, 'the native renderer never sends worldprompts:set')
    local names = {}
    for i = 1, #stubs.drawSprites do
        names[stubs.drawSprites[i].name] = true
        eq(stubs.drawSprites[i].dict, 'core_wp', 'sprites draw from the runtime texture dict name')
    end
    -- D1 (§6.7): ring + core are ONE composited 'idle' sprite; 'ring' is only the pulse
    check(names.idle == true, 'an off-reticle dot draws the one composite idle sprite')
    check(names.ring == true, 'and the pulse ring, because it is in reach')
    check(names.dot == nil, 'the separate core-dot sprite is gone')
    local dotTexture = false
    for i = 1, #stubs.runtimeTextures do
        if stubs.runtimeTextures[i].name == 'dot' then dotTexture = true end
    end
    check(not dotTexture, 'and no dot texture is painted at all any more')
    check(names.cap == true, 'the looked-at entry draws the key cap')
    local seen = {}
    for i = 1, #stubs.drawTexts do seen[stubs.drawTexts[i]] = true end
    check(seen['E'] == true, 'the cap letter is drawn in the render thread')
    check(seen['PICK UP BANDAGE'] == true, 'the label is drawn next to the cap, uppercased like the kit')
    eq(stubs.registeredFonts[1], 'Barlow Condensed', 'the 600 band font is registered by name')
    eq(stubs.registeredFonts[2], 'Barlow Condensed Bold', 'and the 700 cap font')
    local usedFont = false
    for i = 1, #stubs.textFonts do
        if stubs.textFonts[i] == 8 then usedFont = true end
    end
    check(usedFont, 'the label and key draw with the registered font id')
    local bandSprite, bandTexture = false, nil
    for i = 1, #stubs.drawSprites do
        local n = stubs.drawSprites[i].name or ''
        if n:sub(1, 4) == 'band' then bandSprite = true end
    end
    for i = 1, #stubs.runtimeTextures do
        if (stubs.runtimeTextures[i].name or ''):sub(1, 4) == 'band' then bandTexture = stubs.runtimeTextures[i] end
    end
    check(bandSprite, 'the band is drawn as one gradient sprite (no solid/fade seam)')
    check(bandTexture ~= nil and bandTexture.h == 4 and bandTexture.w >= 16,
        'the band texture is painted once for the measured width')
    check(#stubs.drawOrigins > 0, 'the prompt is anchored with SetDrawOrigin at the world point')

    -- the render thread must repaint every frame (screen-space draw commands are per frame)
    local before = #stubs.drawSprites
    local widthBefore = stubs.widthCommands
    wpFrame(projection)
    check(#stubs.drawSprites > before, 'every projection frame redraws')
    eq(stubs.widthCommands, widthBefore, 'the label width is cached, not measured per frame')
    check(#stubs.nuiOf('worldprompts:set') == 0, 'and still never a NUI message')

    -- steady-state per-frame budget (§6.7): 1 looked-at dot + 1 idle dot on screen
    local originsBefore = #stubs.drawOrigins
    local clearsBefore = stubs.clearOrigins
    local alignSetsBefore = stubs.gfxAlignSets
    local alignResetsBefore = stubs.gfxAlignResets
    local timerBefore = stubs.gameTimerReads
    local texturesBefore = #stubs.runtimeTextures
    wpFrame(projection)
    eq(#stubs.drawOrigins - originsBefore, 2,
        'one draw-origin group per visible dot: the looked-at dot opens only its own')
    eq(stubs.clearOrigins - clearsBefore, 2, 'every draw origin is cleared')
    eq(stubs.gfxAlignSets - alignSetsBefore, 1, 'one script-gfx-align bracket per frame')
    eq(stubs.gfxAlignResets - alignResetsBefore, 1, 'and it is closed exactly once')
    eq(stubs.gameTimerReads - timerBefore, 1, 'the frame timestamp is read once and handed down')
    eq(#stubs.runtimeTextures - texturesBefore, 0, 'no texture is created in a steady frame')

    -- a renamed label rebuilds the hint cache once, then caches again
    local textsBefore = #stubs.drawTexts
    widthBefore = stubs.widthCommands
    I.setLabel(hintId, 'Open crate')
    wpFrame(projection)
    eq(stubs.widthCommands - widthBefore, 1, 'a renamed label rebuilds the hint cache once')
    local renamed = false
    for i = textsBefore + 1, #stubs.drawTexts do
        if stubs.drawTexts[i] == 'OPEN CRATE' then renamed = true end
    end
    check(renamed, 'and that frame draws the new uppercased label')
    widthBefore = stubs.widthCommands
    wpFrame(projection)
    eq(stubs.widthCommands, widthBefore, 'and is cached again')
    I.setLabel(hintId, 'Pick up Bandage')          -- restore for the checks below

    -- out of reach: the lock cap replaces the key cap, the label dims, nothing interacts
    stubs.coords[101] = stubs.vector3(5.0, 0.0, 0.0)
    wpFrame(scan)
    wpFrame(projection)
    local locked = false
    for i = 1, #stubs.drawSprites do
        if stubs.drawSprites[i].name == 'lock' then locked = true end
    end
    check(locked, 'a dot beyond the radius draws the lock cap')

    -- D1: an out-of-reach idle dot is exactly ONE sprite (the composite), never a pulse
    local dimBefore = #stubs.drawSprites
    wpFrame(projection)
    local composites, pulses = 0, 0
    for i = dimBefore + 1, #stubs.drawSprites do
        local name = stubs.drawSprites[i].name
        if name == 'idle' then composites = composites + 1 end
        if name == 'ring' then pulses = pulses + 1 end
    end
    eq(composites, 1, 'a disabled idle dot draws exactly one sprite')
    eq(pulses, 0, 'and no pulse ring')

    -- look-only (DESIGN §6.7): a worldPrompt entry that is NOT under the reticle must not fire
    env, Core, frame = newInteractionsClient(nil, 'sprites')
    I = Core.Interactions
    projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.projectWorld = function() return true, 0.8, 0.5 end   -- visible, but far from the reticle
    local fired = 0
    I.add({ coords = stubs.vector3(1.0, 0.0, 0.0), radius = 2.0, label = 'Look me at',
        worldPrompt = true, onInteract = function() fired = fired + 1 end })
    wpFrame(scan)
    wpFrame(projection)
    local cmd = env.__vm.commands.core_interact
    check(cmd ~= nil, 'core_interact is registered')
    if cmd then cmd.fn(0, {}) end
    eq(fired, 0, 'a worldPrompt entry outside the reticle never fires on E')

    -- ... while an entry WITHOUT worldPrompt keeps the proximity fallback its pill represents
    env, Core, frame = newInteractionsClient(nil, 'sprites')
    I = Core.Interactions
    projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.projectWorld = function() return true, 0.8, 0.5 end
    fired = 0
    I.add({ coords = stubs.vector3(1.0, 0.0, 0.0), radius = 2.0, label = 'Plain',
        onInteract = function() fired = fired + 1 end })
    wpFrame(scan)
    wpFrame(projection)
    cmd = env.__vm.commands.core_interact
    if cmd then cmd.fn(0, {}) end
    eq(fired, 1, 'an entry without worldPrompt still fires from the active fallback')
end

--------------------------------------------------------------------------------
-- the Scaleform key hint (the shipped default): the looked-at hint is ONE movie,
-- the idle dots stay sprites and sprites are the automatic fallback (DESIGN §6.7)
--------------------------------------------------------------------------------

--- 'SET_HINT(E, Pick up Bandage, false, false, true)' — the nth recorded method call.
local function sfCall(n)
    local call = stubs.scaleformCalls[n]
    if not call then return 'none' end
    local out = {}
    for i = 1, #call.params do out[i] = tostring(call.params[i]) end
    return ('%s(%s)'):format(call.method, table.concat(out, ', '))
end

--- The set of sprite names drawn after index `from`.
local function spriteNames(from)
    local names = {}
    for i = from + 1, #stubs.drawSprites do names[stubs.drawSprites[i].name] = true end
    return names
end

local function suiteWorldPromptsScaleform()
    suite('world prompts scaleform')
    local env, Core, frame = newInteractionsClient()     -- no override: the shipped default
    local I = Core.Interactions
    local projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    -- projected by WORLD x, so the pair stays stable when the scan re-sorts the list by distance
    stubs.projectWorld = function(x)
        if x == 1.0 then return true, 0.5, 0.5 end       -- the hint entry, dead centre
        return true, 0.8, 0.4                            -- the idle dot, off the reticle
    end
    local hintId = I.add({ coords = stubs.vector3(1.0, 0.0, 0.0), radius = 2.0,
        label = 'Pick up Bandage', worldPrompt = true, onInteract = function() end })
    local idleId = I.add({ coords = stubs.vector3(2.0, 0.0, 0.0), radius = 2.0,
        label = 'Idle crate', worldPrompt = true })

    wpFrame(scan)
    eq(#stubs.scaleformRequests, 1, 'the first scan with a visible prompt requests the movie once')
    eq(stubs.scaleformRequests[1], 'core_hint', 'and requests it by name')
    wpFrame(scan)
    eq(#stubs.scaleformRequests, 1, 'a movie that is already loaded is never requested again')

    local spritesBefore = #stubs.drawSprites
    wpFrame(projection)
    eq(#stubs.scaleformCalls, 1, 'the focused hint sends exactly one method call')
    eq(sfCall(1), 'SET_HINT(E, Pick up Bandage, false, false, true)',
        'SET_HINT carries the key, the RAW label, disabled, left and restart')
    -- a new focus is announced one frame before it is drawn (§6.7): a buffered method call must
    -- never land on a frame that already shows the movie at the new position
    eq(#stubs.scaleformDraws, 0, 'the announcing frame draws no movie')
    eq(#stubs.drawOrigins, 1, 'and opens no draw origin for the hint: only the idle dot has one')
    eq(#stubs.drawTexts, 0, 'the movie lays its own text out: no HUD text is drawn at all')
    eq(stubs.widthCommands, 0, 'and nothing measures a label')
    local names = spriteNames(spritesBefore)
    check(names.ring and names.idle, 'the idle dot still draws its pulse ring and its composite')
    check(not names.cap and not names.lock, 'the hint draws no cap sprite')
    local banded = false
    for name in pairs(names) do
        if name:sub(1, 4) == 'band' then banded = true end
    end
    check(not banded, 'and no band sprite')
    local bandTex = false
    for i = 1, #stubs.runtimeTextures do
        if (stubs.runtimeTextures[i].name or ''):sub(1, 4) == 'band' then bandTex = true end
    end
    check(not bandTex, 'and no band texture is ever painted')

    local originsBefore = #stubs.drawOrigins
    wpFrame(projection)
    eq(#stubs.scaleformDraws, 1, 'the next frame draws exactly one movie')
    local draw = stubs.scaleformDraws[1] or {}
    eq(draw.x, 0.0, 'the movie is drawn at its draw origin (x)')
    eq(draw.y, 0.0, 'and at its draw origin (y)')
    eq(draw.w, 1400 / 1920, 'as the whole 1400 px stage at 1920x1080')
    eq(draw.h, 64 / 1080, 'and its 64 px height')
    eq(#stubs.drawOrigins - originsBefore, 2, 'one draw-origin group per visible dot, the hint included')
    local origin = stubs.drawOrigins[#stubs.drawOrigins] or {}
    eq(origin.x, 1.0, 'the hint opens its own origin at the entry world point')
    eq(#stubs.scaleformCalls, 1, 'and that frame sends nothing more')

    local drawsBefore = #stubs.scaleformDraws
    for _ = 1, 3 do wpFrame(projection) end
    eq(#stubs.scaleformCalls, 1, 'steady frames send no method call')
    eq(#stubs.scaleformDraws - drawsBefore, 3, 'but every frame draws the movie')

    I.setLabel(hintId, 'Open crate')
    wpFrame(projection)
    eq(#stubs.scaleformCalls, 2, 'a renamed label sends exactly one more SET_HINT')
    eq(sfCall(2), 'SET_HINT(E, Open crate, false, false, false)',
        'with the new label and restart false: the same dot keeps its animation')

    stubs.coords[101] = stubs.vector3(5.0, 0.0, 0.0)     -- inside promptRange, beyond the radius
    wpFrame(scan)
    wpFrame(projection)
    eq(#stubs.scaleformCalls, 3, 'walking out of reach sends exactly one SET_HINT')
    eq(sfCall(3), 'SET_HINT(E, Open crate, true, false, false)', 'with disabled true')
    stubs.coords[101] = stubs.vector3(0.0, 0.0, 0.0)
    wpFrame(scan)
    wpFrame(projection)
    eq(sfCall(4), 'SET_HINT(E, Open crate, false, false, false)', 'and one with disabled false back in reach')

    drawsBefore = #stubs.scaleformDraws
    stubs.projectWorld = function(x)
        if x == 1.0 then return true, 0.9, 0.5 end       -- the hint dot leaves the reticle
        return true, 0.8, 0.4
    end
    wpFrame(projection)
    eq(#stubs.scaleformCalls, 5, 'losing focus sends exactly one more call')
    eq(sfCall(5), 'HIDE()', 'and that call is HIDE')
    wpFrame(projection)
    eq(#stubs.scaleformCalls, 5, 'a second unfocused frame sends nothing')
    eq(#stubs.scaleformDraws - drawsBefore, 0, 'and the movie is not drawn while nothing is focused')

    stubs.projectWorld = function(x)
        if x == 1.0 then return true, 0.5, 0.5 end
        return true, 0.8, 0.4
    end
    wpFrame(projection)
    eq(sfCall(6), 'SET_HINT(E, Open crate, false, false, true)',
        'looking back sends SET_HINT with restart true: the focus-in animation replays')
    eq(#stubs.scaleformDraws - drawsBefore, 0, 'and that announcing frame still draws nothing')
    wpFrame(projection)
    eq(#stubs.scaleformDraws - drawsBefore, 1, 'while the frame after it draws the re-announced hint')

    -- focus moving straight from dot A to dot B: no unfocused frame in between, so HIDE never runs
    local callsBeforeMove, drawsBeforeMove = #stubs.scaleformCalls, #stubs.scaleformDraws
    stubs.projectWorld = function(x)
        if x == 2.0 then return true, 0.5, 0.5 end       -- the OTHER entry takes the reticle
        return true, 0.9, 0.4
    end
    wpFrame(projection)
    eq(#stubs.scaleformCalls - callsBeforeMove, 1, 'a direct A -> B focus move sends exactly one call')
    eq(sfCall(#stubs.scaleformCalls), 'SET_HINT(E, Idle crate, false, false, true)',
        'and it is B SET_HINT with restart true, never a HIDE')
    eq(#stubs.scaleformDraws - drawsBeforeMove, 0,
        'that frame draws no movie: A content at B position is what this avoids')
    wpFrame(projection)
    eq(#stubs.scaleformDraws - drawsBeforeMove, 1, 'and the next frame draws B')

    check(I.remove(hintId) and I.remove(idleId), 'both prompt entries are removed')
    wpFrame(projection)                                  -- the promptCount == 0 early return
    eq(sfCall(8), 'HIDE()', 'losing the last prompt hides the movie too')
    eq(#stubs.scaleformCalls, 8, 'exactly once')
    stubs.triggerOn(env, 'onClientResourceStop', 0, 'core')
    eq(stubs.scaleformReleased, 1, 'stopping the resource gives the one pool slot back')

    -- a LONE Scaleform hint: no idle dot, so not even the sprite bracket is opened. FocusRadius 0.6
    -- widens the reticle so the side flip (x > 0.62) can be reached by a FOCUSED dot at all.
    env, Core, frame = newInteractionsClient(nil, nil, 0.6)
    I = Core.Interactions
    projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.projectWorld = function() return true, 0.5, 0.5 end
    I.add({ coords = stubs.vector3(1.0, 0.0, 0.0), radius = 2.0, label = 'Lone', worldPrompt = true })
    wpFrame(scan)
    wpFrame(projection)                                  -- the first frame sends SET_HINT
    local originsBefore, clearsBefore = #stubs.drawOrigins, stubs.clearOrigins
    local alignsBefore, resetsBefore = stubs.gfxAlignSets, stubs.gfxAlignResets
    local timerBefore, lonesBefore = stubs.gameTimerReads, #stubs.drawSprites
    local textsBefore = #stubs.drawTexts
    drawsBefore = #stubs.scaleformDraws
    local callsBefore = #stubs.scaleformCalls
    wpFrame(projection)
    eq(#stubs.drawOrigins - originsBefore, 1, 'a steady lone hint opens exactly one draw origin')
    eq(stubs.clearOrigins - clearsBefore, 1, 'and clears it')
    eq(#stubs.scaleformDraws - drawsBefore, 1, 'draws the movie exactly once')
    eq(stubs.gfxAlignSets - alignsBefore, 0, 'opens no script-gfx-align bracket (that belongs to the sprites)')
    eq(stubs.gfxAlignResets - resetsBefore, 0, 'and closes none')
    eq(stubs.gameTimerReads - timerBefore, 1, 'reads the frame timestamp once')
    eq(#stubs.drawSprites - lonesBefore, 0, 'draws no sprite at all')
    eq(#stubs.drawTexts - textsBefore, 0, 'and no text')
    eq(#stubs.scaleformCalls - callsBefore, 0, 'and sends no method call')

    stubs.projectWorld = function() return true, 0.8, 0.5 end
    wpFrame(projection)
    local flips = #stubs.scaleformCalls
    eq(sfCall(flips), 'SET_HINT(E, Lone, false, true, false)', 'x > 0.62 flips the band to the left')
    stubs.projectWorld = function() return true, 0.6, 0.5 end
    wpFrame(projection)
    eq(#stubs.scaleformCalls, flips, 'and 0.58 < x < 0.62 sends nothing: the side flip has hysteresis')

    -- the movie never streams in: the sprite hint draws, and the handle goes back after the timeout
    env, Core, frame = newInteractionsClient()
    I = Core.Interactions
    projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.scaleformLoaded = false          -- set AFTER the VM: newInteractionsClient clears the stubs
    stubs.projectWorld = function() return true, 0.5, 0.5 end
    I.add({ coords = stubs.vector3(1.0, 0.0, 0.0), radius = 2.0, label = 'Pick up Bandage',
        worldPrompt = true })
    wpFrame(scan)
    eq(#stubs.scaleformRequests, 1, 'the movie is requested even when it will never load')
    wpFrame(projection)
    eq(#stubs.scaleformDraws, 0, 'nothing of the movie is drawn while it loads')
    check(spriteNames(0).cap, 'the sprite hint draws the cap instead')
    local seen = {}
    for i = 1, #stubs.drawTexts do seen[stubs.drawTexts[i]] = true end
    check(seen.E and seen['PICK UP BANDAGE'], 'with the cap letter and the uppercased label')
    stubs.tick(11000)
    wpFrame(scan)
    eq(stubs.scaleformReleased, 1, 'after the load timeout the handle is released exactly once')
    check(printed('did not load') ~= nil, 'and one warning names the fallback')
    wpFrame(scan)
    eq(#stubs.scaleformRequests, 1, 'a movie that failed for good is never requested again')
    eq(stubs.scaleformReleased, 1, 'and never released twice')
    local fallbackBefore = #stubs.drawSprites
    wpFrame(projection)
    check(spriteNames(fallbackBefore).cap, 'and the sprite hint keeps drawing')

    -- a Begin the engine refuses: the cache mirrors only what was SENT, so the next frame retries
    env, Core, frame = newInteractionsClient()
    I = Core.Interactions
    projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.scaleformBeginFails = 1          -- after the VM: newInteractionsClient clears the stubs
    stubs.projectWorld = function() return true, 0.5, 0.5 end
    I.add({ coords = stubs.vector3(1.0, 0.0, 0.0), radius = 2.0, label = 'Retry', worldPrompt = true })
    wpFrame(scan)
    wpFrame(projection)
    eq(#stubs.scaleformCalls, 0, 'a refused BeginScaleformMovieMethod records no method call')
    eq(#stubs.scaleformDraws, 0, 'and nothing is drawn while the hint is still unannounced')
    wpFrame(projection)
    eq(#stubs.scaleformCalls, 1, 'the next frame retries it')
    eq(sfCall(1), 'SET_HINT(E, Retry, false, false, true)', 'with restart still true')
    eq(#stubs.scaleformDraws, 0, 'that retry frame announces, it does not draw')
    wpFrame(projection)
    eq(#stubs.scaleformDraws, 1, 'and the frame after it draws the hint')
    eq(#stubs.scaleformCalls, 1, 'without sending anything more')
end

--------------------------------------------------------------------------------
-- the projection cadence (DESIGN §6.7): every frame DRAWS, only every 33 ms one
-- projects and asks IsNuiFocused, and the dirty flag pulls a projection forward
--------------------------------------------------------------------------------

local function suiteWorldPromptsCadence()
    suite('world prompts cadence')
    local env, Core, frame = newInteractionsClient()      -- native + scaleform, the shipped default
    local I = Core.Interactions
    local projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.projectWorld = function(x)
        if x == 1.0 then return true, 0.5, 0.5 end        -- the hint entry, dead centre
        return true, 0.8, 0.4                             -- the idle dot, off the reticle
    end
    local hintId = I.add({ coords = stubs.vector3(1.0, 0.0, 0.0), radius = 2.0,
        label = 'Pick up Bandage', worldPrompt = true })
    I.add({ coords = stubs.vector3(2.0, 0.0, 0.0), radius = 2.0, label = 'Idle crate',
        worldPrompt = true })
    wpFrame(scan)
    wpFrame(projection)                                   -- announces the hint
    wpFrame(projection)                                   -- ... and from here it is steady

    -- six 5 ms frames stay inside one 33 ms window: they all draw, none of them projects
    local projBefore, focusBefore = stubs.screenProjections, stubs.nuiFocusReads
    local drawsBefore, spritesBefore = #stubs.scaleformDraws, #stubs.drawSprites
    for _ = 1, 6 do wpFrame(projection, 5) end
    eq(stubs.screenProjections - projBefore, 0, 'frames inside the 33 ms window never project')
    eq(stubs.nuiFocusReads - focusBefore, 0, 'and never ask IsNuiFocused')
    eq(#stubs.scaleformDraws - drawsBefore, 6, 'but every one of them draws the hint movie')
    eq(#stubs.drawSprites - spritesBefore, 12, 'and redraws the idle dot (pulse + composite) each time')
    wpFrame(projection, 5)                                -- 35 ms: the window is over
    eq(stubs.screenProjections - projBefore, 2, 'the frame past 33 ms projects every slot exactly once')
    eq(stubs.nuiFocusReads - focusBefore, 1, 'and asks IsNuiFocused exactly once')
    eq(#stubs.scaleformDraws - drawsBefore, 7, 'a projection frame draws like any other')

    projBefore, focusBefore = stubs.screenProjections, stubs.nuiFocusReads
    drawsBefore = #stubs.scaleformDraws
    for _ = 1, 20 do wpFrame(projection, 5) end           -- 100 ms of frames = two more windows
    eq(stubs.screenProjections - projBefore, 4, 'a 100 ms stretch projects the two slots twice')
    eq(stubs.nuiFocusReads - focusBefore, 2, 'one IsNuiFocused per window')
    eq(#stubs.scaleformDraws - drawsBefore, 20, 'while all 20 frames draw')

    -- a page taking NUI focus still freezes the drawing, one cadence step later at the latest
    stubs.nuiFocused = true
    local frozen = #stubs.scaleformDraws
    wpFrame(projection, 40)
    eq(#stubs.scaleformDraws - frozen, 0, 'a focused NUI freezes the drawing')
    for _ = 1, 3 do wpFrame(projection, 5) end
    eq(#stubs.scaleformDraws - frozen, 0, 'and the frames in between keep the last focus answer')
    stubs.nuiFocused = false
    wpFrame(projection, 40)
    eq(#stubs.scaleformDraws - frozen, 1, 'releasing it draws again on the next projection frame')

    -- the dirty flag: a scan, a new entry and a removal each force the NEXT frame to project,
    -- however short the step, so a cached visible set never outlives the list it came from
    local projMark = stubs.screenProjections
    wpFrame(scan, 5)
    wpFrame(projection, 5)
    eq(stubs.screenProjections - projMark, 2, 'a scan pass forces a projection on the next frame')
    projMark = stubs.screenProjections
    wpFrame(projection, 5)
    eq(stubs.screenProjections - projMark, 0, 'and the frame after it draws only, again')

    I.add({ coords = stubs.vector3(3.0, 0.0, 0.0), radius = 2.0, label = 'Late crate',
        worldPrompt = true })
    projMark = stubs.screenProjections
    wpFrame(scan, 5)
    wpFrame(projection, 5)
    eq(stubs.screenProjections - projMark, 3, 'a newly added entry is projected on the very next frame')

    wpFrame(projection, 5)                                -- steady again: nothing is dirty
    local drawsMark, originsMark = #stubs.scaleformDraws, #stubs.drawOrigins
    check(I.remove(hintId), 'the looked-at entry is removed between two 5 ms frames')
    wpFrame(projection, 5)
    eq(#stubs.scaleformDraws - drawsMark, 0, 'the next frame draws no hint for the removed entry')
    eq(#stubs.drawOrigins - originsMark, 2, 'and a draw origin only for the two dots that are left')

    -- the steady-state budget of a NON-projection frame (§6.7): a lone Scaleform hint is five
    -- native calls — the timer, the origin pair, the movie draw and the Wait
    env, Core, frame = newInteractionsClient()
    I = Core.Interactions
    projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.projectWorld = function(x)
        if x == 1.0 then return true, 0.5, 0.5 end
        return true, 0.8, 0.4
    end
    I.add({ coords = stubs.vector3(1.0, 0.0, 0.0), radius = 2.0, label = 'Lone', worldPrompt = true })
    wpFrame(scan)
    wpFrame(projection)
    wpFrame(projection)
    local timerMark, originMark, clearMark = stubs.gameTimerReads, #stubs.drawOrigins, stubs.clearOrigins
    local alignMark, resetMark = stubs.gfxAlignSets, stubs.gfxAlignResets
    local projectMark, focusMark = stubs.screenProjections, stubs.nuiFocusReads
    local movieMark, spriteMark, textMark = #stubs.scaleformDraws, #stubs.drawSprites, #stubs.drawTexts
    wpFrame(projection, 5)
    eq(stubs.gameTimerReads - timerMark, 1, 'a drawing frame reads the game timer exactly once')
    eq(stubs.screenProjections - projectMark, 0, 'projects nothing')
    eq(stubs.nuiFocusReads - focusMark, 0, 'never asks IsNuiFocused')
    eq(#stubs.drawOrigins - originMark, 1, 'opens exactly one draw origin')
    eq(stubs.clearOrigins - clearMark, 1, 'and clears it')
    eq(#stubs.scaleformDraws - movieMark, 1, 'draws the movie once')
    eq(stubs.gfxAlignSets - alignMark, 0, 'opens no sprite bracket')
    eq(stubs.gfxAlignResets - resetMark, 0, 'and closes none')
    eq(#stubs.drawSprites - spriteMark, 0, 'draws no sprite')
    eq(#stubs.drawTexts - textMark, 0, 'and no text at all')

    -- hint + one disabled point dot: two origins, one sprite, one movie, one bracket
    I.add({ coords = stubs.vector3(5.0, 0.0, 0.0), radius = 2.0, label = 'Far crate', worldPrompt = true })
    wpFrame(scan)
    wpFrame(projection)
    originMark, clearMark = #stubs.drawOrigins, stubs.clearOrigins
    alignMark, resetMark = stubs.gfxAlignSets, stubs.gfxAlignResets
    movieMark, spriteMark = #stubs.scaleformDraws, #stubs.drawSprites
    projectMark, timerMark = stubs.screenProjections, stubs.gameTimerReads
    wpFrame(projection, 5)
    eq(#stubs.drawOrigins - originMark, 2, 'hint + one disabled dot: two draw origins')
    eq(stubs.clearOrigins - clearMark, 2, 'both cleared')
    eq(#stubs.drawSprites - spriteMark, 1, 'exactly one sprite, the composite of the out-of-reach dot')
    eq(#stubs.scaleformDraws - movieMark, 1, 'one movie draw')
    eq(stubs.gfxAlignSets - alignMark, 1, 'one sprite bracket')
    eq(stubs.gfxAlignResets - resetMark, 1, 'closed once')
    eq(stubs.screenProjections - projectMark, 0, 'and still no projection on a drawing frame')
    eq(stubs.gameTimerReads - timerMark, 1, 'ten native calls in total')
end

--------------------------------------------------------------------------------
-- entity targets (DESIGN §6.7): the world coordinates are re-read every frame only
-- while they change; a resting prop is read once per 250 ms
--------------------------------------------------------------------------------

--- The last recorded draw origin whose x is `x` (one dot per origin), or nil.
local function originOf(x)
    for i = #stubs.drawOrigins, 1, -1 do
        if stubs.drawOrigins[i].x == x then return stubs.drawOrigins[i] end
    end
    return nil
end

local function suiteWorldPromptsEntity()
    suite('world prompts entity')
    local env, Core, frame = newInteractionsClient()
    local I = Core.Interactions
    local projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.projectWorld = function() return true, 0.8, 0.4 end     -- visible, never looked at
    local drop = stubs.newEntity(3, {})
    stubs.coords[drop] = stubs.vector3(1.0, 0.0, 0.0)
    check(I.add({ entity = drop, radius = 2.0, label = 'Dropped bandage', worldPrompt = true }) ~= nil,
        'an entity world prompt registers')
    wpFrame(scan)

    local reads = stubs.entityCoordReads
    for _ = 1, 12 do wpFrame(projection, 5) end
    eq(stubs.entityCoordReads - reads, 8, 'a resting entity is read 8 frames in a row, then parked')
    local origin = originOf(1.0)
    check(origin ~= nil, 'and its dot is anchored at the entity world point')

    reads = stubs.entityCoordReads
    wpFrame(projection, 200)
    eq(stubs.entityCoordReads - reads, 0, 'a parked slot is not read again inside the 250 ms')
    wpFrame(projection, 40)
    eq(stubs.entityCoordReads - reads, 1, 'and exactly once when they are up')

    -- somebody pushes the prop: the next due read notices and puts it back on every frame
    stubs.coords[drop] = stubs.vector3(1.0, 2.0, 0.0)
    reads = stubs.entityCoordReads
    wpFrame(projection, 260)
    eq(stubs.entityCoordReads - reads, 1, 'the next due read of a parked slot notices the move')
    origin = originOf(1.0)
    eq(origin and origin.y, 2.0, 'and the draw origin follows it')
    reads = stubs.entityCoordReads
    for _ = 1, 4 do wpFrame(projection, 5) end
    eq(stubs.entityCoordReads - reads, 4, 'a moving entity is read every frame again')

    -- a slot the scan re-fills with a DIFFERENT entry starts the read rule over: the parked
    -- state of the entry that used to sit there must never silence the new one
    local crate = stubs.newEntity(3, {})
    stubs.coords[crate] = stubs.vector3(0.5, 0.0, 0.0)            -- nearer: it sorts to slot 1
    check(I.add({ entity = crate, radius = 2.0, label = 'Crate', worldPrompt = true }) ~= nil,
        'a second, nearer entity prompt registers')
    for _ = 1, 9 do wpFrame(projection, 5) end                    -- park the first one again
    wpFrame(scan)
    stubs.coords[crate] = stubs.vector3(0.5, 3.0, 0.0)            -- and that one is pushed too
    wpFrame(projection, 5)
    origin = originOf(0.5)
    eq(origin and origin.y, 3.0, 'a re-filled slot reads its new entry on the next frame')

    -- both props are picked up: a slot that is being read every frame drops out at once,
    -- before any scan (push both first, so neither is parked whatever order the scan filled in)
    stubs.coords[drop] = stubs.vector3(1.0, 2.5, 0.0)
    stubs.coords[crate] = stubs.vector3(0.5, 3.5, 0.0)
    wpFrame(projection, 260)                                     -- every due read notices its move
    wpFrame(projection, 5)
    local spritesMark, originsMark = #stubs.drawSprites, #stubs.drawOrigins
    stubs.entities[drop].exists = false
    stubs.entities[crate].exists = false
    wpFrame(projection, 5)
    eq(#stubs.drawSprites - spritesMark, 0, 'a deleted entity stops being drawn on the very next frame')
    eq(#stubs.drawOrigins - originsMark, 0, 'and opens no draw origin')
    wpFrame(projection, 5)
    eq(#stubs.drawSprites - spritesMark, 0, 'and stays gone while the scan has not caught up')

    -- the documented trade-off (§6.7): a RESTING entity that vanishes is noticed at its next due
    -- read (or by the scan), never later than 250 ms
    env, Core, frame = newInteractionsClient()
    I = Core.Interactions
    projection, scan = frame[1], frame[2]
    stubs.nui('ui_ready', {})
    stubs.projectWorld = function() return true, 0.8, 0.4 end
    local rock = stubs.newEntity(3, {})
    stubs.coords[rock] = stubs.vector3(1.0, 2.0, 0.0)            -- out of reach: one sprite a frame
    check(I.add({ entity = rock, radius = 2.0, label = 'Rock', worldPrompt = true }) ~= nil,
        'the resting entity prompt registers')
    wpFrame(scan)
    for _ = 1, 10 do wpFrame(projection, 5) end                  -- parked after its 8 reads
    stubs.entities[rock].exists = false
    local parkedMark = #stubs.drawSprites
    wpFrame(projection, 5)
    eq(#stubs.drawSprites - parkedMark, 1, 'a parked entity is still drawn until its next due read')
    wpFrame(projection, 260)
    eq(#stubs.drawSprites - parkedMark, 1, 'which drops it, 250 ms after the last read at the latest')
end

--------------------------------------------------------------------------------
-- runner
--------------------------------------------------------------------------------

local SUITES <const> = { suiteManifest, suiteDiscovery, suiteFocus, suitePatch, suitePaths,
    suiteFeed, suiteRequests, suiteServerForward, suiteWorldPrompts, suiteWorldPromptsNative,
    suiteWorldPromptsScaleform, suiteWorldPromptsCadence, suiteWorldPromptsEntity }

for i = 1, #SUITES do SUITES[i]() end

for i = 1, #stubs.failures do
    failed = failed + 1
    print('FAIL  [stubs] ' .. stubs.failures[i])
end

print(('\nclient ui: %d passed, %d failed'):format(passed, failed))
if failed > 0 then
    print('')
    for i = 1, #failures do print(failures[i]) end
    os.exit(1)
end

-- end of file
