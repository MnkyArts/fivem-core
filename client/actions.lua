-- Core.Actions (DESIGN §40). Verified client natives: PlayerPedId, DoesEntityExist,
-- IsEntityDead, IsPedFalling, IsPedSwimming, IsPedRagdoll, GetGameTimer, GetHashKey,
-- GetEntityCoords, TaskPlayAnim, TaskStartScenarioInPlace, StopAnimTask, ClearPedTasks,
-- CreateObject, GetPedBoneIndex, AttachEntityToEntity, DeleteEntity.
local Registry = Core.Registry
local Actions, active, serial = {}, nil, 0
local function finite(v, low, high)
    return type(v) == 'number' and v == v and v >= low and v <= high
end
local function text(v) return type(v) == 'string' and #v > 0 and #v <= 128 end
local function vector(v)
    if v == nil then return { x = 0.0, y = 0.0, z = 0.0 } end
    if type(v) ~= 'table' and type(v) ~= 'vector3' then return nil end
    if not finite(v.x, -1000, 1000) or not finite(v.y, -1000, 1000) or not finite(v.z, -1000, 1000) then return nil end
    return { x = v.x + 0.0, y = v.y + 0.0, z = v.z + 0.0 }
end
local function options(opts)
    if type(opts) ~= 'table' or math.type(opts.duration) ~= 'integer' or not finite(opts.duration, 100, 600000) then return nil end
    local result = { duration = opts.duration, label = type(opts.label) == 'string' and opts.label:sub(1, 128) or '', props = {} }
    for _, key in ipairs({ 'canCancel', 'allowDead', 'allowFalling', 'allowSwimming', 'allowRagdoll' }) do
        if opts[key] ~= nil and type(opts[key]) ~= 'boolean' then return nil end
        result[key] = opts[key] == true
    end
    if opts.animation ~= nil then
        local a = opts.animation
        if type(a) ~= 'table' or not text(a.dict) or not text(a.clip) or (a.flag ~= nil and (math.type(a.flag) ~= 'integer' or not finite(a.flag, 0, 2147483647))) then return nil end
        result.animation = { dict = a.dict, clip = a.clip, flag = a.flag or 49 }
    end
    if opts.scenario ~= nil then
        if not text(opts.scenario) or result.animation then return nil end
        result.scenario = opts.scenario
    end
    if opts.disable ~= nil then
        if type(opts.disable) ~= 'table' or #opts.disable > 361 then return nil end
        result.disable = {}
        for i, id in ipairs(opts.disable) do
            if math.type(id) ~= 'integer' or not finite(id, 0, 360) then return nil end
            result.disable[i] = id
        end
    end
    if opts.props ~= nil then
        if type(opts.props) ~= 'table' or #opts.props > 8 then return nil end
        for i, prop in ipairs(opts.props) do
            if type(prop) ~= 'table' or (not text(prop.model) and math.type(prop.model) ~= 'integer') then return nil end
            if prop.bone ~= nil and (math.type(prop.bone) ~= 'integer' or not finite(prop.bone, 0, 65535)) then return nil end
            local offset, rotation = vector(prop.offset), vector(prop.rotation)
            if not offset or not rotation then return nil end
            result.props[i] = { model = prop.model, bone = prop.bone or 60309, offset = offset, rotation = rotation }
        end
    end
    return result
end
local function truth(value) return value == true or value == 1 end
local function interrupted(entry)
    if PlayerPedId() ~= entry.ped or not truth(DoesEntityExist(entry.ped)) then return 'ped_changed' end
    local opts, ped = entry.opts, entry.ped
    if not opts.allowDead and truth(IsEntityDead(ped, false)) then return 'dead' end
    if not opts.allowFalling and truth(IsPedFalling(ped)) then return 'falling' end
    if not opts.allowSwimming and truth(IsPedSwimming(ped)) then return 'swimming' end
    if not opts.allowRagdoll and truth(IsPedRagdoll(ped)) then return 'ragdoll' end
end
local function cleanup(entry, reason)
    if entry.cleaned then return end
    entry.cleaned, entry.reason = true, reason
    if entry.progress then Core.UIInternal.cancelManagedProgress(entry.progressToken) end
    if entry.controls then Registry.releaseControls(entry.controls) end
    if truth(DoesEntityExist(entry.ped)) then
        if entry.animStarted then StopAnimTask(entry.ped, entry.opts.animation.dict, entry.opts.animation.clip, 1.0) end
        if entry.scenarioStarted then ClearPedTasks(entry.ped) end
    end
    for _, entity in ipairs(entry.entities) do if truth(DoesEntityExist(entity)) then DeleteEntity(entity) end end
    for model in pairs(entry.models) do Core.Streaming.releaseModel(model) end
    if entry.dict then Core.Streaming.releaseAnimDict(entry.dict) end
    Registry.untrack('action', entry.id)
    -- Keep the busy slot until the run coroutine returns: a stalled streamer cannot overlap a new action.
end
local function run(entry)
    local opts = entry.opts
    local reason = interrupted(entry)
    if reason then return false, reason end
    if opts.disable and #opts.disable > 0 then
        entry.controls = Core.Controls.acquire({ controls = opts.disable })
        if not entry.controls then return false, 'controls_failed' end
    end
    if opts.animation then
        entry.dict = opts.animation.dict
        local loaded = Core.Streaming.requestAnimDict(entry.dict, 10000)
        if entry.cleaned then Core.Streaming.releaseAnimDict(entry.dict); return false, entry.reason end
        if not loaded then return false, 'asset_failed' end
    end
    for _, prop in ipairs(opts.props) do
        entry.models[prop.model] = true
        local loaded = Core.Streaming.requestModel(prop.model, 10000)
        if entry.cleaned then Core.Streaming.releaseModel(prop.model); return false, entry.reason end
        if not loaded then return false, 'asset_failed' end
        reason = interrupted(entry)
        if reason then return false, reason end
        local coords = GetEntityCoords(entry.ped, false)
        local hash = type(prop.model) == 'string' and GetHashKey(prop.model) or prop.model
        local entity = CreateObject(hash, coords.x, coords.y, coords.z, false, false, false)
        if entity == 0 then return false, 'entity_failed' end
        entry.entities[#entry.entities + 1] = entity
        local o, r = prop.offset, prop.rotation
        AttachEntityToEntity(entity, entry.ped, GetPedBoneIndex(entry.ped, prop.bone), o.x, o.y, o.z, r.x, r.y, r.z, false, false, false, true, 2, true, 0)
    end
    reason = interrupted(entry)
    if reason then return false, reason end
    if opts.animation then
        local a = opts.animation
        TaskPlayAnim(entry.ped, a.dict, a.clip, 3.0, 3.0, opts.duration, a.flag, 0.0, false, false, false)
        entry.animStarted = true
    elseif opts.scenario then
        TaskStartScenarioInPlace(entry.ped, opts.scenario, 0, true)
        entry.scenarioStarted = true
    end
    entry.progress = true
    entry.progressToken = {}
    entry.deadline = GetGameTimer() + opts.duration + 2000
    local completed = Core.UI.progress({ label = opts.label, duration = opts.duration, canCancel = opts.canCancel, _actionToken = entry.progressToken })
    entry.progress = false
    return completed and not entry.cleaned, entry.reason or (completed and 'completed' or 'cancelled')
end
function Actions.run(opts)
    if active then return false, 'busy' end
    opts = options(opts)
    if not opts then return false, 'invalid_options' end
    serial = serial + 1
    local entry = { id = 'action:' .. serial, owner = Registry.getCaller(), opts = opts, ped = PlayerPedId(), entities = {}, models = {}, deadline = GetGameTimer() + 90000 }
    active = entry
    Registry.track('action', entry.id, entry.owner)
    CreateThread(function()
        while active == entry and not entry.cleaned do
            local reason = interrupted(entry)
            if not reason and GetGameTimer() >= entry.deadline then reason = 'timeout' end
            if reason then cleanup(entry, reason); break end
            Wait(50) -- bounded activity monitor; no thread when idle
        end
    end)
    local ok, completed, reason = pcall(run, entry)
    if not ok then completed, reason = false, 'error' end
    cleanup(entry, reason)
    if active == entry then active = nil end
    return completed == true, entry.reason or reason
end
function Actions.cancel()
    if not active or active.cleaned or active.owner ~= Registry.getCaller() then return false end
    cleanup(active, 'cancelled')
    return true
end
function Actions.isActive() return active ~= nil and not active.cleaned end
Registry.onOwnerStop('action', function(id)
    if active and active.id == id then cleanup(active, 'owner_stopped') end
end)
AddEventHandler('onResourceStop', function(resource)
    if resource == 'core' and active then cleanup(active, 'core_stopped') end
end)
Core.Actions = Actions
