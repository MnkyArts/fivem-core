--[[
    core/tests/admin_api_tests.lua — offline suite for Core.Admin (DESIGN §51): registrations + ownership,
    the owner sweep, every dispatch step of Admin.run and its audit row, target kinds and selectors,
    snapshot filtering, duty and modes (state bags, audit, drop), staff echo, the debounced
    snapshotChanged, the transport callbacks, chat command generation and Security.isStaffExempt.

        lua5.4 tests/admin_api_tests.lua    (from the resource directory, or from tests/)

    Same harness as perms_tests.lua: natives from tests/stubs.lua, one real core server VM per suite
    (import.lua, shared/config.lua, then the server modules in manifest order, audit.lua included).
    Exit code 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/admin_api_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test helpers
local H = assert(loadfile(here .. '/admin_harness.lua'))(here)
local stubs, vector3, xtype = H.stubs, H.vector3, H.xtype
local suite, show, check, eq, printed, sends = H.suite, H.show, H.check, H.eq, H.printed, H.sends
local hasFunction, newServer, as, callServer, rows, def = H.hasFunction, H.newServer, H.as, H.callServer, H.rows, H.def

--------------------------------------------------------------------------------
-- suites
--------------------------------------------------------------------------------

--- Definition validation and the defaults of §51.
local function suiteRegister()
    suite('register')
    local env, Core = newServer()
    local A = Core.Admin
    local function refused(d, err, label)
        local ok, e = A.action(d)
        check(ok == false and e == err, label, ('expected false, %s; got %s, %s'):format(err, show(ok), show(e)))
    end
    refused('x', 'definition', 'a non-table definition')
    refused(def('bad id'), 'id', 'an id with a space')
    refused(def(('x'):rep(65)), 'id', 'an id over 64 characters')
    refused(def('t.nolabel', { label = '' }), 'label', 'an empty label')
    refused(def('t.nocat', { category = 'no cat' }), 'category', 'a bad category id')
    refused(def('t.nohandler', { handler = 'nope' }), 'handler', 'a non-callable handler')
    refused(def('t.target', { target = 'vehicle' }), 'target', 'an unknown target kind')
    refused(def('t.reason', { reason = 'maybe' }), 'reason', 'an unknown reason policy')
    refused(def('t.danger', { danger = 'high' }), 'danger', 'an unknown danger level')
    refused(def('t.max', { target = 'players', max = 0 }), 'max', 'max 0')
    refused(def('t.max2', { target = 'players', max = 2001 }), 'max', 'max above 2000')
    refused(def('t.max3', { target = 'player', max = 3 }), 'max', "'player' is always max 1")
    refused(def('t.cool', { cooldown = -1 }), 'cooldown', 'a negative cooldown')
    refused(def('t.cmd', { command = 'two words' }), 'command', 'a command with a space')
    refused(def('t.self', { self = 'yes' }), 'self', 'a non-boolean self')
    refused(def('t.perm', { permission = 'bad perm' }), 'permission', 'a bad permission')
    refused(def('t.' .. ('x'):rep(60)), 'permission', "an id whose default permission exceeds 64 characters")
    local ok, err = A.action(def('t.args', { args = { { name = 'n', type = 'nope' } } }))
    check(ok == false and tostring(err):find('^args:') ~= nil, 'a bad args schema is refused', show(err))

    -- defaults
    eq(A.action(def('t.plain', { target = 'players' })), true, 'a minimal action registers')
    local snap = A.snapshot(0)
    local entry
    for i = 1, #snap.actions do if snap.actions[i].id == 't.plain' then entry = snap.actions[i] end end
    check(entry ~= nil, 'the console snapshot lists it')
    eq(entry and entry.permission, 'admin.t.plain', "permission defaults to 'admin.' .. id")
    eq(entry and entry.max, 50, "'players' max defaults to 50")
    eq(entry and entry.self, true, 'self defaults to true')
    eq(entry and entry.hierarchy, true, 'hierarchy defaults to true')
    eq(entry and entry.duty, true, 'duty defaults to Config.Admin.RequireDuty')
    eq(entry and entry.echo, true, 'echo defaults to true')
    eq(entry and entry.cooldown, 1, 'cooldown defaults to 1 s')
    eq(entry and entry.reason, 'none', "reason defaults to 'none'")
    eq(entry and entry.danger, 'none', "danger defaults to 'none'")
    eq(entry and entry.owner, 'core', 'the owner is the caller')
    local cat
    for _, c in ipairs(Core.Perms.catalogue()) do if c.perm == 'admin.t.plain' then cat = c end end
    eq(cat and cat.default, 'admin', 'the permission is Perms.define\'d with default admin')
    eq(Core.Perms.has(2, 'admin.t.plain'), true, 'the admin group received it')
    eq(Core.Perms.has(3, 'admin.t.plain'), false, 'the mod group did not')
    eq(A.action(def('t.mod', { default = 'mod' })), true, 'default = mod')
    eq(Core.Perms.has(3, 'admin.t.mod'), true, 'the mod group received that one')
    eq(A.action(def('t.nodef', { default = false, permission = 'custom.perm' })), true, 'default = false')
    eq(Core.Perms.has(2, 'custom.perm'), false, 'no group received the permission')

    -- a callable table handler (a function crossing the export hop)
    local callable = setmetatable({}, { __call = function() return true end })
    eq(A.action(def('t.callable', { handler = callable })), true, 'a callable table is a handler')

    -- categories, pages and player tabs
    eq(A.category({ id = 'players', label = 'Players', order = 10 }), true, 'a category registers')
    eq(select(2, A.category({ id = 'x', label = 5 })), 'label', 'a category needs a label')
    eq(select(2, A.page({ id = 'p1', label = 'P' })), 'page_or_provider', 'a page needs page or provider')
    eq(select(2, A.page({ id = 'p1', label = 'P', page = 'bad page' })), 'page', 'a page id is checked')
    eq(select(2, A.page({ id = 'p1', label = 'P', provider = 'x' })), 'provider', 'a provider must be callable')
    eq(select(2, A.page({ id = 'p1', label = 'P', page = 'inv:viewer' })), 'page', "a page id with ':' is refused")
    eq(select(2, A.page({ id = 'p1', label = 'P', page = 'inv.viewer' })), 'page', "a page id with '.' is refused")
    eq(select(2, A.page({ id = 'p1', label = 'P', page = ('v'):rep(65) })), 'page', 'a page id over 64 characters')
    eq(select(2, A.playerTab({ id = 't1', label = 'T', page = 'inv:tab' })), 'page', "a tab's page id is checked too")
    eq(A.page({ id = 'p1', label = 'P', page = 'inv_viewer-2' }), true, 'a plain UI page id registers')
    eq(A.playerTab({ id = 'tab1', label = 'Tab', provider = function() return {} end }), true, 'a player tab registers')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- First registrant owns an id; the same owner replaces; the owner sweep removes everything.
local function suiteOwnership()
    suite('ownership')
    local env, Core = newServer()
    local A = Core.Admin
    A.setDuty(1, true)
    A.setDuty(4, true)
    stubs.tick(2000)
    eq(as('pluginA', 'category', { id = 'plug', label = 'Plugin' }), true, 'pluginA registers a category')
    eq(as('pluginA', 'action', def('plug.do', { category = 'plug', label = 'Do', command = 'plugdo' })), true,
        'pluginA registers an action')
    eq(as('pluginA', 'page', { id = 'plug.page', label = 'Page', page = 'plug_page' }), true, 'and a page')
    eq(as('pluginA', 'playerTab', { id = 'plug.tab', label = 'Tab', page = 'plug_tab' }), true, 'and a tab')
    local ok, err = as('pluginB', 'action', def('plug.do', { label = 'Stolen' }))
    check(ok == false and err == 'owned', 'another owner cannot take the id', show(err))
    eq(select(2, as('pluginB', 'category', { id = 'plug', label = 'X' })), 'owned', 'nor a category id')
    eq(as('pluginA', 'action', def('plug.do', { category = 'plug', label = 'Do again', command = 'plugdo' })), true,
        'the owner replaces its own entry')
    local snap = A.snapshot(0)
    local label
    for i = 1, #snap.actions do if snap.actions[i].id == 'plug.do' then label = snap.actions[i].label end end
    eq(label, 'Do again', 'the replacement is live')
    local owned = Core.Registry.getOwned('pluginA')
    check(owned and owned.adminAction and owned.adminAction['plug.do'], 'Registry tracks kind adminAction')
    check(owned and owned.adminCategory and owned.adminPage and owned.adminPlayerTab, 'and the other three kinds')

    local mark = #stubs.sent + 1
    stubs.triggerOn(env, 'onResourceStop', 0, 'pluginA')
    snap = A.snapshot(0)
    local left = 0
    for i = 1, #snap.actions do if snap.actions[i].id == 'plug.do' then left = left + 1 end end
    eq(left, 0, 'the sweep removed the action')
    eq(#snap.pages + #snap.playerTabs, 0, 'and the page and the tab')
    local okRun, code = A.run(0, 'plug.do', {})
    check(okRun == false and code == 'unknown_action', 'running it now is unknown_action')
    local command = env.__vm.commands.plugdo
    check(command ~= nil, 'the chat command had been bound')
    command.fn(1, {}, '/plugdo')
    check(#sends('core:client:notify', 1, mark) >= 1, 'the stale command answers instead of dispatching')
    eq(as('pluginB', 'action', def('plug.do', { label = 'Now mine' })), true, 'the id is free for another owner')
    stubs.tick(1000)
    eq(#sends('core:admin:snapshotChanged', 4, mark), 1, 'staff got ONE debounced snapshotChanged')
    eq(#sends('core:admin:snapshotChanged', 5, mark), 0, 'a non-staff player got none')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- Admin.run, step by step, with the audit row each refusal writes.
local function suiteDispatch()
    suite('dispatch')
    local env, Core = newServer()
    local A = Core.Admin
    local seen
    A.action(def('t.kick', { target = 'player', reason = 'required', danger = 'confirm', default = 'mod',
        args = { { name = 'note', type = 'string', maxLength = 16 }, { name = 'level', type = 'integer', min = 1, max = 3, default = 2 } },
        handler = function(ctx)
            seen = ctx
            return true, 'kicked', { changes = { { key = 'kicked', old = false, new = true } }, extra = 7 }
        end }))
    local function denied(code, label)
        local row = rows(Core, 't.kick')[1]
        check(row and row.result == 'denied' and row.message == code, label .. ' (audit row)',
            ('got %s / %s'):format(show(row and row.result), show(row and row.message)))
        return row
    end
    local good = { targets = { 5 }, reason = 'being rude', confirm = true }

    -- the per-actor budget persists one denied row per 5 s: each audited refusal below starts fresh
    local function fresh() stubs.tick(5000) end

    -- 1 action exists
    local ok, code = A.run(2, 'nope.nothing', good)
    check(ok == false and code == 'unknown_action', '1: an unknown id is refused')
    local row = rows(Core, 'core.admin.unknown')[1]
    check(row and row.result == 'denied' and row.message == 'unknown_action', '1: audited as core.admin.unknown (staff)')
    eq(row and row.ctx and row.ctx.requested, 'nope.nothing', '1: naming the requested id')
    local unknownRows = #rows(Core, 'core.admin.unknown')
    fresh()
    A.run(5, 'nope.other', good)
    eq(#rows(Core, 'core.admin.unknown'), unknownRows, '1: a non-staff unknown_action is only logged')
    -- 2 actor loaded (console allowed)
    local before2 = #rows(Core, 't.kick')
    eq(select(2, A.run(42, 't.kick', good)), 'not_loaded', '2: an unknown src is refused')
    eq(select(2, A.run('1', 't.kick', good)), 'not_loaded', '2: a non-integer actor is refused')
    eq(#rows(Core, 't.kick'), before2, '2: not_loaded of a non-staff actor is only logged')
    -- 3 permission
    fresh()
    eq(select(2, A.run(4, 't.kick', good)), 'no_permission', '3: a helper lacks the mod permission')
    local r3 = denied('no_permission', '3')
    eq(r3 and r3.actor and r3.actor.src, 4, '3: the row names the actor')
    eq(r3 and r3.ctx and r3.ctx.step, 'permission', '3: and the step')
    -- 4 duty (console exempt)
    eq(select(2, A.run(3, 't.kick', good)), 'off_duty', '4: off duty is refused')
    denied('off_duty', '4')
    A.setDuty(3, true)
    A.setDuty(2, true)
    -- 6 args (before 5: a refused request does not burn the cooldown)
    fresh()
    eq(select(2, A.run(3, 't.kick', { targets = { 5 }, reason = 'being rude', confirm = true, args = { note = 5 } })),
        'invalid_args', '6: a bad arg type is refused')
    local r6 = denied('invalid_args', '6')
    check(r6 and r6.ctx and r6.ctx.detail ~= nil, '6: the schema errors are in ctx.detail')
    eq(select(2, A.run(3, 't.kick', { targets = { 5 }, reason = 'x y z', confirm = true, args = { bogus = 1 } })),
        'invalid_args', '6: an unknown arg is refused')
    -- 7 reason policy
    fresh()
    eq(select(2, A.run(3, 't.kick', { targets = { 5 }, confirm = true })), 'reason_required', '7: a missing reason')
    denied('reason_required', '7')
    eq(select(2, A.run(3, 't.kick', { targets = { 5 }, confirm = true, reason = 'no' })), 'invalid_reason',
        '7: a reason under 3 characters')
    eq(select(2, A.run(3, 't.kick', { targets = { 5 }, confirm = true, reason = ('r'):rep(300) })), 'invalid_reason',
        '7: a reason over 256 characters')
    -- 8 targets (details in suiteTargets); a refused target costs the cooldown
    fresh()
    eq(select(2, A.run(3, 't.kick', { targets = { 2 }, reason = 'being rude', confirm = true })), 'rank',
        '8: a mod cannot act on an admin')
    local r8 = denied('rank', '8')
    eq(r8 and r8.targets and r8.targets[1] and r8.targets[1].name, 'Ada', '8: the row lists the target by name')
    eq(select(2, A.run(3, 't.kick', { targets = { 5 }, reason = 'being rude', confirm = true })), 'cooldown',
        '8: the target refusal stamped the action cooldown')
    -- 9 confirm
    fresh()
    eq(select(2, A.run(3, 't.kick', { targets = { 5 }, reason = 'being rude' })), 'confirm_required',
        "9: danger 'confirm' needs confirm = true")
    denied('confirm_required', '9')
    -- 10 admin:before veto (filtered by id)
    local hookId = Core.Hooks.register('admin:before', function(p)
        if p.targets[1] == 6 then return false, 'protected' end
        return true
    end, { filter = function(p) return p.id == 't.kick' end })
    fresh()
    eq(select(2, A.run(3, 't.kick', { targets = { 6 }, reason = 'being rude', confirm = true })), 'vetoed',
        '10: an admin:before hook vetoes')
    local r10 = denied('vetoed', '10')
    eq(r10 and r10.ctx and r10.ctx.detail, 'protected', '10: with the hook reason')
    Core.Hooks.remove(hookId)
    fresh()

    -- 11-14: the handler runs
    local observed
    Core.on('adminAction', function(p) observed = p end)
    A.setDuty(4, true)
    local mark = #stubs.sent + 1
    local okRun, result = A.run(3, 't.kick', { targets = { 5 }, reason = '  being rude ', confirm = true,
        args = { note = 'n1' }, source = 'palette' })
    eq(okRun, true, '11: the handler ran')
    eq(result and result.message, 'kicked', '11: its message comes back')
    eq(result and result.data and result.data.extra, 7, '11: and its data')
    eq(seen and seen.actor, 3, '11: ctx.actor')
    eq(seen and seen.targets and seen.targets[1], 5, '11: ctx.targets (src)')
    eq(seen and seen.args and seen.args.level, 2, '11: ctx.args with the default filled')
    eq(seen and seen.reason, 'being rude', '11: ctx.reason trimmed')
    eq(seen and seen.source, 'palette', '11: ctx.source')
    eq(seen and seen.id, 't.kick', '11: ctx.id')
    local ok12 = rows(Core, 't.kick')[1]
    eq(ok12 and ok12.result, 'ok', '12: an ok row')
    eq(ok12 and ok12.source, 'palette', '12: with the source')
    eq(ok12 and ok12.reason, 'being rude', '12: and the reason')
    eq(ok12 and ok12.changes and ok12.changes[1] and ok12.changes[1].key, 'kicked', '12: data.changes are recorded')
    eq(ok12 and ok12.targets and ok12.targets[1].name, 'Uma', '12: the target by name')
    local echoes = sends('core:admin:echo', nil, mark)
    eq(#echoes, 2, '13: the echo reached the two other on-duty staff')
    local toActor = sends('core:admin:echo', 3, mark)
    eq(#toActor, 0, '13: not the actor')
    local payload = echoes[1] and echoes[1].args[1]
    check(payload and payload.text:find('Moe: Act t.kick', 1, true) and payload.text:find('Uma (5)', 1, true),
        '13: the echo text names actor, label and target', payload and payload.text)
    eq(observed and observed.id, 't.kick', '14: the adminAction hook fired')
    eq(observed and observed.result, 'ok', '14: with the result')

    -- 5 cooldown: never audited
    local before = #rows(Core, 't.kick')
    eq(select(2, A.run(3, 't.kick', { targets = { 5 }, reason = 'being rude', confirm = true })), 'cooldown',
        '5: a second run inside the cooldown is refused')
    eq(#rows(Core, 't.kick'), before, '5: without an audit row')
    stubs.tick(1000)
    eq(A.run(3, 't.kick', { targets = { 5 }, reason = 'being rude', confirm = true }), true, '5: after 1 s it runs')
    eq(A.run(0, 't.kick', { targets = { 5 }, reason = 'console', confirm = true }), true,
        '2/4: the console runs without session or duty')
    eq(rows(Core, 't.kick')[1].source, 'console', "the console's default source is 'console'")

    -- handler failure and error
    A.action(def('t.fail', { handler = function() return false, 'nothing to do' end }))
    A.action(def('t.throw', { handler = function() error('boom') end }))
    local okF, msgF = A.run(2, 't.fail')
    check(okF == false and msgF == 'nothing to do', 'a handler returning false fails with its message')
    eq(rows(Core, 't.fail')[1].result, 'error', "and is audited as 'error'")
    local okT, msgT = A.run(2, 't.throw')
    check(okT == false and msgT == 'error', 'a throwing handler is caught')
    eq(rows(Core, 't.throw')[1].result, 'error', "and audited as 'error'")
    check(printed('t.throw') ~= nil, 'and logged')
    stubs.tick(1000)
    eq(select(2, A.run(2, 't.fail', { args = { a = 1 } })), 'invalid_args', 'args to an action without args')

    -- denied rows: one per (actor, action) per 5 s; unknown ids share one budget per actor (R2-14)
    fresh()
    local kickRows, failRows = #rows(Core, 't.kick'), #rows(Core, 't.fail')
    A.run(5, 't.kick', good)
    A.run(5, 't.kick', good)
    A.run(5, 't.fail')
    eq(#rows(Core, 't.kick'), kickRows + 1, 'two refusals of one action inside 5 s write one row')
    eq(#rows(Core, 't.fail'), failRows + 1, 'a refusal on another action is never hidden by it')
    fresh()
    A.run(5, 't.kick', good)
    local r = rows(Core, 't.kick')[1]
    eq(r and r.ctx and tonumber(r.ctx.suppressed), 1, "the action's next row reports its suppressed count")
    -- a cheap refusal cannot mask the attempt that matters (different actions)
    fresh()
    A.run(2, 't.fail', { args = { junk = 1 } })
    A.run(2, 't.kick', { targets = { 1 }, reason = 'owner', confirm = true })
    eq(rows(Core, 't.fail')[1].message, 'invalid_args', 'the cheap refusal is recorded')
    eq(rows(Core, 't.kick')[1].message, 'rank', '... and so is the rank refusal right after it')
    -- unknown ids: one budget per actor, whatever the id
    fresh()
    local unknown = #rows(Core, 'core.admin.unknown')
    A.run(2, 'nope.a')
    A.run(2, 'nope.b')
    A.run(2, 'nope.c')
    eq(#rows(Core, 'core.admin.unknown'), unknown + 1, 'cycling unknown ids writes one row per 5 s')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- Target kinds: selectors, arrays, self, count caps (action max + Config.Admin.Scope), entity, coords.
local function suiteTargets()
    suite('targets')
    local env, Core = newServer()
    local A = Core.Admin
    local got
    local function capture(ctx) got = ctx.targets return true end
    A.action(def('t.many', { target = 'players', max = 3, cooldown = 0, handler = capture }))
    A.action(def('t.one', { target = 'player', self = false, cooldown = 0, handler = capture }))
    A.action(def('t.flat', { target = 'players', hierarchy = false, cooldown = 0, handler = capture, default = 'mod' }))
    A.action(def('t.ent', { target = 'entity', cooldown = 0, handler = capture }))
    A.action(def('t.pos', { target = 'coords', cooldown = 0, handler = capture }))
    for src = 1, 3 do A.setDuty(src, true) end
    Core.Perms.grant(3, 'admin.t.many')
    local function targets(actor, id, input)
        got = nil
        local ok, code, detail = A.run(actor, id, { targets = input })
        return ok and got or nil, code, detail
    end
    local list = targets(2, 't.many', '5,6')
    check(list and list[1] == 5 and list[2] == 6, 'a selector string is resolved (§49)')
    list = targets(2, 't.many', { 6, 5, 6 })
    check(list and #list == 2 and list[1] == 6, 'an id array is de-duplicated in order')
    list = targets(2, 't.many', 5.0)
    check(list and list[1] == 5 and math.type(list[1]) == 'integer', 'a JSON float id becomes an integer')
    eq(select(2, targets(2, 't.many', { 5, 99 })), 'not_found', 'an id that is not loaded')
    eq(select(2, targets(2, 't.many', { 'x' })), 'invalid_targets', 'a non-number id')
    eq(select(2, targets(2, 't.many', true)), 'invalid_targets', 'a boolean target')
    eq(select(2, targets(2, 't.many', nil)), 'no_target', 'no target at all')
    eq(select(2, targets(2, 't.many', {})), 'no_target', 'an empty array')
    eq(select(2, targets(2, 't.many', 'Nobody')), 'not_found', 'a name that matches nobody')
    eq(select(2, targets(2, 't.many', 'U')), 'ambiguous', 'an ambiguous partial name')
    list = targets(2, 't.many', 'Uma')
    eq(list and list[1], 5, 'a unique name')
    eq(select(2, targets(2, 't.one', { 2 })), 'self', 'self = false refuses the actor')
    eq(select(2, targets(2, 't.one', 'me')), 'self', '... also through a selector')
    list = targets(2, 't.many', { 2 })
    eq(list and list[1], 2, 'self = true allows the actor (hierarchy passes for self)')
    eq(select(2, targets(2, 't.one', { 5, 6 })), 'too_many', "'player' takes exactly one")
    eq(select(2, targets(2, 't.many', { 3, 4, 5, 6 })), 'too_many', 'above the action max (3)')
    -- scope: mod = 5 in Config.Admin.Scope, the flat action allows 50
    eq(select(2, targets(3, 't.flat', { 1, 2, 4, 5, 6, 3 })), 'too_many', 'the mod scope caps at 5')
    list = targets(3, 't.flat', { 1, 2, 4, 5, 6 })
    eq(list and #list, 5, 'five targets are within the mod scope')
    list = targets(2, 't.flat', '*')
    eq(list and #list, 6, "'*' for an admin (scope 50)")
    local row = rows(Core, 't.flat')[1]
    eq(row and #row.targets, 6, 'the audit row lists every target')
    eq(select(2, targets(3, 't.many', { 2 })), 'rank', 'hierarchy: a mod on an admin')
    eq(select(2, targets(3, 't.many', 'others')), 'too_many', "'others' counts before the hierarchy")
    list = targets(0, 't.many', { 1 })
    eq(list and list[1], 1, 'the console outranks everyone')
    -- entity
    local veh = stubs.newEntity(2, {})
    local netId = stubs.entities[veh].netId
    list = targets(2, 't.ent', { netId = netId })
    eq(list and list[1].entity, veh, 'entity: { netId } resolves the entity')
    eq(list and list[1].netId, netId, '... keeping the net id')
    list = targets(2, 't.ent', { { netId = netId } })
    eq(list and list[1].entity, veh, 'entity: { { netId } } too')
    eq(select(2, targets(2, 't.ent', { netId = 9999 })), 'no_entity', 'an unknown net id')
    eq(select(2, targets(2, 't.ent', { netId = -1 })), 'invalid_targets', 'a negative net id')
    eq(select(2, targets(2, 't.ent', 5)), 'invalid_targets', 'a bare number')
    stubs.entities[veh].exists = false
    eq(select(2, targets(2, 't.ent', { netId = netId })), 'no_entity', 'a deleted entity')
    -- coords
    list = targets(2, 't.pos', vector3(100.0, -200.0, 30.0))
    check(list and xtype(list[1]) == 'vector3' and list[1].y == -200.0, 'coords: a vector3')
    list = targets(2, 't.pos', { x = 1, y = 2, z = 3 })
    check(list and xtype(list[1]) == 'vector3' and list[1].z == 3.0, 'coords: a plain { x, y, z } becomes a vector3')
    stubs.tick(5000)   -- a fresh denied-row budget for actor 2
    eq(select(2, targets(2, 't.pos', { x = 10001, y = 0, z = 0 })), 'out_of_bounds', 'x beyond 10000')
    eq(select(2, targets(2, 't.pos', { x = 0, y = 0, z = 3001 })), 'out_of_bounds', 'z above 3000')
    eq(select(2, targets(2, 't.pos', { x = 0, y = 0, z = -1001 })), 'out_of_bounds', 'z below -1000')
    eq(select(2, targets(2, 't.pos', { x = 0 / 0, y = 0, z = 0 })), 'invalid_targets', 'NaN')
    eq(select(2, targets(2, 't.pos', 'here')), 'invalid_targets', 'a string')
    -- L4: entity targets pass the hierarchy (player peds, player occupants of vehicles)
    Core.Perms.grant(3, 'admin.t.ent')
    local car = stubs.newEntity(2, {})
    local carNet = stubs.entities[car].netId
    stubs.vehicleSeats[car] = { [-1] = stubs.peds[2] }
    eq(select(2, targets(3, 't.ent', { netId = carNet })), 'rank', 'L4: a vehicle an admin drives is protected from a mod')
    list = targets(2, 't.ent', { netId = carNet })
    eq(list and list[1].entity, car, 'L4: its own driver may target it')
    stubs.vehicleSeats[car] = { [-1] = stubs.peds[5], [2] = stubs.peds[1] }
    eq(select(2, targets(2, 't.ent', { netId = carNet })), 'rank', 'L4: every seat counts (the owner as a passenger)')
    eq(select(2, targets(3, 't.ent', { netId = stubs.entities[stubs.peds[2]].netId })), 'rank',
        'L4: a player ped of a heavier rank')
    list = targets(3, 't.ent', { netId = stubs.entities[stubs.peds[5]].netId })
    check(list ~= nil, 'L4: a lighter player ped is fine')
    A.action(def('t.entFree', { target = 'entity', hierarchy = false, cooldown = 0, handler = capture, default = 'mod' }))
    list = targets(3, 't.entFree', { netId = carNet })
    check(list ~= nil, 'L4: hierarchy = false skips the occupant check')
    -- M2: selectors resolve with max = min(action max, scope)
    local realResolve, lastMax = Core.Player.resolveTargets, nil
    Core.Player.resolveTargets = function(actor, selector, o)
        lastMax = o and o.max
        return realResolve(actor, selector, o)
    end
    targets(3, 't.flat', '5')
    eq(lastMax, 5, 'M2: a mod resolves t.flat (max 50) with max = 5')
    targets(2, 't.many', '5')
    eq(lastMax, 3, 'M2: an admin resolves t.many with its action max 3')
    Core.Player.resolveTargets = realResolve
    local r
    for _, candidate in ipairs(rows(Core, 't.pos')) do if not r and candidate.result == 'ok' then r = candidate end end
    eq(r and r.ctx and r.ctx.coords, '1.00, 2.00, 3.00', 'coords are recorded in ctx')
    local out
    for _, candidate in ipairs(rows(Core, 't.pos')) do
        if not out and candidate.message == 'out_of_bounds' then out = candidate end
    end
    check(out and out.result == 'denied', 'an out-of-bounds refusal is audited')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- Only what the viewer may use; public fields only; max capped for the viewer.
local function suiteSnapshot()
    suite('snapshot')
    local env, Core = newServer()
    local A = Core.Admin
    A.category({ id = 'players', label = 'Players', order = 1 })
    A.category({ id = 'world', label = 'World', order = 2 })
    A.category({ id = 'secret', label = 'Secret', permission = 'core.owner' })
    A.category({ id = 'empty', label = 'Empty' })
    A.action(def('t.admin', { target = 'players', args = { { name = 'n', type = 'integer',
        validate = function(v) return v > 0 end } } }))
    A.action(def('t.helper', { default = 'helper', hidden = true }))
    A.action(def('t.duty', { default = 'helper', duty = false, category = 'world' }))
    A.action(def('t.secret', { default = 'helper', category = 'secret' }))
    A.page({ id = 'pg.admin', label = 'Admin page', page = 'x_y', permission = 'core.admin' })
    A.page({ id = 'pg.all', label = 'All', provider = function() return {} end, duty = false })
    A.playerTab({ id = 'tab.mod', label = 'Mod tab', page = 'x_tab', permission = 'core.mod' })
    local function ids(list)
        local out = {}
        for i = 1, #list do out[list[i].id] = list[i] end
        return out
    end

    local offDuty = A.snapshot(4)
    local acts = ids(offDuty.actions)
    check(acts['t.duty'] and not acts['t.helper'], 'off duty: only duty = false actions')
    eq(offDuty.duty, false, 'the snapshot says off duty')
    check(ids(offDuty.pages)['pg.all'] ~= nil, 'a duty = false page is listed off duty')
    A.setDuty(4, true)
    local helper = A.snapshot(4)
    acts = ids(helper.actions)
    check(acts['t.helper'] and acts['t.duty'] and not acts['t.admin'], 'on duty: the helper actions, not the admin one')
    eq(acts['t.helper'] and acts['t.helper'].hidden, true, 'a hidden action is listed with hidden = true')
    local cats = ids(helper.categories)
    check(cats.players and cats.world and not cats.secret, 'categories: used and permitted only')
    check(not cats.empty, 'a category without a visible entry is left out')
    eq(helper.rank.group, 'helper', 'rank.group')
    eq(helper.rank.weight, 100, 'rank.weight')
    eq(helper.rank.scope, 1, 'rank.scope (helper = 1)')
    check(not ids(helper.pages)['pg.admin'] and not ids(helper.playerTabs)['tab.mod'], 'pages and tabs by permission')
    eq(helper.categories[1].id, 'players', 'sorted by order')

    A.setDuty(3, true)
    A.setDuty(2, true)
    local admin = A.snapshot(2)
    acts = ids(admin.actions)
    eq(acts['t.admin'] and acts['t.admin'].max, 50, 'admin: max 50 within the admin scope')
    local mod = A.snapshot(3)
    check(ids(mod.playerTabs)['tab.mod'] ~= nil, 'the mod sees the mod tab')
    Core.Perms.grant(3, 'admin.t.admin')
    acts = ids(A.snapshot(3).actions)
    eq(acts['t.admin'] and acts['t.admin'].max, 5, 'a granted mod sees max capped to the mod scope (5)')
    check(not hasFunction(admin), 'no function anywhere in the snapshot (handlers, validate)')
    local arg = acts['t.admin'] and acts['t.admin'].args and acts['t.admin'].args[1]
    eq(arg and arg.name, 'n', 'args are the public schema')
    eq(arg and arg.validate, nil, '... without validate')
    eq(ids(admin.pages)['pg.all'].provider, true, 'a provider page says provider = true')

    -- the callback: staff only, 1 s cooldown
    local ok, snap = callServer(env, 'core:admin:snapshot', 4)
    check(ok == true and type(snap) == 'table' and snap.rank.group == 'helper', 'core:admin:snapshot answers staff')
    ok = callServer(env, 'core:admin:snapshot', 4)
    eq(ok, false, 'a second request inside 1 s is refused')
    ok = callServer(env, 'core:admin:snapshot', 5)
    eq(ok, false, 'a player without the staff permission is refused')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- core:admin:run, core:admin:page, core:admin:playerTab.
local function suiteTransport()
    suite('transport')
    local env, Core = newServer()
    local A = Core.Admin
    A.setDuty(2, true)
    local ctxSeen
    A.action(def('t.go', { target = 'player', handler = function(ctx) ctxSeen = ctx return true, 'went', { n = 1 } end }))
    local ok, answer = callServer(env, 'core:admin:run', 2, { id = 't.go', targets = { 5 }, source = 'chat' })
    eq(ok, true, 'core:admin:run answers')
    eq(answer and answer.ok, true, '{ ok = true }')
    eq(answer and answer.message, 'went', 'with the message')
    eq(answer and answer.data and answer.data.n, 1, 'and the data')
    eq(ctxSeen and ctxSeen.source, 'menu', "a client cannot claim source 'chat' (-> menu)")
    stubs.tick(200)
    ok, answer = callServer(env, 'core:admin:run', 2, { id = 't.go', targets = { 5 }, source = 'editor' })
    eq(answer and answer.error, 'cooldown', 'the action cooldown answers { ok = false, error }')
    eq(ctxSeen.source, 'menu', 'the editor source is allowed (handler did not run again)')
    ok = callServer(env, 'core:admin:run', 2, 'nope')
    eq(ok, false, 'a non-table payload is refused by the schema')
    local before = #rows(Core, 't.go')
    ok, answer = callServer(env, 'core:admin:run', 5, { id = 't.go', targets = { 6 } })
    eq(ok, false, 'core:admin:run refuses a player without the staff permission (H1)')
    eq(#rows(Core, 't.go'), before, '... before any audit row')

    -- pages
    A.page({ id = 'pg.ui', label = 'UI', page = 'plug_page' })
    local rowsBig = {}
    for i = 1, 250 do rowsBig[i] = { a = i, b = 'x', c = 'hidden' } end
    A.action(def('t.hidden', { default = 'owner' }))
    A.page({ id = 'pg.blocks', label = 'Blocks', provider = function(ctx)
        return {
            { kind = 'keyvalue', title = 'KV', rows = { { label = 'viewer', value = ctx.viewer }, { 'p', ctx.params and ctx.params.x } } },
            { kind = 'table', columns = { { key = 'a', label = 'A' }, { key = 'b' } }, rows = rowsBig },
            { kind = 'text', text = 'hello' },
            { kind = 'stats', items = { { label = 'n', value = 3, icon = 'users' } } },
            { kind = 'actions', ids = { 't.go', 't.hidden', 'nope' } },
            { kind = 'form', fields = { { name = 'q', type = 'string' } }, submit = 't.go' },
            { kind = 'form', fields = { { name = 'q', type = 'string' } }, submit = 't.hidden' },
            { kind = 'evil', html = '<script>' },
            'garbage',
        }
    end })
    A.page({ id = 'pg.throw', label = 'Throw', provider = function() error('bad provider') end })
    ok, answer = callServer(env, 'core:admin:page', 2, { id = 'pg.ui' })
    check(answer and answer.ok and answer.page == 'plug_page' and answer.blocks == nil, 'a UI page answers its page id')
    stubs.tick(300)
    ok, answer = callServer(env, 'core:admin:page', 2, { id = 'pg.blocks', params = { x = 'y' } })
    local blocks = answer and answer.blocks or {}
    eq(#blocks, 6, 'unknown kinds, garbage and a form the viewer cannot submit are dropped')
    eq(blocks[1] and blocks[1].rows[1].value, 2, 'keyvalue: ctx.viewer reached the provider')
    eq(blocks[1] and blocks[1].rows[2].value, 'y', 'keyvalue: positional rows and ctx.params')
    eq(blocks[2] and #blocks[2].rows, 200, 'table rows are capped at 200')
    eq(blocks[2] and blocks[2].rows[1].c, nil, 'table cells are the declared columns only')
    eq(blocks[2] and blocks[2].columns[2].label, 'b', 'a column label defaults to its key')
    eq(blocks[5] and #blocks[5].ids, 1, 'actions: only ids the viewer may use')
    eq(blocks[6] and blocks[6].submit, 't.go', 'a form the viewer may submit stays')
    stubs.tick(300)
    ok, answer = callServer(env, 'core:admin:page', 2, { id = 'pg.throw' })
    eq(answer and answer.error, 'error', 'a throwing provider answers error')
    stubs.tick(300)
    ok, answer = callServer(env, 'core:admin:page', 2, { id = 'nope' })
    eq(answer and answer.error, 'unknown', 'an unknown page')
    ok = callServer(env, 'core:admin:page', 5, { id = 'pg.ui' })
    eq(ok, false, 'non-staff are refused by the callback permission')
    -- player tabs
    A.playerTab({ id = 'tab.info', label = 'Info', provider = function(ctx)
        return { { kind = 'text', text = ('target %d'):format(ctx.target) } }
    end })
    stubs.tick(300)
    ok, answer = callServer(env, 'core:admin:playerTab', 2, { id = 'tab.info', target = 6.0 })
    eq(answer and answer.blocks and answer.blocks[1].text, 'target 6', 'a player tab gets ctx.target')
    stubs.tick(300)
    ok, answer = callServer(env, 'core:admin:playerTab', 2, { id = 'tab.info', target = 77 })
    eq(answer and answer.error, 'payload', 'a target that is not loaded')
    stubs.tick(300)
    ok, answer = callServer(env, 'core:admin:playerTab', 2, { id = 'tab.info', target = 1 })
    eq(answer and answer.error, 'rank', 'L5: a tab on a heavier rank is refused')
    A.playerTab({ id = 'tab.open', label = 'Open', hierarchy = false, provider = function() return {} end })
    stubs.tick(300)
    ok, answer = callServer(env, 'core:admin:playerTab', 2, { id = 'tab.open', target = 1 })
    eq(answer and answer.ok, true, 'L5: hierarchy = false opts out')
    eq(select(2, A.playerTab({ id = 'tab.bad', label = 'B', page = 'x_y', hierarchy = 'no' })), 'hierarchy',
        'hierarchy must be a boolean')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- Duty: staff permission, state bag, audit, demotion, drop; the debounced snapshotChanged.
--- The payload of the last `name` sent to `target` (since `from`), or nil.
local function lastTo(name, target, from)
    local list = sends(name, target, from)
    return list[#list] and list[#list].args[1] or nil
end

local function suiteDuty()
    suite('duty')
    local env, Core = newServer()
    local A = Core.Admin
    local mark = #stubs.sent + 1
    eq(A.setDuty(5, true), false, 'a player without the staff permission cannot go on duty')
    eq(A.setDuty(0, true), false, 'the console has no duty')
    eq(A.setDuty(4, 'yes'), false, 'on must be a boolean')
    eq(A.isOnDuty(0), true, 'the console counts as on duty')
    eq(A.setDuty(4, true), true, 'a helper goes on duty')
    eq(A.isOnDuty(4), true, 'isOnDuty')
    eq(stubs.playerState(env, 4).duty, nil, 'no duty state bag is written (F1)')
    eq(lastTo('core:admin:self', 4, mark).duty, true, 'the player is told: core:admin:self { duty = true }')
    local list = lastTo('core:admin:staffStates', 4, mark)
    check(list and #list == 1 and list[1].src == 4 and list[1].duty == true, '... and gets the on-duty list once')
    local row = rows(Core, 'core.admin.duty')[1]
    check(row and row.result == 'ok' and row.changes and row.changes[1].new == true, 'audited with the change',
        row and row.changes and show(row.changes[1].new))
    local count = #rows(Core, 'core.admin.duty')
    eq(A.setDuty(4, true), true, 'setting the same state again is fine')
    eq(#rows(Core, 'core.admin.duty'), count, '... and not audited')
    stubs.tick(999)
    eq(#sends('core:admin:snapshotChanged', 4, mark), 0, 'no snapshotChanged before 1 s')
    stubs.tick(1)
    eq(#sends('core:admin:snapshotChanged', 4, mark), 1, 'one snapshotChanged after 1 s')
    eq(#sends('core:admin:snapshotChanged', 3, mark), 0, '... only to the player whose duty changed')
    local staff = A.staff()
    eq(#staff, 4, 'Admin.staff(): four staff online')
    local onDuty = A.staff(true)
    check(#onDuty == 1 and onDuty[1] == 4, 'Admin.staff(true): only the helper')

    -- Admin.echo
    A.setDuty(3, true)
    mark = #stubs.sent + 1
    eq(A.echo('hello staff'), 2, 'echo reaches the on-duty staff')
    eq(A.echo('only mods', { perm = 'core.mod' }), 1, 'echo with perm')
    eq(A.echo('not you', { exclude = 4 }), 1, 'echo with exclude')
    eq(A.echo(''), 0, 'an empty echo sends nothing')
    local e = sends('core:admin:echo', 3, mark)[1]
    eq(e and e.args[1].text, 'hello staff', 'the echo payload carries the text')

    -- demotion takes duty away, the whole-group change reaches all staff
    mark = #stubs.sent + 1
    Core.Perms.setGroup(4, 'user')
    eq(A.isOnDuty(4), false, 'losing the staff permission ends the duty')
    eq(lastTo('core:admin:self', 4, mark).duty, false, '... and the player is told')
    local off = lastTo('core:admin:staffState', 3, mark)
    check(off and off.src == 4 and off.duty == false and off.modes == nil, '... and the on-duty staff too')
    check(not A.staff()[4] and #A.staff() == 3, 'and the player left the staff set')
    stubs.tick(1000)
    eq(#sends('core:admin:snapshotChanged', 4, mark), 1, 'the demoted player is told to refresh')
    mark = #stubs.sent + 1
    Core.Perms.saveGroup('mod', { label = 'Moderator' })
    stubs.tick(2000)   -- one coalesced walk after 1 s, then the snapshotChanged debounce
    eq(#sends('core:admin:snapshotChanged', 1, mark), 1, 'a group change (permsChanged nil) reaches every staff member')
    eq(#sends('core:admin:snapshotChanged', 5, mark), 0, '... but not a regular player')

    -- L13: a burst of permsChanged(nil) is ONE walk over the players
    stubs.tick(3000)
    local realHas, calls = Core.Perms.has, 0
    Core.Perms.has = function(...) calls = calls + 1 return realHas(...) end
    for _ = 1, 5 do Core.emitHook('permsChanged', nil, 'define') end
    eq(calls, 0, 'permsChanged(nil) does not walk at once')
    stubs.tick(1000)
    eq(calls, 6, 'five group-wide changes inside 1 s: one walk (one check per loaded player)')
    Core.Perms.has = realHas

    -- L1: modes end with the duty and with a demotion
    A.setDuty(1, true)
    A.setMode(1, 'noclip', true)
    A.setMode(1, 'vanish', true)
    eq(A.setDuty(1, false), true, 'off duty')
    eq(next(A.getModes(1)), nil, 'going off duty clears the modes')
    local selfOff = lastTo('core:admin:self', 1)
    check(selfOff and selfOff.duty == false and next(selfOff.modes) == nil, '... and the player is told (no modes)')
    eq(Core.Security.isStaffExempt(1, 'collision'), false, '... so nothing is exempt any more')
    A.setMode(2, 'god', true)
    Core.Perms.setGroup(2, 'user')
    eq(next(A.getModes(2)), nil, 'a demotion (off duty) clears the modes')
    local demoted = lastTo('core:admin:self', 2)
    check(demoted and next(demoted.modes) == nil, '... and the player is told')

    -- drop clears everything and tells the remaining on-duty staff
    A.setMode(3, 'noclip', true)
    A.setDuty(1, true)
    mark = #stubs.sent + 1
    stubs.dropPlayer(env, 3)
    local gone = lastTo('core:admin:staffState', 1, mark)
    check(gone and gone.src == 3 and gone.duty == false, 'a dropped on-duty member leaves the staff maps')
    eq(A.isOnDuty(3), false, 'drop clears the duty')
    eq(next(A.getModes(3)), nil, 'and the modes')
    eq(#A.staff(), 1, 'and the staff entry')
    eq(stubs.playerState(env, 1).staffModes, nil, 'no staffModes state bag is ever written (F1)')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- Modes: validation, the staffModes bag (names only), audit on change, security exemption.
local function suiteModes()
    suite('modes')
    local env, Core = newServer()
    local A = Core.Admin
    local S = Core.Security
    eq(A.setMode(9, 'noclip', true), false, 'an unknown player')
    eq(A.setMode(2, 'no clip', true), false, 'a mode with a space')
    eq(A.setMode(2, 'noclip', 1), false, 'on must be a boolean')
    eq(A.setMode(2, 'noclip', true, function() end), false, 'data must be data')
    eq(S.isStaffExempt(2, 'invisible'), false, 'no mode: not exempt')
    eq(A.setMode(2, 'vanish', true, { alpha = 120 }), true, 'vanish on with data')
    eq(A.getModes(2).vanish.alpha, 120, 'getModes returns the data')
    eq(stubs.playerState(env, 2).staffModes, nil, 'no staffModes state bag (F1)')
    local told = lastTo('core:admin:self', 2)
    check(told and told.modes.vanish == true, 'core:admin:self carries the mode name')
    check(told and type(told.modes.vanish) ~= 'table', '... never the data')
    eq(#sends('core:admin:staffState'), 0, 'off duty: no staffState reaches anyone')
    local row = rows(Core, 'core.admin.mode')[1]
    check(row and row.changes and row.changes[1].key == 'vanish', 'the change is audited')
    local count = #rows(Core, 'core.admin.mode')
    eq(A.setMode(2, 'vanish', true, { alpha = 90 }), true, 'a data update')
    eq(#rows(Core, 'core.admin.mode'), count, '... is not audited again')
    eq(A.getModes(2).vanish.alpha, 90, '... but stored')
    local copy = A.getModes(2)
    copy.vanish.alpha = 1
    eq(A.getModes(2).vanish.alpha, 90, 'getModes hands out a copy')
    eq(S.isStaffExempt(2, 'invisible'), true, 'vanish sanctions invisibility')
    eq(S.isStaffExempt(2, 'collision'), false, 'but not collision')
    eq(S.isStaffExempt(2, 'weapon'), false, 'unknown anomalies are never exempt')
    A.setMode(2, 'noclip', true)
    eq(S.isStaffExempt(2, 'collision'), true, 'noclip sanctions collision')
    eq(S.isStaffExempt(2, 'teleport'), true, 'and teleport')
    eq(A.setMode(2, 'vanish', false), true, 'vanish off')
    eq(A.setMode(2, 'vanish', false), true, 'off again is fine')
    eq(lastTo('core:admin:self', 2).modes.vanish, nil, 'the player is told vanish is off')
    A.setMode(2, 'noclip', false)
    eq(next(lastTo('core:admin:self', 2).modes), nil, 'no mode left: an empty set')

    -- on-duty staff see each other's modes; nobody else does
    A.setDuty(3, true)
    local mark = #stubs.sent + 1
    A.setDuty(2, true)
    local list = lastTo('core:admin:staffStates', 2, mark)
    check(list and #list == 2, 'going on duty: the full on-duty list once (both)')
    local joined = lastTo('core:admin:staffState', 3, mark)
    check(joined and joined.src == 2 and joined.duty == true, 'the others hear who came on duty')
    eq(#sends('core:admin:staffState', 2, mark), 0, '... the newcomer not about itself')
    mark = #stubs.sent + 1
    A.setMode(2, 'spectate', true, { target = 5 })
    local seen = lastTo('core:admin:staffState', 3, mark)
    check(seen and seen.modes and seen.modes.spectate == true, 'a mode change reaches the on-duty staff')
    check(seen and type(seen.modes.spectate) ~= 'table', '... names only (the target stays on the server)')
    eq(#sends('core:admin:staffState', 5, mark), 0, 'a regular player never hears it')
    eq(#sends('core:admin:staffState', 4, mark), 0, 'nor off-duty staff')
    mark = #stubs.sent + 1
    stubs.triggerOn(env, 'core:hook:playerLoaded', 0, 4)
    eq(lastTo('core:admin:self', 4, mark) and lastTo('core:admin:self', 4, mark).duty, false,
        'a staff member that (re)loads is told its state once')
    stubs.triggerOn(env, 'core:hook:playerLoaded', 0, 5)
    eq(#sends('core:admin:self', 5, mark), 0, '... a regular player is not')
    -- server hook staffModeChanged (src, modes): every change, the clears and the drop
    local hooked = {}
    Core.on('staffModeChanged', function(src, names) hooked[#hooked + 1] = { src = src, names = names } end)
    A.setMode(4, 'ids', true)
    check(hooked[1] and hooked[1].src == 4 and hooked[1].names.ids == true, 'staffModeChanged on a mode change')
    A.setMode(4, 'ids', true, { x = 1 })
    eq(#hooked, 1, 'a data update is not a change')
    A.setDuty(4, true)
    A.setMode(4, 'god', true)
    A.setDuty(4, false)
    check(#hooked == 4 and next(hooked[4].names) == nil, 'going off duty clears the modes through the hook')
    A.setMode(4, 'noclip', true)
    stubs.dropPlayer(env, 4)
    check(#hooked == 6 and hooked[6].src == 4 and next(hooked[6].names) == nil, 'a drop reports the cleared modes')
    for i = 1, 16 do A.setMode(3, 'm' .. i, true) end
    eq(A.setMode(3, 'm17', true), false, 'at most 16 modes per player')
    eq(next(A.getModes(99)), nil, 'getModes of nobody is empty')
    eq(#stubs.failures, 0, 'no thread errored')
end

--- Chat commands generated from `command`.
local function suiteCommands()
    suite('commands')
    local env, Core = newServer()
    local A = Core.Admin
    local cmds = env.__vm.commands
    local got
    local function capture(ctx) got = ctx return true, 'ok' end
    A.setDuty(2, true)
    A.action(def('t.kick', { target = 'player', reason = 'required', danger = 'confirm', command = 'akick',
        handler = capture }))
    A.action(def('t.ban', { target = 'player', reason = 'required', command = 'aban', handler = capture,
        args = { { name = 'duration', type = 'duration', required = true }, { name = 'evidence', type = 'string' } } }))
    A.action(def('t.say', { command = 'asay', handler = capture,
        args = { { name = 'loud', type = 'boolean', required = true }, { name = 'message', type = 'string', required = true } } }))
    A.action(def('t.bring', { target = 'players', command = 'abring', handler = capture }))
    A.action(def('t.fix', { target = 'entity', command = 'afix', handler = capture }))
    A.action(def('t.tp', { target = 'coords', command = 'atp', handler = capture }))
    A.action(def('t.pick', { command = 'apick', handler = capture,
        args = { { name = 'what', type = 'enum', options = { 'a', 'b' }, required = true } } }))
    A.action(def('t.vec', { command = 'avec', handler = capture, args = { { name = 'at', type = 'vector3' } } }))
    A.action(def('t.res', { command = 'ares', handler = capture, args = { { name = 'target', type = 'string' } } }))
    Core.Commands.register('taken', {}, function() end)
    A.action(def('t.taken', { command = 'taken', handler = capture }))

    local kick = Core.Commands.get('akick')
    eq(kick and kick.usage, 'Usage: /akick <target> <reason>', 'player target first, reason as rest')
    eq(kick and kick.permission, 'admin.t.kick', 'the command carries the action permission')
    eq(Core.Commands.get('aban').usage, 'Usage: /aban <target> <duration> <reason>',
        'an optional arg before the required reason is left out')
    eq(Core.Commands.get('asay').params[2].type, 'rest', 'reason none: the last string arg takes the rest')
    eq(Core.Commands.get('abring').params[1].type, 'targets', "'players' -> a targets param")
    eq(Core.Commands.get('afix').params[1].name, 'netId', 'entity -> netId')
    eq(Core.Commands.get('atp').usage, 'Usage: /atp <x> <y> <z>', 'coords -> x y z')
    eq(Core.Commands.get('apick').params[1].type, 'string', 'a string enum -> string')
    eq(Core.Commands.get('avec'), nil, 'an arg without a chat form: no command')
    check(printed('/avec (arg at (vector3) has no chat form)') ~= nil, '... with a warning')
    eq(Core.Commands.get('ares'), nil, 'a reserved arg name: no command')
    eq(Core.Commands.get('taken').description, '', 'an existing command is never replaced')
    check(printed('/taken already exists') ~= nil, '... with a warning')

    cmds.akick.fn(2, { 'Uma', 'being', 'rude' }, '/akick Uma being rude')
    eq(got and got.targets[1], 5, 'the command resolved the selector')
    eq(got and got.reason, 'being rude', 'the rest is the reason')
    eq(got and got.source, 'chat', "source = 'chat'")
    eq(rows(Core, 't.kick')[1].source, 'chat', 'the audit row says chat')
    got = nil
    cmds.aban.fn(2, { '6', '3600', 'cheating' }, '/aban 6 3600 cheating')
    eq(got and got.args.duration, 3600, 'a duration arg arrives as integer')
    eq(got and got.reason, 'cheating', 'and the reason')
    got = nil
    cmds.asay.fn(2, { 'yes', 'hello', 'there' }, '/asay yes hello there')
    eq(got and got.args.message, 'hello there', 'the rest arg')
    eq(got and got.args.loud, true, 'a boolean arg')
    got = nil
    cmds.abring.fn(2, { '5,6' }, '/abring 5,6')
    eq(got and #got.targets, 2, 'targets from a selector')
    got = nil
    local veh = stubs.newEntity(2, {})
    cmds.afix.fn(2, { tostring(stubs.entities[veh].netId) }, '/afix')
    eq(got and got.targets[1].entity, veh, 'entity by net id')
    got = nil
    cmds.atp.fn(2, { '1', '2', '3' }, '/atp 1 2 3')
    check(got and xtype(got.targets[1]) == 'vector3' and got.targets[1].x == 1.0, 'coords from x y z')
    got = nil
    cmds.atp.fn(0, { '1', '2', '3' }, '/atp 1 2 3')
    eq(got and got.source, 'console', "the console's command source is 'console'")
    got = nil
    cmds.akick.fn(5, { '6', 'being', 'rude' }, '/akick 6 being rude')
    eq(got, nil, 'Core.Commands refuses a player without the permission')

    -- re-registration by the owner with another name frees the old one
    A.action(def('t.kick', { target = 'player', reason = 'required', danger = 'confirm', command = 'akick2',
        handler = capture }))
    eq(Core.Commands.get('akick'), nil, 'the old command name is unregistered')
    check(Core.Commands.get('akick2') ~= nil, 'the new one is bound')
    local mark = #stubs.sent + 1
    cmds.akick.fn(2, { '6', 'being', 'rude' }, '/akick 6 being rude')
    local reply = sends('core:client:notify', 2, mark)[1]
    check(reply ~= nil, 'the stale engine binding answers instead of dispatching')
    eq(#stubs.failures, 0, 'no thread errored')
end

--------------------------------------------------------------------------------
-- run
--------------------------------------------------------------------------------

local SUITES <const> = {
    { 'register', suiteRegister }, { 'ownership', suiteOwnership }, { 'dispatch', suiteDispatch },
    { 'targets', suiteTargets }, { 'snapshot', suiteSnapshot }, { 'transport', suiteTransport },
    { 'duty', suiteDuty }, { 'modes', suiteModes }, { 'commands', suiteCommands },
}

for i = 1, #SUITES do
    local name, fn = SUITES[i][1], SUITES[i][2]
    local ok, err = pcall(fn)
    if not ok then H.crashed(name, err) end
end

local passed, failed = H.counts()
print(('admin api: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
