return function(H)
    local check, eq, newServer, printed, stubs, suite =
        H.check, H.eq, H.newServer, H.printed, H.stubs, H.suite

--- server/api.lua (DESIGN §2.2, §2.3, §14): the `call` export block list and the caller record.
local function suiteApi()
    suite('api')
    stubs.resetServer()
    local env, Core = newServer()
    local call = stubs.exports.core and stubs.exports.core.call
    check(type(call) == 'function', 'server/api.lua registered the call export')

    -- internal namespaces and functions are not reachable through the export
    -- DB (§56.1): the lib runs in the caller's own VM; through the export it would act as core, so the whole
    -- namespace is refused (DB.setAdapter / DB.markDegraded are gone with the document store)
    local blocked = {
        { 'Registry', 'track' }, { 'Registry', 'getOwned' },
        { 'DB', 'query' }, { 'DB', 'save' }, { 'DB', 'setAdapter' },
        { 'Player', 'loadSession' }, { 'Player', 'loadAllConnected' },
        { 'Player', 'startAutosave' }, { 'Player', 'stopAutosave' }, { 'Player', 'saveAll' },
    }
    for i = 1, #blocked do
        local namespace, fn = blocked[i][1], blocked[i][2]
        local ok, err = pcall(call, 'plugin', namespace, fn)
        eq(ok, false, ('%s.%s is refused'):format(namespace, fn))
        eq(err, ('core: %s.%s is internal'):format(namespace, fn),
            ('%s.%s reports why'):format(namespace, fn))
    end
    eq(select(2, pcall(call, 'plugin', 'Nope', 'nothing')), 'core: no API Nope.nothing',
        'an unknown namespace errors instead of returning nil')
    -- DESIGN §14 blocks Core.World from the export, but that was written when Core.World meant the
    -- client-side scheduler of §6.3; §17 makes the *server* Core.World (time/weather) plugin-facing,
    -- so the server block list holds Registry only. This pins that reading.
    eq(select(2, pcall(call, 'plugin', 'World', 'setTime', 12, 0)), 'core: no API World.setTime',
        'the server Core.World is not block-listed (DESIGN §17 supersedes the §14 note)')
    eq(select(2, pcall(call, 'plugin', 'Player', 'nothing')), 'core: no API Player.nothing',
        'an unknown function on a real namespace errors too')

    -- the public half still works, and Core.DB is the lib inside core (DESIGN §56.5)
    stubs.connectPlayer(env, 1, { license = 'license:api', name = 'Api' })
    eq(call('plugin', 'Player', 'isLoaded', 1), true, 'a public API is reachable through the export')
    eq(call('plugin', 'Money', 'get', 1, 'cash'), 5000, 'arguments and return values pass through')
    local a, b = call('plugin', 'Player', 'getCoords', 1)
    check(a ~= nil and b ~= nil, 'multiple return values survive the export')
    check(type(rawget(Core.DB, 'query')) == 'function', 'Core.DB.query is the lib inside core\'s own VM')
    eq(Core.DB.scalar('SELECT 41 + 1 AS n'), 42, '... and reaches core_db')

    -- an error inside the target surfaces unchanged (no pcall wrapper text)
    Core.Testing = { boom = function() error('inner failure', 0) end }
    eq(select(2, pcall(call, 'plugin', 'Testing', 'boom')), 'inner failure',
        'the target error is re-raised as it was')

    -- the caller is per coroutine and survives a yield inside the dispatched function
    local seen = {}
    Core.Testing.who = function(tag, waitMs)
        seen[#seen + 1] = { tag = tag, at = 'enter', caller = Core.Registry.getCaller() }
        if waitMs then env.Wait(waitMs) end
        seen[#seen + 1] = { tag = tag, at = 'exit', caller = Core.Registry.getCaller() }
    end
    env.CreateThread(function() call('res_a', 'Testing', 'who', 'a', 100) end)
    env.CreateThread(function() call('res_b', 'Testing', 'who', 'b', 10) end)
    eq(#seen, 2, 'both dispatches ran up to their Wait')
    eq(seen[1].caller, 'res_a', 'the first dispatch sees its own caller')
    eq(seen[2].caller, 'res_b', 'the second dispatch sees its own caller')
    stubs.tick(200)
    eq(#seen, 4, 'both dispatches finished')
    eq(seen[3].tag, 'b', 'the shorter Wait resumed first')
    eq(seen[3].caller, 'res_b', 'the second dispatch still knows its caller after the yield')
    eq(seen[4].tag, 'a', 'the longer Wait resumed second')
    eq(seen[4].caller, 'res_a',
        'the first caller was not clobbered by the dispatch that overlapped it')
    eq(Core.Registry.getCaller(), 'core', 'the global caller is back to core once both finished')

    -- the runtime's own view of the invoking resource is the caller; a declared name that differs from it is
    -- REFUSED (DESIGN §2.2, §54.1) — nobody acts under another resource's name
    stubs.invokingResource = 'real_plugin'
    Core.Testing.owner = function() return Core.Registry.getCaller() end
    local spoofOk, spoofErr = pcall(call, 'lying_plugin', 'Testing', 'owner')
    eq(spoofOk, false, 'a declared caller that is not the invoking resource is refused')
    check(tostring(spoofErr):find('refused', 1, true) ~= nil, 'with a refusal message', tostring(spoofErr))
    check(printed('call() refused: resource real_plugin declared itself as lying_plugin') ~= nil,
        'and a warning naming both')
    eq(call('real_plugin', 'Testing', 'owner'), 'real_plugin', 'the matching declared name passes')
    eq(call(nil, 'Testing', 'owner'), 'real_plugin', 'no declared name: the invoking resource is the caller')
    stubs.invokingResource = nil
    eq(call(nil, 'Testing', 'owner'), 'core', 'an absent caller name falls back to core')

    -- Core.Registry bookkeeping and the owner sweep (DESIGN §2.3)
    local removed = {}
    eq(Core.Registry.onOwnerStop('widget', function(id, owner)
        removed[#removed + 1] = { id = id, owner = owner }
    end), true, 'a module registers its remover')
    eq(Core.Registry.track('widget', 'w1', 'plugin_a'), true, 'track')
    eq(Core.Registry.track('vehicle', 7, 'plugin_a'), true, 'track accepts a numeric id')
    eq(Core.Registry.track('', 'w2'), false, 'track refuses an empty kind')
    eq(Core.Registry.track('widget', {}), false, 'track refuses a table id')
    eq(Core.Registry.getOwned('plugin_a').widget.w1, true, 'getOwned reports what the plugin holds')
    stubs.triggerOn(env, 'onResourceStop', 0, 'plugin_a')
    eq(#removed, 1, 'the registered remover ran for the stopped resource')
    eq(removed[1].id, 'w1', 'the remover got the id')
    eq(removed[1].owner, 'plugin_a', 'the remover got the owner')
    eq(Core.Registry.getOwned('plugin_a').widget, nil, 'the swept kind is forgotten')
    eq(Core.Registry.getOwned('plugin_a').vehicle[7], true,
        'a kind without a remover keeps its bookkeeping (core vehicles outlive a plugin)')
    eq(Core.Registry.untrack('vehicle', 7), true, 'untrack')
    eq(Core.Registry.untrack('vehicle', 7), false, 'a second untrack is false')
    eq(Core.Registry.getOwned('plugin_a'), nil, 'the owner entry disappears once it holds nothing')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

    return suiteApi
end
