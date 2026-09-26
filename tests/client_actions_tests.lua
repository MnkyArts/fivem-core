-- Standalone deterministic client activity/controls tests (no game required).
local here = (arg[0]:match('^(.*)/') or '.')
local root = here .. '/..'
local passed = 0
local function eq(a, b, label)
    assert(a == b, ('%s: expected %s, got %s'):format(label, tostring(b), tostring(a)))
    passed = passed + 1
end
local owner, time, ped, dead = 'alpha', 0, 1, false
local threads, removers, stopHandlers, tracked = {}, {}, {}, {}
local disabled, deleted, released, cancelled, created = {}, 0, 0, 0, 0
local progressToken
local loadHook, progressHook, animStarted, animStopped, scenarioStopped
local env = setmetatable({}, { __index = _G })
env.Core = { Registry = {}, Streaming = {}, UI = {}, UIInternal = {} }
local Core = env.Core
Core.Registry.getCaller = function() return owner end
Core.Registry.track = function(kind, id, who) tracked[id] = { kind, who } end
Core.Registry.untrack = function(_, id) tracked[id] = nil end
Core.Registry.onOwnerStop = function(kind, fn) removers[kind] = fn end
function env.CreateThread(fn) threads[#threads + 1] = coroutine.create(fn) end
function env.Wait(ms) coroutine.yield(ms) end
function env.AddEventHandler(_, fn) stopHandlers[#stopHandlers + 1] = fn end
function env.DisableControlAction(group, control) disabled[group .. ':' .. control] = true end
function env.PlayerPedId() return ped end
function env.GetGameTimer() return time end
function env.DoesEntityExist(entity) return entity ~= 0 end
function env.IsEntityDead() return dead end
function env.IsPedFalling() return false end
function env.IsPedSwimming() return false end
function env.IsPedRagdoll() return false end
function env.GetHashKey() return 123 end
function env.GetEntityCoords() return { x = 1.0, y = 2.0, z = 3.0 } end
function env.CreateObject(_, _, _, _, network) eq(network, false, 'prop is local'); created = created + 1; return 50 + created end
function env.GetPedBoneIndex(_, bone) return bone end
function env.AttachEntityToEntity(...) eq(select('#', ...), 16, 'OAL attach argument count') end
function env.DeleteEntity() deleted = deleted + 1 end
function env.TaskPlayAnim() animStarted = true end
function env.StopAnimTask() animStopped = true end
function env.TaskStartScenarioInPlace() end
function env.ClearPedTasks() scenarioStopped = true end
Core.Streaming.requestModel = function() if loadHook then return loadHook() end return true end
Core.Streaming.requestAnimDict = function() if loadHook then return loadHook() end return true end
Core.Streaming.releaseModel = function() released = released + 1 end
Core.Streaming.releaseAnimDict = function() released = released + 1 end
Core.UI.progress = function(opts) progressToken = opts._actionToken; if progressHook then return progressHook() end return true end
Core.UIInternal.cancelManagedProgress = function(token) if token == progressToken then cancelled = cancelled + 1 end end
assert(loadfile(root .. '/client/controls.lua', 't', env))()
assert(loadfile(root .. '/client/actions.lua', 't', env))()
local function tick()
    local current = threads
    threads = {}
    for _, co in ipairs(current) do
        if coroutine.status(co) ~= 'dead' then
            local ok, err = coroutine.resume(co)
            assert(ok, err)
            if coroutine.status(co) ~= 'dead' then threads[#threads + 1] = co end
        end
    end
end
local function stop(who)
    local ids = {}
    for id, entry in pairs(tracked) do if entry[2] == who then ids[#ids + 1] = { id, entry[1] } end end
    for _, entry in ipairs(ids) do removers[entry[2]](entry[1], who) end
end
local a = Core.Controls.acquire({ controls = { 24, 24 }, groups = { 0, 0 } })
local b = Core.Controls.acquire({ controls = { 24 } })
eq(type(a), 'string', 'handle')
tick(); eq(disabled['0:24'], true, 'restriction drawn')
eq(Core.Controls.release(a), true, 'first released')
disabled = {}; tick(); eq(disabled['0:24'], true, 'overlap remains')
owner = 'beta'; eq(Core.Controls.release(b), false, 'foreign owner refused')
owner = 'alpha'; Core.Controls.releaseAll(); disabled = {}; tick()
eq(next(disabled), nil, 'last release stops restrictions')
eq(Core.Controls.acquire({ controls = { -1 } }), nil, 'invalid control')
eq(Core.Controls.acquire({ controls = { [1] = 24, [3] = 25 } }), nil, 'sparse controls')
eq(Core.Controls.acquire({ controls = { 24, extra = 25 } }), nil, 'controls extra keys')
eq(Core.Controls.acquire({ controls = { 24 }, groups = { [1] = 0, [3] = 2 } }), nil, 'sparse groups')
eq(Core.Controls.acquire({ controls = { 24 }, groups = { 3 } }), nil, 'invalid group')
eq(Core.Actions.run({ duration = 0/0 }), false, 'nan duration')
eq(Core.Actions.run({ duration = 100, props = { { model = 'box', offset = { x = 0/0, y = 0, z = 0 } } } }), false, 'nan offset')
local completed, reason = Core.Actions.run({ duration = 100, animation = { dict = 'dict', clip = 'clip' }, disable = { 24 }, props = { { model = 'box' } } })
eq(completed, true, 'successful action'); eq(reason, 'completed', 'success reason')
eq(animStarted, true, 'animation started'); eq(animStopped, true, 'animation stopped')
eq(deleted, 1, 'prop deleted'); eq(released, 2, 'assets released'); eq(next(tracked), nil, 'registrations released')
progressHook = function()
    owner = 'beta'; eq(Core.Actions.cancel(), false, 'foreign cancel refused'); owner = 'alpha'
    eq(Core.Actions.run({ duration = 100 }), false, 'busy action refused')
    eq(Core.Actions.cancel(), true, 'owner cancel'); return true
end
completed, reason = Core.Actions.run({ duration = 100, scenario = 'WORLD_HUMAN_STAND_IMPATIENT' })
eq(completed, false, 'cancel beats UI success'); eq(reason, 'cancelled', 'cancel reason')
eq(scenarioStopped, true, 'scenario cleaned'); eq(cancelled, 1, 'progress cancelled')
progressHook = function()
    progressToken = {} -- another widget replaced the managed progress before its coroutine resumed
    local before = cancelled
    Core.Actions.cancel()
    eq(cancelled, before, 'replacement progress untouched')
    return false
end
Core.Actions.run({ duration = 100 })
progressHook = nil
local previousCreated = created
loadHook = function() stop('alpha'); return true end
completed, reason = Core.Actions.run({ duration = 100, props = { { model = 'box' } }, disable = { 24 } })
eq(completed, false, 'owner stop during loading'); eq(reason, 'owner_stopped', 'stop reason')
eq(created, previousCreated, 'no entity after owner stop'); eq(next(tracked), nil, 'stop released all handles')
loadHook = nil
progressHook = function() ped = 2; tick(); return true end
completed, reason = Core.Actions.run({ duration = 100 })
eq(completed, false, 'ped swap interrupts'); eq(reason, 'ped_changed', 'ped reason')
progressHook = function() dead = true; tick(); return true end
completed, reason = Core.Actions.run({ duration = 100 })
eq(completed, false, 'death interrupts'); eq(reason, 'dead', 'death reason'); dead = false
progressHook = function() time = time + 1000000; tick(); return true end
completed, reason = Core.Actions.run({ duration = 100 })
eq(completed, false, 'deadline interrupts'); eq(reason, 'timeout', 'timeout reason')
progressHook = function() error('UI unavailable') end
completed, reason = Core.Actions.run({ duration = 100, disable = { 24 } })
eq(completed, false, 'UI error fails closed'); eq(reason, 'error', 'error reason'); eq(next(tracked), nil, 'error cleanup')
progressHook = function() for _, fn in ipairs(stopHandlers) do fn('core') end return true end
completed, reason = Core.Actions.run({ duration = 100, props = { { model = 'box' } } })
eq(completed, false, 'core stop'); eq(reason, 'core_stopped', 'core stop reason')
eq(Core.Actions.isActive(), false, 'inactive afterwards')
print(('client_actions_tests: %d passed, 0 failed'):format(passed))
