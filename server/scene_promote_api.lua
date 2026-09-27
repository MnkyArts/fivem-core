--[[
    core/server/scene_promote_api.lua — the entry points of R.promote (DESIGN §55.15, §55.19): what the Scene API,
    players and FXServer ask of the promotion engine (server/scene_promote.lua). Loads RIGHT AFTER
    server/scene_promote.lua and takes its internals ONCE through R.promoteInternal (asserted, then cleared).
      promote(id) -> true | nil, err          owner or core; queued (async)
      demote(id) -> true | nil, err           forced: 'not_promoted', or 'occupied' while someone sits in the vehicle
      lease(id, src, ms?, seq?) -> seq | nil, err    first request wins, the holder renews (with its seq), ms = 0
                                              releases; 'missing' 'owner' 'src' 'ms' 'leased' 'stale' 'none'
      adopt(id, entity) -> true | nil, err    core-internal (SceneRuntime never reaches plugins): an existing networked
                                              entity of the node's class becomes its clone — vehicles_park parks a live
                                              car through the hand-off (RV6 F11), then demote(id)
      beforeStop(fn) -> ok                    core stops: fn() runs before any clone is deleted (vehicles_park.lua)
      beforeChange(node, what) -> demoted?   scene.lua, BEFORE move / motion / drive / attach / detach / a fields set
      refuses(src, node, action) / onInteract(src, node, action)   scene.lua's interaction path; get(id) / stats()
    Net events (§55.19, Core.Net.on: schema → cooldown → loaded, then the checks below → act):
      core:scene:report (id, 'enter' | 'damaged', data?): 250 ms per player (≤ 4/s) → what / data (≤ 256 B plain) →
        node → 500 ms per (player, node, what) → bucket / audience → distance (enter 6 m, damaged 60 m) → policy →
        promote. (No 'rest' any more: the 1 Hz monitor decides; 'applied' has its own event.)
      core:scene:applied (id): the clone's owner applied a vehicle's one-shot config → the bag keeps the per-owner
        part. Its own event, no per-player cooldown shared with the reports (RV5 F1 / RV6 F1): a live vehicle
        promotion not applied yet → 500 ms per (player, node) → ours(clone) → the sender owns the clone → act.
    FXServer events: onEntityBucketChange(entity, bucket, oldBucket) — a live clone's node follows it into its new
    bucket at once (read back with GetEntityRoutingBucket; the arguments only name the entity; not a net event);
    playerDropped; onResourceStop (core): every live clone's pose + bucket into its node (persisted, flushed), the
    pre-stop hooks, then every clone is deleted.

    Natives (fxref 2026-09-27, server / CFX forms): GetPlayerPed(playerSrc), GetEntityCoords(entity),
      GetPlayerRoutingBucket(playerSrc), NetworkGetEntityOwner(entity), DoesEntityExist(entity), DeleteEntity(entity),
      GetEntityType(entity), NetworkGetNetworkIdFromEntity(entity). Runtime helpers: Entity(e).state, AddEventHandler,
      SetTimeout.
]]

local R = Core.SceneRuntime
local X = type(R) == 'table' and R.promoteInternal or nil
assert(type(X) == 'table' and X.P and X.finishDemote and type(R.promote) == 'table' and R.promote.policy,
    'server/scene_promote_api.lua loads right after server/scene_promote.lua (R.promoteInternal)')
R.promoteInternal = nil

local Log, Utils = Core.Log, Core.Utils
local store, V, PM, P, stats = R.store, R.valid, R.promote, X.P, X.stats
local type, pairs, pcall, tostring = type, pairs, pcall, tostring
local toint = math.tointeger

local ID_MAX <const> = 0x7FFFFFFF
local ENTER_M <const>, DAMAGE_M <const>, REPORT_DATA_MAX <const> = 6.0, 60.0, 256
local REPORT_CD_MS <const> = 500            -- per (player, node, what); Core.Net.on's 250 ms per player = <= 4/s
local ENTITY_TYPE <const> = { ped = 1, vehicle = 2, prop = 3 }
local PC = (type(Config) == 'table' and type(Config.Scene) == 'table' and type(Config.Scene.Promote) == 'table')
    and Config.Scene.Promote or {}
local LEASE_MS <const> = (function(v)
    v = tonumber(v)
    if not v or v ~= v then return 10000 end
    return math.floor(v < 100 and 100 or (v > 3600000 and 3600000 or v))
end)(PC.LeaseMs)

local function now() return R.now() end
local function toId(v) local n = toint(v) return (n and n >= 1 and n <= ID_MAX) and n or nil end

--------------------------------------------------------------------------------
-- core:scene:report (enter, damaged) and core:scene:applied
--------------------------------------------------------------------------------

local reportAt = {}                          -- [src] = { n, ['<id>:<what>'] = Clock ms } (reset past 64 entries)

local function tooSoon(src, id, what, t)
    local m = reportAt[src]
    if not m or m.n >= 64 then
        m = { n = 0 }
        reportAt[src] = m
    end
    local key = id .. ':' .. what
    local last = m[key]
    if last and R.diff(t, last) < REPORT_CD_MS then return true end
    if not last then m.n = m.n + 1 end
    m[key] = t
    return false
end

local function onReport(src, id, what, data)
    if what ~= 'enter' and what ~= 'damaged' then return end
    if data ~= nil then
        local _, err = V.plain(data, REPORT_DATA_MAX)
        if err then return end
    end
    if not store.loaded() then return end
    local node = store.get(id)
    if not node or PM.policy(node).none then return end
    local t = now()
    if tooSoon(src, id, what, t) then return end
    if GetPlayerRoutingBucket(src) ~= (node.bucket or 0) then return end
    if node.audience ~= nil and not R.interest.allows(node, src) then return end
    if P[id] then return end                         -- promoted already, or on its way
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local c = GetEntityCoords(ped)
    local x, y, z = store.pose(node, t)
    local limit = what == 'enter' and ENTER_M or DAMAGE_M
    local dx, dy, dz = c.x - x, c.y - y, c.z - z
    if dx * dx + dy * dy + dz * dz > limit * limit then return end
    local pol, enter = PM.policy(node), what == 'enter'
    if not ((enter and pol.enter) or (not enter and pol.damage)) then return end
    stats.reports[what] = stats.reports[what] + 1
    X.promote(node, enter and 'enter' or 'damage', src)
end

Core.Net.on('core:scene:report', { { 'integer', min = 1, max = ID_MAX }, { 'string', max = 8, pattern = '^%a+$' },
    'any?' }, onReport, { cooldown = 250 })

--- The clone's owner applied the one-shot part of a vehicle's config (D-A): the bag keeps the per-owner part.
local function onApplied(src, id)
    if not store.loaded() then return end
    local node, pr = store.get(id), P[id]
    if not node or not pr or pr.node ~= node or pr.phase ~= 'live' or pr.cls ~= 'vehicle' or pr.applied then return end
    if tooSoon(src, id, 'applied', now()) then return end
    local e = pr.entity
    if not PM.ours(e, id, pr.snv) or NetworkGetEntityOwner(e) ~= src then return end
    pr.applied, pr.appliedAt = true, now()
    Entity(e).state:set('snCfg', X.persistentCfg(node), true)
    stats.reports.applied = stats.reports.applied + 1
end

Core.Net.on('core:scene:applied', { { 'integer', min = 1, max = ID_MAX } }, onApplied, { cooldown = 0 })

--------------------------------------------------------------------------------
-- beforeChange (§55.21.1): scene.lua demotes a promoted node before it changes it
--------------------------------------------------------------------------------

-- what -> does the node stay where its clone is now (true) or does the change bring its own pose (false)
local FORCED <const> = { set = true, motion = true, move = false, drive = false, attach = false, detach = false }

--- scene.lua calls this BEFORE Scene.move / motion / drive / attach / detach and a Scene.set that changes fields
--- (§55.21.1): the server never moves a clone, so a promoted node is demoted first — synchronously (no yield: no
--- props from the owner; the last sampled wear). 'set' / 'motion' leave the node where its clone stands (the snap
--- rule applies); the others bring their own pose. Clients get the DEMOTE and the change in the same tick; the clone
--- goes DeleteDelayMs later. -> true when it demoted (or cancelled a promotion on its way); any other `what`
--- (interact, audience, radius …) keeps the promotion: false.
function PM.beforeChange(node, what)
    local here = FORCED[what]
    if here == nil or type(node) ~= 'table' then return false end
    local pr = P[node.id]
    if not pr or pr.node ~= node then return false end
    stats.forced = stats.forced + 1
    if pr.phase == 'queued' or pr.phase == 'spawning' then
        X.cancel(pr)                                 -- the worker deletes what it created once it exists
        return true
    end
    local e = pr.entity
    local atClone = here and not node.motion and PM.ours(e, pr.id, pr.snv)
    if atClone then X.sample(pr, e) end
    local wear = pr.cls == 'vehicle' and pr.wear or nil
    X.finishDemote(pr, node, atClone, (wear and what ~= 'set') and X.wearProps(node, wear, nil) or nil, 'forced',
        false)
    if wear and what == 'set' then           -- the set assigns fields it built before this call: the wear goes after
        local id = node.id
        SetTimeout(0, function()
            if store.get(id) ~= node or node.promoted or P[id] then return end
            local props = X.wearProps(node, wear, nil)
            if props then Core.Scene.set(id, { props = props }) end
        end)
    end
    return true
end

--------------------------------------------------------------------------------
-- Interactions (§55.14): actions promote; a lease refuses the other players' interactions on a promoted node
--------------------------------------------------------------------------------

--- scene.lua's pre-dispatch check: true = refuse this interaction (a promoted node leased by someone else).
function PM.refuses(src, node, _action)
    if type(node) ~= 'table' or node.promoted == nil then return false end
    local L = X.leaseOf(node.id)
    return L ~= nil and L.src ~= src
end

--- scene.lua calls this after the dispatch of an accepted interaction (pcall'ed).
function PM.onInteract(src, node, action, _data)
    if type(node) ~= 'table' or P[node.id] or store.get(node.id) ~= node then return end
    local L = X.leaseOf(node.id)
    if L and L.src ~= src then return end
    local pol = PM.policy(node)
    if not pol.none and pol.actions and pol.actions[action] then X.promote(node, 'action', src) end
end

--------------------------------------------------------------------------------
-- The API behind Scene.promote / demote / lease (owner rules: the node's owner or core) and R.promote.adopt
--------------------------------------------------------------------------------

local function mine(id)
    if not store.loaded() then return nil, 'unavailable' end
    local node = store.get(toId(id) or 0)
    if not node then return nil, 'missing' end
    local caller = Core.Registry.getCaller()
    if caller ~= 'core' and caller ~= node.owner then return nil, 'owner' end
    return node
end

--- Scene.promote(id) -> true | nil, err. Queued (the clone appears within the 5 s existence wait); a gated node too.
function PM.promote(id)
    local node, err = mine(id)
    if not node then return nil, err end
    return X.promote(node, 'manual', nil, true)
end

--- Scene.demote(id) -> true | nil, err: forced — no rest, idle or lease condition; never under somebody sitting in
--- the vehicle ('occupied'; one who gets in while the owner's props are read aborts it too — RV4 F12).
function PM.demote(id)
    local node, err = mine(id)
    if not node then return nil, err end
    local pr = P[node.id]
    if not pr then return nil, 'not_promoted' end
    if pr.phase == 'queued' or pr.phase == 'spawning' then
        X.cancel(pr)
    elseif pr.phase == 'live' then
        if pr.cls == 'vehicle' and PM.ours(pr.entity, pr.id, pr.snv) and X.occupied(pr.entity) then
            return nil, 'occupied'
        end
        X.demote(pr, 'manual')
    end
    return true
end

--- R.promote.adopt(id, entity) -> true | nil, err ('unavailable' 'missing' 'class' 'parent' 'attach' 'model'
--- 'promoted' 'entity'): core-internal. A live networked entity of the node's class — not another node's clone —
--- becomes its clone at once (nothing one-shot; never refused for the budget); hook promoted fires synchronously.
function PM.adopt(id, entity)
    if not store.loaded() or X.stopping() then return nil, 'unavailable' end
    local node = store.get(toId(id) or 0)
    if not node then return nil, 'missing' end
    local cls, err = X.eligible(node)
    if not cls then return nil, err end
    if P[node.id] or node.promoted then return nil, 'promoted' end
    local e = toint(entity)
    if not e or e == 0 or not DoesEntityExist(e) or GetEntityType(e) ~= ENTITY_TYPE[cls]
        or (toint(NetworkGetNetworkIdFromEntity(e)) or 0) == 0 then return nil, 'entity' end
    local sn = Entity(e).state.sn
    if sn ~= nil and sn ~= node.id then return nil, 'entity' end
    X.adopt(node, e)
    return true
end

local leaseSeq = 0

--- Scene.lease(id, src, ms = Promote.LeaseMs, seq?) -> seq | nil, err: the first request wins; the holder renews
--- (a `seq` of an earlier lease is stale and refused); ms = 0 releases (holder only). Leased nodes never demote.
function PM.lease(id, src, ms, seq)
    local node, err = mine(id)
    if not node then return nil, err end
    src = toint(src)
    if not src or src < 1 or src > 65535 or GetPlayerPed(src) == 0 then return nil, 'src' end
    if ms == nil then ms = LEASE_MS end
    ms = toint(ms)
    if not ms or ms < 0 or ms > 3600000 then return nil, 'ms' end
    if seq ~= nil and not toint(seq) then return nil, 'stale' end
    local L = X.leaseOf(node.id)
    if ms == 0 then
        if not L then return nil, 'none' end
        if L.src ~= src then return nil, 'leased' end
        if seq ~= nil and seq ~= L.seq then return nil, 'stale' end
        X.leases[node.id] = nil
        return L.seq
    end
    if not L then
        if seq ~= nil then return nil, 'stale' end   -- a renewal of a lease that ended
        leaseSeq = leaseSeq + 1
        X.leases[node.id] = { src = src, seq = leaseSeq, untilMs = R.add(now(), ms) }
        return leaseSeq
    end
    if L.src ~= src then return nil, 'leased' end
    if seq ~= nil and seq ~= L.seq then return nil, 'stale' end
    L.untilMs = R.add(now(), ms)
    return L.seq
end

--- A copy of node `id`'s promotion (debug, tests): { phase, netId, entity, since, trigger, by } | nil.
function PM.get(id)
    local pr = P[toId(id) or 0]
    if not pr then return nil end
    return { phase = pr.phase, netId = pr.netId, entity = pr.entity, since = pr.since, trigger = pr.trigger,
        by = pr.by }
end

function PM.stats()
    local promotions, slots, proxSlots, propAreas, proxNodes, working, monitoring = X.counts()
    local out = { promotions = promotions, slots = slots, proximitySlots = proxSlots, maxEntities = X.maxEntities,
        proximityMax = X.proxMax, proximityNodes = proxNodes, leases = 0, propAreas = propAreas, working = working,
        monitoring = monitoring, phases = { queued = 0, spawning = 0, live = 0, demoting = 0 } }
    for _, pr in pairs(P) do out.phases[pr.phase] = out.phases[pr.phase] + 1 end
    for id in pairs(X.leases) do if X.leaseOf(id) then out.leases = out.leases + 1 end end
    for k, v in pairs(stats) do out[k] = type(v) == 'table' and Utils.deepCopy(v) or v end
    return out
end

--------------------------------------------------------------------------------
-- FXServer: bucket changes, players leaving, core stopping
--------------------------------------------------------------------------------

--- SetEntityRoutingBucket raises onEntityBucketChange(entity, bucket, oldBucket) synchronously (citizen-server-impl
--- ServerGameState_Scripting.cpp; server-only, not a net event): a live clone of ours takes its node along (D-D).
AddEventHandler('onEntityBucketChange', function(entity)
    local e = toint(entity)
    if not e or e == 0 then return end
    local ok, err = pcall(X.onBucket, e)
    if not ok then Log.error('scene: following a clone into its new bucket failed: %s', tostring(err)) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    reportAt[src] = nil
    for id, L in pairs(X.leases) do
        if L.src == src then X.leases[id] = nil end
    end
end)

local stopHooks = {}                         -- PM.beforeStop: core's own work that needs the clones still there

--- PM.beforeStop(fn) -> ok: fn() runs when core stops, BEFORE any clone is deleted (and before this file refuses
--- work), whatever order FiveM runs the onResourceStop handlers of the files in — server/vehicles_park.lua hands
--- its adopted clones' final poses to their persistent nodes there. Core-internal (R.promote).
function PM.beforeStop(fn)
    if type(fn) ~= 'function' then return false end
    for i = 1, #stopHooks do if stopHooks[i] == fn then return true end end
    stopHooks[#stopHooks + 1] = fn
    return true
end

--- Core stops: every live clone's pose + bucket into its node (persisted, flushed: RV6 F13), the pre-stop hooks,
--- then every clone goes now (ours only; a spawning one by the handle its create returned).
AddEventHandler('onResourceStop', function(res)
    if res ~= Core.name then return end
    X.followAll()
    for i = 1, #stopHooks do
        local ok, err = pcall(stopHooks[i])
        if not ok then Log.error('scene: a pre-stop hook failed: %s', tostring(err)) end
    end
    X.stop()                                  -- then every clone goes now (ours only; a spawning one by the
    for e, d in pairs(X.doomed) do            -- handle its create returned)
        if PM.ours(e, d.id, d.snv) then DeleteEntity(e) end
        X.doomed[e] = nil
    end
    for _, pr in pairs(P) do
        local e = pr.entity
        if e and ((pr.phase == 'spawning' and DoesEntityExist(e)) or PM.ours(e, pr.id, pr.snv)) then DeleteEntity(e) end
    end
end)
