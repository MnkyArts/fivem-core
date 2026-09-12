--[[
    core/server/worldsync.lua -- server-driven world controllers (DESIGN §15).

    A plugin defines markers, blips, text labels and interactions ON THE SERVER,
    for everyone (`addGlobal`) or for one player (`addFor`); the handlers stay in
    the plugin's server VM. This file keeps the registry, pushes add/update/remove
    to the clients (never from a loop -- only when a plugin acts), sends the
    snapshot on `playerLoaded`, and owns the three client -> server events plus the
    `core:world:canInteract` callback.

    Option shapes are the client ones: §6.4 markers, §6.5 text labels, §6.6 blips
    (coords/radius only, no entity), §6.7 interactions (no entity/models) with
    server-side `onInteract(src, ctx)`, `onEnter`, `onExit`, `canInteract(src)`.

    Ownership: every entry is tracked as kind 'world' in `Core.Registry`, so a
    plugin that stops loses its world entries automatically (§2.3).

    Natives: GetGameTimer (shared), GetPlayerPed(playerSrc) and
    GetEntityCoords(entity) -- both the SERVER forms, one argument each.
]]

local Registry <const> = Core.Registry

local SNAPSHOT_CHUNK_BYTES <const> = 32 * 1024   -- §15: one snapshot message stays under 32 KB
local WIRE_MAX_DEPTH <const> = 6                 -- plugin tables are copied this deep, no further
local ENTRY_OVERHEAD <const> = 2                 -- the separator each entry adds to the enclosing array
local DEFAULT_RADIUS <const> = 2.0
local DEFAULT_COOLDOWN_MS <const> = 500
local INTERACT_SLACK <const> = 1.0                -- §15: interact distance = radius + 1.0
local PRESENCE_SLACK <const> = 2.0                -- §15: enter/exit distance = radius + 2.0
local PRESENCE_COOLDOWN_MS <const> = 250          -- per (src, id) between enter/exit callback pairs
local FLOOD_COOLDOWN_MS <const> = 100             -- Net.on floor; the per-entry cooldown is checked below
local CHECK_SLACK <const> = 5.0                   -- canInteract is asked on approach, so a wider ring
local CHECK_COOLDOWN_MS <const> = 250             -- per src between canInteract questions
local MAX_BATCH <const> = 512                     -- entries or ids in one client message
local GLOBAL_TARGET <const> = -1                  -- queue key for "everyone"

-- The plugin handlers an entry may carry; `updateGlobal` can replace any of them.
local HANDLER_KEYS <const> = { 'onInteract', 'onEnter', 'onExit', 'canInteract' }

-- Keys a kind never accepts from the plugin (client-only concepts, §15).
local BLOCKED <const> = {
    marker = {},
    label = {},
    blip = { entity = true, netId = true },
    interaction = { entity = true, netId = true, models = true },
}

---@type table<string, table<string, table>>  kind -> id -> entry
local registry = { marker = {}, label = {}, blip = {}, interaction = {} }
---@type table<string, table>  id -> entry (ids are unique across kinds)
local index = {}
---@type table<integer, table<string, integer>>  src -> id -> last accepted interact (ms)
local lastUse = {}
---@type table<integer, table<string, boolean>>  src -> id -> inside (true = callbacks are live)
local inside = {}
---@type table<integer, table<string, integer>>  src -> id -> last presence callback (ms)
local lastPresence = {}
---@type table<integer, integer>  src -> last canInteract question (ms)
local lastCheck = {}
local counter = 0

--- Ids are 'g:<n>' (DESIGN §15), global and per-player alike.
---@return string
local function nextId()
    counter = counter + 1
    return 'g:' .. counter
end

--- vector3 from a vector3 or a { x, y, z } / { [1], [2], [3] } table.
---@param value any
---@return vector3|nil
local function toVector3(value)
    if type(value) == 'vector3' then return value end
    if type(value) ~= 'table' then return nil end
    local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

--- Copy of a plugin value that is safe to put on the wire: functions, coroutines
--- and userdata are dropped, vectors become { x, y, z } tables (the client turns
--- them back into vector3), nesting is capped -- which also breaks any cycle.
---@param value any
---@param depth integer
---@return any
local function wireValue(value, depth)
    local t = type(value)
    if t == 'string' or t == 'number' or t == 'boolean' then return value end
    if t == 'vector3' then return { x = value.x, y = value.y, z = value.z } end
    if t == 'vector2' then return { x = value.x, y = value.y } end
    if t == 'vector4' then return { x = value.x, y = value.y, z = value.z, w = value.w } end
    if t ~= 'table' or depth >= WIRE_MAX_DEPTH then return nil end
    local out = {}
    for k, v in pairs(value) do
        local kt = type(k)
        if kt == 'string' or kt == 'number' then out[k] = wireValue(v, depth + 1) end
    end
    return out
end

--- Wire options for one kind: the plugin's table minus the blocked keys, minus
--- every function. Interactions gain `hasCheck`, so the client only asks the
--- `canInteract` callback for entries that actually have one.
---@param kind string
---@param opts table
---@return table
local function toWire(kind, opts)
    local blocked = BLOCKED[kind]
    local out = {}
    for k, v in pairs(opts) do
        if type(k) == 'string' and not blocked[k] then
            local copy = wireValue(v, 1)
            if copy ~= nil then out[k] = copy end
        end
    end
    if kind == 'interaction' then
        -- A flag, never the funcref: the plugin's `canInteract` stays server-side.
        -- Enter/exit carry no flag on purpose -- the client reports both for every
        -- interaction, because the server's presence record (which decides whether
        -- an exit is honoured) is what a later re-entry depends on.
        out.hasCheck = Core.Utils.isCallable(opts.canInteract) or nil
    end
    return out
end

--- Push one world event to the entry's audience: everyone, or its one player.
---@param entry table
---@param event string
local function send(entry, event, ...)
    if entry.target then
        Core.Net.emit(entry.target, event, ...)
    else
        Core.Net.broadcast(event, ...)
    end
end

--- Rough encoded size of one wire entry; the wire copy is always encodable.
---@param wire table
---@return integer
local function wireBytes(wire)
    local ok, encoded = pcall(json.encode, wire)
    if ok and type(encoded) == 'string' then return #encoded end
    return 512
end

--- Send to everyone (-1) or to one player.
---@param target integer
---@param event string
local function emitTo(target, event, ...)
    if target == GLOBAL_TARGET then
        Core.Net.broadcast(event, ...)
    else
        Core.Net.emit(target, event, ...)
    end
end

--- Send `list` as one or more array messages of at most MAX_BATCH entries and
--- SNAPSHOT_CHUNK_BYTES bytes. With `withFirst`, every message also carries the
--- snapshot's `first` flag and at least one message is always sent.
---@param target integer
---@param event string
---@param list table[]
---@param withFirst boolean
local function sendBatched(target, event, list, withFirst)
    local chunk, bytes, first = {}, ENTRY_OVERHEAD, true

    local function flushChunk()
        if withFirst then
            emitTo(target, event, chunk, first)
        else
            emitTo(target, event, chunk)
        end
        first, chunk, bytes = false, {}, ENTRY_OVERHEAD
    end

    for i = 1, #list do
        local wire = list[i]
        local size = wireBytes(wire) + ENTRY_OVERHEAD
        if #chunk > 0 and (#chunk >= MAX_BATCH or bytes + size > SNAPSHOT_CHUNK_BYTES) then flushChunk() end
        chunk[#chunk + 1] = wire
        bytes = bytes + size
    end

    if #chunk > 0 or (withFirst and first) then flushChunk() end
end

--------------------------------------------------------------------------------
-- Outgoing batch. A plugin that registers 300 points at boot would otherwise
-- fan out 300 broadcasts in one tick -- well inside the engine's 50 events/s
-- (burst 200) budget per client, which drops the client outright. Adds and
-- removals are therefore collected per target and flushed once on the next
-- tick, as arrays. Updates stay single: they arrive one at a time by nature.
--------------------------------------------------------------------------------

---@type table<integer, table[]>  target -> queued wire entries
local pendingAdd = {}
---@type table<integer, string[]>  target -> queued ids
local pendingRemove = {}
local flushQueued = false

--- Ship everything queued during this tick. Adds go out before removals; an id
--- removed in the same tick it was added never leaves the server at all, so the
--- two arrays can never contradict each other.
local function flush()
    flushQueued = false
    local adds, removes = pendingAdd, pendingRemove
    pendingAdd, pendingRemove = {}, {}

    for target, list in pairs(adds) do
        if #list > 0 then sendBatched(target, 'core:client:worldAdd', list, false) end
    end

    for target, list in pairs(removes) do
        local chunk = {}
        for i = 1, #list do
            chunk[#chunk + 1] = list[i]
            if #chunk >= MAX_BATCH then
                emitTo(target, 'core:client:worldRemove', chunk)
                chunk = {}
            end
        end
        if #chunk > 0 then emitTo(target, 'core:client:worldRemove', chunk) end
    end
end

local function scheduleFlush()
    if flushQueued then return end
    flushQueued = true
    SetTimeout(0, flush)
end

--- Queue one entry for its audience. The wire table keeps a live reference to
--- `entry.opts`, so an update in the same tick is folded into the add.
---@param entry table
local function queueAdd(entry)
    local target = entry.target or GLOBAL_TARGET
    local list = pendingAdd[target]
    if not list then
        list = {}
        pendingAdd[target] = list
    end
    list[#list + 1] = { kind = entry.kind, id = entry.id, opts = entry.opts }
    scheduleFlush()
end

--- Queue one removal, or cancel the add that is still sitting in this tick's
--- batch (ids are never reused, so the two can only ever be the same entry).
---@param entry table
local function queueRemove(entry)
    local target = entry.target or GLOBAL_TARGET
    local adds = pendingAdd[target]
    if adds then
        for i = #adds, 1, -1 do
            if adds[i].id == entry.id then
                table.remove(adds, i)
                return
            end
        end
    end

    local list = pendingRemove[target]
    if not list then
        list = {}
        pendingRemove[target] = list
    end
    list[#list + 1] = entry.id
    scheduleFlush()
end

--- The entry behind a client-supplied id, for `src`, or nil.
--- A per-player entry is invisible to every other player.
---@param id string
---@param src integer
---@return table|nil
local function entryFor(id, src)
    local entry = index[id]
    if not entry or entry.kind ~= 'interaction' then return nil end
    if entry.target and entry.target ~= src then return nil end
    return entry
end

--- Distance from the player's ped to the entry, or nil when there is no ped.
--- Server natives: GetPlayerPed(playerSrc), GetEntityCoords(entity).
---@param src integer
---@param entry table
---@return number|nil
local function pedDistance(src, entry)
    if not entry.coords then return nil end
    local ped = GetPlayerPed(src)
    if ped == 0 then return nil end
    return #(GetEntityCoords(ped) - entry.coords)
end

--- `canInteract` decides; a check that errors denies (fail closed).
---@param entry table
---@param src integer
---@return boolean
local function allowed(entry, src)
    if not Core.Utils.isCallable(entry.canInteract) then return true end
    local ok, result = pcall(entry.canInteract, src)
    if not ok then
        Core.Log.error('world %s: canInteract errored: %s', entry.id, tostring(result))
        return false
    end
    return result ~= false
end

--- Server-owned session truth, never the client-writable `loaded` state bag.
--- Fails closed when `Core.Player` cannot answer.
---@param src integer
---@return boolean
local function isLoaded(src)
    local ok, loaded = pcall(function() return Core.Player.isLoaded(src) end)
    return ok and loaded == true
end

--- Context handed to the plugin's server-side handlers (§15: fn(src, ctx)).
---@param entry table
---@param distance number
---@return table
local function makeCtx(entry, distance)
    return { id = entry.id, coords = entry.coords, distance = distance, data = entry.data }
end

--- Only the plugin that created an entry may change or remove it; core itself
--- (its own modules, the admin tooling) is not restricted.
---@param entry table
---@return boolean
local function ownsEntry(entry)
    local caller = Registry.getCaller()
    return caller == 'core' or caller == entry.owner
end

--- Drop every per-player record that mentions `id` (cooldowns and presence).
---@param id string
local function forgetPlayerState(id)
    for _, byId in pairs(lastUse) do byId[id] = nil end
    for _, byId in pairs(inside) do byId[id] = nil end
    for _, byId in pairs(lastPresence) do byId[id] = nil end
end

--- Where the entry lives in the world: `coords`, or a radius blip's own coords.
---@param kind string
---@param opts table
---@return vector3|nil
local function coordsFrom(kind, opts)
    local coords = toVector3(opts.coords)
    if not coords and kind == 'blip' and type(opts.radius) == 'table' then
        coords = toVector3(opts.radius.coords)
    end
    return coords
end

--- Build the four functions of one kind's server namespace.
---@param kind string
---@return table
local function makeKind(kind)
    local store = registry[kind]
    local api = {}

    --- Shared body of addGlobal/addFor. `target` is nil for a global entry.
    ---@param target integer|nil
    ---@param opts table
    ---@return string|nil id
    local function add(target, opts)
        if type(opts) ~= 'table' then
            Core.Log.error('world %s: an options table is required', kind)
            return nil
        end
        local coords = coordsFrom(kind, opts)
        if not coords then
            Core.Log.error('world %s: opts.coords is required', kind)
            return nil
        end
        if kind == 'interaction' and not Core.Utils.isCallable(opts.onInteract) then
            Core.Log.warn('world interaction: no onInteract handler, the entry will do nothing')
        end

        local owner = Registry.getCaller()
        local id = nextId()
        local entry = {
            id = id, kind = kind, owner = owner, target = target, coords = coords,
            radius = tonumber(opts.radius) or DEFAULT_RADIUS,
            cooldown = math.max(0, tonumber(opts.cooldown) or DEFAULT_COOLDOWN_MS),
            data = opts.data,
            onInteract = opts.onInteract, onEnter = opts.onEnter,
            onExit = opts.onExit, canInteract = opts.canInteract,
            opts = toWire(kind, opts),
        }

        store[id] = entry
        index[id] = entry
        Registry.track('world', id, owner)
        queueAdd(entry)
        return id
    end

    --- Create the entry for every player.
    ---@param opts table
    ---@return string|nil id
    function api.addGlobal(opts)
        return add(nil, opts)
    end

    --- Create the entry for one player only.
    ---@param src integer
    ---@param opts table
    ---@return string|nil id
    function api.addFor(src, opts)
        if math.type(src) ~= 'integer' or src < 1 then
            Core.Log.error('world %s: addFor needs a player src, got %s', kind, tostring(src))
            return nil
        end
        return add(src, opts)
    end

    --- Change any subset of an entry's options (global and per-player ids alike).
    --- Handlers may be replaced by passing them again.
    ---@param id string
    ---@param partial table
    ---@return boolean ok
    ---@return string|nil reason
    function api.updateGlobal(id, partial)
        local entry = store[id]
        if not entry or type(partial) ~= 'table' then return false end
        if not ownsEntry(entry) then return false, 'not_owner' end

        local coords = coordsFrom(kind, partial)
        if coords then entry.coords = coords end
        if partial.radius ~= nil then entry.radius = tonumber(partial.radius) or entry.radius end
        if partial.cooldown ~= nil then
            entry.cooldown = math.max(0, tonumber(partial.cooldown) or entry.cooldown)
        end
        if partial.data ~= nil then entry.data = partial.data end
        for i = 1, #HANDLER_KEYS do
            local key = HANDLER_KEYS[i]
            if Core.Utils.isCallable(partial[key]) then entry[key] = partial[key] end
        end

        local wire = toWire(kind, partial)
        for k, v in pairs(wire) do entry.opts[k] = v end
        send(entry, 'core:client:worldUpdate', kind, id, wire)
        return true
    end

    --- Remove an entry (global and per-player ids alike).
    ---@param id string
    ---@return boolean ok
    ---@return string|nil reason
    function api.removeGlobal(id)
        local entry = store[id]
        if not entry then return false end
        if not ownsEntry(entry) then return false, 'not_owner' end

        store[id] = nil
        index[id] = nil
        forgetPlayerState(id)
        Registry.untrack('world', id)
        queueRemove(entry)
        return true
    end

    return api
end

-- The four server namespaces. They only exist for the world sync, but a later
-- module may add to the same table, so an existing one is extended, not replaced.
local NAMESPACES <const> = {
    Markers = 'marker', TextLabels = 'label', Blips = 'blip', Interactions = 'interaction',
}

for namespace, kind in pairs(NAMESPACES) do
    local api = makeKind(kind)
    local existing = rawget(Core, namespace)
    if type(existing) == 'table' then
        for name, fn in pairs(api) do existing[name] = fn end
    else
        Core[namespace] = api
    end
end

--------------------------------------------------------------------------------
-- Snapshot on playerLoaded (§15): everything global plus that player's own
-- entries, split into messages of at most SNAPSHOT_CHUNK_BYTES.
--------------------------------------------------------------------------------

--- Send the full world state to one player: every global entry plus that
--- player's own, in messages of at most MAX_BATCH entries and 32 KB. `first`
--- marks the opening message, which replaces whatever the client still holds.
---@param src integer
local function sendSnapshot(src)
    local list = {}
    for kind, store in pairs(registry) do
        for id, entry in pairs(store) do
            if not entry.target or entry.target == src then
                list[#list + 1] = { kind = kind, id = id, opts = entry.opts }
            end
        end
    end
    -- Always at least one message: an empty snapshot still clears the client.
    sendBatched(src, 'core:client:worldSnapshot', list, true)
end

Core.on('playerLoaded', function(src)
    if math.type(src) ~= 'integer' then return end
    sendSnapshot(src)
end)

--------------------------------------------------------------------------------
-- Client -> server: interaction triggers (§15). Every handler goes through
-- `Core.Net.on`, so src -> schema -> cooldown -> loaded runs before this code;
-- the entry's own cooldown and distance are checked here because both depend on
-- the id in the payload. Nothing else is trusted: the id only ever selects a
-- server-side entry, and a per-player entry answers to its own player only.
--------------------------------------------------------------------------------

--- Run one plugin handler; a plugin error never reaches the event dispatcher.
---@param entry table
---@param fn function
---@param what string
---@param src integer
---@param ctx table
local function runHandler(entry, fn, what, src, ctx)
    local ok, err = pcall(fn, src, ctx)
    if not ok then
        Core.Log.error('world %s: %s handler errored: %s', entry.id, what, tostring(err))
    end
end

Core.Net.on('core:server:worldInteract', { 'id' }, function(src, id)
    local entry = entryFor(id, src)
    if not entry or entry.opts.enabled == false or not Core.Utils.isCallable(entry.onInteract) then return end

    local distance = pedDistance(src, entry)
    if not distance or distance > entry.radius + INTERACT_SLACK then return end

    local now = GetGameTimer()
    local byId = lastUse[src]
    if not byId then
        byId = {}
        lastUse[src] = byId
    end
    local last = byId[id]
    if entry.cooldown > 0 and last and now - last < entry.cooldown then return end
    byId[id] = now

    if not allowed(entry, src) then return end
    runHandler(entry, entry.onInteract, 'onInteract', src, makeCtx(entry, distance))
end, { cooldown = FLOOD_COOLDOWN_MS })

-- Presence is bookkeeping first, callbacks second. `Core.Net.on`'s own cooldown
-- is off here on purpose: it stamps before the loaded/distance checks, so one
-- rejected event would swallow the next real enter. The rate limit lives inside
-- instead, per (src, id), and it only decides whether this enter/exit CYCLE runs
-- the plugin's callbacks -- `inside` is always kept straight, and an exit is
-- delivered exactly when its enter was, so a plugin never sees a half pair.
---@param src integer
---@param id string
---@param now integer
---@return boolean
local function presenceAllowed(src, id, now)
    local byId = lastPresence[src]
    if not byId then
        byId = {}
        lastPresence[src] = byId
    end
    local last = byId[id]
    if last and now - last < PRESENCE_COOLDOWN_MS then return false end
    byId[id] = now
    return true
end

Core.Net.on('core:server:worldEnter', { 'id' }, function(src, id)
    local entry = entryFor(id, src)
    if not entry or entry.opts.enabled == false then return end
    local distance = pedDistance(src, entry)
    if not distance or distance > entry.radius + PRESENCE_SLACK then return end

    local byId = inside[src]
    if not byId then
        byId = {}
        inside[src] = byId
    end
    if byId[id] ~= nil then return end   -- already inside: a repeated enter changes nothing

    -- `live` says whether this cycle reports to the plugin at all; either way the
    -- player counts as inside, so the matching exit still clears the record.
    local live = presenceAllowed(src, id, GetGameTimer())
    byId[id] = live
    if not live or not Core.Utils.isCallable(entry.onEnter) then return end
    runHandler(entry, entry.onEnter, 'onEnter', src, makeCtx(entry, distance))
end, { cooldown = 0 })

-- Exit is gated by the server's own record of the matching enter, not by distance:
-- by the time the client notices it left, a player in a vehicle is already well
-- past `radius + 2.0`, and a distance check would swallow the exit (and leave the
-- plugin's state stuck). An exit the server never saw an enter for is ignored.
Core.Net.on('core:server:worldExit', { 'id' }, function(src, id)
    local byId = inside[src]
    if not byId then return end
    local live = byId[id]
    if live == nil then return end
    byId[id] = nil

    local entry = entryFor(id, src)
    if not live or not entry or entry.opts.enabled == false then return end
    if not Core.Utils.isCallable(entry.onExit) then return end
    runHandler(entry, entry.onExit, 'onExit', src, makeCtx(entry, pedDistance(src, entry) or -1.0))
end, { cooldown = 0 })

--- Asked when the client approaches an entry with a `canInteract` handler (§15).
--- Gated like a net event: a loaded session, a ped near the entry and one
--- question per src per CHECK_COOLDOWN_MS. Anything else answers `false`.
Core.Callback.register('core:world:canInteract', { 'id' }, function(src, id)
    local now = GetGameTimer()
    local last = lastCheck[src]
    if last and now - last < CHECK_COOLDOWN_MS then return false end
    lastCheck[src] = now

    if not isLoaded(src) then return false end

    local entry = entryFor(id, src)
    if not entry or entry.opts.enabled == false then return false end

    local distance = pedDistance(src, entry)
    if not distance or distance > entry.radius + CHECK_SLACK then return false end

    return allowed(entry, src)
end)

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

--- Forget one entry without telling the client (the client is gone, or the
--- owning resource stopped and the removal is broadcast by the caller).
---@param entry table
local function forget(entry)
    local store = registry[entry.kind]
    if store then store[entry.id] = nil end
    index[entry.id] = nil
    forgetPlayerState(entry.id)
end

-- A player left: drop their cooldowns and every entry that was only theirs
-- (server ids are reused, so a stale per-player entry would surface on the next
-- player to take that src).
AddEventHandler('playerDropped', function()
    local src = source
    lastUse[src] = nil
    lastCheck[src] = nil
    lastPresence[src] = nil
    inside[src] = nil          -- no onExit for a player who is already gone: plugins have the playerDropped hook
    local stale = {}
    for id, entry in pairs(index) do
        if entry.target == src then stale[#stale + 1] = id end
    end
    for i = 1, #stale do
        local entry = index[stale[i]]
        Registry.untrack('world', entry.id)
        forget(entry)
    end
end)

-- The owning plugin stopped: remove its entries everywhere (§2.3). Synchronous.
-- One remover call per id (api.lua sweeps id by id), but the removals leave as
-- one batched array event on the next tick -- a plugin with 300 points must not
-- turn into 300 broadcasts while it stops.
Registry.onOwnerStop('world', function(id)
    local entry = index[id]
    if not entry then return end
    forget(entry)
    queueRemove(entry)
end)

-- end of file
