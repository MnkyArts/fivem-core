--[[ core — client/interiors.lua
     The IPL loader and Core.Interiors API (DESIGN §36).

     At boot, one thread requests the curated IPL groups from
     client/interiors_data.lua (honouring Config.Interiors toggles and the
     game-build / DLC gates), then exits: after boot this module is idle until
     a plugin calls it, so it costs nothing in resmon (§9).

     Plugins style faction-owned interiors (office decor, club walls, bunker
     tiers, ...) through activateSet/deactivateSet; their IPLs and entity sets
     are owner-tracked and swept when the plugin stops (DESIGN §2.3). Removing
     a base-set IPL from a plugin is refused: one call must not punch a hole
     in every player's map.

     Natives (all apiset client, verified with fxref 2026-09-15): RequestIpl,
     RemoveIpl, IsIplActive, GetInteriorAtCoords, IsValidInterior,
     IsInteriorReady, ActivateInteriorEntitySet, DeactivateInteriorEntitySet,
     IsInteriorEntitySetActive, RefreshInterior, GetGameBuildNumber (CFX
     shared), IsDlcPresent.
]]

local Interiors = {}

local Registry = Core.Registry
local Log = Core.Log

local NAME_MAX <const> = 96   -- longest researched IPL is 65 chars; headroom for future DLCs
local RESOLVE_POLL_MS <const> = 100
local RESOLVE_TIMEOUT_MS <const> = 5000

--- IPL and entity-set names are Rockstar map data: word characters only.
---@param v any
---@return boolean
local function validName(v)
    return type(v) == 'string' and #v > 0 and #v <= NAME_MAX and v:match('^[%w_]+$') ~= nil
end

---@type table<string, boolean>  IPLs the boot set owns; plugins may not remove these
local baseIpls = {}

---@type table<string, { coords: vector3, set: string }>  active plugin entity sets by key
local activeSets = {}

---@param coords vector3
---@param set string
---@return string
local function setKey(coords, set)
    return ('%.2f:%.2f:%.2f:%s'):format(coords.x, coords.y, coords.z, set)
end

---@param group table one interiors_data row
---@return boolean
local function groupEnabled(group)
    local cfg = (type(Config) == 'table' and Config.Interiors) or {}
    if cfg.Enabled == false then return false end
    local v = cfg[group.id]
    if v == nil then return group.default ~= false end
    return v == true
end

---@param group table one interiors_data row
---@return boolean
local function gateOk(group)
    if group.minBuild and GetGameBuildNumber() < group.minBuild then return false end
    if group.dlc and not IsDlcPresent(group.dlc) then return false end
    return true
end

--- Wait (up to RESOLVE_TIMEOUT_MS) for the streamed interior at `coords`.
---@param coords vector3
---@return integer|nil interior id, nil on bad coords or timeout
local function resolveInterior(coords)
    if type(coords) ~= 'vector3' then return nil end
    local deadline = GetGameTimer() + RESOLVE_TIMEOUT_MS
    while GetGameTimer() < deadline do
        local interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
        if interior ~= 0 and IsValidInterior(interior) and IsInteriorReady(interior) then
            return interior
        end
        Wait(RESOLVE_POLL_MS)
    end
    return nil
end

--- Request one IPL; tracked under the caller so a plugin stop unloads it.
---@param ipl string
---@return boolean
function Interiors.request(ipl)
    if not validName(ipl) then return false end
    RequestIpl(ipl)
    Registry.track('ipl', ipl, Registry.getCaller())
    return true
end

--- Remove one IPL the caller added. Base-set IPLs are refused (except to core itself).
---@param ipl string
---@return boolean
function Interiors.remove(ipl)
    if not validName(ipl) then return false end
    if baseIpls[ipl] and Registry.getCaller() ~= 'core' then return false end
    RemoveIpl(ipl)
    Registry.untrack('ipl', ipl)
    return true
end

---@param ipl string
---@return boolean
function Interiors.isActive(ipl)
    if not validName(ipl) then return false end
    return IsIplActive(ipl)
end

--- Activate an interior entity set at `coords` (resolves + refreshes). Yields up to 5 s.
---@param coords vector3
---@param set string
---@return boolean
function Interiors.activateSet(coords, set)
    if not validName(set) then return false end
    local interior = resolveInterior(coords)
    if not interior then return false end
    ActivateInteriorEntitySet(interior, set)
    RefreshInterior(interior)
    activeSets[setKey(coords, set)] = { coords = coords, set = set }
    Registry.track('iplset', setKey(coords, set), Registry.getCaller())
    return true
end

--- Deactivate an interior entity set at `coords`. Yields up to 5 s.
---@param coords vector3
---@param set string
---@return boolean
function Interiors.deactivateSet(coords, set)
    if not validName(set) then return false end
    local interior = resolveInterior(coords)
    if not interior then return false end
    DeactivateInteriorEntitySet(interior, set)
    RefreshInterior(interior)
    local key = setKey(coords, set)
    activeSets[key] = nil
    Registry.untrack('iplset', key)
    return true
end

---@param coords vector3
---@param set string
---@return boolean|nil true/false when an interior is there, nil otherwise
function Interiors.isSetActive(coords, set)
    if type(coords) ~= 'vector3' or not validName(set) then return nil end
    local interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
    if interior == 0 then return nil end
    return IsInteriorEntitySetActive(interior, set)
end

---@param coords vector3
---@return boolean
function Interiors.refreshAt(coords)
    local interior = resolveInterior(coords)
    if not interior then return false end
    RefreshInterior(interior)
    return true
end

--- The groups with their effective state (a copy; toggling needs a config change + restart).
---@return table
function Interiors.listGroups()
    local cfg = (type(Config) == 'table' and Config.Interiors) or {}
    local out = {}
    for _, group in ipairs(Core.InteriorsData or {}) do
        out[#out + 1] = {
            id = group.id,
            label = group.label,
            count = group.ipls and #group.ipls or 0,
            enabled = groupEnabled(group),
            gated = not gateOk(group),
        }
    end
    return out
end

Registry.onOwnerStop('ipl', function(id)
    if type(id) ~= 'string' or baseIpls[id] then return end
    RemoveIpl(id)
end)

Registry.onOwnerStop('iplset', function(id)
    local entry = type(id) == 'string' and activeSets[id] or nil
    if not entry then return end
    activeSets[id] = nil
    local interior = GetInteriorAtCoords(entry.coords.x, entry.coords.y, entry.coords.z)
    if interior ~= 0 then
        DeactivateInteriorEntitySet(interior, entry.set)
        RefreshInterior(interior)
    end
end)

Core.Interiors = Interiors

-- Boot: removals first, then requests, one debug line per loaded group.
CreateThread(function()
    local loaded, skipped = 0, 0
    for _, group in ipairs(Core.InteriorsData or {}) do
        if not groupEnabled(group) then
            skipped = skipped + 1
        elseif not gateOk(group) then
            skipped = skipped + 1
            Log.debug('interiors: group %s gated (build %d)', tostring(group.id), GetGameBuildNumber())
        else
            for _, ipl in ipairs(group.remove or {}) do
                RemoveIpl(ipl)
            end
            for _, ipl in ipairs(group.ipls or {}) do
                RequestIpl(ipl)
                baseIpls[ipl] = true
            end
            loaded = loaded + 1
            Log.debug('interiors: group %s loaded (%d ipls)', tostring(group.id), #(group.ipls or {}))
        end
    end
    Log.debug('interiors: boot done (%d groups loaded, %d skipped)', loaded, skipped)
end)

--- Diagnostics: group counts in console and chat.
RegisterCommand('interiors', function()
    for _, group in ipairs(Interiors.listGroups()) do
        local state = group.gated and 'gated' or (group.enabled and 'on' or 'off')
        print(('[core] interiors %s: %s (%d ipls)'):format(group.id, state, group.count))
    end
end, false)
