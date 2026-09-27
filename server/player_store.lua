--[[
    core/server/player_store.lua — the rows behind Core.Player sessions (DESIGN §56.6, §56.8)

    The persistence half of server/player.lua, split off so neither file passes ~900 lines. Stateless:
    player.lua owns the sessions, this file maps rows <-> the shapes every caller has always seen
    (`Player.getData` = the character "document" with camelCase keys, `money = { cash, bank, … }`,
    times as Unix seconds, plugin keys at the top level) and queues every write. It loads RIGHT BEFORE
    server/player.lua and hands its table over through the one-shot global `CorePlayerStore` (player.lua
    asserts and clears it), so nothing here is reachable through the export.

    Reads — AWAITED, they yield (callers run in a thread, event handler or command):
      loadAccount(license)            accounts by license (accounts_license_key), { sync = true }
      createAccount(license, name)    awaited insert; the 23505 of a concurrent join re-selects
      loadCharacter(accountId)        ONE round trip: the character + money (jsonb_object_agg over
                                      character_money) + faction (faction_members), { sync = true }
      createCharacter(accountId, name) the character and its money rows in ONE transaction
      readAccount(accountId)          the offline account + identifiers, one query, { sync = true }
      activeBan(identifiers)          the connect-path fallback: one indexed query (ban_identifiers + bans)
    A failed read answers nil, err — never "none" (§56.8 rule 4); "none" is false.

    Connection identity and the connect gate (§47): identifierOf(src, kind), collectIdentifiers(src) (every
    kind but ip), connectingBan(src, license) — Core.Bans.checkConnecting, else the activeBan query; a FAILED
    query refuses the connection while the setting bans.failClosed is on (the default).

    Writes — QUEUED, never yield (safe in onResourceStop):
      markChar(session, key) / markAccount(session, key)   flag one top-level key dirty
      flush(list)       per list of sessions (§56.8 rule 6): ONE characters patch per session (dirty
                        columns only, + last_played), the changed character_money rows, ONE accounts patch
                        per session, then the plugin `data` maps. A session with nothing dirty writes nothing.
      saveIdentifiers(accountId, identifiers)   one queued save per identifier kind
    Plugin keys (any top-level key that is no column) live in `characters.data` / `accounts.data`, written as a
    `patch` of the whole map (bulk, coalesced); an EMPTY map crosses msgpack as [], so only then one keyed
    statement turns a stored non-object into {} (order-safe against a later patch of the row). Every value is
    checked before it is queued: one that cannot be stored (a function, userdata, …) is logged and left out —
    alone, never the rest of its row or map. A write refused as 'unavailable' stays dirty for the next save;
    any other refusal is logged and dropped. When core_db drops a queued write later (hook dbWriteFailed,
    §56.3.5), player.lua calls writeFailed and the next save re-sends that row.

    Natives (fxref, CFX server): GetPlayerIdentifierByType(playerSrc, identifierType),
    GetNumPlayerIdentifiers(playerSrc), GetPlayerIdentifier(playerSrc, identiferIndex). Everything else is
    Core.DB, Core.Utils and os.time / os.date.
]]

local Store = {}

local DB = Core.DB
local Log = Core.Log
local Utils = Core.Utils

-- character key -> { column, kind }; kinds: text | texts (text[]) | json | nullable (json or NULL)
local CHAR_COLUMNS <const> = {
    name = { 'name', 'text' }, model = { 'model', 'text' }, appearance = { 'appearance', 'json' },
    position = { 'position', 'nullable' }, stats = { 'stats', 'json' }, weapons = { 'weapons', 'json' },
    attachments = { 'attachments', 'json' }, meta = { 'meta', 'json' },
    permissions = { 'permissions', 'texts' }, tempPermissions = { 'temp_permissions', 'json' },
}
-- document keys that are neither a column nor a plugin key: read-only columns, money rows, the session-only faction
local CHAR_RESERVED <const> = { id = true, accountId = true, createdAt = true, updatedAt = true, money = true, faction = true }

-- account key -> { column, kind }; kinds as above plus time (Unix seconds), count (integer >= 0), bool
local ACCOUNT_COLUMNS <const> = {
    name = { 'name', 'text' }, group = { 'perm_group', 'text' }, firstSeen = { 'first_seen', 'time' },
    lastSeen = { 'last_seen', 'time' }, playtime = { 'playtime', 'count' }, banned = { 'banned', 'bool' },
    permissions = { 'permissions', 'texts' }, tempPermissions = { 'temp_permissions', 'json' },
}
local ACCOUNT_RESERVED <const> = { id = true, license = true, identifiers = true, createdAt = true, updatedAt = true }

local ID_TYPES <const> = { 'license', 'license2', 'discord', 'fivem', 'steam', 'xbl', 'live' }   -- fallback list
local MAX_PLAYTIME <const> = 2147483647
local MONEY_KEY <const> = '^[%a_][%w_]*$'
local MAX_MONEY_KEY <const> = 32
local BAN_READ_TIMEOUT_MS <const> = 5000
local MAX_VALUE_DEPTH <const> = 32

Store.CHAR_COLUMNS, Store.CHAR_RESERVED = CHAR_COLUMNS, CHAR_RESERVED
Store.ACCOUNT_COLUMNS, Store.ACCOUNT_RESERVED = ACCOUNT_COLUMNS, ACCOUNT_RESERVED

--------------------------------------------------------------------------------
-- reads (awaited)
--------------------------------------------------------------------------------

-- the character with its money rows and faction membership: ONE round trip (§56.8 rule 5)
local CHARACTER_SQL <const> = [[
SELECT c.id, c.account_id, c.name, c.model, c.appearance, c.position, c.stats, c.weapons, c.attachments,
       c.meta, c.permissions, c.temp_permissions, c.data, c.created_at, c.updated_at,
       (SELECT jsonb_object_agg(m.account, m.balance) FROM character_money m WHERE m.character_id = c.id) AS money,
       (SELECT jsonb_build_object('id', f.faction_id, 'rank', f.rank)
          FROM faction_members f WHERE f.character_id = c.id) AS faction
FROM characters c
WHERE c.account_id = $1
ORDER BY c.created_at, c.id
LIMIT 1]]

-- the offline account reader (§48): the row and its identifiers map
local ACCOUNT_SQL <const> = [[
SELECT a.*, (SELECT jsonb_object_agg(i.kind, i.identifier) FROM account_identifiers i
             WHERE i.account_id = a.id) AS identifiers
FROM accounts a
WHERE a.id = $1]]

-- an active ban on any of the identifiers (§47 fallback): unrevoked, and permanent or not expired yet
local BAN_SQL <const> = [[
SELECT b.id, b.reason, b.expires_at
FROM ban_identifiers i
JOIN bans b ON b.id = i.ban_id
WHERE i.identifier = ANY($1::text[]) AND b.revoked_at IS NULL
  AND (b.expires_at IS NULL OR b.expires_at > to_timestamp($2))
ORDER BY b.expires_at DESC NULLS FIRST, b.id
LIMIT 1]]

--- A JSON map column as a Lua table (a jsonb `[]` — the empty Lua table of old documents — reads as {}).
local function mapOf(value)
    return type(value) == 'table' and value or {}
end

--- The account "document" of a row: camelCase keys, plugin keys from `data` at the top level.
local function accountFromRow(row, identifiers)
    local account = {
        id = row.id, license = row.license, name = row.name or '', group = row.perm_group or 'user',
        firstSeen = row.first_seen, lastSeen = row.last_seen, playtime = row.playtime or 0,
        banned = row.banned == true, permissions = mapOf(row.permissions), tempPermissions = mapOf(row.temp_permissions),
        createdAt = row.created_at, updatedAt = row.updated_at, identifiers = mapOf(identifiers),
    }
    for key, value in pairs(mapOf(row.data)) do
        if type(key) == 'string' and account[key] == nil and not ACCOUNT_COLUMNS[key] and not ACCOUNT_RESERVED[key] then
            account[key] = value
        end
    end
    return account
end
Store.accountFromRow = accountFromRow

--- The character "document" of a row (with `money` and `faction` from the sub-selects).
local function characterFromRow(row)
    local faction = row.faction
    local character = {
        id = row.id, accountId = row.account_id, name = row.name or '', model = row.model,
        appearance = mapOf(row.appearance), position = type(row.position) == 'table' and row.position or nil,
        stats = mapOf(row.stats), weapons = mapOf(row.weapons), attachments = mapOf(row.attachments),
        meta = mapOf(row.meta), permissions = mapOf(row.permissions), tempPermissions = mapOf(row.temp_permissions),
        money = mapOf(row.money), createdAt = row.created_at, updatedAt = row.updated_at,
        faction = (type(faction) == 'table' and faction.id ~= nil) and { id = faction.id, rank = faction.rank } or false,
    }
    for key, value in pairs(mapOf(row.data)) do
        if type(key) == 'string' and character[key] == nil and not CHAR_COLUMNS[key] and not CHAR_RESERVED[key] then
            character[key] = value
        end
    end
    return character
end

--- accounts by license → account | false (none) | nil, err. `sync` defaults to true (read-your-writes); the
--- restore after `restart core` passes false once it flushed (§56.8 rule 5, review R2a item 4).
function Store.loadAccount(license, sync)
    local row, err = DB.first('accounts', { license = license }, { sync = sync ~= false })
    if row == nil then
        if err ~= nil then return nil, err end
        return false
    end
    return accountFromRow(row)
end

--- A new account (awaited: the id is needed at once). A concurrent join of the same license loses the
--- UNIQUE race with 23505 and reads the winner's row instead.
function Store.createAccount(license, name)
    local row, err = DB.insert('accounts', { id = Utils.uuid(), license = license, name = name })
    if row then return accountFromRow(row) end
    if DB.errorCode(err) == '23505' then
        local account, readErr = Store.loadAccount(license)
        if account then return account end
        return nil, readErr or err
    end
    return nil, err
end

--- The account's character → character | false (none) | nil, err. `sync` as in loadAccount.
function Store.loadCharacter(accountId, sync)
    local rows, err = DB.query(CHARACTER_SQL, { accountId }, { sync = sync ~= false })
    if not rows then return nil, err end
    if rows[1] == nil then return false end
    return characterFromRow(rows[1])
end

--- The rows a session needs: the account (created when there is none) and its character (false = none yet)
--- → true, account, character | false, 'account'|'character', err.
function Store.readRows(license, name, sync)
    local account, err = Store.loadAccount(license, sync)
    if account == nil then return false, 'account', err end
    if account == false then
        account, err = Store.createAccount(license, name)
        if not account then return false, 'account', err end
    end
    local character
    character, err = Store.loadCharacter(account.id, sync)
    if character == nil then return false, 'character', err end
    return true, account, character
end

--- The first character of a new account (Config.Player.NewCharacter) and one money row per
--- Config.Money.Accounts key, in ONE transaction → character | nil, err.
function Store.createCharacter(accountId, name)
    local spawn = Config.Player.SpawnPoint
    local defaults = (Config.Player.NewCharacter or {}).money or {}
    local id = Utils.uuid()
    local accounts = {}
    for account in pairs(Config.Money.Accounts) do accounts[#accounts + 1] = account end
    table.sort(accounts)
    local moneyRows, money = {}, {}
    for i = 1, #accounts do
        local balance = type(defaults[accounts[i]]) == 'number' and math.tointeger(defaults[accounts[i]]) or 0
        moneyRows[i] = { character_id = id, account = accounts[i], balance = balance }
        money[accounts[i]] = balance
    end
    local ok, row = DB.transaction(function(tx)
        local created, err = tx.insert('characters', {
            id = id, account_id = accountId, name = name, model = Config.Player.DefaultModel,
            position = { x = spawn.coords.x, y = spawn.coords.y, z = spawn.coords.z, heading = spawn.heading + 0.0 },
            stats = { deaths = 0, playtime = 0 },
        })
        if not created then return false, err end
        if moneyRows[1] then
            local count, moneyErr = tx.insertMany('character_money', moneyRows)
            if not count then return false, moneyErr end
        end
        return created
    end)
    if not ok then return nil, row end
    row.money = money
    return characterFromRow(row)
end

--- The stored account view (offline, §48) → account | false (none) | nil, err.
function Store.readAccount(accountId)
    local rows, err = DB.query(ACCOUNT_SQL, { tostring(accountId) }, { sync = true })
    if not rows then return nil, err end
    if rows[1] == nil then return false end
    return accountFromRow(rows[1], rows[1].identifiers)
end

--- The newest active ban naming one of `identifiers` → { id, reason, expiresAt? } | false | nil, err. A connecting
--- player waits for it, so it gives up after BAN_READ_TIMEOUT_MS (an outage refuses in ~5 s, not ~30 s).
function Store.activeBan(identifiers)
    local rows, err = DB.query(BAN_SQL, { identifiers, os.time() }, { timeout = BAN_READ_TIMEOUT_MS })
    if not rows then return nil, err end
    local row = rows[1]
    if row == nil then return false end
    return { id = row.id, reason = row.reason, expiresAt = row.expires_at }
end

--------------------------------------------------------------------------------
-- the connection's identifiers and the connect-time ban gate (§47)
--------------------------------------------------------------------------------

--- One identifier of a kind. The engine PREFIX-matches, so 'license' may answer 'license2:…': ask with the
--- colon (§47) and accept only a value that carries it.
function Store.identifierOf(src, kind)
    local prefix = kind .. ':'
    local value = GetPlayerIdentifierByType(src, prefix)
    return type(value) == 'string' and value:sub(1, #prefix) == prefix and value or nil
end
local identifierOf = Store.identifierOf

--- The identifier set of a connection: { kind = 'kind:value' } — account_identifiers and the session's view.
--- R2-3: EVERY identifier type except ip: (the §47 index and ban holders must see license2/xbl/live too).
function Store.collectIdentifiers(src)
    local out = {}
    local count = GetNumPlayerIdentifiers ~= nil and tonumber(GetNumPlayerIdentifiers(src)) or nil
    if not count then
        for i = 1, #ID_TYPES do out[ID_TYPES[i]] = identifierOf(src, ID_TYPES[i]) end
        return out
    end
    for i = 0, count - 1 do
        local id = GetPlayerIdentifier(src, i)
        local kind = type(id) == 'string' and #id <= 128 and id:match('^(%w+):.') or nil
        if kind and kind ~= 'ip' and out[kind] == nil then out[kind] = id end
    end
    return out
end

--- Reject text for a ban (§47 `expiresAt`, or the pre-§47 `until` some Core.Bans answers may still carry).
local function banNotice(ban)
    local expiry = tonumber(ban.expiresAt or ban['until']) or 0
    local head = expiry == 0 and 'You are permanently banned.'
        or ('You are banned until %s.'):format(os.date('%Y-%m-%d %H:%M', math.floor(expiry)))
    return ('%s Reason: %s%s'):format(head, Utils.sanitize(ban.reason or 'No reason given', 128),
        ban.id ~= nil and (' (ban %s)'):format(tostring(ban.id)) or '')
end

--- Setting `bans.failClosed` (§47, defined by server/bans.lua): default true = refuse while unreadable.
local function failClosed()
    local settings = Core.Settings
    if type(settings) ~= 'table' or not Utils.isCallable(settings.get) then return true end
    local ok, value = pcall(settings.get, 'bans.failClosed')
    return not (ok and value == false)
end

--- The ban blocking this connection and its reject text, or nil (§47). Core.Bans collects, checks and enriches;
--- when it is missing, throws or answers `nil, 'unavailable'`, ONE indexed query (ban_identifiers + bans) looks
--- up the connecting identifiers here, and when that query FAILS bans.failClosed refuses the connection
--- (§56.8 rule 4: driven by the read error). Yields.
function Store.connectingBan(src, license)
    local bans = Core.Bans
    if type(bans) == 'table' and Utils.isCallable(bans.checkConnecting) then
        local ok, ban, notice = pcall(bans.checkConnecting, src)
        if ok and ban then
            if type(notice) == 'string' then return ban, notice end
            return ban, type(ban) == 'table' and banNotice(ban) or 'You are banned from this server.'
        end
        if ok and notice ~= 'unavailable' then return nil end
        if ok and not DB.isHealthy() then
            -- Core.Bans could not read the ban list and core_db is down: the fallback would only wait for its own
            -- timeout — decide at once (bans.failClosed)
            Log.error('Core.Bans unavailable and the database is down for [%d]', src)
            if failClosed() then return true, 'Ban service unavailable, please try again in a minute.' end
            return nil
        end
        Log.error('Core.Bans %s for [%d], using the identifier check', ok and 'unavailable' or tostring(ban), src)
    end
    local ids = { license }
    for _, identifier in pairs(Store.collectIdentifiers(src)) do
        if identifier ~= license then ids[#ids + 1] = identifier end
    end
    local ok, ban, err = pcall(Store.activeBan, ids)
    if ok and ban then return ban, banNotice(ban) end
    if ok and ban == false then return nil end
    Log.error('the ban list cannot be read for [%d]: %s', src, tostring(ok and err or ban))
    if failClosed() then
        Log.error('refusing [%d] (bans.failClosed)', src)
        return true, 'Ban service unavailable, please try again in a minute.'
    end
    return nil
end

--------------------------------------------------------------------------------
-- writes (queued, never yield)
--------------------------------------------------------------------------------

--- 'ok' | 'retry' (core_db unavailable: keep it dirty) | 'drop' (refused: logged here). The queued call goes
--- LAST in the argument list, so both of its return values (true | false, err) arrive.
local function outcome(what, id, ok, err)
    if ok then return 'ok' end
    if DB.errorCode(err) == 'unavailable' then return 'retry' end
    Log.error('player store: the %s write of %s was refused (%s)', what, tostring(id), tostring(err))
    return 'drop'
end

local REFUSED_TYPES <const> = { ['function'] = true, userdata = true, thread = true }

--- Can `v` cross the hop and be stored as JSON? (after Utils.jsonSafe: no function/userdata/thread, string or
--- number keys, bounded depth). A value that cannot is logged and never written — it would fail its whole
--- statement (or the whole `data` map) at every save.
local function storable(v, depth)
    local kind = type(v)
    if REFUSED_TYPES[kind] then return false end
    if kind ~= 'table' then return true end
    if depth > MAX_VALUE_DEPTH then return false end
    for key, value in pairs(v) do
        local keyKind = type(key)
        if (keyKind ~= 'string' and keyKind ~= 'number') or not storable(value, depth + 1) then return false end
    end
    return true
end
Store.storable = function(v) return storable(v, 1) end

local function textDefault(column)
    if column == 'model' then return Config.Player.DefaultModel end
    if column == 'perm_group' then return 'user' end
    return ''
end

--- The column value of one session value, or nil + what the column needs.
local function columnValue(spec, value)
    local column, kind = spec[1], spec[2]
    local t = type(value)
    if kind == 'text' then
        if t == 'string' then return value end
        if t == 'number' then return tostring(value) end
        if value == nil then return textDefault(column) end
        return nil, 'a string'
    elseif kind == 'texts' then
        if value == nil then return {} end
        if t ~= 'table' then return nil, 'a list of strings' end
        local out = {}
        for i = 1, #value do
            if type(value[i]) == 'string' then out[#out + 1] = value[i] end
        end
        return out
    elseif kind == 'time' then
        if t == 'number' and value == value then return value end
        return nil, 'Unix seconds'
    elseif kind == 'count' then
        local n = t == 'number' and math.tointeger(math.floor(value)) or nil
        if not n then return nil, 'an integer' end
        return math.max(0, math.min(n, MAX_PLAYTIME))
    elseif kind == 'bool' then
        return value == true
    end
    -- json / nullable (json or NULL)
    if value == nil then
        if kind == 'nullable' then return DB.NULL end
        return {}   -- a NOT NULL column falls back to an empty aggregate
    end
    if not storable(value, 1) then return nil, 'JSON-encodable (no function, userdata or thread)' end
    return value
end

--- Dirty keys of one side → the changes map and the keys it covers. The keys are CLEARED here (before the
--- queued call, so a dbWriteFailed that marks them again during the call sticks); a bad value is logged.
local function takeChanges(dirty, doc, columns, what, id)
    local changes, keys = nil, nil
    for key in pairs(dirty) do
        dirty[key] = nil
        local spec = columns[key]
        if spec then
            local value, needs = columnValue(spec, doc[key])
            if needs then
                Log.warn('player store: %s.%s of %s must be %s — not saved', what, key, tostring(id), needs)
            else
                changes = changes or {}
                keys = keys or {}
                changes[spec[1]] = value
                keys[#keys + 1] = key
            end
        end   -- not a column: the plugin keys go through `data`
    end
    return changes, keys
end

local function remark(dirty, keys)
    for i = 1, #(keys or {}) do dirty[keys[i]] = true end
end

--- The plugin keys of a document as one map (never a column, never a reserved key). A value that cannot be
--- stored is left out (and logged) so the other plugin keys still persist.
local function pluginMap(doc, columns, reserved, what, id)
    local out = {}
    for key, value in pairs(doc) do
        if type(key) == 'string' and not columns[key] and not reserved[key] then
            if storable(value, 1) then
                out[key] = value
            else
                Log.warn('player store: %s key %s of %s is not JSON-encodable — not saved', what, key, tostring(id))
            end
        end
    end
    return out
end

-- An EMPTY Lua table crosses msgpack as [] (DESIGN §56.2.4): the map is patched (coalesced, bulk) and, only when
-- it is empty, one keyed statement turns the stored [] into {}. It changes nothing but a non-object, so whatever
-- order the queue runs it in against a later patch of the same row, the newest map wins.
local NORMALISE_DATA_SQL <const> = {
    characters = "UPDATE characters SET data = '{}'::jsonb WHERE id = $1 AND jsonb_typeof(data) <> 'object'",
    accounts = "UPDATE accounts SET data = '{}'::jsonb WHERE id = $1 AND jsonb_typeof(data) <> 'object'",
}

--- Queues one row's `data` map → ok, err (the patch's answer).
local function queueData(tbl, id, map)
    local ok, err = DB.patch(tbl, id, { data = map })
    if ok and next(map) == nil then
        ok, err = DB.enqueue(NORMALISE_DATA_SQL[tbl], { id }, ('core:%s.data:%s'):format(tbl, id))
    end
    return ok, err
end

function Store.markChar(session, key)
    if CHAR_COLUMNS[key] then
        session.dirtyChar[key] = true
    elseif not CHAR_RESERVED[key] then
        session.dirtyCharData = true
    end
end

function Store.markAccount(session, key)
    if ACCOUNT_COLUMNS[key] then
        session.dirtyAccount[key] = true
    elseif not ACCOUNT_RESERVED[key] then
        session.dirtyAccountData = true
    end
end

--- core_db dropped a queued write of this session's rows (hook dbWriteFailed, §56.3.5): mark what it carried
--- dirty again so the next save re-sends it. `tbl` = the table, `key` = the row key core_db reports.
function Store.writeFailed(session, tbl, key)
    if tbl == 'characters' then
        for name in pairs(CHAR_COLUMNS) do session.dirtyChar[name] = true end
        session.dirtyCharData = true
    elseif tbl == 'accounts' then
        for name in pairs(ACCOUNT_COLUMNS) do session.dirtyAccount[name] = true end
        session.dirtyAccountData = true
    elseif tbl == 'character_money' and type(key) == 'table' and key.account ~= nil then
        session.moneySaved[key.account] = nil
    end
end

--- The balances that differ from what was last queued → one save per row (a removed key deletes its row).
--- The saved balance is recorded BEFORE the queued call (a dbWriteFailed during it clears it again).
local function flushMoney(session)
    local money = mapOf(session.data.money)
    local saved, wrote = session.moneySaved, false
    for account, value in pairs(money) do
        local balance = type(value) == 'number' and math.tointeger(value) or nil
        if type(account) ~= 'string' or #account > MAX_MONEY_KEY or not account:find(MONEY_KEY)
            or not balance or balance < 0 then
            if saved[account] ~= false then   -- once per bad value: `false` marks "known, not stored"
                Log.warn('player store: money.%s of %s is not a whole non-negative amount — not saved',
                    tostring(account), tostring(session.charId))
                saved[account] = false
            end
        elseif saved[account] ~= balance then
            local previous = saved[account]
            saved[account] = balance
            local result = outcome('money', session.charId, DB.save('character_money', {
                character_id = session.charId, account = account, balance = balance,
            }))
            if result == 'retry' then saved[account] = previous end
            wrote = wrote or result == 'ok'
        end
    end
    for account, was in pairs(saved) do
        if money[account] == nil then
            saved[account] = nil
            if was ~= false then
                local result = outcome('money', session.charId,
                    DB.remove('character_money', { character_id = session.charId, account = account }))
                if result == 'retry' then saved[account] = was end
                wrote = wrote or result == 'ok'
            end
        end
    end
    return wrote
end

--- Queues everything dirty of `list` (sessions) in table order: characters, character_money, accounts, then
--- the `data` maps. Returns { [i] = true } for every session that wrote something.
function Store.flush(list)
    local wrote = {}
    for i = 1, #list do
        local s = list[i]
        local changes, keys = takeChanges(s.dirtyChar, s.data, CHAR_COLUMNS, 'character', s.charId)
        local playedAt = s.playedAt
        if playedAt then
            changes = changes or {}
            changes.last_played = playedAt
            s.playedAt = nil
        end
        if changes then
            local result = outcome('character', s.charId, DB.patch('characters', s.charId, changes))
            if result == 'retry' then
                remark(s.dirtyChar, keys)
                s.playedAt = s.playedAt or playedAt
            end
            wrote[i] = wrote[i] or result == 'ok'
        end
    end
    for i = 1, #list do
        if flushMoney(list[i]) then wrote[i] = true end
    end
    for i = 1, #list do
        local s = list[i]
        local changes, keys = takeChanges(s.dirtyAccount, s.account, ACCOUNT_COLUMNS, 'account', s.accountId)
        if changes then
            local result = outcome('account', s.accountId, DB.patch('accounts', s.accountId, changes))
            if result == 'retry' then remark(s.dirtyAccount, keys) end
            wrote[i] = wrote[i] or result == 'ok'
        end
    end
    for i = 1, #list do
        local s = list[i]
        if s.dirtyCharData then
            s.dirtyCharData = false
            local result = outcome('character data', s.charId, queueData('characters', s.charId,
                pluginMap(s.data, CHAR_COLUMNS, CHAR_RESERVED, 'character', s.charId)))
            if result == 'retry' then s.dirtyCharData = true end
            wrote[i] = wrote[i] or result == 'ok'
        end
        if s.dirtyAccountData then
            s.dirtyAccountData = false
            local result = outcome('account data', s.accountId, queueData('accounts', s.accountId,
                pluginMap(s.account, ACCOUNT_COLUMNS, ACCOUNT_RESERVED, 'account', s.accountId)))
            if result == 'retry' then s.dirtyAccountData = true end
            wrote[i] = wrote[i] or result == 'ok'
        end
    end
    return wrote
end

--- The latest identifier of every kind the account connected with (never ip:), one queued save per kind.
function Store.saveIdentifiers(accountId, identifiers)
    local now = os.time()
    for kind, identifier in pairs(identifiers) do
        if type(kind) == 'string' and type(identifier) == 'string' then
            outcome('identifier', accountId, DB.save('account_identifiers', {
                account_id = accountId, kind = kind, identifier = identifier, last_seen = now,
            }))
        end
    end
end

--- The dirty-tracking fields a new session starts with (money as loaded counts as saved).
function Store.initSession(session)
    session.dirtyChar, session.dirtyAccount = {}, {}
    session.dirtyCharData, session.dirtyAccountData = false, false
    session.playedAt = nil
    local saved = {}
    for account, value in pairs(mapOf(session.data.money)) do
        if type(value) == 'number' then saved[account] = math.tointeger(value) end
    end
    session.moneySaved = saved
end

-- fxlint-disable-next-line C003 -- one-shot hand-off to server/player.lua (it asserts and clears the global)
CorePlayerStore = Store
