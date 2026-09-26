--[[
    core/tests/buckets_tests.lua — offline suite for Core.Buckets (DESIGN §50).

        lua5.4 tests/buckets_tests.lua    (from the resource directory, or from tests/)

    Allocation from Config.Buckets.Range (round robin, exhaustion), the population and lockdown natives,
    owner-only release with evacuation to bucket 0, info/list, and the owner-stop sweep. The two bucket
    natives stubs.lua does not have are recorded here. Exit code is 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/buckets_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local passed, failed = 0, 0

local function eq(actual, expected, label)
    if actual == expected then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    print(('FAIL  [buckets] %s\n        expected %s, got %s'):format(label, tostring(expected), tostring(actual)))
    return false
end

local function check(cond, label)
    return eq(cond and true or false, true, label)
end

local population, lockdown = {}, {}   -- bucket -> the last value the natives were given

local function newServer()
    stubs.newWorld()
    stubs.clear()
    stubs.resetServer()
    population, lockdown = {}, {}
    local env = stubs.newEnv('server', 'core')
    env.SetRoutingBucketPopulationEnabled = function(bucket, mode) population[bucket] = mode end
    env.SetRoutingBucketEntityLockdownMode = function(bucket, mode) lockdown[bucket] = mode end
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    stubs.loadFile(env, 'server/api.lua')
    stubs.loadFile(env, 'server/buckets.lua')
    return env, env.Core
end

-- allocate, natives, info/list ---------------------------------------------------------------------------
do
    local env, Core = newServer()
    local B, Registry = Core.Buckets, Core.Registry
    local lo, hi = env.Config.Buckets.Range[1], env.Config.Buckets.Range[2]

    local first = B.allocate({ label = 'studio' })
    eq(first, lo, 'the first bucket is the start of Config.Buckets.Range')
    eq(population[first], false, 'population defaults to off')
    eq(lockdown[first], 'strict', "lockdown defaults to 'strict'")
    local info = B.info(first)
    eq(info.owner, 'core', 'the owner is the calling resource')
    eq(info.label, 'studio', 'label')

    local second = select(2, Registry.withCaller('plugin_a', B.allocate, { population = true, lockdown = 'relaxed' }))
    eq(second, lo + 1, 'the next id follows')
    eq(population[second], true, 'population on')
    eq(lockdown[second], 'relaxed', 'relaxed lockdown')
    eq(B.info(second).owner, 'plugin_a', 'owner tracked per caller')
    eq(Registry.getOwned('plugin_a').bucket[second], true, "tracked in the Registry as kind 'bucket'")

    eq(B.allocate({ lockdown = 'open' }), nil, 'an unknown lockdown mode is refused')
    eq(B.allocate({ population = 'yes' }), nil, 'a non-boolean population is refused')
    eq(B.allocate({ label = 5 }), nil, 'a non-string label is refused')
    eq(B.allocate('x'), nil, 'non-table opts are refused')
    eq(B.info(first - 1), nil, 'info of an unallocated bucket is nil')
    eq(B.info('x'), nil, 'info of a non-number is nil')

    local list = B.list()
    eq(#list, 2, 'list has both')
    eq(list[1].bucket, first, 'list is sorted')
    eq(list[2].owner, 'plugin_a', 'list carries the owner')
    check(lo >= 10000 and hi >= lo, 'the configured range is sane')
end

-- release: owner only, evacuation, round robin -----------------------------------------------------------
do
    local env, Core = newServer()
    local B, Registry = Core.Buckets, Core.Registry
    local lo = env.Config.Buckets.Range[1]
    local mine = select(2, Registry.withCaller('plugin_a', B.allocate, {}))
    stubs.connectPlayer(env, 1, { joining = false })
    stubs.connectPlayer(env, 2, { joining = false })
    stubs.connectPlayer(env, 3, { joining = false })
    env.SetPlayerRoutingBucket('1', mine)
    env.SetPlayerRoutingBucket('2', mine)
    env.SetPlayerRoutingBucket('3', 7)

    eq(select(2, Registry.withCaller('plugin_b', B.release, mine)), false, 'another resource may not release it')
    eq(B.info(mine) ~= nil, true, 'still allocated')
    eq(select(2, Registry.withCaller('plugin_a', B.release, mine)), true, 'the owner releases it')
    eq(env.GetPlayerRoutingBucket('1'), 0, 'a player inside went back to bucket 0')
    eq(env.GetPlayerRoutingBucket('2'), 0, 'every player inside did')
    eq(env.GetPlayerRoutingBucket('3'), 7, 'players elsewhere are untouched')
    eq(B.info(mine), nil, 'released')
    eq(Registry.getOwned('plugin_a'), nil, 'untracked')
    eq(B.release(mine), false, 'a second release is false')

    local next1 = B.allocate({})
    eq(next1, lo + 1, 'a just-released id is not reused at once (round robin)')
    eq(B.release(next1), true, 'core may release its own')
    local other = select(2, Registry.withCaller('plugin_c', B.allocate, {}))
    eq(B.release(other), true, 'core may release any bucket')
end

-- owner stop sweep and exhaustion ----------------------------------------------------------------------------
do
    local env, Core = newServer()
    local B, Registry = Core.Buckets, Core.Registry
    env.Config.Buckets.Range = { 20000, 20002 }
    local a = select(2, Registry.withCaller('plugin_a', B.allocate, {}))
    local b = select(2, Registry.withCaller('plugin_a', B.allocate, {}))
    local c = B.allocate({})
    eq(a, 20000, 'a small range starts at its low end')
    eq(c, 20002, 'and fills up')
    eq(B.allocate({}), nil, 'an exhausted range allocates nothing')
    check(stubs.printed[#stubs.printed]:find('exhausted', 1, true) ~= nil, 'exhaustion is logged')
    stubs.connectPlayer(env, 4, { joining = false })
    env.SetPlayerRoutingBucket('4', b)
    stubs.triggerOn(env, 'onResourceStop', 0, 'plugin_a')
    eq(B.info(a), nil, "the owner's buckets are released when it stops")
    eq(B.info(b), nil, 'all of them')
    eq(env.GetPlayerRoutingBucket('4'), 0, 'and their players moved to bucket 0')
    eq(B.info(c) ~= nil, true, "other owners' buckets stay")
    eq(B.allocate({}), 20000, 'freed ids are handed out again (wrapping)')
end

-- release with core's real sessions: a loaded player goes through Player.setBucket (L11) ------------------
do
    stubs.newWorld()
    stubs.clear()
    stubs.resetServer()
    stubs.tick(1000)
    local env = stubs.newEnv('server', 'core')
    env.SetRoutingBucketPopulationEnabled = function() end
    env.SetRoutingBucketEntityLockdownMode = function() end
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    for _, file in ipairs({ 'shared/ui_forms.lua', 'server/api.lua', 'shared/hooks.lua', 'server/db.lua',
        'server/globals.lua', 'server/notify.lua', 'server/perms.lua', 'server/buckets.lua', 'server/player.lua' }) do
        if stubs.readFile(stubs.root .. '/' .. file) then stubs.loadFile(env, file) end
    end
    local Core = env.Core
    local bucket = Core.Buckets.allocate({ label = 'map' })
    stubs.connectPlayer(env, 1, { license = 'license:b1' })          -- joins: a session
    stubs.connectPlayer(env, 2, { license = 'license:b2', joining = false })   -- connected, no session
    check(Core.Player.isLoaded(1) and not Core.Player.isLoaded(2), 'one loaded player, one without a session')
    Core.Player.setBucket(1, bucket)
    env.SetPlayerRoutingBucket('2', bucket)
    stubs.sent = {}
    eq(Core.Buckets.release(bucket), true, 'core releases the bucket')
    eq(env.GetPlayerRoutingBucket('1'), 0, 'the loaded player is back in bucket 0')
    eq(env.GetPlayerRoutingBucket('2'), 0, 'the player without a session too')
    local notices = {}
    for _, packet in ipairs(stubs.sent) do
        if packet.name == 'core:client:bucketChanged' then notices[#notices + 1] = packet end
    end
    eq(#notices, 1, 'one core:client:bucketChanged (the loaded player only)')
    eq(notices[1] and tonumber(notices[1].target), 1, 'sent to the loaded player')
    eq(notices[1] and notices[1].args[1], 0, 'naming bucket 0')
end

print(('buckets: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
