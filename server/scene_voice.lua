--[[
    core/server/scene_voice.lua — voice through world speakers, the server half (DESIGN §55.17). Last of the scene
    server files (… → scene.lua → scene_promote → scene_audio → scene_voice): it fills R.voice of Core.SceneRuntime,
    which server/scene.lua's Scene.voice.start / stop / list delegate to. A trusted server API — the calling plugin
    authorises the talker; the only client entry point is the talker's 'no_voice' report.

      R.voice.start({ talker = src, speakers = { nodeIds }, fx = 'none', range = 60, onEnd? }) -> sessionId | nil, err
          fx = 'megaphone' | 'pa' | 'phone' | 'radio' | 'none'; range 1..600 m; 1..32 distinct speaker nodes of one
          bucket; onEnd = callable(sessionId, reason), called once for an end the owner did not ask for
      R.voice.stop(sessionId) -> true | false, err       by the session's owner or core
      R.voice.list() -> { { id, owner, talker, speakers, fx, range, bucket, listeners, startedAt }, … }
      R.voice.stats() -> { sessions, listeners }
    Errors: 'def', 'talker' (not a loaded player), 'fx', 'range', 'speakers' (not an array of 1..32 distinct ids),
    'missing' (a speaker node that does not exist or is a dependency node), 'bucket' (speakers in different
    buckets), 'busy' (the talker already has a session), 'limit' (Voice.MaxSessions), 'owner' (stop).
    End reasons (audit, onEnd): 'stopped', 'owner' (the owner resource stopped), 'talker' (unloaded), 'dropped'
    (the talker left), 'speakers' (every speaker node removed), 'no_voice' (the talker's client has no voice).

    Every 500 ms — a thread that exists only while a session exists — per session: the speaker poses from R.store
    (motion-evaluated), then the listeners: loaded players within range + 20 m of any speaker (a listener stays
    until range + 30 m), in the speakers' bucket, allowed by a gated speaker's audience, minus the talker, the
    nearest Voice.MaxListeners. Candidates come from Core.PlayerGrid (cells + cached positions: no natives); the
    bucket is read only for players inside the distance. The diffs go out as
      core:scene:voice:targets (sessionId, add[], remove[])                      → the talker (whisper targets)
      core:scene:voice:listen (sessionId, talker, speakers, fx, range)           → each added listener, and every
          listener again when a speaker moved >= 1 m or went away; speakers = { { id, x, y, z }, … } (cm)
      core:scene:voice:unlisten (sessionId)                                      → each removed listener
    through Core.Net.emitMany (a payload is packed once for many listeners). start() runs the first selection at
    once, so the talker's client hears of the session right away and answers core:scene:voice:report
    (sessionId, 'no_voice') when it has no voice connection — that ends the session.
    playerDropped: a dropped talker ends his session, a dropped listener leaves every session. Registry kind
    'sceneVoice' (a stopped owner's sessions end); Core.Audit rows scene.voice.start / scene.voice.stop.

    Natives: GetPlayerRoutingBucket(playerSrc) -> int (server, CFX; fxref 2026-09-27). Runtime helpers:
    CreateThread, Wait, AddEventHandler.
]]

local R = Core.SceneRuntime
assert(R and R.store and R.store.get and R.store.pose, 'server/scene_voice.lua loads after server/scene.lua (R.store)')

local store = R.store
local Registry, Log, Utils, Net = Core.Registry, Core.Log, Core.Utils, Core.Net
local type, pairs, pcall, tostring = type, pairs, pcall, tostring
local toint, floor, huge, sort = math.tointeger, math.floor, math.huge, table.sort

local KIND <const> = 'sceneVoice'
local TICK_MS <const> = 500
local JOIN <const>, STAY <const> = 20.0, 30.0          -- listener margins past `range`: join within, stay within
local MOVED2 <const> = 1.0                              -- speaker poses re-sent past 1 m (squared)
local MAX_SPEAKERS <const> = 32
local RANGE_MIN <const>, RANGE_MAX <const>, RANGE_DEFAULT <const> = 1.0, 600.0, 60.0
local FX <const> = { megaphone = true, pa = true, phone = true, radio = true, none = true }
local EV_TARGETS <const> = 'core:scene:voice:targets'
local EV_LISTEN <const> = 'core:scene:voice:listen'
local EV_UNLISTEN <const> = 'core:scene:voice:unlisten'
local QUIET <const> = { stopped = true, owner = true }  -- ends the owner asked for (or cannot hear): no onEnd
local EMPTY <const> = {}

local Voice = {}
R.voice = Voice

local sessions = {}     -- [id] = session (below)
local order = {}        -- session ids in start order (the tick walks it)
local byTalker = {}     -- [src] = session id
local nextId = 0
local looping = false

-- session = { id, owner, talker, speakers = { ids }, fx, range, bucket, onEnd, listeners = { [src] = true },
--             count, peak, sent = { [speakerId] = { x, y, z } }, payload = { { id, x, y, z }, … }, want = {},
--             startedAt }

local function vcfg()
    local s = type(Config) == 'table' and Config.Scene
    return type(s) == 'table' and type(s.Voice) == 'table' and s.Voice or EMPTY
end
local function maxSessions() return toint(vcfg().MaxSessions) or 16 end
local function maxListeners() return toint(vcfg().MaxListeners) or 64 end

local function finite(v) return type(v) == 'number' and v == v and v ~= huge and v ~= -huge end
local function round(v) return floor(v * 100 + 0.5) / 100 end
local function bucketOf(src) return toint(GetPlayerRoutingBucket(src)) or 0 end

--- Speaker ids -> a fresh array, or nil, err; the third answer is their common bucket.
local function speakerList(list)
    if type(list) ~= 'table' then return nil, 'speakers' end
    local n = #list
    if n < 1 or n > MAX_SPEAKERS then return nil, 'speakers' end
    local out, seen, bucket = {}, {}, nil
    for i = 1, n do
        local id = toint(list[i])
        if not id or id < 1 or seen[id] then return nil, 'speakers' end
        seen[id] = true
        local node = store.get(id)
        if not node or (node.k and node.k.dependency) then return nil, 'missing' end
        if bucket == nil then bucket = node.bucket elseif node.bucket ~= bucket then return nil, 'bucket' end
        out[i] = id
    end
    return out, nil, bucket
end

--- One Core.Audit row (§46); a missing Audit never blocks the session.
local function audit(what, s, reason)
    local Audit = rawget(Core, 'Audit')
    if not (Audit and Audit.record) then return end
    local ok, err = pcall(Audit.record, {
        actor = 'system', action = 'scene.voice.' .. what, reason = reason,
        targets = { { type = 'player', id = s.talker } },
        ctx = { session = s.id, owner = s.owner, fx = s.fx, range = s.range, bucket = s.bucket,
            speakers = #s.speakers, peak = what == 'stop' and s.peak or nil },
    })
    if not ok then Log.warn('scene: voice audit %s failed: %s', what, tostring(err)) end
end

--- The sorted srcs of a set (reliable events carry arrays; sorted = deterministic).
local function keysOf(set)
    local out = {}
    for src in pairs(set) do out[#out + 1] = src end
    sort(out)
    return out
end

--------------------------------------------------------------------------------
-- Ending a session
--------------------------------------------------------------------------------

--- Ends `s` once: every listener unlistens, the talker drops them from his voice target (unless he left), the
--- audit row, then onEnd for an end the owner did not ask for.
local function finish(s, reason)
    if sessions[s.id] ~= s then return end
    sessions[s.id] = nil
    if byTalker[s.talker] == s.id then byTalker[s.talker] = nil end
    for i = 1, #order do
        if order[i] == s.id then
            table.remove(order, i)
            break
        end
    end
    Registry.untrack(KIND, s.id)
    local list = keysOf(s.listeners)
    s.listeners, s.count = {}, 0
    if #list > 0 then
        if reason ~= 'dropped' then Net.emit(s.talker, EV_TARGETS, s.id, {}, list) end
        Net.emitMany(list, EV_UNLISTEN, s.id)
    end
    audit('stop', s, reason)
    if s.onEnd and not QUIET[reason] then
        local ok, err = pcall(s.onEnd, s.id, reason)
        if not ok then Log.warn('scene: voice onEnd of %s failed: %s', s.owner, tostring(err)) end
    end
end

--------------------------------------------------------------------------------
-- The selection (start, then every 500 ms)
--------------------------------------------------------------------------------

local buf, sel, mark = {}, {}, {}           -- PlayerGrid candidates, the selection, [src] = generation (reused)
local selN, gen = 0, 0
local px, py, pz, pnode = {}, {}, {}, {}    -- the ticked session's speaker poses and nodes (reused)
local q = { x = 0.0, y = 0.0 }              -- the PlayerGrid query point (reused)
local rank                                  -- the `want` map `nearer` reads while sorting
local function nearer(a, b)
    local da, db = rank[a], rank[b]
    if da ~= db then return da < db end
    return a < b
end

--- Speaker poses into px/py/pz/pnode, removed speakers dropped -> count, moved (>= 1 m, or the set shrank).
local function posesOf(s, now)
    local list, n, moved = s.speakers, 0, false
    local total = #list
    for i = 1, total do
        local id = list[i]
        local node = store.get(id)
        if node and node.bucket == s.bucket and not (node.k and node.k.dependency) then
            n = n + 1
            list[n] = id
            local x, y, z = store.pose(node, now)
            px[n], py[n], pz[n], pnode[n] = x, y, z, node
            local last = s.sent[id]
            if not last or (x - last[1]) ^ 2 + (y - last[2]) ^ 2 + (z - last[3]) ^ 2 >= MOVED2 then moved = true end
        else
            s.sent[id] = nil
            moved = true
        end
    end
    for i = n + 1, total do list[i] = nil end
    return n, moved
end

--- The listeners' speaker payload (cm) and the poses it carries.
local function repack(s, n)
    local payload, list, sent = {}, s.speakers, s.sent
    for i = 1, n do
        local id = list[i]
        payload[i] = { id, round(px[i]), round(py[i]), round(pz[i]) }
        local last = sent[id]
        if last then
            last[1], last[2], last[3] = px[i], py[i], pz[i]
        else
            sent[id] = { px[i], py[i], pz[i] }
        end
    end
    s.payload = payload
end

--- s.want[src] = the smallest squared distance to a speaker the player may hear, within range + STAY of one.
local function gather(s, n)
    local want = s.want
    for src in pairs(want) do want[src] = nil end
    local Grid = Core.PlayerGrid
    local allows = R.interest and R.interest.allows
    local reach = s.range + STAY
    local stay2, talker = reach * reach, s.talker
    for i = 1, n do
        local sx, sy, sz, node = px[i], py[i], pz[i], pnode[i]
        local gated = node.audience ~= nil and allows ~= nil
        q.x, q.y = sx, sy
        local cnt = Grid.candidates(q, reach, buf)
        for j = 1, cnt do
            local src = buf[j]
            if src ~= talker then
                local x, y, z = Grid.positionOf(src)
                if x then
                    local d2 = (x - sx) ^ 2 + (y - sy) ^ 2 + (z - sz) ^ 2
                    local cur = want[src]
                    if d2 <= stay2 and (not cur or d2 < cur) and (not gated or allows(node, src)) then
                        want[src] = d2
                    end
                end
            end
        end
    end
    return want
end

--- This tick's listeners into sel[1..count]: loaded, in the speakers' bucket, within JOIN (STAY for a current
--- listener), the nearest maxListeners() of them.
local function choose(s, want)
    local join2, cur, bucket = (s.range + JOIN) ^ 2, s.listeners, s.bucket
    local isLoaded = Core.Player.isLoaded
    local m = 0
    for src, d2 in pairs(want) do
        if (d2 <= join2 or cur[src]) and isLoaded(src) and bucketOf(src) == bucket then
            m = m + 1
            sel[m] = src
        end
    end
    for i = m + 1, selN do sel[i] = nil end
    selN = m
    local cap = maxListeners()
    if m > cap then
        rank = want
        sort(sel, nearer)
        rank = nil
        for i = cap + 1, m do sel[i] = nil end
        selN = cap
    end
    return selN
end

--- One selection of `s`: poses → listeners → diffs → events. `first` (start) always tells the talker.
local function tick(s, first)
    if not Core.Player.isLoaded(s.talker) then return finish(s, 'talker') end
    local n, moved = posesOf(s, R.now())
    if n == 0 then return finish(s, 'speakers') end
    if moved then repack(s, n) end
    local m = choose(s, gather(s, n))
    for i = 1, n do pnode[i] = nil end              -- no node reference outlives the tick
    gen = gen + 1
    local cur, add, remove = s.listeners, nil, nil
    for i = 1, m do
        local src = sel[i]
        mark[src] = gen
        if not cur[src] then
            add = add or {}
            add[#add + 1] = src
        end
    end
    for src in pairs(cur) do
        if mark[src] ~= gen then
            remove = remove or {}
            remove[#remove + 1] = src
        end
    end
    if remove then
        sort(remove)
        for i = 1, #remove do cur[remove[i]] = nil end
        s.count = s.count - #remove
    end
    local stayed = (moved and s.count > 0) and keysOf(cur) or nil     -- listeners that need the new poses
    if add then
        sort(add)
        for i = 1, #add do cur[add[i]] = true end
        s.count = s.count + #add
        if s.count > s.peak then s.peak = s.count end
    end
    if add or remove or first then Net.emit(s.talker, EV_TARGETS, s.id, add or {}, remove or {}) end
    if remove then Net.emitMany(remove, EV_UNLISTEN, s.id) end
    if add then Net.emitMany(add, EV_LISTEN, s.id, s.talker, s.payload, s.fx, s.range) end
    if stayed then Net.emitMany(stayed, EV_LISTEN, s.id, s.talker, s.payload, s.fx, s.range) end
end

--- The 500 ms thread: exists only while a session exists (newest first; finish() may drop the one ticked).
local function loop()
    while #order > 0 do
        Wait(TICK_MS)
        for i = #order, 1, -1 do
            local s = sessions[order[i]]
            if s then
                local ok, err = pcall(tick, s, false)
                if not ok then Log.warn('scene: voice session %s tick failed: %s', tostring(s.id), tostring(err)) end
            end
        end
    end
    looping = false
end

local function ensureLoop()
    if looping then return end
    looping = true
    CreateThread(loop)
end

--------------------------------------------------------------------------------
-- API (Scene.voice.* in server/scene.lua delegates here)
--------------------------------------------------------------------------------

function Voice.start(def)
    if type(def) ~= 'table' then return nil, 'def' end
    local talker = toint(def.talker)
    if not talker or talker < 1 or not Core.Player.isLoaded(talker) then return nil, 'talker' end
    local fx = def.fx
    if fx == nil then fx = 'none' end
    if not FX[fx] then return nil, 'fx' end
    local range = def.range
    if range == nil then range = RANGE_DEFAULT end
    if not finite(range) or range < RANGE_MIN or range > RANGE_MAX then return nil, 'range' end
    local onEnd = def.onEnd
    if onEnd ~= nil and not Utils.isCallable(onEnd) then return nil, 'def' end
    local speakers, err, bucket = speakerList(def.speakers)
    if not speakers then return nil, err end
    if byTalker[talker] then return nil, 'busy' end
    if #order >= maxSessions() then return nil, 'limit' end
    repeat nextId = nextId % 0x7FFFFFFF + 1 until not sessions[nextId]
    local s = { id = nextId, owner = Registry.getCaller(), talker = talker, speakers = speakers, fx = fx,
        range = range + 0.0, bucket = bucket, onEnd = onEnd, listeners = {}, count = 0, peak = 0, sent = {},
        payload = nil, want = {}, startedAt = R.now() }
    sessions[s.id], byTalker[talker] = s, s.id
    order[#order + 1] = s.id
    Registry.track(KIND, s.id, s.owner)
    audit('start', s)
    tick(s, true)
    if sessions[s.id] then ensureLoop() end
    return s.id
end

function Voice.stop(id)
    local s = sessions[toint(id) or 0]
    if not s then return false, 'missing' end
    local caller = Registry.getCaller()
    if caller ~= 'core' and caller ~= s.owner then return false, 'owner' end
    finish(s, 'stopped')
    return true
end

function Voice.list()
    local out = {}
    for i = 1, #order do
        local s = sessions[order[i]]
        if s then
            out[#out + 1] = { id = s.id, owner = s.owner, talker = s.talker,
                speakers = table.move(s.speakers, 1, #s.speakers, 1, {}), fx = s.fx, range = s.range,
                bucket = s.bucket, listeners = s.count, startedAt = s.startedAt }
        end
    end
    return out
end

function Voice.stats()
    local listeners = 0
    for i = 1, #order do
        local s = sessions[order[i]]
        if s then listeners = listeners + s.count end
    end
    return { sessions = #order, listeners = listeners }
end

Registry.onOwnerStop(KIND, function(id)
    local s = sessions[id]
    if s then finish(s, 'owner') end
end)

--------------------------------------------------------------------------------
-- Drops and the talker's report
--------------------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    local src = source
    mark[src] = nil
    local sid = byTalker[src]
    if sid and sessions[sid] then finish(sessions[sid], 'dropped') end
    for i = 1, #order do
        local s = sessions[order[i]]
        if s and s.listeners[src] then
            s.listeners[src], s.want[src] = nil, nil
            s.count = s.count - 1
            Net.emit(s.talker, EV_TARGETS, s.id, {}, { src })
        end
    end
end)

-- schema → cooldown → loaded (Core.Net.on) → the session exists → it is the sender's → end it
Net.on('core:scene:voice:report', { { 'integer', min = 1, max = 0x7FFFFFFF }, { 'enum', 'no_voice' } },
    function(src, id, code)
        local s = sessions[id]
        if not s or s.talker ~= src then return end
        Log.warn('scene: voice session %d ends: player %d has no voice connection', id, src)
        finish(s, code)
    end, { cooldown = 1000 })
