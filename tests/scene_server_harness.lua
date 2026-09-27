--[[
    core/tests/scene_server_harness.lua — the harness of tests/scene_server_tests.lua (Core.Scene server,
    DESIGN §55.3/§55.4/§55.12/§55.14/§55.18). Not a suite: `local H = dofile(here .. '/scene_server_harness.lua')`.

    A core server VM with the real api, hooks, db (core's migrations; Core.DB = the lib over the Postgres test
    bridge, DESIGN §56.10.2), the real shared/scene_codec.lua + shared/scene_motion.lua + lib/clock, and the real
    server/scene_kinds.lua → scene_store.lua → scene.lua. R.index / R.interest / R.flush are recording fakes
    (INTERFACES §4): every call lands in H.log in order; the fake index also keeps a working cell map (roots by tier
    and pose) so cellsNear / nodesIn answer like the real one. Core.Perms and Core.Player are stand-ins driven by
    H.perms / H.unloaded; R.interest.allows answers H.allows[src].

    The stored side (§55.18 / §56.6) through SQL: H.row(id) (the raw scene_nodes row), H.doc(id) (its doc with the
    columns folded in — what the old document store held), H.counter() / H.setCounter(v) (core_counters
    'scene_nodes'), H.putRow(row) (a hand-made row), H.recordDb(env) + H.writeCount(log, id) (the core_db export
    calls of a VM and the queued writes per node), H.xmin(id) (the row version: changes with every committed write).
]]

local here = (arg and arg[0] or 'tests/scene_server_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local bridge = stubs.bridge
local H = { stubs = stubs, bridge = bridge, name = 'scene server', passed = 0, failed = 0, log = {}, perms = {},
    unloaded = {}, allows = {} }

function H.check(cond, label)
    if cond then H.passed = H.passed + 1 else H.failed = H.failed + 1; print(('FAIL  [%s] %s'):format(H.name,
        label)) end
    return cond and true or false
end

function H.eq(actual, expected, label)
    return H.check(actual == expected, ('%s (expected %s, got %s)'):format(label, tostring(expected), tostring(actual)))
end

function H.near(actual, expected, eps, label)
    return H.check(type(actual) == 'number' and math.abs(actual - expected) <= eps,
        ('%s (expected %s ± %s, got %s)'):format(label, tostring(expected), tostring(eps), tostring(actual)))
end

function H.callable(fn) return setmetatable({}, { __call = function(_, ...) return fn(...) end }) end

--- The recorded fake-component calls since the last reset(), optionally filtered by op (and node id).
function H.calls(op, id)
    local out = {}
    for _, c in ipairs(H.log) do
        if (op == nil or c.op == op) and (id == nil or c.id == id) then out[#out + 1] = c end
    end
    return out
end

--- 'put:1 changed:1:set remove:2:1' — the call sequence, compact, for exact comparisons.
function H.trace()
    local parts = {}
    for _, c in ipairs(H.log) do
        local s = c.op .. ':' .. tostring(c.id)
        if c.what then s = s .. ':' .. c.what end
        if c.how then s = s .. ':' .. c.how end
        parts[#parts + 1] = s
    end
    return table.concat(parts, ' ')
end

function H.reset() H.log = {} end

local function record(entry) H.log[#H.log + 1] = entry end

--- R.index fake: records put / changed / remove / event / dr and keeps roots in cells (by tier and pose).
local function fakeIndex(env)
    local cfg = env.Config.Scene
    local cells, where = {}, {}          -- cells[bucket][grid][key] = { [id] = node }; where[id] = { b, g, k }
    local I = {}
    local function keyOf(grid, x, y)
        if grid == 2 then return 0 end
        local size = grid == 0 and cfg.CellSize or cfg.RegionSize
        return (math.floor(x / size) + 32768) * 65536 + (math.floor(y / size) + 32768)
    end
    I.keyOf = keyOf
    local function drop(id)
        local w = where[id]
        if w then cells[w[1]][w[2]][w[3]][id] = nil; where[id] = nil end
    end
    local function place(node)
        drop(node.id)
        if node.parent or (node.k and node.k.dependency) then return end
        local grid = node.tier == 'G' and 2 or (node.tier == 'L' and 1 or 0)
        local x, y = env.Core.SceneRuntime.store.pose(node)
        local key = keyOf(grid, x, y)
        cells[node.bucket] = cells[node.bucket] or { [0] = {}, [1] = {}, [2] = {} }
        local g = cells[node.bucket][grid]
        g[key] = g[key] or {}
        g[key][node.id] = node
        where[node.id] = { node.bucket, grid, key }
    end
    function I.put(node)
        record({ op = 'put', id = node.id, ver = node.ver, kind = node.k and node.k.id or false, tier = node.tier,
            parent = node.parent })
        place(node)
    end
    function I.changed(node, what, data)
        record({ op = 'changed', id = node.id, what = what, data = data, ver = node.ver })
        if what == 'move' or what == 'follow' or what == 'motion' or what == 'attach' then place(node) end
    end
    function I.remove(node, how)
        record({ op = 'remove', id = node.id, how = how })
        drop(node.id)
    end
    function I.event(node, x, y, z, bucket, name, params, t, radius, horizonMs)
        record({ op = 'event', id = node and node.id or false, x = x, y = y, z = z, bucket = bucket, name = name,
            params = params, t = t, radius = radius, horizonMs = horizonMs })
    end
    function I.dr(node, t, x, y, z, vx, vy, vz, yaw)
        record({ op = 'dr', id = node.id, t = t, x = x, y = y, z = z, vx = vx, vy = vy, vz = vz, yaw = yaw })
    end
    function I.cellsNear(bucket, x, y, radius, grid)
        local out, b = {}, cells[bucket]
        if not b then return out end
        for key, set in pairs(b[grid]) do
            if next(set) then
                local size = grid == 0 and cfg.CellSize or cfg.RegionSize
                local cx, cy = key // 65536 - 32768, key % 65536 - 32768
                local nx = math.max(cx * size, math.min(x, (cx + 1) * size))
                local ny = math.max(cy * size, math.min(y, (cy + 1) * size))
                if (nx - x) ^ 2 + (ny - y) ^ 2 <= radius * radius then out[#out + 1] = key end
            end
        end
        return out
    end
    function I.nodesIn(bucket, grid, key)
        local out, b = {}, cells[bucket]
        local set = b and b[grid][key]
        for _, node in pairs(set or {}) do out[#out + 1] = node end
        table.sort(out, function(a, c) return a.id < c.id end)
        return out
    end
    function I.gatedIn() return {} end
    function I.stats() local n = 0 for _ in pairs(where) do n = n + 1 end return { cells = n, indexed = n } end
    function I.where(id) return where[id] end
    return I
end

--- `players` audiences are evaluated for real (per node, like scene_gated's allows); anything else answers
--- H.allows[src].
local function allowsFake(node, src)
    local a = node.audience
    if type(a) == 'table' and a.players then
        for i = 1, #a.players do if a.players[i] == src then return true end end
        return false
    end
    return H.allows[src] == true
end

local function fakeInterest()
    return {
        pin = function(src, x, y, z) record({ op = 'pin', id = src, x = x, y = y, z = z }) end,
        prefetch = function(src, x, y, z) record({ op = 'prefetch', id = src, x = x, y = y, z = z }) end,
        allows = allowsFake,
        drop = function() end,
        stats = function() return { subscribers = 7 } end,
    }
end

local function fakeFlush()
    return { queue = function() end, queueLatent = function() end, wake = function() end,
        stats = function() return { flushMsP50 = 1.5, flushMsP99 = 4, bytesPerSecond = 1234 } end }
end

--- A core server VM with the scene server files loaded. opts = { keepDb (a restart over the same database; the old
--- name keepKvp still works), maps (load server/maps_types.lua: the §52 model validator), config = fn(Config) before
--- the scene files, beforeStore = fn(env, Core, R), noStart (no tick after onResourceStart: the store's start thread
--- has not run — nothing is loaded yet) }.
function H.newServer(opts)
    opts = opts or {}
    stubs.newWorld()
    stubs.clear()
    if not (opts.keepDb or opts.keepKvp) then stubs.resetServer() end
    stubs.tick(1000)
    H.log, H.perms, H.unloaded, H.allows = {}, {}, {}, {}
    local env = stubs.newEnv('server', 'core')
    env.GetEntityRotation = function(e)            -- CFX server form (fxref): the entity's rotation, vector3
        local r = stubs.entities[e] and stubs.entities[e].rot
        return stubs.vector3(r and r.x or 0.0, r and r.y or 0.0, r and r.z or 0.0)
    end
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    if opts.config then opts.config(env.Config) end
    stubs.loadFile(env, 'shared/scene_codec.lua')
    stubs.loadFile(env, 'shared/scene_motion.lua')
    stubs.loadFile(env, 'server/api.lua')
    stubs.loadFile(env, 'shared/hooks.lua')
    stubs.loadFile(env, 'server/db.lua')
    local Core = env.Core
    Core.Perms = { has = function(src, perm) return H.perms[src .. '|' .. perm] == true end }
    Core.Player = { isLoaded = function(src) return not H.unloaded[src] end }
    if opts.maps then stubs.loadFile(env, 'server/maps_types.lua') end
    stubs.loadFile(env, 'server/scene_kinds.lua')
    local R = Core.SceneRuntime
    R.index, R.interest, R.flush = fakeIndex(env), fakeInterest(), fakeFlush()
    if opts.beforeStore then opts.beforeStore(env, Core, R) end
    stubs.loadFile(env, 'server/scene_store.lua')
    stubs.loadFile(env, 'server/scene.lua')
    env.TriggerEvent('onResourceStart', 'core')
    if not opts.noStart then stubs.tick(0) end
    return env, Core, R
end

--------------------------------------------------------------------------------
-- the stored side (§55.18 / §56.6): scene_nodes rows and the core_counters row, read and written through SQL
--------------------------------------------------------------------------------

local ROW_SQL <const> = 'SELECT id, kind, owner, parent, bucket, doc FROM scene_nodes WHERE id = $1'

local function sql(text, params)
    local rows, err = bridge.sql(text, params)
    if not rows then error('scene harness: ' .. tostring(err), 2) end
    return rows
end
H.sql = sql

--- The raw scene_nodes row of node `id` ({ id, kind, owner, parent?, bucket, doc }) or nil.
function H.row(id) return sql(ROW_SQL, { id })[1] end

--- The stored document of node `id` the way the old document store held it: doc + the columns, or nil.
function H.doc(id)
    local r = H.row(id)
    if not r then return nil end
    local d = {}
    for k, v in pairs(type(r.doc) == 'table' and r.doc or {}) do d[k] = v end
    d.id, d.kind, d.owner, d.parent, d.bucket = r.id, r.kind, r.owner, r.parent, r.bucket
    return d
end

--- The row version (xmin): it changes with every committed write of the row; nil without a row.
function H.xmin(id)
    local r = sql('SELECT xmin::text AS x FROM scene_nodes WHERE id = $1', { id })[1]
    return r and r.x
end

function H.counter()
    local r = sql("SELECT value FROM core_counters WHERE name = 'scene_nodes'")[1]
    return r and r.value
end

function H.setCounter(value)
    sql("INSERT INTO core_counters (name, value) VALUES ('scene_nodes', $1) "
        .. 'ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value', { value })
end

--- A hand-made row (legacy / fixture): { id, kind, owner, parent? (nil = NULL), bucket? (0), doc }.
function H.putRow(row)
    sql('INSERT INTO scene_nodes (id, kind, owner, parent, bucket, doc) '
        .. 'VALUES ($1, $2, $3, NULLIF($4, 0), $5, $6::jsonb)',
        { row.id, row.kind, row.owner, row.parent or 0, row.bucket or 0, stubs.json.encode(row.doc or {}) })
end

--- Records every core_db export call `env` makes from now on: the returned log gets { fn, args } per call.
function H.recordDb(env)
    local inner, log = rawget(env.exports, 'core_db'), {}
    rawset(env.exports, 'core_db', setmetatable({ synchronous = true }, { __index = function(t, name)
        local f = inner[name]
        if type(f) ~= 'function' then return f end
        local wrapped = function(_, ...)
            log[#log + 1] = { fn = name, args = table.pack(...) }
            return f(inner, ...)
        end
        rawset(t, name, wrapped)
        return wrapped
    end }))
    return log
end

--- Queued writes in a recorded log: of node `id` (save + remove entries on scene_nodes) or, for id 'counter', of
--- the core_counters row.
function H.writeCount(log, id)
    local n = 0
    for _, c in ipairs(log) do
        for _, e in ipairs(c.fn == 'enqueue' and type(c.args[1]) == 'table' and c.args[1] or {}) do
            if id == 'counter' then
                if e.table == 'core_counters' then n = n + 1 end
            elseif e.table == 'scene_nodes' and ((e.t == 'save' and e.row and e.row.id == id) or e.key == id) then
                n = n + 1
            end
        end
    end
    return n
end

--- A recording stand-in for phase C's R.promote: beforeChange / refuses / onInteract / ours / stats.
--- H.promoteLog gets { what, id, x } per beforeChange (x = the node's base x at the call: before the change).
function H.fakePromote(R)
    H.promoteLog, H.refuse = {}, {}
    R.promote = {
        beforeChange = function(node, what)
            H.promoteLog[#H.promoteLog + 1] = { what = what, id = node.id, x = node.pos and node.pos.x }
            return false
        end,
        refuses = function(src, node) return H.refuse[src .. ':' .. node.id] == true end,
        ours = function(e, id) return stubs.entities[e] ~= nil and stubs.entities[e].exists
            and stubs.entities[e].sn == id end,
        stats = function() return { promoted = 0 } end,
    }
    return R.promote
end

--- A call as a plugin makes it: through core's `call` export with that resource as the caller.
function H.as(resource, fn, ...)
    return stubs.exports.core.call(resource, 'Scene', fn, ...)
end

function H.stop(env, resource) env.TriggerEvent('onResourceStop', resource) end

--- A connected, loaded player at `pos` in `bucket` -> src.
function H.player(env, src, pos, bucket)
    stubs.connectPlayer(env, src, { coords = stubs.vector3(pos.x, pos.y, pos.z), joining = false })
    stubs.buckets[src] = bucket or 0
    return src
end

function H.movePlayer(src, pos)
    stubs.coords[stubs.peds[src]] = stubs.vector3(pos.x, pos.y, pos.z)
end

--- Fires core:scene:interact as client `src` (through the Core.Net.on wrapper).
function H.interact(env, src, id, action, data)
    stubs.triggerOn(env, 'core:scene:interact', src, id, action, data)
end

--- Prints the summary line and exits 1 on any failure or uncaught thread/handler error.
function H.finish()
    print(('%s: %d passed, %d failed'):format(H.name, H.passed, H.failed))
    for i = 1, #stubs.failures do print('  uncaught: ' .. stubs.failures[i]) end
    if H.failed > 0 or #stubs.failures > 0 then os.exit(1) end
end

return H
