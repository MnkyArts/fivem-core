--[[
    core/tests/scene_bench.lua — the server benchmark of DESIGN §55.23 (Core.Scene interest + flush on the REAL
    scene_kinds → scene_index → scene_interest → scene_gated → scene_flush → scene_store → scene stack, real codec
    and motion).

        lua5.4 tests/scene_bench.lua [players] [nodes] [seconds] [nogc]      (defaults 2000 50000 30)

    `nogc` stops the collector for the join warm-up and reports the heap growth: the garbage a join storm makes
    (plus what it keeps) — its timings then lack the GC pauses, so read them from a run without it.

    World: `nodes` scene nodes — 60 % in a 4 × 4 km city core, 4 % packed around a hot spot at the origin (≈ 400 per
    near cell), the rest over the map; 85 % S-tier props, 12 % M, 2.5 % L, 100 global. Players: 10 % stand in the hot
    spot (1.5 m/s inside 100 m), the rest random-walk the city at 1.5 (on foot), 15 (driving) or 30 m/s (fast).
    Every player runs the client's focus reporter (§55.10: a sample every 300 ms, a report when it moved ≥ 16 m,
    crossed a near cell or 5 s passed while moving) through the real `core:scene:focus` handler. Live changes:
    100 Scene.set/s (20 % in the hot spot), 10 Scene.emit/s, 50 movers on paths (the index's 2 Hz thread).
    The flush never gets its thread (CreateThread refuses its loop): the bench calls R.flush.tickNow() every 50 ms
    and times it (os.clock).
    Sends are counted per client, never stored. Prints a result table; exit code 0.
]]

local here = (arg and arg[0] or 'tests/scene_bench.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
local vector3 = stubs.vector3

local PLAYERS = math.tointeger(tonumber(arg and arg[1])) or 2000
local NODES = math.tointeger(tonumber(arg and arg[2])) or 50000
local SECONDS = math.tointeger(tonumber(arg and arg[3])) or 30
local NOGC = arg and arg[4] == 'nogc'
local TICK_MS <const> = 50
local HOT = math.max(1, PLAYERS // 10)
local CITY <const> = 2000.0

math.randomseed(20260927)
local rnd = math.random

--------------------------------------------------------------------------------
-- The server VM
--------------------------------------------------------------------------------

local sentBytes, sentEvents, latentBytes, latentEvents = {}, 0, {}, 0
local loaded = {}

stubs.newWorld()
stubs.clear()
stubs.resetServer()
local env = stubs.newEnv('server', 'core')
env.TriggerClientEvent = function(name, target, payload)
    if name == 'core:scene:s' then
        sentBytes[target] = (sentBytes[target] or 0) + #payload
        sentEvents = sentEvents + 1
    end
end
env.TriggerLatentClientEvent = function(name, target, _, payload)
    if name == 'core:scene:p' then
        latentBytes[target] = (latentBytes[target] or 0) + #payload
        latentEvents = latentEvents + 1
    end
end
env.GetPlayerFocusPos = function() return vector3(0.0, 0.0, 0.0) end
stubs.loadImport(env)
stubs.loadFile(env, 'shared/config.lua')
env.Config.Scene.MaxNodesPerOwner = math.max(env.Config.Scene.MaxNodesPerOwner or 0, NODES)   -- one owner spawns all
stubs.loadFile(env, 'shared/scene_codec.lua')
stubs.loadFile(env, 'shared/scene_motion.lua')
stubs.loadFile(env, 'server/api.lua')
stubs.loadFile(env, 'shared/hooks.lua')
stubs.loadFile(env, 'server/db.lua')
local Core = env.Core
Core.Perms = { has = function() return false end }
Core.Player = {
    isLoaded = function(src) return loaded[src] == true end,
    getPlayers = function()
        local out = {}
        for src = 1, PLAYERS do
            if loaded[src] then out[#out + 1] = src end
        end
        return out
    end,
    getData = function() return nil end,
}
stubs.loadFile(env, 'server/playergrid.lua')
stubs.loadFile(env, 'server/scene_kinds.lua')
stubs.loadFile(env, 'server/scene_index.lua')
stubs.loadFile(env, 'server/scene_interest.lua')
stubs.loadFile(env, 'server/scene_gated.lua')
do  -- the flush never gets its thread (it starts one on demand): the bench drives and times every tick itself
    local createThread = env.CreateThread
    env.CreateThread = function(fn)
        local info = debug.getinfo(fn, 'S')
        if info and info.source == '@server/scene_flush.lua' then return nil end
        return createThread(fn)
    end
end
stubs.loadFile(env, 'server/scene_flush.lua')
stubs.loadFile(env, 'server/scene_store.lua')
stubs.loadFile(env, 'server/scene.lua')
env.TriggerEvent('onResourceStart', 'core')
stubs.tick(0)
local R, Scene = Core.SceneRuntime, Core.Scene

--------------------------------------------------------------------------------
-- World: nodes and movers
--------------------------------------------------------------------------------

local pi, cos, sin, sqrt, floor = math.pi, math.cos, math.sin, math.sqrt, math.floor
local ids, hotIds, spawnErrors = {}, {}, {}
local setupStart = os.clock()
local globals = 0
for i = 1, NODES do
    local x, y
    local hot = i <= NODES * 0.04
    if hot then
        local a, d = rnd() * 2 * pi, sqrt(rnd()) * 150
        x, y = cos(a) * d, sin(a) * d
    elseif i <= NODES * 0.64 then
        x, y = (rnd() * 2 - 1) * CITY, (rnd() * 2 - 1) * CITY
    else
        x, y = rnd(-4000, 4000) + 0.0, rnd(-4000, 8000) + 0.0
    end
    local def = { kind = 'prop', pos = vector3(x, y, 30.0 + rnd() * 5), model = 'prop_bench_01a' }
    local r = rnd()
    if i % 97 == 0 and globals < 100 then
        def.global, globals = true, globals + 1
    elseif r < 0.025 then
        def.radius = 600 + rnd() * 800
    elseif r < 0.145 then
        def.radius = 200 + rnd() * 240
    else
        def.radius = 60 + rnd() * 90
    end
    local id, err = Scene.spawn(def)
    if id then
        ids[#ids + 1] = id
        if hot then hotIds[#hotIds + 1] = id end
    else
        spawnErrors[tostring(err)] = (spawnErrors[tostring(err)] or 0) + 1
    end
end
local movers, moverErrors = 0, 0
for i = 1, 50 do
    local id = ids[rnd(#ids)]
    local node = R.store.get(id)
    if node and not node.global then
        local p = node.pos
        local ok = Scene.motion(id, { t = 'path', pts = { { p.x, p.y, p.z }, { p.x + 300, p.y, p.z },
            { p.x + 300, p.y + 300, p.z }, { p.x, p.y + 300, p.z } }, sp = 8 + i % 10, loop = 'loop' })
        if ok then movers = movers + 1 else moverErrors = moverErrors + 1 end
    end
end
stubs.tick(TICK_MS)
R.flush.tickNow()                                  -- the spawn drain (nobody subscribed: nothing encoded)
local setupSeconds = os.clock() - setupStart
local memSetup = collectgarbage('count')

--------------------------------------------------------------------------------
-- Players: the hot spot and the walkers, each with the client's focus reporter; they join staggered over the
-- warm-up (JOIN_MS), and the measurement starts once the join traffic has drained (≤ SETTLE_MAX_MS later)
--------------------------------------------------------------------------------

local JOIN_MS, SETTLE_MAX_MS = 10000, 30000
local P = {}
local SPEEDS <const> = { 1.5, 15.0, 30.0 }
for src = 1, PLAYERS do
    local hot = src <= HOT
    local x, y
    if hot then
        local a, d = rnd() * 2 * pi, sqrt(rnd()) * 100
        x, y = cos(a) * d, sin(a) * d
    else
        x, y = (rnd() * 2 - 1) * CITY, (rnd() * 2 - 1) * CITY
    end
    local roll = rnd()
    local speed = hot and 1.5 or SPEEDS[roll < 0.5 and 1 or (roll < 0.9 and 2 or 3)]
    P[src] = { x = x, y = y, h = rnd() * 2 * pi, speed = speed, hot = hot, cx = floor(x / 128), cy = floor(y / 128),
        rx = x, ry = y, reportAt = -1e9, reported = false, sampleAt = 0, seq = 0, joinAt = rnd(0, JOIN_MS),
        joined = false }
end

-- phase timers inside the flush tick (the fields the flush calls through its tables at call time)
local phase = { drain = 0.0, fill = 0.0, gated = 0.0 }
for name, owner in pairs({ drain = R.index, fill = R.interest, gated = R.interest }) do
    local fn = owner[name]
    owner[name] = function(...)
        local t = os.clock()
        local a, b, c, d = fn(...)
        phase[name] = phase[name] + (os.clock() - t) * 1e6
        return a, b, c, d
    end
end

local counters = { reports = 0, reportUs = 0.0, crossings = 0, sets = 0, emits = 0 }

--- One simulated 50 ms step: joins, walks, reporters, live changes, the threads, one flush tick (timed).
local function step(tick, startNow, walking)
    local now = stubs.now()
    local joinedNow = 0
    for src = 1, PLAYERS do
        local p = P[src]
        if not p.joined then
            if now - startNow >= p.joinAt then
                stubs.connectPlayer(env, src, { coords = vector3(p.x, p.y, 30.0) })
                loaded[src], p.joined, p.sampleAt = true, true, now + rnd(0, 300)
                joinedNow = joinedNow + 1
            end
        else
            if walking then
                if rnd() < 0.02 then p.h = p.h + (rnd() - 0.5) * 2 end
                local stepM = p.speed * TICK_MS / 1000
                local nx, ny = p.x + cos(p.h) * stepM, p.y + sin(p.h) * stepM
                local limit = p.hot and 100.0 or CITY
                if (p.hot and nx * nx + ny * ny > limit * limit)
                    or (not p.hot and (nx < -limit or nx > limit or ny < -limit or ny > limit)) then
                    p.h = p.h + pi
                else
                    p.x, p.y = nx, ny
                end
                stubs.coords[stubs.peds[src]] = vector3(p.x, p.y, 30.0)
                local cx, cy = floor(p.x / 128), floor(p.y / 128)
                if cx ~= p.cx or cy ~= p.cy then
                    counters.crossings = counters.crossings + 1
                    p.cx, p.cy = cx, cy
                end
            end
            if now >= p.sampleAt then
                p.sampleAt = now + 300
                local dx, dy = p.x - p.rx, p.y - p.ry
                local crossed = floor(p.x / 128) ~= floor(p.rx / 128) or floor(p.y / 128) ~= floor(p.ry / 128)
                if not p.reported or dx * dx + dy * dy >= 256 or crossed or (walking and now - p.reportAt >= 5000) then
                    p.seq = p.seq + 1
                    local t = os.clock()
                    stubs.triggerOn(env, 'core:scene:focus', src, p.x, p.y, 30.0,
                        walking and cos(p.h) * p.speed or 0.0, walking and sin(p.h) * p.speed or 0.0, 0.0, p.seq, nil)
                    counters.reportUs = counters.reportUs + (os.clock() - t) * 1e6
                    counters.reports = counters.reports + 1
                    p.rx, p.ry, p.reportAt, p.reported = p.x, p.y, now, true
                end
            end
        end
    end
    if joinedNow > 0 then Core.emitHook('playerLoaded', 1) end
    for _ = 1, 5 do
        local list = rnd() < 0.2 and hotIds or ids
        if Scene.set(list[rnd(#list)], { tint = rnd(0, 15) }) then counters.sets = counters.sets + 1 end
    end
    if tick % 2 == 0 and Scene.emit(ids[rnd(#ids)], 'boom', nil, { radius = 60 }) then
        counters.emits = counters.emits + 1
    end
    local t1 = os.clock()
    stubs.tick(TICK_MS)
    local threads = (os.clock() - t1) * 1e6
    return R.flush.tickNow(), threads
end

-- warm-up: joins over JOIN_MS (players stand still), then until the join traffic drained
local joinUs, joinStart, tick = {}, stubs.now(), 0
local joinHeap, joinGrowth = 0, nil
if NOGC then
    collectgarbage('collect')
    joinHeap = collectgarbage('count')
    collectgarbage('stop')
end
local warmStart = os.clock()
repeat
    tick = tick + 1
    joinUs[#joinUs + 1] = step(tick, joinStart, false)
    local st = R.flush.stats()
    local drained = stubs.now() - joinStart >= JOIN_MS and st.packsWaiting == 0 and st.backlogBytes == 0
until drained or stubs.now() - joinStart >= JOIN_MS + SETTLE_MAX_MS
local joinSeconds = (stubs.now() - joinStart) / 1000
if NOGC then
    joinGrowth = (collectgarbage('count') - joinHeap) / 1024
    collectgarbage('restart')
    collectgarbage('collect')
end
local warmSeconds = os.clock() - warmStart
local joinStats = R.flush.stats()
local joinPacks, joinPackBytes = joinStats.packs, joinStats.packBytes

-- the measured run
local base = { flush = R.flush.stats(), interest = R.interest.stats(), index = R.index.stats() }
local baseSent, baseLatent = {}, {}
for src = 1, PLAYERS do baseSent[src], baseLatent[src] = sentBytes[src] or 0, latentBytes[src] or 0 end
local basePhase = { drain = phase.drain, fill = phase.fill, gated = phase.gated }
for k in pairs(counters) do counters[k] = 0 end
local ticks = SECONDS * 1000 // TICK_MS
local flushUs, threadUs = {}, {}
local peakBacklog, peakClientBacklog = 0, 0
local runStart = os.clock()
for t = 1, ticks do
    local us, th = step(tick + t, joinStart, true)
    flushUs[t], threadUs[t] = us, th
    if t % 20 == 0 then
        local st = R.flush.stats()
        if st.backlogBytes > peakBacklog then peakBacklog = st.backlogBytes end
        for src = 1, PLAYERS do
            local b = R.flush.backlog(src)
            if b > peakClientBacklog then peakClientBacklog = b end
        end
    end
end
local runSeconds = os.clock() - runStart

--------------------------------------------------------------------------------
-- Results
--------------------------------------------------------------------------------

local function pct(list, p)
    local sorted = {}
    for i = 1, #list do sorted[i] = list[i] end
    table.sort(sorted)
    if #sorted == 0 then return 0 end
    return sorted[math.max(1, math.ceil(#sorted * p))]
end

local function sum(list)
    local s = 0
    for i = 1, #list do s = s + list[i] end
    return s
end

local fs, is, xs = R.flush.stats(), R.interest.stats(), R.index.stats()
local function d(t, k) return (t[k] or 0) - (base[t == fs and 'flush' or (t == is and 'interest' or 'index')][k] or 0) end
local perClient, total = {}, 0
for src = 1, PLAYERS do
    local b = (sentBytes[src] or 0) - baseSent[src] + (latentBytes[src] or 0) - baseLatent[src]
    perClient[src] = b / SECONDS
    total = total + b
end
local n = #flushUs
local rows = {
    { 'players / hot spot / nodes (S / M / L / G) / movers', ('%d / %d / %d (%d / %d / %d / %d) / %d'):format(PLAYERS, HOT,
        #ids, xs.nodes.S, xs.nodes.M, xs.nodes.L, xs.nodes.G, movers) },
    { 'wall seconds: setup / warm-up / measured run', ('%.1f / %.1f / %.1f'):format(setupSeconds, warmSeconds,
        runSeconds) },
    { 'JOIN: players joining over 10 s, drained after', ('%.1f s simulated'):format(joinSeconds) },
    { 'JOIN: flush ms per tick p50 / p99 / max', ('%.3f / %.3f / %.3f'):format(pct(joinUs, 0.5) / 1000,
        pct(joinUs, 0.99) / 1000, pct(joinUs, 1) / 1000) },
    { 'JOIN: packs (MiB), per player', ('%d (%.1f), %.1f KiB'):format(joinPacks, joinPackBytes / 1048576,
        joinPackBytes / PLAYERS / 1024) },
    { 'JOIN: Lua heap growth with the collector stopped (MiB)', joinGrowth and ('%.1f'):format(joinGrowth)
        or 'run with nogc' },
    { 'RUN: flush ms per tick p50 / p99 / max', ('%.3f / %.3f / %.3f'):format(pct(flushUs, 0.5) / 1000,
        pct(flushUs, 0.99) / 1000, pct(flushUs, 1) / 1000) },
    { 'RUN: flush ms per tick avg: drain / fill / gated / rest', ('%.3f / %.3f / %.3f / %.3f'):format(
        (phase.drain - basePhase.drain) / n / 1000, (phase.fill - basePhase.fill) / n / 1000,
        (phase.gated - basePhase.gated) / n / 1000, (sum(flushUs) - (phase.drain - basePhase.drain)
        - (phase.fill - basePhase.fill) - (phase.gated - basePhase.gated)) / n / 1000) },
    { 'RUN: threads ms per tick avg (backstop, grid, movers)', ('%.3f'):format(sum(threadUs) / n / 1000) },
    { 'RUN: reports /s, µs per report (handler)', ('%.0f, %.1f'):format(counters.reports / SECONDS,
        counters.reportUs / math.max(1, counters.reports)) },
    { 'RUN: crossings /s (128 m cells)', ('%.1f'):format(counters.crossings / SECONDS) },
    { 'RUN: subscriptions now / per player', ('%d / %.1f'):format(is.subscriptions, is.subscriptions / PLAYERS) },
    { 'RUN: subs / unsubs / ring changes /s', ('%.0f / %.0f / %.0f'):format(d(is, 'subs') / SECONDS,
        d(is, 'unsubs') / SECONDS, d(is, 'ringChanges') / SECONDS) },
    { 'RUN: packs /s (KiB/s), empties /s', ('%.0f (%.1f), %.0f'):format(d(fs, 'packs') / SECONDS,
        d(fs, 'packBytes') / SECONDS / 1024, d(is, 'empties') / SECONDS) },
    { 'RUN: entries delivered /s, skipped, resyncs', ('%.0f, %d, %d'):format(d(fs, 'entries') / SECONDS,
        d(fs, 'skipped'), d(fs, 'resyncs')) },
    { 'RUN: reliable events /s, latent events /s', ('%.0f, %.1f'):format(d(fs, 'events') / SECONDS,
        d(fs, 'latentEvents') / SECONDS) },
    { 'RUN: index pack builds /s, entries encoded /s', ('%.0f, %.0f'):format(d(xs, 'packBuilds') / SECONDS,
        d(xs, 'entries') / SECONDS) },
    { 'RUN: C4 events delivered / expired', ('%d / %d'):format(d(fs, 'transient'), d(fs, 'expired')) },
    { 'RUN: withheld checks / overflows / oversized', ('%d / %d / %d'):format(d(fs, 'withheld'),
        d(fs, 'overflows'), d(fs, 'oversized')) },
    { 'RUN: bytes/s per client mean / p50 / p99 / max', ('%.0f / %.0f / %.0f / %.0f'):format(sum(perClient) / PLAYERS,
        pct(perClient, 0.5), pct(perClient, 0.99), pct(perClient, 1)) },
    { 'RUN: server egress KiB/s', ('%.1f'):format(total / SECONDS / 1024) },
    { 'RUN: peak outbox all clients / one client (bytes)', ('%d / %d'):format(peakBacklog, peakClientBacklog) },
    { 'RUN: live changes sets / emits', ('%d / %d'):format(counters.sets, counters.emits) },
    { 'Lua heap after setup / at the end (MiB)', ('%.1f / %.1f'):format(memSetup / 1024, collectgarbage('count') / 1024) },
}
print(('scene_bench — %d players, %d nodes, %d measured seconds after a 10 s join warm-up (os.clock, one core)')
    :format(PLAYERS, NODES, SECONDS))
print('| metric | value |')
print('|---|---|')
for _, row in ipairs(rows) do print(('| %s | %s |'):format(row[1], row[2])) end
for err, count in pairs(spawnErrors) do print(('  spawn error %s × %d'):format(err, count)) end
if moverErrors > 0 then print(('  mover errors: %d'):format(moverErrors)) end
for i = 1, #stubs.failures do print('  uncaught: ' .. stubs.failures[i]) end
