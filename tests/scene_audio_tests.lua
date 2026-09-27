-- Offline tests for Core.Scene audio (DESIGN §55.16, §55.19, §55.20): server/scene_audio.lua (policy, trust, async
-- resolution with a fake Core.Http, titles, admit, plays + audit, kill, the settings) in the stub server VM of
-- tests/scene_server_harness.lua; client/scene_audio.lua (lifecycle -> exact NUI messages, dependency sources, feed
-- cadence, occlusion probes, prefs, replays) in tests/client_scene_harness.lua's VM with the real materialiser.
local here = (arg and arg[0] or 'tests/scene_audio_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harnesses load the checked-in stubs and files only
local H = dofile(here .. '/scene_server_harness.lua')
H.name = 'scene audio'
local check, eq = H.check, H.eq
local stubs = H.stubs
local json = stubs.json

--------------------------------------------------------------------------------------------------------------------
-- SERVER
--------------------------------------------------------------------------------------------------------------------

local http, audits, subs = { q = {} }, {}, {}
local env, Core, R = H.newServer({ beforeStore = function(e, C, Rt)
    stubs.loadFile(e, 'server/settings.lua')
    C.Audit = { record = function(row) audits[#audits + 1] = row return 'a' .. #audits end }
    Rt.interest.subscribers = function(bucket, grid, key) return subs[bucket .. ':' .. grid .. ':' .. key] end
end })
Core.Http = { fetch = function(url, opts)
    local p = env.promise.new()
    http.q[#http.q + 1] = { url = url, opts = opts, p = p }
    local res = env.Citizen.Await(p)
    return res[1], res[2], res[3]
end }
--- Answers the oldest open request for `url`; false when none is open.
local function answer(url, status, body)
    for _, q in ipairs(http.q) do
        if q.url == url and not q.done then q.done = true return q.p:resolve({ status, body, {} }) or true end
    end
    return false
end
--- Requests of `url`: every one (asked), or only those still unanswered (open).
local function count(list, want)
    local n = 0
    for _, e in ipairs(list) do if want(e) then n = n + 1 end end
    return n
end
local function open(url) return count(http.q, function(q) return q.url == url and not q.done end) end
local function asked(url) return count(http.q, function(q) return q.url == url end) end

stubs.resourceStates.radio = 'started'
stubs.resourceMeta.radio = { file = { 'sounds/*.ogg', 'music/**', 'x/*.aac', 'lists/*.m3u' } }
stubs.loadFile(env, 'server/scene_audio.lua')
stubs.tick(100)
local Scene, Settings, A = Core.Scene, Core.Settings, R.audio
local function spawn(owner, fields, extra)
    local def = { kind = 'audio.source', fields = fields }
    for k, v in pairs(extra or {}) do def[k] = v end
    return H.as(owner, 'spawn', def)
end
local function node(id) return R.store.get(id) end
local function set(key, value)                          -- Settings.set in a thread (the load may yield)
    local done
    env.CreateThread(function() done = table.pack(Settings.set(key, value)) end)
    stubs.tick(50) return done and done[1]
end

-- 1. shape, the settings, the predecessor assert -------------------------------------------------------------------
do
    for _, fn in ipairs({ 'check', 'admit', 'play', 'kill', 'stats' }) do
        eq(type(A[fn]), 'function', 'R.audio.' .. fn)
    end
    for _, fn in ipairs({ 'play', 'kill', 'stats' }) do eq(type(Scene.audio[fn]), 'function', 'Scene.audio.' .. fn) end
    local s = Settings.inspect('scene.audio.enabled')
    check(s and s.value == true, 'scene.audio.enabled defaults to true')
    s = Settings.inspect('scene.audio.allowHosts')
    check(s and type(s.value) == 'table' and #s.value == 0, 'scene.audio.allowHosts defaults to an empty list')
    eq(Settings.inspect('scene.audio.maxStreams').value, 8, 'scene.audio.maxStreams defaults to 8')
    local e2 = stubs.newEnv('server', 'core')
    stubs.loadImport(e2)
    local ok, err = pcall(stubs.loadFile, e2, 'server/scene_audio.lua')
    check(not ok and tostring(err):find('server/scene.lua', 1, true),
        'asserts server/scene.lua (R.store, R.kinds) first')
    eq(A.stats().sources, 0, 'no source yet')
end

-- 2. files: resource, path, files {}, codec -------------------------------------------------------------------------
do
    local id = spawn('radio', { type = 'clip', file = '@radio/sounds/horn.ogg' })
    check(id and node(id).fields.resolved.trusted == true, 'a file clip inside files {} passes, trusted')
    local function refused(fields, field, code, label)
        local rid, err, detail = spawn('radio', fields)
        check(rid == nil and err == 'fields' and type(detail) == 'table' and detail[field] == code,
            ('%s (got %s %s)'):format(label, tostring(err), json.encode(detail or {})))
    end
    refused({ type = 'clip', file = '@radio/sounds/../secret.ogg' }, 'file', 'file', 'a ".." segment is refused')
    refused({ type = 'clip', file = '@radio/other/horn.ogg' }, 'file', 'files', 'a path outside files {} is refused')
    refused({ type = 'clip', file = '@ghost/sounds/horn.ogg' }, 'file', 'resource', 'a resource not started is refused')
    refused({ type = 'clip', file = '@radio/music/readme.txt' }, 'file', 'codec', 'an unknown extension is refused')
    local shippedAac = env.Config.Scene.Audio.AllowAac
    check(shippedAac == true, "the shipped config allows AAC (scene_probe P8: FiveM's CEF decodes it)")
    env.Config.Scene.Audio.AllowAac = false
    refused({ type = 'clip', file = '@radio/x/a.aac' }, 'file', 'codec', 'AAC is refused while AllowAac is off')
    refused({ type = 'loop', file = '@radio/lists/a.m3u' }, 'file', 'playlist', 'a playlist file is refused')
    refused({ type = 'clip', url = 'https://radio.example.com/a.mp3' }, 'url', 'host', 'no host allowed: URLs refused')
    check(spawn('radio', { type = 'loop', file = '@radio/music/a/b/c.mp3' }) ~= nil, "'music/**' covers nested paths")
    check(spawn('radio', { type = 'clip', file = '@radio/music/hit.wav' }) ~= nil, 'WAV passes for a clip')
    local tl = spawn('radio', { type = 'timeline', items = { { file = '@radio/music/a.mp3', duration = 180000 },
        { file = '@radio/music/b.wav', duration = 5000 } } })
    check(tl ~= nil, 'a timeline of files with durations passes')
    refused({ type = 'timeline', items = { { file = '@radio/music/a.mp3' } } }, 'items', '1.duration',
        'a timeline item needs a duration')
    refused({ type = 'timeline', items = { { file = '@radio/music/a.mp3', duration = 1 },
        { file = '@radio/nope/b.mp3', duration = 1 } } }, 'items', '2.file.files', 'a bad item names its index')
    env.Config.Scene.Audio.AllowAac = true
    check(spawn('radio', { type = 'clip', file = '@radio/x/a.aac' }) ~= nil, 'AAC passes with AllowAac')
    env.Config.Scene.Audio.AllowAac = false     -- the rest of the suite was written against the gate closed
end

-- 3. the host allow-list (Core.Settings), URL rules, direct classification -------------------------------------------
do
    check(set('scene.audio.allowHosts', { 'Radio.Example.com', '*.cdn.example.org' }), 'allowHosts set')
    eq(A.stats().hosts, 2, 'two host patterns active')
    check(set('scene.audio.maxStreams', 64), 'maxStreams raised for the resolution cases')
    eq(A.stats().maxStreams, 64, 'the new limit applies')
    local before = #http.q
    local id = spawn('radio', { type = 'clip', url = 'https://radio.example.com/live.mp3' })
    local r = id and node(id).fields.resolved
    check(r and r.url == 'https://radio.example.com/live.mp3' and r.codec == 'audio/mpeg' and r.kind == 'mp3',
        'a direct .mp3 resolves at once')
    eq(#http.q, before, 'a direct URL costs no request')
    r = node(spawn('radio', { type = 'stream', url = 'https://a.cdn.example.org/x.ogg' })).fields.resolved
    check(r and r.kind == 'ogg' and r.codec == 'audio/ogg',
        '*.cdn.example.org covers a subdomain; ogg -> media element')
    check(spawn('radio', { type = 'clip', url = 'https://RADIO.example.com:8443/b.mp3' }) ~= nil,
        'hosts compare case-insensitively, a port is fine')
    local function refused(fields, code, label)
        local rid, err, detail = spawn('radio', fields)
        check(rid == nil and err == 'fields' and detail and detail.url == code,
            ('%s (got %s %s)'):format(label, tostring(err), json.encode(detail or {})))
    end
    refused({ type = 'clip', url = 'https://cdn.example.org/x.ogg' }, 'host', "'*.x' does not cover x itself")
    refused({ type = 'clip', url = 'https://evil.example.net/x.mp3' }, 'host', 'a host not listed is refused')
    refused({ type = 'clip', url = 'https://user:pw@radio.example.com/x.mp3' }, 'url', 'credentials are refused')
    refused({ type = 'stream', url = 'https://radio.example.com/a.aac' }, 'codec', 'an AAC stream is refused')
    refused({ type = 'stream', url = 'https://radio.example.com/a.wav' }, 'codec', 'WAV only for clips and loops')
    refused({ type = 'clip', url = 'https://radio.example.com/list.pls' }, 'playlist', 'playlists only for streams')
    local rid, err, detail = spawn('radio', { type = 'clip', url = 'http://radio.example.com/x.mp3' })
    check(rid == nil and err == 'fields' and detail and detail.url ~= nil, 'http:// never passes (schema)')
    r = node(spawn('radio', { type = 'clip', url = 'https://radio.example.com/sound?id=3' })).fields.resolved
    check(r and r.url == 'https://radio.example.com/sound?id=3' and r.codec == nil,
        'a clip without extension: the page sniffs')
end

-- 4. async playlist resolution: never blocks, one request per URL, the cache ----------------------------------------
local LIVE = 'https://radio.example.com/live'
local s1, s2
do
    local PLS = 'https://radio.example.com/listen.pls'
    s1 = spawn('radio', { type = 'stream', url = PLS })
    check(s1 and node(s1).fields.resolved.pending == true, 'the spawn returns at once, resolved = { pending }')
    eq(open(PLS), 1, 'one GET of the playlist is in flight')
    s2 = spawn('radio', { type = 'stream', url = PLS })
    eq(asked(PLS), 1, 'a second source of the same URL shares the request')
    H.reset()
    answer(PLS, 200, '[playlist]\nNumberOfEntries=2\nFile2=https://radio.example.com/b.mp3\nFile1=' .. LIVE .. '\n')
    eq(open('https://radio.example.com/status-json.xsl'), 1, 'an entry without extension: the status-json is asked')
    check(node(s1).fields.resolved.pending, 'still pending meanwhile')
    answer('https://radio.example.com/status-json.xsl', 200, json.encode({ icestats = { source = {
        listenurl = 'http://radio.example.com:8000/live', server_type = 'application/ogg', title = 'Song A' } } }))
    for _, id in ipairs({ s1, s2 }) do
        local r = node(id).fields.resolved
        check(r.url == LIVE and r.kind == 'ogg' and r.codec == 'application/ogg' and not r.pending,
            'source ' .. id .. ' resolved to the first entry, codec from server_type')
    end
    local sets = H.calls('changed', s1)
    check(#sets == 1 and sets[1].what == 'set' and sets[1].data.f.resolved ~= nil, 'the answer is one SET of resolved')
    local s3 = spawn('radio', { type = 'stream', url = PLS })
    check(node(s3).fields.resolved.url == LIVE, 'a later source of the same URL takes the cached answer')
    eq(asked(PLS), 1, 'no new request for a cached URL')
    local function resolves(url, body, label, want)
        local id = spawn('radio', { type = 'stream', url = url })
        answer(url, body and 200 or 404, body)
        local r = node(id).fields.resolved
        for k, v in pairs(want) do
            if r[k] ~= v then return check(false, ('%s: %s = %s'):format(label, k, tostring(r[k]))) end
        end
        return check(true, label)
    end
    local HLS = 'https://radio.example.com/hls/index.m3u8'
    resolves(HLS, '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg1.ts\n', 'an HLS media playlist stays HLS',
        { url = HLS, kind = 'hls', codec = 'application/vnd.apple.mpegurl' })
    resolves('https://radio.example.com/aac.m3u8',
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="mp4a.40.2"\nlow.m3u8\n',
        'an HLS master of AAC variants only is refused', { error = 'codec' })
    resolves('https://radio.example.com/list.m3u',
        '\239\187\191#EXTM3U\n#EXTINF:-1,Radio\nhttps://radio.example.com/r.mp3\n',
        'a plain m3u (with a BOM): its first entry', { url = 'https://radio.example.com/r.mp3', kind = 'mp3' })
    resolves('https://radio.example.com/a.xspf',
        '<playlist><trackList><track><location>https://radio.example.com/x.ogg?a=1&amp;b=2'
        .. '</location></track></trackList></playlist>', 'an xspf location (XML entities)',
        { url = 'https://radio.example.com/x.ogg?a=1&b=2', kind = 'ogg' })
    resolves('https://radio.example.com/rel.m3u', 'r2.mp3\n', 'a relative entry resolves against the playlist',
        { url = 'https://radio.example.com/r2.mp3' })
    resolves('https://radio.example.com/other.m3u', 'https://evil.example.net/x.mp3\n', 'an entry on a host not listed',
        { error = 'host' })
    resolves('https://radio.example.com/plain.m3u', 'http://radio.example.com/x.mp3\n', 'an http:// entry',
        { error = 'https' })
    resolves('https://radio.example.com/404.pls', nil, 'a failed fetch', { error = 'fetch' })
    local again = spawn('radio', { type = 'stream', url = 'https://radio.example.com/404.pls' })
    check(node(again).fields.resolved.error == 'fetch' and asked('https://radio.example.com/404.pls') == 1,
        'a failed URL answers from the cache for a minute')
    stubs.tick(61000)
    local retry = spawn('radio', { type = 'stream', url = 'https://radio.example.com/404.pls' })
    check(node(retry).fields.resolved.pending and open('https://radio.example.com/404.pls') == 1,
        'after a minute it is asked again')
    answer('https://radio.example.com/404.pls', 200, 'https://radio.example.com/ok.mp3\n')   -- labelled pls, is m3u
    eq(node(retry).fields.resolved.url, 'https://radio.example.com/ok.mp3', 'and resolves when it answers')
    local p1 = spawn('radio', { type = 'stream', url = 'https://b.cdn.example.org/live2' })
    answer('https://b.cdn.example.org/status-json.xsl', 404, 'nope')
    local r = node(p1).fields.resolved
    check(r.url == 'https://b.cdn.example.org/live2' and r.kind == 'mp3' and r.codec == 'audio/mpeg',
        'no status-json: the stream is assumed MP3')
    local p2 = spawn('radio', { type = 'stream', url = 'https://c.cdn.example.org/aacp' })
    answer('https://c.cdn.example.org/status-json.xsl', 200, json.encode({ icestats = { source = { {
        listenurl = 'https://c.cdn.example.org/aacp', server_type = 'audio/aacp' } } } }))
    eq(node(p2).fields.resolved.error, 'codec', 'a status-json naming AAC refuses the stream')
end

-- 5. titles: every 20 s, only while a dependent emitter sits in a subscribed cell -----------------------------------
do
    local STATUS = 'https://radio.example.com/status-json.xsl'
    local e1 = H.as('radio', 'spawn', { kind = 'audio', pos = { x = 10, y = 20, z = 30 }, fields = { source = s1 } })
    check(e1 ~= nil, 'an emitter of the resolved stream')
    local before = asked(STATUS)
    stubs.tick(21000)
    eq(asked(STATUS), before, 'nobody subscribes to its cell: no title poll')
    node(e1).cell = { grid = 0, key = 99 }
    subs['0:0:99'] = { [1] = 1 }
    stubs.tick(20000)
    eq(open(STATUS), 1, 'a subscribed cell: one status-json per origin')
    H.reset()
    answer(STATUS, 200, json.encode({ icestats = { source = { { listenurl = 'http://radio.example.com:8000/other',
        title = 'Nope' }, { listenurl = 'http://radio.example.com:8000/live', artist = 'Artist',
        title = 'Song B' } } } }))
    eq(node(s1).fields.title, 'Artist - Song B', 'the mount of the stream path gives the title')
    eq(node(s2).fields.title, nil, 'a source without a listened emitter keeps its title')
    local sets = H.calls('changed', s1)
    check(#sets == 1 and sets[1].data.f.title == 'Artist - Song B' and sets[1].data.f.resolved == nil,
        'one SET carrying only the title')
    stubs.tick(20000)
    answer(STATUS, 200, json.encode({ icestats = { source = { listenurl = 'http://radio.example.com/live',
        title = ('é'):rep(80) } } }))
    local t = node(s1).fields.title
    check(#t <= 128 and utf8.len(t) == 64, 'a long title is cut to 128 bytes on a UTF-8 boundary')
    subs['0:0:99'] = nil
    local n = asked(STATUS)
    stubs.tick(40000)
    eq(asked(STATUS), n, 'unsubscribed again: polling stops asking')
    check(A.stats().polls >= 2 and A.stats().titles >= 2, 'stats count polls and titles')
end

-- 6. plays on behalf of players: 1 per 5 s, audited; R.audio.admit's owner flood guard -------------------------------
local function plays() return count(audits, function(a) return a.action == 'scene.audio.play' end) end
do
    stubs.playerNames[7] = 'Tester'
    local id = H.as('radio', 'audio.play', { fields = { type = 'clip', file = '@radio/sounds/horn.ogg' }, by = 7 })
    check(id ~= nil and node(id).owner == 'radio', 'a play spawns the source as the calling resource')
    local row = audits[#audits]
    check(row.action == 'scene.audio.play' and row.actor == 7 and row.targets[1].id == id and row.ctx.op == 'spawn'
        and row.ctx.url == '@radio/sounds/horn.ogg' and row.ctx.owner == 'radio', 'the play is audited for player 7')
    local id2, err = H.as('radio', 'audio.play', { fields = { type = 'clip', file = '@radio/sounds/horn.ogg' },
        by = 7 })
    check(id2 == nil and err == 'rate_limit', 'a second play within 5 s is refused')
    eq(plays(), 1, 'a refused play writes no audit row')
    stubs.tick(5000)
    id2 = H.as('radio', 'audio.play', { id = id, fields = { file = '@radio/music/a.mp3' }, by = 7 })
    check(id2 == id and node(id).fields.file == '@radio/music/a.mp3', 'a retarget of the source after 5 s')
    eq(audits[#audits].ctx.op, 'set', 'the retarget is audited as a set')
    stubs.tick(5000)
    local _, e3 = H.as('radio', 'audio.play', { id = 999999, fields = {}, by = 7 })
    eq(e3, 'missing', 'a retarget of no source')
    local _, e4 = H.as('radio', 'audio.play', { fields = { type = 'clip', file = '@radio/sounds/horn.ogg' }, by = 99 })
    eq(e4, 'by', 'a player who is not connected')
    local n = plays()
    check(H.as('radio', 'audio.play', { fields = { type = 'clip', file = '@radio/sounds/horn.ogg' } }) ~= nil,
        'a play without `by` is not rate-limited per player')
    eq(plays(), n, 'and not audited')
    local clip = { kind = 'audio.source', fields = { type = 'clip', file = '@radio/sounds/horn.ogg' } }
    local ok, last = 0, nil
    for _ = 1, 125 do
        local pass, code = A.admit(clip, 'flood')
        if pass then ok = ok + 1 else last = code end
    end
    check(ok == 120 and last == 'audio_rate', 'admit: the owner flood guard lets 120 through at once')
    stubs.tick(1000)
    local more = 0
    for _ = 1, 30 do if A.admit(clip, 'flood') then more = more + 1 end end
    eq(more, 20, 'then 20 a second')
    local pass, code = Core.Registry.withCaller('flood', A.admit, clip)
    check(pass and code == false and select(3, Core.Registry.withCaller('flood', A.admit, clip)) == 'audio_rate',
        'no owner given: the calling resource pays')
    local core = 0
    for _ = 1, 200 do if A.admit(clip, 'core') then core = core + 1 end end
    check(core == 200 and A.admit(clip) == true, 'core is exempt (also as the default caller)')
    check(A.admit({ kind = 'audio', fields = { source = 1 } }, 'flood') == true
        and A.admit({ kind = 'prop', fields = {} }, 'flood') == true and A.admit(nil, 'flood') == true,
        'other kinds (emitters included) always pass')
    check(select(2, A.admit({ kind = { id = 'audio.source' }, fields = {} }, 'flood')) == 'audio_rate',
        'a kind table is read by its id')
    check(A.stats().refused.rate >= 8 and A.stats().refused.player == 1, 'refusals are counted')
end

-- 7. maxStreams, scene.audio.enabled ------------------------------------------------------------------------------
do
    local streams = A.stats().streams
    check(streams >= 4, 'the stream sources are counted (' .. streams .. ')')
    check(set('scene.audio.maxStreams', streams + 1), 'maxStreams set')
    local stream = { kind = 'audio.source', fields = { type = 'stream', url = 'https://radio.example.com/x.mp3' } }
    local clip = { kind = 'audio.source', fields = { type = 'clip', file = '@radio/sounds/horn.ogg' } }
    check(A.admit(stream, 'radio') == true, 'admit: one more stream fits')
    local id = spawn('radio', { type = 'stream', url = 'https://radio.example.com/one.mp3' })
    check(id ~= nil and A.stats().streams == streams + 1, 'spawned: the limit is reached')
    local pass, code = A.admit(stream, 'radio')
    check(pass == false and code == 'audio_streams', 'admit: the next stream is refused')
    check(A.admit(clip, 'radio') == true, 'clips do not count')
    H.as('radio', 'remove', id)
    check(A.admit(stream, 'radio') == true, 'a removed stream frees one')
    check(set('scene.audio.enabled', false), 'enabled set false')
    pass, code = A.admit(clip, 'radio')
    check(pass == false and code == 'audio_disabled', 'audio off: admit refuses new sources')
    check(A.admit({ kind = 'audio', fields = { source = s2 } }, 'radio') == true
        and H.as('radio', 'spawn', { kind = 'audio', pos = { x = 0, y = 0, z = 0 }, fields = { source = s2 } }) ~= nil,
        'emitters of existing sources still spawn')
    local allowed = Core.Hooks.run('scene:beforeSpawn', { kind = 'audio.source', owner = 'radio',
        fields = { type = 'clip', file = '@radio/sounds/horn.ogg' } })
    check(allowed == true, 'no scene:beforeSpawn hook of core: the limits live in R.audio.admit only')
    stubs.tick(1500)
    eq(env.GlobalState['cs:scene.audio.enabled'], false, 'the setting replicates to clients')
    check(set('scene.audio.enabled', true), 'enabled set true')
end

-- 8. kill: any owner, emitters with their source, audited; stats --------------------------------------------------
do
    local sid = spawn('radio', { type = 'loop', file = '@radio/music/a.mp3' })
    local e1 = H.as('radio', 'spawn', { kind = 'audio', pos = { x = 1, y = 1, z = 0 }, fields = { source = sid } })
    local e2 = H.as('radio', 'spawn', { kind = 'audio', pos = { x = 2, y = 1, z = 0 }, fields = { source = sid } })
    H.reset()
    local ok, n = H.as('other', 'audio.kill', sid, 3)
    check(ok == true and n == 1, 'kill(id) as another resource')
    check(node(sid) == nil and node(e1) == nil and node(e2) == nil, 'the source and its emitters are gone')
    local rm = H.calls('remove')
    check(#rm == 3 and rm[1].id == sid and rm[2].how == 2 and rm[3].how == 2, 'source and emitters leave with a fade')
    local row = audits[#audits]
    check(row.action == 'scene.audio.kill' and row.actor == 3 and row.ctx.count == 1 and row.ctx.caller == 'other',
        'the kill is audited with its actor and caller')
    local s3 = spawn('radio', { type = 'loop', file = '@radio/music/a.mp3' })
    local e3 = H.as('radio', 'spawn', { kind = 'audio', pos = { x = 1, y = 1, z = 0 }, fields = { source = s3 } })
    check(select(2, Scene.audio.kill(e3)) == 1 and node(e3) == nil and node(s3) ~= nil,
        'kill(emitter) removes it alone')
    local bad, err = Scene.audio.kill(123456789)
    check(bad == false and err == 'missing', 'kill of an unknown id')
    ok, n = Scene.audio.kill('all')
    check(ok and n > 10 and A.stats().sources == 0 and A.stats().streams == 0, 'kill("all") empties the audio sources')
    local s = A.stats()
    for _, k in ipairs({ 'enabled', 'hosts', 'maxStreams', 'sources', 'streams', 'resolving', 'queued', 'cached',
        'resolved', 'failed', 'requests', 'polls', 'titles', 'plays', 'kills', 'refused' }) do
        check(s[k] ~= nil, 'stats.' .. k)
    end
end

-- 8a. trust (resolved.trusted, server-owned): resource files chosen by server code only ------------------------------
do
    stubs.tick(5000)
    stubs.playerNames[8], stubs.playerNames[9] = 'P8', 'P9'
    local function trusted(id) return node(id).fields.resolved.trusted end
    local HORN, HIT = '@radio/sounds/horn.ogg', '@radio/music/hit.wav'
    check(trusted(spawn('radio', { type = 'clip', url = 'https://radio.example.com/t.mp3' })) == false,
        'a remote URL is never trusted')
    local pl = spawn('radio', { type = 'stream', url = 'https://radio.example.com/t.pls' })
    check(node(pl).fields.resolved.pending and trusted(pl) == false, 'nor one still resolving')
    check(trusted(spawn('radio', { type = 'clip', url = 'https://radio.example.com/u.mp3',
        resolved = { trusted = true } })) == false, 'resolved is server-owned: an input value is ignored')
    check(trusted(spawn('radio', { type = 'timeline', items = { { file = HORN, duration = 1000 },
        { file = '@radio/music/a.mp3', duration = 2000 } } })) == true, 'a timeline of resource files is trusted')
    check(trusted(spawn('radio', { type = 'timeline', items = { { file = HORN, duration = 1000 },
        { url = 'https://radio.example.com/v.mp3', duration = 2000 } } })) == false, 'one remote item: not trusted')
    local p8 = H.as('radio', 'audio.play', { fields = { type = 'loop', file = HIT }, by = 8 })
    check(p8 and trusted(p8) == false, "a file played on a player's behalf is not trusted")
    check(H.as('radio', 'set', p8, { paused = true }) and trusted(p8) == false, 'and stays so when its owner sets it')
    local other = spawn('radio', { type = 'clip', file = HIT })
    check(trusted(other) == false, 'a file a player-chosen source plays is untrusted for everyone meanwhile')
    check(trusted(spawn('radio', { type = 'clip', file = HORN })) == true, 'other files stay trusted')
    check(H.as('radio', 'set', p8, { file = '@radio/music/a.mp3' }) and trusted(p8) == true,
        'its owner choosing other content (no player): trusted again')
    check(trusted(spawn('radio', { type = 'clip', file = HIT })) == true, 'the file is released with it')
    local p9 = H.as('radio', 'audio.play', { fields = { type = 'clip', file = HORN } })
    check(trusted(p9) == true, 'a play without `by` (server code) keeps resource files trusted')
    local t9 = H.as('radio', 'audio.play', { fields = { type = 'timeline', items = { { file = HIT, duration = 900 } } },
        by = 9 })
    check(t9 and trusted(t9) == false and trusted(spawn('radio', { type = 'clip', file = HIT })) == false,
        "a player's timeline marks its files")
    H.as('radio', 'remove', t9)
    check(trusted(spawn('radio', { type = 'clip', file = HIT })) == true, 'removed: its files are trusted again')
    Scene.audio.kill('all')
end

-- 8b. a restart: a persistent source that was still resolving comes back pending and is asked for again -----------
do
    local PLS = 'https://radio.example.com/persist.pls'
    local pid = spawn('radio', { type = 'stream', url = PLS }, { persist = true })
    check(pid and node(pid).persist and open(PLS) == 1, 'a persistent stream source, its playlist in flight')
    stubs.tick(2500)                                                  -- the store writes it (<= 1 per node per second)
    local env2, Core2, R2 = H.newServer({ keepKvp = true, beforeStore = function(e, C)
        stubs.loadFile(e, 'server/settings.lua')
        C.Audit = { record = function() end }
    end })
    Core2.Http = Core.Http
    stubs.loadFile(env2, 'server/scene_audio.lua')
    stubs.tick(200)
    local n2 = R2.store.get(pid)
    check(n2 and n2.fields.resolved and n2.fields.resolved.pending, 'after the restart the source is back, pending')
    eq(asked(PLS), 2, 'the start sweep asks for it again')
    answer(PLS, 200, '[playlist]\nFile1=https://radio.example.com/p.mp3\n')
    answer(PLS, 200, '[playlist]\nFile1=https://radio.example.com/p.mp3\n')
    eq(R2.store.get(pid).fields.resolved.url, 'https://radio.example.com/p.mp3', 'and resolves in the new session')
    eq(R2.audio.stats().sources, 1, 'the new session tracks it')
end

--------------------------------------------------------------------------------------------------------------------
-- CLIENT (the real materialiser + movers; natives are per-VM recording stubs)
--------------------------------------------------------------------------------------------------------------------

-- fxlint-disable-next-line S006 -- offline harness loads the checked-in stubs and files only
local CH = dofile(here .. '/client_scene_harness.lua')
local PED <const> = 77
local SRC <const> = { type = 'clip', url = 'https://radio.example.com/a.mp3', loop = false, t0 = 5000, rate = 1,
    paused = false, offset = 0, volume = 1, category = 'sfx',
    resolved = { url = 'https://radio.example.com/a.mp3', codec = 'audio/mpeg', kind = 'mp3' } }
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = type(v) == 'table' and copy(v) or v end return o end

--- A client VM with client/scene_audio.lua loaded after the materialiser and the movers -> h, V (its recordings).
local function client(opts)
    opts = opts or {}
    local h = CH.new()
    local e = h.env
    e.GetNetworkTimeAccurate = function() return 500000 + h.now() end
    e.GetFrameCount = function() return math.floor(h.now() / 16) end
    h.load('lib/clock/shared.lua', e.Core.Clock)     -- the lib captured the natives at its first load: again
    h.loadMat()
    local V = { h = h, nui = {}, probes = {}, kvp = opts.kvp or {}, prof = {}, settings = {}, rooms = {}, pause = false,
        hidden = false, ready = opts.ready ~= false, lint = 0, lroom = 0, veh = 0, vclass = 1, roof = true,
        conv = false, roofState = 0, under = false, hit = false }
    e.SendNuiMessage = function(s) V.nui[#V.nui + 1] = s return true end
    e.GetProfileSetting = function(id) return V.prof[id] or 10 end
    e.IsPauseMenuActive = function() return V.pause and 1 or false end
    e.PlayerPedId = function() return PED end
    e.GetInteriorFromEntity = function() return V.lint end
    e.GetRoomKeyFromEntity = function(ent) return ent == PED and V.lroom or (V.rooms[ent] or 0) end
    e.GetVehiclePedIsIn = function() return V.veh end
    e.GetVehicleClass = function() return V.vclass end
    e.DoesVehicleHaveRoof = function() return V.roof and 1 or false end
    e.IsVehicleAConvertible = function() return V.conv and 1 or false end
    e.GetConvertibleRoofState = function() return V.roofState end
    e.IsPedSwimmingUnderWater = function() return V.under and 1 or false end
    e.StartShapeTestLosProbe = function(...) V.probes[#V.probes + 1] = table.pack(...) return #V.probes end
    e.GetShapeTestResult = function() return 2, V.hit and 1 or 0, h.stubs.vector3(0.0, 0.0, 0.0),
        h.stubs.vector3(0.0, 0.0, 1.0), 0 end
    e.StartExpensiveSynchronousShapeTestLosProbe = function() error('the synchronous probe is never used') end
    e.GetResourceKvpString = function(k) return V.kvp[k] end
    e.SetResourceKvp = function(k, v) V.kvp[k] = v end
    e.Core.UI.isHidden = function() return V.hidden end
    e.Core.UIInternal = { isNuiReady = function() return V.ready end }
    e.Core.Settings = { get = function(k) return V.settings[k] end }
    h.load('client/scene_audio.lua')
    h.cam(0, 0, 0, 0, 0)
    V.A, V.M = h.C.audio, h.C.mat
    return h, V
end
local function stop(h) h.C.mat.shutdown() h.env.TriggerEvent('onClientResourceStop', 'core') h.tick(500) end
--- Decoded messages of `action` after index `from` (0 = all).
local function msgs(V, action, from)
    local out = {}
    for i = (from or 0) + 1, #V.nui do
        local m = json.decode(V.nui[i])
        if m and m.action == action then out[#out + 1] = m end
    end
    return out
end
local function src(h, id, over, extra)                -- over: fields to change, `false` = remove
    local f = copy(SRC)
    for k, v in pairs(over or {}) do if v == false then f[k] = nil else f[k] = v end end
    return h.node(id, 'audio.source', 6, 0, 0, 0, f, extra)
end
local function emitter(h, id, sid, x, y, z, over, extra)
    local f = { source = sid, range = 40, volume = 1, curve = 'game', ref = 2, priority = 3, occlusion = true }
    for k, v in pairs(over or {}) do f[k] = v end
    local n = h.node(id, 'audio', 6, x, y, z, f, extra)
    h.C.mat.add(n) return n
end

-- 9. shape, the predecessor assert, idle -----------------------------------------------------------------------
do
    local h0 = CH.new()                                   -- the materialiser without the movers
    for _, f in ipairs({ 'client/scene_mat_assets.lua', 'client/scene_materializer.lua' }) do h0.load(f) end
    local ok, err = pcall(h0.load, 'client/scene_audio.lua')
    check(not ok and tostring(err):find('client/scene_movers.lua', 1, true), 'asserts client/scene_movers.lua first')
    h0.C.mat.shutdown()
    local h, V = client()
    for _, fn in ipairs({ 'stats', 'positionOf', 'occlusionOf', 'listener' }) do eq(type(V.A[fn]), 'function', fn) end
    local hd = V.A.handler
    check(hd.class == 'audio' and hd.fade == 'self' and hd.budget == 'audio', "handler class 'audio', fade 'self'")
    local a, b, c = hd.radii({ fields = { range = 30 } })
    check(a == 30 and b == 50 and c == 70, 'radii: range | +20 (enters silent) | +40')
    h.tick(3000)
    eq(#V.nui, 0, 'nothing materialised: not one NUI message (the page loads no audio engine)')
    check(V.A.stats().looping == false and V.A.stats().feeds == 0, 'and no listener loop')
    stop(h)
end

-- 10. lifecycle through the materialiser: exact messages, sources ref-counted by live emitters -------------------
do
    local h, V = client()
    src(h, 10)
    local n11 = emitter(h, 11, 10, 5, 0, 0)
    h.tick(1000)
    eq(V.nui[1], '{"action":"audio:prefs","hrtf":false,"maxVoices":32,"offsetMs":0,"streams":true,"decoders":4,'
        .. '"clipCacheMb":64,"hrtfVoices":8}', 'the first message primes the page with the prefs')
    eq(V.nui[2], '{"action":"audio:source","id":10,"type":"clip","url":"https://radio.example.com/a.mp3",'
        .. '"loop":false,"t0":5000,"rate":1,"paused":false,"offset":0,"volume":1,"category":"sfx",'
        .. '"codec":"audio/mpeg","kind":"mp3","trusted":false}',
        'then the source, exactly')
    eq(V.nui[3], '{"action":"audio:emitter","id":11,"source":10,"x":5.00,"y":0.00,"z":0.00,"range":40,"volume":1,'
        .. '"curve":"game","ref":2,"priority":3,"occlusion":true}', 'then the emitter, exactly')
    local f = msgs(V, 'audio:feed')
    check(#f >= 1 and f[1].env and f[1].master == 1 and f[1].paused == false and f[1].t ~= nil,
        'the first feed is whole: env, volumes, paused, the clock')
    local mark = #V.nui
    V.M.update(n11, 'fields', { 'range' })
    h.tick(200)
    eq(#msgs(V, 'audio:emitter', mark) + #msgs(V, 'audio:source', mark), 0,
        'an update that changes nothing sends nothing')
    n11.fields.range = 60
    V.M.update(n11, 'fields', { 'range' })
    h.tick(200)
    local em = msgs(V, 'audio:emitter', mark)
    check(#em == 1 and em[1].range == 60 and #msgs(V, 'audio:source', mark) == 0, 'a changed field: the emitter alone')
    mark = #V.nui
    local s10 = h.nodes[10]
    s10.fields.paused, s10.fields.pausedAt = true, 6000
    V.M.update(n11, 'dep')
    h.tick(200)
    local so = msgs(V, 'audio:source', mark)
    check(#so == 1 and so[1].paused == true and so[1].pausedAt == 6000 and #msgs(V, 'audio:emitter', mark) == 0,
        "a source change ('dep'): the source alone")
    mark = #V.nui
    local n12 = emitter(h, 12, 10, -5, 0, 0, { cone = { inner = 90, outer = 180, outerGain = 0.2 } }, { rz = 90.0 })
    h.tick(1000)
    em = msgs(V, 'audio:emitter', mark)
    check(#em == 1 and em[1].id == 12 and #msgs(V, 'audio:source', mark) == 0, 'a second emitter: its source is there')
    check(em[1].cone and em[1].cone.inner == 90 and em[1].rz == 90, 'a cone carries the rotation')
    mark = #V.nui
    emitter(h, 13, 10, 0, 7, 1, { zone = { type = 'box', size = { x = 4, y = 6, z = 3 } } }, { rz = 45.0 })
    emitter(h, 14, 10, 0, -7, 1, { zone = { type = 'polygon', points = { { 0, 0 }, { 5, 0 }, { 5, 5 } }, minZ = 0,
        maxZ = 4 } })
    h.tick(1000)
    em = msgs(V, 'audio:emitter', mark)
    local byId = {}
    for _, m in ipairs(em) do byId[m.id] = m end
    local z13, z14 = byId[13] and byId[13].zone, byId[14] and byId[14].zone
    check(z13 and z13.coords.x == 0 and z13.coords.y == 7 and z13.coords.z == 1 and z13.rotation == 45,
        'a box zone without coords / rotation sits on the emitter with its yaw')
    check(z14 and z14.coords == nil and #z14.points == 3 and z14.points[2][1] == 5, 'a polygon zone goes as it is')
    V.M.remove(h.nodes[13], 0)
    V.M.remove(h.nodes[14], 0)
    h.tick(1000)
    mark = #V.nui
    V.M.remove(n11, 0)
    h.tick(1000)
    local rm = msgs(V, 'audio:remove', mark)
    check(#rm == 1 and #rm[1].ids == 1 and rm[1].ids[1] == 11 and rm[1].fadeMs == 300, 'the first emitter goes alone')
    mark = #V.nui
    V.M.remove(n12, 0)
    h.tick(1000)
    rm = msgs(V, 'audio:remove', mark)
    check(#rm == 1 and rm[1].ids[1] == 12 and rm[1].ids[2] == 10, 'the last emitter takes its source with it')
    mark = #V.nui
    for i = 1, 20 do
        h.cam(i * 3, 0, 0, 0, i * 5) h.tick(100)
    end
    eq(#V.nui, mark, 'no emitter left: the loop is gone, the moving camera sends nothing')
    check(not V.A.stats().looping and V.A.stats().emitters == 0 and V.A.stats().sources == 0, 'stats agree')
    stop(h)
end

-- 11. sources that cannot play (yet): pending, failed, voice, late ----------------------------------------------
do
    local h, V = client()
    src(h, 20, { type = 'stream', url = 'https://radio.example.com/listen.pls', resolved = { pending = true } })
    local n21 = emitter(h, 21, 20, 3, 0, 0)
    src(h, 30, { resolved = { error = 'host' } })
    emitter(h, 31, 30, 4, 0, 0)
    src(h, 35, { type = 'voice', url = false, resolved = false })
    emitter(h, 36, 35, 4, 1, 0)
    emitter(h, 41, 40, 6, 0, 0)                            -- its source is not in the cache (yet)
    h.tick(1500)
    eq(V.A.stats().emitters, 4, 'four emitters are live')
    eq(#msgs(V, 'audio:source') + #msgs(V, 'audio:emitter'), 0, 'none of them can play: nothing on the page')
    eq(#msgs(V, 'audio:feed'), 0, 'and no feed while the page has nothing to place')
    local s20 = h.nodes[20]
    s20.fields.resolved = { url = 'https://radio.example.com/live', codec = 'audio/ogg', kind = 'ogg' }
    V.M.update(n21, 'dep')
    h.tick(300)
    local so = msgs(V, 'audio:source')
    check(#so == 1 and so[1].id == 20 and so[1].url == 'https://radio.example.com/live' and so[1].kind == 'ogg'
        and so[1].type == 'stream', 'resolved: the stream goes with its resolved URL and decoder kind')
    check(#msgs(V, 'audio:emitter') == 1 and #msgs(V, 'audio:feed') >= 1, 'with its emitter, then the feed starts')
    src(h, 40)
    h.tick(600)
    check(#msgs(V, 'audio:emitter') == 2, 'a source that arrived after its emitter is picked up at the next pass')
    local mark = #V.nui
    s20.fields.resolved = { error = 'fetch' }
    V.M.update(n21, 'dep')
    h.tick(300)
    local rm = msgs(V, 'audio:remove', mark)
    check(#rm == 1 and rm[1].ids[1] == 21 and rm[1].ids[2] == 20, 'a source that fails leaves with its emitter')
    stop(h)
end

-- 12. the feed: right after the first emitter, 1 Hz heartbeat, thresholds, 20 Hz cap, pause, volumes, environment --
do
    local h, V = client()
    src(h, 10)
    emitter(h, 11, 10, 5, 0, 0)
    h.tick(1000)
    local iE, iF
    for i, s in ipairs(V.nui) do
        local m = json.decode(s)
        if m.action == 'audio:emitter' and not iE then iE = i end
        if m.action == 'audio:feed' and not iF then iF = i end
    end
    check(iE and iF == iE + 1, 'the first feed right after the first emitter reached the page')
    local f1 = json.decode(V.nui[iF])
    check(f1.t >= 500000 and f1.t <= 500000 + h.now(), 'the feed carries Core.Clock.now() (network time)')
    local function last(from, key)                      -- the newest feed after `from` (carrying `key`)
        local out
        for _, m in ipairs(msgs(V, 'audio:feed', from)) do out = (key == nil or m[key] ~= nil) and m or out end
        return out
    end
    local mark = #V.nui
    h.tick(3000)
    local f = msgs(V, 'audio:feed', mark)
    check(#f >= 2 and #f <= 4, 'a still listener: the 1 Hz heartbeat only (' .. #f .. ' in 3 s)')
    check(f[1].env == nil and f[1].master == nil and f[1].paused == nil and f[1].moving == nil and f[1].occl == nil
        and f[1].lx ~= nil and f[1].t ~= nil, 'a heartbeat carries the listener and the clock only')
    h.cam(1, 0, 0, 0, 0) h.tick(120)
    mark = #V.nui
    h.cam(1.1, 0, 0, 0, 0) h.tick(300)
    eq(#msgs(V, 'audio:feed', mark), 0, 'moved 0.1 m: no feed')
    h.cam(1.3, 0, 0, 0, 0) h.tick(120)
    f = msgs(V, 'audio:feed', mark)
    check(#f == 1 and math.abs(f[1].lx - 1.3) < 0.01, 'moved 0.3 m from the last sent pose: one feed')
    mark = #V.nui
    h.cam(1.3, 0, 0, 0, 1) h.tick(300)
    eq(#msgs(V, 'audio:feed', mark), 0, 'turned 1 deg: no feed')
    h.cam(1.3, 0, 0, 0, 3) h.tick(120)
    eq(#msgs(V, 'audio:feed', mark), 1, 'turned 3 deg: one feed')
    h.cam(1.3, 0, 0, 0, 90) h.tick(120)
    f = last(mark)
    check(math.abs(f.fx + 1) < 1e-3 and math.abs(f.fy) < 1e-3 and math.abs(f.uz - 1) < 1e-3,
        'yaw 90: forward -x, up +z')
    mark = #V.nui
    for i = 1, 62 do
        h.cam(1.3 + i, 0, 0, 0, 90) h.tick(16)
    end
    f = msgs(V, 'audio:feed', mark)
    check(#f >= 15 and #f <= 21, 'a camera moving every frame: at most 20 feeds a second (' .. #f .. ')')
    check(f[#f].vx > 10, 'with the listener velocity')
    h.cam(0, 0, 0, 0, 0) h.tick(1200)
    mark = #V.nui
    V.pause = true h.tick(150)
    f = last(mark, 'paused')
    check(f and f.paused == true, 'the pause menu opens: paused within one pass')
    V.pause = false h.tick(150)
    check(last(mark, 'paused').paused == false, 'and unpaused')
    V.hidden = true h.tick(150)
    check(last(mark, 'paused').paused == true, 'the §31 shell hidden: paused too')
    V.hidden = false h.tick(150)
    mark = #V.nui
    V.prof[300] = 5 h.tick(1200)
    f = last(mark, 'sfx')
    check(f and math.abs(f.sfx - 0.5) < 1e-3 and math.abs(f.ambience - 0.5) < 1e-3 and math.abs(f.voice - 0.5) < 1e-3
        and f.music == 1 and f.master == 1, 'GetProfileSetting(300) / 10 scales sfx, ambience and voice')
    mark = #V.nui
    V.lint, V.lroom = 5, 9 h.tick(400)
    f = last(mark, 'env')
    check(f and f.env.interior == 5 and f.env.room == 9 and f.env.vehicle == false, 'the listener goes inside: env')
    local o = last(mark, 'occl')
    check(o and math.abs(o.occl.n11 - 0.85) < 1e-3, 'an outdoor emitter heard from inside: occlusion 0.85 (n<id> keys)')
    V.lint, V.lroom = 0, 0 h.tick(400)
    check(last(mark, 'occl').occl.n11 == 0, 'back outside: 0 again')
    mark = #V.nui
    V.veh = 900 h.tick(400)
    check(last(mark, 'env').env.vehicle == true and math.abs(last(mark, 'occl').occl.n11 - 0.35) < 1e-3,
        'a closed vehicle: env.vehicle, +0.35')
    V.veh, V.conv, V.roofState = 901, true, 2 h.tick(400)
    check(last(mark, 'env').env.vehicle == false, 'a convertible with the roof down is open')
    V.veh, V.conv, V.vclass = 902, false, 8 h.tick(400)
    check(last(mark, 'env').env.vehicle == false, 'a motorcycle is open')
    V.veh, V.under = 0, true h.tick(400)
    check(last(mark, 'env').env.underwater == true and math.abs(last(mark, 'occl').occl.n11 - 0.8) < 1e-3,
        'under water: env.underwater, 0.8')
    V.under = false
    -- a moving emitter: attached to player 5's ped; the feed carries its position
    local ped5 = h.newEntity(0, 20, 0, 0, 1)
    h.players[5] = ped5
    emitter(h, 51, 10, 20, 0, 0, nil, { attach = { p = 5 } })
    h.tick(1000)
    local em = msgs(V, 'audio:emitter')
    check(em[#em].id == 51 and math.abs(em[#em].x - 20) < 0.01, 'the attached emitter starts at the ped')
    mark = #V.nui
    h.ents[ped5].x = 25 h.tick(300)
    f = last(mark, 'moving')
    check(f and f.moving.n51 and math.abs(f.moving.n51.x - 25) < 0.01, 'the ped moved: moving.n51 follows it')
    mark = #V.nui
    h.tick(300)
    eq(last(mark, 'moving'), nil, 'no further movement: no moving entry')
    local x, y, z = V.A.positionOf(51)
    local lx, ly, _, _, fy = V.A.listener()
    check(math.abs(x - 25) < 0.01 and y == 0 and z == 0 and V.A.occlusionOf(11) == 0.0 and V.A.positionOf(999) == nil
        and lx == 0 and ly == 0 and math.abs(fy - 1) < 1e-6, 'C.audio.positionOf / occlusionOf / listener')
    stop(h)
end

-- 13. occlusion: <= LosProbesPerSecond async probes, round-robin, never the synchronous probe; rules ------------------
do
    local h, V = client()
    h.ents[PED] = { model = 0, x = 0, y = 3, z = 0, rx = 0, ry = 0, rz = 0, type = 1, alphaLog = {} }
    h.players[1] = PED
    h.set.interiorAt = function(_, y) return y == 55 and 42 or 0 end
    src(h, 10)
    for i = 1, 20 do emitter(h, 100 + i, 10, i * 2 - 20, 15, 0, { range = 80 }) end
    emitter(h, 150, 10, 0, 55, 0, { range = 80 })                          -- inside interior 42
    emitter(h, 160, 10, 0, 3, 0, { range = 80 }, { attach = { p = 1 } })  -- carried by the local player
    emitter(h, 170, 10, 4, 15, 0, { range = 80, occlusion = false })
    h.tick(1000)
    eq(V.A.stats().emitters, 23, 'all emitters live')
    local p0 = #V.probes
    h.tick(5000)
    local n = #V.probes - p0
    check(n >= 30 and n <= 42, 'at most 8 probes a second, 2 banked (' .. n .. ' in 5 s)')
    local p = V.probes[#V.probes]
    check(p.n == 9 and p[7] == 17 and p[8] == 0 and p[9] == 7, 'LOS probe: world + objects, no entity, collider mask 7')
    local seen, far = {}, false
    for i = p0 + 1, #V.probes do
        local q = V.probes[i]
        seen[('%.1f'):format(q[4])] = true
        if q[5] > 40 then far = true end
    end
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    check(distinct >= 10, 'round-robin: many different emitters asked (' .. distinct .. ')')
    check(not far, 'the indoor emitter (rules decide) is never probed')
    local x, y = V.probes[#V.probes][4], V.probes[#V.probes][5]
    check(y < 15 and y > 13, 'the ray ends 0.5 m short of the emitter (y = ' .. y .. ', x = ' .. x .. ')')
    check(#h.stubs.failures == 0, 'no thread error: the synchronous probe was never called')
    eq(V.A.occlusionOf(150), 0.85, 'an emitter in another interior: 0.85 by rule')
    eq(V.A.occlusionOf(160), 0.0, 'an emitter carried by the listener is never occluded')
    local mark = #V.nui
    V.hit = true h.tick(3000)
    local high = 0
    for _, f in ipairs(msgs(V, 'audio:feed', mark)) do
        for k, v in pairs(f.occl or {}) do if k ~= 'n150' and v > 0.2 then high = high + 1 end end
    end
    check(high >= 5, 'blocked probes raise those emitters in the feed, smoothed (' .. high .. ')')
    check(V.A.occlusionOf(170) == 0.0, 'occlusion = false: never occluded')
    check(V.A.occlusionOf(101) <= 0.55 + 1e-9, 'the LOS share stays within the -8 dB rule')
    stop(h)
end

-- 14. prefs: /audio, the KVP, audio:prefs / audio:debug; a new session starts with them ----------------------------
do
    local kvp = {}
    local h, V = client({ kvp = kvp })
    src(h, 10)
    emitter(h, 11, 10, 5, 0, 0)
    h.tick(1000)
    local cmd = h.env.__vm.commands.audio.fn
    local mark = #V.nui
    cmd(0, { 'volume', '50' })
    h.tick(1200)
    local vf
    for _, f in ipairs(msgs(V, 'audio:feed', mark)) do if f.master then vf = f end end
    check(vf and math.abs(vf.master - 0.5) < 1e-3, '/audio volume 50: master 0.5 in the next feed')
    eq(json.decode(kvp['core:audio:prefs']).master, 0.5, 'saved in the client KVP')
    cmd(0, { 'volume', '30', 'music' })
    h.tick(1200)
    vf = nil
    for _, f in ipairs(msgs(V, 'audio:feed', mark)) do if f.music then vf = f end end
    check(vf and math.abs(vf.music - 0.3) < 1e-3, '/audio volume 30 music')
    mark = #V.nui
    for _, a in ipairs({ { 'hrtf', 'on' }, { 'streams', 'off' }, { 'offset', '120' }, { 'voices', '16' } }) do
        cmd(0, a)
    end
    local p = msgs(V, 'audio:prefs', mark)
    check(#p == 4 and p[1].hrtf == true and p[2].streams == false and p[3].offsetMs == 120 and p[4].maxVoices == 16,
        'hrtf / streams / offset / voices: one audio:prefs each')
    mark = #V.nui
    cmd(0, { 'debug', 'on' }) cmd(0, { 'debug', 'off' })
    h.env.__vm.commands.audiodebug.fn(0, {})
    local d = msgs(V, 'audio:debug', mark)
    check(#d == 3 and d[1].on == true and d[2].on == false and d[3].on == true, '/audio debug and /audiodebug')
    mark = #V.nui
    for _, bad in ipairs({ { 'volume', '150' }, { 'volume', 'x' }, { 'volume', '5', 'bass' }, { 'hrtf', 'maybe' },
        { 'offset', '5000' }, { 'voices', '0' }, { 'bogus' } }) do
        cmd(0, bad)
    end
    eq(#V.nui, mark, 'invalid arguments send nothing')
    local printed = #h.stubs.printed
    cmd(0, {})
    check(#h.stubs.printed > printed and h.stubs.printed[printed + 1]:find('emitters 1', 1, true),
        '/audio prints the state')
    h.env.TriggerEvent('core:ui:audio:stats', { voices = { real = 1, virtual = 0, max = 16 }, sources = { total = 1 },
        clock = { offset = 3, samples = 9 } })
    check(h.stubs.printed[#h.stubs.printed]:find('voices 1 real', 1, true), 'debug on: the page stats are printed')
    stop(h)
    local h2, V2 = client({ kvp = kvp })
    src(h2, 10)
    emitter(h2, 11, 10, 5, 0, 0)
    h2.tick(1000)
    local p2 = json.decode(V2.nui[1])
    check(p2.action == 'audio:prefs' and p2.hrtf == true and p2.streams == false and p2.offsetMs == 120
        and p2.maxVoices == 16, 'the next session primes the page with the saved prefs')
    stop(h2)
end

-- 15. replays (uiReady), scene.audio.enabled, the shell not ready yet, hosts, a station switch, page errors -----------
do
    local h, V = client({ ready = false })
    V.settings['scene.audio.allowHosts'] = { 'Radio.Example.com' }
    h.env.Core.emitHook('settingChanged', 'scene.audio.allowHosts', { 'Radio.Example.com' }, nil)
    src(h, 10)
    src(h, 15, { url = false, resolved = { trusted = true }, file = '@radio/sounds/horn.ogg' })
    local n11 = emitter(h, 11, 10, 5, 0, 0)
    emitter(h, 16, 15, 6, 0, 0)
    h.tick(1000)
    eq(#V.nui, 0, 'the shell has not announced itself: nothing is sent')
    V.ready = true
    h.env.Core.emitHook('uiReady')
    h.tick(100)
    local so = msgs(V, 'audio:source')
    check(#so == 2 and #msgs(V, 'audio:emitter') == 2 and json.decode(V.nui[1]).action == 'audio:prefs',
        'ui_ready: prefs, both sources, both emitters')
    local byId = {}
    for _, m in ipairs(so) do byId[m.id] = m end
    check(byId[10].hosts and byId[10].hosts[1] == 'radio.example.com' and byId[15].hosts == nil,
        'a URL source carries the allowed hosts (lower-cased), a file source none')
    check(byId[15].file == '@radio/sounds/horn.ogg' and byId[15].url == nil, 'a file source goes as file')
    check(byId[15].trusted == true and byId[10].trusted == false, 'trusted is forwarded; unknown = false')
    local mark = #V.nui
    h.env.Core.emitHook('settingChanged', 'scene.audio.allowHosts', { 'a.example.com', 'b.example.com' }, nil)
    so = msgs(V, 'audio:source', mark)
    check(#so == 1 and so[1].id == 10 and #so[1].hosts == 2, 'the host list changes: the URL source goes again')
    mark = #V.nui
    h.env.Core.emitHook('uiReady')
    h.tick(100)
    local f = msgs(V, 'audio:feed', mark)
    check(#msgs(V, 'audio:prefs', mark) == 1 and #msgs(V, 'audio:source', mark) == 2
        and #msgs(V, 'audio:emitter', mark) == 2, 'a reloaded shell hears everything again')
    check(#f >= 1 and f[1].env and f[1].master and f[1].paused ~= nil, 'with a whole feed right away')
    mark = #V.nui
    h.env.Core.emitHook('settingChanged', 'scene.audio.enabled', false, true)
    local rm = msgs(V, 'audio:remove', mark)
    local ids = {}
    for _, id in ipairs(rm[1] and rm[1].ids or {}) do ids[id] = true end
    check(#rm == 1 and ids[10] and ids[11] and ids[15] and ids[16], 'audio off: everything leaves the page at once')
    mark = #V.nui
    h.cam(30, 0, 0, 0, 45) h.tick(2500)
    eq(#V.nui, mark, 'audio off: not one message, feeds included')
    h.env.Core.emitHook('settingChanged', 'scene.audio.enabled', true, false)
    h.tick(100)
    check(#msgs(V, 'audio:emitter', mark) == 2 and #msgs(V, 'audio:feed', mark) >= 1, 'audio on: all back')
    -- a station switch: the new source, the emitter on it (the page crossfades), then the old source
    src(h, 60, { url = 'https://radio.example.com/b.mp3',
        resolved = { url = 'https://radio.example.com/b.mp3', codec = 'audio/mpeg', kind = 'mp3' } })
    mark = #V.nui
    n11.fields.source = 60
    V.M.update(n11, 'fields', { 'source' })
    h.tick(200)
    local order = {}
    for i = mark + 1, #V.nui do
        local m = json.decode(V.nui[i])
        if m.action ~= 'audio:feed' then order[#order + 1] = m end
    end
    check(#order == 3 and order[1].action == 'audio:source' and order[1].id == 60 and order[2].action == 'audio:emitter'
        and order[2].source == 60 and order[3].action == 'audio:remove' and order[3].ids[1] == 10,
        'switch: source 60, emitter 11 on it, then source 10 goes')
    -- the page's answers (ui_event bridge)
    local w = #h.warnings
    h.env.TriggerEvent('core:ui:audio:error', { id = 11, code = 'bad_url' })
    h.env.TriggerEvent('core:ui:audio:error', { id = 11, code = 'bad_url' })
    h.env.TriggerEvent('core:ui:audio:error', 'junk')
    check(#h.warnings == w + 1 and h.warnings[#h.warnings]:find('bad_url', 1, true), 'a page error is logged once')
    eq(V.A.stats().errors, 2, 'and counted every time')
    stop(h)
    check(#h.stubs.failures == 0, 'client: no uncaught thread error (' .. tostring(h.stubs.failures[1]) .. ')')
end

H.finish()
