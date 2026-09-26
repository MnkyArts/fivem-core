--[[
    core/tests/maps_regions_tests.lua — offline suite for Core.MapRegions (DESIGN §52.3, §52.4a).

        lua5.4 tests/maps_regions_tests.lua    (from the resource directory, or from tests/)

    Region key maths (negative coords, borders, clamping), put/move/remove across regions and buckets, the
    module-wide version counter, pack caching (encode count), window validation, the server-read bucket,
    subscription moves, latent packs only for stale regions, per-tick coalescing (delta vs stale), no pushes
    without subscribers, clearBucket, drop cleanup and the Callback cooldown. TriggerLatentClientEvent (a
    runtime helper stubs.lua lacks) is recorded here. Exit code is 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/maps_regions_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local passed, failed = 0, 0

local function eq(actual, expected, label)
    if actual == expected then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    print(('FAIL  [maps_regions] %s\n        expected %s, got %s'):format(label, tostring(expected), tostring(actual)))
    return false
end

local function check(cond, label)
    return eq(cond and true or false, true, label)
end

local latent = {}   -- every TriggerLatentClientEvent: { name, target, bps, args }

local function newServer(maps)
    stubs.newWorld()
    stubs.clear()
    stubs.resetServer()
    latent = {}
    local env = stubs.newEnv('server', 'core')
    env.TriggerLatentClientEvent = function(name, target, bps, ...)
        latent[#latent + 1] = { name = name, target = target, bps = bps, args = table.pack(...) }
    end
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    for k, v in pairs(maps or {}) do env.Config.Maps[k] = v end
    stubs.loadFile(env, 'server/api.lua')
    stubs.loadFile(env, 'server/maps_regions.lua')
    return env, env.Core.MapRegions
end

local OFF, SPAN = 32768, 65536
local function key(rx, ry) return (rx + OFF) * SPAN + (ry + OFF) end

--- A §52.4a tuple for a prop at (x, y).
local function tuple(uid, x, y)
    return { uid, 1, -1044093321, x, y, 30.5, 0.0, 0.0, 90.0, 3, 150 }
end

local reqSeq = 0
--- Drives the window callback as client `src`; returns ok, answer (nil, nil when nothing was answered).
local function window(env, src, req)
    reqSeq = reqSeq + 1
    local cbKey = 'test:' .. reqSeq
    local mark = #stubs.sent
    stubs.triggerOn(env, 'core:cb:req:core:maps:window', src, cbKey, req)
    for i = mark + 1, #stubs.sent do
        local s = stubs.sent[i]
        if s.name == 'core:cb:res:core:maps:window' and s.args[1] == cbKey then return s.args[2], s.args[3] end
    end
    return nil, nil
end

--- Every client event `name` sent after position `mark` of stubs.sent.
local function sentSince(mark, name)
    local out = {}
    for i = mark + 1, #stubs.sent do
        local s = stubs.sent[i]
        if s.name == name then out[#out + 1] = s end
    end
    return out
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- key maths ----------------------------------------------------------------------------------------------
do
    local _, R = newServer()
    eq(R.stats().regionSize, 512.0, 'region size from Config.Maps.RegionSize')
    eq(R.keyOf(0.0, 0.0), key(0, 0), 'origin is region (0, 0)')
    eq(R.keyOf(0.0, 0.0), 32768 * 65536 + 32768, 'the §52.3 key formula')
    eq(math.type(R.keyOf(10.5, -3.25)), 'integer', 'keys are integers')
    eq(R.keyOf(511.999, 511.999), key(0, 0), 'just below the border stays in region 0')
    eq(R.keyOf(512.0, 0.0), key(1, 0), 'exactly on the border is the next region')
    eq(R.keyOf(-0.001, 0.0), key(-1, 0), 'a tiny negative x is region -1 (floor, not truncation)')
    eq(R.keyOf(-512.0, -512.0), key(-1, -1), '-512 is still region -1')
    eq(R.keyOf(-512.001, 0.0), key(-2, 0), 'below -512 is region -2')
    eq(R.keyOf(0.0, -1.0), key(0, -1), 'negative y')
    eq(R.keyOf(-3000.0, 7000.0), key(-6, 13), 'map-scale coordinates')
    eq(R.keyOf(1e12, -1e12), key(32767, -32768), 'absurd coordinates clamp into the key range')
    eq(R.keyOf(0 / 0, 0.0), nil, 'NaN has no key')
    eq(R.keyOf('1', 0.0), nil, 'non-numbers have no key')

    local _, R2 = newServer({ RegionSize = 100 })
    eq(R2.keyOf(150.0, -50.0), key(1, -1), 'a configured region size is used')
    local _, R3 = newServer({ RegionSize = 1 })
    eq(R3.stats().regionSize, 64.0, 'region size is clamped to >= 64')
end

-- put / move / remove -------------------------------------------------------------------------------------
do
    local _, R = newServer()
    eq(R.version(0, key(0, 0)), 0, 'an empty region is version 0')
    check(R.put(0, 'm:1', tuple('m:1', 10.0, 10.0)), 'put adds')
    local v1 = R.version(0, key(0, 0))
    check(v1 > 0, 'a filled region has a version > 0')
    eq(R.stats().regions, 1, 'one region')
    eq(R.stats().elements, 1, 'one element')
    check(R.put(0, 'm:2', tuple('m:2', 20.0, 20.0)), 'a second element')
    local v2 = R.version(0, key(0, 0))
    check(v2 > v1, 'every change bumps the version')
    check(R.put(0, 'm:2', tuple('m:2', 30.0, 30.0)), 'a move inside the region')
    check(R.version(0, key(0, 0)) > v2, 'a move bumps the version')
    eq(R.stats().elements, 2, 'a move inside the region keeps the count')

    check(R.put(0, 'm:2', tuple('m:2', -10.0, 600.0)), 'a move across regions')
    eq(R.stats().regions, 2, 'the element now lives in another region')
    eq(R.stats().elements, 2, 'and is counted once')
    check(R.version(0, key(-1, 1)) > 0, 'the new region has a version')
    check(R.remove(0, 'm:1'), 'remove')
    eq(R.version(0, key(0, 0)), 0, 'the emptied old region is dropped (version 0)')
    eq(R.stats().regions, 1, 'one region left')
    eq(R.remove(0, 'm:1'), false, 'a second remove is false')
    check(R.remove(0, 'm:2'), 'the moved element is removed from its NEW region')
    eq(R.version(0, key(-1, 1)), 0, 'and that region is empty')
    eq(R.stats().regions, 0, 'no regions left')
    eq(R.stats().elements, 0, 'no elements left')

    check(R.put(0, 'm:1', tuple('m:1', 10.0, 10.0)), 'the same uid in bucket 0')
    check(R.put(10001, 'm:1', tuple('m:1', 900.0, 10.0)), 'and in an editor bucket')
    eq(R.stats().elements, 2, '(bucket, uid) is the identity')
    check(R.version(0, key(0, 0)) > 0 and R.version(10001, key(1, 0)) > 0, 'both regions filled')
    eq(R.version(10001, key(0, 0)), 0, 'buckets do not share regions')
    check(R.remove(10001, 'm:1'), 'remove in one bucket')
    check(R.version(0, key(0, 0)) > 0, 'leaves the other bucket alone')

    local v = R.version(0, key(0, 0))
    check(R.remove(0, 'm:1') and R.put(0, 'm:1', tuple('m:1', 10.0, 10.0)), 'empty and refill a region')
    check(R.version(0, key(0, 0)) > v, 'a refilled region never repeats an old version (one counter)')

    eq(R.put(-1, 'x', tuple('x', 0.0, 0.0)), false, 'a negative bucket is refused')
    eq(R.put(1.5, 'x', tuple('x', 0.0, 0.0)), false, 'a fractional bucket is refused')
    eq(R.put(0, '', tuple('', 0.0, 0.0)), false, 'an empty uid is refused')
    eq(R.put(0, 'x', tuple('y', 0.0, 0.0)), false, 'tuple[1] must be the uid')
    eq(R.put(0, 'x', tuple('x', 0 / 0, 0.0)), false, 'a NaN x is refused')
    eq(R.put(0, 'x', tuple('x', 0.0, math.huge)), false, 'an infinite y is refused')
    eq(R.put(0, 'x', 'tuple'), false, 'a non-table tuple is refused')
    check(R.put(0, 7, tuple(7, 0.0, 0.0)), 'integer uids are fine')
    eq(R.remove(0, 'unknown'), false, 'removing an unknown uid is false')
    eq(R.remove(99, 'm:1'), false, 'removing from an unknown bucket is false')
end

-- window: validation and the cooldown --------------------------------------------------------------------
do
    local env, R = newServer()
    local c = key(0, 0)
    local tooMany = {}
    for i = 1, 10 do tooMany[key(i, 0)] = 0 end
    local cases = {
        { 'x', 'a non-table request' },
        { {}, 'a request without c' },
        { { c = -1 }, 'a negative centre' },
        { { c = 65536 * 65536 }, 'a centre above the key range' },
        { { c = 1.5 }, 'a fractional centre' },
        { { c = '5' }, 'a string centre' },
        { { c = c, h = 'x' }, 'a non-table h' },
        { { c = c, h = tooMany }, 'more than 9 h entries' },
        { { c = c, h = {}, extra = 1 }, 'an extra request field' },
    }
    for i, case in ipairs(cases) do
        stubs.tick(300)
        local ok = window(env, i, case[1])
        eq(ok, false, case[2] .. ' is refused by the schema')
    end
    local entries = {
        { { ['k'] = 1 }, 'a string h key' },
        { { [c] = 1.5 }, 'a fractional h version' },
        { { [c] = -1 }, 'a negative h version' },
        { { [c] = 'v' }, 'a string h version' },
    }
    for i, case in ipairs(entries) do
        stubs.tick(300)
        local ok, answer = window(env, 100 + i, { c = c, h = case[1] })
        check(ok == true and answer == nil, case[2] .. ' gets no answer')
    end
    eq(R.stats().subscribers, 0, 'no refused request subscribed anyone')
    eq(R.stats().windows, 0, 'and none was counted as served')

    stubs.tick(300)
    local ok, answer = window(env, 50, { c = c })
    check(ok and type(answer) == 'table', 'h is optional')
    local ok2 = window(env, 50, { c = c, h = {} })
    eq(ok2, false, 'a second request inside 250 ms is refused (Callback cooldown)')
    stubs.tick(249)
    eq((window(env, 50, { c = c, h = {} })), false, 'still refused at 249 ms')
    stubs.tick(1)
    eq((window(env, 50, { c = c, h = {} })), true, 'answered again at 250 ms')
    eq((window(env, 51, { c = c })), true, 'the cooldown is per src')
end

-- window: answer, server bucket, packs only for stale regions, pack caching -----------------------------
do
    local env, R = newServer({ LatentBps = 123456 })
    R.put(0, 'a', tuple('a', 10.0, 10.0))          -- region (0, 0)
    R.put(0, 'b', tuple('b', 600.0, 10.0))         -- region (1, 0)
    R.put(0, 'far', tuple('far', 5000.0, 5000.0))  -- outside the block
    R.put(7, 'z', tuple('z', 10.0, 10.0))          -- same region, other bucket
    stubs.tick(0)

    local ok, answer = window(env, 1, { c = key(0, 0), h = {} })
    check(ok, 'answered')
    eq(answer.b, 0, 'the bucket is the routing bucket the server reads')
    eq(countKeys(answer.v), 9, 'versions for the whole 3×3 block')
    eq(answer.v[key(0, 0)], R.version(0, key(0, 0)), 'the version of a filled region')
    eq(answer.v[key(-1, -1)], 0, 'an empty region is answered inline as 0')
    eq(answer.v[key(10, 10)], nil, 'nothing outside the block')
    eq(#latent, 2, 'one latent pack per filled region in the block')
    local pack = latent[1]
    eq(pack.name, 'core:maps:pack', 'the pack event')
    eq(pack.target, 1, 'to the requester only')
    eq(pack.bps, 123456, 'at Config.Maps.LatentBps')
    eq(pack.args[1], 0, 'pack carries the bucket')
    local decoded = stubs.json.decode(pack.args[3])
    eq(decoded.v, R.version(0, pack.args[2]), 'the pack carries its version')
    eq(#decoded.e, 1, 'and its tuples')
    eq(decoded.e[1][1], pack.args[2] == key(0, 0) and 'a' or 'b', 'the tuple of that region')
    eq(decoded.e[1][4], pack.args[2] == key(0, 0) and 10.0 or 600.0, 'tuple x survives the pack')
    eq(R.stats().encodes, 2, 'two packs encoded')
    eq(R.stats().packs, 2, 'and cached')

    stubs.buckets[2] = 0
    stubs.tick(0)
    window(env, 2, { c = key(0, 0) })
    eq(#latent, 4, 'a second client gets both packs too')
    eq(R.stats().encodes, 2, 'from the cache: N clients cost one encode')

    local v00 = R.version(0, key(0, 0))
    local have = { [key(0, 0)] = v00, [key(1, 0)] = R.version(0, key(1, 0)) }
    window(env, 3, { c = key(0, 0), h = have })
    eq(#latent, 4, 'a client that holds every version gets no pack')

    R.put(0, 'a2', tuple('a2', 20.0, 20.0))
    stubs.tick(300)
    window(env, 3, { c = key(0, 0), h = have })
    eq(#latent, 5, 'after a change only the changed region is sent')
    eq(latent[5].args[2], key(0, 0), 'the changed region')
    eq(R.stats().encodes, 3, 'the changed region was encoded once more')
    eq(#stubs.json.decode(latent[5].args[3]).e, 2, 'with both elements')

    stubs.buckets[4] = 7
    local _, other = window(env, 4, { c = key(0, 0), h = {} })
    eq(other.b, 7, 'a client in bucket 7 is answered for bucket 7')
    eq(latent[#latent].args[1], 7, 'and gets bucket 7 content')
    eq(stubs.json.decode(latent[#latent].args[3]).e[1][1], 'z', "only bucket 7's element")

    local before = #latent
    stubs.tick(300)
    window(env, 1, { c = key(0, 0), h = {} })
    eq(#latent, before + 1, 'a repeat with empty h resends only what changed since it was sent')
    stubs.tick(300)
    window(env, 1, { c = key(0, 0), h = {} })
    eq(#latent, before + 1, 'a pack already sent during this subscription is not sent twice')
    eq(R.stats().packsSent, #latent, 'stats count the latent packs')
    eq(R.stats().subscribers, 4, 'four windows')

    local _, edge = window(env, 9, { c = key(-32768, 32767) })
    eq(countKeys(edge.v), 4, 'a corner of the key space has a 2×2 block')
end

-- pushes: coalescing per tick, subscribers only, delta vs stale ------------------------------------------
do
    local env, R = newServer()
    R.put(0, 'seed', tuple('seed', 10.0, 10.0))
    stubs.tick(0)
    window(env, 1, { c = key(0, 0) })      -- holds (0, 0) … (1, 1)
    window(env, 2, { c = key(5, 5) })      -- far away
    local mark = #stubs.sent

    local fromV = R.version(0, key(0, 0))
    for i = 1, 5 do R.put(0, 'p' .. i, tuple('p' .. i, 10.0 + i, 10.0)) end
    R.put(0, 'q', tuple('q', 700.0, 10.0))   -- region (1, 0)
    eq(#sentSince(mark, 'core:maps:delta'), 0, 'nothing is sent before the tick ends')
    stubs.tick(0)
    local deltas = sentSince(mark, 'core:maps:delta')
    eq(#deltas, 2, 'one delta per changed region, however many ops')
    local d00 = deltas[1].args[2] == key(0, 0) and deltas[1] or deltas[2]
    eq(d00.target, 1, 'only the subscriber of that region gets it')
    eq(d00.args[1], 0, 'delta carries the bucket')
    eq(d00.args[3], fromV, 'fromV = the version before the tick')
    eq(d00.args[4], R.version(0, key(0, 0)), 'toV = the version after it')
    local ops = stubs.json.decode(d00.args[5])
    eq(#ops, 5, 'the five ops, coalesced')
    eq(ops[1].o, 'put', 'put op')
    eq(ops[1].t[1], 'p1', 'with its tuple, in order')
    eq(ops[5].t[1], 'p5', 'last op last')
    eq(#sentSince(mark, 'core:maps:stale'), 0, 'no stale for small changes')
    eq(R.stats().deltas, 2, 'stats count deltas')
    eq(R.stats().packets, 2, 'and packets')

    mark = #stubs.sent
    R.put(0, 'q', tuple('q', 10.0, 20.0))    -- (1, 0) -> (0, 0)
    stubs.tick(0)
    deltas = sentSince(mark, 'core:maps:delta')
    eq(#deltas, 2, 'a move across regions touches both')
    for _, d in ipairs(deltas) do
        local o = stubs.json.decode(d.args[5])[1]
        if d.args[2] == key(1, 0) then
            check(o.o == 'del' and o.u == 'q', 'the old region gets a del')
            eq(d.args[4], 0, 'and is empty now (toV 0)')
        else
            check(o.o == 'put' and o.t[1] == 'q', 'the new region gets a put')
        end
    end

    mark = #stubs.sent
    local before = R.version(0, key(0, 0))
    for i = 1, 33 do R.put(0, 'bulk' .. i, tuple('bulk' .. i, 100.0, 100.0 + i)) end
    stubs.tick(0)
    eq(#sentSince(mark, 'core:maps:delta'), 0, 'more than PushOpsMax ops send no delta')
    local stale = sentSince(mark, 'core:maps:stale')
    eq(#stale, 1, 'but one stale notice')
    eq(stale[1].args[2], key(0, 0), 'for that region')
    eq(stale[1].args[3], R.version(0, key(0, 0)), 'with toV')
    check(R.version(0, key(0, 0)) > before, 'versions still bump')

    mark = #stubs.sent
    for i = 1, 32 do R.remove(0, 'bulk' .. i) end
    stubs.tick(0)
    eq(#sentSince(mark, 'core:maps:delta'), 1, 'exactly PushOpsMax ops still fit a delta')

    mark = #stubs.sent
    local v55 = R.version(0, key(5, 5))
    R.put(0, 'lonely', tuple('lonely', 5000.0, 5000.0))  -- region (9, 9): nobody holds it
    stubs.tick(0)
    eq(#stubs.sent - mark, 0, 'a region without subscribers sends nothing')
    check(R.version(0, key(9, 9)) > v55, 'but its version bumps')

    mark = #stubs.sent
    R.put(0, 'tmp', tuple('tmp', -300.0, -300.0))       -- (-1, -1): empty, in src 1's block
    R.remove(0, 'tmp')
    stubs.tick(0)
    eq(#stubs.sent - mark, 0, 'put + remove of an empty region in one tick is no change at all')

    mark = #stubs.sent
    R.put(7, 'other', tuple('other', 10.0, 10.0))
    stubs.tick(0)
    eq(#stubs.sent - mark, 0, 'a change in another bucket never reaches bucket-0 subscribers')

end

do
    local env, R = newServer({ PushOpsMax = 0 })
    window(env, 1, { c = key(0, 0) })
    local mark = #stubs.sent
    R.put(0, 'a', tuple('a', 10.0, 10.0))
    stubs.tick(0)
    eq(#sentSince(mark, 'core:maps:delta'), 0, 'PushOpsMax = 0: no deltas')
    eq(#sentSince(mark, 'core:maps:stale'), 1, 'every change is a stale notice')
    env.Config.Maps.PushOpsMax = 4
    mark = #stubs.sent
    R.put(0, 'b', tuple('b', 20.0, 10.0))
    stubs.tick(0)
    eq(#sentSince(mark, 'core:maps:delta'), 1, 'PushOpsMax is read live')
end

-- subscriptions: re-centre, bucket change, flush before a window answer ----------------------------------
do
    local env, R = newServer()
    window(env, 1, { c = key(0, 0) })
    eq(R.stats().subscribers, 1, 'one window')

    stubs.tick(300)
    window(env, 1, { c = key(2, 0) })         -- block x 1..3: (0, *) left the window, (1, *) stayed
    local mark = #stubs.sent
    R.put(0, 'left', tuple('left', 10.0, 10.0))     -- (0, 0)
    R.put(0, 'kept', tuple('kept', 600.0, 10.0))    -- (1, 0)
    R.put(0, 'new', tuple('new', 1600.0, 10.0))     -- (3, 0)
    stubs.tick(0)
    local seen = {}
    for _, d in ipairs(sentSince(mark, 'core:maps:delta')) do seen[d.args[2]] = d.target end
    eq(seen[key(0, 0)], nil, 'a region that left the window is no longer pushed')
    eq(seen[key(1, 0)], 1, 'a region that stayed still is')
    eq(seen[key(3, 0)], 1, 'a region that entered is')
    eq(R.stats().subscribers, 1, 're-centring keeps one window')

    stubs.tick(300)
    stubs.buckets[1] = 10001
    local _, answer = window(env, 1, { c = key(2, 0) })
    eq(answer.b, 10001, 'after a bucket change the window follows the server-side bucket')
    mark = #stubs.sent
    R.put(0, 'kept', tuple('kept', 620.0, 10.0))
    R.put(10001, 'ed', tuple('ed', 600.0, 10.0))
    stubs.tick(0)
    local d = sentSince(mark, 'core:maps:delta')
    eq(#d, 1, 'the old bucket block was dropped')
    eq(d[1].args[1], 10001, 'only the new bucket is pushed')

    -- a window answer in the same tick as a change: the delta goes to the old subscribers first, the new
    -- subscriber gets the fresh pack and never the delta
    window(env, 2, { c = key(0, 0) })
    stubs.tick(0)
    mark = #stubs.sent
    local latentMark = #latent
    R.put(0, 'same', tuple('same', 30.0, 30.0))
    window(env, 3, { c = key(0, 0) })
    local toV = R.version(0, key(0, 0))
    d = sentSince(mark, 'core:maps:delta')
    eq(#d, 1, 'the pending delta was flushed before the answer')
    eq(d[1].target, 2, 'to the existing subscriber')
    local fresh
    for i = latentMark + 1, #latent do
        if latent[i].args[2] == key(0, 0) then fresh = latent[i] end
    end
    check(fresh ~= nil, 'the changed region was packed for the new subscriber')
    eq(fresh and fresh.target, 3, '(the pack went to it)')
    eq(fresh and stubs.json.decode(fresh.args[3]).v, toV, 'the new subscriber got the current pack')
    stubs.tick(0)
    eq(#sentSince(mark, 'core:maps:delta'), 1, 'the scheduled flush has nothing left to send')
end

-- clearBucket -------------------------------------------------------------------------------------------
do
    local env, R = newServer()
    R.put(0, 'a', tuple('a', 10.0, 10.0))
    R.put(0, 'b', tuple('b', 600.0, 10.0))
    R.put(0, 'c', tuple('c', 5000.0, 5000.0))       -- nobody holds it
    R.put(5, 'x', tuple('x', 10.0, 10.0))
    stubs.tick(0)
    window(env, 1, { c = key(0, 0) })
    local mark = #stubs.sent
    eq(R.clearBucket(0), 3, 'clearBucket returns the removed count')
    stubs.tick(0)
    local stale = sentSince(mark, 'core:maps:stale')
    eq(#stale, 2, 'a stale notice for every subscribed region that had content')
    eq(stale[1].args[3], 0, 'toV 0 = empty')
    eq(#sentSince(mark, 'core:maps:delta'), 0, 'no deltas for a clear')
    eq(R.version(0, key(0, 0)), 0, 'the regions are empty')
    eq(R.stats().elements, 1, "only the other bucket's element is left")
    eq(R.stats().regions, 1, 'and its region')
    eq(R.remove(0, 'a'), false, 'cleared uids are forgotten')
    check(R.put(0, 'a', tuple('a', 10.0, 10.0)), 'the bucket can be filled again')
    eq(R.clearBucket(99), 0, 'clearing an empty bucket is 0')
    eq(R.clearBucket('x'), 0, 'clearing a non-bucket is 0')

    mark = #stubs.sent
    R.clearBucket(0)
    R.put(0, 'a', tuple('a', 10.0, 10.0))
    stubs.tick(0)
    stale = sentSince(mark, 'core:maps:stale')
    eq(#stale, 1, 'a clear and a refill in one tick coalesce into one stale')
    eq(stale[1].args[3], R.version(0, key(0, 0)), 'carrying the final version')
end

-- drop cleanup and bounded memory ------------------------------------------------------------------------
do
    local env, R = newServer()
    stubs.connectPlayer(env, 1, { joining = false })
    stubs.connectPlayer(env, 2, { joining = false })
    window(env, 1, { c = key(0, 0) })
    window(env, 2, { c = key(0, 0) })
    eq(R.stats().subscribers, 2, 'two windows')
    stubs.dropPlayer(env, 1)
    eq(R.stats().subscribers, 1, 'playerDropped removes the window')
    local mark = #stubs.sent
    R.put(0, 'a', tuple('a', 10.0, 10.0))
    stubs.tick(0)
    local d = sentSince(mark, 'core:maps:delta')
    eq(#d, 1, 'the remaining subscriber is pushed')
    eq(d[1].target, 2, 'and only it')
    eq(R.unsubscribe(1), false, 'a dropped src has no window left')
    check(R.unsubscribe(2), 'unsubscribe removes a window')
    mark = #stubs.sent
    R.remove(0, 'a')
    stubs.tick(0)
    eq(#stubs.sent - mark, 0, 'nobody is pushed once every window is gone')
    local s = R.stats()
    eq(s.regions + s.elements + s.subscribers + s.packs, 0, 'every table is released when empty')
    check(s.version > 0 and s.windows == 2, 'the totals keep counting')
end

-- the per-subscription pack memory is forgotten when a region leaves the window or the bucket changes -----
do
    local env, R = newServer()
    R.put(0, 'a', tuple('a', 10.0, 10.0))
    R.put(7, 'b', tuple('b', 10.0, 10.0))
    window(env, 1, { c = key(0, 0), h = {} })
    eq(#latent, 1, 'first visit: one pack')
    stubs.tick(300)
    window(env, 1, { c = key(5, 5), h = {} })
    stubs.tick(300)
    window(env, 1, { c = key(0, 0), h = {} })
    eq(#latent, 2, 'a region that left and re-entered the window is sent again')
    stubs.tick(300)
    stubs.buckets[1] = 7
    window(env, 1, { c = key(0, 0), h = {} })
    eq(#latent, 3, 'a bucket change sends the new bucket')
    eq(latent[3].args[1], 7, '(bucket 7)')
    stubs.tick(300)
    stubs.buckets[1] = 0
    window(env, 1, { c = key(0, 0), h = {} })
    eq(#latent, 4, 'and coming back sends bucket 0 again')
end

-- tuple shape and encode failures ------------------------------------------------------------------------
do
    local env, R = newServer()
    local bad = tuple('r', 10.0, 10.0)
    bad[9] = 0 / 0
    eq(R.put(0, 'r', bad), false, 'a NaN rotation is refused')
    local short = tuple('s', 10.0, 10.0)
    short[11] = nil
    eq(R.put(0, 's', short), false, 'a tuple without lod is refused')
    local marker = tuple('m', 10.0, 10.0)
    marker[12] = { type = 1, r = 255, g = 0, b = 0, a = 200 }
    check(R.put(0, 'm', marker), 'extra as a table is fine')
    local wrong = tuple('w', 10.0, 10.0)
    wrong[12] = 'extra'
    eq(R.put(0, 'w', wrong), false, 'extra must be a table')
    stubs.tick(0)

    window(env, 1, { c = key(0, 0) })
    eq(#latent, 1, 'the marker region is sent')
    eq(stubs.json.decode(latent[1].args[3]).e[1][12].r, 255, 'extra survives the pack')

    env.json = { encode = function() error('cannot encode', 0) end, decode = stubs.json.decode }
    local mark = #stubs.sent
    R.put(0, 'm2', tuple('m2', 20.0, 20.0))
    stubs.tick(0)
    eq(#sentSince(mark, 'core:maps:delta'), 0, 'ops that do not encode send no delta')
    eq(#sentSince(mark, 'core:maps:stale'), 1, 'but a stale notice')
    local ok, answer = window(env, 2, { c = key(0, 0) })
    check(ok and answer.v[key(0, 0)] > 0, 'a pack that does not encode still answers the versions')
    eq(#latent, 1, 'and sends no pack')
    eq(R.stats().packs, 0, 'nothing is cached')
    env.json = stubs.json
    stubs.tick(300)
    window(env, 2, { c = key(0, 0) })
    eq(#latent, 2, 'once encoding works again the pack goes out')
end

-- per-src pack budget: withheld keys, refill over time, capacity, oversize packs --------------------------
do
    local env, R = newServer()
    -- three regions whose packs have the same size (same uid length, same coordinate text length)
    R.put(0, 'a', tuple('a', 110.0, 110.0))   -- (0, 0), the centre
    R.put(0, 'b', tuple('b', 610.0, 110.0))   -- (1, 0)
    R.put(0, 'c', tuple('c', 110.0, 610.0))   -- (0, 1)
    stubs.tick(0)
    local ok, answer = window(env, 9, { c = key(0, 0) })
    check(ok, 'answered')
    eq(#latent, 3, 'the default 2 MB budget serves a normal window completely')
    eq(type(answer.w), 'table', 'the answer always carries w')
    eq(next(answer.w), nil, 'with nothing withheld')
    eq(latent[1].args[2], key(0, 0), 'the centre region is served first')
    local size = #latent[1].args[3]
    check(#latent[2].args[3] == size and #latent[3].args[3] == size, 'the three packs are the same size')

    env.Config.Maps.PackBudgetBytes = math.floor(2.5 * size)
    env.Config.Maps.PackBudgetWindowMs = 10000
    local mark = #latent
    ok, answer = window(env, 1, { c = key(0, 0) })
    eq(#latent - mark, 2, 'a 2.5-pack budget sends two packs')
    eq(latent[mark + 1].args[2], key(0, 0), 'the centre first')
    eq(countKeys(answer.w), 1, 'and withholds the third')
    local held = next(answer.w)
    check(held ~= key(0, 0) and answer.w[held] == true, 'w = { [key] = true } for a neighbour')
    check(answer.v[held] > 0, 'a withheld key still reports its version')
    eq(R.stats().withheld, 1, 'stats count withheld packs')

    local have = {}
    for k, v in pairs(answer.v) do
        if not answer.w[k] and v > 0 then have[k] = v end
    end
    stubs.tick(1000)                                  -- +0.25 pack: 0.75 of a pack in the bucket
    mark = #latent
    ok, answer = window(env, 1, { c = key(0, 0), h = have })
    eq(#latent - mark, 0, 'not refilled enough after 1 s: nothing sent')
    eq(answer.w[held], true, 'the key is still withheld')
    stubs.tick(2000)                                  -- +0.5 pack: 1.25 packs
    ok, answer = window(env, 1, { c = key(0, 0), h = have })
    eq(#latent - mark, 1, 'the budget refills over time: the withheld key is sent on a later request')
    eq(latent[#latent].args[2], held, 'exactly the withheld region')
    eq(next(answer.w), nil, 'nothing withheld any more')

    -- capacity: a long idle never banks more than PackBudgetBytes
    R.put(0, 'd', tuple('d', 5230.0, 10.0))           -- (10, 0)
    R.put(0, 'e', tuple('e', 5740.0, 10.0))           -- (11, 0)
    R.put(0, 'f', tuple('f', 4720.0, 10.0))           -- (9, 0)
    stubs.tick(60000)
    mark = #latent
    ok, answer = window(env, 1, { c = key(10, 0) })
    eq(#latent - mark, 2, 'after 60 s idle the budget is still capped at 2.5 packs')
    eq(countKeys(answer.w), 1, 'the third pack is withheld')

    -- a pack larger than the whole budget goes out when the budget is full and leaves it in debt
    env.Config.Maps.PackBudgetBytes = math.floor(size / 2)
    mark = #latent
    ok, answer = window(env, 2, { c = key(0, 0) })
    eq(#latent - mark, 1, 'an oversize pack is sent from a full budget')
    eq(countKeys(answer.w), 2, 'the rest waits')
    stubs.tick(10000)                                 -- one window: from -0.5 pack back to 0
    mark = #latent
    window(env, 2, { c = key(0, 0), h = { [key(0, 0)] = R.version(0, key(0, 0)) } })
    eq(#latent - mark, 0, 'the debt is repaid before anything else is sent')
    stubs.tick(15000)                                 -- full again (capped at the capacity)
    window(env, 2, { c = key(0, 0), h = { [key(0, 0)] = R.version(0, key(0, 0)) } })
    eq(#latent - mark, 1, 'then the next oversize pack goes out')

    env.Config.Maps.PackBudgetBytes = 'x'
    env.Config.Maps.PackBudgetWindowMs = -5
    stubs.tick(300)
    ok, answer = window(env, 3, { c = key(0, 0) })
    check(ok and next(answer.w) == nil, 'invalid budget config falls back to the 2 MB / 10 s default')
end

-- M6: FLAG_DATA / FLAG_EDITOR tuples reach editors only ---------------------------------------------------
local function flagged(uid, x, y, flags)
    local t = tuple(uid, x, y)
    t[10] = flags
    return t
end

local function packUids(pack)
    local out = {}
    for _, t in ipairs(stubs.json.decode(pack).e) do out[t[1]] = true end
    return out
end

--- The latent pack sent to `src` for `k` after position `mark` of `latent`, or nil.
local function packFor(mark, src, k)
    for i = mark + 1, #latent do
        if latent[i].target == src and latent[i].args[2] == k then return latent[i] end
    end
end

do
    local env, R = newServer()
    local modes = {}
    env.Core.Admin = { getModes = function(src) return modes[src] or {} end }
    env.Core.MapsRuntime = { state = { editorBuckets = { draftA = 10001 } } }

    R.put(0, 'p', tuple('p', 110.0, 110.0))                 -- public (flags 3)
    R.put(0, 'd', flagged('d', 120.0, 110.0, 16))           -- data (point / zone)
    R.put(0, 'x', flagged('x', 130.0, 110.0, 8 | 16))       -- placeholder
    R.put(0, 'only', flagged('only', 610.0, 110.0, 16))     -- (1, 0): nothing public
    stubs.tick(0)
    eq(R.stats().hidden, 3, 'three hidden elements')
    local full, pub = R.version(0, key(0, 0))
    check(full > 0 and pub > 0 and full ~= pub, 'a mixed region has a public version of its own')
    eq(select(2, R.version(0, key(1, 0))), 0, 'a region with nothing public is 0 for the public')

    local mark = #latent
    local _, answer = window(env, 1, { c = key(0, 0) })
    eq(answer.v[key(0, 0)], pub, 'a player gets the public version')
    eq(answer.v[key(1, 0)], 0, 'and sees a data-only region as empty')
    eq(packFor(mark, 1, key(1, 0)), nil, 'no pack for it')
    local uids = packUids(packFor(mark, 1, key(0, 0)).args[3])
    check(uids.p and not uids.d and not uids.x, 'the public pack holds only the public tuple')
    eq(stubs.json.decode(packFor(mark, 1, key(0, 0)).args[3]).v, pub, 'at the public version')

    modes[2] = { editor = true }
    mark = #latent
    _, answer = window(env, 2, { c = key(0, 0) })
    eq(answer.v[key(0, 0)], full, 'Admin mode editor gets the full version')
    uids = packUids(packFor(mark, 2, key(0, 0)).args[3])
    check(uids.p and uids.d and uids.x, 'and the full pack')
    check(packFor(mark, 2, key(1, 0)) ~= nil, 'and the data-only region')

    stubs.buckets[3] = 10001
    R.put(10001, 'dd', flagged('dd', 110.0, 110.0, 16))
    stubs.tick(0)
    mark = #latent
    _, answer = window(env, 3, { c = key(0, 0) })
    check(answer.v[key(0, 0)] > 0 and packFor(mark, 3, key(0, 0)) ~= nil, 'an open draft bucket is an editor bucket')
    stubs.buckets[4] = 10002
    R.put(10002, 'dd', flagged('dd', 110.0, 110.0, 16))
    stubs.tick(0)
    _, answer = window(env, 4, { c = key(0, 0) })
    eq(answer.v[key(0, 0)], 0, 'another bucket is not')

    -- pushes per audience
    local sentMark = #stubs.sent
    R.put(0, 'd', flagged('d', 121.0, 110.0, 16))            -- data only
    stubs.tick(0)
    local d = sentSince(sentMark, 'core:maps:delta')
    eq(#d, 1, 'a data-only change is pushed once')
    eq(d[1].target, 2, 'to the editor only')

    sentMark = #stubs.sent
    local _, pubBefore = R.version(0, key(0, 0))
    R.put(0, 'p2', tuple('p2', 140.0, 110.0))                -- public
    R.put(0, 'd2', flagged('d2', 150.0, 110.0, 16))          -- data, same tick
    stubs.tick(0)
    d = sentSince(sentMark, 'core:maps:delta')
    eq(#d, 2, 'a mixed tick is split per audience')
    for _, delta in ipairs(d) do
        local ops = stubs.json.decode(delta.args[5])
        if delta.target == 1 then
            eq(#ops, 1, 'the public delta holds only the public op')
            eq(ops[1].t[1], 'p2', '(the public put)')
            eq(delta.args[3], pubBefore, 'public fromV = the version the player holds (in sync)')
            eq(delta.args[4], select(2, R.version(0, key(0, 0))), 'public toV = the new public version')
        else
            eq(#ops, 2, 'the editor delta holds both ops')
            eq(delta.args[4], (R.version(0, key(0, 0))), 'editor toV = the full version')
        end
    end

    sentMark = #stubs.sent
    R.put(0, 'p', flagged('p', 110.0, 110.0, 16))            -- public -> hidden
    stubs.tick(0)
    for _, delta in ipairs(sentSince(sentMark, 'core:maps:delta')) do
        local op = stubs.json.decode(delta.args[5])[1]
        if delta.target == 1 then
            check(op.o == 'del' and op.u == 'p', 'an element that becomes hidden is a del for the public')
        else
            check(op.o == 'put' and op.t[1] == 'p', 'and a put for editors')
        end
    end
    sentMark = #stubs.sent
    R.put(0, 'p', tuple('p', 110.0, 110.0))                  -- hidden -> public
    stubs.tick(0)
    local toPublic
    for _, delta in ipairs(sentSince(sentMark, 'core:maps:delta')) do
        if delta.target == 1 then toPublic = stubs.json.decode(delta.args[5])[1] end
    end
    check(toPublic and toPublic.o == 'put' and toPublic.t[1] == 'p', 'an element that becomes public is a put')
    sentMark = #stubs.sent
    R.remove(0, 'd2')
    R.put(0, 'new', flagged('new', 5000.0, 5000.0, 16))
    stubs.tick(0)
    d = sentSince(sentMark, 'core:maps:delta')
    check(#d == 1 and d[1].target == 2, 'removing a hidden element reaches editors only')

    -- audience changes take effect on the next window request
    stubs.tick(300)
    local pubHave = {}
    for k in pairs(answer.v) do pubHave[k] = select(2, R.version(0, k)) end
    modes[1] = { editor = true }
    mark = #latent
    _, answer = window(env, 1, { c = key(0, 0), h = pubHave })
    eq(answer.v[key(0, 0)], (R.version(0, key(0, 0))), 'entering editor mode: the full version on the next request')
    check(packFor(mark, 1, key(0, 0)) ~= nil and packFor(mark, 1, key(1, 0)) ~= nil, 'with the full packs')
    stubs.tick(300)
    modes[1] = nil
    local fullHave = { [key(0, 0)] = (R.version(0, key(0, 0))), [key(1, 0)] = (R.version(0, key(1, 0))) }
    mark = #latent
    _, answer = window(env, 1, { c = key(0, 0), h = fullHave })
    eq(answer.v[key(1, 0)], 0, 'leaving it: the data-only region is empty again')
    uids = packUids(packFor(mark, 1, key(0, 0)).args[3])
    check(uids.p and not uids.d, 'and the public pack replaces the full one')

    sentMark = #stubs.sent
    R.clearBucket(0)
    stubs.tick(0)
    local stale = sentSince(sentMark, 'core:maps:stale')
    local toPlayer, toEditor = 0, 0
    for _, st in ipairs(stale) do
        if st.target == 1 then toPlayer = toPlayer + 1 else toEditor = toEditor + 1 end
    end
    eq(toPlayer, 1, 'clearBucket: the player hears only about the region with public content')
    eq(toEditor, 2, 'the editor about both')
    eq(R.stats().hidden, 2, 'only the other buckets keep hidden elements')
end

do
    local env, R = newServer()
    env.Core.Admin = { getModes = function(src) return src == 2 and { editor = true } or {} end }
    R.put(0, 'p', tuple('p', 110.0, 110.0))
    stubs.tick(0)
    local full, pub = R.version(0, key(0, 0))
    eq(full, pub, 'without hidden tuples both audiences share one version')
    window(env, 1, { c = key(0, 0) })
    window(env, 2, { c = key(0, 0) })
    eq(R.stats().encodes, 1, 'and one encode serves both')
    eq(latent[1].args[3], latent[2].args[3], 'the very same pack')
    R.put(0, 'bad', flagged('bad', 110.0, 110.0, 1.5))
    eq(R.stats().elements, 1, 'fractional flags are refused')
end

-- R2-8: an editor that loses the audience is downgraded server-side at once --------------------------------
do
    local env, R = newServer()
    local modes = { [2] = { editor = true }, [5] = { editor = true } }
    env.Core.Admin = { getModes = function(src) return modes[src] or {} end }
    env.Core.MapsRuntime = { state = { editorBuckets = { draftA = 10001 } } }
    R.put(0, 'p', tuple('p', 110.0, 110.0))
    R.put(0, 'd', flagged('d', 120.0, 110.0, 16))           -- (0, 0) mixed
    R.put(0, 'only', flagged('only', 610.0, 110.0, 16))     -- (1, 0) data only
    R.put(0, 'pub', tuple('pub', 110.0, 610.0))             -- (0, 1) public only
    stubs.tick(0)
    window(env, 2, { c = key(0, 0) })
    window(env, 5, { c = key(0, 0) })

    eq(R.reaudience(2), false, 'reaudience keeps a src that is still an editor')
    eq(R.reaudience(77), false, 'and ignores a src without a window')

    -- the staffModeChanged hook: the payload decides at once
    local mark = #stubs.sent
    stubs.triggerOn(env, 'core:hook:staffModeChanged', 0, 2, { editor = true, noclip = true })
    eq(#stubs.sent - mark, 0, 'a mode change that keeps editor changes nothing')
    modes[2] = { noclip = true }
    stubs.triggerOn(env, 'core:hook:staffModeChanged', 0, 2, { noclip = true })
    local stale = sentSince(mark, 'core:maps:stale')
    local staleKeys = {}
    for _, st in ipairs(stale) do
        eq(st.target, 2, 'the stale notices go to the downgraded src')
        staleKeys[st.args[2]] = st.args[3]
    end
    eq(staleKeys[key(0, 0)], select(2, R.version(0, key(0, 0))), 'mixed region: stale to its public version')
    eq(staleKeys[key(1, 0)], 0, 'data-only region: stale to 0 (drop the hidden tuples)')
    eq(staleKeys[key(0, 1)], nil, 'a region without hidden tuples needs no notice')
    eq(R.reaudience(2), false, 'already public: nothing more to do')

    mark = #stubs.sent
    R.put(0, 'd', flagged('d', 125.0, 110.0, 16))            -- data only
    stubs.tick(0)
    local d = sentSince(mark, 'core:maps:delta')
    check(#d == 1 and d[1].target == 5, 'the downgraded src gets no editor delta any more')
    mark = #stubs.sent
    R.put(0, 'p', tuple('p', 115.0, 110.0))                  -- public
    stubs.tick(0)
    for _, delta in ipairs(sentSince(mark, 'core:maps:delta')) do
        if delta.target == 2 then
            local ops = stubs.json.decode(delta.args[5])
            check(#ops == 1 and ops[1].t[1] == 'p', 'but the public delta')
        end
    end

    -- an array payload and permsChanged (read through getModes) work too
    modes[5] = nil
    mark = #stubs.sent
    stubs.triggerOn(env, 'core:hook:permsChanged', 0, 5, 'group')
    check(#sentSince(mark, 'core:maps:stale') >= 1, 'permsChanged downgrades a src that lost the mode')
    stubs.tick(300)
    modes[2] = { editor = true }
    window(env, 2, { c = key(0, 0) })                        -- the client's request upgrades again
    mark = #stubs.sent
    stubs.triggerOn(env, 'core:hook:staffModeChanged', 0, 2, { 'noclip' })
    check(#sentSince(mark, 'core:maps:stale') >= 1, 'an array payload without editor downgrades')

    -- a gain is left to the client's next request
    mark = #stubs.sent
    modes[5] = { editor = true }
    stubs.triggerOn(env, 'core:hook:staffModeChanged', 0, 5, { editor = true })
    eq(#stubs.sent - mark, 0, 'gaining the mode sends nothing server-side')
end

do
    local env, R = newServer()
    local modes = { [2] = { editor = true } }
    env.Core.Admin = { getModes = function(src) return modes[src] or {} end }
    env.Core.MapsRuntime = { state = { editorBuckets = { draftA = 10001 } } }
    R.put(0, 'd', flagged('d', 120.0, 110.0, 16))
    stubs.buckets[3] = 10001
    R.put(10001, 'dd', flagged('dd', 110.0, 110.0, 16))
    stubs.tick(0)
    window(env, 2, { c = key(0, 0) })
    window(env, 3, { c = key(0, 0) })

    -- no hook at all: the flush re-checks every editor target before a full delta
    modes[2] = nil
    local mark = #stubs.sent
    R.put(0, 'd', flagged('d', 121.0, 110.0, 16))
    stubs.tick(0)
    eq(#sentSince(mark, 'core:maps:delta'), 0, 'a silent mode loss: no hidden delta reaches the src')
    local stale = sentSince(mark, 'core:maps:stale')
    check(#stale == 1 and stale[1].target == 2 and stale[1].args[3] == 0, 'it is downgraded with a stale instead')

    -- a server-side bucket change out of the draft bucket
    stubs.buckets[3] = 0
    mark = #stubs.sent
    R.put(10001, 'dd', flagged('dd', 111.0, 110.0, 16))
    stubs.tick(0)
    eq(#sentSince(mark, 'core:maps:delta'), 0, 'a src moved out of the draft bucket gets no hidden delta')
    stale = sentSince(mark, 'core:maps:stale')
    check(#stale == 1 and stale[1].target == 3 and stale[1].args[1] == 10001, 'but a stale for the draft region')
    eq(R.reaudience(3), false, 'and is public from then on')
end

print(('maps regions: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
