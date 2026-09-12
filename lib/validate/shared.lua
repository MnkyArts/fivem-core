--[[
    core / lib/validate/shared.lua  —  Core.Validate (DESIGN §3.3)

    The one input validator. Pure Lua, no natives, never throws: every entry
    point returns `ok:boolean, err:string|nil` instead of raising, so it is safe
    to call directly on untrusted network payloads.

    Loaded as a lib chunk: `local ns = ...` is the namespace table (Core.Validate).
]]

local ns = ...

local DEFAULT_ARRAY_MAX <const> = 1000   -- bounds work when a spec has no `max`
local DEFAULT_TABLE_MAX <const> = 256    -- bounds work when a table spec has no `max`
local ID_PATTERN <const> = '^[%w_%-:]+$'
local ID_MAX <const> = 64
local MAX_VALUE_CHARS <const> = 32       -- of an offending value quoted in an error
local EMPTY <const> = {}                 -- read-only stand-in for string specs

-- Table specs are normalised once and memoised (weak keys): `min`/`max` are
-- coerced with `tonumber`, and a non-numeric bound makes the whole spec invalid
-- instead of throwing later on a number-vs-string comparison.
local normalised = setmetatable({}, { __mode = 'k' })

local checkers = {}

local function isFinite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

--- Short, log-safe rendering of an offending value. Client input ends up in
--- logs and in `onReject`, so control characters and `^n` console colour codes
--- are stripped before the value is truncated.
local function shortValue(v)
    local t = type(v)
    if t == 'string' then
        local clean = (v:gsub('%c', ' '))
        clean = (clean:gsub('%^%d', ''))
        if #clean > MAX_VALUE_CHARS then return ('"%s..."'):format(clean:sub(1, MAX_VALUE_CHARS)) end
        return ('"%s"'):format(clean)
    elseif t == 'number' or t == 'boolean' or t == 'nil' then
        return tostring(v)
    end
    return t
end

local function rangeSuffix(spec)
    local min, max = spec.min, spec.max
    if min and max then return (' %s..%s'):format(min, max) end
    if min then return (' >= %s'):format(min) end
    if max then return (' <= %s'):format(max) end
    return ''
end

--- Normalise a table spec once: copy it, coerce `min`/`max`, remember the
--- result (or `false` for a malformed spec) keyed by the caller's own table.
local function normaliseSpec(spec)
    local cached = normalised[spec]
    if cached ~= nil then return cached end
    local name = spec[1]
    if type(name) ~= 'string' then
        normalised[spec] = false
        return false
    end
    local copy = {}
    for k, v in pairs(spec) do copy[k] = v end
    for _, bound in ipairs({ 'min', 'max' }) do
        local raw = copy[bound]
        if raw ~= nil then
            local n = tonumber(raw)
            if n == nil then
                normalised[spec] = false
                return false
            end
            copy[bound] = n
        end
    end
    copy.optional = spec.optional == true
    if name:sub(-1) == '?' then
        name, copy.optional = name:sub(1, -2), true
    end
    copy.name = name
    normalised[spec] = copy
    return copy
end

--- Split a spec into (kindName, optionsTable, optional).
local function specParts(spec)
    local t = type(spec)
    if t == 'string' then
        if spec:sub(-1) == '?' then return spec:sub(1, -2), EMPTY, true end
        return spec, EMPTY, false
    end
    if t == 'table' then
        local norm = normaliseSpec(spec)
        if not norm then return nil end
        return norm.name, norm, norm.optional
    end
    return nil
end

--- Count keys of a table, stopping once `limit` is exceeded.
local function countKeys(t, limit)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
        if n > limit then return n end
    end
    return n
end

-- Every checker: (value, options) -> ok:boolean, expectedText:string, detail:string|nil
-- `detail` replaces the whole "expected X, got Y" message (nested errors).

checkers['any'] = function()
    return true, 'any'
end

checkers['boolean'] = function(v)
    return type(v) == 'boolean', 'boolean'
end

checkers['function'] = function(v)
    return type(v) == 'function', 'function'
end

checkers['integer'] = function(v, spec)
    local expected = 'integer' .. rangeSuffix(spec)
    if math.type(v) ~= 'integer' then return false, expected end
    if spec.min and v < spec.min then return false, expected end
    if spec.max and v > spec.max then return false, expected end
    return true, expected
end

checkers['number'] = function(v, spec)
    local expected = 'number' .. rangeSuffix(spec)
    if not isFinite(v) then return false, expected end
    if spec.min and v < spec.min then return false, expected end
    if spec.max and v > spec.max then return false, expected end
    return true, expected
end

checkers['string'] = function(v, spec)
    local expected = 'string'
    if spec.min or spec.max then expected = expected .. ' (len' .. rangeSuffix(spec) .. ')' end
    if spec.pattern then expected = expected .. ' matching ' .. tostring(spec.pattern) end
    if type(v) ~= 'string' then return false, expected end
    if #v == 0 and not spec.allowEmpty then return false, expected end
    if spec.min and #v < spec.min then return false, expected end
    if spec.max and #v > spec.max then return false, expected end
    if spec.pattern then
        local ok, matched = pcall(string.match, v, spec.pattern)
        if not ok or not matched then return false, expected end
    end
    return true, expected
end

checkers['vector3'] = function(v)
    if type(v) ~= 'vector3' then return false, 'vector3' end
    if not (isFinite(v.x) and isFinite(v.y) and isFinite(v.z)) then return false, 'vector3' end
    return true, 'vector3'
end

checkers['netId'] = function(v)
    local expected = 'netId 1..65535'
    if math.type(v) ~= 'integer' or v < 1 or v > 65535 then return false, expected end
    return true, expected
end

checkers['src'] = function(v)
    local expected = 'src 1..4096'
    if math.type(v) ~= 'integer' or v < 1 or v > 4096 then return false, expected end
    return true, expected
end

checkers['id'] = function(v)
    local expected = ('id string 1..%s [%%w_-:]'):format(ID_MAX)
    if type(v) ~= 'string' or #v < 1 or #v > ID_MAX then return false, expected end
    local ok, matched = pcall(string.match, v, ID_PATTERN)
    if not ok or not matched then return false, expected end
    return true, expected
end

checkers['enum'] = function(v, spec)
    local values = type(spec.values) == 'table' and spec.values or spec
    local first = (values == spec) and 2 or 1
    local parts = {}
    for i = first, #values do
        parts[#parts + 1] = tostring(values[i])
        if values[i] == v then return true, 'enum' end
    end
    return false, 'one of ' .. table.concat(parts, '|')
end

checkers['array'] = function(v, spec)
    local max = spec.max or DEFAULT_ARRAY_MAX
    local expected = ('array (max %s)'):format(max)
    if type(v) ~= 'table' then return false, expected end
    local n = #v
    if n > max then return false, expected end
    if spec.min and n < spec.min then return false, expected end
    if countKeys(v, n) ~= n then return false, expected .. ' without extra keys' end
    if spec.of then
        for i = 1, n do
            local ok, err = ns.value(spec.of, v[i])
            if not ok then return false, expected, ('[%d]: %s'):format(i, err) end
        end
    end
    return true, expected
end

checkers['table'] = function(v, spec)
    local max = spec.max or DEFAULT_TABLE_MAX
    local expected = ('table (max %s keys)'):format(max)
    if type(v) ~= 'table' then return false, expected end
    if countKeys(v, max) > max then return false, expected end
    if spec.keys then
        local ok, err = ns.checkTable(spec.keys, v)
        if not ok then return false, expected, err end
    end
    return true, expected
end

--- Validate one value against one spec.
--- @return boolean ok, string|nil err  -- err reads `expected integer 1..100, got -5`
function ns.value(spec, v)
    local name, opts, optional = specParts(spec)
    if not name then return false, 'invalid spec' end
    if v == nil then
        if optional then return true end
        return false, ('expected %s, got nil'):format(name)
    end
    local checker = checkers[name]
    if not checker then return false, ('invalid spec "%s"'):format(name) end
    local ok, expected, detail = checker(v, opts)
    if ok then return true end
    if detail then return false, detail end
    return false, ('expected %s, got %s'):format(expected, shortValue(v))
end

--- Validate positional arguments against a schema array (or a single spec).
--- Extra arguments beyond the schema are ignored; missing ones must be optional.
--- @return boolean ok, string|nil err  -- err reads `arg 2: expected integer 1..100, got -5`
function ns.check(schema, ...)
    if schema == nil then return true end
    if type(schema) == 'string' then
        local ok, err = ns.value(schema, (...))
        if not ok then return false, 'arg 1: ' .. err end
        return true
    end
    if type(schema) ~= 'table' then return false, 'invalid schema' end
    local args = table.pack(...)
    for i = 1, #schema do
        local ok, err = ns.value(schema[i], args[i])
        if not ok then return false, ('arg %d: %s'):format(i, err) end
    end
    return true
end

--- Validate a keyed table against `{ key = spec }`. Unknown keys are ignored
--- (use `{ 'table', keys = ..., max = n }` to bound the key count).
--- @return boolean ok, string|nil err  -- err reads `field "name": expected string, got nil`
function ns.checkTable(schema, t)
    if type(schema) ~= 'table' then return false, 'invalid schema' end
    if type(t) ~= 'table' then return false, ('expected table, got %s'):format(shortValue(t)) end
    for key, spec in pairs(schema) do
        local ok, err = ns.value(spec, t[key])
        if not ok then return false, ('field "%s": %s'):format(tostring(key), err) end
    end
    return true
end

--- True when `spec` names a kind this validator understands (for self-checks).
function ns.isSpec(spec)
    local name = specParts(spec)
    return name ~= nil and checkers[name] ~= nil
end

