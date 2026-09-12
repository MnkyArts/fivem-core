--[[
    core / lib/log/shared.lua  —  Core.Log (DESIGN §3.4)

    `string.format`-style logging, printed as `[core:<resource>] level: message`
    with `^3` / `^1` console colours for warn / error. `debug` is a no-op unless
    `Core.Config.Debug` is true. The value is re-read on every call; inside core
    that tracks `Config` live, while plugin VMs see changes after a core restart
    (import.lua caches `Core.Config` and invalidates it then).

    `audit` is server-only: it is guarded by `IsDuplicityVersion()` at call time
    (this chunk is shared, so it loads in client VMs too) and additionally emits
    the local hook `core:hook:audit (category, src, message)` for logging plugins.
    Never log identifiers beyond `src` and the player name.

    Natives: IsDuplicityVersion (shared).
]]

local ns = ...

local RESET <const> = '^7'

local function resourceName()
    return (Core and Core.name) or 'core'
end

--- `string.format` that can never throw in the caller's face.
local function safeFormat(fmt, ...)
    if type(fmt) ~= 'string' then return tostring(fmt) end
    if select('#', ...) == 0 then return fmt end
    local ok, msg = pcall(string.format, fmt, ...)
    if ok then return msg end
    return fmt .. ' <invalid format arguments>'
end

local function emit(level, colour, fmt, ...)
    local msg = safeFormat(fmt, ...)
    if colour then
        print(('%s[core:%s] %s: %s%s'):format(colour, resourceName(), level, msg, RESET))
    else
        print(('[core:%s] %s: %s'):format(resourceName(), level, msg))
    end
    return msg
end

function ns.info(fmt, ...)
    return emit('info', nil, fmt, ...)
end

function ns.warn(fmt, ...)
    return emit('warn', '^3', fmt, ...)
end

function ns.error(fmt, ...)
    return emit('error', '^1', fmt, ...)
end

--- No-op unless `Core.Config.Debug`.
function ns.debug(fmt, ...)
    local cfg = Core and Core.Config   -- lazy: core's config, never the plugin's own `Config` (DESIGN §2.0)
    if not (cfg and cfg.Debug) then return end
    return emit('debug', nil, fmt, ...)
end

--- Server-only audit line + `core:hook:audit` for a logging plugin.
--- @return boolean written
function ns.audit(category, src, fmt, ...)
    if not IsDuplicityVersion() then return false end
    local message = safeFormat(fmt, ...)
    local cat = tostring(category)
    print(('[core:audit] %s src=%s %s'):format(cat, tostring(src), message))
    if Core and type(Core.emitHook) == 'function' then
        Core.emitHook('audit', cat, src, message)
    else
        TriggerEvent('core:hook:audit', cat, src, message)
    end
    return true
end
