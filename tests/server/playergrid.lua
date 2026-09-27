return function(H)
    local check, eq, dispatchChat, newServer, stubs, suite, vector3 =
        H.check, H.eq, H.dispatchChat, H.newServer, H.stubs, H.suite, H.vector3

--- Core.PlayerGrid (DESIGN §22.1): the server-side player spatial index and the proximity paths
--- routed through it (Player.getInRange/getClosest, chat's sendNear/dispatch/scream).

--- Players the grid can index without a session: the refresh thread walks Core.Player.getPlayers()
--- and then only calls GetPlayerPed + GetEntityCoords, both of which the stub table drives.
--- Returns the src array and a { [src] = coords } map for the brute-force comparison.
local function fakePlayers(Core, total, placeFn)
    local srcs, coords = {}, {}
    for src = 1, total do
        local ped = 20000 + src
        srcs[src] = src
        stubs.peds[src] = ped
        coords[src] = placeFn(src)
        stubs.coords[ped] = coords[src]
    end
    Core.Player.getPlayers = function() return srcs end
    return srcs, coords
end

--- { [src] = true } of every src the grid offers as a candidate for that query.
local function candidateSet(Core, coords, range, out)
    local count = Core.PlayerGrid.candidates(coords, range, out)
    local set = {}
    for i = 1, count do set[out[i]] = true end
    return set, count
end

local function suitePlayerGrid()
    suite('playergrid')
    stubs.resetServer()
    local env, Core = newServer()
    stubs.loadFile(env, 'server/getters.lua')
    local Grid = Core.PlayerGrid
    check(type(Grid) == 'table', 'server/playergrid.lua installed Core.PlayerGrid')
    eq(Grid.count(), 0, 'a fresh grid holds nobody')

    -- 1. insert on join, removal on drop
    stubs.connectPlayer(env, 1, { name = 'Ada', coords = vector3(0.0, 0.0, 0.0) })
    stubs.connectPlayer(env, 2, { name = 'Bruno', coords = vector3(130.0, 0.0, 0.0) })
    eq(Grid.count(), 2, 'a joining player is indexed immediately')
    eq(math.type(Grid.cellOf(1)), 'integer', 'the cell key is an integer')
    check(Grid.cellOf(1) ~= Grid.cellOf(2), 'players 130 m apart land in different 128 m cells')
    stubs.dropPlayer(env, 2)
    eq(Grid.count(), 1, 'playerDropped removes the record')
    eq(Grid.cellOf(2), nil, 'and with it the cell')

    -- 2. candidates: the neighbouring cell inside range + slack, never the player 1 km away
    stubs.connectPlayer(env, 2, { name = 'Bruno', coords = vector3(130.0, 0.0, 0.0) })
    stubs.connectPlayer(env, 3, { name = 'Cleo', coords = vector3(1000.0, 0.0, 0.0) })
    local out = {}
    local seen = candidateSet(Core, vector3(120.0, 0.0, 0.0), 20.0, out)
    eq(seen[2], true, 'the player in the queried cell is a candidate')
    eq(seen[1], true, 'so is the one in the neighbouring cell (range + slack reaches it)')
    eq(seen[3], nil, 'the player a kilometre away is not')

    -- 3. negative coordinates key into the same positive-integer space
    stubs.connectPlayer(env, 4, { name = 'Dora', coords = vector3(-300.0, -70.0, 15.0) })
    local key = Grid.cellOf(4)
    check(math.type(key) == 'integer' and key > 0, 'a negative cell still keys to a positive integer')
    seen = candidateSet(Core, vector3(-290.0, -70.0, 15.0), 10.0, out)
    eq(seen[4], true, 'the negative-coordinate player is found from a negative query')
    eq(seen[1], nil, 'and the player at the origin is not dragged in')

    -- 4. `out` is the caller's reusable array: only the count is meaningful
    local wide = select(2, candidateSet(Core, vector3(0.0, 0.0, 0.0), 2000.0, out))
    check(wide >= 4, ('a wide query returns everybody (got %d)'):format(wide))
    local narrow = Grid.candidates(vector3(-300.0, -70.0, 15.0), 5.0, out)
    eq(narrow, 1, 'the next query into the same array returns only its own count')
    eq(out[1], 4, 'and writes its result from index 1')
    check(out[narrow + 1] ~= nil, 'the stale tail is deliberately left behind (callers use the count)')
    eq(Grid.candidates(vector3(0.0, 0.0, 0.0), 1e9, out), #Core.Player.getPlayers(),
        'an absurd radius takes the full-loop fallback instead of walking every cell')

    -- 5. a move is picked up by the staggered refresh, not before it
    local before = Grid.cellOf(1)
    stubs.coords[stubs.peds[1]] = vector3(600.0, 0.0, 0.0)
    eq(Grid.cellOf(1), before, 'the grid does not see a move until that player is refreshed')
    stubs.tick(2000)
    check(Grid.cellOf(1) ~= before, 'the refresh moves the player into their new cell')
    seen = candidateSet(Core, vector3(600.0, 0.0, 0.0), 20.0, out)
    eq(seen[1], true, 'and the new cell answers the query')

    -- 5b. positionOf (DESIGN §55.6 backstop): the cached record, read without natives
    local coordReads, timerReads = stubs.entityCoordReads, stubs.gameTimerReads
    local px, py, pz, pat = Grid.positionOf(1)
    eq(px, 600.0, 'positionOf answers the refreshed x')
    check(py == 0.0 and pz == 0.0, 'and y / z of the same record')
    check(math.type(pat) == 'integer' and pat > 0 and pat <= stubs.now(), 'and when it was read')
    eq(stubs.entityCoordReads, coordReads, 'positionOf reads no coordinates')
    eq(stubs.gameTimerReads, timerReads, 'and no timer')
    eq(Grid.positionOf(9999), nil, 'an unknown src has no position')
    stubs.dropPlayer(env, 4)
    eq(Grid.positionOf(4), nil, 'a dropped player has no position')

    -- 6. slice maths: every player refreshed within REFRESH_MS, whatever the population
    for _, total in ipairs({ 1, 7, 500 }) do
        local _, sliceCore = newServer()
        fakePlayers(sliceCore, total, function(src) return vector3(src * 3.0, 0.0, 0.0) end)
        eq(sliceCore.PlayerGrid.count(), 0, ('%d players: nothing indexed before the thread runs'):format(total))
        stubs.tick(1000)                       -- the idle thread wakes and rebuilds its walk order
        if total == 500 then
            local first = sliceCore.PlayerGrid.count()
            check(first > 0 and first < total,
                ('500 players: the first slice refreshes some, not all (got %d)'):format(first))
        end
        stubs.tick(2000)                       -- REFRESH_MS
        eq(sliceCore.PlayerGrid.count(), total,
            ('%d players: every one is refreshed within REFRESH_MS'):format(total))
    end

    -- 7. getInRange / getClosest are identical to the brute-force answer (300 players, fixed seed)
    local bigEnv, bigCore = newServer()
    stubs.loadFile(bigEnv, 'server/getters.lua')
    math.randomseed(20260918)
    local _, positions = fakePlayers(bigCore, 300, function()
        return vector3(math.random(-1500, 1500) + 0.0, math.random(-1500, 1500) + 0.0, 30.0)
    end)
    stubs.tick(3000)
    eq(bigCore.PlayerGrid.count(), 300, 'the grid holds all 300 randomised players')

    local queries = { vector3(0.0, 0.0, 30.0), vector3(-1200.0, 800.0, 30.0), vector3(640.0, -640.0, 30.0) }
    for q = 1, #queries do
        for _, range in ipairs({ 50.0, 200.0 }) do
            local origin = queries[q]
            local expected, expectedCount = {}, 0
            for src = 1, 300 do
                if #(positions[src] - origin) <= range then
                    expected[src] = true
                    expectedCount = expectedCount + 1
                end
            end
            local got = bigCore.Player.getInRange(origin, range)
            local label = ('query %d at %g m'):format(q, range)
            eq(#got, expectedCount, label .. ': getInRange returns the brute-force count')
            local ordered, matched = true, true
            for i = 1, #got do
                if not expected[got[i].src] then matched = false end
                if i > 1 and got[i - 1].dist > got[i].dist then ordered = false end
            end
            check(matched, label .. ': every returned player is one the brute force found')
            check(ordered, label .. ': the result is still nearest first')
        end
    end

    -- getClosest: same nearest neighbour as the brute force, from a real player's ped
    local origin = positions[1]
    local bestSrc, bestDist
    for src = 2, 300 do
        local dist = #(positions[src] - origin)
        if dist <= 2000.0 and (not bestDist or dist < bestDist) then bestSrc, bestDist = src, dist end
    end
    local gotSrc, gotDist = bigCore.Player.getClosest(1, 2000.0)
    eq(gotSrc, bestSrc, 'getClosest finds the brute-force nearest player')
    eq(gotDist, bestDist, 'and reports its exact distance')
    eq(bigCore.Player.getClosest(1, 1.0), nil, 'nobody inside a 1 m radius')

    -- 8. chat proximity: the same recipients as before, for a fraction of the getCoords calls
    stubs.resetServer()          -- a clean player store: 60 fresh characters, no leftover licenses
    local chatEnv, chatCore = newServer()
    stubs.loadFile(chatEnv, 'server/chat.lua')
    local NEAR_COUNT <const> = 6
    local ONLINE <const> = 60
    local chatCoords = {}
    for src = 1, ONLINE do
        chatCoords[src] = (src <= NEAR_COUNT) and vector3((src - 1) * 10.0, 0.0, 0.0)
            or vector3(2000.0 + src * 50.0, 0.0, 0.0)
        stubs.connectPlayer(chatEnv, src, { name = ('P%d'):format(src), coords = chatCoords[src] })
    end
    eq(chatCore.PlayerGrid.count(), ONLINE, 'every chatter is indexed')
    local realGetCoords = chatCore.Player.getCoords
    -- the brute force this replaces, verbatim: every LOADED player, live coords, exact distance
    local loadedChatters = chatCore.Player.getPlayers()
    eq(#loadedChatters, ONLINE, 'every chatter has a session')
    local expectedChat, expectedChatCount = {}, 0
    for i = 1, #loadedChatters do
        local src = loadedChatters[i]
        local at = realGetCoords(src)
        if at and #(at - chatCoords[1]) <= 90.0 then            -- Config.Chat.FadeMeters.far
            expectedChat[src] = true
            expectedChatCount = expectedChatCount + 1
        end
    end

    local coordCalls = 0
    chatCore.Player.getCoords = function(src)
        coordCalls = coordCalls + 1
        return realGetCoords(src)
    end
    stubs.clear()
    dispatchChat(chatEnv, 1, 'proximity words')
    local reached, reachedCount = {}, 0
    for i = 1, #stubs.sent do
        local packet = stubs.sent[i]
        if packet.name == 'core:client:chat' and packet.args[1].action == 'add' then
            if not reached[packet.target] then reachedCount = reachedCount + 1 end
            reached[packet.target] = true
        end
    end
    eq(reachedCount, expectedChatCount, 'the grid-routed line reaches exactly the brute-force recipients')
    local missing = {}
    for src in pairs(expectedChat) do
        if not reached[src] then missing[#missing + 1] = tostring(src) end
    end
    check(#missing == 0, 'and every one of them individually',
        'missing: ' .. table.concat(missing, ', '))
    check(coordCalls <= NEAR_COUNT + 2,
        ('getCoords ran %d times for %d players online'):format(coordCalls, ONLINE))
    chatCore.Player.getCoords = realGetCoords

    -- 9. fallback: an empty grid answers with every loaded player (the old full loop)
    local _, emptyCore = newServer()
    local fallbackSrcs = { 1, 2, 3 }
    emptyCore.Player.getPlayers = function() return fallbackSrcs end
    eq(emptyCore.PlayerGrid.count(), 0, 'the grid is still empty (the thread has not run)')
    local fallbackOut = {}
    eq(emptyCore.PlayerGrid.candidates(vector3(0.0, 0.0, 0.0), 10.0, fallbackOut), 3,
        'an empty grid falls back to every loaded player')
    eq(emptyCore.PlayerGrid.candidates('nope', 10.0, fallbackOut), 0, 'a bad origin returns nothing')

    -- 10. Audio.playAt (server/remote.lua) scans the grid's candidates, not every player, and sends ONE
    -- packed payload to the players in range (Net.emitMany)
    local audioEnv, audioCore = newServer()
    stubs.loadFile(audioEnv, 'server/remote.lua')
    stubs.connectPlayer(audioEnv, 1, { name = 'Ada', coords = vector3(0.0, 0.0, 0.0) })
    stubs.connectPlayer(audioEnv, 2, { name = 'Bruno', coords = vector3(10.0, 0.0, 0.0) })
    stubs.connectPlayer(audioEnv, 3, { name = 'Cleo', coords = vector3(60.0, 0.0, 0.0) })     -- candidate, out of range
    stubs.connectPlayer(audioEnv, 4, { name = 'Dora', coords = vector3(3000.0, 0.0, 0.0) })   -- not even a candidate
    local pedAsks = 0
    local realGetPlayerPed = audioEnv.GetPlayerPed
    audioEnv.GetPlayerPed = function(src) pedAsks = pedAsks + 1; return realGetPlayerPed(src) end
    local audioBefore = #stubs.sent
    eq(audioCore.Audio.playAt(vector3(2.0, 0.0, 0.0), 'BEEP', nil, 20.0), 2, 'playAt reaches the two players in range')
    local reached = {}
    for i = audioBefore + 1, #stubs.sent do
        if stubs.sent[i].name == 'core:client:audio' then reached[stubs.sent[i].target] = true end
    end
    check(reached[1] and reached[2] and not reached[3] and not reached[4], 'exactly the players within range hear it')
    check(pedAsks <= 3, ('the far player is never asked for a ped (%d lookups for 4 online)'):format(pedAsks))
    audioEnv.GetPlayerPed = realGetPlayerPed

    -- 11. the autosave pass is chunked (DESIGN §9 "Scale"): 25 sessions, then 250 ms of air — a full
    -- server is never saved inside one tick, and below one chunk the pass is a single tick as before
    local saveEnv, saveCore = newServer()
    local saved = 0
    saveCore.on('playerSaved', function() saved = saved + 1 end)
    stubs.osTime = 1800000000                       -- no second of playtime passes: only the position is dirty
    for src = 1, 60 do
        -- every ped stands away from the stored spawn point, so each session has a position to write (§56.8)
        stubs.connectPlayer(saveEnv, src, { name = 'P' .. src, coords = vector3(src + 0.0, 0.0, 0.0) })
    end
    saved = 0
    saveEnv.Config.Player.SaveIntervalMs = 5000      -- five minutes of grid steps would exhaust the stub scheduler
    local interval = saveEnv.Config.Player.SaveIntervalMs
    saveCore.Player.startAutosave()
    stubs.tick(interval + 10)
    eq(saved, 25, 'the first tick of a pass saves one chunk of 25 sessions')
    stubs.tick(250)
    eq(saved, 50, 'the next chunk follows 250 ms later')
    stubs.tick(250)
    eq(saved, 60, 'and the rest after that — everybody was saved exactly once')
    stubs.tick(2000)
    eq(saved, 60, 'clean sessions are not written again')
    stubs.tick(interval)
    eq(saved, 60, 'nor by the next pass: nobody moved and no second passed')
    saveCore.Player.stopAutosave()
    stubs.osTime = nil

    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
    stubs.resetServer()
end

    return suitePlayerGrid
end
