--[[
    core/tests/scene_voice_tests.lua — offline suite for voice through world speakers (DESIGN §55.17):
    server/scene_voice.lua and client/scene_voice.lua.

        lua5.4 tests/scene_voice_tests.lua    (from the resource directory, or from tests/)

    Server (the real scene server files through tests/scene_server_harness.lua, a fake Core.PlayerGrid that answers
    every connected player near the query, a recording Core.Audit): validation and caps, listener selection (range +
    20 m, the stay band, bucket, loaded, gated speakers, the talker excluded, the nearest MaxListeners), the diffs
    and their events, the 1 m speaker re-send, removed speakers, drops, owner stop, stop rights, the 'no_voice'
    report, audit rows, onEnd, the 500 ms loop that exists only while a session exists.
    Client (a stub client VM with recording audio / Mumble natives): the pool (create → output → volumes, in that
    order), override + submix ONCE per session, the pan maths (front / right / behind / left / yaw / distance /
    occlusion / summed speakers), gains pushed only on change, the pan loop only while needed, the volume-only
    fallback, unlisten restoring -1, the adapters (pma-voice, raw, custom) and their re-apply, 'no_voice', the
    pma-voice repair, core stop. Exit 1 on failure.
]]

local here = (arg and arg[0] or 'tests/scene_voice_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test files
local H = dofile(here .. '/scene_server_harness.lua')
H.name = 'scene voice'
local stubs, check, eq, near = H.stubs, H.check, H.eq, H.near

local S0 = { x = 100.0, y = 200.0, z = 30.0 }       -- the first speaker
local function at(dx, dy, dz) return { x = S0.x + (dx or 0), y = S0.y + (dy or 0), z = S0.z + (dz or 0) } end
local function errOf(...) return select(2, ...) end

--------------------------------------------------------------------------------
-- server harness
--------------------------------------------------------------------------------

--- A scene server VM with server/scene_voice.lua loaded -> env, Core, R, fx = { grid calls, audits }.
local function server(config)
    local env, Core, R = H.newServer({ config = config })
    local fx = { gridCalls = 0, audits = {} }
    local function posOf(src)
        local ped = stubs.peds[src]
        return ped and stubs.coords[ped] or nil
    end
    Core.PlayerGrid = {
        -- every connected player within the query box + 64 m (the real grid's slack): never exact
        candidates = function(coords, range, out)
            fx.gridCalls = fx.gridCalls + 1
            local n = 0
            for _, src in ipairs(stubs.connected) do
                local c = posOf(src)
                if c and math.abs(c.x - coords.x) <= range + 64 and math.abs(c.y - coords.y) <= range + 64 then
                    n = n + 1
                    out[n] = src
                end
            end
            return n
        end,
        positionOf = function(src)
            local c = posOf(src)
            if not c then return nil end
            return c.x, c.y, c.z, 0
        end,
    }
    Core.Audit = { record = function(row)
        fx.audits[#fx.audits + 1] = row
        return tostring(#fx.audits)
    end }
    stubs.loadFile(env, 'server/scene_voice.lua')
    stubs.sent = {}
    return env, Core, R, fx
end

--- Client events sent since the last clear: name (+ target) filtered, in order.
local function sent(name, target)
    local out = {}
    for _, e in ipairs(stubs.sent) do
        if e.side == 'client' and e.name == name and (target == nil or e.target == target) then out[#out + 1] = e end
    end
    return out
end
local function targetsOf(name)
    local out = {}
    for _, e in ipairs(sent(name)) do out[#out + 1] = e.target end
    table.sort(out)
    return table.concat(out, ',')
end
local function clear() stubs.sent = {} end
local function list(t)
    local parts = {}
    for i = 1, #t do parts[i] = tostring(t[i]) end
    return table.concat(parts, ',')
end
--- Ends every session of a finished block, so its 500 ms loop stops (the virtual clock is shared by every VM).
local function done(Core)
    local voice = Core.Scene.voice
    for _, s in ipairs(voice.list()) do voice.stop(s.id) end
    stubs.tick(500)
    clear()
end
local function speaker(Core, pos, extra)
    local def = { kind = 'group', pos = pos }
    for k, v in pairs(extra or {}) do def[k] = v end
    local id, err = Core.Scene.spawn(def)
    assert(id, 'speaker spawn failed: ' .. tostring(err))
    return id
end

--------------------------------------------------------------------------------
-- server: validation, caps, delegate
--------------------------------------------------------------------------------
do
    local env, Core, R = server(function(Config) Config.Scene.Voice.MaxSessions = 2 end)
    local Scene = Core.Scene
    check(type(R.voice) == 'table' and R.voice.start and R.voice.stop and R.voice.list, 'R.voice is filled')
    H.player(env, 1, at(0, 0, 0))
    H.player(env, 2, at(5, 0, 0))
    H.player(env, 3, at(9, 0, 0))
    H.unloaded[99] = true
    local sp = speaker(Core, S0)
    local function err(def) return errOf(Scene.voice.start(def)) end
    eq(err(nil), 'def', 'start(nil) → def')
    eq(err({ talker = 99, speakers = { sp } }), 'talker', 'an unloaded talker → talker')
    eq(err({ talker = 0, speakers = { sp } }), 'talker', 'talker 0 → talker')
    eq(err({ talker = 1, speakers = { sp }, fx = 'loud' }), 'fx', 'an unknown fx → fx')
    eq(err({ talker = 1, speakers = { sp }, range = 0 }), 'range', 'range 0 → range')
    eq(err({ talker = 1, speakers = { sp }, range = 601 }), 'range', 'range 601 → range')
    eq(err({ talker = 1, speakers = { sp }, range = 0 / 0 }), 'range', 'range NaN → range')
    eq(err({ talker = 1, speakers = { sp }, range = '60' }), 'range', 'range as a string → range')
    eq(err({ talker = 1, speakers = {} }), 'speakers', 'no speakers → speakers')
    eq(err({ talker = 1, speakers = 'x' }), 'speakers', 'speakers not a table → speakers')
    eq(err({ talker = 1, speakers = { sp, sp } }), 'speakers', 'a duplicate speaker → speakers')
    eq(err({ talker = 1, speakers = { 1.5 } }), 'speakers', 'a fractional id → speakers')
    local many = {}
    for i = 1, 33 do many[i] = i end
    eq(err({ talker = 1, speakers = many }), 'speakers', '33 speakers → speakers')
    eq(err({ talker = 1, speakers = { 999999 } }), 'missing', 'an unknown node → missing')
    local source = Scene.spawn({ kind = 'audio.source', fields = { file = '@a/b.ogg' } })
    check(source ~= nil, 'an audio.source node exists')
    eq(err({ talker = 1, speakers = { source } }), 'missing', 'a dependency node (no pose) → missing')
    local far = speaker(Core, S0, { bucket = 3 })
    eq(err({ talker = 1, speakers = { sp, far } }), 'bucket', 'speakers in two buckets → bucket')
    eq(err({ talker = 1, speakers = { sp }, onEnd = 5 }), 'def', 'onEnd not callable → def')
    eq(#Scene.voice.list(), 0, 'no session after refusals')
    check(#stubs.sent == 0, 'refusals send nothing')

    local id = Scene.voice.start({ talker = 1, speakers = { sp }, fx = 'megaphone', range = 40 })
    check(math.type(id) == 'integer' and id >= 1, 'start → an integer session id')
    eq(err({ talker = 1, speakers = { sp } }), 'busy', 'a second session of the same talker → busy')
    local id2 = Scene.voice.start({ talker = 2, speakers = { sp } })
    check(math.type(id2) == 'integer' and id2 ~= id, 'a second talker gets his own session')
    eq(err({ talker = 3, speakers = { sp } }), 'limit', 'MaxSessions (2) → limit')
    local l = Scene.voice.list()
    eq(#l, 2, 'list() has both sessions')
    eq(l[1].id, id, 'list() in start order')
    eq(l[1].owner, 'core', 'the owner is the caller (core)')
    eq(l[1].talker, 1, 'list() talker')
    eq(l[1].fx, 'megaphone', 'list() fx')
    eq(l[1].range, 40.0, 'list() range')
    eq(l[1].bucket, 0, 'list() bucket = the speakers\' bucket')
    eq(list(l[1].speakers), tostring(sp), 'list() speakers (a copy)')
    l[1].speakers[1] = 12345
    eq(Scene.voice.list()[1].speakers[1], sp, 'list() copies cannot change a session')
    eq(Scene.voice.list()[2].fx, 'none', 'fx defaults to none')
    eq(Scene.voice.list()[2].range, 60.0, 'range defaults to 60')
    local st = R.voice.stats()
    eq(st.sessions, 2, 'stats().sessions')
    eq(st.listeners, 4, 'stats().listeners: 2 + 3 hear talker 1, 1 + 3 hear talker 2')
    done(Core)
end

--------------------------------------------------------------------------------
-- server: listener selection, events, audit
--------------------------------------------------------------------------------
do
    local env, Core, R, fx = server()
    local Scene = Core.Scene
    local sp = speaker(Core, S0)
    H.player(env, 1, at(1, 0, 0))                     -- the talker, right at the speaker
    H.player(env, 2, at(30, 0, 0))                    -- 30 m: a listener
    H.player(env, 3, at(0, 75, 0))                    -- 75 m < range 60 + 20: a listener
    H.player(env, 4, at(85, 0, 0))                    -- 85 m: in the stay band, never joins
    H.player(env, 5, at(10, 0, 0), 2)                 -- another bucket
    H.player(env, 6, at(12, 0, 0))                    -- not loaded
    H.unloaded[6] = true
    H.player(env, 7, at(0, 0, 200))                   -- 200 m above: out of range (3D distance)
    local id = Scene.voice.start({ talker = 1, speakers = { sp }, fx = 'pa', range = 60 })
    check(id ~= nil, 'the session starts')
    local t = sent('core:scene:voice:targets')
    eq(#t, 1, 'start: one targets event')
    eq(t[1].target, 1, 'targets go to the talker')
    eq(t[1].args[1], id, 'targets: the session id')
    eq(list(t[1].args[2]), '2,3', 'targets: add = the listeners, sorted')
    eq(#t[1].args[3], 0, 'targets: remove = {}')
    eq(targetsOf('core:scene:voice:listen'), '2,3', 'listen goes to each listener, nobody else')
    local e = sent('core:scene:voice:listen', 2)[1]
    eq(e.args[1], id, 'listen: session id')
    eq(e.args[2], 1, 'listen: the talker')
    eq(#e.args[3], 1, 'listen: one speaker')
    eq(e.args[3][1][1], sp, 'listen: speaker id')
    eq(e.args[3][1][2], 100.0, 'listen: speaker x')
    eq(e.args[3][1][3], 200.0, 'listen: speaker y')
    eq(e.args[3][1][4], 30.0, 'listen: speaker z')
    eq(e.args[4], 'pa', 'listen: fx')
    eq(e.args[5], 60.0, 'listen: range')
    eq(#fx.audits, 1, 'one audit row at start')
    eq(fx.audits[1].action, 'scene.voice.start', 'audit action scene.voice.start')
    eq(fx.audits[1].targets[1].id, 1, 'audit target = the talker')
    eq(fx.audits[1].ctx.session, id, 'audit ctx.session')
    eq(fx.audits[1].ctx.owner, 'core', 'audit ctx.owner')
    eq(Scene.voice.list()[1].listeners, 2, 'list() counts the listeners')
    eq(R.voice.stats().listeners, 2, 'stats().listeners')

    -- a quiet tick sends nothing
    clear()
    stubs.tick(500)
    eq(#stubs.sent, 0, 'nothing changed: the 500 ms tick sends nothing')
    local calls = fx.gridCalls
    stubs.tick(500)
    check(fx.gridCalls > calls, 'the loop queries the grid every 500 ms while the session exists')

    -- the stay band: 3 moves to 85 m (stays), 4 is still at 85 m (never joined); then 3 leaves past 90 m
    H.movePlayer(3, at(0, 85, 0))
    clear()
    stubs.tick(500)
    eq(#stubs.sent, 0, 'a listener in the stay band (85 m) stays; nobody joins there')
    H.movePlayer(3, at(0, 95, 0))
    stubs.tick(500)
    t = sent('core:scene:voice:targets', 1)
    eq(#t, 1, 'a listener past range + 30 m: the talker hears of it')
    eq(#t[1].args[2], 0, 'targets: add = {}')
    eq(list(t[1].args[3]), '3', 'targets: remove = { 3 }')
    eq(targetsOf('core:scene:voice:unlisten'), '3', 'unlisten goes to the removed listener')
    eq(sent('core:scene:voice:unlisten', 3)[1].args[1], id, 'unlisten: session id')

    -- a new listener comes within range + 20 m; a listener changes bucket; one unloads
    H.movePlayer(4, at(79, 0, 0))
    clear()
    stubs.tick(500)
    eq(targetsOf('core:scene:voice:listen'), '4', 'within range + 20 m: 4 joins')
    stubs.buckets[2] = 5
    clear()
    stubs.tick(500)
    eq(targetsOf('core:scene:voice:unlisten'), '2', 'a listener in another bucket leaves')
    H.unloaded[4] = true
    clear()
    stubs.tick(500)
    eq(targetsOf('core:scene:voice:unlisten'), '4', 'an unloaded listener leaves')
    eq(Scene.voice.list()[1].listeners, 0, 'no listener left')
    done(Core)
end

--------------------------------------------------------------------------------
-- server: MaxListeners, gated speakers, the talker excluded, cm payload
--------------------------------------------------------------------------------
do
    local env, Core = server(function(Config) Config.Scene.Voice.MaxListeners = 2 end)
    local Scene = Core.Scene
    local sp = speaker(Core, { x = 100.123456, y = 200.987654, z = 30.5 })
    H.player(env, 1, at(2, 0, 0))
    H.player(env, 2, at(30, 0, 0))
    H.player(env, 3, at(10, 0, 0))
    H.player(env, 4, at(20, 0, 0))
    local id = Scene.voice.start({ talker = 1, speakers = { sp } })
    eq(list(sent('core:scene:voice:targets', 1)[1].args[2]), '3,4', 'MaxListeners 2: the nearest two (10 m, 20 m)')
    local p = sent('core:scene:voice:listen', 3)[1].args[3][1]
    eq(p[2], 100.12, 'payload x rounded to cm')
    eq(p[3], 200.99, 'payload y rounded to cm')
    eq(p[4], 30.5, 'payload z')
    -- 4 walks off, 2 takes the free place
    H.movePlayer(4, at(0, 200, 0))
    clear()
    stubs.tick(500)
    local t = sent('core:scene:voice:targets', 1)[1]
    eq(list(t.args[2]) .. '|' .. list(t.args[3]), '2|4', 'a freed place goes to the next nearest')
    done(Core)
    -- a gated speaker: only players its audience allows hear it
    H.allows[3] = true
    local gated = speaker(Core, S0, { audience = { players = { 3 } } })
    clear()
    local id2 = Scene.voice.start({ talker = 1, speakers = { gated } })
    check(id2 ~= nil and id2 ~= id, 'a gated speaker is a valid speaker')
    eq(list(sent('core:scene:voice:targets', 1)[1].args[2]), '3', 'a gated speaker: only the allowed player')
    -- a public speaker next to it lets everybody in again
    done(Core)
    Scene.voice.start({ talker = 1, speakers = { gated, sp } })
    eq(list(sent('core:scene:voice:targets', 1)[1].args[2]), '2,3',
        'public + gated: 3 (both) and 2 (public only) — 4 is gone, MaxListeners 2')
    done(Core)
end

--------------------------------------------------------------------------------
-- server: speaker movement (>= 1 m), removed speakers, onEnd
--------------------------------------------------------------------------------
do
    local env, Core, _, fx = server()
    local Scene = Core.Scene
    local a = speaker(Core, S0)
    local b = speaker(Core, at(40, 0, 0))
    H.player(env, 1, at(-30, 0, 0))
    H.player(env, 2, at(10, 0, 0))
    H.player(env, 3, at(95, 0, 0))                     -- 55 m from b only
    local ends = {}
    local id = Scene.voice.start({ talker = 1, speakers = { a, b }, fx = 'phone',
        onEnd = H.callable(function(sid, reason) ends[#ends + 1] = sid .. ':' .. reason end) })
    eq(targetsOf('core:scene:voice:listen'), '2,3', 'two speakers: the union of their listeners')
    eq(#sent('core:scene:voice:listen', 2)[1].args[3], 2, 'listen carries both speakers')
    Scene.move(a, at(0.6, 0, 0))
    clear()
    stubs.tick(500)
    eq(#stubs.sent, 0, 'a speaker moved 0.6 m: nothing re-sent')
    Scene.move(a, at(1.2, 0, 0))
    stubs.tick(500)
    eq(targetsOf('core:scene:voice:listen'), '2,3', 'moved 1.2 m in all: every listener gets the new poses')
    eq(sent('core:scene:voice:listen', 2)[1].args[3][1][2], 101.2, 'the new pose')
    eq(#sent('core:scene:voice:targets'), 0, 'a pose update does not touch the talker')
    clear()
    stubs.tick(500)
    eq(#stubs.sent, 0, 'the next tick is quiet again (poses measured from the last send)')
    Scene.remove(b)
    stubs.tick(500)
    local u = sent('core:scene:voice:unlisten')
    eq(#u, 1, 'speaker b removed: 3 (55 m from b, 94 m from a) leaves')
    eq(u[1].target, 3, 'the unlisten goes to 3')
    local l2 = sent('core:scene:voice:listen', 2)
    eq(#l2, 1, 'the remaining listener gets the shorter speaker list')
    eq(#l2[1].args[3], 1, 'one speaker left')
    eq(l2[1].args[3][1][1], a, 'speaker a')
    eq(list(Scene.voice.list()[1].speakers), tostring(a), 'list() drops the removed speaker')
    clear()
    Scene.remove(a)
    stubs.tick(500)
    eq(#Scene.voice.list(), 0, 'every speaker removed: the session ends')
    eq(targetsOf('core:scene:voice:unlisten'), '2', 'the last listener unlistens')
    local t = sent('core:scene:voice:targets', 1)
    eq(#t, 1, 'the talker drops his listeners')
    eq(list(t[1].args[3]), '2', 'targets remove = the listeners')
    eq(list(ends), id .. ':speakers', 'onEnd(sessionId, speakers)')
    local last = fx.audits[#fx.audits]
    eq(last.action, 'scene.voice.stop', 'audit row scene.voice.stop')
    eq(last.reason, 'speakers', 'audit reason speakers')
    eq(last.ctx.peak, 2, 'audit ctx.peak = the most listeners at once')
    local calls = fx.gridCalls
    stubs.tick(2000)
    eq(fx.gridCalls, calls, 'no session: the loop is gone (no grid query in 2 s)')
end

--------------------------------------------------------------------------------
-- server: drops, unloaded talker, owner stop, stop rights, the no_voice report
--------------------------------------------------------------------------------
do
    local env, Core, R, fx = server()
    local Scene = Core.Scene
    local sp = speaker(Core, S0)
    H.player(env, 1, at(0, 0, 0))
    H.player(env, 2, at(10, 0, 0))
    H.player(env, 3, at(20, 0, 0))
    H.player(env, 4, at(30, 0, 0))
    local ends = {}
    local onEnd = H.callable(function(sid, reason) ends[#ends + 1] = sid .. ':' .. reason end)
    local id = Scene.voice.start({ talker = 1, speakers = { sp }, onEnd = onEnd })
    clear()
    stubs.dropPlayer(env, 2)
    local t = sent('core:scene:voice:targets', 1)
    eq(#t, 1, 'a dropped listener: the talker hears of it at once')
    eq(list(t[1].args[3]), '2', 'targets remove = { 2 }')
    eq(#sent('core:scene:voice:unlisten'), 0, 'no unlisten to the dropped player')
    eq(Scene.voice.list()[1].listeners, 2, 'two listeners left')
    clear()
    stubs.dropPlayer(env, 1)
    eq(#Scene.voice.list(), 0, 'a dropped talker ends the session')
    eq(targetsOf('core:scene:voice:unlisten'), '3,4', 'every listener unlistens')
    eq(#sent('core:scene:voice:targets'), 0, 'nothing goes to the dropped talker')
    eq(list(ends), id .. ':dropped', 'onEnd(sessionId, dropped)')
    eq(fx.audits[#fx.audits].reason, 'dropped', 'audit reason dropped')

    -- an unloaded talker (still connected): his client drops the listeners
    H.player(env, 5, at(1, 0, 0))
    local id2 = Scene.voice.start({ talker = 5, speakers = { sp } })
    H.unloaded[5] = true
    clear()
    stubs.tick(500)
    eq(#Scene.voice.list(), 0, 'an unloaded talker ends the session at the next tick')
    eq(list(sent('core:scene:voice:targets', 5)[1].args[3]), '3,4', 'the unloaded talker drops his listeners')
    eq(fx.audits[#fx.audits].reason, 'talker', 'audit reason talker')
    check(id2 ~= id, 'ids are not reused')
    H.unloaded[5] = nil

    -- owner rules and owner stop
    ends = {}
    local pid = H.as('radio', 'voice.start', { talker = 3, speakers = { sp }, onEnd = onEnd })
    check(math.type(pid) == 'integer', 'a plugin starts a session through the proxy')
    eq(Scene.voice.list()[1].owner, 'radio', 'the plugin owns it')
    local ok, err = H.as('other', 'voice.stop', pid)
    check(ok == false and err == 'owner', 'another resource cannot stop it')
    eq(fx.audits[#fx.audits].action, 'scene.voice.start', 'a refused stop writes no audit row')
    clear()
    H.stop(env, 'radio')
    eq(#Scene.voice.list(), 0, 'the owner stopped: its session ends')
    eq(targetsOf('core:scene:voice:unlisten'), '4,5', 'its listeners unlisten')
    eq(#ends, 0, 'no onEnd for a stopped owner')
    eq(fx.audits[#fx.audits].reason, 'owner', 'audit reason owner')
    local pid2 = H.as('radio', 'voice.start', { talker = 3, speakers = { sp }, onEnd = onEnd })
    eq(H.as('radio', 'voice.stop', pid2), true, 'the owner stops its own session')
    eq(#ends, 0, 'no onEnd for stop()')
    eq(fx.audits[#fx.audits].reason, 'stopped', 'audit reason stopped')
    local cid = H.as('radio', 'voice.start', { talker = 3, speakers = { sp } })
    eq(Scene.voice.stop(cid), true, 'core may stop any session')
    local ok2, err2 = Scene.voice.stop(cid)
    check(ok2 == false and err2 == 'missing', 'a second stop → missing')

    -- the no_voice report: only the talker of that session, only the known code
    ends = {}
    local vid = Scene.voice.start({ talker = 3, speakers = { sp }, onEnd = onEnd })
    stubs.triggerOn(env, 'core:scene:voice:report', 4, vid, 'no_voice')
    eq(#Scene.voice.list(), 1, 'a report from another player is ignored')
    stubs.triggerOn(env, 'core:scene:voice:report', 3, vid, 'bogus')
    eq(#Scene.voice.list(), 1, 'an unknown code fails the schema')
    stubs.tick(1000)
    stubs.triggerOn(env, 'core:scene:voice:report', 3, vid + 1000, 'no_voice')
    eq(#Scene.voice.list(), 1, 'an unknown session is ignored')
    stubs.tick(1000)
    clear()
    stubs.triggerOn(env, 'core:scene:voice:report', 3, vid, 'no_voice')
    eq(#Scene.voice.list(), 0, 'the talker\'s no_voice ends the session')
    eq(list(ends), vid .. ':no_voice', 'onEnd(sessionId, no_voice)')
    eq(fx.audits[#fx.audits].reason, 'no_voice', 'audit reason no_voice')
    eq(R.voice.stats().sessions, 0, 'stats(): no session')
end

--------------------------------------------------------------------------------
-- client harness: a core client VM with recording audio / Mumble natives and a fake CoreSceneRuntime
--------------------------------------------------------------------------------

--- opts = { pma = bool, connected = bool (default true), submixLimit = first id refused (default 40),
---         nativeAudio = false, config = fn(Config), keepWorld = bool, src = this client's server id (1) }
---   -> h = { env, log, cam(x, y, z, yaw), nodes, handles, occ, convars, V, fire(name, ...), calls, n, index, vols }
local function client(opts)
    opts = opts or {}
    if not opts.keepWorld then                       -- keepWorld: join the world of a server VM (end to end)
        stubs.newWorld()
        stubs.clear()
    end
    stubs.resourceStates = { core = 'started', ['pma-voice'] = opts.pma and 'started' or nil }
    stubs.vitals.connected = opts.connected ~= false
    stubs.clientSrc = opts.src or 1
    local env = stubs.newEnv('client', 'core')
    stubs.loadFile(env, 'import.lua')
    stubs.loadFile(env, 'shared/config.lua')
    if opts.config then opts.config(env.Config) end
    local h = { env = env, log = {}, nodes = {}, handles = {}, occ = {} }
    local function rec(name, ...) h.log[#h.log + 1] = table.pack(name, ...) end
    local nextId, limit = 28, opts.submixLimit or 40
    env.CreateAudioSubmix = function(name)
        rec('CreateAudioSubmix', name)
        if nextId >= limit then return -1 end
        nextId = nextId + 1
        h.log[#h.log].id = nextId - 1
        return nextId - 1
    end
    for _, name in ipairs({ 'AddAudioSubmixOutput', 'SetAudioSubmixOutputVolumes', 'SetAudioSubmixEffectRadioFx',
        'SetAudioSubmixEffectParamInt', 'SetAudioSubmixEffectParamFloat', 'MumbleSetVolumeOverrideByServerId',
        'MumbleSetSubmixForServerId', 'MumbleAddVoiceTargetPlayerByServerId',
        'MumbleRemoveVoiceTargetPlayerByServerId' }) do
        env[name] = function(...) rec(name, ...) end
    end
    h.convars = { voice_useNativeAudio = opts.nativeAudio == false and 'false' or 'true' }
    env.GetConvar = function(name, default) return h.convars[name] or default end
    local camC, camR = stubs.vector3(0.0, 0.0, 0.0), stubs.vector3(0.0, 0.0, 0.0)
    env.GetFinalRenderedCamCoord = function() rec('GetFinalRenderedCamCoord') return camC end
    env.GetFinalRenderedCamRot = function(order)
        rec('GetFinalRenderedCamRot', order)
        return camR
    end
    function h.cam(x, y, z, yaw) camC.x, camC.y, camC.z, camR.z = x + 0.0, y + 0.0, z + 0.0, (yaw or 0) + 0.0 end
    env.CoreSceneRuntime = {
        mat = { handleOf = function(id) return h.handles[id] end },
        cache = { node = function(id) return h.nodes[id] end },
        audio = { occlusionOf = function(id) return h.occ[id] end },
    }
    stubs.loadFile(env, 'client/scene_voice.lua')
    h.V = env.CoreSceneRuntime.voice
    function h.fire(name, ...) stubs.triggerOn(env, name, 0, ...) end
    --- The recorded calls of `name` (optionally only those whose first argument is `a1`).
    function h.calls(name, a1)
        local out = {}
        for _, c in ipairs(h.log) do
            if c[1] == name and (a1 == nil or c[2] == a1) then out[#out + 1] = c end
        end
        return out
    end
    function h.n(name, a1) return #h.calls(name, a1) end
    function h.index(name, a1)
        for i, c in ipairs(h.log) do
            if c[1] == name and (a1 == nil or c[2] == a1) then return i end
        end
        return nil
    end
    --- The last output volumes of `submix`: fl, fr, rl, rr, c, lfe (and the slot).
    function h.vols(submix)
        local c = h.calls('SetAudioSubmixOutputVolumes', submix)
        c = c[#c]
        if not c then return nil end
        return c[4], c[5], c[6], c[7], c[8], c[9], c[3]
    end
    return h
end

local R2 = math.sqrt(0.5)
local function spk(id, x, y, z) return { id, x + 0.0, y + 0.0, z + 0.0 } end

--------------------------------------------------------------------------------
-- client: the pool, the ONCE rule, the pan loop
--------------------------------------------------------------------------------
do
    local h = client()
    eq(h.n('CreateAudioSubmix'), 8, 'Voice.Submixes (8) submixes created at start')
    eq(h.calls('CreateAudioSubmix')[1][2], 'core_vs_1', 'named core_vs_<n>')
    eq(h.calls('CreateAudioSubmix')[8][2], 'core_vs_8', 'the last is core_vs_8')
    local orderOk, slotOk = true, true
    for _, c in ipairs(h.calls('CreateAudioSubmix')) do
        local id = c.id
        local iCreate, iOut, iVol = nil, h.index('AddAudioSubmixOutput', id), h.index('SetAudioSubmixOutputVolumes', id)
        for i, e in ipairs(h.log) do if e == c then iCreate = i end end
        if not (iCreate and iOut and iVol and iCreate < iOut and iOut < iVol) then orderOk = false end
        local out = h.calls('AddAudioSubmixOutput', id)
        if #out ~= 1 or out[1][3] ~= 0 then slotOk = false end
    end
    check(orderOk, 'every submix: CreateAudioSubmix → AddAudioSubmixOutput → SetAudioSubmixOutputVolumes (R2 §B8)')
    check(slotOk, 'every submix: exactly one output, to the master (0)')
    eq(h.n('SetAudioSubmixEffectRadioFx'), 8, 'RadioFX installed once per submix')
    eq(h.n('GetFinalRenderedCamCoord'), 0, 'idle: no camera read')
    eq(h.n('MumbleSetVolumeOverrideByServerId'), 0, 'idle: no Mumble call')
    local st = h.V.stats()
    check(st.pool == 8 and st.free == 8 and st.heard == 0, 'stats(): 8 free submixes, nothing heard')

    -- listen: preset, first gains BEFORE the voice is routed, then override + submix ONCE
    h.cam(0, 0, 0, 0)
    local mark = #h.log
    h.fire('core:scene:voice:listen', 11, 7, { spk(501, 0, 5, 0) }, 'megaphone', 60.0)
    local iVol, iOv, iSub = nil, nil, nil
    for i = mark + 1, #h.log do
        local c = h.log[i]
        if c[1] == 'SetAudioSubmixOutputVolumes' and not iVol then iVol = i end
        if c[1] == 'MumbleSetVolumeOverrideByServerId' then iOv = i end
        if c[1] == 'MumbleSetSubmixForServerId' then iSub = i end
    end
    check(iVol and iOv and iSub and iVol < iOv and iVol < iSub, 'listen: gains set before the voice is routed in')
    local ov = h.calls('MumbleSetVolumeOverrideByServerId', 7)
    eq(#ov, 1, 'listen: one override for the talker')
    eq(ov[1][3], 1.0, 'override 1.0')
    local sub = h.calls('MumbleSetSubmixForServerId', 7)
    eq(#sub, 1, 'listen: one submix assignment')
    eq(sub[1][3], 28, 'the first pool submix (28)')
    local fl, fr, rl, rr, c, lfe, slot = h.vols(28)
    eq(slot, 0, 'volumes on output slot 0')
    near(fl, R2, 1e-6, 'front speaker at 5 m: fl = 0.707')
    near(fr, R2, 1e-6, 'front: fr = 0.707')
    near(rl, 0, 1e-6, 'front: rl = 0')
    near(rr, 0, 1e-6, 'front: rr = 0')
    near(c, R2, 1e-6, 'centre mirrors min(fl, fr)')
    eq(lfe, 0.0, 'lfe 0')
    local fxInt = h.calls('SetAudioSubmixEffectParamInt', 28)
    eq(fxInt[#fxInt][4], h.env.GetHashKey('default'), 'megaphone: the `default` parameter')
    eq(fxInt[#fxInt][5], 1, 'megaphone: the default preset switched on')
    local floats = {}
    for _, e in ipairs(h.calls('SetAudioSubmixEffectParamFloat', 28)) do floats[#floats + 1] = e[5] end
    eq(table.concat(floats, ','), '400.0,3500.0,400.0,3500.0,3.0', 'megaphone: band 400–3500 Hz + fudge 3')

    -- the pan loop: turning the camera changes the gains, never the routing
    local vols = h.n('SetAudioSubmixOutputVolumes', 28)
    stubs.tick(1000)
    eq(h.n('SetAudioSubmixOutputVolumes', 28), vols, 'a still camera: no volume call (unchanged gains)')
    check(h.n('GetFinalRenderedCamCoord') >= 14, 'the pan loop reads the camera at ~15 Hz')
    h.cam(0, 0, 0, 90)                    -- looking west (-x): the speaker (+y) is on the right
    stubs.tick(100)
    fl, fr, rl, rr = h.vols(28)
    near(fr, R2, 1e-6, 'yaw 90: the speaker is right → fr')
    near(rr, R2, 1e-6, 'yaw 90: rr')
    near(fl, 0, 1e-6, 'yaw 90: fl 0')
    near(rl, 0, 1e-6, 'yaw 90: rl 0')
    for i = 1, 30 do
        h.cam(0, 0, 0, i * 12)
        stubs.tick(70)
    end
    check(h.n('SetAudioSubmixOutputVolumes', 28) > vols + 20, 'a turning camera: volumes follow')
    eq(h.n('MumbleSetVolumeOverrideByServerId', 7), 1, 'after 2 s of panning: still ONE override call')
    eq(h.n('MumbleSetSubmixForServerId', 7), 1, 'after 2 s of panning: still ONE submix call')
    -- a second listen of the same session (a speaker moved) updates the poses only
    h.cam(0, 0, 0, 0)
    h.fire('core:scene:voice:listen', 11, 7, { spk(501, 0, -5, 0) }, 'megaphone', 60.0)
    stubs.tick(100)
    fl, fr, rl, rr = h.vols(28)
    check(math.abs(rl - R2) < 1e-6 and math.abs(rr - R2) < 1e-6 and fl < 1e-6 and fr < 1e-6,
        'the moved speaker (now behind) is panned rear')
    eq(h.n('MumbleSetVolumeOverrideByServerId', 7), 1, 'a pose update never routes again (override)')
    eq(h.n('MumbleSetSubmixForServerId', 7), 1, 'a pose update never routes again (submix)')

    -- unlisten: -1 / -1.0, the submix back to the pool, the loop gone
    h.fire('core:scene:voice:unlisten', 11)
    local s2 = h.calls('MumbleSetSubmixForServerId', 7)
    eq(s2[#s2][3], -1, 'unlisten: submix -1')
    local o2 = h.calls('MumbleSetVolumeOverrideByServerId', 7)
    eq(o2[#o2][3], -1.0, 'unlisten: override -1.0')
    stubs.tick(200)
    local reads = h.n('GetFinalRenderedCamCoord')
    stubs.tick(2000)
    eq(h.n('GetFinalRenderedCamCoord'), reads, 'nothing heard: the pan loop is gone')
    eq(h.V.stats().free, 8, 'the submix is free again')
    h.fire('core:scene:voice:listen', 12, 8, { spk(501, 0, 5, 0) }, 'none', 60.0)
    eq(h.calls('MumbleSetSubmixForServerId', 8)[1][3], 28, 'the freed submix is reused')
    local ints = h.calls('SetAudioSubmixEffectParamInt', 28)
    eq(ints[#ints][4], h.env.GetHashKey('enabled'), 'fx none: the `enabled` parameter')
    eq(ints[#ints][5], 0, 'fx none: RadioFX switched off on the reused submix')
    h.fire('core:scene:voice:unlisten', 12)
end

--------------------------------------------------------------------------------
-- client: pan maths (the first gains of a listen)
--------------------------------------------------------------------------------
do
    local h = client()
    local sid = 100
    --- listen to one talker with `speakers`, camera at the origin looking along `yaw` -> fl, fr, rl, rr, c
    local function gainsFor(speakers, yaw, range, cam)
        sid = sid + 1
        h.cam(cam and cam[1] or 0, cam and cam[2] or 0, cam and cam[3] or 0, yaw or 0)
        h.fire('core:scene:voice:listen', sid, 200 + sid, speakers, 'none', range or 60.0)
        local sub = h.calls('MumbleSetSubmixForServerId', 200 + sid)[1][3]
        local fl, fr, rl, rr, c = h.vols(sub)
        h.fire('core:scene:voice:unlisten', sid)
        return fl, fr, rl, rr, c
    end
    local function quad(label, want, ...)
        local got = { ... }
        local ok = true
        for i = 1, 4 do if math.abs(got[i] - want[i]) > 1e-4 then ok = false end end
        check(ok, ('%s (expected %.4f %.4f %.4f %.4f, got %.4f %.4f %.4f %.4f)'):format(label, want[1], want[2],
            want[3], want[4], got[1], got[2], got[3], got[4]))
    end
    quad('front (0, 5): fl = fr', { R2, R2, 0, 0 }, gainsFor({ spk(1, 0, 5, 0) }))
    quad('right (5, 0): fr = rr', { 0, R2, 0, R2 }, gainsFor({ spk(1, 5, 0, 0) }))
    quad('behind (0, -5): rl = rr', { 0, 0, R2, R2 }, gainsFor({ spk(1, 0, -5, 0) }))
    quad('left (-5, 0): fl = rl', { R2, 0, R2, 0 }, gainsFor({ spk(1, -5, 0, 0) }))
    quad('yaw 90 (looking -x): (-5, 0) is ahead', { R2, R2, 0, 0 }, gainsFor({ spk(1, -5, 0, 0) }, 90))
    quad('yaw 180 (looking -y): (0, 5) is behind', { 0, 0, R2, R2 }, gainsFor({ spk(1, 0, 5, 0) }, 180))
    quad('straight above: centred front', { R2, R2, 0, 0 }, gainsFor({ spk(1, 0, 0.2, 4) }))
    quad('the camera position counts', { 0, R2, 0, R2 }, gainsFor({ spk(1, 50, 50, 0) }, 0, 60, { 47, 50, 0 }))
    local g10 = 10 ^ (-14 / 20)
    quad('10 m: −14 dB (the game table)', { g10 * R2, g10 * R2, 0, 0 }, gainsFor({ spk(1, 0, 10, 0) }))
    local g30 = 10 ^ ((-31 + (-18) * 0.5) / 20)
    quad('30 m: −40 dB (interpolated 20 → 40 m)', { g30 * R2, g30 * R2, 0, 0 }, gainsFor({ spk(1, 0, 30, 0) }))
    local w = math.cos(math.pi / 2 * (7 / 12)) ^ 2
    local g55 = 10 ^ ((-49 + (-13) * (15 / 24)) / 20) * w
    quad('55 m of range 60: the cos² window', { g55 * R2, g55 * R2, 0, 0 }, gainsFor({ spk(1, 0, 55, 0) }))
    quad('at the range: silent', { 0, 0, 0, 0 }, gainsFor({ spk(1, 0, 60, 0) }))
    quad('a short range cuts earlier', { 0, 0, 0, 0 }, gainsFor({ spk(1, 0, 10, 0) }, 0, 10.0))
    local g110 = 10 ^ (-76 / 20) * (1 - 10 / 28)
    quad('110 m of range 600: past the table, linear to 128 m', { g110 * R2, g110 * R2, 0, 0 },
        gainsFor({ spk(1, 0, 110, 0) }, 0, 600.0))
    quad('two front speakers: energies summed, clamped to 1', { 1, 1, 0, 0 },
        gainsFor({ spk(1, 0, 5, 0), spk(2, 0, 4, 0) }))
    quad('left + right speakers: every channel', { R2, R2, R2, R2 }, gainsFor({ spk(1, -5, 0, 0), spk(2, 5, 0, 0) }))
    local sum = math.sqrt(0.5 + 0.5 * g10 * g10)
    quad('a near and a far speaker ahead: power sum', { sum, sum, 0, 0 },
        gainsFor({ spk(1, 0, 5, 0), spk(2, 0, 10, 0) }))
    h.occ[1] = 1.0
    local o = 10 ^ (-15 / 20)
    quad('occlusion 1: −15 dB', { o * R2, o * R2, 0, 0 }, gainsFor({ spk(1, 0, 5, 0) }))
    h.occ[1] = 0.5
    local o5 = 10 ^ (-7.5 / 20)
    quad('occlusion 0.5: −7.5 dB', { o5 * R2, o5 * R2, 0, 0 }, gainsFor({ spk(1, 0, 5, 0) }))
    h.occ[1] = nil
    -- a moving speaker materialised here is read from its entity (the server's pose is stale)
    h.nodes[1] = { motion = { t = 'path' }, parent = 0 }
    h.handles[1] = 9001
    stubs.coords[9001] = stubs.vector3(5.0, 0.0, 0.0)
    quad('a moving speaker: its entity (right), not the server pose (front)', { 0, R2, 0, R2 },
        gainsFor({ spk(1, 0, 5, 0) }))
    h.nodes[1] = { parent = 0 }
    quad('a static speaker: the server pose even when materialised', { R2, R2, 0, 0 }, gainsFor({ spk(1, 0, 5, 0) }))
    h.nodes[1] = { parent = 77 }
    quad('a child node counts as moving', { 0, R2, 0, R2 }, gainsFor({ spk(1, 0, 5, 0) }))
    h.nodes[1], h.handles[1] = nil, nil
end

--------------------------------------------------------------------------------
-- client: no free submix → volume only; bad payloads; an empty pool
--------------------------------------------------------------------------------
do
    local h = client({ submixLimit = 29 })                  -- the device hands out one submix (28)
    eq(h.V.stats().pool, 1, 'CreateAudioSubmix -1: the pool keeps what it got')
    h.cam(0, 0, 0, 0)
    h.fire('core:scene:voice:listen', 1, 5, { spk(1, 0, 5, 0) }, 'radio', 60.0)
    eq(h.calls('MumbleSetSubmixForServerId', 5)[1][3], 28, 'the first session takes the only submix')
    h.fire('core:scene:voice:listen', 2, 6, { spk(2, 0, 10, 0) }, 'radio', 60.0)
    eq(h.n('MumbleSetSubmixForServerId', 6), 0, 'no free submix: no submix assignment')
    local ov = h.calls('MumbleSetVolumeOverrideByServerId', 6)
    eq(#ov, 1, 'the fallback sets the override once')
    near(ov[1][3], 10 ^ (-14 / 20), 1e-6, 'the fallback volume = the summed gain of that moment (10 m: −14 dB)')
    eq(h.V.stats().panned, 1, 'only the submix session is panned')
    for i = 1, 20 do
        h.cam(i, 0, 0, i * 15)
        stubs.tick(70)
    end
    eq(h.n('MumbleSetVolumeOverrideByServerId', 6), 1, 'the fallback volume is never re-set while heard')
    h.fire('core:scene:voice:listen', 3, 9, { spk(3, 0, 59, 0) }, 'none', 60.0)
    eq(h.calls('MumbleSetVolumeOverrideByServerId', 9)[1][3], 0.1, 'the fallback volume is at least 0.1')
    h.fire('core:scene:voice:unlisten', 2)
    local last = h.calls('MumbleSetVolumeOverrideByServerId', 6)
    eq(last[#last][3], -1.0, 'fallback unlisten: override -1.0')
    eq(h.n('MumbleSetSubmixForServerId', 6), 0, 'fallback unlisten: no submix call')
    -- payloads the server never sends
    local before = h.n('MumbleSetVolumeOverrideByServerId')
    h.fire('core:scene:voice:listen', 20, 1, { spk(1, 0, 5, 0) }, 'none', 60.0)
    h.fire('core:scene:voice:listen', 21, 30, 'x', 'none', 60.0)
    h.fire('core:scene:voice:listen', 22, 31, { { 1, 0 / 0, 0, 0 } }, 'none', 60.0)
    h.fire('core:scene:voice:listen', 23, 32, {}, 'none', 60.0)
    h.fire('core:scene:voice:listen', 1.5, 33, { spk(1, 0, 5, 0) }, 'none', 60.0)
    eq(h.n('MumbleSetVolumeOverrideByServerId'), before,
        'refused: myself as the talker, speakers not a list, NaN, no speakers, a fractional id')
    h.fire('core:scene:voice:listen', 24, 34, { spk(1, 0, 5, 0) }, 'bogus', 1e9)
    eq(h.n('MumbleSetVolumeOverrideByServerId', 34), 1, 'an unknown fx / range falls back (none, 60 m)')
    -- one routing per talker: a new session of the same talker replaces the old one
    h.fire('core:scene:voice:listen', 25, 34, { spk(1, 0, 5, 0) }, 'none', 60.0)
    local o34 = h.calls('MumbleSetVolumeOverrideByServerId', 34)
    eq(#o34, 3, 'same talker, new session: the old one unrouted (-1), the new one routed')
    eq(o34[2][3], -1.0, 'the old session of that talker is unrouted first')
    eq(h.V.stats().heard, 3, 'heard: sessions 1, 3, 25')

    local plain = client({ nativeAudio = false })
    plain.fire('core:scene:voice:listen', 1, 5, { spk(1, 0, 5, 0) }, 'pa', 60.0)
    eq(plain.n('MumbleSetSubmixForServerId'), 0, 'no native audio: a submix would not route, none is assigned')
    eq(plain.V.stats().free, 8, 'no native audio: the pool stays free')
    eq(plain.calls('MumbleSetVolumeOverrideByServerId', 5)[1][3], 1.0, 'no native audio: volume only (5 m: 1.0)')
    plain.fire('core:scene:voice:unlisten', 1)

    local empty = client({ config = function(Config) Config.Scene.Voice.Submixes = 0 end })
    eq(empty.n('CreateAudioSubmix'), 0, 'Voice.Submixes = 0: no submix is created')
    empty.fire('core:scene:voice:listen', 1, 5, { spk(1, 0, 5, 0) }, 'pa', 60.0)
    eq(empty.n('MumbleSetSubmixForServerId'), 0, 'no pool: every session is volume only')
    eq(empty.n('MumbleSetVolumeOverrideByServerId', 5), 1, 'no pool: the override once')
    empty.fire('core:scene:voice:unlisten', 1)
end

--------------------------------------------------------------------------------
-- client: the talker's adapter (pma-voice, raw, custom), re-apply, no_voice
--------------------------------------------------------------------------------
do
    local h = client({ pma = true })
    eq(h.V.stats().adapter, 'pma-voice', 'pma-voice started: its adapter')
    h.fire('core:scene:voice:targets', 7, { 5, 6, 1 }, {})
    local adds = h.calls('MumbleAddVoiceTargetPlayerByServerId')
    eq(#adds, 2, 'two listeners added (myself never)')
    check(adds[1][2] == 1 and adds[1][3] == 5 and adds[2][3] == 6, 'pma-voice: whisper target 1')
    eq(h.V.stats().held, 2, 'two listeners held')
    stubs.tick(1000)
    eq(h.n('MumbleAddVoiceTargetPlayerByServerId'), 4, 're-applied after 1 s')
    stubs.tick(1000)
    eq(h.n('MumbleAddVoiceTargetPlayerByServerId'), 6, 're-applied every second')
    stubs.triggerOn(h.env, 'pma-voice:radioActive', 0, false)
    eq(h.n('MumbleAddVoiceTargetPlayerByServerId'), 8, 'pma-voice:radioActive(false): re-applied at once')
    stubs.triggerOn(h.env, 'pma-voice:radioActive', 0, true)
    eq(h.n('MumbleAddVoiceTargetPlayerByServerId'), 8, 'radioActive(true) changes nothing')
    h.fire('core:scene:voice:targets', 7, {}, { 5 })
    local rm = h.calls('MumbleRemoveVoiceTargetPlayerByServerId')
    check(#rm == 1 and rm[1][2] == 1 and rm[1][3] == 5, 'a removed listener leaves target 1')
    h.fire('core:scene:voice:targets', 8, { 6 }, {})
    eq(h.n('MumbleAddVoiceTargetPlayerByServerId'), 8, 'a listener held by two sessions is added once')
    h.fire('core:scene:voice:targets', 7, {}, { 6 })
    eq(h.n('MumbleRemoveVoiceTargetPlayerByServerId'), 1, 'still held by the other session: not removed')
    h.fire('core:scene:voice:targets', 8, {}, { 6 })
    eq(h.n('MumbleRemoveVoiceTargetPlayerByServerId'), 2, 'the last session let go: removed')
    eq(h.V.stats().held, 0, 'nothing held')
    local n = h.n('MumbleAddVoiceTargetPlayerByServerId')
    stubs.tick(3000)
    eq(h.n('MumbleAddVoiceTargetPlayerByServerId'), n, 'nothing held: the re-apply loop is gone')
    eq(#stubs.sent, 0, 'a connected talker never reports')

    local raw = client({ config = function(Config) Config.Scene.Voice.Target = 3 end })
    eq(raw.V.stats().adapter, 'raw', 'no pma-voice: the raw adapter')
    raw.fire('core:scene:voice:targets', 1, { 9 }, {})
    local ra = raw.calls('MumbleAddVoiceTargetPlayerByServerId')
    check(#ra == 1 and ra[1][2] == 3 and ra[1][3] == 9, 'raw: Voice.Target (3)')
    stubs.tick(1000)
    eq(raw.n('MumbleAddVoiceTargetPlayerByServerId'), 2, 'raw: re-applied every second')
    local got = {}
    local function note(sign) return H.callable(function(l) got[#got + 1] = sign .. table.concat(l, ',') end) end
    check(raw.V.setAdapter({ name = 'test', add = note('+'), remove = note('-') }), 'setAdapter accepts callables')
    eq(table.concat(got, ' '), '+9', 'a new adapter gets the held listeners at once')
    local rr = raw.calls('MumbleRemoveVoiceTargetPlayerByServerId')
    check(#rr == 1 and rr[1][2] == 3 and rr[1][3] == 9, '… after they left the old adapter\'s target')
    raw.fire('core:scene:voice:targets', 1, { 10 }, { 9 })
    eq(table.concat(got, ' '), '+9 +10 -9', 'the custom adapter hears adds and removes')
    eq(raw.V.stats().adapter, 'test', 'stats(): the custom adapter')
    local before = raw.n('MumbleAddVoiceTargetPlayerByServerId')
    stubs.tick(3000)
    eq(table.concat(got, ' '), '+9 +10 -9', 'a custom adapter is never re-applied')
    eq(raw.n('MumbleAddVoiceTargetPlayerByServerId'), before, '… and the natives stay untouched')
    check(raw.V.setAdapter({ add = 1 }) == false, 'setAdapter refuses non-callables')
    check(raw.V.setAdapter(nil), 'setAdapter(nil) restores the automatic choice')
    eq(table.concat(got, ' '), '+9 +10 -9 -10', 'the custom adapter hands its listeners back')
    local back = raw.calls('MumbleAddVoiceTargetPlayerByServerId')
    check(back[#back][2] == 3 and back[#back][3] == 10, 'the raw adapter takes them again')
    eq(raw.V.stats().adapter, 'raw', 'back to raw')
    raw.fire('core:scene:voice:targets', 1, {}, { 10 })

    local off = client({ connected = false })
    eq(off.V.stats().adapter, 'none', 'no voice connection: no adapter')
    off.fire('core:scene:voice:targets', 4, { 9 }, {})
    local rep = {}
    for _, e in ipairs(stubs.sent) do
        if e.side == 'server' and e.name == 'core:scene:voice:report' then rep[#rep + 1] = e end
    end
    eq(#rep, 1, 'no voice connection: one report')
    check(rep[1] and rep[1].args[1] == 4 and rep[1].args[2] == 'no_voice', 'report (sessionId, no_voice)')
    eq(off.n('MumbleAddVoiceTargetPlayerByServerId'), 0, 'no voice: nothing added')
    off.fire('core:scene:voice:targets', 4, { 11 }, {})
    local rep2 = 0
    for _, e in ipairs(stubs.sent) do if e.name == 'core:scene:voice:report' then rep2 = rep2 + 1 end end
    eq(rep2, 1, 'one report per session')
    off.fire('core:scene:voice:targets', 4, {}, { 9, 11 })
end

--------------------------------------------------------------------------------
-- client: the pma-voice repair, core stop
--------------------------------------------------------------------------------
do
    local h = client({ pma = true })
    h.cam(0, 0, 0, 0)
    h.fire('core:scene:voice:listen', 1, 7, { spk(1, 0, 5, 0) }, 'pa', 60.0)
    h.fire('core:scene:voice:listen', 2, 8, { spk(2, 0, 9, 0) }, 'pa', 60.0)
    local function routed(talker) return h.n('MumbleSetVolumeOverrideByServerId', talker) end
    stubs.triggerOn(h.env, 'pma-voice:setTalkingOnRadio', 0, 9, false)
    stubs.tick(400)
    eq(routed(7) + routed(8), 2, 'pma-voice reset a talker nobody hears here: no repair')
    stubs.triggerOn(h.env, 'pma-voice:setTalkingOnRadio', 0, 7, true)
    stubs.tick(400)
    eq(routed(7), 1, 'the talker talks on its radio: pma-voice routes him, no repair')
    stubs.triggerOn(h.env, 'pma-voice:setTalkingOnRadio', 0, 7, false)
    stubs.tick(200)
    eq(routed(7), 1, 'no repair before 300 ms (pma-voice restores the submix after 250 ms)')
    stubs.tick(200)
    eq(routed(7), 2, 'repair: the talker routed again (the same values)')
    eq(h.calls('MumbleSetSubmixForServerId', 7)[2][3], h.calls('MumbleSetSubmixForServerId', 7)[1][3],
        'repair: the same submix')
    eq(routed(8), 2, 'a repair pass re-routes every heard session (a no-op when untouched)')
    stubs.triggerOn(h.env, 'pma-voice:syncRadioData', 0, { [7] = true, [8] = false })
    stubs.tick(400)
    eq(routed(7), 2, 'syncRadioData: 7 talks on the radio — left to pma-voice')
    eq(routed(8), 3, 'syncRadioData: 8 repaired')
    stubs.triggerOn(h.env, 'pma-voice:removePlayerFromRadio', 0, 1)      -- myself: every partner reset
    stubs.tick(400)
    eq(routed(7), 3, 'removePlayerFromRadio(me): radio state cleared, every heard talker repaired')
    stubs.triggerOn(h.env, 'pma-voice:removePlayerFromCall', 0, 8)
    stubs.triggerOn(h.env, 'pma-voice:removePlayerFromCall', 0, 8)
    stubs.tick(400)
    eq(routed(8), 5, 'removePlayerFromCall: one repair for a burst')

    -- core stops: every heard talker unrouted, every held listener out of the voice target
    h.fire('core:scene:voice:targets', 3, { 21, 22 }, {})
    stubs.triggerOn(h.env, 'onClientResourceStop', 0, 'some_plugin')
    eq(h.n('MumbleRemoveVoiceTargetPlayerByServerId'), 0, 'another resource stopping changes nothing')
    stubs.triggerOn(h.env, 'onClientResourceStop', 0, 'core')
    eq(h.n('MumbleRemoveVoiceTargetPlayerByServerId'), 2, 'core stop: held listeners removed from target 1')
    local o7 = h.calls('MumbleSetVolumeOverrideByServerId', 7)
    local s8 = h.calls('MumbleSetSubmixForServerId', 8)
    check(o7[#o7][3] == -1.0 and s8[#s8][3] == -1, 'core stop: heard talkers unrouted (-1.0 / -1)')
    stubs.tick(100)                        -- the loops notice the stop within one wait
    local n = #h.log
    stubs.tick(3000)
    eq(#h.log, n, 'after core stop: no native call at all (pan and re-apply loops gone)')
    h.fire('core:scene:voice:listen', 9, 7, { spk(1, 0, 5, 0) }, 'pa', 60.0)
    h.fire('core:scene:voice:targets', 4, { 30 }, {})
    eq(#h.log, n, 'after core stop: late listen / targets events are ignored')
end

--------------------------------------------------------------------------------
-- end to end: the server VM and two client VMs on one event bus (the payload shapes both halves agree on)
--------------------------------------------------------------------------------
do
    local env, Core = server()
    local Scene = Core.Scene
    local voice = Scene.voice
    local sp = speaker(Core, S0)
    H.player(env, 1, at(1, 0, 0))
    H.player(env, 2, at(0, 10, 0))
    local talker = client({ keepWorld = true, src = 1, pma = true })
    local listener = client({ keepWorld = true, src = 2, pma = true })
    listener.cam(S0.x, S0.y + 10, S0.z, 180)           -- at the player, looking -y: the speaker 10 m ahead
    local id = voice.start({ talker = 1, speakers = { sp }, fx = 'phone', range = 60 })
    check(id ~= nil, 'e2e: the session starts')
    local add = talker.calls('MumbleAddVoiceTargetPlayerByServerId')
    check(#add == 1 and add[1][2] == 1 and add[1][3] == 2, 'e2e: the talker whispers to the listener on target 1')
    eq(#listener.calls('MumbleAddVoiceTargetPlayerByServerId'), 0, 'e2e: the listener adds nobody')
    local ov = listener.calls('MumbleSetVolumeOverrideByServerId', 1)
    check(#ov == 1 and ov[1][3] == 1.0, 'e2e: the listener overrides the talker once (1.0)')
    local sub = listener.calls('MumbleSetSubmixForServerId', 1)
    check(#sub == 1 and sub[1][3] == 28, 'e2e: into its first pool submix')
    local fl, fr, rl, rr = listener.vols(28)
    local g10 = 10 ^ (-14 / 20) * R2
    check(math.abs(fl - g10) < 1e-6 and math.abs(fr - g10) < 1e-6 and rl < 1e-6 and rr < 1e-6,
        'e2e: the speaker 10 m ahead: front, −14 dB')
    local ints = listener.calls('SetAudioSubmixEffectParamInt', 28)
    eq(ints[#ints][5], 1, 'e2e: the phone preset is on')
    eq(#talker.calls('MumbleSetVolumeOverrideByServerId'), 0, 'e2e: the talker never overrides himself')
    Scene.move(sp, at(-20, 10, 0))                 -- 20 m to the listener's right (looking -y: right = -x)
    stubs.tick(500)
    stubs.tick(100)
    fl, fr, rl, rr = listener.vols(28)
    local g20 = 10 ^ (-31 / 20) * R2
    check(fl < 1e-6 and rl < 1e-6 and math.abs(fr - g20) < 1e-6 and math.abs(rr - g20) < 1e-6,
        'e2e: the moved speaker is heard on the right, −31 dB')
    eq(#listener.calls('MumbleSetVolumeOverrideByServerId', 1), 1, 'e2e: the move never re-routes the talker')
    stubs.tick(1000)
    check(#talker.calls('MumbleAddVoiceTargetPlayerByServerId') == 2, 'e2e: the talker re-applied once in 1.6 s')
    eq(voice.stop(id), true, 'e2e: stop')
    local rm = talker.calls('MumbleRemoveVoiceTargetPlayerByServerId')
    check(#rm == 1 and rm[1][3] == 2, 'e2e: stop → the talker drops the listener')
    local sub2 = listener.calls('MumbleSetSubmixForServerId', 1)
    local ov2 = listener.calls('MumbleSetVolumeOverrideByServerId', 1)
    check(sub2[#sub2][3] == -1 and ov2[#ov2][3] == -1.0, 'e2e: stop → the listener restores the talker (-1)')
    eq(listener.V.stats().free, 8, 'e2e: the submix is back in the pool')
    -- the talker without a voice connection: his client reports, the server ends the session
    stubs.vitals.connected = false
    local ends = {}
    local id2 = voice.start({ talker = 1, speakers = { sp },
        onEnd = H.callable(function(sid, reason) ends[#ends + 1] = sid .. ':' .. reason end) })
    check(id2 ~= nil, 'e2e: a second session starts')
    stubs.tick(1000)
    eq(#voice.list(), 0, 'e2e: no_voice from the talker\'s client ends it on the server')
    eq(table.concat(ends, ' '), id2 .. ':no_voice', 'e2e: onEnd(sessionId, no_voice)')
    stubs.vitals.connected = true
end

H.finish()
