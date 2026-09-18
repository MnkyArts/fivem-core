--[[
    core/tests/client_ui_tests.lua — the offline suite for the client UI platform.

        lua5.4 tests/client_ui_tests.lua    (from the resource directory, or from tests/)

    Same harness as server_tests.lua: every native and runtime helper comes from
    tests/stubs.lua, so this proves the pure Lua contracts of DESIGN §38 (manifest
    validation, discovery, the focus stack, the patch queue, feeds and both request
    directions) — never in-game behaviour. Exit code is 1 when anything fails.

    One client VM per suite: import.lua, shared/config.lua, shared/ui_manifest.lua,
    then client/api.lua, client/ui.lua, client/ui_plugins.lua, client/ui_remote.lua
    in manifest order.
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
-- runner
--------------------------------------------------------------------------------

local SUITES <const> = { suiteManifest, suiteDiscovery, suiteFocus, suitePatch, suitePaths,
    suiteFeed, suiteRequests, suiteServerForward }

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
