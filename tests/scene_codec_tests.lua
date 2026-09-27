--[[
    core/tests/scene_codec_tests.lua — offline suite for Core.SceneCodec (DESIGN §55.8, scene INTERFACES §2).

        lua5.4 tests/scene_codec_tests.lua    (from the resource directory, or from tests/)

    Encodes in a server VM and decodes in a client VM (both core's, no runtime msgpack → the built-in subset):
    constants, quantisation edges (negative coords, rotation normalisation, ±0, clamping, NaN/inf), every op
    round-tripped with edge values, s1/s2 limits, integer-field range errors, CELL/PRIV section accounting and
    the reused ctx, a stream of 1,000 mixed ops, truncation at every byte offset (never raises), unknown opcodes,
    hostile blobs, the msgpack subset against byte strings of the msgpack spec, the switch to the runtime's
    `msgpack` global, and a throughput line (encode + decode of 10,000 PUTs). Exit code 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/scene_codec_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local passed, failed = 0, 0

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
    print(('FAIL  [scene_codec] %s%s'):format(label, detail and ('\n        ' .. detail) or ''))
    return false
end

local function eq(actual, expected, label)
    return check(actual == expected, label, ('expected %s, got %s'):format(show(expected), show(actual)))
end

local function near(actual, expected, label, tolerance)
    return check(type(actual) == 'number' and math.abs(actual - expected) <= (tolerance or 1e-9), label,
        ('expected ~%s, got %s'):format(show(expected), show(actual)))
end

local function hex(s)
    return (s:gsub('.', function(c) return ('%02X '):format(c:byte()) end)):gsub(' $', '')
end

local function bytes(spec)   -- 'CB 3F F8' → the raw string
    return (spec:gsub('%s', ''):gsub('%x%x', function(h) return string.char(tonumber(h, 16)) end))
end

--- A core VM with import.lua and the codec; `before(env)` runs first (e.g. to install a fake msgpack).
local function newVM(side, before)
    local env = stubs.newEnv(side, 'core')
    if before then before(env) end
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/scene_codec.lua')
    return env, env.Core.SceneCodec
end

local OPS = { 'header', 'kinds', 'sub', 'unsub', 'cell', 'priv', 'reset', 'put', 'set', 'move', 'motion', 'del',
    'event', 'dr', 'promote', 'demote' }

--- A handler table recording every call: log[i] = { name, args (packed), ctx snapshot for node ops }.
local function recorder()
    local log, h = {}, {}
    for _, name in ipairs(OPS) do
        h[name] = function(...)
            local args = table.pack(...)
            local entry = { name = name, args = args }
            local last = args[args.n]
            if type(last) == 'table' and last.section ~= nil then
                entry.ctx = last
                entry.section, entry.grid, entry.key = last.section, last.grid, last.key
                entry.variant, entry.from, entry.to = last.variant, last.from, last.to
            end
            log[#log + 1] = entry
        end
    end
    return h, log
end

stubs.newWorld()
stubs.clear()
local _, S = newVM('server')     -- encodes
local _, C = newVM('client')     -- decodes

--------------------------------------------------------------------------------
-- constants
--------------------------------------------------------------------------------

eq(S.VERSION, 1, 'format version 1')
eq(S.nativeMsgpack, false, 'no runtime msgpack in the stub VM: the built-in subset is active')
local codes = { KINDS = 1, SUB = 2, UNSUB = 3, CELL = 4, PRIV = 5, RESET = 6, PUT = 16, SET = 17, MOVE = 18,
    MOTION = 19, DEL = 20, EVENT = 21, DR = 22, PROMOTE = 23, DEMOTE = 24 }
for name, code in pairs(codes) do
    eq(S.OP[name], code, 'OP.' .. name)
    eq(S.OP_NAME[code], name, 'OP_NAME[' .. code .. ']')
end
check(S.GRID.NEAR == 0 and S.GRID.FAR == 1 and S.GRID.GLOBAL == 2, 'GRID codes')
check(S.VARIANT.NEAR == 1 and S.VARIANT.FAR == 2 and S.VARIANT.ONE == 3, 'VARIANT codes')
check(S.DEL.NORMAL == 0 and S.DEL.HANDOVER == 1 and S.DEL.FADE == 2, 'DEL codes')
check(S.RESET.BUCKET == 1 and S.RESET.EPOCH == 2 and S.RESET.RESYNC == 3, 'RESET reasons')
check(S.FLAG.MOTION == 1 and S.FLAG.PROMOTED == 2 and S.FLAG.PLACEHOLDER == 4 and S.FLAG.FAR == 8
    and S.FLAG.INTERACT == 16 and S.FLAG.GATED == 32 and S.FLAG.CHILDREN == 64, 'FLAG bits')
for name, code in pairs(S.CLASS) do eq(S.CLASS_NAME[code], name, 'CLASS_NAME inverts CLASS.' .. name) end
eq(#S.CLASS_NAME, 7, 'seven classes')

--------------------------------------------------------------------------------
-- quantisation
--------------------------------------------------------------------------------

local nan, inf = 0 / 0, math.huge
eq(S.qpos(1.234), 123, 'qpos: metres → centimetres')
eq(S.qpos(-1234.567), -123457, 'qpos: negative coordinates round to the nearest cm')
eq(S.qpos(0.125), 13, 'qpos: a half rounds up')
eq(S.qpos(-0.125), -12, 'qpos: a negative half rounds up too')
eq(math.type(S.qpos(2.5)), 'integer', 'qpos answers an integer')
eq(S.qpos(0), 0, 'qpos(0)')
eq(S.qpos(-0.0), 0, 'qpos(-0)')
eq(S.qpos(nan), 0, 'qpos(NaN) = 0')
eq(S.qpos(inf), 0, 'qpos(+inf) = 0')
eq(S.qpos(-inf), 0, 'qpos(-inf) = 0')
eq(S.qpos('5'), 0, 'qpos of a non-number = 0')
eq(S.qpos(1e12), 2147483647, 'qpos clamps to the i32 maximum')
eq(S.qpos(-1e12), -2147483648, 'qpos clamps to the i32 minimum')
eq(S.qrot(90), 9000, 'qrot: degrees → centi-degrees')
eq(S.qrot(180), 18000, 'qrot(180) stays 18000')
eq(S.qrot(-180), 18000, 'qrot(-180) normalises to +180 (the range is (-180, 180])')
eq(S.qrot(190), -17000, 'qrot(190) = -170')
eq(S.qrot(-190), 17000, 'qrot(-190) = 170')
eq(S.qrot(540), 18000, 'qrot(540) = 180')
eq(S.qrot(-720.25), -25, 'qrot of several turns')
eq(S.qrot(359.999), 0, 'qrot(359.999) rounds to 0, never 36000')
eq(S.qrot(-0.004), 0, 'qrot(-0.004) rounds to 0')
eq(S.qrot(180.006), -17999, 'qrot just past 180 wraps negative')
eq(S.qrot(-0.0), 0, 'qrot(-0) = 0')
eq(S.qrot(nan), 0, 'qrot(NaN) = 0')
eq(S.qrot(inf), 0, 'qrot(inf) = 0')
local big = S.qrot(1e300)
check(math.type(big) == 'integer' and big > -18000 and big <= 18000, 'qrot(1e300) stays in range')
eq(S.qvel(1.5), 150, 'qvel: m/s → cm/s')
eq(S.qvel(-2.344), -234, 'qvel negative')
eq(S.qvel(1000), 32767, 'qvel clamps to the i16 maximum')
eq(S.qvel(-1000), -32768, 'qvel clamps to the i16 minimum')
eq(S.qvel(nan), 0, 'qvel(NaN) = 0')
eq(S.upos(-123457), -1234.57, 'upos inverts qpos')
eq(S.urot(-17000), -170.0, 'urot inverts qrot')
eq(S.uvel(150), 1.5, 'uvel inverts qvel')

--------------------------------------------------------------------------------
-- msgpack subset: bytes of the msgpack spec (and of FiveM's lua-cmsgpack defaults)
--------------------------------------------------------------------------------

local P = S.msgpackLua.pack
local cases = {
    { { 1, 2, 3 }, '93 01 02 03', 'fixarray {1,2,3}' },
    { { a = 1 }, '81 A1 61 01', 'fixmap {a=1}' },
    { 1.5, 'CB 3F F8 00 00 00 00 00 00', 'float64 1.5' },
    { 1.0, 'CB 3F F0 00 00 00 00 00 00', 'a float with an integral value stays float64' },
    { {}, '90', 'the empty table is an empty array (EMPTY_AS_ARRAY)' },
    { true, 'C3', 'true' }, { false, 'C2', 'false' }, { nil, 'C0', 'nil' },
    { 0, '00', 'positive fixint 0' }, { 127, '7F', 'positive fixint 127' },
    { 128, 'CC 80', 'uint8 128' }, { 255, 'CC FF', 'uint8 255' },
    { 256, 'CD 01 00', 'uint16 256' }, { 65535, 'CD FF FF', 'uint16 65535' },
    { 65536, 'CE 00 01 00 00', 'uint32 65536' }, { 4294967295, 'CE FF FF FF FF', 'uint32 max' },
    { 4294967296, 'CF 00 00 00 01 00 00 00 00', 'uint64 2^32' },
    { -1, 'FF', 'negative fixint -1' }, { -32, 'E0', 'negative fixint -32' },
    { -33, 'D0 DF', 'int8 -33' }, { -128, 'D0 80', 'int8 -128' },
    { -129, 'D1 FF 7F', 'int16 -129' }, { -32768, 'D1 80 00', 'int16 -32768' },
    { -32769, 'D2 FF FF 7F FF', 'int32 -32769' }, { -2147483648, 'D2 80 00 00 00', 'int32 min' },
    { -2147483649, 'D3 FF FF FF FF 7F FF FF FF', 'int64 below int32' },
    { '', 'A0', 'empty fixstr' }, { 'a', 'A1 61', 'fixstr' },
    { { 1, 2, nil, 4 }, nil, 'a list with a hole is a map (ARRAY_WITHOUT_HOLES)', '83' },
    { { [0] = 1, [17] = true }, nil, 'integer keys that are not 1..n form a map', '82' },
}
for _, c in ipairs(cases) do
    local got = P(c[1])
    if c[2] then
        eq(hex(got), c[2], 'msgpack ' .. c[3])
    else
        eq(hex(got:sub(1, 1)), c[4], 'msgpack ' .. c[3])
    end
end
eq(hex(P(('x'):rep(31)):sub(1, 1)), 'BF', 'fixstr of 31 bytes')
eq(hex(P(('x'):rep(32)):sub(1, 2)), 'D9 20', 'str8 from 32 bytes')
eq(hex(P(('x'):rep(256)):sub(1, 3)), 'DA 01 00', 'str16 from 256 bytes')
eq(hex(P(('x'):rep(65536)):sub(1, 5)), 'DB 00 01 00 00', 'str32 from 65536 bytes')
local list15, list16, map16 = {}, {}, {}
for i = 1, 15 do list15[i] = i end
for i = 1, 16 do list16[i] = i; map16['k' .. i] = i end
eq(hex(P(list15):sub(1, 1)), '9F', 'fixarray of 15')
eq(hex(P(list16):sub(1, 3)), 'DC 00 10', 'array16 from 16 elements')
eq(hex(P(map16):sub(1, 3)), 'DE 00 10', 'map16 from 16 entries')

local U = S.msgpackLua.unpack
local decodeCases = {
    { 'CA 3F C0 00 00', 1.5, 'float32 decodes' },
    { 'CF FF FF FF FF FF FF FF FF', 18446744073709551615.0, 'uint64 over 2^63-1 decodes to a float' },
    { 'D3 80 00 00 00 00 00 00 00', math.mininteger, 'int64 min' },
    { 'C4 03 61 62 63', 'abc', 'bin8 reads as a string' },
    { 'DB 00 00 00 02 68 69', 'hi', 'str32' },
    { 'D0 FF', -1, 'int8 -1' },
}
for _, c in ipairs(decodeCases) do eq(U(bytes(c[1])), c[2], 'unpack ' .. c[3]) end
local arr32 = U(bytes('DD 00 00 00 02 01 02'))
check(type(arr32) == 'table' and arr32[1] == 1 and arr32[2] == 2, 'array32 decodes')
local map32 = U(bytes('DF 00 00 00 01 A1 6B 07'))
check(type(map32) == 'table' and map32.k == 7, 'map32 decodes')
local holes = U(bytes('93 01 C0 03'))
check(holes[1] == 1 and holes[2] == nil and holes[3] == 3, 'nil inside an array leaves a hole')
local nilKey = U(bytes('82 C0 01 A1 61 02'))
check(type(nilKey) == 'table' and nilKey.a == 2, 'a nil map key is skipped, the rest decodes')

--------------------------------------------------------------------------------
-- Codec.pack / Codec.unpack: protected, and every blob shape of the scene round-trips
--------------------------------------------------------------------------------

--- Deep equality including the integer / float subtype; answers ok, path of the first difference.
local function deepEq(a, b, path)
    path = path or '$'
    if type(a) ~= type(b) then return false, path end
    if type(a) ~= 'table' then
        if a ~= b then return false, path end
        if type(a) == 'number' and math.type(a) ~= math.type(b) then return false, path .. ' (subtype)' end
        return true
    end
    for k, v in pairs(a) do
        local ok, where = deepEq(v, b[k], path .. '.' .. tostring(k))
        if not ok then return false, where end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. '.' .. tostring(k) .. ' (extra)' end
    end
    return true
end

local function roundTrips(value, label)
    local blob = S.pack(value)
    local ok, where = deepEq(value, C.unpack(blob))
    return check(type(blob) == 'string' and ok, 'round trip: ' .. label, where and ('differs at ' .. where))
end

eq(S.pack(nil), '', 'pack(nil) is the empty blob')
eq(C.unpack(''), nil, "unpack('') is nil")
eq(C.unpack(nil), nil, 'unpack(nil) is nil')
eq(C.unpack(42), nil, 'unpack of a non-string is nil')
eq(C.unpack('\xc1'), nil, 'unpack of the reserved byte 0xC1 is nil (never raises)')
eq(C.unpack('\x93\x01'), nil, 'unpack of a truncated array is nil')
eq(C.unpack(('\x91'):rep(100) .. '\x01'), nil, 'unpack of 100 nested arrays stops at the depth limit')
eq(C.unpack('\xdd\xff\xff\xff\xff'), nil, 'unpack of a hostile array32 count fails fast')
local packed, packErr = S.pack({ fn = function() end })
check(packed == nil and type(packErr) == 'string', 'pack of a function answers nil, err (never raises)')

roundTrips({ model = 'prop_bench_01a', frozen = false, collision = true, tint = 3, lod = 150.5 }, 'fields table')
roundTrips({ 1.5, -2, 3e10, 0.1, math.maxinteger, math.mininteger, -0.25 }, 'array of numbers')
roundTrips({ a = { b = { c = { 1, 2, { d = 'e' } } } } }, 'nested tables')
roundTrips({ [0] = 1, [17] = true, [48] = -1 }, 'integer-keyed map (vehicle mods)')
roundTrips({ [-1] = 'x', [1.5] = 'y', [true] = 'z' }, 'negative, float and boolean keys')
roundTrips({}, 'the empty table')
roundTrips({ s = ('x'):rep(70000) }, 'a 70,000-byte string')
roundTrips({ f = { model = 'prop_x', anim = { dict = 'd', clip = 'c', loop = true, rate = 1.25, t0 = 123 } },
    m = { t = 'spin', t0 = 4294967295, axis = 'z', dps = 90 }, o = { x = 0.5, y = -1, z = 2 },
    r = { x = 0, y = 0, z = 90 }, b = 57005, a = { n = 17 }, i = { { action = 'use', label = 'Use', distance = 2.0 } },
    n = 1234, d = { 5, 6 } }, 'a PUT extra with every key')
roundTrips({ f = { label = 'x' }, x = { 'old', 'gone' }, a = false, d = {} }, 'a SET patch')
roundTrips({ near = { 'label' }, budget = 'props', handler = 'core' }, 'KINDS meta')

local deep = {}
local cur = deep
for _ = 1, 20 do
    cur.c = {}
    cur = cur.c
end
local cut, levels = C.unpack(S.pack(deep)), 0
while cut do
    levels = levels + 1
    cut = cut.c
end
eq(levels, 16, 'tables nested deeper than 16 pack as nil (FiveM MP_MAX_NESTING)')
local cyclic = {}
cyclic.self = cyclic
check(type(S.pack(cyclic)) == 'string', 'a cyclic table packs (cut at the nesting limit) instead of looping')
local vec = C.unpack(S.pack({ p = stubs.vector3(1, 2, 3) }))
check(vec and vec.p.x == 1 and vec.p.y == 2 and vec.p.z == 3, 'offline, a vector packs as an { x, y, z } map')
eq(S.pack({ k = { 1, 'two', false } }), C.pack({ k = { 1, 'two', false } }), 'server and client VMs write the same bytes')

-- the runtime's msgpack global wins when the VM has one
local rtPacks, rtUnpacks = 0, 0
local _, R = newVM('client', function(env)
    env.msgpack = {
        pack = function(v) rtPacks = rtPacks + 1; return S.msgpackLua.pack(v) end,
        unpack = function(s) rtUnpacks = rtUnpacks + 1; return S.msgpackLua.unpack(s) end,
    }
end)
eq(R.nativeMsgpack, true, 'a VM with the msgpack global uses it')
eq(hex(R.pack({ a = 1 })), '81 A1 61 01', 'Codec.pack goes through msgpack.pack')
eq(rtPacks, 1, 'one runtime pack call')
eq(R.unpack(bytes('81 A1 61 01')).a, 1, 'Codec.unpack goes through msgpack.unpack')
eq(rtUnpacks, 1, 'one runtime unpack call')
local _, R2 = newVM('client', function(env)
    env.msgpack = { pack = function() error('boom') end, unpack = function() error('boom') end }
end)
local rp, rpErr = R2.pack({ a = 1 })
check(rp == nil and type(rpErr) == 'string', 'a raising runtime pack answers nil, err')
eq(R2.unpack('\x01'), nil, 'a raising runtime unpack answers nil')

--------------------------------------------------------------------------------
-- every op, edge values, encode (server VM) → decode (client VM)
--------------------------------------------------------------------------------

local H = S.header(7)

local function decodeAll(blob)
    local h, log = recorder()
    local ok, err = C.decode(blob, h)
    return ok, err, log
end

local function args(entry, ...)
    if entry == nil then return false, 'the handler was not called' end
    local want = table.pack(...)
    for i = 1, want.n do
        local ok, where = deepEq(want[i], entry.args[i])
        if not ok then return false, ('%s arg %d differs at %s: %s vs %s'):format(entry.name, i, where,
            show(want[i]), show(entry.args[i])) end
    end
    return true
end

local function expectArgs(entry, label, ...)
    local ok, detail = args(entry, ...)
    return check(entry ~= nil and ok, label, detail)
end

-- header
local ok, err, log = decodeAll(S.header(-1))
check(ok and err == nil and #log == 1, 'a bare header decodes')
expectArgs(log[1], 'header(-1) travels as u32 0xFFFFFFFF', 1, 0xFFFFFFFF)
ok, err, log = decodeAll(S.header(0x100000005))
expectArgs(log[1], 'header wraps a stamp past 2^32', 1, 5)

-- KINDS
local longId = ('k'):rep(300)
ok, err, log = decodeAll(H .. S.kinds({
    { idx = 1, id = 'prop', class = 1, meta = { near = { 'label' }, budget = 'props', handler = 'core' } },
    { idx = 65535, id = 'fireworks:battery', class = 'custom', meta = { budget = 'custom', handler = 'fireworks' } },
    { idx = 9, id = '' },
    { idx = 10, id = longId, class = 7 },
}) .. S.kinds({}) .. S.kinds(nil))
check(ok and #log == 4 and log[2].name == 'kinds', 'KINDS ops decode')
local list = log[2].args[1]
check(#list == 4 and list[1].idx == 1 and list[1].id == 'prop' and list[1].class == 1, 'KINDS entry fields')
check(deepEq(list[1].meta, { near = { 'label' }, budget = 'props', handler = 'core' }), 'KINDS meta decodes to its table')
check(list[2].idx == 65535 and list[2].class == 7, 'a class name encodes as its code, idx up to 65535')
check(list[3].id == '' and list[3].class == 0 and list[3].meta == nil, 'a removed kind: empty id, class 0, no meta')
eq(#list[4].id, 255, 's1 cuts a 300-byte kind id to 255 bytes')
eq(#log[3].args[1], 0, 'an empty KINDS list')
eq(#log[4].args[1], 0, 'KINDS of nil is an empty list')

-- SUB / UNSUB
ok, err, log = decodeAll(H .. S.sub(2, 0, 3, 0xFFFFFFFF) .. S.sub(0, 0xFFFFFFFF, 1, 0) .. S.unsub(1, 123456))
check(ok and #log == 4, 'SUB / UNSUB decode')
expectArgs(log[2], 'SUB global key 0, v max', 2, 0, 3, 0xFFFFFFFF)
expectArgs(log[3], 'SUB key max, v 0', 0, 0xFFFFFFFF, 1, 0)
expectArgs(log[4], 'UNSUB', 1, 123456)

-- CELL / PRIV sections, node ops with edge values, the reused ctx
local extra = { f = { model = 'prop_x', frozen = false, tint = 3 }, m = { t = 'spin', t0 = 5, axis = 'z', dps = 45 },
    i = { { action = 'use', label = 'Use', distance = 2.0 } }, n = 7, d = { 3 } }
local patch = { f = { label = 'x' }, x = { 'old' }, a = false }
ok, err, log = decodeAll(H .. S.cell(0, 2147516416, 1, 0, 12, 3)
    .. S.put(2147483647, 65535, 0xFFFFFFFF, 0, 127, -1234.567, 9999.994, -999.996, 190, -180, 540.004, 70000,
        S.pack(extra))
    .. S.set(5, 6, S.pack(patch))
    .. S.move(5, 7, -0.004, 0.006, 1e12, -190, 0, 359.999)
    .. S.del(9, 8, S.DEL.FADE)
    .. S.priv(2)
    .. S.put(11, 1, 1, 5, 32, 1, 2, 3, 0, 0, 0, 150.6, '')
    .. S.motion(11, 2, '')
    .. S.event(0, 0x100000001, 1, 2, 3, '', nil))
check(ok and err == nil and #log == 10, 'a payload with a CELL and a PRIV section decodes', tostring(err))
expectArgs(log[2], 'CELL header', 0, 2147516416, 1, 0, 12, 3)
expectArgs(log[3], 'PUT: max id / kind / ver, flags 127, quantised pose, radius clamped', 2147483647, 65535,
    0xFFFFFFFF, 0, 127, -1234.57, 9999.99, -1000.0, -170.0, 180.0, 180.0, 65535, extra)
check(log[3].section == 'cell' and log[3].grid == 0 and log[3].key == 2147516416 and log[3].variant == 1
    and log[3].from == 0 and log[3].to == 12, 'PUT sees the CELL section in ctx')
expectArgs(log[4], 'SET with a decoded patch', 5, 6, patch)
eq(log[4].section, 'cell', 'SET is the 2nd op of the section')
expectArgs(log[5], 'MOVE: rounding to 0 / 0.01, clamping, rotation normalisation', 5, 7, 0.0, 0.01, 21474836.47,
    170.0, 0.0, 0.0)
eq(log[5].section, 'cell', 'MOVE is the 3rd and last op of the section')
expectArgs(log[6], 'DEL fade', 9, 8, 2)
check(log[6].section == 'none' and log[6].grid == nil and log[6].key == nil, 'after n ops the section ends')
expectArgs(log[7], 'PRIV', 2)
expectArgs(log[8], 'PUT in PRIV: parent, gated flag, radius rounds, empty extra = nil', 11, 1, 1, 5, 32, 1.0, 2.0,
    3.0, 0.0, 0.0, 0.0, 151)
eq(log[8].args[13], nil, "an empty extra blob decodes to nil")
check(log[8].section == 'priv' and log[8].grid == nil, 'PRIV ops see section priv and no cell')
expectArgs(log[9], "MOTION '' = static (nil)", 11, 2, nil)
eq(log[9].section, 'priv', 'the 2nd PRIV op')
expectArgs(log[10], 'EVENT: positional id 0, t wraps, empty name, no params', 0, 1, 1.0, 2.0, 3.0, '', nil)
eq(log[10].section, 'none', 'the op after the PRIV section')
check(log[3].ctx == log[4].ctx and log[4].ctx == log[10].ctx, 'every node op gets the same (reused) ctx table')
eq(math.type(log[3].args[1]), 'integer', 'ids decode as integers')

-- DR / PROMOTE / DEMOTE / EVENT with params / DEL by name
ok, err, log = decodeAll(H .. S.dr(3, 0xFFFFFFFF, -5.5, 6.25, 7, 400, -1.234, 0, 450)
    .. S.promote(3, 9, 65535)
    .. S.demote(3, 10, 1, 2, 3, 4, 5, 6)
    .. S.event(3, 77, -1, -2, -3, ('n'):rep(300), S.pack({ power = 2, colors = { 'red', 'blue' } }))
    .. S.del(3, 11, 'handover') .. S.del(3, 12))
check(ok and #log == 7, 'DR / PROMOTE / DEMOTE / EVENT / DEL decode')
expectArgs(log[2], 'DR: t max, velocity clamped to i16 cm/s, yaw normalised', 3, 0xFFFFFFFF, -5.5, 6.25, 7.0,
    327.67, -1.23, 0.0, 90.0)
expectArgs(log[3], 'PROMOTE netId 65535', 3, 9, 65535)
expectArgs(log[4], 'DEMOTE pose', 3, 10, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0)
eq(#log[5].args[6], 255, 'EVENT: s1 cuts a 300-byte name to 255')
expectArgs(log[5], 'EVENT params decode', 3, 77, -1.0, -2.0, -3.0, ('n'):rep(255), { power = 2, colors = { 'red', 'blue' } })
expectArgs(log[6], "DEL how by name ('handover' = 1)", 3, 11, 1)
expectArgs(log[7], 'DEL how nil = normal (0)', 3, 12, 0)

-- RESET: drop everything (reason 1 bucket, 2 server restart / epoch, 3 resync-all)
eq(hex(S.reset(S.RESET.BUCKET)), '06 01', 'RESET bytes: opcode 0x06, B reason')
eq(hex(S.reset('epoch')), '06 02', "a reason name ('epoch' = 2) is accepted")
eq(hex(S.reset()), '06 03', 'no reason = RESYNC (3)')
eq(hex(S.reset('nonsense')), '06 03', 'an unknown reason name = RESYNC (3)')
check(not pcall(S.reset, 256), 'a reason over u8 raises')
check(not pcall(S.reset, -1), 'a negative reason raises')
check(not pcall(S.reset, 1.5), 'a fractional reason raises')
ok, err, log = decodeAll(H .. S.reset(1) .. S.sub(0, 5, 1, 9) .. S.reset('epoch') .. S.reset(200) .. S.cell(0, 5, 1, 0, 9, 1)
    .. S.del(3, 4, 0) .. S.reset())
check(ok and err == nil and #log == 8, 'RESET ops decode between the others', tostring(err))
expectArgs(log[2], 'RESET reason bucket', 1)
expectArgs(log[4], 'RESET reason epoch', 2)
expectArgs(log[5], 'an unknown reason byte reaches the handler as sent', 200)
expectArgs(log[8], 'RESET after a completed section', 3)
eq(log[7] and log[7].section, 'cell', 'the section before it decodes normally')
local seen = {}
local skipped = C.decode(H .. S.reset(1) .. S.unsub(0, 5), { unsub = function(_, key) seen[#seen + 1] = key end })
check(skipped and #seen == 1 and seen[1] == 5, 'no reset handler: the op is skipped, the rest still decodes')
ok, err = C.decode(H .. S.cell(0, 5, 1, 0, 9, 2) .. S.del(3, 4, 0) .. S.reset(1) .. S.del(3, 5, 0), {})
check(not ok and err == 'truncated', 'a RESET inside an unfinished section answers truncated')
ok, err = C.decode(H .. S.priv(1) .. S.reset(3), {})
check(not ok and err == 'truncated', 'a RESET inside an unfinished PRIV section answers truncated')
ok, err, log = decodeAll(H .. S.unsub(0, 1) .. '\x06')
check(not ok and err == 'truncated' and #log == 2, 'a RESET cut before its reason byte answers truncated')

-- identical bytes from both VMs
eq(S.put(1, 2, 3, 0, 1, 1.5, -2.5, 3, 10, 20, 30, 50, ''), C.put(1, 2, 3, 0, 1, 1.5, -2.5, 3, 10, 20, 30, 50, ''),
    'server and client encode a PUT to the same bytes')

-- integer fields go to string.pack unchanged: out of range raises there
check(not pcall(S.put, -1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, ''), 'a negative id raises (u32 field)')
check(not pcall(S.put, 1.5, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, ''), 'a fractional id raises')
check(not pcall(S.promote, 1, 1, 70000), 'a netId over u16 raises')
check(not pcall(S.cell, 0, 1, 1, 0, 1, 65536), 'a CELL op count over u16 raises')
check(not pcall(S.set, 1, 1, ('x'):rep(65536)), 'an s2 blob over 65535 bytes raises (never cut)')
check(pcall(S.set, 1, 1, ('x'):rep(65535)), 'an s2 blob of exactly 65535 bytes is fine')
check(not pcall(S.set, 1, 1, {}), 'a table instead of a blob raises (pack it first)')
check(pcall(S.put, 1, nil, 1, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil), 'nil kind / parent / flags / pose / blob default to 0')
local bigBlob = S.pack({ s = ('y'):rep(65000) })
ok, err, log = decodeAll(H .. S.set(1, 1, bigBlob))
check(ok and log[2].args[3] and #log[2].args[3].s == 65000, 'a blob near the s2 limit round-trips')

-- Codec.writer (DESIGN §55.8)
local w = S.writer()
w:u8(1):u16(0xFFFF):u32(0xFFFFFFFF):i16(-2):i32(-3):s1('ab'):s2('cd'):raw('\x00')
eq(hex(w:done()), '01 FF FF FF FF FF FF FE FF FD FF FF FF 02 61 62 02 00 63 64 00', 'writer: little-endian fields')
eq(w:done(), '', 'done() empties the writer for reuse')
w:raw(S.header(9)):raw(S.unsub(0, 5))
ok, err, log = decodeAll(w:done())
check(ok and #log == 2 and log[2].name == 'unsub', 'a payload assembled with the writer decodes')

--------------------------------------------------------------------------------
-- mixed streams: 1,000 ops decoded in one pass, and truncation at every byte offset
--------------------------------------------------------------------------------

local seed = 20260926
local function rnd(n)                                   -- 0 .. n - 1, deterministic
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n
end
local function coord() return (rnd(2000001) - 1000000) / 97 end
local function angle() return (rnd(72001) - 36000) / 37 end
local function speed() return (rnd(80001) - 40000) / 99 end
local function upos(v) return S.upos(S.qpos(v)) end
local function urot(v) return S.urot(S.qrot(v)) end
local function uvel(v) return S.uvel(S.qvel(v)) end
local function maybeTable() return rnd(3) > 0 and { v = rnd(1000), s = 'n' .. rnd(100) } or nil end

--- A header plus `count` random ops (every kind, CELL / PRIV sections included). Answers the payload, the
--- expected handler calls and the payload lengths at which a cut stream is still well-formed.
local function stream(count)
    local parts, expect, clean = { H }, { { name = 'header', args = { 1, 7 } } }, {}
    local length, remaining, section, cellKey = #H, 0, 'none', nil
    clean[length] = true
    local function add(bytes, name, argList, isNode, opensSection, n, key)
        parts[#parts + 1] = bytes
        length = length + #bytes
        local entry = { name = name, args = argList }
        if isNode then
            entry.section = remaining > 0 and section or 'none'
            entry.key = remaining > 0 and cellKey or nil
            if remaining > 0 then remaining = remaining - 1 end
        elseif opensSection then
            section, remaining, cellKey = opensSection, n, key
        end
        expect[#expect + 1] = entry
        if remaining == 0 then clean[length] = true end
    end
    for _ = 1, count do
        local id, ver = rnd(2147483647) + 1, rnd(2147483647) * 2
        local r = rnd(15)
        if r == 0 and remaining == 0 then
            local grid, key, variant, from, to, n = rnd(3), rnd(2147483647) * 2, rnd(3) + 1, rnd(1000), rnd(1000) + 1000, rnd(5)
            add(S.cell(grid, key, variant, from, to, n), 'cell', { grid, key, variant, from, to, n }, false, 'cell', n, key)
        elseif r == 1 and remaining == 0 then
            local n = rnd(4)
            add(S.priv(n), 'priv', { n }, false, 'priv', n, nil)
        elseif r == 2 then
            local grid, key, variant, v = rnd(3), rnd(2147483647), rnd(3) + 1, rnd(2147483647)
            add(S.sub(grid, key, variant, v), 'sub', { grid, key, variant, v })
        elseif r == 3 then
            local grid, key = rnd(3), rnd(2147483647)
            add(S.unsub(grid, key), 'unsub', { grid, key })
        elseif r == 14 and remaining == 0 then
            local reason = rnd(3) + 1
            add(S.reset(reason), 'reset', { reason })
        elseif r == 4 then
            local k = { { idx = rnd(65536), id = 'k' .. rnd(99), class = rnd(8), meta = maybeTable() } }
            add(S.kinds(k), 'kinds', { k })
        elseif r == 5 then
            local x, y, z, rx, ry, rz, radius, e = coord(), coord(), coord(), angle(), angle(), angle(), rnd(80000) / 3, maybeTable()
            local parent, flags, kind = rnd(3) == 0 and rnd(1000) + 1 or 0, rnd(128), rnd(65536)
            add(S.put(id, kind, ver, parent, flags, x, y, z, rx, ry, rz, radius, e and S.pack(e)), 'put',
                { id, kind, ver, parent, flags, upos(x), upos(y), upos(z), urot(rx), urot(ry), urot(rz),
                  math.min(65535, math.floor(radius + 0.5)), e }, true)
        elseif r == 6 then
            local p = maybeTable()
            add(S.set(id, ver, p and S.pack(p)), 'set', { id, ver, p }, true)
        elseif r == 7 then
            local x, y, z, rx, ry, rz = coord(), coord(), coord(), angle(), angle(), angle()
            add(S.move(id, ver, x, y, z, rx, ry, rz), 'move', { id, ver, upos(x), upos(y), upos(z), urot(rx), urot(ry), urot(rz) }, true)
        elseif r == 8 then
            local m = maybeTable()
            add(S.motion(id, ver, m and S.pack(m) or ''), 'motion', { id, ver, m }, true)
        elseif r == 9 then
            local how = rnd(3)
            add(S.del(id, ver, how), 'del', { id, ver, how }, true)
        elseif r == 10 then
            local t, x, y, z, name, p = rnd(2147483647) * 2 + 1, coord(), coord(), coord(), 'e' .. rnd(1000), maybeTable()
            local eid = rnd(2) == 0 and 0 or id
            add(S.event(eid, t, x, y, z, name, p and S.pack(p)), 'event', { eid, t, upos(x), upos(y), upos(z), name, p }, true)
        elseif r == 11 then
            local t, x, y, z, vx, vy, vz, yaw = rnd(2147483647) * 2, coord(), coord(), coord(), speed(), speed(), speed(), angle()
            add(S.dr(id, t, x, y, z, vx, vy, vz, yaw), 'dr',
                { id, t, upos(x), upos(y), upos(z), uvel(vx), uvel(vy), uvel(vz), urot(yaw) }, true)
        elseif r == 12 then
            local net = rnd(65536)
            add(S.promote(id, ver, net), 'promote', { id, ver, net }, true)
        else
            local x, y, z, rx, ry, rz = coord(), coord(), coord(), angle(), angle(), angle()
            add(S.demote(id, ver, x, y, z, rx, ry, rz), 'demote', { id, ver, upos(x), upos(y), upos(z), urot(rx), urot(ry), urot(rz) }, true)
        end
    end
    while remaining > 0 do                                -- close an open section
        add(S.del(1, 1, 0), 'del', { 1, 1, 0 }, true)
    end
    return table.concat(parts), expect, clean
end

local big, expected = stream(1000)
ok, err, log = decodeAll(big)
eq(ok, true, 'a stream of 1,000 mixed ops decodes')
eq(#log, #expected, 'one handler call per op (plus the header)')
--- Same op, same values over the handler's full arity (so an expected nil blob is checked too), same section.
local function sameCall(got, want)
    if got == nil or want == nil or got.name ~= want.name then return false end
    local n = got.args.n - (got.ctx and 1 or 0)
    for i = 1, n do
        if not deepEq(want.args[i], got.args[i]) then return false end
    end
    return want.section == nil or (got.section == want.section and got.key == want.key)
end

local firstBad
for i = 1, math.max(#log, #expected) do
    local got, want = log[i], expected[i]
    local good = sameCall(got, want)
    if not good then
        firstBad = firstBad or ('op %d: %s vs %s'):format(i, want and want.name or '-', got and got.name or '-')
    end
end
check(firstBad == nil, 'every decoded op of the 1,000-op stream matches its encoded values and section', firstBad)

local small, _, clean = stream(80)
local raised, wrong, h0 = 0, 0, recorder()
for cutAt = 0, #small do
    local okCall, okDecode, why = pcall(C.decode, small:sub(1, cutAt), h0)
    if not okCall then
        raised = raised + 1
    else
        local want = cutAt < 5 and 'header' or (clean[cutAt] and true or 'truncated')
        if (want == true and okDecode ~= true) or (want ~= true and (okDecode ~= false or why ~= want)) then
            wrong = wrong + 1
        end
    end
end
eq(raised, 0, ('truncation at every byte offset (%d cuts) never raises'):format(#small + 1))
eq(wrong, 0, 'a cut answers true only on a clean op boundary, else header / truncated')

--------------------------------------------------------------------------------
-- bad input: unknown ops, versions, headers, sections, hostile blobs, handlers
--------------------------------------------------------------------------------

ok, err, log = decodeAll(H .. S.unsub(0, 1) .. '\x07' .. S.unsub(0, 2))
check(not ok and err == 'unknown_op:7' and #log == 2, 'an unknown opcode stops after delivering the ops before it')
eq(select(2, C.decode(H .. '\x19', {})), 'unknown_op:25', 'opcode 0x19 is unknown')
eq(select(2, C.decode(H .. '\xff', {})), 'unknown_op:255', 'opcode 0xff is unknown')
eq(select(2, C.decode(H .. '\x00', {})), 'unknown_op:0', 'opcode 0x00 is unknown')
eq(select(2, C.decode(string.pack('<BI4', 2, 0), {})), 'version:2', 'another format version is refused')
eq(select(2, C.decode('', {})), 'header', 'an empty payload')
eq(select(2, C.decode('\x01\x00\x00\x00', {})), 'header', 'a 4-byte payload')
eq(select(2, C.decode(nil, {})), 'header', 'a nil payload')
eq(select(2, C.decode(12345, {})), 'header', 'a number payload')
eq(C.decode(H .. S.put(1, 1, 1, 0, 0, 1, 2, 3, 0, 0, 0, 5, S.pack({ f = {} })), nil), true, 'no handler table: parsed and skipped')
local puts = 0
eq(C.decode(big, { put = function() puts = puts + 1 end }), true, 'only a put handler: every other op is skipped')
local wantPuts = 0
for _, e in ipairs(expected) do if e.name == 'put' then wantPuts = wantPuts + 1 end end
eq(puts, wantPuts, 'and every PUT still reaches it')

local wrongCalls = 0
local noFallthrough = C.decode(H .. S.set(1, 1, '') .. S.move(1, 2, 0, 0, 0, 0, 0, 0),
    { motion = function() wrongCalls = wrongCalls + 1 end, demote = function() wrongCalls = wrongCalls + 1 end })
check(noFallthrough and wrongCalls == 0, 'a SET / MOVE without its own handler never reaches the MOTION / DEMOTE handler')
eq(select(2, C.decode(S.header(0 / 0) .. S.event(1, math.huge, 0, 0, 0, 'x', nil), { event = function(_, t)
    wrongCalls = t end })), nil, 'a NaN header stamp and an infinite event time encode as 0')
eq(wrongCalls, 0, 'the infinite event time arrives as 0')
ok, err = C.decode(H .. S.cell(0, 1, 1, 0, 1, 2) .. S.del(1, 1, 0) .. S.cell(0, 2, 1, 0, 1, 1), {})
check(not ok and err == 'truncated', 'a CELL inside an unfinished section answers truncated')
ok, err = C.decode(H .. S.cell(0, 1, 1, 0, 1, 2) .. S.del(1, 1, 0), {})
check(not ok and err == 'truncated', 'a section cut short at the end answers truncated')
ok, err = C.decode(H .. S.priv(2) .. S.del(1, 1, 0) .. S.priv(1) .. S.del(1, 1, 0), {})
check(not ok and err == 'truncated', 'a PRIV inside an unfinished section answers truncated')
ok, err, log = decodeAll(H .. S.cell(0, 1, 1, 0, 1, 1) .. S.sub(0, 9, 1, 1) .. S.del(4, 1, 0))
check(ok and log[3].name == 'sub' and log[4].section == 'cell', 'a control op inside a section does not count as one of its n')
ok, err, log = decodeAll(H .. S.priv(0) .. S.del(4, 1, 0) .. S.cell(1, 2, 2, 0, 3, 0) .. S.del(5, 1, 0))
check(ok and log[3].section == 'none' and log[5].section == 'none', 'PRIV(0) and CELL(n = 0) open no section')

ok, err, log = decodeAll(H .. S.put(1, 1, 1, 0, 0, 1, 2, 3, 0, 0, 0, 5, '\xc1')
    .. S.put(2, 1, 1, 0, 0, 1, 2, 3, 0, 0, 0, 5, '\x05')
    .. S.set(3, 1, ('\x91'):rep(100) .. '\x01')
    .. S.motion(4, 1, '\xdd\xff\xff\xff\xff'))
check(ok and #log == 5, 'hostile blobs never stop the decode')
check(log[2].args[13] == nil and log[3].args[13] == nil, 'garbage and non-table extras arrive as nil')
check(log[4].args[3] == nil and log[5].args[3] == nil, 'too-deep and hostile-count blobs arrive as nil')
ok, err = C.decode(H .. '\x10' .. ('\x00'):rep(35) .. '\xff\xff' .. 'x', {})
check(not ok and err == 'truncated', 'an s2 length past the end answers truncated')
ok, err = C.decode(H .. '\x01\xff\xff', {})
check(not ok and err == 'truncated', 'a KINDS count without entries answers truncated')
check(not pcall(C.decode, H .. S.del(1, 1, 0), { del = function() error('handler bug') end }),
    'an error raised by a handler propagates (a bug, not input)')

--------------------------------------------------------------------------------
-- throughput (information, not a gate)
--------------------------------------------------------------------------------

local extraBlob = S.pack({ f = { model = 'prop_bench_01a', frozen = true } })
local clock = os.clock
local t0 = clock()
local benchParts = {}
for i = 1, 10000 do
    benchParts[i] = S.put(i, 1, i, 0, 0, i * 0.37, -i * 0.21, 30.5, 0, 0, i % 360, 150, extraBlob)
end
local t1 = clock()
local benchBlob = S.header(1) .. table.concat(benchParts)
local decoded = 0
local okBench = C.decode(benchBlob, { put = function() decoded = decoded + 1 end })
local t2 = clock()
C.decode(benchBlob, {})
local t3 = clock()
check(okBench and decoded == 10000, 'bench: 10,000 PUTs decode')
print(('scene codec bench: 10,000 PUTs, %d bytes (%.1f B/PUT) — encode %.2f us/op, decode %.2f us/op with the '
    .. 'msgpack extra (pure-Lua subset), %.2f us/op without a put handler'):format(#benchBlob, #benchBlob / 10000,
    (t1 - t0) * 100, (t2 - t1) * 100, (t3 - t2) * 100))

print(('scene codec: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
