-- Offline form/menu schema and bridge regressions.
local here = (arg and arg[0] or 'tests/ui_forms_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
local passed = 0
local function check(value, message) assert(value, message); passed = passed + 1 end
local function fresh(side)
    stubs.newWorld(); stubs.clear(); stubs.resetNui(); stubs.tick(1000)
    local env = stubs.newEnv(side, 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    stubs.loadFile(env, 'shared/ui_forms.lua')
    stubs.loadFile(env, side .. '/api.lua')
    return env, env.Core
end
local env, core = fresh('client')
local forms = core.UIForms
local fields = forms.fields({
    { name = 'text', type = 'textarea', minLength = 2, maxLength = 5 },
    { name = 'secret', type = 'password', required = true },
    { name = 'amount', type = 'slider', min = 1, max = 9, step = 2 },
    { name = 'choice', type = 'select', searchable = true, required = true, options = { false, 'a' } },
    { name = 'many', type = 'select', multiple = true, options = { { label = 'A', value = 'a' }, false } },
    { name = 'checked', type = 'checkbox', required = true },
    { name = 'day', type = 'date' }, { name = 'clock', type = 'time' }, { name = 'tint', type = 'color' },
})
check(fields and fields[5].type == 'multiselect' and fields[4].searchable, 'schema aliases and options')
local answer = { text = 'hello', secret = ' p ', amount = 3, choice = false, many = { false, 'a' },
    checked = true, day = '2024-02-29', clock = '23:59', tint = '#aBc123' }
local result = forms.answer(fields, answer)
check(result and result.choice == false and result.checked == true and result.secret == ' p ', 'valid rich form preserves false/password')
local function rejects(key, value, message)
    local previous = answer[key]; answer[key] = value
    check(forms.answer(fields, answer) == nil, message)
    answer[key] = previous
end
rejects('text', 'x', 'minimum length')
rejects('text', 'toolong', 'maximum length')
rejects('secret', '', 'required text')
rejects('amount', 10, 'numeric bounds')
rejects('amount', 4, 'step alignment')
rejects('amount', '3', 'numeric type strict')
rejects('amount', math.huge, 'finite number required')
rejects('choice', 'other', 'membership')
rejects('many', { 'a', 'a' }, 'multi duplicates')
rejects('many', { 'missing' }, 'multi membership')
rejects('many', { [1] = 'a', extra = false }, 'multi unknown keys')
rejects('checked', nil, 'required checkbox must be supplied')
rejects('checked', false, 'required checkbox must be checked')
rejects('checked', 1, 'checkbox type strict')
rejects('day', '2023-02-29', 'invalid leap day')
rejects('day', '2024-04-31', 'invalid month day')
rejects('clock', '24:00', 'invalid hour')
rejects('clock', '12:60', 'invalid minute')
rejects('tint', 'red', 'color format')
answer.unknown = true
check(forms.answer(fields, answer) == nil, 'unknown fields rejected')
answer.unknown = nil
check(forms.fields({ { name = 'x' }, { name = 'x' } }) == nil, 'duplicate field names rejected')
check(forms.fields({ { name = 'x', type = 'number', min = 10, max = 1 } }) == nil, 'invalid bounds rejected')
check(forms.fields({ { name = 'x', type = 'select', options = { 'a' }, default = 'b' } }) == nil, 'default membership enforced')
check(forms.fields({ { name = 'x', type = 'multi-select', options = { false }, default = { false } } }) ~= nil, 'false multiselect default')

local defaultFields = forms.fields({
    { name = 'accept', type = 'checkbox', required = true, default = false },
    { name = 'name', required = true, minLength = 3, default = '' },
    { name = 'short', minLength = 3, default = 'a' },
    { name = 'many', type = 'multiselect', options = { false, 'a' }, required = true, default = {} },
    { name = 'day', type = 'date', required = true, default = '' },
})
check(defaultFields ~= nil, 'incomplete defaults may open')
check(defaultFields[1].default == false and defaultFields[2].default == '', 'incomplete defaults preserved')
check(forms.answer(defaultFields, { accept = false, name = '', short = 'a', many = {}, day = '' }) == nil,
    'incomplete defaults still rejected on submission')
check(forms.answer(defaultFields, { accept = true, name = 'Name', short = 'abc', many = { false }, day = '2024-01-01' }) ~= nil,
    'completed defaults may submit')
local defaultList = { false, 'a' }
local copiedDefaults = forms.fields({ { name = 'x', type = 'multiselect', options = { false, 'a' }, default = defaultList } })
defaultList[2] = 'changed'
check(copiedDefaults[1].default[1] == false and copiedDefaults[1].default[2] == 'a', 'defaults detached and false preserved')
for _, bad in ipairs({ { [1] = 'a', [3] = false }, { [2] = 'a' }, { [1] = 'a', extra = false },
    { 'a', 'a' }, { {} }, setmetatable({ 'a' }, {}), 'a', false }) do
    check(forms.fields({ { name = 'x', type = 'multiselect', options = { false, 'a' }, default = bad } }) == nil,
        'malformed multiselect default rejected')
end
check(forms.fields({ { name = 'x', type = 'number', default = {} } }) == nil, 'wrong default type not silently dropped')
check(forms.fields({ { name = 'x', default = function() end } }) == nil, 'callable default rejected')
check(forms.fields({ { name = 'x', type = 'number', min = 1, default = 0 } }) == nil, 'default numeric bounds remain strict')
check(forms.fields({ { name = 'x', type = 'number', default = math.huge } }) == nil, 'nonfinite default rejected')
check(forms.fields({ { name = 'x', maxLength = 3, default = 'long' } }) == nil, 'default maximum length remains strict')
check(forms.fields({ { name = 'x', type = 'date', default = '2023-02-29' } }) == nil, 'nonempty default format remains strict')

local original = { tag = true }
local wire, records = forms.menu({ { label = 'Parent', items = {
    { label = 'Child', value = original, metadata = { { label = 'Rank', value = 3 } }, progress = 40 },
} }, { label = 'Toggle', value = false, checked = false },
    { label = 'Choices', values = { { label = 'No', value = false }, { label = 'Yes', value = original } } } })
check(wire and wire[1].items[1].value == 2 and wire[2].value == 3, 'nested stable row ids')
check(forms.menuValue(records, 2) == original and forms.menuValue(records, 3) == false, 'Lua-only values retained')
check(forms.menuValue(records, 1) == nil and forms.menuValue(records, 9) == nil, 'parent and unknown cannot select')
local changed, _, value = forms.menuChange(records, { value = 4, selected = 1 })
check(changed and value == false, 'side scroll false preserved')
changed, _, value = forms.menuChange(records, { value = 4, selected = 2 })
check(changed and value == original, 'side scroll arbitrary Lua value preserved')
check(not forms.menuChange(records, { value = 4, selected = 3 }), 'scroll bound')
check(not forms.menuChange(records, { value = 0 / 0, selected = 1 }), 'nan row id rejected')
check(not forms.menuChange(records, { value = {}, selected = 1 }), 'table row id rejected')
check(not forms.menuChange(records, { value = 3, checked = 'yes' }), 'checked type')
check(forms.menuChange(records, { value = 3, checked = true }), 'checkbox update')
local _, disabled = forms.menu({ { label = 'Disabled', disabled = true, items = { { label = 'Child', checked = true } } } })
check(forms.menuValue(disabled, 2) == nil and not forms.menuChange(disabled, { value = 2, checked = false }), 'disabled ancestors enforce')

stubs.loadFile(env, 'client/ui.lua')
stubs.nui('ui_ready', {})
local function last(action)
    local messages = stubs.nuiOf(action)
    return messages[#messages]
end
local returned, changedValue
core.Registry.setCaller('test_owner')
env.CreateThread(function()
    returned = core.UI.menu.open({ items = { { label = 'Toggle', value = false, checked = false,
        onChange = function(v, state) changedValue = { v, state } end } } })
end)
local id = last('menu:open').id
stubs.nui('menu_change', { id = id, value = 1, checked = true })
check(changedValue and changedValue[1] == false and changedValue[2] == true, 'client onChange validated callback')
stubs.nui('menu_result', { id = id, value = 1 }); stubs.tick(1)
check(returned == false, 'client false menu result preserved')
env.CreateThread(function() returned = core.UI.input.open({ fields = { { name = 'x', type = 'number', max = 3 } } }) end)
stubs.nui('input_result', { id = last('input:open').id, values = { x = 7 } }); stubs.tick(1)
check(returned == nil, 'client rejects out-of-bounds rather than clamps')
local cancelled = 'pending'
core.Registry.setCaller('stop_owner')
env.CreateThread(function() cancelled = core.UI.alert({ message = 'test' }) end)
env.TriggerEvent('onResourceStop', 'stop_owner'); stubs.tick(1)
check(cancelled == false and not stubs.nuiFocus.focus, 'owner stop cancels modal and releases focus')
local token = {}
env.CreateThread(function() core.UI.progress({ duration = 1000, _actionToken = token }) end)
check(not core.UIInternal.cancelManagedProgress({}), 'foreign token cannot cancel progress')
check(core.UIInternal.cancelManagedProgress(token), 'managed token cancels own progress')
stubs.tick(1)

-- A remote menu acknowledges only after the server answers. Rejections never become UI success.
local remoteAccepted = false
core.Callback.await = function(name, token, data)
    check(name == 'core:ui:menuChange' and token == 50, 'change forwards current remote token')
    check(data.checked == true, 'change forwards requested checked state')
    env.Wait(150)
    return remoteAccepted
end
env.CreateThread(function()
    core.UI.menu.open({ _menuToken = 50, items = { { label = 'Remote', checked = false } } })
end)
local remoteId = last('menu:open').id
local first, acks = stubs.nui('menu_change', { id = remoteId, value = 1, checked = true })
check(first == nil and #acks == 0, 'no optimistic acknowledgement while remote is pending')
local rejectedBusy = stubs.nui('menu_change', { id = remoteId, value = 1, checked = false })
check(rejectedBusy.ok == false, 'pending remote change blocks overlap')
stubs.tick(151)
check(#acks == 1 and acks[1].ok == false, 'remote rejection reaches browser exactly once')
remoteAccepted = true
local _, acceptedAcks = stubs.nui('menu_change', { id = remoteId, value = 1, checked = true })
stubs.tick(151)
check(#acceptedAcks == 1 and acceptedAcks[1].ok == true, 'remote acceptance reaches browser after completion')
remoteAccepted = nil
local _, unknownAcks = stubs.nui('menu_change', { id = remoteId, value = 1, checked = true })
stubs.tick(151)
check(#unknownAcks == 1 and unknownAcks[1].ok == false, 'unknown remote outcome does not acknowledge success')
check(last('menu:close').id == remoteId and not stubs.nuiFocus.focus, 'unknown outcome closes uncertain menu and releases focus')

local server, serverCore = fresh('server')
local submitted, callbacks = nil, {}
server.GetPlayerName = function() return 'Tester' end
serverCore.Callback = { register = function(name, _, fn) callbacks[name] = fn end, awaitClientTimeout = function(_, _, _, opts)
    check(opts.fields[1].type == 'multiselect', 'server forwards normalized rich schema')
    return submitted
end }
stubs.loadFile(server, 'server/ui.lua')
submitted = { picks = { false } }
local options = { fields = { { name = 'picks', type = 'multiselect', options = { false, 'a' }, required = true } } }
check(serverCore.UI.input.open(1, options).picks[1] == false, 'server validates valid multiselect')
submitted = { picks = { 'bad' } }
check(serverCore.UI.input.open(1, options) == nil, 'server independently rejects forged membership')
local changes = 0
local originalValue = { token = 'only Lua' }
serverCore.Registry.setCaller('server_owner')
serverCore.Callback.awaitClientTimeout = function(src, name, _, opts)
    check(name == 'core:ui:menu' and src == 1, 'server menu uses scoped callback transport')
    local change = callbacks['core:ui:menuChange']
    check(not change(2, opts._menuToken, { value = 1, checked = true }), 'wrong player denied')
    check(not change(1, opts._menuToken + 1, { value = 1, checked = true }), 'stale token denied')
    check(not change(1, opts._menuToken, { value = 1, checked = 'yes' }), 'forged state denied')
    check(change(1, opts._menuToken, { value = 1, checked = true }), 'valid server change accepted')
    check(not change(1, opts._menuToken, { value = 1, checked = false }), 'rapid server changes throttled')
    return opts.items[2].items[1].value
end
local resultValue = serverCore.UI.menu.open(1, { items = {
    { label = 'Check', value = false, checked = false, onChange = function(v, state)
        check(v == false and state == true, 'server callback receives original values')
        check(serverCore.Registry.getCaller() == 'server_owner', 'server callback preserves owner')
        changes = changes + 1
    end },
    { label = 'Submenu', items = { { label = 'Value', value = originalValue } } },
} })
check(resultValue == originalValue and changes == 1, 'server nested selection maps private value')
check(not callbacks['core:ui:menuChange'](1, 1, { value = 1, checked = true }), 'completed menu rejects late changes')
local yieldedFinished, returnedOwner = false, nil
serverCore.Callback.awaitClientTimeout = function(_, _, _, opts)
    serverCore.Registry.setCaller('unrelated')
    server.CreateThread(function()
        check(callbacks['core:ui:menuChange'](1, opts._menuToken, { value = 1, checked = true }),
            'yielding server callback finishes successfully')
        returnedOwner = serverCore.Registry.getCaller()
    end)
    check(serverCore.Registry.getCaller() == 'unrelated', 'yielding callback does not leak owner globally')
    stubs.tick(101)
    check(not callbacks['core:ui:menuChange'](1, opts._menuToken, { value = 1, checked = false }),
        'busy callback blocks overlap beyond throttle window')
    stubs.tick(101)
    check(yieldedFinished and returnedOwner == 'unrelated', 'completed callback restores coroutine caller')
    serverCore.Registry.setCaller('server_owner')
    return 1
end
check(serverCore.UI.menu.open(1, { items = { { label = 'Yield', checked = false, onChange = function()
    check(serverCore.Registry.getCaller() == 'server_owner', 'yielding callback enters owner context')
    server.Wait(200)
    check(serverCore.Registry.getCaller() == 'server_owner', 'owner context survives yield')
    yieldedFinished = true
end } } }) == 'Yield', 'yielding menu callback preserves selection')
serverCore.Callback.awaitClientTimeout = function(_, _, _, opts)
    server.TriggerEvent('onResourceStop', 'server_owner')
    check(not callbacks['core:ui:menuChange'](1, opts._menuToken, { value = 1, checked = true }), 'stopped owner denies changes')
    return 1
end
check(serverCore.UI.menu.open(1, { items = { { label = 'Check', checked = false } } }) == nil,
    'stopped owner cannot resolve remote selection')
local sent = stubs.sent[#stubs.sent]
check(sent and sent.name == 'core:client:ui', 'owner stop sends close through existing UI channel')
print(('ui forms: %d passed, 0 failed'):format(passed))
