---@meta
--- core/types/core.lua — LuaLS (sumneko) definitions for the `core` framework (DESIGN §27).
---
--- This file is DOCUMENTATION ONLY: it is never loaded at runtime and must NOT be listed in
--- fxmanifest.lua. Editors pick it up through `resources/.luarc.json`
--- (`workspace.library = ["core/types"]`), which makes `Core.*` autocomplete in every plugin.
---
--- Functions are marked `(server)` / `(client)` in their description; an unmarked function
--- exists on both sides. Everything except the libs (Utils, Math, Validate, Log, Callback,
--- Net, Commands, Keys, Streaming, Anim, Player, UI, Locale, Audio, Geometry, Schema, and the server-only DB) is reached
--- through the export proxy of DESIGN §2.2, so it must be called from a coroutine (thread, event
--- handler, command) and after `Core.onReady`.
---
--- The admin platform (DESIGN §41–§53: Schema, Settings, Perms v2, Audit, Bans, Buckets, Admin,
--- Maps, target selectors, input modes, rendered-camera raycasts) is typed in the last section.

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
---| '"pedChanged"'         # (client) (ped, previous) — the local player's ped entity changed; previous is 0 the first time
---| '"playerDataChanged"'  # (server) (src, topKey, value) — emitted by Core.Player.setData
---| '"moneyChanged"'       # (server) (src, account, amount, delta, reason)
---| '"factionChanged"'     # (server) (src, summary|nil) — membership or rank of an online member
---| '"factionUpdated"'     # (server) (factionId) — name/tag/colour/roster of a faction
---| '"vehicleSpawned"'     # (server) (netId, info) — also when a parked car is promoted (key persisted cars by info.vehId)
---| '"vehicleDeleted"'     # (server) (netId) — also when a parked car's clone parks again (§4.6 notes)
---| '"vehicleAutoStored"'  # (server) (vehId, reason) — core garaged a parked car itself ('max_parked': over Config.Vehicles.MaxParked)
---| '"audit"'              # (server) (category, src, message) — from Core.Log.audit
---| '"dbStatus"'           # (server) (healthy, reason) — core_db's connection health flipped (DESIGN §56.2.5)
---| '"dbWriteFailed"'      # (server) (owner, kind, table, err, key) — a queued write was dropped (DESIGN §56.3.5)
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
---| '"permsChanged"'       # (server) (src|nil, what: CorePermsChange, detail?) — §44; src nil = a whole group changed (or the load)
---| '"staffModeChanged"'   # (server) (src, modes) — §51, the { [name] = true } map on every staff-mode change or clear; {} on drop
---| '"adminAction"'        # (server) (payload) — §51, after every executed admin action: { id, actor, targets, args, reason, source, result, message }
---| '"settingChanged"'     # (client) (key, new, old) — §45, a `replicate = true` setting changed (new = nil when it stopped replicating)
---| '"staffSelfChanged"'   # (client) (state) — §51, this player's own { duty, modes } changed (client/adminstate.lua)
---| '"staffStateChanged"'  # (client) (src, state|nil) — §51, an on-duty staff member changed; nil = left duty / dropped (only while on duty)
---| '"uiReady"'          # (client) () — the NUI shell (re)loaded and re-registered its pages
---| '"uiVisibility"'       # (client) (visible, reasons) — the shell was hidden or shown again (§31)
---| '"hudHiddenChanged"'   # (client) (hidden) — §54: the first Core.UI.hideHud reason arrived / the last one went
---| '"uiPluginReady"'      # (client) (resource) — that resource's UI plugin finished loading (§38.4)
---| '"uiPluginFailed"'     # (client) (resource, error) — its manifest or its module was rejected

---@alias CoreNotifyType '"info"' | '"success"' | '"error"' | '"warning"'
---@alias CorePageType '"page"' | '"overlay"' | '"modal"'
---@alias CoreUIPluginState '"registered"' | '"loading"' | '"ready"' | '"failed"' | '"incompatible"'
---@alias CoreAutoHideWatcher '"pause"' | '"fade"' | '"switch"' | '"warning"' | '"hud"' | '"cinematic"'
---@alias CoreShardStyle '"wasted"' | '"success"' | '"info"'
---@alias CoreInputFieldType 'text'|'number'|'select'|'checkbox'|'textarea'|'password'|'slider'|'multiselect'|'multi-select'|'date'|'time'|'color'
---@alias CoreMoneyAccount '"cash"' | '"bank"' | string
---@alias CorePermScope '"account"' | '"character"'
---@alias CoreFactionPerm '"invite"' | '"kick"' | '"manage_ranks"' | '"bank"' | '"manage"'
---@alias CoreCommandParamType '"string"' | '"integer"' | '"number"' | '"player"' | '"rest"' | '"boolean"' | '"target"' | '"targets"'
---@alias CoreWorldKind '"marker"' | '"label"' | '"blip"' | '"interaction"'
---Owner-registry kinds (DESIGN §2.3); the second and third rows are the §44–§52 registries.
---@alias CoreRegistryKind
---| '"marker"' | '"label"' | '"blip"' | '"interaction"' | '"page"' | '"vehicle"' | '"world"'
---| '"settings"' | '"settingsWatch"' | '"permDef"' | '"bucket"' | '"adminCategory"' | '"adminAction"' | '"adminPage"' | '"adminPlayerTab"'
---| '"mapType"' | '"mapsModelValidator"' | '"mapsListener"' | '"mapsDraft"' | '"mapHold"' | '"mapEditorView"'
---| '"sceneNode"' | '"sceneKind"' | '"sceneListener"' | '"sceneInteract"' | '"sceneModelInfo"' | '"sceneFocus"' | '"sceneVoice"'
---| '"sceneHold"' | '"sceneHandler"'

---Named `Core.Hooks` veto pipelines core runs itself (DESIGN §40, §23, §51, §52). Any other name is a
---plugin's own pipeline. Return `false, reason` from a callback to veto; errors fail closed.
---@alias CoreHookPipeline
---| '"money:beforeTransfer"' # (server) { from, to, account, amount, reason } — before any debit (§40)
---| '"chat:beforeMessage"'   # (server) { src, channel, text } — before a player's line is delivered, after setFilter (§23)
---| '"admin:before"'         # (server) { id, actor, targets, args } — step 10 of Admin.run; filter by id (§51)
---| '"maps:beforeApply"'     # (server) { mapId, mode, actor, source, count, ops } — last step of Maps.apply, ops = first 200 { op, id, type, model?, pos } (§52)
---| '"scene:beforeSpawn"'    # (server) { kind, owner, bucket, pos, parent, offset, fields, persist, global, audience, radius } — the last step of Scene.spawn before R.audio.admit (§55.4)

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

---Per-entry 3D interaction dot (DESIGN §6.7). `true` takes every default from
---`Config.Interactions.WorldPrompt`; `false` opts out of an enabled default.
---@class CoreInteractionWorldPromptOptions
---@field enabled? boolean default true when the table form is given
---@field range? number collection range in metres (default Config.Interactions.WorldPrompt.Range)
---@field offsetZ? number z offset added to the target's coords before projecting (default 0.0)
---@field icon? string optional icon shown on the dot (≤ 32 chars)
---@field description? string optional description shown with the dot (≤ 64 chars)

---@class CoreInteractionOptions
---@field coords? vector3 fixed position (one of coords/entity/netId/models is required)
---@field entity? integer follow a local entity handle (client only)
---@field netId? integer follow a networked entity (client only)
---@field models? string[] follow the closest object of these models (client only, ≤ Config.Interactions.MaxModels)
---@field radius? number activation radius in metres (default 2.0)
---@field label? string prompt text shown in the text UI (default 'Interact')
---@field key? string key shown in the prompt — display only (default 'E')
---@field marker? CoreMarkerOptions auto-created marker that follows the interaction
---@field worldPrompt? boolean|CoreInteractionWorldPromptOptions draw the entry as a projected 3D dot
---instead of the text UI pill (§6.7); `true`/`nil` resolve from Config.Interactions.WorldPrompt.Enabled
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

---@alias CorePageInputMode 'ui'|'mixed'|'look'|'game'
---@alias CorePageEscapeMode 'close'|'event'
---@alias CorePageHideMode 'close'|'suspend'

---@class CorePageOptions
---@field type? CorePageType 'page' is exclusive, 'overlay' takes no focus, 'modal' stacks above
---the open page (any number, §38.9). Default 'page'.
---@field keepInput? boolean legacy: true without `input` means 'mixed' (default false)
---@field input? CorePageInputMode §41: 'ui' cursor, game gets nothing (default) · 'mixed' cursor + game input ·
---'look' no cursor, game input, page keeps keyboard events · 'game' no focus at all, stays open, click-through.
---Overlays ignore it. An unknown value makes registerPage return false.
---@field escape? CorePageEscapeMode §41: 'close' (default) · 'event' = Escape keeps the page open and fires
---its page event 'escape' (`Core.UI.on(id, 'escape', fn)`, SDK `page.on('escape')`).
---@field onHide? CorePageHideMode §41: 'close' (default) · 'suspend' = the §31 hidden transition keeps an exclusive
---page open (page events 'suspend' / 'resume', focus re-applied on show). Modals are always cancelled on hide.

---@class CoreUIPluginInfo
---@field id string the owning resource
---@field state CoreUIPluginState
---@field generation integer activation counter; a restart is n+1
---@field build string the `build` field of its manifest.json ('' when it has none)
---@field error? string why it is failed/incompatible
---@field ms? integer how long the shell took to load the module
---@field dev? string the `/uidev` origin it is served from, when one is pinned

---@class CoreUIManifest
---@field id string the owning resource
---@field apiVersion integer must equal `UIManifest.API_VERSION`
---@field entry string the ES module, relative to the `core_ui` folder
---@field css string[] stylesheets shipped with it (at most 8)
---@field build string content stamp ('' when the manifest has none)
---@field load '"eager"'|'"lazy"'
---@field preload string[] chunks worth fetching early (at most 16)
---@field pages string[] page ids the build found (tooling only; Lua stays the authority)
---@field sdk? string the `@core/ui` version it was built with
---@field vue? string the Vue version it was built against

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
---@field checked? boolean checkbox state; selecting toggles without closing
---@field values? (string|number|boolean|{label:string,value:any})[] side-scroll choices
---@field selected? integer 1-based selected side-scroll choice
---@field items? CoreMenuItem[] nested submenu
---@field metadata? {label:string,value:string|number|boolean}[] shown for the active row
---@field progress? number 0..100 progress shown for active row
---@field onChange? fun(value:any,state:any,index?:integer) checkbox/side-scroll changes

---@class CoreMenuOptions
---@field title string menu heading
---@field items CoreMenuItem[] rows, in display order (200 total, depth <=8)
---@field onChange? fun(value:any,state:any,index?:integer) fallback if row has no onChange

---@class CoreInputField
---@field name string key of the value in the returned table
---@field label string field label
---@field type? CoreInputFieldType default 'text'
---@field options? (string|number|boolean|{label:string,value:string|number|boolean})[] select choices
---@field searchable? boolean filters select options
---@field multiple? boolean select alias for multiselect
---@field step? number positive number/slider increment
---@field minLength? integer string length lower bound
---@field maxLength? integer string length upper bound, at most 4096
---@field default? any pre-filled value
---@field required? boolean block empty values; checkboxes must be checked
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

---@alias CoreHudAnchor '"minimap"' | '"bottom-left"'

---@class CoreHudPartial
---@field visible? boolean
---@field cash? integer
---@field bank? integer
---@field name? string
---@field serverId? integer
---@field health? integer
---@field armour? integer
---@field speed? number km/h (core does not draw it: Config.Hud.ShowSpeed is opt-in, §39.5)
---@field street? string (Config.Hud.ShowStreet is opt-in, §39.5)
---@field zone? string (Config.Hud.ShowStreet is opt-in, §39.5)
---@field talking? boolean voice activity — the mic tile (§39); never sent means no tile at all
---@field muted? boolean not connected to the voice server (§39)
---@field anchor? CoreHudAnchor where the strip sits — 'minimap' or 'bottom-left' only, anything else is dropped (§39.4)
---@field scale? number HUD unit multiplier, 0.5..2.0; outside that range it is dropped
---@field minimap? { x: number, y: number, w: number, h: number } minimap rect, screen fractions
---@field faction? table|false { name, tag, color } or false when in no faction

--------------------------------------------------------------------------------
-- Option tables — players, vehicles, services
--------------------------------------------------------------------------------

---@class CoreAppearance
---@field components? table<integer, { drawable: integer, texture: integer, palette: integer?, collection: string?, localDrawable: integer? }> collection + localDrawable are preferred when valid (DESIGN §34.5)
---@field props? table<integer, { drawable: integer, texture: integer, collection: string?, localDrawable: integer? }|false> same pair; '' is the base-game collection, nil means "use drawable"
---@field headBlend? table head blend data as GTA expects it
---@field faceFeatures? table<integer, number> [0..19] = scale -1.0..1.0, GTA's order (DESIGN §34.1)
---@field headOverlays? table<integer, { index: integer, opacity: number, colorType: integer, color: integer, color2: integer }> [0..12], index 255 = none, colorType 0 none / 1 hair / 2 makeup
---@field hairColor? { color: integer, highlight: integer } hair tint indices
---@field eyeColor? integer freemode eye colour index (0..31)

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

---@class CoreTeleportOptions
---@field withVehicle? boolean move the vehicle the player DRIVES, occupants included (default false)
---@field fade? boolean fade the screen out and in (default true)
---@field bucket? integer server only: routing bucket to switch to first (the driven car follows)
---@field moveRiders? boolean server only, with `bucket` + `withVehicle`: the other players in the car change bucket
---too (default false — the caller vouches for its own rank checks on them)

---@class CorePlayerStates
---@field frozen boolean
---@field invincible boolean
---@field visible boolean
---@field controls boolean

---@class CoreAccountView
---@field id string
---@field name string
---@field group string
---@field identifiers table<string, string> license/discord/fivem/steam
---@field firstSeen integer
---@field lastSeen integer
---@field playtime integer seconds
---@field banned boolean

---@class CoreTargetCandidate
---@field src integer
---@field name string

---@class CoreVehicleSpawnOptions
---@field model string|integer vehicle model name or hash
---@field coords vector3 spawn position
---@field heading? number default 0.0
---@field type? string CreateVehicleServerSetter type (default 'automobile')
---@field plate? string 1..8 chars of [%w %-]; normalized upper-case and globally unique across stored/live records
---@field ownerSrc? integer player the props are applied on
---@field ownerCharId? string character that owns the vehicle
---@field keys? string[] charIds that may unlock it
---@field props? CoreVehicleProps appearance/condition applied through ownerSrc's client
---@field keyMode? 'virtual'|'item' default 'virtual'; item mode grants no core virtual owner key
---@field locked? boolean default false
---@field persistent? boolean keep the entity alive without a nearby owner (default false)
---@field bucket? integer routing bucket for the entity

---@class CoreVehicleInfo
---@field netId integer
---@field model integer|string
---@field plate string
---@field ownerCharId string|nil
---@field keys table<string, boolean> explicit virtual keys; empty for an item-key vehicle
---@field keyMode 'virtual'|'item'
---@field locked boolean
---@field vehId string|nil persistence record id, when the vehicle was persisted
---@field spawnedBy string resource that called Core.Vehicles.spawn
---@field createdAt integer os.time() of the spawn
---@field parked? integer the Core.Scene node id while this vehicle is the adopted clone of a parked car (§55.21.4)

---@class CoreVehicleRecord
---@field id string vehId
---@field ownerCharId string
---@field model string|integer
---@field plate string
---@field props CoreVehicleProps
---@field stored boolean true only while deliberately garaged; false means it belongs in the persistent world
---@field position { x: number, y: number, z: number, heading: number, bucket?: integer } bucket when not 0
---@field meta table includes core `vehType`/`keyMode`; plugins use the remaining keys through Core.Vehicles.setData/getData
---@field parked? integer|false the Core.Scene node id while the car is parked (§55.21.4), else false
---@field locked? boolean the lock state kept while parked
---@field keys? string[] the virtual key holders kept while parked
---@field modelName? string the model name when known (parked nodes prefer it over the hash)
---@field destroyed? boolean the car was wrecked: restoreRecord / park / the boot check refuse it, spawnRecord brings it back

---@class CoreVehicleAdoptOptions
---@field ownerSrc? integer current player gaining gameplay ownership
---@field ownerCharId? string character gaining gameplay ownership
---@field keyMode? 'virtual'|'item' default 'virtual'
---@field locked? boolean default false
---@field props? CoreVehicleProps optional already trusted property snapshot

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
---@field tyreHealth? table<integer, number> wheel 0..7 → native wheel health
---@field doors? table<integer, boolean> door 0..7 → open
---@field windows? table<integer, boolean> window 0..7 → intact (GTA reports false for a lowered or broken window)
---@field lights? { [1]: boolean, [2]: boolean, [3]: integer } lights on, high beam, indicators (0..3)

---@class CoreAttachmentDef
---@field id? string unique per player (`^[%w_%-:]+$`, ≤ 64; default a uuid); re-adding the same id replaces the entry
---@field model string|integer a model name (`^[%w_%-]+$`, ≤ 64) or an integer hash
---@field bone? string|integer a bone tag 0..65535 or a bone name; anything else is 28422 (PH_R_Hand)
---@field offset? vector3 position offset from the bone, each component ≤ 1000 m
---@field rotation? vector3 rotation offset in degrees (applied in rotation order 1, the old applier's)

---@class CoreWeaponOptions
---@field tint? integer 0..31
---@field components? string[] 'COMPONENT_...' names

---@class CoreStatDef
---@field min? number floor (default 0)
---@field max? number ceiling (default 100)
---@field default? number value a fresh character starts at
---@field decayPerMinute? number subtracted every Config.Stats.TickMs
---@field thresholds? number[] values that fire `statThreshold` when crossed downwards
---@field hud? boolean|'"health"'|'"armour"' true = a bar on the rail plate, 'health'/'armour' = the bar cut out of that vitals plate (§39); anything else = no bar
---@field icon? string kit icon name for the slotted bar's glyph (default 'hud-food'/'hud-drink', §39.4)

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
---@field command? string|false the slash command; false disables it, nil defaults to the channel name
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


--------------------------------------------------------------------------------
-- Option tables — commands, keys, net (DESIGN §3.6–§3.8)
--------------------------------------------------------------------------------

---@class CoreCommandParam
---@field name string key of the parsed value in the handler's `args`
---@field type? CoreCommandParamType default 'string'; 'rest' must be the last param; 'target' (one src) and
---'targets' (src[]) are server only (DESIGN §49): the word is a selector resolved by `Core.Player.resolveTargets`
---@field help? string shown in the usage line
---@field optional? boolean
---@field max? integer 'targets' only: refuse selectors matching more players
---@field allowSelf? boolean 'target'/'targets': false refuses the caller (default true)

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
---@field whileCaptured? boolean §54: also fire while ANOTHER resource holds a `Core.Keys.capture` (core's chat key does)

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
---@field Perms { Groups: table<string, string[]>, Weights: table<string, integer>, Inherits: table<string, string[]> } the §44 SEED of the `perm_groups` collection (user/helper/mod/admin/senior/owner)
---@field Factions table CreateCost, CostAccount, MaxMembers, MaxRanks, DefaultRanks, …
---@field Vehicles table SpawnTimeoutMs, LockKey, LockDistance, PlatePrefix, MaxPropsBytes, AutoPark (true), AutoParkIdleMs (30000), AutoParkRadius (50), AutoParkSweepMs (10000), MaxParked (20000) — §4.6 parked cars
---@field Interactions table Key, ScanIntervalMs, FarScanIntervalMs, NearRange, MaxModels
---@field World table ScanIntervalMs, GridSize, TimeScale, StartTime, Weathers, WeatherCycle
---@field Locale string default language for Core.Locale
---@field Stats { Enabled: boolean, TickMs: integer, Defs: table<string, CoreStatDef> }
---@field Weapons { Allowed: string[]|nil, SnapshotIntervalMs: integer }
---@field Native { Allow: string[]|nil }
---@field Chat table Mode, ProximityRange, MaxLength (UTF-8 bytes, 1–256), CooldownMs, Format?, History (1–200), HideDelayMs (0 disables idle fade), VisibleLines (1–30), FadeMeters, ScreamRange, ScreamCommand, JoinLeave ('staff' default | 'all' | 'off', §23 note)
---@field Security table EntityLockdown, EnforceLoadout, BlockExplosions, WeaponDamage, …
---@field Doors { InteractDistance: number }
---@field Interiors table Enabled + one boolean per IPL group (base, casino, tuner, …; §36)
---@field Hud { ShowHealth: boolean, ShowArmour: boolean, ShowStats: boolean, ShowVoice: boolean, ShowSpeed: boolean, ShowStreet: boolean, Anchor: CoreHudAnchor, Scale: number } the vitals HUD (§39.5); ShowSpeed/ShowStreet are opt-in
---@field UI table NotifyDurationMs, MaxNotifyPerSecond, HudEnabled, ModalTimeoutMs, CancelKey
---@field Admin { CarDefaultModel: string, RequireDuty: boolean, Scope: table<string, integer>, StaffPerm: string, LegacyCommands: boolean } §51: RequireDuty (true), Scope = max player targets per run by group (helper 1 … owner 2000; 1 for unlisted), StaffPerm ('core.admin.staff'), LegacyCommands (true; false = core's /tp /bring /kick /ban /setcash … are not registered, §4.8)
---@field Buckets { Range: integer[] } §50: the Core.Buckets allocation range, default { 10000, 60000 }
---@field Maps { MaxMarkers: integer } §55.21.1: the editor view's preview budget (64); map content streams as Core.Scene nodes
---@field Scene table §55.20: CellSize (128), RegionSize (512), rings/tiers, FlushMs (50), MaxEventBytes (16384), budgets, Caps (props 3000, vehicles 64, modelsVehicles 32 …), Budgets, Radii, Fades, Visibility, Speed, Motion, DeadReckoning, Promote (… ProximityShare 0.7), Audio (… AllowAac true), Voice, Global { MaxNodes, MaxPerOwner }, MaxNodes, MaxNodesPerOwner, OwnerCaps ({ core = 60000, inventory = 40000 }), CoreReserve ({ nodes = 20000, persistent = 10000 }), MaxPersistent, MaxChildren (64), ObjectPool (nil = learned; 5300 with the pool raise), MaxFieldBytes, ClockMode, Debug — most read once at start
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
---@overload fun(hook: '"pedChanged"', fn: fun(ped: integer, previous: integer)): any
---@overload fun(hook: '"playerDataChanged"', fn: fun(src: integer, topKey: string, value: any)): any
---@overload fun(hook: '"moneyChanged"', fn: fun(src: integer, account: string, amount: integer, delta: integer, reason: string)): any
---@overload fun(hook: '"factionChanged"', fn: fun(src: integer, summary: CoreFactionSummary|nil)): any
---@overload fun(hook: '"factionUpdated"', fn: fun(factionId: string)): any
---@overload fun(hook: '"vehicleSpawned"', fn: fun(netId: integer, info: CoreVehicleInfo)): any
---@overload fun(hook: '"vehicleDeleted"', fn: fun(netId: integer)): any
---@overload fun(hook: '"vehicleAutoStored"', fn: fun(vehId: string, reason: 'max_parked')): any
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
---@overload fun(hook: '"permsChanged"', fn: fun(src: integer|nil, what: CorePermsChange, detail: string|nil)): any
---@overload fun(hook: '"adminAction"', fn: fun(payload: { id: string, actor: integer, targets: table, args: table, reason?: string, source: CoreAdminSource, result: 'ok'|'error', message?: string })): any
---@overload fun(hook: '"settingChanged"', fn: fun(key: string, new: any, old: any)): any
---@overload fun(hook: '"staffModeChanged"', fn: fun(src: integer, modes: table<string, true>)): any
---@overload fun(hook: '"staffSelfChanged"', fn: fun(state: CoreStaffState)): any
---@overload fun(hook: '"staffStateChanged"', fn: fun(src: integer, state: CoreStaffState|nil)): any
---@overload fun(hook: '"uiReady"', fn: fun()): any
---@overload fun(hook: '"uiVisibility"', fn: fun(visible: boolean, reasons: string[])): any
---@overload fun(hook: '"hudHiddenChanged"', fn: fun(hidden: boolean)): any
---@overload fun(hook: '"uiPluginReady"', fn: fun(resource: string)): any
---@overload fun(hook: '"uiPluginFailed"', fn: fun(resource: string, error: string)): any
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

---@class CoreCallbackOpts
---@field permission? string (server) Core.Perms.has(src, permission) must pass, else the caller gets nil
---@field cooldownMs? number (server) per src and name; `cooldown` (Net.on's spelling) is accepted too

---Registers a callback name. Server handlers get `src` as their first argument, client
---handlers do not. `register(name, fn)`, `register(name, schema, fn)`, `register(name, fn, opts)` and
---`register(name, schema, fn, opts)` are accepted (§44). Server order: rate limit → schema → cooldown →
---permission → handler; every refusal answers nil. Invalid opts refuse the registration. The client
---accepts opts and ignores them.
---@param name string convention: '<resource>:<name>'
---@param schema CoreSchema|fun(...): ... the argument schema, or the handler itself
---@param fn? fun(...): ...|CoreCallbackOpts the handler (or opts when `schema` is the handler)
---@param opts? CoreCallbackOpts
function Core.Callback.register(name, schema, fn, opts) end

---Why an await answered nil (§3.5 note, 2026-09-26): the wire carries `(key, false, reason)` for a refusal.
---'timeout' also covers a dropped player; 'error' = handler error, no handler, invalid arguments or an unknown
---reason from the other side (a client cannot forge one). Rate-limited requests are answered 'rate_limit'
---(≤ 10 answers per src and second; the rest time out).
---@alias CoreCallbackError 'rate_limit'|'schema'|'cooldown'|'permission'|'timeout'|'error'

---(client) Ask the server for a value, with `Config.CallbackTimeoutMs`.
---Yields — call it from a thread, event handler or command. Returns the handler's results, or
---`nil, CoreCallbackError` (callers reading one value are unaffected).
---@param name string
---@param ... any
---@return any ...
---@return CoreCallbackError? err only in the nil case
function Core.Callback.await(name, ...) end
---(client) Ask the server for a value, waiting `ms` (100..3600000). Results, or `nil, CoreCallbackError`.
---@param name string
---@param ms integer
---@param ... any
---@return any ...
---@return CoreCallbackError? err only in the nil case
function Core.Callback.awaitTimeout(name, ms, ...) end
---(server) Ask one client for a value, with `Config.CallbackTimeoutMs`.
---Yields. Results, or `nil, CoreCallbackError` ('timeout' also when the player dropped).
---@param src integer
---@param name string
---@param ... any
---@return any ...
---@return CoreCallbackError? err only in the nil case
function Core.Callback.awaitClient(src, name, ...) end
---(server) Ask one client for a value, waiting `ms` (100..3600000). Results, or `nil, CoreCallbackError`.
---@param src integer
---@param name string
---@param ms integer
---@param ... any
---@return any ...
---@return CoreCallbackError? err only in the nil case
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
---(server) Send ONE payload to a list of clients: msgpack-packed once, then one internal native call per
---target (TriggerClientEvent packs per call). Scoped delivery — "the players near X". Entries that are
---not a positive integer are skipped.
---@param targets integer[] array of srcs
---@param name string
---@param ... any
---@return integer sent how many clients were addressed
function Core.Net.emitMany(targets, name, ...) end
---(server) Send to every client. Never call this from a loop, and never for something only nearby
---players need: one reliable packet goes to every connected client (use `emitMany`).
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
---The registry entry for `name`, copied (handler omitted): name, description, params,
---permission, allowConsole, usage. nil for an unknown name.
---@param name string
---@return table|nil entry
function Core.Commands.get(name) end
---(server) Runs `name` AS IF `src` had typed it: same permission check, same param
---parsing, same handler as the engine command. Never throws. false on refusal.
---@param name string
---@param src integer
---@param args string[] raw words, by position
---@param raw? string the raw line, as the handler's third argument
---@return boolean ran
function Core.Commands.execute(name, src, args, raw) end
---Everything `src` may use, for the CEF TAB completer (§23): { command, description,
---params = { { name, help, type, optional } } }. Commands the caller lacks permission for are left out.
---@param src integer
---@return table[]
function Core.Commands.suggestions(src) end

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
---(client, stateful in core — a plugin reaches it through the proxy) Captures the keys for the
---calling resource (DESIGN §54): while ≥ 1 capture is held, a PRESS of every `Core.Keys` binding of
---a resource that holds no capture is swallowed (its release still arrives), unless the binding was
---registered with `whileCaptured = true`. Owner-tracked: released when the caller stops. The reason
---is namespaced like `Core.UI.hide` (`<resource>:<reason>`).
---@param reason? string default `default`
---@return boolean ok false only for an invalid reason
function Core.Keys.capture(reason) end
---(client) Drops the caller's capture; true when it removed one (never a foreign one).
---@param reason? string default `default`
---@return boolean removed
function Core.Keys.release(reason) end
---(client) Whether any capture is held, and whether the CALLING resource holds one itself — the
---question every binding asks at press time (never per frame).
---@return boolean captured
---@return boolean byCaller
function Core.Keys.isCaptured() end

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
--              server/player.lua §4.2, server/getters.lua §22, §17/§20 additions, §48, §49)
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
---(server, internal) One pass over EVERY session in one tick (core's stop/shutdown path); blocked through the
---export — never a plugin's to trigger (§56.12).
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
---(server) Teleports the player (`core:client:teleport`). DESIGN §48: `opts.bucket` changes the
---routing bucket first; `withVehicle` takes the car the player drives; `fade = false` skips the fade.
---@param src integer
---@param coords vector3|{x: number, y: number, z: number}
---@param heading? number
---@param opts? CoreTeleportOptions
---@return boolean ok false for a bad bucket or opts that are not a table
function Core.Player.setCoords(src, coords, heading, opts) end
---(server) Stores and applies a new ped model plus optional appearance.
---@param src integer
---@param model string|integer ≤ 64 characters
---@param appearance? CoreAppearance
---@return boolean ok
function Core.Player.setModel(src, model, appearance) end
---(server) Also sends the client event `core:client:bucketChanged (bucket)` to that player (§48, used by §52).
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
---@param group string must exist (`Core.Perms.groupExists`, the `perm_groups` collection; else Config.Perms.Groups)
---@return boolean ok
function Core.Player.setGroup(src, group) end
---(server) Writes a plugin-owned key to the player state bag (DESIGN §20). Core keys are refused.
---@param src integer
---@param key string
---@param value any
---@return boolean ok
function Core.Player.setReplicated(src, key, value) end
---(server) Writes one field on the live account document and persists it (DESIGN §22). `'id'`, `'license'` and
---`'identifiers'` are refused (engine-sourced). `'group'` emits `permsChanged (src, 'group')`, `'permissions'` /
---`'tempPermissions'` emit `permsChanged (src, 'grants')`.
---@param src integer
---@param key string
---@param value any
---@return boolean ok
function Core.Player.setAccountData(src, key, value) end
---(server, internal) The live account's raw `key` (a deep copy), nil without a session. Never yields:
---`Core.Perms` reads the account grants through it on a permission check. Blocked through the export.
---@param src integer
---@param key string
---@return any
function Core.Player.getAccountData(src, key) end
---(server) Read-only copy of the live account (§48; no permissions list); nil without a session.
---@param src integer
---@return CoreAccountView|nil
function Core.Player.getAccount(src) end
---(server) The same view by account id: live while the player is online, else from the DB (offline players).
---@param accountId string|integer
---@return CoreAccountView|nil
function Core.Player.getAccountById(accountId) end
---(server) Raw account group of a loaded player (no copy); nil without a session. Perms.getGroup is the
---normalised read (unknown groups → 'user').
---@param src integer
---@return string|nil
function Core.Player.getGroup(src) end
---(server) Every account that carries this identifier ('license:…', 'discord:…', …; 'ip:' never), sorted.
---Backed by a lazily built in-memory index (the first call may yield) that follows joins; a miss re-reads
---`accounts` when the count changed or the index is older than 5 minutes. DESIGN §47.
---@param identifier string
---@return string[]|nil accountIds
---@return string|nil err 'unavailable' while `accounts` cannot be read (never cached)
function Core.Player.findAccountsByIdentifier(identifier) end
---(server) Resolves a target selector (DESIGN §49): `me`/`^`, `<id>`/`$<id>`, `c:<charId>`,
---`r:<metres>` (≤ 500, actor's server-side coords), `#<group>`, `%<group>` (weight ≥), `f:<faction>`
---(id, tag or name), `*`, `others`, else a partial name. `,` = union, `!token` = remove. At most 4 set tokens
---(`*` `others` `r:` `f:` `#` `%`, removals included) and 8 distinct names per selector.
---Loaded players only, de-duplicated (case-insensitively, except `c:`). Errors: 'bad_actor' | 'bad_selector' |
---'not_allowed' (a set token under `basic`; 3rd = the token) | 'not_found' | 'ambiguous' (3rd =
---CoreTargetCandidate[] ≤ 10) | 'no_self' | 'no_origin' | 'bad_radius' | 'unknown_group' | 'unknown_faction' |
---'self' | 'no_match' | 'too_many' (3rd = max + 1: the union stops there).
---@param actorSrc integer 0 = console
---@param selector string|integer
---@param opts? { max?: integer, allowSelf?: boolean, basic?: boolean } basic = only me / ^ / ids / c: / names (non-staff commands)
---@return integer[]|nil targets
---@return string|nil err
---@return any detail
function Core.Player.resolveTargets(actorSrc, selector, opts) end

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
---setControls / setFrozen / setInvincible / setVisible are STICKY since §48: kept in the session and
---re-applied by the client after pedChanged, respawn and every teleport (session-only, not persisted).
---(server) The sticky states (a copy); nil without a session.
---(client) The sticky set the server last sent (a copy).
---@param src? integer server only
---@return CorePlayerStates|nil
function Core.Player.getStates(src) end
---(client) Re-applies every sticky state that differs from its default (pedChanged, spawn, teleport do this).
---@param ped? integer default PlayerPedId()
function Core.Player.reapplyStates(ped) end
---(client, internal) Stores sticky values from `core:client:playerState` and applies them.
---@param partial CorePlayerStates|table
---@return boolean ok
function Core.Player.setStates(partial) end
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
---(server) Bans through `Core.Bans.add` (DESIGN §47: identifiers + tokens, audit row `ban.add`, kick).
---`seconds` missing or ≤ 0 is permanent.
---@param src integer
---@param reason string
---@param seconds? integer
---@param by? integer|string actor src (0 = console) or a legacy name
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
---`slot` cuts the bar out of that vitals plate (§39.4), `icon` is a kit icon name; both are
---dropped unless `slot` is 'health'/'armour' and `icon` matches `^[%w_%-]+$` (<= 32 chars).
---@param values table<string, { value: number, min: number, max: number, slot: string?, icon: string? }>
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
---@field skillCheck Core.UI.skillCheck
---@field hud Core.UI.hud
---@field keys Core.UI.keys
---@field spinner Core.UI.spinner
---@field stats Core.UI.stats
---@field state Core.UI.state
---@field locale Core.UI.locale
Core.UI = {}

---(client) Subscribes to an event a NUI page sent back to the game. §41 adds the framework page events
---'escape' (a page registered `escape = 'event'`), 'suspend' and 'resume' (`onHide = 'suspend'`).
---@param pageId string
---@param event string|'escape'|'suspend'|'resume'
---@param fn fun(data: any)
---@return any handle for Core.UI.off, or nil
function Core.UI.on(pageId, event, fn) end
---(client) Removes a subscription created by `Core.UI.on`.
---@param handle any
function Core.UI.off(handle) end
---(client) Declares a page: Lua owns the id, the type and the owner, the shell resolves the
---component from the owning resource's UI plugin (DESIGN §38). `script`/`style` were removed.
---@param id string 1..64 chars of [%w_%-] — a PLAIN id: anything else (':' or '.') is refused with an error,
---because the NUI → Lua `ui_event` bridge (page events, 'escape', `Core.UI.on`) and feed channels drop it.
---@param opts? CorePageOptions `input` / `escape` / `onHide` are validated (§41): an unknown value → false
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
---(client) §41: switches a page's input mode without closing it. Only the resource that registered the
---page may call it; works whether the page is open or not. Same mode again → true, nothing sent.
---@param id string
---@param mode CorePageInputMode
---@return boolean ok false for an unknown page, an unknown mode or a caller that is not the owner
function Core.UI.setInput(id, mode) end
---(client) §41: the page's current input mode.
---@param id string
---@return CorePageInputMode|nil mode nil when no such page is registered
function Core.UI.getInput(id) end
---(client) `send(id, event, data)` pushes an event into an open page.
---(server) `send(src, id, event, data)` does the same on that player's client.
---@param id string|integer client: the page id; server: the player's src
---@param event string|any client: the event name; server: the page id
---@param data any
---@param serverData? table server only
---@return boolean ok
function Core.UI.send(id, event, data, serverData) end
---(client) `update(id, partial)` shallow-merges top-level keys into that page's props.
---(server) `update(src, id, partial)` does the same on that player's client.
---Queued per page and flushed on the next tick as ONE `page:patch`; core keeps its replay
---copy in step, so a shell reload restores current state (DESIGN §38.10). A page that is
---not showing returns false and sends nothing. Values are type-checked, not size-bounded.
---@param id string|integer client: the page id; server: the player's src
---@param partial table|string client: the keys to merge; server: the page id
---@param serverPartial? table server only
---@return boolean ok
function Core.UI.update(id, partial, serverPartial) end
---(client) `patch(id, path, value)` sets one value inside the page's props; a nil value
---deletes the key. (server) `patch(src, id, path, value)`. Path segments address the LUA
---table the page was opened with: a list element is its 1-BASED index (`#t + 1` appends),
---anything else is a map key. At most 8 deep, charset [%w_%-]. An index outside a list, or
---a delete in its middle, still applies but warns — send such a list whole with `update`.
---@param id string|integer client: the page id; server: the player's src
---@param path string|any client: 'slots.12.count'; server: the page id
---@param value? any client: the new value (nil deletes); server: the path
---@param serverValue? any server only
---@return boolean ok
function Core.UI.patch(id, path, value, serverValue) end
---(client) Coalesced telemetry: `feed({ speed = 132 })` uses the CALLING resource as the
---channel, `feed('inventory', { … })` names it. Latest value per key wins and at most one
---`feed` message per `Config.UI.FeedIntervalMs` leaves Lua (DESIGN §38.10).
---@param channel table|string the values, or the channel id
---@param values? table the values when a channel was given
---@return boolean ok
function Core.UI.feed(channel, values) end
---(client) True while a mounted component reads that feed, so a producer loop can sleep
---when nobody looks. Defaults to the calling resource's channel.
---@param channel? string
---@return boolean
function Core.UI.isFeedActive(channel) end
---(client) Answers `nui.invoke(name, data)` from the page on the CALLER's channel. The
---handler may yield (it runs in the NUI callback's coroutine and the page's fetch is simply
---held open) and its return value is sent back as `{ ok = true, data }` (DESIGN §38.8).
---Tracked by `Core.Registry`, so it dies with the resource that registered it.
---@param name string 1..64 chars of [%w_%-%.:]
---@param fn fun(data: table): any
---@return boolean ok
function Core.UI.onRequest(name, fn) end
---(client) Removes a handler registered with `Core.UI.onRequest`.
---@param name string
---@return boolean ok
function Core.UI.offRequest(name) end
---(client) Asks the shell a question and waits for the answer. Yields. The target is a
---registered page id or a UI plugin's channel (its resource name). On failure the second
---return value is the error code: `timeout`, `not_ready`, `shell_reloaded`, `bad_request`,
---`no_target`, `bad_result` or whatever the page answered (DESIGN §38.8).
---@param target string page id or plugin channel
---@param name string 1..64 chars of [%w_%-%.:]
---@param data? table
---@param timeoutMs? integer clamped to 1000..Config.UI.RequestMaxMs
---@return boolean ok, any resultOrErrorCode
function Core.UI.request(target, name, data, timeoutMs) end
---(client) Every UI plugin core knows about, sorted by id (tooling; `/uiplugins` prints it).
---@return CoreUIPluginInfo[]
function Core.UI.plugins() end
---(client) Is that resource's UI plugin loaded and running in the shell right now?
---Defaults to the calling resource.
---@param resource? string
---@return boolean
function Core.UI.isPluginReady(resource) end
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
---(client) Hides the HUD layer — not the shell — for the calling resource (DESIGN §54): core's
---vitals strip, stat bars and world prompts, every OVERLAY page whose owner holds no hideHud
---reason, the text UI / key hints of such a resource, the GTA radar and native HUD (switched
---off once, only what was on, restored on the last reason). The caller's own overlays, prompts,
---pages and modals stay, and so do toasts. Owner-tracked; fires `hudHiddenChanged` on the flip.
---@param reason? string default `default`; stored as `<resource>:<reason>`
---@return boolean ok false only for an invalid reason
function Core.UI.hideHud(reason) end
---(client) Drops the caller's hideHud reason; true when it removed one (never a foreign one).
---@param reason? string default `default`
---@return boolean removed
function Core.UI.showHud(reason) end
---(client) True while at least one hideHud reason is held (by anyone).
---@return boolean
function Core.UI.isHudHidden() end
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
---(server) Deletes a tracked vehicle. A parked car's clone takes its scene node along (the record is out again at
---the clone's pose) — a plain DeleteEntity on a clone would bring the car back at its parking spot.
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
---(server) State bag plus a best-effort `SetVehicleDoorsLocked` RPC. A vehId acts on its live car, else on the record
---(and a parked node's `locked` field) — no promotion needed.
---@param target integer|string a netId or a vehId
---@param locked boolean
---@return boolean ok
function Core.Vehicles.setLocked(target, locked) end
---(client) `isLocked(veh)` reads the state bag. (server) `isLocked(netId)`.
---@param veh integer client: an entity handle; server: a netId
---@return boolean locked
function Core.Vehicles.isLocked(veh) end
---(server) A vehId acts on its live car, else on the record's keys (a parked or garaged car).
---@param target integer|string a netId or a vehId
---@param charId string
---@return boolean ok
function Core.Vehicles.giveKeys(target, charId) end
---(server) A vehId acts on its live car, else on the record's keys.
---@param target integer|string a netId or a vehId
---@param charId string
---@return boolean ok
function Core.Vehicles.removeKeys(target, charId) end
---(client/server) Explicit virtual-key check. `keyMode = 'item'` vehicles intentionally answer false; their domain plugin validates a physical key then calls `setLocked`.
---@param veh integer client: an entity handle; server: the player's src
---@param netId? integer server only
---@return boolean
function Core.Vehicles.hasKeys(veh, netId) end
---(server) A vehId acts on its live car, else on the record (the virtual keys follow the owner).
---@param target integer|string a netId or a vehId
---@param charId string|nil nil clears the owner
---@return boolean ok
function Core.Vehicles.setOwner(target, charId) end
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
---(server) One indexed read, read-your-writes. Awaited. `{}` and `err` when the read failed — never mistake
---that for "no cars".
---@param charId string
---@return CoreVehicleRecord[]
---@return string|nil err set only on a failed read
function Core.Vehicles.getRecords(charId) end
---(server) Awaited.
---@param vehId string
---@return CoreVehicleRecord|nil
---@return string|nil err set only on a failed read (never for "no such record")
function Core.Vehicles.getRecord(vehId) end
---(server) Spawns a stored vehicle from its record. Awaited (one record read, then yields). A PARKED record is
---promoted where it stands instead (coords / heading / ownerSrc unused): the clone's netId after a bounded wait
---(SpawnTimeoutMs + 6 s).
---@param vehId string
---@param coords vector3
---@param heading? number
---@param ownerSrc? integer client the props are applied on
---@return integer|nil netId
---@return string|nil err 'already_spawned' | 'spawn_timeout' | 'promote_failed' | 'db' (the record read failed) | …
function Core.Vehicles.spawnRecord(vehId, coords, heading, ownerSrc) end
---(server) Restores one out-of-garage record at its saved or supplied world position. Awaited (one record read,
---then yields).
---@param vehId string
---@param coords? vector3 defaults to record.position
---@param heading? number defaults to record.position.heading
---@param ownerSrc? integer client that should receive the direct property replay
---@return integer|nil netId
---@return string|nil err 'parked' (a parked record is in the world as a scene node already) | 'destroyed' (a wreck: spawnRecord brings it back) | 'db' (the record read failed) | …
function Core.Vehicles.restoreRecord(vehId, coords, heading, ownerSrc) end
---(server) Promotes an existing network vehicle into a tracked, server-owned persistent vehicle.
---Trusted server-resource API only; no client event exposes it.
---@param netId integer
---@param opts CoreVehicleAdoptOptions
---@return string|nil vehId
---@return string|nil err 'scene_clone' for a Core.Scene clone (an entity with state `sn`) | …
function Core.Vehicles.adopt(netId, opts) end
---(server) Garages a vehicle: saves the last known position/props, then removes the entity from the world. A vehId
---also garages its live vehicle, its parked node, or a record with nothing in the world; a parked car's clone takes
---its node along.
---@param target integer|string a netId or a vehId
---@return boolean ok
function Core.Vehicles.store(target) end
---(server) Parks a persisted vehicle (§55.21.4): it becomes a persistent Core.Scene `vehicle` node owned by core —
---every client nearby shows a local copy, no networked entity exists — until a player tries to enter or damages it
---(authority { mode = 'local' }: no proximity promotion). A live car is handed over (no blink). Only the WEAR of the
---owner client's props read-back (≤ 1 s) is merged over the cached / record props (Core.Scene.mergeWear); the plate is
---the record's. A parked car's clone is demoted instead (refused with someone inside); a parked record answers its
---node. Past Config.Vehicles.MaxParked the longest-unused parked car is garaged (hook vehicleAutoStored). Yields.
---@param target integer|string a netId or a vehId
---@return integer|nil nodeId
---@return string|nil err 'unavailable' 'bad_target' 'missing' 'not_persisted' 'no_record' 'record_stored' 'destroyed' 'occupied' 'busy' 'gone' 'no_entity' 'bad_coords' 'db' | a Scene error
function Core.Vehicles.park(target) end
---(server) A record's vehicle whether it is live, parked or garaged: getInfo's fields (netId only while a vehicle is
---live — a promoted parked car's clone included) + parked (node id), stored, position, destroyed (a wreck). A
---record without a live car is read (awaited); nil, err when that failed.
---@param vehId string
---@return (CoreVehicleInfo|{ stored: boolean, position: table, destroyed: boolean })|nil
---@return string|nil err 'db' when the record read failed
function Core.Vehicles.getInfoByRecord(vehId) end
---(server) `saveProps(netId, props)` accepts a validated props table (the client route is
---`core:server:vehicleProps`). (client) `saveProps(veh)` sends the vehicle's current props.
---@param netId integer server: a netId; client: an entity handle
---@param props? CoreVehicleProps server only
---@return boolean ok
function Core.Vehicles.saveProps(netId, props) end
---(server) Deletes the record (a parked car's node goes with it).
---@param vehId string
---@return boolean removed
function Core.Vehicles.deleteRecord(vehId) end
---(server) Core-tracked vehicles within `range` of `coords`, nearest first.
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
---(server) Nearest core-tracked vehicle to the player's ped.
---@param src integer
---@param maxDist? number default 20.0
---@return integer|nil netId
function Core.Vehicles.getClosestToPlayer(src, maxDist) end
---(server) Writes one key of the persistence record's `meta` table (nil removes it). One atomic SQL UPDATE on
---`vehicles.meta` — awaited, it yields. Never write `meta` from a cached record (a concurrent `setData` would
---race it); returns true when the record exists and was written.
---@param target integer|string a netId or a vehId
---@param key string
---@param value any
---@return boolean ok
function Core.Vehicles.setData(target, key, value) end
---(server) One key of the record's `meta`, or the whole copied table when `key` is nil. One awaited SELECT — it
---yields.
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
---(client) `setProps` for a LOCAL (non-networked) vehicle this client created itself — a Core.Scene local copy
---(DESIGN §55.12, §6.8): the same apply at once, no network-control request, never yields (safe in a creation
---frame). On a networked vehicle this client does not control it only touches the local copy until the owner syncs.
---@param veh integer
---@param props CoreVehicleProps
---@return boolean ok false for a non-vehicle or a non-table
function Core.Vehicles.setPropsLocal(veh, props) end
---(client)
---@param veh integer
---@param on boolean
---@return boolean ok
function Core.Vehicles.setEngine(veh, on) end
---(client) Full local repair (needs network control).
---@param veh integer
---@return boolean ok
function Core.Vehicles.repair(veh) end
---(client) Asks the server to toggle the lock of a virtual-key `veh`, or the current/closest vehicle within
---8 m. Item-key vehicles intentionally no-op so their domain plugin can validate a physical inventory key.
---@param veh? integer
function Core.Vehicles.toggleLock(veh) end

--------------------------------------------------------------------------------
-- Core.Raycast (client/raycast.lua §6.9, §42, server/remote.lua §20)
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
---(client) §42: the world point under a screen position of the RENDERED camera, and the unit direction a
---probe leaves it in. Proxy call — a per-frame tool calls the natives in its own VM.
---@param fx number 0..1 of the game viewport (left → right)
---@param fy number 0..1 of the game viewport (top → bottom)
---@return vector3|nil origin nil when fx/fy are not finite numbers in 0..1
---@return vector3|nil direction nil as above, or when the native gave no direction
function Core.Raycast.screenToWorld(fx, fy) end
---(client) §42: where a world point lands on the rendered camera's screen.
---@param coords vector3
---@return boolean onScreen false behind/outside the camera or for invalid coords
---@return number|nil fx 0..1 (nil when not on screen)
---@return number|nil fy
function Core.Raycast.worldToScreen(coords) end
---(client) §42: probe from the rendered camera through a screen point (cursor picking under any camera).
---@param fx number 0..1
---@param fy number 0..1
---@param distance? number metres, 0 < d <= 5000 (default 1000)
---@param flags? integer intersect flags (default -1 = everything)
---@param ignore? integer entity the probe ignores (default 0)
---@return boolean hit
---@return vector3|nil coords nil when the arguments were refused (no probe cast)
---@return vector3|nil normal
---@return integer entity 0 when nothing was hit
function Core.Raycast.fromScreen(fx, fy, distance, flags, ignore) end
---(client) §42: probe straight out of the RENDERED camera (scripted cameras included).
---@param distance? number metres, 0 < d <= 5000 (default 1000)
---@param flags? integer intersect flags (default -1 = everything)
---@param ignore? integer entity the probe ignores (default 0 — unlike fromCamera)
---@return boolean hit
---@return vector3|nil coords nil when the arguments were refused (no probe cast)
---@return vector3|nil normal
---@return integer entity
function Core.Raycast.fromRenderedCamera(distance, flags, ignore) end
---(server) Shape test out of the player's camera, evaluated on that client. Yields.
---@param src integer
---@param distance? number default 10.0
---@return boolean hit
---@return vector3|nil coords
---@return integer entityNetId 0 when nothing networked was hit
function Core.Raycast.fromPlayer(src, distance) end

--------------------------------------------------------------------------------
-- Core.Interiors (client/interiors.lua §36) — (client) only
--------------------------------------------------------------------------------

---@class Core.Interiors
Core.Interiors = {}

---(client) Request one IPL; tracked under the caller, unloaded on plugin stop.
---@param ipl string
---@return boolean ok
function Core.Interiors.request(ipl) end
---(client) Remove one IPL the caller added. Base-set IPLs are refused (except to core).
---@param ipl string
---@return boolean ok
function Core.Interiors.remove(ipl) end
---(client) Whether an IPL is currently active.
---@param ipl string
---@return boolean active
function Core.Interiors.isActive(ipl) end
---(client) Activate an interior entity set at coords (resolves + refreshes). Yields up to 5 s.
---@param coords vector3
---@param set string
---@return boolean ok
function Core.Interiors.activateSet(coords, set) end
---(client) Deactivate an interior entity set at coords. Yields up to 5 s.
---@param coords vector3
---@param set string
---@return boolean ok
function Core.Interiors.deactivateSet(coords, set) end
---(client) Entity-set state; nil when no interior streams at coords.
---@param coords vector3
---@param set string
---@return boolean|nil active
function Core.Interiors.isSetActive(coords, set) end
---(client) Refresh the interior at coords. Yields up to 5 s.
---@param coords vector3
---@return boolean ok
function Core.Interiors.refreshAt(coords) end
---(client) Groups with their effective state (a copy).
---@return table list of { id, label, count, enabled, gated }
function Core.Interiors.listGroups() end

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
---(client) Teleport (DESIGN §6.1/§48): fade out → freeze → move → collision + map region
---(`Core.Maps.waitAreaReady`, ≤ 3 s) → heading → unfreeze unless sticky-frozen → sticky states
---re-applied → fade in. Yields.
---@param coords vector3
---@param heading? number
---@param opts? CoreTeleportOptions `withVehicle` (driver only, ≤ 1 s network-control request) and `fade`; `bucket` is ignored client-side
function Core.Spawn.teleport(coords, heading, opts) end

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
---(server) A run already in flight finishes. Owner-checked (like Hooks.remove): only the job's owner or core
---may remove it; the owner-stop sweep still removes a stopped plugin's jobs.
---@param id string
---@return boolean removed false when the job is not the caller's
function Core.Cron.remove(id) end
---(server) Every job in creation order.
---@return CoreCronEntry[]
function Core.Cron.list() end

--------------------------------------------------------------------------------
-- Core.DB (lib/db/server.lua, DESIGN §56) — (server) only, a LIB in every server VM that calls the
-- `core_db` resource directly. AWAITED calls yield (coroutine only) and answer `result` or `nil, err`
-- (a failed read is never an empty result); QUEUED calls never yield and commit within one flush.
--------------------------------------------------------------------------------

---@class Core.DB
---@field NULL table sentinel for SQL NULL in params, values and where maps
Core.DB = {}

---@class CoreDBOpts
---@field timeout? number ms (default 30000)
---@field sync? boolean read your own queued writes first

---@class CoreDBSelectOpts: CoreDBOpts
---@field columns? string[]
---@field orderBy? string 'col [ASC|DESC] [NULLS FIRST|LAST], …' (columns are checked)
---@field limit? integer
---@field offset? integer

---@class CoreDBStreamOpts: CoreDBOpts
---@field batch? integer rows per fn call (default 500, max 10000)

---@class CoreDBTx transaction handle: the awaited raw-SQL calls and table helpers on one connection
---@field query fun(sql: string, params?: any[]): table[]|nil, string?
---@field single fun(sql: string, params?: any[]): table|nil, string?
---@field scalar fun(sql: string, params?: any[]): any, string?
---@field execute fun(sql: string, params?: any[]): integer|nil, string?
---@field insert fun(tbl: string, values: table, opts?: table): table|boolean|nil, string?
---@field select fun(tbl: string, where?: table, opts?: CoreDBSelectOpts): table[]|nil, string?
---@field first fun(tbl: string, where?: table, opts?: CoreDBSelectOpts): table|nil, string?
---@field count fun(tbl: string, where?: table): integer|nil, string?
---@field update fun(tbl: string, set: table, where: table): integer|nil, string?
---@field delete fun(tbl: string, where: table): integer|nil, string?
---@field upsert fun(tbl: string, values: table, conflict: string|string[], opts?: table): table|boolean|nil, string?

---(server, awaited) Rows of one statement (`$1 … $n` placeholders).
---@param sql string
---@param params? any[] `Core.DB.NULL` for NULL; `Core.DB.json(t)` + `$n::jsonb` for jsonb
---@param opts? CoreDBOpts
---@return table[]|nil rows
---@return string|nil err
function Core.DB.query(sql, params, opts) end
---(server, awaited) The first row, or (nil, nil) when there is none.
---@param sql string
---@param params? any[]
---@param opts? CoreDBOpts
---@return table|nil row
---@return string|nil err
function Core.DB.single(sql, params, opts) end
---(server, awaited) The first column of the first row (one-column queries).
---@param sql string
---@param params? any[]
---@param opts? CoreDBOpts
---@return any value
---@return string|nil err
function Core.DB.scalar(sql, params, opts) end
---(server, awaited) Affected row count of an INSERT/UPDATE/DELETE.
---@param sql string
---@param params? any[]
---@param opts? CoreDBOpts
---@return integer|nil rowCount
---@return string|nil err
function Core.DB.execute(sql, params, opts) end
---(server, awaited) Several statements in ONE transaction and one hop.
---@param statements table[] `{ { sql, params }, … }`
---@param opts? { rows?: boolean, timeout?: number }
---@return table[]|nil results `{ rowCount, rows? }` per statement
---@return string|nil err
function Core.DB.batch(statements, opts) end
---(server, awaited) Runs `fn(tx)` on one connection; commits when it returns, rolls back when it returns
---false, throws or a statement failed.
---@param fn fun(tx: CoreDBTx): any
---@param opts? { timeout?: number } the transaction deadline in ms (default 10000, max 60000)
---@return boolean ok
---@return any resultOrErr
function Core.DB.transaction(fn, opts) end
---(server, awaited) Server-side cursor: `fn(rows)` per batch, one batch per tick; `fn` returning false stops.
---@param sql string
---@param params? any[]
---@param fn fun(rows: table[]): boolean|nil
---@param opts? CoreDBStreamOpts
---@return integer|nil total
---@return string|nil err
function Core.DB.stream(sql, params, fn, opts) end
---(server, awaited) An atomic counter (`core_counters`).
---@param name string
---@return integer|nil next
---@return string|nil err
function Core.DB.nextId(name) end
---(server, awaited) Waits until everything queued before the call was committed.
---@param timeoutMs? number
---@return boolean ok false, 'dropped:<n>' when queued entries were dropped
---@return string|nil err
function Core.DB.flush(timeoutMs) end
---(server, awaited) Inserts one row; answers it (RETURNING *) or true with `opts.returning = false`.
---@param tbl string
---@param values table column → value (nil = default, `Core.DB.NULL` = NULL)
---@param opts? { returning?: string[]|false, timeout?: number }
---@return table|boolean|nil row
---@return string|nil err
function Core.DB.insert(tbl, values, opts) end
---(server, awaited) Inserts many rows in one statement.
---@param tbl string
---@param rows table[]
---@return integer|nil count
---@return string|nil err
function Core.DB.insertMany(tbl, rows) end
---(server, awaited) `where`: `{ col = v }`, `{ col = { a, b } }` (ANY), `{ col = Core.DB.NULL }`, `{ col = Core.DB.op('>=', v) }`.
---@param tbl string
---@param where? table
---@param opts? CoreDBSelectOpts
---@return table[]|nil rows
---@return string|nil err
function Core.DB.select(tbl, where, opts) end
---(server, awaited) The first matching row, or (nil, nil).
---@param tbl string
---@param where? table
---@param opts? CoreDBSelectOpts
---@return table|nil row
---@return string|nil err
function Core.DB.first(tbl, where, opts) end
---(server, awaited)
---@param tbl string
---@param where? table
---@param opts? CoreDBOpts
---@return integer|nil count
---@return string|nil err
function Core.DB.count(tbl, where, opts) end
---(server, awaited) `where` must be non-empty.
---@param tbl string
---@param set table
---@param where table
---@return integer|nil rowCount
---@return string|nil err
function Core.DB.update(tbl, set, where) end
---(server, awaited) `where` must be non-empty.
---@param tbl string
---@param where table
---@return integer|nil rowCount
---@return string|nil err
function Core.DB.delete(tbl, where) end
---(server, awaited) INSERT … ON CONFLICT (conflict) DO UPDATE SET (opts.update or every other given column).
---@param tbl string
---@param values table
---@param conflict string|string[]
---@param opts? { update?: string[], returning?: string[]|false }
---@return table|boolean|nil row
---@return string|nil err
function Core.DB.upsert(tbl, values, conflict, opts) end
---(server, queued) Upsert by primary key (full row); coalesced per row; never yields.
---@param tbl string
---@param row table
---@return boolean ok
---@return string|nil err validation only
function Core.DB.save(tbl, row) end
---(server, queued) UPDATE of `changes` for the row with primary key `key` (value, or `{ col = v }` for a composite key).
---@param tbl string
---@param key any
---@param changes table
---@return boolean ok
---@return string|nil err
function Core.DB.patch(tbl, key, changes) end
---(server, queued) DELETE by primary key.
---@param tbl string
---@param key any
---@return boolean ok
---@return string|nil err
function Core.DB.remove(tbl, key) end
---(server, queued) Plain INSERT (logs, histories); never coalesced.
---@param tbl string
---@param row table
---@return boolean ok
---@return string|nil err
function Core.DB.append(tbl, row) end
---(server, queued) One raw statement in queue order; `key` makes a newer statement with the same key replace it.
---@param sql string
---@param params? any[]
---@param key? string|number
---@return boolean ok
---@return string|nil err
function Core.DB.enqueue(sql, params, key) end
---(server) Registers the calling resource's migrations (file scope, non-blocking): `'sql/0001_init.sql'` paths
---in the resource, or `{ version, name?, sql | file }`. The resource's later queries wait for them.
---@param list (string|table)[]
---@return boolean ok
---@return string|nil err
function Core.DB.migrate(list) end
---(server, awaited) Waits until the calling resource's migrations are applied.
---@param timeoutMs? number default 60000
---@return boolean ok
---@return string|nil err
function Core.DB.awaitMigrations(timeoutMs) end
---(server, awaited) Health, pool, queue counters, applied migrations per owner.
---@return table|nil status
---@return string|nil err
function Core.DB.status() end
---(server) Last known connection health (synchronous, no yield).
---@return boolean
function Core.DB.isHealthy() end
---(server) A WHERE condition: `= <> < <= > >= like ilike not_like in not_in between is_null not_null contains overlaps`.
---@param name string
---@param value any
---@param value2? any
---@return table condition
function Core.DB.op(name, value, value2) end
---(server) JSON text for a `$n::jsonb` raw param.
---@param value any
---@return string
function Core.DB.json(value) end
---(server) The SQLSTATE ('23505') or the leading word ('timeout', 'unavailable', 'invalid', …) of an error.
---@param err string|nil
---@return string|nil
function Core.DB.errorCode(err) end

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
-- Core.Perms (server/perms.lua §4.4, §22, §44) — (server) only
--------------------------------------------------------------------------------

---@alias CorePermsChange 'grant'|'revoke'|'group'|'grants'|'saveGroup'|'deleteGroup'|'define'|'expired'|'load' 'group'/'grants' also come from Player.setGroup/setAccountData

---@class CorePermDef
---@field perm string
---@field label string
---@field description? string
---@field category string default: the perm's prefix before the first '.'
---@field owner string the defining resource
---@field default? string group that receives the grant once

---@class CorePermGroup
---@field name string
---@field label string
---@field weight integer
---@field inherits string[]
---@field perms string[] the group's own list (not the resolved chain)
---@field color? string '#rrggbb'

---@class CorePermExplain
---@field allowed boolean
---@field via? 'console'|'ace'|'account'|'character'|string 'group:<name>' names the group that lists the perm
---@field group? string the player's group
---@field expiresAt? integer unix seconds, when the deciding grant is temporary

---@class Core.Perms
Core.Perms = {}

---(server) Checked in order: console (src 0) → ACE → account grants → character grants (running
---temporary grants included) → the group chain from `perm_groups` (§44: own list, then `inherits`;
---'core.admin' in the chain still implies everything the admin group lists).
---@param src integer
---@param perm string
---@return boolean
function Core.Perms.has(src, perm) end
---(server)
---@param src integer
---@return string group
function Core.Perms.getGroup(src) end
---(server) Moves the player to another group (persisted on the account); emits `permsChanged(src, 'group')`.
---@param src integer
---@param group string must exist in the `perm_groups` collection (Perms.groupExists)
---@return boolean ok
function Core.Perms.setGroup(src, group) end
---(server) `has(src, 'core.admin')`.
---@param src integer
---@return boolean
function Core.Perms.isAdmin(src) end
---(server) Grants a permission; idempotent. `opts.expiresAt` (unix seconds, future, ≤ 10 years) makes it
---temporary (stored in `tempPermissions`, ignored once expired, pruned by a timer and on load).
---@param src integer
---@param perm string
---@param scope? CorePermScope default 'account'
---@param opts? { expiresAt?: integer }
---@return boolean ok
function Core.Perms.grant(src, perm, scope, opts) end
---(server) Removes the permanent and the temporary grant.
---@param src integer
---@param perm string
---@param scope? CorePermScope default 'account'
---@return boolean removed
function Core.Perms.revoke(src, perm, scope) end
---(server) Group chain + account grants + character grants (running temporary ones included), deduped.
---ACE permissions cannot be enumerated and are not part of the list.
---@param src integer
---@return string[]
function Core.Perms.list(src) end
---(server) True when the group exists in `perm_groups`.
---@param name string
---@return boolean
function Core.Perms.groupExists(name) end
---(server) Catalogue entry, owner-tracked (kind 'permDef'). The first owner keeps a perm; `default` is
---granted to that group once — never again after an owner removed it.
---@param perm string
---@param opts? { label?: string, description?: string, category?: string, default?: string }
---@return boolean ok
function Core.Perms.define(perm, opts) end
---(server) Every defined permission, sorted by category then name.
---@return CorePermDef[]
function Core.Perms.catalogue() end
---(server) Every group, sorted by weight then name.
---@return CorePermGroup[]
function Core.Perms.groups() end
---(server) Create or edit a group (`perms` is the full own list). With `actorSrc`: needs 'core.perms.manage'
---and never touches, creates or inherits from a group weighted above the actor. `actorSrc = nil` is core
---itself (no checks) — a plugin acting for a player passes the player's src. Errors: invalid_name,
---invalid_patch, invalid_actor, not_ready, no_permission, invalid_label, invalid_weight, invalid_color,
---invalid_inherits, unknown_group, cycle, invalid_perms, rank, save_failed.
---@param name string
---@param patch { label?: string, weight?: integer, inherits?: string[], perms?: string[], color?: string|'' }
---@param actorSrc? integer
---@return boolean ok
---@return string|nil err
function Core.Perms.saveGroup(name, patch, actorSrc) end
---(server) Errors: invalid_name, protected ('user'), invalid_actor, not_ready, unknown_group, no_permission,
---rank, inherited (another group inherits it), in_use (a member is online), save_failed.
---@param name string
---@param actorSrc? integer
---@return boolean ok
---@return string|nil err
function Core.Perms.deleteGroup(name, actorSrc) end
---(server) Console math.huge; no session / invalid src 0; otherwise the group's weight.
---@param src integer
---@return number
function Core.Perms.getWeight(src) end
---(server) Console or self: true; otherwise weight(actor) > weight(target). Reasons: invalid_actor,
---invalid_target, rank.
---@param actorSrc integer
---@param targetSrc integer
---@return boolean ok
---@return string|nil reason
function Core.Perms.canTarget(actorSrc, targetSrc) end
---(server) { [perm] = true } of `list`; the console gets every catalogued and group-listed perm.
---@param src integer
---@return table<string, true>
function Core.Perms.effective(src) end
---(server) Why `has` answers what it does (same order).
---@param src integer
---@param perm string
---@return CorePermExplain
function Core.Perms.explain(src, perm) end

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
---(server) Perm `manage`. Yields (one awaited UPDATE, §56).
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
---(server) Whether a weapon name passes core's name rule and `Config.Weapons.Allowed` (the legacy /weapon uses it).
---@param weapon string
---@return boolean
function Core.Weapons.isAllowed(weapon) end

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

---(server) Attaches a prop to the player's ped; an entry with the same id is replaced (its node changes in place).
---Persisted in `data.attachments`; every entry is ONE Core.Scene `prop` node owned by core, attached to the player
---(§55.21.3), so every client near him shows it and it follows respawns, model swaps and bucket changes. While the
---scene store loads, the ped has not reached the server or the scene is FULL ('limit'), the entry is stored, its id
---returned, and its node follows (retry thread; a full scene: 5 s backoff doubling to 60 s).
---@param src integer
---@param def CoreAttachmentDef
---@return string|nil id
---@return string|nil err 'no session' | 'too many attachments' (12) | a validation message | 'scene refused the prop (<code>)' (any other refusal)
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
---(server) Registers a chat channel and its command. Built-ins: local, ooc, faction, me, a, pm.
---@param name string
---@param def CoreChatChannel
---@return boolean ok
function Core.Chat.registerChannel(name, def) end
---(server) Wipes one player's CEF feed (§23).
---@param src integer
---@return boolean ok
function Core.Chat.clear(src) end
---(server) The TAB completer's channel half (§23): every channel `src` may use, as
---{ command, channel, description, params = { { name, help, type, optional } } }.
---@param src integer
---@return table[]
function Core.Chat.suggestions(src) end
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
---(server) True when `src` is in a Core.Admin mode that sanctions the anomaly `what` (§51):
---'invisible' (vanish/noclip/spectate/editor), 'collision' and 'teleport' (noclip/spectate/editor),
---'god' (god/noclip/spectate/editor), 'speed' (noclip/editor); unknown anomalies are never exempt.
---`report` consults it for every kind.
---@param src integer
---@param what string
---@return boolean
function Core.Security.isStaffExempt(src, what) end

--------------------------------------------------------------------------------
-- Core.PlayerGrid (server/playergrid.lua §22.1) — internal spatial index
--------------------------------------------------------------------------------

---The server-side player grid behind `Player.getInRange`/`getClosest` and chat's proximity routes.
---Internal: blocked in the export like `Core.Registry`, so a plugin uses the getters instead.
---@class Core.PlayerGrid
Core.PlayerGrid = {}

---(server, internal) Fills `out[1..count]` with the srcs near `coords`; the stale tail is left
---behind on purpose, so use the returned count. The caller still tests the exact distance.
---@param coords vector3
---@param range number
---@param out table reusable array, written from index 1
---@return integer count
function Core.PlayerGrid.candidates(coords, range, out) end
---(server, internal) How many players the grid holds; 0 means the full-loop fallback.
---@return integer
function Core.PlayerGrid.count() end
---(server, internal) The cell key of `src`, or nil. Tests and debug.
---@param src integer
---@return integer|nil
function Core.PlayerGrid.cellOf(src) end

--------------------------------------------------------------------------------
-- Core.Registry (server/api.lua + client/api.lua §2.3) — internal bookkeeping
--------------------------------------------------------------------------------

---Owner tracking behind the automatic cleanup on `onResourceStop`. Plugins do not need this:
---every registration API already tracks the calling resource.
---@class Core.Registry
Core.Registry = {}

---(internal) Sets the RUNNING COROUTINE's caller (the process-wide value only on the main thread). The `call`
---export dispatches through `withCaller(owner, fn, ...)`.
---@param name string|nil
function Core.Registry.setCaller(name) end
---(internal) The resource whose call is being served. Per coroutine since 2026-09-26: a coroutine without its
---own entry is 'core' (a thread core starts never inherits a parked plugin call); the global value is only the
---main-thread fallback (resource load, offline suites).
---@return string
function Core.Registry.getCaller() end
---(internal) Runs `fn(...)` with `owner` as the running coroutine's caller and restores it (also after an error).
---@param owner string
---@param fn function
---@return boolean ok, any ... pcall results
function Core.Registry.withCaller(owner, fn, ...) end
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

--------------------------------------------------------------------------------
-- Development services (DESIGN §40)
--------------------------------------------------------------------------------

---@class CoreControlOptions
---@field controls? integer[] input control IDs, 0..360 (the list form)
---@field all? boolean the whole group: DisableAllControlActions + one EnableControlAction per `except` (a camera
---mode: ~5 natives per frame). Several handles on one group: `all` wins; a control stays enabled only when EVERY
---`all` handle excepts it and no list handle disables it. Limit: re-enabling an exception can undo another
---resource's disable of that control if theirs ran earlier in the frame.
---@field except? integer[] with `all`: controls left enabled (e.g. 199, 200, 245, 246, 249 — pause, chat, PTT)
---@field groups? integer[] input groups, default {0}
---@class Core.Controls
Core.Controls = {}
---(client) Acquires an owner-scoped restriction handle. Register inside onReady.
---@param options CoreControlOptions
---@return string|nil
function Core.Controls.acquire(options) end
---(client) Releases only the calling owner's handle.
---@param handle string
---@return boolean
function Core.Controls.release(handle) end
---(client) Releases all restrictions owned by the caller.
function Core.Controls.releaseAll() end

---@class CoreActionProp
---@field model string|integer
---@field bone? integer ped bone ID
---@field offset? vector3
---@field rotation? vector3
---@class CoreActionOptions: CoreProgressOptions
---@field animation? {dict:string,clip:string,flag?:integer}
---@field scenario? string mutually exclusive with animation
---@field props? CoreActionProp[] cosmetic, local objects
---@field disable? integer[] restricted controls while running
---@field allowDead? boolean default false
---@field allowFalling? boolean default false
---@field allowSwimming? boolean default false
---@field allowRagdoll? boolean default false
---@class Core.Actions
Core.Actions = {}
---(client) Runs one managed progress activity; completion is not server authority.
---@param options CoreActionOptions
---@return boolean completed
---@return string reason
function Core.Actions.run(options) end
---(client) Cancels the calling owner's active activity.
---@return boolean
function Core.Actions.cancel() end
---(client) Whether any managed activity is running.
---@return boolean
function Core.Actions.isActive() end

---@class CoreShapeDefinition
---@field type 'sphere'|'box'|'polygon'
---@field coords? vector3
---@field radius? number sphere radius
---@field size? vector3 box dimensions
---@field rotation? number box heading in degrees
---@field points? vector3[] polygon vertices
---@field minZ? number polygon floor
---@field maxZ? number polygon ceiling
---@class Core.Geometry
Core.Geometry = {}
---Pure shared lib: validates and snapshots geometry; no native calls or export hop.
---@param definition CoreShapeDefinition
---@return table|nil shape
---@return string|nil error
function Core.Geometry.normalize(definition) end
---Pure shared lib: inclusive boundary containment using normalized geometry.
---@param shape table
---@param coords vector3
---@return boolean
function Core.Geometry.contains(shape, coords) end

---@class CoreZoneOptions: CoreShapeDefinition
---@field onEnter? fun(id:string)
---@field onExit? fun(id:string)
---@field debug? boolean
---@class Core.Zones
Core.Zones = {}
---(client) Adds owner-scoped geometry with proximity callbacks; register inside onReady.
---@param options CoreZoneOptions
---@return string|nil id
function Core.Zones.add(options) end
---(client) Removes the calling owner's zone.
---@param id string
---@return boolean
function Core.Zones.remove(id) end
---(client) Removes all calling-owner zones.
function Core.Zones.removeAll() end
---(client) Tests an owner's zone. Server validation uses the shared Geometry lib instead.
---@param id string
---@param coords vector3
---@return boolean
function Core.Zones.contains(id, coords) end

---@class CorePointOptions
---@field coords vector3
---@field distance number
---@field interval? integer nearby callback period in ms; never per-frame across exports
---@field onEnter? fun(id:string,distance:number)
---@field onExit? fun(id:string,distance:number)
---@field nearby? fun(id:string,distance:number)
---@class Core.Points
Core.Points = {}
---(client) Adds an owner-scoped proximity point; register inside onReady.
---@param options CorePointOptions
---@return string|nil id
function Core.Points.add(options) end
---(client) Removes the calling owner's point.
---@param id string
---@return boolean
function Core.Points.remove(id) end
---(client) Removes all calling-owner points.
function Core.Points.removeAll() end

---@class CorePlayerContext
---@field ped integer
---@field vehicle integer 0 on foot
---@field seat integer|nil -1 driver; nil on foot
---@field weapon integer

---(client) Proxy: Returns a detached snapshot of the single local context cache.
---@return CorePlayerContext
function Core.Player.context() end
---(client) Proxy: Subscribes to a cached value; register inside onReady. Not server authority.
---@param key 'ped'|'vehicle'|'seat'|'weapon'
---@param fn fun(value:any,previous:any)
---@return string|nil handle
function Core.Player.onContextChange(key, fn) end
---(client) Proxy: Removes the caller's context subscription.
---@param handle string
---@return boolean
function Core.Player.offContextChange(handle) end

---(client) Lib: Bounded texture dictionary load; false on invalid input/timeout.
---@param name string
---@param timeoutMs? integer
---@return boolean
function Core.Streaming.requestTextureDict(name, timeoutMs) end
---(client) Lib:
---@param name string
function Core.Streaming.releaseTextureDict(name) end
---(client) Lib: Returns the loaded movie handle, nil on failure.
---@param name string
---@param timeoutMs? integer
---@return integer|nil
function Core.Streaming.requestScaleform(name, timeoutMs) end
---(client) Lib:
---@param handle integer
function Core.Streaming.releaseScaleform(handle) end
---(client) Lib: Loads a script audio bank; false on failure.
---@param name string
---@param timeoutMs? integer
---@return boolean
function Core.Streaming.requestAudioBank(name, timeoutMs) end
---(client) Lib:
---@param name string
function Core.Streaming.releaseAudioBank(name) end
---(client) Lib:
---@param weapon string|integer
---@param timeoutMs? integer
---@return boolean
function Core.Streaming.requestWeaponAsset(weapon, timeoutMs) end
---(client) Lib:
---@param weapon string|integer
function Core.Streaming.releaseWeaponAsset(weapon) end

---@class CoreHookPipelineOptions
---@field priority? integer lower values run first
---@field filter? fun(payload:table):boolean false skips callback
---@field after? boolean observer runs after decision, receives payload, allowed, reason
---@class Core.Hooks
Core.Hooks = {}
---Registers an owner-scoped synchronous pipeline callback; callbacks must not yield.
---Return false, reason to veto. Failures fail closed; existing Core.on is unchanged.
---Core's own pipelines: 'money:beforeTransfer', 'chat:beforeMessage', 'admin:before', 'maps:beforeApply',
---'scene:beforeSpawn'.
---@param name CoreHookPipeline|string
---@param callback fun(payload:table,allowed?:boolean,reason?:string):boolean?,string?
---@param options? CoreHookPipelineOptions
---@return string|nil handle
function Core.Hooks.register(name, callback, options) end
---Removes only the caller's registration.
---@param handle string
---@return boolean
function Core.Hooks.remove(handle) end
---Runs a deterministic pipeline. Each callback receives a detached snapshot.
---@param name CoreHookPipeline|string
---@param payload table
---@return boolean allowed
---@return string|nil reason
function Core.Hooks.run(name, payload) end

---@class CoreSkillCheckOptions
---@field difficulty ('easy'|'medium'|'hard'|{speed:number,areaSize:number})[] 1..20 stages; speed20..200 percent/sec, areaSize5..80 percent
---@field keys? string[] 1..10 single alphanumeric or space keys; default {'e'}; cycled per stage
---@field canCancel? boolean default true
---@class Core.UI.skillCheck
---@overload fun(options:CoreSkillCheckOptions):boolean (client) awaits a presentation-only skill check
local CoreUISkillCheck = {}
---(client) Cancels only the caller's active skill check.
---@return boolean
function CoreUISkillCheck.cancel() end
---(client) Reports whether any skill check is currently active.
---@return boolean
function CoreUISkillCheck.isActive() end

--------------------------------------------------------------------------------
-- Admin platform (DESIGN §41–§53). §41 input modes → CorePageOptions / Core.UI.setInput;
-- §42 → Core.Raycast; §44 → Core.Perms + Core.Callback opts; §48 → Core.Player / Core.Spawn;
-- §49 → Core.Player.resolveTargets + CoreCommandParam; §51's exemption → Core.Security.
-- The namespaces below are new.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Core.Schema (lib/schema/shared.lua §43) — (shared), pure, compiled into the caller's VM
--------------------------------------------------------------------------------

---@alias CoreSchemaType 'boolean'|'integer'|'number'|'string'|'text'|'password'|'reason'|'enum'|'array'|'object'|'color'|'duration'|'vector3'|'heading'|'rotation'|'model'|'player'|'ref'|'faction'|'item'

---@class CoreSchemaField
---@field name? string `^[%a_][%w_]*$`, <= 48; required inside a list
---@field type CoreSchemaType
---@field label? string
---@field description? string
---@field default? any validated against the field (built-in checks) when the field is normalised
---@field required? boolean nil or '' fails with 'required' (never for a field hidden by visibleWhen)
---@field placeholder? string
---@field group? string
---@field order? number
---@field hidden? boolean
---@field readonly? boolean
---@field unit? string
---@field icon? string UI only, <= 32 bytes (CoreSchemaForm)
---@field secret? boolean public() drops the default
---@field visibleWhen? { field: string, equals?: any, in?: any[] }
---@field persistDefault? boolean default true: checkAll fills a missing value with the default
---@field validate? fun(value: any, all: table|nil): boolean, string? server side; kept in a private slot, never in the field
---@field min? number integer/number/vector3 (per component)/duration
---@field max? number
---@field step? number integer/number: the value lies on the grid from `min or 0`
---@field minLength? integer string family: default 0 (reason: 3)
---@field maxLength? integer string family: default 256, cap 4096
---@field pattern? string a Lua pattern
---@field patternMessage? string UI only
---@field rows? integer text only: textarea rows, 2..20 (UI only)
---@field templates? string[] reason: UI presets, up to 32
---@field options? (string|number|boolean|{ value: any, label?: string, description?: string, icon?: string })[] enum: 1..200
---@field multiple? boolean enum: the value is an array of option values
---@field items? CoreSchemaField array: the element field
---@field minItems? integer
---@field maxItems? integer array: default and cap 1000
---@field fields? CoreSchemaField[] object: exactly these keys, nesting <= 4
---@field alpha? boolean color: also '#RRGGBBAA'
---@field allowPermanent? boolean duration: 0 = permanent always passes
---@field presets? integer[] duration: <= 12 quick picks in seconds (UI only); 0 needs allowPermanent, others within min/max
---@field world? boolean vector3: x,y within ±10000, z within -1000..3000
---@field kinds? ('prop'|'vehicle'|'ped'|'weapon')[] model
---@field refType? string ref

---@class Core.Schema
Core.Schema = {}

---(shared) Normalised copy of one definition. Unknown keys are dropped. Errors name the bad key
---('type', 'min', 'options', 'depth', 'default:<err>', 'items.<err>', 'fields.<name>.<err>').
---@param def CoreSchemaField
---@return CoreSchemaField|nil field
---@return string|nil err
function Core.Schema.field(def) end
---(shared) 1..64 named fields with unique names; visibleWhen must name a sibling.
---@param list CoreSchemaField[]
---@return CoreSchemaField[]|nil fields
---@return string|nil err 'count' | 'duplicate:<name>' | '<name>.<err>'
function Core.Schema.fields(list) end
---(shared) Checks type, then range/pattern, then the custom validate. Never coerces a type. The returned value is
---normalised: a fresh table for tables, heading in [0, 360), whole floats as integers.
---Errors: 'required' 'type' 'min' 'max' 'step' 'pattern' 'option' 'length' 'items' 'custom:<text>'; nested ones
---carry a path, '<index|name>.<err>'.
---@param field CoreSchemaField
---@param value any
---@return boolean ok
---@return any valueOrErr
function Core.Schema.check(field, value) end
---(shared) Checks a whole value table. Unknown keys fail with errs[key] = 'unknown'. A missing value gets its
---default, otherwise 'required'. `partial` checks only the keys that are present. A non-table fails with errs['*'] = 'type'.
---@param fields CoreSchemaField[]
---@param values table|nil
---@param opts? { partial?: boolean }
---@return boolean ok
---@return table outOrErrs
function Core.Schema.checkAll(fields, values, opts) end
---(shared) Deep copy of the field's default, or nil.
---@param field CoreSchemaField
---@return any
function Core.Schema.default(field) end
---(shared) JSON-safe copies for the UI: no functions, no secret defaults. A single field comes back as a one-element array.
---@param fields CoreSchemaField[]|CoreSchemaField
---@return table[]|nil
---@return string|nil err
function Core.Schema.public(fields) end

--------------------------------------------------------------------------------
-- Core.Settings (server/settings.lua + client/settings.lua §45) — (server); (client) get only
--------------------------------------------------------------------------------

---@class CoreSettingProperty: CoreSchemaField
---@field scope? 'server' only 'server' is implemented; any other value is refused ('scope')
---@field edit? string permission for set/reset with an actor (default 'core.admin')
---@field view? string permission to see it in list(viewer) (default 'core.settings.view')
---@field replicate? boolean mirrored to GlobalState['cs:<key>'], readable on clients (never with `secret`)
---@field restart? boolean UI hint: the owner only reads it at start
---@field deprecated? boolean UI hint
---@field config? any the plugin's config value; beats the default. If it fails the field, a warning is logged and the default is used

---@class CoreSettingsSection
---@field id string `^[%a_][%w_]*$`, <= 32
---@field title? string defaults to id
---@field icon? string
---@field order? number
---@field properties table<string, CoreSettingProperty> keys '<id>.<segment>(.<segment>)*', <= 64 bytes, 1..128 of them

---@class CoreSettingInspect
---@field key string
---@field value any effective value (secret: '••••')
---@field default any
---@field config any
---@field override any the stored override, even when it no longer validates and is ignored
---@field source 'default'|'config'|'override'
---@field updatedAt? integer
---@field by? table { kind = 'player'|'console'|'resource', src?, accountId?, name?, resource? }
---@field secret? boolean
---@field owner string

---@class Core.Settings
Core.Settings = {}

---(server) Declares a section, or replaces it when the same owner defines it again. Owner-tracked (kind 'settings').
---Errors: 'def' 'id' 'title' 'icon' 'order' 'properties' 'owner' 'key:<key>' 'owner:<key>' '<key>:<schema or setting err>'
---('<key>:scope', '<key>:secret_replicate', '<key>:edit', ...).
---@param section CoreSettingsSection
---@return boolean ok
---@return string|nil err
function Core.Settings.define(section) end
---(server) Effective value: override, then config, then default (tables deep-copied); nil for an undefined key.
---May yield once while the overrides load on an async DB backend.
---(client) The replicated value (replicate = true keys only), read from GlobalState.
---@param key string
---@return any
function Core.Settings.get(key) end
---(server) Validates and stores an override. With `actorSrc` (0 = console) the actor needs the property's `edit`
---permission; a refusal is audited as 'denied'. Errors: 'key' 'actor' 'reason' 'unavailable' 'unknown' <Schema error>
---'recursive' 'permission' 'persist'.
---@param key string
---@param value any
---@param actorSrc? integer
---@param reason? string <= 256
---@return boolean ok
---@return string|nil err
function Core.Settings.set(key, value, actorSrc, reason) end
---(server) Deletes the override. Returns true when there was none. Same permission rules and errors as set.
---@param key string
---@param actorSrc? integer
---@param reason? string
---@return boolean ok
---@return string|nil err
function Core.Settings.reset(key, actorSrc, reason) end
---(server) Every layer of one key; secret values masked. nil for an undefined key.
---@param key string
---@return CoreSettingInspect|nil
function Core.Settings.inspect(key) end
---(server) Sections sorted by order then id. Each property is Schema.public(field) plus key, name (= key), value,
---source, modified, config, scope, section, edit, view, replicate, restart, deprecated and editable. With
---`viewerSrc`, only properties that viewer may `view` are listed; secrets are masked as '••••'.
---@param viewerSrc? integer
---@return table[] sections { id, title, icon, order, owner, properties }
function Core.Settings.list(viewerSrc) end
---(server) fn(key, new, old) for every change of a key that starts with `prefix` ('' = all). Runs in a new thread
---after persist and only when the effective value changed. Errors are logged. Owner-swept (kind 'settingsWatch').
---@param prefix string
---@param fn fun(key: string, new: any, old: any)
---@return integer|nil handle
function Core.Settings.onChange(prefix, fn) end
---(server) Removes a watcher; only its owner (or core) may.
---@param handle integer
---@return boolean removed
function Core.Settings.offChange(handle) end
---(server, internal) Are the stored overrides in memory? False while the first load is out or failed — every
---value answered meanwhile is config/default. Blocked through the export.
---@return boolean
function Core.Settings.isLoaded() end
-- Core's own sections: maps.limits.{elements,perModel,uniqueModels,networked,networkedTotal,opsPerApply},
-- maps.journalMax, maps.journalMaxOps (§52); audit.retentionDays, audit.maxRows, audit.logMaxRows (§46);
-- bans.tokenMatches, bans.enrichTokens, bans.enrichIdentifiers, bans.failClosed (§47).
-- Client hook: Core.on('settingChanged', fn(key, new, old)).

--------------------------------------------------------------------------------
-- Core.Audit (server/audit.lua §46) / Core.Bans (server/bans.lua §47) — (server) only
--------------------------------------------------------------------------------

---@class CoreAuditActor
---@field kind 'player'|'console'|'system'
---@field src? integer
---@field accountId? string
---@field name? string
---@field group? string

---@class CoreAuditTarget
---@field type string 'player'|'account'|'vehicle'|'entity'|'map'|'setting'|'ban'|'group'|… (`^[%w_%-]+$`, <= 32)
---@field id string|integer
---@field name? string
---@field accountId? string added for player targets

---@class CoreAuditChange
---@field key string
---@field old any scalars stay, strings/tables are stringified (<= 256)
---@field new any

---@class CoreAuditRow
---@field id string sortable: 'a' .. 13-digit ms .. 3-digit sequence
---@field ts integer wall-clock milliseconds
---@field actor CoreAuditActor
---@field action string
---@field source 'menu'|'palette'|'chat'|'console'|'editor'|'api'|'core'
---@field resource string the calling resource
---@field targets? CoreAuditTarget[]
---@field changes? CoreAuditChange[]
---@field reason? string
---@field ctx? table
---@field result 'ok'|'denied'|'error'
---@field message? string

---@class CoreAuditInput
---@field actor? integer|0|'system'|CoreAuditActor src, 0 = console, nil/'system' = system
---@field action string `^[%w_.%-:]+$`, <= 64
---@field source? 'menu'|'palette'|'chat'|'console'|'editor'|'api'|'core' default: 'core' for core, else 'api'
---@field targets? (CoreAuditTarget|integer)[] a bare number is a player src; <= 32
---@field changes? ({ key: string, old: any, new: any }|any[])[] named or positional { key, old, new }; <= 64
---@field reason? string <= 256
---@field ctx? table <= 32 string keys
---@field result? 'ok'|'denied'|'error' default 'ok'
---@field message? string <= 512

---@class CoreAuditFilter
---@field action? string
---@field actionPrefix? string
---@field actorAccount? string
---@field target? { type: string, id: string|integer } a player row is also found by { type = 'account', id }
---@field resource? string
---@field result? 'ok'|'denied'|'error'
---@field from? number ms (or seconds when < 1e11)
---@field to? number ms (or seconds when < 1e11)
---@field text? string case-insensitive, over action, actor/target names, message, reason
---@field limit? integer default 50, <= 200
---@field before? string the `next` cursor of the previous page (or a row id)

---@class Core.Audit
Core.Audit = {}

---(server) Appends one row (queued, §56). Never yields, never throws; the row id is assigned when the queue
---commits.
---@param row CoreAuditInput
---@return true|nil ok nil when refused (bad action, the queue refused it)
function Core.Audit.record(row) end
---(server) The Core.Log.audit mirror: actor 'system', action 'core.<category>', target the player src.
---Not re-posted to the 'audit' webhook (webhook.lua already posts the hook line). Gameplay categories (not admin,
---perms, player, native, settings, maps, bans) land in the 'log' pool (`audit.logMaxRows`) and are capped at 20 rows
---per category per second (the rest counted into the next row's `ctx.suppressed`). Queued (§56); never yields.
---@param category string
---@param src? integer
---@param message? string
---@return true|nil ok
function Core.Audit.recordLog(category, src, message) end
---(server) Newest first; one walk over the in-memory index, one DB.get per returned row. A filter key that is
---present but unusable matches nothing (a bad filter never widens the result). The view permission
---`core.audit.view` is the consumer's check.
---@param filter? CoreAuditFilter
---@return { rows: CoreAuditRow[], next: string|nil }
function Core.Audit.query(filter) end
---(server)
---@param id string
---@return CoreAuditRow|nil
function Core.Audit.get(id) end
---(server) Applies the retention now (also daily at 04:30 and at start), per pool: 'main' (`audit.maxRows`),
---'log' (`audit.logMaxRows`), 'exempt' (`ban.*`/`sanction.*`, no cap, retentionDays × 4).
---@return integer removed
function Core.Audit.prune() end

---@class CoreBan
---@field id string 'B<n>' (migrated v1 bans keep their uuid)
---@field accountId? string the single matched account (the explicit one first)
---@field accountIds? string[] every account holding a banned identifier when the ban was made
---@field name string
---@field identifiers string[] never an 'ip:' one
---@field tokens string[]
---@field reason string
---@field evidence? string
---@field by { accountId?: string, name: string }
---@field createdAt integer os.time()
---@field expiresAt integer os.time(), 0 = permanent
---@field revoked? { by: { accountId?: string, name: string }, at: integer, reason?: string }
---@field hits integer refused connections
---@field lastHitAt? integer

---@class CoreBanTarget
---@field accountId? string an online account is treated like a src target (identity collected, kicked)
---@field identifiers? string[]
---@field tokens? string[]
---@field name? string

---@class Core.Bans
Core.Bans = {}

---(server) Bans an online src (identifiers + tokens collected now, then kicked) or an offline identity.
---Sets account.banned, audits `ban.add`. A player `by` must outrank every account holding a banned identifier
---and every online player the ban would refuse, else `nil, 'rank'` (`'db'` when that cannot be read); every such
---online player is kicked with the target. Console / nil / a legacy name string are not rank-checked.
---@param opts { target: integer|CoreBanTarget, reason?: string, duration?: integer, by?: integer|string, evidence?: string, source?: string }
---@return CoreBan|nil ban
---@return string|nil err 'invalid'|'invalid_duration'|'invalid_evidence'|'invalid_target'|'invalid_account'|'not_connected'|'unknown_account'|'no_identifiers'|'rank'|'db'
function Core.Bans.add(opts) end
---(server) Revokes (kept for history); clears account.banned with the account's last active ban; audits `ban.remove`.
---@param banId string
---@param by? integer|string src, 0 = console, or a name
---@param reason? string
---@return boolean ok
---@return string|nil err 'invalid'|'not_found'|'already_revoked'|'db'
function Core.Bans.remove(banId, by, reason) end
---(server) Awaited.
---@param banId string
---@return CoreBan|nil
---@return string|nil err 'db' when the row could not be read
function Core.Bans.get(banId) end
---(server) Newest first. `active = false` lists every ban (history included). Cursor '<createdAt>/<id>'. Awaited.
---@param opts? { active?: boolean, text?: string, accountId?: string, limit?: integer, before?: string }
---@return { rows: CoreBan[], next: string|nil }|nil
---@return string|nil err 'db' when bans cannot be read
function Core.Bans.list(opts) end
---(server) The best active ban (permanent first, then the latest expiry): one identifier overlap, or at least
---`bans.tokenMatches` distinct tokens in one ban.
---@param identifiers? string[]
---@param tokens? string[]
---@return CoreBan|nil ban
---@return 'unavailable'|nil why while the bans collection cannot be read
function Core.Bans.check(identifiers, tokens) end
---(server) Every ban of one account (its `accountId` or listed in `accountIds`), history included, newest first.
---Awaited.
---@param accountId string
---@return CoreBan[]|nil
---@return string|nil err 'db' when bans cannot be read
function Core.Bans.forAccount(accountId) end
---(server) Drops expired bans from the index. Runs once at start and every 60 s (§56.12 SWEEP_MS).
---@return integer expired
function Core.Bans.sweep() end
-- Bans.checkConnecting(src) -> ban, message | nil | nil, 'unavailable' is internal (blocked in the export; the
-- connect path), and so is Core.BanIdentity (server/bans_identity.lua: identity reads, online holder index, rank check).
-- Settings (section 'bans', owner core): 'bans.tokenMatches' integer 0..10 (2; 0 = tokens never match alone),
-- 'bans.enrichTokens' boolean (true), 'bans.enrichIdentifiers' boolean (true; only after an identifier match or
-- >= 2 matching tokens), 'bans.failClosed' boolean (true; the connect path refuses while bans are unavailable).

--------------------------------------------------------------------------------
-- Core.Buckets (server/buckets.lua §50) — (server) only
--------------------------------------------------------------------------------

---@class CoreBucketInfo
---@field owner string
---@field label? string
---@field population boolean
---@field lockdown 'strict'|'relaxed'|'inactive'

---@class Core.Buckets
Core.Buckets = {}

---(server) A routing bucket from Config.Buckets.Range for the calling resource (round robin, owner-tracked
---kind 'bucket'); applies SetRoutingBucketPopulationEnabled + SetRoutingBucketEntityLockdownMode. nil when opts
---are invalid or the range is exhausted.
---@param opts? { label?: string, population?: boolean, lockdown?: 'strict'|'relaxed'|'inactive' } defaults: population false, lockdown 'strict'
---@return integer|nil bucket
function Core.Buckets.allocate(opts) end
---(server) Owner (or core) only; players still inside are moved to bucket 0.
---@param bucket integer
---@return boolean
function Core.Buckets.release(bucket) end
---(server)
---@param bucket integer
---@return CoreBucketInfo|nil
function Core.Buckets.info(bucket) end
---(server) Ascending by bucket id.
---@return (CoreBucketInfo|{ bucket: integer })[]
function Core.Buckets.list() end

--------------------------------------------------------------------------------
-- Core.Admin (server/adminapi.lua + adminapi_dispatch.lua §51) — (server); (client) getSelf/getStaffStates
--------------------------------------------------------------------------------

---@alias CoreAdminTarget 'none'|'player'|'players'|'entity'|'coords'
---@alias CoreAdminSource 'menu'|'palette'|'chat'|'console'|'editor'|'api'|'core'

---@class CoreAdminCategoryDef
---@field id string '^[%w_%-%.]+$' ≤ 64
---@field label string
---@field icon? string
---@field order? number default 100
---@field permission? string

---@class CoreAdminActionCtx
---@field id string
---@field actor integer 0 = console
---@field targets (integer|{ entity: integer, netId: integer }|vector3)[] player srcs | one entity | one vector3; {} for 'none'
---@field args table validated by Core.Schema.checkAll (defaults filled)
---@field reason? string trimmed
---@field source CoreAdminSource

---@class CoreAdminActionDef : CoreAdminCategoryDef
---@field category string
---@field description? string
---@field permission? string default 'admin.' .. id literally ('admin.kick' → 'admin.admin.kick'), Perms.define'd with `default`
---@field default? string|false group granted the permission once (default 'admin'); false = none
---@field target? CoreAdminTarget default 'none'
---@field self? boolean default true
---@field hierarchy? boolean default true (Perms.canTarget per player target)
---@field max? integer 'players': 1..2000, default 50; 'player' is always 1; also capped by Config.Admin.Scope
---@field args? table[] Core.Schema fields
---@field reason? 'none'|'optional'|'required' default 'none' (required: 3..256 characters)
---@field danger? 'none'|'confirm'|'typed' default 'none'; not 'none' needs `confirm = true` on run
---@field cooldown? number seconds per (actor, action), default 1
---@field duty? boolean default Config.Admin.RequireDuty
---@field echo? boolean default true
---@field command? string|false also a chat command (lower-cased, '^[%w_%-]+$' ≤ 32)
---@field key? string default key the admin client may bind
---@field hidden? boolean palette/commands only
---@field handler fun(ctx: CoreAdminActionCtx): boolean?, string?, table? ok (nil = ok), message, data (data.changes -> audit)

---@class CoreAdminViewDef : CoreAdminCategoryDef
---@field category? string (pages only)
---@field duty? boolean default Config.Admin.RequireDuty
---@field hierarchy? boolean (player tabs) default true: the viewer must pass Perms.canTarget on the target
---@field page? string a plain UI page id (^[%w_%-]+$, ≤ 64; else 'page') the admin frontend opens as a modal
---@field provider? fun(ctx: { id: string, viewer: integer, params?: table, target?: integer }): table[] blocks (§51)

---@class CoreAdminSnapshot
---@field rank { group: string, weight: integer, scope: integer }
---@field duty boolean
---@field categories table[]
---@field actions table[] public fields only; `max` capped for the viewer; args = Schema.public
---@field pages table[] { id, category, label, icon, order, permission, duty, page, provider: boolean, owner }
---@field playerTabs table[]

---@class Core.Admin
Core.Admin = {}

---(server) Owner-tracked (kind adminCategory); the first registrant owns the id, the same owner replaces it.
---@param def CoreAdminCategoryDef
---@return boolean ok
---@return string|nil err 'definition'|'id'|'label'|'icon'|'order'|'permission'|'description'|'owned'
function Core.Admin.category(def) end
---(server) Owner-tracked (kind adminAction). Errors name the offending key ('target', 'max', 'args:<schema err>', …) or 'owned'.
---@param def CoreAdminActionDef
---@return boolean ok
---@return string|nil err
function Core.Admin.action(def) end
---(server) Owner-tracked (kind adminPage). Needs `page` and/or `provider` (else 'page_or_provider'; also
---'category', 'page', 'provider', 'duty' and the category errors).
---@param def CoreAdminViewDef
---@return boolean ok
---@return string|nil err
function Core.Admin.page(def) end
---(server) Owner-tracked (kind adminPlayerTab). The provider gets ctx.target (a loaded src the viewer may
---target, unless `hierarchy = false`; else the callback answers `rank`).
---@param def CoreAdminViewDef
---@return boolean ok
---@return string|nil err
function Core.Admin.playerTab(def) end
---(server) The one dispatch path (§51, 14 steps). Refusal codes: unknown_action, not_loaded, no_permission, off_duty,
---cooldown (never audited), invalid_args (3rd = the checkAll errors), reason_required, invalid_reason, no_target,
---invalid_targets, not_found, self, too_many, rank, ambiguous (and the other §49 selector codes), no_entity,
---out_of_bounds, confirm_required, vetoed. A failing handler: false, its message (or 'failed'), data; a throwing one:
---false, 'error'. `source` defaults to 'console' for src 0, else 'api'. The cooldown is stamped when the handler
---runs AND when the targets are refused. Entity targets pass the hierarchy too (a player ped, every seated player).
---@param actorSrc integer 0 = console
---@param id string
---@param opts? { targets?: string|integer|integer[]|{ netId: integer }|vector3|{ x: number, y: number, z: number }, args?: table, reason?: string, source?: CoreAdminSource, confirm?: boolean }
---@return boolean ok
---@return { message?: string, data?: table }|string resultOrErr
---@return table|nil data
function Core.Admin.run(actorSrc, id, opts) end
---(server) What `src` may use (permission + duty), public fields only. Advisory: run re-checks everything.
---@param src integer
---@return CoreAdminSnapshot|nil
function Core.Admin.snapshot(src) end
---(server) Needs Config.Admin.StaffPerm to go on duty; audited on change. Never a state bag: the player hears
---`core:admin:self`, the on-duty staff `core:admin:staffState` (a player going on duty gets `core:admin:staffStates`
---once). Going off duty (and losing the staff permission) turns every staff mode off first.
---@param src integer
---@param on boolean
---@return boolean
function Core.Admin.setDuty(src, on) end
---(server) Console: true.
---@param src integer
---@return boolean
function Core.Admin.isOnDuty(src) end
---(server) Mode names '^%a[%w_]*$' ≤ 32, ≤ 16 per player (known: noclip, vanish, spectate, god, editor). Names
---go to the player (core:admin:self) and, while on duty, to the on-duty staff; `data` stays on the server. On/off
---changes are audited and emit the server hook `staffModeChanged (src, modes)`.
---@param src integer
---@param mode string
---@param on boolean
---@param data? table|string|number|boolean
---@return boolean
function Core.Admin.setMode(src, mode, on, data) end
---(server) A copy of { [mode] = data|true }; {} for nobody.
---@param src integer
---@return table<string, any>
function Core.Admin.getModes(src) end
---(server) Loaded players holding Config.Admin.StaffPerm, ascending. O(staff), never O(players).
---@param onDutyOnly? boolean
---@return integer[]
function Core.Admin.staff(onDutyOnly) end
---(server) `core:admin:echo` { text, at } to on-duty staff (optionally holders of `perm`, minus `exclude`).
---@param text string ≤ 256
---@param opts? { perm?: string, exclude?: integer|integer[] }
---@return integer sent
function Core.Admin.echo(text, opts) end
-- Transport (core-owned, every callback StaffPerm-gated): core:admin:snapshot / run / page / playerTab; client events
-- core:admin:echo, core:admin:snapshotChanged (no payload: refetch the snapshot), core:admin:self,
-- core:admin:staffState(s). Pipeline 'admin:before', hooks 'adminAction' and 'staffModeChanged' (server).

---@class CoreStaffState
---@field duty boolean
---@field modes table<string, true>

---(client) This player's own staff state (a copy), from core:admin:self (client/adminstate.lua). Display only —
---the server re-checks everything. Hook: `staffSelfChanged (state)`.
---@return CoreStaffState
function Core.Admin.getSelf() end
---(client) { [src] = state } of every on-duty staff member — empty unless this player is on duty.
---Hook: `staffStateChanged (src, state|nil)`.
---@return table<integer, CoreStaffState>
function Core.Admin.getStaffStates() end

--------------------------------------------------------------------------------
-- Core.Maps (server/maps_types.lua, maps_runtime.lua, maps.lua, maps_apply.lua; client/maps_preview.lua,
--            maps.lua — DESIGN §52, §55.21.1). A trusted server API: the caller (the admin plugin) authorises its
--            users. Since 2026-09-27 every shown element is a Core.Scene node (server/maps_runtime.lua projects it,
--            fields.mapEl = the uid); the client half is a facade over Core.Scene. Errors are short codes (see
--            README "Maps (§52)").
--------------------------------------------------------------------------------

---@class CoreMapTypeDef
---@field id string '<resource>:<name>' ('^[%w_%-]+:[%w_%-]+$', <= 64)
---@field label? string defaults to the id
---@field icon? string
---@field category? string default 'Gameplay'
---@field description? string
---@field kind 'prop'|'vehicle'|'ped'|'marker'|'hide'|'point'|'zone'
---@field model? string fixed model; otherwise prop/vehicle/ped types need a Schema field `model` of type 'model'
---@field fields? table[] Core.Schema fields
---@field preview? table[] editor-only: { kind='marker', type, scale?, color? } | { kind='box', size } | { kind='sphere', radius } | { kind='label', text } ('$field' references allowed)
---@field transform? { rotate: 'full'|'yaw'|'none' } defaults: prop/marker full, vehicle/ped/point/zone yaw, hide none
---@field networked? boolean prop kind only: a server-created networked object
---@field limits? { perMap: integer }
---@field parents? string[] the map must contain an element of one of these types
---@field validate? fun(record: CoreMapElement, ctx: { mapId: string, actor: any, op: string }): boolean, string?
---@field version? integer default 1
---@field migrate? fun(fields: table, fromVersion: integer): table

---@class CoreMapElement
---@field id string element id (digits), unique per map
---@field type string
---@field typeVersion integer
---@field pos { x: number, y: number, z: number } rounded to 3 decimals
---@field rot { x: number, y: number, z: number } Euler degrees, order 2, (-180, 180], 2 decimals
---@field fields table
---@field layer string default 'default'
---@field cam? { x: number, y: number, z: number }
---@field by string account id of the creator, 'console' or 'system'
---@field updatedAt integer strictly increasing ms stamp (the `expect` token)
---@field info? { lod?: integer, vehicleType?: string } from the model validator

---@class CoreMapRecord
---@field uid string '<mapId>:<elementId>'
---@field key string '<bucket>|<uid>' (a draft's element exists in its editor bucket AND, published, in the target bucket)
---@field mapId string
---@field id string
---@field type string
---@field pos table
---@field rot table
---@field fields table
---@field layer string
---@field bucket integer
---@field editor boolean true in a draft's editor bucket

---@class CoreMapsClientStats
---@field elements integer map elements indexed on this client (wanted scene nodes carrying fields.mapEl)
---@field spawned integer of those, the ones with an entity here
---@field held integer uids held (Core.Maps.hold)
---@field queued integer the materialiser's queue (every scene node, not only maps)
---@field models integer assets the materialiser holds (models, anim dicts, ptfx)
---@field failed integer nodes that failed this session (a missing model, a refused create)
---@field previews integer editor previews drawn in the last pass
---@field dataNodes integer live map:data records (points, zones, helpers, placeholders)
---@field types integer element types known to the editor view
---@field editorView boolean some resource has the editor view on

---@class Core.Maps
Core.Maps = {}

---(server) Defines (or, same owner, redefines) an element type. Owner-tracked (kind 'mapType'); records of a
---removed type stay (placeholders). Built-ins (owner core): core:prop|physprop|vehicle|ped|marker|hide|point|zone.
---@param def CoreMapTypeDef
---@return boolean ok
---@return string|nil err
function Core.Maps.defineType(def) end
---(server) Public type list (no functions, Schema.public fields), sorted by category then label.
---@return table[]
function Core.Maps.types() end
---(server) The one model validator (owner-tracked, kind 'mapsModelValidator'); nil clears (owner or core). Props
---pass on the name pattern without one; vehicles, peds and networked props are refused ('no_validator').
---@param fn? fun(kind: 'prop'|'vehicle'|'ped', model: string): boolean, { lod?: integer, vehicleType?: string }?
---@return boolean
function Core.Maps.setModelValidator(fn) end
---(server) { name, mode = 'draft'|'live', targetBucket? = 0, meta? = { description }, expiresAt? (unix s),
---limits? = { elements?, perModel?, uniqueModels?, networked? }, active? (live default true, draft false) }.
---A `targetBucket` inside Config.Buckets.Range (or an open editor bucket) is refused ('targetBucket').
---@param input table
---@param actor? integer|0|'system'
---@return table|nil map
---@return string|nil err
function Core.Maps.create(input, actor) end
---(server) A copy + counts { elements, networked, uniqueModels, topModels }, editorBucket, dirty.
---@param id string
---@return table|nil
function Core.Maps.get(id) end
---(server) Sorted by name.
---@param filter? { mode?: string, active?: boolean, text?: string }
---@return table[]
function Core.Maps.list(filter) end
---(server) name?, meta?, expiresAt? (false clears), targetBucket?, limits? (false clears). Audited 'maps.update'.
---@param id string
---@param patch table
---@param actor? integer
---@return table|nil map
---@return string|nil err
function Core.Maps.update(id, patch, actor) end
---(server) Deletes the map with its elements, versions and journal (an open draft is closed first).
---@param id string
---@param actor? integer
---@return boolean ok
---@return string|nil err
function Core.Maps.delete(id, actor) end
---(server)
---@param id string
---@param on boolean
---@param actor? integer
---@return boolean ok
---@return string|nil err 'limit' (networkedTotal) | 'not_found' | 'active' | 'unavailable'
---@return table|nil detail
function Core.Maps.setActive(id, on, actor) end
---(server) The draft / live working set, ascending ids (copies).
---@param id string
---@return CoreMapElement[]|nil
function Core.Maps.elements(id) end
---(server) All-or-nothing. ops: { op='create', type, pos, rot?, fields?, layer?, cam?, id? (a free id) }
---| { op='update', id, set = { pos?, rot?, fields? (merged), layer?, cam? }, replace? (fields replaced) } | { op='delete', id }
---| { op='create', id, restore = record } | { op='update', id, restore = record } (undo: the raw earlier record — only
---position/rotation/layer are checked; see invert). Deleting an element another untouched element references → 'referenced'.
---opts = { source? = 'api'|'editor'|'palette'|'menu'|'chat'|'console'|'core', expect? = { [elementId] = updatedAt } }.
---@param id string
---@param ops table[] ≤ maps.limits.opsPerApply
---@param actor? integer|0|'system'
---@param opts? table
---@return boolean|nil ok
---@return table|string appliedOrErr applied = { seq, ops = { { op, id, before?, after? } } }
---@return table|nil detail { index?, fields?, limit?, max?, model?, type?, reason?, id? }
function Core.Maps.apply(id, ops, actor, opts) end
---(server) The undo of an applied: `restore` ops plus the expect table to apply them with (per step: after undoing
---one step, rebase the next step's expects on the undo's own applied).
---@param applied table
---@return table ops
---@return table expect
function Core.Maps.invert(applied) end
---(server) Deletes every element in one journaled apply (no opsPerApply cap). Audited 'maps.clear'.
---@param id string
---@param actor? integer
---@param opts? { source?: string }
---@return boolean|nil ok
---@return table|string appliedOrErr
function Core.Maps.clear(id, actor, opts) end
---(server) Drafts only: snapshots the draft as the next version (the newest 20 are kept).
---@param id string
---@param actor? integer
---@param note? string
---@return integer|nil version
---@return string|nil err
function Core.Maps.publish(id, actor, note) end
---(server) Newest first: { version, by, byName, note, at, count, from?, current }.
---@param id string
---@return table[]|nil
function Core.Maps.versions(id) end
---(server) Publishes a copy of `version` as a new version; the draft is left as it is. Re-runs today's model
---validator ('model'/'no_validator', detail { ids }) and the per-map limits on the snapshot.
---@param id string
---@param version integer
---@param actor? integer
---@return integer|nil newVersion
---@return string|nil err
function Core.Maps.rollback(id, version, actor) end
---(server) Allocates (or returns) the draft's editor bucket; owner core, population off, lockdown strict.
---Closed automatically when the opening resource stops (kind 'mapsDraft').
---@param id string
---@param actor? integer
---@return integer|nil bucket
---@return string|nil err 'unavailable'|'not_found'|'mode'|'bucket'|'limit'
function Core.Maps.openDraft(id, actor) end
---(server)
---@param id string
---@return boolean closed
function Core.Maps.closeDraft(id) end
---(server) Newest first. filter = { limit? = 50 (<= 200), before? = seq, author? = by }. Update rows store only the
---changed keys; a clear row is { clear = true, count, ids }. Pruned per map to `maps.journalMax` rows and
---`maps.journalMaxOps` weight, server-wide to 200000.
---@param id string
---@param filter? { limit?: integer, before?: integer, author?: string }
---@return table[]|nil rows { mapId, seq, at, by, actor, source, count, ops }
function Core.Maps.journal(id, filter) end
---(server) Puts the scene nodes of a map's active contexts (all elements, or one element id) back to their authored
---state: a promoted, displaced or changed node is moved back and reset (Scene demotes a promoted clone first); a missing
---one is spawned again — and a spawn waiting on a 'limit' retry is tried at once. It examines every element
---synchronously; more than 200 missing nodes are queued for the projector's worker. 0 before the Scene store loaded.
---@param id string
---@param elementId? string|integer
---@return integer touched how many nodes it spawned, moved, reset or queued
function Core.Maps.respawn(id, elementId) end
---(server) 'added'|'changed'|'removed' for ACTIVE content of a type ('*' = all), delivered in a thread,
---owner-swept (kind 'mapsListener'). Not replayed: seed with Maps.records.
---@param typeId string
---@param fn fun(event: string, record: CoreMapRecord, mapId: string)
---@return string|nil handle
function Core.Maps.on(typeId, fn) end
---(server)
---@param handle string
---@return boolean removed
function Core.Maps.off(handle) end
---(server) Active content of a type ('*' = all), editor buckets included (record.editor).
---@param typeId string
---@return CoreMapRecord[]
function Core.Maps.records(typeId) end

---(client) True when the scene cells around `coords` are current and every node within `radius` a camera there
---would want is materialised (or failed, or capped) — Core.Scene's readiness; map content is scene nodes. Not ready
---inside a box of GlobalState 'core:mapsPending' of the player's bucket (a large map change still being projected).
---@param coords vector3
---@param radius? number default 50, clamped to 0..500
---@return boolean
function Core.Maps.isAreaReady(coords, radius) end
---(client) Waits in the calling thread until `isAreaReady(coords)` or the timeout; asks the scene's focus reporter
---for a report first, but moves no window (Spawn.teleport waits on Core.Scene.waitAreaReady, the same check).
---@param coords vector3
---@param timeoutMs? integer default 5000, clamped to 0..60000
---@return boolean ready
function Core.Maps.waitAreaReady(coords, timeoutMs) end
---(client) The entity of a map element: its local copy, else the promoted clone standing in for it, else a copy a
---holder keeps (the server replaced or removed the node while it was held); nil while nothing is materialised.
---@param uid string the element uid '<mapId>:<elementId>' (1..128 characters)
---@return integer|nil
function Core.Maps.handleOf(uid) end
---(client) The map element uid of an entity the scene materialised (a local copy or a promoted clone), or nil.
---@param entity integer
---@return string|nil uid
function Core.Maps.uidOf(entity) end
---(client) The runtime leaves the element's entity alone (no move, re-create or delete; changes apply on release)
---until every holder released it; a hold taken before the node arrives applies when it comes. Returns the entity
---when there is one. Owner-tracked (kind 'mapHold'; the scene hold runs under the owner key 'maps:<resource>', so a
---resource's Scene.hold and Maps.hold never release each other).
---@param uid string
---@return integer|nil entity
function Core.Maps.hold(uid) end
---(client) Gives the caller's hold back; with no holder left the element takes its authoritative state.
---@param uid string
---@return boolean released false when the caller held nothing
function Core.Maps.release(uid) end
---(client) Editor view for the calling resource (owner-tracked, kind 'mapEditorView'): the map:data previews
---(points, zones, helpers, placeholders of undefined types) within 150 m, drawn while any owner has it on
---(client/maps_preview.lua; ≤ Config.Maps.MaxMarkers at once).
---@param on boolean
---@return boolean ok false for a non-boolean
function Core.Maps.setEditorView(on) end
---(client) A diagnostic snapshot of the runtime.
---@return CoreMapsClientStats
function Core.Maps.stats() end

--------------------------------------------------------------------------------
-- Core.Clock (lib/clock/shared.lua — DESIGN §55.2). A lib: compiled into every VM, plugins too (no export hop).
--------------------------------------------------------------------------------

---@class Core.Clock
Core.Clock = {}

---(shared) u32 milliseconds on ONE timeline. Server: GetGameTimer() & 0xFFFFFFFF. Client: GetNetworkTimeAccurate()
---& 0xFFFFFFFF (OneSync's network time, the server's timeline ±5–20 ms), latched once per frame; while it reads 0
---(not synced yet) the game timer plus the last known offset. Compare stamps only with `Core.Clock.diff`.
---@return integer
function Core.Clock.now() end
---(shared) a − b as a signed 32-bit difference: wrap-safe for stamps less than 24.8 days apart.
---@param a integer
---@param b integer
---@return integer
function Core.Clock.diff(a, b) end
---(shared) (t + ms) mod 2^32; a fractional ms is floored.
---@param t integer
---@param ms number
---@return integer
function Core.Clock.add(t, ms) end
---(shared) `add(now(), ms)`: a future-stamped plan (a motion's or an audio source's t0).
---@param ms number
---@return integer
function Core.Clock.at(ms) end
---(shared) Server: true. Client: the network time answered non-zero twice with an advancing value (sticky).
---@return boolean
function Core.Clock.ready() end
---(shared) Client: a GetGameTimer()-based stamp → network time (the offset is the max of now() − GetGameTimer()
---over the last 10 s). Server: the identity, masked to u32.
---@param localMs integer
---@return integer
function Core.Clock.local2net(localMs) end
---(shared) The inverse of `local2net`.
---@param netMs integer
---@return integer
function Core.Clock.net2local(netMs) end

--------------------------------------------------------------------------------
-- Core.Scene (server/scene*.lua, client/scene*.lua, lib/scene/{shared,client}.lua — DESIGN §55). Server: a trusted
-- API through the proxy; everything a plugin creates is owner-tracked. Client: the read API through the proxy,
-- `handle` / `on` / `off` in the caller's VM. Errors are short codes (README "Scene streaming (Core.Scene)").
--------------------------------------------------------------------------------

---@alias CoreSceneKindClass 'prop'|'vehicle'|'ped'|'fx'|'data'|'audio'|'custom'
---@alias CoreSceneTier 'S'|'M'|'L'|'G'
---@alias CoreSceneState 'known'|'warm'|'staged'|'live'|'retiring'|'failed'|'off'
---@alias CoreSceneServerEvent 'spawned'|'changed'|'removed'|'promoted'|'demoted'

---What a server 'demoted' hook gets after the node copy (§55.15 final notes).
---@class CoreSceneDemotedInfo
---@field reason 'rest'|'manual'|'forced'|'evicted'|'lost'|'destroyed'
---@field destroyed boolean the clone was wrecked
---@field pos { x: number, y: number, z: number } the clone's last pose (the node follows it)
---@field rot { x: number, y: number, z: number }
---@field bucket integer the clone's last routing bucket
---@field wear? table the last known wear props (Core.Scene.WEAR keys)
---@alias CoreSceneClientEvent 'live'|'gone'|'changed'|'event'|'enter'|'exit'|'promoted'|'demoted'

---A motion descriptor (§55.9; metres, degrees, Core.Clock ms; `t0` defaults to Clock.at(Motion.PlanLeadMs = 200)):
---`{ t = 'tween', d, to = { x, y, z, rx?, ry?, rz? }, from?, e = 'linear'|'in'|'out'|'inout' }`,
---`{ t = 'path', pts (≤ 64 { x, y, z }), sp = m/s | d = ms (one pass), loop = 'once'|'loop'|'pingpong', curve =
---'linear'|'catmull', face = 'fixed'|'path', ph? }`, `{ t = 'spin', axis = 'x'|'y'|'z', dps, a0? }`,
---`{ t = 'osc', dir, amp, period, phase? (deg) }`, `{ t = 'orbit', c, r, period, a0?, cw?, face = 'fixed'|'path'|
---'center' }`, `{ t = 'keys', keys (≤ 128 { t, x, y, z, rx?, ry?, rz? }), loop?, smooth?, ph? }`. A plan whose t0
---lies more than 24 h ahead is refused ('motion_future'). `Scene.drive` makes the server-steered `{ t = 'dr' }`.
---@alias CoreSceneMotion table

---A gated audience (§55.3, §55.6): exactly ONE key per table, combined with `any` / `all` (1..8 entries, nesting ≤ 3).
---The effective audience of a node is its own AND every ancestor's. `players` and `fn` are refused on persistent
---nodes; `fn` must be synchronous (a yield counts as "not allowed").
---@alias CoreSceneAudience { players: integer[] }|{ faction: string }|{ perm: string }|{ editors: true }|{ near: number }|{ fn: fun(src: integer, nodeId: integer): boolean }|{ any: CoreSceneAudience[] }|{ all: CoreSceneAudience[] }

---An interaction descriptor (§55.14); ≤ 4 per node.
---@class CoreSceneInteract
---@field action string ≤ 32, `[%w_-]`, unique per node
---@field label? string ≤ 64, default the action
---@field distance? number 0.5..20 m, default 2.0 (the server allows distance + 2 m from its own position)
---@field icon? string
---@field description? string ≤ 256
---@field perm? string checked with Core.Perms.has before the handlers
---@field cooldownMs? integer 0..60000, default 500, per (player, node, action)
---@field data? table ≤ 1 KiB, handed to the onInteract handlers
---@field prompt? { world?: boolean, offsetZ?: number, range?: number } true = the world dot, false = the text UI (nil: Config.Interactions.WorldPrompt); offsetZ −5..5 m, range 1..50 m

---A promotion policy (§55.15): the kind's default, overridden per node.
---@class CoreSceneAuthority
---@field mode? 'local'|'promote'|'networked' proximity promotes players on foot ('promote') or anyone ('networked')
---@field proximity? number 1..200 m (vehicles: 20)
---@field enter? boolean a player trying to enter the local copy promotes it
---@field damage? boolean damage to the local copy promotes it
---@field actions? string[] ≤ 8 interaction actions that promote
---@field restMs? integer 0..600000, default 3000
---@field idleMs? integer 0..3600000, default 20000
---@field onDestroyed? 'keep'|'remove' default 'keep' (demote at the stored pose)

---@class CoreSceneSpawnDef
---@field kind string a built-in ('prop' 'vehicle' 'ped' 'light' 'particle' 'marker' 'text' 'hide' 'zone' 'sound' 'group' 'audio.source' 'audio') or '<resource>:<name>'
---@field pos? vector3|{ x: number, y: number, z: number } roots: x/y ±10000, z −1000..3000 (ignored for a child and an audio.source)
---@field rot? vector3|{ x: number, y: number, z: number } Euler degrees, rotation order 2
---@field bucket? integer default 0; a child defaults to its parent's
---@field parent? integer a node id: the child rides its root (same bucket, depth ≤ 4, ≤ Config.Scene.MaxChildren descendants per root)
---@field offset? vector3 relative to the parent (or its bone), each component ±1000 m
---@field offrot? vector3
---@field bone? integer|string a bone index or name on the parent's entity
---@field rotOrder? integer children: 0..5, the rotation order `offrot` is applied in (default 2 = EULER_YXZ; Core.Attachments uses 1); ignored on roots
---@field motion? CoreSceneMotion roots only
---@field fields? table the kind's fields (Core.Schema), checked whole. Vehicle: model*, props, plate (`^[%w %-]*$`), locked, engine, lights, siren, doors, frozen, invincible, dirt, vtype (a CreateVehicleServerSetter type or a vehicles.meta name; filled from the model when absent), vehId; prop / vehicle / ped / marker / hide also mapEl, mapType (README "Scene streaming" lists every kind)
---@field model? string|integer shorthand for fields.model: a name, an integer hash or a '0x%08X' string
---@field audience? CoreSceneAudience nil = public in its bucket
---@field radius? number stream radius override, 1..Config.Scene.TierL (a global node: ..65535)
---@field global? boolean the bucket's global set (≤ Global.MaxNodes; a plugin ≤ Global.MaxPerOwner)
---@field persist? boolean stored in Core.DB (`scene_nodes`): survives restarts and its owner's stop
---@field interact? CoreSceneInteract[] ≤ 4
---@field authority? CoreSceneAuthority
---@field allowChildren? true|string[] who else may hang nodes under this one (its owner and core always may)

---@class CoreSceneSetOpts
---@field remove? string[] optional field names to delete (≤ 64)
---@field interact? CoreSceneInteract[]|false false clears
---@field audience? CoreSceneAudience|false false = public again
---@field radius? number|false false = the kind's radius again
---@field allowChildren? true|string[]|false

---A server node copy (Scene.get / query / the Scene.on hooks). Changing it changes nothing.
---@class CoreSceneNode
---@field id integer
---@field kind string
---@field owner string the creating resource
---@field bucket integer
---@field pos { x: number, y: number, z: number } a child's: its world pose when it was last set
---@field rot { x: number, y: number, z: number }
---@field parent? integer
---@field offset? { x: number, y: number, z: number }
---@field offrot? { x: number, y: number, z: number }
---@field bone? integer|string
---@field rotOrder? integer a child's / attached node's rotation order (nil = 2)
---@field motion? CoreSceneMotion
---@field attach? { player?: integer, net?: integer }
---@field fields table
---@field audience? table data-only (an `fn` shows as `fn = true`)
---@field radius number
---@field tier? CoreSceneTier
---@field global boolean
---@field persist boolean
---@field interact? CoreSceneInteract[]
---@field authority? CoreSceneAuthority
---@field deps? integer[] the dependency nodes it needs (an emitter: its source)
---@field children? integer[] a root: every descendant id, parent first
---@field ver integer per node: 1 on spawn, +1 per change, u32 wrapping to 1 (compare with Core.Clock.diff-style serial arithmetic)
---@field placeholder? true the node's kind is not defined (any more)
---@field allowChildren? true|string[]
---@field promoted? { netId: integer }

---@class CoreSceneKindDef
---@field id string '<resource>:<name>' (`^[%w_%-]+:[%w_%-%.]+$`, ≤ 64); the prefix must be the defining resource
---@field class CoreSceneKindClass plugin-drawn kinds use 'custom'
---@field fields? CoreSchemaField[] a `{ name, type = 'table', validate = fn }` field is free-form JSON-safe data (≤ Config.Scene.MaxFieldBytes)
---@field nearFields? string[] sent to near-ring subscribers only
---@field radius? number|fun(node: table): number the stream radius (default by class)
---@field handler? string the client resource that draws it (Core.Scene.handle there); default the owner
---@field authority? CoreSceneAuthority the default promotion policy
---@field budget? string the client cap key (Config.Scene.Caps); a custom kind gets `Caps.custom` of its own

---@class CoreSceneQuery
---@field pos vector3|{ x: number, y: number, z: number }
---@field radius number 0..10000 m
---@field bucket? integer default 0
---@field kind? string
---@field owner? string
---@field limit? integer default 256 (≤ 4096)

---The server's counters (Scene.stats on the server).
---@class CoreSceneStats
---@field nodes integer
---@field byKind table<string, integer>
---@field persistent integer
---@field global integer
---@field kinds integer
---@field loaded boolean the persistent nodes are loaded
---@field cells? integer
---@field subscribers? integer
---@field bytesPerSecond? number
---@field flushMs? { p50: number, p99: number }
---@field index? table
---@field interest? table
---@field flush? table
---@field promote? table
---@field audio? table
---@field voice? table

---@class CoreSceneAudioPlayDef: CoreSceneSpawnDef
---@field id? integer an existing audio.source to change instead (with `fields` = the patch)
---@field by? integer a player on whose behalf it plays: 1 play per 5 s per player, audited, never decoded to PCM

---@class CoreSceneVoiceDef
---@field talker integer a loaded player (the calling plugin authorises him)
---@field speakers integer[] 1..32 distinct node ids of one bucket
---@field fx? 'megaphone'|'pa'|'phone'|'radio'|'none' default 'none'
---@field range? number 1..600 m, default 60
---@field onEnd? fun(sessionId: integer, reason: 'stopped'|'owner'|'talker'|'dropped'|'speakers'|'no_voice') called once for an end the owner did not ask for

---@class CoreSceneVoiceSession
---@field id integer
---@field owner string
---@field talker integer
---@field speakers integer[]
---@field fx string
---@field range number
---@field bucket integer
---@field listeners integer
---@field startedAt integer

---A client node copy (Scene.get on the client).
---@class CoreSceneClientNode
---@field id integer
---@field kind? string
---@field pos vector3
---@field rot vector3
---@field fields table
---@field parent? integer
---@field state CoreSceneState

---What a client Scene.on listener gets as `info`.
---@class CoreSceneEventInfo
---@field event CoreSceneClientEvent
---@field kind? string
---@field entity? integer 'live': the entity (if any)
---@field changes? string[] 'changed': what changed ('fields', 'move', 'motion', 'attach', 'interact', 'kind', 'promote', …)
---@field fields? string[] 'changed': the changed field names
---@field name? string 'event'
---@field params? table 'event'
---@field age? integer 'event': ms since it was emitted
---@field pos? vector3 'event'
---@field netId? integer 'promoted'

---What a plugin kind's handler gets (a copy, §55.13).
---@class CoreScenePluginView
---@field id integer
---@field kind string
---@field pos vector3
---@field rot vector3
---@field fields table
---@field parent? integer
---@field radius number
---@field motion? CoreSceneMotion
---@field interact? CoreSceneInteract[]
---@field attach? table
---@field offset? table
---@field offrot? table
---@field bone? integer|string
---@field netId? integer while promoted
---@field changed? string update: what changed
---@field changedFields? string[] update of 'fields': the names

---@class CoreScenePluginHandlers
---@field create fun(node: CoreScenePluginView): integer|nil a LOCAL entity (or nil); may yield — core waits ≤ 5 s for it
---@field update? fun(node: CoreScenePluginView, entity: integer|nil, changed: string|nil)
---@field destroy? fun(node: CoreScenePluginView, entity: integer|nil)
---@field event? fun(node: CoreScenePluginView, entity: integer|nil, name: string, params: table|nil, age: integer)

---The client's counters (Scene.stats on the client): the materialiser's, the cache's and the focus reporter's.
---@class CoreSceneClientStats
---@field nodes integer cached nodes
---@field cells integer
---@field cellsPending integer
---@field cellsLive integer
---@field cellsLru integer
---@field gated integer
---@field deps integer
---@field kinds integer
---@field byState { known: integer, warm: integer, staged: integer, live: integer, retiring: integer, failed: integer, off: integer }
---@field byBudget table<string, integer> materialised per cap key
---@field queued integer
---@field fades integer
---@field models { props: integer, vehicles: integer, peds: integer }
---@field movers integer
---@field lodScale number
---@field poolSize integer the Object pool size in use (learned or Config.Scene.ObjectPool)
---@field bytesIn integer
---@field payloads integer
---@field latent integer
---@field gaps integer
---@field resyncs integer
---@field reports integer
---@field bucket? integer
---@field plugin { claims: integer, waiting: integer, bound: boolean, listens: integer }

---@class Core.Scene.audio
local CoreSceneAudio = {}
---(server) Spawns an `audio.source` (kind implied), or with `def.id` changes one (`def.fields` = the patch). `by = src`
---plays on that player's behalf. Refusals: 'def' 'by' 'rate_limit' 'missing', the spawn / set errors, and the
---admission's 'audio_disabled' (setting scene.audio.enabled) | 'audio_streams' (scene.audio.maxStreams) | 'audio_rate'
---(per-owner flood guard). Remote URLs must be https on a host in scene.audio.allowHosts.
---@param def CoreSceneAudioPlayDef
---@return integer|nil id
---@return string|nil err
---@return table|nil detail
function CoreSceneAudio.play(def) end
---(server) The kill switch: removes a source (with its emitters), an emitter, or every source ('all'), whatever the
---owner. Audited 'scene.audio.kill'.
---@param target integer|'all'
---@param by? integer the acting player (audit)
---@return boolean ok
---@return integer|string nOrErr the number removed, or 'missing' | 'by'
function CoreSceneAudio.kill(target, by) end
---(server) The audio policy's counters (sources, streams, resolving, plays, kills, refusals, …).
---@return table
function CoreSceneAudio.stats() end

---@class Core.Scene.voice
local CoreSceneVoice = {}
---(server) Routes the talker's voice through speaker nodes to the players near them (panned per listener;
---needs `setr voice_useNativeAudio true` for panning). ≤ 1 session per talker, ≤ Voice.MaxSessions. Audited.
---@param def CoreSceneVoiceDef
---@return integer|nil sessionId
---@return string|nil err 'def' 'talker' 'fx' 'range' 'speakers' 'missing' 'bucket' 'busy' 'limit' | 'unavailable'
function CoreSceneVoice.start(def) end
---(server) Ends a session (its owner or core).
---@param sessionId integer
---@return boolean ok
---@return string|nil err 'missing' | 'owner'
function CoreSceneVoice.stop(sessionId) end
---(server)
---@return CoreSceneVoiceSession[]
function CoreSceneVoice.list() end

---@class Core.Scene
---@field audio Core.Scene.audio
---@field voice Core.Scene.voice
---@field PAINTS integer[][] (shared) the 22 stable vehicle paints { primary, secondary } (read-only)
Core.Scene = {}

---(server) Creates a node. Validation order: kind → fields → pose → rotation (motion) → model → parent / deps →
---audience, interact, authority, radius → limits → the 'scene:beforeSpawn' pipeline → (audio.source) admission.
---@param def CoreSceneSpawnDef
---@return integer|nil id
---@return string|nil err 'unavailable' 'def' 'kind' 'fields' 'pos' 'rot' 'offset' 'offrot' 'bone' 'rotOrder' 'motion' 'motion_future' 'model' 'parent' 'deps' 'audience' 'interact' 'authority' 'radius' 'global' 'persist' 'bucket' 'limit' 'hook' 'owner' 'allowChildren' 'audio_*'
---@return table|string|nil detail Schema errors for 'fields' — `{ [name] = 'reserved' }` when a non-core caller sets mapEl / mapType / vehId — the hook's reason, …
function Core.Scene.spawn(def) end
---(server) Merges `patch` into the fields (the result is checked whole; nil in a patch does not delete — use
---opts.remove). Owner or core.
---@param id integer
---@param patch? table
---@param opts? CoreSceneSetOpts
---@return boolean ok
---@return string|nil err
---@return table|nil detail
function Core.Scene.set(id, patch, opts) end
---(server) A teleport (absolute motions end; spin / osc stay) or, with a duration, a tween from the current pose.
---For a child or an attached node `pos` / `rot` are its offset / offrot (no tween; opts.rotOrder 0..5 replaces its
---rotation order, kept when absent).
---@param id integer
---@param pos vector3|table
---@param rot? vector3|table
---@param opts? { duration?: integer, ease?: 'linear'|'in'|'out'|'inout', rotOrder?: integer } duration 1..600000 ms, ease default 'inout'
---@return boolean ok
---@return string|nil err
function Core.Scene.move(id, pos, rot, opts) end
---(server) Sets (or with nil clears) the node's motion. Roots only.
---@param id integer
---@param desc CoreSceneMotion|nil
---@return boolean ok
---@return string|nil err
---@return string|nil detail the validator's reason
function Core.Scene.motion(id, desc) end
---(server) `{ node = id }` re-parents (same bucket, depth ≤ 4, no cycle, a foreign parent must allow it);
---`{ player = src }` / `{ net = netId }` attach a root (transient: they end at the last pose when the player drops or
---the entity goes).
---@param id integer
---@param target { node?: integer, player?: integer, net?: integer }
---@param opts? { offset?: vector3, offrot?: vector3, bone?: integer|string, rotOrder?: integer } rotOrder 0..5 (default 2): the order offrot is applied in
---@return boolean ok
---@return string|nil err
function Core.Scene.attach(id, target, opts) end
---(server) A child becomes a root at its current world pose; an attachment ends there.
---@param id integer
---@return boolean ok
---@return string|nil err
function Core.Scene.detach(id) end
---(server) A one-shot event to the clients near a node (owner or core) or a position (anyone): client
---`Scene.on('event')`, a plugin kind's `event` handler; `sound` nodes hear 'play' / 'stop'. Not journaled.
---@param target integer|{ pos: vector3, bucket?: integer }
---@param name string `^[%w_%-:%.]+$`, ≤ 32
---@param params? table ≤ 1 KiB
---@param opts? { radius?: number, horizonMs?: integer } radius 1..TierL (default the node's, 150 m for a position); horizonMs 0..30000 (2000)
---@return boolean ok
---@return string|nil err
function Core.Scene.emit(target, name, params, opts) end
---(server) Removes the node and its subtree (a source takes its emitters). `fade` asks clients for a fade-out;
---they delete visibility-safely either way.
---@param id integer
---@param opts? { fade?: boolean }
---@return boolean ok
---@return string|nil err
function Core.Scene.remove(id, opts) end
---(server) Server-steered dead reckoning (C2): the first call makes the node's motion a `dr`; later calls send a DR
---op only when the clients' extrapolation errs > DeadReckoning.Near (far: .Far) m or > .Degrees, or on the heartbeat.
---Roots only; |vel| ≤ 300 m/s.
---@param id integer
---@param pos vector3|table
---@param vel? vector3|table m/s
---@param yaw? number degrees (default the node's)
---@return boolean ok
---@return boolean|string sentOrErr
function Core.Scene.drive(id, pos, vel, yaw) end
---(server) A copy of a node. (client) A copy of a cached node (`state` = the materialiser's).
---@param id integer
---@return CoreSceneNode|CoreSceneClientNode|nil
function Core.Scene.get(id) end
---(server) Copies of the nodes within `radius` of `pos`, nearest first (gated nodes included).
---@param q CoreSceneQuery
---@return CoreSceneNode[]
function Core.Scene.query(q) end
---(server) Node ids, ascending.
---@param filter? { owner?: string, kind?: string, bucket?: integer }
---@return integer[]
function Core.Scene.list(filter) end
---(server) Runs `fn(...)`: every change inside reaches the same flush. `fn` must not yield.
---@param fn function
---@param ... any
---@return any ... fn's results, or nil, 'error' | 'fn'
function Core.Scene.batch(fn, ...) end
---(server) Hooks: 'spawned' | 'changed' (what) | 'removed' (reason) | 'promoted' (netId) | 'demoted' (info:
---CoreSceneDemotedInfo) — fn(copy, ...) for a kind id, a node id or '*' (pcall'ed; owner-tracked 'sceneListener').
---(client) 'live' | 'gone' | 'changed' | 'event' | 'enter' | 'exit' | 'promoted' | 'demoted' — fn(id, info), run in
---the caller's VM; core raises the local event only for what some resource listens to.
---@param event CoreSceneServerEvent|CoreSceneClientEvent
---@param kindOrId string|integer|nil a kind id, a node id or '*' (nil = '*')
---@param fn fun(a: any, b: any, ...)
---@return string|integer|nil handle server 'sl:<n>', client an integer
function Core.Scene.on(event, kindOrId, fn) end
---(server) Removes a Scene.on / onInteract handle (its owner or core). (client) Removes a Scene.on listener.
---@param handle string|integer
---@return boolean removed
function Core.Scene.off(handle) end
---(server) A press of an `interact` descriptor, after core checked the bucket, every audience level, the
---descriptor, `perm`, the server-side distance, the cooldown and a lease. Handlers of the id run first, then the
---kind's; owner-tracked ('sceneInteract').
---@param kindOrId string|integer
---@param fn fun(src: integer, node: CoreSceneNode, action: string, data: table|nil)
---@return string|nil handle 'si:<n>'
function Core.Scene.onInteract(kindOrId, fn) end
---(server) Defines (or, same owner, redefines) a kind. Owner-tracked ('sceneKind'): when the owner stops, its
---nodes stay as placeholders. ≤ 256 new kind ids per plugin per server session.
---@param def CoreSceneKindDef
---@return boolean ok
---@return string|nil err 'def' 'id' 'owner' 'limit' 'class' 'fields' 'fields:reserved:<name>' (a plugin kind may not declare mapEl / mapType / vehId) 'nearFields' 'radius' 'handler' 'authority' 'budget'
function Core.Scene.defineKind(def) end
---(server) The public kind list (no functions): { id, idx, class, fields, nearFields, radius, handler, budget,
---authority, owner, builtin, dependency }.
---@return table[]
function Core.Scene.kinds() end
---(server) The one model-info provider (owner-tracked; nil clears): answer `{ lod?, radius?, bbox = { min, max }?,
---vehicleType? }`, nil (unknown: the Maps validator as an info source, then defaults) or false — the ONLY way a model
---is refused ('model'); a model nobody knows spawns with the defaults. `model` is a name or an integer hash.
---@param fn? fun(class: 'prop'|'vehicle'|'ped', model: string|integer): table|false|nil
---@return boolean ok
function Core.Scene.setModelInfo(fn) end
---(server) Counters. (client) The client's counters.
---@return CoreSceneStats|CoreSceneClientStats
function Core.Scene.stats() end
---(server) Pins a player's streaming focus to `pos` (a scripted camera far from the ped); nil clears. Trusted,
---owner-tracked ('sceneFocus'); refused for a src nobody is connected as.
---@param src integer
---@param pos vector3|table|nil
---@return boolean ok
function Core.Scene.setFocus(src, pos) end
---(server) Core only: re-owns a node (a persistent node of a resource that is gone).
---@param id integer
---@param owner? string default 'core'
---@return boolean ok
---@return string|nil err 'owner' | 'missing' | 'unavailable'
function Core.Scene.adopt(id, owner) end
---(server) Promotes a node to a networked clone now (owner or core; queued — the clone exists within ~5 s).
---@param id integer
---@return boolean|nil ok
---@return string|nil err
function Core.Scene.promote(id) end
---(server) Forces a promoted node back to local copies, whatever the rest conditions — never a vehicle with someone
---inside ('occupied').
---@param id integer
---@return boolean|nil ok
---@return string|nil err 'not_promoted' | 'occupied' | …
function Core.Scene.demote(id) end
---(server) Reserves a node for one player: the first request wins, the holder renews with its `seq`, `ms = 0`
---releases; other players' interactions with the promoted node are refused and it never demotes while leased.
---@param id integer
---@param src integer
---@param ms? integer 0..3600000, default Config.Scene.Promote.LeaseMs (10000)
---@param seq? integer the holder's sequence number (renew / release)
---@return integer|nil seq
---@return string|nil err 'missing' 'owner' 'src' 'ms' 'leased' 'stale' 'none'
function Core.Scene.lease(id, src, ms, seq) end

---(client) The entity of a node on this client: its local copy, a plugin's bound entity, or the promoted clone.
---@param id integer
---@return integer|nil entity
function Core.Scene.handleOf(id) end
---(client) The node id of an entity the runtime created, a plugin bound, or a promoted node's clone.
---@param entity integer
---@return integer|nil id
function Core.Scene.idOf(entity) end
---(client) True when the cells around `pos` are current and every node within `radius` a camera there would
---want is materialised (or failed, or capped) — and no large map change is still being projected there (maps pending).
---@param pos vector3|table
---@param radius? number default 50, ≤ 500
---@return boolean
function Core.Scene.isAreaReady(pos, radius) end
---(client) Waits in the calling thread until `isAreaReady(pos, radius)` or the timeout. It only waits.
---@param pos vector3|table
---@param radius? number default 50, ≤ 500
---@param timeoutMs? integer default 5000, ≤ 60000
---@return boolean ready
function Core.Scene.waitAreaReady(pos, radius, timeoutMs) end
---(client) The runtime leaves the node's entity alone (no move, re-create or delete) until released; returns the
---entity when there is one. Owner-tracked ('sceneHold').
---@param id integer
---@return integer|nil entity
function Core.Scene.hold(id) end
---(client) Gives the caller's hold back; what changed meanwhile applies now.
---@param id integer
---@return boolean released
function Core.Scene.release(id) end
---(client, the caller's VM) This resource draws the nodes of plugin kind `kind` (defined with `handler` = this
---resource). Core decides WHEN (radius, budget, priority, fades, visibility-safe deletes) and raises one local event
---per state change — never per frame; the handlers run pcall'ed in this VM.
---@param kind string '<resource>:<name>'
---@param handlers CoreScenePluginHandlers
---@return boolean ok
function Core.Scene.handle(kind, handlers) end
---(client, proxy) The lib's half of Scene.on: tells core that this resource listens (owner-tracked).
---@param kindOrId string|integer
---@param event CoreSceneClientEvent
---@return boolean ok
function Core.Scene.listen(kindOrId, event) end
---(client, proxy) The inverse of `listen`.
---@param kindOrId string|integer
---@param event CoreSceneClientEvent
---@return boolean ok
function Core.Scene.unlisten(kindOrId, event) end
---(client, proxy) The lib's half of Scene.handle: this resource draws `kind` (a second resource is refused while the
---first runs). Owner-tracked ('sceneHandler').
---@param kind string
---@return boolean ok
function Core.Scene.claim(kind) end
---(client, proxy) The lib reports what the plugin's create returned (0 = none). false = the node is no longer wanted
---(the plugin deletes its entity); false, 'refused' = a player ped, a networked entity or one core owns (ignored).
---@param id integer
---@param entity integer
---@return boolean ok
---@return string|nil why 'refused'
function Core.Scene.bind(id, entity) end

---(shared) Is `id` a well-formed kind id (a plugin '<resource>:<name>' or a reserved plain id)?
---@param id any
---@return boolean
function Core.Scene.validKindId(id) end
---(shared) Is `id` the plugin form '<resource>:<name>'?
---@param id any
---@return boolean
function Core.Scene.isPluginKind(id) end
---(shared) The streaming tier of a radius: S ≤ TierS (160), M ≤ TierM (448), else L; G when global.
---@param radius number
---@param global? boolean
---@return CoreSceneTier
function Core.Scene.tierOf(radius, global) end
---(shared) The stable paint of vehicle node `id` (PAINTS[id % 22 + 1]): the same on the promoted clone and on
---every client's local copy.
---@param id integer
---@return integer|nil primary
---@return integer|nil secondary
function Core.Scene.paintOf(id) end
---(shared) The damage / wear keys of vehicle props `{ [key] = true }`: engineHealth, bodyHealth, tankHealth, dirtLevel,
---fuelLevel, doors, windows, burstTyres, tyreHealth — the ONLY keys a props read-back from a clone's network owner may
---change (everything else goes through saveProps / server APIs).
---@type table<string, true>
Core.Scene.WEAR = {}
---(shared) Splits vehicle props into two fresh tables (either may be empty): the non-WEAR and the WEAR keys.
---@param props table
---@return table cosmetic
---@return table wear
function Core.Scene.splitProps(props) end
---(shared) A fresh copy of `stored` with ONLY the WEAR keys of `readBack` merged in, clamped: healths 0..1000 (a restored
---car never burns), dirt 0..15, fuel 0..100, doors / windows / burstTyres `{ [0..7] = boolean }`, tyreHealth
---`{ [0..7] = 0..1000 }` (a read-back map replaces the stored one); unknown / non-finite values are dropped (the stored
---value stays); `stored` is untouched.
---@param stored table
---@param readBack table
---@return table merged
function Core.Scene.mergeWear(stored, readBack) end
