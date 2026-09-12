--[[ core — client/doors.lua
     The read side of Core.Doors (DESIGN §16): GlobalState `door:<id>` entries -> the game's door
     system. The server owns every lock state; this file only applies it, shows the prompt and
     forwards a keypress.

     Threads: one sweep (1000 ms while a door is within 60 m, 2000 ms when none is within 100 m,
     250 ms while one is close enough to prompt) that re-applies doors which streamed in and keeps
     the text UI in sync. No per-frame loop, no polling of the key.

     Key: `core_door` is mapped to the same default key as `core_interact` (Config.Interactions.Key).
     client/interactions.lua owns that key whenever an interaction is active, so this handler only
     acts while `Core.Interactions.getActive()` is nil — the two are mutually exclusive.

     Text UI: a singleton shared with client/interactions.lua. Every show/hide carries the
     `doors` owner tag and this file never assumes it holds it — client/ui.lua arbitrates.

     Callbacks never run on the sweep thread: `core:doors:canUse` is asked in a one-shot and the
     sweep reads the cached answer (false until the server replies), like client/worldsync.lua.

     Natives: PlayerPedId, GetEntityCoords(entity, alive), GetHashKey, IsDoorRegisteredWithSystem,
     AddDoorToSystem, DoorSystemGetDoorState, DoorSystemSetDoorState, SetStateOfClosestDoorOfType,
     RemoveDoorFromSystem, IsNuiFocused, RegisterKeyMapping, GetClosestObjectOfType, IsEntityAnObject,
     GetEntityModel, GetEntityHeading, DoorSystemFindExistingDoor (all apiset client, verified with
     fxref 2026-09-12); GetGamePool is the Cfx runtime helper.
]]

local Doors = {}

local PREFIX <const> = 'door:'
local PREFIX_LEN <const> = #PREFIX
local APPLY_RANGE <const> = 60.0         -- doors further away are not in the door system yet
local FAR_RANGE <const> = 100.0
local PREFETCH_RANGE <const> = 10.0      -- ask the server whether the player may use this door
local SWEEP_NEAR_MS <const> = 1000
local SWEEP_FAR_MS <const> = 2000
local SWEEP_PROMPT_MS <const> = 250
local CAN_USE_TTL_MS <const> = 10000     -- an allowed answer stands this long
local DENY_RETRY_MS <const> = 2000       -- a denial (or a refused request) is re-asked sooner
local PRESS_COOLDOWN_MS <const> = 500
local DOOR_LOCKED <const> = 1            -- DOOR_SYSTEM_SET_DOOR_STATE lock states
local DOOR_UNLOCKED <const> = 0
local DOOR_CMD <const> = 'core_door'
local INTERACT_DISTANCE <const> = tonumber(Config.Doors.InteractDistance) or 2.0
local INTERACT_KEY <const> = Config.Interactions.Key
local OWNER <const> = 'doors'             -- text UI owner tag (client/ui.lua arbitrates)

local doors = {}          -- [id] = { id, locked, model, coords, hash, applied }
local checks = {}         -- [id] = { allowed = boolean, at = ms, pending = boolean }
local prompt = nil        -- id of the door the text UI is showing for
local promptLocked = nil  -- lock state the prompt was rendered with
local lastPress = 0
local stopping = false

--- Our own door-system identifier for a core door id. The map's own hash for that door is
--- unknown to us, so every client registers the door locally under this one (AddDoorToSystem
--- with `isLocal`), and the server's state bag is what keeps them all in sync.
local function doorHashOf(id)
    return GetHashKey('core_door_' .. id)
end

local function textUI(fnName, ...)
    local ui = Core.UI
    local tui = ui and ui.textUI
    local fn = tui and tui[fnName]
    if fn then return fn(...) end
    return nil
end

--- The text UI is a singleton shared with client/interactions.lua, so every call carries our
--- owner tag: client/ui.lua keeps the label of whoever owns it and turns a foreign hide into a
--- no-op. An owner-less build ignores the extra argument, which is why the caller still checks
--- whether an interaction has taken over before hiding.
local function textUIShow(text)
    textUI('show', INTERACT_KEY, text, { owner = OWNER })
end

local function textUIHide()
    textUI('hide', OWNER)
end

--- True when client/ui.lua says the text UI is ours; nil when it has no owner-aware isShown.
local function ownsTextUI()
    local ui = Core.UI
    local tui = ui and ui.textUI
    local isShown = tui and tui.isShown
    if not isShown then return nil end
    local ok, shown = pcall(isShown, OWNER)
    if not ok then return nil end
    return shown == true
end

--- client/interactions.lua owns the shared key and the text UI while it has an active target.
local function interactionActive()
    local interactions = Core.Interactions
    local getActive = interactions and interactions.getActive
    return getActive ~= nil and getActive() ~= nil
end

--- A registered door whose model hash does not match the object standing at its coords controls
--- nothing, silently. Once per session, as soon as the area is streamed in (within 40 m), look for
--- an object of that model within 2 m and say so in the console when there is none.
local function verifyObject(entry)
    if entry.checked ~= nil then return end
    local coords = entry.coords
    if #(GetEntityCoords(PlayerPedId(), false) - coords) > 40.0 then return end
    local object = GetClosestObjectOfType(coords.x, coords.y, coords.z, 2.0, entry.model, false, false, false)
    entry.checked = object ~= 0
    if object == 0 then
        Core.Log.warn('door %s: no object with model %d within 2 m of %.1f, %.1f, %.1f — the model is wrong; '
            .. 'look at the door and run /doorfind', tostring(entry.id), entry.model, coords.x, coords.y, coords.z)
    end
end

--- Push one door's lock state into the game. Doors the door system will not take (interior
--- doors that were never registered) fall back to SetStateOfClosestDoorOfType.
local function applyState(entry)
    local hash = entry.hash
    local coords = entry.coords
    if not IsDoorRegisteredWithSystem(hash) then
        AddDoorToSystem(hash, entry.model, coords.x, coords.y, coords.z, false, false, true, 0)
    end
    if IsDoorRegisteredWithSystem(hash) then
        local wanted = entry.locked and DOOR_LOCKED or DOOR_UNLOCKED
        if DoorSystemGetDoorState(hash) ~= wanted then
            DoorSystemSetDoorState(hash, wanted, false, true)
        end
    else
        SetStateOfClosestDoorOfType(entry.model, coords.x, coords.y, coords.z, entry.locked, 0.0, false)
    end
    entry.applied = entry.locked
    verifyObject(entry)
end

--- Hand a door back to the engine. Unlock it first: RemoveDoorFromSystem keeps the last lock
--- state, so an unregistered door would stay locked for the rest of the session.
local function releaseDoor(entry)
    local hash = entry.hash
    local coords = entry.coords
    if IsDoorRegisteredWithSystem(hash) then
        DoorSystemSetDoorState(hash, DOOR_UNLOCKED, false, true)
        RemoveDoorFromSystem(hash, false)
    elseif entry.applied then
        SetStateOfClosestDoorOfType(entry.model, coords.x, coords.y, coords.z, false, 0.0, false)
    end
    entry.applied = nil
end

--- Drop our prompt. `hideUI` is false when client/interactions.lua has taken the text UI over:
--- with an owner-less client/ui.lua, hiding then would wipe the interaction's own label.
local function clearPrompt(hideUI)
    if not prompt then return end
    prompt, promptLocked = nil, nil
    if not hideUI then return end
    if ownsTextUI() == false then return end    -- another owner holds the singleton now
    textUIHide()
end

local function forget(id)
    local entry = doors[id]
    if not entry then return end
    releaseDoor(entry)
    doors[id] = nil
    checks[id] = nil
    if prompt == id then clearPrompt(true) end
end

--- Read one `door:<id>` value into the local table. Returns the entry, or nil when the value
--- is not a well-formed door (the server writes it, but never index a payload unchecked).
local function upsert(id, value)
    local model = tonumber(value.model)
    local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
    if not model or not x or not y or not z or type(value.locked) ~= 'boolean' then return nil end
    model = math.floor(model)   -- the door natives take a Hash, never a float
    local entry = doors[id]
    if not entry then
        entry = { id = id, hash = doorHashOf(id) }
        doors[id] = entry
    end
    entry.locked, entry.model, entry.coords = value.locked, model, vector3(x, y, z)
    entry.applied = nil     -- forces the next apply, wherever it happens
    return entry
end

-- GlobalState carries one key per door. A nil key filter matches every key of the bag, so the
-- prefix test is the first thing the handler does (DESIGN §8: server writes, clients read).
AddStateBagChangeHandler(nil, 'global', function(_, key, value)
    if type(key) ~= 'string' or key:sub(1, PREFIX_LEN) ~= PREFIX then return end
    local id = key:sub(PREFIX_LEN + 1)
    if #id == 0 then return end

    if type(value) ~= 'table' then
        forget(id)      -- unregistered: the server writes `false`
        return
    end

    local entry = upsert(id, value)
    if not entry then return end

    local dist = #(GetEntityCoords(PlayerPedId(), false) - entry.coords)
    if dist <= APPLY_RANGE then applyState(entry) end
    if prompt == id and promptLocked ~= entry.locked then
        promptLocked = entry.locked
        textUIShow(entry.locked and 'Unlock' or 'Lock')
    end
end)

--- May the player use this door? The sweep must never wait on the network (a timed-out callback
--- would stall every door for seconds), so the question runs in a one-shot off the sweep thread
--- and this returns the last answer — pessimistic `false` until the first one arrives, so a
--- forbidden prompt never flashes. Mirrors client/worldsync.lua's canInteract.
---@param id string
---@return boolean allowed
local function canUse(id)
    local now = GetGameTimer()
    local state = checks[id]
    if not state then
        state = { allowed = false, at = 0, pending = false }
        checks[id] = state
    end

    local ask
    if state.pending then ask = false
    elseif state.at == 0 then ask = true                        -- never answered yet
    elseif state.allowed then ask = now - state.at >= CAN_USE_TTL_MS
    else ask = now - state.at >= DENY_RETRY_MS end

    if ask then
        state.pending = true
        SetTimeout(0, function()
            local answer = Core.Callback.await('core:doors:canUse', id)
            local current = checks[id]
            if not current then return end
            current.allowed = answer == true
            current.at = GetGameTimer()
            current.pending = false
        end)
    end

    return state.allowed
end

--- Prompt state for the closest door of this pass. Never blocks: canUse answers from cache.
local function updatePrompt(entry, dist)
    if interactionActive() then
        clearPrompt(false)
        return
    end
    if not entry or dist > PREFETCH_RANGE then
        clearPrompt(true)
        return
    end
    if not canUse(entry.id) or dist > INTERACT_DISTANCE then
        clearPrompt(true)
        return
    end
    -- re-show when another owner took the text UI away from us in the meantime
    if prompt == entry.id and promptLocked == entry.locked and ownsTextUI() ~= false then return end
    prompt, promptLocked = entry.id, entry.locked
    textUIShow(entry.locked and 'Unlock' or 'Lock')
end

--- One sweep pass: re-apply everything within APPLY_RANGE (a door that streamed in has lost its
--- state), drop the applied flag of everything that streamed out, then refresh the prompt.
--- Returns the sleep for the next pass.
local function sweep()
    local pedCoords = GetEntityCoords(PlayerPedId(), false)
    local nearest, nearestDist
    local anyNear, anyFar = false, false

    for _, entry in pairs(doors) do
        local dist = #(pedCoords - entry.coords)
        if dist <= APPLY_RANGE then
            anyNear = true
            if entry.applied ~= entry.locked then applyState(entry) end
            if not nearestDist or dist < nearestDist then nearest, nearestDist = entry, dist end
        else
            if dist <= FAR_RANGE then anyFar = true end
            entry.applied = nil
        end
    end

    updatePrompt(nearest, nearestDist or 0.0)

    if nearestDist and nearestDist <= PREFETCH_RANGE then return SWEEP_PROMPT_MS end
    if anyNear or anyFar then return SWEEP_NEAR_MS end
    return SWEEP_FAR_MS
end

CreateThread(function()
    while not stopping do
        local sleep = SWEEP_FAR_MS
        if next(doors) then
            sleep = sweep()
        elseif prompt then
            clearPrompt(true)
        end
        Wait(sleep)
    end
end)

--- The closest door within reach, by id.
local function nearestInReach()
    local pedCoords = GetEntityCoords(PlayerPedId(), false)
    local bestId, bestDist
    for id, entry in pairs(doors) do
        local dist = #(pedCoords - entry.coords)
        if dist <= INTERACT_DISTANCE and (not bestDist or dist < bestDist) then
            bestId, bestDist = id, dist
        end
    end
    return bestId
end

--- Ask the server to flip the closest door in reach. The server re-checks distance, cooldown
--- and permission (DESIGN §16), so a refusal here is only about not wasting an event.
---@return boolean sent
function Doors.tryToggleNearest()
    if stopping or IsNuiFocused() or interactionActive() then return false end
    local now = GetGameTimer()
    if now - lastPress < PRESS_COOLDOWN_MS then return false end
    local id = nearestInReach()
    if not id then return false end
    lastPress = now
    Core.Net.emit('core:server:doorToggle', id)
    return true
end

-- Same default key as `core_interact`; the interactionActive() guard keeps the two apart.
RegisterCommand(DOOR_CMD, function()
    Doors.tryToggleNearest()
end, false)

RegisterKeyMapping(DOOR_CMD, 'Lock/Unlock Door', 'keyboard', INTERACT_KEY)

--- The object the camera points at (6 m), else the nearest object within 3 m. One-shot: the
--- pool scan is fine for a command, never for a loop.
local function objectInFrontOrNearby()
    local raycast = Core.Raycast
    if raycast and raycast.getEntityInFront then
        local entity = raycast.getEntityInFront(6.0)
        if entity and entity ~= 0 and IsEntityAnObject(entity) then return entity, 'in front of you' end
    end
    local here = GetEntityCoords(PlayerPedId(), false)
    local best, bestDist = 0, 3.0
    for _, object in ipairs(GetGamePool('CObject')) do
        local dist = #(GetEntityCoords(object, false) - here)
        if dist < bestDist then
            best, bestDist = object, dist
        end
    end
    if best ~= 0 then return best, ('%.1f m away'):format(bestDist) end
    return 0, nil
end

--- /doorfind — answers "is this the door?": prints the model hash, coords and heading of the
--- object you look at (F8 console), whether the game's door system knows it, and which registered
--- core door sits there — with its expected model, so a mismatch is spelled out. The printed
--- `model = <hash>` line can be pasted into Core.Doors.register as it is.
RegisterCommand('doorfind', function()
    local object, where = objectInFrontOrNearby()
    if object == 0 then
        Core.UI.notify('No object in front of you or within 3 m — stand closer and look at the door', 'error')
        return
    end
    local model = GetEntityModel(object)
    local coords = GetEntityCoords(object, false)
    local heading = GetEntityHeading(object)
    local known, mapDoorHash = DoorSystemFindExistingDoor(coords.x, coords.y, coords.z, model, 0)
    print(('[core] doorfind: object %s — model = %d, coords = vector3(%.2f, %.2f, %.2f), heading %.1f, '
        .. 'door system: %s'):format(where, model, coords.x, coords.y, coords.z, heading,
        known and ('known as door hash %d'):format(mapDoorHash or 0) or 'not a registered door (yet)'))
    local matched = false
    for id, entry in pairs(doors) do
        local dist = #(entry.coords - coords)
        if dist <= 2.5 then
            matched = true
            if entry.model == model then
                print(('[core] doorfind: this IS core door "%s" (model matches, %.1f m from its coords)'):format(id, dist))
                Core.UI.notify(('This is door "%s" — model matches'):format(id), 'success')
            else
                print(('[core] doorfind: core door "%s" is registered %.1f m from here but expects model %d, '
                    .. 'the object here is %d — put `model = %d` into its Core.Doors.register call'):format(
                    id, dist, entry.model, model, model))
                Core.UI.notify(('Door "%s": model mismatch — see F8 console'):format(id), 'error')
            end
        end
    end
    if not matched then
        Core.UI.notify(('Object model %d at %.1f, %.1f, %.1f — no core door registered here (F8 has the snippet)')
            :format(model, coords.x, coords.y, coords.z), 'info')
        print(('[core] doorfind: register it with Core.Doors.register({ id = \'my_door\', model = %d, '
            .. 'coords = vector3(%.2f, %.2f, %.2f), locked = true, perms = { \'core.mod\' } })'):format(
            model, coords.x, coords.y, coords.z))
    end
end, false)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= Core.name then return end
    -- synchronous teardown (no Wait): unlock and unregister every door we put into the door
    -- system, release the text UI, stop the sweep, drop the tables
    stopping = true
    clearPrompt(true)
    for id, entry in pairs(doors) do
        releaseDoor(entry)
        doors[id] = nil
    end
    for id in pairs(checks) do checks[id] = nil end
end)

Core.Doors = Doors

-- end of file
