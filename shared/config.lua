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
        -- Seed only (DESIGN §44): on first start these become documents in the `perm_groups` collection, which is
        -- the source of truth afterwards. Lists stay cumulative for the pre-§44 code paths.
        Groups = {
            user   = {},
            helper = { 'core.helper' },
            mod    = { 'core.mod', 'core.helper' },
            admin  = { 'core.admin', 'core.mod', 'core.helper' },
            senior = { 'core.senior', 'core.admin', 'core.mod', 'core.helper' },
            owner  = { 'core.owner', 'core.senior', 'core.admin', 'core.mod', 'core.helper' },
        },
        -- rank: an actor acts on a player only with a strictly higher weight (Perms.canTarget)
        Weights = { user = 0, helper = 100, mod = 200, admin = 300, senior = 400, owner = 1000 },
        -- seed inheritance (each group inherits the one below)
        Inherits = { helper = { 'user' }, mod = { 'helper' }, admin = { 'mod' }, senior = { 'admin' }, owner = { 'senior' } },
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
        -- §55.21.4: an idle persisted car with nobody inside or within AutoParkRadius m for AutoParkIdleMs is parked
        -- (its networked clone becomes a Core.Scene node); the sweep walks the live cars every AutoParkSweepMs, in slices
        AutoPark = true, AutoParkIdleMs = 30000, AutoParkRadius = 50, AutoParkSweepMs = 10000,
        -- at most this many parked cars; beyond it the longest-unused one is stored (its node removed, hook fired)
        MaxParked = 20000,
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
        -- `hud` places the stat's bar (DESIGN §18, §39): true = a bar on the rail plate,
        -- 'health' / 'armour' = the bar cut out of that vitals plate, false = not shown at all.
        -- `icon` is a kit icon name (§39.3) for the glyph under a slotted bar.
        Defs = {
            hunger = { min = 0, max = 100, default = 100, decayPerMinute = 0.4, thresholds = { 25, 10 },
                hud = 'health', icon = 'hud-food' },
            thirst = { min = 0, max = 100, default = 100, decayPerMinute = 0.6, thresholds = { 25, 10 },
                hud = 'armour', icon = 'hud-drink' },
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
        FadeMeters = { near = 20.0, far = 90.0 },
        -- join/leave lines: 'staff' (default; a server-wide line per connect does not scale), 'all' or 'off'
        JoinLeave = 'staff' },
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
    -- The vitals HUD (DESIGN §39): the mic tile, the HEALTH and ARMOR plates and the food/drink
    -- bars cut out of them. One flag per element of the strip, plus where it sits and how big.
    Hud = {
        ShowHealth = true,    -- the HEALTH plate
        ShowArmour = true,    -- the ARMOR plate
        ShowStats = true,     -- the stat bars: slotted under a plate, or a rail bar without a slot
        ShowVoice = true,     -- the mic tile, fed from Mumble; false hands the tile to a voice
                              -- resource, which pushes Core.UI.hud.set({ talking = , muted = }) itself
        ShowSpeed = false,    -- core draws NEITHER speed nor street/zone any more: turn these on only
        ShowStreet = false,   -- for a plugin that reads useHud().speed / .street / .zone (§38.6)
        Anchor = 'bottom-left', -- 'bottom-left' (fixed 24 px from both edges) | 'minimap' (right of
                              -- the minimap rect). Those two only: the bottom centre and right are the
                              -- progress bar / text UI and the key hints / spinner, and the strip
                              -- would land on top of them
        Scale = 1.0,          -- multiplies the HUD unit (--core-hud-unit), clamped to 0.5-2.0
    },
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
    Admin = {
        CarDefaultModel = 'adder',
        -- Core.Admin dispatch (DESIGN §51)
        RequireDuty = true,
        Scope = { helper = 1, mod = 5, admin = 50, senior = 200, owner = 2000 },   -- max player targets per action run
        StaffPerm = 'core.admin.staff',
        -- core's legacy staff chat commands (/tp /bring /kick /ban /setcash …, DESIGN §4.8); false = not registered
        LegacyCommands = true,
    },
    -- Core.Buckets allocation range (DESIGN §50); charcreator's studio uses 1000 + src, below it
    Buckets = { Range = { 10000, 60000 } },
    -- Core.Maps (DESIGN §52, §55.21.1): elements stream as Core.Scene nodes, so every streaming tunable lives in
    -- Config.Scene; limits are Core.Settings keys `maps.limits.*`. MaxMarkers = the editor view's preview budget.
    Maps = { MaxMarkers = 64 },
    -- Core.Scene streaming (DESIGN §55); `Caps.props` 3000 assumes server.cfg `increase_pool_size "Object" 2000`
    Scene = {
        CellSize = 128, RegionSize = 512,                        -- read once (key encoding)
        NearRing = 160, FarRing = 448, FarRegions = 1024, LeaveMargin = 64, LeaveDwellMs = 3000,
        TierS = 160, TierM = 448, TierL = 1500,
        FlushMs = 50, MaxEventBytes = 16384, MaxBacklogBytes = 262144, LatentBps = 750000,
        PackBudgetBytes = 2000000, PackBudgetWindowMs = 10000, JournalOps = 64, JournalMs = 10000,
        Focus = { MinMove = 16, MinIntervalMs = 250, Slack = 50, MaxSpeed = 90 }, BackstopMs = 5000,
        Lead = { Seconds = 1.5, Max = 150 },
        ClientLruCells = 48, ClientLruMs = 120000, ModelLingerMs = 30000,
        -- vehicles / modelsVehicles are sized for parked player cars (§55.21.4); measure dense lots on scene_probe
        Caps = { props = 3000, peds = 48, vehicles = 64, lights = 32, particles = 32, markers = 64, texts = 64,
                 sounds = 24, hides = 200, custom = 64, modelsProps = 150, modelsPeds = 20, modelsVehicles = 32 },
        Budgets = { PropsPerFrame = 8, EntityPerFrame = 1, CustomPerFrame = 2, DeletesPerFrame = 32,
                    ModelRequestsPerFrame = 2, ModelsInFlight = 30, TeleportMultiplier = 10 },
        Radii = { Band = 20, SmallBand = 5, Margin = 10, Warm = 50, OutMin = 20, OutFactor = 0.25, PropCap = 500 },
        Fades = { PropInMs = 300, PropOutMs = 450, PedMs = 600, VehicleMs = 400, Max = 48, MaxVehicles = 8 },
        Visibility = { UnseenMs = 1500, ImportantUnseenMs = 4000, DeferMaxMs = 10000, SwapMargin = 10, SwapCooldownMs = 100 },
        Speed = { SkipSmallAbove = 50, NoFadeAbove = 80 },
        Motion = { NearRadius = 50, MidHz = 15, ServerHz = 2, RecellTolerance = 8, PlanLeadMs = 200 },
        DeadReckoning = { Near = 0.25, Far = 1.0, Degrees = 3, NearHz = 10, FarHz = 1, HeartbeatMs = 5000, Snap = 5 },
        -- ProximityShare: the part of MaxEntities proximity promotions may hold; enter / manual / action use the rest
        Promote = { MaxEntities = 1000, MaxPropsPerArea = 32, CloneWaitMs = 10000, DeleteDelayMs = 500, RestSpeed = 0.05,
                    LeaseMs = 10000, SwapDist = 0.05, SwapDeg = 2, ProximityShare = 0.7 },
        Audio = { Voices = 32, Decoders = 4, ClipCacheMb = 64, HrtfVoices = 8, ListenerHz = 20, LosProbesPerSecond = 8,
                  ProfileSfx = 300, ProfileMusic = 306,
                  -- AAC / M4A / AAC-only HLS: FiveM's CEF decodes AAC (scene_probe P8 in game, 2026-09-26: audio/aac +
                  -- mp4a.40.2 'probably' with MSE, AudioDecoder mp4a.40.2 supported)
                  AllowAac = true },
        Voice = { Submixes = 8, PanHz = 15, MaxListeners = 64, MaxSessions = 16 },
        Global = { MaxNodes = 256, MaxPerOwner = 64 }, MaxNodes = 100000, MaxNodesPerOwner = 20000, MaxPersistent = 50000,
        -- per-owner overrides of MaxNodesPerOwner: map elements, player attachments and parked vehicles all count as 'core';
        -- inventory's ground drops are one prop node each
        OwnerCaps = { core = 60000, inventory = 40000 },
        -- the share of MaxNodes / MaxPersistent only core may use, so plugins can never starve maps, attachments, parked cars
        CoreReserve = { nodes = 20000, persistent = 10000 },
        MaxChildren = 64,                                        -- descendants per root (§55.3)
        ObjectPool = 5300,       -- = this server.cfg's increase_pool_size "Object" 2000 (3300 + 2000); nil assumes 3300 and learns
        MaxFieldBytes = 8192, ClockMode = 'network', Debug = false,
    },
    Texts = {
        loading = 'Loading your character...', respawn_in = 'Respawn in %d s', respawn_now = 'Respawning...',
        locked = 'Vehicle locked', unlocked = 'Vehicle unlocked',
        no_keys = 'You have no keys for this vehicle',
        no_permission = 'You are not allowed to do that', usage = 'Usage: %s',
        insufficient = 'Not enough money',
    },
}
