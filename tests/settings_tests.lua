-- Offline contract for Core.Settings (DESIGN §45, storage §56): define/ownership, layers, validation,
-- persistence (the `settings` table over the Postgres test bridge, §56.10.2), permissions, audit, onChange +
-- recursion guard, replication and the client read side. A "restart" is a new core VM over the same database.
--     scripts/test-db.sh up   (once)      lua5.4 tests/settings_tests.lua
local here = (arg and arg[0] or 'tests/settings_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
local bridge = stubs.bridge

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

local CORE_MIGRATIONS <const> = { 'sql/0001_core_schema.sql', 'sql/0002_core_legacy_import.sql' }

--- The stored override row of `key` (value, updated_by, updated_at), or nil.
local function storedRow(key)
    local rows = bridge.sql('SELECT value, updated_by, updated_at FROM settings WHERE key = $1', { key })
    return rows and rows[1]
end

--- A core server VM: import, config, api, core's migrations (server/db.lua registers them in the resource),
--- stand-ins for Perms/Player/Audit, then settings.lua. `before(env, Core)` runs right before settings.lua.
local function newServer(before)
    stubs.newWorld()
    stubs.clear()
    stubs.tick(1000)
    local env = stubs.newEnv('server', 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    stubs.loadFile(env, 'server/api.lua')
    local Core = env.Core
    local DB = Core.DB
    assert(DB.migrate(CORE_MIGRATIONS))
    assert(DB.awaitMigrations())
    Core.Perms = { has = function(src, perm)
        if src == 0 then return true end
        return grants[src] ~= nil and grants[src][perm] == true
    end }
    Core.Player = {
        getInfo = function(src) return { accountId = 'acc' .. src } end,
        getName = function(src) return 'Player' .. src end,
    }
    Core.Audit = { record = function(row) audits[#audits + 1] = row return #audits end }
    if before then before(env, Core) end
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
local stored = storedRow('plug.maxWeight')
check(stored ~= nil and stored.value == 45, 'persisted as the settings row plug.maxWeight (dotted key)')
check(stored and type(stored.updated_by) == 'table' and stored.updated_by.accountId == 'acc7'
    and stored.updated_by.kind == 'player', 'the writer is stored with the override (updated_by)')
check(stored and type(stored.updated_at) == 'number' and Settings.inspect('plug.maxWeight').updatedAt ~= nil,
    'updated_at is stored and inspect reports updatedAt')
eq(#(bridge.sql('SELECT key FROM settings') or {}), 1, 'only overrides are stored (never defaults or config)')

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
eq(storedRow('plug.maxWeight'), nil, 'reset deletes the row')
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
check(storedRow('plug.maxWeight') ~= nil, 'the override stays in the DB')
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
eq(storedRow('plug.flag') and storedRow('plug.flag').value, false, 'a false override is stored as JSON false')

--------------------------------------------------------------------------------
-- write failures: 'persist', memory and table unchanged; a nil value is a reset
--------------------------------------------------------------------------------
eq(Settings.get('plug.maxWeight'), 61, 'the valid override applies again')
bridge.fail('INSERT INTO "settings"', 'XX000 simulated failure')
local seenBeforeFail = #seen
ok, err = Settings.set('plug.maxWeight', 55)
check(ok == false and err == 'persist', 'a failed upsert answers persist')
eq(Settings.get('plug.maxWeight'), 61, 'memory keeps the old value when the write failed')
eq(storedRow('plug.maxWeight').value, 61, 'and the table too')
eq(#seen, seenBeforeFail, 'no change event for a write that failed')
check(printed('settings: could not store plug.maxWeight'), 'the failed write is logged')
bridge.unfail()
bridge.fail('DELETE FROM "settings"', 'XX000 simulated failure')
ok, err = Settings.reset('plug.maxWeight')
check(ok == false and err == 'persist', 'a failed delete answers persist')
eq(Settings.get('plug.maxWeight'), 61, 'the override stays in memory')
check(storedRow('plug.maxWeight') ~= nil, 'and in the table')
bridge.unfail()
eq(Settings.get('plug.guarded'), 14, 'plug.guarded holds an override')
check(Settings.set('plug.guarded', nil) == true, 'a nil value on an optional field is accepted')
eq(Settings.get('plug.guarded'), 0, 'and resets the key to its default')
eq(storedRow('plug.guarded'), nil, 'the row is deleted')

--------------------------------------------------------------------------------
-- JSON round trips: false over a true default, arrays, tables, the empty table
--------------------------------------------------------------------------------
local rtDef = { id = 'rt', properties = {
    ['rt.on'] = { type = 'boolean', default = true, order = 1 },
    ['rt.list'] = { type = 'array', items = { type = 'integer' }, order = 2 },
    ['rt.spot'] = { type = 'vector3', order = 3 },
    ['rt.words'] = { type = 'array', items = { type = 'string' }, order = 4 },
} }
check(as('rtplug', 'define', rtDef) == true, 'a second section for the round trips')
check(Settings.set('rt.on', false) == true, 'false over a true default')
check(Settings.set('rt.list', { 3, 1, 2 }) == true, 'an array value')
check(Settings.set('rt.spot', { x = 1.5, y = -2, z = 30.25 }) == true, 'a table value')
check(Settings.set('rt.words', {}) == true, 'an empty table')
eq(storedRow('rt.on').value, false, 'rt.on is stored as false')
local storedList = storedRow('rt.list').value
check(type(storedList) == 'table' and storedList[1] == 3 and storedList[3] == 2, 'rt.list is stored as a JSON array')

--------------------------------------------------------------------------------
-- persistence round trip: a new core VM over the same database
--------------------------------------------------------------------------------
env, Core = newServer()
local Settings = Core.Settings -- a fresh core VM
check(as('plug', 'define', plugDef) == true, 'define after a core restart')
check(as('rtplug', 'define', rtDef) == true, 'the round-trip section after the restart')
eq(Settings.get('plug.maxWeight'), 61, 'override survives a restart')
eq(Settings.get('plug.flag'), false, 'a false override survives a restart')
eq(Settings.get('plug.token'), 'sesame', 'secret override survives a restart')
eq(Settings.get('plug.guarded'), 0, 'a reset key stays reset after a restart')
eq(Settings.get('rt.on'), false, 'false over a true default survives a restart')
local list = Settings.get('rt.list')
check(type(list) == 'table' and #list == 3 and list[1] == 3 and list[2] == 1 and list[3] == 2,
    'an array survives a restart in order')
local spot = Settings.get('rt.spot')
check(type(spot) == 'table' and spot.x == 1.5 and spot.y == -2 and spot.z == 30.25, 'a table survives a restart')
local words = Settings.get('rt.words')
check(type(words) == 'table' and next(words) == nil, 'an empty table survives a restart')
local restored = Settings.inspect('plug.maxWeight')
check(restored.by and restored.by.kind == 'resource' and restored.by.resource == 'core'
    and type(restored.updatedAt) == 'number', 'the writer and time survive a restart (inspect)')
stubs.tick(2000)
eq(env.GlobalState['cs:plug.flag'], false, 'replicated override published after a restart (false too)')
stubs.triggerOn(env, 'onResourceStop', 0, 'core')
eq(env.GlobalState['cs:plug.flag'], nil, 'core stop clears the mirrored keys')
eq(env.GlobalState['cs:keys'], nil, 'core stop clears the index')

--------------------------------------------------------------------------------
-- a yielding load: one load, every concurrent caller waits on the same barrier (DESIGN §22)
--------------------------------------------------------------------------------
local loads = 0
env, Core = newServer(function(vm, C)
    local DB = C.DB
    local realSelect = DB.select
    DB.select = function(tbl, ...)
        if tbl == 'settings' then
            loads = loads + 1
            vm.Wait(50)                          -- the round trip yields in game
        end
        return realSelect(tbl, ...)
    end
end)
local Settings = Core.Settings -- a fresh core VM
check(as('plug', 'define', plugDef) == true, 'define does not need the overrides')
local got = {}
env.CreateThread(function() got[1] = Settings.get('plug.maxWeight') end)
env.CreateThread(function() got[2] = Settings.get('plug.maxWeight') end)
env.CreateThread(function() got[3] = { Settings.set('plug.maxWeight', 70) } end)
eq(got[1], nil, 'callers park while the load is out')
stubs.tick(100)
check(got[1] == 61 and got[2] == 61, 'both readers see the stored override after the one load')
check(got[3] and got[3][1] == true, 'a writer arriving during the load waits and then writes')
eq(Settings.get('plug.maxWeight'), 70, 'the write landed after the load')
eq(storedRow('plug.maxWeight').value, 70, 'and in the table')
eq(loads, 1, 'the settings table was loaded exactly once')

-- two writes of one key while the first is out: they never overlap, so the table ends on the later one
local DB = Core.DB
local realUpsert = DB.upsert
local order = {}
DB.upsert = function(tbl, values, ...)
    order[#order + 1] = tostring(values.value)
    if values.value == 71 then env.Wait(50) end   -- the first round trip is slow
    return realUpsert(tbl, values, ...)
end
local w = {}
env.CreateThread(function() w[1] = Settings.set('plug.maxWeight', 71) end)
env.CreateThread(function() w[2] = Settings.set('plug.maxWeight', 72) end)
eq(#order, 1, 'the second write of a key waits while the first is out')
eq(Settings.get('plug.maxWeight'), 70, 'memory changes only once a write committed')
stubs.tick(100)
check(w[1] == true and w[2] == true, 'both writes succeed')
eq(table.concat(order, ','), '71,72', 'in call order')
eq(Settings.get('plug.maxWeight'), 72, 'memory holds the later write')
eq(storedRow('plug.maxWeight').value, 72, 'and so does the table')
DB.upsert = realUpsert

-- a write that TIMES OUT may still commit later: the slot re-writes what memory holds before it is freed
do
    local calls = {}
    DB.upsert = function(tbl, values, ...)
        calls[#calls + 1] = tostring(values.value)
        local stored = realUpsert(tbl, values, ...)          -- core_db commits it after all ...
        if #calls == 1 then return nil, 'timeout' end        -- ... but the Lua deadline answered first
        return stored
    end
    local okT, errT = Settings.set('plug.maxWeight', 80)
    check(okT == false and errT == 'persist', 'a timed-out upsert answers persist')
    eq(Settings.get('plug.maxWeight'), 72, 'memory keeps the committed value')
    eq(table.concat(calls, ','), '80,72', 'the slot re-writes the value memory holds')
    eq(storedRow('plug.maxWeight').value, 72, 'so the table converges on memory')
    DB.upsert = realUpsert
    local realDelete = DB.delete
    DB.delete = function(tbl, where, ...)
        realDelete(tbl, where, ...)                          -- the delete lands ...
        return nil, 'timeout'                                -- ... after the deadline
    end
    okT, errT = Settings.reset('plug.maxWeight')
    check(okT == false and errT == 'persist', 'a timed-out delete answers persist')
    eq(Settings.get('plug.maxWeight'), 72, 'the override stays in memory')
    eq(storedRow('plug.maxWeight') and storedRow('plug.maxWeight').value, 72, 'and is written back to the table')
    DB.delete = realDelete
end
check(Settings.set('plug.flag', true) == true, 'a replicated override for the outage below')

-- the prune guard of server/audit.lua reads this; plugins never reach it
eq(Settings.isLoaded(), true, 'isLoaded once the overrides are in')
do
    local okE, errE = pcall(as, 'plug', 'isLoaded')
    check(not okE and tostring(errE):find('internal', 1, true) ~= nil, 'Settings.isLoaded is block-listed for plugins')
end

--------------------------------------------------------------------------------
-- a failed load: config/default, no writes, memory and table untouched, retried later — and a late load
-- republishes the replicated keys and tells the watchers what changed against what was answered
--------------------------------------------------------------------------------
stubs.osTime = 1790000000
bridge.fail('SELECT %* FROM "settings"', 'XX000 simulated failure')
env, Core = newServer()
local Settings = Core.Settings -- a fresh core VM
as('plug', 'define', plugDef)
local lateHeard = {}
as('plug', 'onChange', 'plug.', function(key, new, old)
    lateHeard[key] = { new = new, old = old }
end)
eq(Settings.get('plug.maxWeight'), 30, 'an unreadable table answers config/default')
eq(Settings.isLoaded(), false, 'isLoaded is false after a failed load')
stubs.tick(2000)
eq(env.GlobalState['cs:plug.flag'], false, 'during the outage the default is replicated')
ok, err = Settings.set('plug.maxWeight', 40)
check(ok == false and err == 'unavailable', 'no writes while the overrides could not be read')
ok, err = Settings.reset('plug.maxWeight')
check(ok == false and err == 'unavailable', 'no resets either')
check(printed('settings: could not read settings'), 'the failed load is logged')
eq(Settings.inspect('plug.maxWeight').override, nil, 'memory holds no override after the failed load')
bridge.unfail()
eq(storedRow('plug.maxWeight').value, 72, 'the stored override was never overwritten')
eq(Settings.get('plug.maxWeight'), 30, 'within 10 s of the failure the load is not retried')
stubs.osTime = 1790000000 + 11
eq(Settings.get('plug.maxWeight'), 72, 'after 10 s the next caller loads and the override applies')
eq(Settings.isLoaded(), true, 'isLoaded after the late load')
stubs.tick(2000)
eq(env.GlobalState['cs:plug.flag'], true, 'the late load republishes the replicated override')
check(lateHeard['plug.maxWeight'] and lateHeard['plug.maxWeight'].new == 72 and lateHeard['plug.maxWeight'].old == 30,
    'watchers hear every key whose value changed against what was answered (new, old)')
check(lateHeard['plug.flag'] and lateHeard['plug.flag'].new == true and lateHeard['plug.flag'].old == false,
    'a replicated key too')
eq(lateHeard['plug.broken'], nil, 'a key without an override is not dispatched')
check(Settings.set('plug.maxWeight', 42) == true, 'writes work again after the retry')
eq(storedRow('plug.maxWeight').value, 42, 'and reach the table')

-- the retry thread: after a failed load it retries every 10 s by itself (no caller needed)
do
    bridge.fail('SELECT %* FROM "settings"', 'XX000 simulated failure')
    local envR, CoreR = newServer()
    local SR = CoreR.Settings
    as('plug', 'define', plugDef)
    eq(SR.get('plug.maxWeight'), 30, 'retry thread: the failed load answers the default')
    bridge.unfail()
    stubs.tick(5000)
    eq(SR.isLoaded(), false, 'no retry before 10 s')
    stubs.tick(6000)
    eq(SR.isLoaded(), true, 'the retry thread loaded the overrides without any caller')
    eq(SR.get('plug.maxWeight'), 42, 'and the stored override applies')
    stubs.triggerOn(envR, 'onResourceStop', 0, 'core')
end

-- the dbStatus hook: the database is back, the load retries at once
do
    bridge.fail('SELECT %* FROM "settings"', 'XX000 simulated failure')
    local envD, CoreD = newServer()
    local SD = CoreD.Settings
    as('plug', 'define', plugDef)
    local heardD = {}
    as('plug', 'onChange', 'plug.maxWeight', function(_, new) heardD[#heardD + 1] = new end)
    eq(SD.get('plug.maxWeight'), 30, 'dbStatus: the failed load answers the default')
    bridge.unfail()
    stubs.triggerOn(envD, 'core:hook:dbStatus', 0, false, 'still down')
    stubs.tick(10)
    eq(SD.isLoaded(), false, 'an unhealthy status does not load')
    stubs.triggerOn(envD, 'core:hook:dbStatus', 0, true, 'back')
    stubs.tick(10)
    eq(SD.isLoaded(), true, 'a healthy status reloads at once')
    eq(heardD[1], 42, 'and the watcher hears the stored value')
    stubs.triggerOn(envD, 'onResourceStop', 0, 'core')
end
stubs.osTime = nil
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
