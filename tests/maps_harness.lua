--[[
    core/tests/maps_harness.lua — the shared harness of tests/maps_tests.lua and tests/maps_store_tests.lua
    (Core.Maps, DESIGN §52). Not a suite: `local H = dofile(here .. '/maps_harness.lua')`.

    A core server VM with the real api, hooks, db (KVP or a given adapter), settings, buckets and the four
    map files; Audit, Cron and Player are recording stand-ins, Core.MapRegions a fake that records every
    put/remove/clearBucket (§52.4a). The recorded state lives on H and is replaced by every newServer():
    H.audits, H.cronJobs, H.regionLog, H.population, H.lockdown, H.natives (entity creations), H.rpcs
    (plate / paint / lock RPCs), H.owners / H.owner (the network owner NetworkGetEntityOwner answers).
]]

local here = (arg and arg[0] or 'tests/maps_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local H = { stubs = stubs, name = 'maps', passed = 0, failed = 0, audits = {}, cronJobs = {}, regionLog = {},
    population = {}, lockdown = {}, natives = {}, rpcs = {}, owners = {}, owner = 1 }

function H.check(cond, label)
    if cond then H.passed = H.passed + 1 else H.failed = H.failed + 1; print(('FAIL  [%s] %s'):format(H.name, label)) end
    return cond and true or false
end

function H.eq(actual, expected, label)
    return H.check(actual == expected, ('%s (expected %s, got %s)'):format(label, tostring(expected), tostring(actual)))
end

function H.callable(fn) return setmetatable({}, { __call = function(_, ...) return fn(...) end }) end

--- The internal region interface of §52.4a, recording every call in order.
local function fakeRegions()
    local function log(entry) H.regionLog[#H.regionLog + 1] = entry end
    return { stats = function() return {} end,
        put = function(bucket, uid, tuple) log({ op = 'put', bucket = bucket, uid = uid, tuple = tuple }) end,
        remove = function(bucket, uid) log({ op = 'remove', bucket = bucket, uid = uid }) end,
        clearBucket = function(bucket) log({ op = 'clear', bucket = bucket }) end }
end

--- The region calls recorded since the last reset(), optionally filtered by op and bucket.
function H.calls(op, bucket)
    local out = {}
    for _, c in ipairs(H.regionLog) do
        if (op == nil or c.op == op) and (bucket == nil or c.bucket == bucket) then out[#out + 1] = c end
    end
    return out
end

function H.reset() H.regionLog, H.natives, H.rpcs = {}, {}, {} end

--- Natives stubs.lua does not have (all fxref-verified server / server-RPC forms).
local function installNatives(env)
    env.SetRoutingBucketPopulationEnabled = function(bucket, mode) H.population[bucket] = mode end
    env.SetRoutingBucketEntityLockdownMode = function(bucket, mode) H.lockdown[bucket] = mode end
    local function create(name, kind, hash, x, y, z, args)
        H.natives[#H.natives + 1] = { name = name, args = args }
        local e = stubs.newEntity(kind, { model = hash })
        stubs.coords[e] = stubs.vector3(x, y, z)
        return e
    end
    env.CreatePed = function(...) local a = { ... } return create('CreatePed', 1, a[2], a[3], a[4], a[5], a) end
    env.CreateObjectNoOffset = function(...)
        local a = { ... }
        return create('CreateObjectNoOffset', 3, a[1], a[2], a[3], a[4], a)
    end
    local createVehicle = env.CreateVehicleServerSetter
    env.CreateVehicleServerSetter = function(...)
        H.natives[#H.natives + 1] = { name = 'CreateVehicleServerSetter', args = { ... } }
        return createVehicle(...)
    end
    local function setter(key, pack)
        return function(e, ...)
            local rec = stubs.entities[e]
            if rec then rec[key] = pack(...) end
        end
    end
    env.SetEntityRotation = setter('rot', function(x, y, z, order) return { x = x, y = y, z = z, order = order } end)
    env.FreezeEntityPosition = setter('frozen', function(on) return on end)
    env.SetVehicleCustomPrimaryColour = setter('primary', function(r, g, b) return { r, g, b } end)
    env.SetVehicleCustomSecondaryColour = setter('secondary', function(r, g, b) return { r, g, b } end)
    -- in-place updates (§52.2 notes): paint, cleared scenario, bucket / owner reads. H.owners[e] = a
    -- player's net id or -1 (server-owned); unset = H.owner (1: a client near every entity)
    env.SetVehicleColours = function(e, p, s)
        H.rpcs[#H.rpcs + 1] = { name = 'SetVehicleColours', args = { e, p, s } }
        local rec = stubs.entities[e]
        if rec then rec.colours = { p, s } end
    end
    env.ClearPedTasks = setter('tasksCleared', function() return true end)
    env.GetEntityRoutingBucket = function(e)
        local rec = stubs.entities[e]
        return rec and rec.exists and rec.bucket or 0
    end
    env.NetworkGetEntityOwner = function(e)
        local rec = stubs.entities[e]
        if not (rec and rec.exists) then return -1 end
        return H.owners[e] or H.owner
    end
    local setPlate = env.SetVehicleNumberPlateText
    env.SetVehicleNumberPlateText = function(e, plate)
        H.rpcs[#H.rpcs + 1] = { name = 'SetVehicleNumberPlateText', args = { e, plate } }
        return setPlate(e, plate)
    end
    local setLocked = env.SetVehicleDoorsLocked
    env.SetVehicleDoorsLocked = function(e, status)
        H.rpcs[#H.rpcs + 1] = { name = 'SetVehicleDoorsLocked', args = { e, status } }
        return setLocked(e, status)
    end
end

--- The cosmetic RPC natives recorded since the last reset() with that name (H.natives holds creations).
function H.rpcCalls(name)
    local out = {}
    for _, c in ipairs(H.rpcs) do if c.name == name then out[#out + 1] = c end end
    return out
end

--- The `core:maps:pose` events the server sent since `from` (index into stubs.sent, default 1).
function H.poses(from)
    local out = {}
    for i = from or 1, #stubs.sent do
        local s = stubs.sent[i]
        if s.name == 'core:maps:pose' then out[#out + 1] = s end
    end
    return out
end

--- A core server VM with the map system started. opts = { keepKvp (a restart over the same KVP store),
--- adapter = fn(env) -> DB adapter, noRegions }.
function H.newServer(opts)
    opts = opts or {}
    stubs.newWorld()
    stubs.clear()
    if not opts.keepKvp then stubs.resetServer() end
    stubs.tick(1000)
    H.audits, H.cronJobs, H.population, H.lockdown, H.owners, H.owner = {}, {}, {}, {}, {}, 1
    H.reset()
    local env = stubs.newEnv('server', 'core')
    installNatives(env)
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    stubs.loadFile(env, 'server/api.lua')
    stubs.loadFile(env, 'shared/hooks.lua')
    stubs.loadFile(env, 'server/db.lua')
    local Core = env.Core
    if opts.adapter then Core.DB.setAdapter(opts.adapter(env)) end
    Core.Audit = { record = function(row) H.audits[#H.audits + 1] = row return #H.audits end }
    Core.Cron = { every = function(ms, fn)
        H.cronJobs[#H.cronJobs + 1] = { ms = ms, fn = fn }
        return 'cron:' .. #H.cronJobs
    end }
    Core.Player = { getInfo = function(src) return { accountId = 'acc' .. src, name = 'Player' .. src } end }
    stubs.loadFile(env, 'server/settings.lua')
    stubs.loadFile(env, 'server/buckets.lua')
    if not opts.noRegions then Core.MapRegions = fakeRegions() end
    stubs.loadFile(env, 'server/maps_types.lua')
    stubs.loadFile(env, 'server/maps_runtime.lua')
    stubs.loadFile(env, 'server/maps.lua')
    stubs.loadFile(env, 'server/maps_apply.lua')
    env.TriggerEvent('onResourceStart', 'core')
    return env, Core
end

--- A call as a plugin makes it: through core's `call` export with that resource as the caller.
function H.as(resource, fn, ...)
    return stubs.exports.core.call(resource, 'Maps', fn, ...)
end

function H.stop(env, resource) env.TriggerEvent('onResourceStop', resource) end

function H.lastAudit(action)
    for i = #H.audits, 1, -1 do if H.audits[i].action == action then return H.audits[i] end end
end

function H.byUid(list, uid)
    for i = 1, #list do if list[i].uid == uid then return list[i] end end
end

--- Prints the summary line and exits 1 on any failure or uncaught thread/handler error.
function H.finish()
    print(('%s: %d passed, %d failed'):format(H.name, H.passed, H.failed))
    for i = 1, #stubs.failures do print('  uncaught: ' .. stubs.failures[i]) end
    if H.failed > 0 or #stubs.failures > 0 then os.exit(1) end
end

return H
