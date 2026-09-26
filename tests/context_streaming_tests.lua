-- Deterministic context and streaming checks: no game or external dependencies.
local here = (arg[0]:match('^(.*)/') or '.')
local passed = 0
local function eq(a, b, label)
    assert(a == b, ('%s: expected %s, got %s'):format(label, tostring(b), tostring(a)))
    passed = passed + 1
end
local now, owner, ped, vehicle, seat, weapon = 0, 'alpha', 1, 0, nil, 10
local threads, tracked, removers, events, errors = {}, {}, {}, {}, 0
local exists, pedReads, seatReads = true, 0, 0
local env = setmetatable({}, { __index = _G })
local Core = { Player = {}, Registry = {}, Utils = {}, Log = {} }
env.Core = Core
Core.Utils.isCallable = function(v) return type(v) == 'function' or (type(v) == 'table' and getmetatable(v) and getmetatable(v).__call ~= nil) end
Core.Log.error = function() errors = errors + 1 end
Core.Registry.getCaller = function() return owner end
Core.Registry.track = function(kind, id, who) tracked[id] = { kind = kind, owner = who } end
Core.Registry.untrack = function(_, id) tracked[id] = nil end
Core.Registry.onOwnerStop = function(kind, fn) removers[kind] = fn end
env.GetGameTimer = function() return now end
env.PlayerPedId = function() pedReads = pedReads + 1; return ped end
env.DoesEntityExist = function() return exists and 1 or 0 end
env.GetVehiclePedIsIn = function() return vehicle end
env.GetVehicleMaxNumberOfPassengers = function() return 3 end
env.GetPedInVehicleSeat = function(_, index, flag)
    eq(flag, false, 'seat third argument')
    seatReads = seatReads + 1
    return index == seat and ped or 0
end
env.GetSelectedPedWeapon = function() return weapon end
env.CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end
env.Wait = function(ms) coroutine.yield(ms) end
local function tick(ms)
    now = now + (ms or 250)
    local current = threads
    threads = {}
    for _, co in ipairs(current) do
        if coroutine.status(co) ~= 'dead' then
            local ok, err = coroutine.resume(co)
            assert(ok, err)
            if coroutine.status(co) ~= 'dead' then threads[#threads + 1] = co end
        end
    end
end
assert(loadfile(here .. '/../client/context.lua', 't', env))()
tick(); eq(pedReads, 0, 'no context polling without consumers')
local snapshot = Core.Player.context()
eq(snapshot.ped, 1, 'initial ped'); eq(snapshot.vehicle, 0, 'initial vehicle'); eq(snapshot.seat, nil, 'initial seat')
snapshot.ped = 999
eq(Core.Player.context().ped, 1, 'detached context'); eq(pedReads, 1, 'cache shares sample')
eq(Core.Player.onContextChange('coords', function() end), nil, 'invalid key')
eq(Core.Player.onContextChange('ped', {}), nil, 'invalid callback')
local listener = Core.Player.onContextChange('vehicle', setmetatable({}, { __call = function(_, value, previous)
    events[#events + 1] = { value, previous, Core.Player.context().seat }
end }))
eq(type(listener), 'string', 'callable funcref registration')
vehicle, seat = 20, -1
tick(); tick(0)
eq(#events, 1, 'vehicle change once'); eq(events[1][1], 20, 'vehicle value')
eq(events[1][2], 0, 'vehicle previous'); eq(events[1][3], -1, 'callback coherent snapshot')
local oldReads = seatReads
tick(); tick(0)
eq(#events, 1, 'unchanged no event'); eq(seatReads - oldReads, 1, 'cached seat avoids full scan')
seat = 2; tick()
eq(Core.Player.context().seat, 2, 'seat swap refreshed')
vehicle, seat = 0, nil; tick(); tick(0)
eq(#events, 2, 'vehicle exit once'); eq(events[2][1], 0, 'on foot value')
owner = 'beta'; eq(Core.Player.offContextChange(listener), false, 'foreign remove denied')
owner = 'alpha'; eq(Core.Player.offContextChange(listener), true, 'owner remove')
eq(Core.Player.offContextChange(listener), false, 'idempotent remove')
oldReads = pedReads; tick(); eq(pedReads, oldReads, 'unsubscribed watcher no work')
local changed = Core.Player.onContextChange('weapon', function() error('isolated') end)
weapon = 11; tick(); tick(0); eq(errors, 1, 'callback error isolated')
removers.context(changed, 'alpha'); eq(next(tracked), nil, 'registry stop cleanup')
local afterStop = 0
local stopped = Core.Player.onContextChange('weapon', function() afterStop = afterStop + 1 end)
weapon = 12; tick(); removers.context(stopped, 'alpha'); tick(0)
eq(afterStop, 0, 'queued callback suppressed on stop')
local slowCalls = 0
local slow = Core.Player.onContextChange('weapon', function()
    slowCalls = slowCalls + 1
    env.Wait(250)
    env.Wait(250)
end)
weapon = 13; tick(); tick(0)
weapon = 14; tick(); weapon = 15; tick(); tick()
eq(slowCalls <= 2, true, 'slow subscriber bounded/coalesced')
removers.context(slow, 'alpha')
ped = 0; tick(); eq(Core.Player.context().ped, 0, 'ped transition zero')
eq(Core.Player.context().weapon, 0, 'ped transition clears weapon')
ped = 99; exists = false; tick(); eq(Core.Player.context().ped, 0, 'nonexistent ped ignored')

local streaming = {}
local s = setmetatable({}, { __index = _G })
s.Core = { Config = { StreamingTimeoutMs = 20 } }
s.GetGameTimer = function() return now end
s.Wait = function(ms) now = now + math.max(1, ms) end
local ready, requests, releases = false, 0, 0
s.GetHashKey = function(name) return name == 'invalid' and 0 or 123 end
s.IsWeaponValid = function(hash) return hash ~= 0 end
local function release() releases = releases + 1 end
local function request() requests = requests + 1 end
local function loaded() return ready end
s.RequestStreamedTextureDict = request
s.HasStreamedTextureDictLoaded = loaded
s.SetStreamedTextureDictAsNoLongerNeeded = release
s.RequestScaleformMovie = function() request(); return 42 end
s.HasScaleformMovieLoaded = loaded
s.SetScaleformMovieAsNoLongerNeeded = function(handle) eq(handle, 42, 'movie release handle'); release() end
s.RequestScriptAudioBank = function(_, networked, playerBits)
    eq(networked, false, 'bank local'); eq(playerBits, -1, 'bank playerBits'); request(); return ready
end
s.ReleaseNamedScriptAudioBank = release
s.RequestWeaponAsset = function(_, flags, extra) eq(flags, 31, 'weapon flags'); eq(extra, 0, 'weapon extras'); request() end
s.HasWeaponAssetLoaded = loaded
s.RemoveWeaponAsset = release
assert(loadfile(here .. '/../lib/streaming/client.lua', 't', s))(streaming)
local cases = {
    { 'requestTextureDict', 'releaseTextureDict', 'test', true },
    { 'requestScaleform', 'releaseScaleform', 'test', 42 },
    { 'requestAudioBank', 'releaseAudioBank', 'test', true },
    { 'requestWeaponAsset', 'releaseWeaponAsset', 'weapon_pistol', true },
}
for _, case in ipairs(cases) do
    local fn, releaseFn, name, success = table.unpack(case)
    local failure = false
    if fn == 'requestScaleform' then failure = nil end
    ready = true
    eq(streaming[fn](name, 10), success, fn .. ' immediate')
    local before = releases
    streaming[releaseFn](fn == 'requestScaleform' and 42 or name)
    eq(releases, before + 1, fn .. ' explicit release')
    ready = 0
    local started = now
    before = releases
    eq(streaming[fn](name, 3), failure, fn .. ' zero BOOL times out')
    eq(now - started, 3, fn .. ' bounded wait')
    eq(releases, before + 1, fn .. ' timeout release')
    local beforeRequests = requests
    for _, bad in ipairs({ 0, -1, 0/0, math.huge, 60001, '5' }) do
        eq(streaming[fn](name, bad), failure, fn .. ' invalid timeout')
    end
    eq(requests, beforeRequests, fn .. ' invalid timeout no native requests')
    eq(streaming[fn]('', 10), failure, fn .. ' empty name')
    eq(streaming[fn]('nul\0name', 10), failure, fn .. ' embedded NUL')
    eq(streaming[fn](string.rep('a', 257), 10), failure, fn .. ' oversize name')
    ready = 1
    eq(streaming[fn](name, 3), success, fn .. ' numeric true accepted')
end
eq(streaming.requestWeaponAsset('invalid', 1), false, 'invalid weapon')
eq(streaming.requestWeaponAsset(999999999999, 1), false, 'out of hash range')
local beforeRequests = requests
eq(streaming.requestTextureDict(false, 1), false, 'non-string asset')
eq(requests, beforeRequests, 'non-string no native request')
s.Core.Config.StreamingTimeoutMs = 0/0
ready = false
local started = now
eq(streaming.requestTextureDict('test'), false, 'invalid config safe fallback')
eq(now - started, 10000, 'fallback timeout finite')
print(('context_streaming: %d passed, 0 failed'):format(passed))
