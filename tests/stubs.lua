--[[
    core/tests/stubs.lua — an offline stand-in for the FiveM Lua runtime.

    Plain `lua5.4`, no FiveM. `stubs.newEnv(side, resourceName)` builds a fresh `_ENV`
    table that carries the natives and runtime helpers `import.lua` and the libs use, so
    a resource VM can be simulated in-process:

        local server = stubs.newEnv('server', 'core_example')
        stubs.loadImport(server)            -- runs core/import.lua inside that VM
        server.Core.Utils.formatMoney(1234)

    Time is virtual: nothing sleeps, `stubs.tick(ms)` advances the clock and runs the
    timers and threads that come due. Events cross VMs inside the same "world"
    (`stubs.newWorld()`), so a server VM and a client VM can talk to each other.

    Nothing here proves in-game behaviour — these are stubs, not the engine.
]]

local stubs = {}

local selfPath = debug.getinfo(1, 'S').source:sub(2)
local testsDir = selfPath:match('^(.*)[/\\][^/\\]*$') or '.'
stubs.root = testsDir .. '/..'            -- the resource directory (core/)

--------------------------------------------------------------------------------
-- vector2 / vector3 / vector4 and the `type` override that knows about them
--------------------------------------------------------------------------------

local rawtype = type
local vec2mt, vec3mt, vec4mt = {}, {}, {}
local VECTOR_NAME = { [vec2mt] = 'vector2', [vec3mt] = 'vector3', [vec4mt] = 'vector4' }

local function vector2(x, y) return setmetatable({ x = x, y = y }, vec2mt) end
local function vector3(x, y, z) return setmetatable({ x = x, y = y, z = z }, vec3mt) end
local function vector4(x, y, z, w) return setmetatable({ x = x, y = y, z = z, w = w }, vec4mt) end

--- type() that reports vectors like the CitizenFX Lua runtime does.
local function xtype(v)
    if rawtype(v) == 'table' then
        local name = VECTOR_NAME[getmetatable(v)]
        if name then return name end
    end
    return rawtype(v)
end

vec3mt.__sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end
vec3mt.__add = function(a, b) return vector3(a.x + b.x, a.y + b.y, a.z + b.z) end
vec3mt.__mul = function(a, b)
    if rawtype(a) == 'number' then return vector3(a * b.x, a * b.y, a * b.z) end
    return vector3(a.x * b, a.y * b, a.z * b)
end
vec3mt.__len = function(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
vec3mt.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
vec3mt.__tostring = function(v) return ('vector3(%s, %s, %s)'):format(v.x, v.y, v.z) end
vec2mt.__sub = function(a, b) return vector2(a.x - b.x, a.y - b.y) end
vec2mt.__len = function(v) return math.sqrt(v.x * v.x + v.y * v.y) end
vec4mt.__sub = function(a, b) return vector4(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w) end
vec4mt.__len = function(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z + v.w * v.w) end

stubs.vector2, stubs.vector3, stubs.vector4, stubs.type = vector2, vector3, vector4, xtype

--------------------------------------------------------------------------------
-- json (small, enough for the resource's encode/decode round trips)
--------------------------------------------------------------------------------

local ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function jsonEncode(v)
    local t = xtype(v)
    if v == nil then return 'null' end
    if t == 'boolean' then return tostring(v) end
    if t == 'number' then return (math.type(v) == 'integer') and tostring(v) or ('%.14g'):format(v) end
    if t == 'string' then
        return '"' .. v:gsub('[%c"\\]', function(c) return ESCAPES[c] or ('\\u%04x'):format(c:byte()) end) .. '"'
    end
    if t ~= 'table' then error('json: cannot encode ' .. t, 0) end
    local parts = {}
    if v[1] ~= nil or next(v) == nil then
        for i = 1, #v do parts[i] = jsonEncode(v[i]) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, value in pairs(v) do
        parts[#parts + 1] = jsonEncode(tostring(k)) .. ':' .. jsonEncode(value)
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

local parseValue

local function skipSpace(s, i)
    return s:find('[^ \t\r\n]', i) or #s + 1
end

local function parseString(s, i)
    local out, at = {}, i + 1
    while at <= #s do
        local c = s:sub(at, at)
        if c == '"' then return table.concat(out), at + 1 end
        if c == '\\' then
            local n = s:sub(at + 1, at + 1)
            local map = { n = '\n', r = '\r', t = '\t', b = '\b', f = '\f' }
            if n == 'u' then
                out[#out + 1] = utf8.char(tonumber(s:sub(at + 2, at + 5), 16) or 63)
                at = at + 6
            else
                out[#out + 1] = map[n] or n
                at = at + 2
            end
        else
            out[#out + 1] = c
            at = at + 1
        end
    end
    error('json: unterminated string', 0)
end

parseValue = function(s, i)
    i = skipSpace(s, i)
    local c = s:sub(i, i)
    if c == '"' then return parseString(s, i) end
    if c == '{' or c == '[' then
        local isArray, out, n = c == '[', {}, 0
        i = skipSpace(s, i + 1)
        if s:sub(i, i) == (isArray and ']' or '}') then return out, i + 1 end
        while true do
            local key
            if isArray then
                n = n + 1
                key = n
            else
                key, i = parseString(s, skipSpace(s, i))
                i = skipSpace(s, i) + 1  -- the ':'
            end
            out[key], i = parseValue(s, i)
            i = skipSpace(s, i)
            local sep = s:sub(i, i)
            i = i + 1
            if sep ~= ',' then return out, i end
        end
    end
    local word = s:match('^[%w%.%+%-eE]+', i)
    if not word then error('json: unexpected character at ' .. i, 0) end
    local value = (word == 'true' and true) or (word == 'false' and false)
        or (word == 'null' and nil) or tonumber(word)
    return value, i + #word
end

local json = {
    encode = jsonEncode,
    decode = function(s)
        if rawtype(s) ~= 'string' then return nil end
        local ok, value = pcall(parseValue, s, 1)
        if not ok then return nil end
        return value
    end,
}
stubs.json = json

--------------------------------------------------------------------------------
-- Virtual clock, promises, timers and threads
--------------------------------------------------------------------------------

local clock = 0
local timers = {}            -- { at = ms, fn = fn, cancelled = bool }
local threadByCo = {}        -- coroutine -> record
local scheduled = {}         -- record -> true (records waiting for the clock)
local failures = {}          -- uncaught errors from threads/timers, for the tests to inspect

stubs.failures = failures

local promise = {}
promise.__index = promise

function promise.new()
    return setmetatable({ state = 'pending', waiters = {} }, promise)
end

function promise:resolve(value)
    if self.state ~= 'pending' then return end
    self.state, self.value = 'resolved', value
    local waiters = self.waiters
    self.waiters = {}
    for i = 1, #waiters do waiters[i](value) end
end

promise.reject = promise.resolve   -- core never rejects; a rejection reads as a nil answer

--- Resume one thread record and re-schedule it according to what it yielded:
--- a number = Wait(ms), anything else = suspended until something resumes it.
local function step(rec, ...)
    scheduled[rec] = nil
    local ok, yielded = coroutine.resume(rec.co, ...)
    if not ok then
        failures[#failures + 1] = tostring(yielded)
        print('[stubs] thread error: ' .. tostring(yielded))
        return
    end
    if coroutine.status(rec.co) == 'dead' then
        threadByCo[rec.co] = nil
        return
    end
    if rawtype(yielded) == 'number' then
        rec.at = clock + yielded
        scheduled[rec] = true
    end
end

local Citizen = {}

--- Suspends the running coroutine until the promise resolves (CitizenFX semantics).
function Citizen.Await(p)
    if p.state == 'resolved' then return p.value end
    local co = coroutine.running()
    p.waiters[#p.waiters + 1] = function(value)
        local rec = threadByCo[co]
        if rec then return step(rec, value) end
        coroutine.resume(co, value)
    end
    return coroutine.yield('await')
end

local function createThread(fn)
    local co = coroutine.create(fn)
    local rec = { co = co, at = clock }
    threadByCo[co] = rec
    step(rec)                     -- FiveM starts the body right away; it runs to its first Wait
    return co
end

local function setTimeout(ms, fn)
    local timer = { at = clock + (tonumber(ms) or 0), fn = fn }
    timers[#timers + 1] = timer
    return timer
end

local function clearTimeout(timer)
    if rawtype(timer) == 'table' then timer.cancelled = true end
end

--- Earliest timer/thread due at or before `target`, timers first on a tie.
local function nextDue(target)
    local best, kind
    for i = 1, #timers do
        local t = timers[i]
        if not t.cancelled and t.at <= target and (not best or t.at < best.at) then best, kind = t, 'timer' end
    end
    for rec in pairs(scheduled) do
        if rec.at <= target and (not best or rec.at < best.at) then best, kind = rec, 'thread' end
    end
    return best, kind
end

--- Advances the virtual clock by `ms`, running everything that comes due on the way.
function stubs.tick(ms)
    local target = clock + (ms or 0)
    for _ = 1, 20000 do
        local item, kind = nextDue(target)
        if not item then break end
        if item.at > clock then clock = item.at end
        if kind == 'timer' then
            for i = 1, #timers do
                if timers[i] == item then table.remove(timers, i) break end
            end
            local ok, err = pcall(item.fn)
            if not ok then
                failures[#failures + 1] = tostring(err)
                print('[stubs] timer error: ' .. tostring(err))
            end
        else
            step(item)
        end
        if _ == 20000 then error('stubs.tick: scheduler did not settle (busy loop?)', 0) end
    end
    clock = target
    return clock
end

function stubs.now()
    return clock
end

--------------------------------------------------------------------------------
-- Worlds, the event bus and exports
--------------------------------------------------------------------------------

stubs.sent = {}              -- every cross-side send: { side, name, target, args }
stubs.printed = {}           -- every print() from a stubbed VM
stubs.exports = {}           -- resourceName -> { exportName = fn }; preload a fake core.call here
stubs.aces = {}              -- ('%s|%s'):format(src, object) -> true
stubs.peds = { [1] = 101 }   -- server id -> ped entity (0 / missing = no ped)
stubs.coords = {}            -- entity -> vector3
stubs.playerNames = {}       -- server id -> name
stubs.resourceStates = { core = 'started' }
stubs.nuiFocused = false
stubs.pauseMenu = false
stubs.net = { drop = false, latency = 0 }   -- drop = packets vanish, latency = ms before delivery
stubs.clientSrc = 1

local world = { server = {}, client = {} }

--- Starts a fresh, isolated pair of VM lists so suites cannot cross-talk.
function stubs.newWorld()
    world = { server = {}, client = {}, states = {}, entityStates = {}, global = nil }
    return world
end
stubs.newWorld()

function stubs.clear()
    stubs.sent, stubs.printed = {}, {}
end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local data = fh:read('a')
    fh:close()
    return data
end
stubs.readFile = readFile

local function dispatch(rec, name, src, ...)
    local list = rec.handlers[name]
    if not list or #list == 0 then return end
    local previous = rec.env.source
    rec.env.source = src
    for i = 1, #list do
        local ok, err = pcall(list[i].fn, ...)
        if not ok then
            stubs.failures[#stubs.failures + 1] = tostring(err)
            print('[stubs] handler error in ' .. name .. ': ' .. tostring(err))
        end
    end
    rec.env.source = previous
end

--- Cross-side delivery, honouring stubs.net.drop / stubs.net.latency.
local function send(rec, side, name, target, src, ...)
    stubs.sent[#stubs.sent + 1] = { side = side, name = name, target = target, args = table.pack(...) }
    if stubs.net.drop then return end
    local args = table.pack(...)
    local targets = rec.world[side]
    local function deliver()
        for i = 1, #targets do
            local peer = targets[i]
            if side == 'server' or target == -1 or tonumber(target) == peer.clientSrc then
                dispatch(peer, name, src, table.unpack(args, 1, args.n))
            end
        end
    end
    if stubs.net.latency > 0 then setTimeout(stubs.net.latency, deliver) else deliver() end
end

--- Fires a local event inside one VM with `source` set to `src` (playerDropped, hooks, ...).
function stubs.triggerOn(env, name, src, ...)
    return dispatch(env.__vm, name, src, ...)
end

local function makeExports(rec)
    return setmetatable({}, {
        __call = function(_, name, fn)
            local own = stubs.exports[rec.resourceName] or {}
            stubs.exports[rec.resourceName] = own
            own[name] = fn
        end,
        __index = function(_, resourceName)
            return setmetatable({}, {
                __index = function(_, exportName)
                    return function(_self, ...)
                        local own = stubs.exports[resourceName]
                        local fn = own and own[exportName]
                        if not fn then
                            error(("No such export %s in resource %s"):format(exportName, resourceName), 2)
                        end
                        return fn(...)
                    end
                end,
            })
        end,
    })
end

--- The `.state` table of a player / the global bag: plain keys plus a `set` method.
local function newStateBag()
    local bag = {}
    bag.set = function(self, key, value)
        rawset(self == bag and bag or self, key, value)
    end
    return bag
end

function stubs.playerState(env, src)
    local states = env.__vm.world.states
    states[src] = states[src] or newStateBag()
    return states[src]
end

--------------------------------------------------------------------------------
-- Server world: KVP, connected players, entities (used by tests/server_tests.lua)
--------------------------------------------------------------------------------

stubs.kvp = {}               -- the resource KVP store; outlives newEnv so a reload round trips
stubs.kvpFlushes = 0         -- FlushResourceKvp() call count
stubs.identifiers = {}       -- src -> { license = 'license:...', discord = ..., ... }
stubs.connected = {}         -- array of connected server ids (GetPlayers / GetPlayerFromIndex)
stubs.dropped = {}           -- every DropPlayer(src, reason)
stubs.buckets = {}           -- src -> routing bucket
stubs.headings = {}          -- entity -> heading
stubs.health = {}            -- entity -> health (a ped with no entry reads 200)
stubs.entities = {}          -- entity handle -> { type, exists, netId, model, plate, ... }
stubs.pedVehicle = {}        -- ped -> vehicle handle (GetVehiclePedIsIn)
stubs.vehicleSeats = {}      -- vehicle -> { [seat] = ped } (GetPedInVehicleSeat)
stubs.savedFiles = {}        -- every SaveResourceFile(resource, file, data)
stubs.invokingResource = nil -- what GetInvokingResource() reports
stubs.spawnFails = false     -- CreateVehicleServerSetter returns 0
stubs.spawnDelayMs = 0       -- ms until DoesEntityExist() turns true for a fresh vehicle
stubs.osTime = nil           -- fixed os.time() seconds; nil = pass through to the real clock

local nextEntity = 1000
local nextNetId = 100
local findHandles, nextFindHandle = {}, 0

--- Registers a fake entity and returns its handle. kind: 1 = ped, 2 = vehicle, 3 = object.
local function newEntity(kind, fields)
    nextEntity = nextEntity + 1
    nextNetId = nextNetId + 1
    local entity = fields or {}
    entity.handle, entity.type, entity.exists, entity.netId = nextEntity, kind, true, nextNetId
    stubs.entities[nextEntity] = entity
    return nextEntity
end
stubs.newEntity = newEntity

local function removeConnected(src)
    for i = #stubs.connected, 1, -1 do
        if stubs.connected[i] == src then table.remove(stubs.connected, i) end
    end
end

--- Clears every server-side store, KVP included. Call it between suites — but NOT between the
--- two halves of a persistence round trip, where the surviving KVP table is the point.
function stubs.resetServer()
    stubs.kvp, stubs.kvpFlushes = {}, 0
    stubs.identifiers, stubs.connected, stubs.dropped, stubs.buckets = {}, {}, {}, {}
    stubs.entities, stubs.savedFiles = {}, {}
    stubs.peds, stubs.coords, stubs.headings, stubs.health = {}, {}, {}, {}
    stubs.pedVehicle, stubs.vehicleSeats = {}, {}
    stubs.playerNames, stubs.aces = {}, {}
    stubs.invokingResource, stubs.spawnFails, stubs.spawnDelayMs, stubs.osTime = nil, false, 0, nil
    nextEntity, nextNetId = 1000, 100
    findHandles, nextFindHandle = {}, 0
end

--- The `.state` table of one entity bag (`entity:<netId>` in game).
function stubs.entityState(env, entity)
    local world = env.__vm.world
    local states = world.entityStates
    if not states then
        states = {}
        world.entityStates = states
    end
    states[entity] = states[entity] or newStateBag()
    return states[entity]
end

--- Simulates a join: identifiers, name, a ped and the `playerJoining` event with `source = src`.
--- opts = { license, name, coords, heading, ped, identifiers, joining = false to skip the event }.
function stubs.connectPlayer(env, src, opts)
    opts = opts or {}
    src = tonumber(src) or 1
    stubs.identifiers[src] = opts.identifiers or {
        license = opts.license or ('license:%08x'):format(src),
        fivem = ('fivem:%d'):format(src),
    }
    stubs.playerNames[src] = opts.name or ('Player%d'):format(src)
    local ped = opts.ped
    if ped == nil then ped = newEntity(1, {}) end
    stubs.peds[src] = ped
    stubs.health[ped] = opts.health or 200
    stubs.coords[ped] = opts.coords or vector3(0.0, 0.0, 0.0)
    stubs.headings[ped] = opts.heading or 0.0
    removeConnected(src)
    stubs.connected[#stubs.connected + 1] = src
    if opts.joining ~= false then dispatch(env.__vm, 'playerJoining', src, opts.oldId or src) end
    return src
end

--- Fires `playerDropped` with `source = src` and forgets the player, ped included.
function stubs.dropPlayer(env, src, reason)
    src = tonumber(src) or 1
    dispatch(env.__vm, 'playerDropped', src, reason or 'quit', 'core', 'Exiting')
    removeConnected(src)
    local ped = stubs.peds[src]
    if ped then
        stubs.coords[ped], stubs.headings[ped], stubs.health[ped] = nil, nil, nil
        if stubs.entities[ped] then stubs.entities[ped].exists = false end
    end
    stubs.peds[src], stubs.playerNames[src], stubs.identifiers[src] = nil, nil, nil
    stubs.buckets[src] = nil
    return src
end

--- Installs the server-only half of the runtime on a server VM (called at the end of newEnv, so
--- nothing here is overwritten again). Every native was confirmed with `fxref show`; all of them
--- are apiset server, shared or client+server.
local function installServerNatives(env, rec)
    -- KVP store (apiset shared; core only uses it server-side)
    env.SetResourceKvp = function(key, value) stubs.kvp[key] = tostring(value) end
    env.SetResourceKvpNoSync = function(key, value) stubs.kvp[key] = tostring(value) end
    env.GetResourceKvpString = function(key) return stubs.kvp[key] end
    env.DeleteResourceKvp = function(key) stubs.kvp[key] = nil end
    env.DeleteResourceKvpNoSync = function(key) stubs.kvp[key] = nil end
    env.FlushResourceKvp = function() stubs.kvpFlushes = stubs.kvpFlushes + 1 end
    env.StartFindKvp = function(prefix)
        if rawtype(prefix) ~= 'string' then return -1 end
        local keys = {}
        for key in pairs(stubs.kvp) do
            if key:sub(1, #prefix) == prefix then keys[#keys + 1] = key end
        end
        table.sort(keys)
        nextFindHandle = nextFindHandle + 1
        findHandles[nextFindHandle] = { keys = keys, at = 0 }
        return nextFindHandle
    end
    env.FindKvp = function(handle)
        local find = findHandles[handle]
        if not find then return nil end
        find.at = find.at + 1
        return find.keys[find.at]
    end
    env.EndFindKvp = function(handle) findHandles[handle] = nil end

    -- players
    env.GetPlayerIdentifierByType = function(src, kind)
        local ids = stubs.identifiers[tonumber(src)]
        return ids and ids[kind] or nil
    end
    env.GetNumPlayerIndices = function() return #stubs.connected end
    env.GetPlayerFromIndex = function(index)         -- 0-based, like the engine
        local src = stubs.connected[(tonumber(index) or 0) + 1]
        return src and tostring(src) or nil
    end
    env.GetPlayers = function()
        local out = {}
        for i = 1, #stubs.connected do out[i] = tostring(stubs.connected[i]) end
        return out
    end
    env.DropPlayer = function(src, reason)
        stubs.dropped[#stubs.dropped + 1] = { src = tonumber(src), reason = reason }
    end
    env.GetPlayerRoutingBucket = function(src) return stubs.buckets[tonumber(src)] or 0 end
    env.SetPlayerRoutingBucket = function(src, bucket) stubs.buckets[tonumber(src)] = bucket end

    -- entities
    env.CreateVehicleServerSetter = function(model, vehType, x, y, z, heading)
        if stubs.spawnFails then return 0 end
        local entity = newEntity(2, { model = model, vehType = vehType })
        stubs.coords[entity] = vector3(x + 0.0, y + 0.0, z + 0.0)
        stubs.headings[entity] = (heading or 0.0) + 0.0
        if stubs.spawnDelayMs > 0 then
            local record = stubs.entities[entity]
            record.exists = false
            setTimeout(stubs.spawnDelayMs, function() record.exists = true end)
        end
        return entity
    end
    env.DoesEntityExist = function(entity)
        local record = stubs.entities[entity]
        return record ~= nil and record.exists == true
    end
    env.DeleteEntity = function(entity)
        local record = stubs.entities[entity]
        if record then record.exists = false end
        stubs.coords[entity], stubs.headings[entity] = nil, nil
        local states = rec.world.entityStates
        if states then states[entity] = nil end
    end
    env.GetEntityType = function(entity)
        local record = stubs.entities[entity]
        return (record and record.exists) and record.type or 0
    end
    env.GetEntityHeading = function(entity) return stubs.headings[entity] or 0.0 end
    env.GetEntityHealth = function(entity)
        local value = stubs.health[entity]
        if value == nil then return 200 end
        return value
    end
    env.SetVehicleNumberPlateText = function(entity, plate)
        local record = stubs.entities[entity]
        if record then record.plate = plate end
    end
    env.NetworkGetNetworkIdFromEntity = function(entity)
        local record = stubs.entities[entity]
        return (record and record.exists) and record.netId or 0
    end
    env.NetworkGetEntityFromNetworkId = function(netId)
        for entity, record in pairs(stubs.entities) do
            if record.netId == netId and record.exists then return entity end
        end
        return 0
    end
    env.SetEntityOrphanMode = function(entity, mode)
        local record = stubs.entities[entity]
        if record then record.orphanMode = mode end
    end
    env.SetEntityRoutingBucket = function(entity, bucket)
        local record = stubs.entities[entity]
        if record then record.bucket = bucket end
    end
    env.SetVehicleDoorsLocked = function(entity, lockState)
        local record = stubs.entities[entity]
        if record then record.lockState = lockState end
    end
    env.GetVehiclePedIsIn = function(ped) return stubs.pedVehicle[ped] or 0 end
    env.GetPedInVehicleSeat = function(vehicle, seat)
        local seats = stubs.vehicleSeats[vehicle]
        return seats and seats[seat] or 0
    end
    env.GetAllVehicles = function()
        local out = {}
        for entity, record in pairs(stubs.entities) do
            if record.exists and record.type == 2 then out[#out + 1] = entity end
        end
        table.sort(out)
        return out
    end
    env.Entity = function(entity) return { state = stubs.entityState(env, entity) } end

    -- misc server natives / runtime helpers
    env.GetInvokingResource = function() return stubs.invokingResource end
    env.SaveResourceFile = function(resource, file, data)
        stubs.savedFiles[#stubs.savedFiles + 1] = { resource = resource, file = file, data = data }
        return true
    end
end

--------------------------------------------------------------------------------
-- newEnv: one simulated resource VM
--------------------------------------------------------------------------------

local STD <const> = { 'assert', 'error', 'ipairs', 'next', 'pairs', 'pcall', 'xpcall', 'select',
    'setmetatable', 'getmetatable', 'rawget', 'rawset', 'rawequal', 'rawlen', 'tonumber',
    'tostring', 'load', 'string', 'table', 'math', 'coroutine', 'utf8' }

local function hashKey(value)
    local s = tostring(value)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 0x100000000 end
    return math.tointeger(h) or 0
end

--- Builds a fresh `_ENV` for one resource VM. `side` is 'server' or 'client';
--- `resourceName` decides whether import.lua behaves as core or as a plugin.
function stubs.newEnv(side, resourceName)
    local isServer = side == 'server'
    local rec = {
        side = side, resourceName = resourceName, world = world, handlers = {}, netEvents = {},
        commands = {}, keyMappings = {}, clientSrc = stubs.clientSrc,
    }
    local env = { source = 0 }
    rec.env, env.__vm = env, rec
    world[side][#world[side] + 1] = rec

    env._G, env._VERSION = env, _VERSION
    for i = 1, #STD do env[STD[i]] = _G[STD[i]] end
    env.type = xtype
    if isServer then                            -- client Lua has no io/os
        -- os.time()/os.date() pass through; stubs.osTime pins "now" when a test needs a fixed clock
        env.os = setmetatable({
            time = function(spec)
                if spec ~= nil then return os.time(spec) end
                return stubs.osTime or os.time()
            end,
        }, { __index = os })
    end
    env.print = function(...)
        local parts = table.pack(...)
        for i = 1, parts.n do parts[i] = tostring(parts[i]) end
        local line = table.concat(parts, '\t', 1, parts.n)
        stubs.printed[#stubs.printed + 1] = line
        if stubs.echo then io.write(line, '\n') end
    end

    -- natives (all verified with `fxref show`; apiset matches the side they are used on)
    env.GetCurrentResourceName = function() return resourceName end
    env.IsDuplicityVersion = function() return isServer end
    env.LoadResourceFile = function(res, file)
        if res ~= 'core' or rawtype(file) ~= 'string' then return nil end
        return readFile(stubs.root .. '/' .. file)
    end
    env.GetResourceState = function(res) return stubs.resourceStates[res] or 'missing' end
    env.GetGameTimer = function() return math.floor(clock) end
    env.GetHashKey = hashKey
    env.GetPlayerPed = function(src) return stubs.peds[tonumber(src)] or 0 end
    env.GetEntityCoords = function(entity) return stubs.coords[entity] or vector3(0.0, 0.0, 0.0) end
    env.GetPlayerName = function(src) return stubs.playerNames[tonumber(src)] end
    env.RegisterCommand = function(name, fn, restricted)
        rec.commands[name] = { fn = fn, restricted = restricted }
    end
    env.AddStateBagChangeHandler = function() return 0 end
    env.GetPlayerFromStateBagName = function() return stubs.clientSrc end
    -- side-specific natives stay missing on the other side, exactly like the engine,
    -- so a wrong-apiset call shows up here instead of being silently absorbed
    if isServer then
        env.IsPlayerAceAllowed = function(src, object)
            return stubs.aces[('%s|%s'):format(src, object)] == true
        end
    else
        env.RegisterKeyMapping = function(command, description, mapper, key)
            rec.keyMappings[command] = { description = description, mapper = mapper, key = key }
        end
        env.IsNuiFocused = function() return stubs.nuiFocused end
        env.IsPauseMenuActive = function() return stubs.pauseMenu end
        env.PlayerPedId = function() return stubs.peds[stubs.clientSrc] or 101 end
        env.PlayerId = function() return 0 end
        env.GetPlayerServerId = function() return stubs.clientSrc end
    end

    -- runtime helpers (not natives)
    env.CreateThread = createThread
    env.Wait = function(ms) return coroutine.yield(tonumber(ms) or 0) end
    env.SetTimeout = setTimeout
    env.ClearTimeout = clearTimeout
    env.promise = promise
    env.Citizen = { Await = Citizen.Await, CreateThread = createThread, Wait = env.Wait,
        SetTimeout = setTimeout }
    env.json = json
    env.vector2, env.vector3, env.vector4 = vector2, vector3, vector4
    env.exports = makeExports(rec)
    env.GetPlayers = function() return isServer and { tostring(stubs.clientSrc) } or {} end

    local function addHandler(name, fn)
        if rawtype(fn) ~= 'function' then return nil end
        local list = rec.handlers[name]
        if not list then
            list = {}
            rec.handlers[name] = list
        end
        local handle = { name = name, fn = fn }
        list[#list + 1] = handle
        return handle
    end
    env.AddEventHandler = addHandler
    env.RegisterNetEvent = function(name, fn)
        rec.netEvents[name] = true
        return addHandler(name, fn)
    end
    env.RemoveEventHandler = function(handle)
        local list = rawtype(handle) == 'table' and rec.handlers[handle.name]
        if not list then return false end
        for i = 1, #list do
            if list[i] == handle then
                table.remove(list, i)
                return true
            end
        end
        return false
    end
    env.TriggerEvent = function(name, ...) return dispatch(rec, name, env.source, ...) end
    env.TriggerServerEvent = function(name, ...)
        if isServer then return end
        return send(rec, 'server', name, nil, rec.clientSrc, ...)
    end
    env.TriggerClientEvent = function(name, target, ...)
        if not isServer then return end
        return send(rec, 'client', name, target, 65535, ...)
    end

    env.Player = function(src) return { state = stubs.playerState(env, tonumber(src) or src) } end
    if not isServer then env.LocalPlayer = { state = stubs.playerState(env, 'local') } end
    rec.world.global = rec.world.global or newStateBag()
    env.GlobalState = rec.world.global
    if isServer then installServerNatives(env, rec) end
    return env
end

--- Compiles one of core's own files inside `env` and runs it (extra args reach the chunk).
function stubs.loadFile(env, relPath, ...)
    local code = readFile(stubs.root .. '/' .. relPath)
    if not code then error('stubs: missing file ' .. relPath, 2) end
    local chunk, err = load(code, '@' .. relPath, 't', env)
    if not chunk then error('stubs: ' .. tostring(err), 2) end
    return chunk(...)
end

--- Runs core/import.lua inside `env` and returns the resulting `Core` table.
function stubs.loadImport(env)
    stubs.loadFile(env, 'import.lua')
    return env.Core
end

return stubs
