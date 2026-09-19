-- core/client/hudfeed.lua
-- Feeds the vitals HUD of the NUI shell (DESIGN §39.5, §21): ONE thread that runs
-- only while the local player is loaded, ticks at 100 ms while the HUD is visible
-- and idles at 1000 ms while it is not. Three cadences inside that tick:
--   every tick   MumbleIsPlayerTalking -> `talking` (the mic tile), Config.Hud.ShowVoice
--   every 250 ms health, armour (and speed only when Config.Hud.ShowSpeed == true)
--   every 1000 ms MumbleIsConnected -> `muted`, street/zone when ShowStreet == true
-- Only values that actually changed are pushed, through Core.UI.hud.set (which
-- coalesces at 100 ms itself, §6.10), so an idle, silent player sends nothing at
-- all; the payload table is reused and emptied after each send, because a 100 ms
-- loop must not feed the GC (AGENTS §3, resmon averages over 64 frames).
-- `health` and `armour` are 0..100 percentages, `speed` is km/h (the natives give
-- raw hit points and m/s), `street`/`zone` are display strings, `talking`/`muted`
-- are booleans read the §30.4 way (`v == true or v == 1`). The minimap rect rides
-- with `anchor`/`scale` in one message per shell.
-- Natives verified with fxref on 2026-09-19: PlayerPedId, PlayerId,
-- MumbleIsPlayerTalking(player), MumbleIsConnected(), GetEntityCoords(entity,
-- alive), GetEntityHealth, GetEntityMaxHealth, GetPedArmour, GetEntitySpeed,
-- GetStreetNameAtCoord(x, y, z) -> streetHash, crossingHash, GetStreetNameFromHashKey,
-- GetNameOfZone, GetFilenameForAudioConversation (the GetLabelText alias),
-- GetSafeZoneSize, GetAspectRatio(b), GetActualScreenResolution, GetGameTimer
-- (all client) and GetCurrentResourceName (shared).

local UI = Core.UI

local TICK_MS <const> = 100          -- the visible tick: the mic beat (§39.5)
local FAST_TICK_MS <const> = 250     -- health / armour / speed
local SLOW_TICK_MS <const> = 1000    -- mumble connection, street / zone
local HIDDEN_TICK_MS <const> = 1000

--- The two placements of §39.4 and the bounds of the HUD unit multiplier. The bottom centre and
--- right are taken: the progress bar / text UI sit there, and so do the key hints / spinner.
local ANCHORS <const> = { minimap = true, ['bottom-left'] = true }
local SCALE_MIN <const> = 0.5
local SCALE_MAX <const> = 2.0

-- client/ui.lua loads before this file (fxmanifest order), so its HUD getter is
-- the single source of truth for visibility: no mirrored flag, no extra event.
local hudIsVisible = UI['hud.isVisible']

local running = false
local minimapSent = false
local slowAt = 0
local fastAt = 0
local last = {}                     -- field -> last pushed value
local payload = {}                  -- reused between ticks: one table for the whole session
local place = { street = '', zone = '' }
local placeAt = -SLOW_TICK_MS       -- GetGameTimer() of the last street/zone read

--- Config.Hud flag, opt-OUT: a missing key means on (DESIGN §2.0, Core.Config is core's own).
local function hudCfg(key)
    local cfg = Core.Config or Config
    local value = cfg and cfg.Hud and cfg.Hud[key]
    return value ~= false
end

--- Config.Hud flag, opt-IN: only an explicit `true`. ShowSpeed and ShowStreet live here because
--- core draws neither any more (§39.5) — they exist for a plugin reading useHud().speed/street/zone,
--- and a server that does not ask for them must not pay for the natives behind them.
local function hudOptIn(key)
    local cfg = Core.Config or Config
    return (cfg and cfg.Hud and cfg.Hud[key]) == true
end

--- Config.Hud.Anchor / .Scale, each falling back to the §39.4 default when it is unusable.
local function placement()
    local cfg = Core.Config or Config
    local hudCfgTable = cfg and cfg.Hud
    local anchor = hudCfgTable and hudCfgTable.Anchor
    if not ANCHORS[anchor] then anchor = 'bottom-left' end
    local scale = tonumber(hudCfgTable and hudCfgTable.Scale)
    if not scale or scale ~= scale or scale < SCALE_MIN or scale > SCALE_MAX then scale = 1.0 end
    return anchor, scale
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

--- Sends the minimap rect together with the §39.4 placement, once per shell (re-sent on ui_ready:
--- a reloaded shell forgot both). The placement travels even on the rare tick where the screen
--- natives answer nothing usable — the shell then falls back to the vanilla 16:9 rect but still
--- knows where the strip belongs, and `minimapSent` stays false so the next call retries the rect.
local function pushMinimap()
    if minimapSent then return end
    local anchor, scale = placement()
    local rect = computeMinimap()
    if rect then minimapSent = true end
    UI['hud.set']({ minimap = rect, anchor = anchor, scale = scale })
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

--- Adds `value` to the reused payload only when it differs from what was pushed last.
local function changed(field, value)
    if last[field] == value then return end
    last[field] = value
    payload[field] = value
end

--- Sends the payload (if anything changed) and empties it without allocating a new table:
--- UI.hud.set copies what it accepts into its own tables, so this one is ours to reuse.
local function flush()
    if next(payload) == nil then return end
    UI['hud.set'](payload)
    for key in pairs(payload) do payload[key] = nil end
end

-- ---------------------------------------------------------------- feed ----

--- The one feed thread. 100 ms while the HUD is up, 1000 ms while it is hidden; it exits as soon
--- as the session is no longer loaded and is restarted by the playerLoaded hook below. The three
--- cadences of §39.5 share the tick: the mic every time, the vitals every FAST_TICK_MS, the
--- connection state and the place every SLOW_TICK_MS.
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
            local fast = (now - fastAt) >= FAST_TICK_MS
            if fast then fastAt = now end
            -- The mic tile: a BOOL native answers `false` or the INTEGER 1 (DESIGN §30.4).
            if hudCfg('ShowVoice') then
                local talking = MumbleIsPlayerTalking(PlayerId())
                changed('talking', talking == true or talking == 1)
                if slow then
                    local connected = MumbleIsConnected()
                    changed('muted', not (connected == true or connected == 1))
                end
            end
            if fast then
                local ped = PlayerPedId()
                if hudCfg('ShowHealth') then
                    changed('health', healthPercent(GetEntityHealth(ped), GetEntityMaxHealth(ped)))
                end
                if hudCfg('ShowArmour') then
                    changed('armour', clamp(GetPedArmour(ped), 0, 100))
                end
                if hudOptIn('ShowSpeed') then
                    changed('speed', round(GetEntitySpeed(ped) * 3.6))
                end
            end
            if slow and hudOptIn('ShowStreet') then
                local street, zone = refreshPlace()
                changed('street', street)
                changed('zone', zone)
            end
            flush()
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
    for key in pairs(payload) do payload[key] = nil end
    slowAt = 0
    fastAt = 0
    pushMinimap()
    if running then return end
    running = true
    CreateThread(feed)
end)

-- A reloaded shell forgot the rect, the placement and every HUD value: send them again.
Core.on('uiReady', function()
    minimapSent = false
    last = {}
    for key in pairs(payload) do payload[key] = nil end
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
