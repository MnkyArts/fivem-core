--[[
    core lib: Core.Commands (DESIGN §3.7) — typed chat/console commands.

    Loaded into the CALLER's VM by import.lua, so the chunk receives its namespace table as `...`.

        Core.Commands.register(name, opts, handler(src, args, raw))
        opts = { description = '...', params = { { name = 'model', type = 'string', help = '...' },
                                                 { name = 'plate', type = 'string', optional = true } },
                 permission = 'core.admin',   -- server only, checked via Core.Perms.has(src, perm)
                 allowConsole = false }       -- default true; set false to refuse the server console (src 0)

    Param types: string | integer | number | boolean | player | rest (must be last), and server-only
    target (exactly one player) | targets (>= 1; param `max`, `allowSelf = true`), resolved through
    Core.Player.resolveTargets (DESIGN §49: me, ids, c:, r:, #group, %group, f:, *, others, names);
    callers without Config.Admin.StaffPerm get the basic grammar only (me, ids, c:, names).
    Arguments bind left to right, so OPTIONAL PARAMS MUST COME LAST: a missing optional still consumes
    its slot, which makes `{ a? , b }` unusable — registering that order logs a warning.
    `args` reaches the handler keyed by param name; a bad/missing argument answers `Usage: /name <a> [b]`.

    Natives (verified with fxref 2026-09-12): RegisterCommand (shared), GetPlayerName (client+server).
]]

local ns = ...

local IS_SERVER <const> = Core.isServer

local PARAM_TYPES <const> = {
    string = true, integer = true, number = true, boolean = true, player = true, rest = true,
    target = true, targets = true,
}

-- §49 selector errors → Config.Texts key + default text (%s = the selector as typed)
local TARGET_TEXTS <const> = {
    ambiguous = { 'target_ambiguous', "'%s' matches several players: %s" },
    too_many = { 'target_too_many', "'%s' matches too many players" },
    self = { 'target_self', 'You cannot target yourself with this command' },
    not_found = { 'target_not_found', "No player matches '%s'" },
    unknown_group = { 'target_unknown_group', "'%s': no such group" },
    unknown_faction = { 'target_unknown_faction', "'%s': no such faction" },
    bad_radius = { 'target_bad_radius', "'%s': the radius must be 1 to 500 metres" },
    no_origin = { 'target_no_origin', "'%s' needs a position (not available from the console)" },
    bad_selector = { 'target_bad_selector', "'%s' is not a valid target" },
    not_allowed = { 'target_not_allowed', "'%s': only staff can use that kind of target" },
    too_fast = { 'target_too_fast', "'%s': too many target lookups, try again in a moment" },
}

-- R2-7: a selector with a name or set token costs a pass over the players, so a command line holding one is
-- throttled per src like core:admin:run (§51, cooldownMs 100). Lines whose selectors are only ids / me / ^ / c:
-- (O(1) lookups) are not; one line may hold several target params.
local TARGET_COOLDOWN_MS <const> = 100
local lastTargetAt = {}   -- [src] = GetGameTimer() of the last command line that resolved targets

--- True for a selector word made only of O(1) tokens (ids, $ids, me, ^, c:<charId>, their `!` forms). Anything
--- else (names, groups, radius, factions, *, others) or a missing word counts as costly.
local function cheapSelector(word)
    if type(word) ~= 'string' or word == '' or #word > 256 then return word == nil end
    for token in word:gmatch('[^,]+') do
        local t = token:match('^%s*!?%s*(.-)%s*$'):lower()
        if not (t:find('^%$?%d+$') or t == 'me' or t == '^' or t:find('^c:.')) then return false end
    end
    return true
end

-- words accepted by the `boolean` param type
local BOOLEAN_WORDS <const> = {
    ['true'] = true, ['1'] = true, ['on'] = true, ['yes'] = true,
    ['false'] = false, ['0'] = false, ['off'] = false, ['no'] = false,
}

local registered = {}   -- name -> entry { name, description, params, permission, allowConsole }

--- Reads Core.Config.Texts[key] (core's config in every VM, DESIGN §2.0), else `default`.
local function text(key, default)
    local cfg = Core.Config
    local texts = type(cfg) == 'table' and cfg.Texts or nil
    local value = type(texts) == 'table' and texts[key] or nil
    return type(value) == 'string' and value or default
end

--- Answers the caller: chat notification (server, real player), console print (src 0) or client UI.
local function reply(src, message)
    if IS_SERVER then
        if src and src > 0 then
            Core.Notify.send(src, message, 'error')
        else
            print(('[core] %s'):format(message))
        end
    else
        Core.UI.notify(message, 'error')
    end
end

--- `Usage: /car <model> [plate]`
local function usageOf(entry)
    local out = { '/' .. entry.name }
    for i = 1, #entry.params do
        local p = entry.params[i]
        out[#out + 1] = p.optional and ('[' .. p.name .. ']') or ('<' .. p.name .. '>')
    end
    local signature = table.concat(out, ' ')
    -- the format string comes from config: a Texts.usage without %s must not break the usage reply
    local ok, message = pcall(string.format, text('usage', 'Usage: %s'), signature)
    return ok and message or ('Usage: ' .. signature)
end

--- The reply for a selector that did not resolve (§49); unknown errors read as "no player matches".
local function targetMessage(raw, err, detail)
    local entry = TARGET_TEXTS[err] or TARGET_TEXTS.not_found
    local names = ''
    if err == 'ambiguous' and type(detail) == 'table' then
        local list = {}
        for i = 1, math.min(#detail, 10) do
            local c = detail[i]
            list[i] = type(c) == 'table' and ('%s (%s)'):format(tostring(c.name), tostring(c.src)) or tostring(c)
        end
        names = table.concat(list, ', ')
    end
    local ok, message = pcall(string.format, text(entry[1], entry[2]), raw, names)
    return ok and message or entry[2]:gsub('%%s', '?')
end

--- Staff (Config.Admin.StaffPerm, the console always) get the full §49 grammar; everybody else only
--- me / ids / c: / names — no groups, radius, factions, `*`, `others` or `!` (they would reveal staff).
local function isStaff(src)
    if not src or src == 0 then return true end
    local admin = type(Core.Config) == 'table' and Core.Config.Admin or nil
    local perm = type(admin) == 'table' and type(admin.StaffPerm) == 'string' and admin.StaffPerm or 'core.admin'
    local ok, allowed = pcall(Core.Perms.has, src, perm)
    return ok and allowed == true
end

--- `target` / `targets` (server only): Core.Player.resolveTargets is core's getters.lua inside core and
--- the export proxy in a plugin VM. Returns ok, value | false, nil, message.
local function parseTarget(param, raw, src)
    local opts = { max = param.type == 'target' and 1 or param.max, allowSelf = param.allowSelf ~= false,
        basic = not isStaff(src) }
    local ok, list, err, detail = pcall(function()
        return Core.Player.resolveTargets(src or 0, raw, opts)
    end)
    if not ok then
        Core.Log.error('command target %q could not be resolved: %s', raw, tostring(list))
        return false, nil, targetMessage(raw, 'not_found')
    end
    if type(list) ~= 'table' or #list == 0 then return false, nil, targetMessage(raw, err, detail) end
    if param.type == 'target' then return true, list[1] end
    return true, list
end

--- Converts one raw word into the param's type. Returns ok, value (value may legitimately be false),
--- plus a reply text instead of the usage line for a selector that failed.
local function parseValue(param, raw, src)
    local kind = param.type
    if kind == 'target' or kind == 'targets' then return parseTarget(param, raw, src) end
    if kind == 'string' or kind == 'rest' then
        return true, raw
    elseif kind == 'integer' or kind == 'player' then
        local number = tonumber(raw)
        local int = number and math.tointeger(number) or nil
        if not int then return false end
        if kind == 'player' then
            if int < 1 or int > 65535 then return false end
            -- the server can check the id is actually connected; the client only sees its own scope
            if IS_SERVER and (GetPlayerName(int) or '') == '' then return false end
        end
        return true, int
    elseif kind == 'number' then
        local number = tonumber(raw)
        if not number or number ~= number or number == math.huge or number == -math.huge then return false end
        return true, number + 0.0
    elseif kind == 'boolean' then
        local value = BOOLEAN_WORDS[string.lower(raw)]
        if value == nil then return false end
        return true, value
    end
    return false
end

--- Maps the raw word list onto the declared params. Returns args table, or nil + failing param index
--- (+ a reply text when a target selector failed).
local function parseParams(params, args, src)
    local out, index = {}, 1
    if IS_SERVER and type(src) == 'number' and src > 0 then
        for i = 1, #params do
            local word = args[i]
            if (params[i].type == 'target' or params[i].type == 'targets') and not cheapSelector(word) then
                local now = GetGameTimer()
                if now - (lastTargetAt[src] or -TARGET_COOLDOWN_MS) < TARGET_COOLDOWN_MS then
                    return nil, i, targetMessage(tostring(word), 'too_fast')
                end
                lastTargetAt[src] = now
                break
            end
        end
    end
    for i = 1, #params do
        local p = params[i]
        local raw
        if p.type == 'rest' then
            raw = table.concat(args, ' ', index)
            index = #args + 1
        else
            raw = args[index]
            index = index + 1
        end
        if raw == nil or raw == '' then
            if not p.optional then return nil, i end
        else
            local ok, value, message = parseValue(p, raw, src)
            if not ok then return nil, i, message end
            out[p.name] = value
        end
    end
    return out
end

--- Chat suggestion parameter list: { { name = '<model>', help = 'vehicle model' }, ... }
local function suggestionParams(entry)
    local out = {}
    for i = 1, #entry.params do
        local p = entry.params[i]
        out[i] = {
            name = p.optional and ('[' .. p.name .. ']') or ('<' .. p.name .. '>'),
            help = p.help or '',
            type = p.type,
            optional = p.optional == true,
        }
    end
    return out
end

--- Builds the RegisterCommand callback for one entry.
local function makeWrapper(entry, handler)
    return function(source, args, raw)
        local src = source or 0
        if IS_SERVER then
            if src == 0 and not entry.allowConsole then
                print(('[core] /%s cannot be run from the console'):format(entry.name))
                return
            end
            -- console (src 0) always passes the permission check inside Core.Perms.has
            if entry.permission and not Core.Perms.has(src, entry.permission) then
                reply(src, text('no_permission', 'You are not allowed to do that'))
                return
            end
        end

        local parsed, failed, message = parseParams(entry.params, args or {}, src)
        if not parsed then
            Core.Log.debug('command /%s: bad argument #%d (%s)', entry.name, failed, entry.params[failed].name)
            reply(src, message or usageOf(entry))
            return
        end

        local ok, err = pcall(handler, src, parsed, raw)
        if not ok then
            Core.Log.error('command /%s failed: %s', entry.name, tostring(err))
        end
    end
end

--- Validates and copies the declared params; returns nil + index on a bad declaration.
local function normalizeParams(list)
    local out = {}
    for i = 1, #list do
        local p = list[i]
        if type(p) ~= 'table' or type(p.name) ~= 'string' or p.name == '' then return nil, i end
        local kind = p.type or 'string'
        if not PARAM_TYPES[kind] then return nil, i end
        if kind == 'rest' and i ~= #list then return nil, i end
        -- selectors resolve against the server's sessions: a client command cannot take them
        if (kind == 'target' or kind == 'targets') and not IS_SERVER then return nil, i end
        out[i] = { name = p.name, type = kind, help = p.help, optional = p.optional == true,
            max = math.type(p.max) == 'integer' and p.max > 0 and p.max or nil,
            allowSelf = p.allowSelf ~= false }
    end
    return out
end

--- Registers a typed command. Returns the command name.
function ns.register(name, opts, handler)
    if type(name) ~= 'string' or name == '' or name:find('%s') then
        error('Commands.register: name must be a single word', 2)
    end
    opts = opts or {}
    if type(opts) ~= 'table' then error('Commands.register: opts must be a table', 2) end
    if type(handler) ~= 'function' then error('Commands.register: handler must be a function', 2) end

    local params, bad = normalizeParams(opts.params or {})
    if not params then
        error(('Commands.register: /%s has an invalid param #%d'):format(name, bad), 2)
    end

    local entry = {
        name = name,
        description = type(opts.description) == 'string' and opts.description or '',
        params = params,
        permission = type(opts.permission) == 'string' and opts.permission or nil,
        allowConsole = opts.allowConsole ~= false,
        handler = handler,        -- kept for Commands.execute (§23): the same handler, same checks
    }
    registered[name] = entry

    if not IS_SERVER and opts.permission ~= nil then
        Core.Log.warn('/%s: permission is server-only; client commands are unprivileged', name)
    end
    for i = 2, #params do
        if params[i - 1].optional and not params[i].optional then
            Core.Log.warn('/%s: optional param <%s> precedes required <%s>; optional params must come last',
                name, params[i - 1].name, params[i].name)
            break
        end
    end

    -- restricted stays false on purpose: on the SERVER the wrapper enforces entry.permission with
    -- Core.Perms.has(src, perm), so the Core.Perms group fallback keeps working where the ACE-only
    -- `restricted` flag would not (DESIGN §3.7); client-side commands are unprivileged by nature
    -- fxlint-disable-next-line S005 -- permission is enforced server-side by the wrapper above
    RegisterCommand(name, makeWrapper(entry, handler), false)

    if not IS_SERVER then
        TriggerEvent('chat:addSuggestion', '/' .. name, entry.description, suggestionParams(entry))
    end
    return name
end

--- Removes a command from this VM's registry (the engine keeps the binding itself).
function ns.unregister(name)
    if type(name) ~= 'string' then return false end
    if not registered[name] then return false end
    registered[name] = nil
    return true
end

--- The registry entry for `name` (§23 TAB completion), copied — the caller cannot
--- reach the live handler or mutate the params. nil for an unknown name.
function ns.get(name)
    if type(name) ~= 'string' then return nil end
    local entry = registered[name:lower()] or registered[name]
    if not entry then return nil end
    local params = {}
    for i = 1, #entry.params do
        local p = entry.params[i]
        params[i] = {
            name = p.name, type = p.type, help = p.help, optional = p.optional,
        }
    end
    return {
        name = entry.name,
        description = entry.description,
        params = params,
        permission = entry.permission,
        allowConsole = entry.allowConsole,
        usage = usageOf(entry),
    }
end

--- Runs `name` AS IF `src` had typed it (§23, §30.2): the same permission check, the same
--- param parsing and the same handler the engine command would run. Server side only —
--- client-side commands are local to their VM and cannot be reached from the server.
--- Returns true when the command ran. Never throws: a failing handler is logged like the
--- engine path. args are the parsed-by-position words (raw words, not typed values).
function ns.execute(name, src, args, raw)
    if not IS_SERVER then
        Core.Log.error('Commands.execute: server only (use the local command registry client-side)')
        return false
    end
    if type(name) ~= 'string' or name == '' or #name > 64 then return false end
    local entry = registered[name:lower()] or registered[name]
    if not entry then return false end
    if src == nil or src == 0 then
        if not entry.allowConsole then return false end
        src = 0
    end
    if entry.permission and not Core.Perms.has(src, entry.permission) then
        reply(src, text('no_permission', 'You are not allowed to do that'))
        return false
    end
    local wordList = {}
    if type(args) == 'table' then
        for i = 1, math.min(#args, 32) do
            if type(args[i]) == 'string' then wordList[#wordList + 1] = args[i] end
        end
    end
    local parsed, _, message = parseParams(entry.params, wordList, src)
    if not parsed then
        reply(src, message or usageOf(entry))
        return false
    end
    -- the registered handler runs exactly as the engine wrapper would run it (same pcall,
    -- same log shape), so behaviour is IDENTICAL to typing /name into the chat input
    local ok, err = pcall(entry.handler, src, parsed, raw)
    if not ok then
        Core.Log.error('command /%s failed: %s', entry.name, tostring(err))
    end
    return ok
end

--- Everything `src` may use, for the CEF TAB completer (§23): { command, description,
--- params = { { name, help, type, optional } } }. Commands the caller lacks permission for are left out,
--- so a suggestion is never a permission leak.
function ns.suggestions(src)
    local out = {}
    for name, entry in pairs(registered) do
        if IS_SERVER and entry.permission and not Core.Perms.has(src or 0, entry.permission) then
            -- skip silently
        else
            out[#out + 1] = {
                command = '/' .. name,
                description = entry.description,
                params = suggestionParams(entry),
            }
        end
    end
    table.sort(out, function(a, b) return a.command < b.command end)
    return out
end

-- Internal chat snapshot seam: every plugin has its own command VM. Do not enumerate
-- engine commands (that would expose permission-hidden names without useful metadata).
Core.on('chatSuggestionsRequested', function(src)
    if IS_SERVER then
        if Core.name == 'core' or type(src) ~= 'number' or src <= 0 then return end
        TriggerClientEvent('core:client:chat', src, {
            action = 'commandSuggestions', owner = Core.name, items = ns.suggestions(src),
        })
    else
        Core.emitHook('chatSuggestions', Core.name, ns.suggestions())
    end
end)

if IS_SERVER then
    AddEventHandler('playerDropped', function()
        lastTargetAt[source] = nil
    end)

    -- suggestions are pushed per player once their session exists, never broadcast to -1
    AddEventHandler('core:hook:playerLoaded', function(src)
        if type(src) ~= 'number' or src <= 0 then return end
        for name, entry in pairs(registered) do
            if not entry.permission or Core.Perms.has(src, entry.permission) then
                TriggerClientEvent('chat:addSuggestion', src, '/' .. name, entry.description,
                    suggestionParams(entry))
            end
        end
    end)
end
