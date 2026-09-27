--[[ core — client/scene_audio.lua — Core.Scene audio on the client (DESIGN §55.16). Loads after scene_movers.lua
     (scene_promote.lua may sit in between), before scene_voice.lua / scene.lua; asserts C.mat, C.cache, C.movers of
     the one-shot `CoreSceneRuntime` and adds C.audio. Nothing here is reachable through the export.

     - The materialiser handler of the kind 'audio' (class 'audio': no entity, fade 'self', radii range | +20 | +40):
       a live emitter goes to the shell with its source — `audio:source` (the dependency node, never materialised
       itself: sent when the first live emitter needs it, removed with the last), `audio:emitter`, `audio:remove` —
       each encoded here with a fixed key order and sent only when its text changed; `trusted` (the server's
       resolved.trusted, false when unknown) lets the page decode a source whole. A source still resolving, one
       whose resolution failed and a 'voice' source (§55.17) are not sent (nor their emitters).
     - The listener feed: one pre-encoded SendNuiMessage string, at most Audio.ListenerHz a second, only while an
       emitter is materialised and only when something changed — the camera moved >= 0.25 m or turned >= 2 deg, a
       moving emitter (motion, attach, a moving parent) moved >= 0.1 m, an occlusion value by >= 0.02, the
       environment, a volume or the pause state; right after the first emitter reaches the page, and once a second
       (the page's clock mapping and drift control need `t` = Core.Clock.now()); map keys are 'n<id>' (AGENTS §8).
     - Occlusion = rules (listener vs emitter interior / room, the listener in a closed vehicle or under water) +
       <= Audio.LosProbesPerSecond async LOS probes (StartShapeTestLosProbe, GetShapeTestResult polled, never the
       synchronous probe), round-robin over the nearest audible outdoor emitters, smoothed (alpha 0.5 per probe).
     - Volumes = GetProfileSetting(Audio.ProfileSfx | ProfileMusic) / 10 x the player's prefs (client KVP
       core:audio:prefs; `/audio volume|hrtf|streams|offset|voices|debug`, `/audiodebug`); `paused` (the page ducks)
       while the pause menu is open or the §31 shell is hidden. scene.audio.enabled = false (replicated) takes
       everything out of the shell; a reloaded shell (hook uiReady) gets it all again. C.audio: stats(),
       positionOf(id), occlusionOf(id), listener() — for client/scene_voice.lua and /scene.

     Natives (fxref 2026-09-27, runtime names in natives.json / natives_cfx.json; apiset client unless noted; BOOL
     answers by truthiness, BOOL out-values as `v == true or v == 1`, DESIGN §30.4):
       SendNuiMessage(jsonString) (CFX), GetFinalRenderedCamCoord(), GetFinalRenderedCamRot(rotationOrder),
       GetProfileSetting(profileSetting), IsPauseMenuActive(), PlayerPedId(), GetInteriorFromEntity(entity),
       GetRoomKeyFromEntity(entity), GetInteriorAtCoords(x, y, z), GetVehiclePedIsIn(ped, includeEntering),
       GetVehicleClass(vehicle), DoesVehicleHaveRoof(vehicle), IsVehicleAConvertible(vehicle, p1),
       GetConvertibleRoofState(vehicle), IsPedSwimmingUnderWater(ped),
       StartShapeTestLosProbe(x1, y1, z1, x2, y2, z2, flags, entity, p8), GetShapeTestResult(shapeTestHandle),
       GetEntityCoords(entity, alive), GetEntityRotation(entity, rotationOrder), DoesEntityExist(entity),
       GetGameTimer(), GetResourceKvpString(key), SetResourceKvp(key, value), GetCurrentResourceName() (CFX shared).
       Runtime helpers: CreateThread, Wait, RegisterCommand, AddEventHandler, json.
]]

local C = CoreSceneRuntime
assert(type(C) == 'table' and type(C.mat) == 'table' and type(C.cache) == 'table' and type(C.movers) == 'table',
    'client/scene_audio.lua loads after client/scene_movers.lua (CoreSceneRuntime.mat / .cache / .movers)')
local mat, cache = C.mat, C.cache
local Log, Clock, Motion = Core.Log, Core.Clock, Core.SceneMotion

local type, pairs, next, pcall, tostring, tonumber = type, pairs, next, pcall, tostring, tonumber
local sqrt, sin, cos, rad, floor, abs, huge = math.sqrt, math.sin, math.cos, math.rad, math.floor, math.abs, math.huge
local mtype, tointeger, fmt, concat = math.type, math.tointeger, string.format, table.concat

local function num(v, default, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return default end
    if v < lo then return lo end
    return v > hi and hi or v
end

local CS = (type(Config) == 'table' and type(Config.Scene) == 'table') and Config.Scene or {}
local CA = type(CS.Audio) == 'table' and CS.Audio or {}
local FEED_MS <const> = floor(1000 / num(CA.ListenerHz, 20, 1, 60) + 0.5)
local PROBES <const> = num(CA.LosProbesPerSecond, 8, 0, 60)
local PROFILE_SFX <const>, PROFILE_MUSIC <const> = floor(num(CA.ProfileSfx, 300, 0, 4096)),
    floor(num(CA.ProfileMusic, 306, 0, 4096))
local VOICES <const> = floor(num(CA.Voices, 32, 1, 64))
local DECODERS <const>, CLIP_MB <const> = floor(num(CA.Decoders, 4, 0, 8)), num(CA.ClipCacheMb, 64, 8, 512)
local HRTF_VOICES <const> = floor(num(CA.HrtfVoices, 8, 0, 32))
local STILL_MS <const> = 100              -- the loop's poll while nothing was sent
local HEARTBEAT_MS <const> = 1000         -- a still listener still sends `t` once a second (clock, drift)
local MOVE2 <const>, EMOVE2 <const> = 0.0625, 0.01          -- 0.25 m (listener), 0.1 m (a moving emitter)
local TURN_COS <const> = cos(rad(2))
local OCCL_EPS <const> = 0.02
local ENV_MS <const>, VOL_MS <const> = 250, 1000
local PLACED_MS <const> = 120             -- a mover the movers placed this recently is not re-posed here
local FADE_MS <const> = 300               -- audio:remove
local KVP_KEY <const> = 'core:audio:prefs'
-- the R6 §3.2 rule table on the page's 0..1 occlusion scale (0 dB / 20 kHz .. -15 dB / 400 Hz, curves.ts): other room
-- -6 dB 2.5 kHz, inside vs outside -12 dB ~500 Hz, LOS blocked -8 dB 1.5 kHz, closed vehicle -4 dB 3.5 kHz, under
-- water -10 dB 500 Hz; the listener's vehicle / water add to the rest, capped at 1
local OCC_ROOM <const>, OCC_INOUT <const>, OCC_LOS <const> = 0.45, 0.85, 0.55
local OCC_VEHICLE <const>, OCC_WATER <const> = 0.35, 0.8
local PROBE_FLAGS <const>, PROBE_P8 <const> = 17, 7        -- world + objects; the game's own collider mask
-- vehicle classes that are never closed: motorcycles, cycles, boats, open wheel
local OPEN_CLASS <const> = { [8] = true, [13] = true, [14] = true, [22] = true }
local CATS <const> = { master = true, music = true, sfx = true, ambience = true, voice = true }
local EMPTY <const> = {}

local recs, list, nRecs = {}, {}, 0       -- live emitters: id -> record, dense array (record.i)
local srcRefs, nSrcs = {}, 0              -- source id -> { n = live emitters, sent = last text | nil }
local enabled, primed, debugOn, looping, stopped = true, false, false, false, false
local hosts = nil                         -- scene.audio.allowHosts (replicated): the page's redirect / HLS scope
local envDirty, volDirty, pauseDirty, force = true, true, true, true   -- what the next feed must carry
local fwd = { feedSoon = false }          -- ensureLoop / feedNow (defined with the loop), a feed wanted now
local stat = { sent = 0, feeds = 0, probes = 0, errors = 0, created = 0, destroyed = 0 }
local lastStats, statsN, errSeen, errN = nil, 0, {}, 0

--------------------------------------------------------------------------------
-- JSON with a fixed key order (a message's text is compared to the last one sent)
--------------------------------------------------------------------------------

local function esc(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    return fmt('\\u%04x', c:byte())
end
local function jstr(s) return '"' .. s:gsub('[%c"\\]', esc) .. '"' end

--- Any plain value; tables: a sequence as an array, otherwise an object with sorted string keys.
local function enc(v, depth)
    local t = type(v)
    if t == 'string' then return jstr(v) end
    if t == 'boolean' then return v and 'true' or 'false' end
    if t == 'number' then
        if v ~= v or v == huge or v == -huge then return 'null' end
        return mtype(v) == 'integer' and fmt('%d', v) or fmt('%.14g', v)
    end
    if t == 'vector3' or t == 'vector4' then return fmt('{"x":%.14g,"y":%.14g,"z":%.14g}', v.x, v.y, v.z) end
    if t ~= 'table' or depth > 8 then return 'null' end
    local parts = {}
    if #v > 0 or next(v) == nil then
        for i = 1, #v do parts[i] = enc(v[i], depth + 1) end
        return '[' .. concat(parts, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do if type(k) == 'string' then keys[#keys + 1] = k end end
    table.sort(keys)
    for i = 1, #keys do parts[i] = jstr(keys[i]) .. ':' .. enc(v[keys[i]], depth + 1) end
    return '{' .. concat(parts, ',') .. '}'
end

local function kv(parts, key, value)
    if value ~= nil then parts[#parts + 1] = '"' .. key .. '":' .. enc(value, 0) end
end

local function removeText(ids) return fmt('{"action":"audio:remove","ids":%s,"fadeMs":%d}', enc(ids, 0), FADE_MS) end
local function debugText(on) return fmt('{"action":"audio:debug","on":%s}', on and 'true' or 'false') end

--------------------------------------------------------------------------------
-- The player's prefs (client KVP core:audio:prefs) and the shell hand-off
--------------------------------------------------------------------------------

local prefs = { master = 1.0, music = 1.0, sfx = 1.0, ambience = 1.0, voice = 1.0, hrtf = false, streams = true,
    offsetMs = 0, maxVoices = VOICES }

local function loadPrefs()
    local raw = GetResourceKvpString(KVP_KEY)
    if type(raw) ~= 'string' or raw == '' then return end
    local ok, t = pcall(json.decode, raw)
    if not ok or type(t) ~= 'table' then return end
    for k in pairs(CATS) do prefs[k] = num(t[k], prefs[k], 0, 1) end
    if type(t.hrtf) == 'boolean' then prefs.hrtf = t.hrtf end
    if type(t.streams) == 'boolean' then prefs.streams = t.streams end
    prefs.offsetMs = floor(num(t.offsetMs, 0, -1000, 1000))
    prefs.maxVoices = floor(num(t.maxVoices, VOICES, 1, 64))
end

local function savePrefs() SetResourceKvp(KVP_KEY, json.encode(prefs)) end

local function prefsText()
    return fmt('{"action":"audio:prefs","hrtf":%s,"maxVoices":%d,"offsetMs":%d,"streams":%s,"decoders":%d,'
        .. '"clipCacheMb":%s,"hrtfVoices":%d}', tostring(prefs.hrtf), prefs.maxVoices, prefs.offsetMs,
        tostring(prefs.streams), DECODERS, enc(CLIP_MB, 0), HRTF_VOICES)
end

local function nuiReady()
    local UII = rawget(Core, 'UIInternal')
    return not (UII and UII.isNuiReady) or UII.isNuiReady() == true
end

local function send(text)
    SendNuiMessage(text)
    stat.sent = stat.sent + 1
end

--- The first audio message of a shell carries the prefs (the page loads its audio engine on it, so nothing is
--- sent before an emitter — or the player's /audio debug — needs it).
local function prime()
    if primed then return end
    primed = true
    send(prefsText())
    if debugOn then send(debugText(true)) end
end

--------------------------------------------------------------------------------
-- Emitter records: pose, anchor, interior, what the shell has
--------------------------------------------------------------------------------

local L = { x = 0.0, y = 0.0, z = 0.0, fx = 0.0, fy = 1.0, fz = 0.0, ux = 0.0, uy = 0.0, uz = 1.0, vx = 0.0, vy = 0.0,
    vz = 0.0, t = -1, ped = 0, veh = 0, int = 0, room = 0, closed = false, under = false,
    sx = huge, sy = huge, sz = huge, sfx = 0.0, sfy = 0.0, sfz = 0.0, sux = 0.0, suy = 0.0, suz = 0.0 }
local T = { x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0 }   -- a target's pose (reused)
local nMove, nOccl = 0, 0                 -- records with a moved position / a changed occlusion not sent yet

local function entityPose(e)
    local p, q = GetEntityCoords(e, false), GetEntityRotation(e, 2)
    T.x, T.y, T.z, T.rx, T.ry, T.rz = p.x, p.y, p.z, q.x, q.y, q.z
    return T
end

--- The emitter's world pose now: the materialiser's ctx at create, else its parent (entity or record) composed
--- with the offset, its attach target, its motion at Core.Clock time, or the node's base pose.
local function pose(r, ctx)
    if ctx and ctx.x then
        r.x, r.y, r.z, r.rx, r.ry, r.rz = ctx.x, ctx.y, ctx.z, ctx.rx or 0.0, ctx.ry or 0.0, ctx.rz or 0.0
        return
    end
    local node = r.node
    local pid = tointeger(node.parent) or 0
    if pid ~= 0 then
        local pn = cache.node(pid)
        local pm = pn and pn.m
        if pm then
            local ph = pm.handle
            if mtype(ph) == 'integer' and ph ~= 0 and DoesEntityExist(ph) then
                mat.compose(r, entityPose(ph))
                return
            elseif pm.x then
                mat.compose(r, pm)
                return
            end
        end
    elseif node.attach ~= nil then
        local e = mat.targetOf(node.attach)
        if e ~= 0 then
            mat.compose(r, entityPose(e))
            return
        end
    elseif node.motion ~= nil and Motion then
        r.x, r.y, r.z, r.rx, r.ry, r.rz = Motion.pose(node.x or 0.0, node.y or 0.0, node.z or 0.0, node.rx or 0.0,
            node.ry or 0.0, node.rz or 0.0, node.motion, Clock.now())
        return
    end
    r.x, r.y, r.z = node.x or 0.0, node.y or 0.0, node.z or 0.0
    r.rx, r.ry, r.rz = node.rx or 0.0, node.ry or 0.0, node.rz or 0.0
end

local function isMover(n)
    local cls = n.kind and n.kind.class
    return n.motion ~= nil or n.attach ~= nil or ((tointeger(n.flags) or 0) & 2) ~= 0
        or cls == 2 or cls == 3 or cls == 'vehicle' or cls == 'ped'
end

--- Fields, the moving flag (its own motion / attach, or a parent chain that moves: motion, attach, promoted, a
--- vehicle or a ped), the anchor entity (attach target or the parent's entity) and the interior at its pose.
local function classify(r)
    local node = r.node
    local f = node.fields or EMPTY
    r.occlOn, r.range = f.occlusion ~= false, num(f.range, 40, 1, 600)
    local moving, pid, anchor = node.motion ~= nil or node.attach ~= nil, tointeger(node.parent) or 0, 0
    local up, depth = pid, 0
    while not moving and up ~= 0 and depth < 5 do
        local pn = cache.node(up)
        if not pn then break end
        moving, up, depth = isMover(pn), tointeger(pn.parent) or 0, depth + 1
    end
    if pid ~= 0 then
        local pn = cache.node(pid)
        local ph = pn and pn.m and pn.m.handle
        if mtype(ph) == 'integer' then anchor = ph end
    elseif node.attach ~= nil then
        anchor = mat.targetOf(node.attach)
    end
    r.moving, r.anchor = moving, anchor
    r.int = GetInteriorAtCoords(r.x, r.y, r.z)
    r.room = (anchor ~= 0 and r.int ~= 0) and GetRoomKeyFromEntity(anchor) or 0
    r.mine = anchor ~= 0 and (anchor == L.ped or anchor == L.veh)
end

--- Occlusion target of a record (rules; the LOS fraction for two outdoor points) and whether probes may ask.
local function rule(r)
    local v, cand = 0.0, false
    if r.occlOn and not r.mine then
        local ei, li = r.int, L.int
        if ei ~= 0 or li ~= 0 then
            if ei ~= li then
                v = OCC_INOUT
            elseif r.room ~= 0 and L.room ~= 0 and r.room ~= L.room then
                v = OCC_ROOM
            end
        else
            cand, v = true, OCC_LOS * r.los
        end
        if L.under then v = v + OCC_WATER elseif L.closed then v = v + OCC_VEHICLE end
        if v > 1.0 then v = 1.0 end
    end
    r.occl, r.cand = v, cand
    if not r.oDirty and (abs(v - r.occlSent) >= OCCL_EPS or (v == 0 and r.occlSent ~= 0)) then
        r.oDirty, nOccl = true, nOccl + 1
    end
end

--------------------------------------------------------------------------------
-- Messages: audio:source (the dependency node) and audio:emitter, sent only when their text changed
--------------------------------------------------------------------------------

-- the wire order of audio:source (INTERFACES §6); a nil value is left out
local SOURCE_KEYS <const> = { 'id', 'type', 'url', 'file', 'items', 'loop', 't0', 'rate', 'paused', 'pausedAt',
    'offset', 'volume', 'category', 'codec', 'kind', 'hosts', 'trusted' }
local sv = {}                             -- a source message's values (reused, emptied by the key loop)

--- The source's message, or nil while it cannot play (resolving, failed, a voice source, unusable fields).
local function sourceText(s)
    local f = s.fields
    if type(f) ~= 'table' then return nil end
    local t = f.type
    if t ~= 'clip' and t ~= 'loop' and t ~= 'timeline' and t ~= 'stream' then return nil end
    local url, file, codec, kind, r = nil, nil, nil, nil, f.resolved
    if t ~= 'timeline' then
        if type(f.file) == 'string' then
            file = f.file
        elseif type(r) == 'table' then
            if r.pending or r.error or type(r.url) ~= 'string' then return nil end
            url, codec, kind = r.url, r.codec, r.kind
        elseif type(f.url) == 'string' then
            url = f.url                                    -- no server answer recorded: the page checks the URL
        else
            return nil
        end
    elseif type(f.items) ~= 'table' or #f.items == 0 then
        return nil
    end
    sv.id, sv.type, sv.url, sv.file, sv.items = s.id, t, url, file, t == 'timeline' and f.items or nil
    sv.loop, sv.t0, sv.rate, sv.paused = f.loop == true, tointeger(f.t0), f.rate or 1, f.paused == true
    sv.pausedAt, sv.offset, sv.volume = tointeger(f.pausedAt), f.offset or 0, f.volume or 1
    sv.category = f.category or 'sfx'
    sv.codec, sv.kind, sv.hosts = codec, kind, (hosts and (url or t == 'timeline')) and hosts or nil
    sv.trusted = type(r) == 'table' and r.trusted == true          -- server-owned; unknown = never decoded whole
    local p = { '"action":"audio:source"' }
    for i = 1, #SOURCE_KEYS do
        local k = SOURCE_KEYS[i]
        kv(p, k, sv[k])
        sv[k] = nil
    end
    return '{' .. concat(p, ',') .. '}'
end

local function emitterText(r)
    local f = r.node.fields or EMPTY
    local p = { '"action":"audio:emitter"', '"id":' .. enc(r.id, 0), '"source":' .. enc(r.src, 0),
        fmt('"x":%.2f,"y":%.2f,"z":%.2f', r.x, r.y, r.z) }
    kv(p, 'range', f.range or 40)
    kv(p, 'volume', f.volume or 1)
    kv(p, 'curve', f.curve or 'game')
    kv(p, 'ref', f.ref or 2)
    kv(p, 'priority', f.priority or 3)
    kv(p, 'occlusion', f.occlusion ~= false)
    if type(f.cone) == 'table' then              -- the page aims a cone with the node's rotation
        kv(p, 'cone', f.cone)
        p[#p + 1] = fmt('"rx":%.1f,"ry":%.1f,"rz":%.1f', r.rx, r.ry, r.rz)
    end
    local z = f.zone                          -- a sphere / box without coords sits on the emitter, a box without a
    if type(z) == 'table' then                -- rotation takes its yaw (the zone kind's rule, scene_world.lua)
        if (z.type == 'sphere' or z.type == 'box') and (z.coords == nil or (z.type == 'box' and z.rotation == nil)) then
            local c = {}
            for k, v in pairs(z) do c[k] = v end
            c.coords = c.coords or { x = r.x, y = r.y, z = r.z }
            if c.type == 'box' and c.rotation == nil then c.rotation = r.rz end
            z = c
        end
        kv(p, 'zone', z)
    end
    return '{' .. concat(p, ',') .. '}'
end

local function sourceGone(sid, ids)
    local so = srcRefs[sid]
    if so and so.sent then
        ids[#ids + 1] = sid
        so.sent = nil
    end
end

--- Brings the shell up to date for one record: its source first, then the emitter; an emitter whose source cannot
--- play (any more) leaves the shell together with that source.
local function push(r)
    if not (enabled and nuiReady()) then return end
    local s = cache.node(r.src)
    local stext = (s and not s.gone) and sourceText(s) or nil
    if not stext then
        local ids = {}
        if r.sent then ids[1], r.sent = r.id, nil end
        sourceGone(r.src, ids)
        if #ids > 0 then send(removeText(ids)) end
        return
    end
    prime()
    local so = srcRefs[r.src]
    if so.sent ~= stext then
        send(stext)
        so.sent = stext
    end
    local etext = emitterText(r)
    if r.sent ~= etext then
        local fresh = r.sent == nil
        send(etext)
        r.sent, r.mx, r.my, r.mz = etext, r.x, r.y, r.z
        if fresh then                          -- a new emitter on the page starts unoccluded
            r.occlSent = 0.0
            if r.occl ~= 0 and not r.oDirty then r.oDirty, nOccl = true, nOccl + 1 end
            if force then fwd.feedSoon = true end   -- the page needs a listener and a clock sample now
        end
    end
end

--------------------------------------------------------------------------------
-- The materialiser handler of 'audio' emitters (§55.11 audio row; §55.16)
--------------------------------------------------------------------------------

local function ref(sid)
    local so = srcRefs[sid] or { n = 0 }
    if so.n == 0 then srcRefs[sid], nSrcs = so, nSrcs + 1 end
    so.n = so.n + 1
end

--- One live emitter less for source `sid`; the last one takes the source out of the shell (ids collects it).
local function unref(sid, ids)
    local so = srcRefs[sid]
    if not so then return end
    so.n = so.n - 1
    if so.n <= 0 then
        sourceGone(sid, ids)
        srcRefs[sid], nSrcs = nil, nSrcs - 1
    end
end

local function prompts(r)
    local K = C.kinds
    if K and K.syncInteract then K.syncInteract(r.node, nil, r.x, r.y, r.z) end
end

local AUDIO = { class = 'audio', budget = 'audio', fade = 'self' }

function AUDIO.radii(node)                -- range | +20 (enters silent) | +40
    local r = num((node.fields or EMPTY).range, 40, 1, 600)
    return r, r + 20, r + 40
end

function AUDIO.create(node, ctx)
    local sid = tointeger((node.fields or EMPTY).source)
    if not sid or sid < 1 then return nil end
    local old = recs[node.id]
    if old then AUDIO.destroy(old.node) end
    local r = { id = node.id, node = node, src = sid, x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0,
        mx = 0.0, my = 0.0, mz = 0.0, placedAt = -huge, los = 0.0, occl = 0.0, occlSent = 0.0, oDirty = false,
        mvDirty = false, probeAt = -huge, cand = false, sent = nil }
    pose(r, ctx)
    classify(r)
    rule(r)
    nRecs = nRecs + 1
    list[nRecs], r.i, recs[node.id] = r, nRecs, r
    ref(sid)
    stat.created = stat.created + 1
    prompts(r)
    push(r)
    fwd.ensureLoop()
    if fwd.feedSoon then fwd.feedNow() end
    return true
end

--- 'dep' = its source changed (re-sent when its text changed), 'interact' = prompts only, anything else re-reads
--- the pose and the fields. Answers false (= re-create) when the fields name no source any more.
function AUDIO.update(node, _, what)
    local r = recs[node.id]
    if not r then return false end
    r.node = node
    local sid = tointeger((node.fields or EMPTY).source)
    if not sid or sid < 1 then return false end
    local old = r.src
    if sid ~= old then
        ref(sid)
        r.src = sid
    end
    if what ~= 'dep' and what ~= 'interact' then
        pose(r, nil)
        classify(r)
        rule(r)
    end
    prompts(r)
    push(r)                                   -- a new station: its source, then the emitter on it (the page
    if sid ~= old then                        -- crossfades), then the old source when nothing else uses it
        local ids = {}
        unref(old, ids)
        if #ids > 0 then send(removeText(ids)) end
    end
    if fwd.feedSoon then fwd.feedNow() end
    return true
end

--- The movers (client/scene_movers.lua) place a moving emitter on screen; the feed re-poses the others itself.
function AUDIO.place(node, _, x, y, z, rx, ry, rz)
    local r = recs[node.id]
    if r then r.x, r.y, r.z, r.rx, r.ry, r.rz, r.placedAt = x, y, z, rx, ry, rz, GetGameTimer() end
end

function AUDIO.destroy(node)
    local r = node and recs[node.id]
    if not r then return end
    recs[node.id] = nil
    local last = list[nRecs]
    list[r.i], last.i = last, r.i
    list[nRecs], nRecs = nil, nRecs - 1
    if r.oDirty then nOccl = nOccl - 1 end
    if r.mvDirty then nMove = nMove - 1 end
    local K = C.kinds
    if K and K.clearInteract then K.clearInteract(node.id) end
    local ids = {}
    if r.sent then ids[1] = r.id end
    unref(r.src, ids)
    stat.destroyed = stat.destroyed + 1
    if #ids > 0 then send(removeText(ids)) end
end

mat.registerKind('audio', AUDIO)

--------------------------------------------------------------------------------
-- The listener feed (<= Audio.ListenerHz, only while an emitter lives, only when something changed)
--------------------------------------------------------------------------------

local vol = { master = -1.0, music = -1.0, sfx = -1.0, ambience = -1.0, voice = -1.0 }
local veh = { e = 0, open = false, conv = false }
local paused = false
local envAt, volAt, lastFeed = -huge, -huge, -huge
local probe = { h = nil, r = nil, at = 0, tokens = 1.0, t = 0 }   -- the one in flight; the budget
local fb, fbn = {}, 0

local function camera(t)
    local c, q = GetFinalRenderedCamCoord(), GetFinalRenderedCamRot(2)
    local x, y, z = c.x, c.y, c.z
    local dt = (t - L.t) / 1000
    if L.t >= 0 and dt > 0 then
        local vx, vy, vz = (x - L.x) / dt, (y - L.y) / dt, (z - L.z) / dt
        if vx * vx + vy * vy + vz * vz > 90000 then vx, vy, vz = 0.0, 0.0, 0.0 end   -- > 300 m/s: a teleport
        L.vx, L.vy, L.vz = vx, vy, vz
    end
    L.x, L.y, L.z, L.t = x, y, z, t
    local p, r, w = rad(q.x), rad(q.y), rad(q.z)                -- rotation order 2: yaw * pitch * roll
    local sp, cp, sr, cr, sw, cw = sin(p), cos(p), sin(r), cos(r), sin(w), cos(w)
    L.fx, L.fy, L.fz = -sw * cp, cw * cp, sp
    L.ux, L.uy, L.uz = cw * sr + sw * sp * cr, sw * sr - cw * sp * cr, cp * cr
end

local function closedVehicle(e)
    if e ~= veh.e then
        veh.e = e
        veh.open = OPEN_CLASS[GetVehicleClass(e)] == true or not DoesVehicleHaveRoof(e)
        veh.conv = not veh.open and IsVehicleAConvertible(e, false) and true or false
    end
    if veh.open then return false end
    if not veh.conv then return true end
    local s = GetConvertibleRoofState(e)
    return s == 0 or s == 5                                          -- raised / stuck raised
end

--- The listener's environment (4 Hz) and every record's rule inputs that depend on it.
local function environment()
    local ped = PlayerPedId()
    local int = tointeger(GetInteriorFromEntity(ped)) or 0                 -- both go out through %d
    local room = int ~= 0 and tointeger(GetRoomKeyFromEntity(ped)) or 0
    local e = GetVehiclePedIsIn(ped, false)
    local closed = e ~= 0 and closedVehicle(e)
    local under = IsPedSwimmingUnderWater(ped) and true or false
    if int ~= L.int or room ~= L.room or closed ~= L.closed or under ~= L.under then envDirty = true end
    L.ped, L.veh, L.int, L.room, L.closed, L.under = ped, e, int, room, closed, under
    for i = 1, nRecs do
        local r = list[i]
        if r.node.attach ~= nil and (tointeger(r.node.parent) or 0) == 0 then r.anchor = mat.targetOf(r.node.attach) end
        if r.moving then r.int = GetInteriorAtCoords(r.x, r.y, r.z) end
        r.mine = r.anchor ~= 0 and (r.anchor == ped or r.anchor == e)
        rule(r)
        if not r.sent then push(r) end            -- a source that came after its emitter, or finished resolving
    end
end

local function volumes()
    local sfx = num(GetProfileSetting(PROFILE_SFX), 10, 0, 10) / 10
    local music = num(GetProfileSetting(PROFILE_MUSIC), 10, 0, 10) / 10
    local m, mu, sf, am, vo = prefs.master, music * prefs.music, sfx * prefs.sfx, sfx * prefs.ambience,
        sfx * prefs.voice
    if m ~= vol.master or mu ~= vol.music or sf ~= vol.sfx or am ~= vol.ambience or vo ~= vol.voice then
        vol.master, vol.music, vol.sfx, vol.ambience, vol.voice = m, mu, sf, am, vo
        volDirty = true
    end
end

--- Moving emitters the movers did not place just now are posed here; >= 0.1 m since the last sent -> the feed.
local function movers(t)
    for i = 1, nRecs do
        local r = list[i]
        if r.moving and r.sent then
            if t - r.placedAt > PLACED_MS then pose(r, nil) end
            local dx, dy, dz = r.x - r.mx, r.y - r.my, r.z - r.mz
            if not r.mvDirty and dx * dx + dy * dy + dz * dz >= EMOVE2 then r.mvDirty, nMove = true, nMove + 1 end
        end
    end
end

--- <= Audio.LosProbesPerSecond async probes (a token bucket, 2 banked): poll the one in flight, then start one
--- for the least recently asked due outdoor emitter in range (due every 0.5 s near .. 2 s far) — round-robin.
local function probes(t)
    local h = probe.h
    if h then
        local st, hit = GetShapeTestResult(h)
        if st == 1 and t - probe.at <= 1000 then return end   -- still running (1 = pending, 2 = done, 0 = gone)
        local r = probe.r
        if st == 2 and r and recs[r.id] == r then
            r.los = r.los + (((hit == true or hit == 1) and 1.0 or 0.0) - r.los) * 0.5
            rule(r)
        end
        probe.h, probe.r = nil, nil
    end
    local tok = probe.tokens + (t - probe.t) * PROBES / 1000
    probe.tokens, probe.t = tok > 2 and 2 or tok, t
    if probe.tokens < 1 then return end
    local best, bestD2
    for i = 1, nRecs do
        local r = list[i]
        if r.cand and r.sent and (not best or r.probeAt < best.probeAt) then
            local dx, dy, dz = r.x - L.x, r.y - L.y, r.z - L.z
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 < r.range * r.range then
                local every = sqrt(d2) * 25
                if every < 500 then every = 500 elseif every > 2000 then every = 2000 end
                if t - r.probeAt >= every then best, bestD2 = r, d2 end
            end
        end
    end
    if not best then return end
    local d = sqrt(bestD2)
    local k = d > 0.6 and (d - 0.5) / d or 0.0                 -- end short of the source's own geometry
    probe.h = StartShapeTestLosProbe(L.x, L.y, L.z, L.x + (best.x - L.x) * k, L.y + (best.y - L.y) * k,
        L.z + (best.z - L.z) * k, PROBE_FLAGS, best.anchor, PROBE_P8)
    probe.r, probe.at, best.probeAt, probe.tokens = best, t, t, probe.tokens - 1
    stat.probes = stat.probes + 1
end

local function put(s) fbn = fbn + 1 fb[fbn] = s end

--- The feed text: the listener always, the rest when changed (everything when `full`); clears what it carries.
local function feedText(full)
    fbn = 0
    put(fmt('{"action":"audio:feed","t":%d,"lx":%.2f,"ly":%.2f,"lz":%.2f,"fx":%.4f,"fy":%.4f,"fz":%.4f,"ux":%.4f,'
        .. '"uy":%.4f,"uz":%.4f,"vx":%.2f,"vy":%.2f,"vz":%.2f', Clock.now(), L.x, L.y, L.z, L.fx, L.fy, L.fz, L.ux,
        L.uy, L.uz, L.vx, L.vy, L.vz))
    if full or envDirty then
        put(fmt(',"env":{"interior":%d,"room":%d,"vehicle":%s,"underwater":%s}', L.int, L.room, tostring(L.closed),
            tostring(L.under)))
    end
    if full or volDirty then
        put(fmt(',"master":%.3f,"music":%.3f,"sfx":%.3f,"ambience":%.3f,"voice":%.3f', vol.master, vol.music,
            vol.sfx, vol.ambience, vol.voice))
    end
    if full or pauseDirty then put(paused and ',"paused":true' or ',"paused":false') end
    local sep = ',"moving":{'
    for i = 1, nMove > 0 and nRecs or 0 do
        local r = list[i]
        if r.mvDirty then
            put(fmt('%s"n%d":{"x":%.2f,"y":%.2f,"z":%.2f}', sep, r.id, r.x, r.y, r.z))
            sep, r.mvDirty, r.mx, r.my, r.mz = ',', false, r.x, r.y, r.z
        end
    end
    if sep == ',' then put('}') end
    sep = ',"occl":{'
    for i = 1, nOccl > 0 and nRecs or 0 do
        local r = list[i]
        if r.oDirty then
            if r.sent then
                put(fmt('%s"n%d":%.3f', sep, r.id, r.occl))
                sep, r.occlSent = ',', r.occl
            end
            r.oDirty = false
        end
    end
    if sep == ',' then put('}') end
    put('}')
    nMove, nOccl = 0, 0
    envDirty, volDirty, pauseDirty, force = false, false, false, false
    L.sx, L.sy, L.sz, L.sfx, L.sfy, L.sfz, L.sux, L.suy, L.suz = L.x, L.y, L.z, L.fx, L.fy, L.fz, L.ux, L.uy, L.uz
    return concat(fb, '', 1, fbn)
end

--- One pass (<= 20 Hz) -> true when a feed went out.
local inStep = false

local function step(t)
    inStep = true
    camera(t)
    if t >= envAt then
        envAt = t + ENV_MS
        environment()
    end
    if t >= volAt then
        volAt = t + VOL_MS
        volumes()
    end
    local UI = rawget(Core, 'UI')
    local hidden = UI and rawget(UI, 'isHidden')
    local p = IsPauseMenuActive() and true or (hidden and hidden() == true) or false
    if p ~= paused then paused, pauseDirty = p, true end
    movers(t)
    if PROBES > 0 then probes(t) end
    inStep = false
    local dx, dy, dz = L.x - L.sx, L.y - L.sy, L.z - L.sz
    local df, du = L.fx * L.sfx + L.fy * L.sfy + L.fz * L.sfz, L.ux * L.sux + L.uy * L.suy + L.uz * L.suz
    local due = force or envDirty or volDirty or pauseDirty or nMove > 0 or nOccl > 0
        or t - lastFeed >= HEARTBEAT_MS or dx * dx + dy * dy + dz * dz >= MOVE2 or df < TURN_COS or du < TURN_COS
    if not due or t - lastFeed < FEED_MS then return false end
    local i = 1
    while i <= nRecs and not list[i].sent do i = i + 1 end
    if i > nRecs then                          -- nothing on the page to hear: the next feed goes out whole
        force = true
        return false
    end
    prime()
    send(feedText(force))
    lastFeed, stat.feeds, fwd.feedSoon = t, stat.feeds + 1, false
    return true
end

local function loop()
    while nRecs > 0 and not stopped do
        local ok, sent = true, false
        if enabled and nuiReady() then ok, sent = pcall(step, GetGameTimer()) end
        if not ok and not stat.failed then Log.warn('scene audio: listener pass failed: %s', tostring(sent)) end
        if not ok then inStep, stat.failed = false, true end
        Wait(sent == true and FEED_MS or STILL_MS)
    end
    looping = false
end

function fwd.ensureLoop()
    if looping or stopped then return end
    looping, force = true, true
    CreateThread(loop)
end

function fwd.feedNow()                    -- a feed now, not at the loop's next pass: an emitter just reached the page
    fwd.feedSoon = false
    if looping and not inStep and enabled and nuiReady() then step(GetGameTimer()) end
end

--------------------------------------------------------------------------------
-- Replays, the setting, the page's answers, /audio, C.audio
--------------------------------------------------------------------------------

--- Everything the shell must hear again (a reloaded shell, the setting back on).
local function replay()
    primed, force = false, true
    for _, so in pairs(srcRefs) do so.sent = nil end
    for i = 1, nRecs do
        local r = list[i]
        r.sent, r.occlSent = nil, 0.0
        if r.mvDirty then r.mvDirty, nMove = false, nMove - 1 end
    end
    if not (enabled and nuiReady()) then return end
    if debugOn then prime() end
    for i = 1, nRecs do push(list[i]) end
    if fwd.feedSoon then fwd.feedNow() end
end

local function setEnabled(on)
    if on == enabled then return end
    enabled = on
    if on then return replay() end
    local ids = {}
    for i = 1, nRecs do
        local r = list[i]
        if r.sent then ids[#ids + 1], r.sent = r.id, nil end
    end
    for sid in pairs(srcRefs) do sourceGone(sid, ids) end
    if #ids > 0 then send(removeText(ids)) end
end

--- scene.audio.allowHosts (replicated) -> the lower-cased list the page keeps redirects / HLS segments in, or nil.
local function readHosts(v)
    local out = {}
    for i = 1, type(v) == 'table' and math.min(#v, 64) or 0 do
        if type(v[i]) == 'string' and v[i] ~= '' then out[#out + 1] = v[i]:lower() end
    end
    hosts = #out > 0 and out or nil
end

local Settings = rawget(Core, 'Settings')
if Settings and Settings.get then
    local ok, v = pcall(Settings.get, 'scene.audio.enabled')
    enabled = not ok or v ~= false
    ok, v = pcall(Settings.get, 'scene.audio.allowHosts')
    if ok then readHosts(v) end
end
Core.on('settingChanged', function(key, value)
    if key == 'scene.audio.enabled' then
        setEnabled(value ~= false)
    elseif key == 'scene.audio.allowHosts' then
        readHosts(value)
        for i = 1, nRecs do push(list[i]) end           -- sources whose text changed go again
    end
end)
Core.on('uiReady', replay)

-- NUI -> Lua through the ui_event bridge (page 'audio'): errors are logged once per node and code, stats kept
AddEventHandler('core:ui:audio:error', function(data)
    if type(data) ~= 'table' then return end
    stat.errors = stat.errors + 1
    local id, code = tointeger(data.id) or 0, type(data.code) == 'string' and data.code:sub(1, 32) or '?'
    local key = id .. ':' .. code
    if errSeen[key] or errN >= 64 then return end
    errSeen[key], errN = true, errN + 1
    Log.warn('scene audio: the page reports %s for node %d', code, id)
end)

local function summary(s)
    local v = type(s.voices) == 'table' and s.voices or EMPTY
    local src, ck = type(s.sources) == 'table' and s.sources or EMPTY, type(s.clock) == 'table' and s.clock or EMPTY
    return fmt('[core] audio: voices %s real / %s virtual / %s max, sources %s (decoders %s/%s), clock offset %s ms '
        .. '(%s samples), emitters %d, feeds %d, probes %d', tostring(v.real), tostring(v.virtual), tostring(v.max),
        tostring(src.total), tostring(src.decoders), tostring(src.maxDecoders), tostring(ck.offset),
        tostring(ck.samples), nRecs, stat.feeds, stat.probes)
end

AddEventHandler('core:ui:audio:stats', function(data)
    if type(data) ~= 'table' then return end
    lastStats, statsN = data, statsN + 1
    if debugOn and statsN % 5 == 1 then print(summary(data)) end
end)

local function sendPrefs()
    savePrefs()
    if primed and enabled and nuiReady() then send(prefsText()) end
end

local function setDebug(on)
    debugOn = on
    print(('[core] audio debug %s'):format(on and 'on' or 'off'))
    if not (enabled and nuiReady()) then return end
    if primed then send(debugText(on)) elseif on then prime() end
end

local function onOff(v)
    if v == 'on' or v == 'true' or v == '1' then return true end
    if v == 'off' or v == 'false' or v == '0' then return false end
    return nil
end

local USAGE <const> = '[core] /audio volume <0-100> [master|music|sfx|ambience|voice] | hrtf on|off | streams on|off'
    .. ' | offset <-1000..1000 ms> | voices <1-64> | debug on|off'

RegisterCommand('audio', function(_, args)
    local a = args or EMPTY
    local cmd, v = a[1], a[2]
    if cmd == 'volume' then
        local n, cat = tonumber(v), a[3] or 'master'
        if not n or n ~= n or n < 0 or n > 100 or not CATS[cat] then return print(USAGE) end
        prefs[cat], volAt = n / 100, -huge                  -- read again on the next pass
        savePrefs()
        print(('[core] audio volume %s = %d'):format(cat, floor(n)))
    elseif cmd == 'hrtf' or cmd == 'streams' then
        local on = onOff(v)
        if on == nil then return print(USAGE) end
        prefs[cmd] = on
        sendPrefs()
        print(('[core] audio %s %s'):format(cmd, on and 'on' or 'off'))
    elseif cmd == 'offset' or cmd == 'voices' then
        local n = tonumber(v)
        local lo, hi = cmd == 'offset' and -1000 or 1, cmd == 'offset' and 1000 or 64
        if not n or n ~= n or n < lo or n > hi then return print(USAGE) end
        prefs[cmd == 'offset' and 'offsetMs' or 'maxVoices'] = floor(n)
        sendPrefs()
        print(('[core] audio %s = %d'):format(cmd, floor(n)))
    elseif cmd == 'debug' then
        local on = onOff(v)
        if on == nil then on = not debugOn end
        setDebug(on)
    elseif cmd == nil or cmd == 'stats' then
        print(('[core] audio: %s, emitters %d, sources %d, feeds %d, probes %d, sent %d, page errors %d, prefs %s')
            :format(enabled and 'on' or 'off (scene.audio.enabled)', nRecs, nSrcs, stat.feeds, stat.probes,
                stat.sent, stat.errors, json.encode(prefs)))
        if lastStats then print(summary(lastStats)) end
    else
        print(USAGE)
    end
end, false)

RegisterCommand('audiodebug', function() setDebug(not debugOn) end, false)

C.audio = {
    handler = AUDIO,
    stats = function()
        return { emitters = nRecs, sources = nSrcs, enabled = enabled, primed = primed, debug = debugOn,
            looping = looping, sent = stat.sent, feeds = stat.feeds, probes = stat.probes, errors = stat.errors,
            created = stat.created, destroyed = stat.destroyed, page = lastStats }
    end,
    positionOf = function(id)                 -- x, y, z | nil
        local r = recs[id]
        return r and r.x, r and r.y, r and r.z
    end,
    occlusionOf = function(id) return recs[id] and recs[id].occl or 0.0 end,
    listener = function() return L.x, L.y, L.z, L.fx, L.fy, L.fz end,
}

loadPrefs()

local SELF <const> = GetCurrentResourceName()
AddEventHandler('onClientResourceStop', function(resource)
    if resource == SELF then stopped = true end
end)
