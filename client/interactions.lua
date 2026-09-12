--[[ core — client/interactions.lua
     Core.Interactions (DESIGN §6.7): point / entity / netId / models targets, one scan thread with a
     near/far cadence, exactly one active interaction, text UI prompt on enter/exit, the `core_interact`
     key mapping, an optional auto marker and owner tracking through Core.Registry.
     No per-frame loop: the scan runs at Config.Interactions.ScanIntervalMs (near) or
     FarScanIntervalMs (far, nothing within Config.Interactions.NearRange).
]]

local Interactions = {}

local entries = {}          -- id -> entry
local candidates = {}       -- reused per scan, never reallocated
local counter = 0
local active = nil          -- ctx of the active entry, or nil
local activeLabel = nil     -- label currently shown in the text UI
local stopping = false

local SCAN_NEAR <const> = Config.Interactions.ScanIntervalMs
local SCAN_FAR <const> = Config.Interactions.FarScanIntervalMs
local NEAR_RANGE <const> = Config.Interactions.NearRange
local MAX_MODELS <const> = Config.Interactions.MaxModels
local LAST_SEEN_TTL_MS <const> = 10000      -- how long a models entry remembers where its prop was
local TEXTUI_OWNER <const> = 'interactions'          -- Core.UI text-UI ownership (client/ui.lua)
local TEXTUI_OPTS <const> = { owner = TEXTUI_OWNER } -- hoisted: a show must not allocate
local INTERACT_CMD <const> = 'core_interact'

-- Funcrefs from other resources must never take the scan thread down with them.
local function safeCall(fn, ctx)
    if not Core.Utils.isCallable(fn) then return nil end
    local ok, res = pcall(fn, ctx)
    if not ok then
        Core.Log.error('interaction callback failed: %s', tostring(res))
        return nil
    end
    return res
end

local function textUI(fnName, ...)
    local ui = Core.UI
    local tui = ui and ui.textUI
    local fn = tui and tui[fnName]
    if fn then fn(...) end
end

-- Resolves an entry's current world target. Returns coords, entity (0 for points) or nil when the
-- target does not exist right now. `now` is GetGameTimer() of the current pass.
local function resolveTarget(entry, pedCoords, now)
    if entry.coords and not entry.models then
        return entry.coords, 0
    end

    if entry.entity then
        if DoesEntityExist(entry.entity) then
            return GetEntityCoords(entry.entity, false), entry.entity
        end
        return nil
    end

    if entry.netId then
        if NetworkDoesEntityExistWithNetworkId(entry.netId) then
            local ent = NetworkGetEntityFromNetworkId(entry.netId)
            if ent ~= 0 and DoesEntityExist(ent) then
                return GetEntityCoords(ent, false), ent
            end
        end
        return nil
    end

    if entry.models then
        -- A models entry with coords is gated on that distance first (cheap). Without coords the pool
        -- search costs one GetClosestObjectOfType per model (≤ Config.Interactions.MaxModels), so once
        -- a pass finds nothing the next search is held off until the far cadence has elapsed.
        if entry.coords and #(pedCoords - entry.coords) > NEAR_RANGE then return nil end
        if entry.nextModelScanAt and now < entry.nextModelScanAt then return nil end
        local bestCoords, bestEnt, bestDist
        for i = 1, #entry.models do
            local obj = GetClosestObjectOfType(pedCoords.x, pedCoords.y, pedCoords.z, entry.radius,
                entry.models[i], false, false, false)
            if obj ~= 0 and DoesEntityExist(obj) then
                local coords = GetEntityCoords(obj, false)
                local dist = #(pedCoords - coords)
                if not bestDist or dist < bestDist then
                    bestDist, bestCoords, bestEnt = dist, coords, obj
                end
            end
        end
        if bestCoords then
            entry.nextModelScanAt = nil
            entry.lastSeen, entry.lastSeenAt = bestCoords, now
            return bestCoords, bestEnt
        end

        entry.nextModelScanAt = now + SCAN_FAR
        if entry.lastSeenAt and now - entry.lastSeenAt > LAST_SEEN_TTL_MS then
            entry.lastSeen, entry.lastSeenAt = nil, nil
        end
    end

    return nil
end

local function makeCtx(entry, coords, entity, distance)
    return { id = entry.id, coords = coords, entity = entity, distance = distance, data = entry.data }
end

local function deactivate()
    local ctx = active
    active, activeLabel = nil, nil
    if not ctx then return end
    textUI('hide', TEXTUI_OWNER)
    local entry = entries[ctx.id]
    if entry then safeCall(entry.onExit, ctx) end
end

local function activate(entry, ctx)
    active = ctx
    activeLabel = entry.label
    safeCall(entry.onEnter, ctx)
    textUI('show', entry.key, entry.label, TEXTUI_OPTS)
end

-- One scan pass. Returns the sleep for the next pass.
local function scan()
    local ped = PlayerPedId()
    local pedCoords = GetEntityCoords(ped, false)
    local now = GetGameTimer()
    local near = false
    local count = 0

    for _, entry in pairs(entries) do
        if entry.enabled then
            local coords, entity = resolveTarget(entry, pedCoords, now)
            if coords then
                local dist = #(pedCoords - coords)
                if dist <= NEAR_RANGE then near = true end
                if dist <= entry.radius then
                    count = count + 1
                    local slot = candidates[count]
                    if not slot then
                        slot = {}
                        candidates[count] = slot
                    end
                    slot.entry, slot.coords, slot.entity, slot.dist, slot.skip = entry, coords, entity, dist, false
                end
            elseif entry.models and not entry.coords and entry.lastSeen then
                -- an ungated models entry keeps the near cadence only while the player is still around
                -- the last place one of its props actually was; otherwise it falls back to far
                if #(pedCoords - entry.lastSeen) <= NEAR_RANGE then near = true end
            end
        end
    end

    -- closest candidate whose canInteract does not say no
    local chosenEntry, chosenCtx
    while not chosenEntry do
        local bestIndex, bestDist
        for i = 1, count do
            local slot = candidates[i]
            if not slot.skip and (not bestDist or slot.dist < bestDist) then
                bestIndex, bestDist = i, slot.dist
            end
        end
        if not bestIndex then break end
        local slot = candidates[bestIndex]
        local ctx = makeCtx(slot.entry, slot.coords, slot.entity, slot.dist)
        if slot.entry.canInteract and safeCall(slot.entry.canInteract, ctx) == false then
            slot.skip = true
        else
            chosenEntry, chosenCtx = slot.entry, ctx
        end
    end

    for i = 1, count do
        local slot = candidates[i]
        slot.entry, slot.coords = nil, nil
    end

    if not chosenEntry then
        deactivate()
    elseif not active or active.id ~= chosenCtx.id then
        deactivate()
        activate(chosenEntry, chosenCtx)
    else
        active.coords, active.entity, active.distance = chosenCtx.coords, chosenCtx.entity, chosenCtx.distance
        if activeLabel ~= chosenEntry.label then
            activeLabel = chosenEntry.label
            textUI('show', chosenEntry.key, chosenEntry.label, TEXTUI_OPTS)
        end
    end

    return near and SCAN_NEAR or SCAN_FAR
end

CreateThread(function()
    while not stopping do
        local sleep = SCAN_FAR
        if next(entries) then
            sleep = scan()
        elseif active then
            deactivate()
        end
        Wait(sleep)
    end
end)

local function addMarker(entry, opts)
    local coords = opts.coords or entry.coords
    if not coords then
        Core.Log.warn('interaction %s: marker ignored, no coords on the interaction', entry.id)
        return nil
    end
    local mopts = {}
    for k, v in pairs(opts) do mopts[k] = v end
    mopts.coords = coords
    return Core.Markers.add(mopts)
end

--- Register an interaction. opts: coords|entity|netId|models, radius, label, key, marker, data,
--- onInteract/onEnter/onExit/canInteract, enabled, cooldown (DESIGN §6.7).
---@param opts table
---@return string|nil id
function Interactions.add(opts)
    if type(opts) ~= 'table' then return nil end

    local models
    if type(opts.models) == 'table' then
        models = {}
        for i = 1, #opts.models do
            if i > MAX_MODELS then break end
            models[i] = Core.Utils.hash(opts.models[i])
        end
        if #models == 0 then models = nil end
    end

    local coords = Core.Utils.isVector3(opts.coords) and opts.coords or nil
    local entity = type(opts.entity) == 'number' and opts.entity or nil
    local netId = type(opts.netId) == 'number' and opts.netId or nil
    if not coords and not entity and not netId and not models then
        Core.Log.error('Interactions.add: needs one of coords, entity, netId or models')
        return nil
    end

    local owner = Core.Registry.getCaller()
    counter = counter + 1
    local id = ('%s:i%d'):format(owner, counter)

    local entry = {
        id = id,
        owner = owner,
        coords = coords,
        entity = entity,
        netId = netId,
        models = models,
        radius = tonumber(opts.radius) or 2.0,
        label = Core.Utils.sanitize(opts.label or 'Interact', 64),
        key = Core.Utils.sanitize(opts.key or Config.Interactions.Key, 16),
        onInteract = opts.onInteract,
        onEnter = opts.onEnter,
        onExit = opts.onExit,
        canInteract = opts.canInteract,
        enabled = opts.enabled ~= false,
        cooldown = tonumber(opts.cooldown) or 500,
        data = opts.data,
        lastUse = nil,      -- nil = never used; set to GetGameTimer() on each accepted press
    }

    if type(opts.marker) == 'table' then
        entry.markerId = addMarker(entry, opts.marker)
    end

    entries[id] = entry
    Core.Registry.track('interaction', id, owner)
    return id
end

--- Remove one interaction (and the marker it created).
---@param id string
---@return boolean removed
function Interactions.remove(id)
    local entry = entries[id]
    if not entry then return false end
    entries[id] = nil
    if active and active.id == id then
        active, activeLabel = nil, nil
        textUI('hide', TEXTUI_OWNER)
        safeCall(entry.onExit, makeCtx(entry, entry.coords, 0, 0.0))
    end
    if entry.markerId then Core.Markers.remove(entry.markerId) end
    Core.Registry.untrack('interaction', id)
    return true
end

--- Remove every interaction of the calling resource.
function Interactions.removeAll()
    local owner = Core.Registry.getCaller()
    for id, entry in pairs(entries) do
        if entry.owner == owner then Interactions.remove(id) end
    end
end

--- Enable/disable an interaction without removing it; disabling clears it if it is active.
---@param id string
---@param enabled boolean
---@return boolean ok
function Interactions.setEnabled(id, enabled)
    local entry = entries[id]
    if not entry then return false end
    entry.enabled = enabled ~= false
    if not entry.enabled and active and active.id == id then deactivate() end
    return true
end

--- Change the prompt label (applied on the next scan while active).
---@param id string
---@param text string
---@return boolean ok
function Interactions.setLabel(id, text)
    local entry = entries[id]
    if not entry then return false end
    entry.label = Core.Utils.sanitize(text, 64)
    return true
end

--- The id of the active interaction, or nil. Allocation-free, unlike getActive.
---@return string|nil id
function Interactions.getActiveId()
    return active and active.id or nil
end

--- The active interaction context, or nil.
---@return table|nil ctx { id, coords, entity, distance, data }
function Interactions.getActive()
    local ctx = active
    if not ctx then return nil end
    return { id = ctx.id, coords = ctx.coords, entity = ctx.entity, distance = ctx.distance, data = ctx.data }
end

-- The interact key: one command + one mapping, no polling. Rebindable in the pause menu.
RegisterCommand(INTERACT_CMD, function()
    local ctx = active
    if not ctx or IsNuiFocused() then return end
    local entry = entries[ctx.id]
    if not entry or not entry.enabled or not entry.onInteract then return end

    local now = GetGameTimer()
    if entry.lastUse and now - entry.lastUse < entry.cooldown then return end

    -- `active` is up to ScanIntervalMs old: re-resolve the target and refuse if the player walked out
    -- of range in the meantime, so the callback always gets a fresh ctx.
    local pedCoords = GetEntityCoords(PlayerPedId(), false)
    local coords, entity = resolveTarget(entry, pedCoords, now)
    if not coords then return end
    local distance = #(pedCoords - coords)
    if distance > entry.radius then return end

    entry.lastUse = now
    active.coords, active.entity, active.distance = coords, entity, distance
    safeCall(entry.onInteract, makeCtx(entry, coords, entity, distance))
end, false)

RegisterKeyMapping(INTERACT_CMD, 'Interact', 'keyboard', Config.Interactions.Key)

-- Owner cleanup: every interaction a plugin registered dies with that plugin (DESIGN §2.3).
Core.Registry.onOwnerStop('interaction', function(id)
    Interactions.remove(id)
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= Core.name then return end
    stopping = true
    active, activeLabel = nil, nil
    for id in pairs(entries) do entries[id] = nil end
end)

Core.Interactions = Interactions

-- end of file
