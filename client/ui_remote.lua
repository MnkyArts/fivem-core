-- core/client/ui_remote.lua
-- The client end of the server-side Core.UI API (DESIGN §21): it owns no UI state
-- of its own, it only forwards what server/ui.lua sends into the local Core.UI
-- (client/ui.lua, DESIGN §6.10).
--   * `core:client:ui (op, args)` — one schema-checked net event for every
--     non-awaiting op; `op` is looked up in an ALLOW-LIST, never used as a raw
--     key into Core.UI, and `args` is the positional argument list.
--   * callbacks `core:ui:progress|menu|input|alert` — each runs the local modal
--     and returns its answer to Core.Callback.awaitClient on the server.
-- Natives: none (SendNUIMessage/focus all live in client/ui.lua).
-- Runtime helpers: Core.Net, Core.Callback, Core.Log (no native calls here).

local UI = Core.UI
local Net = Core.Net
local Callback = Core.Callback
local Log = Core.Log

-- Ops the server may drive, mapped to the flat dotted key on Core.UI (§2.2).
-- Anything not listed here is ignored: the server is trusted, a typo is not.
local OPS <const> = {
    ['open'] = 'open',
    ['close'] = 'close',
    ['send'] = 'send',
    ['textUI.show'] = 'textUI.show',
    ['textUI.hide'] = 'textUI.hide',
    ['hud.setVisible'] = 'hud.setVisible',
    ['keys.show'] = 'keys.show',
    ['keys.hide'] = 'keys.hide',
    ['shard'] = 'shard',
    ['spinner.show'] = 'spinner.show',
    ['spinner.hide'] = 'spinner.hide',
    ['hide'] = 'hide',                 -- §31.5: reason arrives as 'server:<reason>'
    ['show'] = 'show',
}

-- Every op takes at most three arguments (`send(id, event, data)`), so the
-- positional list is unpacked by hand — table.unpack would trip over nil holes.
Net.on('core:client:ui', { 'string', 'any' }, function(op, args)
    local key = type(op) == 'string' and OPS[op] or nil
    if not key then
        Log.warn('core:client:ui: unknown op %s', tostring(op))
        return
    end
    if type(args) ~= 'table' then return end
    -- Resolved per call, not at load time: keys/shard/spinner are added to
    -- Core.UI by client/ui.lua and may be missing in an older client build.
    local fn = UI[key]
    if type(fn) ~= 'function' then
        Log.warn('core:client:ui: Core.UI.%s is not available in this build', key)
        return
    end
    fn(args[1], args[2], args[3])
end)

-- --------------------------------------------------------------- modals ----
-- The handler suspends until the player answers; Core.Callback runs it in the
-- request coroutine and answers `ok = false` if it errors, so a closed shell
-- resolves the server's await with nil instead of hanging it.

Callback.register('core:ui:progress', { 'table' }, function(opts)
    return UI.progress(opts) == true
end)

Callback.register('core:ui:menu', { 'table' }, function(opts)
    return UI['menu.open'](opts)
end)

Callback.register('core:ui:input', { 'table' }, function(opts)
    return UI['input.open'](opts)
end)

Callback.register('core:ui:alert', { 'table' }, function(opts)
    return UI.alert(opts) == true
end)
