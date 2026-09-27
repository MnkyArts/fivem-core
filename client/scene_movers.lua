--[[ core — client/scene_movers.lua — placement of LIVE movers (DESIGN §55.9)
     The materialiser (client/scene_materializer.lua) tracks every materialised node that moves by itself:
     a motion descriptor (tween, path, spin, osc, orbit, keys, dr), an attach target (a player's ped, a
     networked entity), or a non-entity child riding a moving parent. This file places them, tiered:
       - within Motion.NearRadius (50 m) and on screen: every frame,
       - on screen farther away: Motion.MidHz (15 Hz),
       - off screen: not at all (re-placed on their next evaluated frame).
     "On screen" uses THIS frame's rendered camera (one coord + one rotation read per frame while a mover is
     tracked) against the materialiser's widened view cone — turning toward a mover never shows a stale pose.
     Entities go through handler.place(node, handle, x, y, z, rx, ry, rz) when the kind has one, else
     SetEntityCoordsNoOffset + SetEntityRotation (kinematic: the kinds create them frozen). An ENTITY with an
     attach target rides it through AttachEntityToEntity instead (the engine carries it; re-attached when the
     target entity changes, checked every 500 ms).
     Blending (§55.9): a new sample or plan of a mover already on screen (`track(…, true)`: a DR op, a motion
     change, a late plan) does not jump — projective velocity blending from what is rendered (its pose and
     velocity) to the new motion over the nominal interval (DR: 1000 / DeadReckoning.NearHz within NearRing, else
     1000 / FarHz; plans: 200 ms), snapped when the new pose is more than DeadReckoning.Snap (5 m) away.
     track() evaluates a motion once (a path builds its arc-length table there, never first inside the frame
     loop); a motion that Motion.finished() says can no longer change is untracked once its blend ended.
     The per-frame loop exists only while a mover is tracked; each mover runs in its own pcall (one that fails is
     logged once and untracked, the others keep moving) and a loop that dies is restarted by the next track().
     While every tracked mover is an ENTITY riding an attach target (the engine carries it: a Core.Attachments prop,
     review RV5 F4) nothing is placed per frame: the loop reads no camera and sleeps 500 ms, then checks every
     rider at once (one phase: 2 passes per second whatever their number); a track() while it sleeps starts a fresh
     loop at once (the sleeper ends when it wakes).

     C.movers.track(node, handle, handler [, retarget]) / C.movers.untrack(node) / C.movers.stats() (INTERFACES
     §5; `retarget` = blend from the rendered pose).

     Natives (fxref 2026-09-26, apiset client; BOOL answers read by truthiness, DESIGN §30.4):
       GetGameTimer(), GetFinalRenderedCamCoord() -> vector3, GetFinalRenderedCamRot(rotationOrder) -> vector3,
       SetEntityCoordsNoOffset(entity, x, y, z, xAxis, yAxis, zAxis),
       SetEntityRotation(entity, pitch, roll, yaw, rotationOrder, p5), GetEntityAttachedTo(entity) -> entity,
       DoesEntityExist(entity), GetEntityCoords(entity, alive), GetEntityRotation(entity, rotationOrder);
       AttachEntityToEntity through C.mat.attachTo, the attach target through C.mat.targetOf.
]]

local C = CoreSceneRuntime
assert(type(C) == 'table' and type(C.mat) == 'table',
    'client/scene_movers.lua loads after client/scene_materializer.lua (CoreSceneRuntime.mat)')

local mat = C.mat
local huge, rad, sin, cos = math.huge, math.rad, math.sin, math.cos
local CS = (type(Config) == 'table' and type(Config.Scene) == 'table') and Config.Scene or {}
local MO = type(CS.Motion) == 'table' and CS.Motion or {}
local DR = type(CS.DeadReckoning) == 'table' and CS.DeadReckoning or {}
local NEAR <const> = math.max(0.0, tonumber(MO.NearRadius) or 50.0)
local NEAR2 <const> = NEAR * NEAR
local MID_MS <const> = 1000.0 / math.max(1.0, math.min(60.0, tonumber(MO.MidHz) or 15.0))
local ATTACH_CHECK_MS <const> = 500
local SNAP <const> = math.max(0.0, tonumber(DR.Snap) or 5.0)
local SNAP2 <const> = SNAP * SNAP
local DR_NEAR_MS <const> = 1000.0 / math.max(0.1, tonumber(DR.NearHz) or 10.0)
local DR_FAR_MS <const> = 1000.0 / math.max(0.1, tonumber(DR.FarHz) or 1.0)
local RING <const> = math.max(1.0, tonumber(CS.NearRing) or 160.0)
local RING2 <const> = RING * RING
local PLAN_BLEND_MS <const> = 200.0   -- a new or late plan starts at its current phase through this blend
local RENDERED_MS <const> = 500       -- a pose rendered this recently is what a blend starts from
local NEAR_VIS2 <const> = 25.0        -- within 5 m a mover counts as on screen whatever the cone says

local Mv = {}
local L = { n = 0 }                   -- tracked records (node.m), each keeps its index in `mvi`
local running = false
local gen, sleeping, camAt = 0, false, nil   -- the loop's generation; it sleeps (riders only); frame of the camera read
local stat = { frames = 0, placed = 0, lastPlaced = 0, blends = 0, snaps = 0, errors = 0, sleeps = 0 }
local warned = {}
local target = { x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0 }   -- reused: an attach target's pose
local ccx, ccy, ccz, cfx, cfy, cfz, cone2 = 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.36   -- THIS frame's camera (F11)

local function warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    local log = Core.Log
    if log and log.warn then log.warn('scene: ' .. fmt, ...) end
end

local function netNow()
    local clock = Core.Clock
    local fn = clock and clock.now
    if fn then return fn() end
    return GetGameTimer()
end

--- An angle difference in (-180, 180].
local function shortest(a)
    a = (a + 180.0) % 360.0 - 180.0
    return a == -180.0 and 180.0 or a
end

local function readCamera()
    local c = GetFinalRenderedCamCoord()
    local r = GetFinalRenderedCamRot(2)
    ccx, ccy, ccz = c.x, c.y, c.z
    local p, yw = rad(r.x), rad(r.z)
    local cp = cos(p)
    cfx, cfy, cfz = -sin(yw) * cp, cos(yw) * cp, sin(p)
    cone2 = mat.cone()
end

--- Places a tracked record: the motion's pose blended from what was rendered (while a blend runs), then
--- handler.place or the kinematic natives. Remembers the rendered pose, its time and velocity.
local function place(m, x, y, z, rx, ry, rz, t)
    local bd = m.bdur
    if bd and bd > 0 then
        local a = (t - m.bt0) / bd
        if a >= 1.0 then
            m.bdur = 0
        else
            local w, dt = 1.0 - a, (t - m.bt0) * 0.001    -- P = P_new + (P_old + v_old * dt - P_new) * (1 - a)
            x = x + (m.b0x + m.bvx * dt - x) * w
            y = y + (m.b0y + m.bvy * dt - y) * w
            z = z + (m.b0z + m.bvz * dt - z) * w
            rx, ry, rz = rx + m.brx * w, ry + m.bry * w, rz + m.brz * w
        end
    end
    local last = m.pt
    if last and t > last and t - last < 250 then
        local inv = 1000.0 / (t - last)
        m.lvx, m.lvy, m.lvz = (x - m.px) * inv, (y - m.py) * inv, (z - m.pz) * inv
    else
        m.lvx, m.lvy, m.lvz = 0.0, 0.0, 0.0
    end
    m.px, m.py, m.pz, m.prx, m.pry, m.prz, m.pt = x, y, z, rx, ry, rz, t
    local h, hd = m.mvh, m.mvf
    if hd and hd.place then
        local ok, err = pcall(hd.place, m.node, h, x, y, z, rx, ry, rz)
        if not ok then warnOnce('place:' .. tostring(m.kid), 'place() of kind %s failed: %s', tostring(m.kid),
            tostring(err)) end
    elseif type(h) == 'number' then
        SetEntityCoordsNoOffset(h, x, y, z, false, false, false)
        SetEntityRotation(h, rx, ry, rz, 2, false)
    end
end

--- Due this frame? On screen (this frame's camera, read once by the first mover that asks) only; within NearRadius
--- every frame, else at MidHz.
local function due(m, t)
    if camAt ~= t then
        camAt = t
        local okc, err = pcall(readCamera)
        if not okc then warnOnce('camera', 'mover camera read failed: %s', tostring(err)) end
    end
    local dx, dy, dz = (m.px or m.x) - ccx, (m.py or m.y) - ccy, (m.pz or m.z) - ccz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 >= NEAR_VIS2 then
        local fd = dx * cfx + dy * cfy + dz * cfz
        if fd <= 0 or fd * fd < cone2 * d2 then return false end
    end
    return d2 <= NEAR2 or t - (m.pt or -huge) >= MID_MS
end

--- An entity riding an attach target: attached once (or found on it already, attached by its kind's handler),
--- re-attached when the target entity changes (a respawned ped, a re-created clone). Only an attachment to the
--- CURRENT target is adopted: after a gap where the target could not be resolved, the entity may still hang on
--- the old one (which still exists) — it is moved to the new target.
local function ride(m, h, t, force)
    if not force and t - m.mvAt < ATTACH_CHECK_MS then return end
    m.mvAt = t
    local e = mat.targetOf(m.node.attach)
    if e == 0 or not DoesEntityExist(h) then
        m.mvAtt = nil
        return
    end
    if m.mvAtt == e then return end
    if GetEntityAttachedTo(h) == e then
        m.mvAtt = e              -- already on this target (the kind's create() attached it)
        return
    end
    mat.attachTo(h, e, m.node)
    m.mvAtt = e
end

--- One mover, one frame (run in a pcall by the loop). -> 1 when it was placed, 0 when not (it wants frames), -1 for
--- an entity riding its target (the engine carries it: only its attach checks matter; `force` = check it now)
local function stepMover(m, t, tn, Motion, force)
    local node, h = m.node, m.mvh
    local att = node.attach
    if att ~= nil and not m.isKid then
        if type(h) == 'number' then
            ride(m, h, t, force)
            return -1
        elseif due(m, t) then            -- a non-entity (light, emitter …) follows the target's pose
            local e = mat.targetOf(att)
            if e ~= 0 then
                local p, r = GetEntityCoords(e, false), GetEntityRotation(e, 2)
                target.x, target.y, target.z, target.rx, target.ry, target.rz = p.x, p.y, p.z, r.x, r.y, r.z
                mat.compose(m, target)
                place(m, m.x, m.y, m.z, m.rx, m.ry, m.rz, t)
                return 1
            end
        end
    elseif m.isKid then                  -- a non-entity child of a moving parent: the parent's rendered pose ∘ offset
        local p = m.par
        if p and due(m, t) then
            if p.pt then
                target.x, target.y, target.z, target.rx, target.ry, target.rz = p.px, p.py, p.pz, p.prx, p.pry, p.prz
                mat.compose(m, target)
            else
                mat.compose(m, p)
            end
            place(m, m.x, m.y, m.z, m.rx, m.ry, m.rz, t)
            return 1
        end
    elseif node.motion ~= nil and Motion and due(m, t) then
        local desc = node.motion
        local x, y, z, rx, ry, rz = Motion.pose(node.x or 0.0, node.y or 0.0, node.z or 0.0,
            node.rx or 0.0, node.ry or 0.0, node.rz or 0.0, desc, tn)
        place(m, x, y, z, rx, ry, rz, t)
        if (m.bdur or 0) == 0 and Motion.finished(desc, tn) then Mv.untrack(node) end   -- ended: its pose stays
        return 1
    end
    return 0
end

local function loop(g)
    local woke = false                   -- this pass follows a riders-only sleep: every rider is checked (one phase)
    while gen == g and L.n > 0 and not mat.isStopped() do
        local t = GetGameTimer()
        local Motion = Core.SceneMotion
        local tn = netNow()
        local placed, frame = 0, false
        for i = L.n, 1, -1 do
            local m = L[i]
            local ok, res = pcall(stepMover, m, t, tn, Motion, woke)
            if not ok then               -- one broken mover never stops the others (F20): logged once, dropped
                stat.errors = stat.errors + 1
                warnOnce('mover:' .. tostring(m.kid), 'a mover of kind %s failed and is no longer placed: %s',
                    tostring(m.kid), tostring(res))
                if L[i] == m then Mv.untrack(m.node) end
            elseif res >= 0 then         -- (an entity rider answers -1: the engine carries it)
                placed, frame = placed + res, true
            end
        end
        stat.frames, stat.placed, stat.lastPlaced = stat.frames + 1, stat.placed + placed, placed
        if frame or L.n == 0 then
            woke = false
            Wait(0)   -- per-frame: movers on screen are placed right now; the loop ends with the last mover
        else          -- riders only (RV5 F4): nothing per frame, one attach check of every rider per 500 ms
            stat.sleeps = stat.sleeps + 1
            sleeping = true
            Wait(ATTACH_CHECK_MS)
            if gen ~= g then return end  -- a track() started a fresh loop meanwhile: this one ends
            sleeping, woke = false, true
        end
    end
end

local function run(g)
    local ok, err = pcall(loop, g)
    if gen == g then
        running, sleeping = false, false -- the next track() starts a new loop, whatever happened
    end
    if not ok then warnOnce('loop', 'the mover loop failed: %s', tostring(err)) end
end

--- Starts (or re-targets) placing a LIVE node's handle. `retarget`: a new sample / plan of a node whose entity is
--- on screen already — blend from the rendered pose (or the entity's own) instead of jumping (§55.9).
function Mv.track(node, handle, handler, retarget)
    local m = type(node) == 'table' and node.m or nil
    if not m or handle == nil then return false end
    local tracked = (m.mvi or 0) ~= 0 and m.mvh == handle
    m.mvh, m.mvf = handle, handler
    if not tracked then m.mvAt = -huge end
    local Motion = Core.SceneMotion
    local desc = node.motion
    if desc ~= nil and node.attach == nil and not m.isKid and Motion then
        local t, tn = GetGameTimer(), netNow()   -- the first pose() builds a path's table: here, not per frame
        local x, y, z, rx, ry, rz = Motion.pose(node.x or 0.0, node.y or 0.0, node.z or 0.0, node.rx or 0.0,
            node.ry or 0.0, node.rz or 0.0, desc, tn)
        m.bdur = 0
        if retarget then
            local bx, by, bz, brx, bry, brz, vx, vy, vz
            if tracked and m.pt and t - m.pt < RENDERED_MS then
                bx, by, bz, brx, bry, brz = m.px, m.py, m.pz, m.prx, m.pry, m.prz
                vx, vy, vz = m.lvx or 0.0, m.lvy or 0.0, m.lvz or 0.0
            elseif type(handle) == 'number' and DoesEntityExist(handle) then   -- a static entity starts a plan
                local p, r = GetEntityCoords(handle, false), GetEntityRotation(handle, 2)
                bx, by, bz, brx, bry, brz, vx, vy, vz = p.x, p.y, p.z, r.x, r.y, r.z, 0.0, 0.0, 0.0
            end
            if bx then
                local dx, dy, dz = bx - x, by - y, bz - z
                if dx * dx + dy * dy + dz * dz > SNAP2 then
                    stat.snaps = stat.snaps + 1           -- too far off: snap, like GTA
                else
                    local cx, cy, cz = mat.camera()
                    local ex, ey, ez = x - cx, y - cy, z - cz
                    m.bt0 = t
                    m.bdur = desc.t ~= 'dr' and PLAN_BLEND_MS
                        or (ex * ex + ey * ey + ez * ez <= RING2 and DR_NEAR_MS or DR_FAR_MS)
                    m.b0x, m.b0y, m.b0z, m.bvx, m.bvy, m.bvz = bx, by, bz, vx, vy, vz
                    m.brx, m.bry, m.brz = shortest(brx - rx), shortest(bry - ry), shortest(brz - rz)
                    stat.blends = stat.blends + 1
                end
            end
        end
        place(m, x, y, z, rx, ry, rz, t)
        if m.bdur == 0 and Motion.finished(desc, tn) then   -- already at its last pose: nothing to follow
            Mv.untrack(node)
            return true
        end
    end
    if (m.mvi or 0) == 0 then
        local n = L.n + 1
        L.n, L[n], m.mvi = n, m, n
    end
    if not running or sleeping then      -- none, or one asleep for up to 500 ms: a fresh loop runs from now
        running, sleeping, gen = true, false, gen + 1
        local g = gen
        CreateThread(function() run(g) end)
    end
    return true
end

function Mv.untrack(node)
    local m = type(node) == 'table' and node.m or nil
    local i = m and m.mvi or 0
    if i == 0 then return false end
    local n = L.n
    local last = L[n]
    L[i], last.mvi = last, i
    L[n], L.n, m.mvi = nil, n - 1, 0
    m.mvh, m.mvf, m.mvAtt, m.bdur = nil, nil, nil, 0
    return true
end

function Mv.stats()
    return { tracked = L.n, running = running, sleeping = sleeping, frames = stat.frames, placed = stat.placed,
        lastPlaced = stat.lastPlaced, blends = stat.blends, snaps = stat.snaps, errors = stat.errors,
        sleeps = stat.sleeps }
end

C.movers = Mv
