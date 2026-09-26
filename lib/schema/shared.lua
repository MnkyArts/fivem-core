--[[
    core / lib/schema/shared.lua  —  Core.Schema (DESIGN §43)

    One typed field vocabulary for settings (§45), admin action arguments (§51) and map element
    fields (§52), so one kit form renderer serves all three. Pure Lua, no natives: it is compiled
    into every VM that touches `Core.Schema` (lazy lib, import.lua).

      Schema.field(def)                  -> field|nil, err      normalised copy of one definition
      Schema.fields(list)                -> fields|nil, err     1..64 named fields, unique names
      Schema.check(field, value)         -> ok, valueOrErr      one value; never coerces types
      Schema.checkAll(fields, values, { partial = false }) -> ok, out|errs   errs = { [name] = err }
      Schema.default(field)              -> deep copy of the default (or nil)
      Schema.public(fields)              -> JSON-safe array for the UI (no functions, secret defaults removed)

    `validate` (a callable, server side: `fn(value, all) -> ok, err`) never lives in the field table:
    it is kept in a private weak-keyed slot, so a field can be JSON-encoded and `public` cannot leak it.
    Value errors are short machine strings: 'required', 'type', 'min', 'max', 'step', 'pattern',
    'option', 'length', 'items', 'unknown', 'custom:<text>'. A nested error carries its path:
    '<index|name>.<err>' (e.g. '2.reason.length'). Definition errors name the offending key
    ('type', 'min', 'options', 'depth', 'default:<err>', '<name>.<err>' inside a list, ...).

    Natives: none.
]]

local ns = ...

local type, pairs, ipairs, tostring, pcall = type, pairs, ipairs, tostring, pcall
local mathType, floor, abs, huge = math.type, math.floor, math.abs, math.huge
local find = string.find

local MAX_FIELDS <const> = 64
local MAX_DEPTH <const> = 4
local MAX_OPTIONS <const> = 200
local MAX_ITEMS <const> = 1000
local MAX_TEMPLATES <const> = 32
local MAX_PRESETS <const> = 12
local MAX_UNKNOWN <const> = 16          -- unknown keys reported per checkAll / object, then it stops
local STRING_MAX_DEFAULT <const> = 256
local STRING_CAP <const> = 4096
local REASON_MIN_DEFAULT <const> = 3
local PATTERN_MAX <const> = 256
local NAME_PATTERN <const> = '^[%a_][%w_]*$'
local NAME_MAX <const> = 48
local ID_PATTERN <const> = '^[%w_%-]+$'
local REF_PATTERN <const> = '^[%w_%-:]+$'
local REFTYPE_PATTERN <const> = '^[%w_%-%.:]+$'
local ID_MAX <const> = 64
local PLAYER_MAX <const> = 65535
local WORLD_XY <const> = 10000
local WORLD_Z_MIN <const> = -1000
local WORLD_Z_MAX <const> = 3000
local CUSTOM_MAX <const> = 128
local KEY_LABEL_MAX <const> = 48
local STEP_EPS <const> = 1e-9
local MAX_SAFE_FLOAT <const> = 2 ^ 53     -- floats above this are not exact integers any more

local TEXT_KEYS <const> = {             -- common text keys and their length caps, checked in this order
    { 'label', 128 }, { 'description', 1024 }, { 'placeholder', 128 }, { 'group', 64 }, { 'unit', 32 },
    { 'icon', 32 },                     -- UI only (CoreSchemaForm), never read by check
}
local FLAG_KEYS <const> = { 'required', 'hidden', 'readonly', 'secret' }
local MODEL_KINDS <const> = { prop = true, vehicle = true, ped = true, weapon = true }

-- Private slots (weak keys: a dropped field takes its entries with it).
local validators = setmetatable({}, { __mode = 'k' })   -- field -> callable `validate`
local normalized = setmetatable({}, { __mode = 'k' })   -- field -> true (made by this lib)
local listIndex = setmetatable({}, { __mode = 'k' })    -- normalised list -> { [name] = field }
local optionSets = setmetatable({}, { __mode = 'k' })   -- enum field -> { [value] = true }

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function isFinite(v)
    return type(v) == 'number' and v == v and v ~= huge and v ~= -huge
end

--- An integer, or a float with no fraction that is exactly representable (|v| <= 2^53) and so converts
--- with math.tointeger. Larger floats are refused: a consumer that formats with %d would throw on them.
local function isWhole(v)
    if mathType(v) == 'integer' then return true end
    return isFinite(v) and v % 1 == 0 and abs(v) <= MAX_SAFE_FLOAT and math.tointeger(v) ~= nil
end

--- Only ever called after isWhole: always an integer subtype.
local function toWhole(v)
    return math.tointeger(v)
end

local function isScalar(v)
    local t = type(v)
    return t == 'string' or t == 'boolean' or isFinite(v)
end

--- Plain function or a table/userdata with __call — a function passed through the export hop arrives
--- as a callable table (AGENTS §3), so `type(v) == 'function'` alone would be a bug.
local function isCallable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    local mt = getmetatable(v)
    return type(mt) == 'table' and mt.__call ~= nil
end

local function isName(v)
    return type(v) == 'string' and #v <= NAME_MAX and find(v, NAME_PATTERN) ~= nil
end

local function isCount(v, lo, hi)
    return isWhole(v) and v >= lo and v <= hi
end

--- Deep copy of plain data (defaults, option lists). Vectors pass by value like any non-table.
local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, value in pairs(v) do out[k] = copy(value) end
    return out
end

--- Length of a proper sequence (keys exactly 1..n, n <= max), or nil + 'type'|'items'.
--- Counting stops at max + 1, so a hostile payload with a million keys costs max + 1 steps.
local function sequenceLength(t, max)
    local n = 0
    for k in pairs(t) do
        n = n + 1
        if n > max then return nil, 'items' end
        if mathType(k) ~= 'integer' or k < 1 then return nil, 'type' end
    end
    for i = 1, n do
        if t[i] == nil then return nil, 'type' end
    end
    return n
end

--- A printable, bounded label for a key that came from a payload.
local function keyLabel(k)
    local s = tostring(k)
    if #s > KEY_LABEL_MAX then s = s:sub(1, KEY_LABEL_MAX) end
    return s
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--------------------------------------------------------------------------------
-- Definitions: per-type keys (DESIGN §43 table)
--------------------------------------------------------------------------------

local normalizeField, normalizeList, checkInner   -- mutually recursive, defined below

--- min/max/step shared by integer and number: finite, min <= max, step > 0.
local function defineRange(def, f)
    for _, key in ipairs({ 'min', 'max' }) do
        local v = def[key]
        if v ~= nil then
            if not isFinite(v) then return key end
            f[key] = v
        end
    end
    if f.min and f.max and f.min > f.max then return 'max' end
    if def.step ~= nil then
        if not isFinite(def.step) or def.step <= 0 then return 'step' end
        f.step = def.step
    end
    return nil
end

--- minLength/maxLength/pattern/patternMessage for the string family.
local function defineString(def, f, minDefault)
    local minLength, maxLength = def.minLength, def.maxLength
    if minLength ~= nil and not isCount(minLength, 0, STRING_CAP) then return 'minLength' end
    if maxLength ~= nil and not isCount(maxLength, 1, STRING_CAP) then return 'maxLength' end
    f.minLength = toWhole(minLength or minDefault)
    f.maxLength = toWhole(maxLength or STRING_MAX_DEFAULT)
    if f.minLength > f.maxLength then return 'minLength' end
    if def.pattern ~= nil then
        local pattern = def.pattern
        if type(pattern) ~= 'string' or #pattern == 0 or #pattern > PATTERN_MAX then return 'pattern' end
        if not pcall(find, '', pattern) then return 'pattern' end   -- a malformed Lua pattern throws
        f.pattern = pattern
    end
    if def.patternMessage ~= nil then
        if type(def.patternMessage) ~= 'string' or #def.patternMessage > 256 then return 'patternMessage' end
        f.patternMessage = def.patternMessage
    end
    return nil
end

--- minItems/maxItems (enum with multiple = true, array).
local function defineItems(def, f, cap)
    if def.minItems ~= nil and not isCount(def.minItems, 0, cap) then return 'minItems' end
    if def.maxItems ~= nil and not isCount(def.maxItems, 0, cap) then return 'maxItems' end
    f.minItems = def.minItems and toWhole(def.minItems) or nil
    f.maxItems = toWhole(def.maxItems or cap)
    if f.minItems and f.minItems > f.maxItems then return 'minItems' end
    return nil
end

local function defineOptions(def, f)
    local options = def.options
    if type(options) ~= 'table' then return 'options' end
    local n = sequenceLength(options, MAX_OPTIONS)
    if not n or n < 1 then return 'options' end
    local out, set = {}, {}
    for i = 1, n do
        local o = options[i]
        local entry
        if type(o) == 'table' then
            if not isScalar(o.value) then return 'options' end
            if o.label ~= nil and (type(o.label) ~= 'string' or #o.label > 128) then return 'options' end
            if o.description ~= nil and (type(o.description) ~= 'string' or #o.description > 512) then
                return 'options'
            end
            if o.icon ~= nil and (type(o.icon) ~= 'string' or #o.icon > 32) then return 'options' end
            entry = {
                value = o.value, label = o.label or tostring(o.value), description = o.description, icon = o.icon,
            }
        elseif isScalar(o) then
            entry = { value = o, label = tostring(o) }
        else
            return 'options'
        end
        if set[entry.value] then return 'options' end      -- duplicate value
        set[entry.value] = true
        out[i] = entry
    end
    f.options = out
    optionSets[f] = set
    if def.multiple ~= nil then
        if type(def.multiple) ~= 'boolean' then return 'multiple' end
        f.multiple = def.multiple
    end
    if f.multiple then return defineItems(def, f, n) end
    return nil
end

local function defineStringArray(list, max, itemMax, allowed)
    if type(list) ~= 'table' then return nil end
    local n = sequenceLength(list, max)
    if not n then return nil end
    local out, seen = {}, {}
    for i = 1, n do
        local s = list[i]
        if type(s) ~= 'string' or #s == 0 or #s > itemMax then return nil end
        if allowed and not allowed[s] then return nil end
        if seen[s] then return nil end
        seen[s] = true
        out[i] = s
    end
    return out
end

local DEFINE = {}

DEFINE.boolean = function() return nil end
DEFINE.number = function(def, f) return defineRange(def, f) end
DEFINE.integer = DEFINE.number
DEFINE.string = function(def, f) return defineString(def, f, 0) end
--- `rows` (UI only): the textarea height, 2..20.
DEFINE.text = function(def, f)
    if def.rows ~= nil then
        if not isCount(def.rows, 2, 20) then return 'rows' end
        f.rows = toWhole(def.rows)
    end
    return defineString(def, f, 0)
end
DEFINE.password = DEFINE.string

DEFINE.reason = function(def, f)
    local err = defineString(def, f, REASON_MIN_DEFAULT)
    if err then return err end
    if def.templates ~= nil then
        f.templates = defineStringArray(def.templates, MAX_TEMPLATES, 256)
        if not f.templates then return 'templates' end
    end
    return nil
end

DEFINE.enum = defineOptions

DEFINE.array = function(def, f, depth)
    if def.items == nil then return 'items' end
    local items, err = normalizeField(def.items, depth + 1)
    if not items then return 'items.' .. err end
    f.items = items
    return defineItems(def, f, MAX_ITEMS)
end

DEFINE.object = function(def, f, depth)
    if def.fields == nil then return 'fields' end
    local fields, err = normalizeList(def.fields, depth + 1)
    if not fields then return 'fields.' .. err end
    f.fields = fields
    return nil
end

DEFINE.color = function(def, f)
    if def.alpha ~= nil then
        if type(def.alpha) ~= 'boolean' then return 'alpha' end
        f.alpha = def.alpha
    end
    return nil
end

DEFINE.duration = function(def, f)
    if def.allowPermanent ~= nil then
        if type(def.allowPermanent) ~= 'boolean' then return 'allowPermanent' end
        f.allowPermanent = def.allowPermanent
    end
    for _, key in ipairs({ 'min', 'max' }) do
        local v = def[key]
        if v ~= nil then
            if not isWhole(v) or v < 0 then return key end
            f[key] = toWhole(v)
        end
    end
    if f.min and f.max and f.min > f.max then return 'max' end
    -- `presets` (UI only): up to 12 quick picks in seconds; each must be a value check would accept
    -- (0 only with allowPermanent, the others inside min/max)
    if def.presets ~= nil then
        local list = def.presets
        if type(list) ~= 'table' then return 'presets' end
        local n = sequenceLength(list, MAX_PRESETS)
        if not n then return 'presets' end
        local out = {}
        for i = 1, n do
            local v = list[i]
            if not isWhole(v) or v < 0 then return 'presets' end
            v = toWhole(v)
            if v == 0 then
                if not f.allowPermanent then return 'presets' end
            elseif (f.min and v < f.min) or (f.max and v > f.max) then
                return 'presets'
            end
            out[i] = v
        end
        f.presets = out
    end
    return nil
end

DEFINE.vector3 = function(def, f)
    local err = defineRange(def, f)
    if err then return err end
    if f.step then return 'step' end        -- per-component grids are not part of the vocabulary
    if def.world ~= nil then
        if type(def.world) ~= 'boolean' then return 'world' end
        f.world = def.world
    end
    return nil
end

DEFINE.heading = function() return nil end
DEFINE.rotation = function() return nil end
DEFINE.player = function() return nil end
DEFINE.faction = function() return nil end
DEFINE.item = function() return nil end

DEFINE.model = function(def, f)
    if def.kinds ~= nil then
        f.kinds = defineStringArray(def.kinds, 4, 16, MODEL_KINDS)
        if not f.kinds or #f.kinds == 0 then return 'kinds' end
    end
    return nil
end

DEFINE.ref = function(def, f)
    if def.refType ~= nil then
        local t = def.refType
        if type(t) ~= 'string' or #t > ID_MAX or not find(t, REFTYPE_PATTERN) then return 'refType' end
        f.refType = t
    end
    return nil
end

--------------------------------------------------------------------------------
-- Definitions: common keys, one field, a list
--------------------------------------------------------------------------------

--- { field = 'x', equals = v } | { field = 'x', ['in'] = { scalars } }
local function defineVisible(vw)
    if type(vw) ~= 'table' or not isName(vw.field) then return nil end
    local out = { field = vw.field }
    if vw.equals ~= nil then
        if not isScalar(vw.equals) then return nil end
        out.equals = vw.equals
    elseif vw['in'] ~= nil then
        local list = vw['in']
        if type(list) ~= 'table' then return nil end
        local n = sequenceLength(list, MAX_OPTIONS)
        if not n or n < 1 then return nil end
        local values = {}
        for i = 1, n do
            if not isScalar(list[i]) then return nil end
            values[i] = list[i]
        end
        out['in'] = values
    else
        return nil
    end
    return out
end

--- Copies only the keys the vocabulary knows; unknown keys are dropped, never passed through.
-- fxlint-disable-next-line C003 -- normalizeField is the forward-declared local of the Definitions block
normalizeField = function(def, depth)
    if depth > MAX_DEPTH then return nil, 'depth' end
    if type(def) ~= 'table' then return nil, 'field' end
    local kind = def.type
    local define = type(kind) == 'string' and DEFINE[kind]
    if not define then return nil, 'type' end
    local f = { type = kind }
    if def.name ~= nil then
        if not isName(def.name) then return nil, 'name' end
        f.name = def.name
    end
    for i = 1, #TEXT_KEYS do
        local key, max = TEXT_KEYS[i][1], TEXT_KEYS[i][2]
        local v = def[key]
        if v ~= nil then
            if type(v) ~= 'string' or #v > max then return nil, key end
            f[key] = v
        end
    end
    for i = 1, #FLAG_KEYS do
        local key = FLAG_KEYS[i]
        local v = def[key]
        if v ~= nil then
            if type(v) ~= 'boolean' then return nil, key end
            f[key] = v
        end
    end
    if def.order ~= nil then
        if not isFinite(def.order) then return nil, 'order' end
        f.order = def.order
    end
    if def.persistDefault ~= nil and type(def.persistDefault) ~= 'boolean' then return nil, 'persistDefault' end
    f.persistDefault = def.persistDefault ~= false
    if def.visibleWhen ~= nil then
        f.visibleWhen = defineVisible(def.visibleWhen)
        if not f.visibleWhen then return nil, 'visibleWhen' end
    end
    local validate = def.validate
    if validate == nil then validate = validators[def] end    -- re-normalising a field keeps its slot
    if validate ~= nil then
        if not isCallable(validate) then return nil, 'validate' end
        validators[f] = validate
    end
    local err = define(def, f, depth)
    if err then return nil, err end
    if def.default ~= nil then
        -- built-in checks only: a plugin's validate is not run for its own default
        local ok, value = checkInner(f, def.default, false, false)
        if not ok then return nil, 'default:' .. value end
        f.default = value
    end
    normalized[f] = true
    return f
end

--- 1..64 fields, every one named, names unique, visibleWhen pointing at a sibling.
-- fxlint-disable-next-line C003 -- normalizeList is the forward-declared local of the Definitions block
normalizeList = function(list, depth)
    if type(list) ~= 'table' then return nil, 'count' end
    local n = sequenceLength(list, MAX_FIELDS)
    if not n or n < 1 then return nil, 'count' end
    local out, byName = {}, {}
    for i = 1, n do
        local def = list[i]
        local f, err = normalizeField(def, depth)
        if not f then
            local label = (type(def) == 'table' and isName(def.name)) and def.name or tostring(i)
            return nil, label .. '.' .. err
        end
        if not f.name then return nil, tostring(i) .. '.name' end
        if byName[f.name] then return nil, 'duplicate:' .. f.name end
        byName[f.name] = f
        out[i] = f
    end
    for i = 1, n do
        local vw = out[i].visibleWhen
        if vw and (vw.field == out[i].name or not byName[vw.field]) then
            return nil, out[i].name .. '.visibleWhen'
        end
    end
    listIndex[out] = byName
    return out
end

--- A normalised field (made here), or the result of normalising `f`.
local function asField(f)
    if type(f) == 'table' and normalized[f] then return f end
    return normalizeField(f, 0)
end

--- A normalised list (made here) and its name index, or the result of normalising `list`.
local function asList(list)
    if type(list) == 'table' and listIndex[list] then return list, listIndex[list] end
    local out, err = normalizeList(list, 0)
    if not out then return nil, err end
    return out, listIndex[out]
end

--------------------------------------------------------------------------------
-- Values: built-in checks per type (type -> range/pattern), then the custom validator
--------------------------------------------------------------------------------

--- Runs the private `validate` of `f`: true, or false + 'custom:<text>'. Never throws.
local function runCustom(f, value, all)
    local fn = validators[f]
    if not fn or value == nil then return true end
    local ok, res, msg = pcall(fn, value, all)
    if not ok then return false, 'custom:error' end
    if res then return true end
    local text = type(msg) == 'string' and msg or 'invalid'
    if #text > CUSTOM_MAX then text = text:sub(1, CUSTOM_MAX) end
    return false, 'custom:' .. text
end

local function checkRange(f, v)
    if f.min and v < f.min then return false, 'min' end
    if f.max and v > f.max then return false, 'max' end
    if f.step then
        local q = (v - (f.min or 0)) / f.step
        if abs(q - floor(q + 0.5)) > STEP_EPS * math.max(1, abs(q)) then return false, 'step' end
    end
    return true, v
end

local function checkLength(f, s, n)
    if n < f.minLength or #s > f.maxLength then return false, 'length' end
    if f.pattern and not find(s, f.pattern) then return false, 'pattern' end
    return true, s
end

local function checkId(v, pattern)
    if type(v) ~= 'string' then return false, 'type' end
    if #v > ID_MAX then return false, 'length' end
    if not find(v, pattern) then return false, 'pattern' end
    return true, v
end

--- x, y, z of a vector3 or of a table holding exactly those three keys, all finite; nil otherwise.
local function xyz(v)
    local t = type(v)
    if t == 'vector3' then
        if isFinite(v.x) and isFinite(v.y) and isFinite(v.z) then return v.x, v.y, v.z end
        return nil
    end
    if t ~= 'table' then return nil end
    for k in pairs(v) do
        if k ~= 'x' and k ~= 'y' and k ~= 'z' then return nil end
    end
    if isFinite(v.x) and isFinite(v.y) and isFinite(v.z) then return v.x, v.y, v.z end
    return nil
end

--- Is `f` shown given the sibling values? A hidden field is never `required`.
local function isVisible(f, values, byName)
    local vw = f.visibleWhen
    if not vw then return true end
    local other = values[vw.field]
    if other == nil then
        local sibling = byName[vw.field]
        other = sibling and sibling.default
    end
    if vw.equals ~= nil then return other == vw.equals end
    local list = vw['in']
    for i = 1, #list do
        if list[i] == other then return true end
    end
    return false
end

--- Checks every field of a list against `values`. partial: only the given keys, no required, no
--- defaults. Returns out, errs, count (errs is nil when nothing failed).
local function checkFields(fields, byName, values, custom, partial)
    local out, errs, unknown = {}, nil, 0
    for k in pairs(values) do
        if type(k) ~= 'string' or not byName[k] then
            errs = errs or {}
            errs[keyLabel(k)] = 'unknown'
            unknown = unknown + 1
            if unknown >= MAX_UNKNOWN then return out, errs end
        end
    end
    for i = 1, #fields do
        local f = fields[i]
        local name = f.name
        local v = values[name]
        if v == nil and not partial and f.default ~= nil and f.persistDefault then v = copy(f.default) end
        if v ~= nil or not partial then
            local skipRequired = partial or not isVisible(f, values, byName)
            local ok, res = checkInner(f, v, custom, skipRequired)
            if ok then
                out[name] = res
            else
                errs = errs or {}
                errs[name] = res
            end
        end
    end
    if custom and not errs then
        for i = 1, #fields do
            local f = fields[i]
            local ok, err = runCustom(f, out[f.name], out)
            if not ok then
                errs = errs or {}
                errs[f.name] = err
            end
        end
    end
    return out, errs
end

--- The first error of an errs map, in field order, as '<name>.<err>' (object values).
local function firstError(fields, errs)
    for i = 1, #fields do
        local err = errs[fields[i].name]
        if err then return fields[i].name .. '.' .. err end
    end
    local k, err = next(errs)
    return k .. '.' .. err
end

local CHECK = {}

CHECK.boolean = function(_, v)
    if type(v) ~= 'boolean' then return false, 'type' end
    return true, v
end

CHECK.number = function(f, v)
    if not isFinite(v) then return false, 'type' end
    return checkRange(f, v)
end

CHECK.integer = function(f, v)
    if not isWhole(v) then return false, 'type' end
    return checkRange(f, toWhole(v))
end

CHECK.string = function(f, v)
    if type(v) ~= 'string' then return false, 'type' end
    return checkLength(f, v, #v)
end
CHECK.text = CHECK.string
CHECK.password = CHECK.string

--- A reason of three spaces is no reason: the minimum counts the trimmed text (the value is kept as is).
CHECK.reason = function(f, v)
    if type(v) ~= 'string' then return false, 'type' end
    return checkLength(f, v, #trim(v))
end

CHECK.enum = function(f, v)
    local set = optionSets[f]
    if not f.multiple then
        if not isScalar(v) then return false, 'type' end
        if not set[v] then return false, 'option' end
        return true, v
    end
    if type(v) ~= 'table' then return false, 'type' end
    local n, err = sequenceLength(v, f.maxItems)
    if not n then return false, err end
    if f.minItems and n < f.minItems then return false, 'items' end
    local out, seen = {}, {}
    for i = 1, n do
        local item = v[i]
        if not isScalar(item) then return false, 'type' end
        if not set[item] or seen[item] then return false, 'option' end
        seen[item] = true
        out[i] = item
    end
    return true, out
end

CHECK.array = function(f, v, custom)
    if type(v) ~= 'table' then return false, 'type' end
    local n, err = sequenceLength(v, f.maxItems)
    if not n then return false, err end
    if f.minItems and n < f.minItems then return false, 'items' end
    local items, out = f.items, {}
    for i = 1, n do
        local ok, res = checkInner(items, v[i], custom, false)
        if not ok then return false, i .. '.' .. res end
        out[i] = res
    end
    if custom then
        for i = 1, n do
            local ok, res = runCustom(items, out[i], out)
            if not ok then return false, i .. '.' .. res end
        end
    end
    return true, out
end

--- A table with exactly the declared keys: an undeclared key is refused, a missing one is only
--- refused when it is required (defaults are filled like checkAll's).
CHECK.object = function(f, v, custom)
    if type(v) ~= 'table' then return false, 'type' end
    local fields = f.fields
    local out, errs = checkFields(fields, listIndex[fields], v, custom, false)
    if errs then return false, firstError(fields, errs) end
    return true, out
end

CHECK.color = function(f, v)
    if type(v) ~= 'string' then return false, 'type' end
    if find(v, '^#%x%x%x%x%x%x$') then return true, v end
    if f.alpha and find(v, '^#%x%x%x%x%x%x%x%x$') then return true, v end
    return false, 'pattern'
end

--- Integer seconds >= 0. 0 is "permanent" and passes whenever allowPermanent is set; min/max bound
--- every other value (a field that must never be 0 without allowPermanent sets min = 1).
CHECK.duration = function(f, v)
    if not isWhole(v) then return false, 'type' end
    v = toWhole(v)
    if v < 0 then return false, 'min' end
    if v == 0 and f.allowPermanent then return true, v end
    if f.min and v < f.min then return false, 'min' end
    if f.max and v > f.max then return false, 'max' end
    return true, v
end

CHECK.vector3 = function(f, v)
    local x, y, z = xyz(v)
    if not x then return false, 'type' end
    if f.world then
        if x < -WORLD_XY or y < -WORLD_XY or z < WORLD_Z_MIN then return false, 'min' end
        if x > WORLD_XY or y > WORLD_XY or z > WORLD_Z_MAX then return false, 'max' end
    end
    if f.min and (x < f.min or y < f.min or z < f.min) then return false, 'min' end
    if f.max and (x > f.max or y > f.max or z > f.max) then return false, 'max' end
    return true, { x = x, y = y, z = z }
end

CHECK.heading = function(_, v)
    if not isFinite(v) then return false, 'type' end
    return true, v % 360
end

CHECK.rotation = function(_, v)
    local x, y, z = xyz(v)
    if not x then return false, 'type' end
    return true, { x = x, y = y, z = z }
end

CHECK.model = function(_, v) return checkId(v, ID_PATTERN) end
CHECK.faction = CHECK.model
CHECK.item = CHECK.model
CHECK.ref = function(_, v) return checkId(v, REF_PATTERN) end

CHECK.player = function(_, v)
    if not isWhole(v) then return false, 'type' end
    v = toWhole(v)
    if v < 1 then return false, 'min' end
    if v > PLAYER_MAX then return false, 'max' end
    return true, v
end

--- required → type → range/pattern, nested containers included (their children's custom validators
--- run inside with the container as `all`). The field's OWN validate is the caller's job (runCustom).
-- fxlint-disable-next-line C003 -- checkInner is the forward-declared local of the Definitions block
checkInner = function(f, v, custom, skipRequired)
    if v == nil or v == '' then
        if f.required and not skipRequired then return false, 'required' end
        if v == nil then return true, nil end
    end
    return CHECK[f.type](f, v, custom)
end

--------------------------------------------------------------------------------
-- Public API (DESIGN §43)
--------------------------------------------------------------------------------

--- Normalise one definition: a copy with only the vocabulary's keys; `validate` goes to a private slot.
---@param def table
---@return table|nil field, string|nil err
function ns.field(def)
    return normalizeField(def, 0)
end

--- Normalise a list of 1..64 named fields with unique names.
---@param list table[]
---@return table[]|nil fields, string|nil err
function ns.fields(list)
    return normalizeList(list, 0)
end

--- Validate one value: type → range/pattern → custom validate. Never coerces a type; the returned
--- value is normalised (a fresh table for tables, heading in [0, 360), integers as integers).
---@return boolean ok, any valueOrErr
function ns.check(field, value)
    local f, err = asField(field)
    if not f then return false, 'schema:' .. err end
    local ok, res = checkInner(f, value, true, false)
    if not ok then return false, res end
    local okCustom, customErr = runCustom(f, res, nil)
    if not okCustom then return false, customErr end
    return true, res
end

--- Validate a whole value table. Unknown keys are refused ('unknown'); a missing field gets its default
--- (unless persistDefault = false) or 'required'. `partial = true` checks only the keys present.
--- A non-table `values` fails as errs['*'] = 'type'.
---@return boolean ok, table outOrErrs
function ns.checkAll(fields, values, opts)
    local list, byName = asList(fields)
    if not list then return false, { ['*'] = 'schema:' .. byName } end
    if values == nil then values = {} end
    if type(values) ~= 'table' then return false, { ['*'] = 'type' } end
    local partial = type(opts) == 'table' and opts.partial == true
    local out, errs = checkFields(list, byName, values, true, partial)
    if errs then return false, errs end
    return true, out
end

--- Deep copy of the field's (normalised) default, or nil.
function ns.default(field)
    local f = asField(field)
    if not f then return nil end
    return copy(f.default)
end

local function publicField(f)
    local out = {}
    for k, v in pairs(f) do
        if k == 'fields' then
            local list = {}
            for i = 1, #v do list[i] = publicField(v[i]) end
            out.fields = list
        elseif k == 'items' then
            out.items = publicField(v)
        elseif k ~= 'default' or not f.secret then
            out[k] = copy(v)
        end
    end
    return out
end

--- JSON-safe array for the UI: no functions (they never are in a field), secret defaults removed.
--- Takes a list (normalised or raw) or a single field, which comes back as a one-element array.
---@return table[]|nil fields, string|nil err
function ns.public(fields)
    if type(fields) ~= 'table' then return nil, 'count' end
    if type(fields.type) == 'string' then
        local f, err = asField(fields)
        if not f then return nil, err end
        return { publicField(f) }
    end
    local list, err = asList(fields)
    if not list then return nil, err end
    local out = {}
    for i = 1, #list do out[i] = publicField(list[i]) end
    return out
end
