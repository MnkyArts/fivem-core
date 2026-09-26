--[[ core — client/maps.lua — Core.Maps on the client (DESIGN §52.4, wire format §52.4a)
     The region half of the map runtime: a window thread samples the rendered camera every 500 ms
     (1000 ms after 5 still samples) and asks the read-only callback `core:maps:window` for the 3x3
     regions around it whenever the camera leaves the centre region by more than WindowHysteresis,
     sending the versions it holds so unchanged regions cost nothing; packs (latent), deltas and stale
     notices keep the regions current; up to CacheRegions regions stay cached (LRU) after they leave the
     window. The spawning itself is client/maps_spawn.lua's, markers, hides and the editor view are
     client/maps_view.lua's; both are internal and reached only from here.

     Plugins (through the client proxy): isAreaReady, waitAreaReady, handleOf, uidOf, hold/release
     (owner-tracked, kind 'mapHold'), setEditorView (owner-tracked, kind 'mapEditorView'), stats.
     The server is the authority: the client position only decides which public content to download.
     Networked map entities (server-created) get their `mapCfg` applied by the client that controls them,
     and an in-place move (`core:maps:pose`) is applied by that client too.

     Natives (fxref 2026-09-26, apiset client unless noted; BOOL answers read by truthiness, §30.4):
       GetFinalRenderedCamCoord() -> vector3, GetGameTimer(), AddStateBagChangeHandler(keyFilter,
       bagFilter, handler) (shared), NetworkDoesEntityExistWithNetworkId(netId) (the guard, AGENTS §3),
       NetworkGetEntityFromNetworkId(netId), NetworkHasControlOfEntity(entity), GetEntityType(entity),
       SetBlockingOfNonTemporaryEvents(ped, toggle), SetEntityInvincible(entity, toggle, dontResetOnCleanup),
       FreezeEntityPosition(entity, toggle), IsPedUsingScenario(ped, scenario),
       TaskStartScenarioInPlace(ped, scenarioName, unkDelay, playEnterAnim),
       SetVehicleDoorsLocked(vehicle, doorLockStatus), SetEntityRotation(entity, pitch, roll, yaw, order, p5),
       SetEntityCoordsNoOffset(entity, x, y, z, keepTasks, keepIK, doWarp), SetEntityHeading(entity, heading).
]]

local E = CoreMapsEngine
-- fxlint-disable-next-line C003 -- clears the one-shot handoff from client/maps_spawn.lua
CoreMapsEngine = nil
local View = E.View
local Registry, Log, Utils = Core.Registry, Core.Log, Core.Utils
local floor, abs = math.floor, math.abs

local cfg = (type(Config) == 'table' and type(Config.Maps) == 'table') and Config.Maps or {}
local REGION <const> = math.max(64, tonumber(cfg.RegionSize) or 512)
local HYST <const> = math.max(0, tonumber(cfg.WindowHysteresis) or 64)
local CACHE <const> = math.max(0, math.floor(tonumber(cfg.CacheRegions) or 25))

local SAMPLE_MS <const>, STILL_SAMPLE_MS <const>, STILL_SAMPLES <const> = 500, 1000, 5
local STILL_MOVE <const> = 1.0       -- metres between samples below which the camera counts as still
local SAFETY_MS <const> = 60000      -- re-check the window this often even when nothing moves
local MIN_GAP_MS <const> = 300       -- between two window requests (the server's cooldown is 250 ms)
local RETRY_MS <const> = 2000        -- after a failed request, and for packs the server withheld
local PENDING_MS <const> = 15000     -- a pack announced but not arrived by then is asked for again
local LOADED_POLL_MS <const> = 1000
local WAIT_POLL_MS <const> = 50
local AREA_RADIUS <const>, MAX_AREA <const> = 50.0, 500.0
local DEFAULT_WAIT_MS <const>, MAX_WAIT_MS <const> = 5000, 60000
local MAX_PACK_BYTES <const> = 16 * 1024 * 1024
local MAX_OPS_BYTES <const> = 4 * 1024 * 1024

local Maps = {}
local regions, nRegions = {}, 0      -- key -> region { version, pending, want, withheld, elems, hides, win }
local bucket = nil                   -- the routing bucket our regions belong to (nil until answered)
local crx, cry, centre = 0, 0, nil   -- the window's centre region
local inFlight, wanted, armed = false, false, false
local audience = 0                   -- bumped when the local editor mode flips (the server's audience)
local lastRequestAt, lastAnswerAt = -SAFETY_MS, -SAFETY_MS
local stopped = false
local holders, holdIds = {}, {}      -- uid -> { [owner] = true }; registry id -> uid
local selfName <const> = GetCurrentResourceName()

--------------------------------------------------------------------------------
-- Wire (§52.4a): tuples { uid, kind, modelHash, x, y, z, rx, ry, rz, flags, lod, extra }
--------------------------------------------------------------------------------

local function int(v)
    if type(v) ~= 'number' then return nil end
    return math.type(v) == 'integer' and v or math.tointeger(v)
end

local function finite(v, limit)
    return type(v) == 'number' and v == v and v >= -limit and v <= limit
end

--- A uid is opaque: an integer or a short string; integral floats become integers.
local function readUid(uid)
    if type(uid) == 'number' then return int(uid) end
    if type(uid) == 'string' and #uid > 0 and #uid <= 64 then return uid end
    return nil
end

--- The tuple's fields, or nil when it is malformed (the server is trusted, the wire is not assumed).
local function readTuple(t)
    if type(t) ~= 'table' then return nil end
    local uid, kind, hash = readUid(t[1]), int(t[2]), int(t[3])
    if uid == nil or not kind or kind < 1 or kind > 5 or not hash then return nil end
    if hash > 0x7FFFFFFF and hash <= 0xFFFFFFFF then hash = hash - 0x100000000 end   -- signed 32-bit
    if hash < -0x80000000 or hash > 0x7FFFFFFF then return nil end
    local x, y, z, rx, ry, rz = t[4], t[5], t[6], t[7], t[8], t[9]
    if not (finite(x, 20000) and finite(y, 20000) and finite(z, 5000)) then return nil end
    if not (finite(rx, 3600) and finite(ry, 3600) and finite(rz, 3600)) then return nil end
    local flags, lod = int(t[10]) or 0, int(t[11]) or 150
    if flags < 0 or flags > 255 or lod < 1 then return nil end
    local extra = t[12]
    if type(extra) ~= 'table' then extra = nil end
    return uid, kind, hash, x + 0.0, y + 0.0, z + 0.0, rx + 0.0, ry + 0.0, rz + 0.0, flags,
        lod > 65535 and 65535 or lod, extra
end

--- One tuple into a region: hides (kind 3, not an editor helper) to the view, the rest to the engine.
local function putTuple(r, t)
    local uid, kind, hash, x, y, z, rx, ry, rz, flags, lod, extra = readTuple(t)
    if uid == nil then return nil end
    if kind == 3 and flags & 24 == 0 then
        E.del(r, uid)
        View.putHide(r, uid, hash, x, y, z, extra)
    else
        View.delHide(r, uid)
        E.put(r, uid, kind, hash, x, y, z, rx, ry, rz, flags, lod, extra)
    end
    return uid
end

local function delUid(r, uid)
    E.del(r, uid)
    View.delHide(r, uid)
end

--------------------------------------------------------------------------------
-- Regions: integer keys (rx + 32768) * 65536 + (ry + 32768), a 3x3 window, an LRU cache behind it
--------------------------------------------------------------------------------

local function regionKey(rx, ry) return (rx + 32768) * 65536 + (ry + 32768) end

local function inWindow(key)
    if not centre then return false end
    local rx, ry = key // 65536 - 32768, key % 65536 - 32768
    return abs(rx - crx) <= 1 and abs(ry - cry) <= 1
end

local function newRegion(key)
    -- floor: the highest non-zero version seen; non-zero versions only grow, so anything older is stale
    local r = { key = key, version = nil, pending = nil, pendingAt = 0, want = nil, withheld = false,
        floor = 0, bucket = bucket, elems = {}, hides = {}, win = inWindow(key), leftAt = 0 }
    regions[key], nRegions = r, nRegions + 1
    return r
end

local function clearRegion(r)
    E.clear(r)
    View.clearHides(r)
end

local function dropRegion(r)
    clearRegion(r)
    regions[r.key], nRegions = nil, nRegions - 1
end

--- Every region goes (bucket change): objects through the despawn queue, hides at once.
local function resetAll()
    for _, r in pairs(regions) do dropRegion(r) end
    E.dirty()
end

--- A pack replaces the region's content; unchanged elements keep their objects, moved ones move.
local function applyPack(r, v, list)
    local seen, bad = {}, 0
    for i = 1, #list do
        local uid = putTuple(r, list[i])
        if uid == nil then bad = bad + 1 else seen[uid] = true end
    end
    for uid in pairs(r.elems) do
        if not seen[uid] then E.del(r, uid) end
    end
    for uid in pairs(r.hides) do
        if not seen[uid] then View.delHide(r, uid) end
    end
    if bad > 0 then Log.warn('maps: region %d v%d: %d malformed element(s) skipped', r.key, v, bad) end
end

--- Moves the window's centre; regions that leave it stay cached (LRU, CacheRegions of them).
local function recentre(rx, ry, t)
    crx, cry, centre = rx, ry, regionKey(rx, ry)
    local out = 0
    for key, r in pairs(regions) do
        local win = inWindow(key)
        if r.win and not win then r.leftAt = t end
        r.win = win
        if not win then
            if r.version == nil then dropRegion(r) else out = out + 1 end
        end
    end
    while out > CACHE do
        local oldest
        for _, r in pairs(regions) do
            if not r.win and (not oldest or r.leftAt < oldest.leftAt) then oldest = r end
        end
        dropRegion(oldest)
        out = out - 1
    end
    E.dirty()
end

--------------------------------------------------------------------------------
-- The window request (callback core:maps:window, one in flight, >= 300 ms apart)
--------------------------------------------------------------------------------

local request = {}   -- request.fire, defined below (arm -> fire -> requestWindow -> arm)

local function arm(ms)
    if armed or stopped then return end
    armed = true
    SetTimeout(ms, function() CreateThread(request.fire) end)
end

--- Asks for the window as soon as the request gap allows (coalesced: one request covers all reasons).
local function requestWindow()
    wanted = true
    if inFlight or armed or stopped or not centre then return end
    local wait = lastRequestAt + MIN_GAP_MS - GetGameTimer()
    arm(wait > 0 and wait or 0)
end

--- Applies `{ b = bucket, v = { [key] = version }, w? = { [key] = true } }` for the window centred on
--- (cx, cy). `w`: packs the server withheld (its per-player byte budget) — kept, asked for again later.
local function applyAnswer(answer, cx, cy, sentBucket, sentAudience)
    local b, v, w = int(answer.b), answer.v, answer.w
    if b == nil or b < 0 or type(v) ~= 'table' then
        wanted = true
        arm(RETRY_MS)
        return
    end
    if sentBucket ~= bucket or sentAudience ~= audience then   -- bucket or editor mode changed meanwhile
        wanted = true
        return
    end
    if b ~= bucket then
        if bucket ~= nil then   -- our versions described another bucket
            resetAll()
            bucket, wanted = b, true
            return
        end
        bucket = b
        for _, r in pairs(regions) do
            if r.bucket ~= b then dropRegion(r) end   -- packs of another bucket that came early
        end
    end
    local t = GetGameTimer()
    lastAnswerAt = t
    local withheld = false
    if type(w) ~= 'table' then w = nil end
    for dx = -1, 1 do
        for dy = -1, 1 do
            local key = regionKey(cx + dx, cy + dy)
            local ver = v[key]
            if ver == nil then ver = v[tostring(key)] end   -- tolerate a JSON-shaped answer
            ver = int(ver)
            if ver ~= nil and ver >= 0 then
                local r = regions[key] or newRegion(key)
                r.bucket, r.recheck = b, false
                if ver > r.floor then r.floor = ver end
                if ver == 0 then   -- empty
                    clearRegion(r)
                    r.version, r.pending, r.want, r.withheld = 0, nil, nil, false
                elseif ver == r.version then   -- unchanged
                    r.pending, r.withheld = nil, false
                    if r.want and r.want <= ver then r.want = nil end
                elseif w and (w[key] or w[tostring(key)]) then
                    r.pending, r.withheld, withheld = nil, true, true
                    if not r.want or r.want < ver then r.want = ver end
                elseif ver ~= r.pending then   -- a pack is on its way
                    r.pending, r.pendingAt, r.withheld = ver, t, false
                end
            end
        end
    end
    if withheld then
        wanted = true
        arm(RETRY_MS)
    end
end

function request.fire()
    armed = false
    if inFlight or stopped or not centre or not wanted then return end
    inFlight, wanted = true, false
    local cx, cy = crx, cry
    local h = {}
    for dx = -1, 1 do
        for dy = -1, 1 do
            local key = regionKey(cx + dx, cy + dy)
            local r = regions[key]
            local ver = r and not r.recheck and (r.pending or r.version)
            if ver then h[key] = ver end
        end
    end
    local sentBucket, sentAudience = bucket, audience
    lastRequestAt = GetGameTimer()
    local ok, answer = pcall(Core.Callback.await, 'core:maps:window', { c = regionKey(cx, cy), h = h })
    inFlight = false
    lastRequestAt = GetGameTimer()
    if stopped then return end
    if not ok or type(answer) ~= 'table' then
        if not ok then Log.warn('maps: window request failed: %s', tostring(answer)) end
        wanted = true
        arm(RETRY_MS)
        return
    end
    applyAnswer(answer, cx, cy, sentBucket, sentAudience)
    if wanted then requestWindow() end
end

--------------------------------------------------------------------------------
-- Server pushes (§52.3): packs (latent), deltas, stale notices, bucket changes (§48)
--------------------------------------------------------------------------------

local function wantVersion(r, toV)
    if not r.want or r.want < toV then r.want = toV end
    if not r.pending then requestWindow() end   -- an announced pack re-checks `want` when it lands
end

RegisterNetEvent('core:maps:pack', function(b, key, pack)
    b, key = int(b), int(key)
    if stopped or not b or not key or type(pack) ~= 'string' or #pack > MAX_PACK_BYTES then return end
    if bucket ~= nil and b ~= bucket then return end
    local r = regions[key]
    if not r then
        if not inWindow(key) then return end   -- left before it landed: fetched again on return
        r = newRegion(key)
    end
    local ok, data = pcall(json.decode, pack)
    local v = ok and type(data) == 'table' and int(data.v) or nil
    local list = v and data.e or nil
    if not v or v < 0 or (list ~= nil and type(list) ~= 'table') then
        Log.warn('maps: unreadable pack for region %d', key)
        return
    end
    if r.bucket ~= nil and r.bucket ~= b then
        clearRegion(r)
        r.version = nil
    end
    if v < r.floor or (r.version and v < r.version) then return end   -- overtaken by a newer version
    r.bucket, r.floor = b, v > r.floor and v or r.floor
    applyPack(r, v, list or {})
    r.version, r.withheld = v, false
    if r.pending and r.pending <= v then r.pending = nil end
    if r.want and r.want <= v then r.want = nil elseif r.want then requestWindow() end
end)

RegisterNetEvent('core:maps:delta', function(b, key, fromV, toV, ops)
    b, key, fromV, toV = int(b), int(key), int(fromV), int(toV)
    if stopped or not b or not key or not fromV or not toV or type(ops) ~= 'string' then return end
    if b ~= bucket or #ops > MAX_OPS_BYTES then return end
    local r = regions[key]
    if not r or toV <= r.floor then return end                  -- not ours, or already known
    if r.version ~= fromV then return wantVersion(r, toV) end   -- a gap: fetch the region again
    local ok, list = pcall(json.decode, ops)
    if not ok or type(list) ~= 'table' then return wantVersion(r, toV) end
    for i = 1, #list do
        local op = list[i]
        if type(op) == 'table' then
            if op.o == 'put' then
                putTuple(r, op.t)
            elseif op.o == 'del' then
                local uid = readUid(op.u)
                if uid ~= nil then delUid(r, uid) end
            end
        end
    end
    r.version, r.floor = toV, toV
    if r.want and r.want <= toV then r.want = nil end
end)

RegisterNetEvent('core:maps:stale', function(b, key, toV)
    b, key, toV = int(b), int(key), int(toV)
    if stopped or not b or not key or not toV or b ~= bucket then return end
    local r = regions[key]
    if not r or toV <= r.floor then return end
    wantVersion(r, toV)
    r.floor = toV   -- packs older than the notice are stale now
end)

RegisterNetEvent('core:client:bucketChanged', function(b)
    b = int(b)
    if stopped or not b or b < 0 then return end
    if b ~= bucket then
        resetAll()
        bucket = b
    end
    requestWindow()   -- the server dropped our subscription with the move
end)

--------------------------------------------------------------------------------
-- Networked map entities (§52.2): server-created vehicles, peds and physics props carry `mapEl` and
-- `mapCfg`. The server's RPC natives are fallible, so the client that controls such an entity applies
-- `mapCfg` — again after it takes control over. Only the "on" states are applied (the server switches
-- `frozen` / `locked` off by RPC and re-creates a ped that stops being invincible); the sweep reads the live
-- bag, since net ids are recycled.
--------------------------------------------------------------------------------

local netKnown, netList, nNet, netCursor = {}, {}, 0, 0   -- netId -> { i, entity, owned }; sweep order
local NET_CHECKS <const> = 16   -- known map entities looked at per window sample
local NET_ABSENT <const> = 10   -- sweeps without the entity in scope before its id is forgotten (review F12)

local function netForget(netId)
    local rec = netKnown[netId]
    if not rec then return end
    netKnown[netId] = nil
    local lastId = netList[nNet]
    netList[rec.i] = lastId
    if netKnown[lastId] then netKnown[lastId].i = rec.i end
    netList[nNet], nNet = nil, nNet - 1
end

local function applyCfg(entity, cfg)
    local kind = GetEntityType(entity)
    if kind == 1 then   -- ped
        SetBlockingOfNonTemporaryEvents(entity, true)
        if cfg.invincible == true then SetEntityInvincible(entity, true, false) end
        if cfg.frozen == true then FreezeEntityPosition(entity, true) end
        local scenario = cfg.scenario
        if type(scenario) == 'string' and #scenario > 0 and #scenario <= 64
            and not IsPedUsingScenario(entity, scenario) then
            TaskStartScenarioInPlace(entity, scenario, 0, true)
        end
    elseif kind == 2 then   -- vehicle
        if cfg.locked == true then SetVehicleDoorsLocked(entity, 2) end
    end
    local rot = cfg.rot   -- optional { x, y, z }: a physics prop's rotation
    if type(rot) == 'table' and finite(rot.x, 3600) and finite(rot.y, 3600) and finite(rot.z, 3600) then
        SetEntityRotation(entity, rot.x + 0.0, rot.y + 0.0, rot.z + 0.0, 2, false)
    end
end

--- Applies the config once per control: `value` is the new bag value inside the change handler (the bag
--- still holds the old one there), otherwise the live bag is read.
local function netCheck(netId, rec, value)
    if not NetworkDoesEntityExistWithNetworkId(netId) then
        -- deleted or out of scope: forgotten after a few sweeps (streaming back in fires the handler again)
        rec.owned, rec.absent = false, rec.absent + 1
        if rec.absent >= NET_ABSENT then netForget(netId) end
        return
    end
    rec.absent = 0
    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity == 0 or not NetworkHasControlOfEntity(entity) then
        rec.owned = false
        return
    end
    if rec.owned and rec.entity == entity then return end
    local cfg = value
    if cfg == nil then
        local state = Entity(entity).state
        cfg = state.mapEl ~= nil and state.mapCfg or nil
    end
    if type(cfg) ~= 'table' then return netForget(netId) end
    applyCfg(entity, cfg)
    rec.owned, rec.entity = true, entity
end

--- A few known map entities per window sample (round robin): catches streaming in and taking control.
local function netSweep()
    for _ = 1, math.min(nNet, NET_CHECKS) do
        if nNet == 0 then return end
        netCursor = netCursor % nNet + 1
        local netId = netList[netCursor]
        local rec = netKnown[netId]
        if rec then netCheck(netId, rec) end
    end
end

AddStateBagChangeHandler('mapCfg', nil, function(bagName, _, value)
    local netId = not stopped and type(bagName) == 'string' and int(tonumber(bagName:match('^entity:(%d+)$')))
    if not netId then return end
    if type(value) ~= 'table' then return netForget(netId) end
    local rec = netKnown[netId]
    if not rec then
        nNet = nNet + 1
        rec = { i = nNet, entity = 0, owned = false, absent = 0 }
        netList[nNet], netKnown[netId] = netId, rec
    end
    rec.owned = false   -- a new config is applied again
    netCheck(netId, rec, value)
end)

-- An in-place move (server/maps_runtime.lua), sent to the entity's owner: the server's SET_ENTITY_COORDS
-- would lift a ped by its ground-to-root offset and a vehicle by its base offset, while the entity was created
-- with its ROOT at the authored position. Applied only while this client controls the entity and its mapEl
-- names the element (net ids are recycled); the server checks the synced pose ~2 s later and re-creates the
-- entity when the move did not land. Vehicles and peds take the heading (as they are created), props the
-- full rotation (order 2).
RegisterNetEvent('core:maps:pose', function(netId, uid, x, y, z, rx, ry, rz)
    netId = not stopped and int(netId)
    if not netId or netId < 0 or type(uid) ~= 'string' or #uid > 128 then return end
    if not (finite(x, 20000) and finite(y, 20000) and finite(z, 5000) and finite(rx, 3600) and finite(ry, 3600)
        and finite(rz, 3600)) then return end
    if not NetworkDoesEntityExistWithNetworkId(netId) then return end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity == 0 or not NetworkHasControlOfEntity(entity) or Entity(entity).state.mapEl ~= uid then return end
    -- keepTasks (a ped's scenario goes on), no IK reset, warp (no blend on the other machines)
    SetEntityCoordsNoOffset(entity, x + 0.0, y + 0.0, z + 0.0, true, false, true)
    if GetEntityType(entity) == 3 then
        SetEntityRotation(entity, rx + 0.0, ry + 0.0, rz + 0.0, 2, false)
    else
        SetEntityHeading(entity, (rz % 360) + 0.0)
    end
end)

--------------------------------------------------------------------------------
-- The editor audience: the server sends data kinds and editor-only helpers (flags 16/8) only to editors
-- (staff mode `editor`, or players in an open draft's bucket), deciding per window request. When the local
-- `editor` mode flips (core hook `staffSelfChanged (state)` from client/adminstate.lua, seeded from
-- `Core.Admin.getSelf()`), the window's versions are forgotten (content kept until the new packs land) and
-- the cached regions dropped, so the next answer resends each region for the new audience.
--------------------------------------------------------------------------------

local function isEditor(state)
    local modes = type(state) == 'table' and state.modes
    return type(modes) == 'table' and modes.editor ~= nil and modes.editor ~= false
end
local editorMode, editorSeeded = false, false

--- The current editor mode from client/adminstate.lua (looked up at call time: it may load after this file).
local function seedEditor()
    if editorSeeded then return end
    local admin = Core.Admin
    local getSelf = type(admin) == 'table' and admin.getSelf or nil
    if not Utils.isCallable(getSelf) then return end
    local ok, state = pcall(getSelf)
    if ok then editorMode, editorSeeded = isEditor(state), true end
end

local function audienceChanged()
    audience = audience + 1   -- answers to requests sent before this are ignored
    for key, r in pairs(regions) do
        -- recheck: left out of `h` until an answer after this change (a pack of the old audience that lands
        -- meanwhile must not make the region look current)
        if inWindow(key) then r.version, r.pending, r.withheld, r.recheck = nil, nil, false, true
        else dropRegion(r) end
    end
    requestWindow()   -- the request gap keeps it >= 300 ms after the previous one (server cooldown 250 ms)
end

Core.on('staffSelfChanged', function(state)
    if stopped then return end
    local on = isEditor(state)
    editorSeeded = true
    if on == editorMode then return end
    editorMode = on
    audienceChanged()
end)
seedEditor()

--------------------------------------------------------------------------------
-- The window thread: one camera read per 500 ms (1000 ms when still), and the map-entity sweep
--------------------------------------------------------------------------------

local function outside(x, y)
    local x0, y0 = crx * REGION, cry * REGION
    return x < x0 - HYST or x >= x0 + REGION + HYST or y < y0 - HYST or y >= y0 + REGION + HYST
end

--- A pack that was announced but never landed is asked for again (no allocation: 9 lookups).
local function checkPending(t)
    for dx = -1, 1 do
        for dy = -1, 1 do
            local r = regions[regionKey(crx + dx, cry + dy)]
            if r and r.pending and t - r.pendingAt >= PENDING_MS then
                r.pending = nil
                requestWindow()
            end
        end
    end
end

CreateThread(function()
    local loaded = false
    local lastX, lastY, still = nil, nil, 0
    while not stopped do
        if not loaded then
            loaded = LocalPlayer.state.loaded == true
            if loaded then seedEditor() end   -- before the first window request
        end
        if not loaded then
            Wait(LOADED_POLL_MS)   -- no session yet: the loading-screen camera is not worth streaming
        else
            local cam = GetFinalRenderedCamCoord()
            local x, y = cam.x, cam.y
            local t = GetGameTimer()
            if lastX and abs(x - lastX) + abs(y - lastY) < STILL_MOVE then still = still + 1 else still = 0 end
            lastX, lastY = x, y
            if not centre or outside(x, y) then
                recentre(floor(x / REGION), floor(y / REGION), t)
                requestWindow()
            elseif t - lastAnswerAt >= SAFETY_MS then
                requestWindow()   -- safety net: cheap "unchanged" answers
            else
                checkPending(t)
            end
            if nNet > 0 then netSweep() end
            Wait(still >= STILL_SAMPLES and STILL_SAMPLE_MS or SAMPLE_MS)
        end
    end
end)

--------------------------------------------------------------------------------
-- API (reachable by plugins through the client proxy)
--------------------------------------------------------------------------------

local function readCoords(c)
    local t = type(c)
    if t ~= 'vector3' and t ~= 'vector4' and t ~= 'table' then return nil end
    local x, y, z = c.x, c.y, c.z
    if not (finite(x, 20000) and finite(y, 20000) and finite(z, 5000)) then return nil end
    return x + 0.0, y + 0.0, z + 0.0
end

--- True when the regions around `coords` are current for our bucket and every element within
--- `radius` (default 50 m) that a camera there would want is spawned (or failed, or capped).
---@param coords vector3
---@param radius? number
---@return boolean
function Maps.isAreaReady(coords, radius)
    local x, y, z = readCoords(coords)
    if not x or bucket == nil then return false end
    radius = tonumber(radius) or AREA_RADIUS
    if radius ~= radius or radius < 0 then radius = 0.0 elseif radius > MAX_AREA then radius = MAX_AREA end
    for rx = floor((x - radius) / REGION), floor((x + radius) / REGION) do
        for ry = floor((y - radius) / REGION), floor((y + radius) / REGION) do
            local r = regions[regionKey(rx, ry)]
            if not r or not r.win or r.version == nil or r.pending or r.withheld or r.recheck or r.bucket ~= bucket
                or (r.want and r.want > r.version) then
                return false
            end
        end
    end
    return E.areaReady(x, y, z, radius)
end

--- Waits (in the calling thread) until `isAreaReady(coords)` or `timeoutMs` (default 5000) passed.
--- Moves the window onto `coords` first when they are outside it (a teleport lands before the camera).
---@param coords vector3
---@param timeoutMs? integer
---@return boolean ready
function Maps.waitAreaReady(coords, timeoutMs)
    local x, y = readCoords(coords)
    if not x then return false end
    local ms = int(tonumber(timeoutMs)) or DEFAULT_WAIT_MS
    if ms < 0 then ms = 0 elseif ms > MAX_WAIT_MS then ms = MAX_WAIT_MS end
    local deadline = GetGameTimer() + ms
    local rx, ry = floor(x / REGION), floor(y / REGION)
    if not centre or not inWindow(regionKey(rx, ry)) then
        recentre(rx, ry, GetGameTimer())
        requestWindow()
    end
    E.dirty()
    while not Maps.isAreaReady(coords, AREA_RADIUS) do
        if stopped or GetGameTimer() >= deadline then return false end
        Wait(WAIT_POLL_MS)
    end
    return true
end

--- The local object of a map element, or nil while it is not spawned.
---@param uid integer|string
---@return integer|nil
function Maps.handleOf(uid)
    uid = readUid(uid)
    if uid == nil then return nil end
    return E.handleOf(uid)
end

--- The map element uid of a local object the runtime spawned, or nil.
---@param entity integer
---@return integer|string|nil
function Maps.uidOf(entity)
    if math.type(entity) ~= 'integer' or entity == 0 then return nil end
    return E.uidOf(entity)
end

local function holdId(owner, uid)
    return owner .. '|' .. (type(uid) == 'string' and 's' or 'i') .. tostring(uid)
end

--- Keeps the runtime away from an element (no despawn, move or re-create) until released; returns
--- its entity when spawned. Owner-tracked: released when the holding resource stops.
---@param uid integer|string
---@return integer|nil
function Maps.hold(uid)
    uid = readUid(uid)
    if uid == nil then return nil end
    local owner = Registry.getCaller()
    local set = holders[uid]
    if not set then
        set = {}
        holders[uid] = set
    end
    if not set[owner] then
        set[owner] = true
        local id = holdId(owner, uid)
        holdIds[id] = uid
        Registry.track('mapHold', id, owner)
    end
    return E.setHeld(uid, true)
end

local function releaseFor(uid, owner)
    local set = holders[uid]
    if not set or not set[owner] then return false end
    set[owner] = nil
    holdIds[holdId(owner, uid)] = nil
    if next(set) == nil then
        holders[uid] = nil
        E.setHeld(uid, false)   -- applies what changed while held
    end
    return true
end

--- Gives the caller's hold back; the element takes its authoritative state again.
---@param uid integer|string
---@return boolean
function Maps.release(uid)
    uid = readUid(uid)
    if uid == nil then return false end
    local owner = Registry.getCaller()
    if not releaseFor(uid, owner) then return false end
    Registry.untrack('mapHold', holdId(owner, uid))
    return true
end

Registry.onOwnerStop('mapHold', function(id, owner)
    local uid = holdIds[id]
    if uid ~= nil then releaseFor(uid, owner) end
end)

--- Editor view for the calling resource: previews of data kinds and editor-only helpers within 150 m.
---@param on boolean
---@return boolean
function Maps.setEditorView(on)
    if type(on) ~= 'boolean' then return false end
    View.setEditorView(on, Registry.getCaller())
    return true
end

--- { regions, cached, elements, spawned, queued, models, failed, hides, ... } — a diagnostic snapshot.
---@return table
function Maps.stats()
    local s = E.stats()
    local loaded = 0
    for _, r in pairs(regions) do
        if r.version ~= nil then loaded = loaded + 1 end
    end
    s.regions, s.cached, s.bucket, s.centre = loaded, nRegions, bucket, centre
    s.hides, s.editorView = View.hideCount(), View.editorOn()
    return s
end

--------------------------------------------------------------------------------
-- Core stops: objects, hides and model requests go now
--------------------------------------------------------------------------------

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= selfName then return end
    stopped = true
    for _, r in pairs(regions) do View.clearHides(r) end
    E.shutdown()
end)

Core.Maps = Maps
