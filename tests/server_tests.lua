--[[
    core/tests/server_tests.lua — the offline test suite for server/**.

        lua5.4 tests/server_tests.lua    (from the resource directory, or from tests/)

    The runner only: shared helpers live in tests/server_harness.lua, and each of the
    suites is its own file under tests/server/<name>.lua (each `return function(H) ... end`,
    given the harness table so several people can edit different suites in parallel). Same
    harness as run_tests.lua: every native and runtime helper comes from tests/stubs.lua, so
    this proves the pure Lua contracts of DESIGN §4, §5 and §8 — never in-game behaviour.
    Exit code is 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/server_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
local H = dofile(here .. '/server_harness.lua')

--------------------------------------------------------------------------------
-- suites (same order the runner used to run them in; playergrid stays last: it
-- leaves several VMs, and their refresh threads, behind on purpose)
--------------------------------------------------------------------------------

local suiteFiles = {
    { 'db', 'db' },
    { 'globals', 'globals' },
    { 'chat', 'chat' },
    { 'perms', 'perms' },
    { 'player', 'player' },
    { 'player admin', 'player_admin' },
    { 'admin ranks', 'admin_ranks' },
    { 'legacy commands', 'legacy_commands' },
    { 'money', 'money' },
    { 'factions', 'factions' },
    { 'vehicles', 'vehicles' },
    { 'api', 'api' },
    { 'ui', 'ui' },
    { 'ui plugins', 'ui_plugins' },
    { 'stats', 'stats' },
    { 'world', 'world' },
    -- last: this suite leaves several VMs (and their refresh threads) behind on purpose
    { 'playergrid', 'playergrid' },
}

local suites = {}
for i = 1, #suiteFiles do
    local name, file = suiteFiles[i][1], suiteFiles[i][2]
    local factory = dofile(here .. '/server/' .. file .. '.lua')
    suites[i] = { name, factory(H) }
end

--------------------------------------------------------------------------------
-- runner
--------------------------------------------------------------------------------

local perSuite = {}
for i = 1, #suites do
    local name, fn = suites[i][1], suites[i][2]
    local passedBefore, failedBefore = H.passed, H.failed
    local ok, err = pcall(fn)
    if not ok then
        H.suiteName = name
        H.check(false, 'the suite crashed', tostring(err))
    end
    perSuite[#perSuite + 1] = ('  %-16s %4d passed, %d failed'):format(name, H.passed - passedBefore, H.failed - failedBefore)
end

print('\nper suite:\n' .. table.concat(perSuite, '\n'))
print(('\n%d passed, %d failed'):format(H.passed, H.failed))
if H.failed > 0 then
    print(('%d failing check(s):'):format(#H.failures))
    for i = 1, #H.failures do print('  ' .. H.failures[i]:gsub('\n%s+', ' -- ')) end
    os.exit(1)
end
os.exit(0)
