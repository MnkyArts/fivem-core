--[[
    core/tests/targets_tests.lua — target selectors (DESIGN §49).

        lua5.4 tests/targets_tests.lua    (from the resource directory, or from tests/)

    Player.resolveTargets (server/getters.lua) token by token, union / negation / de-duplication,
    ambiguity, max, allowSelf, loaded-only, bad input — and the `target` / `targets` param types of
    Core.Commands (lib/commands/shared.lua) in core's VM, through a plugin's export proxy and refused
    on the client. Same harness as server_tests.lua; exit code 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/targets_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
local stubs = dofile(here .. '/stubs.lua')
local vector3 = stubs.vector3

local passed, failed, suiteName = 0, 0, '?'
local failures = {}

local function suite(name) suiteName = name end

local function show(v)
    if type(v) == 'string' then return ('%q'):format(v) end
    if type(v) == 'table' then
        local parts = {}
        for i = 1, #v do parts[i] = show(v[i]) end
        return '{' .. table.concat(parts, ',') .. '}'
    end
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
    return check(actual == expected, label, ('expected %s, got %s'):format(show(expected), show(actual)))
end

--- Array equality, order included.
local function same(actual, expected, label)
    local ok = type(actual) == 'table' and #actual == #expected
    if ok then
        for i = 1, #expected do
            if actual[i] ~= expected[i] then ok = false end
        end
    end
    return check(ok, label, ('expected %s, got %s'):format(show(expected), show(actual)))
end

local function lastSent(name)
    for i = #stubs.sent, 1, -1 do
        if stubs.sent[i].name == name then return stubs.sent[i] end
    end
    return nil
end

local function printed(needle)
    for i = #stubs.printed, 1, -1 do
        if stubs.printed[i]:find(needle, 1, true) then return stubs.printed[i] end
    end
    return nil
end

-- manifest order (a file that does not exist yet is skipped), plus getters.lua for resolveTargets
local SERVER_FILES <const> = {
    'shared/ui_forms.lua', 'server/api.lua', 'shared/hooks.lua', 'server/db.lua', 'server/globals.lua',
    'server/notify.lua', 'server/perms.lua', 'server/player_store.lua', 'server/player.lua', 'server/playergrid.lua',
    'server/money.lua',
    'server/factions.lua', 'server/vehicles.lua', 'server/getters.lua',
}

local function newServer()
    stubs.newWorld()
    stubs.clear()
    stubs.resetServer()
    for i = #stubs.failures, 1, -1 do stubs.failures[i] = nil end
    stubs.tick(1000)
    local env = stubs.newEnv('server', 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    for i = 1, #SERVER_FILES do
        if stubs.readFile(stubs.root .. '/' .. SERVER_FILES[i]) then stubs.loadFile(env, SERVER_FILES[i]) end
    end
    return env, env.Core
end

--- The shared world: 1 Ada (admin, origin), 2 Bob (mod, 30 m), 3 Bobby (user, 300 m),
--- 4 Cleo (user, 2 km), 5 Ghost (connected, never loaded — playerJoining did not run).
local function world()
    local env, Core = newServer()
    stubs.connectPlayer(env, 1, { name = 'Ada', coords = vector3(0.0, 0.0, 0.0) })
    stubs.connectPlayer(env, 2, { name = 'Bob', coords = vector3(30.0, 0.0, 0.0) })
    stubs.connectPlayer(env, 3, { name = 'Bobby', coords = vector3(300.0, 0.0, 0.0) })
    stubs.connectPlayer(env, 4, { name = 'Cleo', coords = vector3(2000.0, 0.0, 0.0) })
    stubs.connectPlayer(env, 5, { name = 'Ghost', joining = false })
    Core.Player.setGroup(1, 'admin')
    Core.Player.setGroup(2, 'mod')
    return env, Core
end

--- Every token of the §49 grammar on its own.
local function suiteTokens()
    suite('tokens')
    local _, Core = world()
    local P = Core.Player
    local R = P.resolveTargets
    check(type(R) == 'function', 'server/getters.lua installed Player.resolveTargets')

    same(R(1, 'me'), { 1 }, 'me is the actor')
    same(R(1, '^'), { 1 }, '^ is the actor')
    same(R(1, 'ME'), { 1 }, 'keywords are case-insensitive')
    eq(select(2, R(0, 'me')), 'no_self', 'the console has no self')

    same(R(1, '2'), { 2 }, 'a numeric id')
    same(R(1, '$3'), { 3 }, '$<id>')
    same(R(1, 3), { 3 }, 'an integer selector is an id')
    local list, err, detail = R(1, '5')
    eq(list, nil, 'a connected but unloaded player is no target')
    eq(err, 'not_found', '... not_found')
    eq(detail, '5', '... naming the token')
    eq(select(2, R(1, '99')), 'not_found', 'an unknown id')

    local charId = P.getInfo(3).charId
    same(R(1, 'c:' .. charId), { 3 }, 'c:<charId>')
    same(R(1, 'C:' .. charId), { 3 }, 'the prefix letter is case-insensitive')
    eq(select(2, R(1, 'c:nope')), 'not_found', 'an unknown character id')

    same(R(1, 'r:50'), { 1, 2 }, 'r:<metres> from the actor, the actor included, nearest first')
    same(R(2, 'r:400'), { 2, 1, 3 }, 'r: orders by distance from the actor')
    eq(select(2, R(1, 'r:501')), 'bad_radius', 'a radius above 500 is refused')
    eq(select(2, R(1, 'r:0')), 'bad_radius', 'a zero radius is refused')
    eq(select(2, R(1, 'r:far')), 'bad_radius', 'a non-numeric radius is refused')
    eq(select(2, R(0, 'r:10')), 'no_origin', 'the console has no position')

    same(R(1, '#admin'), { 1 }, '#<group> is exactly that group')
    same(R(1, '#user'), { 3, 4 }, '#user, ascending src')
    same(R(1, '#MOD'), { 2 }, 'a group name falls back to lower case')
    eq(select(2, R(1, '#wizard')), 'unknown_group', 'an unknown group')
    same(R(1, '%mod'), { 1, 2 }, '%<group> is every weight >= that group (config weights)')
    same(R(1, '%user'), { 1, 2, 3, 4 }, '%user is everybody')
    eq(select(2, R(1, '%owner')), 'no_match', 'nobody that high: no_match')
    eq(select(2, R(1, '%wizard')), 'unknown_group', 'an unknown group for %')

    same(R(1, '*'), { 1, 2, 3, 4 }, '* is every loaded player')
    same(R(1, 'others'), { 2, 3, 4 }, 'others leaves the actor out')
    same(R(0, 'others'), { 1, 2, 3, 4 }, 'the console has no self to leave out')

    same(R(1, 'cle'), { 4 }, 'a partial name with one match')
    same(R(1, 'CLEO'), { 4 }, 'names are case-insensitive')
    same(R(1, 'bob'), { 2 }, 'an exact name wins over the longer partial match')
    list, err, detail = R(1, 'bo')
    eq(err, 'ambiguous', 'two partial matches are ambiguous')
    eq(type(detail) == 'table' and #detail, 2, '... with both candidates')
    eq(detail and detail[1].src, 2, 'a candidate carries its src')
    eq(detail and detail[1].name, 'Bob', '... and its name')
    eq(select(2, R(1, 'ghost')), 'not_found', 'an unloaded player is not found by name')
    eq(select(2, R(1, 'zzz')), 'not_found', 'nobody by that name')
end

--- Union, negation, de-duplication, max, allowSelf, bad input, factions, perms v2 weights.
local function suiteCombos()
    suite('combos')
    local env, Core = world()
    local R = Core.Player.resolveTargets

    same(R(1, '2,3'), { 2, 3 }, 'a comma is a union')
    same(R(1, '3, 2 ,3'), { 3, 2 }, 'duplicates collapse, first-seen order, spaces trimmed')
    same(R(1, '*,!2'), { 1, 3, 4 }, '! removes')
    same(R(1, '!2,*'), { 1, 3, 4 }, '... wherever it stands')
    same(R(1, '*, !me'), { 2, 3, 4 }, '!me')
    same(R(1, 'r:50,4'), { 1, 2, 4 }, 'a radius and an id')
    same(R(1, '#user,!cleo'), { 3 }, 'a group minus a name')
    same(R(1, '2,!99'), { 2 }, 'removing somebody who is not there is a no-op')
    same(R(0, '*,!me'), { 1, 2, 3, 4 }, '... and so is !me from the console')
    eq(select(2, R(1, '*,!bo')), 'ambiguous', 'an ambiguous removal is still an error')
    eq(select(2, R(1, '2,99')), 'not_found', 'one missing single target fails the whole selector')
    eq(select(2, R(1, '*,!*')), 'no_match', 'everybody removed: no_match')

    local list, err, count = R(1, '*', { max = 2 })
    eq(list, nil, 'max caps the result')
    eq(err, 'too_many', '... too_many')
    eq(count, 3, '... stopping the union at max + 1')
    same(R(1, '2,2, 2'), { 2 }, 'a repeated token is resolved once')
    same(R(1, '*,others,#user,%user'), { 1, 2, 3, 4 }, 'four set tokens are allowed')
    eq(select(2, R(1, '*,others,#user,%user,#mod')), 'bad_selector', 'a fifth set token is refused')
    same(R(1, '*,*,*,*,*,*'), { 1, 2, 3, 4 }, 'repeats of one set token count once')
    eq(select(2, R(1, 'r:10,r:20,r:30,f:x,!*')), 'bad_selector', 'removals count toward the cap')
    eq(select(2, R(1, 'r:')), 'not_found', 'a bare r: is just a name')

    -- R2-7: case variants of one name are ONE token; at most 8 distinct names per selector
    same(R(1, 'cle,Cle,CLE,cLe,clE,CLe,cLE,ClE,cleo'), { 4 }, 'nine spellings of two names pass (two scans)')
    same(R(1, 'ME,me,Me,OTHERS,others'), { 1, 2, 3, 4 }, 'keywords de-duplicate case-insensitively too')
    eq(select(2, R(1, 'zq,zw,ze,zr,zt,zy,zu,zi')), 'not_found', 'eight distinct names are resolved')
    eq(select(2, R(1, 'zq,zw,ze,zr,zt,zy,zu,zi,zo')), 'bad_selector', 'a ninth distinct name is refused')
    same(R(1, '1,2,3,4,1,2,3,4,1,2,3,4'), { 1, 2, 3, 4 }, 'ids are cheap: no name cap for them')

    -- the basic grammar (commands for non-staff): me / ids / c: / names only
    local basic = { basic = true }
    same(R(1, 'me', basic), { 1 }, 'basic: me')
    same(R(1, '2,$3', basic), { 2, 3 }, 'basic: ids, unions of them')
    same(R(1, 'cle', basic), { 4 }, 'basic: names')
    for _, token in ipairs({ '*', 'others', '#admin', '%mod', 'r:50', 'f:lost', '2,!3' }) do
        eq(select(2, R(1, token, basic)), 'not_allowed', 'basic refuses ' .. token)
    end
    same(R(1, '2', { max = 1 }), { 2 }, 'within max')
    same(R(1, '*', { allowSelf = false }), { 2, 3, 4 }, 'allowSelf = false drops the actor')
    eq(select(2, R(1, 'me', { allowSelf = false })), 'self', 'and says self when nothing else is left')
    same(R(1, 'me', { allowSelf = true }), { 1 }, 'allowSelf defaults to true')

    eq(select(2, R('1', 'me')), 'bad_actor', 'a string actor')
    eq(select(2, R(-1, 'me')), 'bad_actor', 'a negative actor')
    eq(select(2, R(1.5, 'me')), 'bad_actor', 'a fractional actor')
    eq(select(2, R(1, {})), 'bad_selector', 'a table selector')
    eq(select(2, R(1, '')), 'bad_selector', 'an empty selector')
    eq(select(2, R(1, ' , ,')), 'bad_selector', 'only commas and spaces')
    eq(select(2, R(1, '!')), 'bad_selector', 'a bare !')
    eq(select(2, R(1, ('x'):rep(257))), 'bad_selector', 'longer than 256 characters')
    eq(select(2, R(1, ('2,'):rep(33))), 'bad_selector', 'more than 32 tokens')
    eq(select(2, R(1, 'me', 'x')), 'bad_selector', 'opts must be a table')

    -- perms v2 (§44): Perms.groups is read ONCE per call, weights never via per-player Perms.getWeight
    local perms = Core.Perms
    local saved = { groups = rawget(perms, 'groups'), getWeight = rawget(perms, 'getWeight'),
        groupExists = rawget(perms, 'groupExists') }
    local groupCalls, weightCalls = 0, 0
    perms.groups = function()
        groupCalls = groupCalls + 1
        return { { name = 'vip', weight = 50 }, { name = 'admin', weight = 300 }, { name = 'user', weight = 0 } }
    end
    perms.getWeight = function() weightCalls = weightCalls + 1 return 0 end
    perms.groupExists = function(name) return name == 'vip' end
    Core.Player.setGroup(3, 'vip')
    perms.groupExists = saved.groupExists
    same(R(1, '%vip'), { 1, 3 }, '%group reads the weights of Perms.groups')
    groupCalls = 0
    same(R(1, '%vip,#vip,%user,#admin'), { 1, 3, 2, 4 }, 'four group tokens in one selector')
    eq(groupCalls, 1, 'Perms.groups ran once for the whole call')
    eq(weightCalls, 0, 'no per-player Perms.getWeight')
    eq(select(2, R(1, '%mod')), 'unknown_group', 'a group Perms.groups does not list is unknown')
    same(R(1, '#user'), { 2, 4 }, 'a stored group Perms does not know reads as user')
    perms.groups = function() error('boom') end
    same(R(1, '%mod'), { 1, 2 }, 'a failing Perms.groups falls back to the config seed')
    perms.groups, perms.getWeight = saved.groups, saved.getWeight

    -- ambiguity lists at most ten candidates
    for i = 1, 12 do
        stubs.connectPlayer(env, 100 + i, { name = ('Twin%02d'):format(i), coords = vector3(5000.0, 0.0, 0.0) })
    end
    local _, why, candidates = R(1, 'twin')
    eq(why, 'ambiguous', 'twelve twins are ambiguous')
    eq(#candidates, 10, '... with ten candidates listed')
    same(R(1, 'twin07'), { 107 }, 'a full name still resolves')

    -- f:<faction> by tag, name or id; members online only
    local id = Core.Factions.create(2, 'Lost Riders', 'LOST')
    check(id ~= nil, 'the test faction was created')
    same(R(1, 'f:LOST'), { 2 }, 'f:<tag>')
    same(R(1, 'f:lost'), { 2 }, 'the tag is case-insensitive')
    same(R(1, 'f:Lost Riders'), { 2 }, 'f:<name>')
    same(R(1, 'f:' .. tostring(id)), { 2 }, 'f:<id>')
    eq(select(2, R(1, 'f:nobody')), 'unknown_faction', 'an unknown faction')
    stubs.dropPlayer(env, 2)
    eq(select(2, R(1, 'f:LOST')), 'no_match', 'a faction with nobody online matches nobody')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

--- The message of the last core:client:notify sent to `src`, or nil.
local function lastNotice(src)
    for i = #stubs.sent, 1, -1 do
        local packet = stubs.sent[i]
        if packet.name == 'core:client:notify' and packet.target == src then return packet.args[1].message end
    end
    return nil
end

--- `target` / `targets` command params (§49) in core's VM, a plugin VM and a client VM.
local function suiteCommands()
    suite('commands')
    local env, Core = world()
    local seen = {}
    Core.Commands.register('tkick', { params = { { name = 'who', type = 'target' },
        { name = 'reason', type = 'rest', optional = true } } }, function(src, args) seen[#seen + 1] = args end)
    Core.Commands.register('tfreeze', { params = { { name = 'who', type = 'targets', max = 3 } } },
        function(src, args) seen[#seen + 1] = args end)
    Core.Commands.register('tslap', { params = { { name = 'who', type = 'target', allowSelf = false } } },
        function(src, args) seen[#seen + 1] = args end)
    -- every command line with target params is throttled per src (100 ms, R2-7): step the clock past it
    local function paced(fn) return function(...) stubs.tick(100) return fn(...) end end
    local kick = paced(env.__vm.commands.tkick.fn)
    local freeze = paced(env.__vm.commands.tfreeze.fn)
    local slap = paced(env.__vm.commands.tslap.fn)
    local staffPerm = Core.Config.Admin.StaffPerm

    -- a caller without the staff permission gets the basic grammar only (review L3)
    eq(Core.Perms.has(3, staffPerm), false, 'player 3 is no staff')
    kick(3, { '2' }, '/tkick 2')
    eq(seen[1] and seen[1].who, 2, 'non-staff: an id works')
    kick(3, { 'cle' }, '/tkick cle')
    eq(seen[2] and seen[2].who, 4, 'non-staff: a name works')
    kick(3, { '#mod' }, '/tkick #mod')
    eq(#seen, 2, 'non-staff: a group selector stops the handler')
    eq(lastNotice(3), "'#mod': only staff can use that kind of target", '... with the staff-only text')
    freeze(3, { 'r:500' }, '/tfreeze r:500')
    eq(lastNotice(3), "'r:500': only staff can use that kind of target", 'non-staff: no radius either')
    seen = {}
    eq(Core.Perms.grant(1, staffPerm), true, 'player 1 becomes staff')

    kick(1, { '2', 'be', 'nice' }, '/tkick 2 be nice')
    eq(#seen, 1, 'a resolved target runs the handler')
    eq(seen[1].who, 2, 'target resolves to one src')
    eq(math.type(seen[1].who), 'integer', '... an integer')
    eq(seen[1].reason, 'be nice', 'the other params still parse')
    kick(1, { 'cleo' }, '/tkick cleo')
    eq(seen[2].who, 4, 'a partial name works as a target')
    kick(1, { 'bo' }, '/tkick bo')
    eq(#seen, 2, 'an ambiguous target stops the handler')
    eq(lastNotice(1), "'bo' matches several players: Bob (2), Bobby (3)", 'the caller sees the candidates')
    kick(1, { '*' }, '/tkick *')
    eq(lastNotice(1), "'*' matches too many players", 'target takes exactly one player')
    kick(1, { 'zzz' }, '/tkick zzz')
    eq(lastNotice(1), "No player matches 'zzz'", 'nobody by that name')
    kick(1, {}, '/tkick')
    eq(lastNotice(1), 'Usage: /tkick <who> [reason]', 'a missing target is still the usage line')
    kick(1, { '#wizard' }, '/tkick #wizard')
    eq(lastNotice(1), "'#wizard': no such group", 'an unknown group has its own text')
    kick(1, { 'r:900' }, '/tkick r:900')
    eq(lastNotice(1), "'r:900': the radius must be 1 to 500 metres", 'so does a bad radius')

    freeze(1, { '#user' }, '/tfreeze #user')
    local last = seen[#seen]
    eq(type(last.who), 'table', 'targets resolves to an array')
    eq(last.who and #last.who, 2, '... of every match')
    eq(last.who and last.who[1], 3, '... in resolve order')
    local before = #seen
    freeze(1, { '*' }, '/tfreeze *')
    eq(#seen, before, 'more than the param max stops the handler')
    eq(lastNotice(1), "'*' matches too many players", '... with too_many')

    slap(1, { 'me' }, '/tslap me')
    eq(#seen, before, 'allowSelf = false refuses the actor')
    eq(lastNotice(1), 'You cannot target yourself with this command', '... with the self text')
    slap(1, { '2' }, '/tslap 2')
    eq(seen[#seen].who, 2, 'somebody else is fine')

    kick(0, { '3' }, '/tkick 3')
    eq(seen[#seen].who, 3, 'the console resolves targets too')
    kick(0, { 'me' }, '/tkick me')
    check(printed("No player matches 'me'") ~= nil, 'the console has no self and is told so')
    stubs.tick(100)
    eq(Core.Commands.execute('tkick', 1, { '4' }, '/tkick 4'), true, 'Commands.execute resolves targets')
    eq(seen[#seen].who, 4, '... to the same src')
    stubs.tick(100)
    eq(Core.Commands.execute('tkick', 1, { 'bo' }, '/tkick bo'), false, 'and refuses an ambiguous one')

    -- the per-src throttle (R2-7): one command line with a costly selector (a name or set token) per 100 ms
    local count = #seen
    stubs.tick(100)
    env.__vm.commands.tkick.fn(1, { 'bob' }, '/tkick bob')
    env.__vm.commands.tkick.fn(1, { 'cle' }, '/tkick cle')
    eq(#seen, count + 1, 'a second name lookup inside 100 ms is refused')
    eq(lastNotice(1), "'cle': too many target lookups, try again in a moment", '... with the too_fast text')
    env.__vm.commands.tkick.fn(1, { '3' }, '/tkick 3')
    env.__vm.commands.tkick.fn(1, { '$4,!2' }, '/tkick $4,!2')
    eq(seen[#seen].who, 4, 'ids (O(1) lookups) are never throttled')
    env.__vm.commands.tkick.fn(2, { 'bobby' }, '/tkick bobby')
    eq(seen[#seen].who, 3, 'another src has its own clock')
    stubs.tick(100)
    env.__vm.commands.tkick.fn(1, { 'cle' }, '/tkick cle')
    eq(seen[#seen].who, 4, 'after 100 ms it resolves again')
    env.__vm.commands.tkick.fn(0, { 'bob' }, '/tkick bob')
    env.__vm.commands.tkick.fn(0, { 'bobby' }, '/tkick bobby')
    eq(seen[#seen].who, 3, 'the console is never throttled')
    Core.Commands.register('tpair', { params = { { name = 'a', type = 'target' }, { name = 'b', type = 'target' } } },
        function(_, args) seen[#seen + 1] = args end)
    stubs.tick(100)
    env.__vm.commands.tpair.fn(1, { '2', '3' }, '/tpair 2 3')
    eq(seen[#seen].b, 3, 'one line with two target params is one lookup budget')
    eq(Core.Commands.get('tkick').params[1].type, 'target', 'Commands.get reports the param type')

    -- a plugin VM: Core.Player.resolveTargets is the export proxy into core
    stubs.resourceStates.tplugin = 'started'
    local penv = stubs.newEnv('server', 'tplugin')
    stubs.loadImport(penv)
    local got
    penv.Core.Commands.register('pkick', { params = { { name = 'who', type = 'target' } } },
        function(_, args) got = args.who end)
    stubs.tick(100)
    penv.__vm.commands.pkick.fn(1, { 'cle' }, '/pkick cle')
    eq(got, 4, "a plugin's target param resolves through the export proxy")
    stubs.tick(100)
    penv.__vm.commands.pkick.fn(1, { 'bo' }, '/pkick bo')
    eq(lastNotice(1), "'bo' matches several players: Bob (2), Bobby (3)",
        '... candidates included (they cross the export)')

    -- a client VM: selectors need the server's sessions
    local cenv = stubs.newEnv('client', 'core')
    stubs.loadImport(cenv)
    stubs.loadFile(cenv, 'shared/config.lua')
    eq(pcall(cenv.Core.Commands.register, 'ckick', { params = { { name = 'who', type = 'target' } } },
        function() end), false, 'a client command cannot declare a target param')
    eq(pcall(cenv.Core.Commands.register, 'cfreeze', { params = { { name = 'who', type = 'targets' } } },
        function() end), false, '... nor targets')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

--------------------------------------------------------------------------------
-- runner
--------------------------------------------------------------------------------

local suites = {
    { 'tokens', suiteTokens },
    { 'combos', suiteCombos },
    { 'commands', suiteCommands },
}

for i = 1, #suites do
    local name, fn = suites[i][1], suites[i][2]
    local ok, err = pcall(fn)
    if not ok then
        suiteName = name
        check(false, 'the suite crashed', tostring(err))
    end
end

print(('\ntargets: %d passed, %d failed'):format(passed, failed))
if failed > 0 then
    print(('%d failing check(s):'):format(#failures))
    for i = 1, #failures do print('  ' .. failures[i]:gsub('\n%s+', ' -- ')) end
    os.exit(1)
end
os.exit(0)
