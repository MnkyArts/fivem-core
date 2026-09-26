-- Deterministic proximity lifecycle, geometry and scheduler tests; no game required.
local here = arg[0]:match('^(.*)/') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads checked-in stubs only
local stubs = dofile(here .. '/stubs.lua')
local env = stubs.newEnv('client', 'core')
stubs.loadFile(env, 'import.lua')
stubs.loadFile(env, 'client/api.lua')
local v, count = stubs.vector3, 0
local function eq(actual, expected, label)
    assert(actual == expected, label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    count = count + 1
end
local pos, time, scan, timers, draws, lines, markers = v(0,0,0), 0, nil, {}, {}, 0, 0
local reads = 0
function env.PlayerPedId() return 1 end
function env.GetEntityCoords() reads = reads + 1; return pos end
function env.GetGameTimer() return time end
function env.CreateThread(fn) scan = coroutine.create(fn) end
function env.Wait(ms) coroutine.yield(ms) end
function env.SetTimeout(_, fn) timers[#timers + 1] = fn end
function env.DrawLine() lines = lines + 1 end
function env.DrawMarker() markers = markers + 1 end
env.Core.World = {
    add = function(_, id, _, _, fn) draws[id] = fn end,
    remove = function(_, id) draws[id] = nil end,
}
stubs.loadFile(env, 'client/zones.lua')
local C = env.Core
local function owner(name) C.Registry.setCaller(name) end
local function tick(coords)
    pos, time = coords or pos, time + 250
    local ok, wait = coroutine.resume(scan)
    assert(ok, wait)
    local pending = timers
    timers = {}
    for _, fn in ipairs(pending) do fn() end
    return wait
end
owner('alpha')
eq(tick(), 1000, 'empty scheduler sleeps')
eq(reads, 0, 'empty scheduler reads no natives')
local entered, exited, near = 0, 0, 0
local id
local entered2 = 0
id = C.Zones.add({type='sphere',coords=v(0,0,0),radius=4,debug=true,
    onEnter=function(got) eq(got,id,'enter id'); entered=entered+1 end,
    onExit=function() exited=exited+1 end})
eq(type(id), 'string', 'zone handle')
eq(C.Zones.contains(id,v(4,0,0)),true,'exact edge')
eq(C.Zones.contains(id,v(4.001,0,0)),false,'outside edge')
eq(tick(),250,'registered scheduler sleep')
eq(entered,1,'enter once')
tick(); eq(entered,1,'no repeated enter')
tick(v(10,0,0)); eq(exited,1,'exit once')
tick(v(5000,0,0)); eq(exited,1,'far no repeated exit')
tick(v(0,0,0)); eq(entered,2,'reenter after teleport')
draws[id]({id=id}); eq(markers,1,'sphere debug drawn by world')
owner('beta')
eq(C.Zones.remove(id),false,'foreign removal denied')
eq(C.Zones.contains(id,v(0,0,0)),false,'foreign query denied')
owner('alpha')
local box = C.Zones.add({type='box',coords=v(1000,0,0),size=v(4,2,4),rotation=90,debug=true,
    onEnter=function() entered2=entered2+1 end})
tick(v(1000,1.9,0)); eq(entered2,1,'rotated box in remote cell')
draws[box]({id=box}); eq(lines,12,'box debug edges')
local poly = C.Zones.add({type='polygon',points={v(-500,-500,0),v(500,-500,0),v(0,500,0)},minZ=-10,maxZ=10,
    onEnter=function() entered2=entered2+1 end})
tick(v(0,100,0)); eq(entered2,2,'large polygon spatial level')
eq(C.Zones.contains(poly,v(0,100,11)),false,'polygon height')
local point = C.Points.add({coords=v(0,100,0),distance=5,interval=500,nearby=function(_,distance)
    near=near+1; eq(distance,0,'point distance') end})
tick(); eq(near,1,'point nearby')
tick(); eq(near,1,'nearby interval')
tick(); eq(near,2,'nearby due')
eq(C.Zones.remove(point),false,'zone cannot remove point')
eq(C.Points.remove(id),false,'point cannot remove zone')
eq(C.Zones.add({type='sphere',coords=v(0,0,0),radius=-1}),nil,'bad geometry')
eq(C.Points.add({coords=v(0,0,0),distance=2,interval=0}),nil,'bad interval')
eq(C.Points.add({coords=v(0,0,0),distance=2,onEnter=true}),nil,'bad callback')
owner('beta')
local kept = C.Points.add({coords=v(0,0,0),distance=1})
owner('alpha')
C.Zones.removeAll(); eq(next(draws),nil,'all debug unregistered')
C.Points.removeAll(); eq(C.Points.remove(point),false,'point removed')
owner('beta'); eq(C.Points.remove(kept),true,'other owner retained')
eq(tick(),1000,'last removal idle')
-- Callable export references are accepted, and queued callbacks are invalidated on removal.
local called = 0
local callable = setmetatable({}, {__call=function() called=called+1 end})
local ref = C.Points.add({coords=v(0,0,0),distance=2,onEnter=callable})
pos=v(0,0,0); time=time+250
assert(coroutine.resume(scan))
eq(#timers,1,'transition callback deferred')
C.Points.remove(ref)
for _,fn in ipairs(timers) do fn() end
timers={}
eq(called,0,'removed callback cannot fire')
print(('client zones: %d passed, 0 failed'):format(count))
