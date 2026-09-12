-- core/client/hudfeed.lua
-- Feeds the HUD panel of the NUI shell (DESIGN §21): ONE 250 ms thread that runs
-- only while the local player is loaded and the HUD is visible, reads
-- health/armour/speed every tick and street/zone every 1000 ms, and pushes only
-- the values that actually changed through Core.UI.hud.set (which coalesces at
-- 100 ms itself, DESIGN §6.10). While Core.UI.hud.isVisible() is false the thread
-- idles at 1000 ms.
-- `health` and `armour` are 0..100 percentages, `speed` is km/h (the natives give
-- raw hit points and m/s), `street`/`zone` are display strings.
-- Natives verified with fxref on 2026-09-12: PlayerPedId, GetEntityCoords(entity,
-- alive), GetEntityHealth, GetEntityMaxHealth, GetPedArmour, GetEntitySpeed,
-- GetStreetNameAtCoord(x, y, z) -> streetHash, crossingHash, GetStreetNameFromHashKey,
-- GetNameOfZone, GetFilenameForAudioConversation (the GetLabelText alias),
-- GetSafeZoneSize, GetAspectRatio(b), GetActualScreenResolution, GetGameTimer
-- (all client) and GetCurrentResourceName (shared).

local UI = Core.UI

local TICK_MS <const> = 250
local SLOW_TICK_MS <const> = 1000
local HIDDEN_TICK_MS <const> = 1000

-- client/ui.lua loads before this file (fxmanifest order), so its HUD getter is
-- the single source of truth for visibility: no mirrored flag, no extra event.
local hudIsVisible = UI['hud.isVisible']

local running = false
local minimapSent = false
local slowAt = 0
local last = {}                     -- field -> last pushed value
local place = { street = '', zone = '' }
local placeAt = -SLOW_TICK_MS       -- GetGameTimer() of the last street/zone read

--- Config.Hud flag (default on) — Core.Config is core's own config (DESIGN §2.0).
local function hudCfg(key)
    local cfg = Core.Config or Config
    local value = cfg and cfg.Hud and cfg.Hud[key]
    return value ~= false
end

--- The minimap anchor as fractions of the screen (x/y = top-left corner, w/h = size).
--- Canonical GTA V minimap-anchor formula, the one every HUD resource uses
--- (community "GetMinimapAnchor" snippet, derived from the game's own safe-zone
--- maths): the map is 1/(4 * aspectRatio) of the screen wide and 1/5.674 of it
--- high, and it is inset from the bottom-left by the safe-zone margin
--- `safeX * |safeZoneSize - 1| * 10` (safeX = 1/20, safeY = safeX * aspectRatio).
--- Ultra-wide setups report an aspect ratio the formula cannot use, so anything
--- above 2.0 falls back to 16:9. Computed once: it only changes when the player
--- edits the safe-zone slider or the resolution.
local function computeMinimap()
    local resX, resY = GetActualScreenResolution()
    if not resX or resX < 1 or resY < 1 then return nil end
    local aspect = GetAspectRatio(false)
    if not aspect or aspect <= 0.0 then return nil end
    if aspect > 2.0 then aspect = 16.0 / 9.0 end
    local safe = GetSafeZoneSize()
    if not safe then return nil end
    local sx, sy = 1.0 / resX, 1.0 / resY
    local safeX = 1.0 / 20.0
    local safeY = safeX * aspect
    local w = sx * (resX / (4.0 * aspect))
    local h = sy * (resY / 5.674)
    local x = sx * (resX * (safeX * (math.abs(safe - 1.0) * 10.0)))
    local bottom = 1.0 - sy * (resY * (safeY * (math.abs(safe - 1.0) * 10.0)))
    return { x = x, y = bottom - h, w = w, h = h }
end

--- Sends the anchor once per shell (re-sent on ui_ready: a reloaded shell forgot it).
local function pushMinimap()
    if minimapSent then return end
    local rect = computeMinimap()
    if not rect then return end
    minimapSent = true
    UI['hud.set']({ minimap = rect })
end

-- ------------------------------------------------------------ sampling ----

local round = Core.Utils.round         -- round half up, integer result
local clamp = Core.Utils.clamp

--- Peds sit at 100 HP when dead and `GetEntityMaxHealth` when full, so the bar
--- percentage is the span above 100, not the raw hit points.
local function healthPercent(hp, max)
    if max > 100 then
        return clamp(round((hp - 100) / (max - 100) * 100), 0, 100)
    end
    if max <= 0 then return 0 end
    return clamp(round(hp / max * 100), 0, 100)
end

--- Street and zone as display strings ('' when the game has no name for them).
local function readPlace(coords)
    local street = ''
    local streetHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    if streetHash and streetHash ~= 0 then
        street = GetStreetNameFromHashKey(streetHash) or ''
    end
    local zone = ''
    local code = GetNameOfZone(coords.x, coords.y, coords.z)
    if type(code) == 'string' and code ~= '' then
        -- GetLabelText is exposed under this name; it answers 'NULL' for unknown labels.
        local label = GetFilenameForAudioConversation(code)
        zone = (type(label) == 'string' and label ~= '' and label ~= 'NULL') and label or code
    end
    return street, zone
end

--- Street/zone of the local ped, re-read at most once per SLOW_TICK_MS. Shared by
--- the feed loop and the `core:player:street` callback (Core.Player.getStreet, §22).
local function refreshPlace()
    local now = GetGameTimer()
    if (now - placeAt) < SLOW_TICK_MS then return place.street, place.zone end
    placeAt = now
    place.street, place.zone = readPlace(GetEntityCoords(PlayerPedId(), true))
    return place.street, place.zone
end

--- Adds `value` to the payload only when it differs from what was pushed last.
local function changed(payload, field, value)
    if last[field] == value then return end
    last[field] = value
    payload[field] = value
end

-- ---------------------------------------------------------------- feed ----

--- The one feed thread. 250 ms while the HUD is up, 1000 ms while it is hidden;
--- it exits as soon as the session is no longer loaded and is restarted by the
--- playerLoaded hook below.
local function feed()
    while running do
        local now = GetGameTimer()
        local slow = (now - slowAt) >= SLOW_TICK_MS
        if slow then
            slowAt = now
            if LocalPlayer.state.loaded ~= true then break end
        end
        local sleep = HIDDEN_TICK_MS
        if hudIsVisible() then
            sleep = TICK_MS
            local ped = PlayerPedId()
            local payload = {}
            if hudCfg('ShowHealth') then
                changed(payload, 'health', healthPercent(GetEntityHealth(ped), GetEntityMaxHealth(ped)))
            end
            if hudCfg('ShowArmour') then
                changed(payload, 'armour', clamp(GetPedArmour(ped), 0, 100))
            end
            if hudCfg('ShowSpeed') then
                changed(payload, 'speed', round(GetEntitySpeed(ped) * 3.6))
            end
            if slow and hudCfg('ShowStreet') then
                local street, zone = refreshPlace()
                changed(payload, 'street', street)
                changed(payload, 'zone', zone)
            end
            if next(payload) ~= nil then
                UI['hud.set'](payload)
            end
        end
        Wait(sleep)
    end
    running = false
end

-- -------------------------------------------------------------- wiring ----

--- core feeds the HUD only for a loaded session; client/main.lua turns the HUD on
--- from Config.UI.HudEnabled right after this hook, and Core.UI.hud.isVisible()
--- follows every later toggle (local or server-driven, DESIGN §21).
Core.onPlayerLoaded(function()
    last = {}
    slowAt = 0
    pushMinimap()
    if running then return end
    running = true
    CreateThread(feed)
end)

-- A reloaded shell forgot the anchor and every HUD value: send them again.
Core.on('uiReady', function()
    minimapSent = false
    last = {}
    pushMinimap()
end)

-- Answers Core.Player.getStreet(src) on the server (server/getters.lua, §22).
Core.Callback.register('core:player:street', function()
    local street, zone = refreshPlace()
    return street, zone
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    running = false
end)
