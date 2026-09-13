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
Net.broadcast(name, ...)             -- TriggerClientEvent(name, -1, ...); never from a loop
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
   dirty ones. `playerDropped`: same refresh, `emitHook('playerDropped', src, charId)` **before** removal,
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
--          locked = false, persistent = false, bucket = nil }
Vehicles.delete(netId) -> bool
Vehicles.exists(netId) -> bool, Vehicles.getEntity(netId) -> entity|0
Vehicles.getInfo(netId) -> { netId, model, plate, ownerCharId, keys, locked, vehId, spawnedBy, createdAt } | nil
Vehicles.setLocked(netId, locked) -> bool          -- state 'locked' + SetVehicleDoorsLocked(veh, locked and 2 or 1) (RPC, best effort)
Vehicles.isLocked(netId) -> bool
Vehicles.giveKeys(netId, charId) / Vehicles.removeKeys(netId, charId) -> bool
Vehicles.hasKeys(src, netId) -> bool               -- owner or keys[charId]
Vehicles.setOwner(netId, charId|nil), Vehicles.getOwner(netId) -> charId|nil
Vehicles.getPlayerVehicles(src) -> array of netId  -- spawned vehicles owned by the player's charId
Vehicles.list() -> array of netId
-- persistence (collection 'vehicles': { id, ownerCharId, model, plate, props = {}, stored = false, position = {x,y,z,heading}, meta = {} })
Vehicles.persist(netId) -> vehId | nil             -- creates the record for a spawned vehicle, writes state vehId
Vehicles.getRecords(charId) -> array of records
Vehicles.getRecord(vehId) -> record | nil
Vehicles.spawnRecord(vehId, coords, heading, ownerSrc?) -> netId | nil, err   -- spawns from a record (props sent to ownerSrc's client), stored = false
Vehicles.store(netId) -> bool                      -- saves position/props (last known), deletes the entity, stored = true
Vehicles.saveProps(netId, props) -> bool           -- from the owner's client (§5), validated
Vehicles.deleteRecord(vehId) -> bool
```

`spawn`: hash the model, `CreateVehicleServerSetter(hash, type, x, y, z, heading)`, `0` → `nil, 'create_failed'`;
wait for `DoesEntityExist` up to `Config.Vehicles.SpawnTimeoutMs` (`Wait(50)` polling); plate =
`opts.plate` (validated `^[%w ]{1,8}$`) or `Config.Vehicles.PlatePrefix .. random 5 alnum` (unique among
spawned); `SetVehicleNumberPlateText`; state: `coreVeh = true`, `locked`, `owner`, `keys`, `plate`,
`vehId`; `SetEntityRoutingBucket` if `bucket`; `SetEntityOrphanMode(veh, 2)` when `persistent` or an owner is
set (otherwise leave default); track `spawned[netId]`; props → `TriggerClientEvent('core:client:applyVehicleProps',
ownerSrc, netId, props)` if `ownerSrc`; hook `vehicleSpawned (netId, info)`. `delete`: `DeleteEntity` + untrack +
hook `vehicleDeleted (netId)`. `onResourceStop`: delete every spawned vehicle (synchronous loop).
`entityRemoved` (AddEventHandler): untrack if it was ours.

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
`false` becomes `active`. On change: old → `onExit` + `Core.UI.textUI.hide()`; new → `onEnter` +
`Core.UI.textUI.show(key, label)`. The scan sleeps 1000 ms when no entry is within 60 m (cheap distance test
first). Key: `RegisterCommand('core_interact', fn, false)` + `RegisterKeyMapping('core_interact', 'Interact',
'keyboard', Config.Interactions.Key)`; the handler runs `onInteract(ctx)` (pcall) when `active` and enabled,
not focused (`IsNuiFocused`), and `cooldown` elapsed. **No per-frame loop.** Callbacks that come from another
resource are funcrefs — always `pcall` them.

### 6.8 `Core.Vehicles` client (`client/vehicles.lua`)

```lua
Vehicles.getClosest(coords?, radius = 5.0) -> veh|0, distance      -- GetGamePool('CVehicle') scan, on demand only
Vehicles.getCurrent() -> veh|0, Vehicles.isDriver() -> bool, Vehicles.getSeat() -> seat|nil
Vehicles.getNetId(veh) -> netId, Vehicles.fromNetId(netId, timeoutMs = 5000) -> veh|0   -- waits for NetworkDoesEntityExistWithNetworkId
Vehicles.getProps(veh) -> props, Vehicles.setProps(veh, props) -> bool   -- requests control first (NetworkRequestControlOfEntity, ≤ 1 s)
Vehicles.getPlate(veh) -> string (trimmed), Vehicles.getDisplayName(vehOrModel) -> string
Vehicles.hasKeys(veh) -> bool           -- Entity(veh).state: owner == my charId or keys[charId]; false if not a coreVeh
Vehicles.isLocked(veh) -> bool          -- state 'locked'
Vehicles.toggleLock(veh?) -> nil        -- veh or current/closest (≤ 8 m) with keys → Net.emit('core:server:vehicleLock', netId)
Vehicles.setEngine(veh, on), Vehicles.repair(veh), Vehicles.saveProps(veh)   -- saveProps → Net.emit('core:server:vehicleProps', netId, getProps(veh))
```

`props` (JSON-safe, every key optional): `model, plate, plateIndex, colorPrimary, colorSecondary, customPrimary =
{r,g,b}|false, customSecondary, pearlescentColor, wheelColor, interiorColor, dashboardColor, wheels, windowTint,
livery, livery2, xenonColor, neonEnabled = {b,b,b,b}, neonColor = {r,g,b}, tyreSmokeColor, extras = { [id] = bool },
mods = { [modType 0..49] = index }, modToggles = { [17,18,19,20,22] = bool }, modVariations?, engineHealth,
bodyHealth, tankHealth, fuelLevel, dirtLevel, burstTyres = { [wheel] = true }`. `setProps` calls `SetVehicleModKit(veh,
0)` first and applies only keys present.

Built-in behaviour: `AddStateBagChangeHandler('locked', nil, ...)` → only for entities with state `coreVeh` →
`SetVehicleDoorsLocked(veh, value and 2 or 1)` (+ on stream-in via `Core.Vehicles` checking `Entity(veh).state.locked`
when the player tries to enter: a 500 ms guard that only runs while `GetVehiclePedIsTryingToEnter(ped) ~= 0`).
Key `Config.Vehicles.LockKey` (`U`) via `Core.Keys.register` → `toggleLock()`.

### 6.9 `Core.Raycast` (`client/raycast.lua`)

```lua
Raycast.fromCamera(distance = 10.0, flags = -1, ignoreEntity = PlayerPedId()) -> hit:boolean, coords:vector3, normal:vector3, entity:integer
Raycast.between(from, to, flags = -1, ignoreEntity = 0) -> hit, coords, normal, entity
Raycast.getEntityInFront(distance = 5.0) -> entity|0, coords
```

Uses `GetGameplayCamCoord`, `GetGameplayCamRot(2)`, `Core.Math.rotationToDirection`,
`StartExpensiveSynchronousShapeTestLosProbe` + `GetShapeTestResult` (synchronous, no loop).

### 6.10 `Core.UI` (`client/ui.lua`) — the NUI bridge

State: `pages[id] = { owner, type, script, style, keepInput, registered = bool }`, `openPage = id|nil`
(exclusive, `type = 'page'`), `overlays[id] = true`, `pending = { [requestId] = promise }`, `nuiReady = bool`,
`notifyQueue`.

```lua
UI.registerPage(id, { type = 'page' | 'overlay', keepInput = false, script = nil, style = nil })
--   default: the page component is COMPILED INTO core's bundle (§7.4) and looked up by id; script/style are an
--   optional fallback (relative paths inside the CALLER's resource → 'https://cfx-nui-<owner>/<path>')
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
| `progress:start` / `progress:stop` | `id, label, duration, canCancel` / `id` |
| `menu:open` / `menu:close` | `id, title, items` / — |
| `input:open` / `input:close` | `id, title, fields, submit, cancel` / — |
| `alert:open` / `alert:close` | `id, title, message, confirm, cancel` / — |
| `hud:set` | partial of `{ visible, cash, bank, name, serverId, faction = { name, tag, color } | false }` |
| `page:register` / `page:unregister` | `id, type, script (URL), style (URL|null), keepInput` / `id` |
| `page:open` / `page:close` / `page:event` | `id, props` / `id` / `id, event, data` |
| `focus` | `focused` |

NUI → Lua (`RegisterNuiCallback`, every one calls `cb({})` or `cb({ ok = true })`):
`ui_ready {}` (NUI reloaded/loaded → set `nuiReady`, re-send every registered page + hud snapshot),
`ui_close { page }` (ESC or close button → `UI.close(page)`), `ui_event { page, event, data }` →
`TriggerEvent(('core:ui:%s:%s'):format(page, event), data)` (page/event validated as `'id'` strings, `data` ≤
16 KB json), `menu_result { id, value }`, `input_result { id, values }`, `alert_result { id, confirmed }`,
`progress_cancel { id }`, `progress_done { id }`. Results resolve the matching pending promise (unknown ids
ignored). Focus: exactly `SetNuiFocus(true, true)` when a `page` or a built-in modal (menu/input/alert) is
open, `SetNuiFocus(false, false)` the moment none is; `onResourceStop` releases focus and hides everything.
Notify throughput: queue, flushed at most `Config.UI.MaxNotifyPerSecond` per second (a 100 ms timer), extra
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

```
ui/index.html, ui/vite.config.js, ui/package.json
ui/src/main.js            creates the app, exposes window.Vue and window.CoreUI, mounts #app
ui/src/bridge.js          post(name, data) → fetch('https://' + resource + '/' + name) (JSON); dev shim when GetParentResourceName is missing; onMessage(action, fn) dispatcher for window 'message' events
ui/src/store.js           reactive state: notifications[], textui, progress, menu, input, alert, hud, pages{}, openPage, overlays{}
ui/src/coreui.js          window.CoreUI implementation (§7.4)
ui/src/App.vue            root: <Hud/> <TextUI/> <Progress/> <Notifications/> <PageHost/> <Menu/> <InputDialog/> <AlertDialog/>
ui/src/components/Notifications.vue, TextUI.vue, Progress.vue, Menu.vue, InputDialog.vue, AlertDialog.vue, Hud.vue, PageHost.vue
ui/src/styles.css         design tokens + base (dark glass panels, one accent colour, system font stack)
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
| | `plate`, `vehId` | strings (`vehId` only when persisted) |
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
| client | `uiReady` | — |
| client | `core:ui:<page>:<event>` (not under `hook:`) | `data` |

---

## 9. Performance budget

| loop | side | cadence | note |
|---|---|---|---|
| world scan | client | 500 ms | grid 3×3 cells, `#(pedCoords - coords)` only |
| world draw | client | 0 ms while `#visible > 0`, else 250 ms | markers + labels only |
| interactions scan | client | 300 ms near (≤ 60 m of any entry), 1000 ms far | `GetClosestObjectOfType` ≤ MaxModels per model-interaction |
| death watch | client | 1000 ms | `IsPedDeadOrDying` |
| entry guard (vehicle locks) | client | 500 ms only while `GetVehiclePedIsTryingToEnter ~= 0` | |
| NUI focus watchdog | client | 500 ms | |
| idle cam reset (§35) | client | 5000 ms | two natives; only while `Config.Camera.DisableIdleCam` |
| notify flush | client | 100 ms timer only while queue non-empty | |
| load request | client | 5000 ms until loaded | |
| autosave | server | `Config.Player.SaveIntervalMs` (5 min) | |
| DB flush | server | 5000 ms (only when dirty) | |
| invite sweep | server | 30 s | |

Targets: client idle **0.00–0.02 ms**; ≤ 10 visible markers/labels **< 0.06 ms**; NUI messages ≤ 10/s. Never:
`TriggerClientEvent(-1)` from a loop, per-frame `.state` reads, `GetGamePool` per frame, funcref calls per frame.

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
    Vehicles = { SpawnTimeoutMs = 5000, LockKey = 'U', LockDistance = 20.0, PlatePrefix = 'LS', MaxPropsBytes = 16384 },
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
'page', key = 'F5', description = 'Example page', onPress = function() Core.UI.open('core_example', { opened = GetGameTimer() }) end })`;
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
5. F5 → example page opens with cursor, ESC closes it and the cursor is gone; restart `core_example` while open → page closed, focus released.
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
        hunger = { min = 0, max = 100, default = 100, decayPerMinute = 0.4, thresholds = { 25, 10 }, hud = true },
        thirst = { min = 0, max = 100, default = 100, decayPerMinute = 0.6, thresholds = { 25, 10 }, hud = true },
    },
}
```

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
Audio.playFrontend(src, name, set) / Audio.playAt(coords, name, set, range?)  -- to src, or to every player within range (server iterates sessions; ≤ 20 targets)
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
`Hud = { ShowHealth = true, ShowArmour = true, ShowStats = true, ShowSpeed = true, ShowStreet = true }`.

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
