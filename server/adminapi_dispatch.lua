--[[
    core/server/adminapi_dispatch.lua — Admin.run, the one dispatch path of every admin action (DESIGN §51),
    the `core:admin:run` callback and the chat commands generated from an action's `command`.

      Admin.run(actorSrc, id, { targets?, args?, reason?, source?, confirm? })
        -> true, { message?, data? } | false, errCode|message, data?

    Steps: 1 action exists → 2 actor loaded (console allowed) → 3 Perms.has(permission) → 4 duty (console
    exempt) → 5 cooldown (actor, action) → 6 Schema.checkAll(args) → 7 reason policy → 8 targets → 9 danger
    needs confirm → 10 Hooks.run('admin:before') → 11 handler under pcall → 12 audit ok/error → 13 staff
    echo → 14 observer hook `adminAction`. Every refusal except the cooldown writes a `denied` audit row
    with the reason code as its message, within a budget per (actor, action id): one persisted denied row
    per DENY_AUDIT_MS per action, the refusals in between counted into that action's next row
    (ctx.suppressed) — so a refusal on one action never hides one on another (review R2-14), and a client
    cannot flood the trail or the webhooks. Unknown ids share ONE budget per actor. `unknown_action` and
    `not_loaded` of a non-staff actor are only logged at debug level. `core:admin:run` itself is gated by
    Config.Admin.StaffPerm. Target counts are checked before the hierarchy (cheap first; both refuse);
    selectors resolve with `max = cap`. The cooldown is stamped when the handler runs and when the targets
    are refused (a refused selector costs a cooldown), never for the earlier refusals.
    Entity targets pass the hierarchy too: a player ped, and every player in a vehicle's seats.

    Natives: NetworkGetEntityFromNetworkId, DoesEntityExist (BOOL, truthiness), GetEntityType,
    IsPedAPlayer (BOOL, truthiness), NetworkGetEntityOwner, GetPlayerPed, GetPedInVehicleSeat,
    GetGameTimer — all server.
]]

local Admin = Core.Admin
local slot = type(Admin) == 'table' and getmetatable(Admin) or nil
local P = slot and slot.__private
if type(P) ~= 'table' then error('adminapi_dispatch.lua must load right after adminapi.lua', 0) end
slot.__private = nil
local Log = Core.Log
local Schema = Core.Schema
local actions = P.actions

local SOURCES <const> = { menu = true, palette = true, chat = true, console = true, editor = true, api = true,
    core = true }
local CLIENT_SOURCES <const> = { menu = true, palette = true, editor = true }
local MAX_TARGET_INPUT <const> = 2000
local MAX_NETID <const> = 0xFFFFF
local WORLD_XY <const>, WORLD_Z_MIN <const>, WORLD_Z_MAX <const> = 10000.0, -1000.0, 3000.0
local MIN_REASON <const>, MAX_REASON <const> = 3, 256
local MAX_MESSAGE <const> = 256
local DENY_AUDIT_MS <const> = 5000
local ECHO_NAMES <const> = 10

local cooldowns = {}     -- [actor] = { [actionId] = GetGameTimer() of the last run }
local lastDenied = {}    -- [actor] = { [actionId | UNKNOWN_KEY] = { at = GetGameTimer() of the last row, suppressed } }
local UNKNOWN_KEY <const> = '?'   -- every unknown id of one actor shares one budget
local SILENT_FOR_NON_STAFF <const> = { unknown_action = true, not_loaded = true }
local VEHICLE_SEATS <const> = { -1, 14 }   -- driver .. last passenger seat probed for player occupants

local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

--- A refusal: at most one persisted `denied` row per (actor, action) per DENY_AUDIT_MS, then false + the code.
local function deny(state, code, detail)
    local actor = state.actor
    local action = state.action
    if SILENT_FOR_NON_STAFF[code] and actor ~= 0 and not P.staffSet[actor] then
        Log.debug('admin: %s refused for %s (%s)', action and action.id or tostring(state.requested), tostring(actor), code)
        return false, code
    end
    local perActor = lastDenied[actor]
    if not perActor then
        perActor = {}
        lastDenied[actor] = perActor
    end
    local key = action and action.id or UNKNOWN_KEY
    local now, budget = GetGameTimer(), perActor[key]
    if budget and now - budget.at < DENY_AUDIT_MS then
        budget.suppressed = budget.suppressed + 1
        return false, code
    end
    local suppressed = budget and budget.suppressed or 0
    perActor[key] = { at = now, suppressed = 0 }
    P.audit(action and action.owner or 'core', {
        actor = actor >= 0 and actor or 'system',
        action = action and action.id or 'core.admin.unknown', source = state.source,
        targets = state.auditTargets, reason = state.reason, result = 'denied', message = code,
        ctx = { step = state.step, detail = detail, requested = state.requested, coords = state.coords,
            suppressed = suppressed > 0 and suppressed or nil },
    })
    return false, code
end

local function onCooldown(actor, action)
    if action.cooldown <= 0 then return false end
    local list = cooldowns[actor]
    local last = list and list[action.id]
    return last ~= nil and GetGameTimer() - last < action.cooldown * 1000
end

local function stamp(actor, action)
    if action.cooldown <= 0 then return end
    local list = cooldowns[actor]
    if not list then
        list = {}
        cooldowns[actor] = list
    end
    list[action.id] = GetGameTimer()
end

--- Reason policy: the cleaned reason (or nil) | nil, code.
local function checkReason(policy, value)
    if policy == 'none' then return nil end
    if value == nil or value == '' then
        if policy == 'required' then return nil, 'reason_required' end
        return nil
    end
    if type(value) ~= 'string' then return nil, 'invalid_reason' end
    local clean = P.text(value, MAX_REASON + 1)
    if not clean then
        if policy == 'required' then return nil, 'reason_required' end
        return nil
    end
    if #clean > MAX_REASON or (policy == 'required' and #clean < MIN_REASON) then return nil, 'invalid_reason' end
    return clean
end

-- == Step 8: targets =======================================================================================

--- Audit targets of a player list (≤ 32, the audit keeps no more).
local function playerRows(list)
    local out = {}
    for i = 1, math.min(#list, 32) do out[i] = { type = 'player', id = list[i] } end
    return out
end

--- `player(s)`: a selector string (§49), one id or an array of ids -> array of src | nil, code, detail.
--- The resolved list is put on `state.auditTargets` before it is checked, so a refusal names it.
local function playerTargets(action, actor, input, state)
    local list
    local cap = math.min(action.max, P.scopeOf(actor))
    if type(input) == 'string' then
        local resolved, err, detail = Core.Player.resolveTargets(actor, input, { allowSelf = action.self, max = cap })
        if not resolved then return nil, err or 'not_found', detail end
        list = resolved
    elseif type(input) == 'number' then
        local src = P.toSrc(input)
        if not src then return nil, 'invalid_targets' end
        list = { src }
    elseif type(input) == 'table' then
        local n = #input
        if n > MAX_TARGET_INPUT then return nil, 'too_many', n end
        local seen = {}
        list = {}
        for i = 1, n do
            local src = P.toSrc(input[i])
            if not src then return nil, 'invalid_targets' end
            if not seen[src] then
                seen[src] = true
                list[#list + 1] = src
            end
        end
    elseif input == nil then
        return nil, 'no_target'
    else
        return nil, 'invalid_targets'
    end
    if #list == 0 then return nil, 'no_target' end
    state.auditTargets = playerRows(list)
    for i = 1, #list do
        if not P.isLoaded(list[i]) then return nil, 'not_found', list[i] end
        if list[i] == actor and not action.self then return nil, 'self' end
    end
    if #list > cap then return nil, 'too_many', #list end
    if action.hierarchy then
        for i = 1, #list do
            local ok, why = Core.Perms.canTarget(actor, list[i])
            if not ok then return nil, why or 'rank', list[i] end
        end
    end
    return list
end

--- The src of a player ped (its network owner, confirmed by GetPlayerPed), or nil.
local function playerOfPed(ped)
    if ped == 0 or not IsPedAPlayer(ped) then return nil end
    local src = P.toSrc(NetworkGetEntityOwner(ped))
    if src and GetPlayerPed(src) == ped then return src end
    return false   -- a player ped nobody can be matched to: treated as protected
end

--- Hierarchy for an entity: a player ped, or every player seated in a vehicle -> true | nil, code, detail.
local function entityHierarchy(actor, entity)
    local kind = GetEntityType(entity)
    local peds = {}
    if kind == 1 then
        peds[1] = entity
    elseif kind == 2 then
        for seat = VEHICLE_SEATS[1], VEHICLE_SEATS[2] do
            local ped = GetPedInVehicleSeat(entity, seat)
            if ped ~= 0 then peds[#peds + 1] = ped end
        end
    end
    for i = 1, #peds do
        local src = playerOfPed(peds[i])
        if src == false then return nil, 'rank' end
        if src then
            local ok, why = Core.Perms.canTarget(actor, src)
            if not ok then return nil, why or 'rank', src end
        end
    end
    return true
end

--- `entity`: { netId } (or { { netId } }) -> { { entity, netId } } | nil, code.
local function entityTargets(action, actor, input)
    if type(input) ~= 'table' then return nil, 'invalid_targets' end
    local netId = input.netId
    if netId == nil and type(input[1]) == 'table' then netId = input[1].netId end
    netId = type(netId) == 'number' and math.tointeger(netId) or nil
    if not netId or netId < 1 or netId > MAX_NETID then return nil, 'invalid_targets' end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if type(entity) ~= 'number' or entity == 0 or not DoesEntityExist(entity) then return nil, 'no_entity', netId end
    if action.hierarchy then
        local ok, why, detail = entityHierarchy(actor, entity)
        if not ok then return nil, why, detail end
    end
    return { { entity = entity, netId = netId } }
end

--- `coords`: a vector3 or { x, y, z } inside the world bounds -> { vector3 } | nil, code.
local function coordsTargets(input)
    local kind = type(input)
    if kind ~= 'vector3' and kind ~= 'table' then return nil, 'invalid_targets' end
    local x, y, z = input.x, input.y, input.z
    if not (finite(x) and finite(y) and finite(z)) then return nil, 'invalid_targets' end
    if math.abs(x) > WORLD_XY or math.abs(y) > WORLD_XY or z < WORLD_Z_MIN or z > WORLD_Z_MAX then
        return nil, 'out_of_bounds'
    end
    return { vector3(x + 0.0, y + 0.0, z + 0.0) }
end

local function resolveTargets(action, actor, input, state)
    local kind = action.target
    if kind == 'none' then return {} end
    if kind == 'player' or kind == 'players' then return playerTargets(action, actor, input, state) end
    if kind == 'entity' then return entityTargets(action, actor, input) end
    return coordsTargets(input)
end

--- Hook-safe copy (plain data only: Core.Hooks refuses userdata and metatables).
local function plainTargets(action, targets)
    if action.target ~= 'coords' then
        if action.target ~= 'entity' then return targets end
        return { { entity = targets[1].entity, netId = targets[1].netId } }
    end
    local c = targets[1]
    return { { x = c.x, y = c.y, z = c.z } }
end

--- Audit targets + ctx coords for one resolved list.
local function auditTargets(action, targets, state)
    if action.target == 'player' or action.target == 'players' then
        state.auditTargets = playerRows(targets)
    elseif action.target == 'entity' then
        state.auditTargets = { { type = 'entity', id = targets[1].netId } }
    elseif action.target == 'coords' then
        local c = targets[1]
        state.coords = ('%.2f, %.2f, %.2f'):format(c.x, c.y, c.z)
    end
end

-- == Steps 13 and 14 =======================================================================================

--- `core:admin:echo` to on-duty staff but the actor: { text, at, id, label, actor, targets, count }.
local function echo(action, actor, targets)
    local recipients = P.echoTargets(nil, actor)
    if #recipients == 0 then return end
    local names, parts = {}, {}
    if action.target == 'player' or action.target == 'players' then
        for i = 1, math.min(#targets, ECHO_NAMES) do
            names[i] = { src = targets[i], name = P.nameOf(targets[i]) }
            parts[i] = ('%s (%d)'):format(names[i].name, targets[i])
        end
        if #targets > ECHO_NAMES then parts[#parts + 1] = ('+%d'):format(#targets - ECHO_NAMES) end
    end
    local line = ('%s: %s'):format(P.nameOf(actor), action.label)
    if #parts > 0 then line = line .. ' → ' .. table.concat(parts, ', ') end
    Core.Net.emitMany(recipients, 'core:admin:echo', {
        text = line, at = os.time(), id = action.id, label = action.label,
        actor = { src = actor, name = P.nameOf(actor) }, targets = names, count = #targets,
    })
end

local function message(value)
    if type(value) ~= 'string' then return nil end
    return P.text(value, MAX_MESSAGE)
end

-- == Admin.run =============================================================================================

--- The only way an action runs (DESIGN §51). `source` defaults to 'console' for src 0, else 'api'.
function Admin.run(actorSrc, id, opts)
    if type(opts) ~= 'table' then opts = {} end
    local actor = math.type(actorSrc) == 'integer' and actorSrc or nil
    local source = SOURCES[opts.source] and opts.source or (actor == 0 and 'console' or 'api')
    local state = { actor = actor or -1, source = source, step = 'action' }

    local action = type(id) == 'string' and actions[id] or nil                          -- 1
    if not action then
        state.requested = type(id) == 'string' and id:sub(1, 64) or type(id)
        return deny(state, 'unknown_action')
    end
    state.action = action
    state.step = 'actor'                                                               -- 2
    if actor == nil or (actor ~= 0 and not P.isLoaded(actor)) then return deny(state, 'not_loaded') end
    state.step = 'permission'                                                          -- 3
    if not Core.Perms.has(actor, action.permission) then return deny(state, 'no_permission') end
    state.step = 'duty'                                                                -- 4
    if action.duty and not P.onDuty(actor) then return deny(state, 'off_duty') end
    if onCooldown(actor, action) then return false, 'cooldown' end                     -- 5 (never audited)

    state.step = 'args'                                                                -- 6
    local args = {}
    if action.args then
        local ok, out = Schema.checkAll(action.args, opts.args)
        if not ok then return deny(state, 'invalid_args', out) end
        args = out
    elseif opts.args ~= nil and (type(opts.args) ~= 'table' or next(opts.args) ~= nil) then
        return deny(state, 'invalid_args', { ['*'] = 'unknown' })
    end
    state.step = 'reason'                                                              -- 7
    local reason, reasonErr = checkReason(action.reason, opts.reason)
    if reasonErr then return deny(state, reasonErr) end
    state.reason = reason
    state.step = 'targets'                                                             -- 8
    local targets, targetErr, detail = resolveTargets(action, actor, opts.targets, state)
    if not targets then
        stamp(actor, action)   -- a refused selector still costs the cooldown (resolution is the expensive part)
        return deny(state, targetErr, detail)
    end
    auditTargets(action, targets, state)
    state.step = 'confirm'                                                             -- 9
    if action.danger ~= 'none' and opts.confirm ~= true then return deny(state, 'confirm_required') end
    local plain = plainTargets(action, targets)
    state.step = 'hook'                                                                -- 10
    local hooks = rawget(Core, 'Hooks')
    if type(hooks) == 'table' and type(hooks.run) == 'function' then
        local pass, why = hooks.run('admin:before', { id = action.id, actor = actor, targets = plain, args = args })
        if not pass then return deny(state, 'vetoed', why) end
    end

    stamp(actor, action)                                                               -- 11
    local ctx = { id = action.id, actor = actor, targets = targets, args = args, reason = reason, source = source }
    local packed = table.pack(pcall(action.handler, ctx))
    local result, text, data = 'ok', nil, nil
    if not packed[1] then
        Log.error('admin: action %s (%s) failed: %s', action.id, action.owner, tostring(packed[2]))
        result, text = 'error', 'error'
    else
        text, data = message(packed[3]), type(packed[4]) == 'table' and Core.Utils.jsonSafe(packed[4]) or nil
        if packed[2] == false then result = 'error' end
    end
    P.audit(action.owner, {                                                            -- 12
        actor = actor, action = action.id, source = source, targets = state.auditTargets, reason = reason,
        changes = data and type(data.changes) == 'table' and data.changes or nil, result = result,
        message = text, ctx = { count = #targets, coords = state.coords },
    })
    if result == 'ok' and action.echo then echo(action, actor, targets) end            -- 13
    Core.emitHook('adminAction', { id = action.id, actor = actor, targets = plain, args = args,     -- 14
        reason = reason, source = source, result = result, message = text })
    if result == 'ok' then return true, { message = text, data = data } end
    return false, text or 'failed', data
end

-- == Transport =============================================================================================

-- `{ id, targets?, args?, reason?, source?, confirm? }` -> `{ ok, message?, data?, error? }`. Staff only
-- (Config.Admin.StaffPerm; anyone else is answered nil before any work or audit row). A client may only
-- claim the sources menu / palette / editor; every other check happens in Admin.run.
Core.Callback.register('core:admin:run', { { 'table', max = 8 } }, function(src, payload)
    local source = CLIENT_SOURCES[payload.source] and payload.source or 'menu'
    local ok, result, data = Admin.run(src, payload.id, { targets = payload.targets, args = payload.args,
        reason = payload.reason, source = source, confirm = payload.confirm == true })
    if ok then return { ok = true, message = result.message, data = result.data } end
    return { ok = false, error = result, message = result, data = data }
end, { permission = P.staffPerm(), cooldownMs = 100 })

AddEventHandler('playerDropped', function()
    local src = P.toSrc(source)
    if not src then return end
    cooldowns[src], lastDenied[src] = nil, nil
end)

-- == Chat commands from `command` ==========================================================================
-- Target param first (player kinds: `target`/`targets`; entity: netId; coords: x y z), then the scalar
-- args in order, then the reason as `rest`. An optional arg followed by a required param is left out of
-- the chat form (it takes its default): arguments bind left to right. A chat command is its own
-- confirmation (confirm = true); Core.Commands checks the permission first (hiding the suggestion).

local COMMAND_TYPES <const> = {
    boolean = 'boolean', integer = 'integer', duration = 'integer', player = 'player', number = 'number',
    heading = 'number', string = 'string', text = 'string', password = 'string', reason = 'string',
    model = 'string', ref = 'string', faction = 'string', item = 'string', color = 'string',
}
local STRING_TYPES <const> = { string = true, text = true, reason = true }
local RESERVED <const> = { target = true, targets = true, netId = true, x = true, y = true, z = true, reason = true }

local commandOwner = {}   -- [command] = action id currently bound to it

--- Command param type for one enum field: all-string options -> string, all-number -> number; else nil.
local function enumType(field)
    if field.multiple then return nil end
    local strings, numbers = true, true
    for i = 1, #field.options do
        local kind = type(field.options[i].value)
        strings, numbers = strings and kind == 'string', numbers and kind == 'number'
    end
    return strings and 'string' or numbers and 'number' or nil
end

--- The Core.Commands params of an action, or nil + the reason it cannot be a command.
local function commandParams(action)
    local params = {}
    if action.target == 'player' then
        params[1] = { name = 'target', type = 'target', allowSelf = action.self, help = 'player' }
    elseif action.target == 'players' then
        params[1] = { name = 'targets', type = 'targets', allowSelf = action.self, max = action.max, help = 'players' }
    elseif action.target == 'entity' then
        params[1] = { name = 'netId', type = 'integer', help = 'network id' }
    elseif action.target == 'coords' then
        params[1], params[2], params[3] = { name = 'x', type = 'number' }, { name = 'y', type = 'number' },
            { name = 'z', type = 'number' }
    end
    local fields = action.args or {}
    local lastRequired = action.reason == 'required' and math.huge or 0
    for i = 1, #fields do
        if fields[i].required and fields[i].default == nil then lastRequired = math.max(lastRequired, i) end
    end
    local list = {}
    for i = 1, #fields do
        local f = fields[i]
        local kind = f.type == 'enum' and enumType(f) or COMMAND_TYPES[f.type]
        if not kind then return nil, ('arg %s (%s) has no chat form'):format(f.name, f.type) end
        if RESERVED[f.name] then return nil, ('arg name %s is reserved'):format(f.name) end
        local optional = not f.required or f.default ~= nil
        if not optional or i > lastRequired then
            list[#list + 1] = { name = f.name, type = kind, optional = optional, help = f.label, field = f }
        end
    end
    -- the last string arg takes the rest of the line when there is no reason to do that
    local last = list[#list]
    if action.reason == 'none' and last and STRING_TYPES[last.field.type] then last.type = 'rest' end
    for i = 1, #list do
        params[#params + 1] = { name = list[i].name, type = list[i].type, optional = list[i].optional, help = list[i].help }
    end
    if action.reason ~= 'none' then
        params[#params + 1] = { name = 'reason', type = 'rest', optional = action.reason ~= 'required', help = 'reason' }
    end
    return params
end

local function reply(src, ok, text)
    if src == 0 then
        print(('[core] %s'):format(text))
    else
        Core.Notify.send(src, text, ok and 'success' or 'error')
    end
end

--- The Core.Commands handler of one (command, action) binding.
local function commandHandler(name, id, params)
    return function(src, parsed)
        local action = actions[id]
        if not action or action.command ~= name or commandOwner[name] ~= id then
            reply(src, false, ('/%s is no longer available'):format(name))
            return
        end
        local targets
        if parsed.target then targets = { parsed.target }
        elseif parsed.targets then targets = parsed.targets
        elseif parsed.netId then targets = { netId = parsed.netId }
        elseif parsed.x then targets = vector3(parsed.x, parsed.y, parsed.z) end
        local args = {}
        for i = 1, #params do
            local p = params[i]
            if not RESERVED[p.name] and parsed[p.name] ~= nil then args[p.name] = parsed[p.name] end
        end
        local ok, result = Admin.run(src, id, { targets = targets, args = args, reason = parsed.reason,
            source = src == 0 and 'console' or 'chat', confirm = true })
        if ok then
            reply(src, true, result.message or ('%s: done'):format(action.label))
        elseif result ~= 'cooldown' or src == 0 then
            reply(src, false, ('%s: %s'):format(action.label, tostring(result)))
        end
    end
end

--- Keeps the chat command of `action` (nil = removed) in step with `previous` (nil = new).
function P.syncCommand(action, previous)
    local old = previous and previous.command
    if old and commandOwner[old] == previous.id and (not action or action.command ~= old) then
        commandOwner[old] = nil
        Core.Commands.unregister(old)
    end
    local name = action and action.command
    if not name then return end
    if commandOwner[name] ~= action.id and Core.Commands.get(name) then
        Log.warn('Admin.action %s: /%s already exists, no chat command', action.id, name)
        return
    end
    local params, err = commandParams(action)
    if not params then
        Log.warn('Admin.action %s: no chat command /%s (%s)', action.id, name, err)
        return
    end
    local ok, registerErr = pcall(Core.Commands.register, name, {
        description = action.description or action.label, params = params, permission = action.permission,
        allowConsole = true,
    }, commandHandler(name, action.id, params))
    if not ok then
        Log.warn('Admin.action %s: /%s could not be registered (%s)', action.id, name, tostring(registerErr))
        return
    end
    commandOwner[name] = action.id
end
