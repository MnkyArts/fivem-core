--[[ core — client/scene_focus.lua — Core.Scene's focus reporter, resync requests and bucket changes
     (DESIGN §55.6, §55.10). Loads RIGHT AFTER client/scene_cache.lua (it asserts CoreSceneRuntime.cache) and fills
     C.focus; internal like every client scene file (client/scene.lua clears the one-shot global).
       * Focus reporter (one thread): the rendered camera every 250 ms while moving, 1000 ms still, never before
         LocalPlayer.state.loaded; velocity from successive samples (a jump of 150 m or more is a teleport: none).
         `core:scene:focus (x, y, z, vx, vy, vz, seq, held)` when the camera moved ≥ Focus.MinMove, crossed a
         near-cell border, the bucket changed or 5 s passed while moving — ≥ MinIntervalMs + 30 ms apart (the
         server's cooldown plus network jitter). `held` = the versions of the cache's LRU cells, newest first,
         ≤ 48, keyed '<grid>:<key>:<variant>' (a return costs a journal, not a pack). Every sample also runs the
         cache's housekeeping (LRU expiry, subscriptions whose content never came).
       * Resync requests (the cache's gaps): `core:scene:resync (grid, key, variant, v)`, one per 110 ms (the
         server's cooldown is 62 ms), at most one per cell per 2 s; a cell whose request went out `awaits` its
         answer (the cache keeps the entries that arrive meanwhile).
       * Bucket changes (`core:client:bucketChanged`, §48): a REAL change (a known bucket, another one) drops the
         whole cache (the server re-subscribes) and a report goes out at once; the first notice only seeds the
         bucket. A change the client is not told about arrives as the stream's RESET op: C.focus.onReset.
     C.focus.requestResync(cell) · C.focus.reportSoon() · C.focus.onReset(reason) · C.focus.stats()

     Natives (fxref 2026-09-26, apiset client): GetFinalRenderedCamCoord() -> vector3, GetGameTimer().
     Runtime helpers: RegisterNetEvent, AddEventHandler, TriggerServerEvent, CreateThread, Wait, SetTimeout.
]]

local C = CoreSceneRuntime
assert(type(C) == 'table' and type(C.cache) == 'table',
    'client/scene_focus.lua loads right after client/scene_cache.lua (CoreSceneRuntime.cache)')
local cache = C.cache
local LRU <const> = cache.STATE.lru      -- a cell state: unsubscribed, kept in the cache's LRU
local floor, tointeger = math.floor, math.tointeger

local cfg = (type(Config) == 'table' and type(Config.Scene) == 'table') and Config.Scene or {}
local focusCfg = type(cfg.Focus) == 'table' and cfg.Focus or {}
local function setting(value, default, low, high)
    value = tonumber(value) or default
    if value ~= value or value < low then return low end
    return value > high and high or value
end

local CELL_SIZE <const> = setting(cfg.CellSize, 128, 8, 8192)       -- the near grid: border crossings report
local MIN_MOVE <const> = setting(focusCfg.MinMove, 16, 1, 1000)
local MIN_MOVE2 <const> = MIN_MOVE * MIN_MOVE
local REPORT_GAP_MS <const> = floor(setting(focusCfg.MinIntervalMs, 250, 50, 10000)) + 30
local SAMPLE_MOVING_MS <const>, SAMPLE_STILL_MS <const>, LOADED_POLL_MS <const> = 250, 1000, 1000
local MOVING_SPEED2 <const> = 0.25       -- (0.5 m/s)²: slower than this between two samples = still
local MOVING_REPORT_MS <const> = 5000    -- a moving camera reports at least this often
local TELEPORT2 <const> = 150.0 * 150.0  -- a jump this large between two samples is a teleport: no velocity
local MAX_SPEED <const> = 200.0          -- reported velocity clamp per axis (m/s); the server clamps its lead
local HELD_MAX <const> = 48              -- held versions per report (§55.19)
local RESYNC_GAP_MS <const> = 110        -- between two resync requests (the server's cooldown: 62 ms)
local RESYNC_CELL_MS <const> = 2000      -- per cell
local MAX_SEQ <const> = 0x7FFFFFFF

local Focus = {}
C.focus = Focus

local stopped = false
local bucket = nil                       -- the routing bucket the cache's content belongs to (nil = not told yet)
local stats = { resyncs = 0, reports = 0, resets = 0 }

--------------------------------------------------------------------------------
-- resync requests: one per RESYNC_GAP_MS, at most one per cell per RESYNC_CELL_MS (coalesced)
--------------------------------------------------------------------------------

local resyncQ, rqHead, rqTail = {}, 1, 0
local resyncArmed, lastResyncAt = false, -RESYNC_GAP_MS
local resync = {}                        -- resync.drain, defined below (arm -> drain -> arm)

local function armResync(ms)
    if resyncArmed or stopped then return end
    resyncArmed = true
    SetTimeout(ms > 0 and ms or 0, resync.drain)
end

function resync.drain()
    resyncArmed = false
    if stopped then return end
    local t = GetGameTimer()
    local wait = lastResyncAt + RESYNC_GAP_MS - t
    if wait > 0 then return armResync(wait) end
    while rqHead <= rqTail do
        local cell = resyncQ[rqHead]
        resyncQ[rqHead], rqHead = nil, rqHead + 1
        cell.resyncQueued = false
        if not cell.dropped and cell.state ~= LRU then        -- not subscribed: nothing the server answers
            cell.resyncAt, lastResyncAt, cell.awaiting = t, t, true
            stats.resyncs = stats.resyncs + 1
            -- v = what it holds OF the subscribed variant (0 while that is still the other variant's content)
            local v = cache.baseOf(cell, cell.variant)
            TriggerServerEvent('core:scene:resync', cell.grid, cell.key, cell.variant, v)
            break
        end
    end
    if rqHead <= rqTail then armResync(RESYNC_GAP_MS) else rqHead, rqTail = 1, 0 end
end

--- Asks the server for a cell's content again (a gap, a cut payload, a pack that never came): queued, one
--- request per 110 ms, a cell at most once per 2 s — a need within those 2 s is deferred, never dropped: the
--- cell asks again when they are over if it still misses content (`cell.awaiting`, RV2 F10).
---@param cell table the cache's cell record
function Focus.requestResync(cell)
    if cell.resyncQueued or cell.dropped or cell.state == LRU then return end
    local t = GetGameTimer()
    local due = cell.resyncAt and cell.resyncAt + RESYNC_CELL_MS or t
    if due > t then
        if cell.resyncDeferred then return end
        cell.resyncDeferred = true
        SetTimeout(due - t, function()
            cell.resyncDeferred = false
            if not stopped and cell.awaiting then Focus.requestResync(cell) end
        end)
        return
    end
    cell.resyncQueued = true
    rqTail = rqTail + 1
    resyncQ[rqTail] = cell
    armResync(lastResyncAt + RESYNC_GAP_MS - t)
end

local function clearResyncs()
    for i = rqHead, rqTail do
        local cell = resyncQ[i]
        if cell then cell.resyncQueued = false end
        resyncQ[i] = nil
    end
    rqHead, rqTail = 1, 0
end

--------------------------------------------------------------------------------
-- the focus reporter (§55.6 / §55.10): one thread, one camera read per sample
--------------------------------------------------------------------------------

local rep = { loaded = false, sentAt = nil, sx = 0.0, sy = 0.0, sz = 0.0, x = 0.0, y = 0.0, z = 0.0,
    vx = 0.0, vy = 0.0, vz = 0.0, moving = false, seq = 0, dirty = false, armed = false }
local held = {}                          -- reused: TriggerServerEvent packs it at once

local function sendReport(t)
    for k in pairs(held) do held[k] = nil end
    local lru, n = cache.lru(), 0
    for i = #lru, 1, -1 do               -- newest first
        local c = lru[i]
        if c.v > 0 then
            local hk = c.hk
            if not hk or c.hkVariant ~= c.cv then       -- the key names the CONTENT's variant: cached per cell
                hk = ('%d:%d:%d'):format(c.grid, c.key, c.cv)
                c.hk, c.hkVariant = hk, c.cv
            end
            held[hk], n = c.v, n + 1
            if n >= HELD_MAX then break end
        end
    end
    rep.seq = rep.seq % MAX_SEQ + 1
    rep.sentAt, rep.sx, rep.sy, rep.sz, rep.dirty = t, rep.x, rep.y, rep.z, false
    stats.reports = stats.reports + 1
    TriggerServerEvent('core:scene:focus', rep.x, rep.y, rep.z, rep.vx, rep.vy, rep.vz, rep.seq, held)
end

local function due(t)
    if not rep.sentAt or rep.dirty then return true end
    local x, y, sx, sy = rep.x, rep.y, rep.sx, rep.sy
    local dx, dy, dz = x - sx, y - sy, rep.z - rep.sz
    if dx * dx + dy * dy + dz * dz >= MIN_MOVE2 then return true end
    if floor(x / CELL_SIZE) ~= floor(sx / CELL_SIZE) or floor(y / CELL_SIZE) ~= floor(sy / CELL_SIZE) then
        return true
    end
    return rep.moving and t - rep.sentAt >= MOVING_REPORT_MS
end

--- Reports now, or as soon as the server's cooldown allows (one timer at most).
local function tryReport(t)
    if stopped or not rep.loaded or not due(t) then return end
    local wait = rep.sentAt and rep.sentAt + REPORT_GAP_MS - t or 0
    if wait <= 0 then return sendReport(t) end
    if rep.armed then return end
    rep.armed = true
    SetTimeout(wait, function()
        rep.armed = false
        local now = GetGameTimer()
        if not stopped and (not rep.sentAt or now - rep.sentAt >= REPORT_GAP_MS) and due(now) then sendReport(now) end
    end)
end

--- Sends a focus report as soon as allowed (a teleport landed, an area is awaited: Scene.waitAreaReady).
function Focus.reportSoon()
    rep.dirty = true
    tryReport(GetGameTimer())
end

local function clampV(v)
    if v > MAX_SPEED then return MAX_SPEED elseif v < -MAX_SPEED then return -MAX_SPEED end
    return v
end

CreateThread(function()
    local lastT, lx, ly, lz = nil, 0.0, 0.0, 0.0
    while not stopped do
        if not rep.loaded then rep.loaded = LocalPlayer.state.loaded == true end
        if not rep.loaded then
            Wait(LOADED_POLL_MS)         -- no session yet: the loading camera is no focus
        else
            local cam = GetFinalRenderedCamCoord()
            local x, y, z, t = cam.x, cam.y, cam.z, GetGameTimer()
            local vx, vy, vz = 0.0, 0.0, 0.0
            if lastT and t > lastT then
                local dx, dy, dz = x - lx, y - ly, z - lz
                if dx * dx + dy * dy + dz * dz < TELEPORT2 then
                    local dt = (t - lastT) / 1000
                    vx, vy, vz = clampV(dx / dt), clampV(dy / dt), clampV(dz / dt)
                end
            end
            lastT, lx, ly, lz = t, x, y, z
            rep.x, rep.y, rep.z, rep.vx, rep.vy, rep.vz = x, y, z, vx, vy, vz
            rep.moving = vx * vx + vy * vy + vz * vz >= MOVING_SPEED2
            tryReport(t)
            cache.housekeep(t)           -- LRU expiry, pending subscriptions that never got content
            Wait(rep.moving and SAMPLE_MOVING_MS or SAMPLE_STILL_MS)
        end
    end
end)

--------------------------------------------------------------------------------
-- bucket changes (§48): the cached content is the old bucket's
--------------------------------------------------------------------------------

-- Only a REAL change resets: the first notice just tells which bucket the content is of (Player.setBucket sends
-- one even when the bucket stays — an admin goto / return in bucket 0 — and the server then keeps its `sent`),
-- RV2 F1. A change the client is not told about reaches it as the stream's RESET op (Focus.onReset, F14).
RegisterNetEvent('core:client:bucketChanged', function(b)
    b = tointeger(b)
    if stopped or not b or b < 0 then return end
    if bucket ~= nil and b ~= bucket then
        local nCells, nNodes = cache.count()
        if nCells > 0 or nNodes > 0 then
            clearResyncs()
            cache.reset()
        end
    end
    bucket = b
    rep.dirty = true
    tryReport(GetGameTimer())
end)

--- The stream's RESET op (the cache dropped everything, LRU included): nothing queued is valid any more, and the
--- server wants a report at once to subscribe the new window.
function Focus.onReset(reason)
    clearResyncs()
    stats.resets = stats.resets + 1
    stats.lastReset = reason
    rep.dirty = true
    tryReport(GetGameTimer())
end

--- { bucket, loaded, seq, reports, resyncs, resyncQueued } — merged into Scene.stats().
function Focus.stats()
    return { bucket = bucket, loaded = rep.loaded, seq = rep.seq, reports = stats.reports, resyncs = stats.resyncs,
        resyncQueued = rqTail - rqHead + 1, streamResets = stats.resets, lastResetReason = stats.lastReset }
end

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then stopped = true end
end)
