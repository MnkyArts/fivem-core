--- core — Core.Factions (server)
--- Factions (tables `factions` + `faction_members`, DESIGN §56.6), membership + rank management, bank,
--- state-bag / GlobalState replication, invite expiry sweep and the core:faction:* callbacks.
--- Contract: DESIGN.md §4.5 (API + §56 port notes), §5.2 (callbacks), §8 (replication + hooks), §10 (config).
---
--- Storage (§56.8 rules 1, 6): every faction and membership lives in memory, loaded ONCE by a file-scope thread (one
--- query, retried with backoff; until it lands mutations answer 'unavailable' — a failed load never reads as "no
--- factions"). Reads never touch the database. Writes: create = awaited transaction (23505 → name_taken / tag_taken /
--- already_in_faction); update (name/tag/color) = awaited UPDATE (the unique indexes decide); acceptInvite / kick =
--- awaited insert / delete of the member row (its primary key is the one-faction-per-character constraint); deposit /
--- withdraw = ONE awaited guarded UPDATE of factions.bank, Core.Money moved around it; everything else = queued patch /
--- remove, memory changed once the queue took it. A lost answer (timeout, connection) re-reads the row before any
--- rollback; a queued write the database drops (dbWriteFailed) re-reads its faction. data.faction
--- ({ id, rank } | false) is derived from faction_members at session load and kept in step here (never stored).
--- Natives: GetPlayerName (server), GetGameTimer (shared).

local Factions = {}
Core.Factions = Factions

local DB = Core.DB
local Log = Core.Log
local Utils = Core.Utils

local PERM_KEYS <const> = { 'invite', 'kick', 'manage_ranks', 'bank', 'manage' }
local COLOR_PATTERN <const> = '^#%x%x%x%x%x%x$'
-- Raw, unsanitized name/tag input: bounded here so no huge string ever reaches gsub.
local NAME_ARG <const> = { 'string', max = 64 }
local SWEEP_INTERVAL_MS <const> = 30000
local ACTION_COOLDOWN_MS <const> = 1000
local LOAD_BACKOFF_MS <const> = { 1000, 2000, 5000, 10000, 30000 }
local PUBLISH_CHUNK <const> = 50
local FLUSH_WAIT_MS <const> = 5000
local RESYNC_RETRY_MS <const> = 5000
local RECORD_KEYS <const> = { 'name', 'tag', 'color', 'ownerCharId', 'ranks', 'bank', 'meta', 'createdAt', 'updatedAt' }

-- every faction with its members in one round trip (joined_at as Unix seconds inside the jsonb)
local LOAD_SQL <const> = [[
SELECT f.id, f.name, f.tag, f.color, f.owner_character_id, f.ranks, f.bank, f.meta, f.created_at, f.updated_at,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('charId', m.character_id, 'rank', m.rank, 'name', m.name,
                                                     'joinedAt', extract(epoch FROM m.joined_at)::bigint))
                 FROM faction_members m WHERE m.faction_id = f.id), '[]'::jsonb) AS members
FROM factions f]]
-- the bank moves in ONE statement each, guarded in SQL (§56.8 rule 2): a lost race answers no row, never < 0
local DEPOSIT_SQL <const> = 'UPDATE factions SET bank = bank + $2 WHERE id = $1 AND bank + $2 <= $3 RETURNING bank'
local WITHDRAW_SQL <const> = 'UPDATE factions SET bank = bank - $2 WHERE id = $1 AND bank >= $2 RETURNING bank'
local REFUND_SQL <const> = 'UPDATE factions SET bank = bank + $2 WHERE id = $1'
-- meta stays a JSON OBJECT even when empty (an empty Lua table crosses msgpack as []): raw, keyed per faction
local META_SQL <const> = 'UPDATE factions SET meta = $2::jsonb WHERE id = $1'
-- a refund to a character whose session is gone: ONE atomic upsert, queued behind his session's final save
local CREDIT_SQL <const> = [[INSERT INTO character_money (character_id, account, balance) VALUES ($1, $2, $3)
ON CONFLICT (character_id, account) DO UPDATE SET balance = character_money.balance + EXCLUDED.balance]]
-- errors of a call that was never sent or failed as a whole: its statement cannot have committed
local NOT_SENT <const> = { invalid = true, unavailable = true, forbidden = true, migrations_failed = true,
    not_in_coroutine = true, tx_unknown = true, tx_aborted = true, tx_expired = true }

-- [id] = { id, name, tag, color, ownerCharId?, ranks, members = { [charId] = member }, bank, meta, createdAt, updatedAt }
local factions = {}
local memberOf = {}    -- [charId] = factionId: the faction_members rows, in memory
local joining = {}     -- [charId] = true while an accepted invite's insert runs (the member is reserved)
local loaded = false
local running = true
local scheduleResync   -- (factionId): re-read one faction from the database (defined with the load, below)
local pending = {}     -- [targetSrc] = { factionId = id, expires = gameTimer ms, byName = string }
local lastAction = {}  -- [src] = { [bucket] = GetGameTimer() of the last call in that bucket }

--- Validate positional arguments; returns nil when ok, the error string otherwise.
local function invalid(schema, ...)
    local ok, err = Core.Validate.check(schema, ...)
    if ok then return nil end
    return err or 'invalid_arguments'
end

--- A queued write the queue refused (bad value, or core_db down): logged, and the caller refuses the change.
local function queued(what, ok, err)
    if ok then return true end
    Log.error('factions: the %s write was refused (%s)', what, tostring(err))
    return false
end

local function touch(faction)
    faction.updatedAt = os.time()
end

--- May a failed awaited write have committed anyway? Only a timeout or a connection lost around COMMIT leaves that
--- open; an SQL error (outside classes 08 / 57P) or a call that was never sent does not.
local function mayHaveApplied(err)
    local code = DB.errorCode(err)
    if code == nil then return true end
    if NOT_SENT[code] then return false end
    if #code == 5 and code:find('%d') then return code:sub(1, 2) == '08' or code:sub(1, 3) == '57P' end
    return true
end

--- After a failed awaited write: false when it cannot have committed, else `probe()` re-reads the row and answers
--- true (it did) / false (it did not) / nil (that read failed as well: the outcome stays unknown).
local function committed(err, probe)
    if not mayHaveApplied(err) then return false end
    local ok, answer = pcall(probe)
    if ok then return answer end
    return nil
end

local function memberCount(faction)
    return Utils.count(faction.members)
end

--- GlobalState entry read by any client/plugin that wants faction headlines (§8).
local function publish(faction)
    GlobalState['faction:' .. faction.id] = {
        name = faction.name, tag = faction.tag, color = faction.color, memberCount = memberCount(faction),
    }
end

local function unpublish(id)
    GlobalState['faction:' .. id] = false
end

local function rankName(faction, rank)
    local def = faction.ranks[rank]
    return (type(def) == 'table' and type(def.name) == 'string') and def.name or ('Rank ' .. tostring(rank))
end

local function rankPerms(faction, rank, isOwner)
    local out = {}
    local def = faction.ranks[rank]
    local perms = (type(def) == 'table' and type(def.perms) == 'table') and def.perms or nil
    for _, key in ipairs(PERM_KEYS) do
        out[key] = isOwner or (perms ~= nil and perms[key] == true)
    end
    return out
end

--- Player text that is stored (names, tags, rank names): sanitized, valid UTF-8 and cut to `maxChars` CHARACTERS on a
--- character boundary (Utils.sanitize cuts bytes and may split one). Returns text, length | nil (not UTF-8).
local function cleanText(value, maxChars)
    local text = Utils.sanitize(value, maxChars * 4)
    local len = utf8.len(text)
    if not len then return nil end
    if len > maxChars then
        text = text:sub(1, utf8.offset(text, maxChars + 1) - 1):match('^(.-)%s*$')
        len = utf8.len(text)
    end
    return text, len
end

--- Keep only known perm keys with boolean true values.
local function sanitizePerms(perms)
    local out = {}
    if type(perms) ~= 'table' then return out end
    for _, key in ipairs(PERM_KEYS) do
        if perms[key] == true then out[key] = true end
    end
    return out
end

--- Full summary used by getPlayerFaction / the factionChanged hook.
local function memberSummary(faction, charId)
    local member = faction.members[charId]
    if not member then return nil end
    local isOwner = faction.ownerCharId == charId
    return {
        id = faction.id, name = faction.name, tag = faction.tag, color = faction.color,
        rank = member.rank, rankName = rankName(faction, member.rank),
        perms = rankPerms(faction, member.rank, isOwner), isOwner = isOwner,
    }
end

--- The six replicated keys of the `faction` state-bag value (§8); false = no faction.
local function stateSummary(full)
    if not full then return false end
    return {
        id = full.id, name = full.name, tag = full.tag, color = full.color,
        rank = full.rank, rankName = full.rankName,
    }
end

--- The session's data.faction + the player state bag for one member, when he is online (§4.5).
local function replicateMember(faction, charId)
    local target = Core.Player.getSrcByCharId(charId)
    if not target then return end
    local full = faction and memberSummary(faction, charId) or nil
    Core.Player.setData(target, 'faction', full and { id = full.id, rank = full.rank } or false)
    Player(target).state:set('faction', stateSummary(full), true)
    Core.emitHook('factionChanged', target, full)
end

local function replicateAll(faction)
    for charId in pairs(faction.members) do
        replicateMember(faction, charId)
    end
end

--- Brings a session's data.faction and state bag in line with memory: a session that loaded before the factions
--- did, or whose membership changed while it loaded. Writes data.faction only when it differs.
local function reconcile(src)
    if not loaded then return end
    local info = Core.Player.getInfo(src)
    if not info or not info.charId then return end
    local faction = factions[memberOf[info.charId]]
    local full = faction and memberSummary(faction, info.charId) or nil
    local have = Core.Player.getData(src, 'faction')
    if full and (type(have) ~= 'table' or have.id ~= full.id or have.rank ~= full.rank)
        or (not full and have ~= false) then
        Core.Player.setData(src, 'faction', full and { id = full.id, rank = full.rank } or false)
    end
    -- the bag is written only when it differs (a replicated write reaches every client of the player)
    local want, state = stateSummary(full), Player(src).state
    local cur = state.faction
    local same
    if type(want) == 'table' then
        same = type(cur) == 'table' and cur.id == want.id and cur.name == want.name and cur.tag == want.tag
            and cur.color == want.color and cur.rank == want.rank and cur.rankName == want.rankName
    else
        same = cur == false
    end
    if not same then state:set('faction', want, true) end
end

local function notify(src, message, kind)
    if not src then return end
    Core.Notify.send(src, message, kind or 'info')
end

--- Loaded session + faction of a member. Returns faction, member, info or nil, err.
local function context(src)
    local info = Core.Player.getInfo(src)
    if not info or not info.charId then return nil, 'not_loaded' end
    if not loaded then return nil, 'unavailable' end
    local faction = factions[memberOf[info.charId]]
    local member = faction and not joining[info.charId] and faction.members[info.charId] or nil
    if not member then return nil, 'no_faction' end
    return faction, member, info
end

--- A member other actions may target: not the one whose accepted invite is still being written.
local function targetMember(faction, charId)
    if joining[charId] then return nil end
    return faction.members[charId]
end

local function hasPermIn(faction, charId, perm)
    if faction.ownerCharId == charId then return true end
    local member = faction.members[charId]
    if not member then return false end
    local def = faction.ranks[member.rank]
    return type(def) == 'table' and type(def.perms) == 'table' and def.perms[perm] == true
end

local function bankOf(faction)
    local amount = tonumber(faction.bank) or 0
    return math.floor(amount)
end

--- Gives back money an action took when its database write failed, by CHARACTER (a src may be reused after a drop):
--- online through Core.Money, offline as one atomic upsert of his money row queued behind his final save.
local function refund(charId, amount, reason)
    if amount <= 0 then return end
    local account = Config.Factions.CostAccount
    local target = Core.Player.getSrcByCharId(charId)
    if target then
        if not Core.Money.add(target, account, amount, reason) then
            Log.error('factions: could not give %d back to %s (%s): the balance is full', amount, charId, reason)
        end
        return
    end
    local ok, err = DB.enqueue(CREDIT_SQL, { charId, account, amount })
    if ok then
        Log.warn('factions: %s left during %s — %d credited to his %s offline', charId, reason, amount, account)
    else
        Log.error('factions: could not credit %d to %s offline (%s): %s', amount, charId, reason, tostring(err))
    end
end

-- Reads (memory only: never yield)

--- Factions.get(id) -> copy | nil
function Factions.get(id)
    if invalid({ 'id' }, id) then return nil end
    local faction = factions[id]
    return faction and Utils.deepCopy(faction) or nil
end

--- Factions.list() -> array of { id, name, tag, color, memberCount }, oldest faction first
function Factions.list()
    local out = {}
    for _, faction in pairs(factions) do
        out[#out + 1] = { id = faction.id, name = faction.name, tag = faction.tag, color = faction.color,
            memberCount = memberCount(faction) }
    end
    table.sort(out, function(a, b)
        local ta, tb = factions[a.id].createdAt or 0, factions[b.id].createdAt or 0
        if ta ~= tb then return ta < tb end
        return a.id < b.id
    end)
    return out
end

--- Factions.getMembers(id) -> array of { charId, name, rank, rankName, online = src|false }
function Factions.getMembers(id)
    if invalid({ 'id' }, id) then return {} end
    local faction = factions[id]
    if not faction then return {} end
    local out = {}
    for charId, member in pairs(faction.members) do
        out[#out + 1] = { charId = charId, name = member.name, rank = member.rank,
            rankName = rankName(faction, member.rank), online = Core.Player.getSrcByCharId(charId) or false }
    end
    table.sort(out, function(a, b)
        local rankA, rankB = a.rank or 0, b.rank or 0
        if rankA ~= rankB then return rankA > rankB end
        return tostring(a.name) < tostring(b.name)
    end)
    return out
end

--- Factions.getPlayerFaction(src) -> { id, name, tag, color, rank, rankName, perms, isOwner } | nil
function Factions.getPlayerFaction(src)
    if invalid({ 'src' }, src) then return nil end
    local faction, _, info = context(src)
    if not faction then return nil end
    return memberSummary(faction, info.charId)
end

function Factions.hasPerm(src, perm)
    if invalid({ 'src', 'string' }, src, perm) then return false end
    local faction, _, info = context(src)
    if not faction then return false end
    return hasPermIn(faction, info.charId, perm)
end

function Factions.getBank(id)
    if invalid({ 'id' }, id) then return 0 end
    local faction = factions[id]
    return faction and bankOf(faction) or 0
end

--- Plugin scratch space on the faction (server only). Queued; false when the write was refused.
function Factions.setMeta(id, key, value)
    if invalid({ 'id', { 'string', max = 64 } }, id, key) then return false end
    local faction = factions[id]
    if not faction then return false end
    local meta = Utils.deepCopy(type(faction.meta) == 'table' and faction.meta or {})
    meta[key] = Utils.jsonSafe(value)
    local ok, text = pcall(DB.json, meta)
    if not ok or type(text) ~= 'string' then return false end
    if next(meta) == nil then text = '{}' end
    if not queued('meta of ' .. id, DB.enqueue(META_SQL, { id, text }, 'core:factions.meta:' .. id)) then
        return false
    end
    faction.meta = meta
    touch(faction)
    return true
end

function Factions.getMeta(id, key)
    if invalid({ 'id' }, id) then return nil end
    local faction = factions[id]
    if not faction or type(faction.meta) ~= 'table' then return nil end
    local value = faction.meta[key]
    return type(value) == 'table' and Utils.deepCopy(value) or value
end

-- Lifecycle (create / disband / update)

--- NameMin / NameMax count CHARACTERS (UTF-8), the tag is ASCII by its pattern.
local function checkName(name)
    local clean, len = cleanText(name, Config.Factions.NameMax)
    if not clean or len < Config.Factions.NameMin then return nil, 'invalid_name' end
    return clean
end

local function checkTag(tag)
    local clean = cleanText(tag, Config.Factions.TagMax)
    clean = clean and clean:upper()
    if not clean or #clean < Config.Factions.TagMin or not clean:match(Config.Factions.TagPattern) then
        return nil, 'invalid_tag'
    end
    return clean
end

local function checkColor(color)
    if color == nil then return Config.Factions.DefaultColor end
    if type(color) ~= 'string' or not color:match(COLOR_PATTERN) then return nil, 'invalid_color' end
    return color:lower()
end

--- Names and tags are unique across factions (case-insensitive). Memory is the fast path (Lua's lower() is ASCII
--- only); the unique indexes factions_name_key (Postgres lower(name)) and factions_tag_key are the authority, so every
--- name / tag write is AWAITED and a 23505 answers name_taken / tag_taken.
local function duplicateOf(name, tag, exceptId)
    local lowerName, upperTag = name and name:lower(), tag and tag:upper()
    local tagHit = false
    for id, faction in pairs(factions) do
        if id ~= exceptId then
            if lowerName and faction.name:lower() == lowerName then return 'name_taken' end
            if upperTag and faction.tag:upper() == upperTag then tagHit = true end
        end
    end
    return tagHit and 'tag_taken' or nil
end

--- The answer for a unique violation of a faction write (nil for any other error).
local function uniqueError(err)
    if DB.errorCode(err) ~= '23505' or type(err) ~= 'string' then return nil end
    if err:find('factions_name_key', 1, true) then return 'name_taken' end
    if err:find('factions_tag_key', 1, true) then return 'tag_taken' end
    if err:find('faction_members_pkey', 1, true) then return 'already_in_faction' end
    return nil
end

local function defaultRanks()
    local out = {}
    for i, def in ipairs(Config.Factions.DefaultRanks) do
        out[i] = { name = cleanText(def.name, 32) or ('Rank ' .. i), perms = sanitizePerms(def.perms) }
    end
    return out
end

--- Factions.create(src, name, tag, opts?) -> id | nil, err — yields (one transaction).
function Factions.create(src, name, tag, opts)
    local err = invalid({ 'src', NAME_ARG, NAME_ARG, 'table?' }, src, name, tag, opts)
    if err then return nil, err end
    local info = Core.Player.getInfo(src)
    if not info or not info.charId then return nil, 'not_loaded' end
    if not loaded then return nil, 'unavailable' end
    local charId = info.charId
    if memberOf[charId] then return nil, 'already_in_faction' end

    local cleanName, nameErr = checkName(name)
    if not cleanName then return nil, nameErr end
    local cleanTag, tagErr = checkTag(tag)
    if not cleanTag then return nil, tagErr end
    local color, colorErr = checkColor(opts and opts.color)
    if not color then return nil, colorErr end
    local duplicate = duplicateOf(cleanName, cleanTag, nil)
    if duplicate then return nil, duplicate end

    local cfg = Config.Factions
    local cost = cfg.CreateCost
    if cost > 0 and not Core.Money.remove(src, cfg.CostAccount, cost, 'faction_create') then
        return nil, 'insufficient_funds'
    end
    local ranks = defaultRanks()
    local id, now = Utils.uuid(), os.time()
    local memberName = info.name or GetPlayerName(src)
    -- a member row this character left a moment ago may still sit in the queue: commit it first (bounded wait)
    DB.flush(FLUSH_WAIT_MS)
    local ok, txErr = DB.transaction(function(tx)
        local done, e = tx.insert('factions', {
            id = id, name = cleanName, tag = cleanTag, color = color, owner_character_id = charId, ranks = ranks,
        }, { returning = false })
        if not done then return false, e end
        done, e = tx.insert('faction_members', {
            character_id = charId, faction_id = id, rank = #ranks, name = memberName, joined_at = now,
        }, { returning = false })
        if not done then return false, e end
        return true
    end)
    if not ok then
        -- a lost COMMIT may still have landed: the faction row tells (the member row went in the same transaction)
        local landed = committed(txErr, function()
            local n = DB.scalar('SELECT count(*) FROM factions WHERE id = $1', { id })
            if n == nil then return nil end
            return n > 0
        end)
        if landed == nil then
            -- unknown: nothing is refunded twice or handed out free; a later re-read shows whether it exists
            Log.error('factions: the create of %s by %s (fee %d) may or may not have landed (%s)', id, charId, cost,
                tostring(txErr))
            scheduleResync(id)
            return nil, 'create_failed'
        end
        if not landed then
            refund(charId, cost, 'faction_create_rollback')
            local code = uniqueError(txErr)
            if not code then Log.error('factions: create failed (%s)', tostring(txErr)) end
            return nil, code or 'create_failed'
        end
    end

    local faction = {
        id = id, name = cleanName, tag = cleanTag, color = color, ownerCharId = charId, ranks = ranks,
        members = { [charId] = { rank = #ranks, name = memberName, joinedAt = now } },
        bank = 0, meta = {}, createdAt = now, updatedAt = now,
    }
    factions[id] = faction
    memberOf[charId] = id
    publish(faction)
    replicateMember(faction, charId)
    Log.audit('faction', src, 'created %s [%s] id=%s', cleanName, cleanTag, id)
    Core.emitHook('factionUpdated', id)
    return id
end

--- Drop every pending invite that points at a faction.
local function purgeInvites(factionId)
    for targetSrc, invite in pairs(pending) do
        if invite.factionId == factionId then pending[targetSrc] = nil end
    end
end

--- Factions.disband(src) -> bool, err — owner only; the faction bank is lost; the member rows go with the
--- faction row (ON DELETE CASCADE).
function Factions.disband(src)
    local err = invalid({ 'src' }, src)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if faction.ownerCharId ~= info.charId then return false, 'not_owner' end
    local id, name = faction.id, faction.name
    if not queued('disband of ' .. id, DB.remove('factions', id)) then return false, 'save_failed' end

    factions[id] = nil
    purgeInvites(id)
    for charId in pairs(faction.members) do
        if memberOf[charId] == id then memberOf[charId] = nil end
        local target = Core.Player.getSrcByCharId(charId)
        replicateMember(nil, charId)
        if target and target ~= src then
            notify(target, ('%s has been disbanded.'):format(name), 'warning')
        end
    end
    unpublish(id)
    Log.audit('faction', src, 'disbanded %s id=%s', name, id)
    Core.emitHook('factionUpdated', id)
    return true
end

--- Factions.update(src, { name?, tag?, color? }) -> bool, err — perm `manage`. Yields (one awaited UPDATE).
function Factions.update(src, changes)
    local err = invalid({ 'src', 'table' }, src, changes)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if not hasPermIn(faction, info.charId, 'manage') then return false, 'no_permission' end

    local newName, newTag, newColor
    if changes.name ~= nil then
        newName, err = checkName(changes.name)
        if not newName then return false, err end
    end
    if changes.tag ~= nil then
        newTag, err = checkTag(changes.tag)
        if not newTag then return false, err end
    end
    if changes.color ~= nil then
        newColor, err = checkColor(changes.color)
        if not newColor then return false, err end
    end
    local duplicate = duplicateOf(newName, newTag, faction.id)
    if duplicate then return false, duplicate end

    local columns = { name = newName, tag = newTag, color = newColor }
    if next(columns) ~= nil then
        -- AWAITED, never queued (yields): the unique indexes decide, and a refused rename must neither leave memory
        -- renamed nor sit in a pending patch where a ranks / owner patch of the same faction would merge into it
        local count, updateErr = DB.update('factions', columns, { id = faction.id })
        if not count then
            local code = uniqueError(updateErr)
            if code then return false, code end
            if mayHaveApplied(updateErr) then scheduleResync(faction.id) end   -- whatever landed is read back
            Log.error('factions: the update of %s failed (%s)', faction.id, tostring(updateErr))
            return false, 'save_failed'
        end
        if count == 0 or factions[faction.id] ~= faction then return false, 'no_faction' end
    end
    faction.name = newName or faction.name
    faction.tag = newTag or faction.tag
    faction.color = newColor or faction.color
    touch(faction)
    publish(faction)
    replicateAll(faction)
    Log.audit('faction', src, 'updated %s id=%s', faction.name, faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

-- Membership

--- Factions.invite(src, targetSrc) -> bool, err — perm `invite`.
function Factions.invite(src, targetSrc)
    local err = invalid({ 'src', 'src' }, src, targetSrc)
    if err then return false, err end
    if targetSrc == src then return false, 'self_target' end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if not hasPermIn(faction, info.charId, 'invite') then return false, 'no_permission' end
    if memberCount(faction) >= Config.Factions.MaxMembers then return false, 'faction_full' end

    local targetInfo = Core.Player.getInfo(targetSrc)
    if not targetInfo or not targetInfo.charId then return false, 'target_not_loaded' end
    if memberOf[targetInfo.charId] then return false, 'target_in_faction' end

    local existing = pending[targetSrc]
    if existing and existing.factionId ~= faction.id and GetGameTimer() <= existing.expires then
        return false, 'invite_pending'
    end

    local inviterName = info.name or GetPlayerName(src)
    pending[targetSrc] = {
        factionId = faction.id,
        expires = GetGameTimer() + Config.Factions.InviteTimeoutMs,
        byName = inviterName,
    }
    notify(targetSrc, ('%s invited you to %s — /faction accept'):format(inviterName, faction.name))
    notify(src, ('Invited %s to %s.'):format(targetInfo.name or GetPlayerName(targetSrc), faction.name), 'success')
    Log.audit('faction', src, 'invited src=%d to %s', targetSrc, faction.id)
    return true
end

--- Factions.acceptInvite(src) -> bool, err — joins at rank 1; expiry checked here and by the sweep. Yields: the
--- member row is inserted before the answer (its primary key allows one faction per character).
function Factions.acceptInvite(src)
    local err = invalid({ 'src' }, src)
    if err then return false, err end
    local invite = pending[src]
    if not invite then return false, 'no_invite' end
    if GetGameTimer() > invite.expires then
        pending[src] = nil
        return false, 'invite_expired'
    end
    local info = Core.Player.getInfo(src)
    if not info or not info.charId then return false, 'not_loaded' end
    if not loaded then return false, 'unavailable' end
    local charId = info.charId
    if memberOf[charId] then
        pending[src] = nil
        return false, 'already_in_faction'
    end
    local faction = factions[invite.factionId]
    if not faction then
        pending[src] = nil
        return false, 'no_faction'
    end
    if memberCount(faction) >= Config.Factions.MaxMembers then return false, 'faction_full' end

    pending[src] = nil
    -- reserved while the insert runs: counts against MaxMembers, is no target and cannot act yet
    local member = { rank = 1, name = info.name or GetPlayerName(src), joinedAt = os.time() }
    faction.members[charId], memberOf[charId], joining[charId] = member, faction.id, true
    local ok, insertErr = DB.insert('faction_members', {
        character_id = charId, faction_id = faction.id, rank = 1, name = member.name, joined_at = member.joinedAt,
    }, { returning = false, sync = true })
    if not ok then
        -- a timeout / lost COMMIT may still have landed: the member row tells
        ok = committed(insertErr, function()
            local row, readErr = DB.single('SELECT faction_id FROM faction_members WHERE character_id = $1', { charId })
            if readErr ~= nil then return nil end
            return row ~= nil and row.faction_id == faction.id
        end)
    end
    joining[charId] = nil
    local current = factions[faction.id] == faction and faction.members[charId] == member
    if not ok or not current then
        if faction.members[charId] == member then faction.members[charId] = nil end
        if memberOf[charId] == faction.id then memberOf[charId] = nil end
        if ok then return false, 'no_faction' end     -- disbanded meanwhile: the row went with it (cascade)
        if ok == nil then scheduleResync(faction.id) end   -- unknown: a later read decides the membership
        local code = DB.errorCode(insertErr)
        if code == '23505' then return false, 'already_in_faction' end
        if code == '23503' then return false, 'no_faction' end
        Log.error('factions: could not add %s to %s (%s)', charId, faction.id, tostring(insertErr))
        return false, 'save_failed'
    end
    touch(faction)
    publish(faction)
    replicateMember(faction, charId)
    Log.audit('faction', src, 'joined %s', faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

--- Factions.declineInvite(src) -> bool
function Factions.declineInvite(src)
    if invalid({ 'src' }, src) then return false end
    if not pending[src] then return false end
    pending[src] = nil
    return true
end

--- Factions.leave(src) -> bool, err — the owner must disband or transfer first.
function Factions.leave(src)
    local err = invalid({ 'src' }, src)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if faction.ownerCharId == info.charId then return false, 'owner_cannot_leave' end
    if not queued('leave of ' .. info.charId, DB.remove('faction_members', info.charId)) then
        return false, 'save_failed'
    end

    faction.members[info.charId] = nil
    memberOf[info.charId] = nil
    touch(faction)
    publish(faction)
    replicateMember(nil, info.charId)
    Log.audit('faction', src, 'left %s', faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

--- Factions.kick(src, targetCharId) -> bool, err — perm `kick`; never the owner or a higher rank. Yields: the
--- member row is deleted before the answer.
function Factions.kick(src, targetCharId)
    local err = invalid({ 'src', 'id' }, src, targetCharId)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if not hasPermIn(faction, info.charId, 'kick') then return false, 'no_permission' end
    if targetCharId == info.charId then return false, 'self_target' end
    local target = targetMember(faction, targetCharId)
    if not target then return false, 'target_not_member' end
    if faction.ownerCharId == targetCharId then return false, 'cannot_kick_owner' end
    if faction.ownerCharId ~= info.charId and target.rank > faction.members[info.charId].rank then
        return false, 'rank_too_high'
    end

    local id = faction.id
    local count, deleteErr = DB.delete('faction_members', { character_id = targetCharId, faction_id = id },
        { sync = true })
    if not count then
        -- a timeout / lost COMMIT may still have landed: the member row tells
        local gone = committed(deleteErr, function()
            local row, readErr = DB.single('SELECT faction_id FROM faction_members WHERE character_id = $1 '
                .. 'AND faction_id = $2', { targetCharId, id })
            if readErr ~= nil then return nil end
            return row == nil
        end)
        if not gone then
            if gone == nil then scheduleResync(id) end
            Log.error('factions: could not remove %s from %s (%s)', targetCharId, id, tostring(deleteErr))
            return false, 'save_failed'
        end
    end
    if faction.members[targetCharId] == target then faction.members[targetCharId] = nil end
    if memberOf[targetCharId] == id then
        memberOf[targetCharId] = nil
        replicateMember(nil, targetCharId)
        notify(Core.Player.getSrcByCharId(targetCharId), ('You were removed from %s.'):format(faction.name), 'error')
    end
    if factions[id] == faction then
        touch(faction)
        publish(faction)
    end
    Log.audit('faction', src, 'kicked charId=%s from %s', targetCharId, id)
    Core.emitHook('factionUpdated', id)
    return true
end

-- Ranks and ownership (queued: the faction patch and the member patches of one action share a slice, so they
-- commit in one transaction — §56.3.3)

local RANK_SPEC <const> = { 'integer', min = 1, max = Config.Factions.MaxRanks }

--- Queues `ranks` for the faction and the new rank of every member in `moves` ({ [charId] = rank }); memory
--- changes only when every write was taken. Absolute ranks per row (never `rank - 1` in SQL): a flush that is
--- retried after a lost COMMIT applies them twice without harm (§56.3.3). The queue bulk-writes the rows.
local function writeRanks(faction, ranks, moves, what)
    if ranks and not queued(what, DB.patch('factions', faction.id, { ranks = ranks })) then return false end
    for charId, rank in pairs(moves) do
        if not queued(what, DB.patch('faction_members', charId, { rank = rank })) then return false end
    end
    if ranks then faction.ranks = ranks end
    for charId, rank in pairs(moves) do
        local member = faction.members[charId]
        if member then member.rank = rank end
    end
    touch(faction)
    return true
end

--- Factions.setRank(src, targetCharId, rank) -> bool, err — perm `manage_ranks`.
function Factions.setRank(src, targetCharId, rank)
    local err = invalid({ 'src', 'id', RANK_SPEC }, src, targetCharId, rank)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if not hasPermIn(faction, info.charId, 'manage_ranks') then return false, 'no_permission' end
    if not faction.ranks[rank] then return false, 'invalid_rank' end
    if targetCharId == info.charId then return false, 'self_target' end
    local target = targetMember(faction, targetCharId)
    if not target then return false, 'target_not_member' end
    if faction.ownerCharId == targetCharId then return false, 'cannot_demote_owner' end
    local ownRank = faction.members[info.charId].rank
    if faction.ownerCharId ~= info.charId and (rank >= ownRank or target.rank >= ownRank) then
        return false, 'rank_too_high'
    end

    if not writeRanks(faction, nil, { [targetCharId] = rank }, 'rank of ' .. targetCharId) then
        return false, 'save_failed'
    end
    replicateMember(faction, targetCharId)
    Log.audit('faction', src, 'set rank %d for charId=%s in %s', rank, targetCharId, faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

--- Factions.setRankDef(src, rank, { name?, perms? }) -> bool, err — owner only for the top rank.
function Factions.setRankDef(src, rank, def)
    local err = invalid({ 'src', RANK_SPEC, 'table' }, src, rank, def)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if not hasPermIn(faction, info.charId, 'manage_ranks') then return false, 'no_permission' end
    if type(faction.ranks[rank]) ~= 'table' then return false, 'invalid_rank' end
    local isOwner = faction.ownerCharId == info.charId
    if not isOwner then
        if rank == #faction.ranks then return false, 'not_owner' end
        if rank >= faction.members[info.charId].rank then return false, 'rank_too_high' end
    end

    local ranks = Utils.deepCopy(faction.ranks)
    local entry = ranks[rank]
    if def.name ~= nil then
        local clean, len = cleanText(def.name, 32)
        if not clean or len < 1 then return false, 'invalid_name' end
        entry.name = clean
    end
    if def.perms ~= nil then
        if type(def.perms) ~= 'table' then return false, 'invalid_perms' end
        entry.perms = sanitizePerms(def.perms)
    end
    if not writeRanks(faction, ranks, {}, 'ranks of ' .. faction.id) then return false, 'save_failed' end
    replicateAll(faction)
    Log.audit('faction', src, 'changed rank %d of %s', rank, faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

--- Factions.addRank(src, name, perms?) -> bool, err — owner only.
--- The new rank becomes the top rank and the owner moves up to it; members keep their rank.
function Factions.addRank(src, name, perms)
    local err = invalid({ 'src', { 'string', max = 32 }, 'table?' }, src, name, perms)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if faction.ownerCharId ~= info.charId then return false, 'not_owner' end
    if #faction.ranks >= Config.Factions.MaxRanks then return false, 'max_ranks' end
    local clean, len = cleanText(name, 32)
    if not clean or len < 1 then return false, 'invalid_name' end

    local ranks = Utils.deepCopy(faction.ranks)
    ranks[#ranks + 1] = { name = clean, perms = sanitizePerms(perms) }
    if not writeRanks(faction, ranks, { [info.charId] = #ranks }, 'ranks of ' .. faction.id) then
        return false, 'save_failed'
    end
    replicateAll(faction)
    Log.audit('faction', src, 'added rank %s to %s', clean, faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

--- Factions.removeRank(src, rank) -> bool, err — owner only; members of that rank drop to 1, the ranks above
--- move down one, the owner stays on top.
function Factions.removeRank(src, rank)
    local err = invalid({ 'src', RANK_SPEC }, src, rank)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if faction.ownerCharId ~= info.charId then return false, 'not_owner' end
    if not faction.ranks[rank] then return false, 'invalid_rank' end
    if #faction.ranks <= 1 then return false, 'min_ranks' end

    local ranks = Utils.deepCopy(faction.ranks)
    table.remove(ranks, rank)
    local top, moves = #ranks, {}
    for charId, member in pairs(faction.members) do
        local new = member.rank
        if charId == faction.ownerCharId then
            new = top
        elseif member.rank == rank then
            new = 1
        elseif member.rank > rank then
            new = member.rank - 1
        end
        if new ~= member.rank then moves[charId] = new end
    end
    if not writeRanks(faction, ranks, moves, 'ranks of ' .. faction.id) then return false, 'save_failed' end
    replicateAll(faction)
    Log.audit('faction', src, 'removed rank %d from %s', rank, faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

--- Factions.setOwner(src, targetCharId) -> bool, err — owner only; the old owner drops one rank.
function Factions.setOwner(src, targetCharId)
    local err = invalid({ 'src', 'id' }, src, targetCharId)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if faction.ownerCharId ~= info.charId then return false, 'not_owner' end
    if targetCharId == info.charId then return false, 'self_target' end
    if not targetMember(faction, targetCharId) then return false, 'target_not_member' end

    local top = #faction.ranks
    local what = 'owner of ' .. faction.id
    if not queued(what, DB.patch('factions', faction.id, { owner_character_id = targetCharId }))
        or not writeRanks(faction, nil, { [targetCharId] = top, [info.charId] = top > 1 and top - 1 or 1 }, what) then
        return false, 'save_failed'
    end
    faction.ownerCharId = targetCharId
    replicateMember(faction, targetCharId)
    replicateMember(faction, info.charId)
    notify(Core.Player.getSrcByCharId(targetCharId), ('You now lead %s.'):format(faction.name), 'success')
    Log.audit('faction', src, 'transferred %s to charId=%s', faction.id, targetCharId)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

-- Bank: one guarded UPDATE per action (§56.8 rule 2), Core.Money moved around it

local AMOUNT_SPEC <const> = { 'integer', min = 1, max = Config.Money.MaxAmount }

--- After a bank statement failed: did it land anyway? Re-reads factions.bank; `expected` (memory's balance +/- the
--- amount) is the one value that change explains. true / false / nil (the re-read failed too: unknown).
local function bankLanded(err, id, expected)
    return committed(err, function()
        local bank, readErr = DB.scalar('SELECT bank FROM factions WHERE id = $1', { id })
        if readErr ~= nil then return nil end
        return bank == expected
    end)
end

--- A bank statement whose outcome cannot be told: nothing is refunded or paid twice, memory is re-read and the
--- numbers go to the log for the staff.
local function bankUnknown(what, id, charId, amount, err)
    scheduleResync(id)
    Log.error('factions: the %s of %d by %s on %s may or may not have landed (%s) — check the bank and his balance',
        what, amount, charId, id, tostring(err))
end

--- Factions.deposit(src, amount) -> bool, err — any member may deposit. Yields: the money leaves the player, the
--- bank statement runs, and a statement that did not land (bank full, error, faction disbanded) gives it back.
function Factions.deposit(src, amount)
    local err = invalid({ 'src', AMOUNT_SPEC }, src, amount)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    local max = Config.Money.MaxAmount
    if bankOf(faction) + amount > max then return false, 'bank_full' end
    if not Core.Money.remove(src, Config.Factions.CostAccount, amount, 'faction_deposit') then
        return false, 'insufficient_funds'
    end

    local id, before = faction.id, bankOf(faction)
    local row, sqlErr = DB.single(DEPOSIT_SQL, { id, amount, max })
    if not row and sqlErr ~= nil then
        local landed = bankLanded(sqlErr, id, before + amount)
        if landed == nil then
            bankUnknown('deposit', id, info.charId, amount, sqlErr)
            return false, 'save_failed'
        end
        row = landed or nil
    end
    if not row then
        refund(info.charId, amount, 'faction_deposit_rollback')
        if sqlErr ~= nil then
            Log.error('factions: the deposit into %s failed (%s)', id, tostring(sqlErr))
            return false, 'save_failed'
        end
        return false, factions[id] and 'bank_full' or 'no_faction'
    end
    if factions[id] ~= faction then
        -- disbanded while the statement ran: the deposit went down with the row, the member gets it back
        refund(info.charId, amount, 'faction_deposit_rollback')
        return false, 'no_faction'
    end
    -- the delta, not RETURNING: two statements of one faction may answer out of order, the sum never does
    faction.bank = bankOf(faction) + amount
    touch(faction)
    Log.audit('faction', src, 'deposited %d into %s', amount, id)
    Core.emitHook('factionUpdated', id)
    return true
end

--- Factions.withdraw(src, amount) -> bool, err — perm `bank`. Yields: the bank statement runs first, then the
--- payout; a payout that cannot land any more (the player left, the cap) puts the amount back into the bank.
function Factions.withdraw(src, amount)
    local err = invalid({ 'src', AMOUNT_SPEC }, src, amount)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if not hasPermIn(faction, info.charId, 'bank') then return false, 'no_permission' end
    if bankOf(faction) < amount then return false, 'insufficient_funds' end
    local account = Config.Factions.CostAccount
    if Core.Money.get(src, account) > Config.Money.MaxAmount - amount then return false, 'payout_failed' end

    local id, before = faction.id, bankOf(faction)
    local row, sqlErr = DB.single(WITHDRAW_SQL, { id, amount })
    if not row and sqlErr ~= nil then
        local landed = bankLanded(sqlErr, id, before - amount)
        if landed == nil then
            bankUnknown('withdrawal', id, info.charId, amount, sqlErr)
            return false, 'save_failed'
        end
        row = landed or nil
    end
    if not row then
        if sqlErr ~= nil then
            Log.error('factions: the withdrawal from %s failed (%s)', id, tostring(sqlErr))
            return false, 'save_failed'
        end
        return false, factions[id] and 'insufficient_funds' or 'no_faction'
    end
    faction.bank = math.max(0, bankOf(faction) - amount)
    -- paid by character: the src may belong to someone else after a drop during the statement
    local target = Core.Player.getSrcByCharId(info.charId)
    if not target or not Core.Money.add(target, account, amount, 'faction_withdraw') then
        local back, backErr = DB.execute(REFUND_SQL, { id, amount })
        if back then
            faction.bank = bankOf(faction) + amount
        else
            Log.error('factions: %d withdrawn from %s could not be paid out nor put back (%s)', amount, id,
                tostring(backErr))
        end
        return false, 'payout_failed'
    end
    touch(faction)
    Log.audit('faction', src, 'withdrew %d from %s', amount, id)
    Core.emitHook('factionUpdated', id)
    return true
end

-- The load, invite expiry sweep, session hooks, resource lifecycle

--- One loaded row -> the in-memory faction.
local function recordOf(row)
    if type(row) ~= 'table' or type(row.id) ~= 'string' then return nil end
    local members, list = {}, type(row.members) == 'table' and row.members or {}
    for i = 1, #list do
        local m = list[i]
        if type(m) == 'table' and type(m.charId) == 'string' then
            members[m.charId] = { rank = math.tointeger(m.rank) or 1, name = m.name or '', joinedAt = m.joinedAt }
        end
    end
    return {
        id = row.id, name = row.name or '', tag = row.tag or '', color = row.color or Config.Factions.DefaultColor,
        ownerCharId = row.owner_character_id, ranks = type(row.ranks) == 'table' and row.ranks or {},
        members = members, bank = math.tointeger(row.bank) or 0, meta = type(row.meta) == 'table' and row.meta or {},
        createdAt = row.created_at, updatedAt = row.updated_at,
    }
end

--- Every faction and member row, `sync` = after whatever a previous core run queued. Memory is replaced only by a
--- complete answer; a failed read leaves `loaded` false.
local function loadAll()
    local rows, err = DB.query(LOAD_SQL, nil, { sync = true })
    if not rows then return false, err end
    local byId, members = {}, {}
    for i = 1, #rows do
        local faction = recordOf(rows[i])
        if faction then
            byId[faction.id] = faction
            for charId in pairs(faction.members) do members[charId] = faction.id end
        end
    end
    factions, memberOf, loaded = byId, members, true
    return true
end

--- Makes memory, GlobalState and the online members agree with one faction as the database holds it (`record`; nil =
--- the row is gone). The faction table is updated IN PLACE (calls in flight hold it and compare identities), and a
--- member whose accepted invite is still being written keeps his reservation.
local function applyRecord(id, record)
    local faction = factions[id]
    local old = faction and faction.members or {}
    if not record then
        if not faction then return end
        factions[id] = nil
        purgeInvites(id)
        for charId in pairs(old) do
            if memberOf[charId] == id then
                memberOf[charId] = nil
                replicateMember(nil, charId)
            end
        end
        unpublish(id)
        Core.emitHook('factionUpdated', id)
        return
    end
    for charId, member in pairs(old) do
        if joining[charId] and memberOf[charId] == id then record.members[charId] = member end
    end
    if faction then
        for i = 1, #RECORD_KEYS do faction[RECORD_KEYS[i]] = record[RECORD_KEYS[i]] end
        faction.members = record.members
    else
        faction = record
        factions[id] = record
    end
    for charId in pairs(old) do
        if not faction.members[charId] and memberOf[charId] == id then
            memberOf[charId] = nil
            replicateMember(nil, charId)
        end
    end
    for charId in pairs(faction.members) do
        local other = memberOf[charId] ~= id and factions[memberOf[charId]]
        if other then            -- one faction per character (the rows' key): the database's wins
            other.members[charId] = nil
            publish(other)
        end
        memberOf[charId] = id
        replicateMember(faction, charId)
    end
    publish(faction)
    Core.emitHook('factionUpdated', id)
end

local resyncing = {}   -- [factionId] = true while its re-read is scheduled

--- Re-reads one faction after a write whose outcome memory cannot know (a dropped queued write, a lost COMMIT).
-- fxlint-disable-next-line C003 -- assigns the forward-declared LOCAL at the top (the writers above call it)
scheduleResync = function(id)
    if type(id) ~= 'string' or resyncing[id] or not running then return end
    resyncing[id] = true
    SetTimeout(0, function()
        local rows, err
        if loaded then rows, err = DB.query(LOAD_SQL .. ' WHERE f.id = $1', { id }, { sync = true }) end
        resyncing[id] = nil
        if loaded and not rows then
            Log.error('factions: could not re-read %s (%s) — retrying', id, tostring(err))
            SetTimeout(RESYNC_RETRY_MS, function() scheduleResync(id) end)
            return
        end
        if rows then applyRecord(id, rows[1] and recordOf(rows[1]) or nil) end
    end)
end

--- A queued write of core's that the database refused (§56.3.5: dropped, the rest of its flush committed). Memory
--- already shows it, so the rows it touched are read back — e.g. a dropped owner patch must not leave the transfer
--- in memory while the member ranks of the same slice landed.
Core.on('dbWriteFailed', function(owner, _, tbl, _, key)
    if owner ~= Core.name or type(key) ~= 'string' then return end
    if tbl == 'factions' then
        scheduleResync(key)
    elseif tbl == 'faction_members' then
        if memberOf[key] then scheduleResync(memberOf[key]) end
        SetTimeout(0, function()
            local row = DB.single('SELECT faction_id FROM faction_members WHERE character_id = $1', { key }, { sync = true })
            if row and row.faction_id ~= memberOf[key] then scheduleResync(row.faction_id) end
        end)
    end
end)

--- The load thread (file scope: it does not wait for onResourceStart). Retries with backoff until the rows are in,
--- then republishes the GlobalState summaries (empty again after a core restart; spread over ticks for the
--- state-bag budget) and reconciles the sessions that loaded first.
-- one thread per core start, and it ends with the load
-- fxlint-disable-next-line P004
CreateThread(function()
    local attempt = 0
    while running and not loaded do
        local ok, err = loadAll()
        if not ok then
            attempt = attempt + 1
            Log.error('factions: could not load the factions (%s) — faction actions answer "unavailable" until then',
                tostring(err))
            Wait(LOAD_BACKOFF_MS[math.min(attempt, #LOAD_BACKOFF_MS)])
        end
    end
    if not loaded then return end
    local written = 0
    for _, faction in pairs(factions) do
        publish(faction)
        written = written + 1
        -- batching yield over a finite list, not a per-frame loop: this thread exits below
        -- fxlint-disable-next-line P002
        if written % PUBLISH_CHUNK == 0 then Wait(0) end
    end
    Core.Player.forEach(reconcile)
end)

CreateThread(function()
    while running do
        Wait(SWEEP_INTERVAL_MS)
        local now = GetGameTimer()
        for targetSrc, invite in pairs(pending) do
            if now > invite.expires then
                pending[targetSrc] = nil
                notify(targetSrc, 'Your faction invite expired.', 'warning')
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    pending[src] = nil
    lastAction[src] = nil
end)

--- The state bag is authoritative for clients; refresh it (and a stale data.faction) once the session exists.
Core.on('playerLoaded', function(src)
    reconcile(src)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= Core.name then return end
    running = false
end)

-- Callbacks (DESIGN §5.2) — args validated here, rules enforced by the API above

--- Faction callbacks move money, write rows or copy member lists: at most one per second per src and per
--- bucket. Reads get their own bucket so a UI that opens with `mine` + `list` back to back is not refused;
--- every mutation shares the 'action' bucket.
local function throttled(src, bucket)
    local now = GetGameTimer()
    local buckets = lastAction[src]
    if not buckets then
        buckets = {}
        lastAction[src] = buckets
    end
    local key = bucket or 'action'
    if now - (buckets[key] or 0) < ACTION_COOLDOWN_MS then return true end
    buckets[key] = now
    return false
end

--- core:faction:<name> -> { argument schema (nil = none), handler(src, a, b), throttle bucket (nil = 'action') }.
local CALLBACKS <const> = {
    create = { { NAME_ARG, NAME_ARG }, function(src, name, tag)
        local id, err = Factions.create(src, name, tag)
        if not id then return false, err end
        return true, id
    end },
    --- own faction plus its member list; false when the player is in no faction
    mine = { nil, function(src)
        local summary = Factions.getPlayerFaction(src)
        if not summary then return false end
        summary.members = Factions.getMembers(summary.id)
        return summary
    end, 'mine' },
    list = { nil, function() return Factions.list() end, 'list' },
    invite = { { 'src' }, Factions.invite },
    kick = { { 'id' }, Factions.kick },
    setRank = { { 'id', RANK_SPEC }, Factions.setRank },
    setRankDef = { { RANK_SPEC, { 'table', keys = { name = 'string?', perms = 'table?' }, max = 4 } },
        Factions.setRankDef },
    deposit = { { AMOUNT_SPEC }, Factions.deposit },
    withdraw = { { AMOUNT_SPEC }, Factions.withdraw },
    accept = { nil, Factions.acceptInvite }, decline = { nil, Factions.declineInvite },
    leave = { nil, Factions.leave }, disband = { nil, Factions.disband },
}
for action, spec in pairs(CALLBACKS) do
    local schema, fn, bucket = spec[1], spec[2], spec[3]
    Core.Callback.register('core:faction:' .. action, function(src, a, b)
        if schema then
            local err = invalid(schema, a, b)
            if err then return false, err end
        end
        if throttled(src, bucket) then return false, 'too_fast' end
        if schema then return fn(src, a, b) end
        return fn(src)
    end)
end

-- end of file
