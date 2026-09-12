--[[
    core/server/security.lua — Core.Security (DESIGN §25)

    Three things, all driven by `Config.Security`:

    1. Entity lockdown: bucket 0 is switched to `relaxed`/`strict` at start, so clients can no longer
       create (script) entities themselves. `inactive` leaves the server as the engine defaults it.
    2. `weaponDamageEvent`: the `weaponDamage` hook and the optional damage filter run first, then the
       §19 loadout check and the `Config.Security.WeaponDamage[hash]` ceiling. A failed check cancels
       the event (the damage never lands), audits it and emits `cheatDetected`.
    3. `explosionEvent`: the `explosion` hook always fires; with `BlockExplosions` the event is
       cancelled unless the sender holds `core.explosions`.

    `sender` is the server-provided source of the game event — the payload's own ids are never trusted.
    Both game events fire per bullet / per blast, so audits, hooks and kicks are throttled per src and
    per kind (AUDIT_COOLDOWN_MS); the cancel itself is never throttled.

    Natives: SetRoutingBucketEntityLockdownMode (server), CancelEvent (shared), GetGameTimer (shared).
]]

local Security = {}
Core.Security = Security

local Log = Core.Log

local damageFilter = nil    -- fn(sender, data) -> false cancels the damage
local loadoutWarned = false -- EnforceLoadout is on but server/weapons.lua is not loaded: warn once
local lastDetection = {}    -- [src] = { [kind] = GetGameTimer() of the last audited detection }

local EXPLOSION_PERM <const> = 'core.explosions'
local AUDIT_COOLDOWN_MS <const> = 5000
local LOCKDOWN_MODES <const> = { relaxed = true, strict = true }
local UNSIGNED_SPAN <const> = 0x100000000

local function config()
    return Config.Security or {}
end

-- Damage the engine attributes to a "weapon" that is never part of a stored loadout: melee and
-- unarmed, every environmental death cause, and the vehicle-mounted weapons. Without this list
-- EnforceLoadout would cancel fists, a run-over, a fall or a tank shell as if they were a cheat.
-- Read once at start from `Config.Security.ExemptWeapons` (a list of names or hashes) with this
-- default; changing the config afterwards needs a core restart.
local DEFAULT_EXEMPT <const> = {
    'WEAPON_UNARMED', 'WEAPON_KNIFE', 'WEAPON_NIGHTSTICK', 'WEAPON_HAMMER', 'WEAPON_BAT',
    'WEAPON_GOLFCLUB', 'WEAPON_CROWBAR', 'WEAPON_BOTTLE', 'WEAPON_DAGGER', 'WEAPON_HATCHET',
    'WEAPON_KNUCKLE', 'WEAPON_MACHETE', 'WEAPON_FLASHLIGHT', 'WEAPON_SWITCHBLADE', 'WEAPON_POOLCUE',
    'WEAPON_WRENCH', 'WEAPON_BATTLEAXE', 'WEAPON_STONE_HATCHET', 'WEAPON_ANIMAL', 'WEAPON_COUGAR',
    'WEAPON_FIRE', 'WEAPON_RUN_OVER_BY_VEHICLE', 'WEAPON_RAMMED_BY_VEHICLE', 'WEAPON_FALL',
    'WEAPON_EXPLOSION', 'WEAPON_HELI_CRASH', 'WEAPON_DROWNING', 'WEAPON_DROWNING_IN_VEHICLE',
    'WEAPON_BLEEDING', 'WEAPON_ELECTRIC_FENCE', 'WEAPON_EXHAUSTION', 'WEAPON_BARBED_WIRE',
    'WEAPON_HIT_BY_WATER_CANNON', 'WEAPON_PETROLCAN', 'WEAPON_FIREEXTINGUISHER', 'WEAPON_PARACHUTE',
    'WEAPON_BALL', 'WEAPON_SNOWBALL',
    'VEHICLE_WEAPON_PLAYER_LAZER', 'VEHICLE_WEAPON_TANK', 'VEHICLE_WEAPON_SPACE_ROCKET',
    'VEHICLE_WEAPON_PLANE_ROCKET', 'VEHICLE_WEAPON_PLAYER_BULLET', 'VEHICLE_WEAPON_PLAYER_BUZZARD',
    'VEHICLE_WEAPON_PLAYER_HUNTER', 'VEHICLE_WEAPON_ENEMY_LASER', 'VEHICLE_WEAPON_SEARCHLIGHT',
    'VEHICLE_WEAPON_RADAR', 'VEHICLE_WEAPON_NOSE_TURRET_VALKYRIE', 'VEHICLE_WEAPON_TURRET_VALKYRIE',
    'VEHICLE_WEAPON_TURRET_INSURGENT', 'VEHICLE_WEAPON_TURRET_TECHNICAL',
    'VEHICLE_WEAPON_TURRET_BOXVILLE', 'VEHICLE_WEAPON_TURRET_LIMO', 'VEHICLE_WEAPON_RUINER_BULLET',
    'VEHICLE_WEAPON_RUINER_ROCKET', 'VEHICLE_WEAPON_TAMPA_MISSILE',
    'VEHICLE_WEAPON_OPPRESSOR_MISSILE', 'VEHICLE_WEAPON_SUBCAR_TORPEDO',
    'VEHICLE_WEAPON_TURRET_MOGUL_DUAL', 'VEHICLE_WEAPON_DUNE_GRENADELAUNCHER',
    'VEHICLE_WEAPON_CANNON_BLAZER', 'VEHICLE_WEAPON_RCTANK_ROCKET',
}

local exempt = {}   -- [unsigned hash] = true

--- GetHashKey hands Lua a signed int, the game event an unsigned one: one key for both.
local function toUnsigned(hash)
    local n = math.floor(hash)
    if n < 0 then return n + UNSIGNED_SPAN end
    return n
end

--- Hash the exempt list once at start; entries may be weapon names or raw hashes.
local function buildExempt()
    local list = config().ExemptWeapons
    if type(list) ~= 'table' then list = DEFAULT_EXEMPT end
    for i = 1, #list do
        local entry = list[i]
        if type(entry) == 'string' and entry ~= '' then
            exempt[toUnsigned(GetHashKey(entry))] = true
        elseif type(entry) == 'number' and entry == entry then
            exempt[toUnsigned(entry)] = true
        end
    end
end

--- Hashes arrive unsigned from the game event, while `GetHashKey` / backtick literals give Lua a
--- signed int — a config table written either way has to match.
local function damageCeiling(hash)
    local table_ = config().WeaponDamage
    if type(table_) ~= 'table' or type(hash) ~= 'number' then return nil end
    local value = table_[hash]
    if type(value) == 'number' then return value end
    local alternate = hash >= 0 and (hash - UNSIGNED_SPAN) or (hash + UNSIGNED_SPAN)
    value = table_[alternate]
    return type(value) == 'number' and value or nil
end

--- True at most once per src per kind per AUDIT_COOLDOWN_MS: a cheater generates one game event per
--- bullet, and neither the console nor a webhook should see all of them.
local function allowReport(src, kind)
    if type(src) ~= 'number' or src < 1 then return false end
    local now = GetGameTimer()
    local perSrc = lastDetection[src]
    if not perSrc then
        perSrc = {}
        lastDetection[src] = perSrc
    end
    local last = perSrc[kind]
    if last and (now - last) < AUDIT_COOLDOWN_MS then return false end
    perSrc[kind] = now
    return true
end

--- Audit + `cheatDetected` + the optional kick, throttled as above. The caller has already cancelled
--- the event; this only reports it.
local function report(src, kind, details, fmt, ...)
    if not allowReport(src, kind) then return end
    Log.audit('security', src, fmt, ...)
    Core.emitHook('cheatDetected', src, kind, details)
    if config().KickOnDetect == true and Core.Player and Core.Player.kick then
        Core.Player.kick(src, 'Kicked by the anti-cheat')
    end
end

--- Install a filter that sees every `weaponDamageEvent` before core's own checks; returning `false`
--- cancels the damage. Pass nil to remove it. One filter at a time (the last one wins).
--- @return boolean accepted
function Security.setDamageFilter(fn)
    if fn == nil then
        damageFilter = nil
        return true
    end
    if not Core.Utils.isCallable(fn) then
        Log.error('Security.setDamageFilter: expected a function or nil')
        return false
    end
    damageFilter = fn
    return true
end

--- Bucket 0 lockdown, applied once when core starts (DESIGN §25).
local function applyLockdown()
    local mode = config().EntityLockdown
    if mode == nil or mode == 'inactive' then return end
    if type(mode) ~= 'string' or not LOCKDOWN_MODES[mode] then
        Log.error("security: EntityLockdown must be 'inactive', 'relaxed' or 'strict' (got %s)", tostring(mode))
        return
    end
    SetRoutingBucketEntityLockdownMode(0, mode)
    Log.info('security: routing bucket 0 entity lockdown set to %s', mode)
end

applyLockdown()
buildExempt()

-- weaponDamageEvent (OneSync, server-side, cancelable) ------------------------

-- A local game event, not a net event: it is raised by the server's own state machinery with the
-- sender's server id, so there is nothing client-supplied to authenticate here.
AddEventHandler('weaponDamageEvent', function(sender, data)
    if type(data) ~= 'table' then return end
    local src = sender
    if type(src) ~= 'number' or src < 1 then return end

    Core.emitHook('weaponDamage', src, data)

    if damageFilter then
        local ok, allowed = pcall(damageFilter, src, data)
        if not ok then
            Log.error('security: damage filter failed (%s)', tostring(allowed))
        elseif allowed == false then
            CancelEvent()
            return
        end
    end

    local cfg = config()
    local hash = data.weaponType

    -- §19: the server knows the loadout, so a carried weapon the player never got is a cheat, not a
    -- desync. Hash 0 (engine damage) and everything on the exempt list skip this check — they are
    -- never stored in a loadout — while the damage ceiling below still applies to them.
    -- hasHash is tri-state: true = owned, false = definitely not owned, nil = unknown (no session,
    -- module not ready). Only an explicit `false` cancels; nil never cancels, audits or kicks.
    if cfg.EnforceLoadout == true and type(hash) == 'number' and hash ~= 0
        and not exempt[toUnsigned(hash)] then
        if Core.Weapons and Core.Weapons.hasHash then
            local ok, owned = pcall(Core.Weapons.hasHash, src, hash)
            if not ok then
                Log.error('security: Weapons.hasHash failed (%s)', tostring(owned))
            elseif owned == false then
                CancelEvent()
                report(src, 'weapon', data, 'weapon %s not in loadout (hit %s)',
                    tostring(hash), tostring(data.hitGlobalId))
                return
            end
        elseif not loadoutWarned then
            loadoutWarned = true
            Log.warn('security: EnforceLoadout is on but Core.Weapons.hasHash is missing, not enforcing')
        end
    end

    local ceiling = damageCeiling(hash)
    if not ceiling then return end
    local multiplier = cfg.MaxWeaponDamageMultiplier
    if type(multiplier) ~= 'number' or multiplier ~= multiplier or multiplier <= 0 then multiplier = 1.0 end
    local damage = data.weaponDamage
    if type(damage) ~= 'number' or damage ~= damage then return end
    local allowedDamage = ceiling * multiplier
    if damage > allowedDamage then
        CancelEvent()
        report(src, 'damage', data, 'weapon %s damage %.1f above the allowed %.1f (type %s)',
            tostring(hash), damage, allowedDamage, tostring(data.damageType))
    end
end)

-- explosionEvent (OneSync, server-side, cancelable) --------------------------

AddEventHandler('explosionEvent', function(sender, data)
    if type(data) ~= 'table' then return end
    local src = type(sender) == 'number' and sender or tonumber(sender)

    Core.emitHook('explosion', src or sender, data)

    if config().BlockExplosions ~= true then return end
    if src and src > 0 and Core.Perms and Core.Perms.has and Core.Perms.has(src, EXPLOSION_PERM) then
        return
    end
    CancelEvent()
    -- Blocking is a server policy, not proof of cheating: audit it, but never emit cheatDetected or kick.
    if src and allowReport(src, 'explosion') then
        Log.audit('security', src, 'explosion type %s blocked at %.1f %.1f %.1f',
            tostring(data.explosionType), tonumber(data.posX) or 0.0, tonumber(data.posY) or 0.0,
            tonumber(data.posZ) or 0.0)
    end
end)

-- Per-player state, cleared when the player leaves (DESIGN §9 / rulebook §9).
AddEventHandler('playerDropped', function()
    local src = source
    if src == nil then return end
    lastDetection[src] = nil
end)
