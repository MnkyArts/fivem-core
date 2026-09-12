--[[
    core lib: Core.UI sugar (DESIGN §3.12) — page event subscriptions, in this VM.

    Loaded into the CALLER's VM by import.lua (`local ns = ...`), client side only.

        local handle = Core.UI.on(pageId, event, fn(data))   -- 'core:ui:<pageId>:<event>'
        Core.UI.off(handle)

    Only `on`/`off` live here: every other Core.UI call (registerPage, open, notify, menu, input,
    progress, textUI, hud) proxies into core's client/ui.lua (DESIGN §6.10).

    Natives: none — AddEventHandler/RemoveEventHandler are runtime helpers.
]]

local ns = ...

--- Subscribes to an event a NUI page sent back to the game. Returns the handler handle, or nil.
function ns.on(pageId, event, fn)
    if type(pageId) ~= 'string' or pageId == '' then return nil end
    if type(event) ~= 'string' or event == '' then return nil end
    if type(fn) ~= 'function' then return nil end
    return AddEventHandler(('core:ui:%s:%s'):format(pageId, event), fn)
end

--- Removes a subscription created by Core.UI.on.
function ns.off(handle)
    if handle == nil then return false end
    RemoveEventHandler(handle)
    return true
end
