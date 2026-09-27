--[[ core — client/scene_voice.lua — voice through world speakers, the client half (DESIGN §55.17)
     Loads after client/scene_audio.lua and before client/scene.lua (which clears the one-shot global
     CoreSceneRuntime); it fills C.voice (internal: stats, setAdapter). Both roles are driven by
     server/scene_voice.lua; nothing here is reachable by plugins.

     LISTENER — core:scene:voice:listen (sessionId, talker, speakers = { { id, x, y, z } … }, fx, range) and
     core:scene:voice:unlisten (sessionId). A fixed pool of Voice.Submixes custom submixes is created ONCE at start:
     CreateAudioSubmix('core_vs_<n>') (cached by name, so a core restart gets the same ids back; there is no destroy
     native, the device holds 40 and voice routes only into 28–39, R2 §B7/§B8), then AddAudioSubmixOutput(id, 0)
     BEFORE any SetAudioSubmixOutputVolumes (output slot 0 = master — pma-voice sets its volumes first, so they
     never apply), RadioFX in effect slot 0 (disabled until a session wants a preset). A heard session takes a free
     submix, sets its preset and its first gains, then ONCE MumbleSetVolumeOverrideByServerId(talker, 1.0) +
     MumbleSetSubmixForServerId(talker, submix); afterwards only SetAudioSubmixOutputVolumes(submix, 0, fl, fr, rl,
     rr, c, 0) at Voice.PanHz, from a loop that exists only while a panned session is heard, and only when a gain
     moved more than 0.002. A changed override or submix recreates the voice (a 20–40 ms dropout, NuiAudioSink.cpp
     2035-2047; setting the SAME values changes nothing), so neither is ever animated. Unlisten: submix -1, override
     -1.0, the submix back to the pool. No free submix, or no native audio (a submix routes a voice only with
     `setr voice_useNativeAudio true`, R2 §B6) → volume only: the override set ONCE to the summed gain of that
     moment (0.1..1), no panning.
     Gains, per speaker: the camera-relative direction (GetFinalRenderedCamCoord/Rot, read once per pan tick) →
     equal-power L/R × equal-power front/rear (4 channels; the overridden voice is quad 1,1,1,1 — NAS:1720-1731 —
     so the centre only mirrors min(fl, fr)), × the §55.16 'game' curve (GTA's table, a cos² window to 0 at range,
     ui/src/runtime/audio/curves.ts), × the occlusion of that node when client/scene_audio.lua offers
     C.audio.occlusionOf(id) (0 dB … −15 dB); the speakers' energies are summed per channel, each clamped to 1 (the
     mixer's Q15 range). A moving speaker (motion, attach, parent) that is materialised here is read from its entity;
     every other one from the server's pose (re-sent when a speaker moved >= 1 m).
     pma-voice resets a talker's override / submix when he stops talking on its radio or leaves a radio / call
     (client/init/main.lua:148-177 toggleVoice: override -1 at once, submix after 250 ms): after its
     setTalkingOnRadio(false) / removePlayerFromRadio / removePlayerFromCall / syncRadioData events every heard
     session is routed again 300 ms later (the same values: a no-op for a talker it did not touch), except a talker
     that is talking on its radio right now.

     TALKER — core:scene:voice:targets (sessionId, add[], remove[]): a voice adapter adds / removes the listeners as
     whisper targets of the voice target the running voice resource talks on. 'pma-voice' (started): target 1 —
     its `voiceTarget` (shared.lua:3, made the active target in client/events.lua:7). Its 200 ms proximity refresh
     clears only the CHANNELS (client/init/proximity.lua:36), but -radiotalk (client/module/radio.lua:249), a call
     ending (client/module/phone.lua:21,27) and a (re)connect / setVoiceState (client/events.lua:6) clear the
     PLAYERS: the listeners are added again right after its local 'pma-voice:radioActive' (false) event
     (radio.lua:251, fired after that clear) and every second. Otherwise 'raw': MumbleAddVoiceTargetPlayerByServerId
     on Voice.Target (default 1), also re-applied every second. The re-apply loop exists only while a listener is
     held. A session the talker's client first hears of while MumbleIsConnected() is false is answered with
     core:scene:voice:report (sessionId, 'no_voice'); the server ends it.

     Natives (fxref 2026-09-27; runtime names checked in natives.json / natives_cfx.json; apiset client unless
     noted; BOOL answers read by truthiness): CreateAudioSubmix(name) -> int, AddAudioSubmixOutput(submixId,
     outputSubmixId), SetAudioSubmixEffectRadioFx(submixId, effectSlot), SetAudioSubmixEffectParamInt(submixId,
     effectSlot, paramIndex, paramValue), SetAudioSubmixEffectParamFloat(submixId, effectSlot, paramIndex,
     paramValue), SetAudioSubmixOutputVolumes(submixId, outputSlot, frontLeftVolume, frontRightVolume,
     rearLeftVolume, rearRightVolume, channel5Volume, channel6Volume), MumbleSetVolumeOverrideByServerId(serverId,
     volume), MumbleSetSubmixForServerId(serverId, submixId), MumbleAddVoiceTargetPlayerByServerId(targetId,
     serverId), MumbleRemoveVoiceTargetPlayerByServerId(targetId, serverId), MumbleIsConnected() -> BOOL,
     GetResourceState(resourceName) (CFX shared), GetFinalRenderedCamCoord() -> vector3,
     GetFinalRenderedCamRot(rotationOrder) -> vector3, GetEntityCoords(entity, alive) -> vector3,
     GetHashKey(string) -> int, GetPlayerServerId(player) -> int, PlayerId() -> int, GetConvar(varName, default_)
     (CFX shared), GetCurrentResourceName() (CFX shared). Runtime helpers: RegisterNetEvent, AddEventHandler,
     TriggerServerEvent, CreateThread, Wait, SetTimeout.
]]

local C = CoreSceneRuntime
assert(type(C) == 'table' and type(C.mat) == 'table',
    'client/scene_voice.lua loads after the materialiser and before client/scene.lua (CoreSceneRuntime.mat)')
local mat, cache = C.mat, C.cache
local Utils = Core.Utils

local type, pairs, next, pcall, tostring = type, pairs, next, pcall, tostring
local sqrt, sin, cos, rad, floor, abs, min, max = math.sqrt, math.sin, math.cos, math.rad, math.floor, math.abs,
    math.min, math.max
local mtype, tointeger, huge = math.type, math.tointeger, math.huge
local PI4 <const>, HALF_PI <const> = math.pi / 4, math.pi / 2

local V = {}
C.voice = V

-- settings (read once)
local VC = (type(Config) == 'table' and type(Config.Scene) == 'table' and type(Config.Scene.Voice) == 'table')
    and Config.Scene.Voice or {}
local function num(v, default, low, high)
    v = tonumber(v) or default
    if v ~= v or v < low then return low end
    return v > high and high or v
end
local POOL_SIZE <const> = floor(num(VC.Submixes, 8, 0, 12))
local PAN_MS <const> = floor(1000 / num(VC.PanHz, 15, 1, 60))
local TARGET <const> = floor(num(VC.Target, 1, 1, 30))
local REAPPLY_MS <const> = 1000
local REPAIR_MS <const> = 300          -- after pma-voice's own 250 ms submix reset (client/init/main.lua:169)
local EPS <const> = 0.002              -- the smallest gain change worth a SetAudioSubmixOutputVolumes
local FALLBACK_MIN <const>, FALLBACK_MAX <const> = 0.1, 1.0
local MAX_SPEAKERS <const>, MAX_LIST <const> = 64, 256
local PMA <const> = 'pma-voice'
local EV_REPORT <const> = 'core:scene:voice:report'
local SELF_RES <const> = GetCurrentResourceName()
local SELF <const> = GetPlayerServerId(PlayerId())

local function finite(v) return type(v) == 'number' and v == v and v ~= huge and v ~= -huge end

--------------------------------------------------------------------------------
-- The §55.16 'game' curve (ui/src/runtime/audio/curves.ts curveGain('game')): GTA's table, dB interpolated linearly
-- in distance, falling linearly to 0 at 128 m past the last point; a cos² window over the last 20 % of `range`
--------------------------------------------------------------------------------

local CD <const> = { 5, 10, 20, 40, 64, 100 }
local CDB <const> = { 0, -14, -31, -49, -62, -76 }
local SILENT <const> = 128

local function gameTable(d)
    if d <= CD[1] then return 1.0 end
    for i = 2, #CD do
        local d1 = CD[i]
        if d <= d1 then
            local d0, db0 = CD[i - 1], CDB[i - 1]
            return 10 ^ ((db0 + (CDB[i] - db0) * (d - d0) / (d1 - d0)) / 20)
        end
    end
    if d >= SILENT then return 0.0 end
    return 10 ^ (CDB[#CDB] / 20) * (1 - (d - CD[#CD]) / (SILENT - CD[#CD]))
end

--- Distance gain 0..1, exactly 0 from `range` on.
local function curveGain(d, range)
    if not (d < range) then return 0.0 end
    local g = gameTable(d)
    local w0 = range * 0.8
    if d > w0 then
        local c = cos(HALF_PI * ((d - w0) / (range - w0)))
        g = g * c * c
    end
    return g
end

--------------------------------------------------------------------------------
-- RadioFX presets (FiveM RadioDSP.cpp:543-592: `default` = enabled, 389–3,248 Hz in, 348–4,900 Hz out, rm_mix 0.16
-- with no ring modulator frequency; `fudge` mixes in a crushed copy, 0.05 × fudge of it) and the submix pool
--------------------------------------------------------------------------------

local PRESETS <const> = {
    none = false,                                                                         -- RadioFX off
    radio = {},                                                                           -- FiveM's default
    megaphone = { freq_low = 400.0, freq_hi = 3500.0, o_freq_lo = 400.0, o_freq_hi = 3500.0, fudge = 3.0 },
    phone = { freq_low = 300.0, freq_hi = 3400.0, o_freq_lo = 300.0, o_freq_hi = 3400.0 },
    pa = { freq_low = 120.0, freq_hi = 7000.0, o_freq_lo = 100.0, o_freq_hi = 8000.0, rm_mix = 0.0 },  -- light band
}
local PARAMS <const> = { 'freq_low', 'freq_hi', 'o_freq_lo', 'o_freq_hi', 'fudge', 'rm_mix' }
local HASH = {}
do
    local names = { 'enabled', 'default', table.unpack(PARAMS) }
    for i = 1, #names do HASH[names[i]] = GetHashKey(names[i]) end
end

local pool = {}              -- { id = submix index, busy, fx = the preset applied }

--- The pool, ONCE: create → output to master (slot 0) → RadioFX (off) → silent until a session takes it.
local function createPool()
    for n = 1, POOL_SIZE do
        local id = tointeger(CreateAudioSubmix('core_vs_' .. n))
        if id and id >= 0 then
            AddAudioSubmixOutput(id, 0)                              -- BEFORE any output volume (R2 §B8)
            SetAudioSubmixEffectRadioFx(id, 0)
            SetAudioSubmixEffectParamInt(id, 0, HASH.enabled, 0)
            SetAudioSubmixOutputVolumes(id, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
            pool[#pool + 1] = { id = id, busy = false, fx = 'none' }
        end
    end
end

--- Submixes route a voice only in native-audio mode (pma-voice sets it by default, server/main.lua:59-72).
local function nativeAudio() return GetConvar('voice_useNativeAudio', 'false') == 'true' end

local function takeSlot()
    for i = 1, #pool do
        local slot = pool[i]
        if not slot.busy then
            slot.busy = true
            return slot
        end
    end
    return nil
end

--- A slot's RadioFX preset (only when it changes).
local function applyFx(slot, fx)
    if slot.fx == fx then return end
    slot.fx = fx
    local p, id = PRESETS[fx], slot.id
    if not p then
        SetAudioSubmixEffectParamInt(id, 0, HASH.enabled, 0)
        return
    end
    SetAudioSubmixEffectParamInt(id, 0, HASH.default, 1)            -- enabled + FiveM's defaults
    for i = 1, #PARAMS do
        local k = PARAMS[i]
        local v = p[k]
        if v then SetAudioSubmixEffectParamFloat(id, 0, HASH[k], v) end
    end
end

--------------------------------------------------------------------------------
-- Gains
--------------------------------------------------------------------------------

--- A speaker's position: a moving node materialised here from its entity, otherwise the server's pose.
local function speakerPos(s, i)
    local id = s.ids[i]
    local node = cache and cache.node(id)
    if node and (node.motion or node.attach or (node.parent and node.parent ~= 0)) then
        local h = mat.handleOf and mat.handleOf(id)
        if h and h ~= 0 then
            local c = GetEntityCoords(h, false)
            if c and (c.x ~= 0.0 or c.y ~= 0.0) then return c.x, c.y, c.z end
        end
    end
    return s.xs[i], s.ys[i], s.zs[i]
end

--- Channel gains fl, fr, rl, rr of session `s` for a camera at cx..cz looking along (fwx, fwy): per speaker
--- equal-power L/R × front/rear × curve × occlusion, energies summed per channel, each clamped to 1.
local function gains(s, cx, cy, cz, fwx, fwy, occl)
    local efl, efr, ebl, ebr = 0.0, 0.0, 0.0, 0.0
    local rtx, rty = fwy, -fwx                  -- right of the view (yaw 0 looks along +y: right = +x)
    for i = 1, s.n do
        local x, y, z = speakerPos(s, i)
        local dx, dy, dz = x - cx, y - cy, z - cz
        local g = curveGain(sqrt(dx * dx + dy * dy + dz * dz), s.range)
        if g > 0.0 then
            if occl then
                local o = occl(s.ids[i])
                if type(o) == 'number' and o > 0 then g = g * 10 ^ (-0.75 * min(o, 1.0)) end   -- −15 dB × o
            end
            local side, front = 0.0, 1.0
            local h = sqrt(dx * dx + dy * dy)
            if h >= 0.5 then
                side, front = (dx * rtx + dy * rty) / h, (dx * fwx + dy * fwy) / h
                side = side > 1.0 and 1.0 or (side < -1.0 and -1.0 or side)
                front = front > 1.0 and 1.0 or (front < -1.0 and -1.0 or front)
            end
            local a = (side + 1.0) * PI4
            local gl, gr = cos(a), sin(a)
            local f, b = (1.0 + front) * 0.5, (1.0 - front) * 0.5   -- squared front / rear weights
            local g2 = g * g
            efl, efr = efl + g2 * gl * gl * f, efr + g2 * gr * gr * f
            ebl, ebr = ebl + g2 * gl * gl * b, ebr + g2 * gr * gr * b
        end
    end
    return min(1.0, sqrt(efl)), min(1.0, sqrt(efr)), min(1.0, sqrt(ebl)), min(1.0, sqrt(ebr))
end

--- The audio occlusion lookup of client/scene_audio.lua, when it offers one.
local function occlusionFn()
    local a = C.audio
    local f = type(a) == 'table' and a.occlusionOf or nil
    return type(f) == 'function' and f or nil
end

--- The camera: position and horizontal forward (yaw 0 = +y).
local function camera()
    local c = GetFinalRenderedCamCoord()
    local r = GetFinalRenderedCamRot(2)
    local yaw = rad(r.z)
    return c.x, c.y, c.z, -sin(yaw), cos(yaw)
end

--- One SetAudioSubmixOutputVolumes when a gain moved more than EPS.
local function push(s, fl, fr, rl, rr)
    local g = s.g
    if abs(fl - g[1]) < EPS and abs(fr - g[2]) < EPS and abs(rl - g[3]) < EPS and abs(rr - g[4]) < EPS then return end
    g[1], g[2], g[3], g[4] = fl, fr, rl, rr
    SetAudioSubmixOutputVolumes(s.slot.id, 0, fl, fr, rl, rr, min(fl, fr), 0.0)
end

--------------------------------------------------------------------------------
-- Listener: heard sessions, routing, the pan loop
--------------------------------------------------------------------------------

local heard = {}             -- [sessionId] = { sid, talker, fx, range, n, ids, xs, ys, zs, slot | nil, vol | nil, g }
local byTalker = {}          -- [talker] = sessionId
local heardN, pannedN = 0, 0
local radioTalking = {}      -- [talker] = true while pma-voice routes his radio transmission
local stopped, panning, repairPending = false, false, false

--- The talker's voice into the session's submix (or the flat fallback volume). ONCE per session — the same
--- values again (a repair) change nothing in the engine.
local function route(s)
    if s.slot then
        MumbleSetVolumeOverrideByServerId(s.talker, 1.0)
        MumbleSetSubmixForServerId(s.talker, s.slot.id)
    else
        MumbleSetVolumeOverrideByServerId(s.talker, s.vol)
    end
end

local function unroute(s)
    if s.slot then MumbleSetSubmixForServerId(s.talker, -1) end
    MumbleSetVolumeOverrideByServerId(s.talker, -1.0)
end

--- Validates, then copies { { id, x, y, z } … } into the session's arrays -> ok.
local function readSpeakers(s, list)
    if type(list) ~= 'table' then return false end
    local n = #list
    if n < 1 or n > MAX_SPEAKERS then return false end
    for i = 1, n do
        local e = list[i]
        if type(e) ~= 'table' or not tointeger(e[1]) or not finite(e[2]) or not finite(e[3]) or not finite(e[4]) then
            return false
        end
    end
    for i = 1, n do
        local e = list[i]
        s.ids[i], s.xs[i], s.ys[i], s.zs[i] = tointeger(e[1]), e[2] + 0.0, e[3] + 0.0, e[4] + 0.0
    end
    for i = n + 1, s.n do s.ids[i], s.xs[i], s.ys[i], s.zs[i] = nil, nil, nil, nil end
    s.n = n
    return true
end

local function panTick()
    local cx, cy, cz, fwx, fwy = camera()
    local occl = occlusionFn()
    for _, s in pairs(heard) do
        if s.slot then push(s, gains(s, cx, cy, cz, fwx, fwy, occl)) end
    end
end

--- Exists only while a panned session is heard.
local function panLoop()
    while pannedN > 0 and not stopped do
        Wait(PAN_MS)
        if pannedN > 0 and not stopped then panTick() end
    end
    panning = false
end

local function ensurePan()
    if panning or pannedN == 0 or stopped then return end
    panning = true
    CreateThread(panLoop)
end

local function unlisten(sid)
    local s = heard[sid]
    if not s then return end
    heard[sid] = nil
    if byTalker[s.talker] == sid then byTalker[s.talker] = nil end
    heardN = heardN - 1
    unroute(s)
    if s.slot then
        s.slot.busy = false
        pannedN = pannedN - 1
    end
end

local function listen(sid, talker, speakers, fx, range)
    if PRESETS[fx] == nil then fx = 'none' end
    range = (finite(range) and range >= 1 and range <= 600) and range + 0.0 or 60.0
    local s = heard[sid]
    if s then
        if s.talker == talker then readSpeakers(s, speakers) end      -- the poses only: never routed again
        return
    end
    local other = byTalker[talker]
    if other then unlisten(other) end                                  -- one routing per talker
    s = { sid = sid, talker = talker, fx = fx, range = range, n = 0, ids = {}, xs = {}, ys = {}, zs = {},
        g = { -1.0, -1.0, -1.0, -1.0 } }
    if not readSpeakers(s, speakers) then return end
    local cx, cy, cz, fwx, fwy = camera()
    local fl, fr, rl, rr = gains(s, cx, cy, cz, fwx, fwy, occlusionFn())
    local slot = nativeAudio() and takeSlot() or nil
    if slot then
        s.slot = slot
        applyFx(slot, fx)
        push(s, fl, fr, rl, rr)                                       -- panned BEFORE the voice arrives
        pannedN = pannedN + 1
    else
        s.vol = min(FALLBACK_MAX, max(FALLBACK_MIN, sqrt(fl * fl + fr * fr + rl * rl + rr * rr)))
    end
    heard[sid], byTalker[talker] = s, sid
    heardN = heardN + 1
    route(s)
    ensurePan()
end

RegisterNetEvent('core:scene:voice:listen', function(sid, talker, speakers, fx, range)
    if stopped or mtype(sid) ~= 'integer' or sid < 1 or mtype(talker) ~= 'integer' or talker < 1
        or talker == SELF then return end
    listen(sid, talker, speakers, type(fx) == 'string' and fx or 'none', range)
end)

RegisterNetEvent('core:scene:voice:unlisten', function(sid)
    if mtype(sid) == 'integer' then unlisten(sid) end
end)

--- pma-voice reset a talker (client/init/main.lua:148-177): route every heard session again 300 ms later.
local function repair()
    repairPending = false
    if stopped then return end
    for _, s in pairs(heard) do
        if not radioTalking[s.talker] then route(s) end
    end
end

local function scheduleRepair(talker)
    if heardN == 0 or repairPending or (talker and not byTalker[talker]) then return end
    repairPending = true
    SetTimeout(REPAIR_MS, repair)
end

RegisterNetEvent('pma-voice:setTalkingOnRadio', function(src, enabled)
    src = tointeger(src)
    if not src then return end
    radioTalking[src] = enabled and true or nil
    if not enabled then scheduleRepair(src) end
end)

RegisterNetEvent('pma-voice:removePlayerFromRadio', function(src)
    src = tointeger(src)
    if not src then return end
    if src == SELF then
        for k in pairs(radioTalking) do radioTalking[k] = nil end
        return scheduleRepair(nil)
    end
    radioTalking[src] = nil
    scheduleRepair(src)
end)

RegisterNetEvent('pma-voice:syncRadioData', function(radioTable)
    if type(radioTable) ~= 'table' then return end
    for k in pairs(radioTalking) do radioTalking[k] = nil end
    for src, talking in pairs(radioTable) do
        local id = tointeger(src)
        if id and talking then radioTalking[id] = true end
    end
    scheduleRepair(nil)
end)

RegisterNetEvent('pma-voice:removePlayerFromCall', function(src)
    src = tointeger(src)
    if not src then return end
    scheduleRepair(src ~= SELF and src or nil)
end)

--------------------------------------------------------------------------------
-- Talker: the voice adapter, held listeners, the re-apply loop
--------------------------------------------------------------------------------

local ADAPTER_PMA <const> = { name = PMA, target = 1 }        -- pma-voice's voiceTarget (shared.lua:3)
local ADAPTER_RAW <const> = { name = 'raw', target = TARGET }
local custom                 -- V.setAdapter: { name, add = callable(list), remove = callable(list) }
local refs = {}              -- [listener src] = how many of this talker's sessions hold it
local held = 0               -- #refs
local tsess = {}             -- [sessionId] = { [src] = true }
local reported = {}          -- [sessionId] = true: 'no_voice' sent
local list = {}              -- reused src list
local reapplying = false

--- The adapter for this moment: a custom one, else pma-voice when it runs, else 'raw'; nil without a voice
--- connection (the natives would do nothing).
local function adapter()
    if custom then return custom end
    if not MumbleIsConnected() then return nil end
    return GetResourceState(PMA) == 'started' and ADAPTER_PMA or ADAPTER_RAW
end

--- list[1..n] into (add) or out of the adapter's voice target.
local function apply(a, add, n)
    if n == 0 then return end
    local t = a.target
    if t then
        for i = 1, n do
            if add then
                MumbleAddVoiceTargetPlayerByServerId(t, list[i])
            else
                MumbleRemoveVoiceTargetPlayerByServerId(t, list[i])
            end
        end
        return
    end
    local ok, err = pcall(add and a.add or a.remove, table.move(list, 1, n, 1, {}))
    if not ok then Core.Log.warn('scene: voice adapter %s failed: %s', tostring(a.name), tostring(err)) end
end

--- list[1..n] = every held listener -> n.
local function fillHeld()
    local n = 0
    for src in pairs(refs) do
        n = n + 1
        list[n] = src
    end
    return n
end

--- Every held listener into the voice target again (the running voice resource may have cleared its players).
--- A custom adapter keeps its own state: it is handed the listeners once (setAdapter), never re-applied.
local function reapply()
    if held == 0 or stopped or custom then return end
    local a = adapter()
    if a then apply(a, true, fillHeld()) end
end

--- Exists only while a listener is held.
local function reapplyLoop()
    while held > 0 and not stopped do
        Wait(REAPPLY_MS)
        reapply()
    end
    reapplying = false
end

local function ensureReapply()
    if reapplying or held == 0 or stopped then return end
    reapplying = true
    CreateThread(reapplyLoop)
end

local function targets(sid, add, remove)
    local s = tsess[sid]
    if not s and not reported[sid] and not MumbleIsConnected() then
        reported[sid] = true
        TriggerServerEvent(EV_REPORT, sid, 'no_voice')
    end
    if not s then
        s = {}
        tsess[sid] = s
    end
    local a = adapter()
    local n = 0
    for i = 1, #add do
        local src = tointeger(add[i])
        if src and src > 0 and src ~= SELF and not s[src] then
            s[src] = true
            local r = (refs[src] or 0) + 1
            refs[src] = r
            if r == 1 then
                held, n = held + 1, n + 1
                list[n] = src
            end
        end
    end
    if a then apply(a, true, n) end
    n = 0
    for i = 1, #remove do
        local src = tointeger(remove[i])
        if src and s[src] then
            s[src] = nil
            local r = refs[src] - 1
            if r > 0 then
                refs[src] = r
            else
                refs[src], held, n = nil, held - 1, n + 1
                list[n] = src
            end
        end
    end
    if a then apply(a, false, n) end
    if next(s) == nil then tsess[sid] = nil end
    ensureReapply()
end

RegisterNetEvent('core:scene:voice:targets', function(sid, add, remove)
    if stopped or mtype(sid) ~= 'integer' or sid < 1 or type(add) ~= 'table' or type(remove) ~= 'table'
        or #add > MAX_LIST or #remove > MAX_LIST then return end
    targets(sid, add, remove)
end)

-- pma-voice's -radiotalk clears the players of its target, re-adds its call partners, THEN fires this local event
-- (client/module/radio.lua:246-251): the listeners go back in at once
AddEventHandler('pma-voice:radioActive', function(active)
    if not active then reapply() end
end)

--------------------------------------------------------------------------------
-- Cleanup, internals, start
--------------------------------------------------------------------------------

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= SELF_RES then return end
    local a = held > 0 and adapter() or nil
    if a then apply(a, false, fillHeld()) end
    for _, s in pairs(heard) do unroute(s) end
    stopped = true
end)

--- { pool, free, heard, panned, held, adapter } (the /scene debug overlay, tests).
function V.stats()
    local free = 0
    for i = 1, #pool do
        if not pool[i].busy then free = free + 1 end
    end
    local a = adapter()
    return { pool = #pool, free = free, heard = heardN, panned = pannedN, held = held,
        adapter = a and a.name or 'none' }
end

--- Internal: replaces the automatic adapter choice (nil restores it) -> ok. `a.add` / `a.remove` receive a fresh
--- array of server ids; the held listeners move at once (out of the old adapter, into the new one).
function V.setAdapter(a)
    if a ~= nil and (type(a) ~= 'table' or not Utils.isCallable(a.add) or not Utils.isCallable(a.remove)) then
        return false
    end
    local n = held > 0 and not stopped and fillHeld() or 0
    local old = n > 0 and adapter() or nil
    if old then apply(old, false, n) end
    custom = a and { name = tostring(a.name or 'custom'), add = a.add, remove = a.remove } or nil
    local new = n > 0 and adapter() or nil
    if new then apply(new, true, n) end
    return true
end

createPool()
