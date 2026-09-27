--[[
    core/tests/scene_interest_tests.lua — offline suite for R.interest + R.flush (DESIGN §55.6, §55.7, §55.8).

        lua5.4 tests/scene_interest_tests.lua    (from the resource directory, or from tests/)

    Sections 1–11 and 13–14 run a core server VM with the real codec (shared/scene_codec.lua), the real player grid
    and the three files under test (scene_interest → scene_gated → scene_flush); R.kinds, R.index and R.store are
    recording fakes (versions, journals and packs built with the real codec; the index fake wakes the flush like the
    real one), so they do not depend on server/scene_index.lua. Section 12 runs the real stack end to end
    (scene_kinds → scene_index → scene_interest → scene_gated → scene_flush → scene_store → scene). Natives stubs.lua lacks are
    installed and counted here: GetPlayerFocusPos, GetPlayerRoutingBucket (wrapped), TriggerLatentClientEvent,
    TriggerClientEventInternal + a fake msgpack.pack_args (the packed path). Every new server parks the previous
    VM's threads and drops its sends (they share the stub scheduler). Exit code 1 on any failure.
]]

local here = (arg and arg[0] or 'tests/scene_interest_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
local vector3 = stubs.vector3


local passed, failed = 0, 0
local function eq(actual, expected, label)
    if actual == expected then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    print(('FAIL  [scene_interest] %s\n        expected %s, got %s'):format(label, tostring(expected), tostring(actual)))
    return false
end
local function check(cond, label) return eq(cond and true or false, true, label) end

local OFF, SPAN, GSPAN = 32768, 65536, 4294967296
local function key(cx, cy) return (cx + OFF) * SPAN + (cy + OFF) end
local function cname(grid, cx, cy) return ('%d:%d'):format(grid, grid == 2 and 0 or key(cx, cy)) end

--------------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------------

local H = {}   -- the current server: env, Core, R, I (index fake), K (kinds fake), counters

--- The index fake: per (bucket, grid, key, variant) a version, a pack and a journal, built with the real codec.
local function newIndex(Codec)
    local I = { q = { entries = {}, gated = {}, events = {}, drs = {} }, pendingFlag = false, v = {}, j = {},
        packs = {}, calls = { pack = 0, since = 0, version = 0, drain = 0, gatedPut = 0 }, seq = 1000 }
    local function k(b, g, key_, var) return b .. ':' .. g .. ':' .. key_ .. ':' .. var end
    function I.keyOf(grid, x, y)
        if grid == 2 then return 0 end
        local size = grid == 1 and 512 or 128
        return (math.floor(x / size) + OFF) * SPAN + (math.floor(y / size) + OFF)
    end
    --- New content of a variant: `n` PUTs (padded with `pad` extra bytes each); the version moves, the journal grows.
    function I.fill(b, g, key_, var, n, pad)
        I.seq = I.seq + 1
        local kk, to = k(b, g, key_, var), I.seq
        local from = I.v[kk] or 0
        local ops = {}
        for i = 1, n do ops[i] = Codec.put(i, 1, to, 0, 0, 0.0, 0.0, 0.0, 0, 0, 0, 10, pad or '') end
        local body = table.concat(ops)
        if n == 0 then to = 0 end
        I.packs[kk] = n > 0 and Codec.cell(g, key_, var, 0, to, n) .. body or nil
        local entry = { bucket = b, grid = g, key = key_, variant = var, from = from, to = to,
            blob = Codec.cell(g, key_, var, from, to, n) .. body, n = n }
        local j = I.j[kk] or {}
        I.j[kk] = j
        j[#j + 1] = entry
        I.v[kk] = to
        return entry
    end
    --- Something is queued for the next drain: pending, and the flush is woken (what R.index does).
    function I.touch()
        I.pendingFlag = true
        local flush = H.R and H.R.flush
        if flush then flush.wake() end
    end
    --- The same, queued for the next drain (a change this tick).
    function I.change(b, g, key_, var, n, pad)
        local e = I.fill(b, g, key_, var, n, pad)
        I.q.entries[#I.q.entries + 1] = e
        I.touch()
        return e
    end
    function I.drain()
        I.calls.drain = I.calls.drain + 1
        local q = I.q
        I.q = { entries = {}, gated = {}, events = {}, drs = {} }
        I.pendingFlag = false
        return q.entries, q.gated, q.events, q.drs
    end
    function I.pending() return I.pendingFlag end
    function I.pack(b, g, key_, var)
        I.calls.pack = I.calls.pack + 1
        local kk = k(b, g, key_, var)
        local v = I.v[kk] or 0
        if v == 0 then return '', 0 end
        return I.packs[kk], v
    end
    function I.since(b, g, key_, var, fromV)
        I.calls.since = I.calls.since + 1
        local kk = k(b, g, key_, var)
        if (I.v[kk] or 0) == fromV then return '' end
        local j = I.j[kk]
        if not j then return nil end
        for i = 1, #j do
            if j[i].from == fromV then
                local parts = {}
                for m = i, #j do parts[#parts + 1] = j[m].blob end
                return table.concat(parts)
            end
        end
        return nil
    end
    function I.version(b, g, key_, var)
        I.calls.version = I.calls.version + 1
        return I.v[k(b, g, key_, var)] or 0
    end
    --- The unit's PUTs: the head, then `node.kids` (child node tables), each with `extraBytes` of padding.
    function I.gatedPut(node)
        I.calls.gatedPut = I.calls.gatedPut + 1
        if node.gone then return '', 0 end
        local pad = string.rep('p', node.extraBytes or 0)
        local ops = { Codec.put(node.id, 1, node.ver or 1, 0, 32, node.pos.x, node.pos.y, node.pos.z, 0, 0, 0, 10, pad) }
        for _, kid in ipairs(node.kids or {}) do
            ops[#ops + 1] = Codec.put(kid.id, 1, kid.ver or 1, node.id, 32, 0.0, 0.0, 0.0, 0, 0, 0, 10, pad)
        end
        return table.concat(ops), #ops
    end
    function I.gatedIn() return {} end
    function I.nodesIn() return {} end
    function I.cellsNear() return {} end
    function I.stats() return {} end
    return I
end

local latent, internal = {}, {}
local counters = { routing = 0, focusPos = 0 }

local clientKills = {}   -- the dead-flag setters of client VMs made since the last server

--- A fresh server VM that is isolated from the previous one: the old VM's threads park at their next Wait and
--- whatever its last loop iteration sends is dropped (all VMs share the stub scheduler and the event log).
local function isolatedEnv(msgpackPath)
    if H.kill then H.kill() end
    for i = #clientKills, 1, -1 do
        clientKills[i]()
        clientKills[i] = nil
    end
    stubs.newWorld()
    stubs.clear()
    stubs.resetServer()
    latent, internal = {}, {}
    counters.routing, counters.focusPos = 0, 0
    local env = stubs.newEnv('server', 'core')
    local dead = false
    H.kill = function() dead = true end
    env.Wait = function(ms)
        if dead then return coroutine.yield('dead') end   -- not a number: the stub scheduler parks it for good
        return coroutine.yield(tonumber(ms) or 0)
    end
    env.Citizen.Wait = env.Wait
    local tce = env.TriggerClientEvent
    env.TriggerClientEvent = function(...)
        if not dead then return tce(...) end
    end
    env.TriggerLatentClientEvent = function(name, target, bps, payload)
        if dead then return end
        latent[#latent + 1] = { name = name, target = target, bps = bps, payload = payload }
    end
    if msgpackPath then
        env.msgpack = { pack_args = function(str) return 'MP' .. str end }
        env.TriggerClientEventInternal = function(name, target, payload, len)
            if dead then return end
            internal[#internal + 1] = { name = name, target = target, payload = payload, len = len }
        end
    end
    H.focusPos, H.loaded, H.factions, H.perms, H.modes = {}, {}, {}, {}, {}
    env.GetPlayerFocusPos = function(src)
        counters.focusPos = counters.focusPos + 1
        return H.focusPos[tonumber(src)] or vector3(0.0, 0.0, 0.0)
    end
    local routing = env.GetPlayerRoutingBucket
    env.GetPlayerRoutingBucket = function(src)
        counters.routing = counters.routing + 1
        return routing(src)
    end
    return env
end

--- A fresh server. opts = { scene = { Config.Scene overrides }, msgpack = true }.
local function newServer(opts)
    opts = opts or {}
    local env = isolatedEnv(opts.msgpack)
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    for k, v in pairs(opts.scene or {}) do env.Config.Scene[k] = v end
    local Core = env.Core
    Core.Player = {
        isLoaded = function(src) return H.loaded[src] == true end,
        getPlayers = function()
            local out = {}
            for src in pairs(H.loaded) do out[#out + 1] = src end
            table.sort(out)
            return out
        end,
        getData = function(src, path)
            if path == 'faction' and H.factions[src] then return { id = H.factions[src], rank = 1 } end
            return nil
        end,
    }
    Core.Perms = { has = function(src, perm) return H.perms[src .. '|' .. perm] == true end }
    Core.Admin = { getModes = function(src) return H.modes[src] or {} end }
    stubs.loadFile(env, 'server/playergrid.lua')
    stubs.loadFile(env, 'shared/scene_codec.lua')
    local Codec = Core.SceneCodec
    H.kindsV, H.kindsList = 1, { { idx = 1, id = 'prop', class = 1 } }
    local K = {
        version = function() return H.kindsV end,
        table = function(since)
            if since >= H.kindsV then return {} end
            return H.kindsList
        end,
        get = function() return nil end,
    }
    local I = newIndex(Codec)
    H.nodes = {}
    local R = { kinds = K, index = I, store = {
        get = function(id) return H.nodes[id] end,
        pose = function(node) return node.pos.x, node.pos.y, node.pos.z end,
        root = function(node)
            local n = node
            while n.up do n = n.up end
            return n
        end,
        --- own + ancestors' (`up` = the parent node table), like server/scene_store.lua
        audienceOf = function(node)
            local list, n = {}, node
            while n do
                if n.audience then table.insert(list, 1, n.audience) end
                n = n.up
            end
            if #list == 0 then return nil end
            if #list == 1 then return list[1] end
            return { all = list }
        end,
    } }
    Core.SceneRuntime = R
    stubs.loadFile(env, 'server/scene_interest.lua')
    stubs.loadFile(env, 'server/scene_gated.lua')
    stubs.loadFile(env, 'server/scene_flush.lua')
    H.env, H.Core, H.R, H.I, H.Codec = env, Core, R, I, Codec
    return env, Core, R, I
end

--- A REAL client cache (client/scene_cache.lua + client/scene_focus.lua) with a fake materialiser, as in
--- tests/client_scene_cache_tests.lua; its sends are dropped unless `forward(name, ...)` takes them, and its
--- threads park when the next server is made. @return env, C (CoreSceneRuntime)
local function clientCache(at, forward)
    local cenv = stubs.newEnv('client', 'core')
    cenv.__vm.clientSrc = -99    -- never a target: the stubs' own delivery skips it (the tests route the wire)
    local dead = false
    clientKills[#clientKills + 1] = function() dead = true end
    cenv.Wait = function(ms)
        if dead then return coroutine.yield('dead') end
        return coroutine.yield((tonumber(ms) or 0) > 0 and ms or 16)
    end
    cenv.GetFinalRenderedCamCoord = function() return vector3(at.x, at.y, 30.0) end
    cenv.TriggerServerEvent = function(name, ...)
        if forward and not dead then forward(name, ...) end
    end
    for _, f in ipairs({ 'import.lua', 'shared/config.lua', 'client/api.lua', 'shared/scene_codec.lua',
        'shared/scene_motion.lua', 'client/scene_cache.lua' }) do stubs.loadFile(cenv, f) end
    local C = cenv.CoreSceneRuntime
    stubs.loadFile(cenv, 'client/scene_focus.lua')
    local M = { PENDING = 'pending' }
    for _, f in ipairs({ 'add', 'update', 'remove', 'event', 'registerKind', 'hold', 'release', 'setTeleport', 'bound' }) do
        M[f] = function() end
    end
    M.handleOf, M.idOf, M.areaReady = function() end, function() end, function() return true end
    M.stats, M.stateOf = function() return { byState = {} } end, function() end
    C.mat = M
    return cenv, C
end

--- Replays reliable payloads into a real client cache, one per 16 ms.
local function replay(C, cenv, list)
    for i = 1, #list do
        stubs.triggerOn(cenv, 'core:scene:s', 65535, list[i])
        stubs.tick(16)
    end
end

--- A loaded player with a ped at `pos` (the player grid indexes them at once).
local function join(src, pos, bucket)
    stubs.connectPlayer(H.env, src, { coords = pos or vector3(0.0, 0.0, 0.0) })
    H.loaded[src] = true
    if bucket then stubs.buckets[src] = bucket end
    H.Core.emitHook('playerLoaded', src)
end

--- Moves `src`'s ped and re-indexes it in the player grid at once (the grid's own playerLoaded path), so the
--- backstop never compares a report with a position from before an instantaneous test jump.
--- A player leaves the way the server sees it: the engine's playerDropped, the session gone, core's hook.
local function leave(src)
    stubs.dropPlayer(H.env, src)
    H.loaded[src] = nil
    H.Core.emitHook('playerDropped', src)
end

local function movePed(src, pos)
    stubs.coords[stubs.peds[src]] = pos
    H.Core.PlayerGrid.positionOf(src)
    H.Core.emitHook('playerLoaded', src)
end

local seq = 0
--- `core:scene:focus` from `src` (after the cooldown: the clock moves 300 ms first unless `now`).
local function report(src, x, y, z, vx, vy, vz, held, now)
    if not now then stubs.tick(300) end
    seq = seq + 1
    stubs.triggerOn(H.env, 'core:scene:focus', src, x, y, z or 0.0, vx or 0.0, vy or 0.0, vz or 0.0, seq, held)
end

local function mark() return #stubs.sent, #latent, #internal end

--- Every reliable payload to `src` since `from` (index into stubs.sent), unpacked.
local function payloads(src, from)
    local out = {}
    for i = (from or 0) + 1, #stubs.sent do
        local s = stubs.sent[i]
        if s.name == 'core:scene:s' and s.target == src then out[#out + 1] = s.args[1] end
    end
    return out
end

local function latents(src, from)
    local out = {}
    for i = (from or 0) + 1, #latent do
        if latent[i].target == src then out[#out + 1] = latent[i].payload end
    end
    return out
end

--- Decodes payloads into one flat op list with the real codec. @return ops, number of payloads that failed
local function decode(list)
    local ops, bad = {}, 0
    local function add(t) ops[#ops + 1] = t end
    local h = {
        header = function(_, now) add({ op = 'header', now = now }) end,
        kinds = function(l) add({ op = 'kinds', n = #l, list = l }) end,
        sub = function(g, k, var, v) add({ op = 'sub', grid = g, key = k, variant = var, v = v }) end,
        unsub = function(g, k) add({ op = 'unsub', grid = g, key = k }) end,
        reset = function(reason) add({ op = 'reset', reason = reason }) end,
        cell = function(g, k, var, from, to, n)
            add({ op = 'cell', grid = g, key = k, variant = var, from = from, to = to, n = n })
        end,
        priv = function(n) add({ op = 'priv', n = n }) end,
        put = function(id, _, ver, _, flags, _, _, _, _, _, _, _, _, ctx)
            add({ op = 'put', id = id, ver = ver, flags = flags, section = ctx.section })
        end,
        set = function(id, ver, _, ctx) add({ op = 'set', id = id, ver = ver, section = ctx.section }) end,
        del = function(id, ver, how, ctx) add({ op = 'del', id = id, ver = ver, how = how, section = ctx.section }) end,
        event = function(id, t, _, _, _, name) add({ op = 'event', id = id, t = t, name = name }) end,
        dr = function(id, t) add({ op = 'dr', id = id, t = t }) end,
    }
    for i = 1, #list do
        if not H.Codec.decode(list[i], h) then bad = bad + 1 end
    end
    return ops, bad
end

local function count(ops, op, pred)
    local n = 0
    for _, o in ipairs(ops) do
        if o.op == op and (not pred or pred(o)) then n = n + 1 end
    end
    return n
end

local function find(ops, op, pred)
    for i, o in ipairs(ops) do
        if o.op == op and (not pred or pred(o)) then return o, i end
    end
    return nil
end

--- The window a fresh subscription must have (no hysteresis), by brute force over a wide square.
local function expectedWindow(fx, fy, lx, ly)
    lx, ly = lx or fx, ly or fy
    local out = {}
    local function gap(p, a, size)
        if p < a then return a - p elseif p > a + size then return p - a - size end
        return 0
    end
    local function dist(px, py, cx, cy, size)
        local dx, dy = gap(px, cx * size, size), gap(py, cy * size, size)
        return math.sqrt(dx * dx + dy * dy)
    end
    for cx = math.floor((math.min(fx, lx) - 700) / 128), math.floor((math.max(fx, lx) + 700) / 128) do
        for cy = math.floor((math.min(fy, ly) - 700) / 128), math.floor((math.max(fy, ly) + 700) / 128) do
            local dF, dL = dist(fx, fy, cx, cy, 128), dist(lx, ly, cx, cy, 128)
            local ring = dF <= 160 and 1 or ((dF <= 448 or dL <= 448) and 2 or nil)
            if ring then out[cname(0, cx, cy)] = ring end
        end
    end
    for rx = math.floor((math.min(fx, lx) - 1300) / 512), math.floor((math.max(fx, lx) + 1300) / 512) do
        for ry = math.floor((math.min(fy, ly) - 1300) / 512), math.floor((math.max(fy, ly) + 1300) / 512) do
            if dist(fx, fy, rx, ry, 512) <= 1024 or dist(lx, ly, rx, ry, 512) <= 1024 then out[cname(1, rx, ry)] = 1 end
        end
    end
    out['2:0'] = 1
    return out
end

local function sameWindow(got, want, label)
    local missing, extra, wrong = 0, 0, 0
    for k, v in pairs(want) do
        if got[k] == nil then missing = missing + 1 elseif got[k] ~= v then wrong = wrong + 1 end
    end
    for k in pairs(got) do
        if want[k] == nil then extra = extra + 1 end
    end
    eq(missing, 0, label .. ': no cell missing')
    eq(extra, 0, label .. ': no extra cell')
    eq(wrong, 0, label .. ': every ring right')
end

local function nkeys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------------
-- 1. Windows: rings, lead, the global set, SUBs
--------------------------------------------------------------------------------
do
    newServer()
    join(1, vector3(64.0, 64.0, 30.0))
    local m = mark()
    report(1, 64.0, 64.0, 30.0)
    stubs.tick(300)
    local w = H.R.interest.window(1)
    check(w ~= nil, 'a report creates a window')
    eq(w and w.bucket, 0, 'the bucket comes from GetPlayerRoutingBucket')
    sameWindow(w.cells, expectedWindow(64, 64), 'focus at a cell centre')
    eq(w.cells[cname(0, 0, 0)], 1, 'the own cell is ring 1')
    eq(w.cells[cname(0, 1, 1)], 1, 'the diagonal neighbour (90 m) is ring 1')
    eq(w.cells[cname(0, 2, 0)], 2, 'two cells over (192 m) is ring 2')
    eq(w.cells[cname(0, 4, 0)], 2, 'exactly 448 m is still ring 2')
    eq(w.cells[cname(0, 5, 0)], nil, '576 m is out')
    eq(w.cells['2:0'], 1, 'the global set is always subscribed')
    local ops, bad = decode(payloads(1, m))
    eq(bad, 0, 'every payload decodes')
    eq(count(ops, 'sub'), w.n, 'one SUB per subscription')
    eq(count(ops, 'sub', function(o) return o.v ~= 0 end), 0, 'empty cells are announced with v = 0')
    eq(count(ops, 'sub', function(o) return o.grid == 0 and o.variant == 1 end), 9, 'nine near-variant cells')
    eq(count(ops, 'sub', function(o) return o.grid == 1 and o.variant == 3 end),
        count(ops, 'sub', function(o) return o.grid == 1 end), 'regions subscribe variant ONE')
    eq(ops[1] and ops[1].op, 'header', 'a payload starts with the header')
    eq(count(ops, 'kinds'), 1, 'the first payload carries the full kinds table')
    check(select(2, find(ops, 'kinds')) < select(2, find(ops, 'sub')), 'KINDS comes before the first SUB')
    eq(H.R.interest.bucketOf(1), 0, 'bucketOf')
    local fx, fy = H.R.interest.focusOf(1)
    check(fx == 64.0 and fy == 64.0, 'focusOf answers the validated focus')

    -- a corner, negative coordinates, the lead point
    join(2, vector3(-128.0, -256.0, 0.0))
    report(2, -128.0, -256.0, 0.0)
    stubs.tick(300)
    sameWindow(H.R.interest.window(2).cells, expectedWindow(-128, -256), 'focus on a cell corner (negative)')
    join(3, vector3(1000.0, 500.0, 0.0))
    report(3, 1000.0, 500.0, 0.0, 30.0, 0.0, 0.0)
    stubs.tick(300)
    local w3 = H.R.interest.window(3)
    eq(w3.lead.x, 1045.0, 'lead = F + v × 1.5 s')
    sameWindow(w3.cells, expectedWindow(1000, 500, 1045, 500), 'with a lead of 45 m')
    check(w3.cells[cname(0, 11, 3)] == 2, 'a cell only the lead reaches is ring 2')
    join(4, vector3(0.0, 0.0, 0.0))
    report(4, 0.0, 0.0, 0.0, 0.0, 200.0, 0.0)
    stubs.tick(300)
    eq(H.R.interest.window(4).lead.y, 135.0, 'the reported speed is clamped to MaxSpeed (90 m/s × 1.5 s)')
end

do
    newServer({ scene = { Lead = { Seconds = 2, Max = 100 } } })
    join(1, vector3(0.0, 0.0, 0.0))
    report(1, 0.0, 0.0, 0.0, 80.0, 0.0, 0.0)
    stubs.tick(300)
    local w = H.R.interest.window(1)
    eq(w.lead.x, 100.0, 'Lead.Max clamps the lead point')
    sameWindow(w.cells, expectedWindow(0, 0, 100, 0), 'a clamped lead')
end

--------------------------------------------------------------------------------
-- 2. Content: packs, `sent` memory, entries by ring, resync when behind, pending subscriptions
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer()
    local k00 = key(0, 0)
    local vk = '0:0:' .. k00
    I.fill(0, 0, k00, 1, 3)
    I.fill(0, 0, k00, 2, 1)
    join(1, vector3(64.0, 64.0, 0.0))
    local m = mark()
    report(1, 64.0, 64.0, 0.0)
    stubs.tick(300)
    local ops = decode(payloads(1, m))
    local sub = find(ops, 'sub', function(o) return o.grid == 0 and o.key == k00 end)
    eq(sub and sub.variant, 1, 'the own cell subscribes the near variant')
    eq(sub and sub.v, I.v[vk .. ':1'], 'its SUB names the current version')
    local cell = find(ops, 'cell', function(o) return o.key == k00 end)
    eq(cell and cell.from, 0, 'the content follows as a snapshot (CELL from 0)')
    eq(count(ops, 'put', function(o) return o.section == 'cell' end), 3, 'with its three PUTs')
    eq(R.interest.sent(1, 0, k00, 1), I.v[vk .. ':1'], 'sent = the pack version')
    eq(R.interest.sent(1, 0, k00, 2), nil, 'sent is per variant: the far variant is not subscribed')
    eq(R.flush.stats().packs, 1, 'one pack went out (the only cell with content)')
    eq(#latents(1), 0, 'a small pack rides the reliable stream')
    local packsBefore, m2 = I.calls.pack, mark()
    report(1, 64.0, 64.0, 0.0)
    stubs.tick(300)
    eq(I.calls.pack, packsBefore, 'a repeated report builds no pack')
    eq(#payloads(1, m2), 0, 'and sends nothing at all')

    local e = I.change(0, 0, k00, 1, 4)
    local m3 = mark()
    stubs.tick(300)
    ops = decode(payloads(1, m3))
    local c = find(ops, 'cell')
    eq(c and c.from, e.from, 'an entry goes to the subscriber whose sent is its from')
    eq(c and c.to, e.to, 'up to its to')
    eq(count(ops, 'put'), 4, 'with its ops')
    eq(R.interest.sent(1, 0, k00, 1), e.to, 'sent moves to the entry\'s to')
    eq(#payloads(1, m3), 1, 'one event for that tick')
    local m4 = mark()
    I.change(0, 0, k00, 2, 2)
    stubs.tick(300)
    eq(#payloads(1, m4), 0, 'a far-variant entry skips a ring-1 subscriber')

    join(2, vector3(364.0, 64.0, 0.0))
    report(2, 364.0, 64.0, 0.0)
    stubs.tick(300)
    eq(R.interest.window(2).cells[cname(0, 0, 0)], 2, 'player 2 has cell (0,0) on its far ring')
    eq(R.interest.sent(2, 0, k00, 2), I.v[vk .. ':2'], 'and the far variant\'s pack')
    local m5 = mark()
    I.change(0, 0, k00, 2, 3)
    I.change(0, 0, k00, 1, 5)
    stubs.tick(300)
    local o1, o2 = decode(payloads(1, m5)), decode(payloads(2, m5))
    eq(count(o1, 'cell', function(o) return o.variant == 1 end), 1, 'ring 1 gets the near entry')
    eq(count(o1, 'cell', function(o) return o.variant == 2 end), 0, 'and not the far one')
    eq(count(o2, 'cell', function(o) return o.variant == 2 end), 1, 'ring 2 gets the far entry')
    eq(count(o2, 'cell', function(o) return o.variant == 1 end), 0, 'and not the near one')

    R.interest.setSent(1, 0, k00, 1, 5)
    local m6 = mark()
    local e6 = I.change(0, 0, k00, 1, 2)
    stubs.tick(300)
    ops = decode(payloads(1, m6))
    local c6 = find(ops, 'cell')
    eq(c6 and c6.from, 0, 'a subscriber behind gets the snapshot instead of the entry')
    eq(c6 and c6.to, e6.to, 'at the current version')
    eq(count(ops, 'sub', function(o) return o.key == k00 and o.v == e6.to end), 1, 'announced by a fresh SUB')
    eq(R.interest.sent(1, 0, k00, 1), e6.to, 'sent = that version')
    check(R.flush.stats().resyncs >= 1, 'counted as a resync')
    local e7 = I.change(0, 0, k00, 1, 1)
    R.interest.setSent(1, 0, k00, 1, e7.to)
    local m7 = mark()
    stubs.tick(300)
    eq(count(decode(payloads(1, m7)), 'cell'), 0, 'a subscriber that already has the entry\'s to gets nothing')
    check(R.flush.stats().skipped >= 1, 'counted as skipped')

    eq(R.interest.setSent(1, 0, key(40, 40), 1, 3), false, 'setSent of an unsubscribed cell is refused')
    eq(R.interest.setSent(1, 0, k00, 2, 3), false, 'setSent of the other variant is refused')
    eq(R.interest.sent(9, 0, k00, 1), nil, 'sent of an unknown src is nil')
    eq(R.interest.sent(1, 0, key(1, 1), 1), 0, 'a subscribed empty cell answers 0')
    eq(R.interest.subscribers(0, 0, k00)[1], 1, 'subscribers answers the live ring map')
    eq(R.interest.subscribers(0, 0, k00)[2], 2, 'with each subscriber\'s ring')
    eq(R.interest.subscribers(7, 0, k00), nil, 'nil for a bucket nobody is in')
end

do  -- a subscription made in the tick of a change: the fill sends the state that includes it (no entry)
    local _, _, R, I = newServer()
    local k = key(0, 0)
    I.fill(0, 0, k, 1, 2)
    join(1, vector3(64.0, 64.0, 0.0))
    local m = mark()
    report(1, 64.0, 64.0, 0.0)
    eq(R.interest.sent(1, 0, k, 1), -1, 'a new subscription is pending until the next tick fills it')
    local e = I.change(0, 0, k, 1, 3)
    stubs.tick(300)
    local ops = decode(payloads(1, m))
    eq(count(ops, 'cell', function(o) return o.key == k end), 1, 'one CELL for that cell')
    eq(find(ops, 'cell').from, 0, 'a snapshot')
    eq(find(ops, 'cell').to, e.to, 'that already includes the change of the tick')
    eq(find(ops, 'sub', function(o) return o.grid == 0 and o.key == k end).v, e.to, 'and its SUB names that version')
    eq(R.interest.sent(1, 0, k, 1), e.to, 'sent = that version')
end

--------------------------------------------------------------------------------
-- 4. Hysteresis: margin AND dwell, ring changes (UNSUB + SUB + pack), drops applied by the backstop
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer()
    local k10 = key(1, 0)
    I.fill(0, 0, k10, 1, 2)
    I.fill(0, 0, k10, 2, 1)
    local c = cname(0, 1, 0)
    local function go(x)
        movePed(1, vector3(x, 64.0, 0.0))
        report(1, x, 64.0, 0.0)
        stubs.tick(300)
        return R.interest.window(1)
    end
    join(1, vector3(64.0, 64.0, 0.0))
    local w = go(64.0)
    eq(w.cells[c], 1, 'cell (1,0) starts on ring 1 (64 m)')
    w = go(-40.0)
    eq(w.cells[c], 1, '168 m (inside the 64 m margin) keeps ring 1')
    eq(w.past[c], nil, 'inside the margin no dwell runs for it')
    w = go(-100.0)
    eq(w.cells[c], 1, '228 m (past the margin): still ring 1 while the dwell runs')
    local started = w.past[c]
    eq(started, stubs.now() - 300, 'the dwell starts at the first report past the margin')
    check(w.pendingAt > 0 and w.pendingAt <= started + 3000, 'a drop is pending')
    w = go(-40.0)
    eq(w.past[c], nil, 'back inside the margin: the dwell is reset')
    w = go(-100.0)
    check(w.past[c] > started, 'past the margin again: a new dwell from now')
    local m = mark()
    w = go(-100.0)
    eq(w.cells[c], 1, '600 ms into the dwell: still ring 1')
    stubs.tick(3000)                                   -- no report: the backstop applies the due drop
    w = R.interest.window(1)
    eq(w.cells[c], 2, 'after the dwell the backstop drops it one ring (228 m is inside the far ring)')
    local ops = decode(payloads(1, m))
    local _, iu = find(ops, 'unsub', function(o) return o.grid == 0 and o.key == k10 end)
    local s2, is = find(ops, 'sub', function(o) return o.grid == 0 and o.key == k10 end)
    check(iu ~= nil and is ~= nil and iu < is, 'a ring change is UNSUB then SUB')
    eq(s2 and s2.variant, 2, 'of the far variant')
    eq(s2 and s2.v, I.v['0:0:' .. k10 .. ':2'], 'with the far variant\'s version')
    local cf = find(ops, 'cell', function(o) return o.key == k10 end)
    check(cf ~= nil and cf.variant == 2 and cf.from == 0, 'and the far variant\'s pack')
    eq(R.interest.sent(1, 0, k10, 2), I.v['0:0:' .. k10 .. ':2'], 'sent follows the new variant')
    eq(R.interest.sent(1, 0, k10, 1), nil, 'the near variant is no longer subscribed')
    check(R.interest.stats().ringChanges >= 1, 'counted as a ring change')
    m = mark()
    w = go(64.0)
    eq(w.cells[c], 1, 'entering is instant: back to ring 1 at once')
    ops = decode(payloads(1, m))
    eq(find(ops, 'sub', function(o) return o.grid == 0 and o.key == k10 end).variant, 1, 'SUB of the near variant')
    -- ring 2 -> out: past FarRing + margin, after the dwell
    w = go(-600.0)                                      -- 728 m from cell (1,0)
    eq(w.cells[c], 1, 'far past every ring: still subscribed while the dwell runs')
    stubs.tick(3500)
    w = R.interest.window(1)
    eq(w.cells[c], nil, 'after the dwell it is out: a near cell past both bands drops straight out')
    eq(R.interest.sent(1, 0, k10, 1), nil, 'and its sent is forgotten')
    -- regions: the same rule at FarRegions + margin
    local r = cname(1, 0, 0)
    w = go(64.0)
    stubs.tick(3500)
    eq(R.interest.window(1).cells[r], 1, 'region (0,0) is subscribed')
    w = go(1600.0)                                      -- region (0,0) spans 0..512: 1088 m
    eq(w.cells[r], 1, '1088 m: within FarRegions + margin, kept')
    w = go(1700.0)
    stubs.tick(3500)
    eq(R.interest.window(1).cells[r], nil, '1188 m past the dwell: the region leaves')
end

--------------------------------------------------------------------------------
-- 5. Returning to a cell: nothing, the journal, or the pack (held versions)
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer()
    local kf = key(10, 0)
    I.fill(0, 0, kf, 1, 2)
    join(1, vector3(1344.0, 64.0, 0.0))
    report(1, 1344.0, 64.0, 0.0)
    stubs.tick(300)
    local v1 = R.interest.sent(1, 0, kf, 1)
    check(v1 ~= nil and v1 > 0, 'the cell went out as a pack')
    movePed(1, vector3(-1000.0, 64.0, 0.0))
    report(1, -1000.0, 64.0, 0.0)
    stubs.tick(3600)
    eq(R.interest.window(1).cells[cname(0, 10, 0)], nil, 'after the dwell the cell left the window')
    local e = I.change(0, 0, kf, 1, 3)
    stubs.tick(300)
    local packs, since, m = I.calls.pack, I.calls.since, mark()
    movePed(1, vector3(1344.0, 64.0, 0.0))
    report(1, 1344.0, 64.0, 0.0, 0, 0, 0, { [('0:%d:1'):format(kf)] = v1 })   -- A4's client lists its LRU
    stubs.tick(300)
    local ops = decode(payloads(1, m))
    eq(find(ops, 'sub', function(o) return o.grid == 0 and o.key == kf end).v, e.to, 'SUB names the current version')
    local cell = find(ops, 'cell', function(o) return o.key == kf end)
    eq(cell and cell.from, v1, 'a return costs the journal from the version the client kept, not a pack')
    eq(cell and cell.to, e.to, 'up to the current one')
    eq(I.calls.pack, packs, 'no pack was built')
    eq(I.calls.since, since + 1, 'one journal lookup')
    eq(R.interest.sent(1, 0, kf, 1), e.to, 'sent = the current version')
    check(R.interest.stats().journals >= 1, 'counted as a journal')

    -- without a report in between (a prefetch away and back): the server remembers what the client had at UNSUB
    R.interest.prefetch(1, -1500.0, 64.0, 0.0)
    stubs.tick(3600)
    eq(R.interest.window(1).cells[cname(0, 10, 0)], nil, 'the prefetch moved the window: the cell left')
    local e2 = I.change(0, 0, kf, 1, 1)
    stubs.tick(300)
    local m2b, packs2 = mark(), I.calls.pack
    R.interest.prefetch(1, 1344.0, 64.0, 0.0)
    stubs.tick(300)
    cell = find(decode(payloads(1, m2b)), 'cell', function(o) return o.key == kf end)
    eq(cell and cell.from, e.to, 'the journal starts at what the client had when the cell left')
    eq(cell and cell.to, e2.to, 'and ends at the current version')
    eq(I.calls.pack, packs2, 'still no pack')

    -- the client's own `held` (its LRU): the current version → SUB only; an uncovered one → the pack
    local _, _, R2, I2 = newServer()
    I2.fill(0, 0, kf, 1, 2)
    local cur = I2.v['0:0:' .. kf .. ':1']
    local other = key(11, 0)
    I2.fill(0, 0, other, 1, 1)
    join(1, vector3(1344.0, 64.0, 0.0))
    local m2 = mark()
    report(1, 1344.0, 64.0, 0.0, 0, 0, 0, { [('0:%d:1'):format(kf)] = cur, [('0:%d:1'):format(other)] = 77 }, true)
    stubs.tick(300)
    ops = decode(payloads(1, m2))
    eq(count(ops, 'cell', function(o) return o.key == kf end), 0, 'a held current version costs nothing but the SUB')
    eq(find(ops, 'sub', function(o) return o.grid == 0 and o.key == kf end).v, cur, 'SUB names it')
    eq(count(ops, 'cell', function(o) return o.key == other and o.from == 0 end), 1,
        'a held version the journal does not cover gets the pack')
    eq(R2.interest.stats().heldHits, 1, 'one held hit')
    local _, _, R3 = newServer()
    join(1, vector3(1344.0, 64.0, 0.0))
    report(1, 1344.0, 64.0, 0.0, 0, 0, 0, { ['0:5'] = 3, [GSPAN + key(1, 1)] = 4 }, true)
    eq(R3.interest.stats().reports, 1, 'held keys "<grid>:<key>" and integer cell ids are read')
    local _, _, R4 = newServer()
    join(1, vector3(0.0, 0.0, 0.0))
    local function accepted(held)
        local before = R4.interest.stats().reports
        report(1, 0.0, 0.0, 0.0, 0, 0, 0, held)
        return R4.interest.stats().reports - before
    end
    eq(accepted({ ['7:1'] = 3 }), 0, 'a held key with grid 7 refuses the report')
    eq(accepted({ ['0:1'] = -3 }), 0, 'a negative held version refuses the report')
    eq(accepted({ ['nope'] = 3 }), 0, 'a malformed held key refuses the report')
    eq(accepted({ ['0:1:9'] = 3 }), 0, 'a held variant above 3 refuses the report')
    local many = {}
    for i = 1, 49 do many[('0:%d'):format(i)] = i end
    eq(accepted(many), 0, '49 held entries fail the schema')
    many['0:49'] = nil
    eq(accepted(many), 1, '48 are fine')
    eq(accepted(nil), 1, 'no held at all is fine')
end

--------------------------------------------------------------------------------
-- 6. Bucket changes: at the next report, from the engine event, from the backstop
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer()
    local k = key(0, 0)
    I.fill(0, 0, k, 1, 2)
    I.fill(5, 0, k, 1, 3)
    join(1, vector3(64.0, 64.0, 0.0))
    report(1, 64.0, 64.0, 0.0)
    stubs.tick(300)
    local n0 = R.interest.window(1).n
    stubs.buckets[1] = 5
    local m = mark()
    report(1, 64.0, 64.0, 0.0)
    stubs.tick(300)
    local w = R.interest.window(1)
    eq(w.bucket, 5, 'the next report reads the new bucket')
    local ops = decode(payloads(1, m))
    check(n0 > 0, 'the old window had subscriptions')
    eq(count(ops, 'reset'), 1, 'a bucket change sends RESET once (RV1 F17/F18)')
    eq(ops[2] and ops[2].op, 'reset', 'first in its event, right after the header')
    eq((find(ops, 'reset') or {}).reason, 1, 'reason: bucket')
    eq(count(ops, 'unsub'), 0, 'no UNSUBs: RESET drops everything')
    eq(count(ops, 'sub'), w.n, 'then the new window\'s SUBs')
    local _, ir = find(ops, 'reset')
    local _, is = find(ops, 'sub')
    check(ir ~= nil and is ~= nil and ir < is, 'RESET before the first SUB')
    eq(R.interest.sent(1, 0, k, 1), I.v['5:0:' .. k .. ':1'], 'sent restarts in the new bucket')
    eq(count(ops, 'put'), 3, 'the new bucket\'s content (a pack) arrives')
    eq(R.interest.subscribers(0, 0, k), nil, 'nothing is left subscribed in bucket 0')
    eq(R.interest.stats().bucketChanges, 1, 'counted')
    stubs.buckets[1] = 0
    local m2 = mark()
    stubs.triggerOn(H.env, 'onPlayerBucketChange', 0, '1', 0, 5)
    eq(R.interest.bucketOf(1), 0, 'onPlayerBucketChange resets the window without a report')
    stubs.tick(300)
    check(#payloads(1, m2) > 0, 'and the new window goes out')
    stubs.buckets[1] = 9
    stubs.tick(1000)
    eq(R.interest.bucketOf(1), 9, 'the backstop sees a bucket change nobody reported')
end

--------------------------------------------------------------------------------
-- 7. Focus validation: schema, cooldown, loaded, clamping (ped / free camera / pin / prefetch / Δt)
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    join(1, vector3(100.0, 100.0, 10.0))
    local function reports() return R.interest.stats().reports end
    local function focusX() return R.interest.window(1) and R.interest.window(1).focus.x end
    local r0 = reports()
    stubs.tick(300)
    stubs.triggerOn(H.env, 'core:scene:focus', 1, 0 / 0, 0.0, 0.0, 0.0, 0.0, 0.0, 1)
    eq(reports(), r0, 'NaN fails the schema')
    stubs.tick(300)
    stubs.triggerOn(H.env, 'core:scene:focus', 1, 'x', 0.0, 0.0, 0.0, 0.0, 0.0, 1)
    eq(reports(), r0, 'a string fails the schema')
    stubs.tick(300)
    stubs.triggerOn(H.env, 'core:scene:focus', 1, 1.0, 2.0, 3.0, 0.0, 0.0, 0.0)
    eq(reports(), r0, 'a missing seq fails the schema')
    stubs.tick(300)
    stubs.triggerOn(H.env, 'core:scene:focus', 1, 1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 1.5)
    eq(reports(), r0, 'a fractional seq fails the schema')
    stubs.tick(300)
    stubs.triggerOn(H.env, 'core:scene:focus', 1, 1.0, 2.0, 3.0, 0.0, 1 / 0, 0.0, 1)
    eq(reports(), r0, 'an infinite velocity fails the schema')
    stubs.tick(300)
    stubs.triggerOn(H.env, 'core:scene:focus', 1, 100.0, 100.0, 10.0, 0.0, 0.0, 0.0, 1, 'held')
    eq(reports(), r0, 'held must be a table')
    report(1, 100.0, 100.0, 10.0)
    eq(reports(), r0 + 1, 'a clean report is accepted')
    stubs.tick(100)
    stubs.triggerOn(H.env, 'core:scene:focus', 1, 110.0, 100.0, 10.0, 0.0, 0.0, 0.0, 99)
    eq(reports(), r0 + 1, 'a second report inside the 250 ms cooldown is dropped')
    eq(R.interest.window(1).seq, seq, 'and changes nothing')
    H.loaded[2] = nil
    stubs.connectPlayer(H.env, 2, { coords = vector3(0.0, 0.0, 0.0) })
    stubs.triggerOn(H.env, 'core:scene:focus', 2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1)
    eq(R.interest.window(2), nil, 'a player without a session is refused (requireLoaded)')

    report(1, 5000.0, 5000.0, 10.0, 10.0, 0.0, 0.0)
    eq(focusX(), 100.0, 'a report far from every allowed point is clamped to the ped (x)')
    eq(R.interest.window(1).focus.y, 100.0, '(y)')
    eq(R.interest.window(1).lead.x, 100.0, 'a clamped report has no lead')
    eq(R.interest.stats().clamped, 1, 'counted')
    report(1, 130.0, 100.0, 10.0)
    eq(focusX(), 130.0, 'a report within the slack is kept')
    report(1, 220.0, 100.0, 10.0)
    eq(focusX(), 100.0, '120 m from the ped 300 ms after the last report is clamped (slack 77 m)')
    stubs.tick(2000)
    report(1, 300.0, 100.0, 10.0)
    eq(focusX(), 300.0, '200 m after 2.3 s is inside the slack (50 + 90 × 2 = 230 m)')

    H.focusPos[1] = vector3(3000.0, 0.0, 50.0)
    local fp = counters.focusPos
    report(1, 3000.0, 0.0, 50.0)
    eq(counters.focusPos, fp, 'no GetPlayerFocusPos without a free-camera mode')
    eq(focusX(), 100.0, 'the camera far away is clamped without the mode')
    H.modes[1] = { noclip = true }
    Core.emitHook('staffModeChanged', 1, { noclip = true })
    stubs.tick(300)
    fp = counters.focusPos
    report(1, 3010.0, 0.0, 50.0, 0, 0, 0, nil, true)
    eq(counters.focusPos, fp + 1, 'noclip: one GetPlayerFocusPos per report')
    eq(focusX(), 3010.0, 'a report at the camera is accepted in noclip')
    Core.emitHook('staffModeChanged', 1, { spectate = true })
    report(1, 3000.0, 0.0, 50.0)
    eq(focusX(), 3000.0, 'spectate too')
    Core.emitHook('staffModeChanged', 1, { editor = true })
    report(1, 2990.0, 0.0, 50.0)
    eq(focusX(), 2990.0, 'and editor')
    Core.emitHook('staffModeChanged', 1, { god = true })
    report(1, 3000.0, 0.0, 50.0)
    eq(focusX(), 100.0, 'another mode is no free camera: clamped to the ped')
    Core.emitHook('staffModeChanged', 1, {})

    R.interest.pin(1, -2000.0, 1500.0, 20.0)
    eq(focusX(), -2000.0, 'pin moves the window at once')
    check(R.interest.window(1).pinned, 'pinned')
    report(1, -1990.0, 1500.0, 20.0)
    eq(focusX(), -1990.0, 'a report near the pin is accepted')
    report(1, 100.0, 100.0, 10.0)
    eq(focusX(), 100.0, 'a report near the ped stays accepted while pinned')
    eq(R.interest.pin(1, 0 / 0, 0.0, 0.0), false, 'a NaN pin is refused')
    eq(R.interest.pin('1', 1.0, 2.0, 3.0), false, 'a string src is refused')
    R.interest.pin(1, nil)
    check(not R.interest.window(1).pinned, 'pin(src, nil) clears')
    report(1, -1990.0, 1500.0, 20.0)
    eq(focusX(), 100.0, 'after the pin a report there is clamped')

    local packs = R.interest.stats().prefetches
    R.interest.prefetch(1, 800.0, -800.0, 5.0)
    eq(R.interest.stats().prefetches, packs + 1, 'prefetch counted')
    eq(focusX(), 800.0, 'prefetch moves the window before the player arrives')
    check(R.interest.window(1).cells[cname(0, 6, -7)] == 1, 'the destination\'s cells are subscribed')
    report(1, 805.0, -800.0, 5.0)
    eq(focusX(), 805.0, 'reports at the destination are accepted')
    stubs.tick(10500)
    report(1, 805.0, -800.0, 5.0)
    eq(focusX(), 100.0, 'after PREFETCH_MS the destination is no longer an allowed point')
    eq(R.interest.prefetch(1, 'a', 0.0, 0.0), false, 'a bad prefetch is refused')

    stubs.peds[1] = 0
    local before = reports()
    report(1, 100.0, 100.0, 10.0)
    eq(reports(), before, 'a report without a ped, pin or prefetch is ignored')
end

--------------------------------------------------------------------------------
-- 8. Backstop: corrections, players without a window, natives per visit, slices
--------------------------------------------------------------------------------
do
    local _, _, R = newServer()
    join(1, vector3(0.0, 0.0, 0.0))
    report(1, 0.0, 0.0, 0.0)
    stubs.tick(300)
    movePed(1, vector3(1500.0, 0.0, 0.0))
    stubs.tick(600)
    eq(R.interest.window(1).focus.x, 1500.0, 'the backstop moves a window whose focus left every slack')
    check(R.interest.stats().corrections >= 1, 'counted as a correction')
    check(R.interest.window(1).cells[cname(0, 11, 0)] == 1, 'the new window is around the server position')
    join(2, vector3(-300.0, 200.0, 0.0))
    stubs.tick(600)
    local w2 = R.interest.window(2)
    check(w2 ~= nil and w2.n > 0, 'a loaded player that never reported gets a window')
    eq(w2 and w2.focus.x, -300.0, 'at its server position')
    local r0, f0, v0 = counters.routing, counters.focusPos, R.interest.stats().backstops
    stubs.tick(5000)
    local visits = R.interest.stats().backstops - v0
    check(visits > 0, 'the backstop visited')
    eq(counters.routing - r0, visits, 'one GetPlayerRoutingBucket per visit')
    eq(counters.focusPos - f0, 0, 'no GetPlayerFocusPos outside the free-camera modes')
    H.modes[2] = { spectate = true }
    H.Core.emitHook('staffModeChanged', 2, { spectate = true })
    H.focusPos[2] = vector3(-300.0, 200.0, 0.0)
    r0, f0, v0 = counters.routing, counters.focusPos, R.interest.stats().backstops
    stubs.tick(2000)
    visits = R.interest.stats().backstops - v0
    check(counters.routing - r0 + counters.focusPos - f0 <= 2 * visits, 'at most two natives per visit')

    local _, _, R2 = newServer()
    for src = 1, 40 do join(src, vector3(src * 10.0, 0.0, 0.0)) end
    stubs.tick(1000)
    local v1 = R2.interest.stats().backstops
    stubs.tick(5000)
    local n = R2.interest.stats().backstops - v1
    check(n >= 40 and n <= 44, ('40 players: each visited once per BackstopMs (%d visits in 5 s)'):format(n))
end

--------------------------------------------------------------------------------
-- 9. Gated audiences: players, faction, perm, editors, near, fn, any / all; hooks; rings; set / del
--------------------------------------------------------------------------------

--- A gated root in cell (0,0) of bucket 0 (the fields the flush reads; index-owned `cell` included).
local function gnode(id, audience, opts)
    opts = opts or {}
    local p = opts.pos or vector3(64.0, 64.0, 0.0)
    return { id = id, bucket = opts.bucket or 0, tier = opts.tier or 'S', audience = audience, ver = 7,
        owner = 'test', pos = { x = p.x, y = p.y, z = p.z }, cell = { grid = 0, key = H.I.keyOf(0, p.x, p.y) } }
end

local function gatedOp(node, op, blob, id)
    local q = H.I.q.gated
    q[#q + 1] = { node = node, id = id or node.id, op = op, n = 1,
        blob = blob or H.Codec.put(node.id, 1, node.ver, 0, 32, node.pos.x, node.pos.y, node.pos.z, 0, 0, 0, 10, '') }
    H.I.touch()
end

--- The PRIV ops (put / set / del inside a PRIV section) each src got since `from`: { [src] = { 'put:500', … } }.
local function privSince(from, srcs)
    local out = {}
    for _, src in ipairs(srcs) do
        local list = {}
        for _, o in ipairs(decode(payloads(src, from))) do
            if o.section == 'priv' then list[#list + 1] = o.op .. ':' .. o.id end
        end
        out[src] = table.concat(list, ',')
    end
    return out
end

do
    local _, Core, R = newServer()
    join(1, vector3(64.0, 64.0, 0.0))
    join(2, vector3(114.0, 64.0, 0.0))
    join(3, vector3(64.0, 114.0, 0.0))
    join(4, vector3(364.0, 64.0, 0.0))
    for src, x in pairs({ 64.0, 114.0, 64.0, 364.0 }) do report(src, x, src == 3 and 114.0 or 64.0, 0.0, 0, 0, 0, nil, true) end
    stubs.tick(400)
    local ALL = { 1, 2, 3, 4 }
    eq(R.interest.window(4).cells[cname(0, 0, 0)], 2, 'player 4 has cell (0,0) on its far ring')

    local m = mark()
    local n500 = gnode(500, { players = { 2 } })
    gatedOp(n500, 'put')
    stubs.tick(300)
    local got = privSince(m, ALL)
    eq(got[2], 'put:500', 'players: the listed player gets the node in a PRIV section')
    check(got[1] == '' and got[3] == '' and got[4] == '', 'players: nobody else')
    local ops = decode(payloads(2, m))
    local p, ip = find(ops, 'priv')
    local _, iput = find(ops, 'put', function(o) return o.id == 500 end)
    check(p ~= nil and ip < iput, 'PRIV(n) announces the gated ops')
    eq(find(ops, 'put', function(o) return o.id == 500 end).flags & 32, 32, 'the PUT carries GATED')
    eq(R.interest.holders(500)[2], 500, 'holders records it, with the head it was published under')
    eq(table.concat(R.interest.gatedTargets(n500), ','), '2', 'gatedTargets')
    check(R.interest.allows(n500, 2) and not R.interest.allows(n500, 1), 'allows')
    local other = gnode(599, nil, { bucket = 5 })
    eq(R.interest.allows(other, 1), false, 'a node of another bucket is never allowed')
    local public = gnode(598, nil)
    eq(R.interest.allows(public, 1), true, 'no audience = public')

    H.factions[3] = 'police'
    m = mark()
    local n501 = gnode(501, { faction = 'police' })
    gatedOp(n501, 'put')
    stubs.tick(300)
    got = privSince(m, ALL)
    eq(got[3], 'put:501', 'faction: the member gets it')
    check(got[1] == '' and got[2] == '', 'faction: the others do not')
    m = mark()
    H.factions[3] = nil
    Core.emitHook('factionChanged', 3, nil)
    H.factions[1] = 'police'
    Core.emitHook('factionChanged', 1, { id = 'police', rank = 1 })
    stubs.tick(300)
    got = privSince(m, ALL)
    eq(got[3], 'del:501', 'factionChanged: a member who left gets the DEL')
    eq(got[1], 'put:501', 'factionChanged: a new member gets the PUT')
    local n502f = gnode(502, { faction = { 'ems', 'police' } })
    check(R.interest.allows(n502f, 1) and not R.interest.allows(n502f, 2), 'faction lists')

    H.perms['2|scene.see'] = true
    m = mark()
    local n503 = gnode(503, { perm = 'scene.see' })
    gatedOp(n503, 'put')
    stubs.tick(300)
    got = privSince(m, ALL)
    eq(got[2], 'put:503', 'perm: the holder of the permission gets it')
    check(got[1] == '' and got[3] == '', 'perm: nobody else')
    m = mark()
    H.perms['3|scene.see'] = true
    Core.emitHook('permsChanged', 3, 'grant')
    stubs.tick(300)
    eq(privSince(m, ALL)[3], 'put:503', 'permsChanged(src): a new grant gets the PUT')
    m = mark()
    H.perms['2|scene.see'] = nil
    Core.emitHook('permsChanged', nil, 'saveGroup')
    stubs.tick(300)
    got = privSince(m, ALL)
    eq(got[2], 'del:503', 'permsChanged(nil) re-evaluates everyone: a lost right gets the DEL')
    eq(got[3], '', 'and a kept one gets nothing new')

    m = mark()
    local n504 = gnode(504, { editors = true })
    gatedOp(n504, 'put')
    stubs.tick(300)
    eq(privSince(m, ALL)[1], '', 'editors: nobody without the mode')
    Core.emitHook('staffModeChanged', 1, { editor = true })
    stubs.tick(300)
    eq(privSince(m, ALL)[1], 'put:504', 'staffModeChanged: Admin mode editor gets it')
    Core.emitHook('staffModeChanged', 1, {})
    stubs.tick(300)
    eq(privSince(m, ALL)[1], 'put:504,del:504', 'and loses it with the mode')
    m = mark()
    Core.MapsRuntime = { state = { editorBuckets = { m1 = 0 } } }
    Core.emitHook('permsChanged', nil, 'define')
    stubs.tick(300)
    got = privSince(m, ALL)
    check(got[1] == 'put:504' and got[2] == 'put:504' and got[3] == 'put:504', 'an open draft\'s editor bucket: everyone in it')
    eq(got[4], '', 'except a far-ring subscriber of an S-tier node')
    Core.MapsRuntime = nil
    Core.emitHook('permsChanged', nil, 'define')
    stubs.tick(300)

    m = mark()
    local n505 = gnode(505, { near = 30 })
    gatedOp(n505, 'put')
    stubs.tick(300)
    got = privSince(m, ALL)
    eq(got[1], 'put:505', 'near: the player 0 m away gets it')
    eq(got[2], '', 'near: the one 50 m away does not')
    movePed(2, vector3(84.0, 64.0, 0.0))
    report(2, 84.0, 64.0, 0.0)
    stubs.tick(300)
    eq(privSince(m, ALL)[2], 'put:505', 'near is re-checked on a focus report')
    stubs.coords[stubs.peds[2]] = vector3(164.0, 64.0, 0.0)
    stubs.tick(2600)
    eq(privSince(m, ALL)[2], 'put:505,del:505', 'and by the backstop (server position)')

    m = mark()
    local fnCalls = 0
    local n506 = gnode(506, { fn = setmetatable({}, { __call = function(_, src, id)
        fnCalls = fnCalls + 1
        return src == 3 and id == 506
    end }) })
    gatedOp(n506, 'put')
    stubs.tick(300)
    got = privSince(m, ALL)
    eq(got[3], 'put:506', 'fn: a callable table decides (src, id)')
    check(got[1] == '' and got[2] == '', 'fn: the others do not')
    check(fnCalls >= 3, 'fn ran per subscriber')
    local errs, slow = R.interest.stats().fnErrors, R.interest.stats().fnSlow
    local bad = gnode(507, { fn = function() error('boom') end })
    eq(R.interest.allows(bad, 1), false, 'an erroring fn denies')
    eq(R.interest.stats().fnErrors, errs + 1, 'and is counted')
    local slowNode = gnode(508, { fn = function()
        local t = os.clock() + 0.002
        while os.clock() < t do end
        return true
    end })
    eq(R.interest.allows(slowNode, 1), true, 'a slow fn still answers')
    eq(R.interest.stats().fnSlow, slow + 1, 'but is counted over the 0.2 ms budget')
    eq(R.interest.allows(gnode(509, { fn = 'nope' }), 1), false, 'a non-callable fn denies')

    check(R.interest.allows(gnode(1, { any = { { players = { 1 } }, { perm = 'scene.see' } } }), 1), 'any: one branch is enough')
    check(R.interest.allows(gnode(1, { any = { { players = { 1 } }, { perm = 'scene.see' } } }), 3), 'any: the other branch')
    check(not R.interest.allows(gnode(1, { any = { { players = { 1 } }, { perm = 'scene.see' } } }), 2), 'any: neither')
    check(R.interest.allows(gnode(1, { all = { { perm = 'scene.see' }, { players = { 2, 3 } } } }), 3), 'all: both hold')
    check(not R.interest.allows(gnode(1, { all = { { perm = 'scene.see' }, { players = { 1, 2 } } } }), 1), 'all: one fails')
    check(R.interest.allows(gnode(1, { players = { 3 }, perm = 'scene.see' }), 3), 'several keys: all of them hold')
    check(not R.interest.allows(gnode(1, { players = { 1 }, perm = 'scene.see' }), 1), 'several keys: one fails')
    check(R.interest.allows(gnode(1, { players = { [2] = true } }), 2), 'players as a set')
    check(not R.interest.allows(gnode(1, { color = 'red' }), 1), 'an unknown key fails closed')
    check(not R.interest.allows(gnode(1, { players = 'x' }), 1), 'a malformed value fails closed')
    check(not R.interest.allows(gnode(1, { near = 0 / 0 }), 1), 'a NaN radius fails closed')
    check(not R.interest.allows(gnode(1, 'public'), 1), 'a non-table audience fails closed')
    local deep = { players = { 1 } }
    for _ = 1, 10 do deep = { all = { deep } } end
    check(not R.interest.allows(gnode(1, deep), 1), 'nesting deeper than 8 fails closed')

    m = mark()
    local n510 = gnode(510, { players = { 4 } }, { tier = 'S' })
    local n511 = gnode(511, { players = { 4 } }, { tier = 'M' })
    gatedOp(n510, 'put')
    gatedOp(n511, 'put')
    stubs.tick(300)
    eq(privSince(m, ALL)[4], 'put:511', 'a far-ring subscriber gets M-tier gated nodes only')

    m = mark()
    local gp = H.I.calls.gatedPut
    n500.audience = { players = { 2, 3 } }
    gatedOp(n500, 'set', H.Codec.set(500, 8, ''))
    stubs.tick(300)
    got = privSince(m, ALL)
    eq(got[2], 'set:500', 'a holder gets the SET')
    eq(got[3], 'put:500', 'a newly allowed subscriber gets the full PUT')
    eq(H.I.calls.gatedPut, gp + 1, 'from R.index.gatedPut')
    m = mark()
    n500.audience = { players = { 3 } }
    gatedOp(n500, 'set', H.Codec.set(500, 9, ''))
    stubs.tick(300)
    got = privSince(m, ALL)
    eq(got[2], 'del:500', 'a holder the audience lost gets a DEL')
    eq(got[3], 'set:500', 'the remaining holder the SET')
    eq(R.interest.holders(500)[2], nil, 'holders forgets the lost one')
    m = mark()
    gatedOp(n500, 'put', H.Codec.put(777, 1, 9, 500, 32, 64.0, 64.0, 0.0, 0, 0, 0, 10, ''), 777)
    stubs.tick(300)
    eq(privSince(m, ALL)[3], 'put:777', 'a new child reaches the unit\'s holders')
    eq(R.interest.holders(777)[3], 500, 'and is published with the head')
    m = mark()
    gatedOp(n500, 'del', H.Codec.del(777, 9, 0), 777)
    stubs.tick(300)
    eq(privSince(m, ALL)[3], 'del:777', 'a child\'s DEL goes to the srcs that hold the child')
    eq(R.interest.holders(500)[3], 500, 'who keep the head')
    eq(R.interest.holders(777), nil, 'and forget the child')
    m = mark()
    gatedOp(n500, 'del', H.Codec.del(500, 10, 0))
    stubs.tick(300)
    eq(privSince(m, ALL)[3], 'del:500', 'the root\'s DEL reaches its holders')
    eq(R.interest.holders(500), nil, 'and the holders are gone')

    m = mark()
    movePed(3, vector3(3000.0, 114.0, 0.0))
    report(3, 3000.0, 114.0, 0.0)
    stubs.tick(3600)
    got = privSince(m, { 3 })
    check(got[3]:find('del:501', 1, true) == nil, 'player 3 no longer held 501 (it left the faction earlier)')
    check(got[3]:find('del:503', 1, true) ~= nil, 'a cell leaving the window takes its held gated nodes (DEL)')
    check(got[3]:find('del:506', 1, true) ~= nil, 'every one of them')
    eq(next(R.interest.windowOf(3).priv), nil, 'player 3 holds no gated node any more')
end

--------------------------------------------------------------------------------
-- 10. Flush: one event per client per tick, priorities, MaxEventBytes, backlog, budget, latent, dedupe, cancel
--------------------------------------------------------------------------------

--- A CELL entry of about `size` bytes (one PUT whose extra is padding).
local function big(k, size)
    local C = H.Codec
    return C.cell(0, k, 1, 0, 5, 1) .. C.put(k, 1, 5, 0, 0, 0.0, 0.0, 0.0, 0, 0, 0, 10, string.rep('x', size))
end

do
    local _, _, R = newServer()
    local C = H.Codec
    join(1, vector3(0.0, 0.0, 0.0))
    report(1, 0.0, 0.0, 0.0)
    stubs.tick(600)
    local m = mark()
    R.flush.queue(1, C.event(0, 1, 0.0, 0.0, 0.0, 'e1', ''), 4)
    R.flush.queue(1, C.cell(0, 333, 2, 0, 5, 0), 3)
    R.flush.queue(1, C.cell(0, 222, 1, 0, 5, 0), 2)
    R.flush.queue(1, C.unsub(0, 111), 1)
    R.flush.queue(1, C.unsub(0, 112), 1)
    R.flush.queue(1, C.unsub(0, 113), 1)
    stubs.tick(300)
    local list = payloads(1, m)
    eq(#list, 1, 'everything queued for a client in one tick goes out as ONE event')
    local ops = decode(list)
    local _, a = find(ops, 'unsub', function(o) return o.key == 111 end)
    local _, b = find(ops, 'unsub', function(o) return o.key == 112 end)
    local _, c = find(ops, 'unsub', function(o) return o.key == 113 end)
    local _, d = find(ops, 'cell', function(o) return o.key == 222 end)
    local _, e = find(ops, 'cell', function(o) return o.key == 333 end)
    local _, f = find(ops, 'event')
    check(a and b and c and a < b and b < c, 'FIFO inside a priority')
    check(c and d and c < d, 'priority 1 (control) before 2 (near)')
    check(d and e and d < e, 'priority 2 before 3 (far)')
    check(e and f and e < f, 'priority 3 before 4 (transient)')
    eq(R.flush.queue(1, '', 2), false, 'an empty blob is refused')
    eq(R.flush.queue(0, 'x', 2), false, 'src 0 is refused')
    eq(R.flush.queue(1.5, 'x', 2), false, 'a fractional src is refused')
    eq(R.flush.backlog(1), 0, 'nothing is left queued')
end

do
    local _, _, R = newServer({ scene = { MaxEventBytes = 4096 } })
    join(1, vector3(0.0, 0.0, 0.0))
    report(1, 0.0, 0.0, 0.0)
    stubs.tick(600)
    local m = mark()
    for k = 1, 3 do R.flush.queue(1, big(k, 1750), 2) end
    stubs.tick(300)
    local list = payloads(1, m)
    eq(#list, 2, 'three 1.8 KiB items at MaxEventBytes 4096: two events')
    check(#list[1] <= 4096 and #list[2] <= 4096, 'each event stays within MaxEventBytes')
    eq(count(decode({ list[1] }), 'cell'), 2, 'the first carries two items')
    eq(find(decode({ list[2] }), 'cell').key, 3, 'the rest waits for the next tick in order')
    m = mark()
    R.flush.queue(1, big(4, 5000), 2)
    R.flush.queue(1, big(5, 100), 2)
    stubs.tick(300)
    list = payloads(1, m)
    eq(#list, 2, 'an item larger than MaxEventBytes goes alone')
    check(#list[1] > 4096 and count(decode({ list[1] }), 'cell') == 1, 'in an event of its own')
    eq(R.flush.stats().oversized, 1, 'counted as oversized')
end

do  -- the backlog guard
    local _, _, R, I = newServer({ scene = { MaxEventBytes = 4096, MaxBacklogBytes = 16384 } })
    local k = key(0, 0)
    I.fill(0, 0, k, 1, 2)
    join(1, vector3(64.0, 64.0, 0.0))
    report(1, 64.0, 64.0, 0.0)
    stubs.tick(600)
    local subs = R.interest.window(1).n
    local m, lm = mark()
    R.flush.queue(1, H.Codec.unsub(0, 999), 1)
    for i = 1, 30 do R.flush.queue(1, big(100 + i, 1750), 2) end
    R.flush.queue(1, H.Codec.event(0, 1, 0.0, 0.0, 0.0, 'late', ''), 4)
    stubs.tick(300)
    local st = R.flush.stats()
    eq(st.overflows, 1, 'a backlog over MaxBacklogBytes trips the guard once')
    check(st.dropped >= 20, ('its pending priority 2–4 items are dropped (%d)'):format(st.dropped))
    local ops = decode(payloads(1, m))
    eq(count(ops, 'unsub', function(o) return o.key == 999 end), 1, 'control ops survive')
    eq(count(ops, 'event'), 0, 'transient ones do not')
    eq(count(ops, 'sub'), subs, 'every subscription is announced again')
    local lops = decode(latents(1, lm))
    eq(count(lops, 'cell', function(o) return o.key == k and o.from == 0 end), 1, 'and resynced through a latent pack')
    eq(R.interest.sent(1, 0, k, 1), I.v['0:0:' .. k .. ':1'], 'sent = that pack')
    check(R.flush.backlog(1) < 16384, 'the backlog is bounded again')
end

do  -- the pack budget: latent above MaxEventBytes, withheld when the budget is spent, retried when it refills
    local _, _, R, I = newServer({ scene = { MaxEventBytes = 4096, PackBudgetBytes = 20000,
        PackBudgetWindowMs = 10000 } })
    local k1, k2 = key(0, 0), key(1, 0)
    I.fill(0, 0, k1, 1, 1, string.rep('y', 15000))
    I.fill(0, 0, k2, 1, 1, string.rep('z', 15000))
    join(1, vector3(64.0, 64.0, 0.0))
    local m, lm = mark()
    report(1, 64.0, 64.0, 0.0)
    stubs.tick(300)
    local l = latents(1, lm)
    eq(#l, 1, 'a pack over MaxEventBytes goes latent')
    local lops = decode(l)
    eq(count(lops, 'cell'), 1, 'one pack fits the budget')
    eq(find(lops, 'cell').key, k1, 'the nearest cell first')
    check(R.flush.stats().withheld > 0, 'the other is withheld')
    eq(latent[#latent].bps, 750000, 'latent events use LatentBps')
    local subT
    for _, p in ipairs(payloads(1, m)) do
        local o = decode({ p })
        if find(o, 'sub', function(x) return x.grid == 0 and x.key == k1 end) then subT = o[1].now end
    end
    check(subT ~= nil and subT <= lops[1].now, 'the latent pack is never stamped before its SUB left')
    eq(R.flush.stats().packsWaiting, 1, 'one pack waits')
    stubs.tick(3000)
    eq(#latents(1, lm), 1, 'still waiting while the budget refills')
    stubs.tick(2500)
    l = latents(1, lm)
    eq(#l, 2, 'the withheld pack goes when the budget allows')
    eq(find(decode({ l[2] }), 'cell').key, k2, 'the one that waited')
    eq(R.flush.stats().packsWaiting, 0, 'nothing waits any more')
end

do  -- dedupe and cancel of waiting packs
    local _, _, R, I = newServer({ scene = { MaxEventBytes = 4096, PackBudgetBytes = 20000,
        PackBudgetWindowMs = 100000 } })
    local k1, k2 = key(0, 0), key(1, 0)
    I.fill(0, 0, k1, 1, 1, string.rep('y', 15000))
    I.fill(0, 0, k2, 1, 1, string.rep('z', 15000))
    join(1, vector3(64.0, 64.0, 0.0))
    local _, lm = mark()
    report(1, 64.0, 64.0, 0.0)
    stubs.tick(300)
    eq(#latents(1, lm), 1, 'one pack out, one waiting')
    local e = I.change(0, 0, k2, 1, 1, string.rep('w', 15000))
    stubs.tick(300)
    stubs.triggerOn(H.env, 'core:scene:resync', 1, 0, k2, 1, 0)
    stubs.tick(300)
    eq(R.flush.stats().packsWaiting, 1, 'a newer pack of the same cell replaces the waiting one')
    eq(R.interest.sent(1, 0, k2, 1), e.to, 'sent names the newer pack')
    movePed(1, vector3(3064.0, 64.0, 0.0))
    report(1, 3064.0, 64.0, 0.0)
    stubs.tick(3600)
    eq(R.interest.window(1).cells[cname(0, 1, 0)], nil, 'the cell left the window')
    eq(R.flush.stats().packsWaiting, 0, 'its waiting pack is cancelled')
    stubs.tick(90000)
    eq(#latents(1, lm), 1, 'and never sent')
end

--------------------------------------------------------------------------------
-- 11. Events (radius, horizon, expiry, gated), DR caps, KINDS, idle, stats, msgpack, resync, drop
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer()
    local C = H.Codec
    local ALL = { 1, 2, 3, 4 }
    local xs = { 64.0, 104.0, 184.0, 664.0 }
    for src = 1, 4 do
        join(src, vector3(xs[src], 64.0, 0.0))
        report(src, xs[src], 64.0, 0.0, 0, 0, 0, nil, true)
    end
    stubs.tick(600)
    local function event(radius, horizon, age, node)
        local t = (stubs.now() - (age or 0)) & 0xFFFFFFFF
        I.q.events[#I.q.events + 1] = { bucket = 0, grid = 0, key = key(0, 0), x = 64.0, y = 64.0, z = 0.0,
            radius = radius, horizonMs = horizon, t = t, blob = C.event(node and node.id or 0, t, 64.0, 64.0, 0.0, 'boom', ''),
            node = node }
        I.touch()
    end
    local function heard(from)
        local out = {}
        for _, src in ipairs(ALL) do out[src] = count(decode(payloads(src, from)), 'event') end
        return out
    end
    local m = mark()
    event(50, 1000)
    stubs.tick(300)
    local h = heard(m)
    check(h[1] == 1 and h[2] == 1, 'an event reaches the subscribers whose focus is within its radius')
    check(h[3] == 0 and h[4] == 0, 'and nobody farther away')
    m = mark()
    event(700, 1000)
    stubs.tick(300)
    h = heard(m)
    check(h[1] == 1 and h[3] == 1 and h[4] == 1, 'a radius past FarRing reaches through the regions (600 m)')
    m = mark()
    event(50, 1000, 2000)
    stubs.tick(300)
    h = heard(m)
    check(h[1] == 0 and h[2] == 0, 'an event older than its horizon is dropped')
    check(R.flush.stats().expired >= 1, 'counted as expired')
    m = mark()
    R.flush.queue(1, C.event(0, 1, 0.0, 0.0, 0.0, 'stale', ''), 4, (stubs.now() - 10) & 0xFFFFFFFF)
    R.flush.queue(1, C.event(0, 1, 0.0, 0.0, 0.0, 'fresh', ''), 4, (stubs.now() + 5000) & 0xFFFFFFFF)
    stubs.tick(300)
    local ops = decode(payloads(1, m))
    eq(count(ops, 'event', function(o) return o.name == 'stale' end), 0, 'a queued transient past its expiry is dropped')
    eq(count(ops, 'event', function(o) return o.name == 'fresh' end), 1, 'a fresh one goes')
    local n = { id = 700, bucket = 0, tier = 'S', audience = { players = { 2 } }, ver = 3, pos = { x = 64.0, y = 64.0, z = 0.0 },
        cell = { grid = 0, key = key(0, 0) } }
    I.q.gated[1] = { node = n, id = 700, op = 'put', blob = C.put(700, 1, 3, 0, 32, 64.0, 64.0, 0.0, 0, 0, 0, 10, '') }
    I.touch()
    stubs.tick(300)
    m = mark()
    event(50, 1000, 0, n)
    stubs.tick(300)
    h = heard(m)
    check(h[2] == 1 and h[1] == 0, 'an event of a gated node reaches its holders only')

    -- C2 dead reckoning: near ring ≤ NearHz (10), far ring ≤ FarHz (1), latest wins
    local node = { id = 900, bucket = 0, tier = 'M', ver = 1, pos = { x = 64.0, y = 64.0, z = 0.0 },
        cell = { grid = 0, key = key(0, 0) } }
    eq(R.interest.window(4).cells[cname(0, 0, 0)], nil, 'player 4 (600 m) does not hold cell (0,0)')
    join(5, vector3(400.0, 64.0, 0.0))
    report(5, 400.0, 64.0, 0.0, 0, 0, 0, nil, true)
    stubs.tick(600)
    m = mark()
    for i = 1, 20 do
        I.q.drs[#I.q.drs + 1] = { node = node, blob = C.dr(900, i, 64.0 + i, 64.0, 0.0, 1.0, 0.0, 0.0, 0.0) }
        I.touch()
        R.flush.tickNow()
        stubs.tick(50)
    end
    stubs.tick(2000)
    local function drs(src)
        local list = {}
        for _, o in ipairs(decode(payloads(src, m))) do
            if o.op == 'dr' then list[#list + 1] = o.t end
        end
        return list
    end
    local d1, d3 = drs(1), drs(5)
    check(#d1 >= 9 and #d1 <= 12, ('near ring: ≤ 10 Hz over 1 s (%d DR ops for 20 offered)'):format(#d1))
    eq(d1[#d1], 20, 'near ring: the latest DR arrives in the end')
    eq(R.interest.window(5).cells[cname(0, 0, 0)], 2, 'player 5 (272 m from the cell) has it on its far ring')
    eq(#drs(4), 0, 'a player without the cell gets no DR')
    check(#d3 >= 1 and #d3 <= 3, ('far ring: ≤ 1 Hz (%d DR ops for 20 offered)'):format(#d3))
    eq(d3[#d3], 20, 'far ring: latest wins')
    check(R.flush.stats().drCapped > 0, 'capped ops are counted')
    eq(R.flush.stats().drPending, 0, 'nothing is left pending')

    -- KINDS: the first payload carries the table; a new definition goes to every window as a delta, first
    eq(R.interest.kindsVersion(1), 1, 'each window records the kinds version it got')
    m = mark()
    H.kindsV, H.kindsList = 2, { { idx = 1, id = 'prop', class = 1 }, { idx = 2, id = 'fireworks:battery', class = 7 } }
    R.flush.queue(1, C.unsub(0, 4242), 1)
    stubs.tick(300)
    for src = 1, 5 do
        local o = decode(payloads(src, m))
        eq(o[2] and o[2].op, 'kinds', ('player %d: the KINDS delta comes right after the header'):format(src))
        eq(R.interest.kindsVersion(src), 2, ('player %d: kinds version 2'):format(src))
    end
    eq(find(decode(payloads(1, m)), 'kinds').n, 2, 'with the new table')
    R.interest.setKindsVersion(1, 7)
    eq(R.interest.kindsVersion(1), 7, 'setKindsVersion')
    eq(R.interest.kindsVersion(99), 0, 'an unknown src has version 0')

    -- drop
    leave(1)
    eq(R.interest.window(1), nil, 'a dropped player has no window')
    eq((R.interest.subscribers(0, 0, key(0, 0)) or {})[1], nil, 'nor any subscription')
    R.flush.queue(2, C.unsub(0, 1), 1)
    stubs.tick(300)
    eq(R.flush.stats().clients, 4, 'nor an outbox')
end

do  -- stats and the slow-tick log
    local _, _, R, I = newServer()
    join(1, vector3(64.0, 64.0, 0.0))
    report(1, 64.0, 64.0, 0.0)
    stubs.tick(600)
    local slowNode = { id = 800, bucket = 0, tier = 'S', ver = 1, pos = { x = 64.0, y = 64.0, z = 0.0 },
        cell = { grid = 0, key = key(0, 0) }, audience = { fn = function()
            local t = os.clock() + 0.006
            while os.clock() < t do end
            return true
        end } }
    I.q.gated[1] = { node = slowNode, id = 800, op = 'put', blob = H.Codec.put(800, 1, 1, 0, 32, 0, 0, 0, 0, 0, 0, 10, '') }
    I.touch()
    stubs.tick(300)
    local st = R.flush.stats()
    check(st.ticks > 0, 'ticks are counted')
    check(st.flushMsP50 >= 0 and st.flushMsP99 >= st.flushMsP50, 'p50 ≤ p99')
    check(st.events > 0 and st.bytesOut > 0, 'events and bytes are counted')
    check(st.slowTicks >= 1, 'a tick over 5 ms is counted')
    local logged = false
    for _, line in ipairs(stubs.printed) do
        if line:find('flush tick took', 1, true) then logged = true end
    end
    check(logged, 'and logged')
    local lines = #stubs.printed
    I.q.gated[1] = { node = slowNode, id = 800, op = 'set', blob = H.Codec.set(800, 2, '') }
    I.touch()
    stubs.tick(300)
    local again = 0
    for i = lines + 1, #stubs.printed do
        if stubs.printed[i]:find('flush tick took', 1, true) then again = again + 1 end
    end
    eq(again, 0, 'at most once a minute')
    local ist = R.interest.stats()
    check(ist.windows == 1 and ist.subscribers == 1 and ist.subscriptions > 0 and ist.cells > 0, 'interest stats')
    stubs.tick(12000)
    check(R.flush.stats().bytesPerSecond >= 0, 'bytesPerSecond')
end

do  -- the packed path: msgpack.pack_args + TriggerClientEventInternal(name, src, payload, #payload)
    newServer({ msgpack = true })
    join(1, vector3(0.0, 0.0, 0.0))
    report(1, 0.0, 0.0, 0.0)
    stubs.tick(600)
    check(#internal > 0, 'with msgpack the stream uses TriggerClientEventInternal')
    eq(internal[1].name, 'core:scene:s', 'on core:scene:s')
    eq(internal[1].target, 1, 'to the client')
    eq(internal[1].payload:sub(1, 2), 'MP', 'the payload is msgpack-packed once')
    eq(internal[1].len, #internal[1].payload, 'with its length')
    eq(#payloads(1), 0, 'and TriggerClientEvent is not used')
end

do  -- idle: no natives, no work
    local _, _, _, I = newServer()
    local gt, ec, rt, fp, dr, sent = stubs.gameTimerReads, stubs.entityCoordReads, counters.routing,
        counters.focusPos, I.calls.drain, #stubs.sent
    stubs.tick(10000)
    eq(stubs.gameTimerReads - gt, 0, 'idle: no GetGameTimer in 10 s')
    eq(stubs.entityCoordReads - ec, 0, 'idle: no GetEntityCoords')
    eq(counters.routing - rt + counters.focusPos - fp, 0, 'idle: no player natives')
    eq(I.calls.drain - dr, 0, 'idle: the flush does not even drain')
    eq(#stubs.sent - sent, 0, 'idle: nothing is sent')
end

do  -- core:scene:resync
    local _, _, R, I = newServer()
    local k = key(0, 0)
    I.fill(0, 0, k, 1, 2)
    join(1, vector3(64.0, 64.0, 0.0))
    report(1, 64.0, 64.0, 0.0)
    stubs.tick(600)
    local v1 = R.interest.sent(1, 0, k, 1)
    local e = I.change(0, 0, k, 1, 1)
    stubs.tick(300)
    local function resync(grid, key_, variant, v, wait)
        stubs.tick(wait or 2100)
        local m = mark()
        stubs.triggerOn(H.env, 'core:scene:resync', 1, grid, key_, variant, v)
        stubs.tick(300)
        return decode(payloads(1, m))
    end
    local r0 = R.interest.stats().resyncs
    local ops = resync(0, k, 1, v1)
    local c = find(ops, 'cell')
    eq(c and c.from, v1, 'a resync from a version the journal covers gets the journal')
    eq(c and c.to, e.to, 'up to the current version')
    ops = resync(0, k, 1, 12345)
    c = find(ops, 'cell')
    check(c and c.from == 0 and c.to == e.to, 'from an unknown version: the pack')
    ops = resync(0, k, 1, e.to)
    eq(count(ops, 'cell'), 0, 'from the current version: nothing')
    eq(count(ops, 'sub'), 0, 'not even a SUB (a live cell that is current)')
    local empty = key(1, 1)
    eq(R.interest.sent(1, 0, empty, 1), 0, 'cell (1,1) is subscribed and empty')
    ops = resync(0, empty, 1, 0)
    local sub0 = find(ops, 'sub', function(o) return o.grid == 0 and o.key == empty end)
    check(sub0 ~= nil and sub0.variant == 1 and sub0.v == 0,
        'a pending cell asking with v = 0 while the cell is empty gets SUB(grid, key, variant, 0)')
    eq(count(ops, 'cell', function(o) return o.key == empty end), 0, 'and no content')
    eq(R.interest.sent(1, 0, empty, 1), 0, 'sent stays 0 (empty)')
    I.fill(0, 0, empty, 1, 2)
    ops = resync(0, empty, 1, 0)
    local filled = find(ops, 'cell', function(o) return o.key == empty end)
    check(filled ~= nil and filled.from == 0 and filled.to == I.v['0:0:' .. empty .. ':1'],
        'once the cell has content, v = 0 gets the pack')
    ops = resync(0, key(40, 40), 1, 0)
    eq(#ops, 0, 'a cell that is not subscribed is ignored')
    ops = resync(0, k, 2, 0)
    eq(#ops, 0, 'the other variant is ignored')
    ops = resync(3, k, 1, 0)
    eq(#ops, 0, 'grid 3 fails the schema')
    ops = resync(0, k, 1, -1)
    eq(#ops, 0, 'a negative version fails the schema')
    local before = R.interest.stats().resyncs
    stubs.tick(2100)
    stubs.triggerOn(H.env, 'core:scene:resync', 1, 0, k, 1, 0)
    stubs.tick(1500)
    stubs.triggerOn(H.env, 'core:scene:resync', 1, 0, k, 1, 0)
    eq(R.interest.stats().resyncs, before + 1, 'the same cell again within 2 s is ignored (RV1 F5)')
    stubs.tick(10)
    stubs.triggerOn(H.env, 'core:scene:resync', 1, 0, key(1, 0), 1, 0)
    eq(R.interest.stats().resyncs, before + 1, 'any resync within 62 ms of the last is dropped (≤ 16/s)')
    check(R.interest.stats().resyncs > r0, 'resyncs are counted')
end

--------------------------------------------------------------------------------
-- 15. RV1 F16 / F15 / F2: PRIV(n) counts ops; DELs reach what was published; a gated unit's child's events
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer()
    local C = H.Codec
    join(1, vector3(64.0, 64.0, 0.0))
    join(2, vector3(80.0, 64.0, 0.0))
    report(1, 64.0, 64.0, 0.0, 0, 0, 0, nil, true)
    report(2, 80.0, 64.0, 0.0, 0, 0, 0, nil, true)
    stubs.tick(400)
    local function unit(id, audience, nkids, extra)
        local head = gnode(id, audience)
        head.kids, head.extraBytes = {}, extra
        H.nodes[id] = head
        for i = 1, nkids or 0 do
            local kid = { id = id + i, ver = 1, up = head, pos = head.pos }
            head.kids[i], H.nodes[kid.id] = kid, kid
        end
        return head
    end
    local stash = unit(610, { players = { 1 } }, 2)
    local sign = unit(620, { players = { 1 } })
    local m = mark()
    gatedOp(stash, 'put')
    gatedOp(sign, 'put')
    stubs.tick(300)
    local ops = decode(payloads(1, m))
    eq(count(ops, 'put', function(o) return o.section == 'priv' end), 4,
        'F16: a unit with two children and a second unit all decode inside PRIV')
    eq(count(ops, 'put', function(o) return o.section ~= 'priv' end), 0, 'F16: no loose PUT')
    eq(find(ops, 'priv').n, 4, 'F16: PRIV(n) counts ops, not blobs')
    eq(R.interest.holders(611)[1], 610, 'children are published with their head')
    eq(#payloads(2, m), 0, 'player 2 (not in the audience) gets nothing')
    check(R.interest.allows(stash.kids[1], 1) and not R.interest.allows(stash.kids[1], 2),
        'F2: a child answers with its unit\'s effective audience')

    local big = unit(630, { players = { 1 } }, 400, 100)
    m = mark()
    gatedOp(big, 'put')
    stubs.tick(2000)
    local list, longest = payloads(1, m), 0
    for _, p in ipairs(list) do longest = math.max(longest, #p) end
    check(#list >= 4 and longest <= 16384, ('F16: a %d-op unit of ~57 KB is cut at op boundaries (%d events, longest %d B)')
        :format(401, #list, longest))
    ops = decode(list)
    eq(count(ops, 'put', function(o) return o.section == 'priv' end), 401, 'F16: every one of its PUTs inside PRIV')
    local sections = 0
    for _, o in ipairs(ops) do if o.op == 'priv' then sections = sections + o.n end end
    eq(sections, 401, 'F16: the sections\' counts add up to the ops')

    -- F2: an event of a child of a gated unit reaches the unit's holders only
    m = mark()
    local t = stubs.now() & 0xFFFFFFFF
    I.q.events[1] = { bucket = 0, grid = 0, key = key(0, 0), x = 64.0, y = 64.0, z = 0.0, radius = 50, horizonMs = 1000,
        t = t, blob = C.event(611, t, 64.0, 64.0, 0.0, 'opened', ''), node = stash.kids[1] }
    I.touch()
    stubs.tick(300)
    eq(count(decode(payloads(1, m)), 'event'), 1, 'F2: the child\'s event reaches the unit\'s holder')
    eq(count(decode(payloads(2, m)), 'event'), 0, 'F2: and not the player standing next to it')

    -- F15 (A): the unit is re-parented under a public root far away: the DEL item names the NEW (public) root
    m = mark()
    local public = { id = 699, bucket = 0, ver = 1, pos = { x = 3000.0, y = 3000.0, z = 0.0 } }
    I.q.gated[#I.q.gated + 1] = { node = public, id = 610, op = 'del', blob = C.del(610, 5, 1), n = 1 }
    I.touch()
    stubs.tick(300)
    local got = privSince(m, { 1 })[1]
    check(got:find('del:610', 1, true) ~= nil, 'F15 (A): the re-parented unit\'s DEL reaches its holder')
    check(got:find('del:611', 1, true) ~= nil and got:find('del:612', 1, true) ~= nil,
        'F15 (A): and so do DELs for what it still held of the unit (children)')
    eq(R.interest.holders(610), nil, 'F15 (A): nothing of it is held any more')
    eq(R.interest.holders(611), nil, 'F15 (A): (children too)')

    -- F15 (B): a unit with a child becomes public: the head's DEL, then the child's DEL (node = the head)
    local reveal = unit(640, { players = { 1 } }, 1)
    gatedOp(reveal, 'put')
    stubs.tick(300)
    m = mark()
    I.q.gated[#I.q.gated + 1] = { node = reveal, id = 640, op = 'del', blob = C.del(640, 6, 1), n = 1, public = true }
    I.q.gated[#I.q.gated + 1] = { node = reveal, id = 641, op = 'del', blob = C.del(641, 6, 1), n = 1, public = true }
    I.touch()
    stubs.tick(300)
    got = privSince(m, { 1 })[1]
    check(got:find('del:640', 1, true) ~= nil and got:find('del:641', 1, true) ~= nil,
        'F15 (B): revealing a unit DELs its head and its child for the holder')
    eq(R.interest.holders(641), nil, 'F15 (B): the child is no longer held')

    -- F15 (C): a child is detached: its DEL item names the child itself (now its own public root)
    local host = unit(650, { players = { 1 } }, 1)
    gatedOp(host, 'put')
    stubs.tick(300)
    m = mark()
    local detached = host.kids[1]
    detached.up = nil
    I.q.gated[#I.q.gated + 1] = { node = detached, id = 651, op = 'del', blob = C.del(651, 7, 1), n = 1, public = true }
    I.touch()
    stubs.tick(300)
    eq(privSince(m, { 1 })[1], 'del:651', 'F15 (C): the detached child\'s DEL reaches the unit\'s holder')
    eq(R.interest.holders(650)[1], 650, 'F15 (C): the head stays held')

    -- F15 (D): a holder leaves the audience: every node published with the unit gets its DEL, not just the head
    local vault = unit(660, { players = { 1 } }, 2)
    gatedOp(vault, 'put')
    stubs.tick(300)
    m = mark()
    vault.audience = { players = { 2 } }
    gatedOp(vault, 'set', C.set(660, 8, ''))
    stubs.tick(300)
    got = privSince(m, { 1, 2 })
    check(got[1]:find('del:660', 1, true) and got[1]:find('del:661', 1, true) and got[1]:find('del:662', 1, true),
        'F15 (D): a revoke DELs the head and every child published with it')
    eq(got[2], 'put:660,put:661,put:662', 'F15 (D): the new audience member gets the whole unit')
end

--------------------------------------------------------------------------------
-- 16. RV1 F17 / F18: a bucket change purges the old bucket's queued content and starts with RESET
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer({ scene = { MaxEventBytes = 4096 } })
    local k = key(0, 0)
    I.fill(1, 0, k, 1, 3)
    I.fill(0, 0, k, 1, 1)
    join(1, vector3(64.0, 64.0, 0.0), 1)
    report(1, 64.0, 64.0, 0.0, 0, 0, 0, nil, true)
    local m = mark()
    stubs.tick(1)                                     -- one tick: SUB out, the bucket-1 pack now waits reliable
    check(R.flush.backlog(1) > 0, 'the old bucket\'s pack waits in the reliable queue')
    stubs.buckets[1] = 0
    stubs.triggerOn(H.env, 'onPlayerBucketChange', 0, '1', 0, 1)
    eq(R.flush.backlog(1) <= 11 * 200, true, 'the reset purged every queued old-bucket item')
    local m2 = mark()
    stubs.tick(300)
    local after = decode(payloads(1, m2))
    eq(after[2] and after[2].op, 'reset', 'F17: the next event starts with RESET')
    eq(count(after, 'cell', function(o) return o.key == k and o.to == I.v['1:0:' .. k .. ':1'] end), 0,
        'F17: the old bucket\'s queued pack never goes out')
    eq(count(after, 'cell', function(o) return o.key == k and o.to == I.v['0:0:' .. k .. ':1'] end), 1,
        'F17: the new bucket\'s pack does')
    eq(R.flush.stats().resets, 1, 'counted')
    local before = decode(payloads(1, m))
    eq(count(before, 'reset'), 1, 'exactly one RESET in all')

    -- the raw native, noticed only at the next focus report (no engine event, no client event): RESET as well
    local m3 = mark()
    stubs.buckets[1] = 7
    report(1, 64.0, 64.0, 0.0)
    stubs.tick(300)
    local ops = decode(payloads(1, m3))
    eq(R.interest.bucketOf(1), 7, 'F18: the report reads the new bucket')
    eq(ops[2] and ops[2].op, 'reset', 'F18: RESET first in the next event')

    -- a latent pack still waiting for the budget is dropped with the old bucket
    local _, _, R2, I2 = newServer({ scene = { MaxEventBytes = 4096, PackBudgetBytes = 20000, PackBudgetWindowMs = 100000 } })
    I2.fill(1, 0, key(0, 0), 1, 1, string.rep('y', 15000))
    I2.fill(1, 0, key(1, 0), 1, 1, string.rep('z', 15000))
    join(1, vector3(64.0, 64.0, 0.0), 1)
    local _, lm = mark()
    report(1, 64.0, 64.0, 0.0, 0, 0, 0, nil, true)
    stubs.tick(300)
    eq(#latents(1, lm), 1, 'one bucket-1 pack out, one waiting for the budget')
    stubs.buckets[1] = 0
    stubs.triggerOn(H.env, 'onPlayerBucketChange', 0, '1', 0, 1)
    stubs.tick(3000)
    eq(#latents(1, lm), 1, 'the waiting bucket-1 pack is dropped by the reset')
    eq(R2.flush.stats().packsWaiting, 0, 'nothing waits')
end

--------------------------------------------------------------------------------
-- 17. RV1 F4: an audience fn that yields never suspends the flush
--------------------------------------------------------------------------------
do
    local env, _, R, I = newServer()
    join(1, vector3(64.0, 64.0, 0.0))
    join(3, vector3(2000.0, 2000.0, 0.0))
    report(1, 64.0, 64.0, 0.0, 0, 0, 0, nil, true)
    report(3, 2000.0, 2000.0, 0.0, 0, 0, 0, nil, true)
    stubs.tick(400)
    local calls = 0
    local door = gnode(700, { fn = setmetatable({}, { __call = function()
        calls = calls + 1
        env.Wait(1000)                                -- a DB await in the plugin
        return true
    end }) })
    H.nodes[700] = door
    gatedOp(door, 'put')
    stubs.tick(300)
    check(calls >= 1, 'the fn ran')
    local m = mark()
    gatedOp(door, 'set', H.Codec.set(700, 2, ''))
    local e = I.change(0, 0, key(15, 15), 1, 1)
    stubs.tick(100)
    local c = find(decode(payloads(3, m)), 'cell', function(o) return o.key == key(15, 15) end)
    eq(c and c.to, e.to, 'F4: an unrelated player\'s update is not held up by a yielding audience fn')
    eq(privSince(m, { 1 })[1], '', 'F4: a yielding fn counts as not allowed')
    check(R.interest.stats().fnYield >= 2, 'F4: every yield is counted')
    local lines = 0
    for _, line in ipairs(stubs.printed) do
        if line:find('yielded', 1, true) then lines = lines + 1 end
    end
    eq(lines, 1, 'F4: and logged once per owner')
    local ok = gnode(701, { fn = function(src) return src == 1 end })
    check(R.interest.allows(ok, 1) and not R.interest.allows(ok, 3), 'a synchronous fn still decides')
end

--------------------------------------------------------------------------------
-- 18. RV1 F7: `near` audiences are re-checked for the window's own cells, never the whole bucket
--------------------------------------------------------------------------------
do
    local _, _, R = newServer()
    join(1, vector3(9000.0, 9000.0, 0.0))
    report(1, 9000.0, 9000.0, 0.0, 0, 0, 0, nil, true)
    stubs.tick(300)
    for i = 1, 300 do
        gatedOp(gnode(800 + i, { near = 30 }, { pos = vector3(-4000.0 + i * 20.0, 0.0, 0.0) }), 'put')
    end
    stubs.tick(300)
    local allows, calls = R.interest.allows, 0
    R.interest.allows = function(...)
        calls = calls + 1
        return allows(...)
    end
    R.interest.syncWindow(R.interest.windowOf(1), true)
    eq(calls, 0, 'F7: a player far from every near-gated node evaluates none of the 300')
    join(2, vector3(-3800.0, 0.0, 0.0))
    report(2, -3800.0, 0.0, 0.0, 0, 0, 0, nil, true)
    calls = 0
    R.interest.syncWindow(R.interest.windowOf(2), true)
    check(calls > 0 and calls <= 60, ('F7: a player among them evaluates only those in its window (%d of 300)'):format(calls))
    R.interest.allows = allows
end

--------------------------------------------------------------------------------
-- 19. RV1 F5: resync answers spend the pack budget (no amplification)
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer({ scene = { PackBudgetBytes = 20000, PackBudgetWindowMs = 100000 } })
    local k = key(0, 0)
    I.fill(0, 0, k, 1, 1)
    join(1, vector3(64.0, 64.0, 0.0))
    report(1, 64.0, 64.0, 0.0, 0, 0, 0, nil, true)
    stubs.tick(300)
    local v0 = R.interest.sent(1, 0, k, 1)
    for _ = 1, 12 do
        I.change(0, 0, k, 1, 1, string.rep('x', 1000))
        stubs.tick(50)
    end
    stubs.tick(300)
    local journal = I.since(0, 0, k, 1, v0)
    check(#journal > 12000 and #journal <= 16384, ('a journal of %d bytes fits one event'):format(#journal))
    local m, lm = mark()
    for _ = 1, 10 do
        stubs.tick(2100)
        stubs.triggerOn(H.env, 'core:scene:resync', 1, 0, k, 1, v0)
    end
    stubs.tick(500)
    local bytes = 0
    for _, p in ipairs(payloads(1, m)) do bytes = bytes + #p end
    for _, p in ipairs(latents(1, lm)) do bytes = bytes + #p end
    check(bytes < 2 * #journal + 12000, ('F5: ten old-version resyncs of a %d-byte journal cost %d bytes (was 10 × the journal)')
        :format(#journal, bytes))
    check(R.flush.stats().withheld > 0, 'F5: a journal answer past the budget is refused (the small pack serves)')
end

--------------------------------------------------------------------------------
-- 20. RV1 F9: an entry larger than MaxEventBytes goes as SUB + a latent pack, never as one giant event
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer()
    for src = 1, 3 do
        join(src, vector3(64.0, 64.0, 0.0))
        report(src, 64.0, 64.0, 0.0, 0, 0, 0, nil, true)
    end
    stubs.tick(400)
    local m, lm = mark()
    local e = I.change(0, 0, key(0, 0), 1, 200, string.rep('b', 100))
    check(#e.blob > 16384, ('the entry is %d bytes'):format(#e.blob))
    stubs.tick(300)
    for src = 1, 3 do
        local longest = 0
        for _, p in ipairs(payloads(src, m)) do longest = math.max(longest, #p) end
        check(longest <= 16384, ('F9: player %d: no reliable event over MaxEventBytes (longest %d)'):format(src, longest))
        local sub = find(decode(payloads(src, m)), 'sub', function(o) return o.grid == 0 and o.key == key(0, 0) end)
        eq(sub and sub.v, e.to, ('F9: player %d: SUB of the new version'):format(src))
        local lops = decode(latents(src, lm))
        local cell = find(lops, 'cell', function(o) return o.key == key(0, 0) end)
        check(cell ~= nil and cell.from == 0 and cell.to == e.to, ('F9: player %d: the pack, latent'):format(src))
        eq(R.interest.sent(src, 0, key(0, 0), 1), e.to, ('F9: player %d: sent = to'):format(src))
    end
    eq(R.flush.stats().bigEntries, 3, 'F9: counted')
    eq(R.flush.stats().oversized, 0, 'F9: nothing oversized went reliable')
end

--------------------------------------------------------------------------------
-- 21. RV1 F14: a big gated set never trips the backlog guard, and control ops do not wait behind it
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer()
    join(1, vector3(64.0, 64.0, 0.0))
    report(1, 64.0, 64.0, 0.0, 0, 0, 0, nil, true)
    stubs.tick(400)
    for i = 1, 400 do
        local head = gnode(3000 + i, { players = { 1 } })
        head.extraBytes = 1000
        gatedOp(head, 'put')
    end
    stubs.tick(60)
    check(R.flush.backlog(1) > 262144, ('a PRIV backlog of %d bytes'):format(R.flush.backlog(1)))
    local m = mark()
    movePed(1, vector3(900.0, 64.0, 0.0))
    report(1, 900.0, 64.0, 0.0, 0, 0, 0, nil, true)
    stubs.tick(60)
    local ops = decode(payloads(1, m))
    check(count(ops, 'sub') > 0 and R.flush.backlog(1) > 0, 'F14: new SUBs go out while the PRIV bulk still drains')
    for _ = 1, 60 do stubs.tick(50) end
    eq(R.flush.stats().overflows, 0, 'F14: the backlog guard never fired')
    eq(R.flush.stats().dropped, 0, 'F14: nothing was dropped')
    I.touch()
end

--------------------------------------------------------------------------------
-- 22–24. RV1 F11 (no window without a session), F21 (no per-src leftovers), F22 (a global regate is sliced)
--------------------------------------------------------------------------------
do
    local _, _, R = newServer()
    eq(R.interest.pin(777, 64.0, 64.0, 0.0), false, 'F11: a pin for a src that is not connected is refused')
    eq(R.interest.prefetch(777, 64.0, 64.0, 0.0), false, 'F11: so is a prefetch')
    eq(R.interest.windowOf(777), nil, 'F11: and no window exists for it')
    join(5, vector3(0.0, 0.0, 0.0))
    eq(R.interest.pin(5, 64.0, 64.0, 0.0), true, 'a loaded player can be pinned')
    stubs.connectPlayer(H.env, 6, { coords = vector3(0.0, 0.0, 0.0) })   -- connected, no session yet (a login screen)
    eq(R.interest.pin(6, 64.0, 64.0, 0.0), true, 'F11: so can a connected player without a session')
    check(R.interest.windowOf(6) ~= nil, 'F11: which gets a window')
    stubs.dropPlayer(H.env, 6)
    eq(R.interest.windowOf(6), nil, 'F11: that the engine\'s playerDropped removes')

    join(1, vector3(64.0, 64.0, 0.0))
    report(1, 64.0, 64.0, 0.0, 0, 0, 0, nil, true)
    stubs.tick(300)
    local g = gnode(900, { players = { 1 } })
    H.nodes[900] = g
    gatedOp(g, 'put')
    stubs.tick(300)
    local st = R.interest.gatedStats()
    check(st.gatedHolders >= 1 and st.seenSrcs >= 1, 'player 1 holds a gated node and has a per-src mark')
    leave(1)
    st = R.interest.gatedStats()
    eq(st.gatedHolders, 0, 'F21: a dropped player holds nothing')
    eq(st.seenSrcs, 0, 'F21: and leaves no per-src mark behind')

    local _, _, R3 = newServer()
    for src = 1, 200 do
        join(src, vector3((src % 20) * 300.0, (src // 20) * 300.0, 0.0))
        report(src, (src % 20) * 300.0, (src // 20) * 300.0, 0.0, 0, 0, 0, nil, true)
    end
    stubs.tick(600)
    local r0 = R3.interest.gatedStats().regates
    H.Core.emitHook('permsChanged', nil, 'saveGroup', 'police')
    local now = R3.interest.gatedStats().regates - r0
    check(now > 0 and now <= 50, ('F22: a global permsChanged re-gates at most one slice per frame (%d now)'):format(now))
    stubs.tick(300)
    eq(R3.interest.gatedStats().regates - r0, 200, 'F22: every window within a few frames')
end

--------------------------------------------------------------------------------
-- 12. End to end on the real stack: scene_kinds → scene_index → interest → flush → scene_store → scene
--------------------------------------------------------------------------------

local function newRealServer(scene)
    local env = isolatedEnv(false)
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    for k, v in pairs(scene or {}) do env.Config.Scene[k] = v end
    stubs.loadFile(env, 'shared/scene_codec.lua')
    stubs.loadFile(env, 'shared/scene_motion.lua')
    stubs.loadFile(env, 'server/api.lua')
    stubs.loadFile(env, 'shared/hooks.lua')
    stubs.loadFile(env, 'server/db.lua')
    local Core = env.Core
    Core.Perms = { has = function(src, perm) return H.perms[src .. '|' .. perm] == true end }
    Core.Player = {
        isLoaded = function(src) return H.loaded[src] == true end,
        getPlayers = function()
            local out = {}
            for src in pairs(H.loaded) do out[#out + 1] = src end
            table.sort(out)
            return out
        end,
        getData = function() return nil end,
    }
    stubs.loadFile(env, 'server/playergrid.lua')
    for _, file in ipairs({ 'server/scene_kinds.lua', 'server/scene_index.lua', 'server/scene_interest.lua',
        'server/scene_gated.lua', 'server/scene_flush.lua', 'server/scene_store.lua', 'server/scene.lua' }) do
        stubs.loadFile(env, file)
    end
    env.TriggerEvent('onResourceStart', 'core')
    stubs.tick(0)
    local R = Core.SceneRuntime
    H.env, H.Core, H.R, H.I, H.Codec = env, Core, R, R.index, Core.SceneCodec
    return env, Core, R
end

do
    local _, Core, R = newRealServer()
    local Scene = Core.Scene
    check(R.interest and R.flush and R.store, 'the real stack loads in manifest order')
    join(1, vector3(64.0, 64.0, 30.0))
    local id = Scene.spawn({ kind = 'prop', pos = vector3(70.0, 70.0, 30.0), model = 'prop_bench_01a' })
    check(id ~= nil, 'a prop spawns')
    local m = mark()
    report(1, 64.0, 64.0, 30.0)
    stubs.tick(600)
    local ops, bad = decode(payloads(1, m))
    eq(bad, 0, 'every payload of the real stack decodes')
    local k = R.index.keyOf(0, 70.0, 70.0)
    local cell = find(ops, 'cell', function(o) return o.grid == 0 and o.key == k end)
    eq(cell and cell.from, 0, 'the subscriber gets its cell as a snapshot')
    eq(count(ops, 'put', function(o) return o.id == id and o.section == 'cell' end), 1, 'holding the prop')
    eq(find(ops, 'sub', function(o) return o.grid == 0 and o.key == k end).v, cell and cell.to, 'SUB = snapshot version')
    eq(R.interest.sent(1, 0, k, 1), cell and cell.to, 'sent = that version')
    check(find(ops, 'kinds') ~= nil and select(2, find(ops, 'kinds')) < select(2, find(ops, 'sub')),
        'the kinds table comes first')

    m = mark()
    check(Scene.set(id, { tint = 3 }), 'a field change')
    stubs.tick(600)
    ops = decode(payloads(1, m))
    local c2 = find(ops, 'cell', function(o) return o.grid == 0 and o.key == k end)
    eq(c2 and c2.from, cell and cell.to, 'arrives as the entry from the version the client has')
    check(c2 and c2.to > c2.from, 'to a newer one')
    check(find(ops, 'set', function(o) return o.id == id end) ~= nil or find(ops, 'put', function(o) return o.id == id end) ~= nil,
        'with the node op')
    eq(R.interest.sent(1, 0, k, 1), c2 and c2.to, 'sent follows')

    m = mark()
    local gid = Scene.spawn({ kind = 'prop', pos = vector3(60.0, 60.0, 30.0), model = 'prop_bench_01a',
        audience = { players = { 1 } } })
    check(gid ~= nil, 'a gated prop spawns')
    join(2, vector3(80.0, 60.0, 30.0))
    report(2, 80.0, 60.0, 30.0, 0, 0, 0, nil, true)
    stubs.tick(600)
    ops = decode(payloads(1, m))
    local gp = find(ops, 'put', function(o) return o.id == gid end)
    eq(gp and gp.section, 'priv', 'the gated prop reaches its audience in a PRIV section')
    eq(gp and gp.flags & 32, 32, 'flagged GATED')
    eq(count(decode(payloads(2, m)), 'put', function(o) return o.id == gid end), 0, 'and nobody else')
    eq(count(decode(payloads(2, m)), 'put', function(o) return o.id == id end), 1, 'the second player gets the public prop')

    m = mark()
    Scene.emit(id, 'boom', { power = 2 }, { radius = 40 })
    stubs.tick(600)
    eq(count(decode(payloads(1, m)), 'event', function(o) return o.name == 'boom' end), 1, 'an event reaches the player 8 m away')

    m = mark()
    check(Scene.remove(id), 'remove')
    stubs.tick(600)
    ops = decode(payloads(1, m))
    eq(count(ops, 'del', function(o) return o.id == id and o.section == 'cell' end), 1, 'a removal arrives as a DEL in the cell')
    check(R.flush.stats().entries > 0 and R.index.stats().entries > 0, 'entries flowed through the real index')
    leave(1)
    leave(2)
    stubs.tick(6000)
    eq(R.interest.stats().windows, 0, 'drops leave no window behind')
end

--------------------------------------------------------------------------------
-- 13. Join-storm safeguards: the fill budget resumes next tick; the per-tick pack byte cap rotates clients
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer()
    for cx = -1, 1 do
        for cy = -1, 1 do I.fill(0, 0, key(cx, cy), 1, 1) end
    end
    join(1, vector3(64.0, 64.0, 0.0))
    report(1, 64.0, 64.0, 0.0, 0, 0, 0, nil, true)
    local n = R.interest.window(1).n
    local asks = 0
    eq(R.interest.fill(function() asks = asks + 1 return true end), false, 'a fill over its budget stops early')
    eq(asks, 1, 'the budget is asked after every cell (RV1 F12)')
    local pending = 0
    for _, v in pairs(R.interest.window(1).sent) do
        if v == -1 then pending = pending + 1 end
    end
    eq(pending, n - 1, 'one cell was filled, the rest still pending')
    asks = 0
    eq(R.interest.fill(function() asks = asks + 1 return asks >= 3 end), false, 'the next fill stops after three')
    pending = 0
    for _, v in pairs(R.interest.window(1).sent) do
        if v == -1 then pending = pending + 1 end
    end
    eq(pending, n - 4, 'where the first one stopped')
    eq(R.interest.fill(), true, 'the next fill finishes')
    pending = 0
    for _, v in pairs(R.interest.window(1).sent) do
        if v == -1 then pending = pending + 1 end
    end
    eq(pending, 0, 'nothing is pending any more')
    local m = mark()
    stubs.tick(300)
    local ops = decode(payloads(1, m))
    eq(count(ops, 'sub'), n, 'every subscription got exactly one SUB')
    eq(count(ops, 'cell', function(o) return o.from == 0 end), 9, 'and the nine packs')
end

do  -- the budget also holds between windows: a window finished at the limit leaves the next ones for later
    local _, _, R = newServer()
    for src = 1, 3 do
        join(src, vector3(64.0 + src, 64.0, 0.0))
        report(src, 64.0 + src, 64.0, 0.0, 0, 0, 0, nil, true)
    end
    local function pendingOf(src)
        local c = 0
        for _, v in pairs(R.interest.window(src).sent) do
            if v == -1 then c = c + 1 end
        end
        return c
    end
    local n1, asks = R.interest.window(1).n, 0
    eq(R.interest.fill(function() asks = asks + 1 return asks >= n1 end), false,
        'a fill that reaches its limit on the last cell of a window stops there')
    check(pendingOf(1) == 0 and pendingOf(2) == R.interest.window(2).n and pendingOf(3) == R.interest.window(3).n,
        'the first window is done, the other two wait whole')
    eq(R.interest.fill(), true, 'the next fill finishes both')
    eq(pendingOf(2) + pendingOf(3), 0, 'nothing is pending any more')
    for src = 1, 3 do leave(src) end
    stubs.tick(6000)
end

do
    local _, _, R, I = newServer()
    I.fill(0, 0, key(0, 0), 1, 1, string.rep('y', 60000))
    for src = 1, 25 do
        join(src, vector3(64.0, 64.0, 0.0))
        report(src, 64.0, 64.0, 0.0, 0, 0, 0, nil, true)
    end
    local _, lm = mark()
    R.flush.tickNow()
    local first = #latent - lm
    eq(first, 17, '25 × 60 KB of packs: the first tick releases 1 MiB (17 packs)')
    local got = {}
    for i = lm + 1, #latent do got[latent[i].target] = true end
    R.flush.tickNow()
    local second = #latent - lm - first
    eq(second, 8, 'the other 8 go in the next tick')
    for i = lm + first + 1, #latent do
        check(not got[latent[i].target], ('client %d gets its pack once'):format(latent[i].target))
        got[latent[i].target] = true
    end
    eq(nkeys(got), 25, 'every client got its pack')
    for src = 1, 25 do eq(R.flush.backlog(src), 0, ('client %d has nothing left'):format(src)) end
end

--------------------------------------------------------------------------------
-- 14. The flush thread exists only while there is work: wake / queue start it, it ends after the last work
--------------------------------------------------------------------------------
do
    local _, _, R, I = newServer()
    eq(R.flush.stats().running, false, 'no flush thread at load')
    local gt, drains = stubs.gameTimerReads, I.calls.drain
    stubs.tick(3000)
    eq(stubs.gameTimerReads - gt, 0, 'nothing runs before the first work')
    R.flush.wake()
    eq(R.flush.stats().running, true, 'wake() starts the thread')
    eq(I.calls.drain, drains, 'which waits a frame before its first tick (never inside the caller)')
    stubs.tick(100)
    eq(I.calls.drain, drains + 1, 'one tick')
    eq(R.flush.stats().running, false, 'then it ends: nothing is pending')
    stubs.connectPlayer(H.env, 7, { coords = vector3(0.0, 0.0, 0.0) })
    local m = mark()
    R.flush.queue(7, H.Codec.unsub(0, 77), 1)
    eq(R.flush.stats().running, true, 'a queued item starts it')
    stubs.tick(300)
    eq(#payloads(7, m), 1, 'the item went out')
    eq(R.flush.stats().running, false, 'and the thread ended after the last work')
    gt, drains = stubs.gameTimerReads, I.calls.drain
    stubs.tick(5000)
    eq(stubs.gameTimerReads - gt, 0, 'no natives per second after the last work')
    eq(I.calls.drain - drains, 0, 'no drains either (no polling)')
    I.change(0, 0, key(0, 0), 1, 1)
    eq(R.flush.stats().running, true, 'the index waking the flush starts it')
    stubs.tick(300)
    eq(I.calls.drain, drains + 1, 'which drains the change')
    eq(R.flush.stats().running, false, 'and ends again')
end

--------------------------------------------------------------------------------
-- 25. RV1 on the real stack, delivered into REAL client caches (client/scene_cache.lua): F16, F15, F1/F2, F17,
--     F18, F9 — the reviewer's demos d13, d12, d1, d14, d15 and d8 as regressions
--------------------------------------------------------------------------------

--- Real client caches for `srcs`, fed from the server's sends in send order at each pump — like the network,
--- never inside the server's own call; their resync requests reach the server as that player at the next pump.
--- @return clients { [src] = { C, env, at } }, advance(ms, step) (ticks in steps and pumps after each)
local function liveClients(env, srcs)
    local clients, queue, qh, qt = {}, {}, 1, 0
    local function live() return H.env == env end
    local function push(e) qt = qt + 1; queue[qt] = e end
    for _, src in ipairs(srcs) do
        local at = { x = 0.0, y = 0.0 }
        local cenv, C = clientCache(at, function(name, ...)
            if name == 'core:scene:resync' then push({ env, name, src, table.pack(...) }) end
        end)
        clients[src] = { C = C, env = cenv, at = at }
    end
    local tce, tlce = env.TriggerClientEvent, env.TriggerLatentClientEvent
    env.TriggerClientEvent = function(name, target, ...)
        tce(name, target, ...)
        local c = live() and clients[target]
        if c and (name == 'core:scene:s' or name == 'core:client:bucketChanged') then
            push({ c.env, name, 65535, table.pack(...) })
        end
    end
    env.TriggerLatentClientEvent = function(name, target, bps, payload)
        tlce(name, target, bps, payload)
        local c = live() and clients[target]
        if c and name == 'core:scene:p' then push({ c.env, name, 65535, table.pack(payload) }) end
    end
    local function pump()
        while qh <= qt do
            local q = queue[qh]
            queue[qh] = nil
            qh = qh + 1
            if live() then stubs.triggerOn(q[1], q[2], q[3], table.unpack(q[4], 1, q[4].n)) end
        end
    end
    local function advance(ms, step)
        step = step or 50
        pump()
        local t = 0
        while t < ms do
            local d = math.min(step, ms - t)
            stubs.tick(d)
            t = t + d
            pump()
        end
    end
    return clients, advance
end

local function heldBy(C, id)
    local n = id and C.cache.node(id)
    return n ~= nil and C.cache.wanted(n), n
end

do  -- F16 (d13): every op of a grant sits inside its PRIV section; the client holds every gated node
    local env, Core = newRealServer()
    local Scene = Core.Scene
    local cl, advance = liveClients(env, { 1 })
    join(1, vector3(3000.0, 3000.0, 30.0))
    report(1, 3000.0, 3000.0, 30.0)
    local stash = Scene.spawn({ kind = 'prop', pos = vector3(70.0, 70.0, 30.0), model = 'prop_stash',
        audience = { players = { 1 } } })
    local lid = Scene.spawn({ kind = 'prop', parent = stash, model = 'prop_lid', offset = { x = 0.0, y = 0.0, z = 1.0 } })
    local lock = Scene.spawn({ kind = 'prop', parent = stash, model = 'prop_lock', offset = { x = 0.5, y = 0.0, z = 0.5 } })
    local sign = Scene.spawn({ kind = 'prop', pos = vector3(72.0, 70.0, 30.0), model = 'prop_sign',
        audience = { players = { 1 } } })
    local asrc = Scene.spawn({ kind = 'audio.source', fields = { type = 'loop', file = '@core/sounds/radio.ogg' } })
    local radio = asrc and Scene.spawn({ kind = 'audio', pos = vector3(75.0, 70.0, 30.0),
        fields = { source = asrc, range = 30 }, audience = { players = { 1 } } })
    advance(600)
    local m = mark()
    movePed(1, vector3(64.0, 64.0, 30.0))
    report(1, 64.0, 64.0, 30.0)
    advance(2000)
    local ops, bad = decode(payloads(1, m))
    eq(bad, 0, 'F16 real: every payload decodes')
    eq(count(ops, 'put', function(o) return o.section == 'none' end), 0, 'F16 real: no PUT outside a section')
    eq(count(ops, 'del', function(o) return o.section == 'none' end), 0, 'F16 real: no DEL outside a section')
    local C = cl[1].C
    local all = true
    for _, id in ipairs({ stash, lid, lock, sign, radio }) do
        local wanted, n = heldBy(C, id)
        all = all and wanted and n.priv == true
    end
    check(all, 'F16 real: the client holds stash, lid, lock, sign and radio privately')
    check(asrc ~= nil and C.cache.node(asrc) ~= nil, 'F16 real: with the radio\'s audio source as a dependency')
end

do  -- F15 (d12): DELs reach what was PUBLISHED — re-parent, reveal + remove, detach, a non-audience bystander
    local env, Core, R = newRealServer()
    local Scene = Core.Scene
    local cl, advance = liveClients(env, { 1, 2 })
    join(1, vector3(64.0, 64.0, 30.0))
    join(2, vector3(66.0, 64.0, 30.0))
    report(1, 64.0, 64.0, 30.0)
    report(2, 66.0, 64.0, 30.0)
    advance(600)
    local C1, C2 = cl[1].C, cl[2].C
    -- A: a held gated root re-parented under a public root 4 km away
    local g = Scene.spawn({ kind = 'prop', pos = vector3(70.0, 70.0, 30.0), model = 'prop_safe',
        audience = { players = { 1 } } })
    local far = Scene.spawn({ kind = 'prop', pos = vector3(3000.0, 3000.0, 30.0), model = 'prop_bench_01a' })
    advance(600)
    check(heldBy(C1, g) and C1.cache.node(g).priv == true, 'F15 A real: the audience member holds the gated root')
    eq(C2.cache.node(g), nil, 'F15 A real: the bystander never gets it')
    Scene.attach(g, { node = far })
    advance(3000)
    eq(C1.cache.node(g), nil, 'F15 A real: re-parented far away, it is gone from the client')
    eq((R.interest.holders(g) or {})[1], nil, 'F15 A real: and from the server\'s holders')
    -- B: a gated root with a child made public, the child removed later
    local r = Scene.spawn({ kind = 'prop', pos = vector3(70.0, 60.0, 30.0), model = 'prop_safe',
        audience = { players = { 1 } } })
    local k = Scene.spawn({ kind = 'prop', parent = r, model = 'prop_lid', offset = { x = 0.0, y = 0.0, z = 1.0 } })
    advance(600)
    check(heldBy(C1, r) and heldBy(C1, k), 'F15 B real: root and child held privately')
    Scene.set(r, nil, { audience = false })
    advance(600)
    local _, nr = heldBy(C1, r)
    local wk, nk = heldBy(C1, k)
    check(heldBy(C1, r) and wk and not nr.priv and not nk.priv, 'F15 B real: made public, both are held by the cell')
    check(heldBy(C2, r) and heldBy(C2, k), 'F15 B real: the bystander gets both through the cell')
    Scene.remove(k)
    advance(3000)
    eq(C1.cache.node(k), nil, 'F15 B real: the removed child is gone for the former holder')
    eq(C2.cache.node(k), nil, 'F15 B real: and for the bystander')
    check(heldBy(C1, r), 'F15 B real: the root stays')
    -- C: a child of a gated root detached: public in its own right
    local r2 = Scene.spawn({ kind = 'prop', pos = vector3(60.0, 70.0, 30.0), model = 'prop_safe',
        audience = { players = { 1 } } })
    local k2 = Scene.spawn({ kind = 'prop', parent = r2, model = 'prop_lid', offset = { x = 0.0, y = 0.0, z = 1.0 } })
    advance(600)
    check(heldBy(C1, k2) and C1.cache.node(k2).priv == true, 'F15 C real: the child of a gated root is private')
    Scene.detach(k2)
    advance(3000)
    local wd, nd = heldBy(C1, k2)
    check(wd and not nd.priv, 'F15 C real: detached, the former holder holds it through its cell')
    check(heldBy(C2, k2), 'F15 C real: and so does the bystander')
    eq(C2.cache.node(r2), nil, 'F15 C real: never the gated root')
end

do  -- F1 / F2 (d1): a gated child under a public root, and the events of a gated unit, reach only its audience
    local env, Core = newRealServer()
    local Scene = Core.Scene
    local cl, advance = liveClients(env, { 1, 2 })
    join(1, vector3(64.0, 64.0, 30.0))
    join(2, vector3(66.0, 64.0, 30.0))
    report(1, 64.0, 64.0, 30.0)
    report(2, 66.0, 64.0, 30.0)
    advance(600)
    local C1, C2 = cl[1].C, cl[2].C
    local root = Scene.spawn({ kind = 'group', pos = vector3(70.0, 70.0, 30.0) })
    local secret = Scene.spawn({ kind = 'prop', parent = root, model = 'prop_secret_safe',
        offset = { x = 1.0, y = 0.0, z = 0.0 }, audience = { players = { 1 } } })
    advance(600)
    check(heldBy(C1, secret) and C1.cache.node(secret).priv == true, 'F1 real: the audience member holds the gated child')
    eq(C2.cache.node(secret), nil, 'F1 real: the bystander never gets the gated child')
    check(heldBy(C2, root), 'F1 real: while it holds the public root')
    local groot = Scene.spawn({ kind = 'prop', pos = vector3(68.0, 64.0, 30.0), model = 'prop_faction_stash',
        audience = { players = { 1 } } })
    local handle = Scene.spawn({ kind = 'prop', parent = groot, model = 'prop_stash_handle',
        offset = { x = 0.0, y = 0.0, z = 0.5 } })
    advance(600)
    local m = mark()
    Scene.emit(handle, 'stash:opened', { code = 4711 }, { radius = 30 })
    Scene.emit(secret, 'safe:clicked', { code = 1 }, { radius = 30 })
    Scene.emit(root, 'root:ping', {}, { radius = 30 })
    advance(600)
    local ops1, ops2 = decode(payloads(1, m)), decode(payloads(2, m))
    local function named(n) return function(o) return o.name == n end end
    eq(count(ops1, 'event', named('stash:opened')), 1, 'F2 real: the event of a gated root\'s child reaches the audience')
    eq(count(ops2, 'event', named('stash:opened')), 0, 'F2 real: and nobody else')
    eq(count(ops1, 'event', named('safe:clicked')), 1, 'F2 real: the event of a gated child reaches the audience')
    eq(count(ops2, 'event', named('safe:clicked')), 0, 'F2 real: and nobody else')
    eq(count(ops2, 'event', named('root:ping')), 1, 'F2 real: the public root\'s event reaches everyone')
end

do  -- F17 (d14): a bucket change right after a SUB: the old bucket's queued pack never reaches the client
    local env, Core, R = newRealServer()
    local Scene = Core.Scene
    local cl, advance = liveClients(env, { 1 })
    local secret = Scene.spawn({ kind = 'prop', pos = vector3(70.0, 70.0, 30.0), model = 'prop_bucket1_only',
        bucket = 1 })
    join(1, vector3(3000.0, 3000.0, 30.0), 1)
    report(1, 3000.0, 3000.0, 30.0)
    advance(1000)
    local K = R.index.keyOf(0, 70.0, 70.0)
    movePed(1, vector3(64.0, 64.0, 30.0))
    local m = mark()
    report(1, 64.0, 64.0, 30.0, 0, 0, 0, nil, true)
    local subSeen = false
    for _ = 1, 40 do
        stubs.tick(5)
        subSeen = find(decode(payloads(1, m)), 'sub', function(o) return o.grid == 0 and o.key == K and o.v ~= 0 end) ~= nil
        if subSeen then break end
    end
    check(subSeen, 'F17 real: the SUB of the bucket-1 cell went out (its pack is still queued)')
    m = mark()
    stubs.buckets[1] = 0
    stubs.triggerOn(env, 'onPlayerBucketChange', 1, '1', 0, 1)
    advance(2000)
    local ops = decode(payloads(1, m))
    local first = ops[1] and ops[1].op == 'header' and ops[2] or ops[1]
    eq(first and first.op, 'reset', 'F17 real: the next payload starts with RESET')
    eq(count(ops, 'put', function(o) return o.id == secret end), 0, 'F17 real: the old bucket\'s pack is never sent')
    check(not heldBy(cl[1].C, secret), 'F17 real: the bucket-0 client does not show the bucket-1 node')
end

do  -- F18 (d15): the raw native (the client is not told): RESET first, then only the new bucket's content
    local env, Core, R = newRealServer()
    local Scene = Core.Scene
    local cl, advance = liveClients(env, { 1 })
    local sofa = Scene.spawn({ kind = 'prop', pos = vector3(70.0, 70.0, 30.0), model = 'prop_apartment_sofa',
        bucket = 5 })
    local bench = Scene.spawn({ kind = 'prop', pos = vector3(72.0, 70.0, 30.0), model = 'prop_street_bench' })
    join(1, vector3(64.0, 64.0, 30.0))
    report(1, 64.0, 64.0, 30.0)
    advance(600)
    for i = 1, 5 do
        Scene.set(bench, { tint = i })
        advance(100)
    end
    local C = cl[1].C
    check(heldBy(C, bench) and not heldBy(C, sofa), 'F18 real: in bucket 0 the client shows the street bench')
    local m = mark()
    stubs.buckets[1] = 5
    stubs.triggerOn(env, 'onPlayerBucketChange', 1, '1', 5, 0)
    advance(1000)
    local ops = decode(payloads(1, m))
    local first = ops[1] and ops[1].op == 'header' and ops[2] or ops[1]
    eq(first and first.op, 'reset', 'F18 real: the next payload starts with RESET')
    check(heldBy(C, sofa) and not heldBy(C, bench), 'F18 real: in bucket 5 the client shows the sofa, not the bench')
    eq(R.interest.bucketOf(1), 5, 'F18 real: the window is in bucket 5')
end

do  -- F9 (d8): a prefab activation (one entry > MaxEventBytes) goes as SUB + a latent pack; the clients end complete
    local env, Core, R = newRealServer()
    local Scene = Core.Scene
    local cl, advance = liveClients(env, { 1, 2, 3 })
    for src = 1, 3 do
        join(src, vector3(64.0, 64.0, 30.0))
        report(src, 64.0, 64.0, 30.0)
    end
    advance(600)
    local m = mark()
    local ids = {}
    Scene.batch(function()
        for i = 1, 1200 do
            ids[i] = Scene.spawn({ kind = 'prop', pos = vector3(1.0 + (i % 40) * 3.0, 1.0 + (i // 40) * 3.0, 30.0),
                model = 'prop_bench_01a' })
        end
    end)
    advance(100)
    local biggest = 0
    for i = m + 1, #stubs.sent do
        local s = stubs.sent[i]
        if s.name == 'core:scene:s' and #s.args[1] > biggest then biggest = #s.args[1] end
    end
    check(biggest > 0 and biggest <= Core.Config.Scene.MaxEventBytes, ('F9 real: no reliable event over MaxEventBytes '
        .. '(biggest %d)'):format(biggest))
    eq(R.flush.stats().oversized, 0, 'F9 real: nothing oversized')
    check(R.flush.stats().bigEntries > 0, 'F9 real: the big entry went the latent way')
    advance(8000)
    for src = 1, 3 do
        local held = 0
        for i = 1, 1200 do
            if heldBy(cl[src].C, ids[i]) then held = held + 1 end
        end
        eq(held, 1200, ('F9 real: client %d holds all 1200 props'):format(src))
    end
end

--------------------------------------------------------------------------------
-- 26. The RV1 differential fuzz (fuzz2) as a suite: random API operations, jumps and bucket changes on the real
--     stack; after a settle period every REAL client cache equals the server's truth (ids + node versions). The
--     truth is the effective audience (own + ancestors, F2): a node is wanted where its root's cell is covered.
--------------------------------------------------------------------------------
local function fuzzSeed(seed, o)
    local state = seed * 2654435761 % 4294967296 + 1
    local function rnd(a, b)
        state = (state * 1103515245 + 12345) % 2147483648
        local f = state / 2147483648
        if a == nil then return f end
        if b == nil then a, b = 1, a end
        return a + math.floor(f * (b - a + 1))
    end
    local env, Core, R = newRealServer({ JournalOps = 8, MaxBacklogBytes = o.backlog })
    local Scene = Core.Scene
    local PLAYERS, GS = 3, 4294967296
    local WAY = { { 0, 0 }, { 300, 0 }, { 0, 600 }, { -900, 0 }, { 150, -150 } }
    local RADII = { 50, 50, 50, 300, 300, 800 }
    local cl, advance = liveClients(env, { 1, 2, 3 })
    local pos = {}
    for p = 1, PLAYERS do
        local w = WAY[rnd(#WAY)]
        pos[p] = { w[1] + 0.0, w[2] + 0.0 }
        cl[p].at.x, cl[p].at.y = pos[p][1], pos[p][2]
    end
    for p = 1, PLAYERS do
        join(p, vector3(pos[p][1], pos[p][2], 30.0))
        report(p, pos[p][1], pos[p][2], 30.0)
    end
    local roots, all, sources = {}, {}, {}
    local function pick(t) if #t == 0 then return nil end return t[rnd(#t)] end
    local function randPos() return vector3((rnd() * 2 - 1) * 700, (rnd() * 2 - 1) * 700, 30.0) end
    local function rootOf(id)
        local n = id and R.store.get(id)
        return n ~= nil and not n.parent, n
    end
    local function op()
        local r = rnd()
        if r < 0.25 then
            local def = { kind = 'prop', pos = randPos(), model = 'prop_bench_01a', radius = RADII[rnd(#RADII)] }
            if rnd() < 0.05 then def.global, def.radius = true, nil end
            if rnd() < 0.15 then def.audience = { players = { rnd(PLAYERS) } } end
            if o.buckets and rnd() < 0.3 then def.bucket = 1 end
            local id = Scene.spawn(def)
            if id then roots[#roots + 1] = id; all[#all + 1] = id end
        elseif r < 0.40 then
            local id = pick(all); if id then Scene.set(id, { tint = rnd(0, 15) }) end
        elseif r < 0.52 then
            local id = pick(roots); if rootOf(id) then Scene.move(id, randPos()) end
        elseif r < 0.56 then
            local id = pick(roots); if rootOf(id) then Scene.move(id, randPos(), nil, { duration = rnd(200, 3000) }) end
        elseif r < 0.64 then
            local id = pick(all); if id then Scene.remove(id) end
        elseif r < 0.76 then
            local parent = pick(all)
            if parent and R.store.get(parent) then
                local id = Scene.spawn({ kind = 'prop', parent = parent, model = 'prop_bench_01a',
                    offset = { x = rnd() * 4, y = 0.0, z = 0.0 } })
                if id then all[#all + 1] = id end
            end
        elseif r < 0.80 then
            local id = pick(all); if id then Scene.detach(id) end
        elseif r < 0.86 then
            local id = pick(roots)
            local isRoot, n = rootOf(id)
            if isRoot then
                if n.audience then Scene.set(id, nil, { audience = false })
                else Scene.set(id, nil, { audience = { players = { rnd(PLAYERS) } } }) end
            end
        elseif r < 0.92 then
            local id = pick(roots); if id then Scene.set(id, nil, { radius = RADII[rnd(#RADII)] }) end
        else
            local a, b = pick(all), pick(all)
            if a and b and a ~= b then Scene.attach(a, { node = b }) end
        end
    end
    local function extraOp()
        local r = rnd()
        if r < 0.06 then
            local id = pick(roots)
            local isRoot, n = rootOf(id)
            if isRoot and not n.global then
                Scene.attach(id, { player = rnd(PLAYERS) }, { offset = { x = 0.0, y = 0.0, z = 1.0 } })
            end
        elseif r < 0.09 then
            local id = pick(roots); if id then Scene.detach(id) end
        elseif r < 0.14 then
            local sid = Scene.spawn({ kind = 'audio.source', fields = { type = 'loop', file = '@core/s/' .. rnd(1, 9) .. '.ogg' } })
            if sid then
                sources[#sources + 1] = sid
                for _ = 1, rnd(1, 2) do
                    local def = { kind = 'audio', pos = randPos(),
                        fields = { source = sid, range = RADII[rnd(#RADII)] > 300 and 200 or 40 } }
                    if rnd() < 0.2 then def.audience = { players = { rnd(PLAYERS) } } end
                    local e = Scene.spawn(def)
                    if e then roots[#roots + 1] = e; all[#all + 1] = e end
                end
            end
        elseif r < 0.18 and #sources > 0 then
            local sid = sources[rnd(#sources)]
            if R.store.get(sid) then Scene.set(sid, { volume = rnd() * 2 }) end
        elseif r < 0.20 and #sources > 0 then
            local sid = sources[rnd(#sources)]
            if R.store.get(sid) then Scene.remove(sid) end
        end
    end
    local function heldOf(p)
        if not o.held then return nil end
        local out, n, lru = {}, 0, cl[p].C.cache.lru()
        for i = #lru, 1, -1 do
            local c = lru[i]
            if c.v > 0 then
                out[('%d:%d:%d'):format(c.grid, c.key, c.cv)] = c.v
                n = n + 1
                if n >= 48 then break end
            end
        end
        return out
    end
    for _ = 1, o.ticks do
        for _ = 1, rnd(0, 4) do op() end
        if o.extra then extraOp() end
        for _ = 1, o.dense or 0 do
            local id = Scene.spawn({ kind = 'prop', pos = vector3((rnd() * 2 - 1) * 200, (rnd() * 2 - 1) * 200, 30.0),
                model = 'prop_bench_01a', radius = 50, fields = { tint = rnd(0, 15) } })
            if id then all[#all + 1] = id end
        end
        if o.buckets and rnd() < 0.02 then             -- Player.setBucket: the native, then the client is told
            local p = rnd(PLAYERS)
            local old = stubs.buckets[p] or 0
            local b = old == 0 and 1 or 0
            stubs.buckets[p] = b
            stubs.triggerOn(env, 'onPlayerBucketChange', p, tostring(p), b, old)
            env.TriggerClientEvent('core:client:bucketChanged', p, b)
        end
        if rnd() < 0.03 then                             -- a jump (teleport) somewhere else
            local p = rnd(PLAYERS)
            local w = WAY[rnd(#WAY)]
            pos[p] = { w[1] + (rnd() * 2 - 1) * 60, w[2] + (rnd() * 2 - 1) * 60 }
            cl[p].at.x, cl[p].at.y = pos[p][1], pos[p][2]
            stubs.coords[stubs.peds[p]] = vector3(pos[p][1], pos[p][2], 30.0)
            report(p, pos[p][1], pos[p][2], 30.0, 0, 0, 0, heldOf(p), true)
        end
        advance(50)
    end
    for s = 1, 200 do                                    -- settle: movers finish, dwells run out, everything drains
        if s % 6 == 0 then
            for p = 1, PLAYERS do report(p, pos[p][1], pos[p][2], 30.0, 0, 0, 0, heldOf(p), true) end
        end
        advance(50)
    end
    local problems, lines = 0, {}
    local function problem(text)
        problems = problems + 1
        lines[#lines + 1] = text
    end
    for p = 1, PLAYERS do
        local w = R.interest.windowOf(p)
        local want, have = {}, {}
        R.store.each(function(node)
            if node.k and node.k.dependency then return end
            local root = R.store.root(node)
            local cell = root.cell
            if not cell or root.bucket ~= w.bucket then return end
            local ring = w.cells[cell.grid * GS + cell.key]
            if not ring or not (cell.grid ~= 0 or ring == 1 or root.tier == 'M') then return end
            if R.store.audienceOf(node) == nil or R.interest.allows(node, p) then want[node.id] = true end
        end)
        cl[p].C.cache.forEachNode(function(node)
            local sn = R.store.get(node.id)
            if sn and sn.k and sn.k.dependency then return end
            if cl[p].C.cache.wanted(node) then have[node.id] = node.ver end
        end)
        for id in pairs(want) do
            if not have[id] then problem(('p%d MISSING node %d'):format(p, id))
            elseif have[id] ~= R.store.get(id).ver then
                problem(('p%d node %d ver client %s server %s'):format(p, id, tostring(have[id]), tostring(R.store.get(id).ver)))
            end
        end
        for id in pairs(have) do
            if not want[id] then problem(('p%d EXTRA node %d (%s)'):format(p, id, R.store.get(id) and 'exists' or 'removed')) end
        end
    end
    return problems, lines, R.store.count(), R.flush.stats()
end

do
    local configs = {
        { name = 'plain', seeds = { 1, 4, 6, 7 }, ticks = 150 },
        { name = 'buckets+held+extra', seeds = { 1, 2, 3, 4 }, ticks = 150, buckets = true, held = true, extra = true },
        { name = 'dense+backlog', seeds = { 1, 2 }, ticks = 120, buckets = true, held = true, extra = true, dense = 6,
            backlog = 20000 },
    }
    local pressure = 0
    for _, o in ipairs(configs) do
        for _, seed in ipairs(o.seeds) do
            local problems, lines, nodes, fs = fuzzSeed(seed, o)
            for i = 1, math.min(#lines, 8) do print('    fuzz ' .. o.name .. ' seed ' .. seed .. ': ' .. lines[i]) end
            eq(problems, 0, ('fuzz %s seed %d (%d nodes): every client view equals the server truth'):format(o.name, seed,
                nodes))
            if o.dense then pressure = pressure + fs.overflows + fs.latentEvents end
        end
    end
    check(pressure > 0, 'the dense seeds went through the backlog guard / latent packs')
end

-- @@TESTS-END@@
print(('scene_interest: %d passed, %d failed'):format(passed, failed))
for i = 1, #stubs.failures do print('  uncaught: ' .. stubs.failures[i]) end
if failed > 0 or #stubs.failures > 0 then os.exit(1) end
