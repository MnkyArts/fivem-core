# core — framework design contract

This file is the binding contract between every file of the `core` resource, the Vue UI shell, and every
plugin resource that imports it. Implementers follow it exactly: same global names, same function
signatures, same event names, same state-bag keys, same NUI message shapes, same config keys. If something
here is ambiguous, note it in your report — never invent a different shape.

Rulebook: the `fivem-scripting` skill (Lua 5.4, standalone, no ox_lib, resmon-friendly, server-authoritative).
Rule zero: **the server owns every gameplay fact (money, factions, ownership, permissions, spawns). The
client renders, reads input and asks. Plugins reuse `Core.*` APIs instead of building their own.**

---

## 0. What this is

A FiveM framework for a GTA-Online-flavoured RP server (factions, rules, OOC-heavy). Inspired by Rebar
(alt:V): one framework resource with deep reusable APIs on both sides, one real UI (a single Vue 3 CEF page
hosted by `core`), and "plugins". In FiveM the plugin unit is simply **another resource** that declares
`dependency 'core'` and includes `@core/import.lua` — it gets the `Core` global, can start/stop/restart on its
own, and everything it registers in core (markers, interactions, blips, text labels, UI pages) is removed
automatically when it stops.

Three layers:

| Layer | Lives in | Reached by plugins via |
|---|---|---|
| **libs** — pure helpers that run *inside the plugin's own VM* (no cross-resource hop): Utils, Math, Validate, Log, Callback, Net, Keys, Streaming, Anim, Commands, client Player reads | `core/lib/<module>/{shared,client,server}.lua`, lazily loaded by `import.lua` | `Core.Utils.x()` … |
| **core modules** — stateful systems that run inside `core`: server Player/Money/Factions/Perms/Vehicles/DB/Notify, client Interactions/Markers/TextLabels/Blips/UI/Vehicles/Raycast/Spawn | `core/server/*.lua`, `core/client/*.lua` | the same `Core.X.y()` syntax; `import.lua` proxies unknown functions through **one export** (`exports.core:call`) |
| **UI shell** — Vue 3 app (Vite build → `core/html/`) with built-in components (notify, text UI, progress, menu, input, alert, HUD) and a page host that loads plugin page bundles into the same CEF | `core/ui/` (source), `core/html/` (build output) | `Core.UI.*` from Lua, `window.CoreUI` from a plugin's Vue bundle |

Non-goals for v1 (plugin territory, documented as such): inventory/items, jobs, hunger/thirst, character
creator, garages, housing, chat replacement, Discord logging, MySQL adapter (the DB has an adapter seam).

---

## 1. Files and load order

```
core/
  fxmanifest.lua
  DESIGN.md                      this file
  PLAN.md                        implementation plan (runs, natives per file)
  README.md                      integrator guide (how to write a plugin, API cheat sheet, test checklist)
  import.lua                     THE consumer include (@core/import.lua) — also loaded by core itself first
  shared/config.lua              Config table (§10)
  lib/utils/shared.lua           Core.Utils
  lib/math/shared.lua            Core.Math
  lib/validate/shared.lua        Core.Validate
  lib/log/shared.lua             Core.Log
  lib/callback/shared.lua        Core.Callback (client+server halves, branches on IsDuplicityVersion)
  lib/net/shared.lua             Core.Net (validated net events; branches on side)
  lib/commands/shared.lua        Core.Commands (typed commands; branches on side)
  lib/keys/client.lua            Core.Keys
  lib/streaming/client.lua       Core.Streaming
  lib/anim/client.lua            Core.Anim
  lib/player/client.lua          Core.Player (client read side: state-bag readers)
  lib/ui/client.lua              Core.UI.on / Core.UI.off sugar (in-VM), everything else proxied
  client/main.lua                boot, load request, ready flags, death watch, onResourceStop
  client/spawn.lua               Core.Spawn (spawnPlayer, applyAppearance, teleport)
  client/player.lua              client Player extras (cached public data, setModel handler)
  client/world.lua               World scheduler: visible sets + the single draw loop (markers + labels)
  client/markers.lua             Core.Markers
  client/textlabels.lua          Core.TextLabels
  client/blips.lua               Core.Blips
  client/interactions.lua        Core.Interactions
  client/vehicles.lua            Core.Vehicles (client)
  client/raycast.lua             Core.Raycast
  client/ui.lua                  Core.UI (NUI bridge, focus stack, pages, built-ins, notify queue)
  client/api.lua                 `call` export + owner registry + cleanup on owner stop
  server/main.lua                boot, ready, GlobalState, autosave loop, onResourceStop
  server/db.lua                  Core.DB (document store, KVP adapter)
  server/player.lua              Core.Player (sessions, load/save, data, state replication)
  server/money.lua               Core.Money
  server/perms.lua               Core.Perms
  server/factions.lua            Core.Factions (+ faction callbacks)
  server/vehicles.lua            Core.Vehicles (server) (+ lock/props net events)
  server/notify.lua              Core.Notify (server)
  server/admin.lua               admin + utility commands
  server/api.lua                 `call` export + owner registry
  ui/                            Vite + Vue 3 source of the shell (§7)
  html/                          BUILD OUTPUT of ui/ (committed; `ui_page 'html/index.html'`)
  templates/plugin/              copy-me plugin skeleton (fxmanifest, client/server/shared, ui/ vite config)
  tests/run_tests.lua            `lua5.4 tests/run_tests.lua` — offline tests for the pure libs + import loader
core_example/                    the example plugin (§11) — separate resource next to core/
```

Manifest (explicit order; no globs for lib files — they are not scripts, they are `files`):

```lua
fx_version 'cerulean'
game 'gta5'
author 'MnkyArts'
description 'Framework core: shared APIs (player, money, factions, vehicles, interactions, markers, UI) for GTA-Online-style RP servers'
version '1.0.0'

shared_scripts { 'import.lua', 'shared/config.lua' }
client_scripts {
    'client/api.lua', 'client/world.lua', 'client/markers.lua', 'client/textlabels.lua', 'client/blips.lua',
    'client/interactions.lua', 'client/ui.lua', 'client/vehicles.lua', 'client/raycast.lua',
    'client/spawn.lua', 'client/player.lua', 'client/main.lua',
}
server_scripts {
    'server/api.lua', 'server/db.lua', 'server/notify.lua', 'server/perms.lua', 'server/player.lua',
    'server/money.lua', 'server/factions.lua', 'server/vehicles.lua', 'server/admin.lua', 'server/main.lua',
}
ui_page 'html/index.html'
files { 'import.lua', 'shared/config.lua', 'lib/**/shared.lua', 'lib/**/client.lua', 'html/**' }
```

`client/api.lua` / `server/api.lua` load **first** because they define the owner registry other modules
register cleanup hooks into. `main.lua` loads **last** on both sides.

Deliberate globals (everything else `local`): `Config` (config.lua) and `Core` (import.lua). Module files
assign `Core.<Name> = { ... }` (server/client modules) or add functions to the table `import.lua` already
created for lib modules. No other globals.

A plugin's manifest:

```lua
fx_version 'cerulean'
game 'gta5'
dependency 'core'
shared_scripts { '@core/import.lua', 'shared/config.lua' }
client_scripts { 'client/*.lua' }
server_scripts { 'server/*.lua' }
-- no `files {}` for UI: plugin pages are compiled into core's bundle (§7.4)
```

---

## 2. `import.lua` — the consumer include

Runs in **every** VM that includes it (core's own VMs included). ~200 lines, pure Lua plus a handful of
shared natives (`GetCurrentResourceName`, `IsDuplicityVersion`, `LoadResourceFile`, `GetResourceState`,
`GetGameTimer`). It must never call a client-only or server-only native at file scope.

```lua
Core = {
    name = GetCurrentResourceName(),   -- the VM's own resource name
    isServer = IsDuplicityVersion(),
    isClient = not IsDuplicityVersion(),
    isCore = (GetCurrentResourceName() == 'core'),
    version = '1.0.0',
}
```

### 2.0 `Core.Config` — core's config in every VM

Inside a plugin's VM the global `Config` is the **plugin's own** config (or nil). Libs therefore never read
`Config` directly; they read `Core.Config`, which import.lua provides lazily: inside core (`Core.isCore`) it is
the `Config` global itself; elsewhere the first access loads `shared/config.lua` from core's files with
`load(LoadResourceFile('core', 'shared/config.lua'), '@core/shared/config.lua', 't', env)` into a private
environment (`env` falls back to `_G` for `vector3` etc.) and returns `env.Config`. `shared/config.lua` is in
core's `files` list for that reason. Libs keep the DESIGN §10 defaults as fallbacks in case a key is missing.

### 2.1 Lazy lib modules

`LIB_MODULES` (in import.lua) maps namespace → file set:

```lua
local LIB_MODULES = {
    Utils = 'utils', Math = 'math', Validate = 'validate', Log = 'log', Callback = 'callback',
    Net = 'net', Commands = 'commands', Keys = 'keys', Streaming = 'streaming', Anim = 'anim',
    Player = 'player', UI = 'ui',
}
```

On first access of `Core.<Name>`, the loader creates the namespace table, then for each of
`lib/<dir>/shared.lua`, `lib/<dir>/<side>.lua` (side = `client`|`server`) that exists
(`LoadResourceFile('core', path)` returns a non-empty string) it compiles the chunk with
`load(code, '@core/' .. path, 't', _ENV)` and calls it with the namespace table as its single argument
(`chunk(ns)`); a chunk adds functions to `ns` and returns nothing. This is the standard FiveM library
pattern (ox_lib does the same) — the file path is fixed and comes from core's own packfile, so the
`fxlint` S006 finding is suppressed on that one line with a justification comment:
`-- fxlint-disable-next-line S006 -- fixed path inside core's own resource files, not user input`.

Every namespace table — lib or not — gets a metatable whose `__index` is the **export proxy** (§2.2), so a
function that is not implemented in-VM transparently reaches core. Namespaces that are not in `LIB_MODULES`
are pure proxies (`Core.Markers`, `Core.Interactions`, `Core.Blips`, `Core.TextLabels`, `Core.Vehicles`,
`Core.Raycast`, `Core.Spawn`, `Core.DB`, `Core.Money`, `Core.Factions`, `Core.Perms`, `Core.Notify`). Inside
core itself (`Core.isCore`), the proxy is never installed — core's module files assign the real tables and a
missing function is a plain `nil` (so a typo inside core fails loudly at call time, as it should).

Server-only sugar: `Core.Player` on the server gets `__call`: `Core.Player(src)` returns a handle
`{ src = src }` whose metatable `__index` turns `handle:addMoney('cash', 10)` into
`Core.Player.addMoney(src, 'cash', 10)` (works for every `Core.Player.*` and, for convenience, `Core.Money.*`
via `handle.money` → `handle.money:add('cash', 10)`) — keep it to those two).

### 2.2 The export proxy (`exports.core:call`)

Both sides of core register exactly one export:

```lua
exports('call', function(caller, namespace, fn, ...)
    -- caller: resource name passed by the proxy; namespace/fn: strings; ...: arguments
    local ns = Core[namespace]
    local f = ns and rawget(ns, fn)
    if type(f) ~= 'function' then error(('core: no API %s.%s'):format(tostring(namespace), tostring(fn))) end
    Core.Registry.setCaller(caller)         -- §2.3: registration APIs read the current caller
    return f(...)
end)
```

The proxy in import.lua: `Core.<Ns>.<fn>(...)` → `exports.core:call(Core.name, '<Ns>', '<fn>', ...)`; the
generated closure is cached per (namespace, fn). Multiple return values pass through. A core function that
`Wait`s (e.g. `Core.UI.menu.open`) still works: the runtime turns a yielding export into a promise that the
caller awaits — callers must therefore be inside a coroutine (thread, event handler, command), which every
normal call site is. Cost: one msgpack hop per call — fine for everything in this design, which never calls
core per frame; per-frame work (drawing, proximity) runs inside core's own loops.

Nested namespaces (`Core.UI.menu.open`) are represented as **flat function names with a dot**:
`Core.UI.menu.open(...)` is `call(caller, 'UI', 'menu.open', ...)`; the proxy builds sub-proxies for one
nesting level (`Core.UI.menu`, `Core.UI.input`, `Core.UI.alert`, `Core.UI.progress`, `Core.UI.textUI`,
`Core.UI.hud`) and core's `UI` table stores those functions under the dotted key
(`Core.UI['menu.open'] = function(opts) ... end`) **and** as `Core.UI.menu.open` for internal use.

### 2.3 Owner registry and automatic cleanup (`Core.Registry`, in api.lua on both sides)

```lua
Core.Registry.setCaller(name)      -- called by the `call` export before dispatch
Core.Registry.getCaller() -> name  -- 'core' when called internally
Core.Registry.track(kind, id, owner)   -- kinds: 'marker', 'label', 'blip', 'interaction', 'page', 'vehicle'
Core.Registry.untrack(kind, id)
Core.Registry.onOwnerStop(kind, fn(id, owner))  -- module registers its remover once at file scope
```

`AddEventHandler('onResourceStop', function(res) ... end)` in api.lua walks every tracked id of that owner
and calls the kind's remover. Vehicles are tracked for bookkeeping only — they are **not** deleted when the
spawning plugin stops (only when core stops).

### 2.4 Hooks, readiness, restarts

- `Core.on(hook, fn)` = `AddEventHandler('core:hook:' .. hook, fn)`; `Core.emitHook(hook, ...)` =
  `TriggerEvent('core:hook:' .. hook, ...)` (used by core; plugins may emit their own hooks too).
- `Core.isReady()` → `GetResourceState('core') == 'started'` and (client) `LocalPlayer.state.loaded == true`
  is **not** required — readiness is "core is running", player-loaded is a separate hook.
- `Core.onReady(fn)`: runs `fn` once as soon as core is started (polls `GetResourceState('core')` every 100 ms
  for up to 30 s, then errors to console) **and again after every core restart** (`onResourceStart` /
  `onClientResourceStart` for `core`). Registration calls into core (markers, interactions, blips, labels,
  pages, server-side hooks that need sessions) belong inside `Core.onReady`; in-VM registrations (keys,
  callbacks, net handlers, commands) stay at file scope.
- `Core.onPlayerLoaded(fn)` (client): runs `fn` immediately if `LocalPlayer.state.loaded == true`, else on the
  `playerLoaded` hook. (Server: use `Core.on('playerLoaded', function(src) end)`.)

---

## 3. Libs (run in the caller's VM)

Every lib chunk has the shape `local ns = ...` (the namespace table) followed by `function ns.x(...) end`
definitions and `local` helpers. Libs never keep per-player state on the server except the small tables
noted below, and they clear those in `playerDropped`.

### 3.1 `Core.Utils` (`lib/utils/shared.lua`, pure)

```lua
Utils.isInteger(v) -> bool           -- math.type(v) == 'integer'
Utils.isNumber(v) -> bool            -- number and finite (v == v, not inf)
Utils.isString(v, maxLen?) -> bool   -- non-empty string, optional #v <= maxLen
Utils.isBool(v), Utils.isTable(v), Utils.isVector3(v) (type(v) == 'vector3'), Utils.isFunction(v)
Utils.clamp(n, lo, hi), Utils.round(n, decimals?), Utils.lerp(a, b, t)
Utils.deepCopy(t) -> t'              -- copies nested tables; vectors and other values by reference
Utils.merge(base, override) -> base  -- deep merge in place, override wins; arrays replaced not merged
Utils.keys(t), Utils.values(t), Utils.count(t), Utils.isEmpty(t)
Utils.contains(arr, v) -> bool, Utils.indexOf(arr, v) -> i|nil, Utils.removeValue(arr, v) -> bool
Utils.map(t, fn(v, k)), Utils.filter(t, fn(v, k)) -> array, Utils.find(t, fn(v, k)) -> v, k
Utils.split(s, sep) -> array, Utils.trim(s), Utils.startsWith(s, p), Utils.endsWith(s, p)
Utils.capitalize(s), Utils.truncate(s, n)
Utils.sanitize(s, maxLen) -> string  -- tostring, strip control chars (%c), trim, cut to maxLen (default 64)
Utils.uuid() -> 32-hex string        -- math.random based; math.randomseed() called once at lib load
Utils.randomInt(lo, hi), Utils.randomString(len, alphabet?)
Utils.formatMoney(n) -> '$1,234'     -- integer input; negative → '-$1,234'
Utils.hash(s) -> integer             -- GetHashKey; numbers pass through
Utils.now() -> integer               -- GetGameTimer()
Utils.tableToVector3(t) / Utils.vector3ToTable(v)   -- {x=,y=,z=} <-> vector3 (JSON-safe form)
Utils.jsonSafe(v) -> v'              -- deep copy converting vector2/3/4 into {x,y,z,w} tables
```

### 3.2 `Core.Math` (`lib/math/shared.lua`, pure)

```lua
Math.distance(a, b) -> number  (#(a - b)),  Math.distance2d(a, b)
Math.headingToDirection(h) -> vector3, Math.directionToHeading(dir) -> number, Math.normalizeHeading(h)
Math.rotationToDirection(rot) -> vector3           -- GTA rotation (degrees, vector3) → unit forward vector
Math.offset(coords, heading, forward, right, up) -> vector3
Math.isInsideSphere(p, center, radius), Math.isInsideBox(p, min, max)
Math.deg2rad(d), Math.rad2deg(r), Math.roundVector(v, decimals)
```

### 3.3 `Core.Validate` (`lib/validate/shared.lua`, pure) — the one input validator

```lua
Validate.check(schema, ...) -> ok:boolean, err:string|nil       -- positional args against a schema array
Validate.checkTable(schema, t) -> ok, err                       -- keyed table against { key = spec }
Validate.value(spec, v) -> ok, err                              -- one value
```

A `spec` is a string or a table:

| spec | accepts |
|---|---|
| `'integer'` | `math.type(v) == 'integer'` |
| `'number'` | finite number |
| `'string'` | string (empty allowed only with `allowEmpty = true`) |
| `'boolean'`, `'table'`, `'function'`, `'any'` | by `type()` |
| `'vector3'` | `type(v) == 'vector3'`, all components finite |
| `'netId'` | integer 1..65535 |
| `'src'` | integer 1..4096 |
| `'id'` | string of 1..64 chars matching `^[%w_%-:]+$` (document ids, faction ids, page ids) |
| `{ 'integer', min = 1, max = 100 }` | range on integer/number |
| `{ 'string', max = 32, min = 1, pattern = '^[%w_]+$' }` | length + Lua pattern |
| `{ 'enum', 'cash', 'bank' }` | one of the listed values |
| `{ 'array', of = spec, max = 50 }` | sequential table, every element matches `of`, `#t <= max` |
| `{ 'table', keys = { name = spec, ... }, max = 64 }` | keyed table via `checkTable`; `max` = max key count |
| any spec string with a trailing `?` (`'integer?'`) or table with `optional = true` | also accepts `nil` |

Errors read `arg 2: expected integer 1..100, got -5`. `Validate` never throws.

### 3.4 `Core.Log` (`lib/log/shared.lua`)

`Log.info(fmt, ...)`, `Log.warn`, `Log.error`, `Log.debug` (no-op unless `Config.Debug`), all
`string.format`-style, printed as `[core:<resource>] level: message` (`^3`/`^1` colour prefixes for
warn/error). Server-only `Log.audit(category, src, fmt, ...)` prints `[core:audit] <category> src=<n> <msg>`
and emits the local hook `core:hook:audit (category, src, message)` for a logging plugin. Never log
identifiers beyond `src` + player name.

### 3.5 `Core.Callback` (`lib/callback/shared.lua`) — promise based, from `patterns/callback.lua`

```lua
-- server
Callback.register(name, fn(src, ...) -> ...)        -- registers RegisterNetEvent('core:cb:req:' .. name)
Callback.awaitClient(src, name, ...) -> ... | nil    -- ask one client; nil on timeout/error
-- client
Callback.register(name, fn(...) -> ...)
Callback.await(name, ...) -> ... | nil               -- ask the server; nil on timeout/error
```

Wire: request event `core:cb:req:<name>` carries `(key, ...)`; response event `core:cb:res:<name>` carries
`(key, ok, ...)`. `key = Core.name .. ':' .. counter` (unique across VMs). Each VM registers the response
event for a name lazily, once, and only resolves keys it owns. Timeout `Config.CallbackTimeoutMs`. The
server's request handler applies a per-src limiter (`Config.RateLimits.CallbackPerSecond`, token bucket
in a table cleared in `playerDropped`) and `pcall`s the handler; a handler error answers `ok = false` and
logs. Names are global strings; the convention is `<resource>:<name>` (`core:faction:create`,
`core_example:getStats`).

### 3.6 `Core.Net` (`lib/net/shared.lua`) — validated net events

```lua
-- server
Net.on(name, schema, handler(src, ...), opts?)
--   opts = {
--     cooldown = 250,                 -- ms per src (0 disables); table keyed by src, cleared in playerDropped
--     requireLoaded = true,           -- Player(src).state.loaded must be true
--     permission = 'core.admin',      -- IsPlayerAceAllowed(src, permission) (in-VM; group fallback is Core.Perms)
--     distance = { coords = vector3 | fn(src, ...) -> vector3|nil, max = 5.0 },  -- #(GetEntityCoords(GetPlayerPed(src)) - coords) <= max
--     onReject = fn(src, reason),     -- optional; default: Core.Log.debug
--   }
Net.emit(src, name, ...)             -- TriggerClientEvent
Net.emitMany(targets, name, ...) -> sent  -- targets = src[]; msgpack-packs the payload ONCE, then one
                                     -- TriggerClientEventInternal per target (TriggerClientEvent packs per call).
                                     -- Scoped delivery ("the players near X"); non-integer / < 1 entries are skipped.
Net.broadcast(name, ...)             -- TriggerClientEvent(name, -1, ...); never from a loop, and never for
                                     -- something only nearby players need: -1 is one reliable packet to EVERY
                                     -- connected client (2,000 players = 2,000 packets per call) — use emitMany.
-- client
Net.on(name, schema, handler(...))   -- server → client events, schema-checked (catches bugs, not cheaters)
Net.emit(name, ...)                  -- TriggerServerEvent
```

Order inside the server wrapper, exactly: `local src = source` → schema (`Validate.check`) → cooldown →
requireLoaded → permission → distance → `handler(src, ...)` (in `pcall`; errors logged with the event name).
Rejections never reply to the client (silent), except `onReject`.

### 3.7 `Core.Commands` (`lib/commands/shared.lua`) — typed commands

```lua
Commands.register(name, opts, handler(src, args, raw))
-- opts = {
--   description = 'Spawn a vehicle',
--   params = { { name = 'model', type = 'string', help = 'vehicle model' },
--              { name = 'plate', type = 'string', optional = true } },
--   permission = 'core.admin',   -- server: checked with Core.Perms.has(src, permission); console (src 0) always passes
--   allowConsole = true,
-- }
```

Param types: `string` (one word), `integer`, `number`, `player` (integer server id that must be connected,
resolved with `GetPlayerName(id) ~= nil` on the server / passed through on the client), `rest` (the remainder
of the line, must be last), `boolean` (`true/false/1/0/on/off`). The wrapper registers
`RegisterCommand(name, wrapper, false)` (the permission check is done in the wrapper so the group fallback of
`Core.Perms` works; the `restricted` flag stays `false` deliberately — fxlint S005 is suppressed with a
comment explaining that `Core.Perms.has` guards the command). `args` is keyed by param name; on a
validation failure the caller gets `Usage: /name <model> [plate]` via `Core.Notify.send(src, msg, 'error')`
(server, src > 0) / `print` (console) / `Core.UI.notify` (client). The server keeps `registered[name] = opts`
and sends `chat:addSuggestion` for every command the player may use on `core:hook:playerLoaded` (targeted to
that src) — never `-1` broadcasts. Client-side registrations add the suggestion locally with
`TriggerEvent('chat:addSuggestion', ...)`.

### 3.8 `Core.Keys` (`lib/keys/client.lua`)

```lua
Keys.register({ name = 'menu', description = 'Open the menu', key = 'F5', mapper = 'keyboard',
                onPress = fn(), onRelease = fn()?, debounce = 250 }) -> commandName
```

Registers `RegisterCommand('+' .. Core.name .. '_' .. name, ...)` and the matching `-` command, then
`RegisterKeyMapping('+' .. Core.name .. '_' .. name, description, mapper, key)`. Ignores presses while
`IsNuiFocused()` or `IsPauseMenuActive()` unless `opts.whileFocused = true`. Debounced per key. Zero
per-frame cost.

### 3.9 `Core.Streaming` (`lib/streaming/client.lua`) — from `patterns/model-loading.lua`

`requestModel(model, timeoutMs?) -> bool`, `releaseModel(model)`, `requestAnimDict(dict, timeoutMs?)`,
`releaseAnimDict(dict)`, `requestAnimSet(set, timeoutMs?)`, `releaseAnimSet(set)`, `requestPtfx(name,
timeoutMs?)`, `releasePtfx(name)`, `requestCollision(coords, timeoutMs?) -> bool` (RequestCollisionAtCoord +
HasCollisionLoadedAroundEntity(PlayerPedId()) polling). Default timeout `Config.StreamingTimeoutMs` (10000).

### 3.10 `Core.Anim` (`lib/anim/client.lua`)

`Anim.play(ped, dict, clip, { flags = 1, duration = -1, blendIn = 8.0, blendOut = -8.0, playbackRate = 0.0,
lockX = false, lockY = false, lockZ = false }) -> bool` (loads the dict with timeout, plays, releases the dict),
`Anim.stop(ped, dict?, clip?)` (StopAnimTask when dict+clip given, else ClearPedTasks),
`Anim.isPlaying(ped, dict, clip) -> bool`.

### 3.11 `Core.Player` client lib (`lib/player/client.lua`) — read side, no hop

```lua
Player.isLoaded() -> bool            -- LocalPlayer.state.loaded == true
Player.get(key) -> value             -- LocalPlayer.state[key] for the replicated keys (§8): 'name','charId','cash','bank','faction','group','dead'
Player.getServerId(), Player.getPed(), Player.getCoords() -> vector3, Player.getHeading()
Player.getFaction() -> table|nil     -- LocalPlayer.state.faction (one read)
Player.isDead() -> bool
Player.onChange(key, fn(value))      -- AddStateBagChangeHandler(key, 'player:' .. serverId, ...) filtered to the local player
```

Anything else on `Core.Player` (client) falls through the proxy to `client/player.lua` (§6.2).

### 3.12 `Core.UI` client sugar (`lib/ui/client.lua`)

`UI.on(pageId, event, fn(data)) -> handle` = `AddEventHandler(('core:ui:%s:%s'):format(pageId, event), fn)`,
`UI.off(handle)` = `RemoveEventHandler`. Everything else on `Core.UI` proxies to `client/ui.lua` (§6.7).

---

## 4. Server modules (run inside core)

### 4.1 `Core.DB` (`server/db.lua`) — document store

Collections of JSON documents, in-memory with a KVP-backed adapter. Documents are plain tables with a
string `id`; nested tables allowed; **no vectors** (call `Core.Utils.jsonSafe` first — `DB.create/set/update`
do it for you). Every returned document is a **deep copy**.

```lua
DB.create(collection, doc) -> id            -- assigns doc.id = Utils.uuid() when absent, doc.createdAt = os.time()
DB.get(collection, id) -> doc | nil
DB.set(collection, id, doc) -> true         -- replace (doc.id forced to id)
DB.update(collection, id, partial) -> bool  -- shallow merge of top-level keys (a nested table value replaces the old one); false if missing
DB.delete(collection, id) -> bool
DB.find(collection, match) -> array         -- match = fn(doc) -> bool | { key = value, ... } (top-level equality)
DB.findOne(collection, match) -> doc | nil
DB.all(collection) -> array, DB.count(collection) -> integer
DB.flush()                                  -- adapter flush now (called by the 5 s timer and onResourceStop)
DB.setAdapter(adapter)                      -- adapter = { loadAll(collection) -> { [id] = jsonString }, put(collection, id, jsonString), remove(collection, id), flush() }
```

KVP adapter (default): key `Config.DB.KeyPrefix .. collection .. ':' .. id` (`doc:characters:<id>`), values
`json.encode(doc)`; `loadAll` enumerates with `StartFindKvp/FindKvp/EndFindKvp` on the prefix; `put` =
`SetResourceKvpNoSync`, `remove` = `DeleteResourceKvpNoSync`, `flush` = `FlushResourceKvp`. A collection is
loaded lazily on first access. `updatedAt = os.time()` is set on every write. Collections used by core:
`accounts`, `characters`, `factions`, `vehicles`, `bans`.

### 4.2 `Core.Player` (`server/player.lua`) — sessions and persistence

Documents:

```lua
-- accounts: one per license identifier
{ id, license = 'license:...', identifiers = { license, discord, fivem, steam }, name = 'last known name',
  group = 'user', firstSeen = os.time(), lastSeen, playtime = 0 (seconds), banned = false }
-- characters: one per account in v1 (accountId lookup; the schema allows more later)
{ id, accountId, name = 'account name', model = Config.Player.DefaultModel, appearance = {} (§6.1),
  position = { x, y, z, heading }, money = { cash = n, bank = n }, faction = { id, rank } | nil,
  stats = { deaths = 0, playtime = 0 }, meta = {} }
-- bans: { id, license, reason, by = 'name', until = os.time() | 0 (permanent), createdAt }
```

Session table (in-memory, `sessions[src]`): `{ src, accountId, charId, license, name, account (live doc),
data (live character doc), dirty = false, loadedAt, deadSince = nil }`. Index `bySrc`, `byCharId`.

Flow:

1. `playerConnecting` (AddEventHandler, deferrals): `defer()` → `Wait(0)` → `update('Checking...')` →
   license identifier required (`done('No license identifier')` otherwise) → active ban in `bans`
   (`until == 0 or until > os.time()`) → `done(reason)`; else `done()`.
2. `playerJoining`: `loadSession(src)` — find/create account (update `lastSeen`, `name`), find/create
   character with `Config.Player.NewCharacter` defaults → session → `replicate(src)` (§8) → mark
   `loaded`. Also runs for every already-connected player in `onResourceStart` (core restart).
3. Client asks `core:server:requestLoad` (§5) → server answers `core:client:loaded (payload)` with
   `payload = { charId, name, model, appearance, position, money, faction, group, respawn = bool }` —
   `respawn = true` on a fresh join, `false` when the session already existed (core restart while the player
   is alive in the world). Then `emitHook('playerLoaded', src)` (only on the first answer per session).
4. Autosave every `Config.Player.SaveIntervalMs`: for each session, refresh `data.position` from
   `GetEntityCoords(GetPlayerPed(src))` + `GetEntityHeading` (skip if ped is 0 or dead), add playtime, save
   dirty ones. The pass is chunked since 2026-09-18 (§9 "Scale"): the srcs are snapshotted, then 25 sessions per
   tick with 250 ms between chunks — a full 2,000-player server is spread over ~20 s instead of three natives and a
   document write per player in ONE tick; below 25 sessions the pass is a single tick as before. `playerDropped`:
   same refresh, `emitHook('playerDropped', src, charId)` **before** removal,
   save, remove session, clear `deadSince`.

API (all take `src`; return `nil`/`false` when there is no loaded session):

```lua
Player.isLoaded(src) -> bool
Player.getInfo(src) -> { src, charId, accountId, name, group, license } | nil   -- copy, cheap
Player.getData(src, path) -> value          -- path 'money.cash' / 'meta.foo' (dot path); returns a deep copy for tables
Player.setData(src, path, value) -> bool    -- dot path; marks dirty; if the top-level key is replicated (§8) → re-replicate that key
Player.save(src) -> bool, Player.saveAll() -> count
Player.getPlayers() -> array of src (loaded only), Player.forEach(fn(src, info)), Player.count()
Player.getSrcByCharId(charId) -> src | nil, Player.getName(src), Player.getLicense(src)
Player.getPed(src) -> ped|0, Player.getCoords(src) -> vector3|nil, heading
Player.setCoords(src, coords, heading?)     -- TriggerClientEvent('core:client:teleport', src, coords, heading)
Player.setModel(src, model, appearance?)    -- validates model is a string ≤ 64; stores; TriggerClientEvent('core:client:setModel', ...)
Player.setBucket(src, bucket) / Player.getBucket(src)
Player.kick(src, reason)                    -- DropPlayer
Player.ban(src, reason, seconds?, by?)      -- writes bans + DropPlayer
Player.notify(src, message, type?, duration?)  -- sugar for Core.Notify.send
Player.respawn(src, coords?, heading?)      -- server-side forced respawn (admin /revive): clears deadSince, TriggerClientEvent('core:client:spawn', src, coords, heading, true)
```

Death: client reports `core:server:died` (§5) → `deadSince[src] = now`, `stats.deaths + 1`,
`Player(src).state:set('dead', true, true)`, hook `playerDied (src)`. `core:server:respawn` → accepted only
if `deadSince` is set and `now - deadSince >= Config.Respawn.DelayMs - 500` → nearest of
`Config.Respawn.Points` to the death coords → `core:client:spawn (coords, heading, true)`, `dead = false`,
hook `playerRespawned (src)`.

### 4.3 `Core.Money` (`server/money.lua`)

Accounts: keys of `Config.Money.Accounts` (`cash`, `bank`). Amounts are **integers** `0..Config.Money.MaxAmount`.

```lua
Money.get(src, account) -> integer
Money.add(src, account, amount, reason?) -> bool           -- amount integer > 0; caps at MaxAmount → false if it would exceed
Money.remove(src, account, amount, reason?) -> bool        -- false if insufficient (no partial removal)
Money.set(src, account, amount, reason?) -> bool           -- admin/reset use
Money.canAfford(src, account, amount) -> bool
Money.transfer(fromSrc, toSrc, account, amount, reason?) -> bool   -- both loaded, remove then add; rolls back on failure
```

Every successful change: `setData(src, 'money', moneyTable)` (replicates `cash`/`bank`), `Log.audit('money',
src, ...)`, `emitHook('moneyChanged', src, account, newAmount, delta, reason or 'unknown')`.

### 4.4 `Core.Perms` (`server/perms.lua`)

```lua
Perms.has(src, perm) -> bool      -- src == 0 → true; IsPlayerAceAllowed(src, perm) → true; else Config.Perms.Groups[group] contains perm (or 'core.admin' implies everything listed under admin)
Perms.getGroup(src) -> string, Perms.setGroup(src, group) -> bool (group must exist in Config.Perms.Groups; persists on the account)
Perms.isAdmin(src) -> bool        -- has('core.admin')
```

### 4.5 `Core.Factions` (`server/factions.lua`)

Document `factions`: `{ id, name, tag, color = '#RRGGBB', ownerCharId, ranks = { { name, perms = { invite=true, ... } }, ... }
(index 1 = lowest), members = { [charId] = { rank = n, name = 'display', joinedAt } }, bank = 0, meta = {}, createdAt }`.
Perms are strings: `invite`, `kick`, `manage_ranks`, `bank`, `manage` (rename/color). The owner has every
perm and cannot be kicked/demoted; ownership transfer via `Factions.setOwner`.

```lua
Factions.create(src, name, tag, opts?) -> id | nil, err   -- validates (§10 Factions.*), charges CreateCost from CostAccount, owner = creator, rank = #DefaultRanks
Factions.disband(src) -> bool, err                        -- owner only; members lose faction; bank is lost (documented)
Factions.get(id) -> doc copy | nil
Factions.list() -> array of { id, name, tag, color, memberCount }
Factions.getPlayerFaction(src) -> { id, name, tag, color, rank, rankName, perms = {...}, isOwner } | nil
Factions.getMembers(id) -> array of { charId, name, rank, rankName, online = src|false }
Factions.hasPerm(src, perm) -> bool
Factions.invite(src, targetSrc) -> bool, err              -- perm invite; target not in a faction; pending[targetSrc] = { factionId, expires }
Factions.acceptInvite(src) -> bool, err                   -- joins at rank 1; MaxMembers enforced
Factions.declineInvite(src)
Factions.leave(src) -> bool, err                          -- owner cannot leave (must disband/transfer)
Factions.kick(src, targetCharId) -> bool, err             -- perm kick; cannot kick owner or higher rank
Factions.setRank(src, targetCharId, rank) -> bool, err    -- perm manage_ranks; rank < own rank unless owner
Factions.setRankDef(src, rank, { name?, perms? }) -> bool, err   -- perm manage_ranks (owner only for rank == #ranks)
Factions.addRank(src, name, perms?) / Factions.removeRank(src, rank)  -- owner only; members in a removed rank drop to 1
Factions.setOwner(src, targetCharId) -> bool, err
Factions.update(src, { name?, tag?, color? }) -> bool, err   -- perm manage
Factions.deposit(src, amount) / Factions.withdraw(src, amount) -> bool, err   -- perm bank for withdraw; anyone can deposit
Factions.getBank(id) -> integer
Factions.setMeta(id, key, value) / Factions.getMeta(id, key)   -- for plugins (server only)
```

Replication: on any membership/rank change for an online member → `Player(src).state:set('faction', summary
or false, true)` (whole value; `false` instead of nil so change handlers fire) and `data.faction` on the
character; on create/update/disband → `GlobalState['faction:' .. id] = { name, tag, color, memberCount }` or
`false`. Hooks: `factionChanged (src, summary|nil)`, `factionUpdated (id)`. Invites expire after
`Config.Factions.InviteTimeoutMs` (checked lazily on accept + a 30 s sweep). Callbacks registered by core
(names in §5.2) expose all of this to a faction UI plugin.

### 4.6 `Core.Vehicles` server (`server/vehicles.lua`)

```lua
Vehicles.spawn(opts) -> netId | nil, err
-- opts = { model = 'adder' | hash, coords = vector3, heading = 0.0, type = 'automobile' (CreateVehicleServerSetter type),
--          plate = 'ABC123'?, ownerSrc = src?, ownerCharId = id?, keys = { charId, ... }?, props = table?,
--          keyMode = 'virtual'|'item' (default virtual), locked = false, persistent = false, bucket = nil }
Vehicles.delete(netId) -> bool
Vehicles.exists(netId) -> bool, Vehicles.getEntity(netId) -> entity|0
Vehicles.getInfo(netId) -> { netId, model, plate, ownerCharId, keys, locked, vehId, spawnedBy, createdAt } | nil
Vehicles.setLocked(netId, locked) -> bool          -- state 'locked' + SetVehicleDoorsLocked(veh, locked and 2 or 1) (RPC, best effort)
Vehicles.isLocked(netId) -> bool
Vehicles.giveKeys(netId, charId) / Vehicles.removeKeys(netId, charId) -> bool
Vehicles.hasKeys(src, netId) -> bool               -- explicit virtual key in keys[charId]
Vehicles.setOwner(netId, charId|nil), Vehicles.getOwner(netId) -> charId|nil
Vehicles.getPlayerVehicles(src) -> array of netId  -- spawned vehicles owned by the player's charId
Vehicles.list() -> array of netId
-- persistence (collection 'vehicles': { id, ownerCharId, model, plate, props = {}, stored = false, position = {x,y,z,heading}, meta = { vehType, keyMode } })
Vehicles.persist(netId) -> vehId | nil             -- creates the record for a spawned vehicle, writes state vehId
Vehicles.getRecords(charId) -> array of records
Vehicles.getRecord(vehId) -> record | nil
Vehicles.spawnRecord(vehId, coords, heading, ownerSrc?) -> netId | nil, err   -- spawns from a record (props sent to ownerSrc's client), stored = false
Vehicles.restoreRecord(vehId, coords?, heading?, ownerSrc?) -> netId | nil, err -- only an out record; saved position is the default
Vehicles.adopt(netId, opts) -> vehId | nil, err -- trusted server resource promotes an existing network vehicle
Vehicles.store(netId) -> bool                      -- saves position/props (last known), deletes the entity, stored = true
Vehicles.saveProps(netId, props) -> bool           -- from the owner's client (§5), validated
Vehicles.deleteRecord(vehId) -> bool
```

`spawn`: hash the model, `CreateVehicleServerSetter(hash, type, x, y, z, heading)`, `0` → `nil, 'create_failed'`;
wait for `DoesEntityExist` up to `Config.Vehicles.SpawnTimeoutMs` (`Wait(50)` polling); plate =
`opts.plate` (trimmed/uppercased and validated `^[%w %-]{1,8}$`) or `Config.Vehicles.PlatePrefix .. random 5 alnum`.
Every plate is unique across **all stored records and live entities**, not merely this process; `spawnRecord` passes
its own record id so it alone may restore that plate. The default prefix `LS-` produces registration-shaped values
such as `LS-48291`. `SetVehicleNumberPlateText`; state: `coreVeh = true`, `locked`, `owner`, `keys`, `keyMode`, `plate`,
`vehId`; `keyMode = 'virtual'` (the compatibility default) inserts the owner into `keys`, while
`'item'` intentionally does not so a domain plugin can make a physical inventory key authoritative; `SetEntityRoutingBucket` if `bucket`; `SetEntityOrphanMode(veh, 2)` when `persistent` or an owner is
set (otherwise leave default); track `spawned[netId]`; props → `TriggerClientEvent('core:client:applyVehicleProps',
ownerSrc, netId, props)` if `ownerSrc`; `persist` saves `vehType` and `keyMode` in `meta`, and both record spawn
paths restore them; hook `vehicleSpawned (netId, info)`. `delete`: `DeleteEntity` + untrack + hook
`vehicleDeleted (netId)`. `adopt` accepts only an existing network vehicle, canonicalises or replaces its plate,
sets orphan mode, creates the same record/state contract and refuses an already tracked net id. It is a trusted
server-resource API, never a client event.

`stored = true` means deliberately garaged; `stored = false` means the record belongs in the world. On core's own
`onResourceStop`, every persisted live record keeps `stored = false` while its cached props and exact final server
position are synchronously saved before the obsolete entity is deleted. A domain plugin calls `restoreRecord` in
bounded boot batches; that function refuses stored records and duplicate vehIds, so it cannot materialise something
parked in a garage twice. A restored record also projects `coreProps` in its entity state (and refreshes it only
when a validated saved-property payload changes), allowing whichever client streams it to replay colours/mods/
damage even when the owner is offline. `entityRemoved`
(`AddEventHandler`) only drops live bookkeeping: it never silently changes the persistent garage/world decision.

### 4.7 `Core.Notify` server (`server/notify.lua`)

`Notify.send(src, message, type = 'info', duration?)` → `TriggerClientEvent('core:client:notify', src, {
message, type, duration, title? })`; `Notify.broadcast(message, type?)` → `-1` (announcements only, never in
loops). `type ∈ { info, success, error, warning }`; message sanitized to ≤ 256 chars.

### 4.8 Admin and utility commands (`server/admin.lua`, via `Core.Commands.register`)

| command | perm | behaviour |
|---|---|---|
| `/id` | — | notify own server id + name |
| `/players` | — | notify count + list of `[id] name` (≤ 20 shown) |
| `/car <model> [plate]` | `core.admin` | `Vehicles.spawn` at the player's coords/heading with `ownerSrc = src`, then `core:client:warpIntoVehicle (netId)` |
| `/dv` | `core.admin` | delete the vehicle the ped is in, else the nearest spawned-by-core vehicle within 5 m, else the nearest of `GetAllVehicles()` within 5 m |
| `/tp <x> <y> <z>` | `core.admin` | `Player.setCoords` |
| `/tpm` | `core.admin` | client command (in `client/main.lua`) reads the waypoint and sends `core:server:teleportToWaypoint (coords)`; server checks perm + `Validate` then `Player.setCoords` |
| `/tpto <player>` / `/bring <player>` | `core.admin` | teleport to / bring |
| `/setcash <player> <amount>`, `/setbank`, `/givecash <player> <amount>`, `/givebank` | `core.admin` | `Money.set` / `Money.add` |
| `/setgroup <player> <group>` | `core.admin` (console always) | `Perms.setGroup` |
| `/kick <player> [reason...]` | `core.mod` | `Player.kick` |
| `/ban <player> <hours> [reason...]` | `core.admin` | `Player.ban` (0 hours = permanent) |
| `/announce <message...>` | `core.mod` | `Notify.broadcast` |
| `/revive [player]` | `core.mod` | `Player.respawn(target, coords of target)` → `core:client:revive` semantics: spawn at current coords |
| `/heal [player]` | `core.mod` | `core:client:heal` (full health + armour via client natives) |
| `/faction <create|invite|accept|leave|kick|rank|info|list> ...` | — | thin chat front-end over `Core.Factions` (see §5.2 callbacks for the UI route) |

### 4.9 `server/main.lua`

`onResourceStart` (guarded): `GlobalState['core:ready'] = true`, load sessions for connected players, start the
autosave loop and the DB flush loop (single threads, stop flags). `onResourceStop`: `Player.saveAll()`,
`Vehicles` cleanup, `DB.flush()`, `GlobalState['core:ready'] = false` — synchronous, no `Wait`.
`emitHook('ready')` after start.

---

## 5. Server net events and callbacks (security table)

Every handler is registered with `Core.Net.on` (so the order src → schema → cooldown → loaded → permission →
distance is enforced by the wrapper) unless marked *raw*.

| event (client → server) | schema | cooldown | extra checks | action |
|---|---|---|---|---|
| `core:server:requestLoad` | — | 1000 | *raw*, `requireLoaded = false`; waits up to 10 s (`Wait(250)` poll) for the session | answers `core:client:loaded` |
| `core:server:died` | — | 2000 | `GetEntityHealth(ped) <= 0` or `deadSince` nil | records death (§4.2) |
| `core:server:respawn` | — | 1000 | `deadSince` set + delay elapsed | respawn (§4.2) |
| `core:server:vehicleLock` | `'netId'` | 500 | entity exists, `GetEntityType == 2`, `Entity(veh).state.coreVeh`, `Vehicles.hasKeys`, ped within `Config.Vehicles.LockDistance` | toggle lock, notify `locked`/`unlocked` |
| `core:server:vehicleProps` | `'netId', { 'table', max = 96 }` | 5000 | exists, coreVeh, `hasKeys`, ped inside or within 10 m; props deep-checked: keys strings ≤ 32, values number/bool/string ≤ 32/array ≤ 32 of numbers, total ≤ `MaxPropsBytes` after `json.encode` | `Vehicles.saveProps` |
| `core:server:teleportToWaypoint` | `'vector3'` | 1000 | permission `core.admin`; coords inside the map bounds (±5000 xy, -300..2000 z) | `Player.setCoords` |
| `core:server:uiEvent` | — | — | **does not exist**: plugin pages talk to their own resource locally (§7) | — |

Server → client (targeted unless stated): `core:client:loaded (payload)`, `core:client:spawn (coords,
heading, respawn)`, `core:client:teleport (coords, heading)`, `core:client:setModel (model, appearance)`,
`core:client:notify (data)`, `core:client:applyVehicleProps (netId, props)`, `core:client:warpIntoVehicle
(netId)`, `core:client:revive ()`, `core:client:heal ()`. Client handlers use `Core.Net.on` with schemas.

### 5.2 Callbacks registered by core (server VM)

| name | args | returns |
|---|---|---|
| `core:player:getInfo` | — | `Player.getInfo(src)` + `money` |
| `core:faction:create` | `name, tag` | `ok, errOrId` |
| `core:faction:mine` | — | `getPlayerFaction(src)` + `members` |
| `core:faction:list` | — | `Factions.list()` |
| `core:faction:invite` | `targetSrc` | `ok, err` |
| `core:faction:accept` / `decline` / `leave` / `disband` | — | `ok, err` |
| `core:faction:kick` | `charId` | `ok, err` |
| `core:faction:setRank` | `charId, rank` | `ok, err` |
| `core:faction:setRankDef` | `rank, def` | `ok, err` |
| `core:faction:deposit` / `withdraw` | `amount` | `ok, err` |
| `core:vehicles:mine` | — | `Vehicles.getRecords(charId)` |

Each handler validates its args with `Core.Validate.check` first (`'string'`, `'src'`, `'id'`,
`{ 'integer', min = 1, max = Config.Factions.MaxRanks }`, `{ 'integer', min = 1, max = Config.Money.MaxAmount }`).

---

## 6. Client modules (run inside core)

### 6.1 `Core.Spawn` (`client/spawn.lua`)

```lua
Spawn.spawnPlayer({ coords = vector3, heading = 0.0, model = 'mp_m_freemode_01', appearance = {}, fade = true, resurrect = true }) -> bool
Spawn.applyAppearance(ped, appearance)      -- appearance = { components, props, headBlend, faceFeatures, headOverlays, hairColor, eyeColor } (all optional; the full shape and the apply order are §34)
Spawn.teleport(coords, heading?)            -- fade out → RequestCollisionAtCoord + wait → SetEntityCoords(ped, x, y, z, false, false, false, false) → heading → fade in
Spawn.setModel(model, appearance?) -> bool  -- Streaming.requestModel → SetPlayerModel(PlayerId(), hash) → SetPedDefaultComponentVariation → applyAppearance → SetModelAsNoLongerNeeded
```

`spawnPlayer` order: fade out (if not already) → `setModel` (only if the current model differs) →
`FreezeEntityPosition(ped, true)` → `Streaming.requestCollision(coords)` → `NetworkResurrectLocalPlayer(x, y, z,
heading)` (if `resurrect`) → `SetEntityCoords` + `SetEntityHeading` → `ClearPedTasksImmediately` →
`ClearPlayerWantedLevel(PlayerId())` → `SetEntityVisible(ped, true, false)` → unfreeze → `ShutdownLoadingScreen`
+ `ShutdownLoadingScreenNui` (first spawn only) → fade in. Returns `false` (and still unfreezes) if the model
or collision failed to load in time.

### 6.2 `Core.Player` client extras (`client/player.lua`)

Holds the `loaded` payload (`cached`). Adds to the lib table (inside core) and via proxy for plugins:
`Player.getData(key) -> value` (public payload fields: `model`, `appearance`, `position`, `money`, `faction`,
`group`, `charId`, `name`), `Player.refresh()` (re-sends `core:server:requestLoad`). Handles
`core:client:setModel` (→ `Spawn.setModel`), `core:client:teleport` (→ `Spawn.teleport`), `core:client:revive`
(→ `Spawn.spawnPlayer` at current coords with `resurrect = true`, `fade = false`), `core:client:heal`
(`SetEntityHealth(ped, GetEntityMaxHealth(ped))`, `SetPedArmour(ped, 100)`).

### 6.3 World scheduler (`client/world.lua`)

Internal (not exported): `World.add(kind, id, coords, range, draw)`, `World.remove(kind, id)`,
`World.update(id, coords?, range?)`. Entries live in a coarse grid (`Config.World.GridSize` m cells keyed
`cx .. ':' .. cy`). Thread A (`Config.World.ScanIntervalMs`): `pedCoords` once → check the 3×3 cells around the
player → `visible = { entries within range }`. Thread B: `while true do if #visible > 0 then for each: draw(entry,
dist) end Wait(0) else Wait(250) end end` — the only per-frame loop in the framework besides interactions'
help text, and it sleeps 250 ms whenever nothing is in range. Draw callbacks are local Lua functions supplied by
markers/textlabels (never funcrefs).

### 6.4 `Core.Markers` (`client/markers.lua`)

```lua
Markers.add({ coords = vector3 (required), type = 1, size = vector3(1.0, 1.0, 1.0) | number, color = { r, g, b, a } (default 0,150,255,120),
              drawDistance = 30.0, bobUpAndDown = false, faceCamera = false, rotate = false, offsetZ = 0.0 }) -> id
Markers.update(id, partialOpts), Markers.remove(id) -> bool, Markers.removeAll()   -- removeAll = the caller's markers
```

Draw: `DrawMarker(type, x, y, z + offsetZ, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, sx, sy, sz, r, g, b, a, bob, faceCam, 2,
rotate, nil, nil, false)`. Ids are strings `owner .. ':m' .. n`.

### 6.5 `Core.TextLabels` (`client/textlabels.lua`)

```lua
TextLabels.add({ coords = vector3, text = 'Hello', drawDistance = 15.0, scale = 0.35, font = 4, color = { 255, 255, 255, 215 } }) -> id
TextLabels.setText(id, text), TextLabels.update(id, partial), TextLabels.remove(id), TextLabels.removeAll()
```

Draw with `SetDrawOrigin(x, y, z, 0)` → text commands (`SetTextFont`, `SetTextScale(0.0, scale)`, `SetTextColour`,
`SetTextCentre(true)`, `SetTextDropshadow(0, 0, 0, 0, 255)` (verify exact name with fxref), `SetTextEdge`,
`BeginTextCommandDisplayText('STRING')`, `AddTextComponentSubstringPlayerName(text)`,
`EndTextCommandDisplayText(0.0, 0.0)`) → `ClearDrawOrigin()`.

### 6.6 `Core.Blips` (`client/blips.lua`)

```lua
Blips.add({ coords = vector3 | radius = { coords = vector3, radius = 50.0 } | entity = handle | netId = n,
            sprite = 1, color = 0, scale = 0.8, label = 'Blip', shortRange = true, alpha = 255?, display = 4?, category = nil?, route = false }) -> id
Blips.update(id, partial), Blips.setLabel(id, text), Blips.setCoords(id, coords), Blips.setRoute(id, bool), Blips.getHandle(id) -> blip
Blips.remove(id), Blips.removeAll()
Blips.setWaypoint(coords), Blips.getWaypoint() -> vector3 | nil   -- GetFirstBlipInfoId(8) / GetBlipInfoIdCoord; nil when none
```

Static blips are created once (no loop). Label via `BeginTextCommandSetBlipName('STRING')` +
`AddTextComponentSubstringPlayerName` + `EndTextCommandSetBlipName(blip)`.

### 6.7 `Core.Interactions` (`client/interactions.lua`)

```lua
Interactions.add({
    coords = vector3 | entity = handle | netId = n | models = { 'prop_atm_01', ... } (≤ Config.Interactions.MaxModels),
    radius = 2.0, label = 'Use ATM', key = 'E' (display only; the real key is the core_interact mapping),
    marker = markerOpts | nil (auto Markers.add following the interaction; removed with it),
    worldPrompt = true | { enabled?, range?, offsetZ?, icon?, description? } | nil   -- the 3D dot below; default
                                                      -- Config.Interactions.WorldPrompt.Enabled (false)
    onInteract = fn(ctx), onEnter = fn(ctx)?, onExit = fn(ctx)?, canInteract = fn(ctx) -> bool?,
    enabled = true, cooldown = 500, data = any,
}) -> id
Interactions.remove(id), Interactions.removeAll(), Interactions.setEnabled(id, bool), Interactions.setLabel(id, text)
Interactions.getActive() -> ctx | nil     -- ctx = { id, coords, entity, distance, data }
```

Scheduler (one thread, `Config.Interactions.ScanIntervalMs` ms): `pedCoords` once; for each enabled entry
compute the target coords: point → `coords`; entity/netId → `GetEntityCoords(entity)` if `DoesEntityExist`;
models → for each model `GetClosestObjectOfType(px, py, pz, radius, hash, false, false, false)` → its coords
(`GetEntityCoords`) if non-zero. The closest entry within its `radius` whose `canInteract(ctx)` (pcall) is not
`false` becomes `active` (the `canInteract` answer is evaluated for every entry within its radius, once per
pass). On change: old → `onExit` + `Core.UI.textUI.hide()`; new → `onEnter` + `Core.UI.textUI.show(key, label)`
unless the entry opted into the world prompt. The scan sleeps 1000 ms when no entry is within 60 m (cheap
distance test first). Key: `RegisterCommand('core_interact', fn, false)` + `RegisterKeyMapping('core_interact',
'Interact', 'keyboard', Config.Interactions.Key)`; the handler runs `onInteract(ctx)` (pcall) when the target is
enabled, not focused (`IsNuiFocused`), and `cooldown` elapsed. Callbacks that come from another resource are
funcrefs — always `pcall` them.

**World prompt (2026-09-18, native renderer 2026-09-19).** An entry whose `worldPrompt` resolves to true gets
a 3D dot on its world position, and its text UI line is never shown — the dot IS its prompt.
`Config.Interactions.WorldPrompt.Renderer` picks how it is drawn:

- **`'native'` (default).** The projection thread draws the dot, the key cap and the band itself, in the game's
  render thread. Sprites are runtime textures (`CreateRuntimeTxd`/`CreateRuntimeTexture`/
  `SetRuntimeTexturePixel`/`CommitRuntimeTexture`) painted once from the kit's own geometry and tokens: the
  whole idle dot as ONE composite texture `'idle'` (48x48, `WP_RING_PX` 36 on screen — deliberately larger than
  the CEF dot so it reads in world), the `'ring'` texture it is built on (kept for the pulse of an enabled dot,
  tinted and scaled), the white rounded cap with an ink rim (`WP_CAP_PX` 26, radius 3), the outline lock, and a
  one-sprite band: a
  `--color-hud` texture painted per measured width (last 76 px ramping to zero — one quad, so there is no
  filtered seam between a solid body and a separate fade sprite) and cached per quantized width. Everything is
  drawn under `SetDrawOrigin` at the world point (+`offsetZ`), so the render thread projects it and the prompt
  stays glued to the position while the camera moves; the script-side projection is only used for the
  look-at test and the side flip. The band follows the kit geometry exactly: near edge `cap/2 + WP_BAND_GAP_PX`
  (8), label inset `WP_BAND_PAD_PX` (14), tail 76, height 36, and `SetScriptGfxAlignParams(0,0,0,0)` keeps the
  origin aligned with the full screen rather than the safe zone. The label's width measurement
  (`BeginTextCommandGetWidth`/`EndTextCommandGetWidth`) and the aspect ratio are cached — both are text-layout /
  native reads that must not run per frame (the projection thread is a per-frame loop). The whole looked-at
  hint's layout — the uppercased text, that measured width and the band sprite that fits it — is one cache keyed
  on (label, text scale, resolution), and the key is the RAW `entry.label`, so an unchanged frame costs two
  comparisons and no string work at all; a rebuild happens before the draw bracket opens, never inside it. Per
  frame there is exactly ONE `SetScriptGfxAlignParams`/`ResetScriptGfxAlign` bracket around every draw and ONE
  draw-origin group per visible dot (the looked-at dot opens only its own — the engine limit is 32 per frame),
  and `GetGameTimer` is read once by the projection thread and handed down to the pass. The unit of cost here is
  a native call from Lua (each one goes through the runtime's invoke path), so the renderer optimises the call
  count — see the scheduling and the budget below. **The idle dot is ONE sprite** (2026-09-19): `'idle'` is
  painted as the `'ring'` texture's layers (ink disc r 11 at 0.45, white ring 9.5 − 8.0 at 0.92) with the old
  `'dot'` texture's layers converted into ring space and composited on top in the same source-over order — a dot
  texel radius r becomes `r * (WP_DOT_PX / 24) / (WP_RING_PX / 48)` ring texels (halo 6.5 → 5.778, core 3.0 →
  2.667) around the centre (24, 24), so `WP_DOT_PX` (16) survives only as that conversion's scale reference and
  there is no `'dot'` texture and no second draw any more. Identical by construction at `dim = 255`; a
  `disabled` dot (`dim = 150`) composites the halo/core overlap once instead of twice, which is the deliberate
  and only visual difference. Both Barlow Condensed weights are streamed as GFx font libraries —
  `stream/barlow_condensed.gfx` (600, `RegisterFontId('Barlow Condensed')`, the band label) and
  `stream/barlow_condensed_bold.gfx` (700, `RegisterFontId('Barlow Condensed Bold')`, the cap letter, exactly
  CoreKey's weight) — both written exactly like a gfxexport-built FiveM font: `ExporterInfo`,
  `FileAttributes`, **`DefineFont3`** (the 20x-em tag Scaleform's font provider enumerates) and an
  **`ExportAssets`** entry exporting the font under its name (that symbol is what `RegisterFontId` resolves).
  A plain `DefineFont2` or a `DefineCompactedFont` in a `.gfx` is not picked up and renders as fallback boxes —
  verified against a working community `.gfx`. Built from the kit's own woff2 by `scripts/build-font-gfx.sh`
  (FFDec at build time; nothing extra at runtime). Text is calibrated so a line is exactly the kit's `WP_LABEL_PX` (15) via
  `GetRenderedCharacterHeight`; the cap scales in on focus (130 ms), the idle dot pulses in `--color-accent`
  (`WP_TONE`), the label is `--color-fg` and the cap `--color-key`/`--color-key-fg`; everything scales with
  `resY/1080`, the band flips side at `x > 0.6`, dims when the dot is `disabled`, and
  `GetActualScreenResolution` is re-read every 5 s. Sprites are warmed 2 s after start so the first dot never
  hitches. Zero NUI messages, frame-perfect movement, nothing to throttle. This is the NP/qtarget-class path —
  the prompt is drawn where the game draws.

  **The looked-at hint (2026-09-19, `Config.Interactions.WorldPrompt.Hint`).** The idle dots stay sprites, but
  the ONE hint under the reticle is drawn as ONE Scaleform movie: 22 of the 28 native calls a lone hint made per
  frame were its own draws (2 sprites, 18 text natives, the draw-origin pair). The in-game probe (2026-09-18,
  `wp_sfprobe`) proved the two facts this rests on — `DrawScaleformMovie` called between `SetDrawOrigin` and
  `ClearDrawOrigin` IS projected by the render thread (the movie stays glued to the world point exactly like the
  sprites), and a per-frame thread drawing one movie reads 0.03 ms in resmon where the sprite hint reads ~0.10.
  It is deliberately a HYBRID: the game's `ScaleformMgrArray` pool is 40 movies for the WHOLE game (HUD, minimap,
  phone, every resource — read from gameconfig.xml), so core keeps exactly ONE instance and never one per dot.

  - `Hint = 'scaleform'` (default) draws the hint as the movie; `Hint = 'sprites'` keeps the DrawSprite + HUD
    text hint, which is also the automatic fallback while the movie loads or if it never does. Only meaningful
    with `Renderer = 'native'`.
  - The movie is `stream/core_hint.gfx`, requested as `core_hint`: GFX (Scaleform) signature, SWF 8, AS2, ONE
    frame, 60 fps, transparent, stage **1400 x 64 px** with the hint's origin — the CENTRE of the key cap — at
    the stage centre (700, 32); the root timeline sets `TIMELINE = this` and defines the API as timeline
    functions, so both `TIMELINE.<METHOD>` (what the game invokes on a script movie, FiveM's `ScaleformHacks.cpp`
    does `GetMember("TIMELINE")` + `Invoke`) and `_root.<METHOD>` resolve. The API — argument order and types are
    binding — is `SET_HINT(key:String, label:String, disabled:Boolean, left:Boolean, restart:Boolean)`: `key` is
    the cap text as registered, `label` the RAW label (the movie uppercases it, Unicode-aware, like the kit's
    CSS), `disabled` out of reach or locked (outline lock cap, dimmed label), `left` the band opening to the
    left, `restart` replays the focus-in animation; plus `HIDE()`, which blanks the movie so a late-applied
    `SET_HINT` can never flash the previous hint's content. The look is 1:1 with `CoreInteractionDot` focused,
    size md. Built by `scripts/build-hint-gfx.sh` (`scripts/hint-to-gfx.java` + `scripts/hint.as`, FFDec at build
    time, nothing extra at runtime); the `.gfx` is committed and a rebuild needs `refresh` before `restart core`.
  - Lifecycle, on the scan cadence and never in the per-frame path: the movie is requested
    (`RequestScaleformMovie`) when the first world prompt becomes visible, kept until the resource stops (one
    pool slot), given up on after 10 s with ONE warning naming the fallback, and forgotten — handle and every
    cached field — when `HasScaleformMovieLoaded` stops answering (the game dropped it), so the next scan
    requests it again. `onClientResourceStop` releases the handle.
  - Per frame the hint is `SetDrawOrigin` + ONE `DrawScaleformMovie(handle, 0.0, 0.0, 1400 * s / resX,
    64 * s / resY, 255, 255, 255, 255, 0)` + `ClearDrawOrigin` (`s = resY / 1080`, the size is refreshed with the
    resolution). `SET_HINT` goes out only when the focused entry, its key, its label, `disabled` or `left`
    changed; `HIDE` once when focus is lost (the `promptCount == 0` early return included). The cached fields
    mirror ONLY what the movie was really told — a `BeginScaleformMovieMethod` the engine refuses leaves them
    untouched, so the next frame retries instead of assuming a call that never happened — and a NEW focus
    (`restart`) is ANNOUNCED one frame before it is drawn: focus can move straight from dot A to dot B with no
    unfocused frame in between, so no `HIDE` ran, and a method call the engine applies after that frame's render
    would put A's content on B's position; the focus-in animation starts at alpha 0, so the one skipped frame is
    invisible. The side flip has
    hysteresis around the sprite path's 0.6 — left above `x > 0.62`, right below `x < 0.58` — so a dot sitting on
    the threshold cannot send a method call per frame. In Scaleform mode nothing measures text: `measureHint`,
    the band texture and both text draws belong to the sprite hint alone.
  - The `SetScriptGfxAlignParams`/`ResetScriptGfxAlign` bracket belongs to the SPRITES: it is opened lazily
    before the first sprite draw of a frame and closed only if it was opened, so a lone Scaleform hint draws with
    no bracket at all while a frame with idle dots still has exactly one.
  - Budget: **a lone looked-at hint is 5 native calls on a drawing frame** (`GetGameTimer`, `SetDrawOrigin`,
    `DrawScaleformMovie`, `ClearDrawOrigin`, `Wait`) and 7 on a projection frame (+`IsNuiFocused`,
    +`GetScreenCoordFromWorldCoord`) — ~5.7 averaged at 60 fps, where one frame in two or three projects. The
    sprite hint costs 26 on a drawing frame (24 of them its own draws) and stays documented as the fallback's
    number. The whole table is under "Scheduling and budget" below.
- **`'nui'`.** The projected dots are sent to the CEF shell as `worldprompts:set` and rendered as
  `CoreInteractionDot` (§37.5, §37.6) — the design-system look, for a page-like prompt. Position-only changes
  are throttled to `WP_SEND_MS` (~30 Hz, structural changes bypass) and the shell applies the set IN PLACE
  (per-id stable object) on a composited `transform: translate3d` with a 34 ms linear transition.

**Scheduling and budget (2026-09-19, run N10).** Both renderers share one scan and one per-frame thread. The
scan fills a second list: enabled entries within `range` metres of the ped (nearest
`Config.Interactions.WorldPrompt.MaxVisible`, entries whose `canInteract` said no while within `radius`
excluded), and writes each slot's draw anchor (`coords` + `offsetZ`) while it fills it. The second thread runs
only while that list is non-empty (`Wait(0)`, else 250 ms). **Drawing is per frame; the projection is not** —
everything is anchored with `SetDrawOrigin`, so the RENDER thread projects the world point and the script-side
`GetScreenCoordFromWorldCoord` is needed only for the look-at test and the visible set, never for drawing:

1. **Every frame, `entity` targets only:** re-read the world coordinates, but only as often as the entity
   actually moves. Per slot, `sameReads` counts consecutive reads that returned exactly the previous x, y, z
   (three scalar comparisons, never a vector or a key string) and `nextReadAt` is when the next read is due:
   a read that differs sets `sameReads = 0` and `nextReadAt = now` (every frame — a dot on a driving vehicle
   must not judder), 8 identical reads in a row set `nextReadAt = now + 250` (a resting prop). `DoesEntityExist`
   answering no drops the slot from the visible set at once and sets the dirty flag; a *resting* entity that
   vanishes is noticed at its next due read or by the scan, whichever comes first. The scan resets
   `sameReads`/`nextReadAt` when it re-fills a slot with a DIFFERENT entry. Point/models targets keep the scan's
   coords. `drawX/drawY/drawZ` — the draw anchor — is (re)set by that read and by the scan, never by the
   projection.
2. **On a projection frame** — `now - lastFocusAt >= WP_FOCUS_MS` (33 ms) or the dirty flag is set — every slot
   is projected with `GetScreenCoordFromWorldCoord` into normalized screen x/y (a failure — behind the camera,
   off screen — leaves it out of the visible set for this pass), `d = sqrt(((x - 0.5) * aspect)^2 +
   (y - 0.5)^2)` is computed with the cached `GetAspectRatio(false)`, and the candidate with the smallest
   `d ≤ Config.Interactions.WorldPrompt.FocusRadius` becomes `focused`; a candidate within the entry's `radius`
   beats an out-of-reach one. `IsNuiFocused()` is read on projection frames only — between them the last answer
   stands, and a focused NUI still parks the whole thread on the 250 ms idle cadence (which always lands on a
   projection frame on wake-up). At 60 fps that is every 2nd frame, at 144 fps every 5th, at 30 fps every frame.
3. **Every other frame** reuses that visible set and that focused slot and only draws. 33 ms is a third of the
   focus animation and below the reaction floor, so focus still feels immediate.
4. **The dirty flag (`focusDirty`) forces a projection on the next frame**, so a cached set can never outlive
   the list it was built from: it is set at the end of every scan pass (the slot tables are reused and re-filled
   there) and by `Interactions.remove` when it swap-removes a prompt slot. `setEnabled`/`setLabel` need no flag
   — the draw path reads `entry.label` live.
5. the frame is drawn (native) or the changed whole set is sent (`nui`);
6. `focused` is the ONLY interact target for a worldPrompt entry: `core_interact` acts on the focused
   entry when it has one; with no focused dot it falls back to the scan's `active` entry only when that entry
   does NOT use the world prompt (look-at gating is what the dot promises) — same enabled/freshness/distance/
   cooldown checks either way.

Steps 2–4 are the **native renderer only**. `'nui'` needs x/y to place DOM nodes, so it projects and reads
`IsNuiFocused` every frame exactly as before; only step 1 (which cannot change what it sends — a resting entity
projects to the same x/y) is shared.

Native call count per frame, steady state (a projection frame adds 1 `IsNuiFocused` + 1
`GetScreenCoordFromWorldCoord` per slot; the average column is the 16 ms step, where every 3rd frame projects):

| on screen | drawing frame | average |
|---|---|---|
| lone Scaleform hint | 5 | ~5.7 (was 7) |
| lone enabled idle dot | 8 (bracket + origin + pulse + `'idle'` + clear + timer + `Wait`) | ~8.7 (was 11) |
| each further enabled idle dot | 4 | ~4.33 (was 6) |
| each disabled idle dot (the common case: drawn within `range` 6 m, usable within `radius` 2 m) | 3 | ~3.33 (was 5) |
| a resting entity target, on top of its dot | 0 (2 on the frame its 250 ms read is due) | ~0.13 (was +2) |
| hint + 7 disabled point dots (`MaxVisible` 8) | 28 | ~31 (was 51) |
| hint + 7 resting entity dots (a drop-heavy scene) | 28 | ~32 (was 67) |
| the sprite hint (fallback) instead of the movie | 26 | ~26.7 (was 28) |

A dot is `disabled` (outline lock cap) while the ped is farther than the entry's `radius`. `id`, `key`, `label`,
`icon` and `description` come from the entry; `key` stays display-only. The text UI suppression only affects
the entry itself, so doors and drops keep their own pills. `range` is how far the dot is DRAWN, not how far it
can be used: keep it a few metres past the `radius` (default 6.0) — a dot is a "you can interact here" hint,
not a map pin. On `uiReady` the projection thread re-sends unconditionally (a reloaded shell forgot every
set). The whole projection idles at 250 ms while `IsNuiFocused()` (a page or modal is reading input).

### 6.8 `Core.Vehicles` client (`client/vehicles.lua`)

```lua
Vehicles.getClosest(coords?, radius = 5.0) -> veh|0, distance      -- GetGamePool('CVehicle') scan, on demand only
Vehicles.getCurrent() -> veh|0, Vehicles.isDriver() -> bool, Vehicles.getSeat() -> seat|nil
Vehicles.getNetId(veh) -> netId, Vehicles.fromNetId(netId, timeoutMs = 5000) -> veh|0   -- waits for NetworkDoesEntityExistWithNetworkId
Vehicles.getProps(veh) -> props, Vehicles.setProps(veh, props) -> bool   -- requests control first (NetworkRequestControlOfEntity, ≤ 1 s)
Vehicles.getPlate(veh) -> string (trimmed), Vehicles.getDisplayName(vehOrModel) -> string
Vehicles.hasKeys(veh) -> bool           -- Entity(veh).state: explicit keys[charId] (not item-key vehicles); false if not a coreVeh
Vehicles.isLocked(veh) -> bool          -- state 'locked'
Vehicles.toggleLock(veh?) -> nil        -- virtual-key veh or current/closest (≤ 8 m) → Net.emit('core:server:vehicleLock', netId); item-key vehicle no-ops for its plugin
Vehicles.setEngine(veh, on), Vehicles.repair(veh), Vehicles.saveProps(veh)   -- saveProps → Net.emit('core:server:vehicleProps', netId, getProps(veh))
```

`props` (JSON-safe, every key optional): `model, plate, plateIndex, colorPrimary, colorSecondary, customPrimary =
{r,g,b}|false, customSecondary, pearlescentColor, wheelColor, interiorColor, dashboardColor, wheels, windowTint,
livery, livery2, xenonColor, neonEnabled = {b,b,b,b}, neonColor = {r,g,b}, tyreSmokeColor, extras = { [id] = bool },
mods = { [modType 0..49] = index }, modToggles = { [17,18,19,20,22] = bool }, modVariations?, engineHealth,
bodyHealth, tankHealth, fuelLevel, dirtLevel, burstTyres = { [wheel] = true }, tyreHealth = { [wheel] = health },
doors = { [door] = open }, windows = { [window] = intact }, lights = { on, highBeam, indicators 0..3 }`.
Nested maps accept bounded integer ids including zero or their JSON string form; values are finite numbers or
booleans. GTA's `IsVehicleWindowIntact` reports false for a lowered window as well as a broken one, so that one
visual distinction cannot be reconstructed after persistence. `setProps` calls `SetVehicleModKit(veh, 0)` first and
applies only keys present.

Built-in behaviour: `AddStateBagChangeHandler('locked', nil, ...)` → only for entities with state `coreVeh` →
`SetVehicleDoorsLocked(veh, value and 2 or 1)` (+ on stream-in via `Core.Vehicles` checking `Entity(veh).state.locked`
when the player tries to enter: a 500 ms guard that only runs while `GetVehiclePedIsTryingToEnter(ped) ~= 0`).
Key `Config.Vehicles.LockKey` (`U`) via `Core.Keys.register` → `toggleLock()`. For `keyMode = 'item'`, this
intentionally no-ops (without a false "no keys" message) so the owning domain plugin can bind the same UX key and
validate its physical inventory item server-side.

### 6.9 `Core.Raycast` (`client/raycast.lua`)

```lua
Raycast.fromCamera(distance = 10.0, flags = -1, ignoreEntity = PlayerPedId()) -> hit:boolean, coords:vector3, normal:vector3, entity:integer
Raycast.between(from, to, flags = -1, ignoreEntity = 0) -> hit, coords, normal, entity
Raycast.getEntityInFront(distance = 5.0) -> entity|0, coords
```

Uses `GetGameplayCamCoord`, `GetGameplayCamRot(2)`, `Core.Math.rotationToDirection`,
`StartExpensiveSynchronousShapeTestLosProbe` + `GetShapeTestResult` (synchronous, no loop).

### 6.10 `Core.UI` (`client/ui.lua`) — the NUI bridge

> **Amended by §38 (2026-09-18).** `script`/`style` are removed from `registerPage` (passing either fails the
> registration with an error pointing at §38); `type` gains `'modal'`; `page:register` carries `owner`; the
> focus paragraph below is replaced by the focus STACK of §38.9; and §38.5 adds `plugin:*`, `page:patch`,
> `page:request`, `feed`, `dev:set`, `inspector:toggle` and the `ui_request` / `ui_response` / `ui_plugin` /
> `ui_error` / `ui_feed` callbacks. Everything else in this section is unchanged.

State: `pages[id] = { owner, type, script, style, keepInput, registered = bool }`, `openPage = id|nil`
(exclusive, `type = 'page'`), `overlays[id] = true`, `pending = { [requestId] = promise }`, `nuiReady = bool`,
`notifyQueue`.

```lua
UI.registerPage(id, { type = 'page' | 'overlay', keepInput = false, script = nil, style = nil })
--   default: the page component is COMPILED INTO core's bundle (§7.4) and looked up by id; script/style are an
--   optional fallback (relative paths inside the CALLER's resource → 'https://cfx-nui-<owner>/<path>')
--   §38: script/style REMOVED, type gains 'modal' — UI.registerPage(id, { type, keepInput }) only
UI.unregisterPage(id)
UI.open(id, props?) -> bool          -- page: closes the current page first, SetNuiFocus(true, true) (+ SetNuiFocusKeepInput(keepInput)); overlay: just shows it
UI.close(id?)                        -- id nil → close the open page; no page open → SetNuiFocus(false, false)
UI.closeAll()                        -- pages + overlays + built-ins; focus off
UI.isOpen(id) -> bool, UI.getOpenPage() -> id|nil, UI.isFocused() -> bool
UI.send(id, event, data)             -- → NUI 'page:event'
UI.notify({ message, type = 'info', duration = Config.UI.NotifyDurationMs, title? }) | UI.notify(message, type)
UI.textUI.show(key, text, { position = 'bottom' }?) / UI.textUI.hide() / UI.textUI.isShown()
UI.progress({ label, duration, canCancel = false }) -> completed:boolean   -- awaits; false when cancelled (X / Backspace) or a second progress starts
UI.progress.cancel()
UI.menu.open({ title, items = { { label, description?, icon?, value, disabled? }, ... } }) -> value|nil     -- awaits; nil on ESC
UI.menu.close()
UI.input.open({ title, fields = { { name, label, type = 'text'|'number'|'select'|'checkbox', options?, default?, required?, min?, max?, placeholder? } }, submit = 'OK', cancel = 'Cancel' }) -> values|nil
UI.alert({ title, message, confirm = 'OK', cancel = 'Cancel'|false }) -> confirmed:boolean
UI.hud.setVisible(bool), UI.hud.set(partial)   -- core feeds cash/bank/name/serverId/faction itself from state bags
```

Wire to NUI (`SendNUIMessage({ action = ..., ... })`, table form of the runtime helper):

| action | fields |
|---|---|
| `notify` | `id, message, type, duration, title` |
| `textui:show` / `textui:hide` | `key, text, position` / — |
| `worldprompts:set` | whole set: `items = { { id, x, y, focused, disabled, keys, label, icon?, description? }, … }` (`x`/`y` normalized 0..1, §6.7); `{}` clears |
| `progress:start` / `progress:stop` | `id, label, duration, canCancel` / `id` |
| `menu:open` / `menu:close` | `id, title, items` / — |
| `input:open` / `input:close` | `id, title, fields, submit, cancel` / — |
| `alert:open` / `alert:close` | `id, title, message, confirm, cancel` / — |
| `hud:set` | partial of `{ visible, cash, bank, name, serverId, faction = { name, tag, color } | false }` |
| `page:register` / `page:unregister` | `id, type, script (URL), style (URL|null), keepInput` / `id` — §38.5: `id, type ('page'\|'overlay'\|'modal'), keepInput, owner`; `script`/`style` gone |
| `page:open` / `page:close` / `page:event` | `id, props` / `id` / `id, event, data` |
| `focus` | `focused` — §38.5 adds `stack = { { key, layer, id?, owner } … }` (top last) |

NUI → Lua (`RegisterNuiCallback`, every one calls `cb({})` or `cb({ ok = true })`):
`ui_ready {}` (NUI reloaded/loaded → set `nuiReady`, re-send every registered page + hud snapshot),
`ui_close { page }` (ESC or close button → `UI.close(page)`), `ui_event { page, event, data }` →
`TriggerEvent(('core:ui:%s:%s'):format(page, event), data)` (page/event validated as `'id'` strings, `data` ≤
16 KB json), `menu_result { id, value }`, `input_result { id, values }`, `alert_result { id, confirmed }`,
`progress_cancel { id }`, `progress_done { id }`. Results resolve the matching pending promise (unknown ids
ignored). Focus **(superseded by §38.9 — the three booleans are a focus STACK now; the observable behaviour is
the same, plus plugin modals)**: exactly `SetNuiFocus(true, true)` when a `page` or a built-in modal
(menu/input/alert) is open, `SetNuiFocus(false, false)` the moment none is; `onResourceStop` releases focus and
hides everything. Notify throughput: queue, flushed at most `Config.UI.MaxNotifyPerSecond` per second (a 100 ms timer), extra
messages coalesced (`count` field). ESC is handled in the page (keydown → `ui_close`); a 500 ms watchdog also
releases focus if `IsNuiFocused()` while nothing is open.

### 6.11 `client/api.lua` and `client/main.lua`

`api.lua`: `call` export + `Core.Registry` (§2.3). `main.lua`: on start → `pcall(function()
exports.spawnmanager:setAutoSpawn(false) end)`; request loop: `Net.emit('core:server:requestLoad')` every 5 s until
`core:client:loaded` arrives (max 12 tries, then a console error); on `loaded` → cache → if `payload.respawn` →
`Spawn.spawnPlayer` → `LocalPlayer` is marked by the server (`loaded` state) → `Core.emitHook('playerLoaded')`
→ `UI.hud.setVisible(Config.UI.HudEnabled)`. Death watch: one thread, `Wait(1000)`; on `IsPedDeadOrDying(ped,
true)` transition → `Net.emit('core:server:died')`, `emitHook('playerDied')`, text UI "Respawn in N s" updated
each second (uses `SetTimeout`-free countdown inside the same loop) → after `Config.Respawn.DelayMs` →
`Net.emit('core:server:respawn')`; `core:client:spawn` → `Spawn.spawnPlayer(...)` + `emitHook('playerRespawned')`.
Client commands: `tpm` (admin; waypoint → `core:server:teleportToWaypoint`). `onResourceStop`: `UI.closeAll()`
equivalent focus release (synchronous).

---

## 7. UI shell (`core/ui` → `core/html`)

### 7.1 Stack and build

> **Superseded in part by §38 (2026-09-18).** The infrastructure is TypeScript now (`ui/src/runtime/*.ts`,
> `ui/src/shell.ts`, `ui/sdk/**`), the tokens moved to `ui/sdk/theme.css`, the entry is `@import "tailwindcss"
> source(none)` with explicit `@source` lines, the `@source "../../../*/ui/src/…"` line is gone, and a plugin
> page `@reference`s `@core/ui/reference.css` instead of a relative path into core. Everything below about
> Tailwind v4 CSS-first, the tokens-are-utilities rule and the Chromium 103 bans still holds.

Vue 3 + Vite, plain JavaScript (no TypeScript), `<script setup>` SFCs, Tailwind utilities with scoped CSS where
a component needs it, no UI component library, no external fonts (the CEF cannot fetch the web).
`ui/package.json` scripts: `dev` (Vite dev server with the dev shim), `build` (→ `../html`).
`vite.config.js`: `base: './'`, `build.outDir: '../html'`,
`build.emptyOutDir: true`, deterministic file names (`assets/app.js`, `assets/app.css`, no hashes) so the
manifest's `files { 'html/**' }` stays stable. `src/main.js` does `import * as Vue from 'vue'; window.Vue = Vue`
**before** mounting so plugin bundles share the one Vue instance.

**The CSS framework is Tailwind CSS v4**, CSS-first: `@tailwindcss/vite` is the only Vite plugin besides
`@vitejs/plugin-vue`, there is no `tailwind.config.js` and no PostCSS step, and `src/styles.css` is the entry
(`@import "tailwindcss"` + one `@theme` block + the `@layer components` with the shared `.core-*` classes).
Every §7.2 token is therefore also a utility: `--color-panel|panel-solid|panel-raise|border|border-strong|backdrop|accent|accent-soft|success|error|warning|info|fg|fg-dim|fg-faint`
→ `bg-*` / `text-*` / `border-*` (with opacity modifiers, `bg-accent/10`), `--radius-ui[-sm]` → `rounded-ui[-sm]`,
`--shadow-ui` → `shadow-ui`, `--ease-ui` → `ease-ui`, `--text-ui[-sm|-xs]` → `text-ui[-sm|-xs]`,
`--font-sans|--font-mono` → `font-sans|font-mono`, `--animate-core-*` → `animate-core-*`. Plugin pages are compiled
into this same bundle (§7.4), so the entry scans them too: `@source "../../../*/ui/src/**/*.{vue,js}"` — the file
pattern is load-bearing, a `@source` path containing `*` is matched against *files*, so the bare directory
`../../../*/ui/src` matches nothing and plugin utilities silently never reach the bundle. A plugin installs and
configures no CSS toolchain; a scoped `<style>` that uses `@apply` points Tailwind at the theme with
`@reference "../../../core/ui/src/styles.css";` (relative to `<plugin>/ui/src`), which reads the tokens and emits
nothing. FiveM's CEF is **Chromium 103** (2026-09-13, `fivem/vendor/cef/cef_build_name.txt`): Tailwind v4's `translate-*`, `rotate-*` and `scale-*` utilities compile to the individual transform properties (`translate:`, `rotate:`, `scale:`, Chrome 104+) and are therefore banned in the shell and in plugin pages — use `[transform:translateX(-50%)]`-style arbitrary properties; the Popover API, `:has()` and `calc(infinity)` are unavailable as well. `backdrop-filter` / `-webkit-backdrop-filter` and Tailwind's `backdrop-*` utilities are banned shell-wide:
the game frame is not part of the CEF's compositing surface, so FiveM paints the filtered area as a solid black box.
A panel that should show the blurred game behind it carries `data-core-blur` instead (§32: the shell draws the
game frame through FiveM's NUI render hook and blurs that copy).

### 7.2 Files

> **Superseded in part by §38.6/§38.7 (2026-09-18).** `ui/src/main.js` and `ui/src/plugins.js` are DELETED:
> the entry is `ui/src/main.ts` over `ui/src/shell.ts` (`createShell`), the transport moved into
> `ui/src/runtime/transport.ts` (`bridge.js` is the thin legacy shim), the host object lives in
> `ui/src/runtime/host.ts`, and `ui/sdk/**` is the plugin-facing package. The `ui/src/store.js` and
> `ui/src/App.vue` rows still describe what those files do.

```
ui/index.html, ui/vite.config.js, ui/package.json
ui/src/main.js            creates the app, exposes window.Vue and window.CoreUI, mounts #app
ui/src/bridge.js          post(name, data) → fetch('https://' + resource + '/' + name) (JSON); dev shim when GetParentResourceName is missing; onMessage(action, fn) dispatcher for window 'message' events
ui/src/store.js           reactive state: notifications[], textui, progress, menu, input, alert, hud, pages{}, openPage, overlays{}
ui/src/coreui.js          window.CoreUI implementation (§7.4)
ui/src/App.vue            root: <Hud/> <StatsBars/> <Notifications/> <TextUI/> <Progress/> <Chat/> <KeyHints/> <Spinner/> <PageHost/> <Shard/> <Menu/> <InputDialog/> <AlertDialog/> + #core-overlays
ui/src/shell/*.vue        the Lua-driven widgets: store state → kit components, no drawing of their own (§37.6; 2026-09-18 — `ui/src/components/` is gone)
ui/src/kit/               the design system (§37): tokens → css partials → Core*.vue components
ui/src/styles.css         design tokens (§37.2) + base + the structural shell classes
```

Visual direction: minimal, dark translucent panels (rgba(14,16,20,.86)), 8 px radius, 1 px hairline border
(rgba(255,255,255,.08)), accent `#5b8cff`, success `#3ddc84`, error `#ff5d5d`, warning `#ffb347`; HUD top-right
(cash/bank/faction/id, small caps labels); notifications top-right below the HUD, slide in/out; text UI bottom
centre pill `[E] Open shop` with the key in a bordered box; progress bottom centre bar with label; menu and
input as centred panels, keyboard navigable (↑↓ Enter Esc for the menu; Tab/Enter/Esc for input). Everything
is `pointer-events: none` except open modals/pages.

### 7.3 Message handling

`bridge.onMessage(action, handler)`; `App`/store subscribe to every action in §6.10. Result posts:
`menu_result`, `input_result`, `alert_result`, `progress_cancel`, `progress_done`, `ui_close`, `ui_event`,
`ui_ready` (sent once on mount). Keyboard: `Escape` → if a modal is open → its cancel result; else if a page is
open → `ui_close { page }`. Progress cancel keys: `x`, `Backspace`.

### 7.4 Plugin pages (`window.CoreUI`) — one UI dist

> **SUPERSEDED BY §38 (2026-09-18).** Build-time compilation of plugin pages, `ui/src/plugins.js`, the
> `export const id` / `export const pages` entry convention and the `script`/`style` URL loader are all GONE —
> a resource now builds its own frontend and core imports it at runtime (§38.3, §38.6).
> What still holds, unchanged: the `window.CoreUI` surface listed below (§38.12 keeps it for tests, stories and
> old pages) and the **props-identity rule** at the end of this section — `usePage(id).props` is the same
> reactive object for the life of the shell, across `page:unregister` + `page:register`.

Players download exactly one UI: core's `html/`. Plugin pages live in the plugin's source tree
(`<plugin>/ui/src/index.js` exporting `id` and the default Vue component, plus its SFCs) and are compiled INTO the
shell bundle at build time: `core/ui/src/plugins.js` globs `../../../*/ui/src/index.js` and registers every page
with `CoreUI.registerPage(id, component)` before mount. Plugins ship no UI files (`files {}` stays empty) and call
`Core.UI.registerPage(id, { type })` only to declare page metadata. Dev dependencies live in ONE `node_modules`:
`resources/package.json` is an npm workspace (`core/ui`, `*/ui`); a plugin that needs an extra runtime library adds a
minimal `ui/package.json` with just that dependency, `npm install` at `resources/` hoists it, and Rollup bundles it
into the single dist (Vue itself is never duplicated). The URL loader below stays as a fallback for prebuilt
third-party bundles (`script`/`style` given).

```js
window.CoreUI = {
  Vue,                                   // same as window.Vue
  registerPage(id, component),           // called by a plugin bundle once it has executed
  emit(pageId, event, data),             // → post('ui_event', { page, event, data })
  on(pageId, event, fn) -> off,          // page:event from Lua
  close(pageId),                         // → post('ui_close', { page })
  post(name, data) -> Promise,           // raw NUI callback
  hud,                                   // readonly reactive HUD snapshot
  usePage(id) -> { props (reactive), emit(event, data), on(event, fn), close() }   // composable for the page component
}
```

A plugin may register **more than one page** from the same `index.js` with `export const pages = { '<id>':
Component, ... }` (2026-09-13, for the inventory's hotbar overlay): `plugins.js` registers every entry after the
default export, with the same duplicate-id check; each id is still declared from Lua with
`Core.UI.registerPage(id, { type })` and owned by the same resource.

`usePage(id).props` is **the same reactive object for the life of the shell** (2026-09-13, found when the
inventory opened empty after `restart inventory`): `page:unregister` + `page:register` — what a plugin restart
does — hand the id a fresh record, but the record reuses the id's props object, so a module-level page store that
captured `props` once keeps seeing every later `page:open`. Two rules for such stores: bind to the current record
on every mount anyway when you can (`inventory/ui/src/inventory.js bindPage`), and create watchers in a detached
`effectScope(true)` — a `watch` made inside a component's setup stops when that component unmounts, and the first
`useX()` call usually happens inside one (`ui/tests/shell-regression.js` covers the identity).

`page:register` handling in `PageHost`: create `<link rel="stylesheet" href=style>` (if any) and `<script
src=script>` in `<head>` (once per id; re-register replaces); a bundle calls `CoreUI.registerPage(id,
component)` when it runs; `page:open` before registration waits up to 5 s (then posts `ui_event { page:id,
event:'__error' }` and shows an error notification). `PageHost` renders the open page (`<component :is="pages[openPage].component" :props="props"/>`) and every overlay (`v-for`, absolutely positioned, `pointer-events:none`
container; the component decides its own hit area). Fallback only (prebuilt third-party bundles): a Vite lib-mode IIFE with `vue` external, registered with `script`/`style` paths inside the owner resource.

### 7.5 Dev shim and offline tests

When `window.GetParentResourceName` is undefined, `bridge.post` logs to the console and resolves `{}` and
`window.__core = { send(msg) }` dispatches a fake `message` event, so `html/index.html` can be opened with
`agent-browser` and driven with `__core.send({ action: 'menu:open', ... })`. `core/ui/tests/shell-regression.js`
(run with `agent-browser eval --stdin` on `html/index.html`) exercises notify/textui/progress/menu/input/alert/hud
and the page host with a fake registered component.

---

## 8. State bags, GlobalState, hooks

Server writes, clients read (strict-mode safe). All keys flat.

| bag | key | value |
|---|---|---|
| `player:<src>` | `loaded` | `true` once the session exists (set to `false` right before removal in `playerDropped` is unnecessary — the bag disappears) |
| | `name`, `charId`, `group` | strings |
| | `cash`, `bank` | integers (mirrors `data.money`) |
| | `faction` | `{ id, name, tag, color, rank, rankName }` or `false` |
| | `dead` | boolean |
| `entity:<netId>` (core vehicles) | `coreVeh` | `true` |
| | `locked` | boolean |
| | `owner` | charId or `false` |
| | `keys` | `{ [charId] = true }` |
| | `keyMode` | `'virtual'` or `'item'` |
| | `plate`, `vehId` | strings (`vehId` only when persisted) |
| | `coreProps` | optional persisted `CoreVehicleProps` projection, refreshed only when saved props change |
| `global` | `core:ready` | boolean |
| | `faction:<id>` | `{ name, tag, color, memberCount }` or `false` |

Replicated character fields (`REPLICATED` in `server/player.lua`): `name`, `charId` (from session), `money` →
`cash` + `bank`, `faction` → summary, and the account `group`. `Player.setData(src, 'money', ...)` or any
`Money.*` call re-replicates; `setData` on other keys never replicates.

Hooks (local events `core:hook:<name>`, cross-resource, same side):

| side | hook | args |
|---|---|---|
| server | `ready` | — |
| server | `playerLoaded` | `src` |
| server | `playerDropped` | `src, charId` (before the session is removed) |
| server | `playerSaved` | `src` |
| server | `playerDied` / `playerRespawned` | `src` |
| server | `moneyChanged` | `src, account, amount, delta, reason` |
| server | `factionChanged` | `src, summary|nil` |
| server | `factionUpdated` | `factionId` |
| server | `vehicleSpawned` / `vehicleDeleted` | `netId, info` / `netId` |
| server | `audit` | `category, src, message` |
| client | `ready` | — |
| client | `playerLoaded` | — (after the first spawn) |
| client | `playerDied` / `playerRespawned` | — |
| client | `pedChanged` | `ped, previous` — the local player's ped ENTITY changed (model swap, spawn, character switch); `previous` is `0` the first time |
| client | `uiReady` | — |
| client | `core:ui:<page>:<event>` (not under `hook:`) | `data` |

`pedChanged` comes out of the death-watch thread (§6.11): the `PlayerPedId()` it already reads every second is
compared with the last handle, so the hook costs one compare per second and one local event per change. Everything
bound to the ped entity — `SetPedConfigFlag`, proofs, attached objects — dies with the old ped; a plugin re-applies
it from this hook instead of polling `PlayerPedId()` itself. It fires once after `playerLoaded` (`previous = 0`) and
is NOT replayed for a resource that starts later: such a resource applies its state once at its own start as well.

---

## 9. Performance budget

| loop | side | cadence | note |
|---|---|---|---|
| world scan | client | 500 ms | grid 3×3 cells, `#(pedCoords - coords)` only |
| world draw | client | 0 ms while `#visible > 0`, else 250 ms | markers + labels only |
| world prompt projection (§6.7) | client | drawing 0 ms while a `worldPrompt` entry is in `Range` (else 250 ms), projecting on a 33 ms cadence | native (default): ONE composite `'idle'` DrawSprite per idle dot (a second one for the pulse of an enabled dot), the looked-at hint is ONE Scaleform movie (`Hint = 'scaleform'`) — per drawing frame **5 native calls for a lone looked-at hint**, 8 for a lone enabled idle dot, +4 per further enabled dot, +3 per disabled one, 28 for hint + 7 dots at `MaxVisible` 8 (~31 averaged with the 33 ms projection pass; entity targets add 2 natives per read and a resting one is read every 250 ms). The sprite hint (`Hint = 'sprites'`, and the automatic fallback while the movie loads) costs 26 for a lone hint. Zero NUI messages either way; nui: projects every frame, one reused `worldprompts:set` per *changed* frame, nearest `MaxVisible` dots, a still camera sends nothing |
| interactions scan | client | 300 ms near (≤ 60 m of any entry), 1000 ms far | `GetClosestObjectOfType` ≤ MaxModels per model-interaction |
| death watch | client | 1000 ms | `IsPedDeadOrDying` |
| entry guard (vehicle locks) | client | 500 ms only while `GetVehiclePedIsTryingToEnter ~= 0` | |
| NUI focus watchdog | client | 500 ms | |
| idle cam reset (§35) | client | 5000 ms | two natives; only while `Config.Camera.DisableIdleCam` |
| notify flush | client | 100 ms timer only while queue non-empty | |
| load request | client | 5000 ms until loaded | |
| autosave | server | `Config.Player.SaveIntervalMs` (5 min) | chunked: 25 sessions, then 250 ms (§4) |
| stat decay | server | `Config.Stats.TickMs` (60 s) | chunked: 100 players, then 250 ms; the next wait is shortened by the time a pass took, so `decayPerMinute` holds |
| DB flush | server | 5000 ms (only when dirty) | |
| invite sweep | server | 30 s | |
| player grid refresh | server | 250 ms per slice, every player refreshed once per 2000 ms | two natives per player per 2 s, ONE thread (§22.1) |

Targets: client idle **0.00–0.02 ms**; ≤ 10 visible markers/labels **< 0.06 ms**; NUI messages ≤ 10/s
(**replaced by §38.10**: idle = 0 messages/s, with feeds ≤ 20 messages/s total). The §6.7 world prompt
projection is the one built-in allowed per-frame work because the dot tracks a world point; it defaults to the
native renderer (DrawSprites, no messages at all), and in `'nui'` mode it uses one reused table, sends only on
a visible change and stops entirely while the camera is still. Never:
`TriggerClientEvent(-1)` from a loop, per-frame `.state` reads, `GetGamePool` per frame, funcref calls per frame.

At 1,000–2,000 players a **full loop over every player is itself the bug**, even off a timer: `Player.getCoords`
is three natives, so one local chat line used to cost ~6,000 native calls on the single server script thread.
Every "who is near this position" answer therefore goes through the player grid (§22.1); a loop over
`Player.getPlayers()` is only acceptable when the answer genuinely concerns everybody (autosave, a global chat
channel, a staff channel).

---

## 10. `shared/config.lua`

```lua
Config = {
    Debug = false,
    CallbackTimeoutMs = 5000,
    StreamingTimeoutMs = 10000,
    RateLimits = { CallbackPerSecond = 20 },
    Net = { DefaultCooldownMs = 250 },
    Player = {
        DefaultModel = 'mp_m_freemode_01',
        SpawnPoint = { coords = vector3(-1037.9, -2738.0, 20.17), heading = 330.0 },   -- LSIA arrivals; first spawn of a new character
        SaveIntervalMs = 300000,
        NewCharacter = { money = { cash = 5000, bank = 25000 } },
        MaxNameLength = 32,
    },
    Respawn = {
        DelayMs = 8000,
        Points = {
            { coords = vector3(295.2, -1446.7, 29.97), heading = 230.0 },   -- Central LS Medical
            { coords = vector3(-449.4, -340.4, 34.5), heading = 80.0 },     -- Mount Zonah
            { coords = vector3(1839.6, 3672.9, 34.28), heading = 210.0 },   -- Sandy Shores
            { coords = vector3(-247.7, 6331.1, 32.43), heading = 220.0 },   -- Paleto Bay
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
        NameMin = 3, NameMax = 32, TagPattern = '^[A-Z0-9][A-Z0-9]?[A-Z0-9]?[A-Z0-9]?[A-Z0-9]?$', TagMin = 2, TagMax = 5,
        DefaultColor = '#5b8cff', InviteTimeoutMs = 60000,
        DefaultRanks = {
            { name = 'Member',  perms = {} },
            { name = 'Officer', perms = { invite = true, kick = true } },
            { name = 'Leader',  perms = { invite = true, kick = true, manage_ranks = true, bank = true, manage = true } },
        },
    },
    Vehicles = { SpawnTimeoutMs = 5000, LockKey = 'U', LockDistance = 20.0, PlatePrefix = 'LS-', MaxPropsBytes = 16384 },
    Interactions = { Key = 'E', ScanIntervalMs = 300, FarScanIntervalMs = 1000, NearRange = 60.0, MaxModels = 8 },
    World = { ScanIntervalMs = 500, GridSize = 100.0 },
    UI = { NotifyDurationMs = 5000, MaxNotifyPerSecond = 10, HudEnabled = true, ModalTimeoutMs = 300000, CancelKey = 'X' },
    DB = { KeyPrefix = 'doc:', FlushIntervalMs = 5000 },
    Admin = { CarDefaultModel = 'adder' },
    Texts = {
        loading = 'Loading your character...', respawn_in = 'Respawn in %d s', respawn_now = 'Respawning...',
        locked = 'Vehicle locked', unlocked = 'Vehicle unlocked', no_keys = 'You have no keys for this vehicle',
        no_permission = 'You are not allowed to do that', usage = 'Usage: %s', insufficient = 'Not enough money',
    },
}
```

Coordinates are approximate and tunable; nothing else in code hard-codes a coordinate.

---

## 11. Example plugin `core_example` (separate resource)

Files: `fxmanifest.lua` (per §1 plugin manifest, no UI files),
`shared/config.lua` (`Config = { Shop = { coords = vector3(25.7, -1347.3, 29.49), heading = 270.0 }, SnackPrice = 5,
SnackHeal = 25 }` — the Strawberry 24/7), `server/main.lua`, `client/main.lua`, `ui/src/index.js` + `ui/src/Page.vue` (compiled into core's shell),
`README.md`.

Server: `Core.Callback.register('core_example:getStats', function(src) return { cash = Core.Money.get(src,'cash'),
bank = ..., faction = Core.Factions.getPlayerFaction(src), name = Core.Player.getName(src) } end)`;
`Core.Net.on('core_example:server:buySnack', {}, handler, { cooldown = 1000, distance = { coords = Config.Shop.coords,
max = 4.0 } })` → `Core.Money.remove(src, 'cash', Config.SnackPrice, 'snack')` → `Core.Net.emit(src,
'core_example:client:snack', Config.SnackHeal)` + `Core.Notify.send`; `Core.Callback.register('core_example:greet',
function(src, name) ... validate string ≤ 32 ... return ('Hello %s, you have %s'):format(name, Core.Utils.formatMoney(cash)) end)`;
`Core.Commands.register('example', { description = 'Open the example page' }, function(src) Core.Net.emit(src,
'core_example:client:openPage') end)`; `Core.on('playerLoaded', function(src) Core.Notify.send(src, 'core_example loaded') end)`.

Client (inside `Core.onReady`): blip (sprite 52, colour 2, "Example shop"), marker (type 1, cyan), text label
"Example 24/7", interaction `{ coords, radius = 2.0, label = 'Buy a snack ($5)', marker = {...}, onInteract = function()
if Core.UI.progress({ label = 'Buying...', duration = 2000, canCancel = true }) then Core.Net.emit('core_example:server:buySnack') end end }`;
`Core.Net.on('core_example:client:snack', { 'integer' }, function(heal) SetEntityHealth(...) end)`; `Core.Keys.register({ name =
'page', key = 'F9', description = 'Example page', onPress = function() Core.UI.open('core_example', { opened = GetGameTimer() }) end })`;
`Core.UI.registerPage('core_example', { type = 'page' })` (the page component lives in `core_example/ui/src/index.js` + `Page.vue` and is compiled into core's bundle);
`Core.UI.on('core_example', 'greet', function(data) local reply = Core.Callback.await('core_example:greet', data.name)
Core.UI.send('core_example', 'greeting', { text = reply }) end)`; `Core.UI.on('core_example', 'menu', function() local v =
Core.UI.menu.open({ title = 'Example', items = { { label = 'Notify me', value = 'notify' }, { label = 'Ask a question', value = 'input' } } })
... end)`. The Vue page (`ui/src/Page.vue`): shows `CoreUI.hud` values, a name input + "Greet" button (emits
`greet`), a "Menu demo" button (emits `menu`), the greeting text from `on('greeting')`, and a close button.

---

## 12. In-game test checklist (draft; final in README)

1. Fresh join → loading fades in at LSIA, HUD shows $5,000 / $25,000, name and id → expect `core:hook:playerLoaded` notify from core_example.
2. `/car adder` (admin) → vehicle spawns, you are warped in, `U` toggles the lock (notify + doors), a second player without keys pressing `U` → "no keys".
3. Walk to the Strawberry 24/7 → blip on the map, marker + text label within 30 m, `[E] Buy a snack ($5)` within 2 m → E → progress bar 2 s → cash −5, health +25; press X during the progress → nothing charged.
4. Stand 4 m away and trigger `core_example:server:buySnack` manually (F8 console) → nothing happens.
5. F9 → example page opens with cursor, ESC closes it and the cursor is gone; restart `core_example` while open → page closed, focus released.
6. `/faction create Test TST` → $25,000 leaves the bank, HUD shows `TST`; invite a second player, accept → both show it; `/faction leave`.
7. Die → "Respawn in 8 s" countdown → respawn at the nearest hospital, `dead` state false; `/revive` from console works.
8. Disconnect and rejoin → position, money and faction persisted; restart `core` while online → no re-spawn, HUD refreshed, markers/interactions of core_example re-registered.
9. `resmon 1`: idle far away 0.00–0.02 ms, next to the shop with the marker < 0.06 ms.

---

## 13. Out of scope (v1) — do not implement, do not stub

Inventory, jobs, needs, character creator UI, garages/parking (use `Core.Vehicles` records), housing, chat
replacement, Discord webhooks (subscribe to `audit`), MySQL adapter (implement `DB.setAdapter`), voice,
radial menu, nametags, weather/time sync.

---

## 14. Implementation notes (decisions taken while building, 2026-09-12)

These refine the sections above; where they differ, this section wins.

- **`Core.Config`** (§2.0) is the only way libs read core's config; the bare `Config` global is the plugin's own.
- **Sub-namespace proxies are callable**: `Core.UI.progress({...})` and `Core.UI.progress.cancel()` both work from a
  plugin (`subProxy` has `__call`). Inside core, `Core.UI.progress` is the function and cancel lives under the flat
  key `Core.UI['progress.cancel']`.
- **`Core.DB.migrate` accepts a re-registration of the same version** (2026-09-13): a plugin restart replays its
  `Core.onReady`, so the same `(collection, version)` arriving again replaces the function quietly and returns `true`
  instead of warning and returning `false`.
- **`Core.Player.setModel` emits `playerDataChanged`** (2026-09-13, for the `inventory` plugin): `(src, 'model', model)`
  and, when an appearance table was given, `(src, 'appearance', copy)` — the same hook `setData` fires (§22), so a
  plugin mirroring the look (worn clothing as items) reconciles after a creator save.
- **`Core.Player(src)` sugar inside core** is attached by `Core`'s `__newindex` when `server/player.lua` assigns the
  table; therefore no server file may *read* `Core.Player` at file scope before `server/player.lua` loads.
- **Registry**: server exposes `Core.Registry.getOwned(owner)`, client exposes `Core.Registry.idsOf(kind, owner)`
  (both internal to core; plugins never call them). the CLIENT `Core.World` (draw scheduler) is blocked from the `call` export; the SERVER `Core.World` (§17 time/weather) is public.
- **`Core.Commands.register`**: `allowConsole` defaults to `true`; handlers run in `pcall`; no built-in cooldown.
- **`Core.Player.setGroup(src, group)`** (server) exists and is what `Core.Perms.setGroup` delegates to; `getInfo`
  includes `license` for server code, but the `core:player:getInfo` callback strips it.
- **Extra public functions** beyond the tables above: `Core.Keys.isDown(cmd)`, `Core.Commands.unregister(name)`,
  `Core.Validate.isSpec(spec)`, `Core.Blips.clearWaypoint()`, `Core.Interactions.removeAll()` (caller scoped),
  `Core.Vehicles.spawnRecord` stores the vehicle `type` in `record.meta.vehType`.
- **Callbacks**: `core:vehicles:mine` lives in `server/vehicles.lua`; `core:faction:mine` returns `false` (not nil)
  when the player has no faction; faction callbacks carry a 1 s per-src cooldown.
- **`Core.Player.setData(src, 'faction', false)`** is how a faction is cleared (nil cannot travel through the API);
  readers treat `nil` and non-table as "no faction".
- **UI shell**: menu items are sent to the page with their index as `value` and mapped back in Lua, so table/vector
  values survive; an `input` result with an empty `required` field counts as cancel (`nil`); built-ins called before
  the NUI reported `ui_ready` resolve immediately with their cancel value; the modal backdrop is
  `rgba(0,0,0,.28)`; the text UI pill is content-sized.
- **Autosave** loop is owned by `server/player.lua` (`Player.startAutosave()` is idempotent); `server/main.lua`
  performs the final `saveAll` on stop.
- **Testing**: `lua5.4 tests/run_tests.lua` (libs + loader with stubbed natives), `ui/tests/shell-regression.js`
  via `agent-browser` on the built `html/` served over HTTP (ES modules do not load from `file://`), and
  Storybook (`cd ui && npm run storybook`) for every built-in UI.
- **Review-driven changes (2026-09-12, after the opus reviews)**: `Core.Net.on`'s `requireLoaded` gates on
  `Core.Player.isLoaded(src)` (server-owned session table), never on the `loaded` state bag (client-writable unless
  `sv_stateBagStrictMode true`); `permission` uses `Core.Perms.has` (ACE + config groups), ACE alone only if
  `Core.Perms` is unreachable — from a plugin VM each is one extra export hop per event. `Core.Callback.register`
  accepts an optional schema: `register(name, schema, fn)`. The `call` export saves/restores the caller around
  yielding calls (per-coroutine record), `pcall`s the target on both sides, and refuses internal APIs
  (`Registry`, `World`, `DB.setAdapter`, `Player.loadSession/loadAllConnected/startAutosave/stopAutosave`).
  Sessions: an unclean reconnect takes the character over from the ghost session (ghost saved first, then
  evicted). The NUI focus watchdog only releases focus core itself took. Progress cancel is a core key mapping
  (`core_cancel`, default `X`, `Config.UI.CancelKey`); modal awaits time out after `Config.UI.ModalTimeoutMs` and
  are cancelled on a shell reload. Page bundle paths must be relative and inside the owner resource.
  `core:client:revive` is not sent by anything (admin `/revive` uses `core:client:spawn`); the handler is harmless.

---

# WAVE 2 — Rebar parity + framework services (2026-09-12, second build wave)

Everything below is additive. The rules of §2–§9 apply unchanged (owner-tracked registrations, `Core.Net.on` for
every net event, `Core.Callback` for RPC, server-owned truth, no per-frame work outside core's loops, hooks as
`core:hook:<name>`). Every new server namespace is reached from plugins through the existing `call` export.
File ownership per run is in PLAN.md §5.

## 15. Server-driven world controllers (`Core.World` sync) — Rebar `use*Global` / `use*Local`

Plugins can define markers, blips, text labels and interactions **on the server**, for everyone or for one
player; the handlers run server-side. Files: `server/worldsync.lua`, `client/worldsync.lua`.

```lua
-- server; every function returns an id string 'g:<n>' and tracks the caller for cleanup on plugin stop
Core.Markers.addGlobal(opts) / Core.Markers.addFor(src, opts)                 -- opts = §6.4 options
Core.Blips.addGlobal(opts) / Core.Blips.addFor(src, opts)                     -- opts = §6.6 options (coords/radius only; no entity)
Core.TextLabels.addGlobal(opts) / Core.TextLabels.addFor(src, opts)           -- opts = §6.5 options
Core.Interactions.addGlobal(opts) / Core.Interactions.addFor(src, opts)
--   opts = §6.7 options minus entity/models, plus: onInteract = fn(src, ctx), onEnter = fn(src, ctx)?, onExit = fn(src, ctx)?,
--          canInteract = fn(src) -> bool? (evaluated server-side when the client asks), cooldown = 500 (per src)
Core.<Kind>.updateGlobal(id, partial), Core.<Kind>.removeGlobal(id)           -- works for addFor ids too
```

Wire: the server keeps `registry[kind][id] = { opts (without functions), owner, target = nil | src }`. On
`playerLoaded` the server sends a snapshot `core:client:worldSnapshot (entries)` (targeted, ≤ 32 KB per
message; split into several messages when larger); on add/update/remove it sends `core:client:worldAdd
(kind, id, opts)`, `core:client:worldUpdate (kind, id, partial)`, `core:client:worldRemove (kind, id)` to `-1`
(global) or to `src` (per-player) — these fire on plugin actions only, never in loops. The client registers
them into the existing modules with owner `'core:server'` and id prefix `s:` (so a client `removeAll()` never
touches them). Interaction triggers: the client sends `core:server:worldInteract (id)` (`Core.Net.on`, schema
`{ 'id' }`, cooldown = the entry's cooldown, distance = entry coords vs ped ≤ radius + 1.0) → the server runs
`onInteract(src, ctx)` in `pcall`; `onEnter/onExit` are sent as `core:server:worldEnter/worldExit (id)` (cooldown
250 ms, distance ≤ radius + 2.0). `canInteract` is asked once on enter via callback `core:world:canInteract`.

## 16. Doors (`Core.Doors`) — Rebar `useDoor`

Files: `server/doors.lua`, `client/doors.lua`. Collection `doors`: `{ id (uid string), model (hash), coords,
locked = bool, perms = { 'core.admin', 'faction:<id>', 'faction:<id>:<minRank>' }, autoLockMs?, meta }`.

```lua
Doors.register({ id = 'lspd_front', model = 'v_ilev_ph_door01', coords = vector3(...), locked = true, perms = {...}, autoLockMs = 0 }) -> id
Doors.unregister(id), Doors.get(id) -> copy, Doors.list()
Doors.setLocked(id, locked, src?) -> bool           -- force; emits hooks doorLocked/doorUnlocked (src or nil)
Doors.toggle(src, id) -> bool, err                  -- permission check: Core.Perms.has(src, p) for any p, or faction rules
Doors.canUse(src, id) -> bool
Doors.getNearest(src, radius = 3.0) -> id|nil
```

State: `GlobalState['door:' .. id] = { locked, model, x, y, z }` (whole value; written on register + change; on
`onResourceStart` published in chunks of 50 with `Wait(0)`). Client: `AddStateBagChangeHandler('door:', 'global', ...)`
prefix-matched by name → `DoorSystemSetDoorState`/`SetStateOfClosestDoorOfType` for doors within 60 m, plus a
1000 ms thread that applies states for doors that streamed in (only for doors within 60 m; sleeps 2000 ms when none
within 100 m). Key: reuses `core_interact` when within 2.0 m of a registered door and no interaction is active →
`core:server:doorToggle (id)` (`Core.Net.on`, cooldown 500, distance ≤ 3.5). Text UI "[E] Lock/Unlock" while near
a door the player may use. Hooks: `doorLocked (id, src|nil)`, `doorUnlocked (id, src|nil)`. Persisted `locked` on
change (DB `doors`, `Doors.register` merges the stored state).
Seeding (2026-09-12, in-game): state-bag change handlers only fire for keys written after the client script
started, so a joining player or a core restart mid-session left the client without any door until the next
change. The client now asks `core:doors:list` (callback, loaded players only, the GlobalState shape) once on
`playerLoaded` and upserts the answer; `/doorfind` also lists every door the client knows with distance, lock
state, whether the object of that model stands at the coords and what the door system reports.
Model verification (2026-09-12): a wrong `model` makes the door system control nothing, silently, so the client
checks once per session (within 40 m, `GetClosestObjectOfType` 2 m) that an object of that model exists at
`coords` and warns in the console otherwise, and the client command `/doorfind` prints the model hash, coords
and heading of the object in front of the player (`Core.Raycast.getEntityInFront`, else the nearest object
within 3 m via `GetGamePool('CObject')`), whether the door system knows it, and whether a registered core door
at that spot expects a different model — with a ready `Core.Doors.register` line.

## 17. Environment (`Core.World`, `Core.Screen`, `Core.Cron`) — Rebar `useWorld`, `useCronJob`, time/weather services

Files: `server/environment.lua`, `client/environment.lua`, `server/cron.lua`.

```lua
-- server
World.setTime(hour, minute, second?)             -- global; GlobalState['core:time'] = { h, m, s, frozen }
World.getTime() -> h, m, s
World.freezeTime(bool), World.isTimeFrozen()
World.setWeather(type, transitionSec = 15)       -- global; GlobalState['core:weather'] = { type, transition }; type validated against Config.World.Weathers
World.getWeather() -> type
World.setTimeFor(src, hour, minute) / World.clearTimeFor(src)        -- per-player override (targeted events)
World.setWeatherFor(src, type, transitionSec) / World.clearWeatherFor(src)
-- clock: Config.World.TimeScale (game seconds per real second, default 30 = 48-minute day), thread ticks every 1000 ms,
-- writes GlobalState only when the game MINUTE changes; hooks timeChanged (h, m), weatherChanged (type)
-- weather cycle: Config.World.WeatherCycle = { { type = 'CLEAR', minutes = 60 }, ... } | nil (nil = manual)
Screen.fade(src, ms), Screen.unfade(src, ms), Screen.blur(src, ms), Screen.unblur(src, ms)
Screen.effect(src, name, durationMs, looped), Screen.clearEffect(src, name), Screen.clearEffects(src)
Screen.timecycle(src, name, strength?), Screen.clearTimecycle(src)
Player.setControls(src, enabled), Player.setFrozen(src, bool), Player.setInvincible(src, bool), Player.setVisible(src, bool)
Player.setHealth(src, hp), Player.setArmour(src, ap), Player.getHealth(src), Player.getArmour(src)   -- server natives where they exist, else client event
Cron.every(intervalMs, fn, opts?) -> id            -- opts.runNow = false; min interval 1000 ms
Cron.at(hour, minute, fn) -> id                    -- server wall-clock (os.date), daily
Cron.schedule(expr, fn) -> id                      -- 5-field cron expression ('*/5 * * * *'), evaluated once per minute
Cron.remove(id), Cron.list() -> array
```

Client (`client/environment.lua`): applies `core:time`/`core:weather` (`NetworkOverrideClockTime`,
`SetWeatherTypeOverTime` then `SetWeatherTypeNowPersist`, `ClearOverrideWeather`), handles the per-player override
events `core:client:timeOverride (h, m | false)`, `core:client:weatherOverride (type, transition | false)`, and the
screen/control events `core:client:screen (op, ...)`, `core:client:playerState ({ controls?, frozen?, invincible?,
visible?, health?, armour? })`. One thread (1000 ms) re-applies the clock while an override or frozen time is active.

## 18. Stats (`Core.Stats`) — Rebar `useStatus` / needs

Files: `server/stats.lua`, `client/stats.lua`. Config:

```lua
Config.Stats = {
    Enabled = true, TickMs = 60000,
    Defs = {
        hunger = { min = 0, max = 100, default = 100, decayPerMinute = 0.4, thresholds = { 25, 10 }, hud = 'health', icon = 'hud-food' },
        thirst = { min = 0, max = 100, default = 100, decayPerMinute = 0.6, thresholds = { 25, 10 }, hud = 'armour', icon = 'hud-drink' },
    },
}
```

`hud` is `true` (a bar on the rail plate), `'health'` / `'armour'` (the bar cut out of that HUD plate, §39) or
`false`; `icon` is a kit icon name for the slot's glyph.

```lua
Stats.get(src, name) -> number, Stats.set(src, name, value) -> bool, Stats.add(src, name, delta), Stats.sub(src, name, delta)
Stats.getAll(src) -> table, Stats.define(name, def) -- plugins may add stats at start (before players load)
Stats.reset(src, name?)
```

Stored in `data.stats` (character document), decayed once per `TickMs` for every loaded player (one thread),
clamped to min/max, replicated as `Player(src).state.stats = { name = value }` (whole table, at most once per
second per player: dirty flag + the tick), hooks `statChanged (src, name, value)` (only on set/add/sub, not on
decay) and `statThreshold (src, name, threshold, value)` when a value crosses a threshold downwards. Client
`Core.Stats.get(name)` reads `LocalPlayer.state.stats` (§3.11 lib style) and the HUD shows bars for defs with
`hud = true` (§21).

## 19. Weapons (`Core.Weapons`) — Rebar `useWeapon`

Files: `server/weapons.lua`, `client/weapons.lua`. Loadout stored in `data.weapons = { [weaponName] = { ammo,
tint?, components = {} } }` (names like `WEAPON_PISTOL`, validated with `Config.Weapons.Allowed` list or any
`WEAPON_%u+` pattern when the list is nil).

```lua
Weapons.give(src, weapon, ammo = 0, opts?) -> bool      -- opts.tint, opts.components; persists; TriggerClientEvent core:client:weaponGive
Weapons.remove(src, weapon) -> bool, Weapons.clear(src)
Weapons.setAmmo(src, weapon, ammo), Weapons.addAmmo(src, weapon, delta)
Weapons.has(src, weapon) -> bool, Weapons.getLoadout(src) -> copy
Weapons.apply(src)                                     -- sends the whole loadout (core:client:weaponsApply); called on spawn by player.lua's loaded flow via hook playerLoaded and on respawn
```

Client: applies with `GiveWeaponToPed`/`SetPedAmmo`/`GiveWeaponComponentToPed`/`SetPedWeaponTintIndex`, removes
with `RemoveWeaponFromPed`/`RemoveAllPedWeapons`; every 60 s (and on `playerDied`) sends `core:server:weaponsSnapshot
({ [weapon] = ammo })` (`Core.Net.on`, cooldown 30 s, schema `{ 'table', max = 64 }`): the server only accepts weapons
already in the loadout and ammo `0 ≤ ammo ≤ storedAmmo` (ammo can only go down between snapshots; increases come
from `addAmmo`). Security (§25): `weaponDamageEvent` with a weapon the sender does not own is cancelled when
`Config.Security.EnforceLoadout` is true. Hook `weaponsChanged (src)`.

## 20. Remote player control — Rebar `useNative`, `useAnimation`, `useAudio`, `useAttachment`, `useWaypoint`, `useRaycast`, `useScreenshot`

Files: `server/remote.lua`, `client/remote.lua`, `lib/audio/client.lua`.

```lua
Native.invoke(src, name, ...)                       -- fire-and-forget: core:client:native (name, args); client calls _G[name] if allowed
Native.invokeWithResult(src, name, ...) -> ...      -- Core.Callback.awaitClient('core:native', ...)
-- allowlist: Config.Native.Allow = nil (any global function whose name matches ^%u[%w_]+$ and exists) | { 'SetEntityHealth', ... }
Anim.play(src, dict, clip, opts?) / Anim.stop(src)  -- client lib Core.Anim (§3.10) via core:client:anim
Audio.playFrontend(src, name, set) / Audio.playAt(coords, name, set, range?)  -- to src, or to every player within range (≤ 20 targets; the server tests the player grid's candidates (§22.1), not every session, and sends one packed payload with Net.emitMany)
Attachments.add(src, { id, model, bone, offset = vector3, rotation = vector3 }) -> id / Attachments.remove(src, id) / Attachments.clear(src) / Attachments.list(src)
--   persisted in data.attachments; replicated as Player(src).state.attachments (whole table); EVERY client attaches props to that ped
--   (state-bag change handler + a 2000 ms sweep for peds that streamed in; objects are local, created with CreateObject(…, false, false, false))
Waypoint.set(src, coords) / Waypoint.clear(src) / Waypoint.get(src) -> vector3|nil (awaitClient)
Raycast.fromPlayer(src, distance = 10.0) -> hit, coords, entityNetId|0 (awaitClient)
Screenshot.take(src, opts?) -> url|nil             -- only if GetResourceState('screenshot-basic') == 'started'; exports['screenshot-basic']:requestClientScreenshot (verify the export name in that resource); else nil, 'unavailable'
Player.setReplicated(src, key, value)                -- Player(src).state[key] for plugin keys; refuses core keys (§8 list)
```

Client `lib/audio/client.lua`: `Audio.playFrontend(name, set)`, `Audio.playAt(coords, name, set)` (`PlaySoundFromCoord`),
`Audio.stop(id)`.

## 21. Server-side UI API and new built-ins — Rebar `useWebview`, `useNotify.showShard/showSpinner`, instructional buttons

Files: `server/ui.lua`, `client/ui_remote.lua`, additions to `client/ui.lua`, Vue: `Shard.vue`, `Spinner.vue`,
`KeyHints.vue`, `StatsBars.vue`, store/coreui additions.

```lua
-- server (all forward to the player's client; awaiting ones use Core.Callback.awaitClient with the UI timeout)
UI.open(src, id, props?), UI.close(src, id?), UI.send(src, id, event, data)
UI.notify(src, ...) (alias of Notify.send), UI.textUI.show(src, key, text, opts?) / UI.textUI.hide(src)
UI.progress(src, opts) -> completed:boolean, UI.menu.open(src, opts) -> value|nil, UI.input.open(src, opts) -> values|nil, UI.alert(src, opts) -> bool
UI.keys.show(src, { { key = 'E', label = 'Interact' }, ... }) / UI.keys.hide(src)
UI.shard(src, { title, subtitle?, duration = 4000, style = 'wasted'|'success'|'info' })
UI.spinner.show(src, text) / UI.spinner.hide(src)
UI.hud.setVisible(src, bool)
-- client additions (client/ui.lua): UI.keys.show/hide, UI.shard(opts), UI.spinner.show/hide, UI.stats.set(table) (internal), UI.state.set(key, value) (internal),
--   UI.locale.set(table) (internal), NUI callback ui_sound { name, set } -> PlaySoundFrontend
```

Client `client/ui_remote.lua` registers callbacks `core:ui:progress`, `core:ui:menu`, `core:ui:input`, `core:ui:alert`
(each calls the local `Core.UI.*` and returns the result) and net handlers `core:client:ui (op, ...)` for the
non-awaiting ops (`open/close/send/textUI/keys/shard/spinner/hud`). NUI messages added: `keys:show { items }`,
`keys:hide`, `shard:show { title, subtitle, duration, style }`, `spinner:show { text }`, `spinner:hide`, `stats:set
{ [name] = { value, min, max } }`, `state:set { key, value }`, `locale:set { lang, strings }`; page → Lua: `ui_sound
{ name, set }`. `window.CoreUI` gains `state` (reactive replicated player state, from `state:set`), `t(key, vars)`
(from `locale:set`), `playSound(name, set)`, `minimap` (anchor rect computed by the client from `GetSafeZoneSize`
+ resolution, sent once via `hud:set { minimap = { x, y, w, h } }`). HUD extension: health/armour bars and
`StatsBars.vue` for `Config.Stats` defs with `hud = true`; `client/hudfeed.lua` pushes `hud:set { health, armour,
speed (km/h), street, zone }` at most every 250 ms and only on change (street/zone every 1000 ms).

## 22. Getters, globals, services, plugin API registry, permissions — Rebar `get`, `useGlobal`, `useServices`, `useApi`, `usePermissions`

Files: `server/getters.lua`, `server/globals.lua`, `server/services.lua`, edits to `server/perms.lua`, `server/player.lua`, `server/db.lua`.

```lua
Player.getClosest(src, maxDist = 50.0) -> src|nil, dist; Player.getInRange(coords, range) -> array of { src, dist }
Player.findByName(name) -> src|nil (exact, case-insensitive), Player.findByPartialName(part) -> array; Player.getInVehicle(netId) -> array of src
Player.isNear(src, coords, range) -> bool; Player.getStreet(src) -> street, zone (awaitClient)
Vehicles.getInRange(coords, range) -> array of netId (core vehicles only), Vehicles.getDriver(netId) -> src|nil, Vehicles.getPassengers(netId) -> array
Vehicles.getClosestToPlayer(src, maxDist = 20.0) -> netId|nil; Vehicles.setData(netId|vehId, key, value) / getData — record meta
Globals.get(key, default?) / Globals.set(key, value) / Globals.increment(key, delta = 1) -> number / Globals.unset(key)   -- document 'globals'/'server', persisted; Globals.set(key, value, true) also mirrors to GlobalState['g:' .. key]
--   the document is read on first access; that read yields on an asynchronous backend (postgres, mysql), and every caller arriving during it
--   waits on the same promise (the db.lua barrier) — a plugin's onReady and its first cron tick may hit Globals at once (2026-09-16)
Services.register(name, impl) -> bool / Services.get(name) -> impl|nil / Services.has(name) / Services.unregister(name)
--   documented interfaces (README): notification { send(src, msg, type), broadcast(msg, type) }, currency { add(src, account, n, reason), sub, has, get },
--   death { respawn(src, coords, heading), revive(src) }, items { add(src, id, qty, data), sub, has, remove(src, uid), get(src) }, time { set(h, m), get() },
--   weather { set(type, transition), get() }. Core registers notification/currency/death/time/weather itself at start; `items` stays empty until an inventory plugin registers it.
Api.register(name, table) / Api.get(name) -> table|nil     -- plugin-to-plugin API sharing through core (functions cross as funcrefs; document the cost)
Perms.grant(src, perm, scope = 'account'|'character') -> bool / Perms.revoke(src, perm, scope) / Perms.list(src) -> array
--   stored on account.permissions / character.permissions; Perms.has checks: console → ACE → account list → character list → config group
DB.nextId(name) -> integer (persistent counter document 'counters'/name), DB.migrate(collection, version, fn(doc) -> doc) (registered before start; documents carry _v; run once per collection on first load)
DB.export(path?) -> path (SaveResourceFile('core', 'data/export-<timestamp>.json', json)), DB.import(path, mode = 'merge'|'replace') -> count
-- console/admin commands: /dbexport, /dbimport <file> [replace] (console only)
Player hook additions: playerDataChanged (src, topKey, value) emitted by setData; Player.setReplicated (§20)
```

### 22.1 Player grid (2026-09-18)

File: `server/playergrid.lua` (manifest order: right after `server/player.lua`). Module table
`Core.PlayerGrid`, **internal** — listed in `INTERNAL_NAMESPACES` in `server/api.lua` exactly like
`Registry`, so a plugin can never reach it through `exports.core:call`. Plugins get its benefit through the
unchanged `Player.getInRange` / `Player.getClosest` and through chat.

Why: §9. `Player.getInRange`, `Player.getClosest`, `Chat.sendNear`, the proximity branch of the chat
dispatcher and `/s` all answered "who is near this position" by looping over **every** loaded player and
calling `Player.getCoords` (three natives) per player. At 2,000 players that is ~6,000 native calls per
local chat line, on the one server script thread, per message.

```lua
PlayerGrid.candidates(coords, range, out) -> count   -- fills out[1..count] with srcs; the TAIL IS STALE
PlayerGrid.count() -> integer                        -- players currently held by the grid
PlayerGrid.cellOf(src) -> key|nil                    -- tests and debug only
```

- **Cells.** Size `Config.World.PlayerGridSize` (default `128.0` m), read once at start — the key encoding
  depends on it, so a live edit does not apply. Integer key `(cx + 32768) * 65536 + (cy + 32768)` with
  `cx = floor(x / size)`, clamped to that range; `cells[key] = { [src] = true }` and
  `where[src] = { key, x, y, z, at }`. The record table is reused on every update, so a refresh allocates
  nothing.
- **Refresh.** ONE thread. Every `STEP_MS = 250` it refreshes the next slice of the loaded players so that
  every player is refreshed once per `REFRESH_MS = 2000`: `slice = ceil(n * STEP_MS / REFRESH_MS)`, walking a
  src array that is rebuilt only when the player set changed (`playerJoining` — where the session is created —
  and `playerLoaded` add and refresh that player immediately, `playerDropped` removes). Per player exactly two
  natives, `GetPlayerPed(src)` (skip on `0`) and
  `GetEntityCoords(ped)` — no heading, no allocation. With nobody loaded the thread sleeps 1000 ms and does
  nothing. Never `Wait(0)`.
- **Queries are exact, the candidate set is approximate.** `candidates` returns the srcs of every cell the
  box around `range + SLACK` touches, `SLACK = 64.0` m — two seconds of staleness at ~30 m/s (a vehicle) is
  60 m. The caller then does the **exact** distance test with a live `Player.getCoords(src)` on the
  candidates only, so results are identical to the old full loop. A player who moves further than `SLACK` in
  less than one refresh period (a teleport) can be missed for at most that period.
- **`out` is the caller's reusable array**: `candidates` writes `out[1..count]` and never clears the tail —
  callers must use the returned count, never `#out`.
- **Fallback.** While `count() == 0` (the first second after a start, or a suite that never ran the thread) —
  and for an absurd radius, `range + SLACK > 4096` m, where the cell walk would cost more than the loop —
  `candidates` answers with every loaded player, i.e. the old full loop, so a query is never wrong, only
  slower. A loaded player whose ped does not exist yet (`GetPlayerPed == 0`) has no cell; it is kept in a
  pending set and added to every candidate list until its ped appears, which preserves
  `Player.getCoords`'s saved-position fallback for exactly those players.

## 23. Chat (`Core.Chat`) — CEF messenger

Files: `server/chat.lua` (routing, channels, permissions) + `client/chat.lua` (NUI bridge) + the shell's
`Chat.vue` (feed and input). The stock `chat` resource is **not** needed for rendering: core cancels its
`chatMessage` (kept for servers that still run it) and the shell renders the feed itself, exactly like the
rest of §7. `chatResult`-style command execution is mirrored: non-commands go to the server as
`core:server:chat:send`, `/commands` use **client** `ExecuteCommand` (without the slash). Server commands
retain the player's identity and §3.7 checks — never execute them as server console (src 0).

Config `Chat = { Mode = 'global'|'proximity', ProximityRange = 20.0, MaxLength = 200, CooldownMs = 800,
ScreamRange = 60.0, ScreamCommand = 's', History = 80, FadeMeters = { near = 20.0, far = 90.0 } }`.

Channels (server-truth; the client only renders):

```lua
Chat.registerChannel(name, { command, permission?, format?, global?, staffOnly?, color?, range?,
                             description?, proximity?, fade? })
-- built-ins: local ('{tag}{name}: {msg}', proximity, default), ooc (global), faction
--   ('[FAC] {name}: {msg}', faction members only), a (staff, core.mod), me, and /pm <id> <msg>.
Chat.send(src, message, opts?)      -- opts = { color?, prefix?, channel? } → one CEF line
Chat.broadcast(message, opts?)      -- announcements, one core CEF broadcast
Chat.sendNear(coords, range, message, opts?) -> count
Chat.setFilter(fn(src, channel, msg) -> bool)   -- false vetoes
Chat.clear(src)                     -- wipe one player's feed (client-side only)
```

Delivery is one `TriggerClientEvent('core:client:chat', target, payload)` per recipient, payload
`{ action = 'add', line = { id, seq, channel, name, text, tag?, color?, kind, opacity } }` where `kind` is
`message|me|system|pm|scream` and `opacity` is 0..1: proximity lines arrive with the **sender distance**
(the client only applies it — the server computes `1 - (dist - near) / (far - near)`, clamped, so distant
speakers genuinely fade). Global/system lines arrive at 1. Scream (`/s <msg>`, also `+scream` keybind-free
command) doubles the effective range and arrives at opacity 1.

Client: `Core.Keys.register` maps **T** to open the CEF input (KeyHints-free; the input is a third
focus owner in `client/ui.lua` — keyboard only, never a cursor, refused while a page/modal holds it,
closed by every §31 hide). The shell stores history (`Config.Chat.History` lines) and offers a command
list, caret-aware argument hints and idle fading as specified in **§30.3**. Suggestions come from the
server-pushed snapshot and each plugin's command VM; Ctrl+TAB cycles permitted channels. The client keeps
**no** authority: every send is validated server-side (schema, cooldown, channel permission, loaded
session). Chat is Registry-tracked as kind `chat`; `restart core` re-seeds suggestions.

A `/command` typed into the CEF input runs through the ENGINE's command path, exactly like the stock
chat's NUI: the client calls `ExecuteCommand` locally (client-registered commands run in their VM) and
the engine forwards unknown-to-client commands to the server as `__cfx_internal:commandFallback` with
the player's identity — core's permission wrapper applies as if typed anywhere else. `ExecuteCommand`
is never called on the SERVER from chat input (that would run as console, src 0). Core re-registers
console `say` as a SYSTEM broadcast and sends join/leave system lines itself.

Formats understand `{tag}`, `{name}`, `{id}`, `{msg}`. Sanitizing: `Utils.sanitize` + all carets stripped
(cleanText). Hook `chatMessage (src, channel, msg)` fires once a message passed the filter, before delivery.

## 24. HTTP (`Core.Http`) — Rebar `useProxyFetch`, `useHono`

File: `server/http.lua`. `Http.fetch(url, { method = 'GET', body = table|string, headers = {}, timeoutMs = 10000 }) ->
status, body(string|table when JSON), headers` (awaits `PerformHttpRequest` with a promise; body tables are
json-encoded; responses with `content-type: application/json` are decoded in `pcall`); `Http.route(method, path,
handler(req) -> status, body, headers?)` registers HTTP endpoints on the server's own port via `SetHttpHandler`
(one dispatcher; `req = { method, path, query, headers, body }`); `Http.setToken(name, convarName)` reads secrets
from convars only. Webhook helper (`server/webhook.lua`): `Webhook.send(name, { title, description, color, fields })`
posts a Discord embed to the URL in convar `core_webhook_<name>` (empty = disabled), batched (≤ 1 request per 2 s
per webhook, embeds grouped up to 10); core subscribes the `audit` hook to `Webhook.send('audit', ...)` when the
convar is set.

## 25. Security extras (`server/security.lua`)

`Config.Security = { EntityLockdown = 'inactive' | 'relaxed' | 'strict' (applied to bucket 0 at start with
SetRoutingBucketEntityLockdownMode), EnforceLoadout = true (§19: weaponDamageEvent from a weapon the sender does
not own → CancelEvent + audit + hook cheatDetected (src, 'weapon', data)), BlockExplosions = false (explosionEvent
→ CancelEvent unless the sender has perm core.explosions; always hook explosion (sender, data)), MaxWeaponDamageMultiplier = 1.0
(weaponDamageEvent with weaponDamage above the config table Config.Security.WeaponDamage[weaponHash] * multiplier → cancel + audit),
KickOnDetect = false, MaxNetIdsPerSecond = nil }`. Hooks: `weaponDamage (sender, data)` (before the checks; a
handler may return `false` via `Core.Security.setDamageFilter(fn)` to cancel), `explosion (sender, data)`,
`cheatDetected (src, kind, details)`. Never trusts payload player ids; `sender` is the server-provided source.

## 26. Locale (`Core.Locale`) — Rebar `translate`

File: `lib/locale/shared.lua`, `core/locales/en.json`, `core/locales/de.json`, template `locales/en.json`.
`Locale.t(key, vars?) -> string` looks up `<callingResource>/locales/<lang>.json` first (loaded once per VM via
`LoadResourceFile(Core.name, 'locales/<lang>.json')`; plugins list `locales/*.json` in `files {}`), then core's
`locales/<lang>.json`, then `Core.Config.Texts[key]`, then the key itself; `{{var}}` substitution; `lang =
Core.Config.Locale` (default `'en'`, core `shared/config.lua` gains `Locale = 'en'`). `Locale.setLanguage(lang)`
(in-VM), `Locale.has(key)`, `Locale.getLanguage()`, `Locale.all()` (merged strings for the NUI push). Locale files use
`{{var}}` placeholders (`{{seconds}}`, `{{usage}}`, `{{key}}`, `{{weapon}}`, `{{max}}`, `{{stat}}`); `Config.Texts` keeps its
`%d/%s` forms for the legacy call sites. The client pushes core's + every loaded plugin's strings? No — only core's strings go to
the NUI (`locale:set` on `ui_ready`); plugin pages import their own locale JSON at build time. Core's existing
`Config.Texts` keys are mirrored into `locales/en.json` (`de.json` = German translations of the same keys).

## 27. Framework tooling

- `types/core.lua`: LuaLS `---@meta` file declaring `Core` and every namespace/function of §3–§6 and §15–§26 with
  `---@param`/`---@return` annotations (generated from DESIGN + the code; kept in sync by hand). `resources/.luarc.json`
  with `workspace.library = ["core/types"]`, `runtime.version = "Lua 5.4"`, `diagnostics.globals = ["Config", "Core", ...]`
  plus the FiveM natives via the `cfxlua` addon note in README.
- `core/scripts/new-plugin.sh <name>`: copies `templates/plugin` to `resources/<name>`, replaces `my_plugin` placeholders,
  prints next steps. `core/scripts/check.sh`: `fxlint core core_example` + `luac5.4 -p` + `lua5.4 tests/run_tests.lua` +
  `lua5.4 tests/server_tests.lua` + `cd ui && npm run build` (+ `npm run build-storybook` with `--full`).
- `resources/.github/workflows/core-ci.yml`: Ubuntu, Lua 5.4 (`apt-get install lua5.4`), Node 22, runs the syntax check, both
  test suites and the UI + Storybook builds (fxlint is local tooling and is skipped in CI).
- `tests/server_tests.lua` (+ `tests/stubs.lua` extensions): db (KVP adapter round trip, nextId, migrate, export/import),
  perms (ACE stub, grants, groups), money (add/remove/transfer/rollback), player sessions (join/load/save/drop, ghost
  takeover), factions (create/invite/accept/rank/kick/bank + permission chain), vehicles (spawn stub/keys/records),
  stats decay + thresholds, globals, services, cron.
- `server/db_mysql.lua`: the oxmysql adapter (`Config.DB.Adapter = 'mysql'` and `GetResourceState('oxmysql') == 'started'`),
  table `core_documents (collection VARCHAR(64), id VARCHAR(64), data LONGTEXT, updated_at, PRIMARY KEY (collection, id))`,
  created with `CREATE TABLE IF NOT EXISTS`; `loadAll` = one SELECT per collection; `put` = INSERT … ON DUPLICATE KEY UPDATE;
  `remove` = DELETE; `flush` = no-op; uses `exports.oxmysql:query_async`/`execute` style calls in `pcall` (verify the export names
  in oxmysql's docs; the adapter is untestable on the dev server — document that).

## 28. Config additions (`shared/config.lua`)

`Locale = 'en'`, `World = { … existing …, TimeScale = 30, StartTime = { 12, 0 }, Weathers = { 'CLEAR', 'EXTRASUNNY',
'CLOUDS', 'OVERCAST', 'RAIN', 'CLEARING', 'THUNDER', 'SMOG', 'FOGGY', 'XMAS', 'SNOW', 'SNOWLIGHT', 'BLIZZARD', 'HALLOWEEN' },
DefaultWeather = 'CLEAR', WeatherCycle = nil }`, `Stats` (§18), `Weapons = { Allowed = nil, SnapshotIntervalMs = 60000 }`,
`Native = { Allow = nil }`, `Chat` (§23), `Security` (§25), `Doors = { InteractDistance = 2.0 }`, `DB.Adapter = 'kvp'`,
`Hud = { ShowHealth = true, ShowArmour = true, ShowStats = true, ShowSpeed = true, ShowStreet = true }` (superseded by §39.5:
`ShowVoice`, `Anchor`, `Scale` joined and `ShowSpeed` / `ShowStreet` default to false).

## 29. Wave 2 implementation notes (decisions taken while building)

- **World controllers**: server ids are `g:<n>`; on the client they are registered under owner `core:server` with the
  modules' own ids (no `s:` prefix). `worldExit` is honoured only after a seen `worldEnter` (server-side presence
  table), because a client notices an exit only after it has left the radius. `canInteract` is answered from a
  client-side cache (pessimistic `false` until the first answer, denials re-asked every 5 s) and re-evaluated on the
  server before `onInteract` runs. Snapshots carry a `first` flag for chunked replace.
- **Doors**: not tracked in `Core.Registry` (a plugin's doors survive its restart on purpose); each client registers
  the door locally under `GetHashKey('core_door_' .. id)`; `unregister` keeps the DB document and sets the
  GlobalState key to `false`; the `core_door` key mapping shares `Config.Interactions.Key` and yields to an active
  interaction. Prompt cadence has a 250 ms tier within 10 m.
- **Environment**: the weather transition native is `SetWeatherTypeOvertimePersist(type, seconds)`;
  `WeatherCycle.minutes` are in-game minutes; cron jobs are tracked as Registry kind `cron` and run in a short-lived
  thread per execution (a yielding job never stalls the scheduler); `Services.get('time').get()` returns `h, m, s`.
- **Stats**: `add/sub` take positive deltas only; `statChanged` fires only when the value moved; `deaths`/`playtime`
  share `data.stats` and are not definable; runtime `Stats.define` values replicate but get no HUD bar (defs are
  read from the client's own config).
- **Weapons**: `give` tops up ammo, `setAmmo` sets; the allow-list gates grants only; `hasHash` returns
  `ok, weaponName` and compares unsigned hashes; the client re-applies its cached loadout on its own
  `playerLoaded`/`playerRespawned` hooks (model swaps wipe weapons).
- **Remote**: `Screenshot.take` forwards only `encoding`/`quality`; ≤ 12 attachments per player, default bone 28422;
  `Raycast.fromPlayer` capped at 100 m; native calls ≤ 16 args; attachments are re-published on `playerLoaded`.
- **Server UI**: `core:client:ui (op, args)` where `args` is one positional table (≤ 3 entries); modal awaits use
  `Core.Callback.awaitClientTimeout` with `Config.UI.ModalTimeoutMs` (progress: `duration + 5000`).
  `Core.UI.hud.isVisible()` exists on the client; `hud.set` accepts `health/armour/speed/street/zone/minimap`
  (health/armour as 0..100 %, speed as km/h).
- **Getters**: `GetVehicleMaxNumberOfPassengers` is client-only, so `getPassengers` scans seats 0..15;
  `Globals` stores values under `values` in the `globals/server` document; `Services.register` accepts any name,
  last registration wins; `Api.register` refuses a name owned by another resource; services/APIs of a stopped
  resource are dropped.
- **Chat**: `chatMessage` arrives as `(playerSrc, name, message)` arguments (verified in the stock resource);
  channels may declare `staffOnly`, `color`, `range`, `description`; console `say` re-broadcasts as `SYSTEM`; a
  mistyped `/command` is answered privately; channels are not Registry-tracked. §23 rebuild (2026-09-13): the
  shell renders the feed (Chat.vue), delivery is `core:client:chat (action = 'add')` per recipient, proximity
  lines carry a per-recipient `opacity`, `/s` screams (doubled range, opacity 1), TAB suggestions are pushed
  on `playerLoaded`, and `/commands` from the CEF input run through `Core.Commands.execute` (§30.2).
- **Http**: routes live under `/core<path>` (per-resource handler); `Http.fetch` returns `nil, reason` on failure;
  bodies are collected with a 5 s fallback; detections in `security.lua` (audit/hook/kick) are throttled to one per
  src per kind per 5 s while the cancel itself never is; `BlockExplosions` cancels + audits without `cheatDetected`.
- **DB**: `nextId` persists every call; migrations stamp `_v`; `export`'s collection discovery scans KVP only on the
  KVP adapter; the MySQL adapter's `loadAll` must be reached from a coroutine and its export names are unverified
  (no MySQL on the dev box). Account permission grants go through `Player.setAccountData` (live session), never a
  direct `accounts` write.
- **Vehicles**: `setOwner` revokes the previous owner's key (keys follow ownership); the first `requestLoad` per
  src is always answered (cooldown keyed on nil).
- **Locale**: `LIB_MODULES` gained `Locale` and `Audio`; placeholders are `{{var}}`; `Config.Texts` keeps `%d/%s`.
- **Tests**: `lua5.4 tests/server_tests.lua` (554 checks: db, perms, player, money, factions, vehicles, api) next to
  `tests/run_tests.lua` (379); `tests/stubs.lua` now stubs the server world (KVP, players, entities).

## 30. Wave 2 review-driven changes (2026-09-12, after the three wave-2 reviews)

- **Weapons/security**: `Core.Weapons.hasHash` is tri-state (`true, name` / `false` / `nil` = unknown); only `false`
  cancels damage; `Config.Security.ExemptWeapons` (nil = built-in melee/environment/vehicle-weapon list) skips the
  loadout check; per-src hash cache; a separate `core:server:weaponsSnapshotDeath` event (2 s cooldown).
- **World controllers**: `core:client:worldAdd`/`worldRemove` carry arrays (≤ 512), adds are coalesced per tick,
  owner-stop removals go out as one batch; `updateGlobal/removeGlobal` refuse another owner; presence callbacks
  have a per-(src,id) 250 ms invocation cooldown; the `canInteract` callback requires a loaded session, ≤ radius + 5 m
  and a 250 ms cooldown.
- **Doors**: all GlobalState writes go through one paced queue (≤ 40 keys/s); unregister clears the key after a
  `false` notification; the `canUse` callback is gated (loaded, ≤ 10 m, 500 ms); clients ask off-thread; doors are
  unlocked and `RemoveDoorFromSystem`ed on forget/stop.
- **Environment**: `NetworkClearClockTimeOverride` on stop; clock deltas clamped; world state persisted in
  `world/state`; services registered only by `services.lua` (defaults survive a plugin stop via `Services.getOwner`).
- **Server UI**: menu answers must be a valid non-disabled index and return the server's value; input answers are
  validated field-by-field; progress only returns `true` when `duration - 250 ms` elapsed; alerts coerce to boolean.
  Client: results are checked against the pending request's kind; a dead shell resolves progress to `false`;
  `ui_ready` ≤ 1/s; text UI has owners (`show(key, text, { owner })`, `hide(owner)`, `isShown(owner)`);
  `state:set` is batched (`values`); `ui_event` page/event ids are plain (`^[%w_%-]+$`).
- **Remote**: `Config.Native.Allow` nil = DENY (an explicit list ships in config); a hard deny-list is enforced on
  both sides and audited; raycast answers are validated (entity exists, ≤ distance + 5 m, finite); attachments ≤ 12
  and validated on both sides; the client sweep only visits players with attachments; audio ids are released on stop.
- **HTTP/webhooks**: in-flight accounting covers parked bodies; `Config.Http.AllowPrivate/AllowHosts` guard
  `Http.fetch` (loopback/RFC1918 refused by default); webhook convars are re-read at runtime.
- **DB**: a failed adapter load leaves the collection unloaded (reads retry, writes refused, hook `dbDegraded`,
  `DB.isDegraded`); one loader per collection (promise parked in `loading`); MySQL write rejections degrade the
  collection; export/import only under `data/*.json`, export ≤ 32 MB; `DB.markDegraded` is internal.
- **Perms**: account grants via `Player.setAccountData`; character grants cached and invalidated by `playerDataChanged`.
- **Chat**: every caret is stripped from outbound lines.
- **Vehicles**: `setOwner` revokes the previous owner's key.
- **Function references are tables** (found on the live server): a function passed through `exports.core:call`
  arrives as a funcref proxy — a TABLE with a `__call` metamethod — so every check on a plugin-supplied callback
  uses `Core.Utils.isCallable(v)` (function or callable table), never `type(v) == 'function'`. Applied to world
  controllers, cron, services contracts, chat/security filters, HTTP routes, DB predicates/migrations,
  `Player.forEach`, client interactions and `Stats.onChange`.
- **Server operations**: after adding scripts to a manifest run `refresh` before `ensure` — FXServer caches
  manifests, so `ensure core` alone restarts the resource with the OLD file list.

### 30.1 Console-warning hygiene (2026-09-12, in-game)

FiveM replaces the game's entity-by-network-id lookup with a version that logs
`GetNetworkObject: no object by ID <n>` for every id the client does not hold, and the client-side
`GetEntityFromStateBagName` goes through that lookup. Entity state bags do reach clients that have the
entity out of scope, so a server writing a bag on a far-away ped every 2 s spammed the console. Rule:
every `entity:` bag handler parses the id and checks `NetworkDoesEntityExistWithNetworkId` (warning-free)
before resolving (`entityFromBag` in client/vehicles.lua), and `NetworkGetEntityFromNetworkId` is only
ever called behind that same check (blips, interactions, vehicles).

### 30.2 Chat is CEF-first (2026-09-13, chat rebuild)

The §23 rebuild replaces the stock chat's NUI with core's own shell component:
- Suggestions, channel chips and the history length come from a **server-pushed**
  `core:client:chat (action = 'suggestions')` snapshot on `playerLoaded` and on the `ui_ready` re-seed —
  the client never enumerates commands itself, so a permission-refused command never appears as a
  suggestion and a factionless player never sees the faction chip.
- `/commands` typed into the CEF input go through the engine's command path: client `ExecuteCommand`,
  server-side execution arrives as `__cfx_internal:commandFallback` with the player's identity, so
  core's permission wrapper applies. `ExecuteCommand` is never called on the SERVER from chat input
  (that would run as console, src 0, bypassing Core.Perms).
- The stock `chatMessage` interceptor is kept so servers that still show chat's own NUI stay consistent,
  but the shell never renders `chat:addMessage` — one renderer, no double feed. Remove `ensure chat`.

### 30.3 Chat usability and lifecycle (2026-09-13, supersedes §23/§30.2 presentation)

- Top-left, unboxed text feed with an explicit space after `name:` and between faction tag/name.
  A slim input and command helper are the only panels; no idle border, channel chips or TAB badge.
- `Config.Chat.HideDelayMs = 8000` fades the feed after inactivity (0 disables auto-hide).
  New messages and closing the input restart one CEF timeout; no polling or per-frame Lua work.
  `VisibleLines = 8` limits the idle feed, `History = 80` bounds both received and sent history
  (1–200). Opening chat restores the retained feed at full opacity, scrolls to the latest line,
  and allows PageUp/PageDown reading. Closed proximity lines retain the server's distance opacity.
  `MaxLength` is passed to the shell and enforced as a UTF-8 byte limit (1–256); commands allow 512 bytes.
- Typing `/` shows a filtered, scrollable list **below** the input: command, description and signature.
  Up/Down selects without changing the draft; Tab accepts, Shift+Tab selects the previous match.
  Enter completes a partial/explicitly selected command without executing it; otherwise Enter sends.
  A known command followed by whitespace shows its signature with the argument at the caret highlighted,
  plus its help/type/required status. Quoted words count as one slot; a `rest` argument stays active
  across words. Command completion preserves existing arguments and never replaces ordinary text.
  With no command list, Up/Down recalls sent history and restores the unsent draft on returning down;
  Ctrl+Tab / Ctrl+Shift+Tab cycles the permitted channels. IME composition never submits a line.
- Suggestion params retain `name`, `help`, `type`, `optional`. Channel suggestions include their message
  param. The shell deduplicates command/channel metadata; it does not invent player-name completions.
  Permission/faction filtering applies to the merged snapshot, not just the channel list. Each open
  requests a refreshed snapshot (server cooldown); no engine command enumeration or authority in CEF.
  Each plugin's `Core.Commands` VM contributes a permission-filtered server snapshot and/or local
  client snapshot through internal `chatSuggestionsRequested` / `chatSuggestions` hooks. Client
  snapshots are Registry-owned (`chatSuggestions`), replaced on refresh and removed on owner stop.
  This includes plugin commands without relying on the stock chat's suggestion event listeners.
- One `uiReady` hook restores the actual chat typing state, never generic page focus. Opening is
  refused while hidden or another focus owner is active; closing is immediate in CEF. A page/modal
  taking focus cancels chat. Async focus replies cannot reopen chat after Escape/hide.
- Client startup and `uiReady` call `SetTextChatEnabled(false)` and `DisableMultiplayerChat(true)`;
  resource stop restores them. This suppresses GTA's native multiplayer chat without a frame loop.
  The separate stock FiveM `chat` resource must still be stopped/removed from startup; cancelling its
  server event cannot hide its independent NUI. Core does not silently stop other resources.
- Slash input is stripped of its leading `/` before **client** `ExecuteCommand`, never executed as
  server console. Offline coverage: Lua bridge/metadata/routing, pure JS caret/completion tests,
  shell keyboard/fade/focus/history regressions and interactive Chat stories.

### 30.4 Native invocation — the direct path (2026-09-18, under evaluation, PLAN.md N8)

Read from the Cfx source (`citizen-scripting-lua/src/LuaScriptNatives.cpp`, `citizen-scripting-core/src/
ScriptInvoker.cpp`, `ext/natives/codegen_out_lua.lua`, `codegen_out_native_lua.lua`) and the shipped
`natives_loader.lua`. A Lua native call has two routes, chosen per RESOURCE by the manifest:

- **default**: a generated Lua wrapper per native (`_ts()` + `tostring` for every string argument) into a
  C closure that builds a generic invoke context (per-argument type switch, the pointer-safety table walk
  whenever a string or pointer is passed, result coercion);
- **direct** — `use_experimental_fxv2_oal 'yes'` in `fxmanifest.lua`: `Citizen.LoadNative` hands the loader a
  generated C function that becomes the global itself (handler resolved once, typed argument parsing off the
  Lua stack, no wrapper, no context). Only natives with int/float/bool/string/Hash arguments get one (309 of
  the 323 natives core calls); the rest keep the default route.

The per-frame cost of a draw loop is its native CALL COUNT times the per-call invoke cost (§6.7 budget), so
core's manifest sets the key — **as an experiment until Liam's in-game resmon result is in**; removing the
line, `refresh`, `restart core` goes back. Core's Lua must behave identically on both routes, because `lib/`
also runs inside plugin VMs whose manifests choose for themselves. The differences, and the rule each one
makes:

- a **BOOL return** is `false` or the INTEGER `1` on the default route and a real boolean on the direct one:
  read it by truthiness, never `== true`, `== 1` or arithmetic (`lib/net` ACE fallback fixed: it could never
  grant);
- a **BOOL out-value** is the integer `0`/`1` on the default route — and `0` is truthy in Lua — and a boolean
  on the direct one: test `v == true or v == 1` / `not v or v == 0` (`Raycast.between` reported every miss
  as a hit, `Vehicles.getProps` never saved lights as on: both fixed);
- the direct route does **not unroll a vector** into x, y, z: pass scalars, always;
- the direct route reads exactly the **declared arguments**: never pass a meaningful value beyond them.

Audit (2026-09-18, scratch `oal_audit.py` over fxref's FiveM parameter lists): 841 call sites, 0 extra
non-zero arguments, 0 vector-for-scalar arguments, the three BOOL sites above. `tests/stubs.lua` models
the default route for `IsPlayerAceAllowed` (`1`/`false`), so a `== true` fails offline the way it does live.

## 31. UI visibility — auto-hide on game states, `Core.UI.hide/show` (2026-09-12, after Liam's report)

The NUI layer is composited above *everything* the game draws, including the pause menu, screen fades,
warning screens and the player-switch cinematic. Without this section the HUD, text UI and notifications
stayed visible over the ESC map. This section is binding for `client/ui.lua`, `server/ui.lua`,
`shared/config.lua`, `ui/src/store.js`, `ui/src/App.vue`, `types/core.lua` and the docs.

### 31.1 Model: a set of hide reasons

- The client keeps `hiddenReasons = { [reasonKey] = true }`. The shell is hidden while the set is not
  empty. Every reason is a string matching `^[%w_%-%.:]+$`, at most 48 characters after prefixing.
- Reason keys are namespaced by who owns them, so no caller can clear somebody else's reason:
  - core's own game-state watchers store `game:pause`, `game:fade`, `game:switch`, `game:warning`,
    `game:hud`, `game:cinematic` verbatim;
  - the server API stores `server:<reason>` verbatim (pushed through the existing `core:client:ui`
    op channel, §21);
  - a plugin calling `Core.UI.hide('cutscene')` gets `<resource>:cutscene` (owner from
    `Core.Registry.getCaller()`); core itself (caller `core`) uses reasons verbatim.
- Plugin reasons are tracked as registry kind `uihide` (client registry, §6.1) and dropped when the plugin
  stops, so a crashed cutscene script cannot leave the shell hidden.

### 31.2 Client API (`client/ui.lua`, reached through the proxy)

| function | behaviour |
|---|---|
| `Core.UI.hide(reason?)` | adds the caller-namespaced reason (default reason `default`); returns true. |
| `Core.UI.show(reason?)` | removes the caller's reason (default `default`); returns true when it removed one. A plugin can never remove `game:*`, `server:*` or another plugin's reason. |
| `Core.UI.isHidden()` | true while any reason is set. |
| `Core.UI.hiddenReasons()` | array copy of the reason keys (for admin/debug tooling). |
| `Core.UI.setAutoHide(name, enabled)` | runtime toggle for one watcher: `pause`, `fade`, `switch`, `warning`, `hud`, `cinematic`; false for an unknown name. Disabling a watcher also clears its `game:<name>` reason. |

Hook: `Core.on('uiVisibility', function(visible, reasons) end)` fires on every hidden⇄visible transition
(not on every reason change), client side, with a copy of the reason list.

### 31.3 Watchers (one thread, `Config.UI.AutoHide`)

`Config.UI.AutoHide = { IntervalMs = 200, PauseMenu = true, ScreenFade = true, PlayerSwitch = true,
Warning = true, HudHidden = false, Cinematic = true }`. One `CreateThread` loop, `Wait(IntervalMs)`
(never 0), reads only the enabled natives and maps each boolean to add/remove of its `game:*` reason:

| watcher | reason | native(s), client apiset, verified with fxref 2026-09-12 |
|---|---|---|
| PauseMenu | `game:pause` | `IsPauseMenuActive()` |
| ScreenFade | `game:fade` | `IsScreenFadedOut() or IsScreenFadingOut()` |
| PlayerSwitch | `game:switch` | `IsPlayerSwitchInProgress()` |
| Warning | `game:warning` | `IsWarningMessageActive()` |
| HudHidden | `game:hud` | `IsHudHidden()` — off by default: its exact semantics (DisplayHud(false) vs per-frame hides) are undocumented, a wrong reading would hide the shell for good |
| Cinematic | `game:cinematic` | `IsCinematicCamRendering()` |

The loop costs nothing visible in resmon (≤ 6 boolean natives every 200 ms) and sends a NUI message only
when the *visible* state flips. Nothing is polled per frame.

### 31.4 Behaviour on the hidden transition

- NUI message `{ action = 'shell:visible', visible = false|true, reasons = { ... } }`, sent on every flip
  and re-sent on `ui_ready` when the shell is (re)mounted while hidden, so a NUI reload lands in the right
  state.
- The shell root (`.core-root`) gets `is-hidden` → `visibility: hidden; pointer-events: none`. State keeps
  running while hidden: progress bars still complete, notifications still expire, HUD values still update.
- To make sure a player is never stuck behind an invisible focus-holding element, the hidden transition
  closes the open built-in modal (menu/input/alert: the awaiting Lua receives the same cancel value as on
  ESC) and the focused page (`page:close`, its `close` event fires as usual), then re-applies focus.
  Overlay pages (non-focus), text UI, key hints, spinner, shard and progress are left alone (merely
  hidden). This is documented behaviour: hiding with a modal open equals cancelling it.
- Showing again does nothing but flip the flag: whatever is still active reappears.

### 31.5 Server API (`server/ui.lua`)

`Core.UI.hide(src, reason?)` and `Core.UI.show(src, reason?)` validate `src` (§4) and the reason
(pattern above, ≤ 32 chars, default `default`), then push ops `hide` / `show` with the single argument
`'server:' .. reason` through `core:client:ui`. The client handler is the generic one from §21
(`Core.UI[op](table.unpack(args))`), which runs with caller `core`, so the prefixed key is stored
verbatim. Server reasons follow the player's session: they are cleared on the client when the NUI reloads
(the client re-sends nothing for them), and the server does not track them (fire-and-forget like every
§21 push).

### 31.6 Shell, tests, docs

- `ui/src/store.js`: `store.shell = { visible: true, reasons: [] }` and the `shell:visible` action.
- `ui/src/App.vue`: `:class="{ 'is-hidden': !store.shell.visible }"` + `aria-hidden` on `.core-root`;
  the rule lives in `ui/src/styles.css` `@layer components`.
- `ui/tests/shell-regression.js`: hide → computed `visibility` of `.core-root` is `hidden` and the text UI
  is not visible; show → visible again and the notifications posted before are still there (+3 checks).
- Storybook: a `Shell/Visibility` story with a control toggling `shell:visible` over the HUD + text UI,
  its Lua panel showing `Core.UI.hide('cutscene')` / `Core.UI.show('cutscene')` and the config block.
- `types/core.lua`: stubs for the five client functions, the two server functions and the hook name.
- `tests/server_tests.lua`: `Core.UI.hide/show` validation (bad src, bad reason, pushed op + argument).
- README: "Visibility (pause menu, fades, cutscenes)" under UI, cheat-sheet lines, config key in the
  table, two checklist steps (ESC hides the HUD and text UI; `/exmenu` open → ESC is swallowed by the NUI,
  so the menu closes first and the pause menu opens on the second press).

## 32. Game blur — glass panels through FiveM's NUI render hook (2026-09-12, Liam's pointer)

`backdrop-filter` cannot blur the game (the NUI page is transparent, there is nothing behind it inside the
CEF), but FiveM's NUI core exposes the game's back buffer to WebGL: `code/components/nui-core/src/NUIInitialize.cpp`
hooks `glTexParameterf`, and a `TEXTURE_2D` texture that receives on `TEXTURE_WRAP_T` the sequence
`CLAMP_TO_EDGE → MIRRORED_REPEAT → REPEAT` is bound to the game frame (shared D3D11 texture → EGL pbuffer).
The FiveM main menu (`ext/cfx-ui/src/app/app.component.ts`) draws that texture into a full-screen canvas at
30 fps and CSS-blurs the canvas; the hook is process-wide, so a resource NUI frame can do the same. This
section makes it a framework feature. The `backdrop-filter` ban (§7.1) stays: it renders a black box.

### 32.1 Consumers: `data-core-blur`

Any element inside `#app` carrying `data-core-blur` gets a live, blurred copy of the game behind it. The
optional value is the blur radius in CSS px (default `Config.UI.Blur.Strength`); `data-core-blur="0"`
switches it off for that element. Plugin pages need no JavaScript: the attribute is enough. Cost is one
small canvas copy per consumer per frame, so consumers are panels (a HUD box, a dialog, a page), never list
rows or per-item elements; the shell keeps its own count ≤ 12.

Built-ins that carry it: the three modal panels (`Menu`, `InputDialog`, `AlertDialog`), the HUD box, the stats
box, each notification card, the text UI pill, the progress box, the key-hint bar and the spinner pill; not
the shard band, not `PageHost` (pages decide for themselves). The example plugin page and the template page
carry it on their panel.

### 32.2 Module `ui/src/gameblur.js`

`installGameBlur(root, initial)` → controller `{ setConfig({ enabled, strength, fps, scale }), isAvailable(),
mode() }`, installed once from `main.js` after mount and from `.storybook/preview.js`; exposed as
`window.CoreUI.gameBlur` for advanced pages.

- **Source**: one hidden WebGL canvas (`alpha:false, antialias:false, depth:false, stencil:false,
  preserveDrawingBuffer:true, failIfMajorPerformanceCaveat:false`) of viewport × `scale` (default 0.5,
  clamped 0.1–1) with the hook sequence exactly as the main menu (CLAMP_TO_EDGE, MIRRORED_REPEAT, REPEAT,
  then CLAMP_TO_EDGE again) and a pass-through shader drawing one full quad.
- **Availability probe**: after the first draw `readPixels` at four points; if every sample is the 1×1
  placeholder colour (0,0,255) the hook is not active (browser, Storybook, a build that dropped it) →
  mode `fallback`: the source is a 2D canvas painted with a procedural dusk gradient (the Storybook preview's
  colours) so the effect stays visible during development. No WebGL at all → mode `off`. The root element
  gets `data-game-blur="live" | "fallback" | "off"`.
- **Discovery**: one `MutationObserver` on `#app` (childList, subtree, attributeFilter `data-core-blur`).
  A consumer element gets `position: relative` when static and `isolation: isolate`; a wrapper
  `<div class="core-glass" aria-hidden="true">` (absolute, inset 0, overflow hidden, border-radius inherit,
  z-index -1, pointer-events none) is inserted as its first child, holding a `<canvas>` that is inset by
  −2×strength on every side (so the blur has no transparent edge bleed) with `filter: blur(<strength>px)`.
  Removing the attribute or the element removes the wrapper.
- **Frame loop**: `setTimeout` at `fps` (default 30, clamped 5–60), like the main menu — never
  `requestAnimationFrame` at full rate. It runs only while: enabled, at least one consumer is connected and
  visible (non-zero rect), the shell is visible (§31), and `document.hidden` is false. Otherwise the loop
  stops completely (zero cost). Each frame: one WebGL draw of the game quad, then per consumer
  `getBoundingClientRect()` of the wrapper (expanded by the margin), the canvas backing size = rect × scale
  (only reassigned when it changes), and `drawImage(source, sx, sy, sw, sh, 0, 0, w, h)` from the matching
  region of the source (clamped to its bounds).
- **Tint, not alpha override**: inside an isolated element a negative-z child paints *above* the element's own
  background, so the blurred copy would hide `bg-panel`. The wrapper therefore carries the panel colour itself:
  `.core-glass::after { inset: 0; background: var(--core-glass-tint, var(--color-panel-glass)) }` above the
  canvas (`--color-panel-glass: rgba(14, 16, 20, 0.62)` in `@theme`); a plugin panel that wants another tint sets
  `--core-glass-tint` on the element. The element's own background is simply covered; its border (outside the
  padding box the wrapper covers) stays visible. Non-glass panels keep the 0.86 `--color-panel` unchanged.
- **Install**: `main.js` calls `installGameBlur(document.getElementById('app'))` after mount; the module imports
  `store.js` itself and reads `store.blur` and `store.shell.visible` every tick (no config plumbing through
  `App.vue`). `.storybook/preview.js` installs it on `document.body`. Controller: `{ mode(), isAvailable(),
  refresh(), destroy() }`, exposed as `window.CoreUI.gameBlur`.
- **Binding reliability** (in-game finding, 2026-09-12): the same recipe bound on one restart and not the
  next — the game recreates its shared texture whenever its back buffer changes and a NUI that issues the
  sequence inside that window sees a stale handle. Every probe retry therefore re-issues the whole hook
  sequence (bind + the seven `texParameterf` calls, `issueHookSequence`) before drawing, on the schedule
  250 ms … 60 s, then every 30 s while the source is still the placeholder, plus once on `resize`. The
  source canvas is in the page (2×2 px, opacity 0.01) like every known-working user of the hook.
  Orientation: the plain 0..1 mapping is upright in the client (`RenderHooks.cpp` flips the shared texture);
  FxDK's viewer flips because its producer does not — never copy that mirror into a resource NUI.
- **Diagnostics**: the shell posts `blur_diag` to Lua after every probe and on `/uiblur diag` (mode, probe
  pixels, source size, the centre pixel of the first consumer's copy); `client/ui.lua` prints it to the
  client console (CitizenFX.log). `/uiblur test` (or 9 s of persistent fallback inside a real NUI) runs
  `ui/src/gameblur.probe.js`: ten throw-away contexts with different recipes, each reporting what it read
  back — the tool that showed the flakiness was timing, not the recipe.
- **Config messages**: `{ action = 'blur:set', enabled, strength, fps, scale }` from Lua on `ui_ready` and
  on change; the store keeps `store.blur = { enabled: true, strength: 10, fps: 30, scale: 0.5 }` (partial
  merge, clamps: strength 0–40, fps 5–60, scale 0.1–1) and `resetExtras()` restores the defaults. The dev shim
  can send it too (Storybook control).

### 32.3 Lua side

`Config.UI.Blur = { Enabled = true, Strength = 4, Fps = 30, Scale = 0.5 }` (Strength 10 was far too heavy on
real game footage — Liam, 2026-09-12). `client/ui.lua` sends `blur:set` right after the HUD snapshot in
`ui_ready` and offers `Core.UI.setBlur(enabled, opts?)` (client, proxy; session-scoped override of `Enabled`
and, through numeric `opts.strength/fps/scale`, of the tunables; re-sent on `ui_ready`; returns true). The
client command `/uiblur` (`/uiblur` prints, `/uiblur off|on`, `/uiblur <strength> [scale] [fps]`) drives the
same override so a value can be tuned in-game without a restart. `types/core.lua` gets the stub,
README the config keys, and the checklist a step ("open /exmenu: the game behind the panel is blurred;
`Config.UI.Blur.Enabled = false` + restart removes it").

### 32.4 Tests and docs

- `ui/tests/shell-regression.js` (+3): in the browser the root reports `data-game-blur="fallback"`; a
  `<div data-core-blur>` with a size appended inside `.core-root` gets a `.core-glass > canvas` child within
  a few frames; after `blur:set { enabled: false }` no `.core-glass` element exists and the root reports `off`
  (the test re-enables and removes its element afterwards). The built-in panels are asserted by the story.
- Storybook: a "Shell/Game blur" story (controls: enabled, strength, scale) over the HUD + a menu, its Lua
  panel showing the config block and `Core.UI.setBlur(false)`; one paragraph in Introduction.mdx. The
  Storybook backdrop gradient and the fallback gradient use the same colours so the glass looks coherent.
- Wording fix everywhere the ban is documented (§7.1, README, template and example READMEs, Introduction.mdx,
  `styles.css` header): "`backdrop-filter` is banned — put `data-core-blur` on the panel instead (§32)".

## 33. Postgres document store (`Config.DB.Adapter = 'postgres'`) — 2026-09-12, Liam's choice

`Core.DB` keeps its document model (§4.1, §22): collections of JSON documents, cached in memory, written
through to an adapter `{ loadAll, put, remove, flush }` (§27, `DB.setAdapter`). This section adds a Postgres
adapter that is the recommended production backend; KVP stays the zero-setup default and the untested
oxmysql adapter stays as it is.

### 33.1 Pieces

| file | runtime | role |
|---|---|---|
| `server/db_pg.js` | Node 22 (FXServer's) | one `pg.Pool` (max 4, idle 30 s, `statement_timeout` 10 s, `application_name` core) from the convar `core_pg_url`; exports `pgQuery(sql, params, cb)` and `pgStatus(cb)`; both refuse any invoking resource other than core itself (`GetInvokingResource() !== GetCurrentResourceName()` → `cb('forbidden')`) so no plugin can run SQL through it |
| `server/db_pg.lua` | Lua | the `Core.DB` adapter, loaded right after `db_mysql.lua`; activates only when `Config.DB.Adapter == 'postgres'` |
| `server/pg/index.js` + `server/db_pg.js` | esbuild | `index.js` is the source; `npm run build:server` (in `core/ui`, esbuild, target node22, `pg-native` external) bundles it WITH the `pg` driver into `server/db_pg.js`, the committed file the manifest loads (first line `// fxlint-disable-file`, which fxlint honours). No install step on the server: FXServer's Node sandbox refuses to read a `node_modules` folder behind the symlinked resource path ("Filesystem permission check … no device found"), and a `package.json` at the resource root would wake the server's yarn builder — exactly why screenshot-basic ships a webpack bundle |

The URL (`postgres://user:password@host:5432/db`) lives in `server.cfg` as `set core_pg_url "…"` — a
secret like every other convar of the framework: never in a file of the resource, never logged. The dev
server runs Postgres 16 in Docker (`core-postgres`, volume `core-pgdata`, bound to 127.0.0.1).

### 33.2 Schema and statements

```sql
CREATE TABLE IF NOT EXISTS core_documents (
    collection text   NOT NULL,
    id         text   NOT NULL,
    data       jsonb  NOT NULL,
    updated_at bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (collection, id)
);
```

- `loadAll`: `SELECT id, data::text AS data FROM core_documents WHERE collection = $1` → `{ [id] = json }`.
- `put`: `INSERT … VALUES ($1, $2, $3::jsonb, $4) ON CONFLICT (collection, id) DO UPDATE SET data = EXCLUDED.data,
  updated_at = EXCLUDED.updated_at` (the document is the JSON string `Core.DB` already encoded).
- `remove`: `DELETE FROM core_documents WHERE collection = $1 AND id = $2`.
- `flush`: no-op (every write already went out).

`jsonb` is deliberate: ad-hoc queries (`WHERE data @> '{"license":"…"}'`) and a GIN index later, without
`Core.DB` knowing.

### 33.3 Behaviour (same guarantees as §29/§30 gave the MySQL adapter)

- The adapter is installed synchronously at load (`DB.setAdapter`), before any collection can be read, so a
  player joining early never reads KVP by accident.
- `ensureSchema` runs once, awaited by the first `loadAll` (a parked promise shared by concurrent callers), and
  again by a start-up thread so a broken connection shows in the console at start, not on the first join.
- `loadAll` awaits the query through a Lua promise (`promise.new()` + `Citizen.Await`, 10 s deadline). It
  returns `nil, reason` on any failure — never `{}` — so `Core.DB` marks the collection degraded (reads empty,
  writes refused, load retried on next access) instead of overwriting rows with an empty cache.
- `put`/`remove` are fire-and-forget: the callback only reports errors, which mark the collection degraded.
- The Lua ↔ Node bridge is the export-with-callback shape oxmysql uses: Lua passes a function, Node calls
  `cb(err, rows)` exactly once. A refused or missing export (Node runtime not up yet) is treated like a
  failed query, logged once.
- Console: `DB: postgres adapter active (core_documents)` on success; `DB: Config.DB.Adapter is "postgres" but
  core_pg_url is empty — staying on KVP` when the convar is missing (the only case where KVP is used).

### 33.4 Migration from KVP, tests, docs

- Procedure (done on the dev server 2026-09-12): on the running KVP server `/dbexport` (writes
  `data/export-<ts>.json`; the `data/` folder must exist — `data/.gitkeep` is tracked for that), load it with
  `scripts/pg-import.js` (plain Node + `pg`, `--replace`, one transaction, no FXServer involved), then set
  `Config.DB.Adapter = 'postgres'`, `refresh`, `restart core`. Sessions of connected players reload from Postgres
  and find their documents. `/dbimport … replace` from the console is only safe with no player connected: a
  session that loaded from the empty database before the import is autosaved over the imported rows.
- `fxmanifest.lua` declares `node_version '22'` (FXServer ships 16 by default and 22 on request; this server
  build ships only 22).
- `tests/server_tests.lua`: a `db_pg` suite that stubs `exports.core.pgQuery` (`stubs.exports`) and checks:
  activation refuses without the convar; `loadAll` returns the id→json map; a query error yields `nil, reason`
  and never `{}`; `put` on error degrades the collection; the schema is created once.
- `tests/pg_smoke.js`: plain Node, shims the FiveM globals (`GetConvar`, `exports`, `GetInvokingResource`,
  `GetCurrentResourceName`, `on`), requires `server/db_pg.js`, and round-trips a document through a real
  server given by `CORE_PG_URL` (skips with a clear message when unset).
- README: a "Postgres" subsection under "Where data lives" (Docker one-liner, convar, the bundle, the
  migration) and the config table row; `templates/plugin` unchanged (plugins never touch adapters).

---

## 34. Full freemode appearance (2026-09-12, for the `charcreator` plugin)

§6.1's `appearance` carried only `components`, `props` and `headBlend`. A character creator also needs
face features, head overlays (with their colours), hair colour and eye colour — and they must be
re-applied by **core** on every path that dresses the ped (`core:client:loaded`, `core:client:spawn`,
`core:client:setModel`, `Spawn.spawnPlayer`, `Spawn.setModel`), so no plugin has to hook respawns to keep
a face. This section is binding for `client/spawn.lua`, `types/core.lua` (`CoreAppearance`) and the
README; the creator itself stays a plugin (§13).

### 34.1 Shape

Every key is optional; a table with only some keys applies only those (that is how the creator previews
a slider: `Spawn.applyAppearance(ped, { faceFeatures = { [3] = 0.4 } })`). Integer keys may arrive as
**strings** after a JSON round trip (§34.3) — every reader goes through the existing `toInt`.

```lua
appearance = {
  components   = { [0..11] = { drawable = int, texture = int, palette = int?, collection = string?, localDrawable = int? } },  -- pair: §34.5
  props        = { [0..7]  = { drawable = int, texture = int, collection = string?, localDrawable = int? } | false },
  headBlend    = { shapeFirst, shapeSecond, shapeThird = 0, skinFirst, skinSecond, skinThird = 0,
                   shapeMix = 0..1, skinMix = 0..1, thirdMix = 0, isParent = false },      -- as before
  faceFeatures = { [0..19] = -1.0..1.0 },                                                 -- SetPedFaceFeature
  headOverlays = { [0..12] = { index = 0..N | 255, opacity = 0..1,                         -- SetPedHeadOverlay
                               colorType = 0|1|2, color = int, color2 = int } },          -- + SetPedHeadOverlayColor when colorType > 0
  hairColor    = { color = int, highlight = int },                                        -- SetPedHairTint
  eyeColor     = 0..31,                                                                   -- SetPedEyeColor
}
```

Overlay ids: 0 blemishes, 1 facial hair, 2 eyebrows, 3 ageing, 4 makeup, 5 blush, 6 complexion, 7 sun
damage, 8 lipstick, 9 moles/freckles, 10 chest hair, 11 body blemishes, 12 add body blemishes. `index 255`
means "none". `colorType` 1 = hair colours (facial hair, eyebrows, chest hair), 2 = makeup colours
(makeup, blush, lipstick), 0 = no colour call. Face features 0..19 in GTA's order (nose width … neck
width).

### 34.2 Apply order and tolerance (`Spawn.applyAppearance`)

`headBlend` → `components` → `props` → `faceFeatures` → `headOverlays` (`SetPedHeadOverlay`, then
`SetPedHeadOverlayColor` when `colorType > 0`) → `hairColor` → `eyeColor`. Head blend first, because
freemode overlays and features only render once blend data exists. Values are clamped, never rejected:
feature scale to `[-1, 1]`, opacity to `[0, 1]`, head blend parent ids to `[0, 45]` and mixes to `[0, 1]`,
every other id to `>= 0` (`math.tointeger` on `n // 1`); a wrong type skips that entry with no error. Core validates *shape* here only; **semantic** validation
(ranges that depend on the model, name rules, who may change what) is the calling plugin's job before
`Player.setModel(src, model, appearance)` stores the table.

Native names: the FiveM Lua runtime generates these as `SetPedFaceFeature`, `SetPedHeadOverlayColor`,
`SetPedEyeColor` and `SetPedHairTint` (`natives.json` names `_SET_PED_FACE_FEATURE`,
`_SET_PED_HEAD_OVERLAY_COLOR`, `_SET_PED_EYE_COLOR`, `SET_PED_HAIR_TINT`). The newer nativedb names
(`SetPedMicroMorph`, `SetPedHeadOverlayTint`, `SetHeadBlendEyeColor`) are **not** emitted by the runtime
and must not be used.

### 34.3 JSON round trip

The runtime `json.encode` (dkjson) treats a table as an array only when every key is an integer `>= 1`,
so every group above — keyed from `0` — is stored as a JSON **object** with string keys and comes back
that way from KVP and Postgres alike. A plugin that stores a group without key `0` (say `components =
{ [11] = … }`) gets an array with `null` holes instead; it still decodes, but plugins should always
write complete groups or string keys. `Utils.jsonSafe` is unchanged.

### 34.4 Docs and tests

`types/core.lua`: the four new `CoreAppearance` fields. README: the "Appearance" block in the client cheat
sheet and the plugin note under "Writing a plugin". No server logic changed, so `tests/server_tests.lua`
stays as is; `scripts/check.sh` must stay green. The in-game check is the `charcreator` plugin's
checklist (its README).

### 34.5 Collections (2026-09-12, second charcreator round)

Global drawable and prop indexes are positions in one long list of collections (base game `""`, then every
official DLC pack in release order, then custom packs). FiveM's collection natives address an item as
`(collection name, local index)` instead, and that pair survives title updates while the global index of every
custom pack shifts (docs: *Work with Drawable Components and Props Using Collections*). Core therefore accepts
the pair on every component and prop entry and prefers it when it is there:

```lua
components[id] = { drawable = int, texture = int, palette = int?, collection = string?, localDrawable = int? }
props[id]      = { drawable = int, texture = int, collection = string?, localDrawable = int? } | false
```

- `applyComponents`: when `collection` is a string and `localDrawable` an integer `>= 0` and
  `IsPedCollectionComponentVariationValid(ped, id, collection, localDrawable, texture)` holds →
  `SetPedCollectionComponentVariation(ped, id, collection, localDrawable, texture, palette)`; otherwise the
  global `SetPedComponentVariation(ped, id, drawable, texture, palette)` as before (a pack that is no longer
  streamed falls back to whatever the global index points at instead of leaving the slot unset).
- `applyProps`: the same with `GetPedPropGlobalIndexFromCollection(ped, id, collection, localDrawable) ~= -1`
  as the validity test and `SetPedCollectionPropIndex(ped, id, collection, localDrawable, texture, true)`.
- The empty string is a real collection (the base game); `nil` means "not known, use the global index".
  `drawable` stays mandatory: it is what UIs show and what older documents carry.
- When the pair is present it is the authority: `drawable` is what UIs show and what older documents carry,
  and a plugin that persists a look re-derives the global index from the pair on load (the creator's
  `refreshGlobals`). Prop textures are bounded with `GetNumberOfPedCollectionPropTextureVariations` because
  no `IsPedCollectionPropValid` exists.
- Nothing else in core reads the pair. Who fills it in (the creator, from `GetPedCollectionNameFromDrawable`
  / `GetPedCollectionLocalIndexFromDrawable` and the prop analogues) and how a stale global index is refreshed
  from the pair (`GetPedDrawableGlobalIndexFromCollection`) is the plugin's business.

---

## 35. Idle cameras off (2026-09-13, Liam: "UIs close when the idle cam starts")

GTA starts a cinematic pan after 30 s without input (on foot, as a passenger, and the cinematic vehicle idle
mode). §31's `Cinematic` watcher sees `IsCinematicCamRendering()`, hides the shell and closes the focused
page — correct for a real cutscene, wrong for an AFK pan. `client/main.lua` therefore switches the idle cameras
off while `Config.Camera.DisableIdleCam` (default `true`) holds: `DisableIdleCamera(true)` and
`DisableVehiclePassengerIdleCamera(true)` once at start (CFX one-shot switches, client apiset), plus one
thread every 5000 ms calling `InvalidateIdleCam()` and `InvalidateVehicleIdleCam()` (the cinematic vehicle
idle mode only listens to its timer being reset; the timers are 30 s, so 5 s keeps them dead — no per-frame
work, §9). `onClientResourceStop` switches the two CFX toggles back on. The `Cinematic` watcher stays enabled
for scripted cutscenes. Config: `Camera = { DisableIdleCam = true }` (§28). Perf table (§9): `idle cam reset ·
client · 5000 ms · two natives`. README: config row + checklist step ("stand still 45 s → no camera pan, an
open page stays").

## 36. Interiors and IPLs (`Core.Interiors`) — 2026-09-15, Liam: "core is missing lots of IPLs"

Without requested IPLs the map has holes (missing collision, sand/water gaps, absent exteriors) and whole
DLC locations never stream (carrier, yacht, bunkers, casino shell, tuner shops, ...). The researched,
up-to-date IPL set is Bob74's `bob74_ipl` (MIT licensed, © 2024 Bob74 — attribution in
`client/interiors_data.lua`; IPL name strings themselves are Rockstar map data, cross-checked against
DurtyFree's `gta-v-data-dumps/ipls.json`). Core ports its IPL layer (the "map exists" part) in core's own
shape; per-interior styling (office decor, clubhouse walls, bunker tiers, casino themes — entity sets chosen
per faction) stays plugin territory and goes through the API below. Never copy `bob74_ipl`'s code: the data
table and loader here are written for core's conventions (AGENTS §6 "Rebar" rule applies to any foreign code).

Files: `client/interiors_data.lua` (pure data, no natives — offline-testable), `client/interiors.lua`
(loader + API). Client only: IPLs are per-client streaming state, there is no server truth to own.

```lua
-- data: one row per group (bob74's client.lua sections, same defaults)
{ id = 'base', label = '...', default = true, minBuild = 2060?, dlc = 'mp2025_01'?,
  remove = { 'dt1_05_hc_end', ... }, ipls = { 'FINBANK', ... } }
-- config: Config.Interiors = { Enabled = true, base = true, ..., north_yankton = false, ufo = false, red_carpet = false }
-- API (client, through the proxy):
Interiors.request(ipl) -> bool                  -- RequestIpl; tracked under the caller for cleanup
Interiors.remove(ipl) -> bool                   -- RemoveIpl; untracks the caller's entry
Interiors.isActive(ipl) -> bool                 -- IsIplActive
Interiors.activateSet(coords, set) -> bool      -- resolve interior at coords, ActivateInteriorEntitySet + RefreshInterior; yields (≤ 5 s)
Interiors.deactivateSet(coords, set) -> bool    -- DeactivateInteriorEntitySet + RefreshInterior; yields
Interiors.isSetActive(coords, set) -> bool|nil  -- IsInteriorEntitySetActive; nil when no interior at coords
Interiors.refreshAt(coords) -> bool             -- RefreshInterior at coords; false when no interior there
Interiors.listGroups() -> array                 -- { { id, label, enabled, gated } } (a copy)
```

Boot: one thread at client start (after `ready`, before the load request — interiors must stream before the
player spawns). For each group with `Config.Interiors[id]` not `false` (missing key = the row's `default`),
master switch `Config.Interiors.Enabled` on, and the gate satisfied (`minBuild` vs `GetGameBuildNumber()`,
`dlc` vs `IsDlcPresent`), it runs that group's `remove` list through `RemoveIpl` then the `ipls` list through
`RequestIpl`, and logs one debug line per group (`loaded <id>: <n> ipls`). No thread or loop survives boot
(§9): after the requests the module is idle until a plugin calls it.

Validation: IPL/set names must match `^[%w_]+$` and be ≤ 96 chars (the longest researched IPL is 65;
anything else returns `false`/`nil`, never errors); `coords` must be `vector3`. Interior resolution polls `GetInteriorAtCoords` + `IsValidInterior` /
`IsInteriorReady` every 100 ms up to 5000 ms, then gives up with `false` — the only yields in the module, and
only inside explicit API calls (proxy-safe, never per frame).

Ownership (§2.3): `request()` tracks kind `'ipl'` (`ipl name → owner`); `activateSet()` tracks kind
`'iplset'` (`coords .. ':' .. set → owner`). The sweep remover drops what the stopping resource added: IPLs
back through `RemoveIpl` (except names the base set owns — core's own boot entries are never removed
underneath a running client), entity sets through `DeactivateInteriorEntitySet` + `RefreshInterior`. A plugin
that styles a faction interior therefore needs no `onResourceStop` cleanup (K005).

Perf table (§9): `interiors boot · client · once · ~370 RequestIpl + 2 RemoveIpl` and nothing afterwards.
Natives (client, fxref 2026-09-15): RequestIpl, RemoveIpl, IsIplActive (STREAMING), GetInteriorAtCoords,
IsValidInterior, IsInteriorReady, ActivateInteriorEntitySet, DeactivateInteriorEntitySet,
IsInteriorEntitySetActive, RefreshInterior (INTERIOR), GetGameBuildNumber (CFX shared), IsDlcPresent (DLC).
README: cheat-sheet row + config rows + checklist step ("carrier off the coast, casino doors closed,
tuner shop exteriors present; `/interiors` prints counts"). Diagnostics: client command `/interiors`
lists groups with loaded counts (console + chat).

## 37. Design system — the UI kit (`ui/src/kit`) — 2026-09-18, Liam: "our UIs all look kind of different"

Every plugin page used to build its own buttons, sliders and panels, so no two UIs looked alike. §37 gives the
shell and every plugin **one visual language and one component library**. The look comes from Liam's four
mockups (`FiveM/DesignMockups/`: main menu, HUD, inventory, map) and **replaces** the §7.2 "visual direction"
(blue accent, system font, 8 px radius) — nothing in the kit is derived from the old look. Three layers, each
usable on its own:

1. **tokens** — the `@theme` block of `ui/src/styles.css` (§37.2): every colour, font, radius, shadow.
2. **classes** — `ui/src/kit/css/*.css`, the `.core-*` vocabulary (§37.5 names them per component); plain HTML
   in a page may wear them directly.
3. **components** — `ui/src/kit/components/Core*.vue`, registered globally (§37.3): `<CoreButton>` works in every
   plugin page without an import.

Rule for pages (AGENTS §3 UI): compose kit components; write custom CSS only for what the kit lacks, and then
with tokens only — never a literal colour, font family or radius.

### 37.1 Visual language (what makes a screen look like the mockups)

- **Surfaces**: blue-black slate. Translucent panels (`--color-panel`, 90 %) over the game, 1 px hairline
  border (white 12 %, 22 % for the strong one), 6 px panel radius, 4 px control radius, 3 px for key caps /
  checkboxes / badges / tags. A faint
  top sheen on panels, a deep soft shadow under them. Wells (inputs, tracks) are darker than the panel
  (`--color-panel-sunken`), raised cells (slots, chips) a touch lighter (`--color-panel-raise`).
- **Accent**: one coral red (`#f6503f`). Two gradient recipes carry the brand: the **solid** accent gradient
  (primary buttons, active chips, checked boxes, progress fills) and the **fading** accent gradient — full
  coral on the left dissolving into the panel on the right (active menu rows, the fading primary button).
  Selection is a 1–2 px `accent-hi` border plus a soft coral glow, never a filled block.
- **Type**: `Barlow Condensed` (display: headings, buttons, tabs, menu rows, labels, numbers — uppercase,
  tracked) and `Barlow` (body copy, descriptions, form text). Both are bundled (`kit/fonts/`, OFL 1.1) because
  the CEF cannot fetch the web. Three label voices: *display* (700, tight tracking), *label* (600, 12 px,
  0.14 em), *eyebrow* (500, 13 px, 0.32 em — the widely spaced subtitle under a heading).
- **Keys**: a key cap is a solid near-white tile with dark condensed text; mouse buttons are line glyphs.
- **Motifs**: the short accent dash, the `//` double-slash heading marker with an italic title, stacked
  wide-tracked taglines next to a vertical hairline, hairline-framed stat rows.
- **Motion**: 120 ms hovers, 160–220 ms enters and 120 ms leaves (`--ease-ui`), fades, a 0.97 pop and 12–18 px
  slides; nothing bounces. `prefers-reduced-motion` cuts every `core-*` transition to nothing, but leaves the
  functional animations running — a frozen spinner reads as a hang, not as calm.
- **Icons**: filled glyphs on a 24 × 24 grid (`kit/icons.js`, path data from Material Design Icons, Apache-2.0),
  drawn with `currentColor`.

### 37.2 Tokens (`ui/src/styles.css`, exact values)

The token *names* of §7.1 stay (every page already uses `bg-panel`, `text-fg-dim`, `rounded-ui`, …); their
values change and new ones join. `@theme` (→ Tailwind utilities) :

```css
--font-sans: 'Barlow', 'Segoe UI', system-ui, -apple-system, Roboto, 'Helvetica Neue', Arial, sans-serif;
--font-display: 'Barlow Condensed', 'Barlow', 'Arial Narrow', 'Segoe UI', sans-serif;
--font-mono: 'Cascadia Mono', Consolas, 'Courier New', monospace;

--color-ink: #060b0f;                          /* page floor, scrims, ring gaps */
--color-panel: rgba(11, 17, 22, 0.90);
--color-panel-glass: rgba(11, 17, 22, 0.64);   /* tint over a data-core-blur copy (§32) */
--color-panel-solid: #0d1419;
--color-panel-raise: rgba(255, 255, 255, 0.035);
--color-panel-sunken: rgba(0, 0, 0, 0.30);
--color-panel-popup: rgba(11, 17, 22, 0.98);  /* select list, context menu, tooltip, popover */
--color-hud: rgba(8, 12, 16, 0.68);          /* HUD plates over the live game: chip, tracker, clock, stat plate */
--color-border: rgba(255, 255, 255, 0.12);
--color-border-strong: rgba(255, 255, 255, 0.22);
--color-backdrop: rgba(4, 8, 11, 0.62);

--color-accent: #f6503f;   --color-accent-hi: #ff6351;   --color-accent-lo: #d53e2f;
--color-accent-soft: rgba(246, 80, 63, 0.16);  --color-on-accent: #ffffff;

--color-success: #3fd67f;  --color-warning: #f5a623;  --color-error: #ff4560;  --color-info: #55b6f7;
--color-health: #fa5246;   --color-armour: #5dbbf7;   --color-stamina: #5de395;
--color-hunger: #f5a623;   --color-thirst: #4fd1e8;   --color-oxygen: #9fd8ff;  --color-stress: #b68cff;
--color-rarity-common: #aeb6bf;  --color-rarity-uncommon: #5de395;  --color-rarity-rare: #5dbbf7;
--color-rarity-epic: #b68cff;    --color-rarity-legendary: #f5a623;

--color-fg: #f3f5f7;  --color-fg-dim: rgba(231, 237, 243, 0.66);  --color-fg-faint: rgba(231, 237, 243, 0.40);
--color-key: #fbfbfb; --color-key-fg: #11161b;

/* §39 — the vitals HUD: white plates over the game, their ink, the drained track, glyphs ON the plate, the mic tile */
--color-plate: #f2f3f6;  --color-plate-lo: #eaedf1;  --color-plate-fg: #11171f;
--color-plate-track: rgba(62, 66, 74, 0.92);
--color-plate-health: #c6022a;  --color-plate-armour: #0152b0;
--color-plate-loss: #f00645;  --color-plate-gain: #0bfd69;   /* §39.3.1: the chunk a vital just lost / gained */
--color-hud-tile: rgba(32, 36, 39, 0.85);

--radius-ui: 6px;  --radius-ui-sm: 4px;  --radius-ui-xs: 3px;
--shadow-ui: 0 14px 40px rgba(0, 0, 0, 0.50);  --shadow-ui-sm: 0 4px 14px rgba(0, 0, 0, 0.40);
--shadow-ui-lg: 0 30px 80px rgba(0, 0, 0, 0.60);
--shadow-glow: 0 0 0 1px #ff6351, 0 0 22px rgba(246, 80, 63, 0.42), inset 0 0 26px rgba(246, 80, 63, 0.12);
--shadow-glow-sm: 0 0 0 1px #ff6351, 0 0 16px rgba(246, 80, 63, 0.32);
--ease-ui: cubic-bezier(0.22, 0.61, 0.36, 1);

--text-ui-xs: 11px;  --text-ui-sm: 13px;  --text-ui: 15px;  --text-ui-lg: 17px;
--text-display-sm: 18px;  --text-display: 24px;  --text-display-lg: 34px;  --text-display-xl: 48px;
--tracking-display: 0.04em;  --tracking-label: 0.14em;  --tracking-eyebrow: 0.32em;
```

plus the `--animate-core-*` entries (§7.1's three and `core-slide-up`, `core-spin`, `core-shimmer`,
`core-pulse`). Plain custom properties in `:root` (not theme keys — recipes, not utilities):

```css
--core-accent-rgb: 246 80 63;     /* kit CSS writes alpha as rgb(var(--core-accent-rgb) / 0.16) — Chrome 65+ */
--core-ink-rgb: 6 11 15;  --core-panel-rgb: 11 17 22;
--core-error-rgb: 255 69 96;  --core-success-rgb: 63 214 127;  --core-warning-rgb: 245 166 35;  --core-info-rgb: 85 182 247;
--core-grad-accent: linear-gradient(90deg, #ff5a49 0%, #f6503f 45%, #ee4339 100%);
--core-grad-accent-fade: linear-gradient(90deg, #fd5443 0%, #f6503f 18%, rgb(246 80 63 / 0.18) 100%);
--core-grad-accent-fade-out: linear-gradient(90deg, #fd5443 0%, #f6503f 16%, rgb(246 80 63 / 0.04) 100%);
--core-grad-sheen: linear-gradient(180deg, rgba(255, 255, 255, 0.035) 0, rgba(255, 255, 255, 0) 120px);
--core-h-sm: 30px;  --core-h-md: 40px;  --core-h-lg: 52px;      /* control heights */
--core-focus: 0 0 0 3px rgb(var(--core-accent-rgb) / 0.18);     /* focus halo for boxes */
```

A server re-themes by overriding `--color-accent*`, `--core-accent-rgb` and the three gradients. The legacy
`--core-*` aliases of §7.1 stay (they point at the theme tokens). Body text is `--text-ui` (15 px Barlow reads
like 14 px Segoe); the root stays 16 px (§7.1). Alpha modifiers (`bg-accent/10`) are only safe on **hex**
tokens — Tailwind's static fallback cannot resolve an `rgba()`/`var()` token and Chromium 103 has no
`color-mix()`.

### 37.3 Files, registration, use from a plugin page

```
ui/src/kit/index.js          components map (import.meta.glob of ./components/Core*.vue), installKit(app), re-exports
ui/src/kit/icons.js          ICONS name → 24×24 path (185 glyphs vendored from @mdi/js 7.4, Apache-2.0 — no
                             dependency), registerIcons(map), iconPath(nameOrPath)
ui/src/kit/use.js            SIZES/TONES/METER_TONES/RARITIES, oneOf, toneClass/rarityClass, useId, normalizeItems,
                             clamp, toPercent, nextEnabledIndex, blurAttr, escape layers, onClickOutside,
                             overlayTarget, placeFloating/useFloating, focusables, useFocusTrap
ui/src/kit/fonts.css         @font-face for the vendored woff2 files in ui/src/kit/fonts/ (+ OFL.txt)
ui/src/kit/css/base.css      type voices, scroll, focus ring, transitions, keyframes        (foundation)
ui/src/kit/css/{actions,surfaces,navigation,forms-text,forms-choice,data-meters,data-display,game,feedback}.css
ui/src/kit/components/Core*.vue
ui/src/stories/kit/*.stories.js, ui/src/stories/kit/scenes/*.vue, ui/src/stories/kit/assets/*
```

`styles.css` imports every partial **into the components layer** (`@import "./kit/css/actions.css"
layer(components);`), so utilities still win over kit classes (`<CoreButton class="w-full">`). `main.js`
imports `kit/fonts.css`, calls `installKit(app)` before mount and publishes `CoreUI.kit = { components,
registerIcons, icons }`; `App.vue` ends with `<div id="core-overlays" class="core-overlays">` (fixed, inset 0,
z 60, click-through) — the Teleport target of every kit popup, inside `.core-root` so §31 hides it with the
shell. `.storybook/preview.js` does the same through `setup(app)`.

A plugin page simply writes the tags — they resolve at runtime against the one Vue app (§7.4):

```vue
<CoreScreen background="scrim" blur>
  <template #nav><CoreTabs v-model="tab" :items="tabs" /></template>
  <CorePanel title="Inventory" subtitle="Gear up for what's next." blur>
    <CoreSlotGrid v-model:selected="sel" :items="items" :columns="4" />
  </CorePanel>
  <template #footer-end><CoreKeyHints :items="[{ key: 'ESC', label: 'Back' }]" bare /></template>
</CoreScreen>
```

A plugin adds icons with `window.CoreUI.kit.registerIcons({ 'my-icon': 'M…' })` (24 × 24 path data) or passes a
raw path wherever an `icon` prop is accepted.

### 37.4 Conventions (every component)

- **Names**: component `Core<Name>`, file `kit/components/Core<Name>.vue`, root class `core-<name>`, parts
  `core-<name>__<part>`, variants `core-<name>--<variant>`, states `is-active | is-selected | is-open |
  is-disabled | is-invalid | is-loading | is-focused`, plus whatever the component itself needs (`is-checked`,
  `is-on`, `is-empty`, `is-bare`, …), and `has-<thing>` for an optional part that changes the box (`has-accent`
  on a panel, `has-slash` on a heading, `has-label` on a divider). No scoped styles: all kit CSS lives in the
  group's
  partial, written as plain CSS over the tokens (no `@apply`, no Tailwind gradient/transform utilities).
  Templates may use layout utilities (`flex`, `gap-*`, `min-w-0`).
- **Props vocabulary**: `size: 'sm'|'md'|'lg'` (default `md`); `tone: 'accent'|'neutral'|'success'|'warning'|
  'danger'|'info'`; `icon: string` (registry name or raw path; a same-named slot overrides it); `disabled`;
  value carriers use `v-model` (`modelValue`); lists take `items` — strings or `{ value, label, icon?,
  description?, disabled?, … }`, normalised by `normalizeItems`. Runtime validators on enum props. `<script
  setup>`, plain JS, `defineModel` allowed (Vue 3.5). A few components widen the scale on purpose: CoreProgress
  adds `xs`, CoreHeading / CoreDialog / CoreAvatar add `xl`, and CoreIcon / CoreAvatar / CoreSpinner / CoreRing
  take a number of px instead.
- **Tones**: a component that takes `tone` puts `core-tone-<tone>` on its root (`toneClass()` in `use.js`).
  `css/base.css` maps every tone — the six semantic ones, the meter tones `health | armour | stamina | hunger |
  thirst | oxygen | stress`, and `core-rarity-<rarity>` — to two custom properties, `--tone` (the colour) and
  `--tone-rgb` (its `r g b` triplet); the group partial only ever writes `var(--tone)` and
  `rgb(var(--tone-rgb) / 0.16)`. A `color` prop sets `--tone` inline.
- **Pointer events**: the shell is click-through, overlays too. Every interactive root sets `pointer-events:
  auto` in its class (HUD-type components — prompt, prompt group, tracker, compass, stat bar, player chip,
  toast — stay `none`, and a slot inside one of them turns the mouse back on for itself).
- **Keyboard**: everything clickable is a `<button>` or carries `tabindex="0"` + Enter/Space; roving arrows in
  tabs, menu, chips, stepper, select, list, slot grid (2D), swatches, table and the context menu — a radio
  group has none, because native radios sharing a `name` already arrow themselves;
  `:focus-visible` shows the 2 px `accent-hi` outline (offset 2 px).
- **Escape layers**: the store closes the open page on Escape (§7.3, a bubbling `window` listener). A kit popup
  (select list, popover, context menu, dialog, drawer) registers an *escape layer*
  (`useEscapeLayer(openRef, close)`): one capturing `window` listener pops the top layer and stops the event,
  so Escape closes the innermost popup first and only then reaches the store. CoreTooltip is the exception —
  it listens without stopping the key, because a hint lying over a dialog must not eat that dialog's Escape.
  A dialog that cannot be closed still registers its layer: swallowing the key is the point.
- **Popups** teleport to `overlayTarget()` (`#core-overlays`, created on `body` when missing) and are placed
  with `useFloating(anchorRef, floatingRef, openRef, { placement, offset, matchWidth })` — fixed coordinates
  from `getBoundingClientRect()`, flipped and clamped into the viewport, refreshed on resize and on capturing
  scroll. Every one of them resolves the target in `onMounted`, never during render: `#core-overlays` is the
  last child of `.core-root`, so a render-time call would find nothing and build a second one on `body` —
  an orphan outside `.core-root`, which §31 could no longer hide with the shell.
- **Overlay z-scale** (everything teleported into `#core-overlays` shares one stacking context): backdrop /
  dialog / drawer 40, popups (select list, popover, context menu) 50, tooltip 60 — a popup opened from inside a
  dialog paints above the scrim, matching the escape-layer order.
- **Chromium 103** (§7.1): no individual `translate`/`rotate`/`scale` properties (write `transform:`), no
  `:has()`, no `color-mix()`, no CSS nesting, no container queries, no `dvh`, no Popover API, no
  `scrollbar-width` (use `::-webkit-scrollbar`), no `oklch()`. Never `backdrop-filter`; glass is
  `data-core-blur` and only on panels (§32) — a kit component exposes it as the `blur` prop
  (`true` → the attribute, a number → its value).
- **Glass budget** (§32.1): `blur` exists on CorePanel, CoreScreen/CoreBackground (one per page), CoreDialog
  and CoreDrawer (both `true` by default), CorePopover, CoreToast and CoreKeyHints; never on rows, slots,
  chips or list items.
- **HUD plates** — the things that float over the live game with no glass behind them (player chip, tracker,
  key-hint bar, the clock chip `CoreTag variant="dark"`, a stat plate) — fill with `--color-hud` or
  `rgb(var(--core-ink-rgb) / a)` (the prompt band is such a gradient); a **popup** over a panel fills with
  `--color-panel-popup` (select list, context menu, popover) or ink 96 % (tooltip).
- **`defineModel` does not reflect a write locally** while a parent `v-model` is bound: the write goes out as
  `update:modelValue` and comes back on the next tick, so a burst of programmatic updates inside one task
  collapses to the last one. Real input is unaffected (one event per keystroke or click); a test or a story
  that drives a control in a loop must `await nextTick()` between the writes.
- **`.core-panel` is a column** (`display: flex; flex-direction: column`). A legacy page that used the class
  as a row writes `flex-row` next to it — a utility always wins over the kit class (§37.3).
- **Inline SVG**: a `fill="var(--x)"` *presentation attribute* does not resolve in Chromium — write
  `style="fill: var(--x)"` (or let the glyph inherit through `fill="currentColor"`, which is what CoreIcon
  does).
- **CSS hover rules win per property, not per rule**: a base `:hover` that sets `background` overrides a
  variant that only adds a `filter`, whatever the source order. Every variant that brings its own fill is
  therefore excluded from the base hover by hand (`:not(.core-btn--primary)…`) or re-declares the fill in its
  own hover — Chromium 103 has no `:has()` to do it the short way.

### 37.5 Catalogue

Format: **Name** — purpose. `props` (default) · slots · emits · classes · look. Sizes are CSS px at 1080p.
Shared looks: *label voice* = display 600, 12 px, uppercase, 0.14 em, `fg-dim`; *eyebrow voice* = display 500,
13 px, uppercase, 0.32 em, `fg-dim`; *display voice* = display 700, uppercase, 0.04 em, line-height 1; *box look*
(inputs, select, number, stepper) = `--core-h-md` high, `panel-sunken` fill, 1 px white 16 % border → 28 % on
hover → `accent` + `--core-focus` halo when focused, `error` when invalid, 4 px radius; *disabled* = opacity
0.45, `cursor: not-allowed`, no hover.

#### Foundation

- **CoreIcon** — a registry glyph. `name` (registry name or raw path), `path` (explicit raw path), `size`
  (`'xs'` 14 | `'sm'` 16 | `'md'` 20 | `'lg'` 24 | `'xl'` 32 | number; default `md`), `spin`, `title` (else
  `aria-hidden`; with one the root is `role="img"`) · — · — · `core-icon is-spin` · an inline
  `<svg viewBox="0 0 24 24" fill="currentColor">`; unknown name renders an empty box and warns once per name.

#### Actions (`css/actions.css`)

- **CoreButton** — every button. `variant: 'primary'|'secondary'|'ghost'|'danger'|'success'` (`secondary`),
  `fade` (primary: the fading gradient of the mockups' USE button instead of the solid one), `size`, `block`,
  `icon`, `iconRight`, `kbd` (a key cap inside, left: `[F] USE`), `loading`, `disabled`, `active` (toggle on),
  `type` (`button`) · default, `icon`, `trailing` · `click` (never while disabled/loading) · `core-btn
  core-btn--<variant> core-btn--<size> is-fade is-block is-active is-loading is-disabled` + `__kbd __icon
  __label __spinner` · display 600 uppercase 0.08 em,
  16 px (sm 13, lg 19 / 0.1 em), heights `--core-h-*`, padding 0 20 (sm 12, lg 28), radius 4, gap 10 (sm 8,
  lg 14 — a 52 px button needs its glyph clear of the label). The BARE class is the secondary md button, so
  `<button class="core-btn">` in a legacy page or a built-in is already right.
  *secondary*: white 3 % fill, white 14 % border, `fg-dim` text → hover 7 % / 30 % / `fg`. *primary*:
  `--core-grad-accent`, white text, inset top highlight + coral drop glow (`0 8px 22px rgb(accent / .24)`), hover
  `filter: brightness(1.08)` and a stronger glow, active `transform: translateY(1px)`. *fade*:
  `--core-grad-accent-fade`, 1 px `rgb(accent / .45)` border, no outer glow. *ghost*: no fill/border, hover white
  6 %. *danger* / *success*: tone 8 % fill, tone 50 % border, tone text, hover 16 %. `is-active`: `accent-soft`
  fill, `accent` border, `fg` text — except on the primary, which keeps its gradient and only gets a stronger
  glow. Loading swaps the icon for a 16 px ring (sm 13, lg 18) and keeps the label, so the width never moves.
  Icon 18 px (sm 14, lg 22).
- **CoreIconButton** — square icon-only button. `icon` (required), `label` (aria-label + `title`), `variant:
  'secondary'|'ghost'|'primary'|'danger'|'success'` (`secondary`), `fade` (primary only, as CoreButton), `size`,
  `round`, `active`, `disabled` · default (custom glyph) · `click` · `core-iconbtn core-iconbtn--<variant>
  core-iconbtn--<size> is-fade is-round is-active is-disabled`
  · width = height = `--core-h-*`, glyph 20 px (sm 16, lg 24), every fill shared with CoreButton in one
  selector list so the two can never drift; `round` = 50 %.
- **CoreKey** — a key cap. `label` (`'F'`, `'ESC'`, `'SPACE'`; `'mouse-left'|'mouse-right'|'mouse-middle'|
  'mouse-scroll'|'mouse'` draw the mouse glyph instead of a cap), `variant: 'solid'|'outline'` (`solid`), `size`
  (20 / 26 / 32 px), `pressed`, `progress` (0–1, hold-to-confirm) · default (wins over the mouse names) · — ·
  `core-key core-key--<size> core-key--<variant>` (`core-key--mouse` instead, for a mouse label) plus
  `is-pressed is-holding` + `__progress` · min-width =
  height, padding 0 7 (sm 5, lg 9), radius 3, display 700 15 px (sm 12, lg 18); the bare class is the solid md
  cap. *solid*:
  `--color-key` tile, `--color-key-fg` text, `0 2px 0 rgba(0,0,0,.45)` lip. *outline*: white 6 % fill, white 28 %
  border, `fg` text. *mouse*: no tile, no lip, the glyph at the cap's height. Pressed: `accent` tile, white text,
  lip collapsed, `translateY(1px)`. `progress` scales a 3 px `accent` bar along the bottom edge — no transition
  on it, because the caller drives it per frame.
- **CoreKeyHint** — cap(s) + caption. `keys` (string | string[]) (alias `k`, used when `keys` is empty),
  `label`, `variant`, `size` · default (caption) · — · `core-keyhint core-keyhint--<size>` + `__keys __label` ·
  gap 10 (sm 8, lg 12); caption display 500 14 px (sm 12, lg 16) uppercase 0.1 em, `fg` at 85 % — not `fg-dim`,
  which disappears over a bright map; several caps sit 4 px apart.
- **CoreKeyHints** — the hint bar. `items: [{ key | keys, label }]` (a bare string is a cap with no caption),
  `align: 'start'|'end'|'between'` (`end`), `bare` (no chrome — inside a CoreScreen footer), `variant`, `size`,
  `blur` · default, `start`, `end` · — · `core-keyhints core-keyhints--<align> is-bare` · gap 10 / 28; not
  bare: `--color-hud` fill, hairline border, radius 4, padding 8 14.
- **CorePrompt** — interaction prompt (`[F] ⛭ ENTER VEHICLE`). `keys` (string | string[]), `label`, `icon`,
  `description`, `progress` (0–1 hold), `active`, `disabled`, `interactive` (takes the mouse and makes the root
  a real `<button>`; default click-through `<div>`)
  · default, `icon` · `click` (interactive only) · `core-prompt is-active is-disabled is-interactive` +
  `__keys __band __icon __text __label __desc` · `lg` solid CoreKeys (every cap carries `progress`),
  8 px gap, then a band ≥ 220 × 40 px: `linear-gradient(90deg, rgb(ink / .80) 0 66%, rgb(ink / 0) 100%)`,
  padding 0 36 0 14, icon 20 px `fg`, label display 600 16 px uppercase 0.08 em; description sans 12 px `fg-dim`
  on a second line. `is-active`: the cap turns `accent` without CoreKey's pressed offset — lit, not held.
- **CorePromptGroup** — stacked prompts. `items: [{ keys, label, icon?, description?, progress?, active?,
  disabled?, interactive? }]` (`interactive` travels per item), `align: 'start'|'end'` (`start`) · default ·
  `select` (item, index) · `core-prompts core-prompts--<align>` · column, gap 8, click-through.

#### Surfaces (`css/surfaces.css`)

- **CorePanel** — the bordered dark panel. `variant: 'default'|'solid'|'flat'|'ghost'|'hud'` (`hud` = the HUD
  plate: `--color-hud` fill, radius 4, `--shadow-ui-sm`, no sheen, `border-strong` hairline, never `blur`), `padding:
  'none'|'sm'|'md'|'lg'` (0 / 12 / 20 / 28; `md`), `title`, `subtitle`, `eyebrow`, `slash`, `headingSize` (`md`),
  `accent` (2 px fading coral line on the top edge), `scroll` (body scrolls), `blur`, `tag` (`section`) ·
  default, `header` (replaces the heading), `actions` (header right), `footer` · — · `core-panel
  core-panel--<variant> core-panel--pad-<p> has-accent` + `__header __heading __actions __body __footer` ·
  `--color-panel` fill +
  `--core-grad-sheen`, hairline border, radius 6, `--shadow-ui`; *solid* opaque; *flat* white 2 %, no shadow;
  *ghost* nothing but padding. The padding lives on the PARTS, so a bare `<div class="core-panel">` is the
  default variant with none of its own; a body that follows a header keeps only 14 px of top padding. Footer
  has a hairline top and a black 18 % fill.
- **CoreCard** — media + text card (the LAST PLAYED card, quest detail). `variant: 'default'|'flat'|'ghost'`
  (`flat` = white 2 % fill, no shadow; `ghost` = no fill, border or shadow — a brief sitting flush on a panel),
  `image`, `imagePosition: 'left'|'top'` (`left`), `mediaWidth` (168), `mediaHeight` (180), `eyebrow`, `title`,
  `uppercase` (true),
  `subtitle`, `icon` (before the subtitle), `selected`, `interactive`, `disabled` · default (body), `media`,
  `icon`, `meta` (footer row under a hairline), `trailing` · `click` · `core-card core-card--media-<pos>
  is-selected is-interactive is-disabled` + `__media __image __fade __main __eyebrow __title __subtitle __body
  __meta __trailing` · panel fill, hairline, radius 6. *left*: image inset in the card's 14 px padding with
  radius 4, 20 px gap. *top*: full-bleed
  image fading into the panel colour, main block pulled 40 px up over the fade. Eyebrow label voice `fg-faint`;
  title display 700 22 px (`uppercase: false` → `is-plain`: mixed case, no tracking — the quest names of
  mockup 4); subtitle sans 15 px `fg-dim` with a 16 px icon; meta 14 px `fg-dim`, `<b>`/`<strong>` = `fg`.
  Interactive hover: border `border-strong` + a `panel-raise` lift; selected: `accent-hi` border +
  `--shadow-glow-sm`. An interactive card is NOT a `<button>` — its slots hold buttons — it takes
  `role="button"` + `tabindex="0"` and answers Enter/Space by hand, the one exception to §37.4's keyboard rule.
- **CoreBackground** — full-bleed scrim over the game. `variant: 'scrim'|'left'|'right'|'top'|'bottom'|
  'bars'|'vignette'|'solid'|'none'` (`vignette`), `dim` (0–1, overrides the variant's own 0.62–0.94 through
  `--core-bg-a`), `fade` (0–1, how far across the box a directional gradient reaches, `--core-bg-fade`; unset
  keeps the variant's own 0.52 / 0.62), `image`, `position` (`background-position` of the image, `'center'`),
  `pattern: 'none'|'grid'`, `blur` · default (extra layers) · — · `core-bg
  core-bg--<variant>` + `__image __scrim __pattern` · absolute inset 0,
  click-through, `aria-hidden`, z 0. *left* = ink 94 % → 0 at 62 % of the width (the main-menu look);
  *vignette* = radial ink 25 % → 88 %; *bars* = the two cinematic bands; *solid* = `--color-ink`; *grid* = a
  40 px white 2 % hairline grid.
- **CoreScreen** — full-page scaffold (the inventory / map frame). `background` (CoreBackground variant,
  `scrim`), `dim`, `image`, `position` (forwarded to the background), `blur`, `padded` (true), `navAlign:
  'space'|'center'|'start'` (`space` shares the room between brand and status; `center` pins the nav to the
  middle of the screen like mockup 3; `start` hangs it next to the brand like mockup 4) · `background`, `brand`,
  `nav`, `status` (header: left / centre / right), default (body), `footer-start`, `footer-end` · — ·
  `core-screen core-screen--nav-<align>` + `__header __brand __nav __status __body __footer __footer-start
  __footer-end` ·
  absolute inset 0, column, `pointer-events: auto`. Header 76 px, padding 0 32, hairline bottom, ink gradient
  fill; body flex 1, `is-padded` = 24 28; footer 64 px, hairline top, ink 90 %. Header and footer render only
  when one of their slots is filled — a bare screen is a scrim and a padded column.
- **CoreHeading** — title block. `title`, `subtitle` (eyebrow voice, under), `eyebrow` (label voice, above),
  `size: 'sm'|'md'|'lg'|'xl'` (18 / 24 / 34 / 48 with the subtitle at 12 / 13 / 14 / 16; `md`), `slash` (the `//`
  marker + italic title), `tag` (`h2`),
  `align` (`left`) · default (title), `subtitle`, `actions` · — · `core-heading core-heading--<size>
  core-heading--align-<align> has-slash` + `__main __eyebrow __title __slash __text __subtitle __actions` · the
  marker is two `accent` bars, 0.34 em × 0.9 em, skewed −20°, 0.2 em apart. At `lg`/`xl` the title is not flat
  white: it is clipped out of a white → `fg` → `fg-dim` vertical gradient (so is a `lg` CoreBrand name).
- **CoreDivider** — hairline. `vertical`, `strong`, `label` · default (the caption) · — · `core-divider
  core-divider--vertical core-divider--strong has-label` + `__label` · a labelled line parts around a label
  voice `fg-faint` caption (the halves are pseudo-elements) and drops `role="separator"`.
- **CoreDash** — the short accent bar. `width` (28; a string passes through), `tone` (`accent`) · — · — ·
  `core-dash core-tone-<tone>` · 3 px high, radius 1.5, `aria-hidden`; the accent tone wears the brand gradient
  instead of a flat fill.
- **CoreTagline** — stacked wide-tracked words. `lines: string[]`, `rule` (`true` a vertical hairline left,
  `'accent'` the 2 px coral rule of mockups 3/4), `dash` (`true` or a width; accent dash under), `align` ·
  default · — · `core-tagline core-tagline--align-<a> has-rule is-rule-accent has-dash` + `__lines __line
  __dash` · display 500 12 px uppercase 0.3 em `fg-faint`, line-height 1.75, an ink text-shadow so it survives
  bright key art (panel text never wears one).
- **CoreBrand** — logo lockup. `name`, `tagline`, `logo` (url), `size: 'sm'|'md'|'lg'|'xl'` · `logo` (an inline
  SVG, which inherits the accent colour from the box) · — · `core-brand core-brand--<size>` + `__logo __text
  __name __tagline` · name display 700 (22 / 30 / 48 / 64) with a 32 / 44 / 70 / 90 px mark box, tagline eyebrow
  voice with an ink text-shadow (it sits on key art); without a logo the box is not rendered at all.

#### Navigation (`css/navigation.css`)

- **CoreTabs** — top navigation. `v-model`, `items: [{ value, label, icon?, badge?, disabled? }]`, `size`,
  `separators`, `stretch`, `line` (true: hairline under the row), `prevKey`, `nextKey` (outline key caps at the
  ends, clickable) · `tab` ({ item, active }) · `update:modelValue`, `change` (value, item) · `core-tabs
  core-tabs--<size> core-tabs--line core-tabs--separators core-tabs--stretch`, `core-tabs__list`,
  `core-tabs__key`, `core-tab is-active is-disabled` + `__label __badge` ·
  row 44 px (sm 34, lg 54), display 600 17 px (sm 14, lg 20) uppercase 0.1 em, `fg-dim` → `fg` on hover → white
  when active with a 3 px (lg 4) glowing `accent` underline sitting on the hairline; gap 36 (sm 26, lg 44); the
  underline is a per-tab `::after` that only fades, so nothing measures the DOM. ←/→ (and ↑/↓) move selection
  and focus together, Home/End jump to the first/last enabled tab, Enter/Space is the button's own click.
- **CoreMenu** — vertical menu (main menu, category sidebar, the shell's keyboard menu). `v-model` (active
  value), `items: [{ value, label, icon?, glyph?, description?, trailing?, badge?, disabled?, danger? }]` (`icon`
  is a registry name; `glyph` is a short text — an emoji — drawn in the icon box when there is no icon), `size`
  (row 38 / 56 / 70 px; text 15 / 18 / 25), `fade` (true: the active row dissolves), `selectOnHover`,
  `loop` (true), `keyboard` (true; `false` = the caller owns ↑/↓/Enter, as the shell's menu does), `rowAttrs`
  (`(item, index) → attrs` merged onto each row: `data-index`, `role`, hook classes) · `item` ({ item, active }),
  `trailing` ({ item, active }) · `update:modelValue`, `select`
  (item: click or Enter) · `core-menu core-menu--<size> is-fade`, `core-menu__item is-active is-disabled
  is-danger` + `__icon __body __label __desc __badge __trailing` · display
  600 uppercase 0.07 em `fg-dim`, icon box 30 px (sm 22, lg 34 — a size up from the mark, because an MDI path
  fills about three quarters of its 24-grid) with a 22 px gap (sm 14, lg 28); hover white 4 % + `fg`; active
  white text on `--core-menu-fade`, the dissolve measured off the mockups (solid coral to 34 %, 52 % at 68 %,
  gone at 100 %) — `fade: false` gives the solid `--core-grad-accent` instead; description sans 13 px `fg-faint`
  under the label; badge an `accent` 20 % pill; trailing right-aligned display 500 `fg-faint`; `is-danger` is
  the same geometry in `error`. ↑/↓ (and ←/→) move, skipping disabled, Home/End jump, Enter selects.
- **CoreChips** — filter chips / segmented control. `v-model` (value, or array with `multiple`), `items`
  (`{ value, label, icon?, count?, disabled? }`), `multiple`, `allowEmpty`, `size`, `wrap`, `stretch` (equal-width
  cells filling the row, the map's filter bar), `minWidth` (px per chip, 0) · `chip`
  ({ item, active }) · `update:modelValue` · `core-chips core-chips--<size> core-chips--wrap`, `core-chip
  is-active is-disabled` + `__label __count`
  · 36 px high (sm 28, lg 44), padding 0 16 (sm 12, lg 22), radius 4, display 600 15 px uppercase 0.08 em — the
  mockup's filter row carries visibly more weight than 500 / 14 px would; idle white 3 % + hairline
  + `fg-dim`; hover `border-strong` + white 6 % + `fg`; active `--core-grad-accent`, white, no border. ←/→ move
  the FOCUS only — a chip is a toggle, so arrowing onto one must not change the filter; Space/Enter toggles.
- **CoreStepper** — `‹ value ›` cycler. `v-model`, `items` (cycles their values) or `min`/`max`/`step`,
  `loop`, `format` (value, item), `showCount` (`3 / 24`), `block`, `size`, `disabled` · default
  ({ value, item }) · `update:modelValue` · `core-stepper core-stepper--<size> core-stepper--block is-disabled`
  + `__btn __btn--prev __btn--next __value __label __count` · box look; the chevron buttons are square at the
  box height (40 px at `md`) and sit OUT of the tab order — the centre is the `role="spinbutton"` tab stop, so
  a settings column is one Tab per control; centre display 600 15 px (sm 13, lg 18) uppercase, count `fg-faint`.
  ←/↓ and →/↑ step, Home/End jump to the ends, the chevrons disable themselves at the bounds unless `loop`,
  and a float step is re-rounded to 6 decimals so `0.1 + 0.2` never prints as `0.30000000000000004`.

#### Forms — text (`css/forms-text.css`)

- **CoreField** — label + control + hint/error. `label`, `hint`, `error` (its presence is what makes the field
  invalid, and it replaces the hint), `required`, `inline` (settings row:
  label left, control right, hairline under), `controlWidth` (`50%`), `id` (else one is generated) · default
  ({ id, invalid }), `label`, `hint` · — · `core-field core-field--inline is-invalid` + `__text __label
  __required __control __hint __error` · label voice (inline: sans 15 px `fg`), hint 13 px
  `fg-faint`, error 13 px `error` with an icon.
- **CoreInput** — `v-model`, `type`, `placeholder`, `icon`, `prefix`, `suffix`, `size`, `clearable`,
  `maxlength`, `invalid`, `disabled`, `readonly`, `autofocus`, `id`, `name` · `prefix`, `suffix` ·
  `update:modelValue`, `enter` (value), `clear`, `focus`, `blur` · exposes `focus()` · `core-inputbox
  core-inputbox--<size> is-focused is-invalid is-disabled` > `__el`, plus `__icon __prefix __suffix __clear` ·
  box look; sans 15 px; `user-select: text` on the element (the shell turns selection off globally).
  `inheritAttrs: false` — a caller's `aria-*` or `@keydown` lands on the `<input>`, not on the div; a click
  anywhere in the well focuses it. The bare legacy elements `input.core-input`, `textarea.core-input` and
  `select.core-select` wear the same look (the shell's InputDialog still renders them).
- **CoreTextarea** — `v-model`, `rows` (4), `maxlength`, `counter`, `resize: 'none'|'vertical'`, `invalid`,
  `disabled`, `readonly`, `autofocus`, `placeholder`, `id`, `name` · — · `update:modelValue`, `focus`, `blur` ·
  exposes `focus()` · `core-textarea core-textarea--resize is-focused is-invalid is-disabled` + `__el
  __counter` (`is-over` past `maxlength`) · the box look as a column, so the counter sits inside the well.
- **CoreNumberInput** — `[−] 12 [+]`. `v-model` (number), `min`/`max` (`null` = unbounded), `step` (1),
  `precision` (`null` = as many decimals as `step` has), `suffix`, `size`, `invalid`, `disabled`, `id`, `name` ·
  — · `update:modelValue`, `focus`, `blur` · exposes `focus()` · `core-number core-number--<size> is-focused
  is-invalid is-disabled` + `__btn __btn--dec __btn--inc __field __el __suffix` · box look; square buttons at
  the box height (40 px at `md`), out of the tab order, disabled at the bounds and repeating while held
  (400 ms, then every 60 ms); centre display 600 17 px tabular (sm 13, lg 18). The field keeps its own TEXT
  while it is being typed — a half-written `-` is not thrown away — and commits (parse, clamp, round) on blur
  and on Enter; ↑/↓ step.
- **CoreSelect** — dropdown. `v-model`, `items` (`{ value, label, icon?, description?, disabled? }`),
  `placeholder` (`Select…`), `label` (inline caption: `SORT:`), `variant:
  'box'|'inline'` (`box`), `size`, `placement: 'auto'|'bottom'|'top'`, `maxHeight` (260), `invalid`,
  `disabled`, `id` · `option` ({ item, selected, active }), `value` ({ item }) · `update:modelValue`, `open`,
  `close` · `core-selectbox core-selectbox--<variant> core-selectbox--<size> is-open is-invalid is-disabled` >
  `__trigger __caption __value __chevron`, popup `core-selectbox__popup core-selectbox__popup--<variant>` >
  `__option is-active is-selected is-disabled` + `__option-icon __option-body __option-label __option-desc
  __check __empty` (the bare legacy `select.core-select` keeps the look of a
  native `<select>`, which is why the component does not reuse that name) · *box* = box look + chevron (turns
  180° and `accent` when open); *inline* = no chrome, caption and
  value both display 600 13 px 0.14 em — only the colour separates them (the mockup's `SORT: RECENT ⌄`).
  Popup: teleported, `--color-panel-popup`,
  `border-strong`, radius 4, `--shadow-ui`, 4 px padding, min-width 160 (`matchWidth` on the box variant);
  options ≥ 36 px, sans 15 px; active = `accent` 16 % +
  2 px inset left bar (the keyboard cursor); selected = an `accent` check on the right — both can be true at
  once. Space/Enter/↑/↓ open, ↑/↓ and Home/End move, Enter/Space picks, Tab and an outside pointerdown close,
  Escape closes through the kit's layer, and typing jumps to a label (700 ms buffer). Focus never leaves the
  trigger: the list is a `role="listbox"` driven by `aria-activedescendant`.

#### Forms — choice (`css/forms-choice.css`)

- **CoreCheckbox** — `v-model` (boolean, or array with `value`), `value`, `label`, `description`, `icon`
  (between box and label — the map-filter row), `indeterminate`, `size`, `disabled` · default (label), `icon` ·
  `update:modelValue` · `core-check core-check--<size> is-checked is-indeterminate is-disabled` + `__icon
  __body __label __desc` (a `<label>` around a real `<input type="checkbox">`) · box 22 px
  (sm 18, lg 26), radius 3, ink 28 % fill, 1.5 px white 38 % border → 70 % hover; checked: `--core-grad-accent`
  + a white tick (a data-URI, `indeterminate` a white bar); label sans 15 px `fg`, description 13 px `fg-dim`.
  The rule targets `.core-check input`, so legacy markup gets the look too; `inheritAttrs: false` keeps
  `class`/`style` on the label and sends `name`, `id` and the rest to the input.
- **CoreRadioGroup** / **CoreRadio** — group: `v-model`, `items`, `name` (generated when absent),
  `orientation: 'vertical'|'horizontal'` (`vertical`), `variant: 'radio'|'card'` (`radio`), `size`, `disabled` ·
  default, `item` ({ item, index, checked }) · `update:modelValue`; the group `provide`s model, name, size,
  variant and disabled, so a CoreRadio written by hand inside the slot joins it. Radio: `value`, `label`,
  `description`, `name`, `disabled`, `size`/`variant` (`null` = inherit the group's) · default ·
  `update:modelValue` · `core-radiogroup core-radiogroup--<orientation> core-radiogroup--<variant> is-disabled`,
  `core-radio core-radio--<size> core-radio--card is-checked is-disabled` + `__body __label __desc` · circle
  20 px (sm 16, lg 24), white 38 % border; checked `accent-hi` 2 px ring + a centred `accent` dot half the
  circle wide, and a soft
  glow. *card*: padded `panel-raise` tile, hairline → checked `accent-hi` border, `accent-soft` fill,
  `--shadow-glow-sm`. No roving-arrow code: native radios sharing a `name` already arrow themselves.
- **CoreSwitch** — `v-model`, `label`, `description`, `labelPosition: 'left'|'right'` (`left` — label, then the
  switch: the settings row), `size`, `disabled` · default (label) ·
  `update:modelValue` · `core-switch core-switch--<size> core-switch--left is-on is-disabled` + `__input
  __track __thumb __body __label __desc` · squared track 42 × 22 (sm 34 × 18, lg 52 × 26), radius 3, sunken
  fill; thumb 16 × 16, radius 2, `--color-key`; on: `--core-grad-accent` track, thumb moved 20 px. The input is
  the only one in the group that is not the paint (Chromium draws no pseudo-element on a void `<input>`): it is
  visually hidden — never `display: none`, which would drop it out of the tab order — and the sibling track
  reads `:checked` through `+`.
- **CoreSlider** — `v-model` (number), `min` (0), `max` (100), `step` (1), `label`, `showValue`, `format`,
  `suffix`, `minLabel`, `maxLabel`, `ticks` (`true` = one mark per step up to 20, or a count), `tone`
  (semantic tones only), `disabled` · `value` ({ value, percent }) · `update:modelValue` (while
  dragging), `change` (on release) · `core-slider core-tone-<tone> is-disabled` + `__head __label __value __rail
  __input __ticks __tick __ends` · the root is a column around a real `<input type="range">` painted through the
  `::-webkit-slider-*` pseudo-elements; track 4 px, white 14 %; the fill is not a second element — the track
  itself is a two-stop `var(--tone)` gradient cut at `--core-slider-pct`; thumb 10 × 20,
  radius 2, `--color-key`, 5 px `rgb(tone / .25)` halo on hover/drag. The bare `input[type=range].core-slider`
  gets the same track and thumb.
- **CoreSwatches** — colour picker. `v-model`, `items` (strings — value and paint at once — or
  `{ value, color, label?, disabled? }`), `size`, `shape: 'square'|'circle'`, `columns` (0 = a wrapping row),
  `disabled` · — · `update:modelValue` · `core-swatches core-swatches--sm|lg core-swatches--circle
  core-swatches--grid is-disabled`, `core-swatch is-selected` ·
  30 px (22 / 30 / 38), radius 3, an inset white 22 % line so a near-black paint still has an edge; selected:
  2 px ink gap, then a 2 px `accent-hi` ring and a coral glow. One tab stop; ←/→ rove AND pick as they go
  (a colour picker is judged by what the ped looks like right now), Home/End jump.

#### Data — meters (`css/data-meters.css`)

- **CoreProgress** — linear bar. `value`, `min` (0), `max` (100), `tone` (the six semantic tones or any of the
  seven vitals; default `accent`), `color` (any CSS colour), `size: 'xs'|'sm'|'md'|'lg'` (2 / 4 / 8 / 12),
  `label`, `icon`, `showValue`, `valueText`, `format` (value, max), `inline` (icon · label · bar · value on one
  row — the capacity bar), `segments`, `indeterminate`, `warnBelow`, `dangerBelow` (percent → the tone CLASS
  switches, so a re-themed server still owns the palette) · `label`,
  `value` · — (exposes `fillEl`, the fill element, for a caller that animates the width itself — the shell's
  progress bar) · `core-progress core-progress--<size> core-tone-<tone> core-progress--inline is-segmented
  is-indeterminate` + `__head __caption __icon __label __value __max __track __fill` · track white
  12 %, radius 2; fill `--core-grad-accent` (accent), `#dfe3e7 → #c9cfd5` (neutral), the tone colour otherwise;
  width eases 250 ms. Value display 600 15 px; the dimmed `/ 30.0` half is only printed when the caller really
  passed a `max` — the prop has a default, so only the raw vnode can tell. `segments` masks the track into
  n cells, `indeterminate` sweeps a 35 % fill across it.
- **CoreRing** — radial progress. `value`, `max` (100), `size` (48 px), `thickness` (4), `tone` (meter tones
  too), `color`, `icon` ·
  default (centre) · — · `core-ring core-tone-<tone>` + `__svg __track __fill __center __value` · one SVG
  circle with a shrinking `stroke-dashoffset`, white 12 % well, butt caps, 250 ms ease; it starts at 12 o'clock
  through the SVG `transform` ATTRIBUTE, never a CSS transform (§37.4). The centre prints the value at 32 % of
  the box, or the glyph at 42 %.
- **CoreStatBar** — HUD vital (`♥ ▬▬▬ 100`). `icon`, `iconTone: 'tone'|'fg'` (`fg` = a white glyph on a coloured
  bar, the mockup's shield), `value`, `max` (100), `tone` (`health`), `width` (220), `showValue` (true), `lowBelow`
  (25 → the GLYPH pulses; the bar never moves) · — · — · `core-statbar
  core-tone-<tone> is-low` + `__icon __track __fill __value` · click-through; icon 20 px in the tone, bar
  10 px in a `panel-sunken` well, value display 600 19 px tabular with a 44 px floor width, so 100 → 75 cannot
  resize the plate around it.
- **CoreVital** — the HUD's slanted vital plate (§39: one parallelogram, the top slice the vital, the cut-off
  bottom slice a second stat's bar, its glyph underneath). `label`, `icon`, `tone` (`health`), `value`, `max`
  (100), `lowBelow` (25 → the icon pulses), `subValue` (`null` = no bar, `--solo`), `subMax` (100), `subIcon`,
  `subLabel`, `subWarnBelow` (25), `subDangerBelow` (10), `unit` (px | CSS length → `--core-hud-unit`) · — · — ·
  `core-vital core-vital--solo core-tone-<tone> is-low is-loss is-gain is-sub-warning is-sub-danger is-sub-loss
  is-sub-gain` + `__shape __plate __content __icon __label __chunk __fill __bar __subchunk __subfill __subicon` · click-through; every length in `em` (1 em = 100 mockup px,
  default unit 24 px), `skewX(-20deg)` shape, fills are `clip-path: inset()` driven by `--core-vital-value` /
  `--core-vital-sub` (0..1) so every progress edge has the parallelogram's angle; the content is drawn twice
  (track look under the fill, plate look inside it) for the two-tone label. Geometry, colours and structure: §39.1–§39.3.
- **CoreStatRow** — detail stat (`♥ HEALTH RESTORE … +75`). `icon`, `label`, `value`, `tone` (no default — an
  untoned row keeps its value in `fg`, exactly like the mockup), `hairlines:
  'both'|'top'|'bottom'|'none'` (`both`) · `value` · — · `core-statrow core-statrow--line-<hairlines>
  core-tone-<tone>` + `__icon __label __value` · 56 px row, icon 22 px in `fg`, label display 500
  16 px uppercase 0.1 em `fg-dim`, value display 700 24 px in the tone; stacked rows share one hairline.
- **CoreSpinner** — `size` (14 / 18 / 24 | number), `tone` (meter tones too), `label` · default (the caption) ·
  — · `core-spinner core-tone-<tone>` + `__ring __label` · `role="status"`; one ring, `border-strong` with the
  top side in the tone and a stroke of size / 8.
- **CoreSkeleton** — `width` (`100%`), `height` (14), `lines` (1), `radius` (3 px) · — · — · `core-skeleton
  core-skeleton--lines` + `__line` · white 6 % + shimmer, `aria-hidden`; the last line of a stack ends at 62 %,
  the way a real paragraph does.

#### Data — display (`css/data-display.css`)

- **CoreBadge** — count / status pip. `value`, `max` (99 → `99+`; a non-numeric value is printed as it stands),
  `tone` (`accent`), `variant: 'solid'|'soft'|'outline'` (`solid`), `dot`, `pulse` · default · — ·
  `core-badge core-badge--<variant> core-tone-<tone> is-dot is-pulse` · 18 px min-width and height, radius 3,
  display 700 11 px tabular; *solid* = the tone filled with `ink` text (the accent wears the brand gradient),
  *soft* = tone 14 %, *outline* = border only; `dot` drops the value for an 8 px round pip; `pulse` adds a ring
  in the tone expanding out of the edge on the `core-ping` keyframe — the pip itself stays solid.
- **CoreTag** — small label chip. `label`, `icon`, `tone` (`neutral`), `rarity: 'common'|'uncommon'|'rare'|
  'epic'|'legendary'` (wins over `tone`), `variant: 'soft'|'solid'|'outline'|'dark'` (`soft`), `size`,
  `removable` ·
  default · `remove` · `core-tag core-tag--<variant> core-tag--<size>` + `core-rarity-<r>` (else
  `core-tone-<tone>`) +
  `__icon __label __remove` · 24 px (sm 20, lg 30), radius 3, display 600 13 px uppercase 0.1 em; *dark* is the
  HUD clock chip — `rgb(ink / .78)` with `fg` text and the glyph in the tone. Only the ✕ takes the mouse.
- **CoreAvatar** — `src`, `name` (initials fallback, also on a load error), `size` (`sm` 28 | `md` 40 | `lg` 56 |
  `xl` 76 | number), `shape: 'square'|'circle'` (`square` = radius 4), `status: 'online'|'away'|'busy'|
  'offline'`, `ring` · — · — · `core-avatar core-avatar--<shape> is-ring` + `__img __initials __status` ·
  everything that scales with the box is inline (a number is a legal `size`); the presence dot is 26 % of the
  box, 8–16 px, ringed in ink; `ring` = a 2 px `accent-hi` outline with a 2 px ink gap.
- **CorePlayerChip** — avatar · name · level · XP bar · status dot (mockup 1, top right). `name`, `avatar`,
  `level`, `levelLabel` (`Lv.`), `progress` (0–1, not 0–100), `status`, `subtitle` · `avatar`, `meta` (replaces
  the level + XP row) · — · `core-playerchip` + `__avatar __body __top __name __status __meta __level __xp
  __xpfill __subtitle` ·
  296 × ≥ 74 px, `--color-hud` fill + sheen + hairline + `--shadow-ui-sm`, click-through; 72 px avatar column
  flush left, name display 700 18 px uppercase. The XP rail is the chip's OWN 4 px bar, not a CoreProgress: it
  shares a flex row with the level and must not inherit a meter's label/value chrome.
- **CoreTable** — `columns: [{ key, label, align?, width?, format?(value, row) }]`, `rows`, `rowKey` (`id`),
  `selectable`, `v-model:selected` (the ROW KEY, never the index — rows get re-sorted), `dense`, `stickyHeader`,
  `empty` · `cell-<key>` ({ row, value, column }), `empty` · `row-click` ·
  root `core-table__wrap core-scroll is-sticky` (the scroll box, so a caller's `max-height` lands on it) around
  `<table class="core-table core-table--dense is-selectable">` + `__th __th--<align> __body __row __cell
  __cell--<align> __empty` · header label voice `fg-faint` 34 px (dense 30) over a hairline, rows 44 px (dense
  36) with white 6 % hairlines, hover white 3 % while selectable, selected
  `accent-soft` + a 2 px inset bar on the first cell (a collapsed table discards an inset shadow put on the
  `<tr>`). The
  `<tbody>` is the tab stop: ↑/↓ and Home/End move the selection, Enter/Space re-fires `row-click`.
- **CoreKeyValue** — `items: [{ label, value, icon?, tone? }]`, `columns` (1), `lastRule` (true; `false` drops
  the last row's hairline so a block can sit flush on a panel edge) · `value-<i>` ({ item, value }), `label-<i>`
  ({ item }) · — · `core-kv` (a `<dl>`) + `__item is-toned __label __icon __value` · rows ≥ 32 px under a white 6 %
  hairline, label voice left, value display 600 15 px tabular right; an item `tone` paints the value and its
  glyph; `columns` only splits the same rows into a grid (32 px column gap).
- **CoreEmpty** — `icon`, `title`, `text` · default (actions) · — · `core-empty` + `__icon __title __text
  __actions` · a 60 px framed glyph box (icon drawn at 28), display 700 18 px title, sans 14 px `fg-dim` text
  at most 46ch wide; the actions row turns the mouse back on, because an empty state often sits in a
  click-through panel.

#### Game (`css/game.css`)

- **CoreSlot** — item slot. `image`, `icon` (fallback glyph), `count`, `hotkey` (key chip top-left), `label`
  (title attr + accessible name), `rarity`, `durability` (0–1, 3 px bar on the bottom edge: green, amber under
  50 %, red under 20 %), `badge` (top-right text), `selected`,
  `disabled` (aria only, so the grid's arrows can still walk over it), `empty`, `size` (px; default fills the
  cell), `ratio` (`'1 / 1'`), `interactive` (true → a `<button>`; false → a plain `<div>` for a legend or a
  tooltip) · default, `overlay` · `click`,
  `dblclick`, `contextmenu` · `core-slot core-slot--rarity-<r> core-rarity-<r> is-selected is-empty
  is-disabled` + `__media __image __glyph __hotkey __badge __count __durability __rarity __overlay` ·
  `panel-raise`
  fill, white 12 % border, radius 4, image contained in a 12 % inset; count display 700 19 px bottom-right;
  hotkey = an 18 px solid key chip (its own markup, not CoreKey — a 96 px cell must not pull in cap sizes and
  hold states); hover `border-strong` + white 6 %; selected 2 px `accent-hi` border +
  `--shadow-glow`; rarity = a 2 px line + a faint bloom in the rarity colour along the bottom.
- **CoreSlotGrid** — `items: [{ id, …slot props }]` (`id` identifies the cell and is stripped before the rest
  is spread onto CoreSlot, so it can never land as a DOM id), `columns` (4), `gap` (12), `slots` (pad with empty
  cells up to this count — the bag's capacity), `v-model:selected` (id), `ratio` · `slot` ({ item }) — rendered
  INSIDE each cell, in CoreSlot's own default slot, so the grid keeps the focus · `select` (item) ·
  `core-slotgrid` (a `role="grid"`) · one tab stop; ←/→ walk the row and spill into the next, ↑/↓ jump a row,
  Home/End go to the ends.
- **CoreHotbar** — `items`, `active` (INDEX, not an id), `keys` (cap labels, default 1…n; an item's own
  `hotkey` still wins), `slotWidth` (96), `ratio` (`'5 / 4'`) · — · `select` (index, item) · `core-hotbar` ·
  gap 6; the cells bring their own `panel-glass` fill and the 6 px radius, because over the bare game
  `panel-raise` has nothing to lighten.
- **CoreList** / **CoreListItem** — rich rows (the quest list). List: `items: [{ id, …item props }]`,
  `v-model` (selected id), `dividers` · `item` ({ item, selected, index }) · `select` (item). Item: `image`,
  `icon`, `iconTone` (`accent`), `title`,
  `subtitle`, `trailing`, `selected`, `completed`, `disabled`, `interactive` (true) · `media`, `icon`, default,
  `trailing` · `click` · `core-listview core-listview--dividers` (a `role="listbox"`), `core-listitem
  is-selected is-completed is-disabled is-interactive` + `__media __image __icon __text __title __subtitle
  __trailing` (not `core-list`: that legacy name is
  the old menu `<ul>`, kept by `css/navigation.css` together with `.core-item` as `core-menu--sm` rows) · cards
  with a 10 px gap by default, `dividers` collapses them into one hairline-separated list; thumb 96 × 84
  radius 3, icon
  26 px in the tone, title display 700 19 px and NOT uppercased — the only display-voice title in the kit that
  is set in Title Case by default; subtitle sans 14 px `fg-dim`, trailing sans 15 px `fg-dim`
  bottom-right; selected = `accent-hi` border + `--shadow-glow-sm`; `completed` dims the thumb and the title.
  One tab stop, ↑/↓ and Home/End rove, Enter/Space selects (the rows are buttons).
- **CoreObjective** — `text`, `state: 'open'|'active'|'done'|'failed'`, `trailing`, `optional` · default (the
  text), `trailing` · — ·
  `core-objective is-<state>` + `__ring __text __optional __trailing` · 18 px ring; active = `accent` ring +
  8 px dot and a glow; done = filled `accent` + check, text
  `fg-dim`; failed = `error` cross, struck through. Display only — the state is announced by the text.
- **CoreTracker** — HUD quest tracker. `title`, `text`, `distance`, `icon` (`map-marker`), `tone`
  (`warning`), `objectives` (rendered as CoreObjectives) · default · — · `core-tracker core-tone-<tone>` +
  `__rail __pin __body __title __text __distance __objectives` · a `--color-hud` card, radius 4,
  `--shadow-ui-sm`, a rail column with the tone pin and a hairline running down out of it and fading beside the
  copy, title display 700 18 px uppercase, text sans 15 px `fg-dim`, distance row with its own
  pin. Click-through.
- **CoreCompass** — heading strip. `heading` (0–360, anything else wrapped), `width` (560), `fov` (270 — the
  field of view of mockup 2, which puts W, N and E on the band at once), `labels: 'all'|'cardinal'` (`cardinal`
  = only N/E/S/W between bare ticks, as the mockup), `markers: [{ heading, icon?, tone?, label? }]`,
  `showBearing` (`042` under the band) · — · — · `core-compass` + `__band __strip __marks
  __tick __label __markers __marker __marker-label __needle __bearing` · a 30 px band fading out at both ends
  (`-webkit-mask-image` — Chromium 103 has no unprefixed one),
  ticks every 15°, cardinals display 700 15 px and the intercardinals 10 px, an `accent` triangle overhanging
  the top edge marks the centre. The strip is built ONCE over −180…540° (every marker repeated a turn either
  side, so a wrap-around never pops) and two `v-memo` layers freeze it: a heading update is one
  `transform: translateX()` and no allocation.

- **CoreInteractionDot** — the world interaction marker: a dot that says "you can interact here" and, when the
  player looks at it, becomes the key to press. `focused` (false), `keys` (`'E'`), `label`, `icon`, `description`,
  `progress` (0–1 hold, CoreKey's bar), `disabled` (locked / out of reach), `tone` (`accent`), `size:
  'sm'|'md'|'lg'` (dot 10 / 14 / 18 px, cap sm / md / lg), `x`, `y` (CSS px — both given ⇒ the root is absolutely
  positioned at that point, else a 0 × 0 anchor the caller places), `side: 'right'|'left'` (which way the band
  opens), `pulse` (true), `options: [{ keys, label, icon?, disabled? }]` (extra actions under the main band) ·
  default (replaces the band) · — · `core-interaction-dot core-interaction-dot--<size> --<side> core-tone-<tone>
  is-focused is-disabled has-progress is-pulse` + `__anchor __dot __ring __pulse __cap __band __icon __label
  __description __options __option` · click-through. Idle: a 14 px white ring around a 6 px core with a dark
  halo, a slow `core-ping` ring in the tone while `pulse`. Focused: the ring collapses while a solid CoreKey
  scales in on the SAME anchor and the band (icon · label · description, `--color-hud`, dissolving like
  CorePrompt's) slides out to the side; disabled + focused shows an outline cap with a `lock` glyph. The shell
  mounts it from `worldprompts:set` (§6.7); a page may compose it directly.
- **CoreHudTile** — the slanted dark HUD tile next to the vitals (§39: the mic tile). `icon` (`hud-mic`), `active`
  (false → `fg` ring + soft glow), `dimmed` (false → glyph at 40 %), `label` (a11y name), `unit` · — · — ·
  `core-hudtile is-active is-dimmed` + `__shape __icon` · click-through; 2.25 × 2.05 em in the vital's unit
  system, `skewX(-20deg)`, `--color-hud-tile`, hairline `--color-border`, the glyph upright and centred (§39.3).
#### Feedback (`css/feedback.css`)

- **CoreAlert** — inline banner. `tone` (`info`), `title`, `text`, `icon` (auto by tone; `icon=""` drops it),
  `variant: 'soft'|'outline'` (`soft`), `dismissible` · default, `actions` · `dismiss` · `core-alert
  core-tone-<tone> core-alert--<tone> core-alert--<variant>` + `__icon __body __title __text __actions __close`
  · tone
  10 % fill (*outline*: a `panel-sunken` well behind the same frame), tone 35 % border, 3 px tone bar on the
  left, title display 600 14 px uppercase, text 14 px `fg-dim`.
- **CoreShard** — the centre-screen banner (GTA's WASTED / MISSION PASSED; the shell's `shard:show`). `title`,
  `subtitle`, `variant: 'wasted'|'success'|'info'` (`info`; not `style` — Vue normalises a `style` prop away)
  · — · — · `core-shard core-shard--<variant> core-tone-<danger|success|accent>` + `__band __title __subtitle`
  · a full-bleed band (ink 74 % fading to nothing at both screen edges) with a tinted hairline top and bottom,
  the title in the display voice (clamp 38–74 px, 0.07 em, tinted), the subtitle in the eyebrow voice;
  click-through, no position of its own (the shell parks it at 24 vh).
- **CoreToast** — notification card. `tone` (`info`), `title`, `message`, `icon` (auto by tone), `count`
  (`×3`; under 2 hides the pill), `progress` (0–1 life bar; omit it and there is no bar),
  `dismissible`, `blur` · default · `dismiss` · `core-toast core-tone-<tone> core-toast--<tone>` + `__bar
  __main __icon __body __title __message __count __close __life __lifefill` · 340 px, panel fill, hairline,
  radius 4, `--shadow-ui-sm`, 3 px tone bar down the left, 20 px tone icon, title display 700 13 px uppercase
  0.12 em in the tone, message sans
  14 px `fg`. Click-through — only the ✕ takes the mouse, so a stack of toasts can never swallow a click.
- **CoreDialog** — modal. `v-model:open`, `title`, `subtitle`, `icon`, `tone` (`accent`), `size:
  'sm'|'md'|'lg'|'xl'` (360 / 460 / 640 / 860), `closable` (true: ✕, Escape, backdrop click), `persistent`
  (blocks Escape and the backdrop; the ✕ and the footer still work), `escape` (true; `false` registers no
  escape layer — the shell's modals leave Escape to the store), `trap` (true; `false` = no focus trap, the
  caller owns focus), `role` (`dialog` | `alertdialog`), `backdrop` (true), `blur` (true), `teleport` (true)
  · default, `header`, `footer` · `update:open`, `close`
  (reason: `escape` | `backdrop` | `button`) · backdrop `core-backdrop core-backdrop--clear`, panel
  `core-dialog core-tone-<tone> core-dialog--<size>` + `__header __icontile __titles __title __subtitle __close
  __body __footer` ·
  panel fill + sheen, hairline, radius 6, `--shadow-ui-lg`, 2 px fading tone line on the top edge; optional
  40 px icon
  tile (tone 16 %); title display 700 22 px uppercase; body sans 15 px `fg-dim` and scrolling; footer black
  22 %, hairline top,
  buttons right, gap 10. Focus moves in on open (first `[autofocus]`, else the first focusable), Tab is
  trapped, focus returns on close. Enter `core-pop`, leave fade. One wrapper does three jobs: the scrim, a
  click-through centring layer (`backdrop: false`) and nothing at all (`teleport: false` as well), so the panel
  markup exists exactly once. `inheritAttrs: false` — the caller's attributes land on the panel.
- **CoreDrawer** — side sheet. `v-model:open`, `side: 'right'|'left'`, `width` (420), `title`, `subtitle`,
  `closable`, `backdrop` (true), `blur` (true), `teleport` (true) · default, `header`, `footer` ·
  `update:open`, `close` (reason) · `core-drawer core-tone-accent core-drawer--<side>` + the same `__header
  __titles __title __subtitle __close __body __footer` parts as CoreDialog · full height against its edge, no
  radius, the same fill, top line, focus trap and Escape layer; it has no `tone` prop, so the coral line is
  pinned to the accent tone class. It enters with the base.css slide that travels towards its own side
  (`core-slide-left` comes in from the right).
- **CorePopover** — anchored floating panel. `v-model:open`, `placement` (`bottom-start`), `offset` (8),
  `trigger: 'click'|'hover'|'manual'`, `matchWidth`, `blur` · `trigger` ({ open, toggle }), default ·
  `update:open` · exposes `toggle/open/close` · `core-popover__anchor` (an inline-flex span, because
  useFloating needs a real rect) + `core-popover core-popover--<resolved placement>` · `--color-panel-popup`,
  `border-strong`, radius 4, `--shadow-ui`, padding 12, max-width 420. Hover keeps a 120 ms grace so the
  pointer can cross the `offset` gap; an outside click closes anything but `trigger="manual"`.
- **CoreContextMenu** — right-click menu. `v-model:open`, `position: { x, y }` (viewport px), `items:
  [{ value, label, icon?, kbd?, danger?, disabled?, separator? }]` · `item` ({ item, active }) · `select`
  (item), `update:open` · `core-contextmenu` + `__item is-active is-danger is-disabled`, `__icon __label __kbd
  __sep` ·
  `--color-panel-popup`, `border-strong`, radius 4, rows 34 px display 600 14 px uppercase 0.06 em, active =
  `accent-soft` + a 2 px inset bar (hover and the roving cursor are the SAME state — never two highlights),
  danger rows in `error`; placed against a zero-size rect with the kit's flip-then-clamp, so a menu opened in a
  corner stays on screen; the panel takes focus on open and ↑/↓ (skipping separators like disabled rows),
  Home/End, Enter/Space and Escape drive it; a window blur, scroll or resize dismisses it.
- **CoreTooltip** — `text`, `placement` (`top`), `delay` (350 ms; focus shows it at once), `disabled` ·
  default (the trigger),
  `content` (rich: item tooltips) · — · `core-tooltip__anchor` + `core-tooltip core-tooltip--rich
  core-tooltip--<resolved placement>` · ink 96 %, `border-strong`, radius 4, 13 px, max-width 260; rich content
  padding 12, max-width 280. Never takes the mouse, and it does NOT register an escape layer (§37.4): Escape
  and any pointer-down dismiss it without stopping the event for whatever is under it.

### 37.6 The shell is kit only (`ui/src/shell/`, 2026-09-18 — Liam: "remove all the old components, we only use kit")

The Lua-driven built-ins (§6.10, §21, §30.3) live in `ui/src/shell/` and are **compositions of kit components**:
a shell widget holds store bindings, the behaviour the protocol needs (keyboard rules, focus, timers, the
progress bar's seeded width transition, the chat's IME/byte-clamp logic) and layout utilities for placement —
and draws nothing itself: no colours, borders, radii or backgrounds outside the kit. The old
`ui/src/components/` folder no longer exists. Kit components are imported by path inside the shell (never
resolved through global registration), and the store, `bridge.js`, `coreui.js`, `plugins.js`, `gameblur.js`,
`chat.js` and `PageHost.vue` are unchanged.

| widget | composed from |
|---|---|
| `Hud` | **§39**: the bottom strip — CoreHudTile (mic: `talking` → `active`, `muted` → `hud-mic-off` + `dimmed`) · CoreVital health · CoreVital armour, the slotted `stats:set` entries as their sub bars; placed by `hud.anchor`, sized by `--core-hud-unit` |
| `StatsBars` | `CorePanel variant="hud"` · one inline CoreProgress per stat WITHOUT a HUD slot (§39.4; vital tone, warning/danger thresholds) — empty with the default config |
| `Notifications` | TransitionGroup of CoreToast (tone = type, `count`) |
| `Shard` | CoreShard (a kit component: the full-bleed band, `style` wasted/success/info), keyed by `seq` |
| `TextUI` | CorePrompt (`key` → cap, `text` → label) in the four `pos-*` placements |
| `WorldPrompts` | one CoreInteractionDot per projected interaction (the `worldprompts:set` items of §6.7), placed at `x * innerWidth` / `y * innerHeight`, band side by screen half |
| `Progress` | `CorePanel variant="hud"` · CoreKeyHint (cancel) · CoreProgress whose exposed `fillEl` carries the seeded transition |
| `KeyHints` | CoreKeyHints (the store's `{ key, label }` items) |
| `Spinner` | `CorePanel variant="hud"` · CoreSpinner |
| `Menu` | CoreDialog (`escape: false`, `trap: false` — the store owns Escape and the widget owns focus) · CoreMenu `sm` (`keyboard: false`, `rowAttrs` puts `data-index`/`role` on the rows; `item.icon` is a registry name, `item.glyph` a text glyph) · CoreKeyHints footer |
| `InputDialog` | the same dialog · CoreField around CoreInput (text/number) / CoreSelect / CoreCheckbox · CoreButton footer; hooks `[data-field]`, `[data-error]`, `[data-role]` on the kit tags |
| `AlertDialog` | the same dialog (`role="alertdialog"`) · CoreButton secondary + primary |
| `Chat` | composer = `core-inputbox` classes around the raw `<input>` the byte clamp needs · CoreButton ghost channel · CorePanel solid suggestion/argument panels with `core-menu__item` rows · CoreKeyHints footer; the feed keeps its text shadow |

Additive kit props that came out of it: CoreDialog `escape`, `trap`, `role`; CoreMenu `keyboard`, `rowAttrs`,
`item.glyph`; CoreProgress exposes `fillEl`; CoreShard is new. The legacy bare-class aliases (`.core-list`,
`.core-item`, `.core-modal`, element-level `.core-input`/`.core-select`) stay in the partials only for the
plugin pages that predate the kit (inventory, charcreator, trucking) and are deleted with their migration.

### 37.7 Stories, tests, docs

- **Storybook**: `Kit/Foundations/{Tokens,Icon}` (colours, type, the icon registry), then one
  `Kit/<Group>/<Name>` file per component — several carry the pair they document, so the titles are:
  *Actions*: Button, Icon Button, Key & Key Hint, Key Hints, Prompt & Prompt Group · *Surfaces*: Panel, Card,
  Background, Screen, Heading, Divider & Dash, Brand & Tagline · *Navigation*: Tabs, Menu, Chips, Stepper ·
  *Forms*: Field, Input & Textarea, Number Input, Select, Checkbox, Radio & Radio Group, Switch, Slider,
  Swatches · *Data*: Progress, Ring, Stat Bar, Stat Row, Spinner & Skeleton, Badge & Tag,
  Avatar & Player Chip, Table, Key Value, Empty · *Game*: Slot & Grid, Hotbar, List & List Item,
  Objective & Tracker, Compass · *Feedback*: Alert, Toast, Dialog, Drawer, Popover, Context Menu, Tooltip.
  Each has a `Playground` (controls) and a `Gallery` story (a scene SFC in `stories/kit/scenes/` — the shipped
  bundle has no runtime compiler, so scenes are compiled SFCs or `h()`), and
  `Kit/Showcase/{MainMenu,Hud,Inventory,Map}`:
  the four mockups rebuilt from kit components only (the completeness proof; art in `stories/kit/assets/`,
  Storybook-only, never in `html/`). `storySort` puts `Kit` after `Built-ins`, Foundations and Showcase first.
  Every gallery scene is built from
  `scenes/KitStage.vue` (`title`, `description`, `width` (1100), `center`, `padded`; the page frame) and
  `scenes/KitSection.vue` (`label`, `layout: 'row'|'column'|'grid'`, `columns`, `gap`, `note`; one labelled
  group). Both turn ligatures off, or Barlow draws the `--` of every token name in the prose as a dash.
- **Dev harness**: `ui/kit-preview.html?scene=<SceneName>&bg=game|keyart|menu|ink|none` (Vite dev server only —
  the production build's single input stays `index.html`; Vite binds **localhost**, not 127.0.0.1) mounts one
  scene with the kit installed, the way implementers and reviewers screenshot a component next to the mockup.
  No `scene` lists every scene it found,
  a failed import is drawn on the page in red, and `&scroll=page` swaps the shell's `fixed inset-0` root for a
  growing one so `agent-browser screenshot --full` catches a tall gallery instead of stopping at the first
  viewport. `node ui/tests/kit-compile-check.mjs <files…>` (no arguments: `ui/src/kit` and
  `ui/src/stories/kit`) parses and `compileScript`s every SFC with
  `@vue/compiler-sfc`, syntax-checks the JS, and lints CSS for the Chromium 103
  list of §37.4 plus brace balance and well-formed comments — the parallel-safe check, because `npm run build`
  empties `html/`. Nothing in that file may be spelled the way a Tailwind class is: Tailwind scans `ui/`,
  so a literal needle would generate the very declarations the rule forbids.
- **`ui/tests/kit-regression.js`** (agent-browser, like the shell suite, against the built `html/`): every
  catalogue name is in `CoreUI.kit.components` and mounts without a Vue warning; the interactive contracts
  (button click/disabled/loading, checkbox/radio/switch/slider/number/stepper/chips/tabs/menu `v-model`,
  select open → arrows → Enter → Escape-closes-the-popup-not-the-page, dialog focus trap + escape layering,
  context menu clamping, tooltip show/hide, slot grid selection); the bundled fonts resolve
  (`document.fonts.check`); no kit CSS rule uses a Chromium-103-unsafe feature (the suite greps the built
  `app.css` for `color-mix(` outside `@supports`, `:has(`, `translate:`, `rotate:`, `scale:`, the banned filter).
- **Docs**: README "Design system" (tokens, the tag list, a page example, re-theming, adding icons),
  `stories/docs/DesignSystem.mdx`, AGENTS §2/§3/§4/§5, the plugin template page and `core_example`'s page
  rebuilt on the kit. No Lua API changes, so `types/core.lua` is untouched.

---

## 38. Runtime UI platform — resource-owned frontends in the one CEF (2026-09-18, Liam: "a real FiveM frontend platform")

Until now core compiled every plugin page INTO its own bundle (`ui/src/plugins.js`, §7.4): changing the
inventory page meant rebuilding core, and a resource core had never seen could not bring a UI. §38 replaces
that coupling and nothing else: there is still exactly ONE `ui_page` (core's), ONE Vue, ONE kit, ONE focus
manager — but every resource owns, builds, ships and restarts its own frontend module, and core loads it at
runtime. **§38 supersedes** §7.1 ("plain JavaScript (no TypeScript)" — the infrastructure is TypeScript now),
§7.4 (build-time pages, the `script`/`style` URL loader — both removed; the `window.CoreUI` surface and the
props-identity rule stay), the focus paragraph of §6.10 (→ §38.9) and the "NUI messages ≤ 10/s" line of §9
(→ §38.10). Everything else in §6.10, §21, §31, §32 and §37 stays in force.

### 38.1 What FiveM guarantees (verified in the CitizenFX source, master `0d8a2a6f7`, 2026-09-07)

| fact | source |
|---|---|
| `https://cfx-nui-<resource>/<path>` is served for EVERY resource, with or without a `ui_page` (factories are registered before the `ui_page` check, once per start) | `nui-resources/src/ResourceUI.cpp:38-55`, `ResourceScriptingComponent.cpp:149-154` |
| the factory is registered on every existing AND future request context — a resource first started while core runs is served inside core's live frame | `nui-core/src/NUIInitialize.cpp:1389-1401` |
| responses carry `access-control-allow-origin: *`, `cache-control: no-cache, must-revalidate`, no validators; `?query` and `#hash` are erased before the file is opened; `js`/`mjs` → `application/javascript`; the CEF also runs with `disable-web-security` | `nui-core/src/NUISchemeHandler.cpp:92-199,341+`, `NUIApp.cpp:169-232` |
| only files packed for the client are reachable (`files {}`), a `client_script` that is not also a `file` is served as garbage, and the WHOLE vfs path `resources:/<res>/<path>` is cut at 255 chars | `ResourceUI.cpp:289-338`, `NUISchemeHandler.cpp:124-127` |
| `restart <res>` re-globs `files {}` against the disk on every start (a NEW file name under an existing glob ships without `refresh`); manifest ENTRIES and new resource folders need `refresh` | `citizen-server-impl/src/ResourceFilesComponent.cpp:506,643-685`, `ServerResourceList.cpp:184` |
| a restart destroys the client's `fx::Resource`, re-downloads the content-addressed `resource.rpf`, mounts it, starts it and queues `onClientResourceStart` for the next tick; a plain `stop` keeps serving the last files | `citizen-legacy-net-resources/src/ResourceNetBindings.cpp:143-182,598-620`, `ResourceEventComponent.cpp:77` |
| `LoadResourceFile(other, path)` and `GetResourceMetadata(other, key, i)` work on the client for any started resource | `citizen-scripting-core/src/MetadataScriptFunctions.cpp:169-175` |
| a NUI callback's `cb` may be called any time later — the POST is simply held, there is no timeout; a body that is not JSON is dropped without a response; a POST to a stopped resource hangs forever | `nui-resources/src/RPCSchemeHandler.cpp:233-236`, `ResourceUICallbacks.cpp:74-101` |
| `SendNUIMessage` = 2 JSON encodes + 2 parses + UTF-16 conversion + IPC + structured clone per message; all `ui_page`s are iframes of one root browser; NUI focus is ONE global flag | `scheduler.lua:807`, `ResourceUIScripting.cpp:55-88,351-394`, `CefOverlay.cpp:298-323`, `root.html` |
| CEF is Chromium 103.0.5060.141 (dynamic `import()`, cascade layers, `inert`: yes; import attributes, `:has()`, container queries: no) | `vendor/cef/cef_build_name.txt` |

Consequences baked into the design: an ES module is pinned in the document's module map by URL for the life
of core's page, so **content-hashed file names are load-bearing** (never re-import one URL and expect new
code); the manifest is read by Lua (`LoadResourceFile`), never fetched by the page, so no HTTP cache is
involved; every `fetch` of the shell has a timeout; payload size is the cost driver of the wire, so state is
patched, not re-sent (§38.10).

### 38.2 Terms and the four states

```
FiveM resource ──owns──► UI plugin (id == resource name, at most one)
                              └──owns──► pages · listeners · request handlers · pending requests
                                         focus entries · feed subscriptions · timers/rAF/observers made through the SDK
```

Four things that must never be confused (each has its own record):

| state | lives in | values | ends when |
|---|---|---|---|
| **module** (code in browser memory, keyed by URL) | shell `runtime/plugins.ts` | `loading` · `loaded` · `failed` | never (a page reload) |
| **plugin** (one activation of a module for a resource, keyed by resource + `generation`) | shell + `client/ui_plugins.lua` | `registered` · `loading` · `ready` · `failed` · `incompatible` | `plugin:unregister` |
| **resource active** | Lua only (`onClientResourceStart/Stop`) | started / stopped | resource stop |
| **page** (declared by Lua, resolved by the plugin, shown by Lua) | shell `runtime/pages.ts` + `client/ui.lua` | `declared` → `resolvable` → `open` → `mounted` | close / unregister |

A cached module is inert: stopping a resource disposes the plugin (scope, pages, CSS, requests) even though
its JS stays in the module map; starting it again re-activates the cached module when the entry URL is
unchanged, or imports the new URL when the build changed. **Module scope is for definitions only** — every side
effect belongs in `setup(ctx)` (runs per activation) or in a component (runs per mount).

### 38.3 What a plugin resource ships

```
inventory/
  fxmanifest.lua        dependency 'core'   files { 'ui/dist/**' }   core_ui 'ui/dist'
  ui/package.json       scripts: dev / build / typecheck; dependencies: the plugin's OWN runtime libs only
  ui/vite.config.ts     export default defineConfig({ plugins: [coreUI()] })        -- '@core/ui/vite'
  ui/tsconfig.json      { "extends": "@core/ui/tsconfig.plugin.json", "include": ["src", "dev"] }
  ui/.gitignore         .core-ui/ and node_modules/ (ui/dist is NOT ignored — it ships)
  ui/dev/host.ts        browser dev host entry: createDevHost({ id, plugin, mock, pages, props, open }) (never shipped)
  ui/dev/mock.ts        typed mock data + fake Lua for the dev host (never shipped)
  ui/index.html         OPTIONAL — `coreUI()` serves one from memory that loads /dev/host.ts
  ui/src/index.ts       export default defineUIPlugin({ pages: { … }, setup(ctx) { … } })
  ui/dist/              BUILD OUTPUT, committed like core/html (players download exactly this):
      manifest.json  plugin.<hash>.js  plugin.<hash>.css  chunks/<name>.<hash>.js  assets/<name>.<hash>.<ext>
```

`ui/dist/manifest.json` (generated, §38.13 validates it three times — build, server start, client register):

```json
{ "id": "inventory", "apiVersion": 1, "entry": "plugin.a81f3c.js", "css": ["plugin.982ca1.css"],
  "build": "a81f3c982c", "load": "eager", "preload": [], "pages": ["inventory", "inventory_hotbar"],
  "sdk": "1.0.0", "vue": "3.5.42" }
```

`id` MUST equal the resource name (one plugin per resource — ownership stays trivial and ids cannot collide).
`apiVersion` is the integer `API_VERSION` of the SDK the plugin was built with; the shell rejects any other
value with both numbers in the message (§38.12). `load: 'lazy'` defers the import to the first `page:open` of
one of the resource's pages. `pages` is what the build found statically in `defineUIPlugin({ pages })` —
tooling and diagnostics only; the authority for page ids, types and ownership remains Lua's
`Core.UI.registerPage` (§6.10). `preload` lists only the chunks the entry imports STATICALLY (transitively) —
a lazy page's chunk is never preloaded.

**Shared dependencies.** Vue exists once, inside core's bundle. The shell publishes
`globalThis.__CORE_UI_HOST__ = { apiVersion, vue, … }` (§38.6) before any plugin is imported; the SDK's Vite
plugin resolves the bare specifier `vue` — from plugin source AND from third-party packages bundled into the
plugin (`@lucide/vue`, `@dnd-kit/vue`), plus `@vue/runtime-dom`, `@vue/runtime-core`, `@vue/reactivity` — to a
virtual module that re-exports the host's namespace. No import map (one static map per document, nothing to
gain over a host object we need anyway), no Module Federation (its version negotiation solves a problem a
single-host platform does not have). `@core/ui` itself is a < 2 KB typed facade bundled into every plugin: it
holds no state and calls the host object at call time, so there is nothing to share and nothing to duplicate.
The kit needs no import at all — `<CoreButton>` resolves against core's app at render time (§37.3); the SDK
ships the `GlobalComponents` typings.

**CSS.** A plugin's stylesheet contains ONLY the Tailwind utilities its own sources use (generated against
core's tokens by reference, inside `@layer utilities`) plus its SFC `<style scoped>` blocks — no preflight, no
`:root` tokens, no kit classes (those stay global in core's `app.css`, and `@theme static` keeps every token
alive for them). Cascade layers are document-wide, core's sheet declares the layer order first, so a plugin
utility still beats a kit class. The sheet is a `<link>` owned by the plugin and removed with it. Unscoped
global selectors in plugin CSS are a bug (nothing can take them back cleanly) — prefix or scope them.
Three things the prototype proved are load-bearing: the tokens live in `ui/sdk/theme.css`, a file with NOTHING
but `@theme` blocks (Tailwind refuses `theme(reference)` on anything else; the `:root` recipes are host-only in
`ui/src/recipes.css`); core's own sheet starts with `@import "tailwindcss" source(none)` plus explicit
`@source` lines (automatic detection walks up to the workspace root and would quietly compile plugin utilities
back into core); token utilities come out as `var(--color-panel, <fallback>)`, so a server re-theme still wins.

### 38.4 Lua: discovery, registration, lifecycle (`client/ui_plugins.lua`, `shared/ui_manifest.lua`, `server/ui_plugins.lua`)

`core_ui '<dir>'` in a resource's fxmanifest is the opt-in (plain manifest metadata; `<dir>` is a relative folder,
charset `[%w%._%-/]`, no `..`, no leading `/`, no `://`). A resource without the key is never probed, so a
missing or unreadable manifest in a resource WITH the key is always a loud, one-line error naming the resource,
the file and the fix — never silence.

Client (`client/ui_plugins.lua`, inside core, loaded after `client/ui.lua`):

- State: `plugins[res] = { id, dir, base, manifest, generation, state, error?, ms? }`; `generations[res]`
  survives unregistration, so a restart is generation n+1.
- `discover(res)`: metadata key → `LoadResourceFile(res, dir .. '/manifest.json')` → `json.decode` (pcall) →
  `UIManifest.validate(res, table)` → `plugins[res]` → `plugin:register`. Triggers: `onClientResourceStart`
  (any resource but core), core's own start (loop over `GetNumResources()` / `GetResourceByFindIndex(i)`,
  `GetResourceState(name) == 'started'`), and `ui_ready` (every `plugin:register` is replayed BEFORE the
  `page:register`s).
- `onResourceStop(res)`: answer the resource's pending requests with `resource_stopped`, drop its request
  handlers and feed channels, `plugins[res] = nil`, `plugin:unregister`. Its pages, modals and focus entries
  leave through the existing Registry sweep (`Registry.onOwnerStop('page', …)`), which runs on the same event.
- `base = 'https://cfx-nui-<res>/<dir>/'`. Dev override: §38.11.
- `ui_plugin { id, generation, state, error?, ms?, pages }` from the shell updates `plugins[res]` (stale
  generations are ignored), prints one `[core:ui]` line (`inventory ready in 38 ms (2 pages)` / the failure
  with its reason) and fires the hook `uiPluginReady(id)` or `uiPluginFailed(id, error)`.

`shared/ui_manifest.lua` — `UIManifest.API_VERSION = 1`, the pure `UIManifest.dirOk(dir)` (the `core_ui`
charset rule above, shared by both callers) and the pure `UIManifest.validate(resource, m, dir?) ->
ok, normalized|error, state?`, where `state` is `incompatible` or `failed` on a rejection and `dir` is only
needed for the 255-char budget below: `id == resource` (exact), integer `apiVersion` (mismatch → state `incompatible`, message
names both), `entry` `^[%w%._%-/]+%.m?js$`, `css` ≤ 8 × `^[%w%._%-/]+%.css$`, `build` string ≤ 64, `load` ∈
{`eager`, `lazy`} (default `eager`), `preload` ≤ 16 js paths, `pages` optional plain ids, no `..` anywhere, and
`#('resources:/' .. res .. '/' .. dir .. '/' .. file) < 255` for every file.

Server (`server/ui_plugins.lua`): on `onResourceStart` runs the same validator against the disk and
additionally checks that entry and css files exist, that a `file` glob covers `<dir>`, and that no
`client_script` glob can match inside `<dir>` (FiveM would serve those files as garbage). Errors go to the
server console, where a developer looks first. Nothing is sent to clients from here.

### 38.5 Wire protocol (additions; everything in §6.10 not listed here is unchanged)

Lua → NUI (`SendNUIMessage { action = … }`):

| action | fields | notes |
|---|---|---|
| `plugin:register` | `id, generation, base, manifest, dev?` | idempotent per (id, generation) |
| `plugin:unregister` | `id` | disposes the activation; the module stays cached |
| `page:register` | `id, type ('page'\|'overlay'\|'modal'), keepInput, owner` | `owner` (resource) is NEW; `script`/`style` are GONE |
| `page:patch` | `id, ops = { { p = 'slots.12', v = value }, … }` | NEW; an op without `v` deletes the key; applied in order |
| `page:event` | `id, event, data` | `id` is a page id OR a plugin channel (the resource name) |
| `page:request` | `id, rid, name, data` | NEW; the shell answers with `ui_response` |
| `feed` | `c = { [channel] = { key = value } }` | NEW; ≤ 1 per `Config.UI.FeedIntervalMs` |
| `focus` | `focused, stack = { { key, layer, id?, owner } … }` | `stack` is NEW (top last) |
| `dev:set` | `enabled, log, inspector, loadTimeoutMs` | NEW; on `ui_ready` and on change |
| `inspector:toggle` | — | NEW |

NUI → Lua (`RegisterNuiCallback`; every one answers `cb`):

| callback | fields | behaviour |
|---|---|---|
| `ui_request` | `c, n, d, t` | channel, name, payload, timeout ms. `cb` is HELD until the handler returns, the timeout fires or the owner stops. `{ ok = true, data }` or `{ ok = false, error = { code, message } }` |
| `ui_response` | `rid, ok, data \| error` | resolves a pending `Core.UI.request` |
| `ui_plugin` | `id, generation, state, error?, ms?, pages` | §38.4 |
| `ui_error` | `plugin?, page?, component?, message, stack?, info?` | client print, ≤ 5/s; a crashed focus-holding page has already been closed by the shell through `ui_close` |
| `ui_feed` | `channel, active` | first subscriber / last unsubscribe of a feed |

### 38.6 The shell runtime (`ui/src/runtime/*.ts`) and the host object

```
runtime/protocol.ts    every wire message as a discriminated union (action → payload), both directions
runtime/transport.ts   post() with timeout, onMessage(), request(), counters, swappable for a mock (setTransport)
runtime/scope.ts       createScope(): the disposable bag behind Scope (listen/timeout/interval/raf/onDispose)
runtime/plugins.ts     plugin registry + loader: states, module cache by URL, <link> management, apiVersion gate,
                       load timing, generation tokens (a restart during a load discards the stale result)
runtime/pages.ts       page records (Lua metadata + owner), component resolution (owner plugin → legacy map),
                       stable props (§7.4), applyPatch (deep in place | shallow copy-on-write), hooks, waiters
runtime/layers.ts      the mirrored focus stack, z-order, Escape routing, inert lower layers
runtime/feeds.ts       latest-value buffers → ONE requestAnimationFrame flush → shallowReactive targets; no idle loop
runtime/errors.ts      PluginBoundary (onErrorCaptured), attribution, ui_error reporting, recovery
runtime/host.ts        builds CoreUIHost, publishes globalThis.__CORE_UI_HOST__, keeps window.CoreUI (legacy) alive
runtime/inspector.ts   stats snapshot for shell/Inspector.vue (lazy chunk, dev only)
```

`CoreUIHost` (the ONLY contract between a plugin bundle and the shell; verbatim types in
`ui/sdk/src/contract.ts`, imported by both sides so the compiler proves the shell implements what the SDK
calls): `apiVersion`, `vue`, `dev`, `usePage(id?)`, `useNui(channel?)`, `useScope()`, `useFeed(channel?)`,
`hud`, `state`, `stats`, `lang`, `t()`, `notify()`, `playSound()`, `registerIcons()`.

**Loading a plugin** (`plugins.ts`): `plugin:register` → record `registered` → (eager: now; lazy: first
`page:open` of an owned page) → append `<link rel=stylesheet data-core-plugin=id>` per css + `modulepreload`
per preload entry → `import(base + entry)` → check `default.__coreUIPlugin === true` and `default.apiVersion
=== API_VERSION` → create the plugin scope → `setup(ctx)` inside try/catch → state `ready` → resolve page
components + waiters → `ui_plugin`. Any failure: state `failed`/`incompatible`, links removed, scope disposed,
one `console.error` with resource, URL, phase (`fetch`/`evaluate`/`validate`/`setup`) and the error, `ui_plugin`
with the message. Stylesheets and the entry module are requested in parallel; `setup` is synchronous (a returned
Promise is warned about and its rejection reported). A `page:open` that waits on a loading plugin waits on THAT promise (no fixed 5 s guess);
it gives up after `loadTimeoutMs` (8000) or immediately when the plugin failed, then posts the legacy
`ui_event { page, event = '__error', data = { error } }`, shows the toast and CLOSES the page (`ui_close`) so a
page that cannot render never holds the cursor. **Unregister**: run page `onClose` for open pages, unmount them,
dispose page scopes then the plugin scope (LIFO: `setup`'s disposer first), reject pending requests
(`plugin_disposed`), drop feed subscriptions, remove `<link>`s, forget the instance — the module record stays.
**Open-state is Lua's**: the shell never closes a page on its own because a plugin went away or came back — it
only unmounts the component. A newer activation that becomes `ready` re-mounts every page Lua still has open
(same props, fresh page scope, the new definition's `onOpen`); one that fails sends those pages through the
failure path above, which is the only place the shell asks Lua to close (`ui_close`). `onOpen` runs once per
open cycle even when `page:open` arrived before the plugin was ready.

**Vue performance rules of the runtime**: components and plugin definitions are `markRaw`; closed pages are
unmounted (zero work) unless the page asks for `keepAlive` — honoured on the exclusive page layer only (an
overlay is cheap, a modal is meant to be fresh): such a page is DEACTIVATED through Vue's `<KeepAlive :max="3">`
and re-activated with its state on the next open, its hooks still fire per open/close, and the cache dies with
the plugin activation that filled it; page props are deep-reactive by default (precise
triggers for patches) or `shallowReactive` with copy-on-write patches when the page says `reactivity:
'shallow'`; feeds are `shallowReactive`; nothing in the runtime runs a timer, observer or rAF while idle.

### 38.7 The SDK (`ui/sdk`, npm workspace package `@core/ui`)

```
ui/sdk/package.json            name '@core/ui'; exports: '.', './contract', './vite', './dev', './theme.css', './reference.css',
                               './tsconfig.plugin.json', './client', './package.json'
ui/sdk/src/contract.ts         types + API_VERSION + HOST_GLOBAL (no runtime code, no enums — Node type-stripping safe)
ui/sdk/src/index.ts            the facade: defineUIPlugin, definePage, usePage, useNui, useScope, useFeed, useHud, usePlayerState,
                               useStats, t, notify, playSound, registerIcons, NuiError + every type
ui/sdk/src/client.d.ts         '*.vue' shim + GlobalComponents for the 62 kit tags (generated by ui/scripts/gen-kit-types.mjs)
ui/sdk/vite/index.mjs          coreUI(options?) — §38.13
ui/sdk/src/dev/*.ts            createDevHost(), createMockTransport() — §38.11
ui/sdk/theme.css               THE token file (`@theme static` only) — core's styles.css imports it, plugin builds reference it
ui/sdk/reference.css           what an SFC `<style>` block names to use `@apply`: `@reference "@core/ui/reference.css";` (emits nothing)
ui/sdk/templates/              reference copies of index.html / dev/host.ts / dev/mock.ts for authors; no code reads them —
                               the scaffold that `scripts/new-plugin.sh` copies is `templates/plugin/`
```

```ts
import { defineUIPlugin, definePage, usePage, useNui } from '@core/ui'

interface InventoryProps { items: InventoryItem[]; maxWeight: number }
interface InventoryEvents { moveItem: { from: number; to: number; amount: number } }
interface InventoryRpc { split: { req: { slot: number; amount: number }; res: { ok: boolean } } }

export default defineUIPlugin({
  pages: {
    inventory: definePage<InventoryProps>({ component: () => import('./Page.vue'), onOpen(page) { … } }),
    inventory_hotbar: HotbarOverlay,
  },
  setup(ctx) { ctx.nui.on('sync', applySync); ctx.scope.listen(window, 'blur', cancelDrag) },
})

// inside Page.vue
const page = usePage<InventoryProps, InventoryEvents>()     // no id: the page being rendered
const nui = useNui<InventoryRpc>()
page.emit('moveItem', { from: 1, to: 2, amount: 5 })        // fire and forget
const res = await nui.invoke('split', { slot: 3, amount: 2 })   // request/response, rejects with NuiError
```

`defineUIPlugin`/`definePage` are pure (they run at module evaluation); every other export resolves the host
lazily and throws a clear error outside the shell. Generics stay one level deep: a props interface, an event
map, an rpc map — nothing is inferred across the Lua boundary.

**Lifecycle, formally** (hooks exist only where a plugin can act on them):

| moment | who | hook |
|---|---|---|
| module evaluated (once per URL) | browser | — (definitions only) |
| plugin activated (per resource start) | `plugins.ts` | `setup(ctx)`; its return value is the disposer |
| page opened / re-opened | `pages.ts` | `onOpen(page)` then the component mounts (or is re-activated) |
| props changed by `open`/`update`/`patch` while open | `pages.ts` | `onUpdate(page, changedTopLevelKeys)` |
| page closed | `pages.ts` | component unmounts (or deactivates), then `onClose(page)` |
| plugin deactivated (resource stop / restart / re-register) | `plugins.ts` | page `onClose`s, scopes disposed, `setup`'s disposer |

### 38.8 Transport: four kinds of traffic

| kind | NUI → Lua | Lua → NUI | guarantees |
|---|---|---|---|
| **event** (fire and forget) | `page.emit` / `nui.emit` → `ui_event` → `TriggerEvent('core:ui:<channel>:<event>')` → `Core.UI.on` | `Core.UI.send(channel, event, data)` → `page:event` → `page.on` / `nui.on` | none; listeners die with their scope |
| **request** | `nui.invoke(name, data, { timeoutMs, signal })` → `ui_request` (held `cb`) → `Core.UI.onRequest(name, fn)` | `Core.UI.request(channel, name, data?, timeoutMs?)` → `page:request` → `nui.handle(name, fn)` → `ui_response` | an id, a timeout on BOTH sides, a typed error (`NuiErrorCode`), rejected when the owner stops (`resource_stopped` / `plugin_disposed`) |
| **state** | — | `Core.UI.open` (snapshot) · `Core.UI.update` / `Core.UI.patch` (increments) · `Core.UI.feed` (telemetry) | §38.10 |
| **lifecycle** | `ui_ready`, `ui_plugin`, `ui_error`, `ui_feed`, `ui_close` | `plugin:*`, `page:register/unregister/open/close`, `focus`, `shell:visible`, `dev:set` | framework only |

`Core.UI.onRequest(name, fn)` is a proxy call: the handler crosses as a callable table (§3 of AGENTS.md),
is stored under the CALLER's channel and tracked by `Core.Registry` (kind `uirpc`). Dispatch: types → payload
bound → handler lookup (`no_handler`) → `pcall(fn, data)` in the callback's own coroutine (a handler may
`Core.Callback.await` the server) → `cb`. A result that cannot be encoded answers `bad_result`; an error
answers `handler_error` with the message. `post()` in the shell never hangs: every fetch has an
`AbortController` timeout (default 10 s, requests `t + 500 ms`), a non-JSON or failed response rejects with
`transport`. Simple notifications stay events — nothing is turned into a request that does not need an answer.

### 38.9 Focus and layers (one owner: core)

FiveM's NUI focus is one global flag and only a resource with a frame can set it, so plugins never touch
`SetNuiFocus`, the cursor, `keepInput` or z-index. `client/ui.lua` replaces its three booleans with a **focus
stack** — same observable behaviour as §6.10, plus plugin modals:

| layer (rank) | entry key | who | cursor | input |
|---|---|---|---|---|
| `hud` (0) | — | overlays (`type = 'overlay'`) and core's HUD widgets | never | never (not in the stack) |
| `chat` (1) | `chat` | CEF chat input (§23) | no | keyboard only; removed the moment any higher entry appears (as today) |
| `page` (2) | `page:<id>` | THE exclusive page (`type = 'page'`); opening another replaces it | yes | `keepInput` of the page |
| `modal` (3) | `modal:<id>` | plugin pages of `type = 'modal'` — NEW; any number, stacked in open order | yes | `keepInput` of the modal |
| `system` (4) | `system:<kind>` | built-in menu / input / alert (one at a time, as today) | yes | never keepInput |

Top entry = highest rank, then most recent; it alone decides `SetNuiFocus(true, top.cursor)` +
`SetNuiFocusKeepInput(top.keepInput)`; an empty stack releases both. Natives are called only when the derived
triple changes. Closing the top entry hands focus to the one below — inventory → confirm modal → closed →
inventory again, with the inventory's `keepInput` restored. Every removal path pops entries: `UI.close`,
`UI.unregisterPage`, the Registry owner sweep (resource stop), the §31 hidden transition (closes system, modals
and the page), the `ui_ready` reset, core's own stop. The 500 ms watchdog keeps its rule: it releases focus
core holds while the stack is empty and never touches focus core did not take. New protection: a focus-holding
page whose plugin failed or whose component crashed is closed by the shell (`ui_close`), so a broken page
cannot trap the cursor.

The shell mirrors the stack (`focus { stack }`) in `runtime/layers.ts`: z-order `hud` 10 < `page` 20 <
`modal` 30 (+ index) < `system` 50 < `#core-overlays` (kit popups) < inspector; while a modal is open every
lower focusable layer gets the `inert` attribute (Chromium 102+), the top one does not. Escape goes to: kit
escape layers (§37, unchanged capturing listener) → system modal → top plugin modal → page.

### 38.10 State: snapshot, patches, feeds

Per message FiveM pays two JSON encodes, two parses, a UTF-16 conversion, an IPC hop and a structured clone —
cost is proportional to payload size, so the framework makes the small message the easy one:

```lua
Core.UI.open('inventory', { slots = all, maxWeight = 120 })        -- snapshot, once
Core.UI.patch('inventory', 'slots.12', slot)                        -- one slot; nil deletes the key
Core.UI.update('inventory', { weight = 84.5, maxWeight = 130 })     -- shallow merge of top-level keys
Core.UI.feed({ speed = 132, rpm = 0.71, gear = 4 })                 -- telemetry, channel = calling resource
```

- `update`/`patch` queue per page and flush once on the next tick (`SetTimeout(0)`) as ONE `page:patch`; any
  other message for the same page (`open`, `close`, `send`, `request`, `unregisterPage`) flushes that queue
  first, so a page never sees an event before the state change that preceded it in Lua. Core applies the same
  ops to its replay copy (`pages[id].props`), so a shell reload (`ui_ready`) restores CURRENT state.
- **A path addresses the Lua table that was passed to `open` — Lua's view, 1-based** (review 2026-09-18: the
  first draft used the page's 0-based view; `Core.UI.patch('inv', 'slots.' .. slot, v)` with a Lua slot number
  would then silently hit the neighbour). Both sides apply the same two rules, so the live page and core's
  replay copy can never drift apart:
  **R1 list element** — the container is a list (Lua: a sequence `#t > 0` or an empty table; JS: an `Array`)
  and the segment is an integer `n` with `1 ≤ n ≤ length + 1`: Lua writes `t[n]`, the shell writes `arr[n - 1]`
  (`length + 1` appends; deleting the last element shrinks the list).
  **R2 map key** — everything else: Lua writes the existing integer key `t[n]` when there is one, otherwise the
  string key; the shell writes the property. An EMPTY JS array that receives a map key is first replaced by `{}`
  in its parent (an empty Lua table is both, JSON had to pick one). A non-empty list that receives an
  out-of-range index, or a delete in its middle, is a hole: both sides still apply it as a map key / `nil`, and
  log a dev warning — send such a list whole with `update`. Collections addressed by id are therefore best
  keyed by STRINGS (`slots = { ['12'] = … }`), lists stay lists.
  Max depth 8, segment charset `[%w_%-]`, ≤ 64 ops per flush (more → one `page:open` snapshot instead).
- `update`/`patch` on a page that is not open (no page, overlay or modal of that id is showing) do nothing and
  return `false` without a log line: a producer may push blindly, the wire stays silent, and the next `open`
  carries fresh props anyway. Values are whatever `open` accepts (boolean, number, string, table) — they come
  from trusted Lua, so they are type-checked but not size-bounded; only `feed` values stay bounded.
- In the shell a patch mutates the deep-reactive props in place (only the dependants of that leaf re-render) or,
  for `reactivity: 'shallow'` pages, copies along the path and re-assigns the top-level key. The props object
  itself is never replaced (§7.4).
- `feed`: latest value per key wins in Lua, one `feed` message per `Config.UI.FeedIntervalMs` (default 50) for ALL
  channels and only while something changed; in the shell the message lands in a buffer, ONE
  `requestAnimationFrame` per frame copies the buffers into `shallowReactive` objects (`useFeed<T>()`), and a
  250 ms timer covers a throttled rAF. `Core.UI.isFeedActive(channel?)` is true while a mounted component reads
  that feed (`ui_feed`), so a producer loop can sleep when nobody looks. Interaction-critical traffic (`open`,
  `close`, `focus`, events, requests, results) is never delayed.
- Budget (replaces the §9 line): idle = 0 messages/s; with feeds ≤ 20 messages/s total; `hud:set` (100 ms),
  `stats:set`/`state:set` (250 ms) and the notify queue keep their own coalescing.

### 38.11 Development workflow

1. **Browser, no game (the default loop).** `cd inventory/ui && npm run dev` — the plugin's `index.html` calls
   `createDevHost({ id, plugin, mock })` from `@core/ui/dev`: the REAL shell (core's `ui/src`, resolved
   through the workspace) mounted in the plugin's own Vite server with a mock transport. One Vite graph → one
   Vue (no host shim in this mode) → native HMR for the plugin AND the shell. `mock` is typed: initial pages/props, `onRequest(name, fn)`
   fakes for `nui.invoke`, `emitToPage`, `patch`, `feed`, and `restart()` which replays
   `plugin:unregister` → `plugin:register` (generation + 1) to prove the plugin's cleanup. The same mock
   transport backs Storybook stories and the unit tests.
2. **In game, plugin-only rebuild.** `npm run build` (or `build -- --watch`) in the plugin, then
   `restart inventory`: new hash → new URL → new code, no core rebuild, no core restart, no NUI reload.
3. **In game, dev server (opt-in).** `npm run dev:game` (`vite --mode game`: the attached mode — `vue` is the
   host shim here, also inside the dep optimizer) plus `Config.UI.Dev.Enabled = true` and
   `/uidev inventory http://localhost:5173` make core register the plugin with `dev = { origin }`: the shell
   imports `<origin>/@vite/client` and `<origin>/src/index.ts` instead of the manifest entry. `coreUI()`
   configures the dev server for it (CORS, `server.origin`, `hmr`, `strictPort`, `fs.allow`). With a production shell a hot
   update re-activates the plugin (props survive — they belong to the shell); a shell built with
   `npm run build:dev` keeps Vue's HMR runtime, so SFC edits patch in place. Only `localhost` is supported
   (secure-context rules; a second machine forwards the port). Production never reads `Config.UI.Dev`.

### 38.12 Errors, isolation, compatibility

- Every page/overlay/modal instance renders inside `PluginBoundary` (`onErrorCaptured` → `false`): the instance is
  replaced by nothing (production) or a kit-styled report (dev), the error is logged ONCE with
  `{ resource, page, component, info, message, stack }`, posted as `ui_error`, toasted, and a focus-holding
  page is closed. The next `page:open` remounts it. `setup`, hooks, event listeners and request handlers run in
  try/catch with the same attribution; `window.onerror`/`unhandledrejection` attribute by stack URL
  (`cfx-nui-<resource>`). Nothing is swallowed silently. One realm means a plugin that blocks the thread still
  blocks the shell — that is the price of one Vue/one CEF, and the inspector's long-task list names the culprit.
- `apiVersion` gate twice (manifest in Lua, definition in the shell). Version text: `inventory was built for
  core UI API 2, this core provides 1 — rebuild the plugin with this core's @core/ui or update core`.
- `window.CoreUI` stays (tests, stories, old pages): `Vue`, `registerPage(id, component)` (legacy component map,
  used when the owner has no plugin), `usePage`, `emit`, `on`, `close`, `post`, `hud`, `state`, `stats`,
  `minimap`, `lang`, `t`, `playSound`, `notify`, `whenRegistered`, `kit`, `gameBlur`. A `CoreUI.on` made inside
  `setup` or a component is scoped like the SDK's; one made at module scope is never cleaned up and logs a dev
  warning.

### 38.13 Build tooling and validation (`@core/ui/vite`: `coreUI(options?)`)

One plugin, no other config: Vue SFC + Tailwind plugins, `build.target 'chrome103'`, ES module entry
`src/index.{ts,js}` → `dist/plugin.[hash].js`, `cssCodeSplit: false` → `dist/plugin.[hash].css`,
`chunks/[name].[hash].js`, `assets/[name].[hash][extname]`, `base: './'` (assets resolve against the plugin's
own origin), `emptyOutDir` (stale hashes never ship), `preserveEntrySignatures: 'strict'` (Vite's app build
otherwise drops the entry's `export default`), the virtual `vue` module, the injected utilities-only CSS entry
(a REAL generated file, `<plugin>/ui/.core-ui/entry.css` — Tailwind resolves `@import`/`@source` against its
folder), a per-plugin `cacheDir`, the dev-server setup of §38.11 and a deterministic `manifest.json` (emitted
by an `enforce: 'post'` plugin — the stylesheet does not exist earlier). It FAILS the build, naming the resource, when:
the folder is not `<resource>/ui`, `defineUIPlugin` is missing from the entry, a page id is not a plain id or
appears twice, an output path would exceed the 255-char vfs limit, the emitted CSS uses a Chromium-103-banned
feature (the §37 lint list) or the SDK's `API_VERSION` differs from the one in `contract.ts`; it WARNS when
a banned CSS feature only shows up inside a JS string literal (bundled third-party code passes through that
heuristic, so it must not make a plugin unbuildable), when
`fxmanifest.lua` lacks `core_ui` / a `files` glob covering `ui/dist` or has a `client_script` glob that could
match it. `ui/scripts/check-plugins.mjs` (workspace level, run by `scripts/check.sh` and CI): duplicate plugin
ids, duplicate page ids across resources, a `dist` older than its `src`, manifests that do not validate.
Workspace root: `npm run build:ui` builds core and every plugin; a single plugin builds alone in ~1 s.

### 38.14 Inspector (dev only)

`/uiinspect` (or `Config.UI.Dev.Inspector`) → `inspector:toggle` → the shell lazy-loads `assets/inspector.js`
(not fetched otherwise): resources and plugin states with generation/build/load ms, module cache, pages
(declared/open/mounted, owner), the focus stack, per-scope listener/timer/rAF counts, pending requests,
messages/s and bytes/s per action (byte counting runs only while the panel is open), feed rates, long tasks
(`PerformanceObserver`), the last 50 errors. With `dev.log` the console shows the lifecycle in one grep-able
format: `[UI] inventory registered (gen 3, build a81f3c)` · `[UI] inventory loading plugin.a81f3c.js` ·
`[UI] inventory ready in 38 ms (2 pages)` · `[UI] focus → page:inventory` · `[UI] inventory stopped — cleaned
2 pages, 5 listeners, 1 pending request`. Production cost: integer counters.

### 38.15 Tests and benchmarks

| suite | runs | covers |
|---|---|---|
| `ui/tests/unit/**/*.test.ts` + `ui/sdk/tests/*.test.mjs` (`node --test` with GLOBS — a directory argument finds nothing on Node 22; type stripping, so relative imports carry `.ts`) | offline | manifest validation, plugin state machine with a fake importer (load, fail, incompatible, stale generation, re-activation of a cached module), scopes, request timeouts/abort/owner stop, patch ops (deep + shallow), feed coalescing with a fake rAF, layer stack |
| `tests/client_ui_tests.lua` (new client stubs for `SendNUIMessage`, `RegisterNuiCallback`, focus natives) | offline | focus stack (nesting, owner sweep, hidden transition, `ui_ready`), discovery + manifest errors, `ui_request` dispatch/timeout/owner stop, patch queue ordering + replay copy, feed coalescing |
| `ui/tests/runtime-regression.js` on `ui/tests/nui-serve.mjs` (one ORIGIN per resource, FiveM's exact headers, query stripping, `files {}` allow-list) with fixture plugins built by `ui/tests/build-fixtures.mjs` | agent-browser | cross-origin load, hot deploy of an unknown plugin, restart with a new build (new code runs, old listeners gone, shell boot id unchanged), same-build restart (cached module re-activated), lazy load, CSS link add/remove + utility-beats-kit-class, page waiting on a loading plugin, failure modes (404 entry, throwing entry, throwing `setup`, wrong `apiVersion`, crashing page → siblings alive, focus released), request cleanup on unregister, modal layering + Escape order, feeds |
| `shell-regression.js`, `kit-regression.js`, Storybook play functions | agent-browser | unchanged behaviour (the `script:` URL check becomes a plugin-load check) |
| `ui/tests/bench.mjs` → `ui/tests/BENCH.md` | agent-browser | shell startup + JS bytes before/after (baseline = the last monolithic `html/`), plugin load latency cold/warm, page open latency, snapshot vs patch for a 200-slot inventory (bytes + apply time, deep vs shallow), feed at 1 kHz in → renders/s out, idle CPU with 10 registered plugins |

### 38.16 Migration

`ui/src/plugins.js` and the `@source "../../../*/ui/src/…"` line are deleted; `core/html` shrinks to the shell
and the kit. inventory, charcreator, trucking, core_example and `templates/plugin` get `vite.config.ts`,
`package.json` scripts, the `defineUIPlugin` entry, `core_ui` + `files` in the manifest and a built `ui/dist`;
side effects at module scope (inventory's store subscriptions and window listeners) move into `setup(ctx)`.
`Core.UI.registerPage(id, { script, style })` logs an error pointing here. Their Lua is otherwise untouched —
`registerPage`/`open`/`send`/`on` keep their signatures.

---

## 39. The vitals HUD — mic tile, HEALTH and ARMOR plates, food and drink bars (2026-09-19, Liam's mockup)

Liam's mockup (`DesignMockups`-style AI image, 2048 × 682) replaces the top-right HUD plate of §7.2 / §21 / the
`Hud` + `StatsBars` rows of §37.6. **This section overrides them.** The HUD is ONE horizontal strip:

```
 ╱▔▔▔▔╱  ╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔╱  ╱▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔╱
╱ mic ╱  ╱  ♥  HEALTH        ╱  ╱  ⛨  ARMOR         ╱      plate  = health / armour (0–100 %)
▔▔▔▔▔▔  ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔  ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔       — the cut —
        ╱▂▂▂▂▂▂▂▂▂▂▂▂▂▂▒▒▒▒╱  ╱▂▂▂▂▂▂▂▂▂▂▂▂▂▒▒▒▒▒╱        bar    = food / drink (the stat in that slot)
               🍔                     ☕
```

Liam's rulings on the mockup (it is AI generated and its geometry is not self-consistent): each vital is **one
parallelogram** whose bottom slice is cut off and used as the food / drink progress bar; the two parallelograms
are **exactly the same size**; the red and blue end caps of the image are **removed**; **every slanted edge —
the sides, the progress edges of plate and bar — has the same angle**; everything else that "makes no sense"
is normalised (equal gaps, equal heights, centred content, point-symmetric corners). Colours, type, glyphs,
proportions and the cut are the mockup's, measured.

### 39.1 Geometry (one unit system)

Every length is in **`em`, and `1em` = 100 px of the mockup**. The unit is the font size of the component root:
`font-size: var(--core-hud-unit, 24px)`. **24 px is the default** — Liam's rulings on the rendered size: the
first build (30 px, viewport-scaled, ≈ 440 px wide) was "way too huge, it must be like 200 px wide max"; the 13 px
build that followed (≈ 200 px) "looks great but … was way too small, make it like 365". 24 px ⇒ the strip is
≈ 351 × 76 px of layout, ≈ 369 px of ink with the skew overhang. The unit is FIXED px like the rest of the shell
(rail 268 px, progress 340 px), not viewport-relative; `Config.Hud.Scale` is the one knob. Nothing in the two components is written in px except
`max(1px, …)` floors on hairlines.

| measure | value |
|---|---|
| slant | `skewX(-20deg)` on the `__shape` wrapper (top leans right); content is un-skewed with `skewX(20deg)` about the SHAPE's centre line, so icon and label stand upright and exactly where the layout puts them |
| vital | shape 6 × 2.05 em = plate 1.57 + cut 0.18 + bar 0.30; the component's BOX is 6 × 3.17 em, because it contains the sub glyph under the bar (so a caller that places the strip by its bottom edge places the glyphs, not the bars); without a sub stat (`--solo`) shape and box are 6 × 1.57 em |
| tile | 2.25 × 2.05 em (the vital's height; 1.57 em next to `--solo` vitals is the caller's business: `height` follows `--core-hudtile-h`) |
| gap between strip items | 0.19 em (the 0.18 em cut seen across a 20° edge: 0.18 / cos 20°) — the shell's spacing, not the components' |
| corners | obtuse (top-left, bottom-right) `0.22em`; acute (top-right, bottom-left) `0.3em / 0.24em` (h / v — a sheared corner needs the longer horizontal radius to read as round); the four corners on the cut `0.035em`. Point-symmetric, so plate + bar read as one rounded parallelogram. `--solo` plates and the tile wear the four outer radii. |
| content | flex row, vertically centred in the plate, `padding-left: 0.9em`; icon box 1.2 em; label `margin-left: 0.62em` |
| label | `--font-display` 600, `0.757em` (cap height 0.53 em), uppercase, `line-height: 1`, no tracking, `transform: scaleX(1.25)` from its left edge — Barlow Condensed SemiBold widened to the mockup's letterforms (H = 0.35 em wide, stems 0.10 em) |
| sub icon | 0.92 em box, top at 2.25 em, horizontally centred on the BAR's visual centre: `left: calc(50% - 0.32em - 0.46em)` (the bar sits 0.875 em under the shape's centre line: 0.875 · tan 20° = 0.32 em to the left). The mockup draws it at 0.69 em; the design carries it a third larger — the proportion Liam approved on the compact 13 px build (where 0.69 em was a 9 px glyph with sub-pixel strokes), kept at 24 px so the look is the same and a `Scale = 0.5` strip still gets an ≈ 11 px glyph |
| shadow | `0 0.04em 0.18em rgba(0, 0, 0, 0.35)` on plate, bar and tile — white plates need an edge over a bright sky |

### 39.2 Tokens (added to `ui/sdk/theme.css`, §37.2)

```css
--color-plate: #f2f3f6;      --color-plate-lo: #eaedf1;   /* the white plate: a top → bottom gradient */
--color-plate-fg: #11171f;                                 /* label ink on the plate */
--color-plate-track: rgba(62, 66, 74, 0.92);               /* the drained part of plate and bar */
--color-plate-health: #c6022a;  --color-plate-armour: #0152b0;   /* glyph colours ON the white plate */
--color-plate-loss: #f00645;    --color-plate-gain: #0bfd69;     /* the change chunk of §39.3.1 (sampled from Liam's clips) */
--color-hud-tile: rgba(32, 36, 39, 0.85);                  /* the mic tile */
```

On the dark track a glyph wears the ordinary vital tone (`--tone`: `--color-health` / `--color-armour`, made for
dark ground); on the white fill it wears `--color-plate-<tone>` (health, armour) or `--tone` for any other tone.

### 39.3 Kit components (catalogue entries in §37.5)

**CoreVital** (`css/data-meters.css`) — props `label`, `icon`, `tone` (`health`, any METER_TONE), `value`, `max`
(100), `lowBelow` (25; 0 = off → the ICON pulses, nothing else moves), `subValue` (`null` = no bar: `--solo`),
`subMax` (100), `subIcon`, `subLabel` (a11y name of the bar), `subWarnBelow` (25), `subDangerBelow` (10), `unit`
(number px | CSS length → `--core-hud-unit` inline; omitted = inherit the variable). Structure:

```html
<div class="core-vital core-tone-health [core-vital--solo] [is-low] [is-sub-warning|is-sub-danger]"
     style="--core-vital-value: 0.81; --core-vital-sub: 0.8" role="progressbar" aria-label="Health" aria-valuenow…>
  <div class="core-vital__shape">
    <div class="core-vital__plate">                      <!-- track + hairline, overflow hidden, the radii -->
      <div class="core-vital__content">icon + label</div>            <!-- the look ON THE TRACK: fg label, --tone glyph -->
      <div class="core-vital__chunk" aria-hidden="true"></div>       <!-- §39.3.1: the loss / gain chunk, under the fill -->
      <div class="core-vital__fill" aria-hidden="true">              <!-- the white plate, clipped to the value -->
        <div class="core-vital__content">icon + label</div>          <!-- the same content, plate ink + plate tone -->
      </div>
    </div>
    <div class="core-vital__bar" role="progressbar" aria-label="…"><div class="core-vital__subchunk"></div><div class="core-vital__subfill"></div></div>
  </div>
  <CoreIcon class="core-vital__subicon" />
</div>
```

The fill is `clip-path: inset(0 calc((1 - var(--core-vital-value)) * 100%) 0 0)` **inside the skewed shape**: a
vertical clip edge in local space IS the parallelogram's angle on screen — no polygon, no second angle. The
content exists twice, pixel-identical, so a half-drained plate shows a two-tone label split along that edge.
`transition: clip-path 0.3s var(--ease-ui)`; values arrive as 0..1 custom properties, never as widths. Sub bar:
plate white while healthy, `--color-warning` under `subWarnBelow`, `--color-error` + pulsing icon under
`subDangerBelow` (fill and sub icon together). Hairline on plate and bar (visible on the drained part only, the
fill covers it): `inset 0 max(1px, 0.02em) 0 rgba(255,255,255,.3), inset 0 0 0 max(1px, 0.015em) rgba(255,255,255,.16)`.
Click-through, like every HUD read-out.

#### 39.3.1 The change effect — a red chunk on loss, a green chunk on gain (Liam's two reference clips)

Liam: "it has some cool effect, I also want that" — two 30 fps screen captures of a HUD in the same style, one
taking damage, one healing, measured frame by frame. Both are the SAME mechanism: the plate has two edges that
travel to the new value at different speeds, and the span between them is a solid colour that hides the label.

| | the edge that LEADS | the edge that LAGS | the chunk between them |
|---|---|---|---|
| **loss** | the white fill drops to the new value: `0.3s` ease-out (90 % of the way in ≈ 170 ms) | the chunk's right edge leaves the OLD value at once and arrives after `0.65s` ease-out | `--color-plate-loss` — "this is what you just lost", shrinking into the fill's edge |
| **gain** | the chunk's right edge races to the NEW value: `0.15s` ease-out | the white fill follows: `0.55s` ease-out | `--color-plate-gain` — "this is what you are getting", eaten from the left by the fill |

Implementation: one more layer, `core-vital__chunk`, between the track content and `__fill` — same box, no
content, `clip-path: inset(0 calc((1 - var(--core-vital-value)) * 100%) 0 0)`, i.e. the SAME target as the fill.
Only the transition durations differ, chosen by a direction class the component sets in the same render as the
new value: `is-loss` / `is-gain` (from a watcher comparing the new percentage with the previous one; the first
value never animates). Because the chunk lies UNDER the white fill, only the span between the two edges shows,
and it needs no geometry of its own — it inherits the parallelogram's angle like everything else in the shape.
The class is dropped 900 ms after the last change (longer than the longest transition), which makes the chunk
transparent again: two anti-aliased edges resting on the same line would otherwise leave a coloured fringe along
the fill's edge. A change arriving mid-animation simply retargets both edges with the new direction's timings.
The cut-off bar gets the same layer and classes (`__subchunk`, `is-sub-loss` / `is-sub-gain`) — eating flashes
green; a decay tick is sub-pixel and shows nothing. Both plates behave alike (armour damage is red too).

**CoreHudTile** (`css/game.css`) — the slanted dark tile. Props `icon` (`hud-mic`), `active` (false → a
`max(2px, 0.04em)` `fg` ring and a soft white glow: "you are transmitting"), `dimmed` (false → glyph at 40 %),
`label` (a11y), `unit`. `core-hudtile is-active is-dimmed` + `__shape __icon`; `--color-hud-tile`, hairline
`inset 0 0 0 max(1px, 0.025em) var(--color-border)`, glyph box 1.226 em centred and NOT skewed.

**Glyphs** (`kit/icons.js`, a hand-made group — the generator's MDI map does not know them): `hud-mic`,
`hud-mic-off` (capsule, holder arc, stem, foot — rebuilt from primitives; the muted twin is the same glyph
knocked out by a slash), `hud-heart`, `hud-shield` (traced from the mockup, mirrored), `hud-food`, `hud-drink`
(Lucide `hamburger` / `coffee`, ISC, strokes outlined to ONE filled path so CoreIcon needs no stroke mode).

### 39.4 Shell (`ui/src/shell/Hud.vue`, `StatsBars.vue`, `App.vue`)

`Hud` = the strip: `CoreHudTile` (only when `hud.talking !== null`) + `CoreVital` health (when `hud.health !==
null`) + `CoreVital` armour (when `hud.armour !== null`), in a flex row with `gap: 0.19em`, wrapped in the
`core-slide-up` transition on `hud.visible`. Labels: `t('hud_health')` / `t('hud_armour')` from core's locale
table (`store.locale.strings`, fallbacks `Health` / `Armor`); the tile's a11y name is `t('hud_voice')` /
`t('hud_voice_muted')`. Next to `--solo` plates the strip sets `--core-hudtile-h: 1.57em`, so the tile shrinks with
them. The sub bars are the `stats:set` entries whose
`slot` is `'health'` / `'armour'` (first by name when several claim a slot); `subIcon` = the entry's `icon`, else
`hud-food` / `hud-drink`. Hook classes for tests and stories: `.hud`, `.hud__tile`, `.hud__vital.is-health`,
`.hud__vital.is-armour`. Cash, bank, speed, street, zone, faction, name and server id are **no longer drawn** by
core — they stay in `store.hud` / `useHud()` for plugins (§38.6 unchanged apart from the additions below).

Placement (`hud.anchor`, from `Config.Hud.Anchor`): `'bottom-left'` (default) — a fixed 24 px from both edges; it
never reads the map rect, so the strip stays put whatever corner the map resource draws the minimap in (the
streamed `sf_minimap` cluster sits in a top corner, not in the vanilla bottom-left).
`'minimap'` — `left` = the minimap rect's right edge (`(x + w) · innerWidth`) + 0.6 em (≈ 14 px at the
default unit), `bottom` = `max(24px, (1 − (y + h)) · innerHeight)`, i.e. the glyphs' bottom edge sits on
the minimap's bottom edge; while no rect has arrived the vanilla 16:9 rect at the default safe zone,
`{ x: 0.025, y: 0.779, w: 0.141, h: 0.176 }`, is assumed. There is
deliberately no centre or right anchor: the bottom centre belongs to the progress bar and the text UI, the bottom
right to the key hints and the spinner. On viewports narrower than 1700 px the strip's right end reaches the
progress panel (at 1600 × 900 already with the default unit), so `Progress.vue` lifts itself to `bottom: 22vh` there (above the text UI) — a classic
`@media (max-width: 1699px)`, never the range syntax Chromium 103 cannot parse. Unit: `--core-hud-unit = 24px ·
hud.scale` (`Config.Hud.Scale`, 0.5–2.0 ⇒ 12–48 px, a ≈ 175–700 px strip).

`StatsBars` keeps its rail plate for every `stats:set` entry WITHOUT a slot, so a plugin's extra need still has a
home; with the default config it has no rows and renders nothing. The rail stays top-right (notifications).

### 39.5 Data: `hud:set`, `stats:set`, config, feed

- `hud:set` gains `talking: boolean`, `muted: boolean`, `anchor: string`, `scale: number` (`HUD_KEYS` in
  `client/ui.lua` and `store.js`; `HudState` in `contract.ts` gains `talking: boolean | null`, `muted: boolean`,
  `anchor: string`, `scale: number` — additive, no `API_VERSION` bump). `talking === null` = no voice feed = no tile.
- `stats:set` entries gain optional `slot: 'health' | 'armour'` and `icon: string` (`StatBar` in `contract.ts`).
  `Config.Stats.Defs.<name>.hud` is now `true` (a rail bar) | `'health'` | `'armour'` (the bar under that
  plate) | `false`; `icon` is a registry name. Defaults: `hunger = { …, hud = 'health', icon = 'hud-food' }`,
  `thirst = { …, hud = 'armour', icon = 'hud-drink' }`. `client/stats.lua` forwards `slot` / `icon`,
  `UI.stats.set` lets them through (sanitised, `slot` from the two literals only), `server/stats.lua` keeps
  `hud` as given when it is one of the four values.
- `Config.Hud = { ShowHealth = true, ShowArmour = true, ShowStats = true, ShowVoice = true, ShowSpeed = false,
  ShowStreet = false, Anchor = 'bottom-left', Scale = 1.0 }` (`Anchor`: `'bottom-left'` | `'minimap'`; `Scale`: 0.5–2.0; an
  unknown anchor or an out-of-range scale is DROPPED by `UI.hud.set`, never clamped — the shell keeps what it
  had). `ShowSpeed` / `ShowStreet` default to **false** now:
  core no longer draws them, so the feed no longer reads or sends them unless a server turns them on for a
  plugin that reads `useHud().speed/street/zone`.
- `client/hudfeed.lua`: the one thread now ticks at **100 ms** while the HUD is visible. Every tick reads
  `MumbleIsPlayerTalking(PlayerId())` (`ShowVoice`); every 250 ms health / armour (/ speed); every 1000 ms
  `MumbleIsConnected()` → `muted = not connected` (and street / zone when on). Only changed values are pushed,
  through `UI.hud.set` (100 ms coalescing, §6.10) — an idle, silent player sends nothing. BOOL returns are read as
  `v == true or v == 1` (§30.4). `anchor` / `scale` ride along with the one-per-shell `minimap` push. A voice
  resource that wants to own the tile sets `ShowVoice = false` and pushes `Core.UI.hud.set({ talking = …, muted = … })` itself.
- Locale: `hud_health`, `hud_armour`, `hud_voice`, `hud_voice_muted` in `locales/*.json`.

### 39.6 Tests, stories, docs

Kit: `Kit/Data/Vital` and `Kit/Game/Hud Tile` (playground + gallery scene each), kit-regression checks (mount,
`--core-vital-value` follows `value`, `--solo`, threshold classes, the tile's `is-active` / `is-dimmed`, the six
glyphs resolve). Shell: `Built-ins/HUD` and `Built-ins/Stats bars` stories rewritten, shell-regression section 7
(strip renders, plates follow `hud:set`, slot bars follow `stats:set`, the tile appears with `talking`, an
unslotted stat still gets a rail bar). Lua: `tests/client_ui_tests.lua` (`hud.set` lets the four new keys through
and drops wrong types; `stats.set` forwards `slot` / `icon`), `tests/server_tests.lua` (`hud` normalisation).
README (config keys, HUD paragraph, kit tag list, in-game checklist), `DesignSystem.mdx`, AGENTS §5 counts.
