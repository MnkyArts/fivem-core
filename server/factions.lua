--- core — Core.Factions (server)
--- Faction documents (collection `factions`), membership + rank management, bank,
--- state-bag / GlobalState replication, invite expiry sweep and the core:faction:* callbacks.
--- Contract: DESIGN.md §4.5 (API), §5.2 (callbacks), §8 (replication + hooks), §10 (Config.Factions).

local Factions = {}
Core.Factions = Factions

local PERM_KEYS <const> = { 'invite', 'kick', 'manage_ranks', 'bank', 'manage' }
local COLOR_PATTERN <const> = '^#%x%x%x%x%x%x$'
-- Raw, unsanitized name/tag input: bounded here so no huge string ever reaches gsub.
local NAME_ARG <const> = { 'string', max = 64 }
local SWEEP_INTERVAL_MS <const> = 30000
local ACTION_COOLDOWN_MS <const> = 1000

local pending = {}     -- [targetSrc] = { factionId = id, expires = gameTimer ms, byName = string }
local lastAction = {}  -- [src] = { [bucket] = GetGameTimer() of the last call in that bucket }
local sweepRunning = true

--- Validate positional arguments; returns nil when ok, the error string otherwise.
local function invalid(schema, ...)
    local ok, err = Core.Validate.check(schema, ...)
    if ok then return nil end
    return err or 'invalid_arguments'
end

local function loadFaction(id)
    if type(id) ~= 'string' then return nil end
    return Core.DB.get('factions', id)
end

--- Returns false when the document store refused the write, so money-moving
--- callers can roll their Core.Money change back.
local function saveFaction(faction)
    return Core.DB.set('factions', faction.id, faction) == true
end

local function memberCount(faction)
    return Core.Utils.count(faction.members)
end

--- GlobalState entry read by any client/plugin that wants faction headlines (§8).
local function publish(faction)
    GlobalState['faction:' .. faction.id] = {
        name = faction.name,
        tag = faction.tag,
        color = faction.color,
        memberCount = memberCount(faction),
    }
end

local function unpublish(id)
    GlobalState['faction:' .. id] = false
end

local function rankName(faction, rank)
    local def = faction.ranks[rank]
    return (def and type(def.name) == 'string') and def.name or ('Rank ' .. tostring(rank))
end

local function rankPerms(faction, rank, isOwner)
    local out = {}
    local def = faction.ranks[rank]
    local perms = (def and type(def.perms) == 'table') and def.perms or nil
    for _, key in ipairs(PERM_KEYS) do
        out[key] = isOwner or (perms ~= nil and perms[key] == true)
    end
    return out
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

--- Write the character doc + player state bag for one member, online or not (§4.5).
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

local function notify(src, message, kind)
    if not src then return end
    Core.Notify.send(src, message, kind or 'info')
end

--- Loaded session + faction document of a member. Returns faction, member, info or nil, err.
local function context(src)
    local info = Core.Player.getInfo(src)
    if not info or not info.charId then return nil, 'not_loaded' end
    local ref = Core.Player.getData(src, 'faction')
    if type(ref) ~= 'table' or type(ref.id) ~= 'string' then return nil, 'no_faction' end
    local faction = loadFaction(ref.id)
    if not faction then
        Core.Player.setData(src, 'faction', false)
        return nil, 'no_faction'
    end
    local member = faction.members[info.charId]
    if not member then
        Core.Player.setData(src, 'faction', false)
        Player(src).state:set('faction', false, true)
        return nil, 'no_faction'
    end
    return faction, member, info
end

local function hasPermIn(faction, charId, perm)
    if faction.ownerCharId == charId then return true end
    local member = faction.members[charId]
    if not member then return false end
    local def = faction.ranks[member.rank]
    return def ~= nil and type(def.perms) == 'table' and def.perms[perm] == true
end

local function bankOf(faction)
    local amount = tonumber(faction.bank) or 0
    return math.floor(amount)
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

--- Factions.get(id) -> doc copy | nil
function Factions.get(id)
    if invalid({ 'id' }, id) then return nil end
    return loadFaction(id)
end

--- Factions.list() -> array of { id, name, tag, color, memberCount }
function Factions.list()
    local out = {}
    for _, faction in ipairs(Core.DB.all('factions')) do
        out[#out + 1] = {
            id = faction.id, name = faction.name, tag = faction.tag,
            color = faction.color, memberCount = memberCount(faction),
        }
    end
    return out
end

--- Factions.getMembers(id) -> array of { charId, name, rank, rankName, online = src|false }
function Factions.getMembers(id)
    if invalid({ 'id' }, id) then return {} end
    local faction = loadFaction(id)
    if not faction then return {} end
    local out = {}
    for charId, member in pairs(faction.members) do
        out[#out + 1] = {
            charId = charId,
            name = member.name,
            rank = member.rank,
            rankName = rankName(faction, member.rank),
            online = Core.Player.getSrcByCharId(charId) or false,
        }
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
    local faction = Factions.get(id)
    return faction and bankOf(faction) or 0
end

--- Plugin scratch space on the document (server only).
function Factions.setMeta(id, key, value)
    if invalid({ 'id', { 'string', max = 64 } }, id, key) then return false end
    local faction = loadFaction(id)
    if not faction then return false end
    if type(faction.meta) ~= 'table' then faction.meta = {} end
    faction.meta[key] = Core.Utils.jsonSafe(value)
    saveFaction(faction)
    return true
end

function Factions.getMeta(id, key)
    local faction = Factions.get(id)
    if not faction or type(faction.meta) ~= 'table' then return nil end
    return faction.meta[key]
end

-- ---------------------------------------------------------------------------
-- Lifecycle (create / disband / update)
-- ---------------------------------------------------------------------------

local function checkName(name)
    local clean = Core.Utils.sanitize(name, Config.Factions.NameMax)
    if #clean < Config.Factions.NameMin then return nil, 'invalid_name' end
    return clean
end

local function checkTag(tag)
    local clean = Core.Utils.sanitize(tag, Config.Factions.TagMax):upper()
    if #clean < Config.Factions.TagMin or not clean:match(Config.Factions.TagPattern) then
        return nil, 'invalid_tag'
    end
    return clean
end

local function checkColor(color)
    if color == nil then return Config.Factions.DefaultColor end
    if type(color) ~= 'string' or not color:match(COLOR_PATTERN) then return nil, 'invalid_color' end
    return color:lower()
end

--- Names and tags are unique across factions (case-insensitive). The predicate form of
--- DB.findOne runs in-VM and copies at most the one match, unlike DB.all.
local function duplicateOf(name, tag, exceptId)
    if name then
        local lowerName = name:lower()
        local hit = Core.DB.findOne('factions', function(doc)
            return doc.id ~= exceptId and type(doc.name) == 'string' and doc.name:lower() == lowerName
        end)
        if hit then return 'name_taken' end
    end
    if tag then
        local upperTag = tag:upper()
        local hit = Core.DB.findOne('factions', function(doc)
            return doc.id ~= exceptId and type(doc.tag) == 'string' and doc.tag:upper() == upperTag
        end)
        if hit then return 'tag_taken' end
    end
    return nil
end

local function defaultRanks()
    local out = {}
    for i, def in ipairs(Config.Factions.DefaultRanks) do
        out[i] = { name = Core.Utils.sanitize(def.name, 32), perms = sanitizePerms(def.perms) }
    end
    return out
end

--- Factions.create(src, name, tag, opts?) -> id | nil, err
function Factions.create(src, name, tag, opts)
    local err = invalid({ 'src', NAME_ARG, NAME_ARG, 'table?' }, src, name, tag, opts)
    if err then return nil, err end
    local info = Core.Player.getInfo(src)
    if not info or not info.charId then return nil, 'not_loaded' end
    if context(src) then return nil, 'already_in_faction' end

    local cleanName, nameErr = checkName(name)
    if not cleanName then return nil, nameErr end
    local cleanTag, tagErr = checkTag(tag)
    if not cleanTag then return nil, tagErr end
    local color, colorErr = checkColor(opts and opts.color)
    if not color then return nil, colorErr end
    local duplicate = duplicateOf(cleanName, cleanTag, nil)
    if duplicate then return nil, duplicate end

    local cfg = Config.Factions
    if cfg.CreateCost > 0 and not Core.Money.canAfford(src, cfg.CostAccount, cfg.CreateCost) then
        return nil, 'insufficient_funds'
    end
    local ranks = defaultRanks()
    local id = Core.DB.create('factions', {
        name = cleanName, tag = cleanTag, color = color, ownerCharId = info.charId, ranks = ranks,
        members = { [info.charId] = { rank = #ranks, name = info.name or GetPlayerName(src), joinedAt = os.time() } },
        bank = 0, meta = {},
    })
    if not id then return nil, 'create_failed' end
    if cfg.CreateCost > 0 and not Core.Money.remove(src, cfg.CostAccount, cfg.CreateCost, 'faction_create') then
        Core.DB.delete('factions', id)
        return nil, 'insufficient_funds'
    end
    local faction = loadFaction(id)
    if not faction then
        if cfg.CreateCost > 0 then
            Core.Money.add(src, cfg.CostAccount, cfg.CreateCost, 'faction_create_rollback')
        end
        Core.DB.delete('factions', id)
        return nil, 'save_failed'
    end
    publish(faction)
    replicateMember(faction, info.charId)
    Core.Log.audit('faction', src, 'created %s [%s] id=%s', cleanName, cleanTag, id)
    Core.emitHook('factionUpdated', id)
    return id
end

--- Drop every pending invite that points at a faction.
local function purgeInvites(factionId)
    for targetSrc, invite in pairs(pending) do
        if invite.factionId == factionId then pending[targetSrc] = nil end
    end
end

--- Factions.disband(src) -> bool, err — owner only; the faction bank is lost.
function Factions.disband(src)
    local err = invalid({ 'src' }, src)
    if err then return false, err end
    -- context() returns nil, err on failure; `failure` carries that error string.
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if faction.ownerCharId ~= info.charId then return false, 'not_owner' end

    local id, name = faction.id, faction.name
    local charIds = Core.Utils.keys(faction.members)
    Core.DB.delete('factions', id)
    purgeInvites(id)
    for _, charId in ipairs(charIds) do
        local target = Core.Player.getSrcByCharId(charId)
        replicateMember(nil, charId)
        if target and target ~= src then
            notify(target, ('%s has been disbanded.'):format(name), 'warning')
        end
    end
    unpublish(id)
    Core.Log.audit('faction', src, 'disbanded %s id=%s', name, id)
    Core.emitHook('factionUpdated', id)
    return true
end

--- Factions.update(src, { name?, tag?, color? }) -> bool, err — perm `manage`.
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

    faction.name = newName or faction.name
    faction.tag = newTag or faction.tag
    faction.color = newColor or faction.color
    saveFaction(faction)
    publish(faction)
    replicateAll(faction)
    Core.Log.audit('faction', src, 'updated %s id=%s', faction.name, faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

-- ---------------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------------

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
    if context(targetSrc) then return false, 'target_in_faction' end

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
    Core.Log.audit('faction', src, 'invited src=%d to %s', targetSrc, faction.id)
    return true
end

--- Factions.acceptInvite(src) -> bool, err — joins at rank 1; expiry checked here and by the sweep.
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
    if context(src) then
        pending[src] = nil
        return false, 'already_in_faction'
    end
    local faction = loadFaction(invite.factionId)
    if not faction then
        pending[src] = nil
        return false, 'no_faction'
    end
    if memberCount(faction) >= Config.Factions.MaxMembers then return false, 'faction_full' end

    pending[src] = nil
    faction.members[info.charId] = {
        rank = 1, name = info.name or GetPlayerName(src), joinedAt = os.time(),
    }
    saveFaction(faction)
    publish(faction)
    replicateMember(faction, info.charId)
    Core.Log.audit('faction', src, 'joined %s', faction.id)
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

    faction.members[info.charId] = nil
    saveFaction(faction)
    publish(faction)
    replicateMember(nil, info.charId)
    Core.Log.audit('faction', src, 'left %s', faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

--- Factions.kick(src, targetCharId) -> bool, err — perm `kick`; never the owner or a higher rank.
function Factions.kick(src, targetCharId)
    local err = invalid({ 'src', 'id' }, src, targetCharId)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if not hasPermIn(faction, info.charId, 'kick') then return false, 'no_permission' end
    if targetCharId == info.charId then return false, 'self_target' end
    local target = faction.members[targetCharId]
    if not target then return false, 'target_not_member' end
    if faction.ownerCharId == targetCharId then return false, 'cannot_kick_owner' end
    if faction.ownerCharId ~= info.charId and target.rank > faction.members[info.charId].rank then
        return false, 'rank_too_high'
    end

    faction.members[targetCharId] = nil
    saveFaction(faction)
    publish(faction)
    replicateMember(nil, targetCharId)
    notify(Core.Player.getSrcByCharId(targetCharId), ('You were removed from %s.'):format(faction.name), 'error')
    Core.Log.audit('faction', src, 'kicked charId=%s from %s', targetCharId, faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

-- ---------------------------------------------------------------------------
-- Ranks and ownership
-- ---------------------------------------------------------------------------

local RANK_SPEC <const> = { 'integer', min = 1, max = Config.Factions.MaxRanks }

--- Factions.setRank(src, targetCharId, rank) -> bool, err — perm `manage_ranks`.
function Factions.setRank(src, targetCharId, rank)
    local err = invalid({ 'src', 'id', RANK_SPEC }, src, targetCharId, rank)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if not hasPermIn(faction, info.charId, 'manage_ranks') then return false, 'no_permission' end
    if not faction.ranks[rank] then return false, 'invalid_rank' end
    if targetCharId == info.charId then return false, 'self_target' end
    local target = faction.members[targetCharId]
    if not target then return false, 'target_not_member' end
    if faction.ownerCharId == targetCharId then return false, 'cannot_demote_owner' end
    local ownRank = faction.members[info.charId].rank
    if faction.ownerCharId ~= info.charId and (rank >= ownRank or target.rank >= ownRank) then
        return false, 'rank_too_high'
    end

    target.rank = rank
    saveFaction(faction)
    replicateMember(faction, targetCharId)
    Core.Log.audit('faction', src, 'set rank %d for charId=%s in %s', rank, targetCharId, faction.id)
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
    local entry = faction.ranks[rank]
    if not entry then return false, 'invalid_rank' end
    local isOwner = faction.ownerCharId == info.charId
    if not isOwner then
        if rank == #faction.ranks then return false, 'not_owner' end
        if rank >= faction.members[info.charId].rank then return false, 'rank_too_high' end
    end

    if def.name ~= nil then
        local clean = Core.Utils.sanitize(def.name, 32)
        if #clean < 1 then return false, 'invalid_name' end
        entry.name = clean
    end
    if def.perms ~= nil then
        if type(def.perms) ~= 'table' then return false, 'invalid_perms' end
        entry.perms = sanitizePerms(def.perms)
    end
    saveFaction(faction)
    replicateAll(faction)
    Core.Log.audit('faction', src, 'changed rank %d of %s', rank, faction.id)
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
    local clean = Core.Utils.sanitize(name, 32)
    if #clean < 1 then return false, 'invalid_name' end

    faction.ranks[#faction.ranks + 1] = { name = clean, perms = sanitizePerms(perms) }
    faction.members[info.charId].rank = #faction.ranks
    saveFaction(faction)
    replicateAll(faction)
    Core.Log.audit('faction', src, 'added rank %s to %s', clean, faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

--- Factions.removeRank(src, rank) -> bool, err — owner only; members of that rank drop to 1.
function Factions.removeRank(src, rank)
    local err = invalid({ 'src', RANK_SPEC }, src, rank)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if faction.ownerCharId ~= info.charId then return false, 'not_owner' end
    if not faction.ranks[rank] then return false, 'invalid_rank' end
    if #faction.ranks <= 1 then return false, 'min_ranks' end

    table.remove(faction.ranks, rank)
    local top = #faction.ranks
    for charId, member in pairs(faction.members) do
        if member.rank == rank then
            member.rank = 1
        elseif member.rank > rank then
            member.rank = member.rank - 1
        end
        if charId == faction.ownerCharId then member.rank = top end
    end
    saveFaction(faction)
    replicateAll(faction)
    Core.Log.audit('faction', src, 'removed rank %d from %s', rank, faction.id)
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
    local target = faction.members[targetCharId]
    if not target then return false, 'target_not_member' end

    local top = #faction.ranks
    faction.ownerCharId = targetCharId
    target.rank = top
    faction.members[info.charId].rank = top > 1 and top - 1 or 1
    saveFaction(faction)
    replicateMember(faction, targetCharId)
    replicateMember(faction, info.charId)
    notify(Core.Player.getSrcByCharId(targetCharId), ('You now lead %s.'):format(faction.name), 'success')
    Core.Log.audit('faction', src, 'transferred %s to charId=%s', faction.id, targetCharId)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

-- ---------------------------------------------------------------------------
-- Bank
-- ---------------------------------------------------------------------------

local AMOUNT_SPEC <const> = { 'integer', min = 1, max = Config.Money.MaxAmount }

--- Factions.deposit(src, amount) -> bool, err — any member may deposit.
function Factions.deposit(src, amount)
    local err = invalid({ 'src', AMOUNT_SPEC }, src, amount)
    if err then return false, err end
    local faction, failure = context(src)
    if not faction then return false, failure end
    local balance = bankOf(faction)
    if balance + amount > Config.Money.MaxAmount then return false, 'bank_full' end
    if not Core.Money.remove(src, Config.Factions.CostAccount, amount, 'faction_deposit') then
        return false, 'insufficient_funds'
    end

    faction.bank = balance + amount
    if not saveFaction(faction) then
        Core.Money.add(src, Config.Factions.CostAccount, amount, 'faction_deposit_rollback')
        return false, 'save_failed'
    end
    Core.Log.audit('faction', src, 'deposited %d into %s', amount, faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

--- Factions.withdraw(src, amount) -> bool, err — perm `bank`.
function Factions.withdraw(src, amount)
    local err = invalid({ 'src', AMOUNT_SPEC }, src, amount)
    if err then return false, err end
    local faction, failure, info = context(src)
    if not faction then return false, failure end
    if not hasPermIn(faction, info.charId, 'bank') then return false, 'no_permission' end
    local balance = bankOf(faction)
    if balance < amount then return false, 'insufficient_funds' end
    if not Core.Money.add(src, Config.Factions.CostAccount, amount, 'faction_withdraw') then
        return false, 'payout_failed'
    end

    faction.bank = balance - amount
    if not saveFaction(faction) then
        Core.Money.remove(src, Config.Factions.CostAccount, amount, 'faction_withdraw_rollback')
        return false, 'save_failed'
    end
    Core.Log.audit('faction', src, 'withdrew %d from %s', amount, faction.id)
    Core.emitHook('factionUpdated', faction.id)
    return true
end

-- ---------------------------------------------------------------------------
-- Invite expiry sweep, session cleanup, resource lifecycle
-- ---------------------------------------------------------------------------

CreateThread(function()
    while sweepRunning do
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

--- Faction summaries live in GlobalState, which is empty again after a core restart.
--- Spread the writes: the state-bag budget is 75/s burst 125, over-budget writes are dropped.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= Core.name then return end
    -- one thread per core start (the handler is name-guarded), and it ends with the loop
    -- fxlint-disable-next-line P004
    CreateThread(function()
        local written = 0
        for _, faction in ipairs(Core.DB.all('factions')) do
            publish(faction)
            written = written + 1
            -- batching yield over a finite list, not a per-frame loop: this thread exits below
            -- fxlint-disable-next-line P002
            if written % 50 == 0 then Wait(0) end
        end
    end)
end)

--- The state bag is authoritative for clients; refresh it once the session exists.
Core.on('playerLoaded', function(src)
    local faction, _, info = context(src)
    local summary = faction and stateSummary(memberSummary(faction, info.charId)) or false
    Player(src).state:set('faction', summary, true)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= Core.name then return end
    sweepRunning = false
end)

-- ---------------------------------------------------------------------------
-- Callbacks (DESIGN §5.2) — args validated here, rules enforced by the API above
-- ---------------------------------------------------------------------------

--- Faction callbacks move money, rewrite documents or deep-copy them: at most one per
--- second per src and per bucket. Reads get their own bucket so a UI that opens with
--- `mine` + `list` back to back is not refused; every mutation shares the 'action' bucket.
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

Core.Callback.register('core:faction:create', function(src, name, tag)
    local err = invalid({ NAME_ARG, NAME_ARG }, name, tag)
    if err then return false, err end
    if throttled(src) then return false, 'too_fast' end
    local id, createErr = Factions.create(src, name, tag)
    if not id then return false, createErr end
    return true, id
end)

--- Own faction plus its member list; false when the player is in no faction or throttled.
Core.Callback.register('core:faction:mine', function(src)
    if throttled(src, 'mine') then return false, 'too_fast' end
    local summary = Factions.getPlayerFaction(src)
    if not summary then return false end
    summary.members = Factions.getMembers(summary.id)
    return summary
end)

Core.Callback.register('core:faction:list', function(src)
    if throttled(src, 'list') then return false, 'too_fast' end
    return Factions.list()
end)

Core.Callback.register('core:faction:invite', function(src, targetSrc)
    local err = invalid({ 'src' }, targetSrc)
    if err then return false, err end
    if throttled(src) then return false, 'too_fast' end
    return Factions.invite(src, targetSrc)
end)

Core.Callback.register('core:faction:kick', function(src, charId)
    local err = invalid({ 'id' }, charId)
    if err then return false, err end
    if throttled(src) then return false, 'too_fast' end
    return Factions.kick(src, charId)
end)

Core.Callback.register('core:faction:setRank', function(src, charId, rank)
    local err = invalid({ 'id', RANK_SPEC }, charId, rank)
    if err then return false, err end
    if throttled(src) then return false, 'too_fast' end
    return Factions.setRank(src, charId, rank)
end)

Core.Callback.register('core:faction:setRankDef', function(src, rank, def)
    local err = invalid({ RANK_SPEC, { 'table', keys = { name = 'string?', perms = 'table?' }, max = 4 } }, rank, def)
    if err then return false, err end
    if throttled(src) then return false, 'too_fast' end
    return Factions.setRankDef(src, rank, def)
end)

for action, fn in pairs({ deposit = Factions.deposit, withdraw = Factions.withdraw }) do
    Core.Callback.register('core:faction:' .. action, function(src, amount)
        local err = invalid({ AMOUNT_SPEC }, amount)
        if err then return false, err end
        if throttled(src) then return false, 'too_fast' end
        return fn(src, amount)
    end)
end

local NO_ARG_ACTIONS <const> = {
    accept = Factions.acceptInvite, decline = Factions.declineInvite,
    leave = Factions.leave, disband = Factions.disband,
}
for action, fn in pairs(NO_ARG_ACTIONS) do
    Core.Callback.register('core:faction:' .. action, function(src)
        if throttled(src) then return false, 'too_fast' end
        return fn(src)
    end)
end

-- end of file
