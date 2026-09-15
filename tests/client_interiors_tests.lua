-- Offline tests for client/interiors_data.lua + client/interiors.lua; no GTA runtime.
-- Style follows tests/client_chat_tests.lua: a stub client VM, recorded natives.
local here = (arg[0]:match('^(.*)/') or '.')
local stubs = dofile(here .. '/stubs.lua')
stubs.newWorld()
stubs.clear()

local passed = 0
local function eq(actual, expected, label)
    assert(actual == expected, label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    passed = passed + 1
end
local function ok(cond, label)
    assert(cond, 'FAIL: ' .. label)
    passed = passed + 1
end

local env = stubs.newEnv('client', 'core')

-- recorded natives -----------------------------------------------------------
local requested, removed = {}, {}
local activated, deactivated, refreshed = {}, {}, {}
local buildNumber, dlcPresent = 3095, false
local interiorAt, setActiveUpvalue = 0, false
local caller = 'test_plugin'

env.RequestIpl = function(ipl) requested[#requested + 1] = ipl end
env.RemoveIpl = function(ipl) removed[#removed + 1] = ipl end
env.IsIplActive = function(ipl)
    for _, r in ipairs(removed) do if r == ipl then return false end end
    for _, r in ipairs(requested) do if r == ipl then return true end end
    return false
end
env.GetGameBuildNumber = function() return buildNumber end
env.IsDlcPresent = function() return dlcPresent end
env.GetInteriorAtCoords = function() return interiorAt end
env.IsValidInterior = function(id) return id ~= 0 end
env.IsInteriorReady = function() return true end
env.ActivateInteriorEntitySet = function(id, set) activated[#activated + 1] = { id, set } end
env.DeactivateInteriorEntitySet = function(id, set) deactivated[#deactivated + 1] = { id, set } end
env.IsInteriorEntitySetActive = function() return setActiveUpvalue end
env.RefreshInterior = function(id) refreshed[#refreshed + 1] = id end

local tracked, removers = {}, {}
env.Core = {
    Registry = {
        track = function(_, id, owner) tracked[id] = owner end,
        untrack = function(_, id) tracked[id] = nil end,
        getCaller = function() return caller end,
        onOwnerStop = function(kind, fn) removers[kind] = fn end,
    },
    Log = { debug = function() end, warn = function() end, error = function() end },
}

stubs.loadFile(env, 'shared/config.lua')
stubs.loadFile(env, 'client/interiors_data.lua')
stubs.loadFile(env, 'client/interiors.lua')

local Interiors = env.Core.Interiors
local Data = env.Core.InteriorsData
local Config = env.Config

-- data shape -----------------------------------------------------------------
eq(#Data, 27, '27 IPL groups')
local total, ids = 0, {}
for _, group in ipairs(Data) do
    ok(type(group.id) == 'string' and group.id:match('^[%w_]+$'), 'group id ' .. tostring(group.id))
    ok(type(group.label) == 'string' and #group.label > 0, 'group label ' .. group.id)
    ok(group.default == true or group.default == false, 'group default ' .. group.id)
    ok(type(group.ipls) == 'table' and #group.ipls > 0, 'group ipls ' .. group.id)
    ok(ids[group.id] == nil, 'group id unique ' .. group.id)
    ids[group.id] = true
    if group.minBuild ~= nil then ok(type(group.minBuild) == 'number', 'minBuild number ' .. group.id) end
    if group.dlc ~= nil then ok(type(group.dlc) == 'string', 'dlc string ' .. group.id) end
    total = total + #group.ipls
end
eq(total, 369, '369 researched IPLs')

-- every IPL name is a valid RequestIpl argument, without cross-group duplicates
local seen = {}
for _, group in ipairs(Data) do
    for _, ipl in ipairs(group.ipls) do
        ok(type(ipl) == 'string' and #ipl <= 96 and ipl:match('^[%w_]+$') ~= nil, 'name valid ' .. ipl)
        ok(seen[ipl] == nil, 'no duplicate ' .. ipl)
        seen[ipl] = group.id
    end
    for _, ipl in ipairs(group.remove or {}) do
        ok(ipl:match('^[%w_]+$') ~= nil, 'removal valid ' .. ipl)
    end
end

-- config covers exactly the groups (plus the master switch)
for key in pairs(Config.Interiors) do
    ok(key == 'Enabled' or ids[key] ~= nil, 'config key maps to a group ' .. key)
end
for _, group in ipairs(Data) do
    ok(Config.Interiors[group.id] ~= nil, 'group has a config toggle ' .. group.id)
end

-- boot (build 3095, no DLCs) --------------------------------------------------
-- gated out: bounties (3258), agents (3407), money_fronts / mansions / kortz (DLC);
-- off by default: north_yankton, ufo, red_carpet.
local skipped = {
    bounties = true, agents = true, money_fronts = true, mansions = true,
    kortz = true, north_yankton = true, ufo = true, red_carpet = true,
}
local expected = 0
for _, group in ipairs(Data) do
    if not skipped[group.id] then expected = expected + #group.ipls end
end
eq(#requested, expected, 'boot requests exactly the enabled, ungated IPLs')
eq(#removed, 2, 'boot runs the base removals')
eq(removed[1], 'dt1_05_hc_end', 'FIB fountain hole first')
eq(removed[2], 'dt1_05_hc_req', 'FIB fountain hole second')

local function has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end
ok(has(requested, 'FINBANK'), 'base fix FINBANK loads')
ok(has(requested, 'hei_carrier'), 'heist carrier loads')
ok(has(requested, 'vw_casino_main'), 'casino main shell loads')
ok(has(requested, 'tr_tuner_shop_burton'), 'tuner shops load')
ok(has(requested, 'rc12b_default'), 'pillbox default loads')
ok(not has(requested, 'prologue01'), 'north yankon stays off by default')
ok(not has(requested, 'ufo'), 'UFOs stay off by default')
ok(not has(requested, 'm24_1_carrier'), 'gated bounties carrier skipped on b3095')
ok(not has(requested, 'm25_1_bobcat'), 'DLC-gated money fronts skipped without the DLC')

-- runtime API ------------------------------------------------------------------
eq(Interiors.request('my_plugin_hideout'), true, 'request accepts a name')
ok(has(requested, 'my_plugin_hideout'), 'request forwards to RequestIpl')
eq(tracked['my_plugin_hideout'], 'test_plugin', 'request tracks the caller')
eq(Interiors.request('bad name!'), false, 'request rejects spaces/punctuation')
eq(Interiors.request(''), false, 'request rejects empty names')
eq(Interiors.request(string.rep('x', 97)), false, 'request rejects overlong names')
eq(Interiors.request(42), false, 'request rejects non-strings')

eq(Interiors.isActive('my_plugin_hideout'), true, 'isActive follows the stub state')
eq(Interiors.isActive('never_requested'), false, 'isActive is false for unknown IPLs')
eq(Interiors.isActive('nope!'), false, 'isActive rejects bad names')

eq(Interiors.remove('my_plugin_hideout'), true, 'remove unloads a plugin IPL')
ok(has(removed, 'my_plugin_hideout'), 'remove forwards to RemoveIpl')
eq(tracked['my_plugin_hideout'], nil, 'remove untracks')
eq(Interiors.remove('FINBANK'), false, 'remove refuses a base-set IPL for plugins')
ok(not has(removed, 'FINBANK'), 'refused removal never reaches RemoveIpl')
caller = 'core'
eq(Interiors.remove('my_plugin_hideout'), true, 'core itself may remove anything')
caller = 'test_plugin'

-- entity sets ------------------------------------------------------------------
interiorAt = 42
local setCoords = env.vector3(1100.0, 220.0, -50.0)
eq(Interiors.activateSet(setCoords, 'vw_dlc_casino_door'), true, 'activateSet resolves + activates')
eq(#activated, 1, 'one ActivateInteriorEntitySet call')
eq(activated[1][1], 42, 'activation targets the resolved interior')
eq(activated[1][2], 'vw_dlc_casino_door', 'activation names the set')
eq(#refreshed, 1, 'activation refreshes the interior')
eq(Interiors.activateSet('nope', 'x'), false, 'activateSet rejects non-vector coords')
eq(Interiors.activateSet(setCoords, 'bad set!'), false, 'activateSet rejects bad set names')

setActiveUpvalue = true
eq(Interiors.isSetActive(setCoords, 'vw_dlc_casino_door'), true, 'isSetActive reads the state')
interiorAt = 0
eq(Interiors.isSetActive(setCoords, 'vw_dlc_casino_door'), nil, 'isSetActive is nil with no interior')
-- timeout paths yield, so they run on stub threads with a ticked clock
local refreshResult, activateResult = 'pending', 'pending'
env.CreateThread(function() refreshResult = Interiors.refreshAt(setCoords) end)
env.CreateThread(function() activateResult = Interiors.activateSet(setCoords, 'x') end)
stubs.tick(6000)
eq(refreshResult, false, 'refreshAt fails with no interior')
eq(activateResult, false, 'activateSet times out with no interior')
interiorAt = 42

eq(Interiors.deactivateSet(setCoords, 'vw_dlc_casino_door'), true, 'deactivateSet works')
eq(deactivated[#deactivated][2], 'vw_dlc_casino_door', 'deactivation names the set')

-- owner sweep ------------------------------------------------------------------
eq(Interiors.request('sweep_me'), true, 'tracked IPL for the sweep')
removers.ipl('sweep_me')
ok(has(removed, 'sweep_me'), 'the ipl sweep unloads plugin IPLs')
local before = #removed
removers.ipl('FINBANK')
eq(#removed, before, 'the ipl sweep never touches base-set IPLs')

eq(Interiors.activateSet(setCoords, 'sweep_set'), true, 'tracked set for the sweep')
local deactBefore = #deactivated
removers.iplset(('%.2f:%.2f:%.2f:%s'):format(1100.0, 220.0, -50.0, 'sweep_set'))
eq(#deactivated, deactBefore + 1, 'the iplset sweep deactivates plugin sets')

-- diagnostics ------------------------------------------------------------------
local groups = Interiors.listGroups()
eq(#groups, 27, 'listGroups covers every group')
eq(groups[1].id, 'base', 'listGroups keeps data order')
ok(groups[1].count > 0, 'listGroups carries IPL counts')
local byId = {}
for _, g in ipairs(groups) do byId[g.id] = g end
eq(byId.north_yankton.enabled, false, 'disabled group reports off')
eq(byId.bounties.gated, true, 'build-gated group reports gated on b3095')
eq(byId.money_fronts.gated, true, 'DLC-gated group reports gated without the DLC')
eq(byId.base.gated, false, 'base is neither gated nor off')

print(('interiors: %d passed'):format(passed))
