--[[
    core/lib/utils/shared.lua — Core.Utils (DESIGN §3.1).

    Pure helpers, compiled into the caller's own VM by import.lua; the namespace table
    arrives as the chunk's single argument. Only shared natives (GetHashKey, GetGameTimer).
]]

local ns = ...

math.randomseed() -- once per VM, at lib load

local floor, huge = math.floor, math.huge
local concat = table.concat

--------------------------------------------------------------------------------
-- Type checks
--------------------------------------------------------------------------------

function ns.isInteger(v)
    return math.type(v) == 'integer'
end

--- Finite number (rejects NaN and ±inf).
function ns.isNumber(v)
    return type(v) == 'number' and v == v and v ~= huge and v ~= -huge
end

--- Non-empty string, optionally no longer than maxLen.
function ns.isString(v, maxLen)
    if type(v) ~= 'string' or v == '' then return false end
    return maxLen == nil or #v <= maxLen
end

function ns.isBool(v)
    return type(v) == 'boolean'
end

function ns.isTable(v)
    return type(v) == 'table'
end

function ns.isVector3(v)
    return type(v) == 'vector3'
end

function ns.isFunction(v)
    return type(v) == 'function'
end

--- A plain function OR a callable table: functions that cross the export boundary between resources
--- arrive as function-reference proxies (tables with a __call metamethod), so every check on a
--- plugin-supplied callback must use this, never `type(v) == 'function'`.
function ns.isCallable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    local mt = getmetatable(v)
    return mt ~= nil and type(mt) == 'table' and mt.__call ~= nil
end

--------------------------------------------------------------------------------
-- Numbers
--------------------------------------------------------------------------------

function ns.clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

--- Round half up; without decimals the result is an integer.
function ns.round(n, decimals)
    if not decimals or decimals <= 0 then
        local rounded = floor(n + 0.5)
        return math.tointeger(rounded) or rounded
    end
    local mult = 10 ^ decimals
    return floor(n * mult + 0.5) / mult
end

function ns.lerp(a, b, t)
    return a + (b - a) * t
end

--------------------------------------------------------------------------------
-- Tables
--------------------------------------------------------------------------------

local function copy(value, seen)
    if type(value) ~= 'table' then return value end -- vectors and other values by reference
    local existing = seen[value]
    if existing then return existing end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do
        out[k] = copy(v, seen)
    end
    return out
end

function ns.deepCopy(t)
    return copy(t, {})
end

local function isArray(t)
    return t[1] ~= nil
end

--- Deep merge in place, override wins; arrays are replaced, not merged. Returns base.
function ns.merge(base, override)
    if type(base) ~= 'table' or type(override) ~= 'table' then return base end
    for k, v in pairs(override) do
        local current = base[k]
        if type(v) == 'table' and type(current) == 'table' and not isArray(v) and not isArray(current) then
            ns.merge(current, v)
        elseif type(v) == 'table' then
            base[k] = ns.deepCopy(v)
        else
            base[k] = v
        end
    end
    return base
end

function ns.keys(t)
    local out, n = {}, 0
    for k in pairs(t) do
        n = n + 1
        out[n] = k
    end
    return out
end

function ns.values(t)
    local out, n = {}, 0
    for _, v in pairs(t) do
        n = n + 1
        out[n] = v
    end
    return out
end

function ns.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function ns.isEmpty(t)
    return next(t) == nil
end

function ns.indexOf(arr, v)
    for i = 1, #arr do
        if arr[i] == v then return i end
    end
    return nil
end

function ns.contains(arr, v)
    return ns.indexOf(arr, v) ~= nil
end

--- Removes the first occurrence of v; true when something was removed.
function ns.removeValue(arr, v)
    local i = ns.indexOf(arr, v)
    if not i then return false end
    table.remove(arr, i)
    return true
end

--- Same keys, mapped values.
function ns.map(t, fn)
    local out = {}
    for k, v in pairs(t) do
        out[k] = fn(v, k)
    end
    return out
end

--- Array of every value the predicate accepts.
function ns.filter(t, fn)
    local out, n = {}, 0
    for k, v in pairs(t) do
        if fn(v, k) then
            n = n + 1
            out[n] = v
        end
    end
    return out
end

function ns.find(t, fn)
    for k, v in pairs(t) do
        if fn(v, k) then return v, k end
    end
    return nil, nil
end

--------------------------------------------------------------------------------
-- Strings
--------------------------------------------------------------------------------

--- Splits on a plain (non-pattern) separator, default ','. Empty fields are kept.
function ns.split(s, sep)
    sep = sep or ','
    if sep == '' then return { s } end
    local out, n, pos = {}, 0, 1
    while true do
        local from, to = string.find(s, sep, pos, true)
        if not from then break end
        n = n + 1
        out[n] = s:sub(pos, from - 1)
        pos = to + 1
    end
    out[n + 1] = s:sub(pos)
    return out
end

function ns.trim(s)
    return (s:match('^%s*(.-)%s*$'))
end

function ns.startsWith(s, p)
    return s:sub(1, #p) == p
end

function ns.endsWith(s, p)
    return p == '' or s:sub(-#p) == p
end

--- Uppercases the first character, leaves the rest untouched.
function ns.capitalize(s)
    if s == '' then return s end
    return s:sub(1, 1):upper() .. s:sub(2)
end

--- Cuts s to at most n characters, marking a cut with '...'.
function ns.truncate(s, n)
    if #s <= n then return s end
    if n <= 3 then return s:sub(1, n) end
    return s:sub(1, n - 3) .. '...'
end

--- Anything (usually player input) -> printable, trimmed, length-capped string.
function ns.sanitize(s, maxLen)
    local out = tostring(s):gsub('%c', '')
    out = out:match('^%s*(.-)%s*$')
    maxLen = maxLen or 64
    if #out > maxLen then out = out:sub(1, maxLen) end
    return out
end

--------------------------------------------------------------------------------
-- Random and formatting
--------------------------------------------------------------------------------

local ALPHABET <const> = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

--- 32 hex characters (not RFC 4122, just a unique id).
function ns.uuid()
    return ('%08x%08x%08x%08x'):format(math.random(0, 0xffffffff), math.random(0, 0xffffffff),
        math.random(0, 0xffffffff), math.random(0, 0xffffffff))
end

function ns.randomInt(lo, hi)
    return math.random(floor(lo), floor(hi))
end

function ns.randomString(len, alphabet)
    alphabet = alphabet or ALPHABET
    local size = #alphabet
    local out = {}
    for i = 1, len do
        local at = math.random(1, size)
        out[i] = alphabet:sub(at, at)
    end
    return concat(out)
end

local function groupDigits(digits)
    local reversed = digits:reverse():gsub('(%d%d%d)', '%1,')
    local grouped = reversed:reverse()
    if grouped:sub(1, 1) == ',' then grouped = grouped:sub(2) end
    return grouped
end

--- 1234 -> '$1,234', -1234 -> '-$1,234'.
function ns.formatMoney(n)
    local value = math.tointeger(n) or floor(tonumber(n) or 0)
    local negative = value < 0
    if negative then value = -value end
    local out = '$' .. groupDigits(tostring(value))
    return negative and ('-' .. out) or out
end

--------------------------------------------------------------------------------
-- Game values and JSON-safe conversion
--------------------------------------------------------------------------------

--- Strings are hashed, numbers pass through unchanged.
function ns.hash(s)
    if type(s) == 'number' then return s end
    return GetHashKey(s)
end

function ns.now()
    return GetGameTimer()
end

function ns.tableToVector3(t)
    return vector3(t.x or t[1] or 0.0, t.y or t[2] or 0.0, t.z or t[3] or 0.0)
end

function ns.vector3ToTable(v)
    return { x = v.x, y = v.y, z = v.z }
end

local JSON_MAX_DEPTH <const> = 16

--- `seen` holds the tables on the current path only, so a real cycle is dropped while a
--- sub-table referenced twice side by side is still converted twice.
local function jsonSafeValue(v, state, depth)
    local t = type(v)
    if t == 'vector2' then return { x = v.x, y = v.y } end
    if t == 'vector3' then return { x = v.x, y = v.y, z = v.z } end
    if t == 'vector4' then return { x = v.x, y = v.y, z = v.z, w = v.w } end
    if t ~= 'table' then return v end
    if state.seen[v] then return nil end -- cycle: drop the back reference
    if depth >= JSON_MAX_DEPTH then
        if not state.warned then
            state.warned = true
            print(('[core] Utils.jsonSafe: table deeper than %d levels, deeper values dropped')
                :format(JSON_MAX_DEPTH))
        end
        return nil
    end
    state.seen[v] = true
    local out = {}
    for k, value in pairs(v) do
        out[k] = jsonSafeValue(value, state, depth + 1)
    end
    state.seen[v] = nil
    return out
end

--- Deep copy in which every vector becomes a {x, y, z, w} table (json.encode cannot
--- serialise a vector). Cycles are dropped and nesting is capped at JSON_MAX_DEPTH, so a
--- plugin table can never blow the stack inside a persistence path.
function ns.jsonSafe(v)
    return jsonSafeValue(v, { seen = {}, warned = false }, 0)
end
