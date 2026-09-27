--[[ core — client/scene_mat_assets.lua — the materialiser's resources: assets, interiors, fades (DESIGN §55.11)
     Split out of client/scene_materializer.lua, which drives everything here (this file never decides WHEN a
     node exists). It hands over through the one-shot global `CoreSceneRuntime` only — nothing on Core:
       C.assets  models, anim dicts and ptfx assets: requested once, ref-counted by the records that use them,
                 polled at 20 Hz by the materialiser's thread, failed after 10 s (once per session, one log line),
                 released ModelLingerMs after their last use; distinct models per class (Caps.modelsProps /
                 modelsVehicles / modelsPeds); the model sanity and class checks; interiors (fields.room or
                 GetInteriorAtCoords once per node, IsInteriorReady polled at 4 Hz while a node waits).
       C.fades   the slot-budgeted fade manager: <= Fades.Max at once (<= Fades.MaxVehicles vehicles), stepped by
                 frame time in ONE loop that exists only while a fade runs; SetEntityAlpha(e, a, false) from 51
                 (below 50 nothing is drawn), ResetEntityAlpha at the end of a fade-in, the owner's deletion (the
                 materialiser's hook), onDone or DeleteEntity at the end of a fade-out; a reversal continues from
                 the current alpha.
     Load order: right after client/scene_focus.lua (asserted), right before client/scene_materializer.lua (which
     asserts C.assets / C.fades and installs C.fades.hooks).

     Natives (fxref 2026-09-26 + runtime names checked in natives.json; apiset client; BOOL answers read by
     truthiness, DESIGN §30.4):
       GetGameTimer(), RequestModel(hash), HasModelLoaded(hash), SetModelAsNoLongerNeeded(hash),
       IsModelInCdimage(hash), IsModelValid(hash), IsModelAVehicle(hash), IsModelAPed(hash) (_IS_MODEL_A_PED),
       RequestAnimDict(dict), HasAnimDictLoaded(dict), RemoveAnimDict(dict), DoesAnimDictExist(dict),
       RequestNamedPtfxAsset(name), HasNamedPtfxAssetLoaded(name), RemoveNamedPtfxAsset(name), GetHashKey(str),
       GetInteriorAtCoords(x, y, z) -> interior, IsInteriorReady(interior), SetEntityAlpha(entity, alpha, skin),
       ResetEntityAlpha(entity), DoesEntityExist(entity), DeleteEntity(entity).
]]

local C = CoreSceneRuntime
assert(type(C) == 'table' and type(C.cache) == 'table' and type(C.focus) == 'table',
    'client/scene_mat_assets.lua loads right after client/scene_focus.lua (CoreSceneRuntime.focus)')

local floor, abs, tointeger = math.floor, math.abs, math.tointeger

-- settings: Config.Scene, clamped, read once
local K <const> = {}
do
    local CS = (type(Config) == 'table' and type(Config.Scene) == 'table') and Config.Scene or {}
    local function sub(name)
        local v = CS[name]
        return type(v) == 'table' and v or {}
    end
    local function num(v, default, low, high)
        v = tonumber(v) or default
        if v ~= v or v < low then return low end
        return v > high and high or v
    end
    local BU, CA, FA = sub('Budgets'), sub('Caps'), sub('Fades')
    K.inFlight = floor(num(BU.ModelsInFlight, 30, 1, 512))
    K.linger = num(CS.ModelLingerMs, 30000, 0, 3600000)
    K.modelCaps = { prop = floor(num(CA.modelsProps, 150, 1, 10000)),
        vehicle = floor(num(CA.modelsVehicles, 20, 1, 10000)), ped = floor(num(CA.modelsPeds, 20, 1, 10000)) }
    K.propIn, K.propOut = num(FA.PropInMs, 300, 1, 10000), num(FA.PropOutMs, 450, 1, 10000)
    K.ped, K.veh = num(FA.PedMs, 600, 1, 10000), num(FA.VehicleMs, 400, 1, 10000)
    K.fadeMax, K.fadeVeh = floor(num(FA.Max, 48, 1, 250)), floor(num(FA.MaxVehicles, 8, 1, 250))
    K.assetTimeoutMs = 10000
end
local ALPHA_MIN <const> = 51                -- below 50 nothing is drawn: ramps start and end here
local NAME <const> = { model = 'model', anim = 'anim dict', ptfx = 'ptfx asset' }   -- also the valid types
local MODEL_CLASS <const> = { prop = true, vehicle = true, ped = true }            -- classes with a model cap

local warned = {}
local function logWarn(fmt, ...)
    local log = Core.Log
    if log and log.warn then log.warn('scene: ' .. fmt, ...) else print(('[core] scene: ' .. fmt):format(...)) end
end

local function warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    logWarn(fmt, ...)
end

-- intrusive lists { n, [i] = item }: the item keeps its index in item[f]
local function ladd(L, x, f)
    local n = L.n + 1
    L.n, L[n], x[f] = n, x, n
end

local function lrem(L, x, f)
    local i = x[f]
    if not i or i == 0 then return end
    local n = L.n
    local last = L[n]
    L[i], last[f] = last, i
    L[n], L.n, x[f] = nil, n - 1, 0
end

--------------------------------------------------------------------------------
-- C.assets — entries { ty, k, st = 'loading' | 'loaded' | 'failed', refs, … }: the materialiser reads `st`
--------------------------------------------------------------------------------

local A = {}
local store = { model = {}, anim = {}, ptfx = {} }   -- asset type -> key -> entry
local loadL = { n = 0 }                              -- entries streaming in
local nAssets, nLinger = 0, 0
local modelsActive = { prop = 0, vehicle = 0, ped = 0 }   -- distinct models in use per class

local function assetLoaded(e)
    local ty, k = e.ty, e.k
    if ty == 'model' then return HasModelLoaded(k) end
    if ty == 'anim' then return HasAnimDictLoaded(k) end
    return HasNamedPtfxAssetLoaded(k)
end

--- Gives the streaming request back.
local function assetDrop(e)
    local ty, k = e.ty, e.k
    if ty == 'model' then SetModelAsNoLongerNeeded(k) elseif ty == 'anim' then RemoveAnimDict(k)
    else RemoveNamedPtfxAsset(k) end
end

local function assetFail(e, why)
    if e.li ~= 0 then
        lrem(loadL, e, 'li')
        assetDrop(e)
    end
    e.st = 'failed'
    if e.lingerAt then e.lingerAt, nLinger = nil, nLinger - 1 end
    local k = e.k
    if e.ty == 'model' then
        logWarn('model %d (0x%08X) %s; its nodes stay unmaterialised this session', k, k & 0xFFFFFFFF, why)
    else
        logWarn('%s %s %s; its nodes stay unmaterialised this session', NAME[e.ty], k, why)
    end
end

--- The entry of an asset; the first use checks and requests it. `cls` = the first user's class (model caps).
local function assetEntry(ty, k, cls, t)
    local bucket = store[ty]
    local e = bucket[k]
    if e then return e end
    e = { ty = ty, k = k, st = 'loading', at = t, refs = 0, lingerAt = nil, li = 0,
        mc = (ty == 'model' and MODEL_CLASS[cls]) and cls or nil }
    bucket[k] = e
    nAssets = nAssets + 1
    if ty == 'model' then
        if not IsModelInCdimage(k) or not IsModelValid(k) then
            assetFail(e, 'is not in the game files')
            return e
        end
        e.veh, e.ped = IsModelAVehicle(k) and true or false, IsModelAPed(k) and true or false
        RequestModel(k)
    elseif ty == 'anim' then
        if not DoesAnimDictExist(k) then
            assetFail(e, 'does not exist')
            return e
        end
        RequestAnimDict(k)
    else
        RequestNamedPtfxAsset(k)
    end
    if assetLoaded(e) then e.st = 'loaded' else ladd(loadL, e, 'li') end
    return e
end

local function aref(e)
    if e.refs == 0 then
        if e.lingerAt then e.lingerAt, nLinger = nil, nLinger - 1 end
        local mc = e.mc
        if mc then modelsActive[mc] = modelsActive[mc] + 1 end
    end
    e.refs = e.refs + 1
end

local function aunref(e, t)
    if e.refs <= 0 then return end
    e.refs = e.refs - 1
    if e.refs > 0 then return end
    local mc = e.mc
    if mc then modelsActive[mc] = modelsActive[mc] - 1 end
    if e.st ~= 'failed' and not e.lingerAt then e.lingerAt, nLinger = t + K.linger, nLinger + 1 end
end

--- A handler's asset descriptor ({ type = 'model', hash } | { type = 'anim' | 'ptfx', name }) -> type, key.
function A.key(d)
    if type(d) ~= 'table' then return nil end
    local ty = NAME[d.type] and d.type
    if ty == 'model' then
        local h = d.hash or d.model or d.name
        if type(h) == 'string' then h = GetHashKey(h) end
        h = type(h) == 'number' and tointeger(h) or nil
        if h then return ty, h end
    elseif ty then
        local name = d.name
        if type(name) == 'string' and name ~= '' then return ty, name end
    end
    return nil
end

--- Is a model entry fit for a node class? (IsModelAVehicle / IsModelAPed, asked once per model)
local function fits(e, cls)
    if cls == 'vehicle' then return e.veh end
    if cls == 'ped' then return e.ped end
    if cls == 'prop' then return not e.veh and not e.ped end
    return true
end

--- Takes a ref on every asset a handler's descriptor list names, for a record of class `cls` (kind `kid`, for the
--- log). -> used (new requests made, >= 0), entries, bad | -1 over this frame's request budget `left` | -3 a
--- distinct-model cap is full | -4 ModelsInFlight streaming (nothing requested or ref'd for the negative answers).
--- `fresh` = nothing requested yet this frame: a list needing more than a whole frame's budget still goes then.
--- `bad` = a failed asset or a model of the wrong class: the caller fails the record and gives back with A.drop.
function A.acquire(list, cls, kid, t, left, fresh)
    local n = #list
    local mc = MODEL_CLASS[cls] and cls or nil
    local need, newModels = 0, 0
    for i = 1, n do
        local ty, k = A.key(list[i])
        if ty then
            local e = store[ty][k]
            if not e then need = need + 1 end
            if ty == 'model' and mc and (not e or (e.refs == 0 and e.st ~= 'failed')) then
                newModels = newModels + 1
            end
        end
    end
    if need > 0 then
        if loadL.n + need > K.inFlight then return -4 end
        if need > left and not fresh then return -1 end
    end
    if newModels > 0 and modelsActive[mc] + newModels > K.modelCaps[mc] then return -3 end
    local ae, bad = {}, false
    for i = 1, n do
        local ty, k = A.key(list[i])
        if ty then
            local e = assetEntry(ty, k, cls, t)
            ae[#ae + 1] = e
            aref(e)
            if e.st == 'failed' then
                bad = true
            elseif ty == 'model' and not fits(e, cls) then
                bad = true
                warnOnce(('class:%d:%s'):format(k, cls), 'model %d (0x%08X) is not a %s model; nodes of kind %s '
                    .. 'with it stay unmaterialised this session', k, k & 0xFFFFFFFF, cls, tostring(kid))
            end
        end
    end
    return need, ae, bad
end

--- Gives a record's entries back (the last user of an entry starts its linger).
function A.drop(ae, t)
    for i = 1, #ae do aunref(ae[i], t) end
end

--- Polls what streams in (the materialiser's thread, 20 Hz). -> true when something loaded or failed.
function A.poll(t)
    local changed, i = false, 1
    while i <= loadL.n do
        local e = loadL[i]
        if assetLoaded(e) then
            e.st = 'loaded'
            lrem(loadL, e, 'li')
            changed = true
        elseif t - e.at >= K.assetTimeoutMs then
            assetFail(e, 'did not load within 10 s')
            changed = true
        else
            i = i + 1
        end
    end
    return changed
end

--- Releases what nobody used for ModelLingerMs (the materialiser's thread, once a second while something lingers).
function A.release(t)
    for _, bucket in pairs(store) do
        for k, e in pairs(bucket) do
            local at = e.lingerAt
            if at and t >= at then
                e.lingerAt, nLinger = nil, nLinger - 1
                if e.refs == 0 then
                    if e.li ~= 0 then lrem(loadL, e, 'li') end
                    assetDrop(e)
                    bucket[k], nAssets = nil, nAssets - 1
                end
            end
        end
    end
end

function A.loading() return loadL.n end
function A.lingering() return nLinger end
--- -> entries, streaming, lingering, distinct models in use: props, vehicles, peds
function A.counts()
    return nAssets, loadL.n, nLinger, modelsActive.prop, modelsActive.vehicle, modelsActive.ped
end

-- interiors: a record's `int` / `roomKey` once, `intWait` while IsInteriorReady says no (polled at 4 Hz)
local intL = { n = 0 }
local intSeen, intRound = {}, 0   -- interior -> +round ready / -round not ready (one native per interior per poll)

--- The interior of an entity record (fields.room = { interior, key } from the editor, else GetInteriorAtCoords
--- once); a record whose interior is not ready yet waits (`intWait`). -> waiting
function A.interior(m)
    if not m.intChecked then
        m.intChecked = true
        local f = m.node.fields
        local room = type(f) == 'table' and f.room or nil
        local int, key = 0, nil
        if type(room) == 'table' then
            int = tonumber(room.interior or room[1]) or 0
            key = room.key or room[2]
            if type(key) == 'string' then key = GetHashKey(key) end
            if type(key) ~= 'number' then key = nil end
        end
        if int == 0 then int = GetInteriorAtCoords(m.x, m.y, m.z) or 0 end
        m.int, m.roomKey = int, key
    end
    if m.int ~= 0 and not m.intWait and not IsInteriorReady(m.int) then
        m.intWait = true
        ladd(intL, m, 'ii')
    end
    return m.intWait == true
end

--- The record no longer waits (released, failed, dropped).
function A.unwait(m)
    if not m.intWait then return end
    m.intWait = false
    lrem(intL, m, 'ii')
end

--- 4 Hz while records wait. -> true when an interior became ready.
function A.pollInteriors()
    intRound = intRound + 1
    local changed, i = false, 1
    while i <= intL.n do
        local m = intL[i]
        local int = m.int
        local seen = intSeen[int]
        local ok
        if seen == intRound then
            ok = true
        elseif seen == -intRound then
            ok = false
        else
            ok = IsInteriorReady(int) and true or false
            intSeen[int] = ok and intRound or -intRound
        end
        if ok then
            m.intWait = false
            lrem(intL, m, 'ii')
            changed = true
        else
            i = i + 1
        end
    end
    return changed
end

function A.interiorsPending() return intL.n end

--- Core stops: every request goes back now.
function A.shutdown()
    for _, bucket in pairs(store) do
        for k, e in pairs(bucket) do
            if e.st ~= 'failed' then assetDrop(e) end
            bucket[k] = nil
        end
    end
    loadL, intL = { n = 0 }, { n = 0 }
    nAssets, nLinger = 0, 0
    modelsActive.prop, modelsActive.vehicle, modelsActive.ped = 0, 0, 0
end

--------------------------------------------------------------------------------
-- C.fades — owner = a record / shell the materialiser deletes at the end of a fade-out (its hook)
--------------------------------------------------------------------------------

local F = {}
local fadeL, fpool, fadeOf = { n = 0 }, { n = 0 }, {}   -- running records, recycled records, entity -> record
local nVeh, running, stopped = 0, false, false
local onOwnerDone, onSlotFree = nil, nil               -- the materialiser's hooks

--- The materialiser installs: done(owner, t) deletes a faded-out owner, slot(t) reveals STAGED records.
function F.hooks(done, slot) onOwnerDone, onSlotFree = done, slot end

--- Fade length of a class (props: in / out).
function F.ms(cls, out)
    if cls == 'ped' then return K.ped end
    if cls == 'vehicle' then return K.veh end
    return out and K.propOut or K.propIn
end

function F.slotFree(veh) return fadeL.n < K.fadeMax and (not veh or nVeh < K.fadeVeh) end
function F.max() return K.fadeMax end

local function finish(r, t)
    local h, dir, owner, done = r.h, r.dir, r.m, r.done
    F.cancel(h)
    if dir > 0 then
        if DoesEntityExist(h) then ResetEntityAlpha(h) end
    elseif owner then
        if onOwnerDone then onOwnerDone(owner, t) end
    elseif done then
        local ok, err = pcall(done, h)
        if not ok then logWarn('fade-out callback failed: %s', tostring(err)) end
    elseif DoesEntityExist(h) then
        DeleteEntity(h)
    end
    if onSlotFree then onSlotFree(t) end
end

--- One fade, one frame (run in a pcall). -> true when it finished (it left the list)
local function stepFade(r, t)
    local span = (r.dir > 0 and 255 or ALPHA_MIN) - r.from
    local dur = r.ms * abs(span) / (255 - ALPHA_MIN)
    local p = dur > 0 and (t - r.t0) / dur or 1.0
    if p >= 1.0 then
        finish(r, t)
        return true
    end
    local a = floor(r.from + span * p + 0.5)
    if a ~= r.a then
        r.a = a
        SetEntityAlpha(r.h, a, false)
    end
    return false
end

local function loop()
    while fadeL.n > 0 and not stopped do
        local t = GetGameTimer()
        local i = 1
        while i <= fadeL.n do
            local r = fadeL[i]
            local ok, res = pcall(stepFade, r, t)
            if not ok then                   -- one broken fade never stops the others (F20): logged once, dropped
                warnOnce('fade:' .. tostring(res), 'a fade failed and was dropped: %s', tostring(res))
                if fadeL[i] == r then
                    if r.h ~= nil and fadeOf[r.h] == r then F.cancel(r.h) else lrem(fadeL, r, 'fi') end
                end
            elseif not res then
                i = i + 1                    -- finished ones left the list: the next one moved into slot i
            end
        end
        Wait(0)   -- per-frame: fades are stepped by frame time; the loop ends when the last one finished
    end
end

local function run()
    local ok, err = pcall(loop)
    running = false                          -- the next start() creates a new loop, whatever happened
    if not ok then warnOnce('fadeloop', 'the fade loop failed: %s', tostring(err)) end
end

--- Starts (or reverses) the fade of entity h: dir 1 = in (51 -> 255, then ResetEntityAlpha), -1 = out (-> 51,
--- then the owner's deletion / onDone / DeleteEntity). false when no slot is free.
function F.start(h, dir, ms, veh, owner, onDone, t)
    local r = fadeOf[h]
    if r then
        if r.dir ~= dir then r.dir, r.from, r.t0, r.ms = dir, r.a, t, ms end
        r.m, r.done = owner, onDone
        return true
    end
    if not F.slotFree(veh) then return false end
    local n = fpool.n
    if n > 0 then
        r = fpool[n]
        fpool[n], fpool.n = nil, n - 1
    else
        r = { fi = 0 }
    end
    local from = dir > 0 and ALPHA_MIN or 255
    r.h, r.dir, r.ms, r.veh, r.m, r.done, r.t0, r.from, r.a = h, dir, ms, veh == true, owner, onDone, t, from, from
    SetEntityAlpha(h, from, false)
    fadeOf[h] = r
    ladd(fadeL, r, 'fi')
    if r.veh then nVeh = nVeh + 1 end
    if not running then
        running = true
        CreateThread(run)
    end
    return true
end

--- Drops the fade of an entity that goes now (no callback).
function F.cancel(h)
    local r = fadeOf[h]
    if not r then return end
    fadeOf[h] = nil
    lrem(fadeL, r, 'fi')
    if r.veh then nVeh = nVeh - 1 end
    r.h, r.m, r.done = nil, nil, nil
    local n = fpool.n + 1
    fpool[n], fpool.n = r, n
end

--- -> 1 (fading in), -1 (fading out) or nil (no fade).
function F.dir(h)
    local r = fadeOf[h]
    return r and r.dir or nil
end

--- A running fade changes owner (the materialiser hands an old entity to a shell).
function F.owner(h, owner)
    local r = fadeOf[h]
    if r then r.m = owner end
end

function F.running() return fadeL.n end
function F.vehicles() return nVeh end

--- Core stops: `wipe(owner)` for every owned fade (the materialiser deletes it), DeleteEntity for the others.
function F.shutdown(wipe)
    stopped = true
    for i = fadeL.n, 1, -1 do
        local r = fadeL[i]
        if r.m then
            wipe(r.m)
        elseif DoesEntityExist(r.h) then
            DeleteEntity(r.h)
        end
    end
    fadeL, fadeOf, nVeh = { n = 0 }, {}, 0
end

C.assets, C.fades = A, F
