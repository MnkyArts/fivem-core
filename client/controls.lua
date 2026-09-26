-- Core.Controls (DESIGN §40). Native: DisableControlAction (client), verified fxref.
local Registry = Core.Registry
local Controls, handles, counts = {}, {}, {}
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
local function remove(id)
    local entry = handles[id]
    if not entry then return false end
    handles[id] = nil
    for group, controls in pairs(entry.pairs) do
        for control in pairs(controls) do
            counts[group][control] = counts[group][control] - 1
            if counts[group][control] == 0 then counts[group][control] = nil end
        end
        if not next(counts[group]) then counts[group] = nil end
    end
    Registry.untrack('controls', id)
    return true
end
local function startLoop()
    if running then return end
    running = true
    CreateThread(function()
        while next(handles) do
            for group, controls in pairs(counts) do
                for control in pairs(controls) do DisableControlAction(group, control, true) end
            end
            Wait(0) -- per-frame: input restrictions only while at least one handle exists
        end
        running = false
    end)
end
function Controls.acquire(opts)
    if type(opts) ~= 'table' or not dense(opts.controls, 1, 361) then return nil end
    local groups = opts.groups or { 0 }
    if not dense(groups, 1, 3) then return nil end
    local restrictions = {}
    for _, group in ipairs(groups) do
        if not integer(group, 0, 2) then return nil end
        local controls = {}
        for _, control in ipairs(opts.controls) do
            if not integer(control, 0, 360) then return nil end
            controls[control] = true
        end
        restrictions[group] = controls
    end
    serial = serial + 1
    local id, owner = 'controls:' .. serial, Registry.getCaller()
    handles[id] = { owner = owner, pairs = restrictions }
    for group, controls in pairs(restrictions) do
        counts[group] = counts[group] or {}
        for control in pairs(controls) do counts[group][control] = (counts[group][control] or 0) + 1 end
    end
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
