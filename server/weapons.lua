--[[
    core/server/weapons.lua — Core.Weapons (DESIGN §19)

    The loadout lives on the character document as
    `data.weapons = { [WEAPON_NAME] = { ammo = n, tint = n|nil, components = { 'COMPONENT_...' } } }`,
    so Core.Player saves and restores it like every other character field. The server is the only
    writer: clients get the whole loadout on playerLoaded / playerRespawned and single-weapon updates
    in between; all they may send back is an ammo snapshot, which can never raise a counter.

    Names are stored, never hashes; §25 checks weaponDamageEvent's `weaponType`, so `Weapons.hasHash`
    resolves each name's hash once with GetHashKey and compares unsigned (GetHashKey returns a signed
    32-bit integer, the event delivers the unsigned form).

    Natives (verified with fxref on 2026-09-12): GetHashKey (apiset client+server).
]]

local Weapons = {}

local Log = Core.Log
local Net = Core.Net
local Commands = Core.Commands
local Utils = Core.Utils

local MAX_AMMO <const> = 9999
local MAX_LOADOUT <const> = 64          -- weapons per character; also the snapshot schema bound
local MAX_COMPONENTS <const> = 16
local MAX_TINT <const> = 31
local MAX_NAME <const> = 64
local SNAPSHOT_COOLDOWN_MS <const> = 30000
local DEATH_COOLDOWN_MS <const> = 2000  -- the death snapshot needs its own bucket, see below
local WEAPON_PATTERN <const> = '^WEAPON_%u[%u_%d]*$'
local COMPONENT_PATTERN <const> = '^COMPONENT_%u[%u_%d]*$'
local PERM_ADMIN <const> = 'core.admin'
local UINT_MASK <const> = 0xFFFFFFFF

local hashes = {}                       -- [WEAPON_NAME] = unsigned hash, computed once
local hashSets = {}                     -- [src] = { [unsignedHash] = WEAPON_NAME }, §25's hot path

--- Config.Weapons.Allowed (array of names) when configured, nil for "any WEAPON_ name".
local function allowedSet()
    local cfg = Config.Weapons
    local list = cfg and cfg.Allowed
    if type(list) ~= 'table' then return nil end
    return list
end

--- Membership in Config.Weapons.Allowed; false when no list is configured. The list may be an
--- array of names (DESIGN §19) or a set { WEAPON_PISTOL = true } — both read the same way.
local function inAllowed(weapon)
    local allowed = allowedSet()
    if not allowed then return false end
    return allowed[weapon] == true or Utils.contains(allowed, weapon)
end

--- Structurally a weapon name (or an explicitly listed one): the check for stored data and reads.
--- Reads never depend on the allow list, so editing it never silently drops a stored loadout.
local function isWeaponName(weapon)
    if type(weapon) ~= 'string' or #weapon == 0 or #weapon > MAX_NAME then return false end
    return weapon:match(WEAPON_PATTERN) ~= nil or inAllowed(weapon)
end

--- The grant gate (give and /weapon): Config.Weapons.Allowed when set, the pattern otherwise.
local function isAllowedName(weapon)
    if type(weapon) ~= 'string' or #weapon == 0 or #weapon > MAX_NAME then return false end
    if allowedSet() then return inAllowed(weapon) end
    return weapon:match(WEAPON_PATTERN) ~= nil
end

local function isComponentName(name)
    return type(name) == 'string' and #name <= MAX_NAME and name:match(COMPONENT_PATTERN) ~= nil
end

--- Unsigned hash of a weapon name, computed once per name.
local function hashOf(weapon)
    local cached = hashes[weapon]
    if cached then return cached end
    local hash = GetHashKey(weapon) & UINT_MASK
    hashes[weapon] = hash
    return hash
end

local function clampAmmo(value)
    local ammo = math.tointeger(value) or 0
    if ammo < 0 then return 0 end
    if ammo > MAX_AMMO then return MAX_AMMO end
    return ammo
end

--- Clean component list: known COMPONENT_ names only, de-duplicated, capped.
local function cleanComponents(list, into)
    local result, seen = into or {}, {}
    for i = 1, #result do seen[result[i]] = true end
    if type(list) ~= 'table' then return result end
    for i = 1, #list do
        if #result >= MAX_COMPONENTS then break end
        local name = list[i]
        if isComponentName(name) and not seen[name] then
            seen[name] = true
            result[#result + 1] = name
        end
    end
    return result
end

--- A stored entry, repaired: integer ammo, optional integer tint, component array.
local function cleanEntry(entry)
    if type(entry) ~= 'table' then entry = {} end
    local tint = math.tointeger(entry.tint)
    if tint and (tint < 0 or tint > MAX_TINT) then tint = nil end
    return { ammo = clampAmmo(entry.ammo), tint = tint, components = cleanComponents(entry.components) }
end

--- The player's loadout as a repaired copy, or nil without a loaded session.
local function readLoadout(src)
    local player = Core.Player
    if not player or not player.isLoaded(src) then return nil end
    local stored = player.getData(src, 'weapons')
    local loadout, count = {}, 0
    if type(stored) == 'table' then
        for weapon, entry in pairs(stored) do
            if isWeaponName(weapon) and count < MAX_LOADOUT then
                count = count + 1
                loadout[weapon] = cleanEntry(entry)
            end
        end
    end
    return loadout, count
end

--- Rebuilds the hash lookup security.lua hits on every weaponDamageEvent (§25): rebuilding it from
--- the document there would deep-copy the whole loadout per shot. `nil` loadout = forget the player.
local function cacheHashes(src, loadout)
    if type(loadout) ~= 'table' then
        hashSets[src] = nil
        return nil
    end
    local set = {}
    for weapon in pairs(loadout) do set[hashOf(weapon)] = weapon end
    hashSets[src] = set
    return set
end

--- Persists the loadout, refreshes the hash cache and fires the weaponsChanged hook.
local function writeLoadout(src, loadout)
    if not Core.Player.setData(src, 'weapons', loadout) then return false end
    cacheHashes(src, loadout)
    Core.emitHook('weaponsChanged', src)
    return true
end

-- The cache is the only per-player table in this file (DESIGN §9: clear it on drop).
AddEventHandler('playerDropped', function()
    local src = source
    hashSets[src] = nil
end)

-- ---------------------------------------------------------------------------
-- API (DESIGN §19) — every entry point validates as if it came from the network
-- ---------------------------------------------------------------------------

--- Gives a weapon or tops up an owned one. opts = { tint = 0..31, components = { 'COMPONENT_...' } }.
function Weapons.give(src, weapon, ammo, opts)
    if not isAllowedName(weapon) then return false end
    if ammo == nil then ammo = 0 end
    if math.type(ammo) ~= 'integer' or ammo < 0 or ammo > MAX_AMMO then return false end

    local loadout, count = readLoadout(src)
    if not loadout then return false end
    local entry = loadout[weapon]
    if not entry then
        if count >= MAX_LOADOUT then return false end
        entry = { ammo = 0, components = {} }
        loadout[weapon] = entry
    end
    entry.ammo = clampAmmo(entry.ammo + ammo)

    if type(opts) == 'table' then
        local tint = math.tointeger(opts.tint)
        if tint and tint >= 0 and tint <= MAX_TINT then entry.tint = tint end
        entry.components = cleanComponents(opts.components, entry.components)
    end
    if not writeLoadout(src, loadout) then return false end
    Net.emit(src, 'core:client:weaponGive', weapon, entry)
    return true
end

function Weapons.remove(src, weapon)
    if not isWeaponName(weapon) then return false end
    local loadout = readLoadout(src)
    if not loadout or not loadout[weapon] then return false end
    loadout[weapon] = nil
    if not writeLoadout(src, loadout) then return false end
    Net.emit(src, 'core:client:weaponRemove', weapon)
    return true
end

function Weapons.clear(src)
    local loadout = readLoadout(src)
    if not loadout then return false end
    if not writeLoadout(src, {}) then return false end
    Net.emit(src, 'core:client:weaponsClear')
    return true
end

function Weapons.setAmmo(src, weapon, ammo)
    if not isWeaponName(weapon) then return false end
    if math.type(ammo) ~= 'integer' or ammo < 0 or ammo > MAX_AMMO then return false end
    local loadout = readLoadout(src)
    local entry = loadout and loadout[weapon]
    if not entry then return false end
    if entry.ammo == ammo then return true end
    entry.ammo = ammo
    if not writeLoadout(src, loadout) then return false end
    Net.emit(src, 'core:client:weaponGive', weapon, entry)  -- re-applies ammo, tint and components
    return true
end

function Weapons.addAmmo(src, weapon, delta)
    if not isWeaponName(weapon) then return false end
    if math.type(delta) ~= 'integer' or delta < -MAX_AMMO or delta > MAX_AMMO then return false end
    local loadout = readLoadout(src)
    local entry = loadout and loadout[weapon]
    if not entry then return false end
    return Weapons.setAmmo(src, weapon, clampAmmo(entry.ammo + delta))
end

function Weapons.has(src, weapon)
    if not isWeaponName(weapon) then return false end
    local loadout = readLoadout(src)
    return (loadout and loadout[weapon]) ~= nil
end

--- Hash form for §25 (weaponDamageEvent carries `weaponType`, not a name). Tri-state, so the
--- security checks can fail open on "unknown" instead of accusing a player:
---   nil   -- unknown: no loaded session, no cached loadout yet, or an unusable hash argument
---   false -- the loadout is known and does not contain that hash
---   true  -- owned; the second return is the weapon name
--- Reads the cache only (rebuilt by writeLoadout/apply), never the character document: this runs
--- once per weaponDamageEvent.
--- @return boolean|nil owns, string|nil weaponName
function Weapons.hasHash(src, hash)
    local set = hashSets[src]
    if not set then return nil end
    local wanted = math.tointeger(hash)
    if not wanted then return nil end
    local weapon = set[wanted & UINT_MASK]
    if weapon then return true, weapon end
    return false
end

--- The whole loadout as a copy (readLoadout builds fresh tables), nil without a session.
function Weapons.getLoadout(src)
    return (readLoadout(src))
end

--- Sends the whole loadout to the client (core:client:weaponsApply) and refreshes the hash cache;
--- this is what the playerLoaded hook runs, so §25 has a cache from the first spawn on.
function Weapons.apply(src)
    local loadout = readLoadout(src)
    if not loadout then
        cacheHashes(src, nil)
        return false
    end
    cacheHashes(src, loadout)
    Net.emit(src, 'core:client:weaponsApply', loadout)
    return true
end

-- ---------------------------------------------------------------------------
-- Client snapshot (DESIGN §19) and the spawn hooks
-- ---------------------------------------------------------------------------

local SNAPSHOT_SCHEMA <const> = { { 'table', max = MAX_LOADOUT } }

--- `{ [WEAPON_NAME] = ammo }` from the client. Only weapons already in the loadout are accepted and
--- ammo may only go down — an increase is a desync or a cheat, and real increases come from
--- Weapons.addAmmo. Shared by both snapshot events below.
local function acceptSnapshot(src, snapshot)
    local loadout = readLoadout(src)
    if not loadout then return end

    local changed = false
    for weapon, ammo in pairs(snapshot) do
        local entry = type(weapon) == 'string' and loadout[weapon] or nil
        local value = math.tointeger(ammo)
        if entry and value and value >= 0 and value < entry.ammo then
            entry.ammo = value
            changed = true
        end
    end
    if changed then writeLoadout(src, loadout) end
end

-- The periodic one, every Config.Weapons.SnapshotIntervalMs (the client clamps it to >= 30 s).
Net.on('core:server:weaponsSnapshot', SNAPSHOT_SCHEMA, acceptSnapshot,
    { cooldown = SNAPSHOT_COOLDOWN_MS, requireLoaded = true })

-- Death gets its own event and cooldown bucket: on the shared 30 s bucket a death shortly after a
-- periodic snapshot was dropped, and the `apply` on respawn then handed the unspent ammo back.
Net.on('core:server:weaponsSnapshotDeath', SNAPSHOT_SCHEMA, acceptSnapshot,
    { cooldown = DEATH_COOLDOWN_MS, requireLoaded = true })

-- The ped is fresh after a spawn and after a respawn: push the stored loadout again (§19).
Core.on('playerLoaded', function(src)
    Weapons.apply(src)
end)

Core.on('playerRespawned', function(src)
    Weapons.apply(src)
end)

-- ---------------------------------------------------------------------------
-- Admin commands (DESIGN §4.8 shape, permission core.admin)
-- ---------------------------------------------------------------------------

--- Answers the caller: notification in game, plain print on the console (src 0).
local function reply(src, message, kind)
    if src == 0 then
        print(('[core] %s'):format(message))
        return
    end
    Core.Notify.send(src, message, kind or 'info')
end

Commands.register('weapon', {
    description = 'Give a player a weapon',
    permission = PERM_ADMIN,
    allowConsole = true,
    params = {
        { name = 'target', type = 'player', help = 'server id' },
        { name = 'weapon', type = 'string', help = 'WEAPON_PISTOL' },
        { name = 'ammo', type = 'integer', help = 'rounds', optional = true },
    },
}, function(src, args)
    local weapon = args.weapon:upper()
    local ammo = args.ammo or 0
    if not isAllowedName(weapon) then
        reply(src, ('Unknown weapon %s'):format(Utils.sanitize(weapon, MAX_NAME)), 'error')
        return
    end
    if ammo < 0 or ammo > MAX_AMMO then
        reply(src, ('Ammo must be 0..%d'):format(MAX_AMMO), 'error')
        return
    end
    if not Weapons.give(args.target, weapon, ammo) then
        reply(src, 'Could not give that weapon (no loaded character or loadout full)', 'error')
        return
    end
    Log.audit('weapons', src, 'gave %s (%d ammo) to src %d', weapon, ammo, args.target)
    reply(src, ('Gave %s (%d ammo) to [%d]'):format(weapon, ammo, args.target), 'success')
end)

Commands.register('weapons', {
    description = 'Weapon loadout admin: /weapons clear <player>',
    permission = PERM_ADMIN,
    allowConsole = true,
    params = {
        { name = 'action', type = 'string', help = 'clear' },
        { name = 'target', type = 'player', help = 'server id' },
    },
}, function(src, args)
    if args.action:lower() ~= 'clear' then
        reply(src, 'Usage: /weapons clear <player>', 'error')
        return
    end
    if not Weapons.clear(args.target) then
        reply(src, 'Could not clear that loadout (no loaded character)', 'error')
        return
    end
    Log.audit('weapons', src, 'cleared the loadout of src %d', args.target)
    reply(src, ('Cleared the loadout of [%d]'):format(args.target), 'success')
end)

Core.Weapons = Weapons

-- end of file
