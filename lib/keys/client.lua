--[[
    core lib: Core.Keys (DESIGN §3.8) — rebindable key bindings, zero per-frame cost.

    Loaded into the CALLER's VM by import.lua (`local ns = ...`), client side only.

        Core.Keys.register({ name = 'menu', description = 'Open the menu', key = 'F5',
                             mapper = 'keyboard', onPress = fn, onRelease = fn?, debounce = 250,
                             whileFocused = false }) -> commandName

    Uses the +cmd/-cmd convention (patterns/keymapping.lua): the engine calls the commands on key down
    and key up, so nothing polls controls per frame. Presses are swallowed while the NUI has focus or
    the pause menu is open unless `whileFocused` is set. A key-up can get lost (alt-tabbing while the
    key is held), so a press arriving more than STALE_DOWN_MS after the last one is treated as fresh.

    Natives (verified with fxref 2026-09-12): RegisterCommand (shared), RegisterKeyMapping (client),
    IsNuiFocused (client), IsPauseMenuActive (client), GetGameTimer (client+server).
]]

local ns = ...

local DEFAULT_DEBOUNCE_MS <const> = 250
-- after this long a still-"down" binding is assumed to have missed its key-up and is reset
local STALE_DOWN_MS <const> = 5000

local bindings = {}   -- commandName -> { down = bool, downAt = ms, lastPressAt = ms }

--- True while the player is typing in a NUI page or sitting in the pause menu.
local function inputBlocked()
    return IsNuiFocused() or IsPauseMenuActive()
end

--- Runs a binding callback without letting its error kill the key handler.
local function safeCall(fn, commandName)
    if type(fn) ~= 'function' then return end
    local ok, err = pcall(fn)
    if not ok then
        Core.Log.error('key binding %s failed: %s', commandName, tostring(err))
    end
end

--- Registers a `+`/`-` command pair and maps the `+` one to a default key.
--- Returns the `+` command name (the identifier of the binding).
function ns.register(opts)
    if type(opts) ~= 'table' then error('Keys.register: opts must be a table', 2) end
    if type(opts.name) ~= 'string' or opts.name == '' or opts.name:find('%s') then
        error('Keys.register: name must be a single word', 2)
    end
    if type(opts.onPress) ~= 'function' then error('Keys.register: onPress must be a function', 2) end

    local base = ('%s_%s'):format(Core.name, opts.name)
    local pressCommand, releaseCommand = '+' .. base, '-' .. base
    if bindings[pressCommand] then
        error(('Keys.register: %s is already registered'):format(opts.name), 2)
    end

    local debounce = type(opts.debounce) == 'number' and opts.debounce or DEFAULT_DEBOUNCE_MS
    local whileFocused = opts.whileFocused == true
    local onRelease = type(opts.onRelease) == 'function' and opts.onRelease or nil
    local state = { down = false, downAt = 0, lastPressAt = 0 }
    bindings[pressCommand] = state

    -- keybind commands must stay unrestricted (restricted = true would stop players from using them);
    -- they only run local client input callbacks, no privileged action happens here
    -- fxlint-disable-next-line S005 -- client-side keybind command, nothing privileged behind it
    RegisterCommand(pressCommand, function()
        local now = GetGameTimer()
        if state.down then
            -- the matching key-up never arrived (alt-tab while held): release, then take this press
            if now - state.downAt < STALE_DOWN_MS then return end
            state.down = false
            safeCall(onRelease, releaseCommand)
        end
        if not whileFocused and inputBlocked() then return end
        if now - state.lastPressAt < debounce then return end
        state.lastPressAt = now
        state.down = true
        state.downAt = now
        safeCall(opts.onPress, pressCommand)
    end, false)

    -- fxlint-disable-next-line S005 -- release half of the same keybind pair
    RegisterCommand(releaseCommand, function()
        if not state.down then return end
        state.down = false
        safeCall(onRelease, releaseCommand)
    end, false)

    RegisterKeyMapping(pressCommand, opts.description or opts.name,
        opts.mapper or 'keyboard', opts.key or '')
    return pressCommand
end

--- True while the bound key is held down (the `+` command fired, the `-` one did not yet).
function ns.isDown(commandName)
    local state = bindings[commandName]
    return state ~= nil and state.down
end
