--[[
    core / lib/clock/shared.lua  —  Core.Clock (DESIGN §55.2)

    One millisecond timeline for motion plans, animation phases and media play heads. Values are u32
    (they wrap every 49.7 days) and are only ever compared through `Clock.diff`, a signed 32-bit
    difference, so a wrap between two stamps is harmless as long as they are < 24.8 days apart.

      server   GetGameTimer() & 0xFFFFFFFF
      client   GetNetworkTimeAccurate() & 0xFFFFFFFF — OneSync's netTimeSync clock, the same timeline as
               the server's (±5–20 ms, research R1 §3 / R7 §3). Latched once per frame (GetFrameCount), so
               every consumer of a frame sees one instant and `now()` costs one network-time read per frame.
               While the network clock reads 0 (not synced yet) or the native is missing, `now()` answers
               GetGameTimer() & 0xFFFFFFFF plus the last known offset (0 until a network sample was seen),
               so the timeline stays continuous; `ready()` tells a consumer when it is the real network time.

    Clock.now() -> integer                 u32 ms (see above)
    Clock.diff(a, b) -> integer            a - b as a signed 32-bit difference: ((a - b + 2^31) % 2^32) - 2^31
    Clock.add(t, ms) -> integer            (t + ms) % 2^32 (a fractional ms is floored)
    Clock.at(ms) -> integer                Clock.add(Clock.now(), ms): future-stamped plans
    Clock.ready() -> boolean               server: true; client: the network time answered non-zero twice with an
                                           advancing value (sticky once true)
    Clock.local2net(localMs) -> integer    client: GetGameTimer()-based stamp -> network time (offset = the max of
    Clock.net2local(netMs) -> integer      now() - GetGameTimer() over the last 10 s, sampled once per frame);
                                           server: identity (masked to u32)

    Natives: IsDuplicityVersion (CFX, shared); GetGameTimer (CFX server / MISC client); client only:
    GetNetworkTimeAccurate (NETWORK), GetFrameCount (MISC). All fxref-verified 2026-09-26.
]]

local ns = ...

local MASK <const> = 0xFFFFFFFF
local SPAN <const> = 0x100000000
local HALF <const> = 0x80000000
local floor = math.floor

--- a - b as a signed 32-bit difference (wrap-safe); always an integer.
local function diff(a, b)
    return floor((a - b + HALF) % SPAN) - HALF
end

--- (t + ms) mod 2^32; always an integer.
local function add(t, ms)
    return floor(t + ms) % SPAN
end

ns.diff = diff
ns.add = add

if IsDuplicityVersion() then
    local GetGameTimer = GetGameTimer

    function ns.now()
        return GetGameTimer() & MASK
    end

    function ns.at(ms)
        return add(GetGameTimer() & MASK, ms)
    end

    function ns.ready()
        return true
    end

    function ns.local2net(localMs)
        return add(localMs, 0)
    end

    function ns.net2local(netMs)
        return add(netMs, 0)
    end

    return
end

--------------------------------------------------------------------------------
-- client: the network clock, latched per frame
--------------------------------------------------------------------------------

local GetGameTimer = GetGameTimer
local frameCount = GetFrameCount                  -- nil only offline: then every call samples
local networkTime = GetNetworkTimeAccurate        -- nil = missing native: the game timer is the clock

local OFFSET_SLOTS <const> = 10                   -- one slot per second of the 10 s max filter

local latchFrame, latchValue = nil, 0
local lastNet, isReady = nil, false
local offset = 0                                  -- network time - game timer, max-filtered over 10 s
local slotSec, slotMax = {}, {}
for i = 1, OFFSET_SLOTS do slotSec[i], slotMax[i] = -1, 0 end

--- Folds one (network, game) pair into the 10 s max filter. Allocation-free.
local function recordOffset(net, game)
    local off = diff(net, game)
    local sec = game // 1000
    local i = sec % OFFSET_SLOTS + 1
    if slotSec[i] ~= sec then
        slotSec[i], slotMax[i] = sec, off
    elseif off > slotMax[i] then
        slotMax[i] = off
    end
    local best = off
    for j = 1, OFFSET_SLOTS do
        local s = slotSec[j]
        -- a slot from the future (the u32 game timer wrapped) or older than 10 s no longer counts
        if s >= 0 and s <= sec and sec - s < OFFSET_SLOTS and slotMax[j] > best then best = slotMax[j] end
    end
    offset = best
end

--- One fresh reading of the timeline (called at most once per frame through the latch).
local function sample()
    local game = GetGameTimer() & MASK
    local raw = networkTime and networkTime()
    if type(raw) ~= 'number' or raw == 0 then
        return add(game, offset)                  -- not synced (yet): game timer, continuous once seen
    end
    local net = raw & MASK
    if not isReady then
        if lastNet ~= nil and diff(net, lastNet) > 0 then isReady = true end
        lastNet = net
    end
    recordOffset(net, game)
    return net
end

function ns.now()
    if frameCount then
        local frame = frameCount()
        if frame == latchFrame then return latchValue end
        latchFrame = frame
    end
    latchValue = sample()
    return latchValue
end

function ns.at(ms)
    return add(ns.now(), ms)
end

function ns.ready()
    if not isReady then ns.now() end
    return isReady
end

function ns.local2net(localMs)
    ns.now()                                      -- refreshes the offset (once per frame)
    return add(localMs, offset)
end

function ns.net2local(netMs)
    ns.now()
    return add(netMs, -offset)
end
