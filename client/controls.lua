-- Core.Controls (DESIGN §40): reference-counted input restrictions, one active-only frame loop.
--   acquire({ controls = { ids }, groups? })            -- those controls, one DisableControlAction each per frame
--   acquire({ all = true, except = { ids }?, groups? })  -- the whole group: DisableAllControlActions + one
--                                                          EnableControlAction per exception (a camera mode: ~5
--                                                          natives per frame instead of one per control)
-- With several handles on one group, `all` wins; a control stays enabled only when EVERY `all` handle excepts
-- it and no list handle disables it. The per-frame plan is rebuilt on acquire/release as dense arrays.
-- Natives (fxref + natives.json, 2026-09-26): DisableControlAction, DisableAllControlActions (padIndex),
-- EnableControlAction (padIndex, control, enable).
local Registry = Core.Registry
local Controls, handles = {}, {}
local counts, allCounts, exceptCounts = {}, {}, {}   -- group -> control -> n · group -> n · group -> control -> n
local plan = {}                                      -- dense: { group, all, list | enable }
local serial, running = 0, false
local function integer(value, low, high)
    return math.type(value) == 'integer' and value >= low and value <= high
end
local function dense(value, min, max)
    if type(value) ~= 'table' then return false end
    local size = #value
    if size < min or size > max then return false end
    local count = 0
    for key in pairs(value) do
        if not integer(key, 1, size) then return false end
        count = count + 1
    end
    return count == size
end
local function sortedKeys(set, keep)
    local out = {}
    for control in pairs(set or {}) do if not keep or keep(control) then out[#out + 1] = control end end
    table.sort(out)
    return out
end
--- Rebuilds the per-frame plan from the counters (only on acquire/release, never per frame).
local function rebuild()
    plan = {}
    local groups = {}
    for group in pairs(counts) do groups[group] = true end
    for group in pairs(allCounts) do groups[group] = true end
    for _, group in ipairs(sortedKeys(groups)) do
        local all = allCounts[group]
        if all then
            local excepted, listed = exceptCounts[group] or {}, counts[group] or {}
            plan[#plan + 1] = { group = group, all = true, enable = sortedKeys(excepted, function(control)
                return excepted[control] == all and not listed[control]
            end) }
        else
            plan[#plan + 1] = { group = group, all = false, list = sortedKeys(counts[group]) }
        end
    end
end
local function bump(map, group, control, delta)
    local byGroup = map[group] or {}
    map[group] = byGroup
    local n = (byGroup[control] or 0) + delta
    byGroup[control] = n > 0 and n or nil
    if not next(byGroup) then map[group] = nil end
end
local function remove(id)
    local entry = handles[id]
    if not entry then return false end
    handles[id] = nil
    for group, controls in pairs(entry.pairs) do
        for control in pairs(controls) do bump(counts, group, control, -1) end
    end
    for group, except in pairs(entry.all or {}) do
        local n = (allCounts[group] or 0) - 1
        allCounts[group] = n > 0 and n or nil
        for control in pairs(except) do bump(exceptCounts, group, control, -1) end
    end
    rebuild()
    Registry.untrack('controls', id)
    return true
end
local function startLoop()
    if running then return end
    running = true
    CreateThread(function()
        while next(handles) do
            for i = 1, #plan do
                local step = plan[i]
                local group = step.group
                if step.all then
                    DisableAllControlActions(group)
                    local enable = step.enable
                    for j = 1, #enable do EnableControlAction(group, enable[j], true) end
                else
                    local list = step.list
                    for j = 1, #list do DisableControlAction(group, list[j], true) end
                end
            end
            Wait(0) -- per-frame: input restrictions only while at least one handle exists
        end
        running = false
    end)
end
--- { [control] = true } of a validated id array, or nil.
local function controlSet(list)
    local set = {}
    for _, control in ipairs(list) do
        if not integer(control, 0, 360) then return nil end
        set[control] = true
    end
    return set
end
function Controls.acquire(opts)
    if type(opts) ~= 'table' then return nil end
    if opts.all ~= nil and type(opts.all) ~= 'boolean' then return nil end
    local all = opts.all == true
    if all then
        if opts.controls ~= nil or (opts.except ~= nil and not dense(opts.except, 0, 361)) then return nil end
    elseif not dense(opts.controls, 1, 361) then
        return nil
    end
    local groups = opts.groups or { 0 }
    if not dense(groups, 1, 3) then return nil end
    local set = controlSet(all and (opts.except or {}) or opts.controls)
    if not set then return nil end
    local restrictions, everything = {}, all and {} or nil
    for _, group in ipairs(groups) do
        if not integer(group, 0, 2) then return nil end
        if all then everything[group] = set else restrictions[group] = set end
    end
    serial = serial + 1
    local id, owner = 'controls:' .. serial, Registry.getCaller()
    handles[id] = { owner = owner, pairs = restrictions, all = everything }
    for group, controls in pairs(restrictions) do
        for control in pairs(controls) do bump(counts, group, control, 1) end
    end
    for group, except in pairs(everything or {}) do
        allCounts[group] = (allCounts[group] or 0) + 1
        for control in pairs(except) do bump(exceptCounts, group, control, 1) end
    end
    rebuild()
    Registry.track('controls', id, owner)
    startLoop()
    return id
end
function Controls.release(id)
    local entry, owner = handles[id], Registry.getCaller()
    if not entry or entry.owner ~= owner then return false end
    return remove(id)
end
function Controls.releaseAll()
    local owner = Registry.getCaller()
    for id, entry in pairs(handles) do if entry.owner == owner then remove(id) end end
end
-- Private cleanup seam: Registry is blocked by the cross-resource dispatcher.
Registry.releaseControls = remove
Registry.onOwnerStop('controls', remove)
AddEventHandler('onResourceStop', function(resource)
    if resource == 'core' then for id in pairs(handles) do remove(id) end end
end)
Core.Controls = Controls
