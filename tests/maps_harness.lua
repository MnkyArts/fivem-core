--[[
    core/tests/maps_harness.lua — the shared harness of tests/maps_tests.lua and tests/maps_store_tests.lua
    (Core.Maps, DESIGN §52.1, §52.2, §55.21.1). Not a suite: `local H = dofile(here .. '/maps_harness.lua')`.

    A core server VM with the real api, hooks, settings, buckets and the four map files over the Postgres test
    bridge (DESIGN §56.10: core_db's real code against the throwaway test database); Audit, Cron and Player are
    recording stand-ins. Core.Scene is a RECORDING FAKE by default (the real lib
    part, lib/scene/shared.lua — PAINTS, paintOf, tierOf — behind it): spawn / set / move / remove (with its
    `fade` flag) / get / defineKind / batch, every call in H.log in order with the Registry caller it ran as (a
    batch is logged as op 'batch' before its calls: H.slices() splits the log per worker slice), the live nodes in
    H.nodes (their `authority` kept), Core.SceneRuntime.store.loaded() answering H.sceneLoaded, H.refuse[op] = err
    making an op fail, H.refuseIf(op, fn(def|id) -> err|nil) refusing selectively, H.onSpawn = fn(def) running once
    inside the next spawn (Scene fires its hooks synchronously), H.cap = n refusing spawns with 'limit' while n
    fake nodes exist. `scene = 'real'` loads the real scene server files instead (codec, motion, scene_kinds →
    scene_store → scene; no-op R.index / R.interest / R.flush, a recording R.promote: H.promoteLog). The recorded
    state lives on H and is replaced by every newServer(): H.audits, H.cronJobs, H.log, H.nodes, H.kinds,
    H.population, H.lockdown, H.cap, H.refuseIf.

    The database side: the VM's `exports.core_db` is wrapped. Queued writes (save / patch / remove / append /
    enqueue) are HELD until the VM next awaits core_db (any awaited export — not isHealthy / migrate, which never
    yield —, H.release, H.sql, H.sync, H.fail, newServer, finish) and then sent as ONE enqueue — one flush, one transaction — the way FiveM commits everything one Lua
    execution slice queued (§56.3.3); a refused slice is a failure (H.dbErrors). Every statement text the VM sends
    is logged in H.sqlLog ({ fn, sql, key? }; a helper call as 'crud <op> <table> [columns]', a queued row write as
    '<save|patch|remove|append> <table>', a queued statement as its text). H.sql(sql, params) =
    bridge.sql after releasing the held writes; H.fail(pattern, err) / H.unfail() = bridge.fail / unfail (held
    writes released first); H.sync() = Core.DB.flush() of the current VM (waits out a retry after a failed flush).
]]

local here = (arg and arg[0] or 'tests/maps_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local bridge = stubs.bridge
local H = { stubs = stubs, bridge = bridge, name = 'maps', passed = 0, failed = 0, audits = {}, cronJobs = {}, log = {},
    nodes = {}, kinds = {}, refuse = {}, promoteLog = {}, population = {}, lockdown = {}, sceneLoaded = true,
    filters = {}, sqlLog = {}, dbErrors = {} }
local releases = {}           -- the held-write release function of every VM newServer built

--- H.refuseIf(op, fn(def | id) -> err | nil): the fake refuses `op` whenever fn answers an error code.
function H.refuseIf(op, fn) H.filters[op] = fn end

function H.check(cond, label)
    if cond then H.passed = H.passed + 1 else H.failed = H.failed + 1; print(('FAIL  [%s] %s'):format(H.name, label)) end
    return cond and true or false
end

function H.eq(actual, expected, label)
    return H.check(actual == expected, ('%s (expected %s, got %s)'):format(label, tostring(expected), tostring(actual)))
end

function H.callable(fn) return setmetatable({}, { __call = function(_, ...) return fn(...) end }) end

local function deepCopy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepCopy(x) end
    return out
end
H.deepCopy = deepCopy

--- Deep equality of plain data (exact node defs).
function H.same(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do if not H.same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

--- Core.Scene as a recording fake (§55.4 shapes). A move or a fields set clears `promoted` (the real Scene demotes
--- a promoted node first); a node's `owner` is the Registry caller its spawn ran as.
local function fakeScene(env)
    local nextId = 0
    local Scene = {}
    local function log(entry)
        entry.caller = env.Core.Registry.getCaller()
        H.log[#H.log + 1] = entry
        return entry
    end
    local function about(op, id, extra)
        local n = H.nodes[id]
        local entry = extra or {}
        entry.op, entry.id = op, id
        entry.bucket, entry.uid = n and n.bucket, n and n.fields.mapEl
        entry.promoted = n ~= nil and n.promoted ~= nil
        return log(entry)
    end
    function Scene.defineKind(def)
        log({ op = 'defineKind', def = def })
        if H.refuse.defineKind then return false, H.refuse.defineKind end
        H.kinds[def.id] = def
        return true
    end
    local function live()
        local n = 0
        for _ in pairs(H.nodes) do n = n + 1 end
        return n
    end
    function Scene.spawn(def)
        local entry = log({ op = 'spawn', def = deepCopy(def), bucket = def.bucket, kind = def.kind,
            uid = def.fields and def.fields.mapEl })
        if H.refuse.spawn then return nil, H.refuse.spawn end
        local veto = H.filters.spawn and H.filters.spawn(def)
        if veto then return nil, veto end
        if H.cap and live() >= H.cap then
            entry.refused = 'limit'
            return nil, 'limit'
        end
        nextId = nextId + 1
        local id = nextId
        entry.id = id
        H.nodes[id] = { id = id, kind = def.kind, bucket = def.bucket or 0, pos = deepCopy(def.pos),
            rot = deepCopy(def.rot), fields = deepCopy(def.fields or {}), audience = deepCopy(def.audience),
            authority = deepCopy(def.authority), persist = def.persist, owner = entry.caller }
        local hook = H.onSpawn                    -- a one-shot synchronous 'spawned' listener (Scene fires them inline)
        if hook then
            H.onSpawn = nil
            hook(def)
        end
        return id
    end
    function Scene.move(id, pos, rot)
        about('move', id, { pos = deepCopy(pos), rot = deepCopy(rot) })
        if H.refuse.move then return false, H.refuse.move end
        local n = H.nodes[id]
        if not n then return false, 'missing' end
        n.pos, n.rot, n.promoted = deepCopy(pos), rot and deepCopy(rot) or n.rot, nil
        return true
    end
    function Scene.set(id, patch, opts)
        about('set', id, { patch = deepCopy(patch), remove = opts and deepCopy(opts.remove) })
        if H.refuse.set then return false, H.refuse.set end
        local n = H.nodes[id]
        if not n then return false, 'missing' end
        for k, v in pairs(patch or {}) do n.fields[k] = deepCopy(v) end
        for _, k in ipairs(opts and opts.remove or {}) do n.fields[k] = nil end
        n.promoted = nil
        return true
    end
    function Scene.remove(id, opts)
        about('remove', id, { fade = type(opts) == 'table' and opts.fade == true or nil })
        local n = H.nodes[id]
        if not n then return false, 'missing' end
        H.nodes[id] = nil
        return true
    end
    function Scene.get(id)
        local n = H.nodes[id]
        return n and deepCopy(n) or nil
    end
    --- Scene.batch: the calls of fn in one slice (logged as op 'batch' first), errors caught like the real one.
    function Scene.batch(fn, ...)
        H.log[#H.log + 1] = { op = 'batch' }
        local res = table.pack(pcall(fn, ...))
        if not res[1] then
            H.batchErrors = (H.batchErrors or 0) + 1
            return nil, 'error'
        end
        return table.unpack(res, 2, res.n)
    end
    return Scene
end

--- The recorded Scene calls since the last reset(), optionally filtered by op and bucket.
function H.calls(op, bucket)
    local out = {}
    for _, c in ipairs(H.log) do
        if (op == nil or c.op == op) and (bucket == nil or c.bucket == bucket) then out[#out + 1] = c end
    end
    return out
end

--- 'spawn:m1:1 move:m1:1 remove:m1:2' — the call sequence since the last reset(), compact.
function H.trace()
    local parts = {}
    for _, c in ipairs(H.log) do
        if c.op ~= 'defineKind' and c.op ~= 'batch' then parts[#parts + 1] = c.op .. ':' .. tostring(c.uid) end
    end
    return table.concat(parts, ' ')
end

function H.reset() H.log = {} end

--- The recorded calls split at every 'batch' entry: { { spawn = n, remove = n, move = n, set = n, get = n }, … } —
--- slices[1] holds what ran before the first batch (inline work), then one entry per worker slice.
function H.slices()
    local out, cur = {}, {}
    for _, c in ipairs(H.log) do
        if c.op == 'batch' then
            out[#out + 1] = cur
            cur = {}
        elseif c.op ~= 'defineKind' then
            cur[c.op] = (cur[c.op] or 0) + 1
        end
    end
    out[#out + 1] = cur
    return out
end

--- The live fake node of a uid (in `bucket` when given), or nil — and how many there are.
function H.node(uid, bucket)
    local found, n = nil, 0
    for _, node in pairs(H.nodes) do
        if node.fields.mapEl == uid and (bucket == nil or node.bucket == bucket) then found, n = node, n + 1 end
    end
    return found, n
end

--- The first entry of a list of recorded calls (H.calls(...)) about `uid`.
function H.byUid(list, uid)
    for i = 1, #list do if list[i].uid == uid then return list[i] end end
end

--- Natives stubs.lua does not have (fxref-verified server forms, used by server/buckets.lua).
local function installNatives(env)
    env.SetRoutingBucketPopulationEnabled = function(bucket, mode) H.population[bucket] = mode end
    env.SetRoutingBucketEntityLockdownMode = function(bucket, mode) H.lockdown[bucket] = mode end
end

--- The real scene server files (manifest order: after the map files) with no-op R.index / R.interest / R.flush
--- and a recording R.promote whose beforeChange demotes (H.promoteLog { what, id, promoted }).
local function loadRealScene(env)
    local Core = env.Core
    stubs.loadFile(env, 'server/scene_kinds.lua')
    local R = Core.SceneRuntime
    local none = function() end
    local empty = function() return {} end
    R.index = { put = none, changed = none, remove = none, event = none, dr = none, cellsNear = empty,
        nodesIn = empty, gatedIn = empty, stats = empty }
    R.interest = { allows = function() return true end, pin = none, prefetch = none, drop = none, stats = empty }
    R.flush = { queue = none, queueLatent = none, wake = none, stats = empty }
    stubs.loadFile(env, 'server/scene_store.lua')
    stubs.loadFile(env, 'server/scene.lua')
    R.promote = {
        beforeChange = function(node, what)
            H.promoteLog[#H.promoteLog + 1] = { what = what, id = node.id, promoted = node.promoted ~= nil }
            local was = node.promoted ~= nil
            node.promoted = nil
            return was
        end,
        refuses = function() return false end,
        stats = empty,
    }
end

--- Every statement text a VM sends, for H.sqlLog.
local function logStatements(fn, ...)
    local args = table.pack(...)
    local function add(sql) H.sqlLog[#H.sqlLog + 1] = { fn = fn, sql = tostring(sql) } end
    if fn == 'query' then
        add(args[1])
    elseif fn == 'txQuery' then
        add(args[2])
    elseif fn == 'batch' then
        for _, st in ipairs(type(args[1]) == 'table' and args[1] or {}) do add(st.sql) end
    elseif fn == 'crud' then
        local cols = type(args[3]) == 'table' and type(args[3].columns) == 'table' and args[3].columns or nil
        add(('crud %s %s%s'):format(tostring(args[1]), tostring(args[2]), cols and (' ' .. table.concat(cols, ',')) or ''))
    end
end

local SYNC_EXPORTS <const> = { isHealthy = true, migrate = true }

--- Wraps a VM's exports.core_db: queued entries are held and sent as ONE enqueue (one transaction) when the VM
--- next talks to core_db; every statement is logged. Returns the release function.
local function wrapDb(env)
    local target = rawget(env.exports, 'core_db')
    local held = {}
    local function release()
        if #held == 0 then return end
        local list = held
        held = {}
        local ret = target:enqueue(list)
        if type(ret) == 'table' and ret.error ~= nil then
            H.dbErrors[#H.dbErrors + 1] = tostring(ret.error)
            print(('FAIL  [%s] core_db refused a queued slice: %s'):format(H.name, tostring(ret.error)))
        end
    end
    local proxy = setmetatable({ synchronous = true }, { __index = function(t, fn)
        local f
        if fn == 'enqueue' then
            f = function(_, entries)
                for i = 1, #entries do
                    local e = entries[i]
                    held[#held + 1] = e
                    H.sqlLog[#H.sqlLog + 1] = { fn = 'enqueue', key = e.key,
                        sql = e.t == 'sql' and tostring(e.sql) or ('%s %s'):format(tostring(e.t), tostring(e.table)) }
                end
                return { seq = 0 }
            end
        elseif SYNC_EXPORTS[fn] then            -- answered at once in FiveM too: no yield, no flush point
            f = function(_, ...) return target[fn](target, ...) end
        else
            f = function(_, ...)
                release()
                logStatements(fn, ...)
                return target[fn](target, ...)
            end
        end
        rawset(t, fn, f)
        return f
    end })
    rawset(env.exports, 'core_db', proxy)
    return release
end

--- Sends every VM's held writes (one transaction per VM).
function H.release()
    for i = 1, #releases do releases[i]() end
end

--- A direct query as the invoker `tests` (after the held writes) -> rows | nil, err.
function H.sql(sql, params)
    H.release()
    return bridge.sql(sql, params)
end

--- The first row of H.sql, or nil.
function H.row(sql, params)
    local rows = H.sql(sql, params)
    return rows and rows[1]
end

--- Statements matching `pattern` answer `err` until H.unfail() (bridge.fail; held writes go out first).
function H.fail(pattern, err)
    H.release()
    return bridge.fail(pattern, err)
end

function H.unfail() return bridge.unfail() end

--- Core.DB.flush() in the current VM: every queued write committed (after a failed flush: its retry).
function H.sync()
    return H.core.DB.flush()
end

--- The logged statements (since index `from`, default 1) whose text finds `pattern` (a Lua pattern).
function H.statements(pattern, from)
    local out = {}
    for i = from or 1, #H.sqlLog do
        if H.sqlLog[i].sql:find(pattern) then out[#out + 1] = H.sqlLog[i].sql end
    end
    return out
end

--- A core server VM with the map system started. opts = { keepDb (a restart over the same database; the old name
--- keepKvp works too), loadBatch
--- (R.loadBatch at start; the harness default 10000 loads without a tick — a small one makes the load yield per
--- batch), sceneLoaded = false (the fake Scene store has not loaded), refuse = the fake's H.refuse from the start,
--- scene = 'real' }.
function H.newServer(opts)
    opts = opts or {}
    H.release()
    releases = {}
    stubs.newWorld()
    stubs.clear()
    if not (opts.keepDb or opts.keepKvp) then stubs.resetServer() end   -- keepKvp: the old name
    stubs.tick(1000)
    H.audits, H.cronJobs, H.population, H.lockdown = {}, {}, {}, {}
    H.log, H.nodes, H.kinds, H.refuse, H.promoteLog, H.onSpawn = {}, {}, {}, opts.refuse or {}, {}, nil
    H.filters, H.cap, H.batchErrors = {}, nil, nil
    H.sqlLog = {}
    H.sceneLoaded = opts.sceneLoaded ~= false
    local real = opts.scene == 'real'
    local env = stubs.newEnv('server', 'core')
    installNatives(env)
    releases[#releases + 1] = wrapDb(env)
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    if real then
        stubs.loadFile(env, 'shared/scene_codec.lua')
        stubs.loadFile(env, 'shared/scene_motion.lua')
    end
    stubs.loadFile(env, 'server/api.lua')
    stubs.loadFile(env, 'shared/hooks.lua')
    stubs.loadFile(env, 'server/db.lua')
    local Core = env.Core
    H.core = Core
    Core.Audit = { record = function(row) H.audits[#H.audits + 1] = row return #H.audits end }
    Core.Cron = { every = function(ms, fn)
        H.cronJobs[#H.cronJobs + 1] = { ms = ms, fn = fn }
        return 'cron:' .. #H.cronJobs
    end }
    Core.Player = { getInfo = function(src) return { accountId = 'acc' .. src, name = 'Player' .. src } end,
        isLoaded = function() return true end }
    stubs.loadFile(env, 'server/settings.lua')
    stubs.loadFile(env, 'server/buckets.lua')
    if not real then
        local lib = Core.Scene                    -- lib/scene/shared.lua (PAINTS, paintOf, tierOf) behind the fake
        Core.Scene = setmetatable(fakeScene(env), { __index = lib })
        Core.SceneRuntime = { store = { loaded = function() return H.sceneLoaded end } }
    end
    stubs.loadFile(env, 'server/maps_types.lua')
    stubs.loadFile(env, 'server/maps_runtime.lua')
    stubs.loadFile(env, 'server/maps.lua')
    stubs.loadFile(env, 'server/maps_apply.lua')
    Core.MapsRuntime.loadBatch = opts.loadBatch or 10000
    if real then loadRealScene(env) end
    env.TriggerEvent('onResourceStart', 'core')
    if real then stubs.tick(500) end              -- the scene store loads, the maps waiter projects
    return env, Core
end

--- A call as a plugin makes it: through core's `call` export with that resource as the caller.
function H.as(resource, fn, ...)
    return stubs.exports.core.call(resource, 'Maps', fn, ...)
end

function H.stop(env, resource) env.TriggerEvent('onResourceStop', resource) end

--- core stops in `env`: its projector's threads (worker, waiter, retry) end at their next wake without a Scene call,
--- so a later server's ticks never run an old VM's work.
function H.shutdown(env) env.TriggerEvent('onResourceStop', 'core') end

--- A map of `n` props at x = 1..n (y = opts.y or 0; rows of 5,000) created inactive, filled by applies of 200 ops.
--- opts = { mode = 'live' | 'draft', bucket = targetBucket, type = 'core:prop', y }
function H.bigMap(Maps, name, n, opts)
    opts = opts or {}
    local map = assert(Maps.create({ name = name, mode = opts.mode or 'live', active = false,
        targetBucket = opts.bucket, limits = { elements = math.max(n, 1), perModel = math.min(math.max(n, 1), 10000) } },
        1))
    local made = 0
    while made < n do
        local ops = {}
        for i = 1, math.min(200, n - made) do
            made = made + 1
            ops[i] = { op = 'create', type = opts.type or 'core:prop',
                pos = { x = (made - 1) % 5000 + 1, y = (opts.y or 0) + (made - 1) // 5000, z = 0 },
                fields = (opts.type or 'core:prop') == 'core:prop' and { model = 'prop_' .. made % 8 } or nil }
        end
        assert(Maps.apply(map.id, ops, 1))
    end
    return map
end

--- Every Wait(0) of the VM (the worker's yields between slices) records the log length: H.yields.
function H.countYields(env)
    H.yields = {}
    local wait = env.Wait
    env.Wait = function(ms)
        if ms == 0 then H.yields[#H.yields + 1] = #H.log end
        return wait(ms)
    end
end

--- The Scene calls (spawn / remove / move / set) of one H.slices() entry.
function H.sliceCalls(s) return (s.spawn or 0) + (s.remove or 0) + (s.move or 0) + (s.set or 0) end

--- GlobalState writes of `key` in `env`: a proxy that records every write (nil as the string 'nil') -> the list.
function H.recordGlobal(env, key)
    local store, writes = {}, {}
    env.GlobalState = setmetatable({}, {
        __index = store,
        __newindex = function(_, k, v)
            if k == key then writes[#writes + 1] = v == nil and 'nil' or v end
            store[k] = v
        end,
    })
    return writes
end

function H.lastAudit(action)
    for i = #H.audits, 1, -1 do if H.audits[i].action == action then return H.audits[i] end end
end

--- Prints the summary line and exits 1 on any failure, uncaught thread/handler error, refused queued slice or
--- bridge callback error.
function H.finish()
    H.release()
    print(('%s: %d passed, %d failed'):format(H.name, H.passed, H.failed))
    for i = 1, #stubs.failures do print('  uncaught: ' .. stubs.failures[i]) end
    for i = 1, #H.dbErrors do print('  refused slice: ' .. H.dbErrors[i]) end
    for i = 1, #bridge.errors do print('  bridge: ' .. bridge.errors[i]) end
    if H.failed > 0 or #stubs.failures > 0 or #H.dbErrors > 0 or #bridge.errors > 0 then os.exit(1) end
end

return H
