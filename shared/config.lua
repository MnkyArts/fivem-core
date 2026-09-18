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
        SpawnTimeoutMs = 5000, LockKey = 'U', LockDistance = 20.0, PlatePrefix = 'LS-',
        MaxPropsBytes = 16384,
    },
    Interactions = {
        Key = 'E', ScanIntervalMs = 300, FarScanIntervalMs = 1000, NearRange = 60.0, MaxModels = 8,
        -- 3D interaction dots (DESIGN §6.7): Range/OffsetZ/MaxVisible are the defaults an
        -- entry's own worldPrompt table overrides; FocusRadius is the normalized (aspect-scaled)
        -- screen distance from the reticle inside which a dot counts as looked at.
        -- Range is how far the dot is DRAWN: keep it close to the interaction radius, a dot is a
        -- "you can interact here" hint, not a map pin. Renderer: 'native' (default) draws the dot
        -- in the game's render thread; 'nui' draws the shell's CoreInteractionDot instead.
        -- Hint (only with Renderer = 'native'): 'scaleform' (default) draws the looked-at hint as ONE
        -- Scaleform movie (stream/core_hint.gfx), 'sprites' keeps the DrawSprite + HUD text hint —
        -- sprites are also the automatic fallback while the movie loads or if it never does.
        WorldPrompt = { Enabled = false, Renderer = 'native', Hint = 'scaleform', Range = 6.0, OffsetZ = 0.0,
            FocusRadius = 0.15, MaxVisible = 8 },
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
    -- Map interiors (DESIGN §36): one toggle per IPL group from client/interiors_data.lua.
    -- Missing key = the group's default; north_yankton, ufo and red_carpet default off.
    Interiors = {
        Enabled = true,
        base = true, north_yankton = false, ufo = false, red_carpet = false,
        heists = true, highlife = true, executive = true, finance = true,
        bikers = true, import = true, gunrunning = true, smuggler = true,
        doomsday = true, afterhours = true, casino = true, cayoperico = true,
        tuner = true, security = true, criminal_enterprise = true, drugwars = true,
        mercenaries = true, chopshop = true, bounties = true, agents = true,
        money_fronts = true, mansions = true, kortz = true,
    },
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
        -- Runtime UI platform (DESIGN §38). FeedIntervalMs is how often coalesced
        -- telemetry (Core.UI.feed) leaves Lua, clamped to 16-1000 ms; the request
        -- timeouts bound both directions of Core.UI.request / Core.UI.onRequest;
        -- PluginLoadTimeoutMs is how long the shell waits for a plugin's module.
        FeedIntervalMs = 50, RequestTimeoutMs = 10000, RequestMaxMs = 30000,
        PluginLoadTimeoutMs = 8000,
        -- Development only (§38.11, §38.14) — production leaves Enabled = false, and
        -- nothing below it is read then. `Servers` seeds /uidev for this session:
        -- Servers = { inventory = 'http://localhost:5173' } makes the shell import the
        -- plugin from its Vite dev server instead of its build. Log adds the shell's
        -- lifecycle lines, Inspector opens the panel /uiinspect toggles.
        Dev = { Enabled = false, Inspector = false, Log = false, Servers = {} },
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
