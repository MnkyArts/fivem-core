--[[
    core/server/remote.lua — remote player control (DESIGN §20)

    Server-side half of `Core.Native`, `Core.Anim`, `Core.Audio`, `Core.Attachments`, `Core.Waypoint`,
    `Core.Raycast` and `Core.Screenshot`: a plugin calls these with a `src` and core forwards the work
    to that player's client (client/remote.lua), either fire-and-forget through `Core.Net.emit` or as a
    `Core.Callback.awaitClient` round trip (§3.5, `Config.CallbackTimeoutMs`).

    Native invocation is allow-listed here AND on the client: only the names in
    `Config.Native.Allow` (§28) may run, no list at all denies everything, and the hard DENY set
    below is refused on both sides whatever the config says.

    Attachments live on the character document (`data.attachments`); each entry is ONE Core.Scene 'prop' node
    owned by core and attached to the player (§55.21.3) — the scene's clients put the object on that ped. The
    `attachments` state bag (§8) is no longer written.

    Natives (verified with fxref 2026-09-12, GetPlayerRoutingBucket 2026-09-27): GetPlayerPed (apiset server,
    `playerSrc`), GetEntityCoords (apiset server, ONE argument), GetPlayerRoutingBucket (apiset server,
    `playerSrc`), NetworkGetEntityFromNetworkId (apiset server), DoesEntityExist (client+server),
    GetResourceState (shared), GetGameTimer (apiset server). Server event: onPlayerBucketChange (player, bucket,
    oldBucket).
    `promise`, `Citizen.Await`, `SetTimeout`, `CreateThread`, `Wait` and `exports` are runtime helpers.
]]

local Native = {}
local Anim = {}
local Audio = {}
local Attachments = {}
local Waypoint = {}
local Raycast = {}
local Screenshot = {}

local Log = Core.Log
local Net = Core.Net
local Utils = Core.Utils
local Callback = Core.Callback

local MAX_SRC <const> = 4096
local MAX_NAME_LEN <const> = 64
local MAX_ARGS <const> = 16               -- arguments forwarded to one native call
local NATIVE_PATTERN <const> = '^%u[%w_]+$'
local AUDIO_MAX_TARGETS <const> = 20      -- DESIGN §20: playAt never fans out further than this
local AUDIO_DEFAULT_RANGE <const> = 20.0
local AUDIO_MAX_RANGE <const> = 200.0
local audioCandidates = {}                  -- reused by Audio.playAt: PlayerGrid.candidates fills it, its count is what counts
local MAX_ATTACHMENTS <const> = 12        -- props per player (each one is a scene node)
local DEFAULT_BONE <const> = 28422        -- PH_R_Hand, the usual prop bone
local RAYCAST_MAX_DISTANCE <const> = 100.0
local RAYCAST_SLACK <const> = 5.0         -- the client's hit may sit slightly past the probe end
local MAX_NET_ID <const> = 65535
local SCREENSHOT_RES <const> = 'screenshot-basic'
local SCREENSHOT_TIMEOUT_MS <const> = 15000

local allowCache = { list = false, set = nil }     -- memoised Config.Native.Allow lookup
local screenshotPending = {}                       -- [src] = true while one request is in flight

--- Integer server id inside the sane range, or nil.
local function toSrc(value)
    if math.type(value) ~= 'integer' then
        if type(value) ~= 'number' or value ~= value or value % 1 ~= 0 then return nil end
        value = math.floor(value)
    end
    if value < 1 or value > MAX_SRC then return nil end
    return value
end

--- Server id of a player with a loaded session, or nil (every §20 API needs one).
local function toLoaded(value)
    local src = toSrc(value)
    if not src or not Core.Player.isLoaded(src) then return nil end
    return src
end

--- vector3 from a vector3 or a { x, y, z } table, else nil. Every component has to be a
--- finite number: NaN/±inf survive tonumber() and would poison every distance check later.
local function toVector3(value)
    local x, y, z
    if type(value) == 'vector3' then
        x, y, z = value.x, value.y, value.z
    elseif type(value) == 'table' then
        x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
    else
        return nil
    end
    if not (Utils.isNumber(x) and Utils.isNumber(y) and Utils.isNumber(z)) then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

--------------------------------------------------------------------------------
-- Core.Native (DESIGN §20) — run a client native on one player
--------------------------------------------------------------------------------

--- Config.Native.Allow as a name -> true set. No list (or an empty one) means DENY everything:
--- a plugin may only run what the server operator listed in shared/config.lua (§28).
--- Memoised on the config table itself so a reload of core picks a new list up.
local function allowSet()
    local list = Config.Native and Config.Native.Allow
    if type(list) ~= 'table' then return nil end
    if allowCache.list == list then return allowCache.set end
    local set = {}
    for key, value in pairs(list) do
        if type(value) == 'string' then set[value] = true            -- array form { 'SetEntityHealth' }
        elseif value == true and type(key) == 'string' then set[key] = true end
    end
    allowCache.list, allowCache.set = list, set
    return set
end

--- Never runnable on a client, even when the operator put one of them in Config.Native.Allow:
--- these would let any resource run console commands, forge net events in the player's name, take
--- over the NUI, rewrite the KVP store or spawn loops.
--- client/remote.lua carries the same list and refuses them a second time.
local DENY <const> = {
    ExecuteCommand = true, TriggerServerEvent = true, TriggerClientEvent = true, TriggerEvent = true,
    TriggerLatentServerEvent = true, RegisterCommand = true, RegisterNetEvent = true,
    AddEventHandler = true, RemoveEventHandler = true, RegisterKeyMapping = true,
    LoadResourceFile = true, SendNuiMessage = true, SetNuiFocus = true, SetNuiFocusKeepInput = true,
    RegisterNuiCallback = true, SetResourceKvp = true, SetResourceKvpInt = true,
    SetResourceKvpFloat = true, SetResourceKvpNoSync = true, DeleteResourceKvp = true,
    DeleteResourceKvpNoSync = true, NetworkResurrectLocalPlayer = true, CreateThread = true,
    SetTimeout = true, Wait = true,
}

--- True when `name` is a well-formed native name the deny list and the config both permit.
--- A denied name is audited with the resource that asked for it (DESIGN §8 `audit` hook).
local function isAllowed(name, src)
    if type(name) ~= 'string' or #name > MAX_NAME_LEN or not name:match(NATIVE_PATTERN) then return false end
    if DENY[name] then
        Log.audit('native', src, 'resource %s tried to run denied native %s',
            tostring(Core.Registry.getCaller()), name)
        return false
    end
    local set = allowSet()
    return set ~= nil and set[name] == true
end

--- Argument list for one native call: a packed table (nils preserved), bounded length.
--- Returns nil when an argument cannot cross the wire safely.
local function packArgs(...)
    local args = table.pack(...)
    if args.n > MAX_ARGS then return nil end
    for i = 1, args.n do
        local t = type(args[i])
        if t == 'function' or t == 'thread' or t == 'userdata' then return nil end
        if t == 'table' then args[i] = Utils.jsonSafe(args[i]) end
    end
    return args
end

--- Fire-and-forget: the client calls `_G[name](...)` when the name is allowed there too.
--- @return boolean queued
function Native.invoke(src, name, ...)
    local target = toLoaded(src)
    if not target or not isAllowed(name, target) then
        Log.error('Native.invoke: refused %s for src %s', tostring(name), tostring(src))
        return false
    end
    local args = packArgs(...)
    if not args then
        Log.error('Native.invoke: %s has unsupported arguments', name)
        return false
    end
    Net.emit(target, 'core:client:native', name, args)
    return true
end

--- Same, but waits for the client's return values (nil on timeout, refusal or error).
function Native.invokeWithResult(src, name, ...)
    local target = toLoaded(src)
    if not target or not isAllowed(name, target) then
        Log.error('Native.invokeWithResult: refused %s for src %s', tostring(name), tostring(src))
        return nil
    end
    local args = packArgs(...)
    if not args then return nil end
    local result = Callback.awaitClient(target, 'core:native', name, args)
    if type(result) ~= 'table' then return nil end
    return table.unpack(result, 1, math.min(result.n or #result, MAX_ARGS))
end

--------------------------------------------------------------------------------
-- Core.Anim (DESIGN §20) — the client runs it through the Core.Anim lib (§3.10)
--------------------------------------------------------------------------------

local ANIM_NUMBERS <const> = { blendIn = true, blendOut = true, playbackRate = true }
local ANIM_INTEGERS <const> = { flags = true, duration = true, timeout = true }
local ANIM_BOOLS <const> = { lockX = true, lockY = true, lockZ = true }

--- Copy of the caller's options reduced to the fields Core.Anim.play understands.
local function animOpts(opts)
    if type(opts) ~= 'table' then return nil end
    local out = {}
    for key, value in pairs(opts) do
        if ANIM_NUMBERS[key] and type(value) == 'number' and value == value then
            out[key] = value + 0.0
        elseif ANIM_INTEGERS[key] and math.type(value) == 'integer' then
            out[key] = value
        elseif ANIM_BOOLS[key] and type(value) == 'boolean' then
            out[key] = value
        end
    end
    return out
end

--- Play `clip` from `dict` on the player's ped.
--- @return boolean queued
function Anim.play(src, dict, clip, opts)
    local target = toLoaded(src)
    if not target or not Utils.isString(dict, MAX_NAME_LEN) or not Utils.isString(clip, MAX_NAME_LEN) then
        Log.error('Anim.play: invalid arguments (%s, %s, %s)', tostring(src), tostring(dict), tostring(clip))
        return false
    end
    Net.emit(target, 'core:client:anim', 'play', dict, clip, animOpts(opts))
    return true
end

--- Stop whatever the player's ped is playing (ClearPedTasks on the client).
--- @return boolean queued
function Anim.stop(src)
    local target = toLoaded(src)
    if not target then return false end
    Net.emit(target, 'core:client:anim', 'stop')
    return true
end

--------------------------------------------------------------------------------
-- Core.Audio (DESIGN §20) — frontend sounds and world sounds
--------------------------------------------------------------------------------

--- Frontend (2D) sound for one player.
--- @return boolean queued
function Audio.playFrontend(src, name, set)
    local target = toLoaded(src)
    if not target or not Utils.isString(name, MAX_NAME_LEN) then
        Log.error('Audio.playFrontend: invalid arguments (%s, %s)', tostring(src), tostring(name))
        return false
    end
    if set ~= nil and not Utils.isString(set, MAX_NAME_LEN) then return false end
    Net.emit(target, 'core:client:audio', 'frontend', { name = name, set = set })
    return true
end

--- World sound at `coords`, sent to every loaded player within `range` (at most 20).
--- @return integer targets
function Audio.playAt(coords, name, set, range)
    local pos = toVector3(coords)
    if not pos or not Utils.isString(name, MAX_NAME_LEN) then
        Log.error('Audio.playAt: invalid arguments (%s)', tostring(name))
        return 0
    end
    if set ~= nil and not Utils.isString(set, MAX_NAME_LEN) then return 0 end
    local maxRange = tonumber(range) or AUDIO_DEFAULT_RANGE
    if maxRange ~= maxRange or maxRange <= 0.0 then maxRange = AUDIO_DEFAULT_RANGE end
    if maxRange > AUDIO_MAX_RANGE then maxRange = AUDIO_MAX_RANGE end

    local payload = { name = name, set = set, coords = Utils.vector3ToTable(pos), range = math.floor(maxRange) }
    -- The player grid (DESIGN §22.1) narrows the scan to the cells around `pos`: the old loop asked two
    -- natives of EVERY loaded player per sound, and AUDIO_MAX_TARGETS only ever capped the sends, not
    -- the scan. The exact distance test below still uses live coords. Everybody gets the same payload,
    -- so it is packed once (Net.emitMany).
    local count = Core.PlayerGrid.candidates(pos, maxRange, audioCandidates)
    local targets, sent = {}, 0
    for i = 1, count do
        if sent >= AUDIO_MAX_TARGETS then break end
        local target = audioCandidates[i]
        local ped = GetPlayerPed(target)
        if ped ~= 0 and #(GetEntityCoords(ped) - pos) <= maxRange then
            sent = sent + 1
            targets[sent] = target
        end
    end
    if sent > 0 then Net.emitMany(targets, 'core:client:audio', 'at', payload) end
    return sent
end

--------------------------------------------------------------------------------
-- Core.Attachments (DESIGN §20, §55.21.3) — props on the player's ped
--   The character document (data.attachments) is the truth. Every entry is ONE scene 'prop' node owned
--   by core: spawned at the ped in the player's routing bucket, then Scene.attach(id, { player = src },
--   { bone, offset, offrot, rotOrder = 1 }); every client near the player materialises the object on that ped
--   (client/scene_kinds.lua re-attaches it when the ped changes). Nodes are made on playerLoaded and on
--   add, changed in place on a re-add of the same id, removed (faded) on remove / clear / playerDropped.
--   A player whose nodes cannot be made yet (the scene store still loading, no ped on the server yet)
--   waits for ONE retry thread that exists only while somebody waits (1 s pace, 32 players per server tick).
--   A prop the scene refuses for CAPACITY ('limit': core's node cap, the global one — review RV4 F3) is kept
--   stored and retried by the same thread with a backoff (5 s, doubling to 60 s while nothing gets placed);
--   for 1 s after a 'limit' answer no new node is tried (it would be refused too) unless one of ours was
--   removed. The `attachments` state bag (§8) is no longer written; the key stays reserved
--   (server/player.lua CORE_STATE_KEYS).
--------------------------------------------------------------------------------

local ID_PATTERN <const> = '^[%w_%-:]+$'
local NAME_PATTERN <const> = '^[%w_%-]+$'   -- a scene model / bone name (Core.Schema 'model', R.valid.bone)
local BONE_MAX <const> = 65535              -- ped bone tags are 16-bit (R.valid.bone)
local OFFSET_MAX <const> = 1000.0           -- R.valid.offset: each component within ±1000 m
local RETRY_MS <const> = 1000               -- the retry thread's pace while somebody waits
local SYNC_SLICE <const> = 32               -- players one retry pass syncs per server tick
local SLICE_WAIT_MS <const> = 50            -- one server tick (sv 20 Hz) between two slices
local CAP_MIN_MS <const>, CAP_MAX_MS <const> = 5000, 60000   -- 'limit' (scene capacity): the retry backoff
local CAP_HOLD_MS <const> = 1000            -- after a 'limit' answer new nodes wait this long (or for a removal)
local CAP_LOG_MS <const> = 60000            -- one capacity warning per minute
local LIMIT <const> = 'limit'
local FADE <const> = { fade = true }        -- a removed prop fades out where it is seen (§55.11)
local TRANSIENT <const> = { unavailable = true, attach = true }   -- scene answers that mean "not yet"
local ROT_ORDER <const> = 1                 -- the attachment's rotation order (attachOpts)

local held = {}          -- [src] = { bucket, nodes = { [attachmentId] = { id = nodeId?, model, pose, failed? } } }
local waiting = {}       -- [src] = true: a sync that could not run yet (scene store loading, no ped): 1 s pace
local capped = {}        -- [src] = true: a prop the scene refused for capacity: retried with the backoff
local retrying = false   -- the retry thread runs
local capBackoff, capDue, capHeldUntil, capLogAt = CAP_MIN_MS, 0, 0, nil
local placedCount = 0    -- nodes made (the backoff's progress mark)

--- The stored list (a copy, always an array), clamped to MAX_ATTACHMENTS. A document that grew
--- past the cap (older data, a manual DB edit) is trimmed here, so no player ever gets more
--- nodes than that.
local function readList(src)
    local list = Core.Player.getData(src, 'attachments')
    if type(list) ~= 'table' then return {} end
    local out = {}
    for i = 1, #list do
        if type(list[i]) == 'table' then
            out[#out + 1] = list[i]
            if #out >= MAX_ATTACHMENTS then break end
        end
    end
    return out
end

--- Core.Scene with its store loaded; false while the store still loads; nil when this VM has no scene.
local function sceneApi()
    local Scene = rawget(Core, 'Scene')
    if type(Scene) ~= 'table' or type(rawget(Scene, 'spawn')) ~= 'function' then return nil end
    local R = rawget(Core, 'SceneRuntime')
    local store = type(R) == 'table' and R.store or nil
    if type(store) == 'table' and type(store.loaded) == 'function' and not store.loaded() then return false end
    return Scene
end

--- fn(...) as core, whoever called the Attachments API (the nodes are core's) -> fn's results | nil, 'error'.
local function asCore(fn, ...)
    local res = table.pack(Core.Registry.withCaller('core', fn, ...))
    if not res[1] then
        Log.error('Attachments: a scene call failed (%s)', tostring(res[2]))
        return nil, 'error'
    end
    return table.unpack(res, 2, res.n)
end

--- The scene `model` of an entry: a name as is, a hash as '0x' + 8 hex digits (the scene's model field
--- takes names only; the client's prop handler reads that form back as the hash).
local function sceneModel(model)
    if math.type(model) == 'integer' then return ('0x%08X'):format(model & 0xFFFFFFFF) end
    return model
end

--- An integer, or nil. An integral float counts: a stored entry may come back from a JSON round trip that way.
local function toInt(value)
    return type(value) == 'number' and math.tointeger(value) or nil
end

--- A bone tag 0..65535 or a bone name; anything else is the default hand bone.
local function toBone(value)
    local tag = toInt(value)
    if tag and tag >= 0 and tag <= BONE_MAX then return tag end
    if Utils.isString(value, MAX_NAME_LEN) and value:find(NAME_PATTERN) then return value end
    return DEFAULT_BONE
end

--- Validated, JSON-safe entry from a caller's definition (or a stored entry), or nil, err.
local function toEntry(def)
    if type(def) ~= 'table' then return nil, 'definition must be a table' end
    local model = toInt(def.model) or def.model
    if not ((Utils.isString(model, MAX_NAME_LEN) and model:find(NAME_PATTERN)) or math.type(model) == 'integer') then
        return nil, 'model must be a model name or a hash'
    end
    local id = def.id
    if id ~= nil then
        if not Utils.isString(id, MAX_NAME_LEN) or not id:find(ID_PATTERN) then return nil, 'invalid id' end
    else
        id = Utils.uuid()
    end
    local offset = toVector3(def.offset) or vector3(0.0, 0.0, 0.0)
    if math.abs(offset.x) > OFFSET_MAX or math.abs(offset.y) > OFFSET_MAX or math.abs(offset.z) > OFFSET_MAX then
        return nil, 'offset out of range'
    end
    local rotation = toVector3(def.rotation) or vector3(0.0, 0.0, 0.0)
    return {
        id = id, model = model, bone = toBone(def.bone),
        offset = Utils.vector3ToTable(offset), rotation = Utils.vector3ToTable(rotation),
    }
end

--- What a node is attached with: a different key means Scene.attach again.
local function poseKey(e)
    local o, r = e.offset, e.rotation
    return ('%s|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f'):format(tostring(e.bone), o.x, o.y, o.z, r.x, r.y, r.z)
end

local function clampTo(v, lo, hi)
    if v ~= v then return 0.0 end
    return v < lo and lo or (v > hi and hi or v)
end

--- The ped's position inside the scene's world box: the node's own pose until the attachment takes over.
local function pedPos(ped)
    local c = GetEntityCoords(ped)
    return { x = clampTo(c.x, -9999.0, 9999.0), y = clampTo(c.y, -9999.0, 9999.0), z = clampTo(c.z, -999.0, 2999.0) }
end

--- Scene.attach options of entry `e`. Rotation order 1: what core's old attachments applier used (the community
--- prop-table convention, dpemotes-style `..., true, true, false, true, 1, true`), so stored and copied offsets keep
--- looking the same on the scene's AttachEntityToEntity.
local function attachOpts(e)
    return { bone = e.bone, offset = e.offset, offrot = e.rotation, rotOrder = ROT_ORDER }
end

--- A new node for entry `e` of player `src`: spawned at the ped, then attached to the player — one synchronous
--- run, so the index coalesces both into one PUT (§55.5). Runs as core. -> node id | nil, err
local function spawnNode(Scene, src, e, bucket, pos)
    local id, err = Scene.spawn({ kind = 'prop', bucket = bucket, pos = pos,
        fields = { model = sceneModel(e.model), collision = false, frozen = false } })
    if not id then return nil, err end
    local ok, aerr = Scene.attach(id, { player = src }, attachOpts(e))
    if not ok then
        Scene.remove(id)
        return nil, aerr
    end
    return id
end

--- The existing node of `rec` brought in line with `e`: a model change is a Scene.set, a bone / offset /
--- rotation change a Scene.attach again. Runs as core. -> true | nil, err
local function updateNode(Scene, src, rec, e, pose)
    if rec.model ~= e.model then
        local ok, err = Scene.set(rec.id, { model = sceneModel(e.model) })
        if not ok then return nil, err end
        rec.model = e.model
    end
    if rec.pose ~= pose then
        local ok, err = Scene.attach(rec.id, { player = src }, attachOpts(e))
        if not ok then return nil, err end
        rec.pose = pose
    end
    return true
end

--- Removes (fades) one node, as core. A removed node frees scene capacity: new nodes are tried again.
local function removeNode(id)
    local Scene = rawget(Core, 'Scene')
    local remove = type(Scene) == 'table' and rawget(Scene, 'remove') or nil
    if id and type(remove) == 'function' and asCore(remove, id, FADE) then capHeldUntil = 0 end
end

--- Removes every node of src (oldest first) and forgets them; the stored list stays.
local function dropAll(src)
    local mine = held[src]
    if not mine then return end
    held[src] = nil
    local ids = {}
    for _, rec in pairs(mine.nodes) do ids[#ids + 1] = rec.id end
    table.sort(ids)
    for i = 1, #ids do removeNode(ids[i]) end
end

--- held[src] for the player's CURRENT routing bucket (a node's bucket never changes: nodes left in another
--- bucket are removed and made again in this one). -> holder, fresh (true = made now)
local function holder(src)
    local bucket = math.tointeger(GetPlayerRoutingBucket(src)) or 0
    local mine = held[src]
    if mine and mine.bucket == bucket then return mine, false end
    if mine then dropAll(src) end
    mine = { bucket = bucket, nodes = {} }
    held[src] = mine
    return mine, true
end

--- Makes the node of entry `e` exist and match it. -> true | nil, err (TRANSIENT codes: try again later)
local function place(Scene, src, mine, e, pos)
    local pose = poseKey(e)
    local rec = mine.nodes[e.id]
    if rec and rec.id then
        if rec.model == e.model and rec.pose == pose then return true end
        local ok, err = asCore(updateNode, Scene, src, rec, e, pose)
        if ok then return true end
        if err ~= 'missing' and err ~= 'attach' then return nil, err end   -- refused: the node keeps its state
        if err == 'attach' then removeNode(rec.id) end                     -- half updated: made again below
    end
    mine.nodes[e.id] = nil
    local id, err = asCore(spawnNode, Scene, src, e, mine.bucket, pos)
    if not id then
        if err == LIMIT then capHeldUntil = GetGameTimer() + CAP_HOLD_MS end
        return nil, err
    end
    placedCount = placedCount + 1
    mine.nodes[e.id] = { id = id, model = e.model, pose = pose }
    return true
end

--- Brings src's nodes in line with the stored list and the player's bucket. -> true = done, false = retry soon,
--- LIMIT = a prop waits for scene capacity (the backoff)
local function syncPlayer(src)
    local Scene = sceneApi()
    if Scene == nil then return true end                  -- no scene in this VM: nothing is ever made
    if not toLoaded(src) then
        dropAll(src)
        return true
    end
    if Scene == false then return false end               -- the scene store still loads
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end          -- the ped has not reached the server yet
    local list = readList(src)
    if #list == 0 and not held[src] then return true end  -- nothing to make, nothing made
    local mine = holder(src)
    local pos, wanted, again, full, bad = pedPos(ped), {}, false, false, 0
    for i = 1, #list do
        local e = list[i].id ~= nil and toEntry(list[i]) or nil
        if not e then
            bad = bad + 1
        elseif not wanted[e.id] then
            wanted[e.id] = true
            local rec, pose = mine.nodes[e.id], poseKey(e)
            local refused = rec and rec.failed and rec.model == e.model and rec.pose == pose   -- until it changes
            if not refused and not (rec and rec.id) and GetGameTimer() < capHeldUntil then
                full = true                                   -- a new node now would be refused too
            elseif not refused then
                local ok, err = place(Scene, src, mine, e, pos)
                if not ok and TRANSIENT[err] then
                    again = true
                elseif not ok and err == LIMIT then           -- capacity: stored, retried with the backoff
                    full = true
                elseif not ok then                            -- refused: no node until the entry changes
                    local old = mine.nodes[e.id]
                    if old then removeNode(old.id) end
                    mine.nodes[e.id] = { model = e.model, pose = pose, failed = true }
                    Log.warn('Attachments: the scene refused prop %s of player %d (%s)', e.id, src, tostring(err))
                end
            end
        end
    end
    for aid, rec in pairs(mine.nodes) do
        if not wanted[aid] then
            removeNode(rec.id)
            mine.nodes[aid] = nil
        end
    end
    if bad > 0 then Log.warn('Attachments: player %d has %d unusable stored attachment(s)', src, bad) end
    if again then return false end
    return full and LIMIT or true
end

local ensureRetry                                         -- forward: the retry thread

--- src waits for the 1 s retry (the scene store loading, no ped yet, a transient refusal).
local function queue(src)
    waiting[src] = true
    ensureRetry()
end

--- src waits for scene capacity: the first one of a shortage arms the backoff.
local function cap(src)
    local now = GetGameTimer()
    if next(capped) == nil and capDue <= now then capDue = now + capBackoff end
    capped[src] = true
    if not capLogAt or now - capLogAt >= CAP_LOG_MS then
        capLogAt = now
        Log.warn('Attachments: the scene has no room for a prop of player %d (limit); it is stored and retried '
            .. '(further capacity waits are not logged for a minute)', src)
    end
    ensureRetry()
end

--- One pass over the players of `set` (SYNC_SLICE per server tick), each filed by its sync's answer: done → out,
--- false → waiting, LIMIT → capped.
local function pass(set)
    local Scene = sceneApi()
    if Scene == nil then                                  -- no scene: nothing will ever be made
        for src in pairs(waiting) do waiting[src] = nil end
        for src in pairs(capped) do capped[src] = nil end
        return
    end
    if Scene == false then return end
    local list = {}
    for src in pairs(set) do list[#list + 1] = src end
    table.sort(list)
    for i = 1, #list do
        local src = list[i]
        if set[src] then
            set[src] = nil
            local ok, res = pcall(syncPlayer, src)
            if not ok then
                Log.error('Attachments: sync of player %d failed (%s)', src, tostring(res))
            elseif res == LIMIT then
                cap(src)
            elseif not res then
                waiting[src] = true
            end
        end
        if i % SYNC_SLICE == 0 and i < #list then Wait(SLICE_WAIT_MS) end
    end
end

--- ONE thread while somebody waits: the waiting players every second; the capped ones when the backoff is due
--- (then 5 s again after a round that placed something, else twice as long, <= 60 s).
-- fxlint-disable-next-line C003 -- assigns the forward-declared local `ensureRetry`
ensureRetry = function()
    if retrying then return end
    retrying = true
    CreateThread(function()
        repeat
            Wait(RETRY_MS)
            local ok, err = pcall(pass, waiting)
            if not ok then Log.error('Attachments: a retry pass failed (%s)', tostring(err)) end
            if next(capped) ~= nil and GetGameTimer() >= capDue then
                local mark = placedCount
                capHeldUntil = 0                          -- capacity may have freed meanwhile: try again
                ok, err = pcall(pass, capped)
                if not ok then Log.error('Attachments: a capacity retry failed (%s)', tostring(err)) end
                capBackoff = placedCount > mark and CAP_MIN_MS or math.min(capBackoff * 2, CAP_MAX_MS)
                capDue = GetGameTimer() + capBackoff
            end
        until next(waiting) == nil and next(capped) == nil
        retrying = false
    end)
end

--- Syncs src now when the scene and the ped allow it, else through the retry thread.
local function sync(src)
    local ok, res = pcall(syncPlayer, src)
    if not ok then
        Log.error('Attachments: sync of player %d failed (%s)', src, tostring(res))
    elseif res == LIMIT then
        cap(src)
    elseif not res then
        queue(src)
    end
end

--- The node of a new / changed entry: now when the scene and the ped allow it, else by the retry thread.
--- -> true | nil, err (the scene refused the prop: the caller stores nothing)
local function placeNow(src, e)
    local Scene = sceneApi()
    if Scene == nil then return true end                  -- no scene in this VM: stored only
    local ped = Scene and GetPlayerPed(src) or 0
    if not ped or ped == 0 then                           -- the store still loads / no ped yet: the entry is
        queue(src)                                        -- stored and the retry thread makes its node
        return true
    end
    local mine, fresh = holder(src)
    local rec = mine.nodes[e.id]
    if rec and rec.failed then mine.nodes[e.id] = nil end -- a re-add tries a refused entry again
    local ok, err = place(Scene, src, mine, e, pedPos(ped))
    if fresh then queue(src) end                          -- the other entries follow (no sync yet / new bucket)
    if ok then return true end
    if TRANSIENT[err] then
        queue(src)
        return true
    end
    if err == LIMIT then                                  -- capacity: stored, its node follows when there is room
        cap(src)
        return true
    end
    return nil, err
end

--- Attach a prop. An existing entry with the same id is replaced (its node changes in place).
--- @return string|nil id, string|nil err
function Attachments.add(src, def)
    local target = toLoaded(src)
    if not target then return nil, 'no session' end
    local entry, err = toEntry(def)
    if not entry then
        Log.error('Attachments.add: %s', tostring(err))
        return nil, err
    end
    local list = readList(target)
    local index
    for i = 1, #list do
        if list[i].id == entry.id then
            index = i
            break
        end
    end
    if not index and #list >= MAX_ATTACHMENTS then return nil, 'too many attachments' end
    local ok, perr = placeNow(target, entry)
    if not ok then
        Log.error('Attachments.add: the scene refused prop %s (%s)', entry.id, tostring(perr))
        return nil, ('scene refused the prop (%s)'):format(tostring(perr))
    end
    list[index or #list + 1] = entry
    Core.Player.setData(target, 'attachments', list)
    return entry.id
end

--- @return boolean removed
function Attachments.remove(src, id)
    local target = toLoaded(src)
    if not target or not Utils.isString(id, MAX_NAME_LEN) then return false end
    local list = readList(target)
    for i = 1, #list do
        if list[i].id == id then
            table.remove(list, i)
            Core.Player.setData(target, 'attachments', list)
            local mine = held[target]
            local rec = mine and mine.nodes[id]
            if rec then
                mine.nodes[id] = nil
                removeNode(rec.id)
            end
            return true
        end
    end
    return false
end

--- @return boolean ok
function Attachments.clear(src)
    local target = toLoaded(src)
    if not target then return false end
    Core.Player.setData(target, 'attachments', {})
    dropAll(target)
    return true
end

--- @return table list a copy of the stored entries
function Attachments.list(src)
    local target = toLoaded(src)
    if not target then return {} end
    return readList(target)
end

-- The stored props get their nodes when the character comes in (after a core restart as well: the hook
-- fires again for every client that asks core for its load).
Core.on('playerLoaded', function(src)
    local target = toLoaded(src)
    if target then sync(target) end
end)

-- server/player.lua emits this BEFORE the session goes — and before scene.lua's own playerDropped handler,
-- which would otherwise leave a dropped player's attachments standing at their last pose.
Core.on('playerDropped', function(src)
    local target = toSrc(src)
    if not target then return end
    waiting[target], capped[target] = nil, nil
    dropAll(target)
end)

-- The engine's own server event (a local one: clients cannot raise it) for every routing-bucket change —
-- Player.setBucket (§48, §50) or the raw native: the nodes follow the player into the new bucket.
AddEventHandler('onPlayerBucketChange', function(player)
    local target = toLoaded(tonumber(player))
    if target and held[target] then sync(target) end
end)

-- A core restart took every node with the old VM: once the scene store is ready, every loaded player is
-- synced (one whose playerLoaded hook already did it costs a compare per entry).
CreateThread(function()
    Wait(0)                                               -- every server file has loaded
    local Scene = sceneApi()
    while Scene == false do
        Wait(RETRY_MS)
        Scene = sceneApi()
    end
    if Scene == nil then return end
    local players = Core.Player.getPlayers()
    for i = 1, #players do waiting[players[i]] = true end
    local ok, err = pcall(pass, waiting)
    if not ok then Log.error('Attachments: the start sync failed (%s)', tostring(err)) end
    if next(waiting) ~= nil or next(capped) ~= nil then ensureRetry() end
end)

--------------------------------------------------------------------------------
-- Core.Waypoint / Core.Raycast (DESIGN §20) — the client owns both, we ask it
--------------------------------------------------------------------------------

--- Set the player's personal waypoint.
--- @return boolean queued
function Waypoint.set(src, coords)
    local target = toLoaded(src)
    local pos = toVector3(coords)
    if not target or not pos then
        Log.error('Waypoint.set: invalid arguments (%s)', tostring(src))
        return false
    end
    Net.emit(target, 'core:client:waypoint', 'set', pos)
    return true
end

--- @return boolean queued
function Waypoint.clear(src)
    local target = toLoaded(src)
    if not target then return false end
    Net.emit(target, 'core:client:waypoint', 'clear')
    return true
end

--- The player's current waypoint, or nil when there is none / the client did not answer.
--- @return vector3|nil
function Waypoint.get(src)
    local target = toLoaded(src)
    if not target then return nil end
    return toVector3(Callback.awaitClient(target, 'core:waypoint:get'))
end

--- Shape test out of the player's camera.
--- @return boolean hit, vector3|nil coords, integer entityNetId 0 when nothing networked was hit
function Raycast.fromPlayer(src, distance)
    local target = toLoaded(src)
    if not target then return false, nil, 0 end
    local dist = tonumber(distance) or 10.0
    if dist ~= dist or dist <= 0.0 then dist = 10.0 end
    if dist > RAYCAST_MAX_DISTANCE then dist = RAYCAST_MAX_DISTANCE end

    local result = Callback.awaitClient(target, 'core:raycast', dist + 0.0)
    if type(result) ~= 'table' or result.hit ~= true then return false, nil, 0 end

    -- The answer comes from the client, so none of it is fact yet: the coordinates have to be
    -- finite and plausibly in front of that player, and the net id has to resolve to an entity
    -- the server itself knows (§14.12) — otherwise the hit is dropped entirely.
    local coords = toVector3(result.coords)
    if not coords then return false, nil, 0 end
    local ped = GetPlayerPed(target)
    if ped == 0 or #(coords - GetEntityCoords(ped)) > dist + RAYCAST_SLACK then return false, nil, 0 end

    local netId = 0
    if math.type(result.netId) == 'integer' and result.netId > 0 and result.netId <= MAX_NET_ID then
        local entity = NetworkGetEntityFromNetworkId(result.netId)
        if entity ~= 0 and DoesEntityExist(entity) then netId = result.netId end
    end
    return true, coords, netId
end

--------------------------------------------------------------------------------
-- Core.Screenshot (DESIGN §20) — optional, needs the screenshot-basic resource
--------------------------------------------------------------------------------

local SCREENSHOT_ENCODINGS <const> = { jpg = true, png = true, webp = true }

--- Only the two options a plugin may steer. `fileName` is deliberately not forwarded:
--- it makes screenshot-basic write anywhere on the server's disk.
local function screenshotOptions(opts)
    local out = { encoding = 'jpg' }
    if type(opts) ~= 'table' then return out end
    if type(opts.encoding) == 'string' and SCREENSHOT_ENCODINGS[opts.encoding] then
        out.encoding = opts.encoding
    end
    local quality = tonumber(opts.quality)
    if quality and quality == quality then out.quality = Utils.clamp(quality, 0.1, 1.0) end
    return out
end

--- Ask the player's client for a screenshot. Returns the data URL screenshot-basic produced,
--- or nil plus a reason ('unavailable', 'busy', 'timeout', 'failed').
--- @return string|nil url, string|nil err
function Screenshot.take(src, opts)
    local target = toLoaded(src)
    if not target then return nil, 'unavailable' end
    if GetResourceState(SCREENSHOT_RES) ~= 'started' then return nil, 'unavailable' end
    if screenshotPending[target] then return nil, 'busy' end

    screenshotPending[target] = true
    local p = promise.new()
    local settled = false
    local function settle(url, err)
        if settled then return end
        settled = true
        screenshotPending[target] = nil
        p:resolve({ url = url, err = err })
    end

    -- screenshot-basic is optional, so the export is resolved inside a pcall: a missing export
    -- raises instead of returning nil, and the resource may still be starting up.
    local ok, err = pcall(function()
        exports[SCREENSHOT_RES]:requestClientScreenshot(target, screenshotOptions(opts), function(failed, data)
            if failed or type(data) ~= 'string' then return settle(nil, 'failed') end
            settle(data)
        end)
    end)
    if not ok then
        Log.warn('Screenshot.take: %s export failed (%s)', SCREENSHOT_RES, tostring(err))
        settle(nil, 'unavailable')
    end
    SetTimeout(SCREENSHOT_TIMEOUT_MS, function() settle(nil, 'timeout') end)

    local result = Citizen.Await(p)
    return result.url, result.err
end

AddEventHandler('playerDropped', function()
    local src = source
    screenshotPending[src] = nil
end)

Core.Native = Native
Core.Anim = Anim
Core.Audio = Audio
Core.Attachments = Attachments
Core.Waypoint = Waypoint
Core.Raycast = Raycast
Core.Screenshot = Screenshot

-- end of file
