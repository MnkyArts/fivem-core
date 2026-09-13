-- core/shared/config.lua — the one tunable table (DESIGN §10).
-- Coordinates are approximate and tunable; nothing else in core hard-codes a coordinate.

Config = {
    Debug = false,
    CallbackTimeoutMs = 5000,
    StreamingTimeoutMs = 10000,
    RateLimits = { CallbackPerSecond = 20 },
    Net = { DefaultCooldownMs = 250 },
    Player = {
        DefaultModel = 'mp_m_freemode_01',
        -- LSIA arrivals; first spawn of a new character
        SpawnPoint = { coords = vector3(-1037.9, -2738.0, 20.17), heading = 330.0 },
        SaveIntervalMs = 300000,
        NewCharacter = { money = { cash = 5000, bank = 25000 } },
        MaxNameLength = 32,
    },
    Respawn = {
        DelayMs = 8000,
        Points = {
            { coords = vector3(295.2, -1446.7, 29.97), heading = 230.0 },  -- Central LS Medical
            { coords = vector3(-449.4, -340.4, 34.5), heading = 80.0 },    -- Mount Zonah
            { coords = vector3(1839.6, 3672.9, 34.28), heading = 210.0 },  -- Sandy Shores
            { coords = vector3(-247.7, 6331.1, 32.43), heading = 220.0 },  -- Paleto Bay
        },
    },
    Money = { Accounts = { cash = true, bank = true }, MaxAmount = 999999999 },
    Perms = {
        Groups = {
            user  = {},
            mod   = { 'core.mod' },
            admin = { 'core.admin', 'core.mod' },
        },
    },
    Factions = {
        CreateCost = 25000, CostAccount = 'bank', MaxMembers = 30, MaxRanks = 8,
        NameMin = 3, NameMax = 32,
        TagPattern = '^[A-Z0-9][A-Z0-9]?[A-Z0-9]?[A-Z0-9]?[A-Z0-9]?$', TagMin = 2, TagMax = 5,
        DefaultColor = '#5b8cff', InviteTimeoutMs = 60000,
        DefaultRanks = {
            { name = 'Member',  perms = {} },
            { name = 'Officer', perms = { invite = true, kick = true } },
            { name = 'Leader',  perms = { invite = true, kick = true, manage_ranks = true, bank = true, manage = true } },
        },
    },
    Vehicles = {
        SpawnTimeoutMs = 5000, LockKey = 'U', LockDistance = 20.0, PlatePrefix = 'LS',
        MaxPropsBytes = 16384,
    },
    Interactions = {
        Key = 'E', ScanIntervalMs = 300, FarScanIntervalMs = 1000, NearRange = 60.0, MaxModels = 8,
    },
    World = {
        ScanIntervalMs = 500, GridSize = 100.0,
        TimeScale = 30, StartTime = { 12, 0 }, DefaultWeather = 'CLEAR', WeatherCycle = nil,
        Weathers = { 'CLEAR', 'EXTRASUNNY', 'CLOUDS', 'OVERCAST', 'RAIN', 'CLEARING', 'THUNDER', 'SMOG', 'FOGGY',
            'XMAS', 'SNOW', 'SNOWLIGHT', 'BLIZZARD', 'HALLOWEEN' },
    },
    Locale = 'en',
    Stats = {
        Enabled = true, TickMs = 60000,
        Defs = {
            hunger = { min = 0, max = 100, default = 100, decayPerMinute = 0.4, thresholds = { 25, 10 }, hud = true },
            thirst = { min = 0, max = 100, default = 100, decayPerMinute = 0.6, thresholds = { 25, 10 }, hud = true },
        },
    },
    Weapons = { Allowed = nil, SnapshotIntervalMs = 60000 },
    Native = {   -- Core.Native.invoke allow-list (nil = DENY everything). Dangerous natives are always refused.
        Allow = {
            'SetEntityHealth', 'SetPedArmour', 'SetEntityCoords', 'SetEntityCoordsNoOffset', 'SetEntityHeading',
            'FreezeEntityPosition', 'SetEntityInvincible', 'SetEntityVisible', 'SetEntityAlpha', 'ClearPedTasks',
            'ClearPedTasksImmediately', 'TaskPlayAnim', 'StopAnimTask', 'SetPedCanRagdoll', 'SetPedToRagdoll',
            'SetPedComponentVariation', 'SetPedPropIndex', 'ClearPedProp', 'SetPedDefaultComponentVariation',
            'SetPedMovementClipset', 'ResetPedMovementClipset', 'SetVehicleEngineOn', 'SetVehicleDoorsLocked',
            'SetVehicleFixed', 'SetVehicleDirtLevel', 'SetVehicleFuelLevel', 'SetVehicleDoorOpen', 'SetVehicleDoorShut',
            'SetEntityMaxSpeed', 'SetVehicleMaxSpeed', 'PlaySoundFrontend', 'DoScreenFadeIn', 'DoScreenFadeOut',
            'DisplayRadar', 'DisplayHud', 'SetTimecycleModifier', 'ClearTimecycleModifier', 'ClearPlayerWantedLevel',
            'SetPlayerWantedLevel', 'SetPlayerWantedLevelNow', 'GetEntityHealth', 'GetEntityCoords', 'GetEntityHeading',
            'GetPedArmour', 'GetVehiclePedIsIn', 'IsPedInAnyVehicle', 'GetEntityModel', 'GetEntitySpeed', 'IsEntityDead',
            'GetPlayerWantedLevel', 'GetEntityVelocity', 'GetStreetNameAtCoord', 'GetNameOfZone', 'IsPedArmed',
        },
    },
    Chat = { Mode = 'proximity', ProximityRange = 20.0, MaxLength = 200, CooldownMs = 800,
        -- Format = '{tag}{name}: {msg}', -- optional custom format; nil keeps structured name/message styling
        ScreamRange = 60.0, ScreamCommand = 's', History = 80, HideDelayMs = 8000, VisibleLines = 8,
        FadeMeters = { near = 20.0, far = 90.0 } },
    Security = { EntityLockdown = 'inactive', EnforceLoadout = true, BlockExplosions = false, MaxWeaponDamageMultiplier = 1.0,
        WeaponDamage = {}, KickOnDetect = false, ExemptWeapons = nil },   -- ExemptWeapons nil = the built-in melee/vehicle/environment list
    Http = { AllowPrivate = false, AllowHosts = nil },
    Doors = { InteractDistance = 2.0 },
    Hud = { ShowHealth = true, ShowArmour = true, ShowStats = true, ShowSpeed = true, ShowStreet = true },
    -- GTA's idle cameras (DESIGN §35): the AFK pan after 30 s without input, the passenger pan and the
    -- cinematic vehicle idle mode. They trip the §31 cinematic watcher (the shell hides, an open page
    -- closes), so core switches them off. `false` keeps the game's behaviour.
    Camera = { DisableIdleCam = true },

    UI = {
        NotifyDurationMs = 5000, MaxNotifyPerSecond = 10, HudEnabled = true,
        ModalTimeoutMs = 300000, CancelKey = 'X',
        -- Auto-hide of the whole NUI shell while the game draws over it (DESIGN §31.3).
        -- One 200 ms thread reads only the enabled watchers; HudHidden is off by default
        -- because IsHudHidden's semantics are undocumented and a wrong reading would hide
        -- the shell for good.
        AutoHide = {
            IntervalMs = 200,
            PauseMenu = true, ScreenFade = true, PlayerSwitch = true,
            Warning = true, HudHidden = false, Cinematic = true,
        },
        -- Live game blur behind every `data-core-blur` panel (DESIGN §32). The shell
        -- copies the game frame into a small canvas at `Fps` and CSS-blurs it: Strength
        -- is the blur radius in CSS px, Scale the copy resolution (0.1-1, lower = cheaper).
        Blur = { Enabled = true, Strength = 4, Fps = 30, Scale = 0.5 },
    },
    -- Adapter: 'kvp' (no setup) | 'mysql' (oxmysql, untested) | 'postgres' (needs the core_pg_url convar)
    DB = { KeyPrefix = 'doc:', FlushIntervalMs = 5000, Adapter = 'postgres' },
    Admin = { CarDefaultModel = 'adder' },
    Texts = {
        loading = 'Loading your character...', respawn_in = 'Respawn in %d s', respawn_now = 'Respawning...',
        locked = 'Vehicle locked', unlocked = 'Vehicle unlocked',
        no_keys = 'You have no keys for this vehicle',
        no_permission = 'You are not allowed to do that', usage = 'Usage: %s',
        insufficient = 'Not enough money',
    },
}
