--[[
    core / lib/scene/shared.lua  —  Core.Scene, the part compiled into every VM (DESIGN §55.1, §55.3)

    Tiny and pure: the kind id rules and the radius -> tier rule, so a resource can check a kind id or pick a
    stream radius without a hop into core. Everything else of Core.Scene is core's (server: spawn, set, …;
    client: get, handleOf, …) and reached through the import.lua proxy, or lives in lib/scene/client.lua
    (handle, on, off). A name defined here must never be one of those API names: the proxy only fills in what
    this table LACKS (AGENTS §8).

      Scene.validKindId(id) -> boolean    a plugin id '<resource>:<name>' or a reserved plain id ('prop', 'audio')
      Scene.isPluginKind(id) -> boolean   the '<resource>:<name>' form only (what Scene.defineKind accepts from plugins)
      Scene.tierOf(radius, global?) -> 'S' | 'M' | 'L' | 'G'
                                          S ≤ TierS (160), M ≤ TierM (448), else L; G = global (core's Config.Scene)
      Scene.PAINTS                        the 22 stable vehicle paints { primary, secondary } (read-only; one list for
                                          the server's promoted clones and the clients' local copies)
      Scene.paintOf(id) -> primary, secondary   PAINTS[id % 22 + 1]: a node's paint, the same everywhere, every time
      Scene.WEAR                          the damage / wear keys of vehicle props { [key] = true } (§55.15 notes):
                                          engineHealth, bodyHealth, tankHealth, dirtLevel, fuelLevel, doors, windows,
                                          burstTyres, tyreHealth — the ONLY keys a props read-back from a clone's
                                          network owner may change; everything else goes through saveProps / server APIs
      Scene.splitProps(props) -> cosmetic, wear   two fresh tables (either may be empty): the non-WEAR and WEAR keys
      Scene.mergeWear(stored, readBack) -> merged   a fresh copy of `stored` with ONLY the WEAR keys of `readBack`
                                          merged in, clamped: healths 0..1000 (a restored car never burns), dirt 0..15,
                                          fuel 0..100, doors / windows / burstTyres { [0..7] = boolean }, tyreHealth
                                          { [0..7] = 0..1000 } (a read-back map replaces the stored one); unknown /
                                          non-finite values are dropped (the stored value stays); `stored` untouched

    Natives: none.
]]

local ns = ...

local PLUGIN_KIND <const> = '^[%w_%-]+:[%w_%-%.]+$'
local PLAIN_KIND <const> = '^%l[%w_%.]*$'
local MAX_ID <const> = 64

--- Is `id` a plugin kind id ('<resource>:<name>')?
---@param id any
---@return boolean
function ns.isPluginKind(id)
    return type(id) == 'string' and #id <= MAX_ID and id:find(PLUGIN_KIND) ~= nil
end

--- Is `id` a well-formed kind id (plugin form, or a reserved plain id of a built-in)?
---@param id any
---@return boolean
function ns.validKindId(id)
    if type(id) ~= 'string' or id == '' or #id > MAX_ID then return false end
    return id:find(PLUGIN_KIND) ~= nil or id:find(PLAIN_KIND) ~= nil
end

--- Core's tier limits (read on every call: core's config may reload after a core restart).
local function limits()
    local cfg = Core and Core.Config
    local scene = type(cfg) == 'table' and type(cfg.Scene) == 'table' and cfg.Scene or nil
    local s = scene and tonumber(scene.TierS) or 160
    local m = scene and tonumber(scene.TierM) or 448
    return s, m
end

--- Normal GTA paints { primary, secondary } (the §52 list: metallic black … purple). A vehicle node without its
--- own colours gets PAINTS[id % 22 + 1] — on the server's clone and on every client's local copy alike.
ns.PAINTS = { { 0, 0 }, { 1, 1 }, { 4, 4 }, { 3, 3 }, { 7, 7 }, { 10, 10 }, { 111, 111 },
    { 112, 112 }, { 27, 27 }, { 34, 34 }, { 38, 38 }, { 89, 89 }, { 53, 53 }, { 50, 50 }, { 62, 62 },
    { 64, 64 }, { 70, 70 }, { 61, 61 }, { 90, 90 }, { 93, 93 }, { 97, 97 }, { 145, 145 } }

--- The stable paint pair of node `id`. -> primary, secondary (nil for a non-integer id)
---@param id integer
---@return integer|nil, integer|nil
function ns.paintOf(id)
    id = math.tointeger(id)
    if not id then return nil end
    local pair = ns.PAINTS[id % #ns.PAINTS + 1]
    return pair[1], pair[2]
end

--------------------------------------------------------------------------------
-- Vehicle props: damage / wear vs cosmetic (DESIGN §55.15 notes — review RV4 F1, RV5 F1)
--------------------------------------------------------------------------------

-- key -> rule: a number range ('h' 0..1000, 'd' 0..15, 'f' 0..100) or an index map ('b' booleans, 'hm' 0..1000)
local WEAR_RULE <const> = {
    engineHealth = 'h', bodyHealth = 'h', tankHealth = 'h', dirtLevel = 'd', fuelLevel = 'f',
    doors = 'b', windows = 'b', burstTyres = 'b', tyreHealth = 'hm',
}
local WEAR_MAX <const> = { h = 1000, d = 15, f = 100, hm = 1000 }
local WEAR_MAX_INDEX <const> = 7      -- doors / windows / wheels 0..7 (client/vehicles.lua MAX_DOOR / WINDOW / WHEEL)
local WEAR_MAX_SCAN <const> = 32      -- entries looked at per read-back map (a hostile table is never walked whole)
local COPY_DEPTH <const> = 4          -- props nest one level (maps of scalars); deeper tables are not copied

ns.WEAR = {}
for key in pairs(WEAR_RULE) do ns.WEAR[key] = true end

local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

local function clamp(v, hi)
    if v < 0 then return 0 end
    if v > hi then return hi end
    return v
end

--- A bounded deep copy (depth-limited, so a cyclic or absurd table cannot recurse without end).
local function copy(v, depth)
    if type(v) ~= 'table' then return v end
    if depth > COPY_DEPTH then return nil end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x, depth + 1) end
    return out
end

--- One read-back value checked against its rule -> the clamped value | nil (dropped).
local function wearValue(rule, v)
    if rule ~= 'b' and rule ~= 'hm' then
        if not finite(v) then return nil end
        return clamp(v, WEAR_MAX[rule])
    end
    if type(v) ~= 'table' then return nil end
    local out, n = {}, 0
    for k, x in pairs(v) do
        n = n + 1
        if n > WEAR_MAX_SCAN then break end
        local i = math.type(k) == 'integer' and k or math.tointeger(tonumber(k))
        if i and i >= 0 and i <= WEAR_MAX_INDEX then
            if rule == 'b' then
                if type(x) == 'boolean' then out[i] = x end
            elseif finite(x) then
                out[i] = clamp(x, WEAR_MAX.hm)
            end
        end
    end
    return out
end

--- Splits vehicle props into the cosmetic part (every key but WEAR) and the damage / wear part.
---@param props table|nil
---@return table cosmetic, table wear   fresh tables (values copied), either may be empty
function ns.splitProps(props)
    local cosmetic, wear = {}, {}
    if type(props) ~= 'table' then return cosmetic, wear end
    for key, value in pairs(props) do
        if WEAR_RULE[key] then wear[key] = copy(value, 1) else cosmetic[key] = copy(value, 1) end
    end
    return cosmetic, wear
end

--- `stored` with ONLY the damage / wear keys of `readBack` merged in (clamped; bad values dropped). A read-back
--- (a clone owner's answer) can never change mods, colours, extras, livery, wheels, neon or the plate this way.
---@param stored table|nil
---@param readBack table|nil
---@return table merged   a fresh table; `stored` is not touched
function ns.mergeWear(stored, readBack)
    local merged = type(stored) == 'table' and copy(stored, 0) or {}
    if type(readBack) ~= 'table' then return merged end
    for key, rule in pairs(WEAR_RULE) do
        local value = wearValue(rule, readBack[key])
        if value ~= nil then merged[key] = value end
    end
    return merged
end

--- The streaming tier of a node with stream radius `radius` (metres): the server's rule (§55.3).
---@param radius number
---@param global? boolean
---@return 'S'|'M'|'L'|'G'
function ns.tierOf(radius, global)
    if global == true then return 'G' end
    radius = tonumber(radius) or 0
    local s, m = limits()
    if radius <= s then return 'S' end
    if radius <= m then return 'M' end
    return 'L'
end
