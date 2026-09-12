--[[
    core lib: Core.Player client read side (DESIGN §3.11) — state-bag readers, no export hop.

    Loaded into the CALLER's VM by import.lua (`local ns = ...`), client side only.

        Core.Player.isLoaded() -> bool
        Core.Player.get(key) -> value            -- replicated keys only (DESIGN §8)
        Core.Player.getServerId() / getPed() / getCoords() -> vector3 / getHeading()
        Core.Player.getFaction() -> table|nil
        Core.Player.isDead() -> bool
        Core.Player.onChange(key, fn(value)) -> cookie

    The server writes `player:<serverId>` (§8), clients only read it. Every read deserializes the whole
    value, so read once into a local and never inside a per-frame loop.

    Natives (verified with fxref 2026-09-12): PlayerPedId, PlayerId, GetPlayerServerId, GetEntityCoords
    (client form takes (entity, alive)), GetEntityHeading, IsPedDeadOrDying, AddStateBagChangeHandler.
]]

local ns = ...

-- keys the server replicates onto the player bag (DESIGN §8)
local READABLE <const> = {
    loaded = true, name = true, charId = true, cash = true, bank = true,
    faction = true, group = true, dead = true,
}

local bagName   -- 'player:<serverId>', resolved on first use

--- The local player's own state bag name, or nil while the server id is not known yet.
local function ownBag()
    if bagName then return bagName end
    local serverId = GetPlayerServerId(PlayerId())
    if not serverId or serverId <= 0 then return nil end
    bagName = 'player:' .. serverId
    return bagName
end

--- Server id of the local player.
function ns.getServerId()
    return GetPlayerServerId(PlayerId())
end

--- The local player's ped handle.
function ns.getPed()
    return PlayerPedId()
end

--- Current position of the local ped.
function ns.getCoords()
    return GetEntityCoords(PlayerPedId(), true)
end

--- Current heading of the local ped.
function ns.getHeading()
    return GetEntityHeading(PlayerPedId())
end

--- True once the server created the session for this player.
function ns.isLoaded()
    return LocalPlayer.state.loaded == true
end

--- Reads one replicated key from the local player's state bag; nil for anything not in DESIGN §8.
function ns.get(key)
    if type(key) ~= 'string' or not READABLE[key] then return nil end
    return LocalPlayer.state[key]
end

--- The faction summary { id, name, tag, color, rank, rankName } or nil when in no faction.
function ns.getFaction()
    local faction = LocalPlayer.state.faction
    if type(faction) ~= 'table' then return nil end
    return faction
end

--- True while the character is dead: the replicated flag, else the ped's own state.
function ns.isDead()
    local dead = LocalPlayer.state.dead
    if type(dead) == 'boolean' then return dead end
    return IsPedDeadOrDying(PlayerPedId(), true)
end

--- Calls `fn(value)` whenever the server changes `key` on THIS player's bag.
--- Returns the state-bag handler cookie, or nil when the arguments are wrong.
function ns.onChange(key, fn)
    if type(key) ~= 'string' or key == '' or type(fn) ~= 'function' then return nil end
    local bag = ownBag()
    if not bag then
        Core.Log.warn('Player.onChange(%s): server id not known yet', key)
        return nil
    end

    return AddStateBagChangeHandler(key, bag, function(changedBag, changedKey, value)
        if changedBag ~= bag or changedKey ~= key then return end
        local ok, err = pcall(fn, value)
        if not ok then
            Core.Log.error('Player.onChange(%s) handler failed: %s', key, tostring(err))
        end
    end)
end
