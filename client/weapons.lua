--[[
    core / client / weapons.lua — the client half of Core.Weapons (DESIGN §19)

    The server owns the loadout; this file only mirrors it onto the ped and reports ammo back.
    `applied` is the last loadout the server sent — it is re-applied after a spawn (a model change
    clears the ped's weapons) and it is the list the ammo snapshot walks.

    Natives verified with fxref on 2026-09-12:
      PlayerPedId (client), RemoveAllPedWeapons(ped, p1) (client+server),
      GiveWeaponToPed(ped, weaponHash, ammoCount, isHidden, bForceInHand) (client+server),
      SetPedAmmo(ped, weaponHash, ammo, p3) (client form has 4 args), RemoveWeaponFromPed (client+server),
      GiveWeaponComponentToPed (client+server), SetPedWeaponTintIndex (client),
      HasPedGotWeapon(ped, weaponHash, p2) (client), GetAmmoInPedWeapon (client), GetHashKey (client+server).
]]

local Net = Core.Net
local Log = Core.Log

local SNAPSHOT_EVENT <const> = 'core:server:weaponsSnapshot'
local DEATH_EVENT <const> = 'core:server:weaponsSnapshotDeath'   -- own cooldown bucket, see below
local DEFAULT_INTERVAL_MS <const> = 60000
local MIN_INTERVAL_MS <const> = 30000   -- the server drops snapshots below its 30 s cooldown anyway
local MAX_LOADOUT <const> = 64
local MAX_AMMO <const> = 9999
local MAX_TINT <const> = 31

local applied = {}      -- [WEAPON_NAME] = { ammo, tint?, components }
local hashes = {}       -- [name] = hash, computed once
local running = false   -- snapshot thread

local function hashOf(name)
    local cached = hashes[name]
    if cached then return cached end
    local hash = GetHashKey(name)
    hashes[name] = hash
    return hash
end

local function intervalMs()
    local cfg = Config.Weapons
    local value = math.tointeger(cfg and cfg.SnapshotIntervalMs) or DEFAULT_INTERVAL_MS
    if value < MIN_INTERVAL_MS then return MIN_INTERVAL_MS end
    return value
end

--- Ammo the server sent, clamped to a sane integer.
local function entryAmmo(entry)
    local ammo = math.tointeger(entry.ammo) or 0
    if ammo < 0 then return 0 end
    if ammo > MAX_AMMO then return MAX_AMMO end
    return ammo
end

--- Puts one loadout entry on the ped: weapon, exact ammo, components, tint.
local function applyEntry(ped, weapon, entry)
    local hash = hashOf(weapon)
    local ammo = entryAmmo(entry)
    GiveWeaponToPed(ped, hash, ammo, false, false)   -- not hidden, not forced into the hand
    SetPedAmmo(ped, hash, ammo, false)               -- give only tops up; this sets the exact count

    local components = entry.components
    if type(components) == 'table' then
        for i = 1, #components do
            local component = components[i]
            if type(component) == 'string' then
                GiveWeaponComponentToPed(ped, hash, hashOf(component))
            end
        end
    end

    local tint = math.tointeger(entry.tint)
    if tint and tint >= 0 and tint <= MAX_TINT then
        SetPedWeaponTintIndex(ped, hash, tint)
    end
end

--- Distinct weapons in the cache, counted no further than `limit` (the cache holds <= MAX_LOADOUT).
local function appliedCount(limit)
    local n = 0
    for _ in pairs(applied) do
        n = n + 1
        if n >= limit then return n end
    end
    return n
end

--- Re-applies the whole cached loadout (after a spawn, or when the server pushes one).
local function applyAll()
    local ped = PlayerPedId()
    RemoveAllPedWeapons(ped, true)
    for weapon, entry in pairs(applied) do
        applyEntry(ped, weapon, entry)
    end
end

-- ---------------------------------------------------------------------------
-- Ammo snapshot (DESIGN §19): every Config.Weapons.SnapshotIntervalMs and on death.
-- The server only ever lowers a stored counter from it, so a stale or partial
-- snapshot can never hand out ammo.
-- ---------------------------------------------------------------------------

local function sendSnapshot(event)
    if next(applied) == nil then return end
    local ped = PlayerPedId()
    local snapshot, count = {}, 0

    for weapon in pairs(applied) do
        local hash = hashOf(weapon)
        if HasPedGotWeapon(ped, hash, false) and count < MAX_LOADOUT then
            count = count + 1
            snapshot[weapon] = GetAmmoInPedWeapon(ped, hash)
        end
    end

    if count == 0 then return end
    Net.emit(event or SNAPSHOT_EVENT, snapshot)
end

--- One thread, started with the first loadout and stopped when core stops.
local function startSnapshots()
    if running then return end
    running = true
    CreateThread(function()
        while running do
            Wait(intervalMs())
            -- `loaded` is written by the server (§8); no snapshot while there is no session
            if running and LocalPlayer.state.loaded == true then
                sendSnapshot()
            end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Server -> client events
-- ---------------------------------------------------------------------------

Net.on('core:client:weaponsApply', { { 'table', max = MAX_LOADOUT } }, function(loadout)
    applied = {}
    local count = 0
    for weapon, entry in pairs(loadout) do
        if type(weapon) == 'string' and type(entry) == 'table' and count < MAX_LOADOUT then
            count = count + 1
            applied[weapon] = entry
        end
    end
    applyAll()
    if next(applied) ~= nil then startSnapshots() end   -- no thread for an empty loadout
end)

Net.on('core:client:weaponGive', { 'string', 'table' }, function(weapon, entry)
    -- The server caps a loadout at MAX_LOADOUT; refusing here keeps the table the snapshot walks
    -- every minute bounded even if that cap ever changes or a give arrives for an unknown name.
    if applied[weapon] == nil and appliedCount(MAX_LOADOUT) >= MAX_LOADOUT then
        Log.warn('weaponGive: loadout cache is full (%d), ignoring %s', MAX_LOADOUT, weapon)
        return
    end
    applied[weapon] = entry
    applyEntry(PlayerPedId(), weapon, entry)
    startSnapshots()
end)

Net.on('core:client:weaponRemove', { 'string' }, function(weapon)
    applied[weapon] = nil
    RemoveWeaponFromPed(PlayerPedId(), hashOf(weapon))
end)

Net.on('core:client:weaponsClear', {}, function()
    applied = {}
    RemoveAllPedWeapons(PlayerPedId(), true)
end)

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- A spawn sets the ped model, which clears every weapon: put the cached loadout back.
-- The server also re-sends it on its own playerRespawned hook; applying twice is idempotent.
Core.on('playerLoaded', function()
    if next(applied) ~= nil then applyAll() end
end)

Core.on('playerRespawned', function()
    if next(applied) ~= nil then applyAll() end
end)

-- Death is the one moment ammo must be reported immediately (§19), so it goes to its own event:
-- the periodic one is on a 30 s server cooldown and would drop this snapshot, after which the
-- respawn `apply` would hand the unspent ammo back.
Core.on('playerDied', function()
    sendSnapshot(DEATH_EVENT)
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= Core.name then return end
    running = false
end)

-- end of file
