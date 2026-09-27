--[[
    core/server/vehicles_fleet.lua — the parked fleet (DESIGN §55.21.4): AutoPark, MaxParked, the boot and core-stop
    reconciliation. Loads RIGHT AFTER server/vehicles_park.lua and takes P once through the one-shot global
    CoreVehiclesPark (asserted, then cleared); it defines P.wake (server/vehicles.lua: a record appeared), P.beforeStop
    (core stops) and P.touch / P.untouch / P.grew (server/vehicles_park.lua: the MaxParked order).

    AutoPark (Config.Vehicles.AutoPark, default on): a sweep thread (only while persisted vehicles exist) looks at
    each one once per AutoParkSweepMs in 10 slices; one at rest (< 0.1 m/s, within 1 m) for AutoParkIdleMs, nobody
    of its bucket within AutoParkRadius (PlayerGrid candidates + exact distance), nobody inside → queued (≤ 64 per
    sweep) for one park worker (thread only while queued), which re-checks it first; a refused park waits a whole
    idle period before the next try.
    MaxParked (Config.Vehicles.MaxParked, default 20000; review RV6 F9): the parked records in least-recently-used
    order (a park, a promotion, a demotion and the lock key touch one). Past the cap the longest-unused one that is
    not promoted is STORED (its node removed, the record garaged: stored = true, parked = false) and the hook
    `vehicleAutoStored (vehId, 'max_parked')` fires — at most 16 per park, the rest at the next park / the boot.
    Boot (once the scene store is loaded; sliced, Wait(0) every 100 records): a parked record keeps its node; one whose
    node vanished adopts a core node naming it, else is re-parked from the record; an OUT record with neither a node
    nor a live car (a stop without the scene, a crash, a deleted clone — review RV6 F2) is parked at its saved position
    unless it is `destroyed` (a wreck, D-C); a garaged / live / destroyed record drops its mark; a parked node of the
    old policy (without authority 'local', D-B) is re-spawned with it; every other core vehicle node naming a record
    is removed; the LRU is rebuilt (last_used_at order) and the excess over MaxParked stored. A park refused 'limit'
    (the scene's node caps, D-E) drops the stale mark and is retried with backoff (10 s doubling to 5 min, ≤ 50 per
    pass, a pass ends at the next 'limit'; thread only while some wait).
    Core stop (P.beforeStop, no Wait; the promote engine's pre-stop hook, and server/vehicles.lua's stop handler —
    the second call finds nothing left): every adopted clone hands its final pose to its node (Scene.move demotes it
    synchronously: the demoted hook writes the record, bucket included); every other live persisted car is PARKED at
    its pose with its cached props (review RV4 F14 / RV6 F2: no spawn storm at boot, no car lost in limbo); stop-gap
    cars still retiring after a park go now; the scene store writes the nodes.
    Also, since the §56 port (the files' size): setLocked / giveKeys / removeKeys / setOwner by vehId (from
    server/vehicles_park.lua) and the §5 net events of server/vehicles.lua (core:server:vehicleLock / vehicleProps,
    the callback core:vehicles:mine); P.characterExists (a new owner must be a character row) is defined here.
    Database (§56): the boot check reads the world records in ONE streamed query in LRU order (the partial index
    vehicles_world_idx, without props — the few re-parks read theirs by id); a failed read changes nothing and is
    retried with backoff (never "no cars"); P.recovered tells the scene hooks the mirror is complete. Eviction and
    the stop paths use the mirror (P.recs) and queue their writes: nothing here awaits except the boot / retry reads.

    Natives (fxref + natives_cfx.json 2026-09-27, server / CFX forms; BOOL answers read by truthiness):
      GetEntityCoords(entity), GetEntityRotation(entity), GetEntityVelocity(entity), GetEntityRoutingBucket(entity),
      DoesEntityExist(entity), DeleteEntity(entity), GetPlayerPed(playerSrc), GetPlayerRoutingBucket(playerSrc),
      GetEntityType(entity) (the moved §5 events), GetGameTimer(). Runtime: CreateThread, Wait, Entity(e).state.
]]

local P = CoreVehiclesPark
assert(type(P) == 'table' and P.parkRecord and P.hookScene and P.sc,
    'server/vehicles_fleet.lua loads right after server/vehicles_park.lua (CoreVehiclesPark)')
-- fxlint-disable-next-line C003 -- clears the one-shot hand-off created by server/vehicles.lua (+ vehicles_park.lua)
CoreVehiclesPark = nil

local Vehicles, Log, DB = Core.Vehicles, Core.Log, Core.DB
local spawned, byVehId, clones, rest, recs, spawning = P.spawned, P.byVehId, P.clones, P.rest, P.recs, P.spawning
local entityOf, forget, positionOf = P.entityOf, P.forget, P.positionOf
local sc, parkedOf, parkedNode, removeNode = P.sc, P.parkedOf, P.parkedNode, P.removeNode
local nodeFields, spawnNode, parkRecord, occupied, keyList = P.nodeFields, P.spawnNode, P.parkRecord, P.occupied,
    P.keyList
local platedProps, write, readRecord, fromRow, mirrorOf = P.platedProps, P.write, P.readRecord, P.fromRow, P.mirrorOf
local keySet, markWrite, Validate = P.keySet, P.markWrite, Core.Validate
local floor = math.floor

-- The boot check's ONE read of the world records (the partial index vehicles_world_idx, streamed; no props — the few
-- records to re-park get theirs by id afterwards), in the MaxParked order: longest unused first.
local WORLD_SQL <const> = [[SELECT id, owner_character_id, model, model_name, plate, stored, destroyed, parked, locked,
    keys, meta ->> 'vehType' AS veh_type, meta ->> 'keyMode' AS key_mode
FROM vehicles WHERE stored = false OR parked IS NOT NULL ORDER BY last_used_at, id]]
local REPARK_SQL <const> = 'SELECT id, props, position FROM vehicles WHERE id = ANY($1::text[])'
local WORLD_BATCH <const>, REPARK_CHUNK <const> = 1000, 200
-- key changes of a record the mirror lacks (garaged): ONE queued statement each, so two of them never lose one
local ADD_KEY_SQL <const> = [[UPDATE vehicles SET keys = ARRAY(SELECT DISTINCT k FROM unnest(array_append(keys,
    $2::text)) AS k ORDER BY k) WHERE id = $1]]
local REMOVE_KEY_SQL <const> = 'UPDATE vehicles SET keys = array_remove(keys, $2::text) WHERE id = $1'
local SET_OWNER_SQL <const> = [[UPDATE vehicles SET owner_character_id = $2::text, keys = ARRAY(SELECT DISTINCT k
    FROM unnest(CASE WHEN owner_character_id IS NOT NULL AND owner_character_id IS DISTINCT FROM $2::text
        THEN array_remove(keys, owner_character_id) ELSE keys END
    || CASE WHEN $2::text IS NOT NULL AND COALESCE(meta ->> 'keyMode', '') <> 'item' THEN ARRAY[$2::text]
        ELSE '{}'::text[] END) AS k ORDER BY k) WHERE id = $1]]
local ENTITY_TYPE_VEHICLE <const> = 2
local PROPS_MAX_KEYS <const>, PROPS_DISTANCE <const>, RECORDS_COOLDOWN_MS <const> = 96, 10.0, 1000
local AP_SLICES <const>, AP_PER_SWEEP <const> = 10, 64
local AP_REST2 <const>, AP_MOVE2 <const> = 0.01, 1.0  -- at rest: < 0.1 m/s and within 1 m of the rest stamp
local RECOVER_WAIT_MS <const>, RECOVER_TRIES <const>, RECOVER_SLICE <const> = 1000, 600, 100
local EVICT_PER_PARK <const>, EVICT_SCAN <const>, MAX_PARKED_DEFAULT <const> = 16, 64, 20000
local RETRY_MIN_MS <const>, RETRY_MAX_MS <const>, RETRY_PER_PASS <const> = 10000, 300000, 50
local LOG_EVERY_MS <const> = 60000
local EMPTY <const> = setmetatable({}, { __newindex = function() error('read-only', 2) end })

local loggedAt = {}     -- reason -> GetGameTimer() of the last line (a busy fleet logs once a minute per reason)

local function logLimited(reason, fmt, ...)
    local now = GetGameTimer()
    if loggedAt[reason] and now - loggedAt[reason] < LOG_EVERY_MS then return end
    loggedAt[reason] = now
    Log.warn('vehicles: ' .. fmt, ...)
end

--------------------------------------------------------------------------------
-- AutoPark: one sliced sweep over the persisted vehicles (thread only while there are some), a park
-- worker (thread only while something is queued)
--------------------------------------------------------------------------------

local AP = { list = {}, n = 0, i = 0, queued = 0, queue = {}, qh = 1, qt = 0, running = false, working = false,
    warned = {} }
local apBuf, apPoint = {}, { x = 0.0, y = 0.0 }

--- enabled, idle ms, radius m, sweep ms (read live: a config change applies at the next slice).
local function apConfig()
    local c = Config.Vehicles or EMPTY
    return c.AutoPark ~= false, tonumber(c.AutoParkIdleMs) or 30000, tonumber(c.AutoParkRadius) or 50.0,
        math.max(1000, tonumber(c.AutoParkSweepMs) or 10000)
end

--- A loaded player of the vehicle's bucket within r of (x, y, z)? (PlayerGrid candidates + the exact distance)
local function anyoneNear(entity, x, y, z, r)
    local grid = Core.PlayerGrid
    apPoint.x, apPoint.y = x, y
    local n = grid and grid.candidates(apPoint, r, apBuf) or 0
    local bucket, r2 = GetEntityRoutingBucket(entity), r * r
    for i = 1, n do
        local src = apBuf[i]
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 and GetPlayerRoutingBucket(src) == bucket then
            local p = GetEntityCoords(ped)
            if (p.x - x) ^ 2 + (p.y - y) ^ 2 + (p.z - z) ^ 2 <= r2 then return true end
        end
    end
    return false
end

--- Still parkable right now: tracked, at rest, nobody near, nobody inside.
local function apReady(info, radius)
    if spawned[info.netId] ~= info or info.parked or info.parking or not info.vehId then return false end
    local e = entityOf(info.netId)
    if e == 0 then return false end
    local c, v = GetEntityCoords(e), GetEntityVelocity(e)
    return v.x * v.x + v.y * v.y + v.z * v.z <= AP_REST2 and not anyoneNear(e, c.x, c.y, c.z, radius)
        and not occupied(e)
end

--- The worker: parks the queued vehicles one by one (each may wait 1 s for its owner's props); a vehicle that
--- changed since it was queued (moved, entered, approached, a recycled net id) is skipped.
local function apWork()
    while AP.qh <= AP.qt do
        local info = AP.queue[AP.qh]
        AP.queue[AP.qh], AP.qh = nil, AP.qh + 1
        local _, _, radius = apConfig()
        if apReady(info, radius) then
            local ok, id, err = pcall(Vehicles.park, info.netId)
            if not ok or not id then
                local r = rest[info.netId]
                if r then r.t = GetGameTimer() end                -- a whole idle period before the next try
                local why = ok and tostring(err) or 'error'
                if not AP.warned[why] then
                    AP.warned[why] = true
                    Log.warn('vehicles: auto-park of %s refused (%s)', tostring(info.vehId), ok and why or tostring(id))
                end
            end
        end
    end
    AP.queue, AP.qh, AP.qt, AP.working = {}, 1, 0, false
end

local function apQueue(info)
    AP.qt = AP.qt + 1
    AP.queue[AP.qt] = info
    if AP.working then return end
    AP.working = true
    CreateThread(apWork)
end

--- One vehicle of the sweep: a moving (or moved) one gets a new rest stamp; one at rest for `idle` with nobody
--- within `radius` and nobody inside is queued.
local function apCheck(netId, now, idle, radius)
    local info = spawned[netId]
    if not info or not info.vehId or info.parked or info.parking then return end
    local e = entityOf(netId)
    if e == 0 then return end
    local c, v = GetEntityCoords(e), GetEntityVelocity(e)
    local r = rest[netId]
    if not r then
        r = {}
        rest[netId] = r
    end
    if not r.t or v.x * v.x + v.y * v.y + v.z * v.z > AP_REST2
        or (c.x - r.x) ^ 2 + (c.y - r.y) ^ 2 + (c.z - r.z) ^ 2 > AP_MOVE2 then
        r.t, r.x, r.y, r.z = now, c.x, c.y, c.z
        return
    end
    if now - r.t < idle or AP.queued >= AP_PER_SWEEP or anyoneNear(e, c.x, c.y, c.z, radius) or occupied(e) then
        return
    end
    AP.queued = AP.queued + 1
    apQueue(info)
end

--- The sweep: every AutoParkSweepMs each persisted, non-clone vehicle once, in AP_SLICES slices.
local function apLoop()
    while not P.stopped do
        local on, idle, radius, sweep = apConfig()
        if not on or not P.isHooked() then break end
        if AP.i >= AP.n then                                  -- a new sweep
            local n = 0
            for netId, info in pairs(spawned) do
                if info.vehId and not info.parked then
                    n = n + 1
                    AP.list[n] = netId
                end
            end
            for k = n + 1, AP.n do AP.list[k] = nil end
            AP.n, AP.i, AP.queued = n, 0, 0
            if n == 0 then break end
        end
        local now = GetGameTimer()
        for _ = 1, math.ceil(AP.n / AP_SLICES) do
            if AP.i >= AP.n then break end
            AP.i = AP.i + 1
            local ok, err = pcall(apCheck, AP.list[AP.i], now, idle, radius)
            if not ok then Log.error('vehicles: auto-park check failed: %s', tostring(err)) end
        end
        Wait(sweep // AP_SLICES)
    end
    AP.running = false
end

--- Starts the sweep when AutoPark is on, the scene hooked and it is not running yet.
local function wakeAutoPark()
    if AP.running or P.stopped or not P.isHooked() or not apConfig() then return end
    AP.running = true
    CreateThread(apLoop)
end
P.wake = wakeAutoPark

--------------------------------------------------------------------------------
-- MaxParked: the parked records in least-recently-used order (a doubly linked list), the eviction past the cap
--------------------------------------------------------------------------------

local L = { head = nil, tail = nil, n = 0, at = {} }   -- at[vehId] = { id, node, prev, next }; head = longest unused

local function unlink(e)
    if e.prev then e.prev.next = e.next else L.head = e.next end
    if e.next then e.next.prev = e.prev else L.tail = e.prev end
    e.prev, e.next = nil, nil
end

--- The record `vehId` is parked (as node `nodeId`) and was used now: to the back of the order.
function P.touch(vehId, nodeId)
    if type(vehId) ~= 'string' then return end
    local e = L.at[vehId]
    if e then
        e.node = nodeId or e.node
        if L.tail == e then return end
        unlink(e)
    else
        e = { id = vehId, node = nodeId }
        L.at[vehId], L.n = e, L.n + 1
    end
    e.prev = L.tail
    if L.tail then L.tail.next = e else L.head = e end
    L.tail = e
end

--- The record `vehId` is not parked any more.
function P.untouch(vehId)
    local e = L.at[vehId]
    if not e then return end
    unlink(e)
    L.at[vehId], L.n = nil, L.n - 1
end

local function maxParked()
    local v = tonumber((Config.Vehicles or EMPTY).MaxParked)
    return (v and v == v and v >= 0) and floor(v) or MAX_PARKED_DEFAULT
end

--- Stores the longest-unused parked cars past MaxParked, at most `budget` of them (a scan of ≤ EVICT_SCAN entries:
--- a promoted one — in use — moves to the back, one no longer parked leaves the order). -> how many were stored
local function evict(budget)
    local max, done, scanned = maxParked(), 0, 0
    while L.n > max and done < budget and scanned < EVICT_SCAN and L.head do
        scanned = scanned + 1
        local e = L.head
        local record = recs[e.id]                             -- (the mirror: a parked record — no yield here)
        local node = record and record.stored == false and parkedNode(record) or nil
        if not node then
            P.untouch(e.id)
        elseif clones[node.id] or node.promoted then
            P.touch(e.id, node.id)
        elseif Vehicles.store(e.id) then                      -- node removed, stored = true, parked = false
            P.untouch(e.id)
            done = done + 1
            Core.emitHook('vehicleAutoStored', e.id, 'max_parked')
            logLimited('evict', 'MaxParked (%d) reached: the longest-unused parked cars are stored (%s first)', max,
                e.id)
        else
            P.untouch(e.id)
        end
    end
    return done
end

--- A car was parked: past MaxParked the longest-unused ones are stored (bounded per call).
function P.grew()
    if L.n > maxParked() then evict(EVICT_PER_PARK) end
end

--------------------------------------------------------------------------------
-- Parks refused 'limit' (D-E): retried with backoff, sliced, only while some wait
--------------------------------------------------------------------------------

local RT = { list = {}, set = {}, running = false, delay = RETRY_MIN_MS }

--- Still an out record with nothing in the world (else the retry is moot and it is dropped) -> record | nil, err
--- (AWAITED: the record with its props and position; a failed read keeps it for the next pass).
local function stranded(vehId)
    if spawning[vehId] then return nil, 'spawning' end        -- spawnRecord makes its car: the next pass decides
    local rec, err = readRecord(vehId)
    if err ~= nil then return nil, err end
    if rec and rec.stored == false and rec.destroyed ~= true and not byVehId[vehId] and not spawning[vehId]
        and not parkedNode(rec) then
        return rec
    end
    return nil
end

local function retryLoop()
    while not P.stopped and #RT.list > 0 do
        Wait(RT.delay)
        if P.stopped then break end
        local left, tried, limited = {}, 0, false
        for i = 1, #RT.list do
            local vehId = RT.list[i]
            if limited or tried >= RETRY_PER_PASS then
                left[#left + 1] = vehId
            else
                tried = tried + 1
                local rec, err = stranded(vehId)
                local id
                if rec then id, err = parkRecord(rec) end
                if id then
                    P.grew()
                elseif err ~= nil and not rec then            -- the read failed: next pass
                    left[#left + 1] = vehId
                elseif rec and err == 'limit' then
                    limited = true                            -- the rest would be refused too: next pass
                    left[#left + 1] = vehId
                elseif rec then
                    logLimited('retry', 'a car could not be parked (%s): %s', tostring(err), vehId)
                end
            end
        end
        RT.list, RT.set = left, {}
        for i = 1, #left do RT.set[left[i]] = true end
        RT.delay = limited and math.min(RT.delay * 2, RETRY_MAX_MS) or RETRY_MIN_MS
    end
    RT.running = false
end

local function queueRetry(vehId)
    if RT.set[vehId] then return end
    RT.set[vehId] = true
    RT.list[#RT.list + 1] = vehId
    if RT.running or P.stopped then return end
    RT.running = true
    CreateThread(retryLoop)
end

--------------------------------------------------------------------------------
-- Boot: every out record in the world again, one node each
--------------------------------------------------------------------------------

--- D-B: a parked node promotes only on enter / damage / actions (authority { mode = 'local' }).
local function localPolicy(n)
    local a = n.authority
    return type(a) == 'table' and a.mode == 'local'
end

--- A parked node of the old policy is re-spawned with authority 'local' (same fields, pose, bucket) -> the id the
--- record parks now (the old one when the re-spawn is refused).
local function migrate(rec, n)
    local id = spawnNode(n.fields, n.pos, n.rot, n.bucket)
    if not id then return n.id end
    if not write(rec.id, { parked = id }) then
        removeNode(id)
        return n.id
    end
    removeNode(n.id)
    return id
end

--- Every core vehicle node naming a record, as copies: [nodeId] = copy, [vehId] = { copies }.
local function vehicleNodes()
    local nodes, byRec = {}, {}
    local ids = sc('list', { owner = 'core', kind = 'vehicle' }) or {}
    for i = 1, #ids do
        local n = sc('get', ids[i])
        local vehId = n and type(n.fields) == 'table' and n.fields.vehId
        if type(vehId) == 'string' then
            nodes[n.id] = n
            local list = byRec[vehId]
            if not list then
                list = {}
                byRec[vehId] = list
            end
            list[#list + 1] = n
        end
        -- fxlint-disable-next-line P002 -- a one-time boot pass, sliced: one yield per RECOVER_SLICE nodes
        if i % RECOVER_SLICE == 0 then Wait(0) end
    end
    return nodes, byRec
end

--- One out (or marked) record at boot (its mirror entry): garaged / live / destroyed → no mark; its node (or an
--- orphan node naming it) kept (migrated to the 'local' policy), else queued in `todo` for a re-park from the record
--- (props and position are read for those afterwards). Never yields. -> kept node id(s)
local function recoverOne(rec, nodes, byRec, counts, todo)
    local mark = parkedOf(rec)
    local n = mark and nodes[mark]
    if n and n.fields.vehId ~= rec.id then n = nil end
    local live = byVehId[rec.id] and spawned[byVehId[rec.id]]
    if n and live and live.parked == mark then                    -- promoted by a player meanwhile: it stays
        P.touch(rec.id, mark)
        return mark
    end
    if rec.stored ~= false or live or spawning[rec.id] or rec.destroyed == true then   -- (spawning: live soon)
        if mark then write(rec.id, { parked = false }) end
        P.settle(rec.id)
        return nil
    end
    if not n and byRec[rec.id] then                               -- the node outlived the record's write
        n = byRec[rec.id][1]
        if write(rec.id, { parked = n.id }) then counts.adopted = counts.adopted + 1 else n = nil end
    end
    if n then
        local id = n.id
        if not localPolicy(n) then
            id = migrate(rec, n)
            if id ~= n.id then counts.migrated = counts.migrated + 1 end
        end
        P.touch(rec.id, id)
        return id, n.id
    end
    todo[#todo + 1] = { id = rec.id, mark = mark }
    return nil
end

--- The re-parks the boot check queued: their props and position by id (chunks of REPARK_CHUNK, awaited), then each
--- one that is still stranded is parked; 'limit' → the backoff retry; a failed read → the retry as well.
local function reparkAll(todo, counts)
    for from = 1, #todo, REPARK_CHUNK do
        local ids = {}
        for i = from, math.min(from + REPARK_CHUNK - 1, #todo) do ids[#ids + 1] = todo[i].id end
        local rows, err = DB.query(REPARK_SQL, { ids })
        if not rows then
            Log.warn('vehicles: %d record(s) could not be read for their re-park (%s); retried later', #ids,
                tostring(err))
        end
        local extra = {}
        for i = 1, rows and #rows or 0 do extra[rows[i].id] = rows[i] end
        for i = from, from + #ids - 1 do
            local t = todo[i]
            local e, x = recs[t.id], extra[t.id]
            local id, perr
            if e and x and e.stored == false and e.destroyed ~= true and not byVehId[t.id] and not spawning[t.id]
                and not parkedNode(e) then
                local rec = { id = e.id, plate = e.plate, model = e.model, modelName = e.modelName, meta = e.meta,
                    locked = e.locked, props = type(x.props) == 'table' and x.props or {}, position = x.position }
                id, perr = parkRecord(rec)                        -- (touches it)
            elseif not rows then
                perr = 'limit'                                    -- the read failed: retried like a full scene
            end
            if id then
                if t.mark then counts.reparked = counts.reparked + 1 else counts.parked = counts.parked + 1 end
            elseif e and not parkedNode(e) and not byVehId[t.id] and not spawning[t.id] then
                if t.mark and parkedOf(e) == t.mark then write(t.id, { parked = false }) end   -- spawnRecord works
                if perr == 'limit' then
                    counts.limited = counts.limited + 1
                    queueRetry(t.id)
                elseif perr then
                    Log.warn('vehicles: %s could not be parked (%s)', t.id, tostring(perr))
                end
                P.settle(t.id)
            end
        end
    end
end

--- The world records, streamed (ONE query in the MaxParked order) into the mirror -> the ids in that order | nil, err.
--- A row is skipped when this module wrote the record while the read ran (the mirror has the newer state).
local function readWorld()
    local order, start = {}, P.writeSeq()
    local _, err = DB.stream(WORLD_SQL, {}, function(rows)
        for i = 1, #rows do
            local row = rows[i]
            row.meta = { vehType = row.veh_type, keyMode = row.key_mode }
            if (P.lastWrite(row.id) or 0) <= start then mirrorOf(fromRow(row)) end
            order[#order + 1] = row.id
        end
    end, { batch = WORLD_BATCH, sync = true })                -- (after every write queued so far: read-your-writes)
    if err ~= nil then return nil, err end
    return order
end

--- The boot check (once the scene store is loaded): every out record gets its node (see the header), every other
--- core vehicle node naming a record goes, the MaxParked order is rebuilt and its excess stored. A failed read of
--- the world records changes NOTHING (no node removed, no mark dropped) -> false, err: the caller retries.
local function recover()
    local order, err = readWorld()
    if not order then return false, err end
    P.recovered = true
    local nodes, byRec = vehicleNodes()
    local keep, todo = {}, {}
    local counts = { reparked = 0, parked = 0, adopted = 0, migrated = 0, removed = 0, limited = 0, stored = 0 }
    for i = 1, #order do
        local rec = recs[order[i]]
        if rec then
            local id, old = recoverOne(rec, nodes, byRec, counts, todo)
            if id then keep[id] = true end
            if old then keep[old] = true end                  -- (a migrated node is gone already)
        end
        -- fxlint-disable-next-line P002 -- a one-time boot pass, sliced: one yield per RECOVER_SLICE records
        if i % RECOVER_SLICE == 0 then Wait(0) end
    end
    for id in pairs(nodes) do                                 -- every other core node naming a record goes
        if not keep[id] then
            removeNode(id)
            counts.removed = counts.removed + 1
        end
    end
    reparkAll(todo, counts)
    while L.n > maxParked() do                                -- a lowered MaxParked: the excess, sliced
        local n = evict(EVICT_PER_PARK)
        counts.stored = counts.stored + n
        if n == 0 then break end
        -- fxlint-disable-next-line P002 -- bounded by the excess (EVICT_PER_PARK per slice), once at boot
        Wait(0)
    end
    if counts.reparked + counts.parked + counts.adopted + counts.migrated + counts.removed + counts.limited
        + counts.stored > 0 then
        Log.info('vehicles: boot check: %d re-parked, %d out car(s) parked, %d node(s) adopted, %d migrated to the '
            .. 'local policy, %d orphan node(s) removed, %d waiting for scene capacity, %d stored (MaxParked)',
            counts.reparked, counts.parked, counts.adopted, counts.migrated, counts.removed, counts.limited,
            counts.stored)
    end
    return true
end

--- Waits for the scene store, then runs the boot check; a failed read is retried with backoff (10 s doubling to
--- 5 min) until it worked or core stops — never "no cars".
local function boot()
    local st
    for _ = 1, RECOVER_TRIES do                               -- the scene store loads behind its own barrier
        st = sc('stats')
        if type(st) == 'table' and st.loaded then break end
        Wait(RECOVER_WAIT_MS)
    end
    if not (type(st) == 'table' and st.loaded) then
        return Log.error('vehicles: Core.Scene is not loaded; the parked vehicles were not checked')
    end
    local delay = RETRY_MIN_MS
    while not P.stopped do
        local ok, err = recover()
        if ok then return end
        Log.error('vehicles: the parked vehicles could not be read (%s); nothing was changed, the boot check runs '
            .. 'again in %d s', tostring(err), delay // 1000)
        Wait(delay)
        delay = math.min(delay * 2, RETRY_MAX_MS)
    end
end

CreateThread(function()
    Wait(0)                                                   -- every server file has loaded (server/scene.lua too)
    if not P.hookScene() then return end                      -- no Core.Scene: parking is unavailable
    boot()
    wakeAutoPark()
end)

--------------------------------------------------------------------------------
-- Core stop
--------------------------------------------------------------------------------

--- A live persisted car (no clone) becomes a parked node at core stop — no Wait: its cached props, the mirror of its
--- record (review RV4 F14 / RV6 F2), one QUEUED patch. A refused node leaves it to server/vehicles.lua's stop loop
--- (the record stays out at its final pose; the boot check parks it).
local function parkAtStop(info)
    local netId = info.netId
    local e = entityOf(netId)
    local record = e ~= 0 and recs[info.vehId] or nil
    if e == 0 or (record and record.destroyed == true) then return end
    local stale = record and parkedNode(record)
    local fields = nodeFields({ id = info.vehId, plate = info.plate, model = info.model,
        modelName = info.modelName or (record and record.modelName), meta = record and record.meta or
        { vehType = info.vehType, keyMode = info.keyMode } }, info.props or {}, info.locked)
    local c, r = GetEntityCoords(e), GetEntityRotation(e)
    local id, err = spawnNode(fields, { x = c.x, y = c.y, z = c.z }, { x = r.x, y = r.y, z = r.z },
        GetEntityRoutingBucket(e))
    if not id then
        return Log.warn('vehicles: %s could not be parked at stop (%s); the boot check parks it', info.vehId,
            tostring(err))
    end
    if not write(info.vehId, { parked = id, stored = false, props = fields.props, locked = info.locked == true,
        keys = keyList(info.keys), position = positionOf(e) }) then
        removeNode(id)
        return
    end
    if stale then removeNode(stale.id) end
    forget(netId)
    if DoesEntityExist(e) then DeleteEntity(e) end
end

--- core stops (no Wait, every record write QUEUED): every adopted clone hands its final pose to its persistent node —
--- Scene.move demotes it synchronously first (the demoted hook writes the record; if it did not, the record is
--- written here) — then every other live persisted car parks, the stop-gap cars still retiring go, and the scene
--- store writes the nodes. Runs as the promote engine's pre-stop hook and from server/vehicles.lua's stop handler
--- (the second call finds nothing left), whatever the order of the stop handlers.
function P.beforeStop()
    P.stopped = true
    local list = {}
    for nodeId, netId in pairs(clones) do list[#list + 1] = { nodeId, netId } end
    for i = 1, #list do
        local nodeId, netId = list[i][1], list[i][2]
        local info = spawned[netId]
        local e = info and entityOf(netId) or 0
        if e ~= 0 then
            local c, r, position = GetEntityCoords(e), GetEntityRotation(e), positionOf(e)
            sc('move', nodeId, { x = c.x, y = c.y, z = c.z }, { x = r.x, y = r.y, z = r.z })
            if spawned[netId] == info then                    -- the demoted hook did not take it: the record here
                write(info.vehId, { stored = false, parked = nodeId, position = position,
                    props = platedProps(info.props, info.plate), locked = info.locked == true,
                    keys = keyList(info.keys) })
                forget(netId)
            else                                              -- (the hook saw the node before the move's pose)
                write(info.vehId, { position = position })
            end
            if DoesEntityExist(e) then DeleteEntity(e) end
        end
    end
    if P.isHooked() then
        local live = {}
        for _, info in pairs(spawned) do
            if info.vehId and not info.parked then live[#live + 1] = info end
        end
        for i = 1, #live do
            local ok, err = pcall(parkAtStop, live[i])
            if not ok then
                Log.error('vehicles: parking %s at stop failed: %s', tostring(live[i].vehId), tostring(err))
            end
        end
    end
    P.retireNow()
    local R = rawget(Core, 'SceneRuntime')
    local store = R and R.store
    if store and store.flush then pcall(store.flush) end
end

--- A new owner must be a character row (the owner FK, §56.6): an online session's, else one indexed read (AWAITED).
--- A queued owner patch that fails the FK at COMMIT would make core_db drop every change merged into that row's
--- entry. -> true | false | nil, err
local function characterExists(charId)
    if Core.Player.getSrcByCharId(charId) then return true end
    local row, err = DB.first('characters', { id = charId }, { columns = { 'id' } })
    if err ~= nil then return nil, err end
    return row ~= nil
end

local base = { setLocked = Vehicles.setLocked, giveKeys = Vehicles.giveKeys, removeKeys = Vehicles.removeKeys,
    setOwner = Vehicles.setOwner }

--------------------------------------------------------------------------------
-- Lock and keys by vehId (review RV4 F13; moved here from server/vehicles_park.lua with the §56 port): the live car's
-- netId path, else the record (+ a parked node's lock)
--------------------------------------------------------------------------------

--- target -> netId of its live car | nil, record (the mirror's, else read — AWAITED; a garaged record) | nil, nil.
local function liveOrRecord(vehId)
    if not Validate.value('id', vehId) then return nil, nil end
    local netId = byVehId[vehId]
    if netId and spawned[netId] then return netId end
    if recs[vehId] then return nil, recs[vehId] end
    local rec = readRecord(vehId)
    netId = byVehId[vehId]
    if netId and spawned[netId] then return netId end         -- it went live during the read
    return nil, recs[vehId] or rec
end

--- The record's explicit key set (without the owner's implicit virtual key) and the record's key mode.
local function recordKeySet(record)
    local meta = type(record.meta) == 'table' and record.meta or EMPTY
    return keySet(record.keys, nil, nil), meta.keyMode == 'item' and 'item' or 'virtual'
end

--- A key / owner change of a record: a mirrored one in memory + ONE queued patch (no yield between read and write);
--- a garaged one as ONE queued statement that changes the row in place (sql, params). -> bool
local function changeKeys(target, record, apply, sql, params)
    if recs[target] ~= record then
        local ok, err = DB.enqueue(sql, params)
        if not ok then Log.error('vehicles: the key change of %s was refused (%s)', target, tostring(err)) end
        markWrite(target)
        return ok == true
    end
    local keys, keyMode = recordKeySet(record)
    local changes = apply(keys, keyMode) or {}
    changes.keys = keyList(keys)
    return write(target, changes)
end

function Vehicles.setLocked(target, locked)
    if type(target) ~= 'string' then return base.setLocked(target, locked) end
    if type(locked) ~= 'boolean' then return false end
    local netId, record = liveOrRecord(target)
    if netId then return base.setLocked(netId, locked) end
    if not record or not write(target, { locked = locked }) then return false end
    local node = parkedNode(record)
    if node and (node.fields.locked == true) ~= locked then sc('set', node.id, { locked = locked }) end
    return true
end

function Vehicles.giveKeys(target, charId)
    if type(target) ~= 'string' then return base.giveKeys(target, charId) end
    if not Validate.value('id', charId) then return false end
    local netId, record = liveOrRecord(target)
    if netId then return base.giveKeys(netId, charId) end
    if not record then return false end
    return changeKeys(target, record, function(keys) keys[charId] = true end, ADD_KEY_SQL, { target, charId })
end

function Vehicles.removeKeys(target, charId)
    if type(target) ~= 'string' then return base.removeKeys(target, charId) end
    if not Validate.value('id', charId) then return false end
    local netId, record = liveOrRecord(target)
    if netId then return base.removeKeys(netId, charId) end
    if not record then return false end
    return changeKeys(target, record, function(keys) keys[charId] = nil end, REMOVE_KEY_SQL, { target, charId })
end

--- The virtual keys follow ownership (as setOwner(netId) does): the previous owner's key goes, the new owner's
--- comes (a virtual-key car).
function Vehicles.setOwner(target, charId)
    if type(target) ~= 'string' then return base.setOwner(target, charId) end
    if charId ~= nil and not Validate.value('id', charId) then return false end
    -- the owner FK: a queued patch that failed it at COMMIT would drop every change merged into the row's entry
    if charId ~= nil and not characterExists(charId) then return false end
    local netId, record = liveOrRecord(target)
    if netId then return base.setOwner(netId, charId) end
    if not record then return false end
    return changeKeys(target, record, function(keys, keyMode)
        local previous = record.ownerCharId
        if previous and previous ~= charId then keys[previous] = nil end
        if charId and keyMode == 'virtual' then keys[charId] = true end
        return { ownerCharId = charId or false }
    end, SET_OWNER_SQL, { target, charId or DB.NULL })
end

--------------------------------------------------------------------------------
-- The §5 net events of server/vehicles.lua (moved here with the §56 port: the files' size)
--------------------------------------------------------------------------------

--- Distance resolver for the wrapper's `distance` check: the vehicle's own position.
local function vehicleCoords(_, netId)
    local entity = entityOf(netId)
    if entity == 0 then return nil end
    return GetEntityCoords(entity)
end

--- Toggles the lock of a core vehicle the player holds keys for (DESIGN §5).
Core.Net.on('core:server:vehicleLock', { 'netId' }, function(src, netId)
    local entity = entityOf(netId)
    if entity == 0 or GetEntityType(entity) ~= ENTITY_TYPE_VEHICLE then return end
    if Entity(entity).state.coreVeh ~= true then return end
    if not Vehicles.hasKeys(src, netId) then
        Core.Notify.send(src, Config.Texts.no_keys, 'error')
        return
    end
    local locked = not Vehicles.isLocked(netId)
    if not Vehicles.setLocked(netId, locked) then return end
    Core.Notify.send(src, locked and Config.Texts.locked or Config.Texts.unlocked, 'info')
end, {
    cooldown = 500,
    requireLoaded = true,
    distance = { coords = vehicleCoords, max = Config.Vehicles.LockDistance },
})

--- Owner's client reports the vehicle's mod/colour props so they survive a respawn.
--- A ped sitting in the vehicle is inside PROPS_DISTANCE of it by definition (DESIGN §5).
Core.Net.on('core:server:vehicleProps', { 'netId', { 'table', max = PROPS_MAX_KEYS } }, function(src, netId, props)
    local entity = entityOf(netId)
    if entity == 0 or GetEntityType(entity) ~= ENTITY_TYPE_VEHICLE then return end
    if Entity(entity).state.coreVeh ~= true then return end
    if not Vehicles.hasKeys(src, netId) then return end
    Vehicles.saveProps(netId, props)
end, {
    cooldown = 5000,
    requireLoaded = true,
    distance = { coords = vehicleCoords, max = PROPS_DISTANCE },
})

--- DESIGN §5.2: the player's own persisted vehicle records (one indexed read). Throttled per src. The client gets
--- a PROJECTION — never props, plugin meta or other key holders' character ids.
local recordsCooldown = {}

local function forClient(record)
    local p = type(record.position) == 'table' and record.position or nil
    return { id = record.id, model = record.model, modelName = record.modelName, plate = record.plate,
        stored = record.stored == true, parked = record.parked ~= false and record.parked ~= nil,
        destroyed = record.destroyed == true,
        position = p and { x = p.x, y = p.y, z = p.z, heading = p.heading } or nil }
end

Core.Callback.register('core:vehicles:mine', function(src)
    local now = GetGameTimer()
    if now < (recordsCooldown[src] or 0) then return {} end
    recordsCooldown[src] = now + RECORDS_COOLDOWN_MS
    local charId = P.charIdOf(src)
    if not charId then return {} end
    local records, out = Vehicles.getRecords(charId), {}
    for i = 1, #records do out[i] = forClient(records[i]) end
    return out
end)

AddEventHandler('playerDropped', function()
    local src = source
    recordsCooldown[src] = nil
end)

P.characterExists = characterExists
