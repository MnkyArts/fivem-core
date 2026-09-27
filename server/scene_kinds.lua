--[[
    core/server/scene_kinds.lua — Core.Scene kinds, the built-in kinds and the node validators (DESIGN §55.3,
    §55.4 validation, §55.12, §55.14, §55.16). FIRST of the scene server files (scene_kinds → scene_index →
    scene_interest → scene_gated → scene_flush → scene_store → scene → scene_promote → scene_audio → scene_voice:
    the manifest order is load-bearing). It creates
    `Core.SceneRuntime` (R, internal: block-listed in server/api.lua) and fills R.kinds, R.valid and the clock
    helpers R.now / R.diff / R.add; scene_store.lua fills R.store.

      R.kinds.define(def, owner, builtin?) -> ok, err     plugin ids '<resource>:<name>' (prefix = the owner
                                                          unless core); owner-tracked (Registry kind 'sceneKind');
                                                          <= 256 distinct ids per plugin per session ('limit')
      R.kinds.undefine(id) / R.kinds.undefineOwner(owner) -> removed ids (the nodes stay: placeholders)
      R.kinds.get(id) / byIdx(idx) / version() / count() / table(since) / public()
      R.kinds.check(kind, fields, partial) -> true, out | false, errs      Schema.checkAll, then the `table`
                                                          fields (JSON-safe, <= MaxFieldBytes, validate), then
                                                          the built-in cross-field rule (full checks only)
      R.kinds.fillModel(kind, fields) -> true | nil, 'model'   the model-info chain into the server-filled fields
      R.kinds.modelInfo(class, model) -> { lod, r, vtype } | nil, 'model'   provider → Maps validator → defaults;
                                                          only the provider refuses (false); the Maps validator
                                                          only informs (a model it refuses gets the defaults)
      R.kinds.setModelInfo(fn, owner) -> ok               one provider, owner-tracked ('sceneModelInfo')
      R.kinds.radius(kind, node) -> m ; R.kinds.tier(radius, global) -> 'S'|'M'|'L'|'G'
      R.kinds.onChange                                    set by scene_store.lua: fn(id) after a define / undefine
      R.valid.xyz/pos/rot/offset/bone/rotOrder/bucket/plain/audience/interact/authority    shared shape validators

    Kind table: { id, idx, class, classCode, fields (Schema list|nil), tables = { [name] = spec }, names,
    nearFields (set), nearList, radius (number|callable|nil), handler, authority, budget, owner, builtin,
    dependency, filled (server-filled names), derived (model-derived INPUT names: the built-in vehicle's vtype,
    kept when given, filled when absent), clock (Clock-valued field paths), post (built-in rule), hasModel,
    intModel (its `model` also takes an integer hash, kept as is) }.
    Kind indexes are per server session and stable per id (a restarted plugin gets its index back).

    Natives: none.
]]

local R = {}
Core.SceneRuntime = R

local Codec, Schema, Utils, Log, Registry = Core.SceneCodec, Core.Schema, Core.Utils, Core.Log, Core.Registry
assert(Codec and Codec.pack and Codec.CLASS, 'shared/scene_codec.lua must load before server/scene_kinds.lua')

local type, pairs, next, pcall, tostring = type, pairs, next, pcall, tostring
local mathType, huge, floor, sqrt = math.type, math.huge, math.floor, math.sqrt

local KIND_KIND <const> = 'sceneKind'
local INFO_KIND <const> = 'sceneModelInfo'
local PLUGIN_ID <const> = '^[%w_%-]+:[%w_%-%.]+$'
local NAME_PATTERN <const> = '^[%a_][%w_]*$'
local ACTION_PATTERN <const> = '^[%w_%-]+$'
local PERM_PATTERN <const> = '^[%w_%-%.:]+$'
local ID_PATTERN <const> = '^[%w_%-]+$'
local ID_MAX <const> = 64
local MAX_KINDS <const> = 1024            -- defined at once
local MAX_KIND_IDS <const> = 4096         -- distinct ids per server session (u16 wire index)
local MAX_KIND_IDS_OWNER <const> = 256    -- distinct ids one plugin may introduce per session (review F13)
local MAX_NEAR <const> = 32
local MAX_INFO_CACHE <const> = 4096
local WORLD_XY <const>, WORLD_ZMIN <const>, WORLD_ZMAX <const> = 10000, -1000, 3000
local OFFSET_MAX <const> = 1000
local RADIUS_MAX <const> = 65535
local DEFAULT_RADIUS <const> = 250
local PLAIN_DEPTH <const>, PLAIN_ENTRIES <const> = 16, 2048
local INTERACT_MAX <const>, INTERACT_DATA_MAX <const> = 4, 1024
local AUDIENCE_PLAYERS <const>, AUDIENCE_LIST <const>, AUDIENCE_DEPTH <const> = 256, 8, 3
local CLASS_CODE <const> = Codec.CLASS
local DEFAULT_BUDGET <const> = { prop = 'props', vehicle = 'vehicles', ped = 'peds', fx = 'fx', data = 'data',
    audio = 'audio', custom = 'custom' }
local EMPTY <const> = setmetatable({}, { __newindex = function() error('read-only', 2) end })

local function cfg() return Config.Scene end

local function isFinite(v)
    return type(v) == 'number' and v == v and v ~= huge and v ~= -huge
end

local function isCallable(v) return Utils.isCallable(v) end

--- Length of a proper sequence (keys exactly 1..n, n <= max) or nil.
local function seqLen(t, max)
    if type(t) ~= 'table' or getmetatable(t) ~= nil then return nil end
    local n = 0
    for k in pairs(t) do
        n = n + 1
        if n > max or mathType(k) ~= 'integer' or k < 1 then return nil end
    end
    for i = 1, n do if t[i] == nil then return nil end end
    return n
end

local function str(v, max, pattern)
    return type(v) == 'string' and #v >= 1 and #v <= max and (not pattern or v:find(pattern) ~= nil)
end

--- An integer model hash (the int32 or the uint32 form, never 0) -> that integer | nil.
local function intHash(v)
    local n = type(v) == 'number' and math.tointeger(v) or nil
    if n and n ~= 0 and n >= -0x80000000 and n <= 0xFFFFFFFF then return n end
    return nil
end

--------------------------------------------------------------------------------
-- R.valid — shapes shared by the kind checks and scene.lua's validation order (§55.4)
--------------------------------------------------------------------------------

local V = {}
R.valid = V

--- x, y, z of a vector3 or a table with finite numeric x/y/z (other keys ignored), else nil.
function V.xyz(v)
    local t = type(v)
    if t ~= 'vector3' and t ~= 'table' then return nil end
    local x, y, z = v.x, v.y, v.z
    if isFinite(x) and isFinite(y) and isFinite(z) then return x, y, z end
    return nil
end

--- A world position (x/y ±10000, z -1000..3000) -> { x, y, z } | nil, 'pos'.
function V.pos(v)
    local x, y, z = V.xyz(v)
    if not x or x < -WORLD_XY or x > WORLD_XY or y < -WORLD_XY or y > WORLD_XY or z < WORLD_ZMIN or z > WORLD_ZMAX then
        return nil, 'pos'
    end
    return { x = x, y = y, z = z }
end

--- Degrees normalised to (-180, 180].
local function wrap(d)
    d = d % 360
    if d > 180 then d = d - 360 end
    return d
end
V.wrap = wrap

--- A finite Euler rotation (degrees) -> normalised { x, y, z } | nil, err (default 0, 0, 0 for nil).
function V.rot(v, err)
    if v == nil then return { x = 0.0, y = 0.0, z = 0.0 } end
    local x, y, z = V.xyz(v)
    if not x then return nil, err or 'rot' end
    return { x = wrap(x), y = wrap(y), z = wrap(z) }
end

--- A child / attachment offset (each component within ±1000 m) -> { x, y, z } | nil, 'offset'.
function V.offset(v)
    if v == nil then return { x = 0.0, y = 0.0, z = 0.0 } end
    local x, y, z = V.xyz(v)
    if not x or math.abs(x) > OFFSET_MAX or math.abs(y) > OFFSET_MAX or math.abs(z) > OFFSET_MAX then
        return nil, 'offset'
    end
    return { x = x, y = y, z = z }
end

--- A bone: an index 0..65535 or a bone name -> value | nil, 'bone'.
function V.bone(v)
    if v == nil then return nil end
    if mathType(v) == 'integer' and v >= 0 and v <= 65535 then return v end
    if str(v, ID_MAX, ID_PATTERN) then return v end
    return nil, 'bone'
end

--- An attachment's rotation order (AttachEntityToEntity's 14th argument, GET_ENTITY_ROTATION's orders): an
--- integer 0..5 -> value | nil (not given: the engine's default 2, EULER_YXZ) | nil, 'rotOrder'.
function V.rotOrder(v)
    if v == nil then return nil end
    local n = type(v) == 'number' and math.tointeger(v) or nil
    if not n or n < 0 or n > 5 then return nil, 'rotOrder' end
    return n
end

function V.bucket(v)
    if v == nil then return 0 end
    local n = math.tointeger(v)
    if not n or n < 0 or n > 0x7FFFFFFF then return nil, 'bucket' end
    return n
end

--- A plain data value (nil/boolean/finite number/string and metatable-free tables of them with string or
--- integer keys, no cycles), <= 16 levels and 2048 entries. A sequence with an `n` key is refused: FiveM's
--- msgpack packs it as a table.pack array and drops `n`. Returns true or false.
local function plainOk(v, depth, state)
    local t = type(v)
    if t == 'nil' or t == 'boolean' or t == 'string' then return true end
    if t == 'number' then return isFinite(v) end
    if t ~= 'table' or getmetatable(v) ~= nil or depth > PLAIN_DEPTH or state[v] then return false end
    if v[1] ~= nil and v.n ~= nil then return false end
    state[v] = true
    for k, value in pairs(v) do
        state.n = state.n + 1
        if state.n > PLAIN_ENTRIES then return false end
        if not (type(k) == 'string' or mathType(k) == 'integer') or not plainOk(value, depth + 1, state) then
            return false
        end
    end
    state[v] = nil
    return true
end

--- Free-form data (vectors become { x, y, z } first): a detached copy whose packed size is <= maxBytes, or
--- nil, 'type' | 'size'.
function V.plain(v, maxBytes)
    if v == nil then return nil end
    local copy = Utils.jsonSafe(v)
    if not plainOk(copy, 0, { n = 0 }) then return nil, 'type' end
    local ok, blob = pcall(Codec.pack, copy)
    if not ok or type(blob) ~= 'string' then return nil, 'type' end
    if maxBytes and #blob > maxBytes then return nil, 'size' end
    return copy
end

local AUDIENCE_KEYS <const> = { players = true, faction = true, perm = true, editors = true, near = true, fn = true,
    any = true, all = true }

--- One audience (§55.3/§55.6): exactly ONE key of players | faction | perm | editors | near | fn | any | all.
--- `fn` (a callable, kept by reference) and `players` (server ids are per session) are refused for persistent
--- nodes, anywhere in the tree.
local function audience(a, persist, depth)
    if type(a) ~= 'table' or getmetatable(a) ~= nil then return nil end
    local key, value = next(a)
    if key == nil or next(a, key) ~= nil or not AUDIENCE_KEYS[key] then return nil end
    if key == 'players' then
        if persist then return nil end                  -- server ids are per session (review F8)
        local n = seqLen(value, AUDIENCE_PLAYERS)
        if not n or n < 1 then return nil end
        local list, seen = {}, {}
        for i = 1, n do
            local src = math.tointeger(value[i])
            if not src or src < 1 or src > 65535 or seen[src] then return nil end
            seen[src], list[i] = true, src
        end
        return { players = list }
    elseif key == 'faction' then
        return str(value, ID_MAX, ID_PATTERN) and { faction = value } or nil
    elseif key == 'perm' then
        return str(value, ID_MAX, PERM_PATTERN) and { perm = value } or nil
    elseif key == 'editors' then
        return value == true and { editors = true } or nil
    elseif key == 'near' then
        return (isFinite(value) and value > 0 and value <= 200) and { near = value } or nil
    elseif key == 'fn' then
        return (not persist and isCallable(value)) and { fn = value } or nil
    end
    if depth >= AUDIENCE_DEPTH then return nil end
    local n = seqLen(value, AUDIENCE_LIST)
    if not n or n < 1 then return nil end
    local list = {}
    for i = 1, n do
        list[i] = audience(value[i], persist, depth + 1)
        if not list[i] then return nil end
    end
    return { [key] = list }
end

--- nil = public; else a normalised copy | nil, 'audience'.
function V.audience(a, persist)
    if a == nil then return nil end
    local out = audience(a, persist, 0)
    if not out then return nil, 'audience' end
    return out
end

--- A data-only copy of an audience (fn → true): what copies, hooks and persistence carry.
local function audienceData(a)
    if type(a) ~= 'table' then return a end
    local out = {}
    for k, v in pairs(a) do
        if k == 'fn' then out.fn = true
        elseif k == 'any' or k == 'all' then
            local list = {}
            for i = 1, #v do list[i] = audienceData(v[i]) end
            out[k] = list
        elseif k == 'players' then out.players = { table.unpack(v) }
        else out[k] = v end
    end
    return out
end
V.audienceData = audienceData

--- Who may hang children under a node besides its owner and core (review F13): true = any resource, or a list of
--- 1..16 resource names -> value | nil (false / nil = nobody) | nil, 'allowChildren'.
function V.allowChildren(v)
    if v == nil or v == false then return nil end
    if v == true then return true end
    local n = seqLen(v, 16)
    if not n or n < 1 then return nil, 'allowChildren' end
    local out = {}
    for i = 1, n do
        if not str(v[i], ID_MAX, '^[%w_%-%.]+$') then return nil, 'allowChildren' end
        out[i] = v[i]
    end
    return out
end

--- May `owner` parent a node under `parent`? Its owner and core always; others only when the parent allows them.
function V.childAllowed(parent, owner)
    if owner == 'core' or owner == parent.owner then return true end
    local a = parent.allowChildren
    if a == true then return true end
    for i = 1, type(a) == 'table' and #a or 0 do
        if a[i] == owner then return true end
    end
    return false
end

local INTERACT_KEYS <const> = { action = true, label = true, distance = true, icon = true, description = true,
    perm = true, cooldownMs = true, data = true, prompt = true }

--- A descriptor's world-prompt options (§55.21.2, §6.7): { world = bool, offsetZ = -5..5 m, range = 1..50 m }, every
--- key optional, nothing else -> a copy for the clients (nil when empty) | false.
local function promptOf(p)
    if type(p) ~= 'table' or getmetatable(p) ~= nil then return false end
    local out, any = {}, false
    for k, v in pairs(p) do
        if k == 'world' then
            if type(v) ~= 'boolean' then return false end
        elseif k == 'offsetZ' then
            if not isFinite(v) or v < -5 or v > 5 then return false end
        elseif k == 'range' then
            if not isFinite(v) or v < 1 or v > 50 then return false end
        else
            return false
        end
        out[k], any = v, true
    end
    return any and out or nil
end

--- Interaction descriptors (§55.14): 1..4 entries, unique actions, an optional `prompt` (above) -> normalised
--- list | nil, 'interact'.
--- An empty list clears (nil).
function V.interact(list)
    if list == nil then return nil end
    local n = seqLen(list, INTERACT_MAX)
    if not n then return nil, 'interact' end
    if n == 0 then return nil end
    local out, seen = {}, {}
    for i = 1, n do
        local d = list[i]
        if type(d) ~= 'table' or getmetatable(d) ~= nil then return nil, 'interact' end
        for k in pairs(d) do if not INTERACT_KEYS[k] then return nil, 'interact' end end
        if not str(d.action, 32, ACTION_PATTERN) or seen[d.action] then return nil, 'interact' end
        seen[d.action] = true
        local e = { action = d.action, label = d.label == nil and d.action or d.label,
            distance = d.distance == nil and 2.0 or d.distance,
            cooldownMs = d.cooldownMs == nil and 500 or d.cooldownMs }
        if not str(e.label, 64) or not isFinite(e.distance) or e.distance < 0.5 or e.distance > 20 then
            return nil, 'interact'
        end
        local cd = math.tointeger(e.cooldownMs)
        if not cd or cd < 0 or cd > 60000 then return nil, 'interact' end
        e.cooldownMs = cd
        if d.icon ~= nil and not str(d.icon, 32, ID_PATTERN) then return nil, 'interact' end
        if d.description ~= nil and not str(d.description, 256) then return nil, 'interact' end
        if d.perm ~= nil and not str(d.perm, ID_MAX, PERM_PATTERN) then return nil, 'interact' end
        e.icon, e.description, e.perm = d.icon, d.description, d.perm
        if d.prompt ~= nil then
            e.prompt = promptOf(d.prompt)
            if e.prompt == false then return nil, 'interact' end
        end
        if d.data ~= nil then
            e.data = V.plain(d.data, INTERACT_DATA_MAX)
            if e.data == nil then return nil, 'interact' end
        end
        out[i] = e
    end
    return out
end

local AUTH_MODES <const> = { ['local'] = true, promote = true, networked = true }
local AUTH_KEYS <const> = { mode = true, proximity = true, enter = true, damage = true, actions = true,
    restMs = true, idleMs = true, onDestroyed = true }

--- A promotion policy (§55.15; used in phase C) -> normalised copy | nil, 'authority'.
function V.authority(a)
    if a == nil then return nil end
    if type(a) ~= 'table' or getmetatable(a) ~= nil then return nil, 'authority' end
    local out = {}
    for k, v in pairs(a) do
        if not AUTH_KEYS[k] then return nil, 'authority' end
        local ok
        if k == 'mode' then ok = AUTH_MODES[v] == true
        elseif k == 'proximity' then ok = isFinite(v) and v >= 1 and v <= 200
        elseif k == 'enter' or k == 'damage' then ok = type(v) == 'boolean'
        elseif k == 'restMs' then ok = mathType(v) == 'integer' and v >= 0 and v <= 600000
        elseif k == 'idleMs' then ok = mathType(v) == 'integer' and v >= 0 and v <= 3600000
        elseif k == 'onDestroyed' then ok = v == 'remove' or v == 'keep'
        else
            local n = seqLen(v, 8)
            ok = n ~= nil
            for i = 1, n or 0 do ok = ok and str(v[i], 32, ACTION_PATTERN) end
            if ok then v = { table.unpack(v) } end
        end
        if not ok then return nil, 'authority' end
        out[k] = v
    end
    return out
end

--------------------------------------------------------------------------------
-- Built-in table-field rules (validated like Vehicles.saveProps; Core.Geometry shapes; vehicle doors)
--------------------------------------------------------------------------------

local PROPS_MAX_KEYS <const>, PROPS_MAX_KEY_LEN <const>, PROPS_MAX_STRING <const> = 96, 32, 32
local PROPS_MAX_MAP_ENTRIES <const>, PROPS_MAX_MAP_INDEX <const> = 64, 64

--- CoreVehicleProps: string keys <= 32, scalar values or bounded numeric maps (server/vehicles.lua rules).
local function vehicleProps(props)
    local count = 0
    for key, value in pairs(props) do
        count = count + 1
        if count > PROPS_MAX_KEYS or type(key) ~= 'string' or #key < 1 or #key > PROPS_MAX_KEY_LEN then
            return false, 'props'
        end
        local kind = type(value)
        if kind == 'string' then
            if #value > PROPS_MAX_STRING then return false, 'props' end
        elseif kind == 'table' then
            local n = 0
            for index, entry in pairs(value) do
                n = n + 1
                local i = mathType(index) == 'integer' and index or math.tointeger(tonumber(index))
                if not i or i < 0 or i > PROPS_MAX_MAP_INDEX or n > PROPS_MAX_MAP_ENTRIES
                    or (type(entry) ~= 'boolean' and not isFinite(entry)) then return false, 'props' end
            end
        elseif kind ~= 'boolean' and not isFinite(value) then
            return false, 'props'
        end
    end
    return true
end

-- Native value ranges of CoreVehicleProps (D-A, review RV4 F1 (4)) — the SAME rules as server/vehicles.lua's
-- cleanProps (every props write of a record), so a parked car's node and its record never disagree: integers floored
-- and clamped (paint / interior / dashboard colours are the engine's u8 palette index, plate style 0..12 — b3095's
-- plates included —, wheel type 0..12, window tint -1..6, liveries -1..127), healths 0..1000 (never below 0: a
-- restored car never starts burning), fuel 0..100, dirt 0..15, { r, g, b } colours 0..255 (a custom colour is false
-- or RGB), xenon 0..12 or 255 (stock), mods -1..254, tyreHealth 0..1000, lights[3] (indicators) 0..3. A known key of
-- the wrong type is dropped; unknown keys are left to vehicleProps' shape check.
local PROP_INT <const> = { plateIndex = { 0, 12 }, colorPrimary = { 0, 255 }, colorSecondary = { 0, 255 },
    pearlescentColor = { 0, 255 }, wheelColor = { 0, 255 }, interiorColor = { 0, 255 }, dashboardColor = { 0, 255 },
    wheels = { 0, 12 }, windowTint = { -1, 6 }, livery = { -1, 127 }, livery2 = { -1, 127 } }
local PROP_NUM <const> = { engineHealth = 1000, bodyHealth = 1000, tankHealth = 1000, fuelLevel = 100, dirtLevel = 15 }
local PROP_RGB <const> = { neonColor = true, tyreSmokeColor = true, customPrimary = true, customSecondary = true }

local function clampInt(v, lo, hi)
    if not isFinite(v) then return nil end
    v = floor(v)
    return v < lo and lo or (v > hi and hi or v)
end
local function clampNum(v, lo, hi)
    if not isFinite(v) then return nil end
    return v < lo and lo or (v > hi and hi or v)
end
local function clampMap(t, lo, hi, int)
    for k, v in pairs(t) do
        if type(v) == 'number' then t[k] = int and clampInt(v, lo, hi) or clampNum(v, lo, hi) end
    end
end

--- The `norm` of the vehicle kind's props (K.check's detached copy, changed in place): every known value clamped.
local function vehiclePropsNorm(p)
    if type(p) ~= 'table' then return p end
    for key, r in pairs(PROP_INT) do if p[key] ~= nil then p[key] = clampInt(p[key], r[1], r[2]) end end
    for key, hi in pairs(PROP_NUM) do if p[key] ~= nil then p[key] = clampNum(p[key], 0, hi) end end
    for key in pairs(PROP_RGB) do
        local v = p[key]
        if type(v) == 'table' then
            p[key] = { clampInt(v[1], 0, 255) or 0, clampInt(v[2], 0, 255) or 0, clampInt(v[3], 0, 255) or 0 }
        elseif v ~= nil and not (v == false and (key == 'customPrimary' or key == 'customSecondary')) then
            p[key] = nil
        end
    end
    local xenon = p.xenonColor
    if xenon ~= nil then
        xenon = clampInt(xenon, -1, 255)
        p.xenonColor = (xenon and (xenon <= 12 or xenon == 255)) and xenon or nil
    end
    if type(p.mods) == 'table' then clampMap(p.mods, -1, 254, true) end
    if type(p.tyreHealth) == 'table' then clampMap(p.tyreHealth, 0, 1000, false) end
    if type(p.lights) == 'table' and p.lights[3] ~= nil then p.lights[3] = clampInt(p.lights[3], 0, 3) end
    return p
end
R.vehiclePropsNorm = vehiclePropsNorm     -- internal: the same ranges for every core props write (README, D-A)

--- A Core.Geometry definition that normalises (sphere / box / polygon).
local function shape(def)
    local G = Core.Geometry
    local s, err = G.normalize(def)
    if not s then return false, err or 'shape' end
    return true
end

--- Vehicle doors { [door 0..7] = 0..1 }: digit-string keys (a JSON round trip) become integers.
local function doors(v)
    local out, n = {}, 0
    for k, ratio in pairs(v) do
        n = n + 1
        local i = mathType(k) == 'integer' and k or math.tointeger(tonumber(k))
        if n > 8 or not i or i < 0 or i > 7 or not isFinite(ratio) or ratio < 0 or ratio > 1 then return nil end
        out[i] = ratio
    end
    return out
end

--------------------------------------------------------------------------------
-- The kind registry
--------------------------------------------------------------------------------

local K = {}
R.kinds = K

--- Fields that mean "core made this node" (review RV4 F11): Core.Maps' element uid / type and the parked-car record
--- id. Only core may set, change or remove them (scene.lua, K.reservedChange) and no plugin kind may declare them.
K.RESERVED = { mapEl = true, mapType = true, vehId = true }

--- The first reserved field whose value differs between `fields` and `old` (nil = a new node), else nil.
function K.reservedChange(fields, old)
    for name in pairs(K.RESERVED) do
        if fields[name] ~= (old and old[name] or nil) then return name end
    end
    return nil
end

local kinds, byIdx, idxOf, changedAt = {}, {}, {}, {}
local idsOf = {}                          -- [owner] = distinct kind ids it introduced this session
local kindCount, nextIdx, version = 0, 1, 0
local tableCache, publicCache = nil, nil

local function bump(id)
    version = version + 1
    changedAt[id] = version
    tableCache, publicCache = nil, nil
end

local function notify(id)
    local fn = K.onChange
    if fn then
        local ok, err = pcall(fn, id)
        if not ok then Log.error('scene: kind change of %s failed: %s', id, tostring(err)) end
    end
end

--- def.fields -> Schema list, table-field specs, name set | nil, err.
local function buildFields(list, builtin)
    if list == nil then return nil, {}, {}, {} end
    local n = seqLen(list, 64)
    if not n then return nil, nil, nil, nil, 'fields' end
    local schemaDefs, tables, names, order = {}, {}, {}, {}
    for i = 1, n do
        local f = list[i]
        if type(f) ~= 'table' then return nil, nil, nil, nil, 'fields:' .. i end
        local name = f.name
        if type(name) ~= 'string' or #name > 48 or not name:find(NAME_PATTERN) then
            return nil, nil, nil, nil, 'fields:' .. i .. '.name'
        end
        if names[name] then return nil, nil, nil, nil, 'fields:duplicate:' .. name end
        names[name] = true
        if f.type == 'table' then
            if f.validate ~= nil and not isCallable(f.validate) then return nil, nil, nil, nil, 'fields:' .. name end
            if f.required ~= nil and type(f.required) ~= 'boolean' then return nil, nil, nil, nil, 'fields:' .. name end
            tables[name] = { validate = f.validate, required = f.required == true, norm = builtin and f.norm or nil,
                label = type(f.label) == 'string' and f.label:sub(1, 128) or nil }
            order[#order + 1] = name
        else
            schemaDefs[#schemaDefs + 1] = f
        end
    end
    local fields
    if #schemaDefs > 0 then
        local err
        fields, err = Schema.fields(schemaDefs)
        if not fields then return nil, nil, nil, nil, 'fields:' .. tostring(err) end
    end
    return fields, tables, names, order
end

local MODEL_FILLED <const> = { prop = { 'lod', 'r' }, vehicle = { 'vtype' } }

--- def -> kind table | nil, err (the offending key).
local function buildKind(def, owner, builtin)
    local class = def.class
    if not CLASS_CODE[class] then return nil, 'class' end
    local fields, tables, names, order, ferr = buildFields(def.fields, builtin)
    if ferr then return nil, ferr end
    if not builtin and owner ~= 'core' then
        for name in pairs(K.RESERVED) do
            if names[name] then return nil, 'fields:reserved:' .. name end   -- review RV4 F11
        end
    end
    local nearFields, nearList = {}, nil
    if def.nearFields ~= nil then
        local n = seqLen(def.nearFields, MAX_NEAR)
        if not n then return nil, 'nearFields' end
        nearList = {}
        for i = 1, n do
            local name = def.nearFields[i]
            if type(name) ~= 'string' or not names[name] or nearFields[name] then return nil, 'nearFields' end
            nearFields[name], nearList[i] = true, name
        end
        if n == 0 then nearList = nil end
    end
    local radius = def.radius
    if radius ~= nil and not (isFinite(radius) and radius >= 1 and radius <= RADIUS_MAX) and not isCallable(radius) then
        return nil, 'radius'
    end
    local handler = def.handler == nil and owner or def.handler
    if not str(handler, ID_MAX, '^[%w_%-%.]+$') then return nil, 'handler' end
    local authority, aerr = V.authority(def.authority)
    if aerr then return nil, aerr end
    local budget = def.budget == nil and DEFAULT_BUDGET[class] or def.budget
    if not str(budget, 32, ID_PATTERN) then return nil, 'budget' end
    local filled
    local model = MODEL_FILLED[class]
    if model and names.model then
        for i = 1, #model do
            if not names[model[i]] then
                filled = filled or {}
                filled[model[i]] = true
            end
        end
    end
    if builtin and def.filled then
        filled = filled or {}
        for i = 1, #def.filled do filled[def.filled[i]] = true end
    end
    local derived                         -- model-derived INPUT fields (built-ins): kept when given, else filled
    for i = 1, builtin and def.derived and #def.derived or 0 do
        derived = derived or {}
        derived[def.derived[i]] = true
    end
    local modelType                       -- the Schema type of the `model` field (integer hashes: 'model' only)
    for i = 1, fields and #fields or 0 do
        if fields[i].name == 'model' then modelType = fields[i].type end
    end
    local schemaPublic = fields and Schema.public(fields) or {}
    for i = 1, #order do
        local spec = tables[order[i]]
        schemaPublic[#schemaPublic + 1] = { name = order[i], type = 'table', required = spec.required or nil,
            label = spec.label }
    end
    return {
        id = def.id, class = class, classCode = CLASS_CODE[class], fields = fields, tables = tables, names = names,
        schemaPublic = schemaPublic,
        tableOrder = order, nearFields = nearFields, nearList = nearList, radius = radius, handler = handler,
        authority = authority, budget = budget, owner = owner, builtin = builtin == true,
        dependency = builtin == true and def.dependency == true or nil, filled = filled, derived = derived,
        clock = builtin and def.clock or nil, post = builtin and def.post or nil,
        hasModel = (class == 'prop' or class == 'vehicle' or class == 'ped') and names.model == true,
        intModel = (class == 'prop' or class == 'vehicle' or class == 'ped') and modelType == 'model' or nil,
    }
end

--- Scene.defineKind(def) -> true | false, err. `owner` = the defining resource; the same owner may redefine.
function K.define(def, owner, builtin)
    if type(def) ~= 'table' then return false, 'def' end
    owner = (type(owner) == 'string' and owner ~= '') and owner or 'core'
    local id = def.id
    if type(id) ~= 'string' or #id > ID_MAX then return false, 'id' end
    if not builtin then
        local prefix = id:match('^([^:]+):')
        if not id:find(PLUGIN_ID) or (owner ~= 'core' and prefix ~= owner) then return false, 'id' end
    end
    local current = kinds[id]
    if current and (current.builtin or current.owner ~= owner) then return false, 'owner' end
    local idx = idxOf[id]
    if not current and kindCount >= MAX_KINDS then return false, 'limit' end
    if not idx and (nextIdx > MAX_KIND_IDS
        or (not builtin and owner ~= 'core' and (idsOf[owner] or 0) >= MAX_KIND_IDS_OWNER)) then
        return false, 'limit'
    end
    local kind, err = buildKind(def, owner, builtin)
    if not kind then return false, err end
    if not idx then
        idx = nextIdx
        nextIdx = nextIdx + 1
        idxOf[id] = idx
        if not builtin and owner ~= 'core' then idsOf[owner] = (idsOf[owner] or 0) + 1 end
    end
    kind.idx = idx
    if not current then kindCount = kindCount + 1 end
    kinds[id], byIdx[idx] = kind, kind
    bump(id)
    if not builtin then Registry.track(KIND_KIND, id, owner) end
    notify(id)
    return true
end

--- Removes one kind (its nodes stay and are delivered as placeholders). Built-ins cannot be removed.
function K.undefine(id)
    local kind = kinds[id]
    if not kind or kind.builtin then return false end
    kinds[id], byIdx[kind.idx] = nil, nil
    kindCount = kindCount - 1
    bump(id)
    Registry.untrack(KIND_KIND, id)
    notify(id)
    return true
end

--- Every kind of `owner` -> array of the removed ids.
function K.undefineOwner(owner)
    local list = {}
    for id, kind in pairs(kinds) do
        if kind.owner == owner and not kind.builtin then list[#list + 1] = id end
    end
    table.sort(list)
    for i = 1, #list do K.undefine(list[i]) end
    return list
end

Registry.onOwnerStop(KIND_KIND, function(id) K.undefine(id) end)

function K.get(id) return kinds[id] end
function K.byIdx(idx) return byIdx[idx] end
function K.version() return version end
function K.count() return kindCount end

local function wireEntry(kind)
    return { idx = kind.idx, id = kind.id, class = kind.classCode,
        meta = { near = kind.nearList, budget = kind.budget, handler = kind.handler,
            dep = kind.dependency or nil } }
end

--- The KINDS op list: every defined kind when since == 0 (or unknown), else the kinds changed after `since`
--- (removed ones as { idx, id = '', class = 0 }), ascending idx. Callers must not mutate it.
function K.table(since)
    since = math.tointeger(since) or 0
    if since <= 0 or since > version then
        if not tableCache then
            local list = {}
            for _, kind in pairs(kinds) do list[#list + 1] = wireEntry(kind) end
            table.sort(list, function(a, b) return a.idx < b.idx end)
            tableCache = list
        end
        return tableCache
    end
    local list = {}
    for id, at in pairs(changedAt) do
        if at > since then
            local kind = kinds[id]
            list[#list + 1] = kind and wireEntry(kind) or { idx = idxOf[id], id = '', class = 0 }
        end
    end
    table.sort(list, function(a, b) return a.idx < b.idx end)
    return list
end

--- Scene.kinds(): the public list (no functions), sorted by id; a fresh copy per call.
function K.public()
    if not publicCache then
        local list = {}
        for _, k in pairs(kinds) do
            list[#list + 1] = { id = k.id, idx = k.idx, class = k.class, fields = k.schemaPublic,
                nearFields = k.nearList,
                radius = type(k.radius) == 'number' and k.radius or (k.radius ~= nil and 'fn' or nil),
                handler = k.handler, budget = k.budget, authority = k.authority, owner = k.owner, builtin = k.builtin,
                dependency = k.dependency }
        end
        table.sort(list, function(a, b) return a.id < b.id end)
        publicCache = list
    end
    return Utils.deepCopy(publicCache)
end

--------------------------------------------------------------------------------
-- Field checks (§55.4 step 2)
--------------------------------------------------------------------------------

local MAX_UNKNOWN <const> = 16
local INT_STANDIN <const> = '0'          -- what Schema sees for an integer model hash (a valid model name)

--- Schema.checkAll over the Schema fields, then the `table` fields (plain data, <= MaxFieldBytes, `validate`
--- only when nothing else failed), the whole table <= MaxFieldBytes packed, then the built-in cross-field rule
--- (full checks). Server-filled names are ignored on input, so a Scene.get → Scene.set round trip stays valid.
--- A `model` field of Schema type 'model' (prop / vehicle / ped classes) also takes an integer hash, kept as is.
function K.check(kind, fields, partial)
    if fields == nil then fields = {} end
    if type(fields) ~= 'table' or getmetatable(fields) ~= nil then return false, { ['*'] = 'type' } end
    partial = partial == true
    local filled, tables, maxBytes = kind.filled, kind.tables, cfg().MaxFieldBytes or 8192
    local schemaIn, tableIn, errs, unknown = {}, {}, nil, 0
    local intModel = kind.intModel and intHash(fields.model) or nil
    for k, v in pairs(fields) do
        if tables[k] then
            tableIn[k] = v
        elseif not (filled and filled[k]) then
            if kind.fields then
                schemaIn[k] = v
            else
                errs = errs or {}
                errs[tostring(k):sub(1, 48)] = 'unknown'
                unknown = unknown + 1
                if unknown >= MAX_UNKNOWN then return false, errs end
            end
        end
    end
    local out = {}
    if kind.fields then
        if intModel then schemaIn.model = INT_STANDIN end
        local ok, res = Schema.checkAll(kind.fields, schemaIn, { partial = partial })
        if ok then out = res else errs = res end
        if ok and intModel then out.model = intModel end
    end
    for name, spec in pairs(tables) do
        local v = tableIn[name]
        if v == nil then
            if spec.required and not partial then
                errs = errs or {}
                errs[name] = 'required'
            end
        else
            local clean, err = V.plain(v, maxBytes)
            if not err and spec.norm then
                clean = spec.norm(clean)
                if clean == nil then err = 'type' end
            end
            if err then
                errs = errs or {}
                errs[name] = err
            else
                out[name] = clean
            end
        end
    end
    if not errs then
        for name, spec in pairs(tables) do
            local v = out[name]
            if v ~= nil and spec.validate then
                local ok, res, msg = pcall(spec.validate, v, out)
                if not ok or not res then
                    errs = errs or {}
                    local text = type(msg) == 'string' and msg:sub(1, 128) or 'invalid'
                    errs[name] = not ok and 'custom:error' or ('custom:' .. text)
                end
            end
        end
    end
    if errs then return false, errs end
    local ok, blob = pcall(Codec.pack, out)
    if not ok or type(blob) ~= 'string' or #blob > maxBytes then return false, { ['*'] = 'size' } end
    if kind.post and not partial then
        local res, perrs = kind.post(out)
        if not res then return false, perrs end
        out = res
    end
    return true, out
end

--------------------------------------------------------------------------------
-- Model info (§55.12): Scene.setModelInfo provider → the §52 Maps validator (lazy) → defaults
--------------------------------------------------------------------------------

local MODEL_CLASS <const> = { prop = true, vehicle = true, ped = true }
-- Vehicle types: the net types CreateVehicleServerSetter takes and the server's GetVehicleType answers (fxref
-- 2026-09-27: automobile, bike, boat, heli, plane, submarine, trailer, train), plus the vehicles.meta names that
-- are one of them on the wire (admin's catalogue reports those): quadbike / amphibious / submarine cars are
-- automobiles, a blimp is a heli. Input and model info both end up as the net type.
local VTYPE <const> = { automobile = 'automobile', bike = 'bike', boat = 'boat', heli = 'heli', plane = 'plane',
    submarine = 'submarine', trailer = 'trailer', train = 'train', quadbike = 'automobile',
    amphibious_automobile = 'automobile', amphibious_quadbike = 'automobile', submarinecar = 'automobile',
    blimp = 'heli' }
local NONE <const> = {}                       -- the provider answered nil: ask the next link
local provider = nil                          -- { fn, owner }
local infoCache, infoCount = {}, 0            -- ['<class>:<model>'] = cleaned info | NONE | false

--- Only what the runtime uses survives: lod 1..5000, r (bounding radius, from `radius` or `bbox`), vtype.
local function cleanInfo(info)
    local lod = isFinite(info.lod) and floor(info.lod + 0.5) or nil
    if lod and (lod < 1 or lod > 5000) then lod = nil end
    local r = isFinite(info.radius) and info.radius or nil
    if not r and type(info.bbox) == 'table' then
        local ax, ay, az = V.xyz(info.bbox.min)
        local bx, by, bz = V.xyz(info.bbox.max)
        if ax and bx then r = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2 + (bz - az) ^ 2) / 2 end
    end
    if r and (r < 0.01 or r > 1000) then r = nil end
    local vt = VTYPE[info.vehicleType]
    if not lod and not r and not vt then return NONE end
    return { lod = lod, r = r, vtype = vt }
end

local function withDefaults(class, info)
    local out = { lod = info.lod, r = info.r, vtype = info.vtype }
    if class == 'prop' then
        out.lod, out.r = out.lod or 100, out.r or 2
    elseif class == 'vehicle' then
        out.vtype = out.vtype or 'automobile'
    end
    return out
end

--- -> { lod, r, vtype } (a fresh table) | nil, 'model'. Only the Scene.setModelInfo provider can REFUSE a model
--- (it answers false). The §52 Maps validator is an info source here: a model it knows gives its lod / vehicle
--- type, one it refuses or does not know gets the defaults — scene nodes of addon / streamed models and weapon
--- objects are no map elements (Maps enforces its allow-list itself, at authoring / apply time).
--- `model` is a name or an integer hash (cached as '<class>:#<hash>').
function K.modelInfo(class, model)
    if not MODEL_CLASS[class] then return nil, 'model' end
    local key
    if type(model) == 'string' then
        if #model == 0 or #model > ID_MAX then return nil, 'model' end
        key = class .. ':' .. model
    else
        model = intHash(model)
        if not model then return nil, 'model' end
        key = class .. ':#' .. model
    end
    local hit = infoCache[key]
    if hit == nil and provider then
        local ok, res = pcall(provider.fn, class, model)
        if not ok then
            Log.warn('scene: the model-info provider of %s failed for %s: %s', provider.owner, key, tostring(res))
        else
            if res == false then hit = false
            elseif type(res) == 'table' then hit = cleanInfo(res)
            else hit = NONE end
            if infoCount >= MAX_INFO_CACHE then infoCache, infoCount = {}, 0 end
            infoCache[key], infoCount = hit, infoCount + 1
        end
    end
    if hit == false then return nil, 'model' end
    if hit and hit ~= NONE then return withDefaults(class, hit) end
    local M = rawget(Core, 'MapsRuntime')
    if M and M.checkModel then
        local ok, valid, info = pcall(M.checkModel, { kind = class }, model)
        if ok and valid and type(info) == 'table' then
            return withDefaults(class, { lod = info.lod, vtype = VTYPE[info.vehicleType] })
        end
    end
    return withDefaults(class, NONE)
end

--- Fills the server-filled fields of `fields` in place (prop lod / r, the vtype of a vehicle kind that does not
--- declare one) and the model-derived INPUT fields (the built-in vehicle's vtype) only where absent -> true |
--- nil, 'model'. `derivedOnly`: nothing but the absent derived fields (a set that kept the model).
function K.fillModel(kind, fields, derivedOnly)
    if not kind.hasModel or fields.model == nil then return true end
    local derived, need = kind.derived, not derivedOnly
    for name in pairs(derived or EMPTY) do need = need or fields[name] == nil end
    if not need then return true end
    local info, err = K.modelInfo(kind.class, fields.model)
    if not info then return nil, err end
    local filled = kind.filled
    if filled and not derivedOnly then
        if filled.lod then fields.lod = info.lod end
        if filled.r then fields.r = info.r end
        if filled.vtype then fields.vtype = info.vtype end
    end
    for name in pairs(derived or EMPTY) do
        if fields[name] == nil then fields[name] = info[name] end
    end
    return true
end

--- Scene.setModelInfo(fn | nil): one provider; nil clears it (its owner or core). Clears the cache.
function K.setModelInfo(fn, owner)
    owner = (type(owner) == 'string' and owner ~= '') and owner or 'core'
    if fn ~= nil and not isCallable(fn) then return false end
    if fn == nil then
        if not provider then return true end
        if provider.owner ~= owner and owner ~= 'core' then return false end
        provider = nil
    else
        if provider and provider.owner ~= owner then
            Log.warn('scene: %s replaces the model-info provider of %s', owner, provider.owner)
        end
        provider = { fn = fn, owner = owner }
    end
    Registry.untrack(INFO_KIND, 'provider')
    if provider then Registry.track(INFO_KIND, 'provider', owner) end
    infoCache, infoCount = {}, 0
    return true
end

Registry.onOwnerStop(INFO_KIND, function(_, owner)
    if provider and provider.owner == owner then
        provider = nil
        infoCache, infoCount = {}, 0
    end
end)

--------------------------------------------------------------------------------
-- Clock helpers (Core.Clock, u32 ms, §55.2), radius policies and tiers
--------------------------------------------------------------------------------

local Clock = Core.Clock
assert(Clock and Clock.now and Clock.diff and Clock.add,
    'lib/clock (Core.Clock) must exist before server/scene_kinds.lua')
R.now, R.diff, R.add = Clock.now, Clock.diff, Clock.add

local function zoneRadius(f, node)
    local ok, s = pcall(Core.Geometry.normalize, f.shape)
    if not ok or not s then return DEFAULT_RADIUS end
    local p = node.pos
    local d = p and sqrt((s.coords.x - p.x) ^ 2 + (s.coords.y - p.y) ^ 2 + (s.coords.z - p.z) ^ 2) or 0
    return d + s.radius + 40
end

local POLICY <const> = {       -- built-in kinds (§55.11 R_out plus margin; the §55.12 server policies)
    prop = function(f) return (isFinite(f.lod) and f.lod or 100) * 1.75 + 80 end,
    vehicle = function() return 330 end,
    ped = function() return 150 end,
    light = function(f) return math.min((f.range or 10) * 3 + 80, 330) end,
    particle = function(f) return (f.drawDistance or 150) + 30 end,
    marker = function(f) return (f.drawDistance or 50) + 30 end,
    text = function(f) return (f.drawDistance or 25) + 30 end,
    hide = function(f) return (f.radius or 2) + 200 end,
    zone = zoneRadius,
    sound = function(f) return (f.range or 30) + 40 end,
    audio = function(f) return (f.range or 40) + 40 end,
}
local CLASS_POLICY <const> = { prop = POLICY.prop, vehicle = POLICY.vehicle, ped = POLICY.ped,
    audio = function(f) return isFinite(f.range) and f.range + 40 or DEFAULT_RADIUS end }

--- The stream radius: the node's explicit radius, else the kind's (number or fn(nodeCopy)), else the built-in
--- policy / the class policy, else 250 (a placeholder keeps its last radius). Clamped to 1..TierL (global:
--- 1..65535).
function K.radius(kind, node)
    local r = node.fixedRadius
    if r == nil and kind then
        local kr = kind.radius
        if type(kr) == 'number' then
            r = kr
        elseif kr ~= nil then
            local p = node.pos
            local ok, res = pcall(kr, { id = node.id, kind = node.kind, fields = Utils.deepCopy(node.fields),
                pos = p and { x = p.x, y = p.y, z = p.z } })
            if ok and isFinite(res) and res > 0 then r = res end
        end
        if r == nil then
            local policy = (kind.builtin and POLICY[kind.id]) or CLASS_POLICY[kind.class]
            if policy then
                local ok, res = pcall(policy, node.fields or EMPTY, node)
                if ok and isFinite(res) then r = res end
            end
        end
    end
    r = r or node.radius or DEFAULT_RADIUS
    local max = node.global and RADIUS_MAX or (cfg().TierL or 1500)
    if r > max then r = max end
    if r < 1 then r = 1 end
    return r
end

function K.tier(radius, global)
    if global then return 'G' end
    local c = cfg()
    if radius <= (c.TierS or 160) then return 'S' end
    if radius <= (c.TierM or 448) then return 'M' end
    return 'L'
end

--------------------------------------------------------------------------------
-- Built-in kinds (owner core, §55.12): reserved plain ids, handler core
--------------------------------------------------------------------------------

local function B(name, default) return { name = name, type = 'boolean', default = default } end
local function N(name, min, max, default)
    return { name = name, type = 'number', min = min, max = max, default = default }
end
local function I(name, min, max, default, required)
    return { name = name, type = 'integer', min = min, max = max, default = default, required = required }
end
local function S(name, max, pattern, required)
    return { name = name, type = 'string', maxLength = max, pattern = pattern, required = required }
end
local function E(name, options, default) return { name = name, type = 'enum', options = options, default = default } end
local function C(name, default, alpha) return { name = name, type = 'color', default = default, alpha = alpha } end
local function M(kind) return { name = 'model', type = 'model', kinds = { kind }, required = true } end
local function T(name, validate, norm, required)
    return { name = name, type = 'table', validate = validate, norm = norm, required = required }
end
local function O(name, fields) return { name = name, type = 'object', fields = fields } end

local U32 <const>, I32 <const> = 0xFFFFFFFF, -0x80000000
local DICT <const>, CLIP <const>, WORD <const> = '^[%w_%-@/%.]+$', '^[%w_%-%.]+$', '^[%w_%-%. ]+$'
local FILE <const>, HTTPS <const> = '^@[%w_%-%.]+/[%w_%-%./ ]+$', '^https://'
local function anim(ped)
    local f = { S('dict', 128, DICT, true), S('clip', 128, CLIP, true), B('loop', true), N('rate', 0, 10, 1),
        I('t0', 0, U32) }
    if ped then f[#f + 1] = I('flag', 0, 0x7FFFFFFF) end
    return O('anim', f)
end
local ROOM <const> = O('room', { I('interior', I32, U32, nil, true), I('key', I32, U32) })
-- Core.Maps' projection (§55.21.1) tags the nodes it makes: the element uid '<mapId>:<elementId>' and the type id.
-- Ordinary fields (never nearFields): every variant a node materialises from carries them (client/maps.lua).
local function MAPS() return S('mapEl', 48), S('mapType', 64) end

-- vehicle `vtype`: an INPUT (kept; the net type of a vehicles.meta name) that the model info fills when absent
local VTYPE_NAMES <const> = { 'automobile', 'bike', 'boat', 'heli', 'plane', 'submarine', 'trailer', 'train',
    'quadbike', 'amphibious_automobile', 'amphibious_quadbike', 'submarinecar', 'blimp' }
local function vehiclePost(out)
    if out.vtype ~= nil then out.vtype = VTYPE[out.vtype] end
    return out
end

--- audio.source (§55.16): the source matches its type; remote URLs need server/scene_audio.lua (R.audio.check
--- resolves them: -> true, fields | false, err, fieldName), else only `file` sources pass; t0 defaults to
--- Clock.at(PlanLeadMs).
local function sourcePost(out)
    local t, url, file, items = out.type, out.url, out.file, out.items
    if t == 'timeline' then
        if not items or #items == 0 or url or file then return nil, { items = 'required' } end
        for i = 1, #items do
            if (items[i].url == nil) == (items[i].file == nil) then return nil, { items = i .. '.source' } end
        end
    elseif t == 'voice' then
        if url or file or items then return nil, { type = 'voice' } end
    elseif items or (url == nil) == (file == nil) or (t == 'stream' and not url) then
        return nil, { url = 'source' }
    end
    local A = R.audio
    if A and A.check then
        local ok, res, name = A.check(out)
        if not ok then
            return nil, { [type(name) == 'string' and name or 'url'] = type(res) == 'string' and res or 'policy' }
        end
        if type(res) == 'table' then out = res end
    else
        local remote = url ~= nil
        for i = 1, items and #items or 0 do remote = remote or items[i].url ~= nil end
        if remote then return nil, { url = 'unavailable' } end
    end
    if out.t0 == nil then out.t0 = R.add(R.now(), (cfg().Motion or {}).PlanLeadMs or 200) end
    return out
end

local BUILTIN <const> = {
    { id = 'prop', class = 'prop', clock = { 'anim.t0' }, fields = { M('prop'), B('frozen', true), B('collision', true),
        B('invincible', false), B('visible', true), I('tint', 0, 15),
        E('physics', { 'static', 'local', 'promote' }, 'static'), E('snap', { 'ground' }),
        anim(false), ROOM, MAPS() } },
    { id = 'vehicle', class = 'vehicle', derived = { 'vtype' }, post = vehiclePost, fields = { M('vehicle'),
        T('props', vehicleProps, vehiclePropsNorm), S('plate', 8, '^[%w %-]*$'), B('locked', false), B('engine', false),
        I('lights', 0, 2), B('siren', false), T('doors', nil, doors), B('frozen', true), B('invincible', false),
        N('dirt', 0, 15), E('vtype', VTYPE_NAMES), S('vehId', 64, '^[%w_%-:]+$'), MAPS() } },
    { id = 'ped', class = 'ped', clock = { 'anim.t0' }, fields = { M('ped'), T('appearance'), T('variation'),
        S('scenario', 64, '^[%w_]*$'), anim(true), { name = 'weapon', type = 'model', kinds = { 'weapon' } },
        B('invincible', true), B('frozen', true), B('blockEvents', true), I('health', 0, 10000), ROOM, MAPS() } },
    { id = 'light', class = 'fx', budget = 'lights', fields = { E('type', { 'point', 'spot' }, 'point'),
        C('color', '#FFFFFF'),
        N('intensity', 0, 100, 1), N('range', 0.1, 100, 10), B('shadow', false),
        { name = 'dir', type = 'vector3', min = -1, max = 1 }, N('falloff', 0, 100), N('inner', 0, 90),
        N('outer', 0, 90),
        E('flicker', { 'none', 'candle', 'neon', 'strobe' }, 'none'), I('seed', 0, 65535) } },
    { id = 'particle', class = 'fx', budget = 'particles', fields = { S('asset', 64, ID_PATTERN, true),
        S('name', 64, ID_PATTERN, true), N('scale', 0.01, 100, 1), C('color'), N('alpha', 0, 1, 1),
        N('drawDistance', 1, 1000, 150) } },
    { id = 'marker', class = 'fx', budget = 'markers', fields = { I('type', 0, 43, 1),
        { name = 'scale', type = 'vector3', min = 0.01, max = 100, default = { x = 1, y = 1, z = 1 } },
        C('color', '#E0A33AB4', true), B('bob', false), B('face', false), B('rotate', false),
        N('drawDistance', 1, 500, 50), MAPS() } },
    { id = 'text', class = 'fx', budget = 'texts', fields = {
        { name = 'text', type = 'string', minLength = 1, maxLength = 128, required = true }, N('scale', 0.1, 5, 0.35),
        I('font', 0, 8, 4), C('color', '#FFFFFFFF', true), B('outline', true), N('drawDistance', 1, 200, 25) } },
    { id = 'hide', class = 'fx', budget = 'hides', fields = { S('model', 64, ID_PATTERN, true),
        N('radius', 0.5, 50, 2), MAPS() } },
    { id = 'zone', class = 'data', fields = { T('shape', shape, nil, true), B('events', true) } },
    { id = 'sound', class = 'fx', budget = 'sounds', fields = { S('name', 64, WORD, true), S('set', 64, WORD),
        B('looped', true), N('range', 1, 500, 30) } },
    { id = 'group', class = 'data' },
    { id = 'audio.source', class = 'audio', dependency = true, filled = { 'resolved' }, clock = { 't0', 'pausedAt' },
        post = sourcePost, fields = { E('type', { 'clip', 'loop', 'timeline', 'stream', 'voice' }, 'clip'),
        S('url', 512, HTTPS), S('file', 256, FILE), { name = 'items', type = 'array', maxItems = 200, items = {
            type = 'object', fields = { S('url', 512, HTTPS), S('file', 256, FILE), N('duration', 0, 86400000) } } },
        B('loop', false), I('t0', 0, U32), N('rate', 0.1, 4, 1), B('paused', false), I('pausedAt', 0, U32),
        N('offset', -86400000, 86400000, 0), N('volume', 0, 2, 1),
        E('category', { 'music', 'sfx', 'ambience', 'voice' }, 'sfx'),
        S('title', 128) } },
    { id = 'audio', class = 'audio', fields = { I('source', 1, 0x7FFFFFFF, nil, true), N('range', 1, 600, 40),
        N('volume', 0, 2, 1), E('curve', { 'game', 'inverse', 'linear' }, 'game'), N('ref', 0.1, 100, 2),
        O('cone', { N('inner', 0, 360), N('outer', 0, 360), N('outerGain', 0, 1, 0) }), I('priority', 1, 5, 3),
        B('occlusion', true), T('zone', shape) } },
}

for i = 1, #BUILTIN do
    local ok, err = K.define(BUILTIN[i], 'core', true)
    if not ok then Log.error('scene: built-in kind %s refused: %s', BUILTIN[i].id, tostring(err)) end
end
