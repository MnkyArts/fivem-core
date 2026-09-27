--[[
    core/tests/admin_harness.lua — the shared harness of tests/admin_api_tests.lua (Core.Admin, DESIGN §51):
    counters and checks, a real core server VM with six loaded players (1 owner, 2 admin, 3 mod,
    4 helper, 5 and 6 users), plugin calls through the export, server callbacks as a client drives
    them, audit rows and a minimal action definition. Load it with loadfile(path)(testsDir).
]]

local here = ...
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
local vector3 = stubs.vector3
local xtype = stubs.type   -- reports the stub vectors as 'vector3', like the runtime

local passed, failed, suiteName = 0, 0, '?'

local function suite(name) suiteName = name end

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

--- Every client send of `name` (optionally to `target`) since the last stubs.clear / mark.
local function sends(name, target, from)
    local out = {}
    for i = from or 1, #stubs.sent do
        local s = stubs.sent[i]
        if s.side == 'client' and s.name == name and (target == nil or s.target == target) then out[#out + 1] = s end
    end
    return out
end

--- Does a value hold a function anywhere (the snapshot must not)?
local function hasFunction(v, depth)
    depth = depth or 0
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' or depth > 12 then return false end
    for k, item in pairs(v) do
        if hasFunction(k, depth + 1) or hasFunction(item, depth + 1) then return true end
    end
    return false
end

-- manifest order, audit.lua included (real rows), getters.lua for resolveTargets, security.lua last
local SERVER_FILES <const> = {
    'shared/ui_forms.lua', 'server/api.lua', 'shared/hooks.lua', 'server/db.lua',
    'server/audit.lua', 'server/notify.lua', 'server/perms.lua', 'server/buckets.lua', 'server/player_store.lua',
    'server/player.lua',
    'server/playergrid.lua', 'server/money.lua', 'server/factions.lua', 'server/vehicles.lua', 'server/getters.lua',
    'server/adminapi.lua', 'server/adminapi_dispatch.lua', 'server/security.lua',
}

local GROUPS <const> = { 'owner', 'admin', 'mod', 'helper', 'user', 'user' }
local NAMES <const> = { 'Olga', 'Ada', 'Moe', 'Hal', 'Uma', 'Ugo' }

--- A fresh core VM with six loaded players: 1 owner, 2 admin, 3 mod, 4 helper, 5 and 6 users.
local function newServer(opts)
    opts = opts or {}
    stubs.resetServer()
    stubs.newWorld()
    stubs.clear()
    for i = #stubs.failures, 1, -1 do stubs.failures[i] = nil end
    stubs.tick(1000)
    local env = stubs.newEnv('server', 'core')
    env.GetConvar = function(_, fallback) return fallback end
    env.SetRoutingBucketEntityLockdownMode = function() end
    env.SetRoutingBucketPopulationEnabled = function() end
    -- server natives tests/stubs.lua lacks (BOOL answers false / 1 like the default invoke path)
    env.IsPedAPlayer = function(ped)
        for _, p in pairs(stubs.peds) do if p == ped then return 1 end end
        return false
    end
    env.NetworkGetEntityOwner = function(entity)
        for src, p in pairs(stubs.peds) do if p == entity then return src end end
        return -1
    end
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    if opts.config then opts.config(env.Config) end
    for i = 1, #SERVER_FILES do stubs.loadFile(env, SERVER_FILES[i]) end
    stubs.triggerOn(env, 'onResourceStart', 0, 'core')
    stubs.tick(10)
    local Core = env.Core
    for src = 1, #GROUPS do
        stubs.connectPlayer(env, src, { name = NAMES[src], coords = vector3(src * 10.0, 0.0, 0.0) })
        if GROUPS[src] ~= 'user' then assert(Core.Perms.setGroup(src, GROUPS[src]), 'setGroup') end
    end
    stubs.tick(2000)   -- the snapshotChanged of the group changes is out of the way
    return env, Core
end

--- A registration made the way a plugin makes it: through core's `call` export with that caller.
local function as(resource, fn, ...)
    return stubs.exports.core.call(resource, 'Admin', fn, ...)
end

local serial = 0
--- Drives one server callback as client `src` would; returns (answered ok, value).
local function callServer(env, name, src, ...)
    serial = serial + 1
    local key = 'tst:' .. serial
    stubs.triggerOn(env, 'core:cb:req:' .. name, src, key, ...)
    for i = #stubs.sent, 1, -1 do
        local s = stubs.sent[i]
        if s.name == 'core:cb:res:' .. name and s.args[1] == key then return s.args[2], s.args[3] end
    end
    return nil, nil
end

--- Every audit row, newest first; `action` filters exactly.
local function rows(Core, action)
    return Core.Audit.query({ action = action, limit = 200 }).rows
end

--- A minimal valid action; `extra` overrides.
local function def(id, extra)
    local d = { id = id, category = 'players', label = 'Act ' .. id, target = 'none',
        handler = function() return true, 'done' end }
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end

local function counts()
    return passed, failed
end

--- A crashed suite counts as one failure.
local function crashed(name, err)
    failed = failed + 1
    print(('FAIL  [%s] suite crashed: %s'):format(name, tostring(err)))
end

return {
    stubs = stubs, vector3 = vector3, xtype = xtype, suite = suite, show = show, check = check, eq = eq,
    printed = printed, sends = sends, hasFunction = hasFunction, newServer = newServer, as = as,
    callServer = callServer, rows = rows, def = def, counts = counts, crashed = crashed,
}
