--[[
    core/client/worldsync.lua -- the client half of the server-driven world
    controllers (DESIGN §15).

    Server-defined markers, labels, blips and interactions arrive as plain option
    tables and are registered into the normal client modules (§6.4-§6.7) under the
    owner 'core:server'. That owner is not a resource name, so the registry sweep
    in client/api.lua can never match it and a plugin's `removeAll()` (which only
    walks its own owner's ids) never touches a server entry. The module-minted
    ids therefore all start with 'core:server:'; the server's own ids ('g:<n>')
    are the keys of the map below.

    Interactions keep no plugin funcrefs here: `onInteract`/`onEnter`/`onExit`
    only report to the server, which holds the real handlers and re-checks
    distance, cooldown and `canInteract` before running them.

    Natives: none -- this file only talks to the other core modules. GetGameTimer
    (shared) is used for the `canInteract` retry cadence.
]]

local Registry <const> = Core.Registry

local OWNER <const> = 'core:server'
local DENY_RETRY_MS <const> = 5000   -- a denied canInteract is re-asked at most this often
local MAX_BATCH <const> = 512        -- entries or ids the server puts in one message

--- kind -> the client namespace that owns it.
local MODULE <const> = {
    marker = 'Markers', label = 'TextLabels', blip = 'Blips', interaction = 'Interactions',
}

---@type table<string, table>  server id -> { kind, clientId, wire }
local entries = {}
---@type table<string, table>  server id -> { allowed = boolean, at = ms, pending = boolean }
local checks = {}
-- One question in flight at a time. Several entries can be in range at once and
-- the scan asks about each of them in the same pass; the server answers one
-- question per 250 ms and a burst would come back as a denial for the rest.
local asking = false

--- Call a client module as the server owner, then restore the previous caller.
--- pcall: a module error must not kill the net handler.
---@param fn function
---@return any
local function asServer(fn, ...)
    local previous = Registry.getCaller()
    Registry.setCaller(OWNER)
    local result = table.pack(pcall(fn, ...))
    Registry.setCaller(previous)
    if not result[1] then
        Core.Log.error('worldsync: %s', tostring(result[2]))
        return nil
    end
    return table.unpack(result, 2, result.n)
end

--- The server sends vectors as { x, y, z } tables (json/msgpack safe). Turn the
--- coordinate keys back into vector3: `Interactions.add` insists on a real one.
---@param kind string
---@param wire table
---@return table
local function prepare(kind, wire)
    local opts = {}
    for k, v in pairs(wire) do opts[k] = v end

    local coords = type(opts.coords) == 'table' and Core.Utils.tableToVector3(opts.coords) or opts.coords
    if coords ~= nil then opts.coords = coords end

    if kind == 'blip' and type(opts.radius) == 'table' and type(opts.radius.coords) == 'table' then
        local radius = {}
        for k, v in pairs(opts.radius) do radius[k] = v end
        radius.coords = Core.Utils.tableToVector3(radius.coords)
        opts.radius = radius
    end

    if kind == 'interaction' and type(opts.marker) == 'table' then
        local marker = {}
        for k, v in pairs(opts.marker) do marker[k] = v end
        if type(marker.coords) == 'table' then marker.coords = Core.Utils.tableToVector3(marker.coords) end
        opts.marker = marker
    end

    return opts
end

--- Cached answer of the server's `canInteract` for one entry (§15: asked once on
--- enter). The interaction scan must never wait for the network, so the callback
--- runs in a one-shot off the scan thread and this returns the last answer --
--- pessimistic (`false`) until the first one arrives, so a forbidden prompt never
--- flashes. An allowed answer stands until the player leaves (onExit clears it);
--- a denial is re-asked at most every DENY_RETRY_MS while the player stays.
---@param id string
---@return boolean
local function canInteract(id)
    local now = GetGameTimer()
    local state = checks[id]
    if not state then
        state = { allowed = false, at = 0, pending = false }
        checks[id] = state
    end

    local ask
    if state.pending or asking then ask = false
    elseif state.at == 0 then ask = true                    -- never answered yet
    elseif state.allowed then ask = false                   -- stands until onExit clears it
    else ask = now - state.at >= DENY_RETRY_MS end

    if ask then
        state.pending, asking = true, true
        SetTimeout(0, function()
            local answer = Core.Callback.await('core:world:canInteract', id)
            asking = false
            -- The entry may have been removed and re-added while we waited: the
            -- state table identifies the question, the id alone does not.
            if checks[id] ~= state then return end
            state.allowed = answer == true
            state.at = GetGameTimer()
            state.pending = false
        end)
    end

    return state.allowed
end

--- Interaction options for the client module: the server's table without the
--- flag, plus the three reporters. Never a plugin funcref (they live server-side).
--- Enter and exit are always reported, whether or not the plugin has a handler:
--- the server pairs them into a presence record, and an unreported exit would
--- make the next entry look like the player never left.
---@param id string
---@param opts table
---@return table
local function withReporters(id, opts)
    local hasCheck = opts.hasCheck
    opts.hasCheck = nil

    opts.onInteract = function()
        Core.Net.emit('core:server:worldInteract', id)
    end

    opts.onEnter = function()
        Core.Net.emit('core:server:worldEnter', id)
    end

    -- Leaving also drops the cached permission, so the next approach asks again.
    opts.onExit = function()
        checks[id] = nil
        Core.Net.emit('core:server:worldExit', id)
    end

    if hasCheck then
        opts.canInteract = function() return canInteract(id) end
    end

    return opts
end

--------------------------------------------------------------------------------
-- The server's entries, mapped onto the client modules
--------------------------------------------------------------------------------

--- Drop one server entry and whatever the client module made of it.
---@param id string
---@return boolean
local function removeEntry(id)
    local entry = entries[id]
    if not entry then return false end

    entries[id] = nil
    checks[id] = nil
    local module = Core[MODULE[entry.kind]]
    if module then asServer(module.remove, entry.clientId) end
    return true
end

--- Register one server entry in its client module. A repeated id replaces the
--- previous registration (snapshot after a reconnect, plugin re-add).
---@param kind string
---@param id string
---@param wire table
local function addEntry(kind, id, wire)
    if type(kind) ~= 'string' or not MODULE[kind] then return end
    if type(id) ~= 'string' or type(wire) ~= 'table' then return end
    if entries[id] then removeEntry(id) end

    local module = Core[MODULE[kind]]
    if type(module) ~= 'table' then return end

    local opts = prepare(kind, wire)
    if kind == 'interaction' then opts = withReporters(id, opts) end

    local clientId = asServer(module.add, opts)
    if type(clientId) ~= 'string' then
        Core.Log.warn('worldsync: the %s module rejected server entry %s', kind, id)
        return
    end
    entries[id] = { kind = kind, clientId = clientId, wire = wire }
end

-- Interaction options with a dedicated setter; anything else needs a rebuild.
local SETTERS <const> = { label = true, enabled = true }

--- Apply a partial option update coming from the server.
---@param kind string
---@param id string
---@param partial table
local function updateEntry(kind, id, partial)
    local entry = entries[id]
    if not entry or entry.kind ~= kind or type(partial) ~= 'table' then return end

    local module = Core[MODULE[kind]]
    if type(module) ~= 'table' then return end
    for k, v in pairs(partial) do entry.wire[k] = v end

    if kind ~= 'interaction' then
        asServer(module.update, entry.clientId, prepare(kind, partial))
        return
    end

    local simple = true
    for k in pairs(partial) do
        if not SETTERS[k] then
            simple = false
            break
        end
    end

    if simple then
        if partial.label ~= nil then asServer(module.setLabel, entry.clientId, partial.label) end
        if partial.enabled ~= nil then asServer(module.setEnabled, entry.clientId, partial.enabled == true) end
        return
    end

    -- §6.7 has no generic Interactions.update: rebuild from the merged options.
    local merged = entry.wire
    removeEntry(id)
    addEntry(kind, id, merged)
end

--- Forget every server entry (a fresh snapshot replaces the lot).
local function clearAll()
    local ids = {}
    for id in pairs(entries) do ids[#ids + 1] = id end
    for i = 1, #ids do removeEntry(ids[i]) end
end

--------------------------------------------------------------------------------
-- Server -> client (§15). Schemas catch bugs, not cheaters: the server is trusted.
--------------------------------------------------------------------------------

--- Register a batch of { kind, id, opts } entries (adds and snapshots share it).
---@param list table[]
local function applyEntries(list)
    for i = 1, #list do
        local item = list[i]
        if type(item) == 'table' then addEntry(item.kind, item.id, item.opts) end
    end
end

-- Adds arrive as arrays: the server coalesces everything a plugin registers in
-- one tick into as few messages as the engine's event budget likes.
Core.Net.on('core:client:worldAdd', { { 'array', of = 'table', max = MAX_BATCH } }, applyEntries)

Core.Net.on('core:client:worldUpdate', { 'string', 'id', 'table' }, updateEntry)

-- Removals arrive as an array of ids (a stopping plugin removes all of its own
-- entries at once).
Core.Net.on('core:client:worldRemove', { { 'array', of = 'id', max = MAX_BATCH } }, function(ids)
    for i = 1, #ids do
        removeEntry(ids[i])
    end
end)

-- Sent on playerLoaded, split into messages of at most MAX_BATCH entries and
-- 32 KB; `first` marks the opening message, which replaces everything the server
-- put here before.
Core.Net.on('core:client:worldSnapshot', { { 'array', of = 'table', max = MAX_BATCH }, 'boolean?' },
    function(list, first)
        if first then clearAll() end
        applyEntries(list)
    end)

-- end of file
