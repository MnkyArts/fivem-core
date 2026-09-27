-- core/server/perms.lua
-- Core.Perms (DESIGN §4.4, §22, §44): console -> ACE -> account grants -> character grants -> group chain.
--
-- Grants: the account's `permissions`/`tempPermissions` (the LIVE session: Player.getAccountData/setAccountData) and
-- the character's (Player.getData/setData), cached per src; the caches drop on playerDataChanged, permsChanged
-- 'grants'|'group' and playerDropped. Temporary grants: `tempPermissions = { [perm] = expiresAt }` (unix seconds) NEXT
-- to the plain-string arrays; expired entries are ignored at once, pruned on cache build and by one per-player timer
-- (hook `expired`). Perms.has and its whole path never yield: no DB read (§56.8 rule 2).
-- Groups: table `perm_groups` (small: loaded whole), seeded once from Config.Perms, then the truth; loaded in a
-- thread, the config seed answers until then (groups/groupExists/effective/saveGroup/deleteGroup wait for a running
-- load when they can yield). saveGroup/deleteGroup AWAIT their upsert/delete; the seed and define defaults are QUEUED
-- saves (start, a plugin's file scope). Resolved sets (inherits, cycle-guarded, + "'core.admin' implies the admin
-- chain") are cached, dropped on any change. `removed` (a text[] row column, a set in memory) remembers what an
-- owner took out of a group, so `define`'s default is added once, ever.
--
-- Natives: IsPlayerAceAllowed(playerSrc, object) (server, BOOL: read by truthiness), GetGameTimer() (server).
-- GetPlayers, CreateThread, SetTimeout and Citizen.Await are runtime helpers, not natives.

local Perms = {}
Core.Perms = Perms

local DEFAULT_GROUP <const>, ADMIN_GROUP <const>, ADMIN_PERM <const> = 'user', 'admin', 'core.admin'
local MANAGE_PERM <const>, TABLE <const>, TEMP_KEY <const> = 'core.perms.manage', 'perm_groups', 'tempPermissions'
local DEF_KIND <const>, MAX_SRC <const>, MAX_PERM <const>, MAX_GROUP_NAME <const> = 'permDef', 4096, 64, 32
local MAX_LABEL <const>, MAX_TEXT <const>, MAX_CATEGORY <const> = 64, 256, 32
local MAX_GROUP_PERMS <const>, MAX_INHERITS <const>, MAX_WEIGHT <const> = 512, 16, 1000000
local MAX_TEMP_SECONDS <const> = 10 * 365 * 86400   -- a temporary grant runs at most ten years
local LOAD_RETRY_MS <const>, EXPIRY_MARGIN_MS <const> = 30000, 1000

local accountPerms = {}     -- [src] = { list = { perm }, set = { [perm] = true }, temp = { [perm] = expiresAt } }
local charPerms = {}        -- [src] = the same shape, for the active character
local expiry = {}           -- [src] = { at, token, accountId }: the one armed expiry timer per player
local expirySerial = 0
local groupAnnounced = false   -- Player.setGroup announced the change itself (Perms.setGroup does not repeat it)

local groupDocs = {}        -- [name] = normalized group document (the config seed until the collection is read)
local resolved = {}         -- [name] = { set = { [perm] = true }, list = { perm } }, dropped on any group change
local groupState = 'cold'   -- 'cold' -> 'loading' -> 'ready' | 'fallback' (unreadable, retried after LOAD_RETRY_MS)
local loadBarrier = nil     -- promise while a load is in flight
local retryAt = 0
local defs = {}             -- [perm] = { perm, label, description, category, owner, default }

local function toSrc(value)
    if type(value) ~= 'number' or value ~= value then return nil end
    local n = math.floor(value)
    if n < 1 or n > MAX_SRC then return nil end
    return n
end

--- A finite number floored to an integer, or nil.
local function toInt(value)
    if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then return nil end
    return math.floor(value)
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

local function isGroupName(name)
    return type(name) == 'string' and #name >= 1 and #name <= MAX_GROUP_NAME and name:match('^[%w_%-]+$') ~= nil
end

local function isColor(value)
    return type(value) == 'string' and value:match('^#%x%x%x%x%x%x$') ~= nil
end

--- A trimmed, bounded string or nil.
local function text(value, max)
    if type(value) ~= 'string' then return nil end
    value = value:match('^%s*(.-)%s*$')
    if value == '' then return nil end
    return value:sub(1, max)
end

--- Valid (`valid(v)`), deduplicated entries of an array other than `self`, at most `max`, as a fresh table.
local function cleanArray(list, valid, max, self)
    local out, seen = {}, {}
    if type(list) ~= 'table' then return out end
    for i = 1, #list do
        local v = list[i]
        if valid(v) and v ~= self and not seen[v] then
            seen[v] = true
            out[#out + 1] = v
            if #out >= max then break end
        end
    end
    return out
end

local function isString(v) return type(v) == 'string' end

--- The (deduplicated) strings of an array, as a fresh table.
local function cleanList(list) return cleanArray(list, isString, math.huge) end

--- A { [perm] = expiresAt } map with only valid entries that are still running; `pruned` = something was dropped.
local function cleanTemp(map, now)
    local out, pruned = {}, false
    if type(map) ~= 'table' then return out, false end
    for perm, at in pairs(map) do
        local expiresAt = toInt(at)
        if isPerm(perm) and expiresAt and expiresAt > now then
            out[perm] = expiresAt
        else
            pruned = true
        end
    end
    return out, pruned
end

local function copyMap(map)
    local out = {}
    for k, v in pairs(map) do out[k] = v end
    return out
end

local function newState(list, temp)
    local set = {}
    for i = 1, #list do set[list[i]] = true end
    return { list = list, set = set, temp = temp }
end

--- permsChanged (src|nil, what, detail?) — src nil = a whole group (or the group table) changed.
local function changed(src, what, detail)
    Core.emitHook('permsChanged', src, what, detail)
end

--- A group change as a persisted audit row (§46) when Core.Audit is there, the console audit line otherwise.
local function groupAudit(actorSrc, action, name, result, message, changes)
    local A = Core.Audit
    if A and A.record then
        local ok, err = pcall(A.record, { actor = actorSrc or 'system', action = action, result = result,
            targets = { { type = 'group', id = name } }, changes = changes, message = message })
        if not ok then Core.Log.error('perms: Audit.record failed: %s', tostring(err)) end
        return
    end
    Core.Log.audit('perms', actorSrc or 0, '%s %s: %s%s', action, name, result, message and (' ' .. message) or '')
end

-- == Groups: normalisation, the config seed, loading and resolution =========================================

--- `removed` as a { [perm] = true } set — from the row's text[] (or an in-memory set).
local function cleanRemoved(value)
    local out = {}
    if type(value) ~= 'table' then return out end
    for key, flag in pairs(value) do
        local perm = math.type(key) == 'integer' and flag or (flag == true and key or nil)
        if isPerm(perm) then out[perm] = true end
    end
    return out
end

local function normalizeGroup(name, doc)
    doc = type(doc) == 'table' and doc or {}
    local weight = toInt(doc.weight)
    if not weight or weight < 0 or weight > MAX_WEIGHT then
        local weights = Config.Perms and Config.Perms.Weights
        weight = toInt(weights and weights[name]) or 0
    end
    return {
        name = name,
        label = text(doc.label, MAX_LABEL) or name,
        weight = weight,
        inherits = cleanArray(doc.inherits, isGroupName, MAX_INHERITS, name),
        perms = cleanArray(doc.perms, isPerm, MAX_GROUP_PERMS),
        removed = cleanRemoved(doc.removed),
        color = isColor(doc.color) and doc.color or nil,
    }
end

local function copyGroup(doc)
    return {
        name = doc.name, label = doc.label, weight = doc.weight, color = doc.color,
        inherits = cleanList(doc.inherits), perms = cleanList(doc.perms), removed = copyMap(doc.removed),
    }
end

--- The groups of Config.Perms (Groups + Weights + Inherits), in memory only.
local function seedGroups()
    local cfg = Config.Perms or {}
    local groups, inherits = cfg.Groups or {}, cfg.Inherits or {}
    local out = {}
    for name, perms in pairs(groups) do
        if isGroupName(name) then
            out[name] = normalizeGroup(name, {
                label = name:sub(1, 1):upper() .. name:sub(2), inherits = inherits[name], perms = perms,
            })
        end
    end
    if not out[DEFAULT_GROUP] then out[DEFAULT_GROUP] = normalizeGroup(DEFAULT_GROUP, { label = 'User' }) end
    return out
end

for name, doc in pairs(seedGroups()) do groupDocs[name] = doc end

--- The perm_groups row of a normalized group (`removed` as a sorted text[], no colour = NULL).
local function groupRow(doc)
    local removed = {}
    for perm in pairs(doc.removed) do removed[#removed + 1] = perm end
    table.sort(removed)
    return { name = doc.name, label = doc.label, weight = doc.weight, inherits = cleanList(doc.inherits),
        perms = cleanList(doc.perms), removed = removed, color = doc.color or Core.DB.NULL }
end

--- A queued save of one group (never yields: the seed and define defaults run at start / a plugin's file scope).
local function queueGroup(doc)
    local ok, err = Core.DB.save(TABLE, groupRow(doc))
    if not ok then Core.Log.error('perms: group %s was not queued (%s)', doc.name, tostring(err)) end
    return ok == true
end

--- Add a define's default perm to its group once: never when the group lists it or an owner removed it.
local function applyDefault(def)
    local doc = def.default and groupDocs[def.default]
    if not doc or doc.removed[def.perm] or listHas(doc.perms, def.perm) then return false end
    local updated = copyGroup(doc)
    updated.perms[#updated.perms + 1] = def.perm
    if not queueGroup(updated) then return false end
    groupDocs[doc.name] = updated
    resolved = {}
    return true
end

local GROUPS_SQL <const> = 'SELECT name, label, weight, inherits, perms, removed, color FROM perm_groups'

--- Read `perm_groups` whole (seeding it on the very first start). Runs in a thread (ensureGroups).
local function loadGroups()
    local ok, err = pcall(function()
        local rows, readErr = Core.DB.query(GROUPS_SQL, nil, { sync = true })
        if not rows then error(readErr or 'the table could not be read', 0) end   -- never seed over a failed read
        local loaded, seeded = {}, 0
        if #rows == 0 then
            loaded = seedGroups()
            for _, doc in pairs(loaded) do seeded = seeded + (queueGroup(doc) and 1 or 0) end
            Core.Log.info('perms: seeded %d group(s) into %s from Config.Perms', seeded, TABLE)
        else
            for _, row in ipairs(rows) do
                if isGroupName(row.name) then loaded[row.name] = normalizeGroup(row.name, row) end
            end
            if not loaded[DEFAULT_GROUP] then
                loaded[DEFAULT_GROUP] = normalizeGroup(DEFAULT_GROUP, { label = 'User' })
                queueGroup(loaded[DEFAULT_GROUP])
            end
        end
        groupDocs = loaded
        resolved = {}
        groupState = 'ready'
        for _, def in pairs(defs) do applyDefault(def) end
    end)
    if not ok then
        groupState = 'fallback'
        retryAt = GetGameTimer() + LOAD_RETRY_MS
        Core.Log.error('perms: %s could not be loaded (%s); using Config.Perms until it can', TABLE, tostring(err))
    end
    local barrier = loadBarrier
    loadBarrier = nil   -- before resolving: a waiter that resumes sees the finished state
    if barrier then barrier:resolve(true) end
    if ok then changed(nil, 'load') end
end

--- The group documents (the config seed until perm_groups was read). The first call starts the load in a thread;
--- `wait` = a caller that can yield waits for a running load (the check path never does: Perms.has never yields).
local function ensureGroups(wait)
    if groupState == 'ready' then return groupDocs end
    if groupState == 'fallback' and GetGameTimer() < retryAt then return groupDocs end
    if groupState ~= 'loading' then
        groupState = 'loading'
        loadBarrier = promise.new()
        CreateThread(loadGroups)
    end
    if wait and loadBarrier and coroutine.isyieldable() then pcall(Citizen.Await, loadBarrier) end
    return groupDocs
end

--- The resolved chain of a group: its perms, then each inherited group's (depth first, each group once — so a
--- cycle ends), then — when the chain holds 'core.admin' — the admin group's chain (legacy rule, §4.4).
--- `origin[perm]` = the first group of that walk that lists the perm itself (Perms.explain).
local function resolveGroup(name)
    local cached = resolved[name]
    if cached then return cached end
    local docs = ensureGroups()
    local set, list, origin, visited = {}, {}, {}, {}
    local function walk(n)
        if visited[n] then return end
        visited[n] = true
        local doc = docs[n]
        if not doc then return end
        for i = 1, #doc.perms do
            local perm = doc.perms[i]
            if not set[perm] then
                set[perm], origin[perm] = true, n
                list[#list + 1] = perm
            end
        end
        for i = 1, #doc.inherits do walk(doc.inherits[i]) end
    end
    walk(name)
    if set[ADMIN_PERM] then walk(ADMIN_GROUP) end
    local chain = { set = set, list = list, origin = origin }
    resolved[name] = chain
    return chain
end

--- True when `target` is reachable from `from` over the stored `inherits` (saveGroup's cycle check).
local function reaches(from, target)
    local visited = {}
    local function walk(n)
        if n == target then return true end
        if visited[n] or not groupDocs[n] then return false end
        visited[n] = true
        for _, parent in ipairs(groupDocs[n].inherits) do
            if walk(parent) then return true end
        end
        return false
    end
    return walk(from)
end

-- == Per-player grants (account + character), temporary grants and their expiry =============================

local function setState(src, scope, state)
    if scope == 'account' then accountPerms[src] = state else charPerms[src] = state end
end

--- One grant key of the account (Player.setAccountData) or the character (Player.setData): both queue, never yield.
local function write(src, scope, key, value)
    if scope == 'account' then return Core.Player.setAccountData(src, key, value) == true end
    return Core.Player.setData(src, key, value) == true
end

--- Permanent or a temporary grant that is still running.
local function stateHolds(state, perm)
    if state.set[perm] then return true end
    local at = state.temp[perm]
    return at ~= nil and at > os.time()
end

--- Drop the expired temporary grants of one cached scope; true when something was removed.
local function pruneScope(src, scope, now)
    local state = (scope == 'account') and accountPerms[src] or charPerms[src]
    if not state then return false end
    local temp, pruned = cleanTemp(state.temp, now)
    if not pruned then return false end
    if not write(src, scope, TEMP_KEY, temp) then return false end
    setState(src, scope, newState(state.list, temp))
    return true
end

--- The soonest expiry of the player's cached temporary grants, or nil.
local function soonestExpiry(src)
    local best
    for _, state in ipairs({ accountPerms[src] or false, charPerms[src] or false }) do
        if state then
            for _, at in pairs(state.temp) do
                if not best or at < best then best = at end
            end
        end
    end
    return best
end

--- One armed timer per player, for the soonest expiry; an earlier expiry supersedes it (token). When it fires
--- for the same session, the expired grants are pruned, audited and announced, and the next one is armed.
local function armExpiry(src)
    local at = soonestExpiry(src)
    if not at then return end
    local current = expiry[src]
    if current and current.at <= at then return end
    local info = Core.Player.getInfo(src)
    if not info then return end
    expirySerial = expirySerial + 1
    local token, accountId = expirySerial, info.accountId
    expiry[src] = { at = at, token = token, accountId = accountId }
    SetTimeout(math.max(0, at - os.time()) * 1000 + EXPIRY_MARGIN_MS, function()
        local entry = expiry[src]
        if not entry or entry.token ~= token then return end    -- superseded, or the player dropped
        expiry[src] = nil
        local live = Core.Player.getInfo(src)
        if not live or live.accountId ~= accountId then return end
        local stamp = os.time()
        local character = pruneScope(src, 'character', stamp)   -- first: an account write drops both caches
        local account = pruneScope(src, 'account', stamp)
        if account or character then
            Core.Log.audit('perms', src, 'temporary grant(s) expired')
            changed(src, 'expired')
        end
        armExpiry(src)
    end)
end

--- The account grants (cached per session), or nil when the player has no session. Read from the LIVE session
--- (Player.getAccountData: synchronous copies, never the DB), so a permission check never yields.
local function accountState(src)
    local cached = accountPerms[src]
    if cached then return cached end
    local player = Core.Player
    if not player.isLoaded(src) then return nil end
    local temp, pruned = cleanTemp(player.getAccountData(src, TEMP_KEY), os.time())
    if pruned then player.setAccountData(src, TEMP_KEY, temp) end   -- write first: the hook drops accountPerms[src]
    local state = newState(cleanList(player.getAccountData(src, 'permissions')), temp)
    accountPerms[src] = state
    if next(temp) then armExpiry(src) end
    return state
end

--- The character grants, cached per src: Core.Player.getData deep-copies, and Perms.has runs on every
--- command. The cache is dropped on the playerDataChanged hook for `permissions`/`tempPermissions` and in
--- playerDropped. Nil (and nothing cached) while the player has no session.
local function characterState(src)
    local cached = charPerms[src]
    if cached then return cached end
    if not Core.Player.isLoaded(src) then return nil end
    local temp, pruned = cleanTemp(Core.Player.getData(src, TEMP_KEY), os.time())
    if pruned then Core.Player.setData(src, TEMP_KEY, temp) end   -- write first: the hook drops charPerms[src]
    local state = newState(cleanList(Core.Player.getData(src, 'permissions')), temp)
    charPerms[src] = state
    if next(temp) then armExpiry(src) end
    return state
end

local function stateOf(src, scope)
    if scope == 'account' then return accountState(src) end
    return characterState(src)
end

-- == Checks (DESIGN §4.4) — the order is unchanged: console -> ACE -> account -> character -> group chain ===

--- The player's group name; DEFAULT_GROUP when there is no session or the stored group does not exist.
--- (Console, src 0, has no group — it is handled in Perms.has directly.)
function Perms.getGroup(src)
    local target = toSrc(src)
    if not target then return DEFAULT_GROUP end
    local info = Core.Player.getInfo(target)
    local group = info and info.group
    if type(group) == 'string' and ensureGroups()[group] then return group end
    return DEFAULT_GROUP
end

--- True when a group of that name exists (Player.setGroup asks this, §44).
function Perms.groupExists(name)
    return isGroupName(name) and ensureGroups(true)[name] ~= nil
end

--- console -> ACE -> account grants -> character grants -> the group chain (inherits + the legacy
--- "'core.admin' implies the admin group" rule).
function Perms.has(src, perm)
    if type(perm) ~= 'string' or perm == '' then return false end
    if src == 0 then return true end
    local target = toSrc(src)
    if not target then return false end
    if IsPlayerAceAllowed(tostring(target), perm) then return true end
    local account = accountState(target)
    if account and stateHolds(account, perm) then return true end
    local character = characterState(target)
    if character and stateHolds(character, perm) then return true end
    return resolveGroup(Perms.getGroup(target)).set[perm] == true
end

function Perms.isAdmin(src)
    return Perms.has(src, ADMIN_PERM)
end

--- Move the player to another existing group. Core.Player.setGroup is the single source of truth:
--- it updates the live account document, persists it and re-replicates the `group` state-bag key.
function Perms.setGroup(src, group)
    local target = toSrc(src)
    if not target or not Perms.groupExists(group) then return false end
    groupAnnounced = false
    if Core.Player.setGroup(target, group) ~= true then return false end
    Core.Log.audit('perms', target, 'group set to %s', group)
    if not groupAnnounced then changed(target, 'group', group) end
    return true
end

--- Grant a permission. scope 'account' (default, survives a character change) or 'character';
--- opts.expiresAt (unix seconds, in the future, at most ten years ahead) makes it temporary.
--- Idempotent: granting what is already held permanently returns true without a write.
function Perms.grant(src, perm, scope, opts)
    local target = toSrc(src)
    if not target or not isPerm(perm) then return false end
    scope = scope or 'account'
    if scope ~= 'account' and scope ~= 'character' then return false end
    local expiresAt
    if opts ~= nil then
        if type(opts) ~= 'table' then return false end
        if opts.expiresAt ~= nil then
            expiresAt = toInt(opts.expiresAt)
            local now = os.time()
            if not expiresAt or expiresAt <= now or expiresAt > now + MAX_TEMP_SECONDS then return false end
        end
    end
    local state = stateOf(target, scope)
    if not state then return false end
    if state.set[perm] then return true end

    local list, temp = state.list, state.temp
    if expiresAt then
        if temp[perm] == expiresAt then return true end
        temp = copyMap(temp)
        temp[perm] = expiresAt
        if not write(target, scope, TEMP_KEY, temp) then return false end
    else
        list = cleanList(list)
        list[#list + 1] = perm
        if not write(target, scope, 'permissions', list) then return false end
        if temp[perm] then   -- a permanent grant replaces a temporary one
            temp = copyMap(temp)
            temp[perm] = nil
            write(target, scope, TEMP_KEY, temp)
        end
    end
    setState(target, scope, newState(list, temp))
    if expiresAt then
        Core.Log.audit('perms', target, 'granted %s (%s) until %d', perm, scope, expiresAt)
        armExpiry(target)
    else
        Core.Log.audit('perms', target, 'granted %s (%s)', perm, scope)
    end
    changed(target, 'grant', perm)
    return true
end

--- Remove a permission (permanent and temporary) from the account (default) or the character.
--- False when it was not there.
function Perms.revoke(src, perm, scope)
    local target = toSrc(src)
    if not target or not isPerm(perm) then return false end
    scope = scope or 'account'
    if scope ~= 'account' and scope ~= 'character' then return false end
    local state = stateOf(target, scope)
    if not state then return false end
    local inList, inTemp = state.set[perm] == true, state.temp[perm] ~= nil
    if not inList and not inTemp then return false end

    local list, temp = state.list, state.temp
    if inList then
        list = {}
        for i = 1, #state.list do
            if state.list[i] ~= perm then list[#list + 1] = state.list[i] end
        end
        if not write(target, scope, 'permissions', list) then return false end
    end
    if inTemp then
        temp = copyMap(temp)
        temp[perm] = nil
        if not write(target, scope, TEMP_KEY, temp) then return false end
    end
    setState(target, scope, newState(list, temp))
    Core.Log.audit('perms', target, 'revoked %s (%s)', perm, scope)
    changed(target, 'revoke', perm)
    return true
end

--- Everything the player holds: group chain, account grants, character grants — deduped, in that order
--- (temporary grants that are still running included). ACE permissions cannot be enumerated.
function Perms.list(src)
    local out, seen = {}, {}
    local target = toSrc(src)
    if not target then return out end
    local function add(perm)
        if not seen[perm] then
            seen[perm] = true
            out[#out + 1] = perm
        end
    end
    for _, perm in ipairs(resolveGroup(Perms.getGroup(target)).list) do add(perm) end
    local now = os.time()
    for _, state in ipairs({ accountState(target) or false, characterState(target) or false }) do
        if state then
            for _, perm in ipairs(state.list) do add(perm) end
            for perm, at in pairs(state.temp) do if at > now then add(perm) end end
        end
    end
    return out
end

--- { [perm] = true } of Perms.list; the console gets every catalogued and every group-listed perm.
function Perms.effective(src)
    local out = {}
    if src == 0 then
        for perm in pairs(defs) do out[perm] = true end
        for _, doc in pairs(ensureGroups(true)) do
            for i = 1, #doc.perms do out[doc.perms[i]] = true end
        end
        return out
    end
    local list = Perms.list(src)
    for i = 1, #list do out[list[i]] = true end
    return out
end

--- Why `has` answers what it answers: { allowed, via = 'console'|'ace'|'account'|'character'|'group:<name>'|nil,
--- group = the player's group, expiresAt = unix seconds when the grant is temporary }.
function Perms.explain(src, perm)
    if type(perm) ~= 'string' or perm == '' then return { allowed = false } end
    if src == 0 then return { allowed = true, via = 'console' } end
    local target = toSrc(src)
    if not target then return { allowed = false } end
    local group = Perms.getGroup(target)
    if IsPlayerAceAllowed(tostring(target), perm) then return { allowed = true, via = 'ace', group = group } end
    local now = os.time()
    for _, scope in ipairs({ 'account', 'character' }) do
        local state = stateOf(target, scope)
        if state then
            if state.set[perm] then return { allowed = true, via = scope, group = group } end
            local at = state.temp[perm]
            if at and at > now then return { allowed = true, via = scope, group = group, expiresAt = at } end
        end
    end
    local granting = resolveGroup(group).origin[perm]
    if granting then return { allowed = true, via = 'group:' .. granting, group = group } end
    return { allowed = false, group = group }
end

--- Rank (§44): console math.huge; no session or an invalid src 0; otherwise the group's weight.
function Perms.getWeight(src)
    if src == 0 then return math.huge end
    local target = toSrc(src)
    if not target or not Core.Player.getInfo(target) then return 0 end
    local doc = ensureGroups()[Perms.getGroup(target)]
    return doc and doc.weight or 0
end

--- May `actorSrc` act on `targetSrc`? Console or self: true; otherwise only with a strictly higher weight.
function Perms.canTarget(actorSrc, targetSrc)
    if actorSrc == 0 then return true end
    local actor, target = toSrc(actorSrc), toSrc(targetSrc)
    if not actor then return false, 'invalid_actor' end
    if not target then return false, 'invalid_target' end
    if actor == target then return true end
    if Perms.getWeight(actor) > Perms.getWeight(target) then return true end
    return false, 'rank'
end

-- == Catalogue and group management (DESIGN §44) ============================================================

--- Declare a permission for the catalogue (owner-tracked, kind 'permDef'). `default` names a group that
--- receives the grant ONCE: only while its document neither lists the perm nor had it removed by an owner.
function Perms.define(perm, opts)
    if not isPerm(perm) then
        Core.Log.warn('Perms.define: invalid permission %s', tostring(perm))
        return false
    end
    if opts ~= nil and type(opts) ~= 'table' then return false end
    opts = opts or {}
    if opts.default ~= nil and not isGroupName(opts.default) then return false end
    local owner = Core.Registry.getCaller()
    local previous = defs[perm]
    if previous and previous.owner ~= owner then   -- one owner per perm: the first definition stays
        Core.Log.warn('Perms.define: %s is already defined by %s, ignored for %s', perm, previous.owner, owner)
        return true
    end
    local def = {
        perm = perm, owner = owner, default = opts.default,
        label = text(opts.label, MAX_LABEL) or perm,
        description = text(opts.description, MAX_TEXT),
        category = text(opts.category, MAX_CATEGORY) or perm:match('^[^%.:]+'),
    }
    defs[perm] = def
    Core.Registry.track(DEF_KIND, perm, owner)
    if def.default and groupState == 'ready' and applyDefault(def) then changed(nil, 'define', perm) end
    return true
end

-- A stopped owner's definitions leave the catalogue; grants already in group documents stay.
Core.Registry.onOwnerStop(DEF_KIND, function(perm)
    defs[perm] = nil
end)

--- Every defined permission, sorted by category then name.
function Perms.catalogue()
    local out = {}
    for _, def in pairs(defs) do
        out[#out + 1] = { perm = def.perm, label = def.label, description = def.description,
            category = def.category, owner = def.owner, default = def.default }
    end
    table.sort(out, function(a, b)
        if a.category ~= b.category then return a.category < b.category end
        return a.perm < b.perm
    end)
    return out
end

--- Every group, sorted by weight then name (copies; `removed` is internal bookkeeping and not included).
function Perms.groups()
    local out = {}
    for _, doc in pairs(ensureGroups(true)) do
        out[#out + 1] = { name = doc.name, label = doc.label, weight = doc.weight, color = doc.color,
            inherits = cleanList(doc.inherits), perms = cleanList(doc.perms) }
    end
    table.sort(out, function(a, b)
        if a.weight ~= b.weight then return a.weight < b.weight end
        return a.name < b.name
    end)
    return out
end

--- Gate for saveGroup/deleteGroup: nil actor = core itself; else 'core.perms.manage'. A denial is audited.
local function allowedActor(actorSrc, action, name)
    if actorSrc == nil or Perms.has(actorSrc, MANAGE_PERM) then return true end
    groupAudit(actorSrc, action, name, 'denied', 'no_permission')
    return false
end

--- A non-console actor only touches groups strictly below its own weight (so never its own group), never sets
--- a weight >= its own, inherits only from groups below it, and only ADDS perms it holds itself — listed, or
--- through a newly inherited group's chain; removals are free inside those groups. Nil when allowed.
local function actorRefusal(actorSrc, existing, doc)
    if actorSrc == nil or actorSrc == 0 then return nil end
    local own = Perms.getWeight(actorSrc)
    if (existing and existing.weight >= own) or doc.weight >= own or doc.name == Perms.getGroup(actorSrc) then
        return 'rank'
    end
    local before = existing or { perms = {}, inherits = {} }
    for _, parent in ipairs(doc.inherits) do
        if groupDocs[parent].weight >= own then return 'rank' end
        if not listHas(before.inherits, parent) then
            for perm in pairs(resolveGroup(parent).set) do
                if not Perms.has(actorSrc, perm) then return 'not_held' end
            end
        end
    end
    for _, perm in ipairs(doc.perms) do
        if not listHas(before.perms, perm) and not Perms.has(actorSrc, perm) then return 'not_held' end
    end
    return nil
end

--- The candidate document of saveGroup, or nil + error code.
local function buildGroup(name, patch, existing)
    local doc = existing and copyGroup(existing) or normalizeGroup(name, { weight = 0 })
    if patch.label ~= nil then
        doc.label = text(patch.label, MAX_LABEL)
        if not doc.label then return nil, 'invalid_label' end
    end
    if patch.weight ~= nil then
        local weight = toInt(patch.weight)
        if not weight or weight < 0 or weight > MAX_WEIGHT then return nil, 'invalid_weight' end
        doc.weight = weight
    end
    if patch.color ~= nil then
        if patch.color == '' or patch.color == false then doc.color = nil
        elseif isColor(patch.color) then doc.color = patch.color
        else return nil, 'invalid_color' end
    end
    if patch.inherits ~= nil then
        if type(patch.inherits) ~= 'table' or #patch.inherits > MAX_INHERITS then return nil, 'invalid_inherits' end
        local inherits = cleanArray(patch.inherits, isGroupName, MAX_INHERITS, name)
        if #inherits ~= #patch.inherits then return nil, 'invalid_inherits' end
        for i = 1, #inherits do
            if not groupDocs[inherits[i]] then return nil, 'unknown_group' end
            if reaches(inherits[i], name) then return nil, 'cycle' end
        end
        doc.inherits = inherits
    end
    if patch.perms ~= nil then
        if type(patch.perms) ~= 'table' or #patch.perms > MAX_GROUP_PERMS then return nil, 'invalid_perms' end
        local perms = cleanArray(patch.perms, isPerm, MAX_GROUP_PERMS)
        for i = 1, #patch.perms do
            if not isPerm(patch.perms[i]) then return nil, 'invalid_perms' end
        end
        local keep = {}
        for i = 1, #perms do keep[perms[i]] = true; doc.removed[perms[i]] = nil end
        for i = 1, #doc.perms do
            if not keep[doc.perms[i]] then doc.removed[doc.perms[i]] = true end   -- an owner took it out
        end
        doc.perms = perms
    end
    if not existing then   -- a new group is composed by its creator: no define default is added later
        for perm, def in pairs(defs) do
            if def.default == name and not listHas(doc.perms, perm) then doc.removed[perm] = true end
        end
    end
    return doc
end

--- The audit `changes` between two group documents.
local function groupChanges(old, new)
    local out = {}
    local function diff(key, a, b)
        if a ~= b then out[#out + 1] = { key = key, old = a, new = b } end
    end
    old = old or {}
    diff('label', old.label, new.label)
    diff('weight', old.weight, new.weight)
    diff('color', old.color, new.color)
    diff('inherits', old.inherits and table.concat(old.inherits, ','), table.concat(new.inherits, ','))
    diff('perms', old.perms and table.concat(old.perms, ','), table.concat(new.perms, ','))
    return out
end

--- Create or edit a group. patch = { label?, weight?, inherits?, perms?, color? }; perms is the full list.
--- actorSrc (optional) needs 'core.perms.manage' and may not touch a group ranked above itself.
function Perms.saveGroup(name, patch, actorSrc)
    if not isGroupName(name) then return false, 'invalid_name' end
    if type(patch) ~= 'table' then return false, 'invalid_patch' end
    if actorSrc ~= nil and actorSrc ~= 0 and not toSrc(actorSrc) then return false, 'invalid_actor' end
    local docs = ensureGroups(true)
    if groupState ~= 'ready' then return false, 'not_ready' end
    if not allowedActor(actorSrc, 'perms.saveGroup', name) then return false, 'no_permission' end
    local existing = docs[name]
    local doc, err = buildGroup(name, patch, existing)
    if not doc then return false, err end
    local refused = actorRefusal(actorSrc, existing, doc)
    if refused then
        groupAudit(actorSrc, 'perms.saveGroup', name, 'denied', refused)
        return false, refused
    end
    local stored, storeErr = Core.DB.upsert(TABLE, groupRow(doc), 'name', { returning = false })   -- awaited
    if not stored then
        Core.Log.error('perms: group %s could not be saved (%s)', name, tostring(storeErr))
        return false, 'save_failed'
    end
    groupDocs[name] = doc
    resolved = {}
    groupAudit(actorSrc, 'perms.saveGroup', name, 'ok', nil, groupChanges(existing, doc))
    changed(nil, 'saveGroup', name)
    return true
end

--- Delete a group: never 'user', never while another group inherits it or a member is online (members
--- that are offline fall back to 'user' when they load). The online check walks the connected players —
--- an owner action, not a timer, so the one pass is acceptable at 2,000 players.
function Perms.deleteGroup(name, actorSrc)
    if not isGroupName(name) then return false, 'invalid_name' end
    if name == DEFAULT_GROUP then return false, 'protected' end
    if actorSrc ~= nil and actorSrc ~= 0 and not toSrc(actorSrc) then return false, 'invalid_actor' end
    local docs = ensureGroups(true)
    if groupState ~= 'ready' then return false, 'not_ready' end
    local doc = docs[name]
    if not doc then return false, 'unknown_group' end
    if not allowedActor(actorSrc, 'perms.deleteGroup', name) then return false, 'no_permission' end
    if actorSrc ~= nil and actorSrc ~= 0 and doc.weight >= Perms.getWeight(actorSrc) then   -- strictly below only
        groupAudit(actorSrc, 'perms.deleteGroup', name, 'denied', 'rank')
        return false, 'rank'
    end
    for other, d in pairs(docs) do
        if other ~= name and listHas(d.inherits, name) then return false, 'inherited' end
    end
    local players = GetPlayers()
    for i = 1, #players do
        local info = Core.Player.getInfo(tonumber(players[i]))
        if info and info.group == name then return false, 'in_use' end
    end
    local deleted, deleteErr = Core.DB.delete(TABLE, { name = name })   -- awaited
    if not deleted then
        Core.Log.error('perms: group %s could not be deleted (%s)', name, tostring(deleteErr))
        return false, 'save_failed'
    end
    groupDocs[name] = nil
    resolved = {}
    groupAudit(actorSrc, 'perms.deleteGroup', name, 'ok', nil, groupChanges(doc, { inherits = {}, perms = {} }))
    changed(nil, 'deleteGroup', name)
    return true
end

-- == Lifecycle and core's own permissions ====================================================================

-- Someone else wrote the character's grants (Player.setData, an admin tool), or a character loaded.
Core.on('playerDataChanged', function(src, topKey)
    if topKey == 'permissions' or topKey == TEMP_KEY then charPerms[src] = nil end
end)
Core.on('playerLoaded', function(src)
    charPerms[src] = nil
end)
-- Player.setAccountData / setGroup announce every grant or group write ('grants' | 'group'): an out-of-band
-- write counts at once. Perms' own writes land here too and are re-cached right after; its own hooks
-- ('grant', 'revoke', …) never match, and this handler emits nothing, so nothing loops.
Core.on('permsChanged', function(src, what)
    if (what ~= 'grants' and what ~= 'group') or type(src) ~= 'number' then return end
    accountPerms[src], charPerms[src] = nil, nil
    if what == 'group' then groupAnnounced = true end
end)

AddEventHandler('playerDropped', function()
    local src = source
    if src == nil then return end
    accountPerms[src], charPerms[src], expiry[src] = nil, nil, nil
end)

-- Read `perm_groups` as soon as core runs, so no check ever waits for it.
AddEventHandler('onResourceStart', function(resource)
    if resource ~= Core.name then return end
    ensureGroups()
end)

-- Legacy rank perms (listed by the seed) and core's §44–§46 perms; the defaults apply once the groups are read.
for _, perm in ipairs({ 'core.helper', 'core.mod', 'core.admin', 'core.senior', 'core.owner' }) do
    Perms.define(perm, { label = perm, category = 'core' })
end
Perms.define(MANAGE_PERM, { label = 'Manage permission groups', category = 'core', default = 'owner' })
Perms.define('core.settings.view', { label = 'View settings', category = 'core', default = 'admin' })
Perms.define('core.audit.view', { label = 'View the audit trail', category = 'core', default = 'admin' })
Perms.define((Config.Admin and Config.Admin.StaffPerm) or 'core.admin.staff',
    { label = 'Staff (admin tools, duty)', category = 'core', default = 'helper' })
