--[[
    core/server/maps_types.lua — Core.Maps element types, the model validator and the scene node definitions
    (DESIGN §52.1, §52.2, §55.21.1). First of the four map files (maps_types → maps_runtime → maps → maps_apply, in
    that manifest order). It creates `Core.MapsRuntime` (R), the INTERNAL table the four files share — block-listed
    from the export (server/api.lua) — and `R.state`, the in-memory documents maps.lua loads (Core.Scene reads
    `R.state.editorBuckets` for its `editors` audience and `R.checkModel` in its model-info chain).

      R.defineType(def) -> true | false, err     owner-tracked (Registry kind 'mapType'); same owner may redefine
      R.publicTypes() -> list                    Maps.types(): no functions, Schema.public fields, cached
      R.setModelValidator(fn) -> bool            one validator, owner-tracked (kind 'mapsModelValidator')
      R.checkModel(def, model) -> ok, info|err   validator results cached until the validator changes
      R.nodeDef(ctx, el) -> Scene.spawn def|nil  the §55.21.1 kind mapping (maps_runtime.lua projects with it)
      R.on(typeId, fn) / R.off(handle)           Maps.on / Maps.off: active-content events, owner-tracked
                                                 ('mapsListener'); maps_runtime.lua queues them (R.emit) and
                                                 R.flushEvents delivers them in order from one drain thread
                                                 (handlers may Wait); R.recordOf(ctx, el), R.listenerCount()
      R.modelOf(def, el), R.isNetworked(def), R.joaat(name), R.xyz(v), R.rgba(hex), R.uidOf(mapId, elementId),
      R.paintOf(uid)

    A type whose owner stops is removed; its records stay and render as editor-only placeholders
    (maps_runtime.lua re-renders them through R.refreshType, looked up at call time).
    Promotion policy of the nodes (§55.15, review RV6 F8): nothing in an editor bucket (a 'draft' context) is ever
    promoted — `authority = { mode = 'local', enter = false, damage = false }` on its props, vehicles and peds (the
    editor holds and moves local copies); a map vehicle in its target bucket gets `{ mode = 'local' }` (enter and
    damage promote it, a passer-by does not); props and peds there keep the class default.
    Built-in types (owner core): core:prop, core:physprop, core:vehicle, core:ped, core:marker,
    core:hide, core:point, core:zone.

    Natives: none (CreateThread is a runtime helper).
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
    local labelFields                           -- fields a '$field' label preview shows (map:data `f`)
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

--- vehicle, ped and networked (physics) props: what the `networked` / `networkedTotal` limits count and what
--- needs a model validator (their scene nodes can be promoted to networked entities, DESIGN §55.15).
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
-- Node definitions (§55.21.1 kind mapping) — a pure function of the element, its type and its context
--------------------------------------------------------------------------------

local DATA_KIND <const> = 'map:data'            -- point, zone, placeholder: the editor view's previews
R.DATA_KIND = DATA_KIND
local LABELS_MAX <const> = 16
local SCENE_KIND <const> = { prop = 'prop', vehicle = 'vehicle', ped = 'ped', marker = 'marker', hide = 'hide',
    point = DATA_KIND, zone = DATA_KIND }
local MARKER_COLOR <const> = '#E0A33AB4'
local AUTH_EDITOR <const> = { mode = 'local', enter = false, damage = false }   -- a draft's editor bucket
local AUTH_VEHICLE <const> = { mode = 'local' }                                 -- a map vehicle in its target bucket
local PROMOTABLE <const> = { prop = true, vehicle = true, ped = true }

local function uidOf(mapId, elementId)
    return mapId .. ':' .. elementId
end
R.uidOf = uidOf

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function vec(x, y, z)
    return { x = x, y = y, z = z }
end

--- A boolean field of the element when the type declares it, else the fallback.
local function flag(el, name, fallback)
    local v = el.fields and el.fields[name]
    if type(v) == 'boolean' then return v end
    return fallback
end

--- The values a type's '$field' label previews show: { [field] = string <= 64 } | nil.
local function labelsOf(def, el)
    local names = def and def.labelFields
    if not names then return nil end
    local f
    for i = 1, math.min(#names, LABELS_MAX) do
        local v = el.fields and el.fields[names[i]]
        local t = type(v)
        if t == 'string' or t == 'number' or t == 'boolean' then
            f = f or {}
            f[names[i]] = tostring(v):sub(1, 64)
        end
    end
    return f
end

--- A marker's fields: the element's (core:marker names), else the type's first marker preview, else defaults.
local function markerFields(def, el, out)
    local f = el.fields or {}
    local pv
    for i = 1, def.preview and #def.preview or 0 do
        if def.preview[i].kind == 'marker' then pv = def.preview[i] break end
    end
    out.type = clamp(math.tointeger(f.markerType) or (pv and pv.type) or 1, 0, 43)
    out.color = (rgba(f.color) and f.color) or (pv and rgba(pv.color) and pv.color) or MARKER_COLOR
    local sx, sy, sz = xyz(f.scale)
    if not sx and pv and type(pv.scale) == 'table' then sx, sy, sz = xyz(pv.scale) end
    if not sx and pv and isFinite(pv.scale) then sx, sy, sz = pv.scale, pv.scale, pv.scale end
    if not sx then sx, sy, sz = 1, 1, 1 end
    out.scale = vec(clamp(sx, 0.01, 100), clamp(sy, 0.01, 100), clamp(sz, 0.01, 100))
    out.drawDistance = isFinite(f.drawDistance) and clamp(f.drawDistance, 1, 500) or 50
    out.bob, out.face = flag(el, 'bob', false), flag(el, 'faceCamera', false)
end

--- The paint of a map vehicle: Scene's list (lib/scene/shared.lua Scene.PAINTS) picked by the element's UID with
--- the pure-Lua joaat (the §52 rule) — not by node id, so it is the same on every spawn, after a restart or a
--- setActive toggle, and in the editor bucket as in the target bucket. -> primary, secondary | nil
local function paintOf(uid)
    local Scene = Core.Scene
    local paints = type(Scene) == 'table' and Scene.PAINTS or nil
    if type(paints) ~= 'table' or #paints == 0 then return nil end
    local pair = paints[joaat(uid) % #paints + 1]
    return pair[1], pair[2]
end
R.paintOf = paintOf

--- A vehicle's fields. props carry the uid's paint (colorPrimary / colorSecondary: Scene then skips its node-id
--- paint) and `color` as both custom colours on top; without one the custom colours are cleared explicitly (a
--- colour an editor removed must leave the local copies too).
local function vehicleFields(def, el, out, uid)
    local f = el.fields or {}
    out.model = R.modelOf(def, el)
    if type(f.plate) == 'string' and f.plate ~= '' and #f.plate <= 8 and f.plate:find('^[%w ]+$') then
        out.plate = f.plate
    end
    out.locked, out.frozen = flag(el, 'locked', false), true
    local r, g, b = rgba(f.color)
    local props = r and { customPrimary = { r, g, b }, customSecondary = { r, g, b } }
        or { customPrimary = false, customSecondary = false }
    props.colorPrimary, props.colorSecondary = paintOf(uid)
    out.props = props
end

local function pedFields(def, el, out)
    local scenario = el.fields and el.fields.scenario
    out.model = R.modelOf(def, el)
    if type(scenario) == 'string' and scenario ~= '' and #scenario <= 64 and scenario:find('^[%w_]+$') then
        out.scenario = scenario
    end
    out.invincible, out.frozen = flag(el, 'invincible', true), flag(el, 'frozen', true)
    out.blockEvents = flag(el, 'blockEvents', true)
end

--- The Scene.spawn def of an element in a context ({ mapId, bucket, source }), or nil when there is nothing to
--- show (a model kind without a model, a hide without a model name). Unknown types are placeholders (map:data,
--- k = 'placeholder'). The promotion policy follows the context (see the header).
function R.nodeDef(ctx, el)
    local def = types[el.type]
    local kind = def and def.kind
    local uid = uidOf(ctx.mapId, el.id)
    local out, sceneKind = {}, def and SCENE_KIND[kind] or DATA_KIND
    if kind == 'prop' then
        out.model = R.modelOf(def, el)
        out.frozen, out.collision = flag(el, 'frozen', true), flag(el, 'collision', true)
        out.invincible = flag(el, 'unbreakable', false)
        if def.networked then out.physics = 'promote' end
    elseif kind == 'vehicle' then
        vehicleFields(def, el, out, uid)
    elseif kind == 'ped' then
        pedFields(def, el, out)
    elseif kind == 'marker' then
        markerFields(def, el, out)
    elseif kind == 'hide' then
        local model, radius = el.fields and el.fields.model, el.fields and el.fields.radius
        if type(model) ~= 'string' or model == '' then return nil end
        out.model, out.radius = model, isFinite(radius) and clamp(radius, 0.5, 50) or 2
    elseif kind == 'zone' then
        local sx, sy, sz = xyz(el.fields and el.fields.size)
        if not sx then sx, sy, sz = 4, 4, 3 end
        out.t, out.k = el.type, 'zone'
        out.size = vec(clamp(sx, 0.1, 1000), clamp(sy, 0.1, 1000), clamp(sz, 0.1, 1000))
        out.f = labelsOf(def, el)
    elseif kind == 'point' then
        out.t, out.k, out.f = el.type, 'point', labelsOf(def, el)
    else                                        -- a type that is not defined: an editor-only placeholder
        out.t, out.k = el.type, 'placeholder'
    end
    if sceneKind ~= DATA_KIND and sceneKind ~= 'hide' and sceneKind ~= 'marker' and type(out.model) ~= 'string' then
        return nil
    end
    out.mapEl, out.mapType = uid, el.type
    local authority
    if ctx.source == 'draft' then
        authority = PROMOTABLE[sceneKind] and AUTH_EDITOR or nil
    elseif sceneKind == 'vehicle' then
        authority = AUTH_VEHICLE
    end
    local p, r = el.pos, el.rot
    return { kind = sceneKind, bucket = ctx.bucket, persist = false, pos = vec(p.x, p.y, p.z),
        rot = vec(r.x, r.y, r.z), fields = out, audience = sceneKind == DATA_KIND and { editors = true } or nil,
        authority = authority }
end

--------------------------------------------------------------------------------
-- Events of active content (Maps.on / Maps.off): maps_runtime.lua emits them per context, one drain delivers
--------------------------------------------------------------------------------

local LISTENER_KIND <const> = 'mapsListener'
local MAX_LISTENERS <const> = 512

local listeners = {}        -- [handle] = { handle, seq, typeId, fn, owner }
local listenerCount, listenerSeq = 0, 0
local listenedTypes = {}    -- [typeId|'*'] = number of listeners
local eventQueue, eventHead, draining = {}, 1, false

function R.recordOf(ctx, el)
    local uid = uidOf(ctx.mapId, el.id)
    return { uid = uid, key = ctx.bucket .. '|' .. uid, mapId = ctx.mapId, id = el.id, type = el.type,
        pos = el.pos, rot = el.rot, fields = el.fields, layer = el.layer, bucket = ctx.bucket,
        editor = ctx.source == 'draft' }
end

--- Queued only: flushEvents() starts the drain once the caller finished its pass, so a listener that
--- calls back into Core.Maps never runs in the middle of a context update.
function R.emit(event, ctx, el)
    if listenerCount == 0 or not (listenedTypes[el.type] or listenedTypes['*']) then return end
    eventQueue[#eventQueue + 1] = { event = event, record = R.recordOf(ctx, el), mapId = ctx.mapId, typeId = el.type }
end

local function deliver(item)
    local list = {}
    for _, l in pairs(listeners) do
        if l.typeId == item.typeId or l.typeId == '*' then list[#list + 1] = l end
    end
    table.sort(list, function(a, b) return a.seq < b.seq end)
    for i = 1, #list do
        local l = list[i]
        if listeners[l.handle] == l then
            local ok, err = pcall(l.fn, item.event, Utils.deepCopy(item.record), item.mapId)
            if not ok then Log.warn('maps: listener of %s failed on %s: %s', l.owner, item.event, tostring(err)) end
        end
    end
end

function R.flushEvents()
    if draining or eventHead > #eventQueue then return end
    draining = true
    -- one drain thread at a time, ending when the queue is empty; listeners may Wait
    -- fxlint-disable-next-line P004
    CreateThread(function()
        while eventHead <= #eventQueue do
            local item = eventQueue[eventHead]
            eventQueue[eventHead] = nil
            eventHead = eventHead + 1
            deliver(item)
        end
        eventQueue, eventHead, draining = {}, 1, false
    end)
end

--- Maps.on(typeId|'*', fn(event, record, mapId)) -> handle|nil. Owner-swept; seed with Maps.records.
function R.on(typeId, fn)
    if typeId ~= '*' and (type(typeId) ~= 'string' or #typeId > 64 or not typeId:find('^[%w_%-]+:[%w_%-]+$')) then
        return nil
    end
    if not Utils.isCallable(fn) or listenerCount >= MAX_LISTENERS then return nil end
    listenerSeq = listenerSeq + 1
    local handle = 'maps:on:' .. listenerSeq
    local owner = Registry.getCaller()
    listeners[handle] = { handle = handle, seq = listenerSeq, typeId = typeId, fn = fn, owner = owner }
    listenerCount = listenerCount + 1
    listenedTypes[typeId] = (listenedTypes[typeId] or 0) + 1
    Registry.track(LISTENER_KIND, handle, owner)
    return handle
end

local function dropListener(handle)
    local l = listeners[handle]
    if not l then return false end
    listeners[handle] = nil
    listenerCount = listenerCount - 1
    local n = listenedTypes[l.typeId] - 1
    listenedTypes[l.typeId] = n > 0 and n or nil
    Registry.untrack(LISTENER_KIND, handle)
    return true
end

--- Maps.off(handle) -> bool (its owner or core).
function R.off(handle)
    local l = type(handle) == 'string' and listeners[handle]
    if not l then return false end
    local caller = Registry.getCaller()
    if caller ~= l.owner and caller ~= 'core' then return false end
    return dropListener(handle)
end

Registry.onOwnerStop(LISTENER_KIND, dropListener)

function R.listenerCount() return listenerCount end

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
        networked = true, description = 'An object with physics: networked once something hits it.',
        fields = { modelField('prop') } },
    { id = 'core:vehicle', label = 'Vehicle', icon = 'car', category = 'World', kind = 'vehicle',
        description = 'A parked vehicle: networked once a player enters or hits it.',
        fields = { modelField('vehicle'),
            { name = 'plate', type = 'string', maxLength = 8, pattern = '^[%w ]*$', label = 'Plate' },
            { name = 'color', type = 'color', label = 'Colour' },
            { name = 'locked', type = 'boolean', default = false, label = 'Locked' } } },
    { id = 'core:ped', label = 'Ped', icon = 'user', category = 'World', kind = 'ped',
        description = 'A ped streamed by every client near it while the map is active.',
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
