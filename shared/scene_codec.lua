--[[
    core / shared/scene_codec.lua  —  Core.SceneCodec (DESIGN §55.8; internal, both core VMs)

    The binary wire format of Core.Scene: little-endian `string.pack` ops, quantised poses, msgpack blobs for
    nested tables. A stream payload is `Codec.header(now) .. op*`; the server encodes each op once per change
    and the client decodes a payload once in its event handler (never per frame).

    Decisions (DESIGN §55.8 leaves them to the codec):
      * Quantisation clamps and never raises: positions → i32 centimetres (nearest), rotations → i16
        centi-degrees normalised to (-18000, 18000] (so -180° travels as +180°), velocities → i16 cm/s,
        radius → u16 whole metres. NaN and ±inf quantise to 0; huge finite values clamp to the type's range.
      * Integer fields (id, ver, parent, kind index, netId, grid, key, variant, from, to, v, n, how, flags) go to
        `string.pack` unchanged: a value outside its field's range raises THERE (a server bug is loud, an id is
        never silently rewritten into another id). Clock stamps (`t`, header now) are wrapped to u32.
      * `s1` strings (kind ids, event names) longer than 255 bytes are cut to 255 — the registries cap them far
        lower. An `s2` blob longer than 65,535 bytes RAISES: a cut msgpack blob would be garbage.
      * Blobs: FiveM's global `msgpack` (pack/unpack) when the VM has it, else the built-in pure-Lua subset below
        (nil, boolean, integer, float64, string, array, map — decode also takes float32 and bin). The subset
        writes the bytes FiveM's lua-cmsgpack writes with its defaults (citizenfx/lua-cmsgpack `grit`, flags
        EMPTY_AS_ARRAY | UNSIGNED_INTEGERS | ARRAY_WITHOUT_HOLES | NUMBER_AS_DOUBLE): integers in the smallest
        form, every float as float64, strings as str, a table whose keys are exactly 1..n as an array, the EMPTY
        table as an empty ARRAY (0x90), every other table as a map, tables nested deeper than 16 as nil.
        Known difference: FiveM packs `{ ..., n = count }` as a table.pack array and drops `n` — never mix a
        sequence with an `n` key in a scene blob. `Codec.pack(nil)` is '' and `Codec.unpack('')` is nil.
      * `Codec.decode` checks the bounds of every op before reading it and never raises on hostile or truncated
        input: it stops and answers `false, err` (ops before the bad one were delivered). A section (CELL/PRIV)
        that is cut short answers 'truncated'. Errors raised by a HANDLER propagate (they are bugs, not input).
      * RESET (0x06, `B reason`: Codec.RESET.BUCKET 1 / EPOCH 2 = server restart / RESYNC 3 = resync-all) tells the
        client to drop everything it holds (LRU included) and report its focus. It is a control op like SUB (not
        one of a section's n); inside an unfinished CELL / PRIV section it answers 'truncated' (the section's
        remaining ops would land on dropped state). The reason byte reaches `h.reset` as sent (unknown ones too).
        Blob arguments reach handlers decoded, and only when they decode to a table (else nil).

    Natives: none. Runtime helpers: `msgpack` (CFX Lua runtime global, optional).
]]

local Codec = {}

local spack, sunpack, byte, char, sub = string.pack, string.unpack, string.byte, string.char, string.sub
local concat = table.concat
local floor, mathType = math.floor, math.type

Codec.VERSION = 1

Codec.OP = { KINDS = 0x01, SUB = 0x02, UNSUB = 0x03, CELL = 0x04, PRIV = 0x05, RESET = 0x06,
             PUT = 0x10, SET = 0x11, MOVE = 0x12, MOTION = 0x13, DEL = 0x14, EVENT = 0x15, DR = 0x16,
             PROMOTE = 0x17, DEMOTE = 0x18 }
Codec.OP_NAME = {}
for name, code in pairs(Codec.OP) do Codec.OP_NAME[code] = name end

Codec.GRID = { NEAR = 0, FAR = 1, GLOBAL = 2 }
Codec.VARIANT = { NEAR = 1, FAR = 2, ONE = 3 }          -- ONE = far regions and the global set
Codec.DEL = { NORMAL = 0, HANDOVER = 1, FADE = 2 }
Codec.RESET = { BUCKET = 1, EPOCH = 2, RESYNC = 3 }     -- RESET reasons (EPOCH = the server restarted)
Codec.FLAG = { MOTION = 1, PROMOTED = 2, PLACEHOLDER = 4, FAR = 8, INTERACT = 16, GATED = 32, CHILDREN = 64 }
Codec.CLASS = { prop = 1, vehicle = 2, ped = 3, fx = 4, data = 5, audio = 6, custom = 7 }
Codec.CLASS_NAME = { 'prop', 'vehicle', 'ped', 'fx', 'data', 'audio', 'custom' }

local VERSION <const> = 1
local MASK <const> = 0xFFFFFFFF
local I32_MIN <const>, I32_MAX <const> = -2147483648, 2147483647
local I16_MIN <const>, I16_MAX <const> = -32768, 32767
local U16_MAX <const> = 65535
local HUGE <const> = math.huge

--------------------------------------------------------------------------------
-- quantisation (clamped; NaN / ±inf → 0)
--------------------------------------------------------------------------------

--- Rounds a scaled number to the nearest integer inside [lo, hi]; non-numbers, NaN and ±inf give 0.
local function quant(v, scale, lo, hi)
    if type(v) ~= 'number' or v ~= v or v == HUGE or v == -HUGE then return 0 end
    local q = v * scale + 0.5
    if q <= lo then return lo end
    if q >= hi + 1 then return hi end
    return floor(q)
end

--- metres → i32 centimetres
local function qpos(m) return quant(m, 100, I32_MIN, I32_MAX) end

--- degrees → centi-degrees in (-18000, 18000]
local function qrot(deg)
    if type(deg) ~= 'number' or deg ~= deg or deg == HUGE or deg == -HUGE then return 0 end
    local c = floor((deg % 360) * 100 + 0.5)          -- 0 .. 36000
    if c > 18000 then c = c - 36000 end               -- 36000 → 0, 18001 → -17999
    return c
end

--- m/s → i16 cm/s
local function qvel(mps) return quant(mps, 100, I16_MIN, I16_MAX) end

--- stream radius → u16 whole metres
local function qradius(r) return quant(r, 1, 0, U16_MAX) end

--- a Clock stamp → u32 (wraps; a non-number, NaN, ±inf or |t| ≥ 2^63 is 0)
local function u32(t)
    if type(t) ~= 'number' then return 0 end
    local i = math.tointeger(floor(t))
    return i and (i & MASK) or 0
end

Codec.qpos, Codec.qrot, Codec.qvel = qpos, qrot, qvel
function Codec.upos(cm) return cm / 100 end
function Codec.urot(cdeg) return cdeg / 100 end
function Codec.uvel(cms) return cms / 100 end

--- s1: at most 255 bytes (cut); a non-string is ''.
local function s1(s)
    if type(s) ~= 'string' then return '' end
    if #s > 255 then return sub(s, 1, 255) end
    return s
end

--- s2: a packed blob (nil = ''); more than 65,535 bytes raises.
local function s2(blob)
    if blob == nil then return '' end
    if type(blob) ~= 'string' then error('scene codec: a blob must be a string (Codec.pack it first)', 3) end
    if #blob > U16_MAX then
        error(('scene codec: blob of %d bytes exceeds the s2 limit of 65535'):format(#blob), 3)
    end
    return blob
end

--------------------------------------------------------------------------------
-- msgpack: the runtime's when present, else a pure-Lua subset with the same bytes
--------------------------------------------------------------------------------

local PACK_DEPTH <const> = 16       -- FiveM's MP_MAX_NESTING: a table nested deeper packs as nil
local UNPACK_DEPTH <const> = 32

local function encodeInteger(v)
    if v >= 0 then
        if v < 0x80 then return char(v) end
        if v < 0x100 then return char(0xcc, v) end
        if v < 0x10000 then return spack('>BI2', 0xcd, v) end
        if v < 0x100000000 then return spack('>BI4', 0xce, v) end
        return spack('>Bi8', 0xcf, v)           -- 2^32 .. 2^63-1: the same 8 bytes as u64
    end
    if v >= -32 then return char(v + 0x100) end
    if v >= -128 then return spack('>Bi1', 0xd0, v) end
    if v >= -32768 then return spack('>Bi2', 0xd1, v) end
    if v >= -2147483648 then return spack('>Bi4', 0xd2, v) end
    return spack('>Bi8', 0xd3, v)
end

--- Appends the bytes of `v` to `out` after index n and answers the new last index. A table whose keys are
--- exactly 1..n is an array (the empty table too); every other table is a map.
local function encodeValue(v, out, n, depth)
    local t = type(v)
    if t == 'string' then
        local len = #v
        if len < 32 then out[n + 1] = char(0xa0 + len)
        elseif len < 0x100 then out[n + 1] = char(0xd9, len)
        elseif len < 0x10000 then out[n + 1] = spack('>BI2', 0xda, len)
        else out[n + 1] = spack('>BI4', 0xdb, len) end
        out[n + 2] = v
        return n + 2
    elseif t == 'number' then
        out[n + 1] = mathType(v) == 'integer' and encodeInteger(v) or spack('>Bd', 0xcb, v)
        return n + 1
    elseif t == 'boolean' then
        out[n + 1] = v and '\xc3' or '\xc2'
        return n + 1
    elseif t == 'nil' then
        out[n + 1] = '\xc0'
        return n + 1
    elseif t == 'vector2' or t == 'vector3' or t == 'vector4' then
        -- offline only (the runtime packs vectors as its own ext types): a plain { x, y, z, w } map
        v = { x = v.x, y = v.y, z = v.z, w = v.w }
    elseif t ~= 'table' then
        error(('msgpack: cannot pack a %s'):format(t), 0)
    end
    n = n + 1
    if depth >= PACK_DEPTH then
        out[n] = '\xc0'
        return n
    end
    local count, max, isArray = 0, 0, true
    for k in next, v do
        count = count + 1
        if isArray then
            if mathType(k) == 'integer' and k >= 1 then
                if k > max then max = k end
            else
                isArray = false
            end
        end
    end
    if isArray and max == count then
        if count < 16 then out[n] = char(0x90 + count)
        elseif count < 0x10000 then out[n] = spack('>BI2', 0xdc, count)
        else out[n] = spack('>BI4', 0xdd, count) end
        for i = 1, count do n = encodeValue(v[i], out, n, depth + 1) end
        return n
    end
    if count < 16 then out[n] = char(0x80 + count)
    elseif count < 0x10000 then out[n] = spack('>BI2', 0xde, count)
    else out[n] = spack('>BI4', 0xdf, count) end
    for k, item in next, v do
        n = encodeValue(k, out, n, depth + 1)
        n = encodeValue(item, out, n, depth + 1)
    end
    return n
end

local FIXED <const> = { [0xcc] = '>B', [0xcd] = '>I2', [0xce] = '>I4', [0xcf] = '>I8',
    [0xd0] = '>i1', [0xd1] = '>i2', [0xd2] = '>i4', [0xd3] = '>i8', [0xca] = '>f', [0xcb] = '>d' }
local LENGTH <const> = { [0xd9] = '>B', [0xda] = '>I2', [0xdb] = '>I4',       -- str 8/16/32
    [0xc4] = '>B', [0xc5] = '>I2', [0xc6] = '>I4' }                           -- bin 8/16/32 (read as strings)

--- One value at `pos` → value, next position. Raises on bad input (Codec.unpack pcalls it).
local function decodeValue(s, pos, depth)
    local b = byte(s, pos)
    if not b then error('msgpack: truncated', 0) end
    if b < 0x80 then return b, pos + 1 end
    if b >= 0xe0 then return b - 0x100, pos + 1 end
    if b >= 0xa0 and b < 0xc0 then
        local e = pos + b - 0xa0
        if e > #s then error('msgpack: truncated', 0) end
        return sub(s, pos + 1, e), e + 1
    end
    if b == 0xc0 then return nil, pos + 1 end
    if b == 0xc2 then return false, pos + 1 end
    if b == 0xc3 then return true, pos + 1 end
    local fmt = FIXED[b]
    if fmt then
        local v, p = sunpack(fmt, s, pos + 1)    -- raises on a short string
        if b == 0xcf and v < 0 then v = v + 18446744073709551616.0 end   -- u64 over 2^63-1 → float, like FiveM
        return v, p
    end
    fmt = LENGTH[b]
    if fmt then
        local len, p = sunpack(fmt, s, pos + 1)
        local e = p + len - 1
        if e > #s then error('msgpack: truncated', 0) end
        return sub(s, p, e), e + 1
    end
    local count, isMap
    if b < 0x90 then count, isMap, pos = b - 0x80, true, pos + 1
    elseif b < 0xa0 then count, isMap, pos = b - 0x90, false, pos + 1
    elseif b == 0xdc or b == 0xdd then
        count, pos = sunpack(b == 0xdc and '>I2' or '>I4', s, pos + 1)
        isMap = false
    elseif b == 0xde or b == 0xdf then
        count, pos = sunpack(b == 0xde and '>I2' or '>I4', s, pos + 1)
        isMap = true
    else
        error(('msgpack: unsupported type 0x%02x'):format(b), 0)
    end
    if depth >= UNPACK_DEPTH then error('msgpack: nesting too deep', 0) end
    -- every element needs at least one byte: a hostile count fails here, not after a long loop
    if (isMap and count * 2 or count) > #s - pos + 1 then error('msgpack: truncated', 0) end
    local t = {}
    if isMap then
        for _ = 1, count do
            local k, v
            k, pos = decodeValue(s, pos, depth + 1)
            v, pos = decodeValue(s, pos, depth + 1)
            if k ~= nil and k == k then t[k] = v end   -- a nil or NaN key cannot index a Lua table: skipped
        end
    else
        for i = 1, count do
            local v
            v, pos = decodeValue(s, pos, depth + 1)
            t[i] = v                                   -- nil leaves a hole, like the runtime
        end
    end
    return t, pos
end

--- The built-in subset; both RAISE on bad input (Codec.pack / Codec.unpack are the protected entries).
local function luaPack(v)
    local out = {}
    local n = encodeValue(v, out, 0, 0)
    return concat(out, '', 1, n)
end

local function luaUnpack(s)
    return (decodeValue(s, 1, 0))
end

Codec.msgpackLua = { pack = luaPack, unpack = luaUnpack }

local runtime = type(msgpack) == 'table' and type(msgpack.pack) == 'function'
    and type(msgpack.unpack) == 'function' and msgpack or nil
local mpPack = runtime and runtime.pack or luaPack
local mpUnpack = runtime and runtime.unpack or luaUnpack
Codec.nativeMsgpack = runtime ~= nil

--- Any msgpack-able value → blob. nil → ''. Never raises: a value that cannot be packed answers nil, err.
function Codec.pack(v)
    if v == nil then return '' end
    local ok, blob = pcall(mpPack, v)
    if ok and type(blob) == 'string' then return blob end
    return nil, ('pack: %s'):format(tostring(blob))
end

--- Blob → value (the first one). '' / non-string / garbage → nil. Never raises.
function Codec.unpack(blob)
    if type(blob) ~= 'string' or blob == '' then return nil end
    local ok, v = pcall(mpUnpack, blob)
    if ok then return v end
    return nil
end

--------------------------------------------------------------------------------
-- encoders: one string per op (x.. in metres / degrees / m/s, quantised here; blobs already packed)
--------------------------------------------------------------------------------

local DEL_BY_NAME <const> = { normal = 0, handover = 1, fade = 2 }
local RESET_BY_NAME <const> = { bucket = 1, epoch = 2, resync = 3 }

--- `<B I4`: the format version and the server's Clock.now() at the flush.
function Codec.header(serverNow)
    return spack('<BI4', VERSION, u32(serverNow))
end

--- list = array of { idx = int, id = str, class = int (or a class name), meta = table|nil };
--- a removed kind travels as { idx, id = '' }.
function Codec.kinds(list)
    local n = type(list) == 'table' and #list or 0
    local out = { spack('<BH', 0x01, n) }
    for i = 1, n do
        local k = list[i]
        local class = k.class
        if type(class) == 'string' then class = Codec.CLASS[class] end
        local blob = k.meta ~= nil and Codec.pack(k.meta) or ''
        out[i + 1] = spack('<Hs1Bs2', k.idx, s1(k.id), class or 0, s2(blob or ''))
    end
    return concat(out)
end

function Codec.sub(grid, key, variant, v)
    return spack('<BBI4BI4', 0x02, grid, key, variant, v)
end

--- reason = Codec.RESET.* (the names 'bucket' | 'epoch' | 'resync' are accepted; nil or another name = RESYNC).
function Codec.reset(reason)
    if type(reason) == 'string' then reason = RESET_BY_NAME[reason] end
    return spack('<BB', 0x06, reason or 3)
end

function Codec.unsub(grid, key)
    return spack('<BBI4', 0x03, grid, key)
end

function Codec.cell(grid, key, variant, from, to, n)
    return spack('<BBI4BI4I4H', 0x04, grid, key, variant, from, to, n)
end

function Codec.priv(n)
    return spack('<BH', 0x05, n)
end

function Codec.put(id, kindIdx, ver, parent, flags, x, y, z, rx, ry, rz, radius, extraBlob)
    return spack('<BI4HI4I4Bi4i4i4i2i2i2Hs2', 0x10, id, kindIdx or 0, ver, parent or 0, flags or 0,
        qpos(x), qpos(y), qpos(z), qrot(rx), qrot(ry), qrot(rz), qradius(radius), s2(extraBlob))
end

function Codec.set(id, ver, patchBlob)
    return spack('<BI4I4s2', 0x11, id, ver, s2(patchBlob))
end

function Codec.move(id, ver, x, y, z, rx, ry, rz)
    return spack('<BI4I4i4i4i4i2i2i2', 0x12, id, ver, qpos(x), qpos(y), qpos(z), qrot(rx), qrot(ry), qrot(rz))
end

--- motionBlob '' (or nil) = the node is static again.
function Codec.motion(id, ver, motionBlob)
    return spack('<BI4I4s2', 0x13, id, ver, s2(motionBlob))
end

--- how = Codec.DEL.* (the names 'normal' | 'handover' | 'fade' are accepted too).
function Codec.del(id, ver, how)
    if type(how) == 'string' then how = DEL_BY_NAME[how] end
    return spack('<BI4I4B', 0x14, id, ver, how or 0)
end

--- id 0 (or nil) = a positional event.
function Codec.event(id, t, x, y, z, name, paramsBlob)
    return spack('<BI4I4i4i4i4s1s2', 0x15, id or 0, u32(t), qpos(x), qpos(y), qpos(z), s1(name), s2(paramsBlob))
end

function Codec.dr(id, t, x, y, z, vx, vy, vz, yaw)
    return spack('<BI4I4i4i4i4i2i2i2i2', 0x16, id, u32(t), qpos(x), qpos(y), qpos(z),
        qvel(vx), qvel(vy), qvel(vz), qrot(yaw))
end

function Codec.promote(id, ver, netId)
    return spack('<BI4I4H', 0x17, id, ver, netId)
end

function Codec.demote(id, ver, x, y, z, rx, ry, rz)
    return spack('<BI4I4i4i4i4i2i2i2', 0x18, id, ver, qpos(x), qpos(y), qpos(z), qrot(rx), qrot(ry), qrot(rz))
end

--- Codec.writer(): a byte buffer (DESIGN §55.8). Every method appends and returns the writer;
--- done() answers the bytes and empties the writer for reuse.
local Writer = {}
Writer.__index = Writer

local function append(w, s)
    local n = w.n + 1
    w.n, w[n] = n, s
    return w
end

function Writer:u8(v) return append(self, spack('<B', v)) end
function Writer:u16(v) return append(self, spack('<I2', v)) end
function Writer:u32(v) return append(self, spack('<I4', v)) end
function Writer:i16(v) return append(self, spack('<i2', v)) end
function Writer:i32(v) return append(self, spack('<i4', v)) end
function Writer:s1(s) return append(self, spack('<s1', s1(s))) end
function Writer:s2(blob) return append(self, spack('<s2', s2(blob))) end
function Writer:raw(bytes) return append(self, bytes) end      -- pre-encoded op strings

function Writer:done()
    local n = self.n
    local bytes = concat(self, '', 1, n)
    for i = 1, n do self[i] = nil end
    self.n = 0
    return bytes
end

function Codec.writer()
    return setmetatable({ n = 0 }, Writer)
end

--------------------------------------------------------------------------------
-- decoder
--------------------------------------------------------------------------------

local NO_HANDLERS <const> = {}
local ctx = { section = 'none' }   -- reused for every node op: handlers must not keep it

local function resetCtx()
    ctx.section, ctx.grid, ctx.key, ctx.variant, ctx.from, ctx.to = 'none', nil, nil, nil, nil, nil
end

--- The blob in s[a..e] decoded, when it is a table; nil otherwise ('' included).
local function blobArg(s, a, e)
    if e < a then return nil end
    local v = Codec.unpack(sub(s, a, e))
    if type(v) == 'table' then return v end
    return nil
end

--- KINDS body at `pos`: n × (H idx, s1 id, B class, s2 meta). Returns list, nextPos | nil.
local function decodeKinds(s, pos, len, wantMeta)
    if pos + 1 > len then return nil end
    local n = sunpack('<H', s, pos)
    pos = pos + 2
    local list = {}
    for i = 1, n do
        if pos + 2 > len then return nil end
        local idx, idLen = sunpack('<HB', s, pos)
        local classPos = pos + 3 + idLen              -- B class, then H meta length
        if classPos + 2 > len then return nil end
        local id = sub(s, pos + 3, classPos - 1)
        local class, metaLen = sunpack('<BH', s, classPos)
        local a = classPos + 3
        local e = a + metaLen - 1
        if e > len then return nil end
        list[i] = { idx = idx, id = id, class = class, meta = wantMeta and blobArg(s, a, e) or nil }
        pos = e + 1
    end
    return list, pos
end

--- Decodes one stream payload (`header .. op*`) into handler calls (see the file header and INTERFACES §2).
--- -> true | false, 'header' | 'version:<n>' | 'truncated' | 'unknown_op:<n>'
function Codec.decode(blob, h)
    if type(blob) ~= 'string' or #blob < 5 then return false, 'header' end
    if type(h) ~= 'table' then h = NO_HANDLERS end
    local len = #blob
    local version, now = sunpack('<BI4', blob, 1)
    if version ~= VERSION then return false, 'version:' .. version end
    resetCtx()
    local fn = h.header
    if fn then fn(version, now) end
    local pos, remaining = 6, 0
    while pos <= len do
        local op = byte(blob, pos)
        pos = pos + 1
        if op >= 0x10 and op <= 0x18 then
            local inSection = remaining > 0
            if inSection then remaining = remaining - 1 end
            if op == 0x10 then                                               -- PUT
                if pos + 36 > len then return false, 'truncated' end
                local id, kind, ver, parent, flags, x, y, z, rx, ry, rz, radius, n =
                    sunpack('<I4HI4I4Bi4i4i4i2i2i2HH', blob, pos)
                local a = pos + 37
                local e = a + n - 1
                if e > len then return false, 'truncated' end
                pos = e + 1
                fn = h.put
                if fn then
                    fn(id, kind, ver, parent, flags, x / 100, y / 100, z / 100, rx / 100, ry / 100, rz / 100,
                        radius, blobArg(blob, a, e), ctx)
                end
            elseif op == 0x11 or op == 0x13 then                             -- SET, MOTION
                if pos + 9 > len then return false, 'truncated' end
                local id, ver, n = sunpack('<I4I4H', blob, pos)
                local a = pos + 10
                local e = a + n - 1
                if e > len then return false, 'truncated' end
                pos = e + 1
                if op == 0x11 then fn = h.set else fn = h.motion end
                if fn then fn(id, ver, blobArg(blob, a, e), ctx) end
            elseif op == 0x12 or op == 0x18 then                             -- MOVE, DEMOTE
                if pos + 25 > len then return false, 'truncated' end
                local id, ver, x, y, z, rx, ry, rz = sunpack('<I4I4i4i4i4i2i2i2', blob, pos)
                pos = pos + 26
                if op == 0x12 then fn = h.move else fn = h.demote end
                if fn then fn(id, ver, x / 100, y / 100, z / 100, rx / 100, ry / 100, rz / 100, ctx) end
            elseif op == 0x14 then                                           -- DEL
                if pos + 8 > len then return false, 'truncated' end
                local id, ver, how = sunpack('<I4I4B', blob, pos)
                pos = pos + 9
                fn = h.del
                if fn then fn(id, ver, how, ctx) end
            elseif op == 0x15 then                                           -- EVENT
                if pos + 20 > len then return false, 'truncated' end
                local id, t, x, y, z, nameLen = sunpack('<I4I4i4i4i4B', blob, pos)
                local nameEnd = pos + 21 + nameLen                          -- first byte of the s2 length
                if nameEnd + 1 > len then return false, 'truncated' end
                local name = sub(blob, pos + 21, nameEnd - 1)
                local n = sunpack('<H', blob, nameEnd)
                local a = nameEnd + 2
                local e = a + n - 1
                if e > len then return false, 'truncated' end
                pos = e + 1
                fn = h.event
                if fn then fn(id, t, x / 100, y / 100, z / 100, name, blobArg(blob, a, e), ctx) end
            elseif op == 0x16 then                                           -- DR
                if pos + 27 > len then return false, 'truncated' end
                local id, t, x, y, z, vx, vy, vz, yaw = sunpack('<I4I4i4i4i4i2i2i2i2', blob, pos)
                pos = pos + 28
                fn = h.dr
                if fn then fn(id, t, x / 100, y / 100, z / 100, vx / 100, vy / 100, vz / 100, yaw / 100, ctx) end
            else                                                             -- PROMOTE (0x17)
                if pos + 9 > len then return false, 'truncated' end
                local id, ver, netId = sunpack('<I4I4H', blob, pos)
                pos = pos + 10
                fn = h.promote
                if fn then fn(id, ver, netId, ctx) end
            end
            if inSection and remaining == 0 then resetCtx() end
        elseif op == 0x04 then                                               -- CELL
            if remaining > 0 then return false, 'truncated' end              -- the previous section was cut short
            if pos + 15 > len then return false, 'truncated' end
            local grid, key, variant, from, to, n = sunpack('<BI4BI4I4H', blob, pos)
            pos = pos + 16
            ctx.section, ctx.grid, ctx.key, ctx.variant, ctx.from, ctx.to = 'cell', grid, key, variant, from, to
            remaining = n
            fn = h.cell
            if fn then fn(grid, key, variant, from, to, n) end
            if n == 0 then resetCtx() end
        elseif op == 0x05 then                                               -- PRIV
            if remaining > 0 then return false, 'truncated' end
            if pos + 1 > len then return false, 'truncated' end
            local n = sunpack('<H', blob, pos)
            pos = pos + 2
            resetCtx()
            ctx.section = 'priv'
            remaining = n
            fn = h.priv
            if fn then fn(n) end
            if n == 0 then resetCtx() end
        elseif op == 0x02 then                                               -- SUB
            if pos + 9 > len then return false, 'truncated' end
            local grid, key, variant, v = sunpack('<BI4BI4', blob, pos)
            pos = pos + 10
            fn = h.sub
            if fn then fn(grid, key, variant, v) end
        elseif op == 0x06 then                                               -- RESET
            if remaining > 0 then return false, 'truncated' end              -- would land inside a section
            if pos > len then return false, 'truncated' end
            local reason = byte(blob, pos)
            pos = pos + 1
            fn = h.reset
            if fn then fn(reason) end
        elseif op == 0x03 then                                               -- UNSUB
            if pos + 4 > len then return false, 'truncated' end
            local grid, key = sunpack('<BI4', blob, pos)
            pos = pos + 5
            fn = h.unsub
            if fn then fn(grid, key) end
        elseif op == 0x01 then                                               -- KINDS
            fn = h.kinds
            local list, nextPos = decodeKinds(blob, pos, len, fn ~= nil)
            if not list then return false, 'truncated' end
            pos = nextPos
            if fn then fn(list) end
        else
            return false, 'unknown_op:' .. op
        end
    end
    if remaining > 0 then return false, 'truncated' end
    return true
end

Core.SceneCodec = Codec
