-- Core.Hooks — synchronous, owner-scoped veto pipelines (DESIGN §40).
-- Loaded after the side's api.lua. No natives; lifecycle observers remain separate.
local Hooks, Registry, Utils = {}, Core.Registry, Core.Utils
local entries, pipelines, active = {}, {}, {}
local serial, count = 0, 0

local function validName(name)
    return type(name) == 'string' and #name > 0 and #name <= 128
        and name:match('^[%w_:%-%.]+$') ~= nil
end

-- Only data crosses a hook boundary: no functions, metatables, cycles or shared nested tables.
local function snapshot(value)
    local seen, budget = {}, 4096
    local function copy(v, depth)
        budget = budget - 1
        if budget < 0 or depth > 16 then error('payload too large', 0) end
        local kind = type(v)
        if kind == 'nil' or kind == 'boolean' or kind == 'string' then return v end
        if kind == 'number' and v == v and v ~= math.huge and v ~= -math.huge then return v end
        if kind ~= 'table' or getmetatable(v) ~= nil or seen[v] then error('invalid payload', 0) end
        seen[v] = true
        local out = {}
        for key, item in pairs(v) do
            if type(key) ~= 'string' and (type(key) ~= 'number' or key ~= key
                or key == math.huge or key == -math.huge) then error('invalid key', 0) end
            out[key] = copy(item, depth + 1)
        end
        seen[v] = nil
        return out
    end
    return pcall(copy, value, 0)
end

local function discard(id)
    local entry = entries[id]
    if not entry then return false end
    entries[id], count = nil, count - 1
    local list = pipelines[entry.name]
    for i = #list, 1, -1 do
        if list[i] == entry then table.remove(list, i); break end
    end
    if #list == 0 then pipelines[entry.name] = nil end
    Registry.untrack('hookPipeline', id)
    return true
end

function Hooks.register(name, callback, options)
    if not validName(name) or not Utils.isCallable(callback) then return nil end
    if options ~= nil and type(options) ~= 'table' then return nil end
    options = options or {}
    local priority = options.priority or 0
    if type(priority) ~= 'number' or priority % 1 ~= 0 or priority ~= priority or math.abs(priority) > 1000000
        or (options.filter ~= nil and not Utils.isCallable(options.filter))
        or (options.after ~= nil and type(options.after) ~= 'boolean') or count >= 4096 then return nil end
    local list = pipelines[name] or {}
    if #list >= 256 then return nil end
    serial, count = serial + 1, count + 1
    local id = 'hook:' .. serial
    local entry = { id = id, name = name, callback = callback, filter = options.filter,
        after = options.after == true, priority = priority, sequence = serial, owner = Registry.getCaller() }
    entries[id], pipelines[name] = entry, list
    list[#list + 1] = entry
    table.sort(list, function(a, b)
        return a.priority < b.priority or (a.priority == b.priority and a.sequence < b.sequence)
    end)
    Registry.track('hookPipeline', id, entry.owner)
    return id
end

function Hooks.remove(id)
    local entry = type(id) == 'string' and entries[id]
    if not entry or entry.owner ~= Registry.getCaller() then return false end
    return discard(id)
end

-- A suspended callback never becomes a detached task. Close it before returning a fail-closed decision.
local function invoke(entry, fn, payload, allowed, reason)
    local valid, data = snapshot(payload)
    if not valid then return false, 'invalid_payload' end
    local caller = Registry.getCaller()
    local co = coroutine.create(function()
        Registry.setCaller(entry.owner)
        return fn(data, allowed, reason)
    end)
    local ok, result, detail = coroutine.resume(co)
    if coroutine.status(co) ~= 'dead' then
        coroutine.close(co)
        Registry.setCaller(caller)
        return false, 'yield'
    end
    Registry.setCaller(caller)
    if not ok then return false, 'error' end
    return true, result, detail
end

function Hooks.run(name, payload)
    if not validName(name) then return false, 'invalid_name' end
    if active[name] then return false, 'reentrant' end
    local valid, original = snapshot(payload)
    if not valid then return false, 'invalid_payload' end
    local list = pipelines[name]
    if not list then return true end
    -- Registration during dispatch applies next time; removal applies immediately.
    local pending = {}
    for i = 1, #list do pending[i] = list[i] end
    active[name] = true
    local allowed, reason = true, nil
    local observers = {}
    for i = 1, #pending do
        local entry = pending[i]
        if entries[entry.id] == entry then
            local matches = true
            if entry.filter then
                local ok, result = invoke(entry, entry.filter, original)
                if not ok then
                    if not entry.after and allowed then allowed, reason = false, 'filter_' .. result end
                    matches = false
                else matches = result == true end
            end
            if matches then
                if entry.after then observers[#observers + 1] = entry
                elseif allowed then
                    local ok, result, detail = invoke(entry, entry.callback, original)
                    if not ok then allowed, reason = false, 'callback_' .. result
                    elseif result == false then
                        allowed, reason = false, type(detail) == 'string' and detail:sub(1, 128) or 'veto'
                    end
                end
            end
        end
    end
    for i = 1, #observers do
        local entry = observers[i]
        if entries[entry.id] == entry then invoke(entry, entry.callback, original, allowed, reason) end
    end
    active[name] = nil
    return allowed, reason
end

Registry.onOwnerStop('hookPipeline', function(id) discard(id) end)
Core.Hooks = Hooks
