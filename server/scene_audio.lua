--[[
    core/server/scene_audio.lua — Core.Scene audio, the server policy (DESIGN §55.16, §55.19, §55.20). Loads right
    after server/scene.lua (… → scene_store → scene → [scene_promote] → scene_audio → scene_voice); it asserts only
    R.store and R.kinds and fills R.audio of the internal Core.SceneRuntime (block-listed in server/api.lua).

      R.audio.check(fields) -> true, fields | false, code, fieldName
            The audio.source post-check server/scene_kinds.lua runs on every spawn / set of a source: https only,
            the host must match the Core.Settings list `scene.audio.allowHosts`, `file` = '@<started resource>/<sane
            path>' inside that resource's files {}, codec by extension (MP3, Ogg/Opus/Vorbis, FLAC, WebM pass; WAV for
            clips and loops; AAC/M4A only with Config.Scene.Audio.AllowAac; m3u/m3u8/pls/xspf only for streams),
            timeline items need a duration. It never blocks: it fills the server-filled field `resolved` = { url,
            codec, kind = 'mp3'|'ogg'|'hls' } at once, or { pending = true } (a playlist, a stream without a
            telling extension) and answers later through Scene.set as core, or { error = code }. `resolved.trusted`
            (server-owned; the page decodes only trusted sources into PCM): false for remote URLs and for anything
            played on a player's behalf (Scene.audio.play with `by`, kept while that content plays), true for
            resource files chosen by server code. A file / timeline source gets `resolved = { trusted }` too.
      Scene.audio.play(def) -> id | nil, err, detail      def = a Scene.spawn def of an audio.source (kind implied),
            or { id = sourceId, fields = patch } to retarget one, plus `by = src`: a play on behalf of that player —
            1 per 5 s per player, audited ('scene.audio.play'). Refusals: 'def' 'by' 'rate_limit' 'missing', the
            spawn / set errors unchanged ('audio_disabled' | 'audio_streams' | 'audio_rate' from admit included).
      Scene.audio.kill(id | 'all', by?) -> true, n | false, 'missing'   removes sources (their emitters go with them)
            or emitters whatever their owner (the kill switch; server-only API), audited ('scene.audio.kill').
      Scene.audio.stats() / R.audio.stats() -> table
      R.audio.admit(def, owner) -> true | false, code      the spawn policy of audio.source (Scene.spawn calls it
            directly, not through a hook): `scene.audio.enabled` (new sources refused while off; clients stop playing
            through the replicated setting) -> 'audio_disabled', `scene.audio.maxStreams` stream sources server-wide
            -> 'audio_streams', a flood guard per owning resource (a bucket of 120 spawns, 20 per second back; core
            exempt) -> 'audio_rate'.
    `scene.audio.allowHosts` replicates too: the page keeps redirects and HLS segments inside it.
    Titles: every 20 s, for stream sources with a dependent emitter in a subscribed cell only, one Icecast
    `status-json.xsl` per origin (backed off 5 min after a failure) -> Scene.set(id, { title }).
    A live stream is never fetched here (PerformHttpRequest would buffer it for ever): the codec of a stream URL
    without a telling extension comes from the origin's status-json (else MP3 is assumed); playlists are fetched
    (<= 64 KiB), at most 2 requests at a time, answers cached (unused ones 10 min, failures 1 min).

    Natives: GetResourceState(resourceName) (CFX shared), GetNumResourceMetadata(resourceName, metadataKey),
    GetResourceMetadata(resourceName, metadataKey, index) (CFX shared), GetPlayerName(playerSrc) (CFX server) — fxref
    2026-09-27. CreateThread, Wait, SetTimeout, AddEventHandler, json are runtime helpers; HTTP goes through
    Core.Http (loaded after this file: looked up at call time).
]]

local R = Core.SceneRuntime
assert(R and R.store and R.kinds, 'server/scene.lua must load before server/scene_audio.lua (R.store, R.kinds)')

local Scene = Core.Scene
local Utils, Log, Registry, Settings = Core.Utils, Core.Log, Core.Registry, Core.Settings
local store = R.store

local type, pairs, next, pcall, tostring, tonumber = type, pairs, next, pcall, tostring, tonumber
local toint, huge = math.tointeger, math.huge

local PLAYER_COOLDOWN_MS <const> = 5000
local OWNER_BURST <const>, OWNER_RATE <const> = 120, 20
local HTTP_TIMEOUT_MS <const> = 8000
local MAX_BODY <const> = 65536
local MAX_WORKERS <const>, MAX_QUEUE <const> = 2, 64
local CACHE_MAX <const>, CACHE_TTL_MS <const>, ERROR_TTL_MS <const> = 256, 600000, 60000
local TITLE_MS <const>, STATUS_BACKOFF_MS <const> = 20000, 300000
local MAX_NEST <const> = 2
local TITLE_MAX <const> = 128
local EMPTY <const> = {}
local NO_REMOVE <const> = {}

local function cfgAudio() return (Config.Scene or EMPTY).Audio or EMPTY end
local function isFinite(v) return type(v) == 'number' and v == v and v ~= huge and v ~= -huge end

local A = {}
local stat = { resolved = 0, failed = 0, requests = 0, polls = 0, titles = 0, plays = 0, kills = 0,
    refusedPlayer = 0, refusedRate = 0, refusedStreams = 0, refusedDisabled = 0 }

--------------------------------------------------------------------------------
-- Settings (§45): scene.audio.enabled (replicated), scene.audio.allowHosts, scene.audio.maxStreams
--------------------------------------------------------------------------------

local state = { enabled = true, hosts = {}, maxStreams = 8 }

local SECTION <const> = { id = 'scene', title = 'Scene audio', icon = 'volume', order = 820, properties = {
    ['scene.audio.enabled'] = { type = 'boolean', default = true, replicate = true, group = 'Audio', order = 1,
        label = 'World audio', description = 'Positional audio of Core.Scene (clips, loops, timelines, streams). '
            .. 'Off: players hear none of it and new audio sources are refused.' },
    ['scene.audio.allowHosts'] = { type = 'array', default = {}, maxItems = 64, replicate = true, group = 'Audio',
        order = 2, items = { type = 'string', minLength = 1, maxLength = 253, pattern = '^[%w%*%.%-]+$' },
        label = 'Allowed hosts', description = 'https hosts audio URLs and playlists may use: "radio.example.com", '
            .. '"*.example.com" (its subdomains), "*" (any). Empty: only files shipped in resources.' },
    ['scene.audio.maxStreams'] = { type = 'integer', default = 8, min = 0, max = 64, group = 'Audio', order = 3,
        label = 'Stream sources', description = 'Live stream sources (radio) that may exist at once, server-wide.' },
} }

--- Lower-cased patterns without a trailing dot; anything unusable is dropped.
local function normHosts(list)
    local out = {}
    for i = 1, type(list) == 'table' and #list or 0 do
        local h = list[i]
        if type(h) == 'string' and h ~= '' then
            h = h:lower():gsub('%.$', '')
            if h ~= '' then out[#out + 1] = h end
        end
    end
    return out
end

local cache, cacheN, urlUsers = {}, 0, {}      -- [url] = { r, at, err }; [url] = { [sourceId] = true }

--- Answers nobody uses any more go when the host list changes (in-use ones stay: their sources keep playing).
local function purgeUnused()
    for url in pairs(cache) do
        if not urlUsers[url] then cache[url], cacheN = nil, cacheN - 1 end
    end
end

local function apply(key, value)
    if key == 'scene.audio.enabled' then
        state.enabled = value ~= false
    elseif key == 'scene.audio.allowHosts' then
        state.hosts = normHosts(value)
        purgeUnused()
    elseif key == 'scene.audio.maxStreams' then
        local n = toint(value)
        state.maxStreams = (n and n >= 0) and n or 8
    end
end

if Settings and Settings.define then
    local ok, err = Settings.define(SECTION)
    if not ok then Log.error('scene audio: settings section refused: %s', tostring(err)) end
    Settings.onChange('scene.audio.', function(key, value) apply(key, value) end)
end

--- Settings.get may yield once (the overrides load): only from a thread.
local function readSettings()
    if not (Settings and Settings.get) then return end
    for key in pairs(SECTION.properties) do apply(key, Settings.get(key)) end
end

--------------------------------------------------------------------------------
-- Policy: URLs, hosts, files, codecs (§55.16, §55.19: https, allow-listed, server-resolved)
--------------------------------------------------------------------------------

-- extension -> { codec, decoder kind }: 'mp3' = fetch + ICY + MSE, 'ogg' = a media element, 'hls' = hls.js
local DIRECT <const> = {
    mp3 = { 'audio/mpeg', 'mp3' }, mpga = { 'audio/mpeg', 'mp3' },
    ogg = { 'audio/ogg', 'ogg' }, oga = { 'audio/ogg', 'ogg' }, opus = { 'audio/ogg; codecs=opus', 'ogg' },
    flac = { 'audio/flac', 'ogg' }, webm = { 'audio/webm', 'ogg' }, weba = { 'audio/webm', 'ogg' },
}
local WHOLE <const> = { wav = { 'audio/wav', 'ogg' } }                    -- decoded whole: clips and loops only
local AAC <const> = { aac = { 'audio/aac', 'ogg' }, adts = { 'audio/aac', 'ogg' }, m4a = { 'audio/mp4', 'ogg' },
    mp4 = { 'audio/mp4', 'ogg' } }
local PLAYLIST <const> = { m3u = true, m3u8 = true, pls = true, xspf = true }
local HLS_TYPE <const> = 'application/vnd.apple.mpegurl'

--- 'https://[host](:port)/path?q#f' -> { host (lower), origin, path } | nil, code. Credentials are refused.
local function parseUrl(url)
    if type(url) ~= 'string' or #url > 512 then return nil, 'url' end
    local rest = url:match('^[Hh][Tt][Tt][Pp][Ss]://(.+)$')
    if not rest then return nil, 'https' end
    local authority, path = rest:match('^([^/?#]*)(.*)$')
    if not authority or authority == '' or authority:find('@', 1, true) or url:find('%s') then return nil, 'url' end
    local host, port = authority:match('^%[([%x:%.]+)%](.*)$')
    if not host then host, port = authority:match('^([^:]+)(.*)$') end
    if not host or (port ~= '' and not port:match('^:%d%d?%d?%d?%d?$')) then return nil, 'url' end
    host = host:lower()
    if not host:match('^[%w%.%-:]+$') then return nil, 'url' end
    local p = path:match('^([^?#]*)')
    return { host = host, origin = 'https://' .. authority, path = (p == nil or p == '') and '/' or p }
end

--- The extension of a path's last segment, lower-cased ('/a/b.MP3' -> 'mp3'), or nil.
local function extOf(path)
    local e = path:match('%.(%w+)$')
    return e and e:lower() or nil
end

local function hostAllowed(host)
    local list = state.hosts
    for i = 1, #list do
        local p = list[i]
        if p == '*' or p == host then return true end
        if p:sub(1, 2) == '*.' then
            local base = p:sub(2)                                  -- '.example.com'
            if #host > #base and host:sub(-#base) == base then return true end
        end
    end
    return false
end

--- codec, kind for an extension and a source type; nil = unknown; false, code = refused.
local function codecOf(ext, t)
    local d = ext and (DIRECT[ext] or WHOLE[ext] or AAC[ext])
    if not d then return nil end
    if WHOLE[ext] and t ~= 'clip' and t ~= 'loop' and t ~= 'item' then return false, 'codec' end
    if AAC[ext] and cfgAudio().AllowAac ~= true then return false, 'codec' end
    return d[1], d[2]
end

--- A content type (status-json server_type, a playlist answer) -> codec, kind | false, 'codec' | nil.
local function codecOfType(ct)
    if type(ct) ~= 'string' then return nil end
    ct = ct:lower()
    if ct:find('mpegurl', 1, true) then return HLS_TYPE, 'hls' end
    if ct:find('aac', 1, true) or ct:find('mp4', 1, true) then
        if cfgAudio().AllowAac ~= true then return false, 'codec' end
        return ct:match('^[^;]+'), 'ogg'
    end
    if ct:find('mpeg', 1, true) or ct:find('mp3', 1, true) then return 'audio/mpeg', 'mp3' end
    if ct:find('ogg', 1, true) or ct:find('opus', 1, true) or ct:find('vorbis', 1, true) or ct:find('flac', 1, true)
        or ct:find('webm', 1, true) then
        return ct:match('^[^;]+'), 'ogg'
    end
    return nil
end

-- files {} globs of a resource, read once per resource start
local globs = {}

--- A files {} glob as a Lua pattern: '**' = any depth, '*' = within one segment.
local function globPattern(g)
    local p = g:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*%*', '\1'):gsub('%*', '[^/]*'):gsub('\1', '.*')
    return '^' .. p .. '$'
end

local function inFiles(res, path)
    local list = globs[res]
    if not list then
        list = {}
        for i = 0, (GetNumResourceMetadata(res, 'file') or 0) - 1 do
            local g = GetResourceMetadata(res, 'file', i)
            if type(g) == 'string' and g ~= '' then list[#list + 1] = globPattern(g:gsub('^%./', '')) end
        end
        globs[res] = list
    end
    for i = 1, #list do
        if path:find(list[i]) then return true end
    end
    return false
end

--- '@<resource>/<path>': a started resource, a sane relative path inside its files {}, a known audio extension.
local function checkFile(file, t)
    if type(file) ~= 'string' then return false, 'file' end
    local res, path = file:match('^@([%w_%-%.]+)/(.+)$')
    if not res or res == '.' or res == '..' or path:find('\\', 1, true) or path:find('//', 1, true)
        or path:sub(-1) == '/' then return false, 'file' end
    for seg in path:gmatch('[^/]+') do
        if seg == '.' or seg == '..' then return false, 'file' end
    end
    local st = GetResourceState(res)
    if st ~= 'started' and st ~= 'starting' then return false, 'resource' end
    if not inFiles(res, path) then return false, 'files' end
    local ext = extOf(path)
    if ext and PLAYLIST[ext] then return false, 'playlist' end
    local codec, err = codecOf(ext, t)
    if codec == false then return false, err end
    if not codec then return false, 'codec' end
    return true
end

--- A URL: parsed, allowed, classified -> u, how ('direct' | 'list' | 'probe'), codec, kind | nil, code.
local function classify(url, t)
    local u, err = parseUrl(url)
    if not u then return nil, err end
    if not hostAllowed(u.host) then return nil, 'host' end
    local ext = extOf(u.path)
    if ext and PLAYLIST[ext] then
        if t ~= 'stream' then return nil, 'playlist' end   -- a playlist names a station: streams only
        return u, 'list'
    end
    local codec, kind = codecOf(ext, t)
    if codec == false then return nil, kind end
    if codec then return u, 'direct', codec, kind end
    if t == 'stream' then return u, 'probe' end          -- the origin's status-json names the codec
    return u, 'direct'                                    -- a clip of unknown type: the page sniffs it
end

--------------------------------------------------------------------------------
-- R.audio.check — scene_kinds.lua's audio.source post-check (never yields, never blocks)
--------------------------------------------------------------------------------

local function now() return R.now() end

-- Trust (`resolved.trusted`, the page's decode-bomb guard: an untrusted source never becomes PCM, a media element
-- plays it): only resource files chosen by server code are trusted. A remote URL is not, and nothing played on a
-- player's behalf is: `playingBy` is set only across Scene.audio.play's own (synchronous) spawn / set, and the files
-- of such player-chosen sources stay untrusted for every later check while one of them plays them.
local playingBy = nil                  -- the player a Scene.audio.play spawns / sets for, right now
local untrustedFiles = {}              -- [file] = player-chosen sources playing it

--- The cached answer for `url` as a fresh table, or nil (a miss, an expired failure, an unused old answer).
local function cached(url)
    local c = cache[url]
    if not c then return nil end
    local age = R.diff(now(), c.at)
    if (c.err and age > ERROR_TTL_MS) or (not urlUsers[url] and age > CACHE_TTL_MS) then
        cache[url], cacheN = nil, cacheN - 1
        return nil
    end
    local r = {}
    for k, v in pairs(c.r) do r[k] = v end
    return r
end

function A.check(f)
    local t = f.type
    if t == 'voice' then
        f.resolved = nil
        return true, f
    end
    local trusted = playingBy == nil
    if t == 'timeline' then
        local items = f.items or EMPTY
        for i = 1, #items do
            local it = items[i]
            if not (isFinite(it.duration) and it.duration > 0) then return false, i .. '.duration', 'items' end
            if it.url ~= nil then
                local u, err = classify(it.url, 'item')
                if not u then return false, i .. '.url.' .. err, 'items' end
                trusted = false
            else
                local ok, err = checkFile(it.file, 'item')
                if not ok then return false, i .. '.file.' .. err, 'items' end
                if untrustedFiles[it.file] then trusted = false end
            end
        end
        f.resolved = { trusted = trusted }
        return true, f
    end
    if f.file ~= nil then
        local ok, err = checkFile(f.file, t)
        if not ok then return false, err, 'file' end
        f.resolved = { trusted = trusted and not untrustedFiles[f.file] }
        return true, f
    end
    local u, how, codec, kind = classify(f.url, t)
    if not u then return false, how, 'url' end
    if how == 'direct' then
        f.resolved = { url = f.url, codec = codec, kind = kind }
    else
        f.resolved = cached(f.url) or { pending = true }
    end
    f.resolved.trusted = false                                    -- remote content is never decoded whole
    return true, f
end

--------------------------------------------------------------------------------
-- Sources: tracked through the server hooks (spawned / changed / removed) and one sweep once the store loaded
--------------------------------------------------------------------------------

local srcs, nSrc = {}, 0               -- [id] = { url }
local streams, streamCount = {}, 0     -- [id] = true: stream sources (maxStreams, titles)
local fwd = {}                         -- enqueue / ensurePoller, defined below

local function addUser(url, id)
    local set = urlUsers[url]
    if not set then
        set = {}
        urlUsers[url] = set
    end
    set[id] = true
end

local function dropUser(url, id)
    local set = urlUsers[url]
    if not set then return end
    set[id] = nil
    if next(set) == nil then urlUsers[url] = nil end
end

--- The files a source plays (its file, or its timeline items' files), and a key of its whole content.
local function contentOf(f)
    if f.file ~= nil then return { f.file }, f.file end
    if f.url ~= nil then return nil, f.url end
    local files, parts, items = nil, {}, type(f.items) == 'table' and f.items or EMPTY
    for i = 1, #items do
        local it = items[i]
        parts[i] = tostring(it.url or it.file)
        if it.file ~= nil then
            files = files or {}
            files[#files + 1] = it.file
        end
    end
    return files, #parts > 0 and table.concat(parts, '|') or nil
end

--- Moves a source's player-chosen files (rec.files) to `files`, counting them in untrustedFiles.
local function setFiles(rec, files)
    for i = 1, rec.files and #rec.files or 0 do
        local f = rec.files[i]
        local n = (untrustedFiles[f] or 1) - 1
        untrustedFiles[f] = n > 0 and n or nil
    end
    for i = 1, files and #files or 0 do untrustedFiles[files[i]] = (untrustedFiles[files[i]] or 0) + 1 end
    rec.files = files
end

local function untrack(id)
    local rec = srcs[id]
    if not rec then return end
    srcs[id], nSrc = nil, nSrc - 1
    if rec.url then dropUser(rec.url, id) end
    if streams[id] then streams[id], streamCount = nil, streamCount - 1 end
    setFiles(rec, nil)
end

--- (Re)reads source `id` from the store: its URL users, the stream count, a pending resolution, the poller.
local function track(id)
    local node = store.get(id)
    if not node or node.kind ~= 'audio.source' then return untrack(id) end
    local f = node.fields or EMPTY
    local rec = srcs[id]
    if not rec then
        rec = {}
        srcs[id], nSrc = rec, nSrc + 1
    end
    local url = type(f.url) == 'string' and f.url or nil
    if rec.url ~= url then
        if rec.url then dropUser(rec.url, id) end
        if url then addUser(url, id) end
        rec.url = url
    end
    local isStream = f.type == 'stream'
    if isStream ~= (streams[id] == true) then
        streams[id] = isStream or nil
        streamCount = streamCount + (isStream and 1 or -1)
    end
    -- player-chosen: registered while Scene.audio.play is on; kept while the content stays; trusted code choosing
    -- other content clears it
    local files, content = contentOf(f)
    if playingBy ~= nil then
        setFiles(rec, files)
    elseif content ~= rec.content and rec.files then
        setFiles(rec, nil)
    end
    rec.content = content
    local r = f.resolved
    if url and type(r) == 'table' and r.pending then fwd.enqueue(url, f.type) end
    if isStream then fwd.ensurePoller() end
end

--------------------------------------------------------------------------------
-- Resolution (Core.Http, never on the caller's path): playlists, stream probes, the answer cache
--------------------------------------------------------------------------------

local jobs, queue, busy = {}, {}, 0    -- [url] = source type; FIFO of urls; running workers

--- Unused answers go, oldest first, while the cache is over its size.
local function evict()
    while cacheN > CACHE_MAX do
        local oldest, at
        for url, c in pairs(cache) do
            if not urlUsers[url] and (not at or R.diff(c.at, at) < 0) then oldest, at = url, c.at end
        end
        if not oldest then return end
        cache[oldest], cacheN = nil, cacheN - 1
    end
end

--- An answer for `url`: cached, then every source of that URL still pending takes it (Scene.set as core re-runs
--- check(), which reads the cache).
local function finish(url, r)
    if cache[url] == nil then cacheN = cacheN + 1 end
    cache[url] = { r = r, at = now(), err = r.error ~= nil }
    if r.error then stat.failed = stat.failed + 1 else stat.resolved = stat.resolved + 1 end
    evict()
    local users = urlUsers[url]
    if not users then return end
    local ids = {}
    for id in pairs(users) do ids[#ids + 1] = id end
    table.sort(ids)
    for i = 1, #ids do
        local node = store.get(ids[i])
        local res = node and node.fields.resolved
        if node and node.fields.url == url and type(res) == 'table' and res.pending then
            local ok, done, err = Registry.withCaller('core', Scene.set, ids[i], nil, { remove = NO_REMOVE })
            if not (ok and done) then
                Log.warn('scene audio: source %d keeps waiting (%s)', ids[i], tostring(ok and err or done))
            end
        end
    end
end

--- One GET through Core.Http -> body | nil, code. Yields (a worker thread).
local function fetch(url)
    local Http = rawget(Core, 'Http')
    if not (Http and Http.fetch) then return nil, 'unavailable' end
    stat.requests = stat.requests + 1
    local status, body = Http.fetch(url, { method = 'GET', timeoutMs = HTTP_TIMEOUT_MS, headers = { Accept = '*/*' } })
    if type(status) ~= 'number' or status < 200 or status > 299 then return nil, 'fetch' end
    return body
end

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
local XML <const> = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }

--- The first entry of a playlist, told by its content (servers label them loosely): pls, xspf, else one URL per
--- line (m3u) -> entry | nil, true for an HLS playlist (RFC 8216) instead.
local function firstEntry(body)
    if body:find('^%s*%[[Pp][Ll][Aa][Yy][Ll][Ii][Ss][Tt]%]') or body:find('^%s*[Ff][Ii][Ll][Ee]%d+%s*=') then
        local best, bestN
        for n, v in body:gmatch('[Ff][Ii][Ll][Ee](%d+)%s*=%s*([^\r\n]+)') do
            n = tonumber(n)
            if n and (not bestN or n < bestN) then best, bestN = trim(v), n end
        end
        return best
    end
    if body:find('<playlist', 1, true) or body:find('<location>', 1, true) then
        local loc = body:match('<location>%s*(.-)%s*</location>')
        return loc and (loc:gsub('&(%a+);', XML))
    end
    if body:find('#EXT%-X%-TARGETDURATION') or body:find('#EXT%-X%-STREAM%-INF')
        or body:find('#EXT%-X%-MEDIA%-SEQUENCE') then
        return nil, true
    end
    for line in body:gmatch('[^\r\n]+') do
        line = trim(line)
        if line ~= '' and line:sub(1, 1) ~= '#' then return line end
    end
    return nil
end

--- An HLS master whose every variant names AAC only (mp4a.40.2 / .5 / .29) cannot play without AAC (probe P8).
local function hlsAacOnly(body)
    local any, other = false, false
    for codecs in body:gmatch('CODECS%s*=%s*"([^"]*)"') do
        any = true
        local c = codecs:lower()
        if not c:find('mp4a', 1, true) or c:find('mp3', 1, true) or c:find('opus', 1, true) or c:find('flac', 1, true)
            or c:find('vorbis', 1, true) or c:find('mp4a.40.34', 1, true) or c:find('mp4a.6b', 1, true) then
            other = true
        end
    end
    return any and not other
end

--- A playlist entry -> an absolute URL (relative ones against the playlist's own URL).
local function absolute(entry, base)
    if entry:find('^%a[%w+.-]*://') then return entry end
    local u = parseUrl(base)
    if not u then return nil end
    if entry:sub(1, 1) == '/' then return u.origin .. entry end
    return u.origin .. u.path:gsub('[^/]*$', '') .. entry
end

local statusFail = {}                  -- [origin] = Clock ms until which that origin's status is not asked again

--- The Icecast sources of an origin (status-json.xsl, Icecast >= 2.4) or nil. Yields.
local function icecast(origin)
    local till = statusFail[origin]
    if till and R.diff(till, now()) > 0 then return nil end
    local body = fetch(origin .. '/status-json.xsl')
    if type(body) == 'string' then
        local ok, v = pcall(json.decode, body)
        body = ok and v or nil
    end
    local ice = type(body) == 'table' and body.icestats
    local list = type(ice) == 'table' and ice.source
    if type(list) ~= 'table' then
        statusFail[origin] = R.add(now(), STATUS_BACKOFF_MS)
        return nil
    end
    statusFail[origin] = nil
    if list.listenurl ~= nil or list.server_type ~= nil or list.title ~= nil then list = { list } end   -- one mount
    return list
end

--- The status entry whose listen URL has the stream's path (Icecast may name another host or port).
local function mountOf(list, path)
    for i = 1, #list do
        local e = list[i]
        local lu = type(e) == 'table' and type(e.listenurl) == 'string' and e.listenurl:match('^%a+://[^/]+(/[^?#]*)')
        if lu == path then return e end
    end
    return nil
end

--- Resolves one URL -> resolved | { error = code }: a playlist to its first entry (one nested playlist at most),
--- a stream without a telling extension to the codec its origin's status-json names (else MP3). Yields.
local function resolve(url, t, depth)
    local u, how, codec, kind = classify(url, t)
    if not u then return { error = how } end
    if how == 'direct' then return { url = url, codec = codec, kind = kind } end
    if how == 'probe' then
        local list = icecast(u.origin)
        local e = list and mountOf(list, u.path)
        local c, k = codecOfType(e and e.server_type)
        if c == false then return { error = k } end
        return { url = url, codec = c or 'audio/mpeg', kind = k or 'mp3' }
    end
    if depth >= MAX_NEST then return { error = 'playlist' } end   -- a playlist, then one nested one
    local body, err = fetch(url)
    if not body then return { error = err } end
    if type(body) ~= 'string' or #body > MAX_BODY then return { error = 'playlist' } end
    body = body:gsub('^\239\187\191', '')
    local entry, hls = firstEntry(body)
    if hls then
        if cfgAudio().AllowAac ~= true and hlsAacOnly(body) then return { error = 'codec' } end
        return { url = url, codec = HLS_TYPE, kind = 'hls' }
    end
    entry = entry and absolute(entry, url)
    if not entry then return { error = 'playlist' } end
    return resolve(entry, t, depth + 1)
end

local function worker()
    while #queue > 0 do
        local url = table.remove(queue, 1)
        local ok, r = pcall(resolve, url, jobs[url], 0)
        if not ok then
            Log.warn('scene audio: resolving %s failed: %s', url, tostring(r))
            r = { error = 'error' }
        end
        jobs[url] = nil
        local done, err = pcall(finish, url, r)          -- a worker must never die holding its slot
        if not done then Log.warn('scene audio: applying %s failed: %s', url, tostring(err)) end
    end
    busy = busy - 1
end

function fwd.enqueue(url, t)
    if jobs[url] then return end
    jobs[url] = t
    if #queue >= MAX_QUEUE then                  -- flooded: this URL fails for ERROR_TTL_MS (outside the caller)
        SetTimeout(0, function()
            jobs[url] = nil
            finish(url, { error = 'busy' })
        end)
        return
    end
    queue[#queue + 1] = url
    if busy < MAX_WORKERS then
        busy = busy + 1
        CreateThread(worker)
    end
end

--------------------------------------------------------------------------------
-- Titles: every 20 s, only for streams somebody can hear (a dependent emitter in a subscribed cell)
--------------------------------------------------------------------------------

local polling = false

--- Has source `id` a dependent emitter whose root sits in a cell with subscribers? (R.interest, cheap)
local function listened(id)
    local deps = store.dependents(id)
    local subscribers = R.interest and R.interest.subscribers
    if not deps or not subscribers then return false end
    for eid in pairs(deps) do
        local e = store.get(eid)
        local root = e and store.root(e)
        local cell = root and root.cell
        if cell then
            local set = subscribers(root.bucket, cell.grid, cell.key)
            if set and next(set) ~= nil then return true end
        end
    end
    return false
end

--- Cuts a string to `max` bytes without leaving a broken UTF-8 sequence at the end.
local function cut(s, max)
    if #s <= max then return s end
    s = s:sub(1, max)
    local tail = s:match('[\192-\255][\128-\191]*$')
    if tail then
        local lead = tail:byte(1)
        if #tail < (lead >= 240 and 4 or (lead >= 224 and 3 or 2)) then s = s:sub(1, #s - #tail) end
    end
    return s
end

local function titleOf(e)
    local t = type(e) == 'table' and e.title
    if type(t) ~= 'string' and type(t) ~= 'number' then return nil end
    t = tostring(t)
    local artist = e.artist
    if type(artist) == 'string' and artist ~= '' and not t:find(artist, 1, true) then t = artist .. ' - ' .. t end
    t = Utils.sanitize(t, 1024)
    return t ~= '' and cut(t, TITLE_MAX) or nil
end

--- One round: the listened streams grouped by origin, one status-json each. Yields.
local function pollTitles()
    local groups, order = {}, {}
    for id in pairs(streams) do
        local node = store.get(id)
        local r = node and node.fields.resolved
        if type(r) == 'table' and type(r.url) == 'string' and r.kind ~= 'hls' and listened(id) then
            local u = parseUrl(r.url)
            if u then
                local g = groups[u.origin]
                if not g then
                    g = {}
                    groups[u.origin] = g
                    order[#order + 1] = u.origin
                end
                g[#g + 1] = { id = id, path = u.path }
            end
        end
    end
    for i = 1, #order do
        local list = icecast(order[i])
        stat.polls = stat.polls + 1
        local g = groups[order[i]]
        for j = 1, list and #g or 0 do
            local title = titleOf(mountOf(list, g[j].path))
            local node = store.get(g[j].id)
            if title and node and node.fields.title ~= title then
                local ok, done = Registry.withCaller('core', Scene.set, g[j].id, { title = title })
                if ok and done then stat.titles = stat.titles + 1 end
            end
        end
    end
end

function fwd.ensurePoller()
    if polling then return end
    polling = true
    CreateThread(function()
        while streamCount > 0 do
            Wait(TITLE_MS)
            local ok, err = pcall(pollTitles)
            if not ok then Log.warn('scene audio: title poll failed: %s', tostring(err)) end
        end
        polling = false
    end)
end

--------------------------------------------------------------------------------
-- Spawn policy (R.audio.admit — Scene.spawn asks it directly, so core's limits never depend on hook order)
--------------------------------------------------------------------------------

local buckets = {}                     -- [owner] = { tokens, at }

local function take(owner)
    local b, t = buckets[owner], now()
    if not b then
        b = { tokens = OWNER_BURST, at = t }
        buckets[owner] = b
    end
    local refill = R.diff(t, b.at) * OWNER_RATE / 1000
    b.tokens, b.at = math.min(OWNER_BURST, b.tokens + (refill > 0 and refill or 0)), t
    if b.tokens < 1 then return false end
    b.tokens = b.tokens - 1
    return true
end

--- R.audio.admit(def, owner) -> true | false, 'audio_disabled' | 'audio_streams' | 'audio_rate': may `owner`
--- spawn this audio.source now? scene.audio.enabled, scene.audio.maxStreams stream sources server-wide, the
--- owner's flood guard (a bucket of OWNER_BURST, OWNER_RATE a second back; core exempt). Every other kind passes.
--- Scene.spawn calls it after validation, right before the node is created (a pass costs one token).
function A.admit(def, owner)
    if type(def) ~= 'table' then return true end
    local kind = type(def.kind) == 'table' and def.kind.id or def.kind
    if kind ~= 'audio.source' then return true end
    if not state.enabled then
        stat.refusedDisabled = stat.refusedDisabled + 1
        return false, 'audio_disabled'
    end
    local f = type(def.fields) == 'table' and def.fields or EMPTY
    if f.type == 'stream' and streamCount >= state.maxStreams then
        stat.refusedStreams = stat.refusedStreams + 1
        return false, 'audio_streams'
    end
    if owner == nil then owner = Registry.getCaller() end
    if owner ~= 'core' and not take(tostring(owner)) then
        stat.refusedRate = stat.refusedRate + 1
        return false, 'audio_rate'
    end
    return true
end

--------------------------------------------------------------------------------
-- API: Scene.audio.play / kill / stats (server only; plugins through the proxy)
--------------------------------------------------------------------------------

local playAt = {}                      -- [src] = Clock ms of that player's last play

local function record(row)
    local Audit = rawget(Core, 'Audit')
    if not (Audit and Audit.record) then return end
    local ok, err = pcall(Audit.record, row)
    if not ok then Log.warn('scene audio: audit failed: %s', tostring(err)) end
end

--- Scene.audio.play(def) -> id | nil, err, detail: a spawn (or with def.id a retarget) of an audio.source as the
--- caller, on behalf of player `def.by` (1 play per 5 s per player, counted when it is tried, audited when done).
function A.play(def)
    if type(def) ~= 'table' then return nil, 'def' end
    local by = def.by
    if by ~= nil then
        by = toint(by)
        if not by or by < 1 or by > 65535 or GetPlayerName(by) == nil then return nil, 'by' end
        if not store.loaded() then return nil, 'unavailable' end       -- the trust window must not span a yield
        local t, at = now(), playAt[by]
        if at and R.diff(t, at) < PLAYER_COOLDOWN_MS then
            stat.refusedPlayer = stat.refusedPlayer + 1
            return nil, 'rate_limit'
        end
        playAt[by] = t
    end
    local id, err, detail, op, done, a, b, c
    if def.id ~= nil then
        op = 'set'
        local node = store.get(toint(def.id) or 0)
        if not node or node.kind ~= 'audio.source' then return nil, 'missing' end
        playingBy = by
        done, a, b, c = pcall(Scene.set, node.id, def.fields)
        playingBy = nil
        if done then id, err, detail = a and node.id or nil, b, c end
    else
        op = 'spawn'
        local s = {}
        for k, v in pairs(def) do if k ~= 'by' then s[k] = v end end
        s.kind = 'audio.source'
        playingBy = by
        done, a, b, c = pcall(Scene.spawn, s)
        playingBy = nil
        if done then id, err, detail = a, b, c end
    end
    if not done then
        Log.warn('scene audio: play failed: %s', tostring(a))
        return nil, 'error'
    end
    if not id then
        return nil, err, detail                          -- Scene.spawn's / set's, admit's 'audio_*' included
    end
    stat.plays = stat.plays + 1
    if by then
        local node = store.get(id)
        local f = node and node.fields or EMPTY
        record({ actor = by, action = 'scene.audio.play', source = 'api',
            targets = { { type = 'scene', id = id, name = f.title } },
            ctx = { op = op, type = f.type, category = f.category, owner = node and node.owner,
                url = f.url or f.file or (f.items and ('timeline of ' .. #f.items)) } })
    end
    return id
end

--- Scene.audio.kill(id | 'all', by?) -> true, n | false, err: the kill switch — sources (with their emitters)
--- or emitters go whatever their owner.
function A.kill(target, by)
    if by ~= nil and not (toint(by) and toint(by) >= 0 and toint(by) <= 65535) then return false, 'by' end
    local ids
    if target == 'all' then
        ids = Scene.list({ kind = 'audio.source' })
    else
        local id = toint(target)
        local node = id and store.get(id)
        if not node or (node.kind ~= 'audio.source' and node.kind ~= 'audio') then return false, 'missing' end
        ids = { id }
    end
    local n = 0
    for i = 1, #ids do
        if store.get(ids[i]) then
            local ok, done = Registry.withCaller('core', Scene.remove, ids[i], { fade = true })
            if ok and done then n = n + 1 end
        end
    end
    stat.kills = stat.kills + n
    record({ actor = by and toint(by) or 'system', action = 'scene.audio.kill', source = 'api',
        targets = target ~= 'all' and { { type = 'scene', id = toint(target) } } or nil,
        ctx = { target = tostring(target), count = n, caller = Registry.getCaller() } })
    return true, n
end

function A.stats()
    return { enabled = state.enabled, hosts = #state.hosts, maxStreams = state.maxStreams, sources = nSrc,
        streams = streamCount, resolving = busy, queued = #queue, cached = cacheN, resolved = stat.resolved,
        failed = stat.failed, requests = stat.requests, polls = stat.polls, titles = stat.titles, polling = polling,
        plays = stat.plays, kills = stat.kills, refused = { player = stat.refusedPlayer, rate = stat.refusedRate,
            streams = stat.refusedStreams, disabled = stat.refusedDisabled } }
end

R.audio = A
Scene.audio = type(Scene.audio) == 'table' and Scene.audio or {}
Scene.audio.play, Scene.audio.stats = A.play, A.stats
if Scene.audio.kill == nil then Scene.audio.kill = A.kill end   -- scene.lua delegates kill to R.audio.kill

Scene.on('spawned', 'audio.source', function(copy) track(copy.id) end)
Scene.on('changed', 'audio.source', function(copy) track(copy.id) end)
Scene.on('removed', 'audio.source', function(copy) untrack(copy.id) end)

AddEventHandler('playerDropped', function()
    local src = source
    playAt[src] = nil
end)

-- a resource's files {} are read again after it (re)starts
AddEventHandler('onResourceStart', function(res) globs[res] = nil end)
AddEventHandler('onResourceStop', function(res) globs[res] = nil end)

-- Start: the settings (Settings.get may yield once), then every source the store loaded (persistent ones).
CreateThread(function()
    Wait(0)
    readSettings()
    local ids = Scene.list({ kind = 'audio.source' })                     -- waits for the store's load barrier
    for i = 1, #ids do track(ids[i]) end
end)
