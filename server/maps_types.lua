--[[
    core/server/maps_types.lua — Core.Maps element types and the model validator (DESIGN §52.1, §52.2).
    First of the four map files (maps_types → maps_runtime → maps → maps_apply, in that manifest order).
    It creates `Core.MapsRuntime` (R), the INTERNAL table the four files share — block-listed from the
    export like Core.MapRegions — and `R.state`, the in-memory documents maps.lua loads.

      R.defineType(def) -> true | false, err     owner-tracked (Registry kind 'mapType'); same owner may redefine
      R.publicTypes() -> list                    Maps.types(): no functions, Schema.public fields, cached
      R.setModelValidator(fn) -> bool            one validator, owner-tracked (kind 'mapsModelValidator')
      R.checkModel(def, model) -> ok, info|err   validator results cached until the validator changes
      R.modelOf(def, el), R.isNetworked(def), R.joaat(name), R.xyz(v), R.rgba(hex)

    A type whose owner stops is removed; its records stay and render as editor-only placeholders
    (maps_runtime.lua re-renders them through R.refreshType, looked up at call time).
    Built-in types (owner core): core:prop, core:physprop, core:vehicle, core:ped, core:marker,
    core:hide, core:point, core:zone.

    Natives: none.
]]

local R = { state = {
    maps = {},          -- [mapId] = map document (the live copy; persisted on change)
    sets = {},          -- [mapId] = { els = { [elementId] = element } }  the draft / live working set
    snaps = {},         -- [mapId] = { version, els }  a draft's published snapshot
    editorBuckets = {}, -- [mapId] = bucket while the draft is open
} }
Core.MapsRuntime = R

local Log = Core.Log
local Utils = Core.Utils
local Schema = Core.Schema
local Registry = Core.Registry

local TYPE_KIND <const> = 'mapType'
local VALIDATOR_KIND <const> = 'mapsModelValidator'
local TYPE_PATTERN <const> = '^[%w_%-]+:[%w_%-]+$'
local MODEL_PATTERN <const> = '^[%w_%-]+$'
local MAX_ID <const> = 64
local MAX_LABEL <const> = 64
local MAX_ICON <const> = 32
local MAX_CATEGORY <const> = 32
local MAX_DESCRIPTION <const> = 512
local MAX_PARENTS <const> = 16
local MAX_PREVIEW <const> = 8
local MAX_MODEL_CACHE <const> = 4096

local KINDS <const> = { prop = true, vehicle = true, ped = true, marker = true, hide = true, point = true, zone = true }
local MODEL_KINDS <const> = { prop = true, vehicle = true, ped = true }
local ROTATE <const> = { full = true, yaw = true, none = true }
local DEFAULT_ROTATE <const> = { prop = 'full', vehicle = 'yaw', ped = 'yaw', marker = 'full', hide = 'none',
    point = 'yaw', zone = 'yaw' }

local types = {}            -- [typeId] = normalised definition (validate/migrate kept as given)
R.types = types
local typesGen = 0          -- bumped on every define/removal (maps.lua keys its count caches on it)
local publicCache = nil     -- Maps.types() result, rebuilt after a change
local validator = nil       -- { fn, owner }
local modelCache, modelCacheSize = {}, 0   -- ['<kind>:<model>'] = { ok, info|err }

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function isFinite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end
R.isFinite = isFinite

--- x, y, z of a vector3 or of a table with numeric x/y/z (other keys ignored); nil otherwise.
local function xyz(v)
    local t = type(v)
    if t ~= 'vector3' and t ~= 'table' then return nil end
    local x, y, z = v.x, v.y, v.z
    if isFinite(x) and isFinite(y) and isFinite(z) then return x, y, z end
    return nil
end
R.xyz = xyz

local function optString(v, max)
    return v == nil or (type(v) == 'string' and #v <= max)
end

--- GTA's one-at-a-time hash of the lower-cased name, as a signed 32-bit integer (GetHashKey's result).
local function joaat(name)
    local h = 0
    local s = name:lower()
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    if h >= 0x80000000 then h = h - 0x100000000 end
    return h
end
R.joaat = joaat

--- '#RRGGBB' / '#RRGGBBAA' -> r, g, b, a (a = 255 without alpha); nil for anything else.
local function rgba(v)
    if type(v) ~= 'string' then return nil end
    local r, g, b, a = v:match('^#(%x%x)(%x%x)(%x%x)(%x?%x?)$')
    if not r or (#a ~= 0 and #a ~= 2) then return nil end
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16), #a == 2 and tonumber(a, 16) or 255
end
R.rgba = rgba

--- maps_runtime.lua re-renders the active elements of a type whose definition changed.
local function refreshType(id)
    local fn = R.refreshType
    if fn then fn(id) end
end

--------------------------------------------------------------------------------
-- Element types (§52.1)
--------------------------------------------------------------------------------

--- A preview number/vector literal or a '$field' reference.
local function previewValue(v, vector)
    if type(v) == 'string' then return v:find('^%$[%a_][%w_]*$') and v or nil end
    if vector then
        local x, y, z = xyz(v)
        return x and { x = x, y = y, z = z } or nil
    end
    return isFinite(v) and v or nil
end

--- Declarative editor previews (no callbacks): marker / box / sphere / label, at most 8.
local function normalizePreview(list)
    if list == nil then return nil end
    if type(list) ~= 'table' or #list > MAX_PREVIEW then return nil, 'preview' end
    local out = {}
    for i = 1, #list do
        local p = list[i]
        if type(p) ~= 'table' then return nil, 'preview' end
        local entry
        if p.kind == 'marker' then
            local t = math.tointeger(p.type)
            if not t or t < 0 or t > 43 or (p.color ~= nil and not rgba(p.color)) then return nil, 'preview' end
            entry = { kind = 'marker', type = t, color = p.color }
            if p.scale ~= nil then
                entry.scale = previewValue(p.scale, type(p.scale) ~= 'number')
                if not entry.scale then return nil, 'preview' end
            end
        elseif p.kind == 'box' then
            entry = { kind = 'box', size = previewValue(p.size, true) }
            if not entry.size then return nil, 'preview' end
        elseif p.kind == 'sphere' then
            entry = { kind = 'sphere', radius = previewValue(p.radius, false) }
            if not entry.radius then return nil, 'preview' end
        elseif p.kind == 'label' then
            if type(p.text) ~= 'string' or #p.text == 0 or #p.text > MAX_LABEL then return nil, 'preview' end
            entry = { kind = 'label', text = p.text }
        else
            return nil, 'preview'
        end
        out[i] = entry
    end
    return out
end

--- Does a normalised field list contain `model` of Schema type 'model'?
local function hasModelField(fields)
    if not fields then return false end
    for i = 1, #fields do
        if fields[i].name == 'model' and fields[i].type == 'model' then return true end
    end
    return false
end

--- def -> normalised entry, or nil + err (the field that failed).
local function buildType(def, owner)
    local id, kind = def.id, def.kind
    if not KINDS[kind] then return nil, 'kind' end
    local label = def.label == nil and id or def.label
    if type(label) ~= 'string' or #label == 0 or #label > MAX_LABEL then return nil, 'label' end
    if not optString(def.icon, MAX_ICON) then return nil, 'icon' end
    if not optString(def.category, MAX_CATEGORY) then return nil, 'category' end
    if not optString(def.description, MAX_DESCRIPTION) then return nil, 'description' end
    if def.model ~= nil and (not MODEL_KINDS[kind] or type(def.model) ~= 'string' or #def.model > MAX_ID
        or not def.model:find(MODEL_PATTERN)) then return nil, 'model' end
    if def.networked ~= nil and type(def.networked) ~= 'boolean' then return nil, 'networked' end
    if def.networked and kind ~= 'prop' then return nil, 'networked' end
    local rotate = DEFAULT_ROTATE[kind]
    if def.transform ~= nil then
        if type(def.transform) ~= 'table' or (def.transform.rotate ~= nil and not ROTATE[def.transform.rotate]) then
            return nil, 'transform'
        end
        rotate = def.transform.rotate or rotate
    end
    local fields
    if def.fields ~= nil then
        local err
        fields, err = Schema.fields(def.fields)
        if not fields then return nil, 'fields:' .. tostring(err) end
    end
    if MODEL_KINDS[kind] and not def.model and not hasModelField(fields) then return nil, 'model_field' end
    local limits
    if def.limits ~= nil then
        local perMap = type(def.limits) == 'table' and def.limits.perMap
        perMap = perMap ~= nil and math.tointeger(perMap) or nil
        if type(def.limits) ~= 'table'
            or (def.limits.perMap ~= nil and (not perMap or perMap < 0 or perMap > 100000)) then
            return nil, 'limits'
        end
        limits = { perMap = perMap }
    end
    local parents
    if def.parents ~= nil then
        if type(def.parents) ~= 'table' or #def.parents == 0 or #def.parents > MAX_PARENTS then
            return nil, 'parents'
        end
        parents = {}
        for i = 1, #def.parents do
            local p = def.parents[i]
            if type(p) ~= 'string' or #p > MAX_ID or not p:find(TYPE_PATTERN) or p == id then return nil, 'parents' end
            parents[i] = p
        end
    end
    if def.validate ~= nil and not Utils.isCallable(def.validate) then return nil, 'validate' end
    if def.migrate ~= nil and not Utils.isCallable(def.migrate) then return nil, 'migrate' end
    local version = def.version == nil and 1 or math.tointeger(def.version)
    if not version or version < 1 or version > 1000000 then return nil, 'version' end
    local preview, perr = normalizePreview(def.preview)
    if perr then return nil, perr end
    local refFields                             -- { name, refType } of the ref fields (apply's ref checks)
    for i = 1, fields and #fields or 0 do
        if fields[i].type == 'ref' then
            refFields = refFields or {}
            refFields[#refFields + 1] = { name = fields[i].name, refType = fields[i].refType }
        end
    end
    local labelFields                           -- fields a '$field' label preview shows (tuple extra.f)
    for i = 1, preview and #preview or 0 do
        local name = preview[i].kind == 'label' and preview[i].text:match('^%$([%a_][%w_]*)$')
        if name then
            labelFields = labelFields or {}
            labelFields[#labelFields + 1] = name
        end
    end
    return {
        id = id, label = label, icon = def.icon, category = def.category or 'Gameplay',
        description = def.description, kind = kind, model = def.model, fields = fields, preview = preview,
        rotate = rotate, networked = def.networked == true, limits = limits, parents = parents,
        validate = def.validate, migrate = def.migrate, version = version, owner = owner, labelFields = labelFields,
        refFields = refFields,
    }
end

--- Maps.defineType(def) -> true | false, err. Owner-tracked; the same owner may redefine its type.
function R.defineType(def)
    if type(def) ~= 'table' then return false, 'def' end
    local id = def.id
    if type(id) ~= 'string' or #id > MAX_ID or not id:find(TYPE_PATTERN) then return false, 'id' end
    local owner = Registry.getCaller()
    local current = types[id]
    if current and current.owner ~= owner then return false, 'owner' end
    local entry, err = buildType(def, owner)
    if not entry then return false, err end
    types[id] = entry
    typesGen, publicCache = typesGen + 1, nil
    Registry.track(TYPE_KIND, id, owner)
    refreshType(id)
    return true
end

local function dropType(id)
    if not types[id] then return end
    types[id] = nil
    typesGen, publicCache = typesGen + 1, nil
    Registry.untrack(TYPE_KIND, id)
    refreshType(id)
end

-- A type's resource stopped: the definition goes, its records stay (rendered as placeholders).
Registry.onOwnerStop(TYPE_KIND, dropType)

function R.typesGen() return typesGen end

--- The public type list (no functions), sorted by category then label. Cached until a type changes.
function R.publicTypes()
    if not publicCache then
        local list = {}
        for _, t in pairs(types) do
            list[#list + 1] = {
                id = t.id, label = t.label, icon = t.icon, category = t.category, description = t.description,
                kind = t.kind, model = t.model, fields = t.fields and Schema.public(t.fields) or {},
                preview = t.preview, transform = { rotate = t.rotate }, networked = t.networked,
                limits = t.limits, parents = t.parents, version = t.version, owner = t.owner,
            }
        end
        table.sort(list, function(a, b)
            if a.category ~= b.category then return a.category < b.category end
            if a.label ~= b.label then return a.label < b.label end
            return a.id < b.id
        end)
        publicCache = list
    end
    return Utils.deepCopy(publicCache)
end

--- The model name of an element under its type (fixed model or `fields.model`), or nil.
function R.modelOf(def, el)
    if def and def.model then return def.model end
    local m = el.fields and el.fields.model
    return type(m) == 'string' and m or nil
end

--- vehicle, ped and networked props are server entities.
function R.isNetworked(def)
    return def ~= nil and (def.kind == 'vehicle' or def.kind == 'ped' or (def.kind == 'prop' and def.networked))
end

--------------------------------------------------------------------------------
-- Model validator (§52.2): one, owner-tracked; results cached until it changes
--------------------------------------------------------------------------------

--- Maps.setModelValidator(fn(kind, model) -> ok, info) — `fn = nil` clears it (its owner or core only).
function R.setModelValidator(fn)
    if fn ~= nil and not Utils.isCallable(fn) then return false end
    local caller = Registry.getCaller()
    if fn == nil then
        if not validator then return true end
        if validator.owner ~= caller and caller ~= 'core' then return false end
        validator = nil
    else
        if validator and validator.owner ~= caller then
            Log.warn('maps: %s replaces the model validator of %s', caller, validator.owner)
        end
        validator = { fn = fn, owner = caller }
    end
    Registry.untrack(VALIDATOR_KIND, 'validator')
    if validator then Registry.track(VALIDATOR_KIND, 'validator', caller) end
    modelCache, modelCacheSize = {}, 0
    return true
end

Registry.onOwnerStop(VALIDATOR_KIND, function(_, owner)
    if validator and validator.owner == owner then
        validator = nil
        modelCache, modelCacheSize = {}, 0
    end
end)

--- Only the two values the runtime uses survive: lod (integer 1..5000) and vehicleType (short word).
local function cleanInfo(info)
    if type(info) ~= 'table' then return nil end
    local lod = info.lod ~= nil and isFinite(info.lod) and math.floor(info.lod + 0.5) or nil
    if lod and (lod < 1 or lod > 5000) then lod = nil end
    local vt = info.vehicleType
    if type(vt) ~= 'string' or #vt > 16 or not vt:find('^[%a_]+$') then vt = nil end
    if not lod and not vt then return nil end
    return { lod = lod, vehicleType = vt }
end

--- The model of an element of type `def` -> true, info|nil | false, err ('model' | 'no_validator').
--- Plain props without a validator pass on the name pattern; networked kinds need one. Hides are
--- world archetypes (buildings included), so only their name pattern is checked.
function R.checkModel(def, model)
    if type(model) ~= 'string' or #model == 0 or #model > MAX_ID or not model:find(MODEL_PATTERN) then
        return false, 'model'
    end
    if def.kind == 'hide' then return true, nil end
    local networked = R.isNetworked(def)
    if not validator then
        if networked then return false, 'no_validator' end
        return true, nil
    end
    local key = def.kind .. ':' .. model
    local hit = modelCache[key]
    if not hit then
        local ok, res, info = pcall(validator.fn, def.kind, model)
        if not ok then
            Log.warn('maps: the model validator of %s failed for %s: %s', validator.owner, key, tostring(res))
            return false, 'model'
        end
        hit = { ok = res and true or false, info = res and cleanInfo(info) or nil }
        if modelCacheSize >= MAX_MODEL_CACHE then modelCache, modelCacheSize = {}, 0 end
        modelCache[key], modelCacheSize = hit, modelCacheSize + 1
    end
    if not hit.ok then return false, 'model' end
    return true, hit.info and Utils.deepCopy(hit.info) or nil
end
--------------------------------------------------------------------------------
-- Built-in types (owner core)
--------------------------------------------------------------------------------

local function modelField(kind)
    return { name = 'model', type = 'model', kinds = { kind }, required = true, label = 'Model' }
end

local BUILTIN <const> = {
    { id = 'core:prop', label = 'Prop', icon = 'box', category = 'World', kind = 'prop',
        description = 'A static object streamed by every client near it.',
        fields = { modelField('prop'),
            { name = 'collision', type = 'boolean', default = true, label = 'Collision' },
            { name = 'unbreakable', type = 'boolean', default = true, label = 'Unbreakable' } } },
    { id = 'core:physprop', label = 'Physics prop', icon = 'boxes', category = 'World', kind = 'prop',
        networked = true, description = 'A networked object with physics, created by the server.',
        fields = { modelField('prop') } },
    { id = 'core:vehicle', label = 'Vehicle', icon = 'car', category = 'World', kind = 'vehicle',
        description = 'A networked vehicle, created by the server while the map is active.',
        fields = { modelField('vehicle'),
            { name = 'plate', type = 'string', maxLength = 8, pattern = '^[%w ]*$', label = 'Plate' },
            { name = 'color', type = 'color', label = 'Colour' },
            { name = 'locked', type = 'boolean', default = false, label = 'Locked' } } },
    { id = 'core:ped', label = 'Ped', icon = 'user', category = 'World', kind = 'ped',
        description = 'A networked ped, created by the server while the map is active.',
        fields = { modelField('ped'),
            { name = 'scenario', type = 'string', maxLength = 64, pattern = '^[%w_]*$', label = 'Scenario' },
            { name = 'invincible', type = 'boolean', default = true, label = 'Invincible' },
            { name = 'frozen', type = 'boolean', default = true, label = 'Frozen' } } },
    { id = 'core:marker', label = 'Marker', icon = 'map-pin', category = 'World', kind = 'marker',
        description = 'A drawn marker (DrawMarker type 0..43).',
        fields = {
            { name = 'markerType', type = 'integer', min = 0, max = 43, default = 1, label = 'Marker type' },
            { name = 'color', type = 'color', alpha = true, default = '#E0A33AB4', label = 'Colour' },
            { name = 'scale', type = 'vector3', min = 0.01, max = 100, default = { x = 1, y = 1, z = 1 },
                label = 'Scale' },
            { name = 'drawDistance', type = 'number', min = 1, max = 500, default = 50, unit = 'm',
                label = 'Draw distance' },
            { name = 'bob', type = 'boolean', default = false, label = 'Bob up and down' },
            { name = 'faceCamera', type = 'boolean', default = false, label = 'Face the camera' } } },
    { id = 'core:hide', label = 'Hide world model', icon = 'eye-off', category = 'World', kind = 'hide',
        description = 'Hides the nearest world object of a model inside the radius.',
        fields = {
            { name = 'model', type = 'string', pattern = '^[%w_%-]+$', maxLength = 64, required = true,
                label = 'Model' },
            { name = 'radius', type = 'number', min = 0.5, max = 50, default = 2, unit = 'm', label = 'Radius' } } },
    { id = 'core:point', label = 'Point', icon = 'crosshair', category = 'Data', kind = 'point',
        description = 'A named position for scripts (not drawn in the world).',
        preview = { { kind = 'sphere', radius = 0.5 }, { kind = 'label', text = '$label' } },
        fields = { { name = 'label', type = 'string', maxLength = 64, label = 'Label' } } },
    { id = 'core:zone', label = 'Zone', icon = 'square-dashed', category = 'Data', kind = 'zone',
        description = 'A box (size + heading) for scripts (not drawn in the world).',
        preview = { { kind = 'box', size = '$size' } },
        fields = { { name = 'size', type = 'vector3', min = 0.1, max = 1000, default = { x = 4, y = 4, z = 3 },
            label = 'Size' } } },
}

for i = 1, #BUILTIN do
    local ok, err = R.defineType(BUILTIN[i])
    if not ok then Log.error('maps: built-in type %s refused: %s', BUILTIN[i].id, tostring(err)) end
end
