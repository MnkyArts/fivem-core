--[[
    core/client/stats.lua — Core.Stats client read side (DESIGN §18, lib style of §3.11).

    The server owns the values and writes `player:<serverId>.stats` at most once per second (§8);
    this side only reads that bag, hands the table to `Core.Stats.onChange` listeners and pushes the
    HUD payload `{ [name] = { value, min, max, slot?, icon? } }` — built from the
    Core.Config.Stats.Defs entries whose `hud` is `true` (a rail bar), `'health'` or `'armour'` (the
    bar cut out of that vitals plate, §39.4, forwarded as `slot`, with the def's `icon` as its glyph)
    — into `Core.UI.stats.set` (§21) when client/ui.lua provides it and Core.Config.Hud.ShowStats is
    not false.

    Every state-bag read deserializes the whole value, so read once into a local, never per frame.

    Natives (verified with fxref 2026-09-12): PlayerId (client), GetPlayerServerId (client),
    AddStateBagChangeHandler (shared). LocalPlayer/CreateThread/Wait are runtime helpers.
]]

local Stats = {}

local ID_POLL_MS <const> = 200
local ID_POLL_TRIES <const> = 150     -- 30 s, then give up loudly

local listeners = {}                  -- Core.Stats.onChange callbacks
local bagName                         -- 'player:<serverId>', resolved once

--- One read of the replicated table; nil until the server has written it.
local function readAll()
    local stats = LocalPlayer.state.stats
    if type(stats) ~= 'table' then return nil end
    return stats
end

--- Copy with numbers only, so a bad value on the bag cannot reach a listener or the HUD.
local function normalize(stats)
    local out = {}
    for name, value in pairs(stats) do
        local n = tonumber(value)
        if type(name) == 'string' and n then out[name] = n end
    end
    return out
end

--- Current value of `name`; 0 while the stat is unknown or not replicated yet.
function Stats.get(name)
    if type(name) ~= 'string' then return 0 end
    local stats = readAll()
    local value = stats and tonumber(stats[name])
    return value or 0
end

--- Every replicated stat as `{ [name] = value }` (a fresh table).
function Stats.getAll()
    local stats = readAll()
    if not stats then return {} end
    return normalize(stats)
end

--- Calls `fn(stats)` whenever the server replicates a new table. The argument is shared between
--- listeners in one dispatch — treat it as read-only.
function Stats.onChange(fn)
    if not Core.Utils.isCallable(fn) then return false end
    listeners[#listeners + 1] = fn
    return true
end

--- The two vitals plates a stat bar can be cut out of (DESIGN §39.4); `hud = true` is the rail bar.
local HUD_SLOTS <const> = { health = true, armour = true }

--- `{ [name] = { value, min, max, slot?, icon? } }` for the defs that asked for a HUD bar; nil
--- when none do. `slot` travels only for `hud = 'health'` / `'armour'`, `icon` only as a string —
--- client/ui.lua re-checks both, this side just forwards what the config says.
local function hudPayload(stats, cfg)
    local stats_cfg = cfg.Stats
    local defs = type(stats_cfg) == 'table' and stats_cfg.Defs or nil
    if type(defs) ~= 'table' then return nil end
    local out, any = {}, false
    for name, def in pairs(defs) do
        local slot = type(def) == 'table' and HUD_SLOTS[def.hud] and def.hud or nil
        if type(def) == 'table' and (def.hud == true or slot) then
            local min = tonumber(def.min) or 0
            local max = tonumber(def.max) or 100
            out[name] = {
                value = stats[name] or tonumber(def.default) or min, min = min, max = max,
                slot = slot, icon = type(def.icon) == 'string' and def.icon or nil,
            }
            any = true
        end
    end
    if not any then return nil end
    return out
end

--- client/ui.lua adds UI.stats.set (§21); it may not exist yet, and it is another module's code.
--- Config.Hud.ShowStats = false turns the stat bars off: no payload is built, nothing is sent.
local function pushHud(stats)
    local cfg = Core.Config
    if type(cfg) ~= 'table' then return end
    local hud = cfg.Hud
    if type(hud) == 'table' and hud.ShowStats == false then return end
    local payload = hudPayload(stats, cfg)
    if not payload then return end
    local ui = Core.UI
    local namespace = type(ui) == 'table' and rawget(ui, 'stats') or nil
    local set = type(namespace) == 'table' and namespace.set or nil
    if type(set) ~= 'function' then return end
    local ok, err = pcall(set, payload)
    if not ok then Core.Log.error('Stats: UI.stats.set failed: %s', tostring(err)) end
end

--- One dispatch: HUD first, then the listeners (an erroring listener never blocks the others).
local function dispatch(raw)
    local stats = normalize(raw)
    pushHud(stats)
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i], stats)
        if not ok then Core.Log.error('Stats.onChange handler failed: %s', tostring(err)) end
    end
end

-- The bag name needs the server id, which is not known during the first frames of the session.
CreateThread(function()
    local serverId = GetPlayerServerId(PlayerId())
    local tries = 0
    while serverId <= 0 and tries < ID_POLL_TRIES do
        Wait(ID_POLL_MS)
        serverId = GetPlayerServerId(PlayerId())
        tries = tries + 1
    end
    if serverId <= 0 then
        Core.Log.warn('Stats: no server id after %d ms, stats stay unread', ID_POLL_TRIES * ID_POLL_MS)
        return
    end

    bagName = 'player:' .. serverId
    AddStateBagChangeHandler('stats', bagName, function(bag, key, value)
        if bag ~= bagName or key ~= 'stats' or type(value) ~= 'table' then return end
        dispatch(value)
    end)

    local current = readAll()   -- the server may have written before this handler existed
    if current then dispatch(current) end
end)

Core.Stats = Stats

-- end of file
