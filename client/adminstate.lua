--[[
    core/client/adminstate.lua — the staff state a client may know (DESIGN §51): its OWN duty and modes, and,
    only while it is on duty itself, the duty and modes of every on-duty staff member. The server keeps both
    as session state and never puts them in a replicated state bag (every client could read who is on duty,
    vanished or spectating); it sends them here instead:

      core:admin:self         { duty, modes = { [name] = true } }        to the player itself
      core:admin:staffState   { src, duty, modes? }                      to on-duty staff, on every change
      core:admin:staffStates  { { src, duty, modes }, … }                once, when this player goes on duty

    Display only — the server re-checks everything. Plugins read it through the proxy:

      Core.Admin.getSelf() -> { duty, modes }
      Core.Admin.getStaffStates() -> { [src] = { duty, modes } }       (empty unless this player is on duty)
      Core.on('staffSelfChanged', fn(state))                            client hooks, every client VM
      Core.on('staffStateChanged', fn(src, state|nil))                  nil = left duty / dropped / map cleared

    Natives: none (RegisterNetEvent and TriggerEvent are runtime helpers).
]]

local Admin = {}
Core.Admin = Admin

local MAX_MODES <const> = 16
local MAX_STAFF <const> = 4096
local MODE_PATTERN <const> = '^%a[%w_]*$'

local own = { duty = false, modes = {} }
local staff = {}   -- [src] = { duty = true, modes = { [name] = true } } while this client is on duty

--- { [name] = true } from a server payload: string names only, bounded.
local function cleanModes(value)
    local out, n = {}, 0
    if type(value) ~= 'table' then return out end
    for mode, on in pairs(value) do
        if n >= MAX_MODES then break end
        if on == true and type(mode) == 'string' and #mode <= 32 and mode:match(MODE_PATTERN) then
            out[mode] = true
            n = n + 1
        end
    end
    return out
end

local function copyState(state)
    local modes = {}
    for mode in pairs(state.modes) do modes[mode] = true end
    return { duty = state.duty, modes = modes }
end

local function toSrc(value)
    local n = type(value) == 'number' and math.tointeger(value) or nil
    return (n and n >= 1 and n <= 65535) and n or nil
end

--- Forget every staff entry (this client left duty), telling the listeners each one is gone.
local function clearStaff()
    local list = {}
    for src in pairs(staff) do list[#list + 1] = src end
    table.sort(list)
    staff = {}
    for i = 1, #list do Core.emitHook('staffStateChanged', list[i], nil) end
end

--- One entry: set while on duty, removed otherwise; the hook fires on every change.
local function applyStaff(src, entry)
    if type(entry) ~= 'table' or entry.duty ~= true then
        if staff[src] then
            staff[src] = nil
            Core.emitHook('staffStateChanged', src, nil)
        end
        return
    end
    local state = { duty = true, modes = cleanModes(entry.modes) }
    staff[src] = state
    Core.emitHook('staffStateChanged', src, copyState(state))
end

RegisterNetEvent('core:admin:self', function(state)
    if type(state) ~= 'table' then return end
    own = { duty = state.duty == true, modes = cleanModes(state.modes) }
    if not own.duty then clearStaff() end
    Core.emitHook('staffSelfChanged', copyState(own))
end)

RegisterNetEvent('core:admin:staffState', function(entry)
    if not own.duty or type(entry) ~= 'table' then return end
    local src = toSrc(entry.src)
    if src then applyStaff(src, entry) end
end)

-- The full list, once, when this client goes on duty: entries missing from it are gone.
RegisterNetEvent('core:admin:staffStates', function(list)
    if not own.duty or type(list) ~= 'table' then return end
    local listed = {}
    for i = 1, math.min(#list, MAX_STAFF) do
        local entry = list[i]
        local src = type(entry) == 'table' and toSrc(entry.src) or nil
        if src and entry.duty == true then listed[src] = entry end
    end
    local gone = {}
    for src in pairs(staff) do
        if not listed[src] then gone[#gone + 1] = src end
    end
    table.sort(gone)
    for i = 1, #gone do applyStaff(gone[i], nil) end
    for src, entry in pairs(listed) do applyStaff(src, entry) end
end)

--- This player's own staff state: { duty, modes = { [name] = true } } (a copy).
function Admin.getSelf()
    return copyState(own)
end

--- { [src] = { duty, modes } } of every on-duty staff member — empty unless this player is on duty.
function Admin.getStaffStates()
    local out = {}
    if not own.duty then return out end
    for src, state in pairs(staff) do out[src] = copyState(state) end
    return out
end
