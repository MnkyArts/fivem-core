--[[
    core/tests/run_tests.lua — the offline test suite for import.lua and lib/**.

        lua5.4 tests/run_tests.lua      (from the resource directory, or from tests/)

    Every FiveM native and runtime helper comes from tests/stubs.lua, so this proves the
    pure Lua contracts of DESIGN §2 and §3 — never in-game behaviour. Exit code is 1 when
    anything fails.
]]

local here = (arg and arg[0] or 'tests/run_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
local stubs = dofile(here .. '/stubs.lua')

local vector3 = stubs.vector3
local xtype = stubs.type

--------------------------------------------------------------------------------
-- assertions
--------------------------------------------------------------------------------

local passed, failed, suiteName = 0, 0, '?'
local failures = {}

local function suite(name)
    suiteName = name
end

local function show(v)
    if type(v) == 'string' then return ('%q'):format(v) end
    return tostring(v)
end

local function check(cond, label, detail)
    if cond then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    local line = ('FAIL  [%s] %s'):format(suiteName, label)
    if detail then line = line .. '\n        ' .. detail end
    failures[#failures + 1] = line
    print(line)
    return false
end

local function eq(actual, expected, label)
    return check(actual == expected, label,
        ('expected %s, got %s'):format(show(expected), show(actual)))
end

local function near(actual, expected, label, tolerance)
    local ok = type(actual) == 'number' and math.abs(actual - expected) <= (tolerance or 1e-6)
    return check(ok, label, ('expected ~%s, got %s'):format(show(expected), show(actual)))
end

local function nearVec(actual, x, y, z, label)
    local ok = xtype(actual) == 'vector3' and math.abs(actual.x - x) < 1e-6
        and math.abs(actual.y - y) < 1e-6 and math.abs(actual.z - z) < 1e-6
    return check(ok, label, ('expected ~(%s, %s, %s), got %s'):format(x, y, z, tostring(actual)))
end

--- The most recent printed line containing `needle`, or nil.
local function printed(needle)
    for i = #stubs.printed, 1, -1 do
        if stubs.printed[i]:find(needle, 1, true) then return stubs.printed[i] end
    end
    return nil
end

local function lastPrinted()
    return stubs.printed[#stubs.printed]
end

--- A fresh, isolated VM with import.lua already loaded.
local function newVM(side, resourceName)
    local env = stubs.newEnv(side, resourceName or 'core_example')
    stubs.loadImport(env)
    return env, env.Core
end

--------------------------------------------------------------------------------
-- suite: import.lua loader and proxy (DESIGN §2)
--------------------------------------------------------------------------------

local function suiteImport()
    suite('import')
    stubs.newWorld()
    stubs.clear()
    local calls = {}
    stubs.exports.core = {
        call = function(caller, namespace, fn, ...)
            calls[#calls + 1] = { caller = caller, ns = namespace, fn = fn, args = table.pack(...) }
            return 'ok', 2
        end,
    }

    local env = stubs.newEnv('server', 'core_example')
    env.Config = { Debug = true, PLUGIN_ONLY = true }   -- the plugin's own config global
    local Core = stubs.loadImport(env)

    eq(Core.name, 'core_example', 'Core.name is the including resource')
    eq(Core.isServer, true, 'Core.isServer on a server VM')
    eq(Core.isClient, false, 'Core.isClient on a server VM')
    eq(Core.isCore, false, 'Core.isCore is false in a plugin')
    eq(Core.version, '1.0.0', 'Core.version')

    -- libs are compiled into the caller's VM, not proxied
    check(type(rawget(Core.Utils, 'formatMoney')) == 'function',
        'Core.Utils comes from the real lib file')
    eq(Core.Utils.formatMoney(1234), '$1,234', 'the in-VM lib function runs locally')
    check(type(rawget(Core.Math, 'offset')) == 'function', 'Core.Math loads from lib/math/shared.lua')
    eq(#calls, 0, 'a lib call never hops through the export')

    -- unknown namespace -> export proxy
    local a, b = Core.Markers.add(5, 'x')
    eq(#calls, 1, 'Core.Markers.add goes through exports.core:call')
    eq(calls[1].caller, 'core_example', 'call() gets the calling resource name')
    eq(calls[1].ns, 'Markers', 'call() gets the namespace')
    eq(calls[1].fn, 'add', 'call() gets the function name')
    eq(calls[1].args[1], 5, 'call() forwards the arguments')
    eq(calls[1].args[2], 'x', 'call() forwards every argument')
    eq(a, 'ok', 'multiple return values pass back through the proxy')
    eq(b, 2, 'second return value passes back too')
    check(rawget(Core.Markers, 'add') ~= nil, 'the proxy closure is cached per (namespace, fn)')

    -- one nesting level: Core.UI.menu.open -> ('UI', 'menu.open')
    Core.UI.menu.open({ title = 't' })
    eq(calls[2].ns, 'UI', 'Core.UI.menu.open keeps the UI namespace')
    eq(calls[2].fn, 'menu.open', 'sub-namespaces become dotted function names')
    Core.UI.progress({ label = 'x' })
    eq(calls[3].fn, 'progress', 'a sub-proxy is callable itself')

    -- Core.Player(src) sugar (server only)
    Core.Player(7):addMoney('cash', 10)
    eq(calls[4].ns, 'Player', 'handle:addMoney reaches Core.Player.addMoney')
    eq(calls[4].fn, 'addMoney', 'handle method name')
    eq(calls[4].args[1], 7, 'the handle passes src as the first argument')
    eq(calls[4].args[2], 'cash', 'handle arguments follow src')
    eq(calls[4].args[3], 10, 'handle arguments follow src (2)')
    Core.Player(7).money:add('cash', 10)
    eq(calls[5].ns, 'Money', 'handle.money:add reaches Core.Money.add')
    eq(calls[5].fn, 'add', 'handle.money method name')
    eq(calls[5].args[1], 7, 'handle.money passes src first')

    -- Core.Config is core's config, never the plugin's
    eq(Core.Config.PLUGIN_ONLY, nil, "Core.Config is not the plugin's Config global")
    eq(Core.Config.CallbackTimeoutMs, 5000, "Core.Config comes from core's shared/config.lua")
    eq(env.Config.PLUGIN_ONLY, true, "the plugin's own Config global stays untouched")
    eq(xtype(Core.Config.Player.SpawnPoint.coords), 'vector3', 'config vectors survive the private env')

    -- hooks and readiness
    local got
    Core.on('greet', function(value) got = value end)
    Core.emitHook('greet', 42)
    eq(got, 42, 'Core.on / Core.emitHook round trip')
    eq(Core.isReady(), true, "Core.isReady() follows GetResourceState('core')")
    local ready = 0
    Core.onReady(function() ready = ready + 1 end)
    eq(ready, 1, 'Core.onReady runs at once when core is already started')
    eq(Core.notANamespace, nil, 'a lowercase unknown key stays nil')

    -- inside core itself: no proxy, but the Player(src) sugar survives assignment
    local coreEnv = stubs.newEnv('server', 'core')
    local C = stubs.loadImport(coreEnv)
    eq(C.isCore, true, 'Core.isCore inside core')
    eq(C.Markers, nil, 'inside core an unimplemented namespace stays nil (no proxy)')
    check(type(rawget(C.Utils, 'split')) == 'function', 'core loads its own libs the same way')
    eq(C.Config, nil, 'inside core, Core.Config is nil until shared/config.lua ran')
    stubs.loadFile(coreEnv, 'shared/config.lua')
    eq(C.Config, coreEnv.Config, 'inside core, Core.Config is the Config global itself')
    C.Player = { getInfo = function(src) return 'info-' .. src end }
    eq(C.Player(5):getInfo(), 'info-5', 'Core.Player = {} keeps the __call handle sugar')
end

--------------------------------------------------------------------------------
-- suite: Core.Utils (DESIGN §3.1)
--------------------------------------------------------------------------------

local function suiteUtils()
    suite('utils')
    stubs.newWorld()
    local _, Core = newVM('server')
    local U = Core.Utils

    eq(U.formatMoney(1234), '$1,234', 'formatMoney groups thousands')
    eq(U.formatMoney(0), '$0', 'formatMoney of zero')
    eq(U.formatMoney(999), '$999', 'formatMoney below a thousand')
    eq(U.formatMoney(1000000), '$1,000,000', 'formatMoney of a million')
    eq(U.formatMoney(-1234567), '-$1,234,567', 'formatMoney of a negative amount')

    local base = { a = 1, nested = { x = 1, y = 2 }, arr = { 1, 2, 3 } }
    local merged = U.merge(base, { nested = { y = 9, z = 3 }, arr = { 7 }, b = 2 })
    eq(merged, base, 'merge returns the base table (in place)')
    eq(base.nested.x, 1, 'merge keeps untouched nested keys')
    eq(base.nested.y, 9, 'merge lets the override win')
    eq(base.nested.z, 3, 'merge adds new nested keys')
    eq(#base.arr, 1, 'merge replaces arrays instead of merging them')
    eq(base.arr[1], 7, 'merge replaced the array contents')
    eq(base.b, 2, 'merge adds new top-level keys')

    local source = { n = 1, deep = { list = { 1, 2 } } }
    source.self = source
    local copy = U.deepCopy(source)
    check(copy ~= source, 'deepCopy returns a new table')
    check(copy.deep ~= source.deep, 'deepCopy copies nested tables')
    eq(copy.deep.list[2], 2, 'deepCopy keeps nested values')
    eq(copy.self, copy, 'deepCopy handles a self reference')
    copy.deep.list[1] = 99
    eq(source.deep.list[1], 1, 'the copy is independent of the source')

    eq(U.sanitize('  he\tllo\n  '), 'hello', 'sanitize strips control chars and trims')
    eq(U.sanitize(string.rep('a', 100)), string.rep('a', 64), 'sanitize caps at 64 by default')
    eq(U.sanitize('abcdef', 3), 'abc', 'sanitize honours maxLen')
    eq(U.sanitize(42), '42', 'sanitize accepts a non-string')

    local parts = U.split('a,b,,c')
    eq(#parts, 4, 'split keeps empty fields')
    eq(parts[3], '', 'split keeps the empty field itself')
    eq(U.split('a|b', '|')[2], 'b', 'split takes a plain separator, not a pattern')
    eq(#U.split('abc', ''), 1, 'split with an empty separator returns the whole string')

    local safe = U.jsonSafe({ pos = vector3(1.0, 2.0, 3.0), list = { vector3(4.0, 5.0, 6.0) }, n = 7 })
    eq(xtype(safe.pos), 'table', 'jsonSafe turns a vector3 into a table')
    eq(safe.pos.x, 1.0, 'jsonSafe keeps x')
    eq(safe.pos.z, 3.0, 'jsonSafe keeps z')
    eq(safe.list[1].y, 5.0, 'jsonSafe recurses into nested tables')
    eq(safe.n, 7, 'jsonSafe leaves plain values alone')
    local cyclic = { name = 'x' }
    cyclic.self = cyclic
    local uncycled = U.jsonSafe(cyclic)
    eq(uncycled.name, 'x', 'jsonSafe keeps the plain keys of a cyclic table')
    eq(uncycled.self, nil, 'jsonSafe drops a cycle instead of recursing forever')
    local deep, node = {}, nil
    node = deep
    for _ = 1, 20 do
        node.child = {}
        node = node.child
    end
    local capped, levels = U.jsonSafe(deep), 0
    local walk = capped
    while walk and walk.child do
        levels = levels + 1
        walk = walk.child
    end
    check(levels < 20, 'jsonSafe caps how deep it converts', ('got %d levels'):format(levels))
    check(printed('deeper than') ~= nil, 'the depth cap is reported once')

    eq(U.isInteger(5), true, 'isInteger of an integer')
    eq(U.isInteger(5.0), false, 'isInteger rejects a float')
    eq(U.isNumber(0 / 0), false, 'isNumber rejects NaN')
    eq(U.isNumber(math.huge), false, 'isNumber rejects infinity')
    eq(U.isString('', 4), false, 'isString rejects the empty string')
    eq(U.isString('abcde', 4), false, 'isString honours maxLen')
    eq(U.isVector3(vector3(0, 0, 0)), true, 'isVector3 sees the vector type')
    eq(U.isVector3({ x = 0 }), false, 'isVector3 rejects a plain table')

    eq(U.round(2.5), 3, 'round is half up')
    eq(U.round(1.2345, 2), 1.23, 'round with decimals')
    eq(math.type(U.round(2.4)), 'integer', 'round without decimals returns an integer')
    eq(U.clamp(15, 1, 10), 10, 'clamp to the upper bound')
    eq(U.clamp(-1, 1, 10), 1, 'clamp to the lower bound')
    eq(U.lerp(0, 10, 0.25), 2.5, 'lerp')

    eq(U.indexOf({ 'a', 'b' }, 'b'), 2, 'indexOf finds the position')
    eq(U.contains({ 'a' }, 'z'), false, 'contains says no')
    local arr = { 'a', 'b', 'c' }
    eq(U.removeValue(arr, 'b'), true, 'removeValue reports the removal')
    eq(#arr, 2, 'removeValue shrinks the array')
    eq(U.removeValue(arr, 'zz'), false, 'removeValue on a missing value')
    eq(U.count({ a = 1, b = 2 }), 2, 'count counts keys')
    eq(U.isEmpty({}), true, 'isEmpty')
    eq(#U.keys({ a = 1, b = 2 }), 2, 'keys returns an array')
    eq(U.map({ a = 2 }, function(v) return v * 2 end).a, 4, 'map keeps the keys')
    eq(#U.filter({ 1, 2, 3, 4 }, function(v) return v % 2 == 0 end), 2, 'filter returns an array')
    local found, key = U.find({ a = 5 }, function(v) return v == 5 end)
    eq(found, 5, 'find returns the value')
    eq(key, 'a', 'find returns the key too')

    eq(U.trim('  x  '), 'x', 'trim')
    eq(U.startsWith('hello', 'he'), true, 'startsWith')
    eq(U.endsWith('hello', 'lo'), true, 'endsWith')
    eq(U.endsWith('hello', ''), true, 'endsWith with an empty suffix')
    eq(U.capitalize('hello'), 'Hello', 'capitalize')
    eq(U.truncate('abcdefghij', 5), 'ab...', 'truncate marks the cut')
    eq(U.truncate('abc', 5), 'abc', 'truncate leaves short strings alone')

    eq(#U.uuid(), 32, 'uuid is 32 hex characters')
    check(U.uuid() ~= U.uuid(), 'two uuids differ')
    eq(#U.randomString(8), 8, 'randomString honours the length')
    local n = U.randomInt(3, 3)
    eq(n, 3, 'randomInt with an empty range')
    eq(U.hash(5), 5, 'hash passes numbers through')
    eq(math.type(U.hash('abc')), 'integer', 'hash of a string is an integer')
    eq(U.now(), stubs.now(), 'now() is GetGameTimer()')
    local vec = U.tableToVector3({ x = 1.0, y = 2.0, z = 3.0 })
    eq(xtype(vec), 'vector3', 'tableToVector3 builds a vector')
    eq(U.vector3ToTable(vec).y, 2.0, 'vector3ToTable round trip')
end

--------------------------------------------------------------------------------
-- suite: Core.Math (DESIGN §3.2)
--------------------------------------------------------------------------------

local function suiteMath()
    suite('math')
    stubs.newWorld()
    local _, Core = newVM('server')
    local M = Core.Math

    nearVec(M.headingToDirection(0.0), 0.0, 1.0, 0.0, 'heading 0 looks +Y (north)')
    nearVec(M.headingToDirection(90.0), -1.0, 0.0, 0.0, 'heading 90 looks -X (west)')
    for _, heading in ipairs({ 0.0, 45.0, 90.0, 180.0, 270.0, 359.0 }) do
        near(M.directionToHeading(M.headingToDirection(heading)), heading,
            ('heading %s survives the direction round trip'):format(heading))
    end
    near(M.normalizeHeading(-90.0), 270.0, 'normalizeHeading of a negative angle')
    near(M.normalizeHeading(450.0), 90.0, 'normalizeHeading above 360')

    near(M.distance(vector3(0, 0, 0), vector3(3, 4, 0)), 5.0, 'distance is #(a - b)')
    near(M.distance2d(vector3(0, 0, 10), vector3(3, 4, 0)), 5.0, 'distance2d ignores z')

    nearVec(M.offset(vector3(0, 0, 0), 0.0, 1.0, 0.0, 0.0), 0.0, 1.0, 0.0, 'offset forward at heading 0')
    nearVec(M.offset(vector3(0, 0, 0), 0.0, 0.0, 1.0, 0.0), 1.0, 0.0, 0.0, 'offset right at heading 0')
    nearVec(M.offset(vector3(0, 0, 0), 90.0, 1.0, 0.0, 2.0), -1.0, 0.0, 2.0, 'offset forward at heading 90 plus up')
    nearVec(M.rotationToDirection(vector3(0, 0, 0)), 0.0, 1.0, 0.0, 'rotationToDirection of a zero rotation')

    eq(M.isInsideSphere(vector3(1, 0, 0), vector3(0, 0, 0), 1.0), true, 'isInsideSphere on the surface')
    eq(M.isInsideSphere(vector3(2, 0, 0), vector3(0, 0, 0), 1.0), false, 'isInsideSphere outside')
    eq(M.isInsideBox(vector3(1, 1, 1), vector3(0, 0, 0), vector3(2, 2, 2)), true, 'isInsideBox inside')
    eq(M.isInsideBox(vector3(3, 1, 1), vector3(0, 0, 0), vector3(2, 2, 2)), false, 'isInsideBox outside')
    eq(M.isInsideBox(vector3(1, 1, 1), vector3(2, 2, 2), vector3(0, 0, 0)), true,
        'isInsideBox accepts swapped corners')

    near(M.deg2rad(180.0), math.pi, 'deg2rad')
    near(M.rad2deg(math.pi), 180.0, 'rad2deg')
    nearVec(M.roundVector(vector3(1.234, 5.678, 9.0), 1), 1.2, 5.7, 9.0, 'roundVector with one decimal')
end

--------------------------------------------------------------------------------
-- suite: Core.Validate (DESIGN §3.3) — every spec kind
--------------------------------------------------------------------------------

local function suiteValidate()
    suite('validate')
    stubs.newWorld()
    local _, Core = newVM('server')
    local V = Core.Validate

    local function accepts(spec, value, label)
        local ok, err = V.value(spec, value)
        return check(ok == true, label, ('rejected with: %s'):format(tostring(err)))
    end
    local function rejects(spec, value, label, expectedErr)
        local ok, err = V.value(spec, value)
        if not check(ok == false, label, 'the value was accepted') then return end
        if expectedErr then eq(err, expectedErr, label .. ' — error text') end
    end

    accepts('integer', 5, "'integer' accepts an integer")
    rejects('integer', 5.0, "'integer' rejects a float", 'expected integer, got 5.0')
    rejects('integer', '5', "'integer' rejects a numeric string")
    accepts('number', -2.5, "'number' accepts a float")
    rejects('number', 0 / 0, "'number' rejects NaN")
    rejects('number', math.huge, "'number' rejects infinity")
    accepts('string', 'x', "'string' accepts a non-empty string")
    rejects('string', '', "'string' rejects the empty string by default")
    accepts({ 'string', allowEmpty = true }, '', 'allowEmpty accepts the empty string')
    accepts('boolean', false, "'boolean' accepts false")
    rejects('boolean', 0, "'boolean' rejects 0")
    accepts('table', {}, "'table' accepts a table")
    accepts('function', print, "'function' accepts a function")
    accepts('any', 'whatever', "'any' accepts anything non-nil")
    accepts('vector3', vector3(1, 2, 3), "'vector3' accepts a vector")
    rejects('vector3', { x = 1, y = 2, z = 3 }, "'vector3' rejects a plain table")
    rejects('vector3', vector3(0 / 0, 0, 0), "'vector3' rejects a NaN component")

    accepts('netId', 1, "'netId' accepts 1")
    accepts('netId', 65535, "'netId' accepts 65535")
    rejects('netId', 0, "'netId' rejects 0", 'expected netId 1..65535, got 0')
    rejects('netId', 65536, "'netId' rejects 65536")
    accepts('src', 4096, "'src' accepts 4096")
    rejects('src', 4097, "'src' rejects 4097", 'expected src 1..4096, got 4097')
    rejects('src', -1, "'src' rejects a negative id")

    accepts('id', 'core_example:page-1', "'id' accepts word, dash, underscore and colon")
    rejects('id', 'bad id', "'id' rejects a space")
    rejects('id', string.rep('a', 65), "'id' rejects more than 64 characters")
    rejects('id', '', "'id' rejects the empty string")

    accepts({ 'integer', min = 1, max = 100 }, 50, 'integer range accepts a value inside')
    rejects({ 'integer', min = 1, max = 100 }, -5, 'integer range rejects a value below',
        'expected integer 1..100, got -5')
    rejects({ 'number', min = 0.0 }, -0.5, 'number min', 'expected number >= 0.0, got -0.5')
    rejects({ 'integer', max = 10 }, 11, 'integer max', 'expected integer <= 10, got 11')

    eq(select(2, V.value({ 'integer', min = 'abc' }, 5)), 'invalid spec',
        'a non-numeric bound makes the whole spec invalid')
    eq(select(2, V.value('integer', 'x\ty^3z')), 'expected integer, got "x yz"',
        'an offending string is stripped of control and colour codes before it is logged')

    accepts({ 'string', max = 32, min = 1, pattern = '^[%w_]+$' }, 'name_1', 'string pattern accepts')
    rejects({ 'string', max = 32, min = 1, pattern = '^[%w_]+$' }, 'nope!', 'string pattern rejects')
    rejects({ 'string', min = 3 }, 'ab', 'string min length')
    rejects({ 'string', max = 2 }, 'abc', 'string max length')

    accepts({ 'enum', 'cash', 'bank' }, 'bank', 'enum accepts a listed value')
    rejects({ 'enum', 'cash', 'bank' }, 'crypto', 'enum rejects an unlisted value',
        'expected one of cash|bank, got "crypto"')

    accepts({ 'array', of = 'integer', max = 3 }, { 1, 2, 3 }, 'array accepts matching elements')
    rejects({ 'array', of = 'integer', max = 3 }, { 1, 2, 3, 4 }, 'array honours max')
    rejects({ 'array', of = 'integer' }, { 1, 'x' }, 'array checks every element',
        '[2]: expected integer, got "x"')
    rejects({ 'array', of = 'integer' }, { 1, extra = true }, 'array rejects extra keys')
    rejects({ 'array' }, 'nope', 'array rejects a non-table')

    local personSpec = { 'table', keys = { name = 'string', age = 'integer?' }, max = 4 }
    accepts(personSpec, { name = 'Ada' }, 'table spec accepts an optional key being absent')
    accepts(personSpec, { name = 'Ada', age = 36 }, 'table spec accepts the optional key')
    rejects(personSpec, { age = 36 }, 'table spec reports the missing key',
        'field "name": expected string, got nil')
    rejects(personSpec, { name = 'Ada', a = 1, b = 2, c = 3, d = 4 }, 'table spec honours max keys')
    rejects(personSpec, 'nope', 'table spec rejects a non-table')

    accepts('integer?', nil, 'a trailing ? accepts nil')
    rejects('integer?', 'x', 'a trailing ? still checks the type')
    accepts({ 'integer', optional = true }, nil, 'optional = true accepts nil')
    rejects('integer', nil, 'a required spec rejects nil', 'expected integer, got nil')

    local ok, err = V.value('nosuchkind', 1)
    eq(ok, false, 'an unknown spec kind is refused')
    eq(err, 'invalid spec "nosuchkind"', 'unknown spec error text')
    eq(select(2, V.value(42, 1)), 'invalid spec', 'a non-spec value is refused')
    eq(V.isSpec('integer'), true, 'isSpec knows a real kind')
    eq(V.isSpec('nope'), false, 'isSpec rejects an unknown kind')

    -- check(): positional arguments
    eq(V.check(nil, 1, 2), true, 'check with no schema accepts anything')
    eq(V.check('string', 'x'), true, 'check accepts a single spec as the schema')
    eq(select(2, V.check('string', 5)), 'arg 1: expected string, got 5', 'single spec error names arg 1')
    eq(V.check({ 'string', 'integer' }, 'a', 1), true, 'check accepts matching arguments')
    eq(select(2, V.check({ 'string', { 'integer', min = 1, max = 100 } }, 'a', -5)),
        'arg 2: expected integer 1..100, got -5', 'check numbers the failing argument (DESIGN §3.3)')
    eq(V.check({ 'string', 'integer?' }, 'a'), true, 'check allows a missing optional argument')
    eq(V.check({ 'string' }, 'a', 'extra'), true, 'check ignores extra arguments')
    eq(select(2, V.check(42)), 'invalid schema', 'check refuses a non-table schema')

    -- checkTable(): keyed tables
    eq(V.checkTable({ name = 'string' }, { name = 'Ada', other = 1 }), true,
        'checkTable ignores unknown keys')
    eq(select(2, V.checkTable({ name = 'string' }, { name = 5 })),
        'field "name": expected string, got 5', 'checkTable names the failing field')
    eq(select(2, V.checkTable({ name = 'string' }, 'nope')), 'expected table, got "nope"',
        'checkTable refuses a non-table')

    -- never throws
    local safe = pcall(V.value, { 'string', pattern = '[' }, 'x')
    eq(safe, true, 'a broken pattern does not throw')
    eq(pcall(V.check, { 'integer' }, nil), true, 'check never throws on nil')
end

--------------------------------------------------------------------------------
-- suite: Core.Net server wrapper (DESIGN §3.6)
--------------------------------------------------------------------------------

local function suiteNet()
    suite('net')
    stubs.newWorld()
    stubs.clear()
    local server, Core = newVM('server')
    local client, ClientCore = newVM('client')

    local handled, rejects = {}, {}
    local loaded, granted = false, {}
    -- inside core these are real modules; from a plugin VM the wrapper reaches them
    -- through the export proxy, so the suite stands them in here
    Core.Player = { isLoaded = function(src) return src == 1 and loaded end }
    Core.Perms = { has = function(src, perm) return granted[('%s|%s'):format(src, perm)] == true end }
    stubs.peds[1] = 101
    stubs.coords[101] = vector3(0, 0, 0)
    stubs.aces['1|core.admin'] = nil

    Core.Net.on('t:act', { 'string' }, function(src, text)
        handled[#handled + 1] = { src = src, text = text }
    end, {
        cooldown = 1000,
        requireLoaded = true,
        permission = 'core.admin',
        distance = { coords = vector3(0, 0, 0), max = 5.0 },
        onReject = function(src, reason) rejects[#rejects + 1] = { src = src, reason = reason } end,
    })
    check(server.__vm.netEvents['t:act'] == true, 'Net.on registers a network event')

    local function lastReason()
        local last = rejects[#rejects]
        return last and last.reason
    end

    -- 1. schema is checked first
    client.TriggerServerEvent('t:act', 42)
    eq(#handled, 0, 'a payload that fails the schema never reaches the handler')
    check((lastReason() or ''):find('^schema:') ~= nil, 'schema rejection comes first',
        ('reason was %s'):format(show(lastReason())))
    eq(rejects[#rejects].src, 1, 'onReject gets the src')

    -- 2. cooldown is checked before requireLoaded
    client.TriggerServerEvent('t:act', 'hello')
    eq(lastReason(), 'not loaded', 'requireLoaded rejects an unloaded player')
    client.TriggerServerEvent('t:act', 'hello')
    eq(lastReason(), 'cooldown', 'the cooldown is recorded before the requireLoaded check')

    -- 3. permission is checked after requireLoaded
    stubs.tick(1100)
    loaded = true
    client.TriggerServerEvent('t:act', 'hello')
    eq(lastReason(), 'permission core.admin', 'the permission is checked next')

    -- 4. distance is checked last
    stubs.tick(1100)
    granted['1|core.admin'] = true
    stubs.coords[101] = vector3(50, 0, 0)
    client.TriggerServerEvent('t:act', 'hello')
    eq(lastReason(), 'distance', 'a player too far away is rejected')

    stubs.tick(1100)
    stubs.peds[1] = nil
    client.TriggerServerEvent('t:act', 'hello')
    eq(lastReason(), 'distance: no ped', 'a missing ped is rejected')
    stubs.peds[1] = 101

    -- 5. everything passes: the handler runs with src first
    stubs.tick(1100)
    stubs.coords[101] = vector3(1, 0, 0)
    client.TriggerServerEvent('t:act', 'hello')
    eq(#handled, 1, 'a valid event reaches the handler')
    eq(handled[1].src, 1, 'the handler gets src as its first argument')
    eq(handled[1].text, 'hello', 'the handler gets the payload')

    -- 6. cooldown blocks the repeat; playerDropped clears it
    client.TriggerServerEvent('t:act', 'hello')
    eq(#handled, 1, 'the cooldown blocks an immediate repeat')
    stubs.triggerOn(server, 'playerDropped', 1, 'quit')
    client.TriggerServerEvent('t:act', 'hello')
    eq(#handled, 2, 'playerDropped cleared the per-src cooldown table')

    -- 6b. a failing session lookup fails closed
    local playerModule = rawget(Core, 'Player')
    Core.Player = { isLoaded = function() error('no session store') end }
    stubs.tick(1100)
    client.TriggerServerEvent('t:act', 'hello')
    eq(lastReason(), 'not loaded', 'a failing Core.Player.isLoaded fails closed')
    check(printed('isLoaded(1) failed') ~= nil, 'the failing session lookup is logged')
    Core.Player = playerModule

    -- 6c. a Core.Perms that cannot be reached falls back to the plain ace check
    local permsModule = rawget(Core, 'Perms')
    Core.Perms = { has = function() error('core is not answering') end }
    stubs.tick(1100)
    stubs.aces['1|core.admin'] = true
    client.TriggerServerEvent('t:act', 'hello')
    eq(#handled, 3, 'an unreachable Core.Perms falls back to IsPlayerAceAllowed')
    stubs.tick(1100)
    stubs.aces['1|core.admin'] = nil
    client.TriggerServerEvent('t:act', 'hello')
    eq(lastReason(), 'permission core.admin', 'the ace fallback still refuses without the ace')
    Core.Perms = permsModule

    -- 7. a handler error is caught and logged, not thrown at the dispatcher
    Core.Net.on('t:boom', {}, function() error('kaboom') end,
        { cooldown = 0, requireLoaded = false })
    client.TriggerServerEvent('t:boom')
    check(printed('net t:boom handler errored') ~= nil, 'a handler error is caught and logged')
    eq(#stubs.failures, 0, 'no error escaped into the event dispatcher')

    -- 8. a distance function resolves the coords from the payload
    local distHandled = 0
    Core.Net.on('t:at', { 'vector3' }, function() distHandled = distHandled + 1 end, {
        cooldown = 0,
        requireLoaded = false,
        distance = { coords = function(_, coords) return coords end, max = 5.0 },
    })
    client.TriggerServerEvent('t:at', vector3(1, 1, 0))
    eq(distHandled, 1, 'distance.coords may be a function of the payload')
    client.TriggerServerEvent('t:at', vector3(80, 0, 0))
    eq(distHandled, 1, 'the payload-derived distance is enforced')

    -- 9. emit / broadcast
    stubs.clear()
    Core.Net.emit(1, 'srv:msg', 'hi')
    eq(stubs.sent[#stubs.sent].name, 'srv:msg', 'Net.emit sends the event')
    eq(stubs.sent[#stubs.sent].target, 1, 'Net.emit targets one client')
    Core.Net.broadcast('srv:all', 1)
    eq(stubs.sent[#stubs.sent].target, -1, 'Net.broadcast targets everyone')
    local before = #stubs.sent
    Core.Net.emit(-1, 'srv:bad')
    eq(#stubs.sent, before, 'Net.emit refuses an invalid src')
    check(printed('Net.emit: invalid src') ~= nil, 'the invalid src is logged')

    -- 9b. emitMany: scoped delivery. Without msgpack in the VM it falls back to one plain call per target.
    before = #stubs.sent
    eq(Core.Net.emitMany({ 1, 2, 'x', 0, 3 }, 'srv:near', 'payload'), 3, 'emitMany counts the valid targets')
    eq(#stubs.sent - before, 3, 'emitMany sends once per valid target')
    eq(stubs.sent[before + 1].target, 1, 'emitMany keeps the target order')
    eq(stubs.sent[#stubs.sent].target, 3, 'emitMany skips entries that are not a positive integer')
    eq(stubs.sent[#stubs.sent].name, 'srv:near', 'emitMany sends the event name')
    eq(Core.Net.emitMany({}, 'srv:near'), 0, 'emitMany with nobody in scope sends nothing')
    eq(Core.Net.emitMany('nope', 'srv:near'), 0, 'emitMany refuses a non-table target list')
    check(printed('Net.emitMany: targets must be an array') ~= nil, 'the bad target list is logged')
    eq(Core.Net.emitMany({ 1 }, ''), 0, 'emitMany refuses an empty event name')

    -- With the runtime's msgpack the payload is packed ONCE and handed to the internal native per target.
    local packs, internal = 0, {}
    server.msgpack = { pack_args = function(...) packs = packs + 1; return 'PACKED' .. select('#', ...) end }
    server.TriggerClientEventInternal = function(name, target, payload, length)
        internal[#internal + 1] = { name = name, target = target, payload = payload, length = length }
    end
    before = #stubs.sent
    eq(Core.Net.emitMany({ 4, 5, 6 }, 'srv:near', 'a', 'b'), 3, 'emitMany (packed) counts its targets')
    eq(packs, 1, 'the payload is packed once for every target')
    eq(#internal, 3, 'one internal native call per target')
    eq(internal[2].target, 5, 'the internal call carries the target')
    eq(internal[2].payload, 'PACKED2', 'every target gets the same packed payload')
    eq(internal[2].length, #'PACKED2', 'the payload length is passed along')
    eq(#stubs.sent, before, 'the packed path never goes through TriggerClientEvent')
    server.msgpack, server.TriggerClientEventInternal = nil, nil
    Core.Net.on(123, {}, function() end)
    check(printed('Net.on: invalid event name') ~= nil, 'Net.on refuses a non-string name')
    Core.Net.on('t:nofn', {}, 'nope')
    check(printed('is not a function') ~= nil, 'Net.on refuses a non-function handler')

    -- 10. the client half schema-checks server -> client payloads
    local fromServer = {}
    ClientCore.Net.on('srv:push', { 'integer' }, function(value)
        fromServer[#fromServer + 1] = value
    end)
    Core.Net.emit(1, 'srv:push', 7)
    eq(fromServer[1], 7, 'a valid server payload reaches the client handler')
    Core.Net.emit(1, 'srv:push', 'nope')
    eq(#fromServer, 1, 'the client drops a payload that fails the schema')
    check(printed('srv:push: bad payload') ~= nil, 'the bad client payload is logged as a warning')
    ClientCore.Net.emit('cl:ping', 1)
    eq(stubs.sent[#stubs.sent].side, 'server', 'client Net.emit goes to the server')
end

--------------------------------------------------------------------------------
-- suite: Core.Callback across two VMs (DESIGN §3.5)
--------------------------------------------------------------------------------

local function suiteCallback()
    suite('callback')
    stubs.newWorld()
    stubs.clear()
    local server, Core = newVM('server')
    local client, ClientCore = newVM('client')

    Core.Callback.register('t:double', function(src, n) return n * 2, src end)
    check(server.__vm.netEvents['core:cb:req:t:double'] == true,
        'register listens on core:cb:req:<name>')

    local answer = {}
    client.CreateThread(function()
        answer.value, answer.src = ClientCore.Callback.await('t:double', 21)
    end)
    eq(answer.value, 42, 'await returns the handler result')
    eq(answer.src, 1, 'the server handler sees the calling src')
    check(client.__vm.netEvents['core:cb:res:t:double'] == true,
        'the response event is registered lazily on the client')

    -- a second call reuses the registration and gets a fresh key
    client.CreateThread(function() answer.second = ClientCore.Callback.await('t:double', 1) end)
    eq(answer.second, 2, 'a second await works with the same name')

    -- a handler error answers nil
    Core.Callback.register('t:err', function() error('nope') end)
    local errored = 'unset'
    client.CreateThread(function() errored = ClientCore.Callback.await('t:err') end)
    eq(errored, nil, 'a handler error answers nil')
    check(printed('callback t:err errored') ~= nil, 'the handler error is logged server-side')

    -- timeout: the request never arrives
    stubs.net.drop = true
    local timedOut = 'unset'
    client.CreateThread(function() timedOut = ClientCore.Callback.await('t:double', 1) end)
    eq(timedOut, 'unset', 'await suspends until an answer or the timeout')
    stubs.tick(Core.Config.CallbackTimeoutMs + 100)
    eq(timedOut, nil, 'await returns nil after Config.CallbackTimeoutMs')
    stubs.net.drop = false

    -- rate limit: Config.RateLimits.CallbackPerSecond requests per src
    local runs = 0
    Core.Callback.register('t:count', function() runs = runs + 1 return runs end)
    Core.Config.RateLimits.CallbackPerSecond = 2
    local limited = { [3] = 'unset' }
    client.CreateThread(function()
        limited[1] = ClientCore.Callback.await('t:count')
        limited[2] = ClientCore.Callback.await('t:count')
        limited[3] = ClientCore.Callback.await('t:count')
    end)
    eq(limited[1], 1, 'the first request is answered')
    eq(limited[2], 2, 'the second request is answered')
    eq(runs, 2, 'the third request never reaches the handler (rate limited)')
    eq(limited[3], 'unset', 'the rate-limited request is simply not answered')
    stubs.tick(Core.Config.CallbackTimeoutMs + 100)
    eq(limited[3], nil, 'the rate-limited request ends in a timeout')
    Core.Config.RateLimits.CallbackPerSecond = 20

    -- an optional schema (DESIGN §3.3) is checked before the handler runs
    local schemaRuns = 0
    Core.Callback.register('t:schema', { 'id' }, function(_, id)
        schemaRuns = schemaRuns + 1
        return id
    end)
    local good, bad = 'unset', 'unset'
    client.CreateThread(function() good = ClientCore.Callback.await('t:schema', 'doc-1') end)
    eq(good, 'doc-1', 'a callback schema lets a valid payload through')
    client.CreateThread(function() bad = ClientCore.Callback.await('t:schema', 42) end)
    eq(bad, nil, 'a callback schema answers nil for a bad payload')
    eq(schemaRuns, 1, 'the handler never saw the bad payload')

    -- server -> client
    ClientCore.Callback.register('t:ping', function(word) return 'pong-' .. word end)
    local fromClient = 'unset'
    server.CreateThread(function() fromClient = Core.Callback.awaitClient(1, 't:ping', 'x') end)
    eq(fromClient, 'pong-x', 'awaitClient asks one client and gets the answer back')
    eq(Core.Callback.awaitClient(0, 't:ping'), nil, 'awaitClient refuses src 0')
    eq(Core.Callback.awaitClient(1, 42), nil, 'awaitClient refuses a non-string name')

    -- a pending awaitClient resolves to nil when that player drops
    stubs.net.drop = true
    local dropped = 'unset'
    server.CreateThread(function() dropped = Core.Callback.awaitClient(1, 't:ping', 'y') end)
    eq(dropped, 'unset', 'awaitClient suspends while waiting')
    stubs.triggerOn(server, 'playerDropped', 1, 'quit')
    eq(dropped, nil, 'playerDropped resolves the pending request with nil')
    stubs.net.drop = false

    -- bad registrations are refused, not thrown
    Core.Callback.register('', function() end)
    check(printed('Callback.register: invalid name') ~= nil, 'register refuses an empty name')
    Core.Callback.register('t:x', 'nope')
    check(printed('is not a function') ~= nil, 'register refuses a non-function handler')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

--------------------------------------------------------------------------------
-- suite: Core.Commands (DESIGN §3.7)
--------------------------------------------------------------------------------

local function suiteCommands()
    suite('commands')
    stubs.newWorld()
    stubs.clear()
    local server, Core = newVM('server')

    local notifies = {}
    Core.Notify = { send = function(src, message, kind)
        notifies[#notifies + 1] = { src = src, message = message, kind = kind }
    end }
    local granted = {}
    Core.Perms = { has = function(src, permission)
        if src == 0 then return true end      -- the console always passes (DESIGN §3.7)
        return granted[('%s|%s'):format(src, permission)] == true
    end }
    local function lastNotify()
        local last = notifies[#notifies]
        return last and last.message
    end

    local seen = {}
    Core.Commands.register('give', {
        description = 'Give money',
        permission = 'core.admin',
        params = {
            { name = 'target', type = 'player', help = 'server id' },
            { name = 'amount', type = 'integer' },
            { name = 'reason', type = 'rest', optional = true },
        },
    }, function(src, args, raw) seen[#seen + 1] = { src = src, args = args, raw = raw } end)

    local give = server.__vm.commands['give']
    check(give ~= nil, 'register calls RegisterCommand')
    eq(give.restricted, false, 'the command stays unrestricted (Core.Perms.has guards it)')
    stubs.playerNames[2] = 'Bob'

    -- permission
    give.fn(1, { '2', '50' }, '/give 2 50')
    eq(#seen, 0, 'the handler does not run without the permission')
    eq(lastNotify(), 'You are not allowed to do that', 'the caller is told about the permission')
    eq(notifies[#notifies].kind, 'error', 'refusals are sent as errors')
    granted['1|core.admin'] = true

    -- typed parsing
    give.fn(1, { '2', '50', 'for', 'the', 'win' }, '/give 2 50 for the win')
    eq(#seen, 1, 'the handler runs once the permission is there')
    eq(seen[1].src, 1, 'the handler gets the caller src')
    eq(seen[1].args.target, 2, 'a player param parses to the server id')
    eq(math.type(seen[1].args.target), 'integer', 'a player param is an integer')
    eq(seen[1].args.amount, 50, 'an integer param parses')
    eq(seen[1].args.reason, 'for the win', 'a rest param takes the remainder of the line')
    eq(seen[1].raw, '/give 2 50 for the win', 'the handler gets the raw line')

    -- bad arguments -> usage
    give.fn(1, { 'abc' }, '/give abc')
    eq(#seen, 1, 'a bad argument stops the handler')
    eq(lastNotify(), 'Usage: /give <target> <amount> [reason]', 'the usage line lists the params')
    give.fn(1, { '99', '5' }, '/give 99 5')
    eq(lastNotify(), 'Usage: /give <target> <amount> [reason]',
        'a player id that is not connected fails the player param')
    give.fn(1, { '2', '5.5' }, '/give 2 5.5')
    eq(lastNotify(), 'Usage: /give <target> <amount> [reason]', 'a float fails an integer param')
    give.fn(1, { '2' }, '/give 2')
    eq(lastNotify(), 'Usage: /give <target> <amount> [reason]', 'a missing required param fails')

    -- console
    local beforeConsole = #notifies
    give.fn(0, { '2', '10' }, '/give 2 10')
    eq(seen[#seen].src, 0, 'the console runs the command with src 0')
    give.fn(0, { 'abc' }, '/give abc')
    eq(#notifies, beforeConsole, 'the console is answered by print, not by Core.Notify')
    check(printed('[core] Usage: /give') ~= nil, 'the console gets the usage line printed')
    Core.Commands.register('noconsole', { allowConsole = false }, function()
        seen[#seen + 1] = { console = true }
    end)
    server.__vm.commands['noconsole'].fn(0, {}, '/noconsole')
    check(printed('cannot be run from the console') ~= nil, 'allowConsole = false refuses src 0')

    -- boolean and number params
    local toggled = {}
    Core.Commands.register('toggle', {
        params = { { name = 'on', type = 'boolean' }, { name = 'amount', type = 'number' } },
    }, function(_, args) toggled[#toggled + 1] = args end)
    local toggle = server.__vm.commands['toggle']
    toggle.fn(1, { 'on', '2.5' }, '/toggle on 2.5')
    eq(toggled[1].on, true, "'on' parses as boolean true")
    eq(toggled[1].amount, 2.5, 'a number param keeps its decimals')
    toggle.fn(1, { 'off', '2' }, '/toggle off 2')
    eq(toggled[2].on, false, "'off' parses as boolean false")
    eq(math.type(toggled[2].amount), 'float', 'a number param is always a float')
    toggle.fn(1, { 'maybe', '1' }, '/toggle maybe 1')
    eq(#toggled, 2, 'an unparseable boolean stops the handler')
    eq(lastNotify(), 'Usage: /toggle <on> <amount>', 'the usage line for a command without optionals')

    -- declaration errors
    eq(pcall(Core.Commands.register, 'bad', {
        params = { { name = 'a', type = 'rest' }, { name = 'b' } },
    }, function() end), false, 'a rest param must be the last one')
    eq(pcall(Core.Commands.register, 'bad2', {
        params = { { name = 'a', type = 'weird' } },
    }, function() end), false, 'an unknown param type is refused')
    eq(pcall(Core.Commands.register, 'two words', {}, function() end), false,
        'a command name must be a single word')
    eq(pcall(Core.Commands.register, 'nofn', {}, 'nope'), false, 'the handler must be a function')

    -- unregister
    eq(Core.Commands.unregister('toggle'), true, 'unregister removes a known command')
    eq(Core.Commands.unregister('toggle'), false, 'unregister of an unknown command is false')

    -- chat suggestions are sent per player, never broadcast
    stubs.clear()
    stubs.triggerOn(server, 'core:hook:playerLoaded', 0, 1)
    local suggestion, broadcast
    for i = 1, #stubs.sent do
        local packet = stubs.sent[i]
        if packet.name == 'chat:addSuggestion' then
            if packet.args[1] == '/give' then suggestion = packet end
            if packet.target == -1 then broadcast = packet end
        end
    end
    check(suggestion ~= nil, 'playerLoaded pushes a suggestion for an allowed command')
    eq(suggestion and suggestion.target, 1, 'the suggestion is targeted at that src')
    eq(suggestion and suggestion.args[2], 'Give money', 'the suggestion carries the description')
    eq(suggestion and suggestion.args[3][1].name, '<target>', 'required params render as <name>')
    eq(suggestion and suggestion.args[3][3].name, '[reason]', 'optional params render as [name]')
    eq(suggestion and suggestion.args[3][1].type, 'player', 'suggestions retain the player argument type')
    eq(suggestion and suggestion.args[3][3].type, 'rest', 'suggestions retain multiword arguments')
    eq(suggestion and suggestion.args[3][3].optional, true, 'suggestions retain optional status')
    eq(broadcast, nil, 'suggestions are never broadcast to -1')
    granted['1|core.admin'] = false
    stubs.clear()
    stubs.triggerOn(server, 'core:hook:playerLoaded', 0, 1)
    local hidden = false
    for i = 1, #stubs.sent do
        if stubs.sent[i].args[1] == '/give' then hidden = true end
    end
    eq(hidden, false, 'a command the player may not use is not suggested')

    stubs.clear()
    stubs.triggerOn(server, 'core:hook:chatSuggestionsRequested', 0, 1)
    local snapshot
    for _, packet in ipairs(stubs.sent) do
        if packet.name == 'core:client:chat' then snapshot = packet end
    end
    eq(snapshot and snapshot.target, 1, 'plugin command snapshots are targeted')
    eq(snapshot and snapshot.args[1].owner, 'core_example', 'plugin snapshot identifies its owner')
    local leaks = false
    for _, item in ipairs(snapshot and snapshot.args[1].items or {}) do
        if item.command == '/give' then leaks = true end
    end
    eq(leaks, false, 'plugin command snapshots also enforce permissions')
end

--------------------------------------------------------------------------------
-- suite: Core.Keys (DESIGN §3.8)
--------------------------------------------------------------------------------

local function suiteKeys()
    suite('keys')
    stubs.newWorld()
    stubs.clear()
    stubs.tick(1000)          -- GetGameTimer() is never 0 in game; start past the debounce window
    local client, Core = newVM('client')

    local presses, releases = 0, 0
    local command = Core.Keys.register({
        name = 'menu', description = 'Open the menu', key = 'F5', mapper = 'keyboard',
        debounce = 250,
        onPress = function() presses = presses + 1 end,
        onRelease = function() releases = releases + 1 end,
    })
    eq(command, '+core_example_menu', 'register returns the + command name')
    check(client.__vm.commands['+core_example_menu'] ~= nil, 'the + command is registered')
    check(client.__vm.commands['-core_example_menu'] ~= nil, 'the - command is registered')
    local mapping = client.__vm.keyMappings['+core_example_menu']
    check(mapping ~= nil, 'the + command is key-mapped')
    eq(mapping and mapping.description, 'Open the menu', 'the mapping carries the description')
    eq(mapping and mapping.mapper, 'keyboard', 'the mapping carries the mapper')
    eq(mapping and mapping.key, 'F5', 'the mapping carries the default key')
    eq(client.__vm.keyMappings['-core_example_menu'], nil, 'only the + command is mapped')

    local press = client.__vm.commands['+core_example_menu'].fn
    local release = client.__vm.commands['-core_example_menu'].fn

    press()
    eq(presses, 1, 'a press runs onPress')
    eq(Core.Keys.isDown(command), true, 'isDown while the key is held')
    press()
    eq(presses, 1, 'a repeat press while held does nothing')
    release()
    eq(releases, 1, 'the - command runs onRelease')
    eq(Core.Keys.isDown(command), false, 'isDown is false after the release')
    release()
    eq(releases, 1, 'a release without a press does nothing')

    press()
    eq(presses, 1, 'a press inside the debounce window is swallowed')
    stubs.tick(300)
    press()
    eq(presses, 2, 'a press after the debounce window runs again')
    release()

    stubs.tick(300)
    stubs.nuiFocused = true
    press()
    eq(presses, 2, 'presses are ignored while the NUI has focus')
    local focusPresses = 0
    Core.Keys.register({ name = 'chat', key = 'T', whileFocused = true,
        onPress = function() focusPresses = focusPresses + 1 end })
    client.__vm.commands['+core_example_chat'].fn()
    eq(focusPresses, 1, 'whileFocused bindings still fire with the NUI focused')
    stubs.nuiFocused = false

    stubs.tick(300)
    stubs.pauseMenu = true
    press()
    eq(presses, 2, 'presses are ignored while the pause menu is open')
    stubs.pauseMenu = false

    -- a key-up that never arrived (alt-tab while held) is recovered on the next press
    stubs.tick(300)
    press()
    eq(presses, 3, 'the key goes down again after the debounce window')
    local staleReleases = releases
    stubs.tick(6000)
    press()
    eq(releases, staleReleases + 1, 'a stale down state is released on the next press')
    eq(presses, 4, 'the press that recovered the stale state still counts')
    release()

    eq(pcall(Core.Keys.register, { name = 'menu', onPress = function() end }), false,
        'registering the same name twice errors')
    eq(pcall(Core.Keys.register, { name = 'nofn' }), false, 'onPress must be a function')
    eq(pcall(Core.Keys.register, 'nope'), false, 'opts must be a table')

    Core.Keys.register({ name = 'boom', onPress = function() error('x') end })
    client.__vm.commands['+core_example_boom'].fn()
    check(printed('key binding +core_example_boom failed') ~= nil,
        'an erroring callback is caught and logged')
    eq(#stubs.failures, 0, 'the key handler never throws at the engine')
end

--------------------------------------------------------------------------------
-- suite: Core.Log (DESIGN §3.4)
--------------------------------------------------------------------------------

local function suiteLog()
    suite('log')
    stubs.newWorld()
    stubs.clear()
    local server, Core = newVM('server')

    Core.Config.Debug = false
    local before = #stubs.printed
    Core.Log.debug('hidden %s', 'x')
    eq(#stubs.printed, before, 'debug is a no-op while Core.Config.Debug is false')
    Core.Config.Debug = true
    Core.Log.debug('shown %d', 7)
    eq(lastPrinted(), '[core:core_example] debug: shown 7', 'debug prints once Debug is on')

    Core.Log.info('hello %s', 'world')
    eq(lastPrinted(), '[core:core_example] info: hello world', 'info formats and tags the resource')
    Core.Log.warn('careful')
    eq(lastPrinted(), '^3[core:core_example] warn: careful^7', 'warn is yellow')
    Core.Log.error('boom')
    eq(lastPrinted(), '^1[core:core_example] error: boom^7', 'error is red')
    Core.Log.info('%d items', 'abc')
    check((lastPrinted() or ''):find('<invalid format arguments>', 1, true) ~= nil,
        'bad format arguments never throw')
    Core.Log.info('100% sure')
    eq(lastPrinted(), '[core:core_example] info: 100% sure', 'a lone % without arguments is safe')

    local audits = {}
    Core.on('audit', function(category, src, message)
        audits[#audits + 1] = { category = category, src = src, message = message }
    end)
    eq(Core.Log.audit('money', 1, 'paid %d', 50), true, 'audit writes on the server')
    eq(lastPrinted(), '[core:audit] money src=1 paid 50', 'the audit line carries category and src')
    eq(#audits, 1, 'audit emits the core:hook:audit hook')
    eq(audits[1].category, 'money', 'the hook gets the category')
    eq(audits[1].src, 1, 'the hook gets the src')
    eq(audits[1].message, 'paid 50', 'the hook gets the formatted message')

    local _, ClientCore = newVM('client')
    before = #stubs.printed
    eq(ClientCore.Log.audit('money', 1, 'x'), false, 'audit is server-only')
    eq(#stubs.printed, before, 'the client audit prints nothing')
    ClientCore.Log.warn('client side')
    eq(lastPrinted(), '^3[core:core_example] warn: client side^7', 'the client logs the same way')
end

--------------------------------------------------------------------------------
-- suite: readiness, restarts and playerLoaded (DESIGN §2.4)
--------------------------------------------------------------------------------

local function suiteReady()
    suite('ready')
    stubs.newWorld()
    stubs.clear()
    stubs.resourceStates.core = 'started'
    local env, Core = newVM('server')

    local runs = 0
    Core.onReady(function() runs = runs + 1 end)
    eq(runs, 1, 'onReady runs at once while core is started')
    stubs.triggerOn(env, 'onResourceStart', 0, 'core_example')
    eq(runs, 1, "another resource's start does not re-fire onReady")
    stubs.triggerOn(env, 'onResourceStop', 0, 'core')
    stubs.triggerOn(env, 'onResourceStart', 0, 'core')
    eq(runs, 2, 'every callback runs again after a core restart')
    local late = 0
    Core.onReady(function() late = late + 1 end)
    eq(late, 1, 'a callback registered while core is up runs immediately')
    eq(runs, 2, 'the earlier callbacks are not run a second time')
    eq(Core.onReady('nope'), nil, 'onReady ignores a non-function')
    Core.onReady(function() error('bad callback') end)
    check(printed('onReady callback failed') ~= nil, 'an erroring onReady callback is caught')

    -- core not started yet: one poll thread waits for it
    stubs.newWorld()
    stubs.resourceStates.core = 'starting'
    local _, Late = newVM('server')
    local waited = 0
    Late.onReady(function() waited = waited + 1 end)
    eq(waited, 0, 'onReady waits while core is not started')
    stubs.tick(300)
    eq(waited, 0, 'it keeps waiting while GetResourceState is not "started"')
    stubs.resourceStates.core = 'started'
    stubs.tick(200)
    eq(waited, 1, 'the poll thread dispatches once core reports started')

    -- client sugar: onPlayerLoaded
    stubs.newWorld()
    local client, ClientCore = newVM('client')
    local loaded = 0
    ClientCore.onPlayerLoaded(function() loaded = loaded + 1 end)
    eq(loaded, 0, 'onPlayerLoaded waits for the hook while the player is not loaded')
    stubs.triggerOn(client, 'core:hook:playerLoaded', 0)
    eq(loaded, 1, 'the playerLoaded hook runs the callback')
    client.LocalPlayer.state.loaded = true
    ClientCore.onPlayerLoaded(function() loaded = loaded + 1 end)
    eq(loaded, 2, 'onPlayerLoaded runs at once when the player is already loaded')
end

--------------------------------------------------------------------------------
-- runner
--------------------------------------------------------------------------------

local suites = {
    { 'import', suiteImport },
    { 'ready', suiteReady },
    { 'utils', suiteUtils },
    { 'math', suiteMath },
    { 'validate', suiteValidate },
    { 'net', suiteNet },
    { 'callback', suiteCallback },
    { 'commands', suiteCommands },
    { 'keys', suiteKeys },
    { 'log', suiteLog },
}

for i = 1, #suites do
    local name, fn = suites[i][1], suites[i][2]
    local ok, err = pcall(fn)
    if not ok then
        suiteName = name
        check(false, 'the suite crashed', tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, failed))
if failed > 0 then
    print(('%d failing check(s):'):format(#failures))
    for i = 1, #failures do print('  ' .. failures[i]:gsub('\n%s+', ' -- ')) end
    os.exit(1)
end
os.exit(0)
