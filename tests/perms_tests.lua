--[[
    core/tests/perms_tests.lua — offline suite for Core.Perms v2 (DESIGN §44) and the Callback
    `opts` of §44 (permission + cooldown, lib/callback/shared.lua).

        lua5.4 tests/perms_tests.lua    (from the resource directory, or from tests/)

    Same harness as server_tests.lua: natives and runtime helpers come from tests/stubs.lua, one core
    server VM per suite (import.lua, shared/config.lua, then the server modules in manifest order).
    Covers: the seed, inheritance + cycles, weights and canTarget, define-once / never-overwrite and
    `removed`, temporary grants (expiry, pruning on load, the timer), explain/effective, hook emission,
    saveGroup/deleteGroup rules and audit rows, the unreadable-table fallback, callback options. The groups and
    grants live in the Postgres test database (DESIGN §56.10: tests/pgbridge.lua); `perm_groups.removed` is a text[]
    there and reads back here as a set. Perms.has never touches the database (suite `no yield`).
    Exit code is 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/perms_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
local bridge = stubs.bridge

local passed, failed, suiteName = 0, 0, '?'

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
    print(line)
    return false
end

local function eq(actual, expected, label)
    return check(actual == expected, label, ('expected %s, got %s'):format(show(expected), show(actual)))
end

local function printed(needle)
    for i = #stubs.printed, 1, -1 do
        if stubs.printed[i]:find(needle, 1, true) then return stubs.printed[i] end
    end
    return nil
end

local function has(list, value)
    for i = 1, #(list or {}) do
        if list[i] == value then return true end
    end
    return false
end

local function clearFailures()
    for i = #stubs.failures, 1, -1 do stubs.failures[i] = nil end
end

-- manifest order (server_tests.lua's list, up to the modules Perms needs)
local SERVER_FILES <const> = {
    'shared/ui_forms.lua', 'server/api.lua', 'shared/hooks.lua', 'server/db.lua',
    'server/globals.lua', 'server/notify.lua', 'server/perms.lua', 'server/player_store.lua', 'server/player.lua',
    'server/playergrid.lua',
}

--- A perm_groups row with `removed` as a { [perm] = true } set (the old document shape), or nil.
local function storedGroup(DB, name)
    local row = DB.first('perm_groups', { name = name })
    if not row then return nil end
    local set = {}
    for _, perm in ipairs(row.removed or {}) do set[perm] = true end
    row.removed = set
    return row
end

--- The stored grants of an account: { permissions, tempPermissions } (the accounts columns), or nil.
local function storedAccount(DB, accountId)
    local row = DB.first('accounts', { id = accountId })
    if not row then return nil end
    return { permissions = row.permissions or {}, tempPermissions = row.temp_permissions or {}, group = row.perm_group }
end

--- A perm_groups row written straight to the table (the way an older core or an admin tool left it).
local function putGroup(DB, row)
    row.label = row.label or row.name
    assert(DB.insert('perm_groups', row), 'insert perm_groups ' .. row.name)
end

--- Wraps env's exports.core_db: every call is logged (lib/db/server.lua reads the raw `synchronous` field).
local function spyDB(env)
    local real = rawget(env.exports, 'core_db')
    local log = {}
    rawset(env.exports, 'core_db', setmetatable({ synchronous = rawget(real, 'synchronous') }, {
        __index = function(t, fnName)
            local fn = function(_, ...)
                log[#log + 1] = fnName
                return real[fnName](real, ...)
            end
            rawset(t, fnName, fn)
            return fn
        end,
    }))
    return log, function() rawset(env.exports, 'core_db', real) end
end

--- A fresh core VM. The test database survives (a second newServer() is a core restart).
local function newServer()
    stubs.newWorld()
    stubs.clear()
    clearFailures()
    stubs.tick(1000)
    local env = stubs.newEnv('server', 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    for i = 1, #SERVER_FILES do
        if stubs.readFile(stubs.root .. '/' .. SERVER_FILES[i]) then stubs.loadFile(env, SERVER_FILES[i]) end
    end
    return env, env.Core
end

--- Every permsChanged hook as { src, what, detail }.
local function recordHooks(Core)
    local seen = {}
    Core.on('permsChanged', function(src, what, detail)
        seen[#seen + 1] = { src = src, what = what, detail = detail }
    end)
    return seen
end

local function lastHook(seen, what)
    for i = #seen, 1, -1 do
        if seen[i].what == what then return seen[i] end
    end
    return nil
end

--- Puts a connected player straight into `group` (the test config lists the group so Player.setGroup
--- accepts it both before and after it asks Perms.groupExists).
local function joinAs(env, Core, src, group)
    stubs.connectPlayer(env, src, { license = ('license:perm%d'):format(src), name = ('P%d'):format(src) })
    if group ~= 'user' then
        env.Config.Perms.Groups[group] = env.Config.Perms.Groups[group] or {}
        assert(Core.Perms.setGroup(src, group), 'setGroup ' .. group)
    end
    return src
end

--------------------------------------------------------------------------------
-- suites
--------------------------------------------------------------------------------

--- First start seeds perm_groups from Config.Perms; afterwards the collection is the truth.
local function suiteSeed()
    suite('seed')
    stubs.resetServer()
    local _, Core = newServer()
    local P, DB = Core.Perms, Core.DB
    local hooks = recordHooks(Core)

    eq(DB.count('perm_groups'), 0, 'nothing is written before the first access')
    local groups = P.groups()
    eq(#groups, 6, 'six seeded groups')
    eq(DB.count('perm_groups'), 6, 'the seed was written to the collection')
    check(printed('seeded 6 group(s)') ~= nil, 'the seed is logged')
    eq(groups[1].name, 'user', 'groups() sorts by weight: user first')
    eq(groups[6].name, 'owner', 'owner last')
    eq(groups[6].weight, 1000, 'weights come from Config.Perms.Weights')
    eq(groups[3].label, 'Mod', 'the seed label is the capitalised name')
    eq(groups[3].inherits[1], 'helper', 'inherits come from Config.Perms.Inherits')
    check(lastHook(hooks, 'load') ~= nil, 'the load emits permsChanged(nil, load)')

    local stored = storedGroup(DB, 'owner')
    check(has(stored.perms, 'core.perms.manage'), "core.perms.manage was added to owner once (define default)")
    check(has(storedGroup(DB, 'admin').perms, 'core.audit.view'), 'core.audit.view default: admin')
    check(has(storedGroup(DB, 'admin').perms, 'core.settings.view'), 'core.settings.view default: admin')
    check(has(storedGroup(DB, 'helper').perms, 'core.admin.staff'), 'the staff perm default: helper')
    check(not has(storedGroup(DB, 'mod').perms, 'core.admin.staff'), 'mod inherits it instead of listing it')
    eq(type(stored.removed), 'table', 'every row carries a removed list')
    eq(stored.color, nil, 'no colour is NULL')

    local cat = P.catalogue()
    local byPerm = {}
    for i = 1, #cat do byPerm[cat[i].perm] = cat[i] end
    eq(byPerm['core.perms.manage'].owner, 'core', "core's perms are owned by core")
    eq(byPerm['core.perms.manage'].default, 'owner', 'the catalogue keeps the default group')
    eq(byPerm['core.audit.view'].category, 'core', 'category')
    check(byPerm['core.admin'] ~= nil, 'the legacy rank perms are catalogued')

    -- a restart reads the collection back instead of seeding again
    DB.update('perm_groups', { label = 'Moderator', weight = 250 }, { name = 'mod' })
    DB.flush()
    local _, Core2 = newServer()
    local again = Core2.Perms.groups()
    eq(#again, 6, 'no second seed')
    local mod
    for i = 1, #again do if again[i].name == 'mod' then mod = again[i] end end
    eq(mod.label, 'Moderator', 'the document is the source of truth after the seed')
    eq(mod.weight, 250, 'weights are read from the document')
    local owner = storedGroup(Core2.DB, 'owner')
    local count = 0
    for i = 1, #owner.perms do if owner.perms[i] == 'core.perms.manage' then count = count + 1 end end
    eq(count, 1, 'a restart never adds a default twice')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- Inheritance chains, cycles in stored documents, the legacy core.admin rule, groupExists.
local function suiteInheritance()
    suite('inheritance')
    stubs.resetServer()
    local env, Core = newServer()
    local P, DB = Core.Perms, Core.DB

    -- stored rows written before the first read: a cycle and a diamond
    putGroup(DB, { name = 'user', weight = 0, perms = {}, inherits = {} })
    putGroup(DB, { name = 'ring_a', weight = 10, perms = { 'ring.a' }, inherits = { 'ring_b' } })
    putGroup(DB, { name = 'ring_b', weight = 11, perms = { 'ring.b' }, inherits = { 'ring_a' } })
    putGroup(DB, { name = 'base', weight = 1, perms = { 'base.x' } })
    putGroup(DB, { name = 'left', weight = 2, perms = { 'left.x' }, inherits = { 'base' } })
    putGroup(DB, { name = 'right', weight = 3, perms = { 'right.x' }, inherits = { 'base' } })
    putGroup(DB, { name = 'top', weight = 4, perms = {}, inherits = { 'left', 'right', 'ghost' } })
    putGroup(DB, { name = 'admin', weight = 300, perms = { 'core.admin', 'admin.only' } })
    putGroup(DB, { name = 'deputy', weight = 250, perms = { 'core.admin' } })

    eq(P.groupExists('ring_a'), true, 'groupExists reads the table')
    eq(P.groupExists('mod'), false, 'a seed group that is not in the table does not exist')
    eq(P.groupExists(42), false, 'groupExists refuses a non-string')
    eq(P.groupExists('bad name'), false, 'groupExists refuses an invalid name')

    joinAs(env, Core, 1, 'ring_a')
    eq(P.has(1, 'ring.a'), true, 'own perm')
    eq(P.has(1, 'ring.b'), true, 'a cyclic chain still resolves the other side')
    joinAs(env, Core, 2, 'top')
    eq(P.has(2, 'left.x'), true, 'first parent')
    eq(P.has(2, 'right.x'), true, 'second parent')
    eq(P.has(2, 'base.x'), true, 'the shared grandparent (diamond)')
    eq(P.has(2, 'ghost.x'), false, 'an unknown parent is skipped')
    local list = P.list(2)
    local seen = {}
    for i = 1, #list do seen[list[i]] = (seen[list[i]] or 0) + 1 end
    eq(seen['base.x'], 1, 'list() dedupes the diamond')
    eq(list[1], 'left.x', 'list() walks depth first in inherits order')
    joinAs(env, Core, 3, 'deputy')
    eq(P.has(3, 'admin.only'), true, "'core.admin' in a group implies the admin group's chain")
    eq(P.explain(3, 'admin.only').via, 'group:admin', 'explain names the admin group for it')
    eq(P.has(3, 'left.x'), false, 'and nothing else')

    -- saveGroup refuses what would create a cycle, and unknown or self parents
    eq(select(2, P.saveGroup('base', { inherits = { 'top' } })), 'cycle', 'a cycle through saveGroup is refused')
    eq(select(2, P.saveGroup('base', { inherits = { 'nope' } })), 'unknown_group', 'an unknown parent is refused')
    eq(select(2, P.saveGroup('base', { inherits = { 'base' } })), 'invalid_inherits', 'self-inheritance is refused')
    eq(P.has(2, 'base.x'), true, 'a refused save changed nothing')

    -- the resolved cache is dropped on a save
    eq(P.saveGroup('base', { perms = { 'base.x', 'base.y' } }), true, 'saveGroup edits the parent')
    eq(P.has(2, 'base.y'), true, 'the child sees the new perm at once')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- getWeight and canTarget (§44): console, self, strictly higher weight.
local function suiteWeights()
    suite('weights')
    stubs.resetServer()
    local env, Core = newServer()
    local P = Core.Perms

    eq(P.getWeight(0), math.huge, 'the console outranks everyone')
    eq(P.getWeight(7), 0, 'no session: 0')
    eq(P.getWeight('x'), 0, 'an invalid src: 0')
    joinAs(env, Core, 1, 'admin')
    joinAs(env, Core, 2, 'mod')
    joinAs(env, Core, 3, 'mod')
    joinAs(env, Core, 4, 'user')
    eq(P.getWeight(1), 300, 'admin weight')
    eq(P.getWeight(2), 200, 'mod weight')
    eq(P.getWeight(4), 0, 'user weight')

    eq(P.canTarget(0, 1), true, 'console may target anyone')
    eq(P.canTarget(1, 2), true, 'admin may target mod')
    local ok, reason = P.canTarget(2, 1)
    eq(ok, false, 'mod may not target admin')
    eq(reason, 'rank', 'the reason is rank')
    eq(P.canTarget(2, 3), false, 'equal weight is not enough')
    eq(P.canTarget(2, 2), true, 'self is always allowed')
    eq(P.canTarget(2, 9), true, 'a src without a session weighs 0')
    eq(P.canTarget(4, 9), false, 'but 0 does not outrank 0')
    eq(select(2, P.canTarget('x', 1)), 'invalid_actor', 'an invalid actor')
    eq(select(2, P.canTarget(1, -3)), 'invalid_target', 'an invalid target')

    -- a weight edit is effective immediately
    eq(P.saveGroup('mod', { weight = 350 }), true, 'console raises mod above admin')
    eq(P.canTarget(2, 1), true, 'the new weight counts at once')
end

--- define(): the default grant is added once, an owner's removal is remembered, owners are tracked.
local function suiteDefine()
    suite('define')
    stubs.resetServer()
    local env, Core = newServer()
    local P, DB, Registry = Core.Perms, Core.DB, Core.Registry
    local hooks = recordHooks(Core)
    P.groups()   -- load + seed

    eq(P.define('bad perm!', { label = 'x' }), false, 'an invalid perm name is refused')
    eq(P.define('ok.perm', 'nope'), false, 'non-table opts are refused')
    eq(P.define('ok.perm', { default = 'bad name' }), false, 'an invalid default group is refused')

    eq(select(2, Registry.withCaller('plugin_a', P.define, 'plugin.fly', { label = 'Fly', default = 'mod',
        description = 'Noclip', category = 'plugin' })), true, 'a plugin defines a perm')
    check(has(storedGroup(DB, 'mod').perms, 'plugin.fly'), 'the default group got the grant')
    local hook = lastHook(hooks, 'define')
    eq(hook and hook.detail, 'plugin.fly', 'permsChanged(nil, define, perm)')
    eq(hook and hook.src, nil, 'with src nil (a group changed)')
    local entry
    for _, def in ipairs(P.catalogue()) do if def.perm == 'plugin.fly' then entry = def end end
    eq(entry and entry.owner, 'plugin_a', 'the catalogue records the calling resource')
    eq(entry and entry.description, 'Noclip', 'description')
    eq(select(2, Registry.withCaller('plugin_b', P.define, 'plugin.fly', { label = 'Mine' })), true,
        'a second owner defining the same perm is ignored')
    for _, def in ipairs(P.catalogue()) do if def.perm == 'plugin.fly' then entry = def end end
    eq(entry.owner, 'plugin_a', 'the first definition keeps its owner')
    eq(entry.label, 'Fly', 'and its fields')
    joinAs(env, Core, 1, 'admin')
    eq(P.has(1, 'plugin.fly'), true, 'admin inherits the new mod grant')

    -- the owner takes it out: remembered, never re-added (not by a redefine, not after a restart)
    local modPerms = {}
    for _, perm in ipairs(storedGroup(DB, 'mod').perms) do
        if perm ~= 'plugin.fly' then modPerms[#modPerms + 1] = perm end
    end
    eq(P.saveGroup('mod', { perms = modPerms }), true, 'the owner removes the perm from mod')
    eq(storedGroup(DB, 'mod').removed['plugin.fly'], true, 'removed[perm] is stored')
    local raw = bridge.sql("SELECT removed FROM perm_groups WHERE name = 'mod'")
    check(raw and raw[1] and has(raw[1].removed, 'plugin.fly'), 'removed is a text[] column holding the perm')
    eq(P.has(1, 'plugin.fly'), false, 'the removal is effective at once')
    Registry.withCaller('plugin_a', P.define, 'plugin.fly', { label = 'Fly', default = 'mod' })
    check(not has(storedGroup(DB, 'mod').perms, 'plugin.fly'), 'a redefine does not re-add it')
    DB.flush()
    local _, Core2 = newServer()
    Core2.Perms.groups()
    Core2.Registry.withCaller('plugin_a', Core2.Perms.define, 'plugin.fly', { label = 'Fly', default = 'mod' })
    check(not has(storedGroup(Core2.DB, 'mod').perms, 'plugin.fly'), 'nor does a restart')

    -- adding it back clears the flag
    modPerms[#modPerms + 1] = 'plugin.fly'
    eq(Core2.Perms.saveGroup('mod', { perms = modPerms }), true, 'the owner adds it back')
    eq(storedGroup(Core2.DB, 'mod').removed['plugin.fly'], nil, 'removed is cleared')

    -- a group created by an owner is composed by them: an earlier define default is not added later
    Core2.Perms.define('vip.perk', { default = 'vip' })
    eq(Core2.Perms.saveGroup('vip', { label = 'VIP', weight = 50, perms = { 'vip.chat' } }), true, 'create vip')
    eq(storedGroup(Core2.DB, 'vip').removed['vip.perk'], true, 'the pending default is marked removed')
    Core2.Perms.define('vip.later', { default = 'vip' })
    check(has(storedGroup(Core2.DB, 'vip').perms, 'vip.later'), 'a define after creation applies once')

    -- a stopped owner's definitions leave the catalogue; the grant stays in the document
    stubs.triggerOn(env, 'onResourceStop', 0, 'plugin_a')
    local still = false
    for _, def in ipairs(P.catalogue()) do if def.perm == 'plugin.fly' then still = true end end
    eq(still, false, 'the owner stop removed the definition')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- Temporary grants: storage next to `permissions`, expiry, pruning on load, the per-player timer.
local function suiteTemporary()
    suite('temporary')
    stubs.resetServer()
    local T = 1800000000
    stubs.osTime = T
    local env, Core = newServer()
    local P, DB = Core.Perms, Core.DB
    local hooks = recordHooks(Core)
    joinAs(env, Core, 1, 'user')
    local accountId = Core.Player.getInfo(1).accountId

    eq(P.grant(1, 'tmp.a', 'account', { expiresAt = T }), false, 'an expiry that is not in the future is refused')
    eq(P.grant(1, 'tmp.a', 'account', { expiresAt = T + 11 * 365 * 86400 }), false, 'more than ten years: refused')
    eq(P.grant(1, 'tmp.a', 'account', { expiresAt = 'soon' }), false, 'a non-number expiry is refused')
    eq(P.grant(1, 'tmp.a', 'account', 'x'), false, 'non-table opts are refused')
    eq(P.grant(1, 'tmp.a', 'account', { expiresAt = T + 60 }), true, 'a temporary account grant')
    eq(P.has(1, 'tmp.a'), true, 'it is held')
    local why = P.explain(1, 'tmp.a')
    eq(why.via, 'account', 'explain: via account')
    eq(why.expiresAt, T + 60, 'explain carries expiresAt')
    local account = storedAccount(DB, accountId)
    eq(account.tempPermissions['tmp.a'], T + 60, 'stored as tempPermissions[perm] = expiresAt')
    check(not has(account.permissions or {}, 'tmp.a'), 'the permissions array stays plain strings')
    eq(lastHook(hooks, 'grant').detail, 'tmp.a', 'permsChanged(src, grant, perm)')
    eq(P.grant(1, 'tmp.a', 'account', { expiresAt = T + 60 }), true, 'the same grant again is a no-op')

    eq(P.grant(1, 'tmp.c', 'character', { expiresAt = T + 30 }), true, 'a temporary character grant')
    eq(Core.Player.getData(1, 'tempPermissions')['tmp.c'], T + 30, 'stored on the character data')
    eq(P.explain(1, 'tmp.c').via, 'character', 'explain: via character')

    -- expiry: ignored at once, pruned and announced by the timer
    stubs.osTime = T + 31
    eq(P.has(1, 'tmp.c'), false, 'an expired grant is ignored immediately')
    eq(P.has(1, 'tmp.a'), true, 'the other one still runs')
    stubs.tick(31000 + 1000)
    eq(Core.Player.getData(1, 'tempPermissions')['tmp.c'], nil, 'the timer pruned the character entry')
    local expired = lastHook(hooks, 'expired')
    eq(expired and expired.src, 1, 'permsChanged(src, expired)')
    stubs.osTime = T + 61
    stubs.tick(30000)
    eq(storedAccount(DB, accountId).tempPermissions['tmp.a'], nil, 'the re-armed timer pruned the next one')
    eq(P.has(1, 'tmp.a'), false, 'and it is gone')

    -- a permanent grant replaces a temporary one; revoke removes both kinds
    P.grant(1, 'tmp.b', 'account', { expiresAt = T + 600 })
    eq(P.grant(1, 'tmp.b'), true, 'a permanent grant over a temporary one')
    account = storedAccount(DB, accountId)
    check(has(account.permissions, 'tmp.b'), 'it is in the permissions array')
    eq(account.tempPermissions['tmp.b'], nil, 'and the temporary entry is gone')
    eq(P.grant(1, 'tmp.b', 'account', { expiresAt = T + 900 }), true, 'a temporary grant of a permanent perm')
    eq(storedAccount(DB, accountId).tempPermissions['tmp.b'], nil, 'changes nothing')
    P.grant(1, 'tmp.d', 'account', { expiresAt = T + 900 })
    eq(P.revoke(1, 'tmp.d'), true, 'revoke removes a temporary grant')
    eq(P.revoke(1, 'tmp.d'), false, 'a second revoke is false')
    eq(P.has(1, 'tmp.d'), false, 'revoked')
    eq(lastHook(hooks, 'revoke').detail, 'tmp.d', 'permsChanged(src, revoke, perm)')

    -- pruning when the cache is built (next session): an expired stored entry is dropped and written back
    P.grant(1, 'tmp.e', 'account', { expiresAt = T + 1000 })
    Core.Player.setData(1, 'tempPermissions', { ['old.c'] = T - 5, ['live.c'] = T + 5000 })
    Core.Player.save(1)
    DB.flush()
    stubs.osTime = T + 2000
    local env2, Core2 = newServer()
    joinAs(env2, Core2, 1, 'user')
    eq(Core2.Perms.has(1, 'tmp.e'), false, 'an entry that expired while offline is ignored')
    eq(storedAccount(Core2.DB, accountId).tempPermissions['tmp.e'], nil, 'and pruned from the account on load')
    eq(Core2.Perms.has(1, 'live.c'), true, 'a running character entry still counts')
    eq(Core2.Player.getData(1, 'tempPermissions')['old.c'], nil, 'an expired character entry is pruned')
    stubs.osTime = nil
    eq(#stubs.failures, 0, 'no thread errored')
end

--- explain() follows has()'s order; effective() is the set of list(); the console gets the catalogue.
local function suiteExplain()
    suite('explain')
    stubs.resetServer()
    local env, Core = newServer()
    local P = Core.Perms
    joinAs(env, Core, 1, 'mod')

    local why = P.explain(0, 'anything')
    eq(why.allowed, true, 'console: allowed')
    eq(why.via, 'console', 'console: via console')
    eq(P.explain(1, '').allowed, false, 'an empty perm is never allowed')
    eq(P.explain(-1, 'core.mod').allowed, false, 'an invalid src is never allowed')
    stubs.aces['1|ace.only'] = true
    eq(P.explain(1, 'ace.only').via, 'ace', 'ACE first')
    P.grant(1, 'acc.perm')
    eq(P.explain(1, 'acc.perm').via, 'account', 'account grant')
    P.grant(1, 'char.perm', 'character')
    eq(P.explain(1, 'char.perm').via, 'character', 'character grant')
    eq(P.explain(1, 'core.mod').via, 'group:mod', 'own group')
    eq(P.explain(1, 'core.admin.staff').via, 'group:helper', 'the inheriting group names the lister')
    local no = P.explain(1, 'core.owner')
    eq(no.allowed, false, 'not held')
    eq(no.via, nil, 'no via')
    eq(no.group, 'mod', 'explain reports the player group')
    for _, perm in ipairs({ 'ace.only', 'acc.perm', 'char.perm', 'core.mod', 'core.admin.staff', 'core.owner', 'x' }) do
        eq(P.explain(1, perm).allowed, P.has(1, perm), 'explain agrees with has: ' .. perm)
    end

    local eff = P.effective(1)
    eq(eff['core.mod'], true, 'effective: own group')
    eq(eff['core.helper'], true, 'effective: inherited')
    eq(eff['acc.perm'], true, 'effective: account')
    eq(eff['char.perm'], true, 'effective: character')
    eq(eff['core.admin'], nil, 'effective: nothing extra')
    eq(eff['ace.only'], nil, 'ACE cannot be enumerated')
    local console = P.effective(0)
    eq(console['core.perms.manage'], true, 'the console effective set covers the catalogue')
    eq(next(P.effective('x')), nil, 'an invalid src: empty')
end

--- saveGroup/deleteGroup through an actor: permission, rank, validation, audit rows, hooks.
local function suiteManage()
    suite('manage')
    stubs.resetServer()
    local env, Core = newServer()
    local P, DB = Core.Perms, Core.DB
    local hooks = recordHooks(Core)
    local rows = {}
    Core.Audit = { record = function(row) rows[#rows + 1] = row return #rows end }
    joinAs(env, Core, 1, 'user')
    joinAs(env, Core, 2, 'owner')
    joinAs(env, Core, 3, 'senior')

    local ok, err = P.saveGroup('vip', { label = 'VIP' }, 1)
    eq(ok, false, 'a user may not save a group')
    eq(err, 'no_permission', 'no_permission')
    eq(rows[#rows].result, 'denied', 'the denial is audited')
    eq(rows[#rows].action, 'perms.saveGroup', 'audit action')
    eq(rows[#rows].targets[1].id, 'vip', 'audit target group')
    eq(storedGroup(DB, 'vip'), nil, 'nothing was written')

    eq(select(2, P.saveGroup('bad name', {})), 'invalid_name', 'invalid name')
    eq(select(2, P.saveGroup('vip', 'x')), 'invalid_patch', 'invalid patch')
    eq(select(2, P.saveGroup('vip', { weight = -1 })), 'invalid_weight', 'negative weight')
    eq(select(2, P.saveGroup('vip', { color = 'red' })), 'invalid_color', 'invalid colour')
    eq(select(2, P.saveGroup('vip', { perms = { 'ok', 'bad perm' } })), 'invalid_perms', 'invalid perm')
    eq(select(2, P.saveGroup('vip', { label = '' })), 'invalid_label', 'empty label')

    eq(select(2, P.saveGroup('vip', { label = 'VIP', weight = 50, perms = { 'vip.chat' } }, 2)), 'not_held',
        'an actor may only add perms it holds itself')
    eq(rows[#rows].message, 'not_held', 'the not_held denial is audited')
    P.grant(2, 'vip.chat')
    eq(P.saveGroup('vip', { label = 'VIP', weight = 50, color = '#ffaa00', inherits = { 'user' },
        perms = { 'vip.chat', 'vip.chat' } }, 2), true, 'the owner creates a group with a perm it holds')
    local vip = storedGroup(DB, 'vip')
    eq(vip.weight, 50, 'weight stored')
    eq(vip.color, '#ffaa00', 'colour stored')
    eq(#vip.perms, 1, 'perms are deduplicated')
    eq(rows[#rows].result, 'ok', 'the save is audited')
    eq(rows[#rows].actor, 2, 'with the actor src')
    check(#rows[#rows].changes > 0, 'and the changes')
    local hook = lastHook(hooks, 'saveGroup')
    eq(hook and hook.detail, 'vip', 'permsChanged(nil, saveGroup, name)')

    eq(select(2, P.saveGroup('vip', { weight = 5000 }, 2)), 'rank', 'nobody raises a group above themselves')
    eq(rows[#rows].message, 'rank', 'the rank denial is audited')
    eq(select(2, P.saveGroup('vip', { weight = 1000 }, 2)), 'rank', 'nor to its own weight')
    eq(P.saveGroup('god', { weight = 5000 }), true, 'core itself may (no actor)')
    eq(select(2, P.saveGroup('god', { label = 'God' }, 2)), 'rank', 'no edits of a group ranked above the actor')
    eq(select(2, P.saveGroup('vip', { inherits = { 'god' } }, 2)), 'rank', 'no inheriting from above')
    eq(select(2, P.saveGroup('owner', { label = 'Boss' }, 2)), 'rank', 'no edits of the actor\'s own group')
    P.grant(3, 'core.perms.manage')
    eq(select(2, P.saveGroup('owner', { label = 'Boss' }, 3)), 'rank', 'a senior may not edit owner')
    eq(select(2, P.saveGroup('senior', { label = 'S' }, 3)), 'rank', 'nor its own group (equal weight)')
    eq(select(2, P.saveGroup('user', { weight = 400 }, 3)), 'rank', 'nor lift user to its own weight')
    eq(P.saveGroup('user', { weight = 0, label = 'Player' }, 3), true, 'a lower group stays editable')
    eq(P.saveGroup('secret', { weight = 10, perms = { 'secret.x' } }), true, 'core creates a group with a perm')
    eq(select(2, P.saveGroup('vip', { inherits = { 'user', 'secret' } }, 3)), 'not_held',
        'inheriting a chain with perms the actor lacks counts as adding them')
    eq(P.saveGroup('secret', { perms = {} }, 3), true, 'removing a perm the actor does not hold is allowed')
    eq(P.saveGroup('vip', { inherits = { 'user', 'secret' } }, 3), true, 'an empty chain may be inherited')
    eq(P.saveGroup('god', { label = 'God' }, 0), true, 'the console outranks everything')

    -- deleteGroup
    eq(select(2, P.deleteGroup('user')), 'protected', 'user cannot be deleted')
    eq(select(2, P.deleteGroup('nope')), 'unknown_group', 'unknown group')
    eq(select(2, P.deleteGroup('vip', 1)), 'no_permission', 'a user may not delete')
    eq(select(2, P.deleteGroup('god', 2)), 'rank', 'the owner may not delete a group above itself')
    eq(select(2, P.deleteGroup('senior', 3)), 'rank', 'nor a group of its own weight')
    eq(select(2, P.deleteGroup('helper')), 'inherited', 'a group another inherits stays')
    joinAs(env, Core, 4, 'vip')
    eq(select(2, P.deleteGroup('vip', 2)), 'in_use', 'a group with an online member stays')
    stubs.dropPlayer(env, 4)
    eq(P.deleteGroup('vip', 2), true, 'deleted once nobody online is in it')
    eq(storedGroup(DB, 'vip'), nil, 'the row is gone')
    eq(P.groupExists('vip'), false, 'groupExists follows')
    eq(rows[#rows].action, 'perms.deleteGroup', 'the delete is audited')
    eq(lastHook(hooks, 'deleteGroup').detail, 'vip', 'permsChanged(nil, deleteGroup, name)')
    joinAs(env, Core, 4, 'user')
    eq(Core.Player.getInfo(4).group, 'vip', 'the offline member reconnects with the stored group')
    eq(P.getGroup(4), 'user', 'which reads as user once the group is gone')

    -- setGroup emits the hook exactly once (Player.setGroup announces it; Perms.setGroup only when it did not)
    local function groupHooks()
        local n = 0
        for i = 1, #hooks do if hooks[i].what == 'group' then n = n + 1 end end
        return n
    end
    local before = groupHooks()
    eq(P.setGroup(1, 'mod'), true, 'setGroup')
    eq(groupHooks() - before, 1, 'permsChanged(src, group) fires once')
    eq(lastHook(hooks, 'group').src, 1, 'for that src')
    local realSetGroup = Core.Player.setGroup
    Core.Player.setGroup = function() return true end   -- a Player.setGroup that announces nothing
    before = groupHooks()
    P.setGroup(1, 'mod')
    eq(groupHooks() - before, 1, 'Perms.setGroup announces it when Player.setGroup did not')
    eq(lastHook(hooks, 'group').detail, 'mod', 'with the group name')
    Core.Player.setGroup = realSetGroup

    -- an out-of-band grant write announced as permsChanged(src, 'grants') drops the cache (L2)
    eq(P.has(1, 'oob.perm'), false, 'not held yet (and cached)')
    local list = {}
    local account = storedAccount(DB, Core.Player.getInfo(1).accountId)
    for _, perm in ipairs(account.permissions or {}) do list[#list + 1] = perm end
    list[#list + 1] = 'oob.perm'
    Core.Player.setAccountData(1, 'permissions', list)
    Core.emitHook('permsChanged', 1, 'grants')   -- what Player.setAccountData announces (idempotent here)
    eq(P.has(1, 'oob.perm'), true, 'the out-of-band grant counts at once')
    Core.Audit = nil
    eq(P.saveGroup('mod', { label = 'M' }, 1), false, 'without Core.Audit a denial still works')
    check(printed('perms.saveGroup mod: denied') ~= nil, 'and falls back to the console audit line')
end

--- An unreadable table: the config seed answers, nothing is seeded over it, the load is retried.
local function suiteFallback()
    suite('fallback')
    stubs.resetServer()
    local env, Core = newServer()
    local P, DB = Core.Perms, Core.DB
    bridge.fail('^SELECT name, label, weight', 'XX000 simulated failure')   -- only the group load fails
    joinAs(env, Core, 1, 'mod')
    eq(P.has(1, 'core.mod'), true, 'the config seed answers while the table is unreadable')
    eq(P.has(1, 'core.helper'), true, 'including inheritance')
    eq(DB.count('perm_groups'), 0, 'nothing is seeded over an unreadable table')
    check(printed('perm_groups could not be loaded') ~= nil, 'the failure is logged')
    eq(select(2, P.saveGroup('vip', {})), 'not_ready', 'group edits wait for the table')

    bridge.unfail()
    eq(P.groupExists('mod'), true, 'within the retry window the seed still answers')
    eq(DB.count('perm_groups'), 0, 'and nothing was read or written yet')
    stubs.tick(30001)
    P.groups()
    eq(DB.count('perm_groups'), 6, 'after the retry window the table is read (and seeded)')
    eq(P.saveGroup('vip', {}), true, 'and edits work')
    eq(#stubs.failures, 0, 'no thread errored')

    -- a failed WRITE of saveGroup / deleteGroup is reported, and the memory keeps the stored state
    bridge.fail('^INSERT INTO "perm_groups"', 'XX000 simulated failure')
    eq(select(2, P.saveGroup('vip', { label = 'Very' })), 'save_failed', 'a failed upsert answers save_failed')
    bridge.unfail()
    eq(storedGroup(DB, 'vip').label, 'vip', 'the row is unchanged')
    local label
    for _, group in ipairs(P.groups()) do if group.name == 'vip' then label = group.label end end
    eq(label, 'vip', 'and so is the cached group')
    bridge.fail('^DELETE FROM "perm_groups"', 'XX000 simulated failure')
    eq(select(2, P.deleteGroup('vip')), 'save_failed', 'a failed delete answers save_failed')
    bridge.unfail()
    eq(P.groupExists('vip'), true, 'the group stays')
end

--- Perms.has never yields and never reads the database (DESIGN §56.8 rule 2): account grants come from the live
--- session (Player.getAccountData), character grants from Player.getData, groups from memory.
local function suiteNoYield()
    suite('no yield')
    stubs.resetServer()
    local env, Core = newServer()
    local P = Core.Perms
    joinAs(env, Core, 1, 'mod')
    eq(P.grant(1, 'acc.perm'), true, 'an account grant')
    eq(P.grant(1, 'char.perm', 'character'), true, 'a character grant')
    Core.emitHook('permsChanged', 1, 'grants')   -- drop the caches: the next checks rebuild them from the session
    local log, restore = spyDB(env)
    bridge.fail('.', 'XX000 simulated failure')   -- any statement would fail now
    local answers = {}
    local co = coroutine.create(function()
        answers[1] = P.has(1, 'acc.perm')
        answers[2] = P.has(1, 'char.perm')
        answers[3] = P.has(1, 'core.mod')
        answers[4] = P.has(1, 'core.admin')
        answers[5] = P.explain(1, 'acc.perm').via
        answers[6] = P.getWeight(1)
        answers[7] = P.canTarget(1, 99)
    end)
    local ok, err = coroutine.resume(co)
    check(ok, 'the checks ran', tostring(err))
    eq(coroutine.status(co), 'dead', 'the checks finished without yielding')
    eq(answers[1], true, 'account grant from the live session')
    eq(answers[2], true, 'character grant from the session data')
    eq(answers[3], true, 'group chain from memory')
    eq(answers[4], false, 'and nothing more')
    eq(answers[5], 'account', 'explain agrees')
    eq(answers[6], 200, 'getWeight from memory')
    eq(answers[7], true, 'canTarget from memory')
    eq(P.has(1, 'acc.perm'), true, 'outside a coroutine as well (main chunk)')
    eq(#log, 0, 'not one core_db call was made')
    bridge.unfail()
    restore()

    -- the account read path: a deep copy of the live account, internal to core
    local grants = Core.Player.getAccountData(1, 'permissions')
    check(has(grants, 'acc.perm'), 'Player.getAccountData reads the live account')
    grants[#grants + 1] = 'forged.perm'
    eq(P.has(1, 'forged.perm'), false, 'it hands out a copy')
    eq(Core.Player.getAccountData(99, 'permissions'), nil, 'nil without a session')
    local called, blocked = pcall(stubs.exports.core.call, 'plugin', 'Player', 'getAccountData', 1, 'permissions')
    eq(called, false, 'Player.getAccountData is not reachable through the export')
    eq(blocked, 'core: Player.getAccountData is internal', 'it is block-listed')

    -- a colour cleared by saveGroup is NULL in the row
    eq(P.saveGroup('mod', { color = '#112233' }), true, 'set a colour')
    eq(storedGroup(Core.DB, 'mod').color, '#112233', 'stored')
    eq(P.saveGroup('mod', { color = '' }), true, 'clear it')
    eq(storedGroup(Core.DB, 'mod').color, nil, 'the column is NULL again')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- Callback.register(name, schema?, fn, opts) — permission + cooldown before the handler (§44).
local function suiteCallbackOpts()
    suite('callback opts')
    stubs.resetServer()
    local env, Core = newServer()
    local client = stubs.newEnv('client', 'core_example')
    local ClientCore = stubs.loadImport(client)
    local CB = Core.Callback

    local runs = 0
    CB.register('t:audit', function() runs = runs + 1 return 'rows' end, { permission = 'core.audit.view' })
    local answer = 'unset'
    client.CreateThread(function() answer = ClientCore.Callback.await('t:audit') end)
    eq(answer, nil, 'a caller without the permission is answered nil')
    eq(runs, 0, 'and the handler never ran')
    joinAs(env, Core, 1, 'admin')
    client.CreateThread(function() answer = ClientCore.Callback.await('t:audit') end)
    eq(answer, 'rows', 'the permission holder (group default) is answered')

    -- schema -> cooldown -> permission, with register(name, schema, fn, opts)
    local seen = 0
    CB.register('t:cool', { 'integer' }, function(_, n) seen = seen + 1 return n end, { cooldownMs = 1000 })
    local a, b, c = 'unset', 'unset', 'unset'
    client.CreateThread(function() a = ClientCore.Callback.await('t:cool', 'nope') end)
    eq(a, nil, 'a bad payload is refused first')
    client.CreateThread(function() b = ClientCore.Callback.await('t:cool', 5) end)
    eq(b, 5, 'the bad payload did not start the cooldown')
    client.CreateThread(function() c = ClientCore.Callback.await('t:cool', 6) end)
    eq(c, nil, 'a second request inside the cooldown is refused')
    stubs.tick(1000)
    client.CreateThread(function() c = ClientCore.Callback.await('t:cool', 7) end)
    eq(c, 7, 'after the cooldown it is answered again')
    eq(seen, 2, 'the handler ran twice')
    stubs.triggerOn(env, 'playerDropped', 1, 'quit')
    client.CreateThread(function() c = ClientCore.Callback.await('t:cool', 8) end)
    eq(c, 8, 'playerDropped clears the cooldown of that src')

    -- register(name, fn, opts) and the `cooldown` spelling
    CB.register('t:noschema', function() return 'x' end, { cooldown = 5000 })
    client.CreateThread(function() c = ClientCore.Callback.await('t:noschema') end)
    eq(c, 'x', 'register(name, fn, opts) keeps the handler')
    client.CreateThread(function() c = ClientCore.Callback.await('t:noschema') end)
    eq(c, nil, "opts.cooldown (Net.on's spelling) works too")

    -- invalid opts refuse the registration
    CB.register('t:bad', function() return 1 end, { permission = 42 })
    check(printed('Callback.register: t:bad refused') ~= nil, 'a non-string permission refuses the registration')
    check(not env.__vm.netEvents['core:cb:req:t:bad'], 'nothing was registered')
    CB.register('t:bad2', function() return 1 end, { cooldownMs = -1 })
    check(printed('Callback.register: t:bad2 refused') ~= nil, 'a negative cooldown refuses the registration')

    -- a plugin VM asks Core.Perms.has through the export proxy
    local asked = {}
    stubs.exports.core = { call = function(_, ns, fn, src, perm)
        if ns == 'Perms' and fn == 'has' then
            asked[#asked + 1] = perm
            return src == 1 and perm == 'plugin.use'
        end
    end }
    local plugin = stubs.newEnv('server', 'core_example')
    local PluginCore = stubs.loadImport(plugin)
    PluginCore.Callback.register('t:plugin', function() return 'ok' end, { permission = 'plugin.use' })
    client.CreateThread(function() c = ClientCore.Callback.await('t:plugin') end)
    eq(c, 'ok', 'the plugin VM gate passes through Core.Perms.has')
    eq(asked[1], 'plugin.use', 'the proxy was asked for the permission')
    PluginCore.Callback.register('t:plugin2', function() return 'ok' end, { permission = 'plugin.other' })
    client.CreateThread(function() c = ClientCore.Callback.await('t:plugin2') end)
    eq(c, nil, 'and refuses what Core.Perms.has refuses')
    stubs.exports.core = nil

    -- the client side accepts and ignores opts
    ClientCore.Callback.register('t:ping', function(w) return 'pong-' .. w end, { permission = 'x' })
    local pong = 'unset'
    env.CreateThread(function() pong = Core.Callback.awaitClient(1, 't:ping', 'y') end)
    eq(pong, 'pong-y', 'a client registration with opts still answers')
    eq(#stubs.failures, 0, 'no thread errored')
end

--------------------------------------------------------------------------------
-- run
--------------------------------------------------------------------------------

local SUITES <const> = {
    { 'seed', suiteSeed }, { 'inheritance', suiteInheritance }, { 'weights', suiteWeights },
    { 'define', suiteDefine }, { 'temporary', suiteTemporary }, { 'explain', suiteExplain },
    { 'manage', suiteManage }, { 'fallback', suiteFallback }, { 'no yield', suiteNoYield },
    { 'callback opts', suiteCallbackOpts },
}

for i = 1, #SUITES do
    local name, fn = SUITES[i][1], SUITES[i][2]
    local ok, err = pcall(fn)
    if not ok then
        failed = failed + 1
        print(('FAIL  [%s] suite crashed: %s'):format(name, tostring(err)))
    end
end

print(('perms: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
