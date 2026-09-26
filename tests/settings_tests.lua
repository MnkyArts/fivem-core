-- Offline contract for Core.Settings (DESIGN §45): define/ownership, layers, validation, persistence,
-- permissions, audit, onChange + recursion guard, replication and the client read side.
local here = (arg and arg[0] or 'tests/settings_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local passed, failed = 0, 0
local function check(value, message)
    if value then
        passed = passed + 1
    else
        failed = failed + 1
        print('FAIL: ' .. message)
    end
end
local function eq(actual, expected, message)
    check(actual == expected, ('%s (expected %s, got %s)'):format(message, tostring(expected), tostring(actual)))
end
local function printed(needle)
    for i = #stubs.printed, 1, -1 do
        if stubs.printed[i]:find(needle, 1, true) then return true end
    end
    return false
end

local grants = {}        -- [src] = { [perm] = true }
local audits = {}        -- every Core.Audit.record call

--- A core server VM: import, config, api, db, stand-ins for Perms/Player/Audit, then settings.lua.
local function newServer(adapter)
    stubs.newWorld()
    stubs.clear()
    stubs.tick(1000)
    local env = stubs.newEnv('server', 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    stubs.loadFile(env, 'server/api.lua')
    stubs.loadFile(env, 'server/db.lua')
    local Core = env.Core
    if adapter then Core.DB.setAdapter(adapter) end
    Core.Perms = { has = function(src, perm)
        if src == 0 then return true end
        return grants[src] ~= nil and grants[src][perm] == true
    end }
    Core.Player = {
        getInfo = function(src) return { accountId = 'acc' .. src } end,
        getName = function(src) return 'Player' .. src end,
    }
    Core.Audit = { record = function(row) audits[#audits + 1] = row return #audits end }
    stubs.loadFile(env, 'server/settings.lua')
    return env, Core
end

--- A call as a plugin would make it: through core's `call` export with that resource as caller.
local function as(resource, fn, ...)
    return stubs.exports.core.call(resource, 'Settings', fn, ...)
end

local function lastAudit() return audits[#audits] end

--------------------------------------------------------------------------------
-- core sections, define validation, ownership
--------------------------------------------------------------------------------
stubs.resetServer()
local env, Core = newServer()
local Settings = Core.Settings
eq(Settings.get('maps.limits.elements'), 3000, 'core maps section: elements')
eq(Settings.get('maps.limits.opsPerApply'), 200, 'core maps section: opsPerApply')
eq(Settings.get('maps.journalMax'), 5000, 'core maps section: journalMax')
eq(Settings.get('audit.retentionDays'), 90, 'core audit section: retentionDays')
eq(Settings.get('audit.maxRows'), 50000, 'core audit section: maxRows')
local all = Settings.list()
check(all[1].id == 'maps' and all[2].id == 'audit', 'sections sorted by order')
eq(all[1].owner, 'core', 'core owns its sections')
eq(all[1].properties[1].key, 'maps.limits.elements', 'properties in definition order')

local ok, err
local function refused(def, want, message)
    local ok, err = Settings.define(def)
    check(ok == false, message .. ' refused')
    eq(err, want, message .. ' error')
end
refused('x', 'def', 'non-table section')
refused({ id = 'bad id', properties = {} }, 'id', 'section id pattern')
refused({ id = 'p', properties = {} }, 'properties', 'no properties')
refused({ id = 'p', properties = { ['q.x'] = { type = 'boolean' } } }, 'key:q.x', 'key outside the section prefix')
refused({ id = 'p', properties = { ['p..x'] = { type = 'boolean' } } }, 'key:p..x', 'empty key segment')
refused({ id = 'p', properties = { ['p.x'] = { type = 'boolean', scope = 'player' } } }, 'p.x:scope', 'scope player')
refused({ id = 'p', properties = { ['p.x'] = { type = 'string', secret = true, replicate = true } } },
    'p.x:secret_replicate', 'secret keys cannot replicate')
refused({ id = 'p', properties = { ['p.x'] = { type = 'string', edit = 'bad perm!' } } }, 'p.x:edit', 'edit perm pattern')
refused({ id = 'p', properties = { ['p.x'] = { type = 'wat' } } }, 'p.x:type', 'schema error carries the key')
refused({ id = 'p', properties = { ['p.x'] = { type = 'integer', max = 5, default = 9 } } }, 'p.x:default:max',
    'invalid default')
refused({ id = 'p', title = 5, properties = { ['p.x'] = { type = 'boolean' } } }, 'title', 'title type')
ok, err = as('other', 'define', { id = 'maps', properties = { ['maps.x'] = { type = 'boolean' } } })
check(ok == false and err == 'owner', "a plugin cannot take core's section")

local calls = 0
local plugDef = { id = 'plug', title = 'Plug', icon = 'box', order = 10, properties = {
    ['plug.maxWeight'] = { type = 'number', default = 30, min = 1, max = 500, label = 'Max weight', order = 1 },
    ['plug.mode'] = { type = 'enum', options = { 'a', 'b', 'c' }, default = 'a', config = 'b', order = 2 },
    ['plug.broken'] = { type = 'integer', default = 1, max = 10, config = 99, order = 3 },
    ['plug.token'] = { type = 'password', secret = true, default = 'hunter2', order = 4 },
    ['plug.flag'] = { type = 'boolean', default = false, replicate = true, order = 5 },
    ['plug.guarded'] = { type = 'integer', default = 0, edit = 'plug.edit', view = 'plug.view', order = 6 },
    ['plug.even'] = { type = 'integer', default = 2, order = 7, validate = function(v)
        calls = calls + 1
        return v % 2 == 0, 'odd'
    end },
} }
ok, err = as('plug', 'define', plugDef)
check(ok == true, 'plugin define through the export: ' .. tostring(err))
eq(Core.Registry.getOwned('plug').settings.plug, true, "section tracked under the caller as kind 'settings'")
ok, err = as('other', 'define', { id = 'plug', properties = { ['plug.x'] = { type = 'boolean' } } })
check(ok == false and err == 'owner', 'another resource cannot take the section')
check(printed('plug.broken: the config value is refused'), 'an invalid config value is logged')

--------------------------------------------------------------------------------
-- layers, set/reset, validation, persistence, permissions, audit
--------------------------------------------------------------------------------
eq(Settings.get('plug.maxWeight'), 30, 'default layer')
eq(Settings.get('plug.mode'), 'b', 'config beats default')
eq(Settings.get('plug.broken'), 1, 'invalid config falls back to the default')
eq(Settings.get('plug.nope'), nil, 'undefined key reads nil')
eq(Settings.inspect('plug.nope'), nil, 'inspect of an undefined key is nil')
local info = Settings.inspect('plug.mode')
check(info.value == 'b' and info.default == 'a' and info.config == 'b' and info.source == 'config', 'inspect layers')

ok, err = Settings.set('plug.maxWeight', 501)
check(ok == false and err == 'max', 'set refuses out of range')
ok, err = Settings.set('plug.maxWeight', '50')
check(ok == false and err == 'type', 'set never coerces a string')
ok, err = Settings.set('plug.nope', 1)
check(ok == false and err == 'unknown', 'set of an undefined key')
ok, err = Settings.set('plug.maxWeight', 45, 'x')
check(ok == false and err == 'actor', 'actor must be a server id')
ok, err = Settings.set('plug.even', 3)
check(ok == false and err == 'custom:odd' and calls > 0, 'custom validate runs on set')

local before = #audits
ok, err = Settings.set('plug.maxWeight', 45, 7, 'heavier')
check(ok == false and err == 'permission', 'actor without core.admin is refused')
eq(#audits, before + 1, 'a refused set is audited')
eq(lastAudit().result, 'denied', 'denied audit row')

grants[7] = { ['core.admin'] = true, ['core.settings.view'] = true }
ok, err = Settings.set('plug.maxWeight', 45, 7, 'heavier')
check(ok == true, 'set by an admin: ' .. tostring(err))
eq(Settings.get('plug.maxWeight'), 45, 'override wins')
eq(Settings.inspect('plug.maxWeight').source, 'override', 'source override')
local row = lastAudit()
check(row.action == 'settings.set' and row.actor == 7 and row.reason == 'heavier' and row.result == 'ok',
    'audit row: action, actor, reason, result')
check(row.targets[1].type == 'setting' and row.targets[1].id == 'plug.maxWeight', 'audit target')
check(row.changes[1].old == 30 and row.changes[1].new == 45 and row.ctx.op == 'set', 'audit change old/new')
local stored = stubs.kvp['doc:settings:plug:maxWeight']
check(stored ~= nil and stored:find('"value":45', 1, true) ~= nil, "persisted as settings/plug:maxWeight")
check(stored and stored:find('acc7', 1, true) ~= nil, 'the writer is stored with the override')

ok, err = Settings.set('plug.guarded', 5, 7)
check(ok == false and err == 'permission', "a property's own edit permission applies")
grants[7]['plug.edit'] = true
check(Settings.set('plug.guarded', 5, 7) == true, 'with the edit permission')
check(Settings.set('plug.guarded', 6, 0) == true, 'console may edit')
check(Settings.set('plug.guarded', 8) == true, 'a server-side call without actor is trusted')
eq(lastAudit().actor, 'system', 'no actor is audited as system')

local secretOk = Settings.set('plug.token', 'sesame', 0)
check(secretOk == true, 'secret set')
eq(Settings.get('plug.token'), 'sesame', 'get returns the secret to server code')
check(lastAudit().changes[1].new == '••••' and lastAudit().changes[1].old == '••••', 'secret masked in audit')
eq(Settings.inspect('plug.token').value, '••••', 'secret masked in inspect')

ok, err = Settings.reset('plug.maxWeight', 7, 'back')
check(ok == true, 'reset: ' .. tostring(err))
eq(Settings.get('plug.maxWeight'), 30, 'reset falls back to the default')
eq(stubs.kvp['doc:settings:plug:maxWeight'], nil, 'reset deletes the document')
check(lastAudit().ctx.op == 'reset' and lastAudit().changes[1].new == 30, 'reset audited')
local auditCount = #audits
check(Settings.reset('plug.maxWeight') == true and #audits == auditCount, 'reset without override is a no-op')
ok, err = Settings.reset('plug.mode', 9)
check(ok == false and err == 'permission', 'reset needs the edit permission')

--------------------------------------------------------------------------------
-- list: view filtering, masking, flags
--------------------------------------------------------------------------------
local function findProp(sections, key)
    for _, s in ipairs(sections) do
        for _, p in ipairs(s.properties) do
            if p.key == key then return p, s end
        end
    end
end
eq(#Settings.list(9), 0, 'a viewer without core.settings.view sees nothing')
local viewList = Settings.list(7)
local tokenProp = findProp(viewList, 'plug.token')
check(tokenProp and tokenProp.value == '••••' and tokenProp.default == nil, 'secret masked in list, default removed')
eq(findProp(viewList, 'plug.guarded'), nil, "a property's own view permission applies")
grants[7]['plug.view'] = true
local guarded = findProp(Settings.list(7), 'plug.guarded')
check(guarded and guarded.editable == true and guarded.name == 'plug.guarded', 'viewer with edit sees editable')
grants[8] = { ['core.settings.view'] = true }
local mw = findProp(Settings.list(8), 'plug.maxWeight')
check(mw and mw.editable == false and mw.value == 30 and mw.source == 'default' and mw.type == 'number'
    and mw.max == 500, 'view without edit: public schema + value + source')
local mode = findProp(Settings.list(8), 'plug.mode')
check(mode.config == 'b' and mode.modified == false and #mode.options == 3, 'config shown, options public')
local flag = findProp(Settings.list(), 'plug.flag')
check(flag.replicate == true and flag.scope == 'server', 'flags in list')
local function hasFunction(t)
    for _, v in pairs(t) do
        if type(v) == 'function' or (type(v) == 'table' and hasFunction(v)) then return true end
    end
    return false
end
check(not hasFunction(Settings.list()), 'list carries no functions (validate stays private)')

--------------------------------------------------------------------------------
-- onChange: after persist, only real changes, errors contained, owner rules, recursion guard
--------------------------------------------------------------------------------
local seen = {}
local handle = as('plug', 'onChange', 'plug.', function(key, new, old)
    seen[#seen + 1] = { key = key, new = new, old = old }
end)
check(type(handle) == 'number', 'onChange returns a handle')
eq(Core.Registry.getOwned('plug').settingsWatch[handle], true, "watcher tracked as kind 'settingsWatch'")
local boom = as('plug', 'onChange', 'plug.maxWeight', function() error('handler boom') end)
Settings.set('plug.maxWeight', 60)
check(#seen == 1 and seen[1].key == 'plug.maxWeight' and seen[1].new == 60 and seen[1].old == 30,
    'handler got key, new, old')
check(printed('handler boom'), 'a failing handler is logged, not propagated')
Settings.set('plug.maxWeight', 60)
eq(#seen, 1, 'no change event when the effective value did not change')
Settings.set('plug.mode', 'b')          -- equals the config layer: stored, but the value is the same
eq(#seen, 1, 'override equal to the config value fires nothing')
eq(as('other', 'offChange', boom), false, "another resource cannot remove someone's watcher")
eq(as('plug', 'offChange', boom), true, 'the owner removes its watcher')
eq(as('plug', 'offChange', boom), false, 'a removed watcher is gone')
eq(Settings.onChange('x', 5), nil, 'non-callable handler refused')
local callableHits = 0
local callable = setmetatable({}, { __call = function() callableHits = callableHits + 1 end })
check(Settings.onChange('plug.mode', callable) ~= nil, 'a callable table (export hop shape) is accepted')
Settings.set('plug.mode', 'c')
eq(callableHits, 1, 'callable-table handler ran')

local inner
as('plug', 'onChange', 'plug.even', function(key)
    inner = { as('plug', 'set', key, 10) }
end)
Settings.set('plug.even', 4)
check(inner and inner[1] == false and inner[2] == 'recursive', "a handler's set of its own key is refused")
eq(Settings.get('plug.even'), 4, 'the recursive write did not land')

local waitingKey = 'plug.guarded'
as('slow', 'onChange', waitingKey, function() env.Wait(500) end)
Settings.set(waitingKey, 11)
ok, err = as('slow', 'set', waitingKey, 12)
check(ok == false and err == 'recursive', 'the handler owner cannot write the key while its handler runs')
check(as('admin', 'set', waitingKey, 13) == true, 'another resource can')
stubs.tick(600)
check(as('slow', 'set', waitingKey, 14) == true, 'after the handler finished the owner can write again')

--------------------------------------------------------------------------------
-- replication
--------------------------------------------------------------------------------
local G = env.GlobalState
stubs.tick(2000)
eq(G['cs:plug.flag'], false, 'replicate key mirrored to GlobalState (a false value too)')
check(type(G['cs:keys']) == 'table' and G['cs:keys'][1] == 'plug.flag' and #G['cs:keys'] == 1, 'index lists it')
eq(G['cs:plug.token'], nil, 'secret keys never replicate')
eq(G['cs:plug.maxWeight'], nil, 'non-replicate keys stay server side')
Settings.set('plug.flag', true)
stubs.tick(2000)
eq(G['cs:plug.flag'], true, 'a change is mirrored')

--------------------------------------------------------------------------------
-- owner stop: definitions and watchers go, overrides stay and come back
--------------------------------------------------------------------------------
local seenBefore = #seen
stubs.triggerOn(env, 'onResourceStop', 0, 'plug')
eq(Settings.get('plug.maxWeight'), nil, 'definitions removed with the owner')
eq(Core.Registry.getOwned('plug'), nil, 'nothing left tracked for the owner')
stubs.tick(2000)
eq(G['cs:plug.flag'], nil, 'replicated key cleared')
eq(#G['cs:keys'], 0, 'index emptied')
check(stubs.kvp['doc:settings:plug:maxWeight'] ~= nil, 'the override stays in the DB')
check(as('plug', 'define', plugDef) == true, 'the owner defines again')
eq(Settings.get('plug.maxWeight'), 60, 'the stored override applies again')
Settings.set('plug.maxWeight', 61)
eq(#seen, seenBefore, 'the stopped owner watcher is gone')
stubs.tick(2000)
eq(G['cs:plug.flag'], true, 'the replicated override is published again')

local tighter = { id = 'plug', properties = {
    ['plug.maxWeight'] = { type = 'number', default = 30, min = 1, max = 50 },
} }
check(as('plug', 'define', tighter) == true, 'same owner may re-define its section')
eq(Settings.get('plug.maxWeight'), 30, 'an override the new schema refuses is ignored')
check(printed('plug.maxWeight is not valid any more'), 'the ignored override is logged')
eq(Settings.get('plug.mode'), nil, 'keys dropped by the re-define are gone')
stubs.tick(2000)
eq(G['cs:plug.flag'], nil, 'a dropped replicate key is unpublished')

eq(Settings.inspect('plug.flag'), nil, 'dropped key has no inspect')
check(as('plug', 'define', plugDef) == true, 'full section back')
Settings.set('plug.flag', false)
local flagInfo = Settings.inspect('plug.flag')
check(flagInfo.override == false and flagInfo.value == false and flagInfo.source == 'override',
    'a false override is a real value (inspect)')
eq(Settings.get('plug.flag'), false, 'a false override is a real value (get)')
-- the stub JSON decoder reads `false` back as nil (tests/stubs.lua), so the restart round trip uses true
Settings.set('plug.flag', true)

--------------------------------------------------------------------------------
-- persistence round trip: a new core VM reads the KVP store back
--------------------------------------------------------------------------------
env, Core = newServer()
local Settings = Core.Settings -- a fresh core VM
check(as('plug', 'define', plugDef) == true, 'define after a core restart')
eq(Settings.get('plug.maxWeight'), 61, 'override survives a restart')
eq(Settings.get('plug.flag'), true, 'boolean override survives a restart')
eq(Settings.get('plug.token'), 'sesame', 'secret override survives a restart')
stubs.tick(2000)
eq(env.GlobalState['cs:plug.flag'], true, 'replicated override published after a restart')
stubs.triggerOn(env, 'onResourceStop', 0, 'core')
eq(env.GlobalState['cs:plug.flag'], nil, 'core stop clears the mirrored keys')
eq(env.GlobalState['cs:keys'], nil, 'core stop clears the index')

--------------------------------------------------------------------------------
-- async backend: one load, every concurrent caller waits on the same barrier (DESIGN §22)
--------------------------------------------------------------------------------
local loads = 0
local asyncAdapter = {
    loadAll = function(collection)
        loads = loads + 1
        local p = env.promise.new()
        env.SetTimeout(50, function() p:resolve(true) end)
        env.Citizen.Await(p)
        local out = {}
        local prefix = 'doc:' .. collection .. ':'
        for key, value in pairs(stubs.kvp) do
            if key:sub(1, #prefix) == prefix then out[key:sub(#prefix + 1)] = value end
        end
        return out
    end,
    put = function(collection, id, encoded) stubs.kvp['doc:' .. collection .. ':' .. id] = encoded end,
    remove = function(collection, id) stubs.kvp['doc:' .. collection .. ':' .. id] = nil end,
    flush = function() end,
}
env, Core = newServer(asyncAdapter)
local Settings = Core.Settings -- a fresh core VM
check(as('plug', 'define', plugDef) == true, 'define does not need the overrides')
local got = {}
env.CreateThread(function() got[1] = Settings.get('plug.maxWeight') end)
env.CreateThread(function() got[2] = Settings.get('plug.maxWeight') end)
env.CreateThread(function() got[3] = { Settings.set('plug.maxWeight', 70) } end)
eq(got[1], nil, 'callers park while the load is out')
stubs.tick(100)
local settingsLoads = loads
check(got[1] == 61 and got[2] == 61, 'both readers see the stored override after the one load')
check(got[3] and got[3][1] == true, 'a writer arriving during the load waits and then writes')
eq(Settings.get('plug.maxWeight'), 70, 'the write landed after the load')
check(settingsLoads == 1 and loads == 1, 'the settings collection was loaded exactly once')

local brokenAdapter = {
    loadAll = function() return nil, 'down' end,
    put = function() end, remove = function() end, flush = function() end,
}
env, Core = newServer(brokenAdapter)
local Settings = Core.Settings -- a fresh core VM
as('plug', 'define', plugDef)
eq(Settings.get('plug.maxWeight'), 30, 'an unreadable collection answers config/default')
ok, err = Settings.set('plug.maxWeight', 40)
check(ok == false and err == 'unavailable', 'no writes while the overrides could not be read')
check(printed('settings: could not read settings'), 'the failed load is logged')
stubs.resetServer()

--------------------------------------------------------------------------------
-- client read side: GlobalState reads, seeded cache, settingChanged hook
--------------------------------------------------------------------------------
stubs.newWorld()
stubs.clear()
local client = stubs.newEnv('client', 'core')
stubs.loadImport(client)
stubs.loadFile(client, 'shared/config.lua')
stubs.loadFile(client, 'client/api.lua')
local changeHandler
client.AddStateBagChangeHandler = function(keyFilter, bagFilter, fn)
    if keyFilter == nil and bagFilter == 'global' then changeHandler = fn end
    return 1
end
local CG = client.GlobalState
CG['cs:keys'] = { 'plug.flag', 'plug.list' }
CG['cs:plug.flag'] = true
CG['cs:plug.list'] = { 1, 2 }
stubs.loadFile(client, 'client/settings.lua')
local CS = client.Core.Settings
local hooks = {}
client.Core.on('settingChanged', function(key, new, old) hooks[#hooks + 1] = { key = key, new = new, old = old } end)
check(type(changeHandler) == 'function', 'one global state-bag handler')
eq(CS.get('plug.flag'), true, 'client get reads GlobalState')
local list = CS.get('plug.list')
list[1] = 99
eq(CG['cs:plug.list'][1], 1, 'client get returns a copy')
eq(CS.get('bad key'), nil, 'client get refuses a malformed key')
eq(#hooks, 0, 'seeding emits nothing')
CG['cs:plug.flag'] = false
changeHandler('global', 'cs:plug.flag', false)
check(#hooks == 1 and hooks[1].key == 'plug.flag' and hooks[1].new == false and hooks[1].old == true,
    'settingChanged(key, new, old) with old from the seed')
changeHandler('global', 'cs:plug.flag', false)
eq(#hooks, 1, 'an unchanged value emits nothing')
changeHandler('global', 'cs:plug.list', { 1, 2 })
eq(#hooks, 1, 'an equal table emits nothing')
changeHandler('global', 'door:1', { locked = true })
eq(#hooks, 1, 'other GlobalState keys are ignored')
changeHandler('global', 'cs:plug.new', 5)
check(#hooks == 2 and hooks[2].new == 5 and hooks[2].old == nil, 'a new key emits with old = nil')
changeHandler('global', 'cs:keys', { 'plug.flag', 'plug.new' })
check(#hooks == 3 and hooks[3].key == 'plug.list' and hooks[3].new == nil and type(hooks[3].old) == 'table',
    'a key that left the index emits new = nil')
changeHandler('global', 'cs:plug.new', nil)
check(#hooks == 4 and hooks[4].new == nil and hooks[4].old == 5, 'a nil write emits once')
changeHandler('global', 'cs:keys', { 'plug.flag' })
eq(#hooks, 4, 'the index catching up does not emit twice')

print(('settings: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
