--[[ core — client/scene_materializer.lua — the materialiser of Core.Scene (DESIGN §55.11)
     The §52.4 engine (once client/maps_spawn.lua) generalised to every node class, plus the anti-pop pipeline of
     research R5 §9: 64 m client cells with conservative bounds, a zero-allocation evaluation, 2 x 16 priority
     bins instead of 16 m rings, per-frame budgets, caps with eviction of the farthest UNSEEN node, the
     object-pool guard, visibility-safe deletes, children, holds, handover, late binds, teleport mode. Its
     resources live in client/scene_mat_assets.lua (loaded right before it): C.assets (ref-counted models,
     anim dicts, ptfx assets with a linger, model caps, interiors) and C.fades (the slot-budgeted fade manager,
     whose hooks this file installs). Internal: it fills `C.mat` of the one-shot global `CoreSceneRuntime`
     (created by client/scene_cache.lua, cleared by client/scene.lua); nothing here is reachable by plugins.

     States: KNOWN -> WARM (assets requested) -> STAGED (created at alpha 0 waiting for a fade slot, or a create
     that answered C.mat.PENDING waiting for C.mat.bound — the plugin-kind bridge) -> LIVE -> RETIRING (deletion
     deferred while seen, fading out, or queued) -> gone (entity deleted, the record back to KNOWN, or dropped
     when the node was removed). FAILED (an asset failed, create refused 3 times, no bind within 5 s: never again
     this session) and OFF (no handler, placeholder kind) never materialise.
     Update vocabulary (the cache): 'fields' (data = changed names) | 'move' | 'motion' | 'dr' (the reused
     descriptor: the movers place it, no re-bind) | 'kind' | 'radius' | 'attach' | 'interact' | 'dep'; handlers
     hear them through update(node, handle, what, data) (answer false = re-create), never 'dr'.
     Core.Maps' elements are scene nodes since phase D (§55.21.1): the caps and the pool guard count them as props.

     Budget: a bare 500 ms sleep while nothing is known; otherwise one camera check (coord + rot + screen fade)
     per 100 ms moving / 500 ms still; the full evaluation runs when the camera moved >= 4 m or turned >= 10 deg or
     content changed (a thread evaluation yields a frame per 2,000 records); movers and retiring records alone get
     a light pass (O(movers + retiring), no grid walk); Wait(0) only while a queue holds work.
     GetLodscale + GetFinalRenderedCamFov + GetAspectRatio once per second; a LOD-scale change re-derives the
     radii in slices of 500 records per frame, and the cell bounds / maxReach are rebuilt the same way (also when
     the widest record left). Teleport mode (x10 budgets, no fades, no deferred deletes) = the screen is faded
     out; C.mat.setTeleport only marks a core teleport in progress. The Object pool size is learned (3,300 unless
     Config.Scene.ObjectPool; raised by a larger pool read, lowered by a refused create). Fades and movers run their
     own guarded per-frame loops that exist only while a fade runs / a mover is LIVE.

     Natives (fxref 2026-09-26 + runtime names checked in natives.json; apiset client unless noted; BOOL
     answers read by truthiness, DESIGN §30.4):
       GetGameTimer(), GetFinalRenderedCamCoord() -> vector3, GetFinalRenderedCamRot(rotationOrder) -> vector3,
       GetFinalRenderedCamFov() -> float, GetAspectRatio(physicalAspect) -> float (_GET_ASPECT_RATIO),
       GetLodscale() -> float, GetGamePool(poolName) (CFX shared), IsScreenFadedOut(),
       ForceRoomForEntity(entity, interior, roomHashKey), SetEntityAlpha(entity, alphaLevel, skin),
       ResetEntityAlpha(entity), SetEntityLodDist(entity, value), DoesEntityExist(entity), DeleteEntity(entity),
       SetEntityCoordsNoOffset(entity, x, y, z, xAxis, yAxis, zAxis),
       SetEntityRotation(entity, pitch, roll, yaw, rotationOrder, p5), IsEntityAttached(entity),
       AttachEntityToEntity(entity1, entity2, boneIndex, x, y, z, rx, ry, rz, p9, softPinning, collision, isPed,
       rotationOrder, fixedRot, p15), GetEntityType(entity), GetPedBoneIndex(ped, boneId),
       GetEntityBoneIndexByName(entity, boneName), GetEntityCoords(entity, alive),
       GetPlayerFromServerId(serverId) (CFX), GetPlayerPed(player), NetworkDoesEntityExistWithNetworkId(netId)
       (always before NetworkGetEntityFromNetworkId(netId)), GetCurrentResourceName() (CFX shared),
       SetEntityCollision(entity, toggle, keepPhysics), SetEntityVisible(entity, toggle, p2) (a world change, RV6 F3).
]]

local C = CoreSceneRuntime
assert(type(C) == 'table' and type(C.assets) == 'table' and type(C.fades) == 'table',
    'client/scene_materializer.lua loads right after client/scene_mat_assets.lua (CoreSceneRuntime.assets / .fades)')
local A, F = C.assets, C.fades   -- assets + interiors, the fade manager (client/scene_mat_assets.lua)
local startFade, cancelFade, fadeMs, slotFree = F.start, F.cancel, F.ms, F.slotFree

local floor, sqrt, abs, sin, cos, rad = math.floor, math.sqrt, math.abs, math.sin, math.cos, math.rad
local huge, tointeger = math.huge, math.tointeger

-- settings: Config.Scene, clamped, read once (the hot loops copy what they need into locals below)
local K <const> = {}
do
    local CS = (type(Config) == 'table' and type(Config.Scene) == 'table') and Config.Scene or {}
    local function sub(name)
        local v = CS[name]
        return type(v) == 'table' and v or {}
    end
    local function num(v, default, low, high)
        v = tonumber(v) or default
        if v ~= v or v < low then return low end
        return v > high and high or v
    end
    local BU, CA, RA, VI, SP, LE = sub('Budgets'), sub('Caps'), sub('Radii'), sub('Visibility'), sub('Speed'),
        sub('Lead')
    local propsCap = floor(num(CA.props, 3000, 1, 100000))
    -- F16: the Object pool is 3,300 unless Config.Scene.ObjectPool says otherwise (set it to 5,300 with server.cfg
    -- `increase_pool_size "Object" 2000`); the pool guard also LEARNS it: a read above the assumption raises it, a
    -- prop create refused below the limit lowers it (both logged once)
    local poolSize = floor(num(CS.ObjectPool, 3300, 100, 100000))
    K.poolSize, K.poolExplicit = poolSize, CS.ObjectPool ~= nil
    local propsPF = floor(num(BU.PropsPerFrame, 8, 1, 256))
    -- per-frame budgets (x TeleportMultiplier while the screen is faded out or a core teleport runs); creation
    -- groups: 1 props, 2 peds + vehicles (EntityPerFrame), 3 custom kinds, 4 fx / data / audio
    K.groupPF = { propsPF, floor(num(BU.EntityPerFrame, 1, 1, 64)), floor(num(BU.CustomPerFrame, 2, 1, 64)), propsPF }
    K.deletesPF = floor(num(BU.DeletesPerFrame, 32, 1, 1024))
    K.requestsPF = floor(num(BU.ModelRequestsPerFrame, 2, 1, 64))
    K.tpMult = floor(num(BU.TeleportMultiplier, 10, 1, 100))
    K.band, K.smallBand, K.margin = num(RA.Band, 20, 0, 500), num(RA.SmallBand, 5, 0, 500), num(RA.Margin, 10, 0, 500)
    K.warm, K.outMin, K.outFactor = num(RA.Warm, 50, 0, 1000), num(RA.OutMin, 20, 0, 1000), num(RA.OutFactor, 0.25, 0, 4)
    K.propCap, K.leadS, K.leadMax = num(RA.PropCap, 500, 50, 5000), num(LE.Seconds, 1.5, 0, 10), num(LE.Max, 150, 0, 2000)
    K.unseen, K.unseenImp = num(VI.UnseenMs, 1500, 0, 60000), num(VI.ImportantUnseenMs, 4000, 0, 60000)
    K.defer, K.swapMargin = num(VI.DeferMaxMs, 10000, 0, 600000), num(VI.SwapMargin, 10, 0, 1000)
    K.swapCooldown = num(VI.SwapCooldownMs, 100, 0, 60000)
    K.skipSmall, K.noFade = num(SP.SkipSmallAbove, 50, 0, 2000), num(SP.NoFadeAbove, 80, 0, 2000)
    K.poolLimit, K.poolWatch = poolSize * 0.85, propsCap * 0.6
    K.caps = CA                                -- per budget key; every custom kind gets Caps.custom of its own
    K.evalMove2, K.turnCos, K.moving2 = 16.0, 0.9848, 0.25   -- re-evaluate after 4 m / 10 deg; 0.5 m per check = moving
    K.movingMs, K.stillMs, K.pollMs, K.interiorMs = 100, 500, 50, 250
    K.releaseScanMs, K.lodMs, K.backoffMs, K.poolCheckMs = 1000, 1000, 1000, 10000
    K.handoverMs = 1000       -- a DEL(handover) keeps the entity this long for the PUT of the same id
    K.jumpSpeed = 300.0       -- faster than this between two checks = a teleport, not a velocity
    K.visits, K.evN = 64, 8   -- warm-queue entries looked at per frame; eviction candidates per budget
    K.bindMs = 5000           -- a create that answered PENDING and got no C.mat.bound this long failed
    K.slice = 500             -- records per frame of a sliced job (rescale, rebound)
    K.evalSlice = 2000        -- a thread evaluation yields a frame after this many records looked at
    K.reboundMs = 5000        -- at most one bounds rebuild per 5 s after the widest record left
end
local WARM_R <const>, SKIP_SMALL <const> = K.warm, K.skipSmall
local CELL <const> = 64                 -- client cell (m)
local NB <const> = 32                   -- priority bins per queue: 1..16 late arrivals, 17..32 the rest
local NEAR2 <const> = 25.0              -- within 5 m a node counts as seen whatever the frustum says

local KNOWN <const>, WARM <const>, STAGED <const>, LIVE <const>, RETIRING <const>, FAILED <const>, OFF <const> =
    0, 1, 2, 3, 4, 5, 6
local T <const> = {}       -- lookup tables of the cold paths
T.CLASS_NAME = { 'prop', 'vehicle', 'ped', 'fx', 'data', 'audio', 'custom' }   -- the wire's class codes
-- classes are interned strings (a pointer compare, like an integer): creation group, default budget, radius rule
local CLASS <const> = {
    prop = { g = 1, budget = 'props', rule = 'prop', model = true },
    vehicle = { g = 2, budget = 'vehicles', rule = 'veh', model = true },
    ped = { g = 2, budget = 'peds', rule = 'ped', model = true },
    fx = { g = 4, rule = 'custom', fade = 'self' }, data = { g = 4, rule = 'custom', fade = 'none' },
    audio = { g = 4, rule = 'range', fade = 'self' }, custom = { g = 3, budget = 'custom', rule = 'custom' },
}
T.KIND = {   -- built-in non-entity kinds: radius rule, budget, default drawDistance
    light = { rule = 'light', budget = 'lights' }, particle = { rule = 'draw', budget = 'particles', draw = 150 },
    marker = { rule = 'draw', budget = 'markers', draw = 50 }, text = { rule = 'draw', budget = 'texts', draw = 25 },
    hide = { rule = 'hide', budget = 'hides' }, zone = { rule = 'zone' }, sound = { rule = 'range', budget = 'sounds' },
}
T.FADE_OK = { engine = true, alpha = true, none = true, self = true }
-- 3 | 'world' is client-side only (never on the wire): the cache's bucket reset — the world changed (RV6 F3)
T.HOW = { [0] = 'normal', 'handover', 'fade', 'world', normal = 'normal', handover = 'handover', fade = 'fade',
    world = 'world' }
T.ASSET_NAME = { model = 'model', anim = 'anim dict', ptfx = 'ptfx asset' }

local mat = {}
local cache = C.cache
local handlers = {}                 -- kind id or class name -> handler
local recs, zombies = {}, {}        -- id -> record of a known node / of a removed node whose entity is still going
local byHandle, holders = {}, {}    -- entity -> record (or shell); id -> { [owner] = true }
local nNodes, nZombies = 0, 0
local counts = { [0] = 0, 0, 0, 0, 0, 0, 0 }
local live = {}                     -- budget key -> materialised count (shells included until deleted)
local evl = {}                      -- budget key -> eviction candidates { n, cap, on, d = { d2 } }, farthest first
local capBlocked = {}               -- budget key -> true: full and nothing evictable until the next evaluation
local grid = {}                     -- cell key -> { list, n, nDone, nAct, bounds, seen, seenAt }
-- intrusive lists { n, [i] = item } (the item keeps its index): cells with active nodes, movers, retiring
-- records, handover grace
local actL, movL, retL, hoL = { n = 0 }, { n = 0 }, { n = 0 }, { n = 0 }
local kidL = { n = 0 }                      -- roots whose children still have to be warmed / created
local orphL = { n = 0 }                     -- removed children whose root was still there (decided next pass)
local pendL = { n = 0 }                     -- records whose handler's create answered PENDING (late bind)
-- a handler's create may answer PENDING (the plugin-kind bridge: the entity comes from another VM later);
-- C.mat.bound(node, entity | 0) finishes it
local PENDING <const> = setmetatable({}, { __tostring = function() return 'C.mat.PENDING' end })
local stgQ, delQ = { h = 1, n = 0 }, { h = 1, n = 0 }   -- STAGED records waiting for a fade slot; deletions
local wbL, wbN, wbH = {}, {}, {}            -- warm queue: bins of records whose assets are wanted
local cbL, cbN, cbH = {}, {}, {}            -- create queues: [group][bin]
for b = 1, NB do wbL[b], wbN[b], wbH[b] = {}, 0, 1 end
for g = 1, 4 do
    cbL[g], cbN[g], cbH[g] = {}, {}, {}
    for b = 1, NB do cbL[g][b], cbN[g][b], cbH[g][b] = {}, 0, 1 end
end
local pauseUntil = { 0, 0, 0, 0 }           -- per creation group: a refused create backs off
local ctx = { late = false, seen = false, x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0 }
local EMPTY <const> = {}
-- the camera of the last check (cx..fz), its velocity, and the evaluation's lead / priority direction
local cx, cy, cz, fx, fy, fz, vx, vy, vz, speed = 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0
local camOk, camT, moving = false, 0, false
local evc = { x = 0.0, y = 0.0, z = 0.0, fx = 0.0, fy = 1.0, fz = 0.0, ok = false }   -- the last evaluation's camera
local rfx, rfy, rfz, lead, leadK = 0.0, 1.0, 0.0, 0.0, 0.0
local cosV2 = 0.36                          -- cos^2 of the view cone's half angle
local fr = { cosH = 0.6, sinH = 0.8, tanV = 0.47, fov = -1.0, aspect = -1.0 }   -- the cone; tan(vertical fov / 2)
local S = 1.0                               -- GetLodscale()
local teleport, forcedTp = false, false
local poolCount, poolOwnAt, poolAt, ownProps = 0, 0, -huge, 0
local evalId, qgen, maxReach = 0, 0, 0.0
local nCells, nearCap, reachDirty = 0, false, false   -- cells in `grid`; a budget near its cap; maxReach may shrink
local snap = {}                     -- reused snapshot array of the sliced jobs (rescale, rebound)
local dirty, recheck, stopped = false, false, false
local lightPass = false             -- a light pass (movers / retiring only) does not collect eviction candidates
local listener = nil
local stat = { evaluations = 0, created = 0, deleted = 0, evicted = 0, failed = 0, poolChecks = 0,
    lastEvalCells = 0, lastEvalNodes = 0, lightEvaluations = 0, lastLightNodes = 0,
    rescaleSlices = 0, rebounds = 0 }
local warned = {}
local now = GetGameTimer
local function KEEP() end                   -- fade-out callback of children: their parent deletes them

local function logWarn(fmt, ...)
    local log = Core.Log
    if log and log.warn then log.warn('scene: ' .. fmt, ...) else print(('[core] scene: ' .. fmt):format(...)) end
end

local function warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    logWarn(fmt, ...)
end

--- Core.Clock.now() (network time) when the lib is there, else the game timer.
local function netNow()
    local clock = Core.Clock
    local fn = clock and clock.now
    if fn then return fn() end
    return GetGameTimer()
end

local function ladd(L, x, f)
    local i = x[f]
    if i and i ~= 0 then return end     -- already listed: never twice (a stale entry would never leave)
    local n = L.n + 1
    L.n, L[n], x[f] = n, x, n
end

local function lrem(L, x, f)
    local i = x[f]
    if not i or i == 0 then return end
    local n = L.n
    local last = L[n]
    L[i], last[f] = last, i
    L[n], L.n, x[f] = nil, n - 1, 0
end

--- A root (or a child on the way) whose children still have to be warmed or created: every evaluation queues
--- the roots of this list, even from a cell it skips as resolved.
local function setKidsDue(p, on)
    p.kidsDue = on
    if on then
        if p.ki == 0 then ladd(kidL, p, 'ki') end
    elseif p.ki ~= 0 then
        lrem(kidL, p, 'ki')
    end
end

--------------------------------------------------------------------------------
-- States and the 64 m cells (conservative bounds: they only grow until a rescale)
--------------------------------------------------------------------------------

local function isDone(st) return st == LIVE or st >= FAILED end       -- nothing to do while the camera stays
local function isActive(st) return st ~= KNOWN and st < FAILED end    -- holds assets or an entity

local function setSt(m, st)
    local was = m.st
    if was == st then return end
    m.st = st
    counts[was], counts[st] = counts[was] - 1, counts[st] + 1
    local c = m.cell
    if not c then return end
    local wd, nd = isDone(was), isDone(st)
    if wd ~= nd then c.nDone = c.nDone + (nd and 1 or -1) end
    local wa, na = isActive(was), isActive(st)
    if wa ~= na then
        c.nAct = c.nAct + (na and 1 or -1)
        if na then
            if c.nAct == 1 then ladd(actL, c, 'ai') end
        elseif c.nAct == 0 then
            lrem(actL, c, 'ai')
        end
    end
end

local function bounds(c, m)
    local rIn = m.rInB or m.rIn
    if rIn < c.minIn then c.minIn = rIn end
    local reach = m.reach
    if reach > c.maxReach then c.maxReach = reach end
    if reach > maxReach then maxReach = reach end
    local z = m.z
    if z < c.minZ then c.minZ = z end
    if z > c.maxZ then c.maxZ = z end
end

local function index(m)
    local gx, gy = floor(m.x / CELL), floor(m.y / CELL)
    local key = (gx + 32768) * 65536 + (gy + 32768)
    local c = grid[key]
    if not c then
        c = { key = key, x0 = gx * CELL, y0 = gy * CELL, list = {}, n = 0, nDone = 0, nAct = 0, ai = 0,
            minIn = huge, maxReach = 0.0, minZ = huge, maxZ = -huge, seen = 0, seenAt = -huge }
        grid[key] = c
        nCells = nCells + 1
    end
    local n = c.n + 1
    c.n, c.list[n], m.cell, m.ci = n, m, c, n
    local st = m.st
    if isDone(st) then c.nDone = c.nDone + 1 end
    if isActive(st) then
        c.nAct = c.nAct + 1
        if c.nAct == 1 then ladd(actL, c, 'ai') end
    end
    bounds(c, m)
end

local function unindex(m)
    local c = m.cell
    if not c then return end
    if c.seenAt > m.seenAt then m.seenAt = c.seenAt end   -- the cell's seen stamp survives the move
    local i, n = m.ci, c.n
    local last = c.list[n]
    c.list[i], last.ci = last, i
    c.list[n], c.n = nil, n - 1
    local st = m.st
    if isDone(st) then c.nDone = c.nDone - 1 end
    if isActive(st) then
        c.nAct = c.nAct - 1
        if c.nAct == 0 then lrem(actL, c, 'ai') end
    end
    m.cell, m.ci = nil, 0
    if m.reach >= maxReach then reachDirty = true end   -- the widest record left: the bounds may shrink (F18)
    if c.n == 0 then
        grid[c.key] = nil
        nCells = nCells - 1
    end
end

--- Takes a record out of the cells / the mover list.
local function unplace(m)
    if m.cell then unindex(m) end
    if m.mi ~= 0 then
        lrem(movL, m, 'mi')
        if m.reach >= maxReach then reachDirty = true end
    end
end

--- Puts a record where the evaluation finds it: movers in their list, roots in a cell, children nowhere
--- (they ride their root), OFF records nowhere.
local function place(m)
    if m.isKid or m.st == OFF then return end
    if m.mover then
        ladd(movL, m, 'mi')
        if m.reach > maxReach then maxReach = m.reach end
    else
        index(m)
    end
end

--------------------------------------------------------------------------------
-- Assets (C.assets, client/scene_mat_assets.lua): a record holds its refs in `ae`; interiors gate entity kinds
--------------------------------------------------------------------------------

local function unwarm(m, t)
    local ae = m.ae
    if ae then
        m.ae = nil
        A.drop(ae, t)
    end
    if m.intWait then A.unwait(m) end
    if m.st == WARM then setSt(m, KNOWN) end
end

local function fail(m, t)
    unwarm(m, t)
    setSt(m, FAILED)
    stat.failed = stat.failed + 1
end

--- Requests the node's assets (C.assets.acquire). -> new requests made | -1 over this frame's request budget |
--- -2 failed | -3 a model cap is full | -4 ModelsInFlight streaming (-3 / -4: retried once something changed).
local function warm(m, t, left, fresh)
    local hd = m.h
    local used = 0
    if hd.assets then
        local ok, list = pcall(hd.assets, m.node)
        if not ok then
            warnOnce('assets:' .. tostring(m.kid), 'assets() of kind %s failed: %s', tostring(m.kid), tostring(list))
        elseif type(list) == 'table' and #list > 0 then
            local ae, bad
            used, ae, bad = A.acquire(list, m.cls, m.kid, t, left, fresh)
            if used < 0 then
                if used == -3 then     -- refused this generation (areaReady does not wait for it); a model slot
                    m.capGen, recheck = qgen, true   -- frees when another node goes: evaluate again next check
                end
                return used
            end
            m.ae = ae
            if bad then
                fail(m, t)
                return -2
            end
        end
    end
    setSt(m, WARM)
    if CLASS[m.cls].model and not m.mover and not m.isKid then A.interior(m) end
    return used
end

--------------------------------------------------------------------------------
-- Handlers, radii, poses
--------------------------------------------------------------------------------

--- kind id, class name of a node (the cache's kind table carries the class as a code or a name).
local function kindOf(node)
    local k = node.kind
    if type(k) ~= 'table' then return nil, nil end
    local cls = k.class
    if type(cls) == 'number' then cls = T.CLASS_NAME[cls] end
    return k.id, cls
end

--- The node's handler: by kind id, else by class ('custom' = the plugin bridge). None for placeholders.
local function handlerOf(node)
    local kid, cname = kindOf(node)
    if type(kid) ~= 'string' or kid == '' then return nil, nil end
    local fl = type(node.flags) == 'number' and tointeger(node.flags) or 0
    if fl and fl & 4 ~= 0 then return nil, kid end
    return handlers[kid] or (cname and handlers[cname]) or nil, kid
end

--- rVis / rIn / rOut of the §55.11 table (or the handler's own), the ped's out-of-view pair, the lod clamp.
local function computeRadii(m)
    local node, rule = m.node, m.rule
    local f = type(node.fields) == 'table' and node.fields or EMPTY
    local rVis, rIn, rOut, rInB, rOutB
    m.lodClamp = nil
    local hd = m.h
    if hd.radii then
        local ok, a, b, c = pcall(hd.radii, node, S)
        if ok and tonumber(a) and tonumber(b) and tonumber(c) then rVis, rIn, rOut = a + 0.0, b + 0.0, c + 0.0 end
    end
    if rVis then   -- the handler's
    elseif rule == 'prop' then
        local L = tonumber(f.lod) or 100
        if L < 1 then L = 1 end
        local B = L <= 20 and K.smallBand or K.band
        rVis = L * S + B
        if rVis + K.margin > K.propCap then   -- clamp the entity's lodDist so the engine band lands inside
            local lod = floor((K.propCap - B - K.margin) / S)
            if lod < 1 then lod = 1 end
            m.lodClamp = lod
            rVis = lod * S + B
        end
        rIn = rVis + K.margin
        local o = K.outFactor * rIn
        rOut = rIn + (o > K.outMin and o or K.outMin)
    elseif rule == 'veh' then
        rVis, rIn, rOut = 500.0, 255.0, 311.0
    elseif rule == 'ped' then
        rVis, rIn, rOut, rInB, rOutB = 240.0, 130.0, 140.0, 75.0, 90.0
    elseif rule == 'range' then
        local r = tonumber(f.range) or tonumber(node.radius) or 40.0
        rVis, rIn, rOut = r, r + 20.0, r + 40.0
    elseif rule == 'light' then
        local r = tonumber(f.range) or 10.0
        rVis, rIn = r * 3.0, r * 3.0 + 50.0
        if rIn > 300.0 then rIn = 300.0 end
        rOut = rIn + 30.0
    elseif rule == 'draw' then
        local r = tonumber(f.drawDistance) or m.drawDef
        rVis, rIn, rOut = r, r + 10.0, r + 30.0
    elseif rule == 'hide' then
        local r = tonumber(f.radius) or 10.0
        rVis, rIn, rOut = 0.0, r + 150.0, r + 200.0
    elseif rule == 'zone' then
        local r = tonumber(f.r) or tonumber(node.radius) or 50.0
        rVis, rIn, rOut = 0.0, r + 20.0, r + 40.0
    else
        local r = tonumber(node.radius) or 100.0
        local o = K.outFactor * r
        rVis, rIn, rOut = r, r, r + (o > K.outMin and o or K.outMin)
    end
    m.rVis, m.rVis2, m.rIn, m.rOut, m.rInB, m.rOutB = rVis, rVis * rVis, rIn, rOut, rInB, rOutB
    local reach = rIn + WARM_R
    m.reach = rOut > reach and rOut or reach
end

--- Binds a record to its handler: class, creation group, fade mode, budget and cap, radius rule, radii.
--- false = no handler (the record stays OFF).
local function bind(m)
    local node = m.node
    local hd, kid = handlerOf(node)
    m.h, m.kid = hd, kid
    local f = node.fields
    m.model = type(f) == 'table' and f.model or nil
    local pid = node.parent
    if pid ~= nil and pid ~= 0 then m.pid = pid end   -- sticky: a cache that zeroes it on removal changes nothing
    m.isKid = m.pid ~= nil
    m.mover = not m.isKid and (node.motion ~= nil or node.attach ~= nil)
    if not hd then return false end
    local _, cname = kindOf(node)
    local cls = (CLASS[hd.class] and hd.class) or (CLASS[cname] and cname) or 'custom'
    local cd, kd = CLASS[cls], T.KIND[kid] or EMPTY
    m.cls, m.grp = cls, cd.g
    local fade = (T.FADE_OK[hd.fade] and hd.fade) or cd.fade or 'engine'
    m.fade, m.fadeable = fade, fade == 'engine' or fade == 'alpha'
    local meta = node.kind.meta
    local budget = hd.budget or (type(meta) == 'table' and meta.budget) or kd.budget or cd.budget
    if type(budget) == 'string' then
        local key = budget == 'custom' and kid or budget
        local cap = floor(tonumber(K.caps[budget]) or tonumber(K.caps.custom) or 64)
        m.bk, m.capN = key, cap
        if not evl[key] then evl[key] = { n = 0, cap = cap, on = false, d = {} } end
        if not live[key] then live[key] = 0 end
    else
        m.bk, m.capN = nil, huge
    end
    m.rule, m.drawDef = kd.rule or cd.rule, kd.draw or 50.0
    m.unseen = (cls == 'ped' or cls == 'vehicle') and K.unseenImp or K.unseen
    computeRadii(m)
    return true
end

local function setPose(m)
    local node = m.node
    m.x, m.y, m.z = node.x or 0.0, node.y or 0.0, node.z or 0.0
    m.rx, m.ry, m.rz = node.rx or 0.0, node.ry or 0.0, node.rz or 0.0
end

--- The entity an attach descriptor names: `{ p | player = src }` a player's ped, `{ n | net = netId }` a
--- networked entity, `{ node = id }` another node's entity. 0 = not on this client right now.
local function targetOf(a)
    if type(a) ~= 'table' then return 0 end
    local src = a.p or a.player
    if type(src) == 'number' then
        local player = GetPlayerFromServerId(src)
        if not player or player == -1 then return 0 end
        local ped = GetPlayerPed(player)
        return (ped and ped ~= 0 and DoesEntityExist(ped)) and ped or 0
    end
    local net = a.n or a.net
    if type(net) == 'number' then
        if net <= 0 or not NetworkDoesEntityExistWithNetworkId(net) then return 0 end
        local e = NetworkGetEntityFromNetworkId(net)
        return (e and e ~= 0 and DoesEntityExist(e)) and e or 0
    end
    local other = a.node and (recs[a.node] or zombies[a.node])
    local h = other and other.handle
    return type(h) == 'number' and h or 0
end

--- The current position of a mover: its attach target, else its motion at network time `tn`, else the base.
local function livePose(m, tn, Motion)
    local node = m.node
    local att = node.attach
    if att ~= nil then
        local e = targetOf(att)
        if e ~= 0 then
            local p = GetEntityCoords(e, false)
            m.x, m.y, m.z = p.x, p.y, p.z
            return
        end
    elseif node.motion ~= nil and Motion then
        m.x, m.y, m.z, m.rx, m.ry, m.rz = Motion.pose(node.x or 0.0, node.y or 0.0, node.z or 0.0, node.rx or 0.0,
            node.ry or 0.0, node.rz or 0.0, node.motion, tn)
        return
    end
    setPose(m)
end

--- The pose a record is indexed / created at: a mover's live pose (its first Motion.pose builds a path's
--- arc-length table: this runs in the cache's event handler, never first inside a per-frame loop), else the base.
local function pose0(m)
    if m.mover then livePose(m, netNow(), Core.SceneMotion) else setPose(m) end
end

local function vec3(t)
    local ty = type(t)
    if ty ~= 'table' and ty ~= 'vector3' then return 0.0, 0.0, 0.0 end
    return tonumber(t.x or t[1]) or 0.0, tonumber(t.y or t[2]) or 0.0, tonumber(t.z or t[3]) or 0.0
end

--- World pose of child record `k` riding `p` (a record or { x, y, z, rx, ry, rz }): p's pose, then the
--- child's offset rotated by p's rotation (order 2: R = Rz(yaw) * Rx(pitch) * Ry(roll)); rotations add up.
local function compose(k, p)
    local node = k.node
    local ox, oy, oz = vec3(node.offset)
    local orx, ory, orz = vec3(node.offrot)
    local a, b, c = rad(p.rx), rad(p.ry), rad(p.rz)
    local sp, cp, sr, cr, sw, cw = sin(a), cos(a), sin(b), cos(b), sin(c), cos(c)
    k.x = p.x + (cw * cr - sw * sp * sr) * ox - sw * cp * oy + (cw * sr + sw * sp * cr) * oz
    k.y = p.y + (sw * cr + cw * sp * sr) * ox + cw * cp * oy + (sw * sr - cw * sp * cr) * oz
    k.z = p.z - cp * sr * ox + sp * oy + cp * cr * oz
    k.rx, k.ry, k.rz = p.rx + orx, p.ry + ory, p.rz + orz
end

--- Bone index on `parent` for a node's `bone` (a name, a ped bone tag, or an index); 0 = the root.
local function boneOf(parent, bone)
    if type(bone) == 'string' and bone ~= '' then
        local i = GetEntityBoneIndexByName(parent, bone)
        return (type(i) == 'number' and i >= 0) and i or 0
    end
    if type(bone) ~= 'number' or bone < 0 then return 0 end
    if GetEntityType(parent) == 1 then return GetPedBoneIndex(parent, bone) end
    return bone
end

--- AttachEntityToEntity with the node's offset / offrot / bone, in the node's rotation order (`rotOrder` 0..5 from
--- the wire, else the engine's 2), the 16-argument form.
local function attachTo(h, parent, node)
    local ox, oy, oz = vec3(node.offset)
    local rx, ry, rz = vec3(node.offrot)
    AttachEntityToEntity(h, parent, boneOf(parent, node.bone), ox, oy, oz, rx, ry, rz, false, false, false, true,
        node.rotOrder or 2, true, 0)
end

--------------------------------------------------------------------------------
-- Camera, frustum, LOD scale
--------------------------------------------------------------------------------

--- The view cone from the vertical FOV and the window's aspect: half the frustum's diagonal + 10 deg of margin
--- (R5 §9 B7) — wide screens widen it.
local function setFrustum(fov, aspect)
    fr.fov, fr.aspect = fov, aspect
    fr.tanV = math.tan(rad(fov * 0.5))
    local d = math.atan(fr.tanV * sqrt(1.0 + aspect * aspect)) + rad(10)
    if d > 1.55 then d = 1.55 end
    fr.cosH, fr.sinH = cos(d), sin(d)
    cosV2 = fr.cosH * fr.cosH
end
setFrustum(50.0, 16 / 9)

local function readCamera(t)
    local c = GetFinalRenderedCamCoord()
    local r = GetFinalRenderedCamRot(2)
    local x, y, z = c.x, c.y, c.z
    local dt = (t - camT) * 0.001
    if camOk and dt > 0 and dt < 2.0 then
        local dx, dy, dz = x - cx, y - cy, z - cz
        local d2 = dx * dx + dy * dy + dz * dz
        moving = d2 >= K.moving2
        local s = sqrt(d2) / dt
        if s > K.jumpSpeed then
            vx, vy, vz, speed = 0.0, 0.0, 0.0, 0.0
        else
            vx, vy, vz, speed = dx / dt, dy / dt, dz / dt, s
        end
    elseif not camOk or dt >= 2.0 then
        vx, vy, vz, speed, moving = 0.0, 0.0, 0.0, 0.0, false
    end
    cx, cy, cz, camT, camOk = x, y, z, t, true
    local p, yw = rad(r.x), rad(r.z)
    local cp = cos(p)
    fx, fy, fz = -sin(yw) * cp, cos(yw) * cp, sin(p)
end

--- Radii of every record again (the LOD scale moved > 5 %), cell bounds rebuilt, live props re-clamped.
--- Exact cell bounds and `maxReach` again (they only grow in between): <= K.slice records per frame, Wait(0) in
--- between — this runs in the materialiser's thread, which yields; cells emptied or replaced meanwhile are skipped,
--- records added meanwhile widened their cell already. F18: a far-reaching record that left stops costing.
local function rebound()
    reachDirty = false
    local n = 0
    for _, c in pairs(grid) do
        n = n + 1
        snap[n] = c
    end
    local done = 0
    for i = 1, n do
        local c = snap[i]
        snap[i] = nil
        if grid[c.key] == c then
            c.minIn, c.maxReach, c.minZ, c.maxZ = huge, 0.0, huge, -huge
            local list = c.list
            for j = 1, c.n do bounds(c, list[j]) end
            done = done + c.n
            if done >= K.slice then
                done = 0
                Wait(0)   -- per-frame: a sliced job yields one frame after each slice of <= K.slice records
                if stopped then return end
            end
        end
    end
    local r = 0.0                         -- the exact maximum: every cell is exact or grew since
    for _, c in pairs(grid) do
        if c.maxReach > r then r = c.maxReach end
    end
    for i = 1, movL.n do
        local m = movL[i]
        if m.reach > r then r = m.reach end
    end
    maxReach = r
    stat.rebounds = stat.rebounds + 1
end

--- Radii of every record again (the LOD scale moved > 5 %), sliced like rebound (F5: a scope toggle must never be
--- one 3–15 ms frame); each record switches on its own, live props re-clamped as they come, then rebound().
local function rescaleAll()
    local n = 0
    for _, m in pairs(recs) do
        n = n + 1
        snap[n] = m
    end
    for i = 1, n do
        local m = snap[i]
        snap[i] = nil
        if m.h and not m.dropped and recs[m.id] == m then
            local old = m.lodClamp
            computeRadii(m)
            local c = m.cell
            if c then bounds(c, m) elseif m.reach > maxReach then maxReach = m.reach end
            local h = m.handle
            if m.lodClamp ~= old and m.cls == 'prop' and type(h) == 'number' then
                local f = m.node.fields
                SetEntityLodDist(h, m.lodClamp or floor(tonumber(type(f) == 'table' and f.lod) or 100))
            end
        end
        if i % K.slice == 0 then
            stat.rescaleSlices = stat.rescaleSlices + 1
            Wait(0)   -- per-frame: a sliced job yields one frame after each slice of K.slice records
            if stopped then return end
        end
    end
    stat.rescaleSlices = stat.rescaleSlices + 1
    rebound()
    dirty = true                          -- radii changed: evaluate with them
end

local function sampleLod()
    local s = tonumber(GetLodscale()) or 1.0
    if s ~= s or s < 0.1 then s = 1.0 elseif s > 10.0 then s = 10.0 end
    local fov = tonumber(GetFinalRenderedCamFov()) or 50.0
    if fov ~= fov or fov < 1.0 or fov > 170.0 then fov = 50.0 end
    local aspect = tonumber(GetAspectRatio(false)) or 16 / 9
    if aspect ~= aspect or aspect < 0.5 or aspect > 8.0 then aspect = 16 / 9 end
    if fov ~= fr.fov or aspect ~= fr.aspect then setFrustum(fov, aspect) end
    if abs(s - S) > 0.05 * S then
        S = s
        rescaleAll()
    end
end

--- Fresh frustum test of a record with the current camera (also refreshes m.d2).
local function viewNow(m)
    local dx, dy, dz = m.x - cx, m.y - cy, m.z - cz
    local d2 = dx * dx + dy * dy + dz * dz
    m.d2 = d2
    if d2 > m.rVis2 then return false end
    if d2 < NEAR2 then return true end
    local fd = dx * fx + dy * fy + dz * fz
    return fd > 0 and fd * fd >= cosV2 * d2
end

--- When the record was last seen: its own stamp, or its cell's (cells skipped as resolved stamp the cell).
local function seenOf(m)
    local c, s = m.cell, m.seenAt
    if c and c.seenAt > s then return c.seenAt end
    return s
end

--------------------------------------------------------------------------------
-- Fades (C.fades, client/scene_mat_assets.lua): who fades is decided here; children fade with their parent
--------------------------------------------------------------------------------

local finishDelete, destroyKids   -- defined below

local function fadesAllowed() return not teleport and speed <= K.noFade end

--- A record's materialised children (`p.kl`, each child keeps its index in `kli` and its parent in `par`): the
--- materialiser's own list, so a root's fade / deletion covers its subtree whatever the cache did to its lists.
local function kidAdd(p, k)
    if k.par == p then return end
    local kl = p.kl
    if not kl then
        kl = {}
        p.kl = kl
    end
    local n = #kl + 1
    kl[n], k.kli, k.par = k, n, p
end

local function kidRemove(k)
    local p = k.par
    if not p then return end
    local kl, i = p.kl, k.kli
    local n = #kl
    local last = kl[n]
    kl[n] = nil
    if i < n then
        kl[i] = last
        last.kli = i
    end
    k.par, k.kli = nil, 0
end

--- Fades every materialised entity child of `p` the same way (children ride and reveal with their parent).
local function kidsFade(p, dir, t)
    local kl = p.kl
    if not kl then return end
    for i = #kl, 1, -1 do
        local k = kl[i]
        local h = k.handle
        if type(h) == 'number' then
            if not startFade(h, dir, fadeMs(k.cls, dir < 0), k.cls == 'vehicle', nil, dir < 0 and KEEP or nil, t)
                and dir > 0 then
                ResetEntityAlpha(h)
            end
            kidsFade(k, dir, t)
        end
    end
end

--- A slot freed: the oldest STAGED records start their fade-in (all of them at once when fades are off).
local function nextStaged(t)
    local allowed = fadesAllowed()
    while stgQ.h <= stgQ.n do
        local m = stgQ[stgQ.h]
        local h = m.handle
        if m.st == STAGED and type(h) == 'number' then
            if allowed then
                if not slotFree(m.cls == 'vehicle') then return end
                startFade(h, 1, fadeMs(m.cls), m.cls == 'vehicle', m, nil, t)
            else
                ResetEntityAlpha(h)
            end
            m.hidden = false
            setSt(m, LIVE)
        end
        stgQ[stgQ.h], stgQ.h = nil, stgQ.h + 1
    end
    stgQ.h, stgQ.n = 1, 0
end

-- the fade manager's hooks: a faded-out owner is deleted here, a freed slot reveals the next STAGED records
F.hooks(function(owner, t) finishDelete(owner, t) end,
    function(t) if stgQ.h <= stgQ.n then nextStaged(t) end end)

--------------------------------------------------------------------------------
-- Materialise, delete, release (visibility-safe), children, eviction, the pool guard
--------------------------------------------------------------------------------

local function liveAdd(x, d)
    local bk = x.bk
    if bk then live[bk] = live[bk] + d end
    if x.cls == 'prop' then ownProps = ownProps + d end
end

local function notify(event, node, h)
    if not listener then return end
    local ok, err = pcall(listener, event, node, h)
    if not ok then warnOnce('listener:' .. event, 'scene listener failed on %s: %s', event, tostring(err)) end
end

--- Does child `k` need the mover loop (a non-entity riding a moving ancestor)?
local function riderMoves(k)
    local p = k.par
    while p do
        if p.mover then return true end
        p = p.par
    end
    return false
end

--- fm: 0 plain, 1 fade in now, 2 STAGED at alpha 0 until a fade slot frees. `counted`: a late bind (the cap
--- and stats counted it when its create answered PENDING).
local function materialise(m, h, t, fm, counted)
    m.handle = h
    local ent = type(h) == 'number'
    if ent then
        byHandle[h] = m
        if m.int and m.int ~= 0 and m.roomKey then ForceRoomForEntity(h, m.int, m.roomKey) end
    end
    if not counted then
        liveAdd(m, 1)
        stat.created = stat.created + 1
    end
    if ent and fm == 1 and not startFade(h, 1, fadeMs(m.cls), m.cls == 'vehicle', m, nil, t) then fm = 2 end
    if ent and fm == 2 then
        SetEntityAlpha(h, 0, false)
        m.hidden = true
        setSt(m, STAGED)
        local n = stgQ.n + 1
        stgQ.n, stgQ[n] = n, m
    else
        m.hidden = false
        setSt(m, LIVE)
    end
    local mv = C.movers
    if mv and (m.mover or (m.isKid and not ent and riderMoves(m))) then mv.track(m.node, h, m.h) end
    notify('live', m.node, h)
end

--- The handler's create answered PENDING: STAGED, counted against its cap, no fade until C.mat.bound.
local function pendingStart(m, t)
    m.handle, m.pendAt = PENDING, t
    liveAdd(m, 1)
    stat.created = stat.created + 1
    setSt(m, STAGED)
    ladd(pendL, m, 'pi')
end

local function drop(m)
    counts[m.st] = counts[m.st] - 1
    if zombies[m.id] == m then zombies[m.id], nZombies = nil, nZombies - 1 end
    if m.ri ~= 0 then lrem(retL, m, 'ri') end
    if m.hi ~= 0 then lrem(hoL, m, 'hi') end
    if m.ki ~= 0 then lrem(kidL, m, 'ki') end
    if m.pi ~= 0 then lrem(pendL, m, 'pi') end
    if m.oi ~= 0 then lrem(orphL, m, 'oi') end
    if m.intWait then A.unwait(m) end
    m.dropped = true
end

--- Deletes now: children first, the handler's destroy, DeleteEntity if still there, assets back.
-- fxlint-disable-next-line C003 -- assigns the forward-declared local `finishDelete` (fades and children call it)
finishDelete = function(x, t)
    x.delq = false
    local h = x.handle
    if h == nil then return end
    if h == PENDING then            -- never bound: the handler hears destroy(node, nil) and cleans up its own
        if (x.pi or 0) ~= 0 then lrem(pendL, x, 'pi') end
        x.handle = nil
        liveAdd(x, -1)
        local hd = x.h
        if hd and hd.destroy then pcall(hd.destroy, x.node, nil) end
        if x.shell then return end
        kidRemove(x)
        if x.dead then drop(x) else setSt(x, KNOWN) end
        return
    end
    if not x.shell then
        destroyKids(x, t)
        kidRemove(x)
        if x.ri ~= 0 then lrem(retL, x, 'ri') end
        local mv = C.movers
        if mv and (x.mvi or 0) ~= 0 then mv.untrack(x.node) end
    end
    local ent = type(h) == 'number'
    if ent then cancelFade(h) end
    local hd = x.h
    if hd and hd.destroy then
        local ok, err = pcall(hd.destroy, x.node, h)
        if not ok then warnOnce('destroy:' .. tostring(x.kid), 'destroy() of kind %s failed: %s', tostring(x.kid), tostring(err)) end
    end
    if ent then
        if DoesEntityExist(h) then DeleteEntity(h) end
        if byHandle[h] == x then byHandle[h] = nil end
    end
    x.handle = nil
    liveAdd(x, -1)
    stat.deleted = stat.deleted + 1
    local ae = x.ae
    if ae then
        x.ae = nil
        A.drop(ae, t)
    end
    if x.shell then return end
    notify('gone', x.node, h)
    if x.dead then drop(x) else setSt(x, KNOWN) end
end

-- fxlint-disable-next-line C003 -- assigns the forward-declared local `destroyKids` (finishDelete calls it)
destroyKids = function(p, t)
    local kl = p.kl
    if not kl then return end
    for i = #kl, 1, -1 do
        local k = kl[i]
        if k then finishDelete(k, t) end
    end
end

local function pushDelete(x, t)
    if x.delq then return end
    x.delq = true
    if not x.shell then
        if x.ri ~= 0 then lrem(retL, x, 'ri') end
        if x.st ~= RETIRING then
            setSt(x, RETIRING)
            x.retireAt = t
        end
    end
    local n = delQ.n + 1
    delQ.n, delQ[n] = n, x
end

local function fadeOut(m, t)
    local h = m.handle
    if not startFade(h, -1, fadeMs(m.cls, true), m.cls == 'vehicle', m, nil, t) then return false end
    if m.ri ~= 0 then lrem(retL, m, 'ri') end
    kidsFade(m, -1, t)
    return true
end

--- A deletion is wanted: at once when the entity cannot be seen (beyond R_vis, STAGED, unseen for UnseenMs,
--- no entity, the handler fades itself, the screen is faded); otherwise RETIRING until unseen (<= DeferMaxMs,
--- then a fade-out). 'fade' fades a visible one out right away.
local function release(m, t, how)
    if m.held then return end
    local st = m.st
    if st == WARM then
        unwarm(m, t)
        return
    end
    local h = m.handle
    if h == nil or h == PENDING then return end   -- PENDING: the bind (or its timeout) decides
    if st == RETIRING then
        if how == 'fade' and not m.delq and not F.dir(h) and fadesAllowed() and type(h) == 'number' then
            fadeOut(m, t)
        end
        return
    end
    if st == STAGED or type(h) ~= 'number' or not m.fadeable or teleport then
        pushDelete(m, t)
        return
    end
    local vis = viewNow(m)
    if vis then m.seenAt = t end
    if not vis and (m.d2 > m.rVis2 or t - seenOf(m) >= m.unseen) then
        pushDelete(m, t)
        return
    end
    setSt(m, RETIRING)
    m.retireAt = t
    if how == 'fade' and fadesAllowed() and fadeOut(m, t) then return end
    ladd(retL, m, 'ri')
end

--- Wanted again while RETIRING: the pending deletion is cancelled, a fade-out turns back into a fade-in.
local function unretire(m, t)
    m.delq, m.retireAt = false, nil
    if m.ri ~= 0 then lrem(retL, m, 'ri') end
    if m.hidden then                   -- still at alpha 0: back in line for a fade slot
        setSt(m, STAGED)
        local n = stgQ.n + 1
        stgQ.n, stgQ[n] = n, m
        return
    end
    local h = m.handle
    if type(h) == 'number' and F.dir(h) == -1 then
        startFade(h, 1, fadeMs(m.cls), m.cls == 'vehicle', m, nil, t)
        kidsFade(m, 1, t)
    end
    setSt(m, LIVE)
end

--- RV6 F4: a node that left the wanted set loses its prompts NOW, even while its entity still retires or fades
--- (C.kinds keys every kind's prompts by node id: entity kinds, fx, world kinds, the plugin-kind bridge).
function T.unprompt(m)
    local kinds = C.kinds
    local fn = kinds and kinds.clearInteract
    if not fn then return end
    local ok, err = pcall(fn, m.id)
    if ok then m.unprompted = true
    else warnOnce('unprompt', 'clearing the prompts of node %s failed: %s', tostring(m.id), tostring(err)) end
end

--- RV6 F3: the node's world is gone (a routing-bucket change): its entity stops colliding and is hidden this frame,
--- then deleted by the queue — no visibility-safe deferral, no fade, no hand-over; a child rides its root's deletion.
function T.worldGone(m, t)
    local h = m.handle
    if type(h) == 'number' and DoesEntityExist(h) then
        SetEntityCollision(h, false, false)
        SetEntityVisible(h, false, false)
    end
    local p = m.isKid and m.par
    if not (p and p.dead) then pushDelete(m, t) end
end

--- The retiring records, each check: unseen long enough -> delete; deferred too long -> fade out.
local function retireCheck(t)
    local i = 1
    while i <= retL.n do
        local m = retL[i]
        local h = m.handle
        local gone = false
        if not m.held and h ~= nil then
            local vis = viewNow(m)
            if vis then m.seenAt = t end
            if teleport or (not vis and (m.d2 > m.rVis2 or t - seenOf(m) >= m.unseen)) then
                pushDelete(m, t)
                gone = true
            elseif t - m.retireAt >= K.defer and not F.dir(h) then
                if not fadesAllowed() then
                    pushDelete(m, t)
                    gone = true
                else
                    gone = fadeOut(m, t)
                end
            end
        end
        if not gone then i = i + 1 end
    end
end

--- Assets of a record (and its children) loaded? -> ready, failed.
local function ready(m)
    local ae = m.ae
    if ae then
        for i = 1, #ae do
            local st = ae[i].st
            if st ~= 'loaded' then return false, st == 'failed' end
        end
    end
    local ids = m.node.children
    if type(ids) == 'table' then
        for i = 1, #ids do
            local k = recs[ids[i]]
            if k and k.h and k.handle == nil and k.st ~= FAILED and k.st ~= OFF then
                if k.st ~= WARM then return false, false end
                local ok, failed = ready(k)
                if not ok and not failed then return false, false end
            end
        end
    end
    return true, false
end

--- Creates the children of materialised `p` in the same slot (after it), attached when both are entities
--- (unless the kind's handler already attached it), revealed like the parent. Missing ones retry later.
local function createKids(p, t, fm)
    local ids = p.node.children
    if type(ids) ~= 'table' then return end
    local missing = false
    for i = 1, #ids do
        local id = ids[i]
        local k = recs[id]
        if not k and cache.node then
            local kn = cache.node(id)
            if kn then
                mat.add(kn)
                k = recs[id]
            end
        end
        if k and k.h and k.handle == nil and k.st ~= FAILED and k.st ~= OFF then
            local ok, failed = false, false
            if k.st == WARM then ok, failed = ready(k) end
            if failed then
                fail(k, t)
            elseif not ok or (k.bk and live[k.bk] >= k.capN) then
                missing = true
            else
                compose(k, p)
                ctx.late, ctx.seen = p.late == true, fm > 0
                ctx.x, ctx.y, ctx.z, ctx.rx, ctx.ry, ctx.rz = k.x, k.y, k.z, k.rx, k.ry, k.rz
                k.creating, k.early = true, nil
                local okc, h = pcall(k.h.create, k.node, ctx)
                k.creating = false
                if okc and h == PENDING and k.early ~= nil then h = k.early == 0 and true or k.early end
                k.early = nil
                if okc and h == PENDING then
                    pendingStart(k, t)
                    kidAdd(p, k)
                elseif okc and h ~= nil and h ~= false and h ~= 0 then
                    local ph = p.handle
                    if type(h) == 'number' and type(ph) == 'number' and not IsEntityAttached(h) then
                        attachTo(h, ph, k.node)
                    end
                    kidAdd(p, k)             -- before materialise: a moving parent makes a non-entity child a mover
                    materialise(k, h, t, fm)
                    createKids(k, t, fm)
                else
                    if not okc then
                        warnOnce('create:' .. tostring(k.kid), 'create() of kind %s failed: %s', tostring(k.kid), tostring(h))
                    end
                    missing = true
                end
            end
        end
    end
    setKidsDue(p, missing)
end

local function evInsert(ev, m, d2)
    local n, d = ev.n, ev.d
    if n == K.evN and d2 <= d[n] then return end
    local i = n < K.evN and n + 1 or n
    while i > 1 and d[i - 1] < d2 do
        ev[i], d[i] = ev[i - 1], d[i - 1]
        i = i - 1
    end
    ev[i], d[i] = m, d2
    if n < K.evN then ev.n = n + 1 end
end

--- A cap is full: the farthest UNSEEN live node of the budget goes when the newcomer is >= SwapMargin closer
--- and was not itself swapped out in the last SwapCooldownMs. A visible one never goes.
local function evict(m, t)
    local ev = evl[m.bk]
    if not ev or ev.n == 0 or t - (m.relAt or -huge) < K.swapCooldown then return false end
    local need = sqrt(m.d2) + K.swapMargin
    need = need * need
    local d = ev.d
    for i = 1, ev.n do
        local v = ev[i]
        if v then
            if d[i] < need then return false end   -- farthest first: the rest are closer still
            ev[i] = false
            if v.st == LIVE and not v.held and not v.dead and v.handle ~= nil and v.bk == m.bk and not viewNow(v)
                and t - seenOf(v) >= v.unseen then
                v.relAt = t
                stat.evicted = stat.evicted + 1
                finishDelete(v, t)
                v.capGen = qgen              -- refused by the cap: areaReady does not wait for it
                return true
            end
        end
    end
    return false
end

--- #GetGamePool('CObject') only after a refused create or above 60 % of the props cap, at most every 10 s.
--- `refused`: a prop create just failed — read now (>= 1 s since the last read) and learn the real pool size.
local function poolCheck(t, force, refused)
    if t - poolAt < (refused and 1000 or K.poolCheckMs) then return end
    if not force and ownProps <= K.poolWatch then return end
    local pool = GetGamePool('CObject')
    poolCount = type(pool) == 'table' and #pool or 0
    poolAt, poolOwnAt = t, ownProps
    stat.poolChecks = stat.poolChecks + 1
    if poolCount > K.poolSize then          -- more objects than the assumed pool holds: it was raised
        K.poolSize = poolCount > 5300 and poolCount or 5300
        K.poolLimit = K.poolSize * 0.85
        warnOnce('pool:raised', 'object pool: %d objects seen, more than assumed — the pool guard now allows up to '
            .. '%d (set Config.Scene.ObjectPool to the real size)', poolCount, floor(K.poolLimit))
    elseif refused and poolCount < K.poolLimit and poolCount >= K.poolSize * 0.5 then
        K.poolSize, K.poolLimit = poolCount, poolCount * 0.85   -- the game refused: the pool is about this full
        warnOnce('pool:learned', 'a prop create was refused at %d objects: the Object pool is smaller than assumed; '
            .. 'the pool guard now stops at %d (increase_pool_size "Object" 2000 + Config.Scene.ObjectPool = 5300 '
            .. 'raise it)', poolCount, floor(K.poolLimit))
    end
end

--- The old entity of a record whose model / kind / handler changed goes (faded when seen) through a shell;
--- the record re-queues from KNOWN and its new entity fades in by the usual rules.
local function toShell(m, t)
    local h = m.handle
    local s = { shell = true, handle = h, node = m.node, h = m.h, ae = m.ae, cls = m.cls, bk = m.bk, kid = m.kid }
    destroyKids(m, t)
    local mv = C.movers
    if mv and (m.mvi or 0) ~= 0 then mv.untrack(m.node) end
    if m.ri ~= 0 then lrem(retL, m, 'ri') end
    if m.pi ~= 0 then lrem(pendL, m, 'pi') end   -- a PENDING create goes with its shell (destroy(node, nil))
    kidRemove(m)
    local ent = type(h) == 'number'
    if ent then
        if byHandle[h] == m then byHandle[h] = s end
        F.owner(h, s)                  -- a running fade now belongs to the shell
    end
    m.handle, m.ae, m.delq, m.retireAt = nil, nil, false, nil
    setSt(m, KNOWN)
    notify('gone', m.node, h)
    if ent and m.fadeable and not m.hidden and fadesAllowed() and viewNow(m)
        and startFade(h, -1, fadeMs(s.cls, true), s.cls == 'vehicle', s, nil, t) then
        return
    end
    pushDelete(s, t)
end

--- Handler or kind changed (registerKind, a kind table update): the old materialisation goes, the record
--- binds again (OFF without a handler) and re-queues.
local function rebind(m, t)
    if m.handle ~= nil then toShell(m, t) end
    if m.st == WARM then unwarm(m, t) end
    unplace(m)
    if bind(m) then
        if m.st ~= KNOWN then setSt(m, KNOWN) end
    else
        setSt(m, OFF)
    end
    pose0(m)
    place(m)
    dirty = true
end

--- A node changed (C.mat.update / a re-add): same handler -> radii, pose and index again; the entity is
--- updated in place (handler.update) or re-created through the queues when the model changed or update()
--- answered false. A held node keeps its entity untouched; the change applies on release.
local function changed(m, what, data, t)
    local node = m.node
    local hd, kid = handlerOf(node)
    if hd ~= m.h or kid ~= m.kid then
        if m.held and m.handle ~= nil then m.recreate = true else rebind(m, t) end
        return
    end
    if not hd then return end
    local oldModel = m.model
    unplace(m)
    bind(m)
    pose0(m)
    place(m)
    local h = m.handle
    if h == PENDING then
        if m.model ~= oldModel then toShell(m, t) end   -- a new model: the pending create is dropped
    elseif h ~= nil then
        if m.held then
            m.moved = true
            if m.model ~= oldModel then m.recreate = true end
        else
            local again = m.model ~= oldModel
            if not again and hd.update and what ~= 'dr' then   -- a dr pose is the movers' business
                local ok, res = pcall(hd.update, node, h, what, data)
                if not ok then
                    warnOnce('update:' .. tostring(kid), 'update() of kind %s failed: %s', tostring(kid), tostring(res))
                elseif res == false then
                    again = true
                end
            elseif not again and what == 'move' and type(h) == 'number' then
                SetEntityCoordsNoOffset(h, m.x, m.y, m.z, false, false, false)
                SetEntityRotation(h, m.rx, m.ry, m.rz, 2, false)
            end
            if again then
                toShell(m, t)
            else
                local mv = C.movers
                if mv then   -- a new or late plan blends from what is on screen (200 ms)
                    if m.mover then mv.track(node, h, hd, true) elseif (m.mvi or 0) ~= 0 then mv.untrack(node) end
                end
            end
        end
    elseif m.st == WARM then
        unwarm(m, t)                       -- its asset list may differ now: re-queued from KNOWN
    elseif m.st == FAILED and m.model ~= oldModel then
        setSt(m, KNOWN)
    end
    dirty = true
end

--------------------------------------------------------------------------------
-- Evaluation (camera moved >= 4 m / turned >= 10 deg, content changed, movers or retiring records exist):
-- cells within reach only, whole cells skipped when out of range or resolved, no allocation
--------------------------------------------------------------------------------

--- Queues a record into a priority bin: late arrivals (inside R_vis) first, then k = (d / R_in)^2 x (0.35 +
--- 0.65 f), f = 0.5 - 0.5 cos(angle to the camera forward, or to the velocity above 8 m/s).
local function enqueue(m, d2, rIn, dx, dy, dz, warmIt)
    if m.qg == qgen then return end     -- queued already in this generation (a light pass re-visits movers)
    local late = d2 <= m.rVis2
    m.late, m.urgent = late, d2 < 0.0625 * rIn * rIn
    local d = sqrt(d2)
    local k = 0.0
    if d > 0.001 then k = d2 / (rIn * rIn) * (0.675 - 0.325 * (dx * rfx + dy * rfy + dz * rfz) / d) end
    local b = floor(k * 8.0)
    if b > 15 then b = 15 end
    b = (late and 1 or 17) + b
    m.bin, m.qg = b, qgen
    if warmIt then
        local n = wbN[b] + 1
        wbN[b], wbL[b][n] = n, m
    else
        local g = m.grp
        local N = cbN[g]
        local n = N[b] + 1
        N[b], cbL[g][b][n] = n, m
    end
end

local function visit(m, t)
    local st = m.st
    if st >= FAILED then return end
    local dx, dy, dz = m.x - cx, m.y - cy, m.z - cz
    local d2 = dx * dx + dy * dy + dz * dz
    m.d2 = d2
    local vis = false
    if d2 <= m.rVis2 then
        if d2 < NEAR2 then
            vis = true
        else
            local fd = dx * fx + dy * fy + dz * fz
            vis = fd > 0 and fd * fd >= cosV2 * d2
        end
        if vis then m.seenAt = t end
    end
    local rIn, rOut = m.rIn, m.rOut
    if m.rInB and not vis then rIn, rOut = m.rInB, m.rOutB end   -- peds: out of view is created later, kept less
    if lead > 0 then                                               -- ahead within +-60 deg of the velocity
        local vd = dx * vx + dy * vy + dz * vz
        if vd > 0 and vd * vd >= leadK * d2 then rIn, rOut = rIn + lead, rOut + lead end
    end
    if st == LIVE or st == STAGED then
        if d2 > rOut * rOut then
            if not m.held then release(m, t, 'normal') end
        else
            local bk = m.bk
            local ev = bk and evl[bk]
            if ev and ev.on and not lightPass and st == LIVE and not vis and not m.held and t - seenOf(m) >= m.unseen then
                evInsert(ev, m, d2)
            end
        end
    elseif st == RETIRING then
        if d2 <= rIn * rIn then unretire(m, t) end
    else
        local rw = rIn + WARM_R
        if d2 <= rw * rw then
            if speed > SKIP_SMALL and m.cls == 'prop' then   -- projected size at R_vis under 4 px (1080p): skipped
                local f = m.node.fields
                if (type(f) == 'table' and tonumber(f.r) or 2.0) * 540.0 < 4.0 * m.rVis * fr.tanV then
                    m.capGen, recheck = qgen, true   -- evaluated again when the camera slows down
                    return
                end
            end
            local inR = d2 <= rIn * rIn
            m.inR = inR
            if st == KNOWN or m.kidsDue then
                enqueue(m, d2, rIn, dx, dy, dz, true)
            elseif inR then
                enqueue(m, d2, rIn, dx, dy, dz, false)
            end
        elseif st == WARM and d2 > (rOut + WARM_R) * (rOut + WARM_R) then
            unwarm(m, t)
        end
    end
end

--- A record in a cell wholly out of reach: release what it holds.
local function farOut(m, t)
    local st = m.st
    if st == WARM then
        unwarm(m, t)
    elseif (st == LIVE or st == STAGED) and not m.held then
        local dx, dy, dz = m.x - cx, m.y - cy, m.z - cz
        m.d2 = dx * dx + dy * dy + dz * dz
        release(m, t, 'normal')
    end
end

--- Could any part of the cell be in view? (its bounding sphere against the widened view cone)
local function cellView(c)
    local dx, dy, dz = c.x0 + 32.0 - cx, c.y0 + 32.0 - cy, (c.minZ + c.maxZ) * 0.5 - cz
    local r = 45.26 + (c.maxZ - c.minZ) * 0.5
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 <= r * r then return true end
    local d = sqrt(d2)
    local s = r / d
    return (dx * fx + dy * fy + dz * fz) / d >= fr.cosH * sqrt(1.0 - s * s) - fr.sinH * s
end

--- One cell of the evaluation: wholly out of reach -> only what it holds goes; wholly in range and resolved ->
--- skipped (its seen stamp kept by the view cone); else every record visited. -> records looked at
local function evalCell(c, t)
    c.seen = evalId
    local x0, y0 = c.x0, c.y0
    local x1, y1 = x0 + CELL, y0 + CELL
    local ndx = cx < x0 and x0 - cx or (cx > x1 and cx - x1 or 0.0)
    local ndy = cy < y0 and y0 - cy or (cy > y1 and cy - y1 or 0.0)
    local cr = c.maxReach + lead
    local list, n = c.list, c.n
    if ndx * ndx + ndy * ndy > cr * cr then
        if c.nAct == 0 then return 0 end
        for i = n, 1, -1 do farOut(list[i], t) end
        return n
    end
    local fdx = cx - x0 > x1 - cx and cx - x0 or x1 - cx
    local fdy = cy - y0 > y1 - cy and cy - y0 or y1 - cy
    local z1, z2 = abs(cz - c.minZ), abs(cz - c.maxZ)
    local fdz = z1 > z2 and z1 or z2
    if c.nDone == n and not nearCap and fdx * fdx + fdy * fdy + fdz * fdz <= c.minIn * c.minIn then
        if cellView(c) then c.seenAt = t end
        return 0
    end
    for i = n, 1, -1 do visit(list[i], t) end
    return n
end

--- Movers: their live pose, then the usual visit; an ended motion settles into a cell at its last pose (a new
--- motion makes it a mover again). -> movers looked at
local function moverPass(t)
    local n = movL.n
    if n == 0 then return 0 end
    local Motion = Core.SceneMotion
    local tn = netNow()
    for i = n, 1, -1 do
        local m = movL[i]
        livePose(m, tn, Motion)
        local node = m.node
        if node.attach == nil and Motion and Motion.finished(node.motion, tn) then
            lrem(movL, m, 'mi')
            m.mover = false
            index(m)
            m.cell.seen = evalId             -- reached by this evaluation (the sweep of unreached cells skips it)
        end
        visit(m, t)
    end
    return n
end

--- The light pass (F4): nothing changed and the camera stayed, but movers move and retiring records wait for
--- "unseen" — O(movers + retiring), no grid walk, no queue rebuild (a still camera costs next to nothing).
local function evaluateLight(t)
    lightPass = true
    local looked = moverPass(t)
    retireCheck(t)
    lightPass = false
    stat.lightEvaluations, stat.lastLightNodes = stat.lightEvaluations + 1, looked + retL.n
end

--- `canYield`: called by the thread — a big evaluation (after a rescale, a teleport into a dense area) yields a frame
--- after every K.evalSlice records looked at instead of costing one long frame (the slot walk stays valid across
--- the yield; cells created meanwhile are caught by the sweep below).
local function evaluate(t, canYield)
    evalId, qgen = evalId + 1, qgen + 1
    dirty, recheck = false, false
    for b = 1, NB do
        local L = wbL[b]
        for i = 1, wbN[b] do L[i] = nil end
        wbN[b], wbH[b] = 0, 1
    end
    for g = 1, 4 do
        local B, N, H = cbL[g], cbN[g], cbH[g]
        for b = 1, NB do
            local L = B[b]
            for i = 1, N[b] do L[i] = nil end
            N[b], H[b] = 0, 1
        end
    end
    for key in pairs(capBlocked) do capBlocked[key] = nil end
    lead = speed >= 1.0 and speed * K.leadS or 0.0
    if lead > K.leadMax then lead = K.leadMax end
    leadK = 0.25 * speed * speed                  -- cos(60 deg)^2 x |v|^2
    if speed > 8.0 then
        rfx, rfy, rfz = vx / speed, vy / speed, vz / speed
    else
        rfx, rfy, rfz = fx, fy, fz
    end
    nearCap = false                     -- a budget near its cap needs every live node as an eviction candidate
    for key, ev in pairs(evl) do
        ev.n = 0
        ev.on = live[key] >= ev.cap - K.evN
        if ev.on then nearCap = true end
    end
    local reach = maxReach + lead
    local gx0, gx1 = floor((cx - reach) / CELL), floor((cx + reach) / CELL)
    local gy0, gy1 = floor((cy - reach) / CELL), floor((cy + reach) / CELL)
    local visited, looked = 0, 0
    if (gx1 - gx0 + 1) * (gy1 - gy0 + 1) > nCells then
        for _, c in pairs(grid) do          -- fewer cells than slots in the square: walk the cells themselves
            visited = visited + 1
            looked = looked + evalCell(c, t)
        end
    else
        local mark = 0
        for gx = gx0, gx1 do
            for gy = gy0, gy1 do
                local c = grid[(gx + 32768) * 65536 + (gy + 32768)]
                if c then
                    visited = visited + 1
                    looked = looked + evalCell(c, t)
                    if canYield and looked - mark >= K.evalSlice then
                        mark = looked
                        Wait(0)   -- per-frame: a big evaluation yields one frame per K.evalSlice records
                        if stopped then return end
                    end
                end
            end
        end
    end
    looked = looked + moverPass(t)
    for i = kidL.n, 1, -1 do                 -- roots with children to warm / create, skipped cells included
        local m = kidL[i]
        local st = m.st
        if not m.isKid and m.qg ~= qgen and (st == LIVE or st == STAGED or st == WARM) and not m.dead then
            local dx, dy, dz = m.x - cx, m.y - cy, m.z - cz
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 <= m.rOut * m.rOut then enqueue(m, d2, m.rIn, dx, dy, dz, true) end
        end
    end
    for i = actL.n, 1, -1 do                 -- active cells this evaluation did not reach (beyond its reach, or
        local c = actL[i]                    -- created while it yielded: then evaluated now)
        if c and c.seen ~= evalId then
            local x0, y0 = c.x0, c.y0
            local ndx = cx < x0 and x0 - cx or (cx > x0 + CELL and cx - x0 - CELL or 0.0)
            local ndy = cy < y0 and y0 - cy or (cy > y0 + CELL and cy - y0 - CELL or 0.0)
            if ndx * ndx + ndy * ndy <= reach * reach then
                looked = looked + evalCell(c, t)
            else
                local list = c.list
                for j = c.n, 1, -1 do farOut(list[j], t) end
            end
        end
    end
    retireCheck(t)
    evc.x, evc.y, evc.z, evc.fx, evc.fy, evc.fz, evc.ok = cx, cy, cz, fx, fy, fz, true
    stat.evaluations, stat.lastEvalCells, stat.lastEvalNodes = stat.evaluations + 1, visited, looked
end

--------------------------------------------------------------------------------
-- One frame of work: asset requests, creations per group, deletions — each within its budget
--------------------------------------------------------------------------------

--- Warms a record and its KNOWN children (a group streams in as one). -> requests used | -1..-4 (warm()).
local function warmTree(m, t, left, fresh)
    local used = 0
    if m.st == KNOWN then
        used = warm(m, t, left, fresh)
        if used < 0 then return used end
    end
    local ids = m.node.children
    if type(ids) == 'table' then
        for i = 1, #ids do
            local id = ids[i]
            local k = recs[id]
            if not k and cache.node then
                local kn = cache.node(id)
                if kn then
                    mat.add(kn)
                    k = recs[id]
                end
            end
            if k and k.h and (k.st == KNOWN or k.kidsDue) then
                local u = warmTree(k, t, left - used, fresh and used == 0)
                if u == -1 or u == -4 then
                    setKidsDue(m, true)
                    return used
                end
                if u > 0 then used = used + u end
            end
        end
    end
    setKidsDue(m, false)
    return used
end

local function tryCreate(m, t, g)
    if m.qg ~= qgen or m.st ~= WARM or m.handle ~= nil or m.dead or not m.h then return 'skipped' end
    local node = m.node
    local wanted = cache.wanted
    if wanted and not wanted(node) then return 'skipped' end
    local ok, failed = ready(m)
    if failed then
        fail(m, t)
        return 'skipped'
    end
    if not ok or m.intWait then return 'skipped' end
    local bk = m.bk
    if bk and live[bk] >= m.capN and (capBlocked[bk] or not evict(m, t)) then
        capBlocked[bk], m.capGen = true, qgen
        recheck = true                  -- unseen timers and swap cooldowns run out: evaluate again next check
        return 'skipped'
    end
    if m.cls == 'prop' then
        if ownProps > K.poolWatch then poolCheck(t, false) end
        if poolCount + ownProps - poolOwnAt >= K.poolLimit then   -- no new props above 85 % of the pool
            pauseUntil[g], m.capGen, recheck = t + K.backoffMs, qgen, true
            return 'stopped'
        end
    end
    local vis = viewNow(m)
    local fm = 0
    if vis and m.fadeable and (m.late or m.fade == 'alpha') and fadesAllowed() then
        if slotFree(m.cls == 'vehicle') then
            fm = 1
        elseif m.urgent and stgQ.n - stgQ.h + 1 < F.max() then
            fm = 2
        else
            recheck = true              -- a non-urgent late arrival waits for a fade slot
            return 'skipped'
        end
    end
    ctx.late, ctx.seen = m.late == true, vis
    ctx.x, ctx.y, ctx.z, ctx.rx, ctx.ry, ctx.rz = m.x, m.y, m.z, m.rx, m.ry, m.rz
    m.creating, m.early = true, nil
    local okc, h = pcall(m.h.create, node, ctx)
    m.creating = false
    if not okc then
        warnOnce('create:' .. tostring(m.kid), 'create() of kind %s failed: %s', tostring(m.kid), tostring(h))
        fail(m, t)
        return 'skipped'
    end
    if h == PENDING then
        local early = m.early          -- C.mat.bound ran inside create (a synchronous round trip)
        m.early = nil
        if early == nil then
            pendingStart(m, t)
            return 'created'
        end
        h = early == 0 and true or early
    end
    if h == nil or h == false or h == 0 then    -- refused (a full pool, a wrong model): the class backs off
        local n = (m.fails or 0) + 1
        m.fails = n
        if n >= 3 then
            fail(m, t)
            warnOnce('refused:' .. tostring(m.kid) .. ':' .. tostring(m.model), 'kind %s (model %s) was refused 3 '
                .. 'times; the node stays unmaterialised this session', tostring(m.kid), tostring(m.model))
        end
        pauseUntil[g], recheck = t + K.backoffMs, true
        if m.cls == 'prop' then poolCheck(t, true, true) end
        return 'stopped'
    end
    m.fails = 0
    materialise(m, h, t, fm)
    createKids(m, t, fm)
    return 'created'
end

--- Returns true while a queue still holds work for the next frame.
local function step(t)
    local mult = teleport and K.tpMult or 1
    local busy = false
    -- 1. assets: <= ModelRequestsPerFrame new requests (<= ModelsInFlight streaming), in priority order
    local full = K.requestsPF * mult
    local left, visits, stop, idle = full, 0, false, false
    for b = 1, NB do
        local L, n, i = wbL[b], wbN[b], wbH[b]
        while i <= n and not stop do
            if visits >= K.visits * mult then
                stop = true
            else
                visits = visits + 1
                local m = L[i]
                local used = 0
                if m.qg == qgen and not m.dead and m.h and (m.st == KNOWN or m.kidsDue) then
                    used = warmTree(m, t, left, left == full)
                end
                if used == -1 or used == -4 then
                    stop = true             -- out of requests: this record is first in line next frame
                    idle = used == -4       -- ModelsInFlight: nothing to do until a load finishes (poll -> dirty)
                else
                    i = i + 1
                    if used > 0 then left = left - used end
                    if m.handle ~= nil then
                        if not m.kidsDue and m.handle ~= PENDING then
                            createKids(m, t, (fadesAllowed() and viewNow(m) and m.fadeable) and 1 or 0)
                        end
                    elseif m.st == WARM and m.inR and m.qg == qgen then
                        local g, bin = m.grp, m.bin
                        local N = cbN[g]
                        local k = N[bin] + 1
                        N[bin], cbL[g][bin][k] = k, m
                    end
                end
            end
        end
        wbH[b] = i
        if i <= n and not idle then busy = true end
        if stop then break end
    end
    -- 2. creations: <= the group's per-frame budget, late arrivals first, then by priority
    for g = 1, 4 do
        if t >= pauseUntil[g] then
            local budget, made, halt = K.groupPF[g] * mult, 0, false
            local B, N, H = cbL[g], cbN[g], cbH[g]
            for b = 1, NB do
                local L, n, i = B[b], N[b], H[b]
                while i <= n do
                    if made >= budget then
                        halt = true
                        break
                    end
                    local r = tryCreate(L[i], t, g)
                    i = i + 1
                    if r == 'created' then
                        made = made + 1
                    elseif r == 'stopped' then   -- the group backs off (pool guard, refused create)
                        halt = true
                        break
                    end
                end
                H[b] = i
                if halt then
                    if t >= pauseUntil[g] then busy = true end
                    break
                end
            end
        end
    end
    -- 3. deletions
    local dels, dmax = 0, K.deletesPF * mult
    while delQ.h <= delQ.n and dels < dmax do
        local x = delQ[delQ.h]
        delQ[delQ.h], delQ.h = nil, delQ.h + 1
        if x.delq then
            finishDelete(x, t)
            dels = dels + 1
        end
    end
    if delQ.h > delQ.n then delQ.h, delQ.n = 1, 0 else busy = true end
    return busy
end

CreateThread(function()
    --- Late binds that never came (K.bindMs): the handler hears destroy(node, nil); the node fails once (logged).
    local function pendingCheck(t)
        local i = 1
        while i <= pendL.n do
            local m = pendL[i]
            if m.pi ~= i or m.handle ~= PENDING then   -- stale (defensive): out of the list, nothing to time out
                local n = pendL.n
                local last = pendL[n]
                pendL[n], pendL.n = nil, n - 1
                if m.pi == i then m.pi = 0 end
                if i < n then
                    pendL[i] = last
                    if last.pi == n then last.pi = i end
                end
            elseif t - m.pendAt >= K.bindMs then
                lrem(pendL, m, 'pi')
                m.handle = nil
                liveAdd(m, -1)
                local hd = m.h
                if hd and hd.destroy then pcall(hd.destroy, m.node, nil) end
                warnOnce('bind:' .. tostring(m.kid), 'kind %s did not bind a node within %d ms; such nodes stay '
                    .. 'unmaterialised this session', tostring(m.kid), K.bindMs)
                if m.dead then drop(m) else fail(m, t) end
            else
                i = i + 1
            end
        end
    end

    --- Children removed while their root stayed: if the root was removed meanwhile (the same flush), the child
    --- rides it; otherwise it leaves on its own by the root's visibility (faded when the root is seen).
    local function orphanCheck(t)
        while orphL.n > 0 do
            local m = orphL[orphL.n]
            lrem(orphL, m, 'oi')
            local h, p = m.handle, m.par
            if m.dead and h ~= nil and not m.held and not (p and p.dead) then
                if type(h) == 'number' and p and p.handle ~= nil and m.fadeable and fadesAllowed() and viewNow(p)
                    and fadeOut(m, t) then
                    setSt(m, RETIRING)
                else
                    pushDelete(m, t)
                end
            end
        end
    end

    --- DEL(handover) records whose re-add did not come: normal (visibility-safe) removal.
    local function handoverCheck(t)
        local i = 1
        while i <= hoL.n do
            local m = hoL[i]
            if t >= m.hoUntil then
                lrem(hoL, m, 'hi')
                T.unprompt(m)                -- it did not come back: its prompts go with it (RV6 F4)
                release(m, t, 'normal')
            else
                i = i + 1
            end
        end
    end

    local nextCheck, nextLod, nextPoll, nextInt, nextRel, nextRebound = 0, 0, 0, 0, 0, 0
    while not stopped do
        local t = GetGameTimer()
        if nNodes == 0 and nZombies == 0 and delQ.n == 0 and A.loading() == 0 and A.lingering() == 0 and not dirty then
            camOk, evc.ok = false, false     -- nothing known, nothing to clean up: no camera read at all
            Wait(K.stillMs)
        else
            if t >= nextCheck or dirty then
                readCamera(t)
                if t >= nextLod then
                    sampleLod()                  -- may run a sliced rescale (yields between slices)
                    nextLod = t + K.lodMs
                end
                if reachDirty and t >= nextRebound then
                    rebound()                    -- sliced; the widest record left (F18)
                    nextRebound = t + K.reboundMs
                end
                teleport = IsScreenFadedOut() and true or false   -- F7: only a faded screen lifts budgets / fades
                local ex, ey, ez = cx - evc.x, cy - evc.y, cz - evc.z
                if dirty or recheck or not evc.ok or ex * ex + ey * ey + ez * ez >= K.evalMove2
                    or fx * evc.fx + fy * evc.fy + fz * evc.fz < K.turnCos then
                    local ok, err = pcall(evaluate, t, true)
                    if not ok then
                        dirty = false
                        logWarn('evaluation failed: %s', tostring(err))
                    end
                elseif movL.n > 0 or retL.n > 0 then
                    local ok, err = pcall(evaluateLight, t)
                    if not ok then
                        lightPass = false
                        warnOnce('light', 'light evaluation failed: %s', tostring(err))
                    end
                end
                if stgQ.h <= stgQ.n then nextStaged(t) end
                if hoL.n > 0 then handoverCheck(t) end
                if pendL.n > 0 then pendingCheck(t) end
                nextCheck = t + ((moving or forcedTp) and K.movingMs or K.stillMs)
            end
            if A.loading() > 0 and t >= nextPoll then
                if A.poll(t) then dirty = true end   -- something loaded or failed: its waiters re-queue
                nextPoll = t + K.pollMs
            end
            if A.interiorsPending() > 0 and t >= nextInt then
                if A.pollInteriors() then dirty = true end
                nextInt = t + K.interiorMs
            end
            if A.lingering() > 0 and t >= nextRel then
                A.release(t)
                nextRel = t + K.releaseScanMs
            end
            if orphL.n > 0 then orphanCheck(t) end
            local busy = false
            if camOk then
                local ok, res = pcall(step, t)
                if ok then busy = res else logWarn('step failed: %s', tostring(res)) end
            end
            -- a frame only while a queue holds work; streaming assets / interiors are polled, not spun on
            Wait((busy or dirty) and 0 or (A.loading() > 0 and K.pollMs) or (A.interiorsPending() > 0 and K.interiorMs)
                or (moving and K.movingMs or K.stillMs))
        end
    end
end)

--------------------------------------------------------------------------------
-- C.mat — the internal interface (INTERFACES §5): the cache, kinds, fx, movers, promote, audio and scene.lua
--------------------------------------------------------------------------------

--- Handlers by kind id ('prop', 'light', …) or by class ('custom' = the plugin-kind bridge); nil unregisters
--- (the kind's live nodes go and stay KNOWN until a handler comes back).
function mat.registerKind(key, handler)
    if type(key) ~= 'string' or key == '' or (handler ~= nil and type(handler) ~= 'table') then return false end
    handlers[key] = handler
    local t = now()
    for _, m in pairs(recs) do
        local kid, cname = kindOf(m.node)
        if kid == key or cname == key then changed(m, 'kind', nil, t) end
    end
    dirty = true
    return true
end

--- A node entered the wanted set (the cache's cell is live, or a gated node arrived). A known id re-binds
--- (a re-sent node); an id removed moments ago (handover, still retiring) takes its entity back.
function mat.add(node)
    if type(node) ~= 'table' or node.id == nil then return end
    local id, t = node.id, now()
    local m = recs[id]
    if m then
        if m.node ~= node then
            m.node = node
            node.m = m
        end
        changed(m, 'move', nil, t)      -- a re-sent node: anything may differ, the pose included
        return
    end
    m = zombies[id]
    if m then
        zombies[id], nZombies = nil, nZombies - 1
        if m.hi ~= 0 then lrem(hoL, m, 'hi') end
        m.dead, m.node, node.m = false, node, m
        recs[id], nNodes = m, nNodes + 1
        if m.st == RETIRING then unretire(m, t) end
        local h0 = m.handle
        changed(m, 'move', nil, t)
        if m.unprompted then            -- its prompts went with the removal (RV6 F4): back with the node
            m.unprompted = nil
            local hd = m.h
            if m.handle == h0 and h0 ~= nil and h0 ~= PENDING and not m.held and hd and hd.update then
                local ok, err = pcall(hd.update, node, h0, 'interact')
                if not ok then warnOnce('reprompt', 'prompts of a revived node failed: %s', tostring(err)) end
            end
        end
        return
    end
    m = { id = id, node = node, st = KNOWN, seenAt = -huge, d2 = huge, qg = -1, ci = 0, mi = 0, ri = 0, ii = 0,
        hi = 0, ki = 0, pi = 0, oi = 0, kli = 0, held = holders[id] ~= nil, dead = false, delq = false }
    counts[KNOWN] = counts[KNOWN] + 1
    node.m = m
    recs[id], nNodes = m, nNodes + 1
    if not bind(m) then setSt(m, OFF) end
    pose0(m)
    place(m)
    if m.isKid then                       -- a child: its root streams it in (the whole chain re-checks)
        local p = recs[m.pid]
        while p do
            setKidsDue(p, true)
            p = p.isKid and recs[p.pid] or nil
        end
    end
    dirty = true
end

--- The node changed; `what` = 'fields' (data = the changed names) | 'move' | 'motion' | 'dr' | 'kind' | 'radius' |
--- 'attach' | 'interact' | 'dep' (the cache's vocabulary; anything else reaches handler.update as is).
function mat.update(node, what, data)
    local m = type(node) == 'table' and node.m or nil
    if not m or recs[m.id] ~= m then return end
    if what == 'dr' and m.mover and m.mi ~= 0 then
        -- a server-steered pose (up to 10 Hz, the descriptor table reused): the movers blend to it (projective
        -- velocity blending, snap above DeadReckoning.Snap), the next evaluation re-reads it; no re-bind, no
        -- handler call, no forced evaluation
        local mv, h = C.movers, m.handle
        if mv and h ~= nil and h ~= PENDING then mv.track(node, h, m.h, true) end
        return
    end
    changed(m, what, data, now())
end

--- The node left the wanted set. how: 0|'normal' (visibility-safe), 1|'handover' (kept for a PUT of the same
--- id), 2|'fade' (faded out when seen), 3|'world' (the cache's bucket reset: gone this frame, RV6 F3). Its prompts
--- go at once unless it is a hand-over (RV6 F4). A held node keeps its entity until release.
function mat.remove(node, how)
    local m = type(node) == 'table' and node.m or nil
    if not m or recs[m.id] ~= m then return end
    local t = now()
    how = T.HOW[how] or 'normal'
    recs[m.id], nNodes = nil, nNodes - 1
    unplace(m)
    if m.st == WARM then unwarm(m, t) end
    if m.handle == nil then
        drop(m)
        return
    end
    if how ~= 'handover' then T.unprompt(m) end
    m.dead = true
    if zombies[m.id] then drop(zombies[m.id]) end
    zombies[m.id], nZombies = m, nZombies + 1
    if m.held then return end
    if how == 'world' then
        T.worldGone(m, t)
    elseif how == 'handover' then
        m.hoUntil = t + K.handoverMs
        ladd(hoL, m, 'hi')
    elseif m.isKid then
        local p = m.par
        if p and p.dead then
            -- its root was removed first (the cache's order): the child rides the root's retire / fade / deletion
        elseif p then
            ladd(orphL, m, 'oi')          -- decided on the next pass: the root's removal may follow in this flush
        else
            pushDelete(m, t)
        end
    else
        release(m, t, how)
    end
end

--- A new world (the cache's bucket reset, RV6 F3): every entity still standing for a node removed EARLIER
--- (retiring, fading out, waiting for a hand-over) goes as well — collision off and hidden now, deleted by the
--- queue; held ones stay with their holder.
function mat.worldReset()
    local t = now()
    for _, m in pairs(zombies) do
        if not m.held and m.handle ~= nil then
            if m.hi ~= 0 then lrem(hoL, m, 'hi') end
            if not m.unprompted then T.unprompt(m) end
            T.worldGone(m, t)
        end
    end
    dirty = true
end

--- A one-shot event: the node's handler gets it when the node is materialised; the listener always.
function mat.event(node, name, params, age, x, y, z)
    local m = type(node) == 'table' and node.m or nil
    local h = m and m.handle
    if h ~= nil and m.h and m.h.event then
        local ok, err = pcall(m.h.event, node, h, name, params, age)
        if not ok then warnOnce('event:' .. tostring(m.kid), 'event() of kind %s failed: %s', tostring(m.kid), tostring(err)) end
    end
    if listener then
        local ok, err = pcall(listener, 'event', node, h, name, params, age, x, y, z)
        if not ok then warnOnce('listener:event', 'scene listener failed on event: %s', tostring(err)) end
    end
end

--- The sentinel a handler's create may answer (see mat.bound).
mat.PENDING = PENDING

--- Finishes a create that answered PENDING: `entity` -> LIVE (late-arrival fade rules), 0 -> LIVE without an
--- entity. A node removed meanwhile: the handler hears destroy(node, nil) and the record goes. Also valid while
--- the create is still running (a synchronous round trip). -> true when it finished something.
function mat.bound(node, entity)
    local m = type(node) == 'table' and node.m or nil
    if not m then return false end
    if m.creating then
        m.early = entity or 0
        return true
    end
    if m.handle ~= PENDING then return false end
    local t = now()
    lrem(pendL, m, 'pi')
    if m.dead then
        m.handle = nil
        liveAdd(m, -1)
        local hd = m.h
        if hd and hd.destroy then pcall(hd.destroy, m.node, nil) end
        drop(m)
        return true
    end
    local h = (entity == nil or entity == 0) and true or entity
    local fm = 0
    if type(h) == 'number' and m.fadeable and (m.late or m.fade == 'alpha') and fadesAllowed() and viewNow(m) then
        fm = slotFree(m.cls == 'vehicle') and 1 or 2
    end
    materialise(m, h, t, fm, true)
    createKids(m, t, fm)
    return true
end

function mat.handleOf(id)
    local m = recs[id] or zombies[id]
    local h = m and m.handle
    return type(h) == 'number' and h or nil
end

function mat.idOf(entity)
    local m = byHandle[entity]
    return (m and not m.shell) and m.id or nil
end

--- The runtime leaves a held node's entity alone (never moved, re-created or deleted); per-owner holder sets,
--- the Registry side ('sceneHold') is client/scene.lua's. -> the entity or nil.
function mat.hold(id, owner)
    local set = holders[id]
    if not set then
        set = {}
        holders[id] = set
    end
    set[owner or 'core'] = true
    local m = recs[id] or zombies[id]
    if m then m.held = true end
    return mat.handleOf(id)
end

--- Gives one holder's hold back; the last one applies what changed meanwhile. -> the entity or nil.
function mat.release(id, owner)
    local set = holders[id]
    if not set then return nil end
    set[owner or 'core'] = nil
    if next(set) ~= nil then return mat.handleOf(id) end
    holders[id] = nil
    local m = recs[id] or zombies[id]
    if not m then return nil end
    m.held = false
    local t = now()
    if m.dead then
        if m.handle ~= nil then release(m, t, 'normal') else drop(m) end
    elseif m.recreate then
        m.recreate, m.moved = false, false
        if m.handle ~= nil then toShell(m, t) end
        rebind(m, t)
    elseif m.moved then
        m.moved = false
        changed(m, 'move', nil, t)      -- what changed while held (fields and pose) applies now
    end
    dirty = true
    return mat.handleOf(id)
end

do
    --- Would a camera at the point still create this record? (KNOWN / WARM within r and its R_in, not held,
    --- not refused by a cap / the pool / the speed rule in the current queue generation, and wanted by the cache)
    local function notReady(m, x, y, z, r2, wanted)
        local st = m.st
        if (st ~= KNOWN and st ~= WARM and m.handle ~= PENDING) or m.held or m.capGen == qgen then return false end
        local dx, dy, dz = m.x - x, m.y - y, m.z - z
        local d2, rIn = dx * dx + dy * dy + dz * dz, m.rInB or m.rIn
        return d2 <= r2 and d2 <= rIn * rIn and (not wanted or wanted(m.node) == true)
    end

    --- True when every node within `r` of the point that a camera there would materialise is created, failed,
    --- capped, held or unwanted (the cache's half — cells still arriving — is client/scene.lua's).
    function mat.areaReady(x, y, z, r)
        r = tonumber(r) or 50.0
        local r2, wanted = r * r, cache.wanted
        for gx = floor((x - r) / CELL), floor((x + r) / CELL) do
            for gy = floor((y - r) / CELL), floor((y + r) / CELL) do
                local c = grid[(gx + 32768) * 65536 + (gy + 32768)]
                if c and c.nDone < c.n then
                    local list = c.list
                    for i = 1, c.n do
                        if notReady(list[i], x, y, z, r2, wanted) then return false end
                    end
                end
            end
        end
        for i = 1, movL.n do
            if notReady(movL[i], x, y, z, r2, wanted) then return false end
        end
        return true
    end
end

--- A core teleport is in progress (client/spawn.lua around its faded teleport): the screen state is checked every
--- 100 ms. Teleport mode itself — x TeleportMultiplier budgets, no fades, no deferred deletes — applies only while
--- IsScreenFadedOut(): a caller that merely waits for an area never makes things pop in view (RV2 F7).
function mat.setTeleport(on)
    forcedTp = on == true
    dirty = true
end

--- The last check's camera: position, forward, speed (m/s). Movers, audio and fx reuse it.
function mat.camera() return cx, cy, cz, fx, fy, fz, speed end

function mat.lodScale() return S end

--- cos^2 of the view cone's half angle (the movers test their own per-frame camera against it).
function mat.cone() return cosV2 end

--- Is a point inside the widened view cone of the last camera? -> bool, squared distance.
function mat.inView(x, y, z)
    local dx, dy, dz = x - cx, y - cy, z - cz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 < NEAR2 then return true, d2 end
    local fd = dx * fx + dy * fy + dz * fz
    return fd > 0 and fd * fd >= cosV2 * d2, d2
end

--- Slot-budgeted fades for other scene files (promote hand-off, handlers): false = no slot free right now.
function mat.fadeIn(entity, ms, isVehicle)
    if type(entity) ~= 'number' or entity == 0 then return false end
    return startFade(entity, 1, tonumber(ms) or fadeMs('prop'), isVehicle == true, nil, nil, now())
end

--- Fades out, then onDone(entity) — or DeleteEntity when no onDone is given.
function mat.fadeOut(entity, ms, isVehicle, onDone)
    if type(entity) ~= 'number' or entity == 0 then return false end
    return startFade(entity, -1, tonumber(ms) or fadeMs('prop', true), isVehicle == true, nil, onDone or nil, now())
end

--- One listener for scene.lua: fn(event, node, handle, ...) with 'live', 'gone', 'event' (+ name, params, age, x, y, z).
function mat.setListener(fn) listener = fn end

-- helpers the movers / kinds reuse (internal)
mat.targetOf, mat.compose, mat.attachTo = targetOf, compose, attachTo

--- Evaluates now with a fresh camera read (tests, the /scene debug overlay).
function mat.evaluate()
    local t = now()
    readCamera(t)
    evaluate(t)
end

function mat.stats()
    local nAssets, loading, lingering, mProps, mVehicles, mPeds = A.counts()
    local byBudget, queued = {}, 0
    for k, v in pairs(live) do byBudget[k] = v end
    for b = 1, NB do queued = queued + wbN[b] - wbH[b] + 1 end
    for g = 1, 4 do
        for b = 1, NB do queued = queued + cbN[g][b] - cbH[g][b] + 1 end
    end
    return {
        nodes = nNodes, zombies = nZombies, byBudget = byBudget, queued = queued,
        byState = { known = counts[KNOWN], warm = counts[WARM], staged = counts[STAGED], live = counts[LIVE],
            retiring = counts[RETIRING], failed = counts[FAILED], off = counts[OFF] },
        deleting = delQ.n - delQ.h + 1, retiring = retL.n, fades = F.running(), vehicleFades = F.vehicles(),
        stagedWaiting = stgQ.n - stgQ.h + 1, assets = nAssets, loading = loading, lingering = lingering,
        models = { props = mProps, vehicles = mVehicles, peds = mPeds },
        interiorsPending = A.interiorsPending(), movers = movL.n, handover = hoL.n, activeCells = actL.n,
        pending = pendL.n,
        evaluations = stat.evaluations, created = stat.created, deleted = stat.deleted, evicted = stat.evicted,
        failed = stat.failed, poolChecks = stat.poolChecks, pool = poolCount, ownProps = ownProps,
        poolEstimate = poolCount + ownProps - poolOwnAt, lastEvalCells = stat.lastEvalCells,
        lastEvalNodes = stat.lastEvalNodes, lightEvaluations = stat.lightEvaluations,
        lastLightNodes = stat.lastLightNodes, rescaleSlices = stat.rescaleSlices, rebounds = stat.rebounds,
        maxReach = maxReach, cellCount = nCells, poolSize = K.poolSize, poolLimit = floor(K.poolLimit),
        lodScale = S, teleport = teleport, speed = speed,
    }
end

--- Core stops: every entity, fade and asset request goes now (no queue, no Wait).
function mat.shutdown()
    stopped = true
    local function wipe(x)
        local h = x.handle
        if h == nil then return end
        x.handle = nil
        if x.h and x.h.destroy then pcall(x.h.destroy, x.node, h ~= PENDING and h or nil) end
        if type(h) == 'number' and DoesEntityExist(h) then DeleteEntity(h) end
    end
    F.shutdown(wipe)
    for i = delQ.h, delQ.n do if delQ[i] then wipe(delQ[i]) end end
    for _, m in pairs(recs) do wipe(m) end
    for _, m in pairs(zombies) do wipe(m) end
    A.shutdown()
    recs, zombies, byHandle, grid = {}, {}, {}, {}
    nNodes, nZombies, nCells = 0, 0, 0
end

function mat.isStopped() return stopped end

-- core stops: nothing it created may outlive it (the §52 runtime does the same)
AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() and not stopped then mat.shutdown() end
end)

C.mat = mat

