--[[
    core/client/settings.lua — the client read side of Core.Settings (DESIGN §45).

    Only `replicate = true` keys reach clients: server/settings.lua mirrors each one to
    GlobalState['cs:<key>'] and the sorted list of them to GlobalState['cs:keys'] (server writes,
    clients read, §8). Plugins read through the proxy:

      Core.Settings.get(key) -> value                  (nil for a key that does not replicate)
      Core.on('settingChanged', fn(key, new, old))     client hook, every client VM

    `old` needs the last value seen. A state-bag change handler never fires for keys that already
    existed when this script started (AGENTS §8), so that cache is seeded from the index once it is
    there (GlobalState lands shortly after the join, like client/environment.lua's boot seed). A key
    that leaves the index (its owner stopped, or it stopped replicating) emits one change with
    new = nil, whether or not the nil write itself reached this client.

    Natives: AddStateBagChangeHandler (shared). GlobalState/CreateThread/Wait are runtime helpers.
]]

local Settings = {}
Core.Settings = Settings

local Utils = Core.Utils

local PREFIX <const> = 'cs:'
local PREFIX_LEN <const> = #PREFIX
local INDEX_KEY <const> = 'cs:keys'
local KEY_MAX <const> = 64
local SEED_TRIES <const> = 20          -- 20 x 500 ms, then a server without replicated settings is left alone
local SEED_WAIT_MS <const> = 500

local cache = {}   -- [key] = last value seen (a copy)
local seen = {}    -- [key] = true while the key holds a value here

--- Same key rule as the server: '<id>.<segment>(.<segment>)*', at most 64 bytes.
local function isKey(v)
    if type(v) ~= 'string' or #v > KEY_MAX then return false end
    if not v:find('^[%a_][%w_]*%.[%w_%.]*[%w_]$') then return false end
    return v:find('..', 1, true) == nil
end

local function copy(v)
    if type(v) == 'table' then return Utils.deepCopy(v) end
    return v
end

local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- The replicated effective value of `key` (deep copy for tables), or nil.
function Settings.get(key)
    if not isKey(key) then return nil end
    return copy(GlobalState[PREFIX .. key])
end

--- Records a value and emits `settingChanged` when it differs from the last one seen.
local function apply(key, value)
    local old = cache[key]
    if value == nil then
        if not seen[key] then return end
        cache[key], seen[key] = nil, nil
        Core.emitHook('settingChanged', key, nil, old)
        return
    end
    if seen[key] and deepEqual(old, value) then return end
    cache[key], seen[key] = copy(value), true
    Core.emitHook('settingChanged', key, copy(value), old)
end

--- The index changed: keys that left it are gone; a listed key this client never saw (its own write
--- was dropped) is read once.
local function reconcile(list)
    local keep = {}
    if type(list) == 'table' then
        for i = 1, #list do
            if isKey(list[i]) then keep[list[i]] = true end
        end
    end
    for key in pairs(seen) do
        if not keep[key] then apply(key, nil) end    -- clearing a field during pairs is allowed
    end
    for key in pairs(keep) do
        if not seen[key] then apply(key, GlobalState[PREFIX .. key]) end
    end
end

-- A nil key filter matches every key of the global bag, so the prefix test comes first (like doors).
AddStateBagChangeHandler(nil, 'global', function(_, key, value)
    if type(key) ~= 'string' or key:sub(1, PREFIX_LEN) ~= PREFIX then return end
    if key == INDEX_KEY then
        reconcile(value)
        return
    end
    local name = key:sub(PREFIX_LEN + 1)
    if isKey(name) then apply(name, value) end
end)

--- Seeds the cache from what was already replicated; no hook for these (nothing changed).
--- Keys the handler saw first are left alone. True once the index was found.
local function seed()
    local list = GlobalState[INDEX_KEY]
    if type(list) ~= 'table' then return false end
    for i = 1, #list do
        local key = list[i]
        if isKey(key) and not seen[key] then
            local value = GlobalState[PREFIX .. key]
            if value ~= nil then cache[key], seen[key] = copy(value), true end
        end
    end
    return true
end

CreateThread(function()
    for _ = 1, SEED_TRIES do
        if seed() then return end
        Wait(SEED_WAIT_MS)
    end
end)
