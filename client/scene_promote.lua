--[[ core — client/scene_promote.lua — the promotion hand-off of Core.Scene (DESIGN §55.15)
     Loads after client/scene_movers.lua and before client/scene_audio.lua / client/scene.lua; it fills C.promote of
     the one-shot global `CoreSceneRuntime`. The cache calls C.promote.onPromote(node, netId) / onDemote(node) for
     nodes it had delivered before (a node that arrives promoted is met in create()).

     The seam into the materialiser: the built-in entity handlers (C.kinds.handlers prop / vehicle / ped) are
     re-registered WRAPPED (C.mat.registerKind, the base handler does the work):
       create   a promoted root whose clone is here answers `true` — the record is LIVE without a local entity, the
                networked clone stands in (prompts go to the clone, entity children ride it); without the clone the
                local copy is created and polled; while a demotion waits for the clone to vanish the new local copy
                (and its entity children) is created HIDDEN (SetEntityVisible false, no collision)
       update   a stand-in record re-creates (false) once it is no longer promoted; the swap answers false after
                hiding / fading the old entity, so the materialiser lets it go and re-creates (→ `true`)
       destroy  the base destroy for entities; prompts follow the stand-in; local vehicle copies are tracked
       place    entities only: the clone of a promoted mover is driven by whoever controls it, in a loop that runs
                per frame only while this client controls one, whatever the view (R7 §2.4 platforms)
     A stand-in whose clone leaves this client while the node is still promoted shows NOTHING (phase 'lost', RV6 F7:
     never a local copy at a stale pose) until the clone is back (the 1 s sweep), a DEMOTE or a new promotion; a
     local copy exists only for a promotion whose clone this client has not seen yet (the hand-off copy).
     Hand-off: the local copy stays LIVE until the clone exists (NetworkDoesEntityExistWithNetworkId → entity with
     state sn == id), polled at 10 Hz only while such copies exist, for CloneWaitMs (then 1 Hz: a late clone still
     swaps; until then the local copy stays). Within SwapDist / SwapDeg: hidden in the same frame; else faded out
     over 300 ms (C.mat.fadeOut) over the clone; collision off either way. An `enter` report then tasks the ped into
     the clone (TaskEnterVehicle). Demotion: the clone stays until the server deletes it; the new local copy is
     created hidden — the materialiser's fade-in on it is ended at once (C.fades, RV6 F12) — and revealed opaque the
     frame the clone is gone (a per-frame check that exists only while one waits). A re-promotion with the SAME
     clone (the server kept it: someone got in, RV4 F12) drops the hidden copy unseen and swaps back to the clone.
     Triggers: enter — GetVehiclePedIsTryingToEnter(PlayerPedId()) at 4 Hz only while a local vehicle copy is within
     6 m (a loop that exists only while local vehicle copies exist, slower when farther) → core:scene:report enter;
     damage — gameEventTriggered CEventNetworkEntityDamage (args[1] = the victim) naming a local copy → damaged
     (each at most once per 2 s per node). The owner of a clone applies `snCfg` once per control period (a state-bag
     handler + a 16-per-second sweep; the net-id guard first; only "on" states, the §52 mapCfg pattern) and answers
     the callback core:scene:props with Vehicles.getProps of the clone it controls (the server takes only the wear
     whitelist of it). A vehicle's snCfg (D-A): `props` (cosmetic), plate, paint, per-owner flags — every owner
     applies them again; `once` (wear, lock, dirt) only until the server strips it: the owner that applied it sends
     core:scene:applied(id), and its 1 s sweep sends it again (≥ 2 s apart) while the live bag still carries `once`
     (RV5 F1: a lost report never lets the next owner reset damage, fuel or a lock); a core vehicle (state coreVeh)
     takes its lock from its `locked` bag only.

     Natives (fxref + natives.json runtime names 2026-09-27, apiset client; BOOL answers read by truthiness):
       NetworkDoesEntityExistWithNetworkId(netId) (always before NetworkGetEntityFromNetworkId(netId)),
       NetworkHasControlOfEntity(entity), DoesEntityExist(entity), GetEntityType(entity), GetEntityCoords(entity,
       alive), GetEntityRotation(entity, rotationOrder), SetEntityVisible(entity, toggle, p2), SetEntityCollision(
       entity, toggle, keepPhysics), SetEntityCoordsNoOffset(entity, x, y, z, keepTasks, keepIK, doWarp),
       SetEntityRotation(entity, pitch, roll, yaw, rotationOrder, p5), ResetEntityAlpha(entity), PlayerPedId(),
       GetVehiclePedIsTryingToEnter(
       ped), GetSeatPedIsTryingToEnter(ped), TaskEnterVehicle(ped, vehicle, timeout, seat, speed, flag, clipset),
       SetVehicleColours(vehicle, primary, secondary), SetVehicleNumberPlateText(vehicle, plate),
       SetVehicleDoorsLocked(vehicle, status), SetVehicleDirtLevel(vehicle, level), SetEntityInvincible(entity,
       toggle, dontResetOnCleanup), FreezeEntityPosition(entity, toggle), SetPedDefaultComponentVariation(ped),
       SetBlockingOfNonTemporaryEvents(ped, toggle), IsPedUsingScenario(ped, scenario), TaskStartScenarioInPlace(ped,
       scenario, timeToLeave, playIntroClip), GiveWeaponToPed(ped, weapon, ammo, hidden, inHand), GetGameTimer(),
       AddStateBagChangeHandler(keyFilter, bagFilter, handler) (CFX shared), GetCurrentResourceName() (CFX).
       Fades through C.mat.fadeOut, attachments through C.mat.attachTo; props through Core.Vehicles.
]]

local C = CoreSceneRuntime
assert(type(C) == 'table' and C.cache and C.mat and type(C.kinds) == 'table' and type(C.kinds.handlers) == 'table'
    and C.movers, 'client/scene_promote.lua loads after client/scene_movers.lua (CoreSceneRuntime.kinds / .movers)')

local mat, cache, kinds = C.mat, C.cache, C.kinds
local mtype, toint, sqrt, huge = math.type, math.tointeger, math.sqrt, math.huge

local cfg = (type(Config) == 'table' and type(Config.Scene) == 'table' and type(Config.Scene.Promote) == 'table')
    and Config.Scene.Promote or {}
local function setting(v, default, lo, hi)
    v = tonumber(v) or default
    if v ~= v or v < lo then return lo end
    return v > hi and hi or v
end
local CLONE_WAIT_MS <const> = setting(cfg.CloneWaitMs, 10000, 0, 600000)
local SWAP_DIST <const> = setting(cfg.SwapDist, 0.05, 0, 10)
local SWAP_DEG <const> = setting(cfg.SwapDeg, 2, 0, 180)
local SWAP_FADE_MS <const> = 300
local POLL_MS <const>, LATE_MS <const>, SWEEP_MS <const> = 100, 1000, 1000
local ENTER_NEAR <const>, ENTER_MS <const>, ENTER_SLOW_MS <const> = 6.0, 250, 1000
local ENTER_TASK_MS <const> = 10000
local REPORT_GAP_MS <const> = 2000
local CFG_CHECKS <const>, CFG_ABSENT <const> = 16, 10
local ENTITY_CLASS <const> = { prop = 'prop', vehicle = 'vehicle', ped = 'ped', [1] = 'prop', [2] = 'vehicle',
    [3] = 'ped' }
local EMPTY <const> = setmetatable({}, { __newindex = function() error('read-only', 2) end })
local function KEEP() end                    -- fade-out callback: the materialiser's shell deletes the entity

local Pr = {}
local P, nP = {}, 0                          -- [id] = { id, netId, phase = wait|late|swapped|lost|demoting, t0,
                                             --   clone, seen (this promotion's clone was here), sup (the record
                                             --   stands in: handle true), next (poll time) }
local polled, nPoll = {}, 0                  -- [id] = p: a local copy waits for its clone
local hidden, nHidden = {}, 0                -- { e, id, clone, t0, vis, col }: revealed once the clone is gone
local vehs, vehOf, nVeh = {}, {}, 0          -- [id] = { e, x, y, z, mover } local vehicle copies / [entity] = id
local enterWant = {}                         -- [id] = { seat, at }: the ped tried to get into the local copy
local lastReport = { enter = {}, damaged = {}, applied = {} }   -- what -> [id] = GetGameTimer() of the last report
local swapping = { id = 0, fade = false }    -- set by the poll around the C.mat.update of a swap
local stopped, pending, sweeping, entering = false, false, false, false
local stat = { swaps = 0, fades = 0, cuts = 0, timeouts = 0, reveals = 0, enterTasks = 0, reports = 0,
    cfgApplied = 0, propsAnswered = 0, lost = 0, fadeEnds = 0, kept = 0 }
local REPORT_EVENT <const> = { enter = 'core:scene:report', damaged = 'core:scene:report',
    applied = 'core:scene:applied' }

local function finite(v, limit) return type(v) == 'number' and v == v and v >= -limit and v <= limit end

local function wrap180(a)
    a = a % 360.0
    return a > 180.0 and a - 360.0 or a
end

--- The clone of node `id`: the networked entity `netId` names, when this client has it and its `sn` is `id`
--- (net ids are recycled; the guard runs before NetworkGetEntityFromNetworkId, AGENTS §3).
local function cloneOf(id, netId)
    if mtype(netId) ~= 'integer' or netId <= 0 or not NetworkDoesEntityExistWithNetworkId(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if not e or e == 0 or not DoesEntityExist(e) or Entity(e).state.sn ~= id then return nil end
    return e
end

--- The root id of a cached node (children ride their root: the root's promotion decides for them).
local function rootOf(node)
    local n, guard = node, 0
    while n and n.parent ~= 0 and guard < 8 do
        local up = cache.node(n.parent)
        if not up then break end
        n, guard = up, guard + 1
    end
    return n and n.id or node.id
end

--------------------------------------------------------------------------------
-- Bookkeeping: promotions known here, the polled copies, the hidden copies, the loops that serve them
--------------------------------------------------------------------------------

local pendingLoop, sweepLoop                 -- forward: the two loops (below)

--- The 10 Hz poll / per-frame reveal loop: exists only while a copy waits for its clone or a hidden copy waits.
local function ensurePending()
    if pending or stopped then return end
    pending = true
    CreateThread(pendingLoop)
end

--- The 1 Hz sweep: exists only while promotions or clone configs are known.
local function ensureSweep()
    if sweeping or stopped then return end
    sweeping = true
    CreateThread(sweepLoop)
end

local cloneIds = {}                          -- [clone entity] = node id (validated against P on every read)

--- The clone of promotion `p` (nil = none here), mirrored into cloneIds for C.promote.idOfClone.
local function setClone(p, e)
    local old = p.clone
    if old and cloneIds[old] == p.id then cloneIds[old] = nil end
    p.clone = e
    if e then cloneIds[e] = p.id end
end

--- The promotion record of `node` (created or re-armed): waiting for the clone `netId`.
local function track(node, netId)
    local id = node.id
    local p = P[id]
    if not p then
        p = { id = id, sup = false, next = 0 }
        P[id], nP = p, nP + 1
    end
    if p.netId ~= netId then p.seen = false end            -- a new clone: not seen here yet
    p.netId, p.phase, p.t0 = netId, 'wait', GetGameTimer()
    setClone(p, nil)
    ensureSweep()
    return p
end

local function poll(p)
    if not polled[p.id] then
        polled[p.id], nPoll = p, nPoll + 1
    end
    p.next = GetGameTimer() + POLL_MS                         -- first look one poll later (never inside a create)
    ensurePending()
end

local function unpoll(p)
    if polled[p.id] == p then
        polled[p.id], nPoll = nil, nPoll - 1
    end
end

local function drop(p)
    if P[p.id] == p then
        P[p.id], nP = nil, nP - 1
    end
    unpoll(p)
    setClone(p, nil)
end

local function unhide(i)
    hidden[i] = hidden[nHidden]
    hidden[nHidden], nHidden = nil, nHidden - 1
end

--- Hides a new local copy until the clone of its (root's) promotion `p` is gone.
local function hide(e, p, cls, node)
    local f = type(node.fields) == 'table' and node.fields or EMPTY
    local prop = cls == 'prop'
    SetEntityVisible(e, false, false)
    SetEntityCollision(e, false, false)
    nHidden = nHidden + 1
    hidden[nHidden] = { e = e, id = p.id, clone = p.clone, t0 = GetGameTimer(),
        vis = not (prop and f.visible == false), col = not (prop and f.collision == false) }
    ensurePending()
end

local function reveal(r)
    if not DoesEntityExist(r.e) then return end
    SetEntityVisible(r.e, r.vis, false)
    SetEntityCollision(r.e, r.col, false)
    stat.reveals = stat.reveals + 1
end

--- Every frame while copies are hidden: the frame the clone is gone (or CloneWaitMs passed), they show. While the
--- clone still stands, the materialiser's fade-in of a hidden copy (a late arrival in view) is ended at once, so the
--- reveal shows it opaque — never mid fade-in (RV6 F12); one whose clone was gone at creation keeps its fade.
local function revealCheck(t)
    local F = C.fades
    for i = nHidden, 1, -1 do
        local r = hidden[i]
        if not DoesEntityExist(r.e) then
            unhide(i)
        elseif not DoesEntityExist(r.clone) or t - r.t0 >= CLONE_WAIT_MS then
            reveal(r)
            unhide(i)
        elseif F and F.dir(r.e) == 1 then
            F.cancel(r.e)
            ResetEntityAlpha(r.e)
            stat.fadeEnds = stat.fadeEnds + 1
        end
    end
end

--- Drops the hidden copies of promotion `id` unseen (the server kept the clone: the swap deletes them).
local function forgetHidden(id)
    for i = nHidden, 1, -1 do
        if hidden[i].id == id then unhide(i) end
    end
end

--- Reveals every hidden copy of promotion `id` now (a re-promotion overtook the demotion).
local function revealAll(id)
    for i = nHidden, 1, -1 do
        if hidden[i].id == id then
            reveal(hidden[i])
            unhide(i)
        end
    end
end

local function hasHidden(id)
    for i = 1, nHidden do if hidden[i].id == id then return true end end
    return false
end

--- core:scene:report (enter / damaged) or core:scene:applied, at most once per REPORT_GAP_MS per node and kind (the
--- server also rate-limits).
local function report(id, what, t)
    local last = lastReport[what]
    if last[id] and t - last[id] < REPORT_GAP_MS then return false end
    last[id] = t
    stat.reports = stat.reports + 1
    if what == 'applied' then
        Core.Net.emit(REPORT_EVENT.applied, id)
    else
        Core.Net.emit(REPORT_EVENT[what], id, what)
    end
    return true
end

local drive, nDrive, driving = {}, 0, false  -- [id] = p: stand-ins of movers (the client in control drives)
local driveLoop                              -- forward (below)

--- A promoted mover: whoever controls its clone places it along the motion, whatever the view (the network
--- carries it to everyone; R7 §2.4 platforms).
local function addDrive(p, node)
    if node.motion == nil or drive[p.id] then return end
    drive[p.id], nDrive = p, nDrive + 1
    if driving or stopped then return end
    driving = true
    CreateThread(driveLoop)
end

--- The clone stands in from now on: prompts on the clone, the ped that tried to get in is tasked into it.
local function setSwapped(p, clone, node)
    p.phase, p.seen = 'swapped', true
    setClone(p, clone)
    unpoll(p)
    stat.swaps = stat.swaps + 1
    if node then
        kinds.syncInteract(node, clone)
        addDrive(p, node)
    end
    local want = enterWant[p.id]
    enterWant[p.id] = nil
    if want and GetGameTimer() - want.at <= CLONE_WAIT_MS and GetEntityType(clone) == 2 then
        TaskEnterVehicle(PlayerPedId(), clone, ENTER_TASK_MS, want.seat, 1.0, 1, 0)
        stat.enterTasks = stat.enterTasks + 1
    end
end

--- The old local copy leaves over the clone: no collision at once; hidden in this frame, or faded out.
local function handOff(h, cls, fade)
    SetEntityCollision(h, false, false)
    if fade and mat.fadeOut(h, SWAP_FADE_MS, cls == 'vehicle', KEEP) then
        stat.fades = stat.fades + 1
    else
        SetEntityVisible(h, false, false)
        stat.cuts = stat.cuts + 1
    end
end

--------------------------------------------------------------------------------
-- The wrapped entity handlers (prop, vehicle, ped): the base handler of client/scene_kinds.lua does the work
--------------------------------------------------------------------------------

local function trackVeh(id, e, node, ctx)
    local v = vehs[id]
    if v then vehOf[v.e] = nil else nVeh = nVeh + 1 end
    local x, y, z = node.x or 0.0, node.y or 0.0, node.z or 0.0
    if type(ctx) == 'table' and ctx.x then x, y, z = ctx.x, ctx.y, ctx.z end
    vehs[id] = { e = e, x = x, y = y, z = z, mover = node.motion ~= nil or node.attach ~= nil }
    vehOf[e] = id
    if not entering and not stopped then
        entering = true
        CreateThread(Pr.enterLoop)
    end
end

local function untrackVeh(e)
    local id = vehOf[e]
    if not id then return end
    vehOf[e] = nil
    if vehs[id] and vehs[id].e == e then
        vehs[id], nVeh = nil, nVeh - 1
    end
end

local function wrapCreate(b, cls, node, ctx)
    local id = node.id
    local p = P[id]
    if node.parent == 0 and node.netId ~= nil then            -- promoted, as the cache knows it
        if not p or p.netId ~= node.netId then p = track(node, node.netId) end
        if p.phase ~= 'demoting' then
            local clone = cloneOf(id, p.netId)
            if clone then
                p.sup = true
                setSwapped(p, clone, node)
                return true                                    -- LIVE without a local entity: the clone stands in
            end
            if p.seen then                                     -- its clone was here and left (RV6 F7): no local
                p.sup, p.phase = true, 'lost'                  -- copy at a stale pose; the record stands in,
                setClone(p, nil)                               -- empty, until the clone is back or a DEMOTE
                return true
            end
        end
    end
    local e = b.create(node, ctx)
    if mtype(e) ~= 'integer' then return e end
    if node.parent ~= 0 then                                   -- an entity child rides its root's stand-in
        local rp = P[rootOf(node)]
        if rp and rp.clone and rp.phase == 'swapped' then
            mat.attachTo(e, rp.clone, node)
        elseif rp and rp.clone and rp.phase == 'demoting' then
            hide(e, rp, cls, node)
        end
    elseif p then
        if p.phase == 'demoting' and p.clone then
            hide(e, p, cls, node)                              -- revealed the frame the clone is gone
        elseif p.phase == 'wait' or p.phase == 'late' then
            poll(p)                                            -- promoted, the clone not here yet
        end
    end
    if cls == 'vehicle' and node.parent == 0 then trackVeh(id, e, node, ctx) end
    return e
end

local function wrapUpdate(b, cls, node, h, what, data)
    if mtype(h) ~= 'integer' then                              -- a stand-in record
        local p = P[node.id]
        -- still the same promotion: a MOVE of the pose the server follows, a set, anything keeps the stand-in (a
        -- local copy would stand at a stale pose, RV6 F7); a new promotion or the demotion re-creates (false)
        if p and node.netId ~= nil and node.netId == p.netId and p.phase ~= 'demoting' and what ~= 'promote' then
            if p.phase == 'swapped' and p.clone then
                if what == 'interact' then kinds.syncInteract(node, p.clone) end
                if what == 'motion' then addDrive(p, node) end
            end
            return true
        end
        return false
    end
    if swapping.id == node.id then
        handOff(h, cls, swapping.fade)
        return false                                           -- the old entity goes; the re-create answers true
    end
    if cls == 'vehicle' and what == 'move' and vehs[node.id] then
        local v = vehs[node.id]
        v.x, v.y, v.z = node.x or v.x, node.y or v.y, node.z or v.z
    end
    return b.update(node, h, what, data)
end

local function wrapDestroy(b, _cls, node, h)
    local id = node.id
    local p = P[id]
    if mtype(h) == 'integer' then
        untrackVeh(h)
        b.destroy(node, h)
    elseif p then
        p.sup = false
    end
    -- prompts: a local entity of the node keeps its own; a stand-in's go to the clone, or away
    local cur = mat.handleOf(id)
    if cur and cur ~= h then return end
    local m = node.m
    if p and p.phase == 'swapped' and p.clone and not node.gone and type(m) == 'table' and not m.dead then
        kinds.syncInteract(node, p.clone)
    elseif mtype(h) ~= 'integer' then
        kinds.clearInteract(id)
    end
    if node.gone and p then drop(p) end
end

--- Movers place entities only; a stand-in's clone is moved by its owner in the drive loop (whatever the view).
local function wrapPlace(b, node, h, x, y, z, rx, ry, rz)
    if mtype(h) == 'integer' then return b.place(node, h, x, y, z, rx, ry, rz) end
end

Pr.handlers = {}
for _, cls in ipairs({ 'prop', 'vehicle', 'ped' }) do
    local b = kinds.handlers[cls]
    assert(type(b) == 'table' and b.create and b.destroy, 'client/scene_kinds.lua registers the ' .. cls .. ' handler')
    local w = {}
    for k, v in pairs(b) do w[k] = v end
    w.create = function(node, ctx) return wrapCreate(b, cls, node, ctx) end
    w.update = function(node, h, what, data) return wrapUpdate(b, cls, node, h, what, data) end
    w.destroy = function(node, h) return wrapDestroy(b, cls, node, h) end
    if b.place then w.place = function(node, h, ...) return wrapPlace(b, node, h, ...) end end
    Pr.handlers[cls] = w
    mat.registerKind(cls, w)
end

--------------------------------------------------------------------------------
-- The hand-offs: promote (poll → swap), demote (hidden → revealed)
--------------------------------------------------------------------------------

--- A polled local copy: its clone here? Then swap (same frame within SwapDist / SwapDeg, else a fade).
local function pollOne(p, t)
    local node = cache.node(p.id)
    if not node or node.gone or node.netId ~= p.netId then return unpoll(p) end
    local h = mat.handleOf(p.id)
    local clone = cloneOf(p.id, p.netId)
    if not clone then
        if p.phase == 'wait' and t - p.t0 >= CLONE_WAIT_MS then
            p.phase = 'late'                                   -- the local copy stays; a late clone still swaps
            stat.timeouts = stat.timeouts + 1
        end
        if not h then unpoll(p) end                            -- no copy: the next create looks again
        return
    end
    if not h then return setSwapped(p, clone, node) end        -- the copy went meanwhile: the clone stands in
    local a, b = GetEntityCoords(h, false), GetEntityCoords(clone, false)
    local ra, rb = GetEntityRotation(h, 2), GetEntityRotation(clone, 2)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    local close = dx * dx + dy * dy + dz * dz <= SWAP_DIST * SWAP_DIST
        and math.abs(wrap180(ra.x - rb.x)) <= SWAP_DEG and math.abs(wrap180(ra.y - rb.y)) <= SWAP_DEG
        and math.abs(wrap180(ra.z - rb.z)) <= SWAP_DEG
    swapping.id, swapping.fade = p.id, not close
    local ok, err = pcall(mat.update, node, 'promote', p.netId)
    swapping.id = 0
    if not ok then Core.Log.warn('scene: the swap of node %d failed: %s', p.id, tostring(err)) end
    if mat.handleOf(p.id) == h then return end                 -- held (the editor): tried again next poll
    p.sup = false
    setSwapped(p, clone, node)
end

local function pollAll(t)
    for _, p in pairs(polled) do
        if t >= p.next then
            p.next = t + (p.phase == 'late' and LATE_MS or POLL_MS)
            pollOne(p, t)
        end
    end
end

--- The cache: a node it delivered before was promoted (PROMOTE, or a PUT with a new netId).
function Pr.onPromote(node, netId)
    if stopped or type(node) ~= 'table' or mtype(netId) ~= 'integer' then return end
    local id = node.id
    local old = P[id]
    if old and old.phase == 'demoting' then
        if old.netId == netId and node.parent == 0 and cloneOf(id, netId) then
            forgetHidden(id)                                   -- the server kept this clone (someone got in, RV4
            stat.kept = stat.kept + 1                          -- F12): its hidden copy is never shown, the swap
        else                                                   -- below deletes it
            revealAll(id)                                      -- re-promoted before the old clone went
        end
    end
    local p = track(node, netId)
    if node.parent ~= 0 then return end
    if p.sup then                                              -- the stand-in of an older clone
        local clone = cloneOf(id, netId)
        if clone then
            setSwapped(p, clone, node)
        else
            mat.update(node, 'promote', netId)                 -- no clone yet: the local copy comes back
        end
    elseif mat.handleOf(id) then
        poll(p)
    end
end

--- The cache: a node it delivered before was demoted. The clone goes DeleteDelayMs later (server): until then the
--- node's new local copy is hidden; one that never swapped is hidden now.
function Pr.onDemote(node)
    if stopped or type(node) ~= 'table' then return end
    local id = node.id
    local p = P[id]
    enterWant[id] = nil
    if not p then return end
    unpoll(p)
    local sup = p.sup
    local clone = (p.clone and DoesEntityExist(p.clone)) and p.clone or cloneOf(id, p.netId)
    if clone then
        p.phase, p.t0 = 'demoting', GetGameTimer()
        setClone(p, clone)
        local h = mat.handleOf(id)
        if h then
            local k = node.kind
            hide(h, p, ENTITY_CLASS[k and k.class] or 'prop', node)
        end
    else
        drop(p)
    end
    if sup then mat.update(node, 'demote') end                -- the stand-in re-creates (hidden while demoting)
end

--- Once a second: records of nodes the cache dropped, demotions whose clone went before any copy was made.
local function sweepP(t)
    for id, p in pairs(P) do
        local node = cache.node(id)
        if not node or node.gone then
            drop(p)
        elseif p.phase == 'demoting' and not hasHidden(id)
            and (not DoesEntityExist(p.clone) or t - p.t0 >= CLONE_WAIT_MS) then
            drop(p)
        elseif (p.phase == 'swapped' and not DoesEntityExist(p.clone)) or p.phase == 'lost' then
            local clone = cloneOf(id, p.netId)
            if clone and p.phase == 'lost' then                -- back on this client: it stands in again
                setSwapped(p, clone, p.sup and node or nil)
            elseif clone then                                  -- back under another handle
                setClone(p, clone)
                if p.sup then kinds.syncInteract(node, clone) end
            elseif p.phase == 'swapped' then                   -- left this client while still promoted (RV6 F7): no
                p.phase, p.t0 = 'lost', t                      -- local copy at a stale pose — the record stands in,
                setClone(p, nil)                               -- empty, until the clone is back, a DEMOTE or a new
                stat.lost = stat.lost + 1                      -- promotion
                if p.sup then kinds.clearInteract(id) end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- snCfg: the owner of a clone applies it once per control period (the §52 mapCfg pattern; only "on" states)
--------------------------------------------------------------------------------

local cfgKnown, cfgList, nCfg, cfgCursor = {}, {}, 0, 0   -- netId -> { i, entity, owned, absent }; sweep order

local function cfgForget(netId)
    local rec = cfgKnown[netId]
    if not rec then return end
    cfgKnown[netId] = nil
    local lastId = cfgList[nCfg]
    cfgList[rec.i] = lastId
    if cfgKnown[lastId] then cfgKnown[lastId].i = rec.i end
    cfgList[nCfg], nCfg = nil, nCfg - 1
end

--- The one-shot part of a vehicle clone's config while the server has not stripped it (D-A), else nil.
local function onceOf(c)
    return c.applied ~= true and type(c.once) == 'table' and c.once or nil
end

--- A vehicle clone (D-A): the cosmetic part (paint, props, plate, per-owner flags) every owner applies again; the
--- one-shot part (`once`: wear, lock, dirt) only while the server has not stripped it — then this client reports
--- core:scene:applied (and its sweep repeats that while the bag still carries it). A core vehicle's lock is its
--- `locked` bag (client/vehicles.lua), never the snapshot's.
local function applyVehicle(e, c)
    if type(c.paint) == 'table' then SetVehicleColours(e, toint(c.paint[1]) or 0, toint(c.paint[2]) or 0) end
    local V, once = Core.Vehicles, onceOf(c)
    local props = type(c.props) == 'table' and c.props or nil
    if once and type(once.wear) == 'table' then             -- one apply: the cosmetic props + the one-shot wear
        local all = {}
        for k, v in pairs(props or EMPTY) do all[k] = v end
        for k, v in pairs(once.wear) do all[k] = v end
        props = all
    end
    if props and V and V.setProps then V.setProps(e, props) end   -- we hold control: no wait
    if not DoesEntityExist(e) then return end
    if type(c.plate) == 'string' and c.plate ~= '' and #c.plate <= 8 then SetVehicleNumberPlateText(e, c.plate) end
    local st = Entity(e).state
    if once then
        if once.locked == true and st.coreVeh ~= true then SetVehicleDoorsLocked(e, 2) end
        if finite(once.dirt, 15) and once.dirt >= 0 then SetVehicleDirtLevel(e, once.dirt + 0.0) end
    end
    if c.invincible == true then SetEntityInvincible(e, true, false) end
    if c.frozen == true then FreezeEntityPosition(e, true) end   -- a kinematic mover
    if once then
        local id = toint(st.sn)
        if id and NetworkHasControlOfEntity(e) then report(id, 'applied', GetGameTimer()) end
    end
end

local function applyPed(e, c)
    local Spawn = Core.Spawn
    if type(c.appearance) == 'table' and Spawn and Spawn.applyAppearance then
        Spawn.applyAppearance(e, c.appearance)
    elseif type(c.variation) == 'table' and kinds.applyVariation then
        kinds.applyVariation(e, c.variation)
    else
        SetPedDefaultComponentVariation(e)
    end
    SetBlockingOfNonTemporaryEvents(e, c.blockEvents ~= false)
    if c.invincible == true then SetEntityInvincible(e, true, false) end
    if c.frozen == true then FreezeEntityPosition(e, true) end
    local s = c.scenario
    if type(s) == 'string' and s ~= '' and #s <= 64 and not IsPedUsingScenario(e, s) then
        TaskStartScenarioInPlace(e, s, 0, false)
    end
    if (type(c.weapon) == 'string' and c.weapon ~= '') or mtype(c.weapon) == 'integer' then
        GiveWeaponToPed(e, Core.Utils.hash(c.weapon), 0, false, true)
    end
end

--- A prop's rotation is re-applied only while it is kinematic (frozen): a dynamic clone keeps its physics pose.
local function applyProp(e, c)
    local r = c.rot
    if c.frozen == true then
        if type(r) == 'table' and finite(r.x, 3600) and finite(r.y, 3600) and finite(r.z, 3600) then
            SetEntityRotation(e, r.x + 0.0, r.y + 0.0, r.z + 0.0, 2, false)
        end
        FreezeEntityPosition(e, true)
    end
    if c.collision == false then SetEntityCollision(e, false, false) end
    if c.invincible == true then SetEntityInvincible(e, true, false) end
end

--- -> true when a vehicle's one-shot part is pending (the sweep re-reports it while the bag keeps it).
local function applyCfg(e, c)
    local kind = GetEntityType(e)
    stat.cfgApplied = stat.cfgApplied + 1
    if kind == 2 then
        CreateThread(function() applyVehicle(e, c) end)       -- setProps may wait for control: never in the handler
        return onceOf(c) ~= nil
    elseif kind == 1 then
        applyPed(e, c)
    elseif kind == 3 then
        applyProp(e, c)
    end
    return false
end

--- RV5 F1 / RV6 F1: this client applied a clone's one-shot part in this control period; while the LIVE bag still
--- carries it (the report was lost, or the server has not taken it yet) the report goes again (≥ 2 s apart).
local function onceCheck(e, rec)
    local st = Entity(e).state
    local c = st.sn ~= nil and st.snCfg or nil
    local id = toint(st.sn)
    if not id or type(c) ~= 'table' or not onceOf(c) then
        rec.once = false
        return
    end
    report(id, 'applied', GetGameTimer())
end

--- Applies the config once per control: `value` is the new bag value inside the change handler (the bag still
--- holds the old one there), otherwise the live bag is read (sn must be there: net ids are recycled).
local function cfgCheck(netId, rec, value)
    if not NetworkDoesEntityExistWithNetworkId(netId) then
        rec.owned, rec.absent = false, rec.absent + 1
        if rec.absent >= CFG_ABSENT then cfgForget(netId) end
        return
    end
    rec.absent = 0
    local e = NetworkGetEntityFromNetworkId(netId)
    if not e or e == 0 or not NetworkHasControlOfEntity(e) then
        rec.owned = false
        return
    end
    if rec.owned and rec.entity == e then
        if rec.once then onceCheck(e, rec) end
        return
    end
    local c = value
    if c == nil then
        local st = Entity(e).state
        c = st.sn ~= nil and st.snCfg or nil
    end
    if type(c) ~= 'table' then return cfgForget(netId) end
    rec.once = applyCfg(e, c)
    rec.owned, rec.entity = true, e
end

local function cfgSweep()
    for _ = 1, math.min(nCfg, CFG_CHECKS) do
        if nCfg == 0 then return end
        cfgCursor = cfgCursor % nCfg + 1
        local netId = cfgList[cfgCursor]
        local rec = cfgKnown[netId]
        if rec then cfgCheck(netId, rec) end
    end
end

AddStateBagChangeHandler('snCfg', nil, function(bagName, _, value)
    local netId = not stopped and type(bagName) == 'string' and toint(tonumber(bagName:match('^entity:(%d+)$')))
    if not netId then return end
    if type(value) ~= 'table' then return cfgForget(netId) end
    local rec = cfgKnown[netId]
    if not rec then
        nCfg = nCfg + 1
        rec = { i = nCfg, entity = 0, owned = false, absent = 0, once = false }
        cfgList[nCfg], cfgKnown[netId] = netId, rec
    end
    rec.owned = false                                          -- a new config is applied again
    cfgCheck(netId, rec, value)
    ensureSweep()
end)

--------------------------------------------------------------------------------
-- Loops: the pending loop (per frame only while a hidden copy waits, else 100 ms while copies wait for clones),
-- the 1 s sweep (while anything is known) and the enter watch (only while local vehicle copies exist)
--------------------------------------------------------------------------------

-- fxlint-disable-next-line C003 -- assigns the forward-declared local `pendingLoop` (ensurePending starts it)
pendingLoop = function()
    while not stopped and (nHidden > 0 or nPoll > 0) do
        local t = GetGameTimer()
        if nHidden > 0 then revealCheck(t) end
        if nPoll > 0 then pollAll(t) end
        -- a frame only while a hidden copy waits (a demotion's reveal, ~1 s): shown the frame its clone is gone
        Wait(nHidden > 0 and 0 or POLL_MS)
    end
    pending = false
end

-- fxlint-disable-next-line C003 -- assigns the forward-declared local `sweepLoop` (ensureSweep starts it)
sweepLoop = function()
    while not stopped and (nP > 0 or nCfg > 0) do
        Wait(SWEEP_MS)
        sweepP(GetGameTimer())
        cfgSweep()
    end
    sweeping = false
end

-- fxlint-disable-next-line C003 -- assigns the forward-declared local `driveLoop` (addDrive starts it)
driveLoop = function()
    local Motion = Core.SceneMotion
    while not stopped and nDrive > 0 do
        local clock = Core.Clock
        local owned, tn = false, (clock and clock.now) and clock.now() or GetGameTimer()
        for id, p in pairs(drive) do
            local node, e = cache.node(id), p.clone
            if P[id] ~= p or p.phase ~= 'swapped' or not node or node.motion == nil or not e then
                drive[id], nDrive = nil, nDrive - 1
            elseif NetworkHasControlOfEntity(e) then
                owned = true
                local x, y, z, rx, ry, rz = Motion.pose(node.x or 0.0, node.y or 0.0, node.z or 0.0, node.rx or 0.0,
                    node.ry or 0.0, node.rz or 0.0, node.motion, tn)
                SetEntityCoordsNoOffset(e, x, y, z, false, false, false)
                SetEntityRotation(e, rx, ry, rz, 2, false)
            end
        end
        -- a frame only while this client owns a promoted mover's clone: it is placed right now
        Wait(owned and 0 or 500)
    end
    driving = false
end

--- 4 Hz while a local vehicle copy is within 6 m of the ped (slower when farther): the ped trying to get into one
--- reports `enter`; the swap then tasks it into the clone.
function Pr.enterLoop()
    while nVeh > 0 and not stopped do
        local ped = PlayerPedId()
        local c = GetEntityCoords(ped, false)
        local best = huge
        for _, v in pairs(vehs) do
            local x, y, z = v.x, v.y, v.z
            if v.mover then
                local p = GetEntityCoords(v.e, false)
                x, y, z = p.x, p.y, p.z
            end
            local dx, dy, dz = x - c.x, y - c.y, z - c.z
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 < best then best = d2 end
        end
        local wait = ENTER_SLOW_MS
        if best <= ENTER_NEAR * ENTER_NEAR then
            wait = ENTER_MS
            local veh = GetVehiclePedIsTryingToEnter(ped)
            local id = veh and veh ~= 0 and vehOf[veh] or nil
            if id then                                          -- (the swap tasks the ped into the clone)
                local t, seat = GetGameTimer(), GetSeatPedIsTryingToEnter(ped)
                local want = enterWant[id] or {}
                want.seat, want.at = (mtype(seat) == 'integer' and seat >= -1 and seat <= 15) and seat or -1, t
                enterWant[id] = want
                if not P[id] then report(id, 'enter', t) end      -- promoted already: nothing to ask for
            end
        elseif best < huge then
            local ms = (sqrt(best) - ENTER_NEAR) * 100.0          -- 10 m/s: nobody closes the gap faster on foot
            wait = ms < ENTER_MS and ENTER_MS or (ms > ENTER_SLOW_MS and ENTER_SLOW_MS or math.floor(ms))
        end
        Wait(wait)
    end
    entering = false
end

--- Damage to a local copy: args[1] = the victim (the event data's first field — to confirm in game). Anything
--- else in that slot (no table, a float, a string, an entity that is not a local copy) reports nothing.
local function onDamage(args)
    local victim = type(args) == 'table' and rawget(args, 1) or nil
    if mtype(victim) ~= 'integer' or victim <= 0 then return end
    local id = mat.idOf(victim)
    local node = id and cache.node(id)
    if not node or node.netId ~= nil or node.parent ~= 0 then return end
    local k = node.kind
    if not (k and ENTITY_CLASS[k.class]) then return end
    report(id, 'damaged', GetGameTimer())
end

-- event-driven, fails safe: a wrong argument layout reports nothing and never raises
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' or stopped then return end
    pcall(onDamage, args)
end)

-- the server asks the owner of a clone for its props at the demotion (only the owner's answer counts, server side)
Core.Callback.register('core:scene:props', { { 'integer', min = 1, max = 65535 } }, function(netId)
    if not NetworkDoesEntityExistWithNetworkId(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if not e or e == 0 or not DoesEntityExist(e) or Entity(e).state.sn == nil then return nil end
    if not NetworkHasControlOfEntity(e) or GetEntityType(e) ~= 2 then return nil end
    local V = Core.Vehicles
    local props = V and V.getProps and V.getProps(e) or nil
    if props then stat.propsAnswered = stat.propsAnswered + 1 end
    return props
end)

--------------------------------------------------------------------------------
-- Interface, stats, core stop
--------------------------------------------------------------------------------

--- The networked clone standing in for node `id` on this client, or nil (client/scene.lua's Scene.handleOf).
function Pr.cloneOf(id)
    local p = P[id]
    return p and p.phase == 'swapped' and p.clone and DoesEntityExist(p.clone) and p.clone or nil
end

--- The node id of a clone this client matched (standing in, or still there while its node is demoted), or nil
--- (client/scene.lua's Scene.idOf; two table reads and one native, no state-bag read).
function Pr.idOfClone(entity)
    local id = mtype(entity) == 'integer' and cloneIds[entity] or nil
    local p = id and P[id]
    if p and p.clone == entity and (p.phase == 'swapped' or p.phase == 'demoting') and DoesEntityExist(entity) then
        return id
    end
    return nil
end

function Pr.stats()
    local phases = { wait = 0, late = 0, swapped = 0, lost = 0, demoting = 0 }
    for _, p in pairs(P) do phases[p.phase] = (phases[p.phase] or 0) + 1 end
    local out = { known = nP, phases = phases, polled = nPoll, hidden = nHidden, vehicles = nVeh, configs = nCfg,
        drives = nDrive, pending = pending, sweeping = sweeping, entering = entering, driving = driving }
    for k, v in pairs(stat) do out[k] = v end
    return out
end

-- core stops: the materialiser deletes every local copy; nothing here outlives it
AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    stopped = true
end)

C.promote = Pr
