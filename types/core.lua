---@meta
--- core/types/core.lua — LuaLS (sumneko) definitions for the `core` framework (DESIGN §27).
---
--- This file is DOCUMENTATION ONLY: it is never loaded at runtime and must NOT be listed in
--- fxmanifest.lua. Editors pick it up through `resources/.luarc.json`
--- (`workspace.library = ["core/types"]`), which makes `Core.*` autocomplete in every plugin.
---
--- Functions are marked `(server)` / `(client)` in their description; an unmarked function
--- exists on both sides. Everything except the libs (Utils, Math, Validate, Log, Callback,
--- Net, Commands, Keys, Streaming, Anim, Player, UI, Locale, Audio) is reached through the
--- export proxy of DESIGN §2.2, so it must be called from a coroutine (thread, event handler,
--- command) and after `Core.onReady`.

--------------------------------------------------------------------------------
-- Enums and aliases
--------------------------------------------------------------------------------

---Hook names used with `Core.on(hook, fn)` / `Core.emitHook(hook, ...)` (DESIGN §8).
---@alias CoreHook
---| '"ready"'              # core started on this side — server: () / client: ()
---| '"playerLoaded"'       # session ready — server: (src) / client: () after the first spawn
---| '"playerDropped"'      # (server) (src, charId), fired before the session is removed
---| '"playerSaved"'        # (server) (src) after the character document was written
---| '"playerDied"'         # server: (src) / client: ()
---| '"playerRespawned"'    # server: (src) / client: ()
---| '"playerDataChanged"'  # (server) (src, topKey, value) — emitted by Core.Player.setData
---| '"moneyChanged"'       # (server) (src, account, amount, delta, reason)
---| '"factionChanged"'     # (server) (src, summary|nil) — membership or rank of an online member
---| '"factionUpdated"'     # (server) (factionId) — name/tag/colour/roster of a faction
---| '"vehicleSpawned"'     # (server) (netId, info)
---| '"vehicleDeleted"'     # (server) (netId)
---| '"audit"'              # (server) (category, src, message) — from Core.Log.audit
---| '"doorLocked"'         # (server) (doorId, src|nil)
---| '"doorUnlocked"'       # (server) (doorId, src|nil)
---| '"timeChanged"'        # (server) (hour, minute)
---| '"weatherChanged"'     # (server) (weatherType)
---| '"statChanged"'        # (server) (src, name, value) — set/add/sub only, never decay
---| '"statThreshold"'      # (server) (src, name, threshold, value) — crossed downwards
---| '"weaponsChanged"'     # (server) (src)
---| '"weaponDamage"'       # (server) (sender, data) — before core's own security checks
---| '"explosion"'          # (server) (sender, data)
---| '"cheatDetected"'      # (server) (src, kind, details)
---| '"chatMessage"'        # (server) (src, channel, message)
---| '"uiReady"'            # (client) () — the NUI shell (re)loaded and re-registered its pages
---| '"uiVisibility"'       # (client) (visible, reasons) — the shell was hidden or shown again (§31)

---@alias CoreNotifyType '"info"' | '"success"' | '"error"' | '"warning"'
---@alias CorePageType '"page"' | '"overlay"'
---@alias CoreAutoHideWatcher '"pause"' | '"fade"' | '"switch"' | '"warning"' | '"hud"' | '"cinematic"'
---@alias CoreShardStyle '"wasted"' | '"success"' | '"info"'
---@alias CoreInputFieldType '"text"' | '"number"' | '"select"' | '"checkbox"'
---@alias CoreMoneyAccount '"cash"' | '"bank"' | string
---@alias CorePermScope '"account"' | '"character"'
---@alias CoreDBImportMode '"merge"' | '"replace"'
---@alias CoreFactionPerm '"invite"' | '"kick"' | '"manage_ranks"' | '"bank"' | '"manage"'
---@alias CoreCommandParamType '"string"' | '"integer"' | '"number"' | '"player"' | '"rest"' | '"boolean"'
---@alias CoreWorldKind '"marker"' | '"label"' | '"blip"' | '"interaction"'
---@alias CoreRegistryKind '"marker"' | '"label"' | '"blip"' | '"interaction"' | '"page"' | '"vehicle"' | '"world"'

---Weather names accepted by `Core.World.setWeather` (`Config.World.Weathers`).
---@alias CoreWeather
---| '"CLEAR"' | '"EXTRASUNNY"' | '"CLOUDS"' | '"OVERCAST"' | '"RAIN"' | '"CLEARING"' | '"THUNDER"'
---| '"SMOG"' | '"FOGGY"' | '"XMAS"' | '"SNOW"' | '"SNOWLIGHT"' | '"BLIZZARD"' | '"HALLOWEEN"'

---A `Core.Validate` spec: a type name (a trailing `?` also accepts nil) or a table form
---such as `{ 'integer', min = 1, max = 100 }`, `{ 'enum', 'cash', 'bank' }`,
---`{ 'array', of = spec, max = 50 }`, `{ 'table', keys = { name = spec }, max = 64 }`.
---@alias CoreSpec
---| '"integer"' | '"number"' | '"string"' | '"boolean"' | '"table"' | '"function"' | '"any"'
---| '"vector3"' | '"netId"' | '"src"' | '"id"'
---| string
---| table

---An argument schema: one spec, or an array of specs matched against positional arguments.
---@alias CoreSchema CoreSpec|CoreSpec[]

---RGBA colour as a 4-element array `{ r, g, b, a }` (0..255).
---@alias CoreColor number[]

--------------------------------------------------------------------------------
-- Option tables — world objects (DESIGN §6.4–§6.7, §15, §16)
--------------------------------------------------------------------------------

---@class CoreMarkerOptions
---@field coords vector3 required world position
---@field type? integer marker type (default 1)
---@field size? vector3|number scale; a number is used for all three axes (default 1.0)
---@field color? CoreColor { r, g, b, a } (default { 0, 150, 255, 120 })
---@field drawDistance? number metres the marker is drawn from (default 30.0)
---@field bobUpAndDown? boolean default false
---@field faceCamera? boolean default false
---@field rotate? boolean default false
---@field offsetZ? number added to coords.z before drawing (default 0.0)

---@class CoreTextLabelOptions
---@field coords vector3 required world position
---@field text string required label text
---@field drawDistance? number default 15.0
---@field scale? number default 0.35
---@field font? integer default 4
---@field color? CoreColor default { 255, 255, 255, 215 }

---@class CoreBlipOptions
---@field coords? vector3 point blip position
---@field radius? { coords: vector3, radius: number } radius blip instead of a point blip
---@field entity? integer attach the blip to a local entity handle (client only)
---@field netId? integer attach the blip to a networked entity (client only)
---@field sprite? integer blip sprite id (default 1)
---@field color? integer blip colour id (default 0)
---@field scale? number default 0.8
---@field label? string name shown on the map (default 'Blip')
---@field shortRange? boolean hide until the player is close (default true)
---@field alpha? integer 0..255 (default 255)
---@field display? integer blip display mode (default 4)
---@field category? integer legend category
---@field route? boolean draw a GPS route to the blip (default false)
---@field routeColor? integer route colour id; falls back to `color`

---The context passed to interaction callbacks and returned by `Core.Interactions.getActive`.
---@class CoreInteractionContext
---@field id string the interaction id
---@field coords vector3 the interaction's current world position
---@field entity integer entity handle when the interaction follows one, else 0
---@field distance number metres between the player's ped and the interaction
---@field data any the `data` value given to `Core.Interactions.add`

---@class CoreInteractionOptions
---@field coords? vector3 fixed position (one of coords/entity/netId/models is required)
---@field entity? integer follow a local entity handle (client only)
---@field netId? integer follow a networked entity (client only)
---@field models? string[] follow the closest object of these models (client only, ≤ Config.Interactions.MaxModels)
---@field radius? number activation radius in metres (default 2.0)
---@field label? string prompt text shown in the text UI (default 'Interact')
---@field key? string key shown in the prompt — display only (default 'E')
---@field marker? CoreMarkerOptions auto-created marker that follows the interaction
---@field onInteract? fun(ctx: CoreInteractionContext) client form; server form is fun(src, ctx)
---@field onEnter? fun(ctx: CoreInteractionContext) client form; server form is fun(src, ctx)
---@field onExit? fun(ctx: CoreInteractionContext) client form; server form is fun(src, ctx)
---@field canInteract? fun(ctx: CoreInteractionContext): boolean server form is fun(src): boolean
---@field enabled? boolean default true
---@field cooldown? number ms between two triggers (default 500)
---@field data any arbitrary payload handed back in the context

---@class CoreDoorOptions
---@field id string unique door id (1..64 chars of [%w_%-:])
---@field model string|integer door model name or hash
---@field coords vector3 the door's world position
---@field locked? boolean initial state; a persisted state wins (default true)
---@field perms? string[] ace/group perms or 'faction:<id>' / 'faction:<id>:<minRank>' entries
---@field autoLockMs? number re-lock automatically after this many ms (0 = never)
---@field meta? table plugin scratch space stored with the door

--------------------------------------------------------------------------------
-- Option tables — UI (DESIGN §6.10, §21)
--------------------------------------------------------------------------------

---@class CorePageOptions
---@field type? CorePageType 'page' is exclusive and takes focus, 'overlay' does not (default 'page')
---@field keepInput? boolean keep game input alive while the page is focused (default false)
---@field script? string fallback bundle path inside the CALLING resource
---@field style? string fallback stylesheet path inside the CALLING resource

---@class CoreNotifyOptions
---@field message string required text
---@field type? CoreNotifyType default 'info'
---@field duration? integer ms on screen (default Config.UI.NotifyDurationMs)
---@field title? string optional heading

---@class CoreTextUIOptions
---@field position? string 'bottom' (default) — where the prompt pill is anchored

---@class CoreProgressOptions
---@field label? string text shown next to the bar
---@field duration integer required length in ms
---@field canCancel? boolean allow the cancel key to abort it (default false)

---@class CoreMenuItem
---@field label string row text
---@field description? string second line
---@field icon? string icon name understood by the shell
---@field value any returned by `Core.UI.menu.open` when the row is picked
---@field disabled? boolean greyed out and not selectable

---@class CoreMenuOptions
---@field title string menu heading
---@field items CoreMenuItem[] rows, in display order

---@class CoreInputField
---@field name string key of the value in the returned table
---@field label string field label
---@field type? CoreInputFieldType default 'text'
---@field options? string[] choices for `type = 'select'`
---@field default? any pre-filled value
---@field required? boolean block submit while empty
---@field min? number minimum for `type = 'number'`
---@field max? number maximum for `type = 'number'`
---@field placeholder? string

---@class CoreInputOptions
---@field title string dialog heading
---@field fields CoreInputField[] the fields to ask for
---@field submit? string submit button text (default 'OK')
---@field cancel? string cancel button text (default 'Cancel')

---@class CoreAlertOptions
---@field title string dialog heading
---@field message string body text
---@field confirm? string confirm button text (default 'OK')
---@field cancel? string|false cancel button text, or false for a single-button alert

---@class CoreKeyHint
---@field key string the key cap text, e.g. 'E'
---@field label string what the key does

---@class CoreShardOptions
---@field title string big line
---@field subtitle? string small line
---@field duration? integer ms on screen (default 4000, clamped to 500..60000)
---@field style? CoreShardStyle default 'info'

---@class CoreHudPartial
---@field visible? boolean
---@field cash? integer
---@field bank? integer
---@field name? string
---@field serverId? integer
---@field health? integer
---@field armour? integer
---@field speed? number km/h
---@field street? string
---@field zone? string
---@field faction? table|false { name, tag, color } or false when in no faction

--------------------------------------------------------------------------------
-- Option tables — players, vehicles, services
--------------------------------------------------------------------------------

---@class CoreAppearance
---@field components? table<integer, { drawable: integer, texture: integer, palette: integer? }>
---@field props? table<integer, { drawable: integer, texture: integer }|false>
---@field headBlend? table head blend data as GTA expects it

---@class CoreSpawnOptions
---@field coords vector3 where the ped ends up
---@field heading? number default 0.0
---@field model? string|integer ped model (default Config.Player.DefaultModel)
---@field appearance? CoreAppearance applied after the model switch
---@field fade? boolean fade the screen around the spawn (default true)
---@field resurrect? boolean NetworkResurrectLocalPlayer first (default true)

---@class CoreAnimOptions
---@field flags? integer animation flags (default 1)
---@field duration? integer ms, -1 = until stopped (default -1)
---@field blendIn? number default 8.0
---@field blendOut? number default -8.0
---@field playbackRate? number default 0.0
---@field lockX? boolean
---@field lockY? boolean
---@field lockZ? boolean

---@class CorePlayerInfo
---@field src integer
---@field charId string
---@field accountId string
---@field name string
---@field group string
---@field license string

---@class CoreVehicleSpawnOptions
---@field model string|integer vehicle model name or hash
---@field coords vector3 spawn position
---@field heading? number default 0.0
---@field type? string CreateVehicleServerSetter type (default 'automobile')
---@field plate? string 1..8 chars of [%w ]; generated from Config.Vehicles.PlatePrefix otherwise
---@field ownerSrc? integer player the props are applied on
---@field ownerCharId? string character that owns the vehicle
---@field keys? string[] charIds that may unlock it
---@field props? CoreVehicleProps appearance/condition applied through ownerSrc's client
---@field locked? boolean default false
---@field persistent? boolean keep the entity alive without a nearby owner (default false)
---@field bucket? integer routing bucket for the entity

---@class CoreVehicleInfo
---@field netId integer
---@field model integer|string
---@field plate string
---@field ownerCharId string|nil
---@field keys table<string, boolean>
---@field locked boolean
---@field vehId string|nil persistence record id, when the vehicle was persisted
---@field spawnedBy string resource that called Core.Vehicles.spawn
---@field createdAt integer os.time() of the spawn

---@class CoreVehicleRecord
---@field id string vehId
---@field ownerCharId string
---@field model string|integer
---@field plate string
---@field props CoreVehicleProps
---@field stored boolean true while the vehicle sits in a garage
---@field position { x: number, y: number, z: number, heading: number }
---@field meta table plugin scratch space (Core.Vehicles.setData/getData)

---JSON-safe vehicle appearance and condition (DESIGN §6.8). Every key is optional.
---@class CoreVehicleProps
---@field model? integer
---@field plate? string
---@field plateIndex? integer
---@field colorPrimary? integer
---@field colorSecondary? integer
---@field customPrimary? number[]|false { r, g, b }
---@field customSecondary? number[]|false
---@field pearlescentColor? integer
---@field wheelColor? integer
---@field interiorColor? integer
---@field dashboardColor? integer
---@field wheels? integer
---@field windowTint? integer
---@field livery? integer
---@field livery2? integer
---@field xenonColor? integer
---@field neonEnabled? boolean[]
---@field neonColor? number[] { r, g, b }
---@field tyreSmokeColor? number[]
---@field extras? table<integer, boolean>
---@field mods? table<integer, integer> mod type 0..49 → index
---@field modToggles? table<integer, boolean> mod types 17, 18, 19, 20, 22
---@field modVariations? table<integer, boolean>
---@field engineHealth? number
---@field bodyHealth? number
---@field tankHealth? number
---@field fuelLevel? number
---@field dirtLevel? number
---@field burstTyres? table<integer, boolean>

---@class CoreAttachmentDef
---@field id string unique per player; re-adding the same id replaces the entry
---@field model string|integer prop model
---@field bone string|integer bone name or index the prop hangs on
---@field offset? vector3 position offset from the bone
---@field rotation? vector3 rotation offset in degrees

---@class CoreWeaponOptions
---@field tint? integer 0..31
---@field components? string[] 'COMPONENT_...' names

---@class CoreStatDef
---@field min? number floor (default 0)
---@field max? number ceiling (default 100)
---@field default? number value a fresh character starts at
---@field decayPerMinute? number subtracted every Config.Stats.TickMs
---@field thresholds? number[] values that fire `statThreshold` when crossed downwards
---@field hud? boolean draw a bar in core's HUD

---@class CoreFactionSummary
---@field id string
---@field name string
---@field tag string
---@field color string '#RRGGBB'
---@field rank integer 1 = lowest
---@field rankName string
---@field perms table<CoreFactionPerm, boolean>
---@field isOwner boolean

---@class CoreFactionMember
---@field charId string
---@field name string
---@field rank integer
---@field rankName string
---@field online integer|false server id while the member is connected

---@class CoreFactionListEntry
---@field id string
---@field name string
---@field tag string
---@field color string
---@field memberCount integer

---@class CoreHttpOptions
---@field method? string default 'GET'
---@field body? table|string tables are json-encoded
---@field headers? table<string, string>
---@field timeoutMs? integer default 10000

---@class CoreHttpRequest
---@field method string
---@field path string
---@field query table<string, string>
---@field headers table<string, string>
---@field body string

---@class CoreWebhookEmbed
---@field title? string
---@field description? string
---@field color? integer decimal Discord colour
---@field fields? table[] { { name = '...', value = '...', inline = bool }, ... }

---@class CoreChatOptions
---@field color? number[] { r, g, b }
---@field prefix? string shown in front of the message
---@field multiline? boolean

---@class CoreChatChannel
---@field command string the slash command that writes into the channel
---@field permission? string perm required to use it
---@field format? string e.g. '(OOC) {name}: {msg}'
---@field global? boolean false routes the message by proximity (default true)
---@field staffOnly? boolean only deliver to holders of `permission`

---@class CoreCronEntry
---@field id string
---@field kind string 'every' | 'at' | 'schedule'
---@field owner string resource that created the job
---@field runs integer how often it fired
---@field lastRun integer|nil os.time() of the last run
---@field interval integer|nil ms, for `Core.Cron.every`
---@field expr string|nil cron expression, for `Core.Cron.schedule`

---A storage backend for `Core.DB.setAdapter` (DESIGN §4.1).
---@class CoreDBAdapter
---@field loadAll fun(collection: string): table<string, string> id → json string
---@field put fun(collection: string, id: string, json: string)
---@field remove fun(collection: string, id: string)
---@field flush fun()

--------------------------------------------------------------------------------
-- Option tables — commands, keys, net (DESIGN §3.6–§3.8)
--------------------------------------------------------------------------------

---@class CoreCommandParam
---@field name string key of the parsed value in the handler's `args`
---@field type? CoreCommandParamType default 'string'; 'rest' must be the last param
---@field help? string shown in the usage line
---@field optional? boolean

---@class CoreCommandOptions
---@field description? string chat suggestion text
---@field params? CoreCommandParam[] typed parameters, in order
---@field permission? string checked with Core.Perms.has (console always passes)
---@field allowConsole? boolean allow src 0 to run it (default true)

---@class CoreKeyBindOptions
---@field name string single word; the binding becomes '+<resource>_<name>'
---@field description string text shown in the GTA key-binding menu
---@field key? string default key, e.g. 'F5'
---@field mapper? string default 'keyboard'
---@field onPress fun() required
---@field onRelease? fun()
---@field debounce? number ms between two presses (default 250)
---@field whileFocused? boolean also fire while NUI has focus / the pause menu is open

---@class CoreNetOptions
---@field cooldown? number ms per src, 0 disables (default Config.Net.DefaultCooldownMs)
---@field requireLoaded? boolean the sender must have a loaded session (default true)
---@field permission? string ace/group permission the sender must hold
---@field distance? { coords: vector3|fun(src: integer, ...): vector3|nil, max: number }
---@field onReject? fun(src: integer, reason: string) default: Core.Log.debug

--------------------------------------------------------------------------------
-- Core.Config — core's own shared/config.lua, available in every VM (DESIGN §2.0, §10, §28)
--------------------------------------------------------------------------------

---@class CoreConfig
---@field Debug boolean
---@field CallbackTimeoutMs integer
---@field StreamingTimeoutMs integer
---@field RateLimits { CallbackPerSecond: integer }
---@field Net { DefaultCooldownMs: integer }
---@field Player table DefaultModel, SpawnPoint, SaveIntervalMs, NewCharacter, MaxNameLength
---@field Respawn { DelayMs: integer, Points: table[] }
---@field Money { Accounts: table<string, boolean>, MaxAmount: integer }
---@field Perms { Groups: table<string, string[]> }
---@field Factions table CreateCost, CostAccount, MaxMembers, MaxRanks, DefaultRanks, …
---@field Vehicles table SpawnTimeoutMs, LockKey, LockDistance, PlatePrefix, MaxPropsBytes
---@field Interactions table Key, ScanIntervalMs, FarScanIntervalMs, NearRange, MaxModels
---@field World table ScanIntervalMs, GridSize, TimeScale, StartTime, Weathers, WeatherCycle
---@field Locale string default language for Core.Locale
---@field Stats { Enabled: boolean, TickMs: integer, Defs: table<string, CoreStatDef> }
---@field Weapons { Allowed: string[]|nil, SnapshotIntervalMs: integer }
---@field Native { Allow: string[]|nil }
---@field Chat table Mode, ProximityRange, MaxLength, CooldownMs, Format
---@field Security table EntityLockdown, EnforceLoadout, BlockExplosions, WeaponDamage, …
---@field Doors { InteractDistance: number }
---@field Hud table ShowHealth, ShowArmour, ShowStats, ShowSpeed, ShowStreet
---@field UI table NotifyDurationMs, MaxNotifyPerSecond, HudEnabled, ModalTimeoutMs, CancelKey
---@field DB { KeyPrefix: string, FlushIntervalMs: integer, Adapter: string }
---@field Admin { CarDefaultModel: string }
---@field Texts table<string, string>

--------------------------------------------------------------------------------
-- Core (import.lua)
--------------------------------------------------------------------------------

---The framework table. `@core/import.lua` creates it in every VM that includes it.
---@class Core
---@field name string the including resource's own name (GetCurrentResourceName)
---@field isServer boolean true inside a server VM
---@field isClient boolean true inside a client VM
---@field isCore boolean true only inside core's own VMs
---@field version string core's version, e.g. '1.0.0'
---@field Config CoreConfig core's shared config, resolved lazily in every VM
Core = {}

---Subscribes to a core hook on this side (`AddEventHandler('core:hook:<hook>', fn)`).
---The overloads below type the handler for the hooks plugins use most.
---@param hook CoreHook
---@param fn function
---@return any handler the event handler cookie, or nil on bad arguments
---@overload fun(hook: '"ready"', fn: fun()): any
---@overload fun(hook: '"playerLoaded"', fn: fun(src: integer)): any
---@overload fun(hook: '"playerDropped"', fn: fun(src: integer, charId: string)): any
---@overload fun(hook: '"playerSaved"', fn: fun(src: integer)): any
---@overload fun(hook: '"playerDied"', fn: fun(src: integer)): any
---@overload fun(hook: '"playerRespawned"', fn: fun(src: integer)): any
---@overload fun(hook: '"playerDataChanged"', fn: fun(src: integer, topKey: string, value: any)): any
---@overload fun(hook: '"moneyChanged"', fn: fun(src: integer, account: string, amount: integer, delta: integer, reason: string)): any
---@overload fun(hook: '"factionChanged"', fn: fun(src: integer, summary: CoreFactionSummary|nil)): any
---@overload fun(hook: '"factionUpdated"', fn: fun(factionId: string)): any
---@overload fun(hook: '"vehicleSpawned"', fn: fun(netId: integer, info: CoreVehicleInfo)): any
---@overload fun(hook: '"vehicleDeleted"', fn: fun(netId: integer)): any
---@overload fun(hook: '"audit"', fn: fun(category: string, src: integer, message: string)): any
---@overload fun(hook: '"statChanged"', fn: fun(src: integer, name: string, value: number)): any
---@overload fun(hook: '"statThreshold"', fn: fun(src: integer, name: string, threshold: number, value: number)): any
---@overload fun(hook: '"timeChanged"', fn: fun(hour: integer, minute: integer)): any
---@overload fun(hook: '"weatherChanged"', fn: fun(weatherType: CoreWeather)): any
---@overload fun(hook: '"doorLocked"', fn: fun(id: string, src: integer|nil)): any
---@overload fun(hook: '"doorUnlocked"', fn: fun(id: string, src: integer|nil)): any
---@overload fun(hook: '"weaponsChanged"', fn: fun(src: integer)): any
---@overload fun(hook: '"cheatDetected"', fn: fun(src: integer, kind: string, details: table)): any
---@overload fun(hook: '"chatMessage"', fn: fun(src: integer, channel: string, message: string)): any
---@overload fun(hook: '"uiReady"', fn: fun()): any
---@overload fun(hook: '"uiVisibility"', fn: fun(visible: boolean, reasons: string[])): any
function Core.on(hook, fn) end

---Fires a hook on this side (`TriggerEvent('core:hook:<hook>', ...)`). Plugins may emit their own.
---@param hook CoreHook|string
---@param ... any
function Core.emitHook(hook, ...) end

---True while the `core` resource is started.
---@return boolean
function Core.isReady() end

---Runs `fn` once core is started, and again after every core restart. Registration calls into
---core (markers, interactions, blips, labels, pages, server hooks) belong in here.
---@param fn fun()
function Core.onReady(fn) end

---(client) Runs `fn` now when the local player is already loaded, and on every `playerLoaded`
---hook afterwards. (server) The plain `playerLoaded` hook, handed `src`.
---@param fn fun(src?: integer)
---@return any handler
function Core.onPlayerLoaded(fn) end

---(server) `Core.Player(src)` sugar: `handle:addMoney(...)` == `Core.Player.addMoney(src, ...)`,
---`handle.money:add('cash', 10)` == `Core.Money.add(src, 'cash', 10)`.
---@class CorePlayerHandle
---@field src integer the player this handle wraps
---@field money table every `Core.Money.*` function, with `src` bound

--------------------------------------------------------------------------------
-- Core.Utils (lib/utils/shared.lua, DESIGN §3.1) — pure, runs in the caller's VM
--------------------------------------------------------------------------------

---@class Core.Utils
Core.Utils = {}

---@param v any
---@return boolean true when `v` is a Lua integer
function Core.Utils.isInteger(v) end
---Finite number (rejects NaN and ±inf).
---@param v any
---@return boolean
function Core.Utils.isNumber(v) end
---Non-empty string, optionally no longer than `maxLen`.
---@param v any
---@param maxLen? integer
---@return boolean
function Core.Utils.isString(v, maxLen) end
---@param v any
---@return boolean
function Core.Utils.isBool(v) end
---@param v any
---@return boolean
function Core.Utils.isTable(v) end
---@param v any
---@return boolean
function Core.Utils.isVector3(v) end
---@param v any
---@return boolean
function Core.Utils.isFunction(v) end
---Whether `v` is a function OR a callable table (a cross-resource function reference is a table with `__call`).
---Use this for every plugin-supplied callback instead of `type(v) == 'function'`.
---@param v any
---@return boolean
function Core.Utils.isCallable(v) end

---@param n number
---@param lo number
---@param hi number
---@return number clamped
function Core.Utils.clamp(n, lo, hi) end
---Round half up; without `decimals` the result is an integer.
---@param n number
---@param decimals? integer
---@return number
function Core.Utils.round(n, decimals) end
---@param a number
---@param b number
---@param t number 0..1
---@return number
function Core.Utils.lerp(a, b, t) end

---Deep copy of a table (vectors and other values are copied by reference).
---@generic T: table
---@param t T
---@return T
function Core.Utils.deepCopy(t) end
---Deep merge in place, `override` wins; arrays are replaced, not merged.
---@param base table
---@param override table
---@return table base
function Core.Utils.merge(base, override) end
---@param t table
---@return any[] keys
function Core.Utils.keys(t) end
---@param t table
---@return any[] values
function Core.Utils.values(t) end
---@param t table
---@return integer count of all keys, array part included
function Core.Utils.count(t) end
---@param t table
---@return boolean
function Core.Utils.isEmpty(t) end
---@param arr any[]
---@param v any
---@return integer|nil index
function Core.Utils.indexOf(arr, v) end
---@param arr any[]
---@param v any
---@return boolean
function Core.Utils.contains(arr, v) end
---Removes the first occurrence of `v`.
---@param arr any[]
---@param v any
---@return boolean removed
function Core.Utils.removeValue(arr, v) end
---Same keys, mapped values.
---@param t table
---@param fn fun(v: any, k: any): any
---@return table
function Core.Utils.map(t, fn) end
---Array of every value the predicate accepts.
---@param t table
---@param fn fun(v: any, k: any): boolean
---@return any[]
function Core.Utils.filter(t, fn) end
---@param t table
---@param fn fun(v: any, k: any): boolean
---@return any value, any key
function Core.Utils.find(t, fn) end

---Splits on a plain (non-pattern) separator, default ','. Empty fields are kept.
---@param s string
---@param sep? string
---@return string[]
function Core.Utils.split(s, sep) end
---@param s string
---@return string
function Core.Utils.trim(s) end
---@param s string
---@param p string
---@return boolean
function Core.Utils.startsWith(s, p) end
---@param s string
---@param p string
---@return boolean
function Core.Utils.endsWith(s, p) end
---Uppercases the first character, leaves the rest untouched.
---@param s string
---@return string
function Core.Utils.capitalize(s) end
---Cuts `s` to at most `n` characters, marking a cut with '...'.
---@param s string
---@param n integer
---@return string
function Core.Utils.truncate(s, n) end
---Anything (usually player input) → printable, trimmed, length-capped string.
---@param s any
---@param maxLen? integer default 64
---@return string
function Core.Utils.sanitize(s, maxLen) end

---32 hex characters (not RFC 4122, just a unique id).
---@return string
function Core.Utils.uuid() end
---@param lo integer
---@param hi integer
---@return integer
function Core.Utils.randomInt(lo, hi) end
---@param len integer
---@param alphabet? string
---@return string
function Core.Utils.randomString(len, alphabet) end
---1234 → '$1,234', -1234 → '-$1,234'.
---@param n integer
---@return string
function Core.Utils.formatMoney(n) end
---Strings are hashed with GetHashKey, numbers pass through unchanged.
---@param s string|integer
---@return integer
function Core.Utils.hash(s) end
---@return integer ms GetGameTimer()
function Core.Utils.now() end
---@param t table { x, y, z }
---@return vector3
function Core.Utils.tableToVector3(t) end
---@param v vector3
---@return table { x = , y = , z = }
function Core.Utils.vector3ToTable(v) end
---Deep copy in which every vector becomes a `{ x, y, z, w }` table, so `json.encode` can
---serialise it. Cycles are dropped and nesting is capped.
---@param v any
---@return any
function Core.Utils.jsonSafe(v) end

--------------------------------------------------------------------------------
-- Core.Math (lib/math/shared.lua, DESIGN §3.2) — pure
--------------------------------------------------------------------------------

---@class Core.Math
Core.Math = {}

---@param a vector3
---@param b vector3
---@return number metres
function Core.Math.distance(a, b) end
---Distance ignoring z.
---@param a vector3
---@param b vector3
---@return number metres
function Core.Math.distance2d(a, b) end
---Heading in degrees → unit forward vector on the ground plane.
---@param h number
---@return vector3
function Core.Math.headingToDirection(h) end
---Ground-plane direction → heading in degrees, normalised to [0, 360).
---@param dir vector3
---@return number
function Core.Math.directionToHeading(dir) end
---@param h number
---@return number heading in [0, 360)
function Core.Math.normalizeHeading(h) end
---GTA camera/entity rotation (degrees) → unit forward vector.
---@param rot vector3
---@return vector3
function Core.Math.rotationToDirection(rot) end
---`coords` moved by forward/right/up metres relative to `heading`.
---@param coords vector3
---@param heading number degrees
---@param forward number
---@param right number
---@param up number
---@return vector3
function Core.Math.offset(coords, heading, forward, right, up) end
---@param p vector3
---@param center vector3
---@param radius number
---@return boolean
function Core.Math.isInsideSphere(p, center, radius) end
---Axis-aligned box; `min`/`max` are the two opposite corners in any order.
---@param p vector3
---@param min vector3
---@param max vector3
---@return boolean
function Core.Math.isInsideBox(p, min, max) end
---@param d number degrees
---@return number radians
function Core.Math.deg2rad(d) end
---@param r number radians
---@return number degrees
function Core.Math.rad2deg(r) end
---@param v vector3
---@param decimals? integer
---@return vector3
function Core.Math.roundVector(v, decimals) end

--------------------------------------------------------------------------------
-- Core.Validate (lib/validate/shared.lua, DESIGN §3.3) — never throws
--------------------------------------------------------------------------------

---@class Core.Validate
Core.Validate = {}

---Validate one value against one spec.
---@param spec CoreSpec
---@param v any
---@return boolean ok
---@return string|nil err reads `expected integer 1..100, got -5`
function Core.Validate.value(spec, v) end
---Validate positional arguments against a schema array (or a single spec). Extra arguments
---beyond the schema are ignored; missing ones must be optional.
---@param schema CoreSchema
---@param ... any
---@return boolean ok
---@return string|nil err reads `arg 2: expected integer 1..100, got -5`
function Core.Validate.check(schema, ...) end
---Validate a keyed table against `{ key = spec }`. Unknown keys are ignored — use
---`{ 'table', keys = ..., max = n }` to bound the key count.
---@param schema table<string, CoreSpec>
---@param t table
---@return boolean ok
---@return string|nil err reads `field "name": expected string, got nil`
function Core.Validate.checkTable(schema, t) end
---True when `spec` names a kind this validator understands (for self-checks).
---@param spec any
---@return boolean
function Core.Validate.isSpec(spec) end

--------------------------------------------------------------------------------
-- Core.Log (lib/log/shared.lua, DESIGN §3.4)
--------------------------------------------------------------------------------

---@class Core.Log
Core.Log = {}

---`string.format` style; prints `[core:<resource>] info: message`.
---@param fmt string
---@param ... any
function Core.Log.info(fmt, ...) end
---@param fmt string
---@param ... any
function Core.Log.warn(fmt, ...) end
---@param fmt string
---@param ... any
function Core.Log.error(fmt, ...) end
---No-op unless `Core.Config.Debug`.
---@param fmt string
---@param ... any
function Core.Log.debug(fmt, ...) end
---(server) Audit line plus the `audit` hook, for a logging plugin. Never log identifiers
---beyond `src` and the player name.
---@param category string
---@param src integer
---@param fmt string
---@param ... any
---@return boolean written
function Core.Log.audit(category, src, fmt, ...) end

--------------------------------------------------------------------------------
-- Core.Callback (lib/callback/shared.lua, DESIGN §3.5) — promise based
--------------------------------------------------------------------------------

---@class Core.Callback
Core.Callback = {}

---Registers a callback name. Server handlers get `src` as their first argument, client
---handlers do not. `register(name, fn)` and `register(name, schema, fn)` are both accepted.
---@param name string convention: '<resource>:<name>'
---@param schema CoreSchema|fun(...): ... the argument schema, or the handler itself
---@param fn? fun(...): ... the handler
function Core.Callback.register(name, schema, fn) end
---(client) Ask the server for a value, with `Config.CallbackTimeoutMs`.
---Yields — call it from a thread, event handler or command. nil on timeout or handler error.
---@param name string
---@param ... any
---@return ... any
function Core.Callback.await(name, ...) end
---(client) Ask the server for a value, waiting `ms` (100..3600000).
---@param name string
---@param ms integer
---@param ... any
---@return ... any
function Core.Callback.awaitTimeout(name, ms, ...) end
---(server) Ask one client for a value, with `Config.CallbackTimeoutMs`.
---Yields. nil on timeout, handler error or drop.
---@param src integer
---@param name string
---@param ... any
---@return ... any
function Core.Callback.awaitClient(src, name, ...) end
---(server) Ask one client for a value, waiting `ms` (100..3600000).
---@param src integer
---@param name string
---@param ms integer
---@param ... any
---@return ... any
function Core.Callback.awaitClientTimeout(src, name, ms, ...) end

--------------------------------------------------------------------------------
-- Core.Net (lib/net/shared.lua, DESIGN §3.6) — validated net events
--------------------------------------------------------------------------------

---@class Core.Net
Core.Net = {}

---Registers a validated event. (server) `Net.on(name, schema, handler(src, ...), opts?)` runs
---schema → cooldown → requireLoaded → permission → distance before the handler; rejections are
---silent unless `opts.onReject` is given. (client) `Net.on(name, schema, handler(...))` for
---server → client events.
---@param name string
---@param schema CoreSchema
---@param handler fun(...): any server form receives `src` first
---@param opts? CoreNetOptions server only
function Core.Net.on(name, schema, handler, opts) end
---(server) Send to one client. (client) `Net.emit(name, ...)` sends to the server — the first
---argument is the event name there, not a src.
---@param src integer|string server: the target; client: the event name
---@param name string|any server: the event name; client: the first payload value
---@param ... any
function Core.Net.emit(src, name, ...) end
---(server) Send to every client. Never call this from a loop.
---@param name string
---@param ... any
function Core.Net.broadcast(name, ...) end

--------------------------------------------------------------------------------
-- Core.Commands (lib/commands/shared.lua, DESIGN §3.7) — typed commands
--------------------------------------------------------------------------------

---@class Core.Commands
Core.Commands = {}

---Registers a typed command. `args` reaches the handler keyed by param name; a validation
---failure answers with `Usage: /name <model> [plate]`.
---@param name string single word, without the slash
---@param opts CoreCommandOptions
---@param handler fun(src: integer, args: table<string, any>, raw: string)
---@return string name
function Core.Commands.register(name, opts, handler) end
---Removes a command from this VM's registry (the engine keeps the binding itself).
---@param name string
---@return boolean removed
function Core.Commands.unregister(name) end

--------------------------------------------------------------------------------
-- Core.Keys (lib/keys/client.lua, DESIGN §3.8) — (client) key bindings
--------------------------------------------------------------------------------

---@class Core.Keys
Core.Keys = {}

---(client) Registers a `+`/`-` command pair and maps the `+` one to a default key. Presses are
---ignored while NUI has focus or the pause menu is open, unless `whileFocused` is set.
---@param opts CoreKeyBindOptions
---@return string commandName the `+` command, i.e. the id of the binding
function Core.Keys.register(opts) end
---(client) True while the bound key is held down.
---@param commandName string the value returned by `Core.Keys.register`
---@return boolean
function Core.Keys.isDown(commandName) end

--------------------------------------------------------------------------------
-- Core.Streaming (lib/streaming/client.lua, DESIGN §3.9) — (client) asset loading
--------------------------------------------------------------------------------

---@class Core.Streaming
Core.Streaming = {}

---(client) Streams in a model. Yields. Default timeout `Config.StreamingTimeoutMs`.
---@param model string|integer
---@param timeoutMs? integer
---@return boolean loaded
function Core.Streaming.requestModel(model, timeoutMs) end
---(client) Marks a model as no longer needed so the streamer may evict it.
---@param model string|integer
function Core.Streaming.releaseModel(model) end
---(client) Streams in an animation dictionary. Yields.
---@param dict string
---@param timeoutMs? integer
---@return boolean loaded
function Core.Streaming.requestAnimDict(dict, timeoutMs) end
---(client) Releases an animation dictionary.
---@param dict string
function Core.Streaming.releaseAnimDict(dict) end
---(client) Streams in a movement clipset (anim set). Yields.
---@param set string
---@param timeoutMs? integer
---@return boolean loaded
function Core.Streaming.requestAnimSet(set, timeoutMs) end
---(client) Releases a movement clipset.
---@param set string
function Core.Streaming.releaseAnimSet(set) end
---(client) Streams in a named particle asset. Yields.
---@param name string
---@param timeoutMs? integer
---@return boolean loaded
function Core.Streaming.requestPtfx(name, timeoutMs) end
---(client) Releases a named particle asset.
---@param name string
function Core.Streaming.releasePtfx(name) end
---(client) Requests collision around `coords` and waits until it loaded around the local ped.
---Meant to be called right after teleporting the ped there. Yields.
---@param coords vector3
---@param timeoutMs? integer
---@return boolean loaded
function Core.Streaming.requestCollision(coords, timeoutMs) end

--------------------------------------------------------------------------------
-- Core.Anim (lib/anim/client.lua §3.10, server/remote.lua §20)
--------------------------------------------------------------------------------

---@class Core.Anim
Core.Anim = {}

---(client) Plays `clip` from `dict` on `ped`; loads and releases the dictionary. Yields.
---(server) `Core.Anim.play(src, dict, clip, opts?)` forwards the same call to that player.
---@param ped integer client: a ped handle; server: the player's src
---@param dict string
---@param clip string
---@param opts? CoreAnimOptions
---@return boolean ok
function Core.Anim.play(ped, dict, clip, opts) end
---(client) Stops one clip (dict + clip given) or every scripted task on the ped.
---(server) `Core.Anim.stop(src)` clears the player's ped tasks.
---@param ped integer client: a ped handle; server: the player's src
---@param dict? string
---@param clip? string
---@return boolean ok
function Core.Anim.stop(ped, dict, clip) end
---(client) True while `ped` is playing `clip` from `dict`.
---@param ped integer
---@param dict string
---@param clip string
---@return boolean
function Core.Anim.isPlaying(ped, dict, clip) end

--------------------------------------------------------------------------------
-- Core.Audio (lib/audio/client.lua §3, server/remote.lua §20)
--------------------------------------------------------------------------------

---@class Core.Audio
Core.Audio = {}

---(client) Play a frontend (2D) sound. (server) `Core.Audio.playFrontend(src, name, set)`.
---@param name string client: the sound name; server: the player's src
---@param set? string audio ref / sound set, nil for the default one
---@return integer|nil soundId client only; the server returns a boolean
function Core.Audio.playFrontend(name, set) end
---(client) Play a sound at world coordinates. (server) `Core.Audio.playAt(coords, name, set,
---range?)` sends it to every loaded player within `range` (at most 20) and returns the count.
---@param coords vector3|table
---@param name string
---@param set? string
---@param range? number server only, metres
---@return integer|nil soundId client: the sound id; server: how many players were reached
function Core.Audio.playAt(coords, name, set, range) end
---(client) Stop a sound started by `playFrontend`/`playAt` and release its id.
---@param soundId integer
---@return boolean stopped
function Core.Audio.stop(soundId) end

--------------------------------------------------------------------------------
-- Core.Locale (lib/locale/shared.lua, DESIGN §26)
--------------------------------------------------------------------------------

---@class Core.Locale
Core.Locale = {}

---Translated string for `key`. Lookup order: the calling resource's `locales/<lang>.json`,
---core's own file, `Core.Config.Texts`, then the key itself. `{{var}}` placeholders are
---substituted from `vars`.
---@param key string
---@param vars? table<string, any>
---@return string
function Core.Locale.t(key, vars) end
---The language this VM translates into.
---@return string
function Core.Locale.getLanguage() end
---Overrides the language inside this VM only (no replication, no file writes).
---@param lang string
---@return boolean accepted
function Core.Locale.setLanguage(lang) end
---True when any source knows `key`.
---@param key string
---@return boolean
function Core.Locale.has(key) end
---Every string of the current language as a flat copy, in lookup precedence.
---@return table<string, string>
function Core.Locale.all() end

--------------------------------------------------------------------------------
-- Core.Player (lib/player/client.lua §3.11, client/player.lua §6.2,
--              server/player.lua §4.2, server/getters.lua §22, §17/§20 additions)
--------------------------------------------------------------------------------

---On the server the namespace is also callable: `Core.Player(src)` returns a handle.
---@class Core.Player
---@overload fun(src: integer): CorePlayerHandle
Core.Player = {}

-- ---------------------------------------------------------------- client ----

---(client) The local player's server id. (server) `Core.Player.getServerId` does not exist.
---@return integer
function Core.Player.getServerId() end
---(client) Current heading of the local ped.
---@return number
function Core.Player.getHeading() end
---(client) Reads one replicated key from the local player's state bag (DESIGN §8):
---'name', 'charId', 'cash', 'bank', 'faction', 'group', 'dead', 'stats', 'attachments'.
---@param key string
---@return any
function Core.Player.get(key) end
---(client) The faction summary, or nil when the player is in no faction.
---@return CoreFactionSummary|nil
function Core.Player.getFaction() end
---(client) Calls `fn(value)` whenever the server changes `key` on THIS player's bag.
---@param key string
---@param fn fun(value: any)
---@return any cookie the state-bag handler, or nil on bad arguments
function Core.Player.onChange(key, fn) end
---(client) Asks the server to re-send the load payload.
function Core.Player.refresh() end
---(client, internal) Stores the payload delivered by `core:client:loaded`.
---@param payload table
function Core.Player.setCached(payload) end

-- ---------------------------------------------------------------- server ----

---(client) True once the server created the session. (server) `isLoaded(src)`.
---@param src? integer server only
---@return boolean
function Core.Player.isLoaded(src) end
---(client) True while the character is dead. (server) use `Player(src).state.dead`.
---@return boolean
function Core.Player.isDead() end
---(server) Cheap copy of the session header, or nil when there is no loaded session.
---@param src integer
---@return CorePlayerInfo|nil
function Core.Player.getInfo(src) end
---(client) `getData(key)` reads one field of the `core:client:loaded` payload: model,
---appearance, position, money, faction, group, charId, name.
---(server) `getData(src, path)` reads a dot path out of the character document ('money.cash',
---'meta.foo'). Tables come back as copies on both sides.
---@param src integer|string server: the player's src; client: the payload field name
---@param path? string server only
---@return any
function Core.Player.getData(src, path) end
---(server) Writes a dot path on the character document and marks it dirty; replicated top-level
---keys are pushed to the state bag again. Emits `playerDataChanged`.
---@param src integer
---@param path string
---@param value any
---@return boolean ok
function Core.Player.setData(src, path, value) end
---(server) Persists one player's character document now.
---@param src integer
---@return boolean saved
function Core.Player.save(src) end
---(server) Persists every dirty session.
---@return integer saved
function Core.Player.saveAll() end
---(server) Every loaded player's src.
---@return integer[]
function Core.Player.getPlayers() end
---(server) Calls `fn(src, info)` for every loaded player.
---@param fn fun(src: integer, info: CorePlayerInfo)
function Core.Player.forEach(fn) end
---(server) Number of loaded players.
---@return integer
function Core.Player.count() end
---(server)
---@param charId string
---@return integer|nil src
function Core.Player.getSrcByCharId(charId) end
---(server)
---@param src integer
---@return string|nil
function Core.Player.getName(src) end
---(server) The account's license identifier.
---@param src integer
---@return string|nil
function Core.Player.getLicense(src) end
---(client) `getPed()` returns the local player's ped. (server) `getPed(src)`.
---@param src? integer server only
---@return integer ped 0 when the player has no ped
function Core.Player.getPed(src) end
---(client) `getCoords()` returns the local ped's position. (server) `getCoords(src)` also
---returns the heading.
---@param src? integer server only
---@return vector3|nil coords
---@return number|nil heading server only
function Core.Player.getCoords(src) end
---(server) Teleports the player (`core:client:teleport`).
---@param src integer
---@param coords vector3
---@param heading? number
---@return boolean ok
function Core.Player.setCoords(src, coords, heading) end
---(server) Stores and applies a new ped model plus optional appearance.
---@param src integer
---@param model string|integer ≤ 64 characters
---@param appearance? CoreAppearance
---@return boolean ok
function Core.Player.setModel(src, model, appearance) end
---(server)
---@param src integer
---@param bucket integer
---@return boolean ok
function Core.Player.setBucket(src, bucket) end
---(server)
---@param src integer
---@return integer bucket
function Core.Player.getBucket(src) end
---(server) Changes the account group; `Core.Perms.setGroup` routes through this so the live
---session, the account document and the `group` state-bag key never disagree.
---@param src integer
---@param group string must exist in Config.Perms.Groups
---@return boolean ok
function Core.Player.setGroup(src, group) end
---(server) Writes a plugin-owned key to the player state bag (DESIGN §20). Core keys are refused.
---@param src integer
---@param key string
---@param value any
---@return boolean ok
function Core.Player.setReplicated(src, key, value) end
---(server) Writes one field on the live account document and persists it (DESIGN §22).
---@param src integer
---@param key string
---@param value any
---@return boolean ok
function Core.Player.setAccountData(src, key, value) end

---(server) Enables or disables the player's controls.
---@param src integer
---@param enabled boolean
---@return boolean ok
function Core.Player.setControls(src, enabled) end
---(server)
---@param src integer
---@param frozen boolean
---@return boolean ok
function Core.Player.setFrozen(src, frozen) end
---(server)
---@param src integer
---@param invincible boolean
---@return boolean ok
function Core.Player.setInvincible(src, invincible) end
---(server)
---@param src integer
---@param visible boolean
---@return boolean ok
function Core.Player.setVisible(src, visible) end
---(server)
---@param src integer
---@param hp integer
---@return boolean ok
function Core.Player.setHealth(src, hp) end
---(server)
---@param src integer
---@param ap integer 0..100
---@return boolean ok
function Core.Player.setArmour(src, ap) end
---(server)
---@param src integer
---@return integer|nil hp
function Core.Player.getHealth(src) end
---(server)
---@param src integer
---@return integer|nil armour
function Core.Player.getArmour(src) end
---(server) Drops the player.
---@param src integer
---@param reason? string
---@return boolean ok
function Core.Player.kick(src, reason) end
---(server) Writes a `bans` document and drops the player. `seconds = 0` is permanent.
---@param src integer
---@param reason string
---@param seconds? integer
---@param by? string admin name for the record
---@return boolean ok
function Core.Player.ban(src, reason, seconds, by) end
---(server) Sugar for `Core.Notify.send`.
---@param src integer
---@param message string
---@param type? CoreNotifyType
---@param duration? integer
---@return boolean ok
function Core.Player.notify(src, message, type, duration) end
---(server) Forced respawn (admin /revive): clears the death timer and spawns the player.
---@param src integer
---@param coords? vector3 defaults to the configured respawn point
---@param heading? number
---@return boolean ok
function Core.Player.respawn(src, coords, heading) end
---(server) Nearest other loaded player to `src`.
---@param src integer
---@param maxDist? number default 50.0
---@return integer|nil otherSrc
---@return number|nil distance
function Core.Player.getClosest(src, maxDist) end
---(server) Every loaded player within `range` of `coords`, nearest first.
---@param coords vector3
---@param range number
---@return { src: integer, dist: number }[]
function Core.Player.getInRange(coords, range) end
---(server) Exact, case-insensitive name match over loaded players.
---@param name string
---@return integer|nil src
function Core.Player.findByName(name) end
---(server) Case-insensitive substring match (plain, no patterns) over loaded players.
---@param part string
---@return integer[] srcs
function Core.Player.findByPartialName(part) end
---(server) Every connected player sitting in the vehicle with this netId.
---@param netId integer
---@return integer[] srcs
function Core.Player.getInVehicle(netId) end
---(server) True when the player's ped is within `range` of `coords`.
---@param src integer
---@param coords vector3
---@param range number
---@return boolean
function Core.Player.isNear(src, coords, range) end
---(server) Street and zone name, read on the player's own client. Yields; nil on timeout.
---@param src integer
---@return string|nil street
---@return string|nil zone
function Core.Player.getStreet(src) end
---(server, internal) Builds the session for an already-connected player (core restart).
---@param src integer
---@return boolean ok
function Core.Player.loadSession(src) end
---(server, internal) Loads a session for every connected player that has none yet.
---@return integer loaded
function Core.Player.loadAllConnected() end
---(server, internal) Starts the autosave thread (idempotent).
function Core.Player.startAutosave() end
---(server, internal) Stops the autosave thread.
function Core.Player.stopAutosave() end

--------------------------------------------------------------------------------
-- Core.UI (lib/ui/client.lua §3.12, client/ui.lua §6.10, server/ui.lua §21)
--------------------------------------------------------------------------------

---@class Core.UI.textUI
local CoreUITextUI = {}
---(client) `show(key, text, opts?)` — (server) `show(src, key, text, opts?)`.
---@param key string|integer client: the key cap; server: the player's src
---@param text string|nil client: the prompt text; server: the key cap
---@param opts? CoreTextUIOptions|string
---@return boolean ok
function CoreUITextUI.show(key, text, opts) end
---(client) `hide()` — (server) `hide(src)`.
---@param src? integer server only
---@return boolean ok
function CoreUITextUI.hide(src) end
---(client) True while a prompt is on screen.
---@return boolean
function CoreUITextUI.isShown() end

---@class Core.UI.menu
local CoreUIMenu = {}
---Opens a list menu and waits for the answer; nil on ESC or timeout. Yields.
---(client) `open(opts)` — (server) `open(src, opts)`.
---@param opts CoreMenuOptions|integer client: the options; server: the player's src
---@param serverOpts? CoreMenuOptions server only
---@return any value the picked item's `value`, or nil
function CoreUIMenu.open(opts, serverOpts) end
---(client) Closes an open menu without a result.
function CoreUIMenu.close() end

---@class Core.UI.input
local CoreUIInput = {}
---Opens a form and waits for the answer; nil on cancel or timeout. Yields.
---(client) `open(opts)` — (server) `open(src, opts)`.
---@param opts CoreInputOptions|integer client: the options; server: the player's src
---@param serverOpts? CoreInputOptions server only
---@return table<string, any>|nil values keyed by field name
function CoreUIInput.open(opts, serverOpts) end

---@class Core.UI.progress
---@overload fun(opts: CoreProgressOptions): boolean (client) run a progress bar, true when it finished
---@overload fun(src: integer, opts: CoreProgressOptions): boolean (server) same, on that player
local CoreUIProgress = {}
---(client) Cancels the running progress bar (its `Core.UI.progress` call returns false).
function CoreUIProgress.cancel() end

---@class Core.UI.hud
local CoreUIHud = {}
---(client) `set(partial)` — core feeds cash/bank/name/serverId/faction itself.
---@param partial CoreHudPartial
---@return boolean ok
function CoreUIHud.set(partial) end
---(client) `setVisible(bool)` — (server) `setVisible(src, bool)`.
---@param visible boolean|integer client: the flag; server: the player's src
---@param serverVisible? boolean server only
---@return boolean ok
function CoreUIHud.setVisible(visible, serverVisible) end
---(client) Whether the HUD is currently shown.
---@return boolean
function CoreUIHud.isVisible() end

---@class Core.UI.keys
local CoreUIKeys = {}
---(client) `show(items)` — (server) `show(src, items)`. Instructional buttons.
---@param items CoreKeyHint[]|integer client: the hints; server: the player's src
---@param serverItems? CoreKeyHint[] server only
---@return boolean ok
function CoreUIKeys.show(items, serverItems) end
---(client) `hide()` — (server) `hide(src)`.
---@param src? integer server only
---@return boolean ok
function CoreUIKeys.hide(src) end

---@class Core.UI.spinner
local CoreUISpinner = {}
---(client) `show(text)` — (server) `show(src, text)`.
---@param text string|integer client: the label; server: the player's src
---@param serverText? string server only
---@return boolean ok
function CoreUISpinner.show(text, serverText) end
---(client) `hide()` — (server) `hide(src)`.
---@param src? integer server only
---@return boolean ok
function CoreUISpinner.hide(src) end

---@class Core.UI.stats
local CoreUIStats = {}
---(client, internal) Pushes the stat bars into the HUD; core's `client/stats.lua` owns this.
---@param values table<string, { value: number, min: number, max: number }>
---@return boolean ok
function CoreUIStats.set(values) end

---@class Core.UI.state
local CoreUIState = {}
---(client, internal) Mirrors one replicated player-state key into `window.CoreUI.state`.
---@param key string
---@param value any
---@return boolean ok
function CoreUIState.set(key, value) end

---@class Core.UI.locale
local CoreUILocale = {}
---(client, internal) Pushes core's locale strings into the shell (`CoreUI.t`).
---@param data { lang: string, strings: table<string, string> }
---@return boolean ok
function CoreUILocale.set(data) end

---@class Core.UI
---@field textUI Core.UI.textUI
---@field menu Core.UI.menu
---@field input Core.UI.input
---@field progress Core.UI.progress
---@field hud Core.UI.hud
---@field keys Core.UI.keys
---@field spinner Core.UI.spinner
---@field stats Core.UI.stats
---@field state Core.UI.state
---@field locale Core.UI.locale
Core.UI = {}

---(client) Subscribes to an event a NUI page sent back to the game.
---@param pageId string
---@param event string
---@param fn fun(data: any)
---@return any handle for Core.UI.off, or nil
function Core.UI.on(pageId, event, fn) end
---(client) Removes a subscription created by `Core.UI.on`.
---@param handle any
function Core.UI.off(handle) end
---(client) Declares a page. Without `script` the component is resolved from core's own bundle.
---@param id string 1..64 chars of [%w_%-:]
---@param opts? CorePageOptions
---@return boolean ok
function Core.UI.registerPage(id, opts) end
---(client) Drops a page declaration (and closes it if it was open).
---@param id string
---@return boolean ok
function Core.UI.unregisterPage(id) end
---(client) `open(id, props?)` opens a page (exclusive) or shows an overlay.
---(server) `open(src, id, props?)` does the same on that player's client.
---@param id string|integer client: the page id; server: the player's src
---@param props? table|string client: the props; server: the page id
---@param serverProps? table server only
---@return boolean ok
function Core.UI.open(id, props, serverProps) end
---(client) `close(id?)` — nil closes the open exclusive page. (server) `close(src, id?)`.
---@param id? string|integer client: the page id; server: the player's src
---@param serverId? string server only
---@return boolean ok
function Core.UI.close(id, serverId) end
---(client) Closes every page, overlay and built-in, then releases focus.
function Core.UI.closeAll() end
---(client)
---@param id string
---@return boolean
function Core.UI.isOpen(id) end
---(client) The id of the exclusive page currently open.
---@return string|nil
function Core.UI.getOpenPage() end
---(client) True while NUI holds focus.
---@return boolean
function Core.UI.isFocused() end
---(client) `send(id, event, data)` pushes an event into an open page.
---(server) `send(src, id, event, data)` does the same on that player's client.
---@param id string|integer client: the page id; server: the player's src
---@param event string|any client: the event name; server: the page id
---@param data any
---@param serverData? table server only
---@return boolean ok
function Core.UI.send(id, event, data, serverData) end
---(client) `notify({ message, type, duration, title })` or `notify(message, type)`.
---(server) `notify(src, message, type?, duration?)` — an alias of `Core.Notify.send`.
---@param data CoreNotifyOptions|string|integer
---@param type? CoreNotifyType|string
---@param duration? integer server only
---@return boolean ok
function Core.UI.notify(data, type, duration) end
---(client) `alert(opts)` — (server) `alert(src, opts)`. Waits for the answer. Yields.
---@param opts CoreAlertOptions|integer client: the options; server: the player's src
---@param serverOpts? CoreAlertOptions server only
---@return boolean confirmed
function Core.UI.alert(opts, serverOpts) end
---(client) `shard(opts)` — (server) `shard(src, opts)`. Big centred title card.
---@param opts CoreShardOptions|integer client: the options; server: the player's src
---@param serverOpts? CoreShardOptions server only
---@return boolean ok
function Core.UI.shard(opts, serverOpts) end
---(client) `hide(reason?)` adds a hide reason: the whole shell stops painting while any is
---set. The caller's own resource name is prefixed, so nobody can clear a foreign reason;
---hiding also cancels the open built-in modal and closes the focused page (DESIGN §31).
---(server) `hide(src, reason?)` does the same on that player's client, as `server:<reason>`.
---@param reason? string|integer client: the reason (default `default`); server: the player's src
---@param serverReason? string server only
---@return boolean ok
function Core.UI.hide(reason, serverReason) end
---(client) `show(reason?)` removes this caller's reason; true when it removed one. The shell
---stays hidden while another reason (a game state, the server, another plugin) is still set.
---(server) `show(src, reason?)` removes that player's `server:<reason>`.
---@param reason? string|integer client: the reason (default `default`); server: the player's src
---@param serverReason? string server only
---@return boolean ok
function Core.UI.show(reason, serverReason) end
---(client) True while the shell is hidden by at least one reason.
---@return boolean
function Core.UI.isHidden() end
---(client) A copy of the current hide reason keys, sorted (admin and debug tooling).
---@return string[]
function Core.UI.hiddenReasons() end
---(client) Enables or disables one auto-hide watcher at runtime (`Config.UI.AutoHide`).
---Only `true` enables; disabling one also clears the `game:<name>` reason it owns.
---@param name CoreAutoHideWatcher
---@param enabled boolean
---@return boolean ok false for an unknown watcher
function Core.UI.setAutoHide(name, enabled) end
---(client) Session-scoped override of `Config.UI.Blur` (DESIGN §32): turns the live game
---blur behind every `data-core-blur` panel on or off for this client. Only `true` enables;
---numeric `opts.strength` (px), `opts.fps` and `opts.scale` override the configured
---tunables (non-numbers are ignored). Re-sent on a shell reload. `/uiblur` drives the same.
---@param enabled boolean
---@param opts? { strength?: number, fps?: number, scale?: number }
---@return boolean ok always true
function Core.UI.setBlur(enabled, opts) end

--------------------------------------------------------------------------------
-- Core.Markers (client/markers.lua §6.4, server/worldsync.lua §15)
--------------------------------------------------------------------------------

---@class Core.Markers
Core.Markers = {}

---(client) Creates a marker drawn by core's world scheduler.
---@param opts CoreMarkerOptions
---@return string|nil id
function Core.Markers.add(opts) end
---(client) Changes any subset of a marker's options.
---@param id string
---@param opts CoreMarkerOptions
---@return boolean ok
function Core.Markers.update(id, opts) end
---(client)
---@param id string
---@return boolean removed
function Core.Markers.remove(id) end
---(client) Removes every marker of the calling resource.
---@return integer removed
function Core.Markers.removeAll() end
---(server) Creates the marker on every client; id looks like 'g:12'.
---@param opts CoreMarkerOptions
---@return string|nil id
function Core.Markers.addGlobal(opts) end
---(server) Creates the marker for one player only.
---@param src integer
---@param opts CoreMarkerOptions
---@return string|nil id
function Core.Markers.addFor(src, opts) end
---(server) Updates a global or per-player entry.
---@param id string
---@param partial CoreMarkerOptions
---@return boolean ok
function Core.Markers.updateGlobal(id, partial) end
---(server) Removes a global or per-player entry.
---@param id string
---@return boolean removed
function Core.Markers.removeGlobal(id) end

--------------------------------------------------------------------------------
-- Core.TextLabels (client/textlabels.lua §6.5, server/worldsync.lua §15)
--------------------------------------------------------------------------------

---@class Core.TextLabels
Core.TextLabels = {}

---(client) Creates a 3D text label.
---@param opts CoreTextLabelOptions
---@return string|nil id
function Core.TextLabels.add(opts) end
---(client)
---@param id string
---@param opts CoreTextLabelOptions
---@return boolean ok
function Core.TextLabels.update(id, opts) end
---(client) Replaces a label's text.
---@param id string
---@param text string
---@return boolean ok
function Core.TextLabels.setText(id, text) end
---(client)
---@param id string
---@return boolean removed
function Core.TextLabels.remove(id) end
---(client) Removes every label of the calling resource.
---@return integer removed
function Core.TextLabels.removeAll() end
---(server) Creates the label on every client.
---@param opts CoreTextLabelOptions
---@return string|nil id
function Core.TextLabels.addGlobal(opts) end
---(server) Creates the label for one player only.
---@param src integer
---@param opts CoreTextLabelOptions
---@return string|nil id
function Core.TextLabels.addFor(src, opts) end
---(server)
---@param id string
---@param partial CoreTextLabelOptions
---@return boolean ok
function Core.TextLabels.updateGlobal(id, partial) end
---(server)
---@param id string
---@return boolean removed
function Core.TextLabels.removeGlobal(id) end

--------------------------------------------------------------------------------
-- Core.Blips (client/blips.lua §6.6, server/worldsync.lua §15)
--------------------------------------------------------------------------------

---@class Core.Blips
Core.Blips = {}

---(client) Creates a blip from coords, a radius, an entity or a netId.
---@param opts CoreBlipOptions
---@return string|nil id
function Core.Blips.add(opts) end
---(client) Changes any subset of a blip's style options.
---@param id string
---@param opts CoreBlipOptions
---@return boolean ok
function Core.Blips.update(id, opts) end
---(client)
---@param id string
---@param text string
---@return boolean ok
function Core.Blips.setLabel(id, text) end
---(client)
---@param id string
---@param coords vector3
---@return boolean ok
function Core.Blips.setCoords(id, coords) end
---(client) Turns the GPS route to a blip on or off.
---@param id string
---@param enabled boolean
---@return boolean ok
function Core.Blips.setRoute(id, enabled) end
---(client) The engine blip handle, for natives core does not wrap.
---@param id string
---@return integer|nil handle
function Core.Blips.getHandle(id) end
---(client)
---@param id string
---@return boolean removed
function Core.Blips.remove(id) end
---(client) Removes every blip of the calling resource.
---@return integer removed
function Core.Blips.removeAll() end
---(client) Sets the player's personal waypoint.
---@param coords vector3
---@return boolean ok
function Core.Blips.setWaypoint(coords) end
---(client) The player's waypoint position (z is the blip's, not ground level).
---@return vector3|nil
function Core.Blips.getWaypoint() end
---(client) Clears the player's waypoint.
---@return boolean ok
function Core.Blips.clearWaypoint() end
---(server) Creates the blip on every client (coords/radius only, no entity).
---@param opts CoreBlipOptions
---@return string|nil id
function Core.Blips.addGlobal(opts) end
---(server) Creates the blip for one player only.
---@param src integer
---@param opts CoreBlipOptions
---@return string|nil id
function Core.Blips.addFor(src, opts) end
---(server)
---@param id string
---@param partial CoreBlipOptions
---@return boolean ok
function Core.Blips.updateGlobal(id, partial) end
---(server)
---@param id string
---@return boolean removed
function Core.Blips.removeGlobal(id) end

--------------------------------------------------------------------------------
-- Core.Interactions (client/interactions.lua §6.7, server/worldsync.lua §15)
--------------------------------------------------------------------------------

---@class Core.Interactions
Core.Interactions = {}

---(client) Registers an interaction. Callbacks that cross a resource boundary are funcrefs and
---are always pcall'd by core.
---@param opts CoreInteractionOptions
---@return string|nil id
function Core.Interactions.add(opts) end
---(client) Removes one interaction (and the marker it created).
---@param id string
---@return boolean removed
function Core.Interactions.remove(id) end
---(client) Removes every interaction of the calling resource.
---@return integer removed
function Core.Interactions.removeAll() end
---(client) Enables/disables an interaction without removing it.
---@param id string
---@param enabled boolean
---@return boolean ok
function Core.Interactions.setEnabled(id, enabled) end
---(client) Changes the prompt label.
---@param id string
---@param text string
---@return boolean ok
function Core.Interactions.setLabel(id, text) end
---(client) The interaction the player is currently in range of.
---@return CoreInteractionContext|nil
function Core.Interactions.getActive() end
---(server) Creates the interaction on every client; the handlers run server-side and receive
---`(src, ctx)`. `models`/`entity` are not supported here.
---@param opts CoreInteractionOptions
---@return string|nil id
function Core.Interactions.addGlobal(opts) end
---(server) Creates the interaction for one player only.
---@param src integer
---@param opts CoreInteractionOptions
---@return string|nil id
function Core.Interactions.addFor(src, opts) end
---(server)
---@param id string
---@param partial CoreInteractionOptions
---@return boolean ok
function Core.Interactions.updateGlobal(id, partial) end
---(server)
---@param id string
---@return boolean removed
function Core.Interactions.removeGlobal(id) end

--------------------------------------------------------------------------------
-- Core.Vehicles (server/vehicles.lua §4.6 + §22, client/vehicles.lua §6.8)
--------------------------------------------------------------------------------

---@class Core.Vehicles
Core.Vehicles = {}

---(server) Spawns a vehicle server-side and tracks it. Yields while the entity materialises.
---@param opts CoreVehicleSpawnOptions
---@return integer|nil netId
---@return string|nil err
function Core.Vehicles.spawn(opts) end
---(server) Deletes a tracked vehicle.
---@param netId integer
---@return boolean removed
function Core.Vehicles.delete(netId) end
---(server)
---@param netId integer
---@return boolean
function Core.Vehicles.exists(netId) end
---(server)
---@param netId integer
---@return integer entity 0 when it is gone
function Core.Vehicles.getEntity(netId) end
---(server)
---@param netId integer
---@return CoreVehicleInfo|nil
function Core.Vehicles.getInfo(netId) end
---(server) State bag plus a best-effort `SetVehicleDoorsLocked` RPC.
---@param netId integer
---@param locked boolean
---@return boolean ok
function Core.Vehicles.setLocked(netId, locked) end
---(client) `isLocked(veh)` reads the state bag. (server) `isLocked(netId)`.
---@param veh integer client: an entity handle; server: a netId
---@return boolean locked
function Core.Vehicles.isLocked(veh) end
---(server)
---@param netId integer
---@param charId string
---@return boolean ok
function Core.Vehicles.giveKeys(netId, charId) end
---(server)
---@param netId integer
---@param charId string
---@return boolean ok
function Core.Vehicles.removeKeys(netId, charId) end
---(client) `hasKeys(veh)` for the local player. (server) `hasKeys(src, netId)`.
---@param veh integer client: an entity handle; server: the player's src
---@param netId? integer server only
---@return boolean
function Core.Vehicles.hasKeys(veh, netId) end
---(server)
---@param netId integer
---@param charId string|nil nil clears the owner
---@return boolean ok
function Core.Vehicles.setOwner(netId, charId) end
---(server)
---@param netId integer
---@return string|nil charId
function Core.Vehicles.getOwner(netId) end
---(server) Spawned vehicles owned by the player's character.
---@param src integer
---@return integer[] netIds
function Core.Vehicles.getPlayerVehicles(src) end
---(server) Every vehicle core spawned.
---@return integer[] netIds
function Core.Vehicles.list() end
---(server) Creates the `vehicles` document for an already spawned vehicle.
---@param netId integer
---@return string|nil vehId
function Core.Vehicles.persist(netId) end
---(server)
---@param charId string
---@return CoreVehicleRecord[]
function Core.Vehicles.getRecords(charId) end
---(server)
---@param vehId string
---@return CoreVehicleRecord|nil
function Core.Vehicles.getRecord(vehId) end
---(server) Spawns a stored vehicle from its record. Yields.
---@param vehId string
---@param coords vector3
---@param heading? number
---@param ownerSrc? integer client the props are applied on
---@return integer|nil netId
---@return string|nil err
function Core.Vehicles.spawnRecord(vehId, coords, heading, ownerSrc) end
---(server) Saves the last known position/props, then removes the entity from the world.
---@param netId integer
---@return boolean ok
function Core.Vehicles.store(netId) end
---(server) `saveProps(netId, props)` accepts a validated props table (the client route is
---`core:server:vehicleProps`). (client) `saveProps(veh)` sends the vehicle's current props.
---@param netId integer server: a netId; client: an entity handle
---@param props? CoreVehicleProps server only
---@return boolean ok
function Core.Vehicles.saveProps(netId, props) end
---(server)
---@param vehId string
---@return boolean removed
function Core.Vehicles.deleteRecord(vehId) end
---(server) Core-spawned vehicles within `range` of `coords`, nearest first.
---@param coords vector3
---@param range number
---@return integer[] netIds
function Core.Vehicles.getInRange(coords, range) end
---(server) Server id of the driver, or nil when the seat is empty or held by an NPC.
---@param netId integer
---@return integer|nil src
function Core.Vehicles.getDriver(netId) end
---(server) Server ids of the players in the passenger seats, in seat order.
---@param netId integer
---@return integer[] srcs
function Core.Vehicles.getPassengers(netId) end
---(server) Nearest core-spawned vehicle to the player's ped.
---@param src integer
---@param maxDist? number default 20.0
---@return integer|nil netId
function Core.Vehicles.getClosestToPlayer(src, maxDist) end
---(server) Writes one key of the persistence record's `meta` table (nil removes it).
---@param target integer|string a netId or a vehId
---@param key string
---@param value any
---@return boolean ok
function Core.Vehicles.setData(target, key, value) end
---(server) One key of the record's `meta`, or the whole copied table when `key` is nil.
---@param target integer|string a netId or a vehId
---@param key? string
---@return any
function Core.Vehicles.getData(target, key) end

---(client) The vehicle the local ped is in, or 0.
---@return integer veh
function Core.Vehicles.getCurrent() end
---(client)
---@return boolean isDriver
function Core.Vehicles.isDriver() end
---(client) Seat index of the local ped (-1 = driver).
---@return integer|nil seat
function Core.Vehicles.getSeat() end
---(client) Closest vehicle to `coords` (default: the local ped). On-demand pool scan — never
---call this per frame.
---@param coords? vector3
---@param radius? number default 5.0
---@return integer veh 0 when nothing is in range
---@return number|nil distance
function Core.Vehicles.getClosest(coords, radius) end
---(client)
---@param veh integer
---@return integer netId 0 when the entity is gone
function Core.Vehicles.getNetId(veh) end
---(client) Resolves a net id to a local entity, waiting for it to stream in. Yields.
---@param netId integer
---@param timeoutMs? integer default 5000
---@return integer veh 0 on timeout
function Core.Vehicles.fromNetId(netId, timeoutMs) end
---(client)
---@param veh integer
---@return string plate trimmed
function Core.Vehicles.getPlate(veh) end
---(client) Localised display name of a vehicle entity, model name or model hash.
---@param vehOrModel integer|string
---@return string
function Core.Vehicles.getDisplayName(vehOrModel) end
---(client) Reads the full appearance/condition set (DESIGN §6.8). JSON-safe.
---@param veh integer
---@return CoreVehicleProps|nil
function Core.Vehicles.getProps(veh) end
---(client) Applies only the keys present. Yields while asking for network control.
---@param veh integer
---@param props CoreVehicleProps
---@return boolean ok
function Core.Vehicles.setProps(veh, props) end
---(client)
---@param veh integer
---@param on boolean
---@return boolean ok
function Core.Vehicles.setEngine(veh, on) end
---(client) Full local repair (needs network control).
---@param veh integer
---@return boolean ok
function Core.Vehicles.repair(veh) end
---(client) Asks the server to toggle the lock of `veh`, or the current/closest vehicle within
---8 m. The server re-checks keys, distance and ownership.
---@param veh? integer
function Core.Vehicles.toggleLock(veh) end

--------------------------------------------------------------------------------
-- Core.Raycast (client/raycast.lua §6.9, server/remote.lua §20)
--------------------------------------------------------------------------------

---@class Core.Raycast
Core.Raycast = {}

---(client) Probe between two points. Synchronous, no loop.
---@param from vector3
---@param to vector3
---@param flags? integer intersect flags (default -1 = everything)
---@param ignoreEntity? integer entity the probe ignores (default 0)
---@return boolean hit
---@return vector3 coords
---@return vector3 normal
---@return integer entity 0 when nothing was hit
function Core.Raycast.between(from, to, flags, ignoreEntity) end
---(client) Probe straight out of the gameplay camera.
---@param distance? number metres (default 10.0)
---@param flags? integer
---@param ignoreEntity? integer default: the local ped
---@return boolean hit
---@return vector3 coords
---@return vector3 normal
---@return integer entity
function Core.Raycast.fromCamera(distance, flags, ignoreEntity) end
---(client) What the player is looking at.
---@param distance? number default 5.0
---@return integer entity 0 when nothing was hit
---@return vector3 coords
function Core.Raycast.getEntityInFront(distance) end
---(server) Shape test out of the player's camera, evaluated on that client. Yields.
---@param src integer
---@param distance? number default 10.0
---@return boolean hit
---@return vector3|nil coords
---@return integer entityNetId 0 when nothing networked was hit
function Core.Raycast.fromPlayer(src, distance) end

--------------------------------------------------------------------------------
-- Core.Spawn (client/spawn.lua §6.1) — (client) only
--------------------------------------------------------------------------------

---@class Core.Spawn
Core.Spawn = {}

---(client) Full spawn sequence: fade → model → collision → resurrect → place → fade in.
---Yields. Returns false when the model or collision failed to load in time (the ped is
---unfrozen and placed either way).
---@param opts CoreSpawnOptions
---@return boolean ok
function Core.Spawn.spawnPlayer(opts) end
---(client) Applies components, props and head blend data to a ped.
---@param ped integer
---@param appearance CoreAppearance
function Core.Spawn.applyAppearance(ped, appearance) end
---(client) Switches the player model (only when it differs) and applies the appearance on top.
---Yields.
---@param model string|integer
---@param appearance? CoreAppearance
---@return boolean ok
function Core.Spawn.setModel(model, appearance) end
---(client) Faded teleport: fade out → freeze → move → collision → heading → fade in. Yields.
---@param coords vector3
---@param heading? number
function Core.Spawn.teleport(coords, heading) end

--------------------------------------------------------------------------------
-- Core.World — (client) draw scheduler §6.3 / (server) time and weather §17
--------------------------------------------------------------------------------

---@class Core.World
Core.World = {}

---(server) Jumps the global clock and publishes it right away.
---@param hour integer 0..23
---@param minute integer 0..59
---@param second? integer
---@return boolean ok
function Core.World.setTime(hour, minute, second) end
---(server)
---@return integer hour
---@return integer minute
---@return integer second
function Core.World.getTime() end
---(server) Stops or resumes the clock.
---@param value boolean
---@return boolean ok
function Core.World.freezeTime(value) end
---(server)
---@return boolean
function Core.World.isTimeFrozen() end
---(server) Global weather change; `weatherType` must be one of `Config.World.Weathers`.
---@param weatherType CoreWeather
---@param transitionSec? number default 15
---@return boolean ok
function Core.World.setWeather(weatherType, transitionSec) end
---(server)
---@return CoreWeather
function Core.World.getWeather() end
---(server) Per-player clock override.
---@param src integer
---@param hour integer
---@param minute integer
---@return boolean ok
function Core.World.setTimeFor(src, hour, minute) end
---(server) Drops the per-player clock override.
---@param src integer
---@return boolean ok
function Core.World.clearTimeFor(src) end
---(server) Per-player weather override.
---@param src integer
---@param weatherType CoreWeather
---@param transitionSec? number
---@return boolean ok
function Core.World.setWeatherFor(src, weatherType, transitionSec) end
---(server) Drops the per-player weather override.
---@param src integer
---@return boolean ok
function Core.World.clearWeatherFor(src) end
---(client, internal) Registers a drawable entry in core's grid scheduler. Markers and text
---labels use this; plugins should use `Core.Markers` / `Core.TextLabels` instead.
---@param kind string 'marker' | 'label'
---@param id string
---@param coords vector3
---@param range number
---@param draw fun(entry: table, dist: number)
---@return boolean ok
function Core.World.add(kind, id, coords, range, draw) end
---(client, internal) Drops an entry.
---@param kind string
---@param id string
---@return boolean removed
function Core.World.remove(kind, id) end
---(client, internal) Moves an entry and/or changes its draw range.
---@param id string
---@param coords? vector3
---@param range? number
---@return boolean ok
function Core.World.update(id, coords, range) end
---(client, internal) The entry table itself.
---@param id string
---@return table|nil
function Core.World.get(id) end

--------------------------------------------------------------------------------
-- Core.Screen (server/environment.lua §17) — (server) only
--------------------------------------------------------------------------------

---@class Core.Screen
Core.Screen = {}

---(server) Fades the player's screen to black.
---@param src integer
---@param ms? integer default 500
---@return boolean ok
function Core.Screen.fade(src, ms) end
---(server) Fades back in.
---@param src integer
---@param ms? integer default 500
---@return boolean ok
function Core.Screen.unfade(src, ms) end
---(server) Screen blur in.
---@param src integer
---@param ms? integer default 1000
---@return boolean ok
function Core.Screen.blur(src, ms) end
---(server) Screen blur out.
---@param src integer
---@param ms? integer default 1000
---@return boolean ok
function Core.Screen.unblur(src, ms) end
---(server) Plays an animpostfx. `durationMs = 0` with `looped` runs until cleared.
---@param src integer
---@param name string
---@param durationMs? integer
---@param looped? boolean
---@return boolean ok
function Core.Screen.effect(src, name, durationMs, looped) end
---(server)
---@param src integer
---@param name string
---@return boolean ok
function Core.Screen.clearEffect(src, name) end
---(server)
---@param src integer
---@return boolean ok
function Core.Screen.clearEffects(src) end
---(server) Applies a timecycle modifier, optionally with a strength in 0..1.
---@param src integer
---@param name string
---@param strength? number
---@return boolean ok
function Core.Screen.timecycle(src, name, strength) end
---(server)
---@param src integer
---@return boolean ok
function Core.Screen.clearTimecycle(src) end

--------------------------------------------------------------------------------
-- Core.Cron (server/cron.lua §17) — (server) only
--------------------------------------------------------------------------------

---@class Core.Cron
Core.Cron = {}

---(server) Runs `fn` every `intervalMs` (raised to a 1000 ms floor).
---@param intervalMs integer
---@param fn fun()
---@param opts? { runNow?: boolean } runNow also fires it once right away
---@return string|nil id
function Core.Cron.every(intervalMs, fn, opts) end
---(server) Runs `fn` daily at a wall-clock time (`os.date` on the server).
---@param hour integer 0..23
---@param minute integer 0..59
---@param fn fun()
---@return string|nil id
function Core.Cron.at(hour, minute, fn) end
---(server) Five-field cron expression, evaluated once a minute.
---@param expr string e.g. '*/5 * * * *'
---@param fn fun()
---@return string|nil id
function Core.Cron.schedule(expr, fn) end
---(server) A run already in flight finishes.
---@param id string
---@return boolean removed
function Core.Cron.remove(id) end
---(server) Every job in creation order.
---@return CoreCronEntry[]
function Core.Cron.list() end

--------------------------------------------------------------------------------
-- Core.DB (server/db.lua §4.1, §22) — (server) only, documents are deep copies
--------------------------------------------------------------------------------

---@class Core.DB
Core.DB = {}

---(server) Inserts a document; assigns `id` (uuid) and `createdAt` when absent.
---@param collection string
---@param doc table
---@return string|nil id
function Core.DB.create(collection, doc) end
---(server)
---@param collection string
---@param id string
---@return table|nil doc a deep copy
function Core.DB.get(collection, id) end
---(server) Replaces the whole document (`doc.id` is forced to `id`); creates it when missing.
---@param collection string
---@param id string
---@param doc table
---@return boolean ok
function Core.DB.set(collection, id, doc) end
---(server) Shallow merge of top-level keys (a nested table value replaces the old one).
---@param collection string
---@param id string
---@param partial table
---@return boolean ok false when the document does not exist
function Core.DB.update(collection, id, partial) end
---(server)
---@param collection string
---@param id string
---@return boolean removed
function Core.DB.delete(collection, id) end
---(server) Every matching document, as deep copies.
---@param collection string
---@param match fun(doc: table): boolean|table a predicate, or a table of top-level equalities
---@return table[]
function Core.DB.find(collection, match) end
---(server)
---@param collection string
---@param match fun(doc: table): boolean|table
---@return table|nil
function Core.DB.findOne(collection, match) end
---(server)
---@param collection string
---@return table[]
function Core.DB.all(collection) end
---(server)
---@param collection string
---@return integer
function Core.DB.count(collection) end
---(server) Pushes pending writes to storage now.
function Core.DB.flush() end
---(server) Replaces the storage backend; loaded collections are re-read from it.
---@param newAdapter CoreDBAdapter
---@return boolean ok
function Core.DB.setAdapter(newAdapter) end
---(server) Persistent counter, document `counters`/<name>.
---@param name string
---@return integer next
function Core.DB.nextId(name) end
---(server) Registers a migration. `fn(doc)` may mutate the document or return a new one; it
---runs once per document whose `_v` is lower than `version`, on first load. Register it before
---the collection is first used.
---@param collection string
---@param version integer
---@param fn fun(doc: table): table|nil
---@return boolean ok
function Core.DB.migrate(collection, version, fn) end
---(server) Dumps every collection to JSON inside the resource.
---@param path? string default 'data/export-<timestamp>.json'
---@return string|nil path
function Core.DB.export(path) end
---(server) Reads an export back in.
---@param path string
---@param mode? CoreDBImportMode 'merge' (default) keeps unknown documents
---@return integer written
function Core.DB.import(path, mode) end

--------------------------------------------------------------------------------
-- Core.Money (server/money.lua §4.3) — (server) only, integer amounts
--------------------------------------------------------------------------------

---@class Core.Money
Core.Money = {}

---(server)
---@param src integer
---@param account CoreMoneyAccount
---@return integer amount
function Core.Money.get(src, account) end
---(server)
---@param src integer
---@param account CoreMoneyAccount
---@param amount integer
---@return boolean
function Core.Money.canAfford(src, account, amount) end
---(server) Adds a positive amount; false when it would pass `Config.Money.MaxAmount`.
---@param src integer
---@param account CoreMoneyAccount
---@param amount integer > 0
---@param reason? string shows up in the audit log and the `moneyChanged` hook
---@return boolean ok
function Core.Money.add(src, account, amount, reason) end
---(server) Removes a positive amount; false when the player cannot afford it (no partial
---removal).
---@param src integer
---@param account CoreMoneyAccount
---@param amount integer > 0
---@param reason? string
---@return boolean ok
function Core.Money.remove(src, account, amount, reason) end
---(server) Admin/reset use.
---@param src integer
---@param account CoreMoneyAccount
---@param amount integer
---@param reason? string
---@return boolean ok
function Core.Money.set(src, account, amount, reason) end
---(server) Remove then add, rolled back when the second half fails.
---@param fromSrc integer
---@param toSrc integer
---@param account CoreMoneyAccount
---@param amount integer
---@param reason? string
---@return boolean ok
function Core.Money.transfer(fromSrc, toSrc, account, amount, reason) end

--------------------------------------------------------------------------------
-- Core.Perms (server/perms.lua §4.4, §22) — (server) only
--------------------------------------------------------------------------------

---@class Core.Perms
Core.Perms = {}

---(server) Checked in order: console (src 0) → ACE → account grants → character grants →
---config group ('core.admin' in the group implies everything the admin group lists).
---@param src integer
---@param perm string
---@return boolean
function Core.Perms.has(src, perm) end
---(server)
---@param src integer
---@return string group
function Core.Perms.getGroup(src) end
---(server) Moves the player to another configured group (persisted on the account).
---@param src integer
---@param group string must exist in Config.Perms.Groups
---@return boolean ok
function Core.Perms.setGroup(src, group) end
---(server) `has(src, 'core.admin')`.
---@param src integer
---@return boolean
function Core.Perms.isAdmin(src) end
---(server) Grants a permission; idempotent.
---@param src integer
---@param perm string
---@param scope? CorePermScope default 'account'
---@return boolean ok
function Core.Perms.grant(src, perm, scope) end
---(server)
---@param src integer
---@param perm string
---@param scope? CorePermScope default 'account'
---@return boolean removed
function Core.Perms.revoke(src, perm, scope) end
---(server) Config group + account grants + character grants, deduped. ACE permissions cannot
---be enumerated and are not part of the list.
---@param src integer
---@return string[]
function Core.Perms.list(src) end

--------------------------------------------------------------------------------
-- Core.Factions (server/factions.lua §4.5) — (server) only
--------------------------------------------------------------------------------

---@class Core.Factions
Core.Factions = {}

---(server) Creates a faction, charging `Config.Factions.CreateCost` from the creator.
---@param src integer the owner-to-be
---@param name string
---@param tag string
---@param opts? table { color?: string }
---@return string|nil id
---@return string|nil err
function Core.Factions.create(src, name, tag, opts) end
---(server) Owner only; the faction bank is lost.
---@param src integer
---@return boolean ok
---@return string|nil err
function Core.Factions.disband(src) end
---(server)
---@param id string
---@return table|nil doc a copy of the faction document
function Core.Factions.get(id) end
---(server)
---@return CoreFactionListEntry[]
function Core.Factions.list() end
---(server)
---@param src integer
---@return CoreFactionSummary|nil
function Core.Factions.getPlayerFaction(src) end
---(server)
---@param id string
---@return CoreFactionMember[]
function Core.Factions.getMembers(id) end
---(server)
---@param src integer
---@param perm CoreFactionPerm
---@return boolean
function Core.Factions.hasPerm(src, perm) end
---(server) Perm `invite`; the target must be in no faction.
---@param src integer
---@param targetSrc integer
---@return boolean ok
---@return string|nil err
function Core.Factions.invite(src, targetSrc) end
---(server) Joins at rank 1; `Config.Factions.MaxMembers` is enforced.
---@param src integer
---@return boolean ok
---@return string|nil err
function Core.Factions.acceptInvite(src) end
---(server)
---@param src integer
---@return boolean ok
function Core.Factions.declineInvite(src) end
---(server) The owner must disband or transfer first.
---@param src integer
---@return boolean ok
---@return string|nil err
function Core.Factions.leave(src) end
---(server) Perm `kick`; never the owner or a higher rank.
---@param src integer
---@param targetCharId string
---@return boolean ok
---@return string|nil err
function Core.Factions.kick(src, targetCharId) end
---(server) Perm `manage_ranks`; the rank must be below the caller's unless they own it.
---@param src integer
---@param targetCharId string
---@param rank integer
---@return boolean ok
---@return string|nil err
function Core.Factions.setRank(src, targetCharId, rank) end
---(server) Perm `manage_ranks` (owner only for the top rank).
---@param src integer
---@param rank integer
---@param def { name?: string, perms?: table<CoreFactionPerm, boolean> }
---@return boolean ok
---@return string|nil err
function Core.Factions.setRankDef(src, rank, def) end
---(server) Owner only; the new rank becomes the top rank and the owner moves up to it.
---@param src integer
---@param name string
---@param perms? table<CoreFactionPerm, boolean>
---@return boolean ok
---@return string|nil err
function Core.Factions.addRank(src, name, perms) end
---(server) Owner only; members of that rank drop to rank 1.
---@param src integer
---@param rank integer
---@return boolean ok
---@return string|nil err
function Core.Factions.removeRank(src, rank) end
---(server) Owner only; the old owner drops one rank.
---@param src integer
---@param targetCharId string
---@return boolean ok
---@return string|nil err
function Core.Factions.setOwner(src, targetCharId) end
---(server) Perm `manage`.
---@param src integer
---@param changes { name?: string, tag?: string, color?: string }
---@return boolean ok
---@return string|nil err
function Core.Factions.update(src, changes) end
---(server) Any member may deposit.
---@param src integer
---@param amount integer
---@return boolean ok
---@return string|nil err
function Core.Factions.deposit(src, amount) end
---(server) Perm `bank`.
---@param src integer
---@param amount integer
---@return boolean ok
---@return string|nil err
function Core.Factions.withdraw(src, amount) end
---(server)
---@param id string
---@return integer bank
function Core.Factions.getBank(id) end
---(server) Plugin scratch space on the faction document.
---@param id string
---@param key string
---@param value any
---@return boolean ok
function Core.Factions.setMeta(id, key, value) end
---(server)
---@param id string
---@param key string
---@return any
function Core.Factions.getMeta(id, key) end

--------------------------------------------------------------------------------
-- Core.Notify (server/notify.lua §4.7) — (server) only
--------------------------------------------------------------------------------

---@class Core.Notify
Core.Notify = {}

---(server) Notifies one player; the message is sanitized to ≤ 256 characters.
---@param src integer
---@param message string
---@param type? CoreNotifyType default 'info'
---@param duration? integer ms
---@return boolean ok
function Core.Notify.send(src, message, type, duration) end
---(server) Announcements only — one call fans out to every client, never use it in a loop.
---@param message string
---@param type? CoreNotifyType
---@return boolean ok
function Core.Notify.broadcast(message, type) end

--------------------------------------------------------------------------------
-- Core.Doors (server/doors.lua + client/doors.lua §16)
--------------------------------------------------------------------------------

---@class Core.Doors
Core.Doors = {}

---(server) Registers (or re-registers) a door. A persisted `locked` flag wins over `opts.locked`.
---@param opts CoreDoorOptions
---@return string|nil id
function Core.Doors.register(opts) end
---(server) Drops the runtime door and its GlobalState key (the document stays).
---@param id string
---@return boolean removed
function Core.Doors.unregister(id) end
---(server)
---@param id string
---@return table|nil door a copy
function Core.Doors.get(id) end
---(server)
---@return table[] doors copies
function Core.Doors.list() end
---(server) Forces a lock state; `src` is only passed on to the hook.
---@param id string
---@param locked boolean
---@param src? integer
---@return boolean ok
function Core.Doors.setLocked(id, locked, src) end
---(server) Flips a door for a player, permission-checked.
---@param src integer
---@param id string
---@return boolean ok
---@return string|nil err
function Core.Doors.toggle(src, id) end
---(server) May `src` toggle this door? Doors without `perms` are public.
---@param src integer
---@param id string
---@return boolean
function Core.Doors.canUse(src, id) end
---(server) The closest door to the player within `radius`.
---@param src integer
---@param radius? number default 3.0
---@return string|nil id
function Core.Doors.getNearest(src, radius) end
---(client) Asks the server to flip the closest door in reach (the interact key does this).
---@return boolean sent
function Core.Doors.tryToggleNearest() end

--------------------------------------------------------------------------------
-- Core.Stats (server/stats.lua §18, client/stats.lua)
--------------------------------------------------------------------------------

---@class Core.Stats
Core.Stats = {}

---(client) `get(name)` reads `LocalPlayer.state.stats`. (server) `get(src, name)`.
---@param name string|integer client: the stat name; server: the player's src
---@param serverName? string server only
---@return number value 0 for an unknown stat
function Core.Stats.get(name, serverName) end
---(client) `getAll()` — (server) `getAll(src)`.
---@param src? integer server only
---@return table<string, number>
function Core.Stats.getAll(src) end
---(server) Sets a stat (clamped to its def). Emits `statChanged` when the value moved.
---@param src integer
---@param name string
---@param value number
---@return boolean ok
function Core.Stats.set(src, name, value) end
---(server) Adds a positive delta.
---@param src integer
---@param name string
---@param delta number
---@return boolean ok
function Core.Stats.add(src, name, delta) end
---(server) Subtracts a positive delta.
---@param src integer
---@param name string
---@param delta number
---@return boolean ok
function Core.Stats.sub(src, name, delta) end
---(server) Back to the default: one stat, or every stat when `name` is nil.
---@param src integer
---@param name? string
---@return boolean ok
function Core.Stats.reset(src, name) end
---(server) Registers a stat definition. Meant for resource start, before players load.
---@param name string
---@param def CoreStatDef
---@return boolean ok
function Core.Stats.define(name, def) end
---(client) Calls `fn(stats)` whenever the server replicates a new table. The argument is
---shared between listeners — treat it as read-only.
---@param fn fun(stats: table<string, number>)
---@return any handler
function Core.Stats.onChange(fn) end

--------------------------------------------------------------------------------
-- Core.Weapons (server/weapons.lua §19) — (server) only
--------------------------------------------------------------------------------

---@class Core.Weapons
Core.Weapons = {}

---(server) Gives a weapon or tops up an owned one; persists and applies it on the client.
---@param src integer
---@param weapon string e.g. 'WEAPON_PISTOL'
---@param ammo? integer default 0
---@param opts? CoreWeaponOptions
---@return boolean ok
function Core.Weapons.give(src, weapon, ammo, opts) end
---(server)
---@param src integer
---@param weapon string
---@return boolean removed
function Core.Weapons.remove(src, weapon) end
---(server) Empties the loadout.
---@param src integer
---@return boolean ok
function Core.Weapons.clear(src) end
---(server)
---@param src integer
---@param weapon string
---@param ammo integer
---@return boolean ok
function Core.Weapons.setAmmo(src, weapon, ammo) end
---(server) Ammo increases only ever come from here, never from a client snapshot.
---@param src integer
---@param weapon string
---@param delta integer
---@return boolean ok
function Core.Weapons.addAmmo(src, weapon, delta) end
---(server)
---@param src integer
---@param weapon string
---@return boolean
function Core.Weapons.has(src, weapon) end
---(server) Hash form, for `weaponDamageEvent` which carries `weaponType`, not a name.
---@param src integer
---@param hash integer
---@return boolean owns
---@return string|nil weaponName
function Core.Weapons.hasHash(src, hash) end
---(server) The whole loadout as a copy, nil without a session.
---@param src integer
---@return table<string, { ammo: integer, tint: integer?, components: string[] }>|nil
function Core.Weapons.getLoadout(src) end
---(server) Sends the whole loadout to the client (done on spawn and respawn already).
---@param src integer
---@return boolean ok
function Core.Weapons.apply(src) end

--------------------------------------------------------------------------------
-- Core.Native / Attachments / Waypoint / Screenshot (server/remote.lua §20) — (server) only
--------------------------------------------------------------------------------

---@class Core.Native
Core.Native = {}

---(server) Fire-and-forget: the client calls `_G[name](...)` when the name is allowed there
---(`Config.Native.Allow`).
---@param src integer
---@param name string native / global function name
---@param ... any
---@return boolean queued
function Core.Native.invoke(src, name, ...) end
---(server) Same, but waits for the client's return values. Yields; nil on timeout or refusal.
---@param src integer
---@param name string
---@param ... any
---@return ... any
function Core.Native.invokeWithResult(src, name, ...) end

---@class Core.Attachments
Core.Attachments = {}

---(server) Attaches a prop to the player's ped; an entry with the same id is replaced.
---Persisted in `data.attachments` and replicated to every client.
---@param src integer
---@param def CoreAttachmentDef
---@return string|nil id
---@return string|nil err
function Core.Attachments.add(src, def) end
---(server)
---@param src integer
---@param id string
---@return boolean removed
function Core.Attachments.remove(src, id) end
---(server)
---@param src integer
---@return boolean ok
function Core.Attachments.clear(src) end
---(server)
---@param src integer
---@return CoreAttachmentDef[] a copy of the stored entries
function Core.Attachments.list(src) end

---@class Core.Waypoint
Core.Waypoint = {}

---(server) Sets the player's personal waypoint.
---@param src integer
---@param coords vector3
---@return boolean queued
function Core.Waypoint.set(src, coords) end
---(server)
---@param src integer
---@return boolean queued
function Core.Waypoint.clear(src) end
---(server) The player's current waypoint, asked from their client. Yields.
---@param src integer
---@return vector3|nil
function Core.Waypoint.get(src) end

---@class Core.Screenshot
Core.Screenshot = {}

---(server) Asks the player's client for a screenshot; needs `screenshot-basic` started. Yields.
---@param src integer
---@param opts? table forwarded to screenshot-basic
---@return string|nil url
---@return string|nil err 'unavailable' | 'busy' | 'timeout' | 'failed'
function Core.Screenshot.take(src, opts) end

--------------------------------------------------------------------------------
-- Core.Globals / Services / Api (server/globals.lua, server/services.lua §22) — (server) only
--------------------------------------------------------------------------------

---@class Core.Globals
Core.Globals = {}

---(server) Persistent server-wide value; tables come back as deep copies.
---@param key string
---@param default? any
---@return any
function Core.Globals.get(key, default) end
---(server) Stores `value` (nil unsets it).
---@param key string
---@param value any
---@param mirrored? boolean also write `GlobalState['g:' .. key]`
---@return boolean ok
function Core.Globals.set(key, value, mirrored) end
---(server) Adds `delta` to a numeric global; unset keys start at 0.
---@param key string
---@param delta? number default 1
---@return number|nil value
function Core.Globals.increment(key, delta) end
---(server) Removes the key and its GlobalState mirror.
---@param key string
---@return boolean removed
function Core.Globals.unset(key) end

---@class Core.Services
Core.Services = {}

---(server) Registers (or replaces) the implementation of a documented service interface
---('notification', 'currency', 'death', 'items', 'time', 'weather').
---@param name string
---@param impl table
---@return boolean ok false when the contract is unmet
function Core.Services.register(name, impl) end
---(server)
---@param name string
---@return table|nil impl
function Core.Services.get(name) end
---(server)
---@param name string
---@return boolean
function Core.Services.has(name) end
---(server)
---@param name string
---@return boolean removed
function Core.Services.unregister(name) end

---@class Core.Api
Core.Api = {}

---(server) Publishes a table under `name` (convention: the resource's own name) so other
---plugins can reach it. Functions cross as funcrefs — one hop per call.
---@param name string
---@param api table
---@return boolean ok
function Core.Api.register(name, api) end
---(server) The table registered under `name`; nil once the owning resource stopped.
---@param name string
---@return table|nil
function Core.Api.get(name) end

--------------------------------------------------------------------------------
-- Core.Chat (server/chat.lua §23) — (server) only
--------------------------------------------------------------------------------

---@class Core.Chat
Core.Chat = {}

---(server) Sends a chat line to one player.
---@param src integer
---@param message string
---@param opts? CoreChatOptions
---@return boolean ok
function Core.Chat.send(src, message, opts) end
---(server) Announcements only, never in a loop.
---@param message string
---@param opts? CoreChatOptions
---@return boolean ok
function Core.Chat.broadcast(message, opts) end
---(server) Loaded players within `range` of `coords`.
---@param coords vector3|table
---@param range number
---@param message string
---@param opts? CoreChatOptions
---@return integer reached
function Core.Chat.sendNear(coords, range, message, opts) end
---(server) Registers a chat channel and its command. Built-ins: ooc, me, a, pm.
---@param name string
---@param def CoreChatChannel
---@return boolean ok
function Core.Chat.registerChannel(name, def) end
---(server) `fn(src, channel, msg) -> false` vetoes a message; nil clears the filter.
---@param fn fun(src: integer, channel: string, msg: string): boolean|nil
---@return boolean ok
function Core.Chat.setFilter(fn) end

--------------------------------------------------------------------------------
-- Core.Http / Core.Webhook (server/http.lua, server/webhook.lua §24) — (server) only
--------------------------------------------------------------------------------

---@class Core.Http
Core.Http = {}

---(server) One awaited HTTP request. Table bodies are json-encoded; a JSON response is
---decoded. Yields — call it from a thread that may wait.
---@param url string absolute http:// or https:// URL
---@param opts? CoreHttpOptions
---@return integer|nil status
---@return string|table|nil body
---@return table|nil headers
function Core.Http.fetch(url, opts) end
---(server) Registers an endpoint reachable at `http://<host>:<port>/core<path>`. Treat
---everything in the request as untrusted input.
---@param method string
---@param path string
---@param handler fun(req: CoreHttpRequest): integer, string|table, table|nil
---@return boolean registered
function Core.Http.route(method, path, handler) end
---(server) Reads a secret from a plain (never `setr`/`sets`) convar and keeps it in core.
---@param name string
---@param convarName string
---@return boolean ok true when the convar held a non-empty value
function Core.Http.setToken(name, convarName) end
---(server) The stored secret; put it in a header, never in a log line or a client payload.
---@param name string
---@return string|nil
function Core.Http.getToken(name) end

---@class Core.Webhook
Core.Webhook = {}

---(server) Queues one Discord embed for the `core_webhook_<name>` convar URL. Batched to at
---most one request every 2 s per webhook.
---@param name string
---@param embed CoreWebhookEmbed
---@return boolean queued false when no URL is configured or the embed is empty
function Core.Webhook.send(name, embed) end

--------------------------------------------------------------------------------
-- Core.Security (server/security.lua §25) — (server) only
--------------------------------------------------------------------------------

---@class Core.Security
Core.Security = {}

---(server) Installs a filter that sees every `weaponDamageEvent` before core's own checks;
---returning `false` cancels the damage. One filter at a time; nil removes it.
---@param fn fun(sender: integer, data: table): boolean|nil
---@return boolean accepted
function Core.Security.setDamageFilter(fn) end

--------------------------------------------------------------------------------
-- Core.Registry (server/api.lua + client/api.lua §2.3) — internal bookkeeping
--------------------------------------------------------------------------------

---Owner tracking behind the automatic cleanup on `onResourceStop`. Plugins do not need this:
---every registration API already tracks the calling resource.
---@class Core.Registry
Core.Registry = {}

---(internal) Set by the `call` export right before dispatch.
---@param name string|nil
function Core.Registry.setCaller(name) end
---(internal) The resource whose call is being served ('core' when core called itself).
---@return string
function Core.Registry.getCaller() end
---(internal) Remembers that `owner` created `id` of `kind`.
---@param kind CoreRegistryKind
---@param id string
---@param owner? string defaults to the current caller
function Core.Registry.track(kind, id, owner) end
---(internal) Drops the bookkeeping for one id.
---@param kind CoreRegistryKind
---@param id string
function Core.Registry.untrack(kind, id) end
---(internal) A module registers its remover once at file scope.
---@param kind CoreRegistryKind
---@param fn fun(id: string, owner: string)
function Core.Registry.onOwnerStop(kind, fn) end
---(server, internal) Everything `owner` still holds, by kind.
---@param owner string
---@return table<string, string[]>
function Core.Registry.getOwned(owner) end
---(client, internal) Ids of `kind` owned by `owner`; used by the modules' `removeAll`.
---@param kind CoreRegistryKind
---@param owner string
---@return string[]
function Core.Registry.idsOf(kind, owner) end
