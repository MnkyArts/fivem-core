-- core/server/perms.lua
-- Core.Perms (DESIGN §4.4 + §22): console -> ACE -> account grants -> character grants -> config group.
--
-- Account grants live on the account document's `permissions` array and are written through
-- Core.Player.setAccountData, which updates the LIVE session document and persists it. Writing the
-- document directly with Core.DB.update would be undone by the next autosave, because Player.save
-- rewrites `accounts` from session.account.
-- Reads are cached per src (seeded from Core.Player.getAccountData when that exists, otherwise from the
-- account document once per session) and cleared in playerDropped, so an out-of-band edit of the account
-- document is not picked up until the next session.
-- Character grants go through Core.Player.getData/setData, which owns the live character document.

local Perms = {}
Core.Perms = Perms

local DEFAULT_GROUP <const> = 'user'
local ADMIN_GROUP <const> = 'admin'
local ADMIN_PERM <const> = 'core.admin'
local MAX_SRC <const> = 4096
local MAX_PERM <const> = 64

local accountPerms = {}     -- [src] = array of strings, mirror of account.permissions
local charPerms = {}        -- [src] = array of strings, mirror of the character's permissions

local function toSrc(value)
    if type(value) ~= 'number' or value ~= value then return nil end
    local n = math.floor(value)
    if n < 1 or n > MAX_SRC then return nil end
    return n
end

local function groupPerms(group)
    local groups = Config.Perms and Config.Perms.Groups
    return groups and groups[group]
end

local function listHas(list, perm)
    for i = 1, #list do
        if list[i] == perm then return true end
    end
    return false
end

local function isPerm(perm)
    return type(perm) == 'string' and #perm >= 1 and #perm <= MAX_PERM and perm:match('^[%w_%-%.:]+$') ~= nil
end

--- Only the strings of an array, as a fresh table.
local function cleanList(list)
    local out = {}
    if type(list) ~= 'table' then return out end
    for i = 1, #list do
        if type(list[i]) == 'string' then out[#out + 1] = list[i] end
    end
    return out
end

--- The account grants (cached per session), or nil when the player has no session.
local function accountList(src)
    local cached = accountPerms[src]
    if cached then return cached end
    local info = Core.Player.getInfo(src)
    if not info or type(info.accountId) ~= 'string' then return nil end
    local stored
    local getAccountData = Core.Player.getAccountData
    if type(getAccountData) == 'function' then
        stored = getAccountData(src, 'permissions')
    else
        local account = Core.DB.get('accounts', info.accountId)
        stored = account and account.permissions
    end
    local list = cleanList(stored)
    accountPerms[src] = list
    return list
end

--- The character grants, cached per src: Core.Player.getData deep-copies, and Perms.has runs on every
--- command. The cache is dropped on the playerDataChanged hook for `permissions` and in playerDropped.
local function characterList(src)
    local cached = charPerms[src]
    if cached then return cached end
    local list = cleanList(Core.Player.getData(src, 'permissions'))
    charPerms[src] = list
    return list
end

--- The player's group name; DEFAULT_GROUP when there is no session or the stored group is unknown.
--- (Console, src 0, has no group — it is handled in Perms.has directly.)
function Perms.getGroup(src)
    local target = toSrc(src)
    if not target then return DEFAULT_GROUP end
    local info = Core.Player.getInfo(target)
    local group = info and info.group
    if type(group) == 'string' and groupPerms(group) then return group end
    return DEFAULT_GROUP
end

--- console -> ACE -> account grants -> character grants -> config group ('core.admin' in the group
--- implies everything the admin group lists).
function Perms.has(src, perm)
    if type(perm) ~= 'string' or perm == '' then return false end
    if src == 0 then return true end
    local target = toSrc(src)
    if not target then return false end
    if IsPlayerAceAllowed(tostring(target), perm) then return true end
    local granted = accountList(target)
    if granted and listHas(granted, perm) then return true end
    if listHas(characterList(target), perm) then return true end
    local list = groupPerms(Perms.getGroup(target))
    if type(list) ~= 'table' then return false end
    if listHas(list, perm) then return true end
    if listHas(list, ADMIN_PERM) then
        local adminList = groupPerms(ADMIN_GROUP)
        if type(adminList) == 'table' and listHas(adminList, perm) then return true end
    end
    return false
end

function Perms.isAdmin(src)
    return Perms.has(src, ADMIN_PERM)
end

--- Move the player to another configured group. Core.Player.setGroup is the single source of truth:
--- it updates the live account document, persists it and re-replicates the `group` state-bag key.
function Perms.setGroup(src, group)
    local target = toSrc(src)
    if not target or type(group) ~= 'string' or not groupPerms(group) then return false end
    if Core.Player.setGroup(target, group) ~= true then return false end
    Core.Log.audit('perms', target, 'group set to %s', group)
    return true
end

--- Grant a permission. scope 'account' (default, survives a character change) or 'character'.
--- Idempotent: granting twice returns true without a second write.
function Perms.grant(src, perm, scope)
    local target = toSrc(src)
    if not target or not isPerm(perm) then return false end
    scope = scope or 'account'
    if scope ~= 'account' and scope ~= 'character' then return false end

    if scope == 'account' then
        local list = accountList(target)
        if not list then return false end
        if listHas(list, perm) then return true end
        local updated = cleanList(list)
        updated[#updated + 1] = perm
        if Core.Player.setAccountData(target, 'permissions', updated) ~= true then return false end
        accountPerms[target] = updated
    else
        local list = characterList(target)
        if listHas(list, perm) then return true end
        local updated = cleanList(list)
        updated[#updated + 1] = perm
        if Core.Player.setData(target, 'permissions', updated) ~= true then return false end
        charPerms[target] = updated
    end

    Core.Log.audit('perms', target, 'granted %s (%s)', perm, scope)
    return true
end

--- Remove a permission from the account (default) or the character. False when it was not there.
function Perms.revoke(src, perm, scope)
    local target = toSrc(src)
    if not target or not isPerm(perm) then return false end
    scope = scope or 'account'
    if scope ~= 'account' and scope ~= 'character' then return false end

    local list = (scope == 'account') and accountList(target) or characterList(target)
    if not list or not listHas(list, perm) then return false end
    local updated = {}
    for i = 1, #list do
        if list[i] ~= perm then updated[#updated + 1] = list[i] end
    end

    if scope == 'account' then
        if Core.Player.setAccountData(target, 'permissions', updated) ~= true then return false end
        accountPerms[target] = updated
    elseif Core.Player.setData(target, 'permissions', updated) ~= true then
        return false
    else
        charPerms[target] = updated
    end

    Core.Log.audit('perms', target, 'revoked %s (%s)', perm, scope)
    return true
end

--- Everything the player holds: config group, account grants, character grants — deduped, in that order.
--- ACE permissions cannot be enumerated and are therefore not part of the list.
function Perms.list(src)
    local out, seen = {}, {}
    local target = toSrc(src)
    if not target then return out end
    local function add(list)
        for i = 1, #list do
            local perm = list[i]
            if type(perm) == 'string' and not seen[perm] then
                seen[perm] = true
                out[#out + 1] = perm
            end
        end
    end
    add(groupPerms(Perms.getGroup(target)) or {})
    add(accountList(target) or {})
    add(characterList(target))
    return out
end

-- Someone else wrote the character's permissions (Player.setData, an admin tool): drop the cache.
Core.on('playerDataChanged', function(src, topKey)
    if topKey == 'permissions' then charPerms[src] = nil end
end)

AddEventHandler('playerDropped', function()
    local src = source
    if src == nil then return end
    accountPerms[src] = nil
    charPerms[src] = nil
end)
