-- Offline contract for Core.Schema (DESIGN §43): every type, bounds, nesting, defaults, the public view
-- and the refusal of unknown keys. Loaded through import.lua, so the LIB_MODULES entry is covered too.
local here = (arg and arg[0] or 'tests/schema_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
stubs.newWorld()
stubs.clear()
local passed, failed = 0, 0
local function check(value, message)
    if value then
        passed = passed + 1
    else
        failed = failed + 1
        print('FAIL: ' .. message)
    end
end
local function eq(actual, expected, message)
    check(actual == expected, ('%s (expected %s, got %s)'):format(message, tostring(expected), tostring(actual)))
end

local env = stubs.newEnv('server', 'some_plugin')
stubs.loadImport(env)
local Schema = env.Core.Schema
check(type(Schema) == 'table' and type(rawget(Schema, 'check')) == 'function', 'Core.Schema loads lazily in a plugin VM')

local function field(def)
    local f, err = Schema.field(def)
    check(f ~= nil, 'field accepted: ' .. tostring(def.type) .. ' ' .. tostring(err))
    return f
end
local function refuses(def, want, message)
    local f, err = Schema.field(def)
    check(f == nil, message .. ' refused')
    if want then eq(err, want, message .. ' error') end
end
local function ok(f, value, message, expected)
    local good, res = Schema.check(f, value)
    check(good == true, message .. ' passes (' .. tostring(res) .. ')')
    if expected ~= nil then eq(res, expected, message .. ' value') end
    return res
end
local function bad(f, value, want, message)
    local good, err = Schema.check(f, value)
    check(good == false, message .. ' fails')
    eq(err, want, message .. ' error')
end

-- Definitions ---------------------------------------------------------------------------------
refuses({ type = 'nope' }, 'type', 'unknown type')
refuses('x', 'field', 'non-table def')
refuses({ type = 'string', name = '1abc' }, 'name', 'name pattern')
refuses({ type = 'string', name = ('a'):rep(49) }, 'name', 'name length')
refuses({ type = 'string', label = 5 }, 'label', 'label type')
refuses({ type = 'string', required = 'yes' }, 'required', 'flag type')
refuses({ type = 'number', min = 5, max = 1 }, 'max', 'min > max')
refuses({ type = 'number', step = 0 }, 'step', 'zero step')
refuses({ type = 'number', min = 0 / 0 }, 'min', 'NaN min')
refuses({ type = 'string', maxLength = 5000 }, 'maxLength', 'maxLength cap')
refuses({ type = 'string', pattern = '[' }, 'pattern', 'malformed pattern')
refuses({ type = 'enum', options = {} }, 'options', 'empty options')
refuses({ type = 'enum', options = { 'a', 'a' } }, 'options', 'duplicate options')
refuses({ type = 'array' }, 'items', 'array without items')
refuses({ type = 'array', items = { type = 'x' } }, 'items.type', 'bad items')
refuses({ type = 'array', items = { type = 'string' }, maxItems = 1001 }, 'maxItems', 'maxItems cap')
refuses({ type = 'object', fields = {} }, 'fields.count', 'object without fields')
refuses({ type = 'model', kinds = { 'plane' } }, 'kinds', 'unknown model kind')
refuses({ type = 'number', default = 'x' }, 'default:type', 'default of the wrong type')
refuses({ type = 'number', max = 3, default = 4 }, 'default:max', 'default out of range')
refuses({ type = 'string', validate = 7 }, 'validate', 'non-callable validate')
refuses({ type = 'string', visibleWhen = { field = 'a' } }, 'visibleWhen', 'visibleWhen without a condition')

local nest = { type = 'string', name = 'leaf' }
for _ = 1, 5 do nest = { type = 'object', name = 'o', fields = { nest } } end
refuses(nest, nil, 'nesting deeper than 4')
local deep = { type = 'string', name = 'leaf' }
for _ = 1, 4 do deep = { type = 'object', name = 'o', fields = { deep } } end
field(deep)

local f = field({ type = 'number', min = 1, max = 10, label = 'L', bogus = 'dropped', default = 2 })
eq(f.bogus, nil, 'unknown def keys are dropped')
eq(f.persistDefault, true, 'persistDefault defaults to true')
eq(Schema.default(f), 2, 'default')

local list, err = Schema.fields({ { type = 'string', name = 'a' }, { type = 'string', name = 'a' } })
check(list == nil and err == 'duplicate:a', 'duplicate names refused')
list, err = Schema.fields({ { type = 'string' } })
check(list == nil and err == '1.name', 'unnamed list field refused')
list, err = Schema.fields({ { type = 'string', name = 'a', visibleWhen = { field = 'zz', equals = 1 } } })
check(list == nil and err == 'a.visibleWhen', 'visibleWhen must reference a sibling')
local many = {}
for i = 1, 65 do many[i] = { type = 'boolean', name = 'f' .. i } end
list, err = Schema.fields(many)
check(list == nil and err == 'count', 'more than 64 fields refused')
list, err = Schema.fields({ { type = 'number', name = 'n', min = 'x' } })
check(list == nil and err == 'n.min', 'list error carries the field name')

-- Types -----------------------------------------------------------------------------------------
local b = field({ type = 'boolean' })
ok(b, false, 'boolean false', false)
bad(b, 1, 'type', 'boolean from number')
bad(b, 'true', 'type', 'boolean never coerced from a string')

local n = field({ type = 'number', min = 0, max = 1, step = 0.1 })
ok(n, 0.3, 'number on step grid')
bad(n, 0.35, 'step', 'number off grid')
bad(n, -0.1, 'min', 'number below min')
bad(n, 1.5, 'max', 'number above max')
bad(n, '0.5', 'type', 'number never coerced from a string')
bad(n, 0 / 0, 'type', 'NaN')
bad(n, math.huge, 'type', 'infinity')

local i = field({ type = 'integer', min = 1, max = 100, step = 5 })
eq(math.type(ok(i, 6.0, 'integer float without fraction')), 'integer', 'integer normalised')
bad(i, 2.5, 'type', 'integer with fraction')
bad(i, 7, 'step', 'integer step grid from min')
bad(i, 0, 'min', 'integer min')

local s = field({ type = 'string', minLength = 2, maxLength = 5, pattern = '^%a+$' })
ok(s, 'abc', 'string ok')
bad(s, 'a', 'length', 'string too short')
bad(s, 'abcdef', 'length', 'string too long')
bad(s, 'ab1', 'pattern', 'string pattern')
bad(s, 12, 'type', 'string from number')
local defaultLen = field({ type = 'text' })
eq(defaultLen.maxLength, 256, 'string maxLength default 256')
bad(defaultLen, ('x'):rep(257), 'length', 'text over the default cap')
field({ type = 'password', maxLength = 4096 })
local req = field({ type = 'string', required = true })
bad(req, nil, 'required', 'required nil')
bad(req, '', 'required', 'required empty string')
ok(field({ type = 'string' }), nil, 'optional nil passes')

local r = field({ type = 'reason', templates = { 'Cheating', 'RDM' } })
eq(r.minLength, 3, 'reason minLength default 3')
bad(r, '   ', 'length', 'reason of spaces')
ok(r, 'RDM ', 'reason ok')
refuses({ type = 'reason', templates = { 5 } }, 'templates', 'bad templates')

local e = field({ type = 'enum', options = { 'a', { value = 2, label = 'Two' }, true } })
eq(e.options[1].label, 'a', 'option label defaults to the value')
ok(e, 2, 'enum number option')
ok(e, true, 'enum boolean option')
bad(e, 'b', 'option', 'enum unknown option')
bad(e, { 'a' }, 'type', 'single enum refuses an array')
local em = field({ type = 'enum', multiple = true, options = { 'a', 'b', 'c' }, minItems = 1 })
ok(em, { 'a', 'c' }, 'multi enum')
bad(em, { 'a', 'a' }, 'option', 'multi enum duplicate')
bad(em, {}, 'items', 'multi enum minItems')
bad(em, { 'a', 'b', 'c', 'a' }, 'items', 'multi enum longer than the option list')
bad(em, { x = 'a' }, 'type', 'multi enum non-sequence')

local a = field({ type = 'array', items = { type = 'integer', min = 0 }, minItems = 1, maxItems = 3 })
local arr = ok(a, { 1, 2 }, 'array ok')
eq(#arr, 2, 'array copy length')
bad(a, {}, 'items', 'array minItems')
bad(a, { 1, 2, 3, 4 }, 'items', 'array maxItems')
bad(a, { 1, -1 }, '2.min', 'array item error carries the index')
bad(a, { [1] = 1, [3] = 3 }, 'type', 'sparse array')
bad(a, { 1, x = 2 }, 'type', 'array with a string key')
local huge = {}
for k = 1, 5000 do huge[k] = k end
bad(field({ type = 'array', items = { type = 'integer' } }), huge, 'items', 'array over 1000 items')

local o = field({ type = 'object', fields = {
    { type = 'string', name = 'label', required = true, maxLength = 8 },
    { type = 'duration', name = 'dur', default = 60 },
} })
local obj = ok(o, { label = 'x' }, 'object ok')
eq(obj.dur, 60, 'object fills a missing default')
bad(o, { label = 'x', extra = 1 }, 'extra.unknown', 'object undeclared key')
bad(o, { dur = 5 }, 'label.required', 'object required child')
bad(o, { label = ('x'):rep(9) }, 'label.length', 'object child path')
bad(o, 'x', 'type', 'object from a string')

local c = field({ type = 'color' })
ok(c, '#A0b1C2', 'color 6 digits')
bad(c, '#A0B1C2FF', 'pattern', 'color alpha without alpha = true')
ok(field({ type = 'color', alpha = true }), '#A0B1C2FF', 'color with alpha')
bad(c, 'red', 'pattern', 'color name')

local d = field({ type = 'duration', max = 3600 })
ok(d, 0, 'duration 0 without min')
bad(d, 3601, 'max', 'duration max')
bad(d, -1, 'min', 'duration negative')
bad(d, 1.5, 'type', 'duration fraction')
local dp = field({ type = 'duration', allowPermanent = true, min = 60 })
ok(dp, 0, 'duration permanent')
bad(dp, 30, 'min', 'duration min applies to non-permanent values')
bad(field({ type = 'duration', min = 1 }), 0, 'min', 'duration 0 refused by min without allowPermanent')

local v = field({ type = 'vector3', world = true })
local vec = ok(v, stubs.vector3(1, 2, 3), 'vector3 from a vector')
check(type(vec) == 'table' and vec.x == 1 and vec.z == 3, 'vector3 normalised to a table')
ok(v, { x = 1, y = 2, z = 3 }, 'vector3 from a table')
bad(v, { x = 1, y = 2 }, 'type', 'vector3 missing z')
bad(v, { x = 1, y = 2, z = 3, w = 4 }, 'type', 'vector3 extra key')
bad(v, { x = 10001, y = 0, z = 0 }, 'max', 'vector3 world x')
bad(v, { x = 0, y = 0, z = -1001 }, 'min', 'vector3 world z')
bad(field({ type = 'vector3', min = 0 }), { x = 1, y = -1, z = 1 }, 'min', 'vector3 component min')

local h = field({ type = 'heading' })
ok(h, 370, 'heading normalised', 10)
ok(h, -90, 'negative heading normalised', 270)
bad(h, 'n', 'type', 'heading from a string')
ok(field({ type = 'rotation' }), { x = 720, y = 0, z = -5 }, 'rotation any finite degrees')

local m = field({ type = 'model', kinds = { 'prop', 'vehicle' } })
ok(m, 'prop_bench_01a', 'model name')
bad(m, 'bad model', 'pattern', 'model pattern')
bad(m, ('a'):rep(65), 'length', 'model length')
bad(m, 12345, 'type', 'model hash number')
local p = field({ type = 'player' })
ok(p, 12, 'player id')
bad(p, 0, 'min', 'player 0')
bad(p, 65536, 'max', 'player too high')
ok(field({ type = 'ref', refType = 'core:vehicle' }), 'map-1:el_2', 'ref id with colon')
bad(field({ type = 'faction' }), 'lspd:x', 'pattern', 'faction id has no colon')
ok(field({ type = 'item' }), 'water_bottle', 'item id')

-- Custom validate (server side, private slot) ------------------------------------------------------
local seenAll
local cv = field({ type = 'integer', validate = function(value, all)
    seenAll = all
    if value % 2 == 1 then return false, 'odd' end
    return true
end })
ok(cv, 4, 'custom validate passes')
bad(cv, 3, 'custom:odd', 'custom validate refuses with its text')
bad(cv, 'x', 'type', 'built-in checks run before custom validate')
eq(cv.validate, nil, 'validate never sits in the field table')
bad(field({ type = 'string', validate = function() error('boom') end }), 'x', 'custom:error', 'throwing validate')
bad(field({ type = 'string', validate = function() return false end }), 'x', 'custom:invalid', 'validate without text')
local callable = setmetatable({}, { __call = function(_, value) return value == 'ok' end })
local fc = field({ type = 'string', validate = callable })
ok(fc, 'ok', 'callable-table validate (export hop shape)')
bad(fc, 'no', 'custom:invalid', 'callable-table validate refuses')
local again = field(fc)
bad(again, 'no', 'custom:invalid', 're-normalising keeps the private validate')

-- checkAll ------------------------------------------------------------------------------------------
local form = assert(Schema.fields({
    { type = 'enum', name = 'kind', options = { 'ban', 'kick' }, required = true },
    { type = 'duration', name = 'duration', required = true, allowPermanent = true,
      visibleWhen = { field = 'kind', equals = 'ban' } },
    { type = 'reason', name = 'reason', required = true },
    { type = 'integer', name = 'count', default = 3 },
    { type = 'integer', name = 'quiet', default = 7, persistDefault = false },
    { type = 'integer', name = 'even', validate = function(value, all)
        seenAll = all
        return value % 2 == 0, 'odd'
    end },
}))
local good, out = Schema.checkAll(form, { kind = 'kick', reason = 'spam', even = 2 })
check(good == true, 'checkAll ok (hidden required field skipped)')
eq(out.count, 3, 'checkAll fills defaults')
eq(out.quiet, nil, 'persistDefault = false is not filled')
check(seenAll == out, 'custom validate sees the normalised values as `all`')
local errs
good, errs = Schema.checkAll(form, { kind = 'ban', reason = 'spam' })
check(good == false and errs.duration == 'required', 'visible required field enforced')
good, errs = Schema.checkAll(form, { kind = 'kick', reason = 'spam', hack = true, [1] = 'x' })
check(good == false and errs.hack == 'unknown' and errs['1'] == 'unknown', 'checkAll refuses unknown keys')
good, errs = Schema.checkAll(form, { kind = 'kick', reason = 'spam', even = 3 })
check(good == false and errs.even == 'custom:odd', 'checkAll custom error per name')
good, errs = Schema.checkAll(form, { kind = 'x', reason = 'ab' })
check(good == false and errs.kind == 'option' and errs.reason == 'length', 'checkAll collects every error')
good, out = Schema.checkAll(form, { reason = 'better reason' }, { partial = true })
check(good == true and out.reason == 'better reason' and out.count == nil and out.kind == nil,
    'partial checks only the given keys, no defaults, no required')
good, errs = Schema.checkAll(form, { reason = 5 }, { partial = true })
check(good == false and errs.reason == 'type', 'partial still validates what is given')
good, errs = Schema.checkAll(form, 'x')
check(good == false and errs['*'] == 'type', 'checkAll non-table values')
good, errs = Schema.checkAll({ { type = 'bogus', name = 'x' } }, {})
check(good == false and errs['*'] == 'schema:x.type', 'checkAll with a broken raw list')
good, out = Schema.checkAll({ { type = 'integer', name = 'x', default = 1 } }, nil)
check(good == true and out.x == 1, 'checkAll accepts a raw list and nil values')
local flood = { kind = 'kick', reason = 'spam' }
for k = 1, 500 do flood['junk' .. k] = k end
good, errs = Schema.checkAll(form, flood)
local nErr = 0
for _ in pairs(errs) do nErr = nErr + 1 end
check(good == false and nErr <= 16, 'unknown-key reporting is bounded')

-- public ------------------------------------------------------------------------------------------
local pubList = assert(Schema.fields({
    { type = 'password', name = 'token', secret = true, default = 'hunter2' },
    { type = 'integer', name = 'n', default = 5, validate = function() return true end },
    { type = 'object', name = 'o', fields = { { type = 'string', name = 'k', secret = true, default = 's' } } },
}))
local pub = Schema.public(pubList)
eq(pub[1].default, nil, 'secret default removed')
eq(pub[1].secret, true, 'secret flag kept')
eq(pub[2].default, 5, 'plain default kept')
eq(pub[3].fields[1].default, nil, 'nested secret default removed')
check(pub[2] ~= pubList[2], 'public returns copies')
local function hasFunction(t)
    for _, value in pairs(t) do
        if type(value) == 'function' then return true end
        if type(value) == 'table' and hasFunction(value) then return true end
    end
    return false
end
check(not hasFunction(pub), 'public view carries no functions')
local encoded = stubs.json.encode(pub)
check(type(encoded) == 'string' and #encoded > 0, 'public view is JSON-encodable')
local single = Schema.public({ type = 'integer', default = 1 })
check(type(single) == 'table' and single[1].default == 1, 'public of a single field')
local nope = Schema.public({ { type = 'x', name = 'a' } })
eq(nope, nil, 'public of a broken list')

-- A plain JSON copy (what crosses VMs) re-normalises to an equivalent field.
local copied = stubs.json.decode(stubs.json.encode(Schema.public(e)[1]))
ok(copied, 2, 'a public copy is itself a valid definition')
bad(copied, 'b', 'option', 'the copy keeps the options')

-- UI-only keys for CoreSchemaForm: kept through field() and public(), validated, never read by check --
local iconField = field({ type = 'integer', icon = 'clock' })
eq(iconField.icon, 'clock', 'icon kept on any field')
refuses({ type = 'integer', icon = ('x'):rep(33) }, 'icon', 'icon over 32 bytes')
refuses({ type = 'integer', icon = 5 }, 'icon', 'icon type')
local eIcon = field({ type = 'enum', options = { { value = 'a', icon = 'star' }, 'b' } })
eq(eIcon.options[1].icon, 'star', 'option icon kept')
refuses({ type = 'enum', options = { { value = 'a', icon = ('x'):rep(33) } } }, 'options', 'option icon over 32 bytes')
local rowsField = field({ type = 'text', rows = 6 })
eq(rowsField.rows, 6, 'text rows kept')
refuses({ type = 'text', rows = 1 }, 'rows', 'rows below 2')
refuses({ type = 'text', rows = 21 }, 'rows', 'rows above 20')
refuses({ type = 'text', rows = 2.5 }, 'rows', 'fractional rows')
eq(field({ type = 'string', rows = 6 }).rows, nil, 'rows only on text')
ok(rowsField, 'line one\nline two', 'rows does not affect check')
local pres = field({ type = 'duration', allowPermanent = true, max = 86400, presets = { 3600, 86400, 0 } })
check(#pres.presets == 3 and pres.presets[3] == 0, 'duration presets kept (0 with allowPermanent)')
refuses({ type = 'duration', presets = { 0 } }, 'presets', 'preset 0 without allowPermanent')
refuses({ type = 'duration', max = 60, presets = { 120 } }, 'presets', 'preset above max')
refuses({ type = 'duration', min = 60, presets = { 30 } }, 'presets', 'preset below min')
refuses({ type = 'duration', presets = { -1 } }, 'presets', 'negative preset')
refuses({ type = 'duration', presets = { 1.5 } }, 'presets', 'fractional preset')
refuses({ type = 'duration', presets = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 } }, 'presets', 'more than 12 presets')
refuses({ type = 'duration', presets = 'x' }, 'presets', 'presets type')
eq(field({ type = 'integer', presets = { 1 } }).presets, nil, 'presets only on duration')
bad(pres, 86401, 'max', 'presets do not change check')
local pubUi = Schema.public({ { type = 'duration', name = 'd', icon = 'clock', presets = { 60 } },
    { type = 'text', name = 't', rows = 4 }, { type = 'enum', name = 'e', options = { { value = 1, icon = 'x' } } } })
check(pubUi[1].icon == 'clock' and pubUi[1].presets[1] == 60 and pubUi[2].rows == 4
    and pubUi[3].options[1].icon == 'x', 'public carries icon, presets, rows and option icons')
eq(Schema.public({ pres }), nil, 'an unnamed field in a list is still refused')

-- L12: integer-valued types only take values math.tointeger can represent (floats up to 2^53) --
local freeInt = field({ type = 'integer' })
bad(freeInt, 2.0 ^ 60, 'type', 'integer float beyond 2^53 refused without max')
bad(freeInt, 1e300, 'type', 'huge float integer refused')
eq(math.type(ok(freeInt, 2.0 ^ 53, 'integer float at 2^53')), 'integer', '2^53 float becomes an integer')
eq(ok(freeInt, 1 << 62, 'integer subtype beyond 2^53 is exact'), 1 << 62, 'integer subtype kept')
local freeDur = field({ type = 'duration' })
bad(freeDur, 2.0 ^ 60, 'type', 'duration float beyond 2^53 refused without max')
bad(freeDur, 1e300, 'type', 'huge duration refused')
eq(math.type(ok(freeDur, 86400.0, 'duration float without fraction')), 'integer', 'duration normalised to integer')
bad(field({ type = 'player' }), 2.0 ^ 60, 'type', 'player float beyond 2^53')
refuses({ type = 'integer', min = 0, step = 1, max = 2.0 ^ 60, default = 2.0 ^ 60 }, 'default:type', 'huge float default')

print(('schema: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
