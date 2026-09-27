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

**Who the caller is (2026-09-26, §54 review F3).** The `caller` argument is a DECLARATION, not the truth: both
sides take the owner from `GetInvokingResource()` (CFX, apiset shared — the resource whose script runtime invoked the
export; the engine sets it for every cross-resource export call) and only CHECK the declared name against it. A call
whose declared name differs from the invoking resource is refused (`error`, plus one `Core.Log.warn` per
invoker/declared pair), so no resource can act under another one's name — release its key capture, drop its §31/§54
hide reason, close its page or remove its registrations. The honest proxy always declares `GetCurrentResourceName()`,
which IS the invoking resource. Without an invoking resource (the offline suites calling the export function
directly) the declared name stands; the test stubs model the engine (`exports.x:y()` sets `GetInvokingResource()` to
the calling VM for the duration of the call). Before this, the server silently replaced a mismatching name and the
client trusted it.

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

**Note (2026-09-26, admin build, review M1).** The caller is tracked PER COROUTINE on both sides (`server/api.lua`,
`client/api.lua`): `getCaller()` inside a coroutine is that coroutine's entry or `'core'`; the process-wide value is
only the main-thread fallback (resource load, offline suites). `setCaller`/`withCaller(owner, fn, ...)` write the
running coroutine's entry, and the `call` export dispatches through `withCaller`, so a thread core starts while a
plugin's yielding export call is parked stays core's. Tests: `tests/registry_caller_tests.lua` (26),
`tests/client_registry_caller_tests.lua` (31).

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

**Note (2026-09-26, admin build, R2-UI).** Refusals carry a reason: the response event is `(key, true, ...results)`
or `(key, false, reason)`, and every await form (`await`, `awaitTimeout`, `awaitClient`, `awaitClientTimeout`) returns
the handler's results or `nil, err` with err ∈ `'rate_limit'|'schema'|'cooldown'|'permission'|'timeout'|'error'`
('timeout' also = the asked player dropped; 'error' = handler error, no handler, invalid arguments, or an unknown reason
from the other side — a client cannot forge one). Rate-limited requests are now answered `'rate_limit'` (≤ 10 answers
per src and second; the rest still time out). Server registrations take `opts = { permission?, cooldownMs? }` (§44).
Tests: `tests/callback_tests.lua` (34).

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
per-frame cost. §54 adds `opts.whileCaptured` and `Core.Keys.capture/release/isCaptured` (key capture: a
press of another resource's binding is swallowed while a capture is held).

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

**Addition (2026-09-27, phase D runs D4 / D4+ — parked vehicles on Core.Scene, §55.21.4).** `server/vehicles_park.lua`
loads right after this file and takes its live maps and helpers once through the one-shot global `CoreVehiclesPark`.
- `Vehicles.park(netId | vehId) -> nodeId | nil, err` (persisted vehicles only; yields ≤ 1 s): the car becomes a
  PERSISTENT scene `vehicle` node owned by core — fields `{ model (the name when known, else the hash), props (the
  owner client's through the callback `core:vehicles:props`, else the cached / record props), plate, locked, vehId,
  vtype }`, the entity's pose and bucket, the class default authority (promote on proximity / enter / damage) — and
  the entity goes. A parked car's clone is demoted instead (refused with someone inside); a parked record answers its
  node; an out record without a live car parks at its saved position. Errors: `unavailable bad_target missing
  not_persisted no_record record_stored occupied busy gone no_entity bad_coords db` + Scene's.
- `Vehicles.getInfoByRecord(vehId) -> info | nil`: getInfo's fields (netId only while a car is live — a promoted
  parked car's clone included) + `parked` (node id), `stored`, `position`. `getInfo` also carries `parked` while the
  vehicle is the adopted clone of a parked car.
- Records gain `parked` (node id | false), `locked`, `keys`, `modelName` and `position.bucket`.
- Wrapped: `spawnRecord` on a parked record PROMOTES its node in place (coords ignored) and returns the clone's netId
  after a bounded wait (SpawnTimeoutMs + 6 s); `restoreRecord` on one answers `nil, 'parked'` (a boot restore never
  duplicates it); `store(netId | vehId)` also garages a parked node or a record with nothing in the world; `delete` of
  a clone removes its node (not while core stops); `deleteRecord` removes the node.
- Promotion of a core node naming a record: the clone is ADOPTED (the §8 bags, `spawned`, hook `vehicleSpawned`);
  demotion: props, pose, lock and keys into the record, hook `vehicleDeleted`; `saveProps` on a clone writes no
  `coreProps` bag (the node takes the props at the demotion).
- AutoPark (`Config.Vehicles.AutoPark = true`, `AutoParkIdleMs 30000`, `AutoParkRadius 50`, `AutoParkSweepMs 10000`):
  a sweep (only while persisted cars exist, 10 slices) parks a car at rest (< 0.1 m/s) for AutoParkIdleMs with
  nobody inside and nobody of its bucket within AutoParkRadius; ≤ 64 per sweep, one park worker re-checks each.
- The lock key on a parked car's LOCAL copy (no state bags): client/vehicles.lua sends its node id,
  `core:server:parkedLock(nodeId)` → schema → 500 ms → loaded → distance from the server's ped ≤ LockDistance → the
  node parks a record of the player's bucket → the record's virtual keys (item-key cars ignored silently) → the
  record's `locked` and the node field toggle.
- Boot: parked cars are persistent nodes (no spawn storm); a parked record whose node vanished is re-parked; a core
  vehicle node naming a record nobody parks is adopted by that record or removed. Core stop: every adopted clone
  hands its final pose to its node through `R.promote.beforeStop` BEFORE any clone is deleted.
- **Compatibility** (plugins, e.g. `vehicle_system`): netIds of persisted cars are NOT stable any more — key by
  `vehId`; `vehicleDeleted` fires at every park / demotion and `vehicleSpawned` at every promotion; a boot restore
  gets `'parked'`; AutoPark parks cars a plugin spawned and persisted; `list` / `getPlayerVehicles` / `getInRange`
  skip parked cars; a direct `DeleteEntity` on a clone makes the car reappear at its spot (use `delete` / `store`);
  entity state bags are lost at park.

**Addition (2026-09-27, final fix round FX1a / FX1b — review RV4–RV6).** `server/vehicles_fleet.lua` now holds AutoPark,
MaxParked and the boot / stop reconciliation (§55.21.4 final notes).
- `setLocked` / `giveKeys` / `removeKeys` / `setOwner` take a netId OR a vehId: a vehId acts on its live car, else on
  the record (and a parked node's `locked` field) — no promotion needed.
- Records gain `destroyed`: a wrecked clone leaves the record at its last saved state with `destroyed = true` (the node
  is removed); `restoreRecord` and `park` answer `'destroyed'`, the boot check skips it, `spawnRecord` brings it back
  and clears the mark; `getInfoByRecord(vehId).destroyed` tells. `adopt` refuses a scene clone (`'scene_clone'`).
- **Park at stop**: core's stop parks every live persisted car at its pose (instead of leaving it for a boot-time
  spawn); the **boot check** parks out-records that have neither a node nor a live car and retries a `'limit'` with
  backoff; `spawnRecord` answers `'already_spawned'` only while the record's car is live.
- **MaxParked** (`Config.Vehicles.MaxParked`, 20,000): past it the longest-unused parked car that is not promoted is
  garaged (node removed, `stored = true`) and the hook `vehicleAutoStored (vehId, 'max_parked')` fires.
- A read-back from a clone's owner changes only wear (`Core.Scene.mergeWear`); every props write re-imposes the
  record's plate; a live car parks through the promotion engine's hand-off (no blink for watchers).

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

**Note (2026-09-26, admin build, R2-15).** The staff commands follow §51's duty rule, write an audit row
`core.cmd.<name>` and echo to on-duty staff (not `admin:before`), check ranks themselves, and are not registered at all
with `Config.Admin.LegacyCommands = false`; `/weapon` and `/weapons` moved here from weapons.lua. Details: §51 notes.

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

**Addition (2026-09-27, scene build run A6).** `Vehicles.setPropsLocal(veh, props) -> bool`: the same apply body as
`setProps` (only the keys present, `SetVehicleModKit` first) with NO network-control request and no yield, so it runs
inside a creation frame — for LOCAL (non-networked) vehicles this client created itself, the `Core.Scene` vehicle
copies (§55.12). On a networked vehicle this client does not control, the calls only touch its local copy until the
owner syncs over it; use `setProps` there.

**Addition (2026-09-27, phase D run D4 / D4+).** The client answers the callback `core:vehicles:props (netId)` with
`getProps` of a `coreVeh` entity it controls (the network-id guard first; nil otherwise) — the server reads the props
before it parks a car (§4.6 notes). `toggleLock` on a parked car's LOCAL copy (no state bags) sends its scene node id
(`Core.Scene.idOf` / `get`, a vehicle node with `fields.vehId`) as `core:server:parkedLock`; the server decides.

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
| client | `hudHiddenChanged` | `hidden` — §54: the first `Core.UI.hideHud` reason arrived (`true`) / the last one went (`false`) |
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

**Note (2026-09-26, admin build, R2-9).** `Cron.remove(id)` is owner-checked like `Hooks.remove`: only the job's owner
or core removes it (`false` otherwise); the owner-stop sweep still removes a stopped plugin's jobs.

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

**Superseded (2026-09-27, phase D run D3) — attachments are Core.Scene nodes (§55.21.3).** The API and the storage
(`data.attachments`) stay; the `attachments` state bag is no longer written (the key stays reserved) and
client/remote.lua has no applier any more. Each entry is ONE scene `prop` node owned by core in the player's routing
bucket, spawned at the ped and attached to the player (`Scene.attach(id, { player = src }, { bone, offset, offrot =
rotation, rotOrder = 1 })`); every client near the player materialises the object on that ped and re-attaches it
when the ped changes. `add` validates `model` (a name `^[%w_%-]+$` ≤ 64 or an integer hash), `bone` (a tag 0..65535 or
a bone name, else 28422 = PH_R_Hand) and `offset` (each component ≤ 1000 m), keeps ≤ 12 entries per player, and
answers `nil, 'scene refused the prop (<code>)'` when the scene refuses it (the entry is not stored). Final round
(2026-09-27, RV4 F3): when the scene is FULL (`'limit'`) `add` stores the entry and returns its id — the node follows
by retry. Details in the §55.21.3 notes.

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

**Veto hook `chat:beforeMessage` (2026-09-26, admin build, W2-ADMIN-S2).** Before a player's message is delivered —
the default channel, the CEF `core:server:chat:send`, channel commands, `/s` and `/pm` — and after the `setFilter`
veto, core runs `Core.Hooks.run('chat:beforeMessage', { src, channel, text })` (§40 pipeline; `channel` is the channel
name, `'scream'` or `'pm'`). A veto (`return false, reason`) drops the message and sends the sender one system line
with the reason; a bare veto or a Hooks-internal code (`veto`, `reentrant`, `invalid_name`, `invalid_payload`,
`callback_*`, `filter_*`) shows "Your message was not sent." Hooks fail closed, so an erroring hook blocks the message
(the admin plugin's mute catches its own errors and fails open). `setFilter` is unchanged — one filter, not
owner-tracked, a throwing filter lets the message through — and when it vetoes, the hook is not asked. The admin
plugin's mute is built on the hook, not on `setFilter`.

**Order and delivery (2026-09-26, R2-4/R2-5).** `dispatch` runs sanitize → channel permission → cooldown → `setFilter`
→ `chat:beforeMessage` → the `chatMessage` observer → route, so a channel the sender may not use never reaches the
filters, hooks or observers and does not stamp the cooldown (`/s` and `/pm` have no channel permission). Global
channels (`ooc`, every `global = true` channel) and faction lines go out through `Core.Net.emitMany`, packed once —
a player-triggered line is never a -1 broadcast. `staffOnly` channels (and `/a`) reach the cached staff set
(`Core.Admin.staff()`) filtered by the channel permission. Join/leave lines follow `Config.Chat.JoinLeave`: `'staff'`
(default; the leaver is excluded), `'all'` (one broadcast per connect/drop, small servers) or `'off'`.
Tests: `tests/chat_hook_tests.lua` (52).

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

/* the world axes — X / Y / Z of a gizmo or a transform read-out (Blender's; admin editor, 2026-09-26) */
--color-axis-x: #ff3352;  --color-axis-y: #8bdc00;  --color-axis-z: #2890ff;

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
- **CorePagination** — page / cursor controls (§53). `v-model:page` (1-based, 1), `v-model:pageSize` (25),
  `pageCount` (`null` = unknown → the cursor pager), `hasNext` / `hasPrev` (`null` = derived from `pageCount` /
  `page > 1`), `total` (`null` hides the `1–25 of 312` read-out), `pageSizes` (`[25, 50, 100]`; `[]` hides the
  select), `sizeLabel` (`Rows:`), `siblings` (1), `size`, `disabled` · — · `update:page`, `update:pageSize`,
  `change` ({ page, pageSize }, once per move; a size change goes back to page 1) · `core-pagination
  core-pagination--<size> is-cursor is-disabled` + `__range __pages __btn __btn--prev __btn--next __page is-active
  __gap __current __size` · a wrapping row, space-between: read-out in the label voice `fg-faint` tabular, the
  pages centred, an inline sm CoreSelect right. Buttons are chip-shaped squares at `--core-page-h` (26 / 32 / 38),
  display 600 15 px (sm 13, lg 17) tabular `fg-dim`, hover white 6 % + `fg`, the current page `--core-grad-accent`
  with `on-accent` text; the gap `…` in `fg-faint`, and a gap that would hide one page shows that page instead.
  Numbered = first, last, the current page ± `siblings`; cursor mode prints `PAGE 3` between the arrows. It never
  fetches — the caller loads on `change`. Disabled dims the bar once (its buttons and select do not add theirs).

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
- **CoreCombobox** — the filterable select (§53). `v-model` (a value, or an array with `multiple`), `options`
  (strings or `{ value, label, description?, icon?, disabled? }`), `search` (`(query) => Option[] | Promise`;
  replaces the local filter), `debounce` (200 ms), `multiple`, `creatable`, `clearable`, `placeholder`
  (`Search…`), `size`, `maxHeight` (280), `virtualThreshold` (100), `emptyText` (`No matches.`), `invalid`,
  `disabled`, `id` · `option` ({ item, selected, active }) · `update:modelValue`, `create` (text), `open`,
  `close`, `focus`, `blur` · exposes `focus/open/close` · `core-combobox core-combobox--<size> is-open is-focused
  is-invalid is-disabled is-multiple is-loading` + `__box __tag __input __spinner __clear __chevron`, popup
  `core-combobox__popup is-virtual` > `__option is-active is-selected is-disabled is-create` + `__option-icon
  __option-body __option-label __option-desc __check __empty` · the box look (min-height `--core-box-h`, it wraps
  with `multiple`: the picks are sm removable CoreTags in the well); popup, options, active bar and check are
  CoreSelect's — the same selector lists. Focus stays in the input (`role="combobox"`, the list driven by
  aria-activedescendant, options prevent their mousedown). Local filter: label, value and description,
  case-insensitive. `search` is debounced and an answer older than the latest query is dropped; every option
  seen is remembered, so a picked value keeps its label. `creatable` puts `+ Create "…"` first when nothing
  matches exactly. Past `virtualThreshold` rows the list renders through CoreVirtualList (36 px rows, 54 with
  descriptions). ↑/↓ open and move (wrapping), Enter picks, Escape closes the list through the kit's layer,
  Tab closes, Backspace in an empty field drops the last pick; a single pick closes the list, a multiple pick
  keeps it open.
- **CoreVectorInput** — `{ x, y, z }` (§53). `v-model`, `step` (0.01), `precision` (`null` = from `step`),
  `min` / `max` (a number, or per axis `{ x, y, z }`; `null` = unbounded), `labels` (`['X', 'Y', 'Z']`),
  `axisColors` (true), `rotation` (the `°` suffix), `suffix`, `copyable` (true), `size` (`sm`), `invalid`,
  `disabled`, `id` · — · `update:modelValue`, `copy` (text), `paste` (vector) · exposes `copy/paste/parseVector`
  · `core-vector core-vector--<size> has-axis-colors is-disabled is-invalid` + `__cell __cell--x|y|z __axis
  __actions` · three CoreNumberInputs, each behind a 22 px axis cap fused to its left edge (radius 4 on the
  outer corners only), display 700 12 px; with `axisColors` the caps are `error` / `success` / `info` with ink
  text (the gizmo convention through tokens), else white 6 % + `fg-dim`; then ghost copy / paste icon buttons.
  Cells are `flex: 1 1 128px` and wrap one per row in a narrow column. Copy writes `x, y, z` at the shared
  precision to the browser clipboard (fire and forget) AND the kit's own; paste tries the browser clipboard
  for 250 ms (a permission prompt the off-screen CEF cannot show would hang it), then the kit's. Parses
  `1, 2, 3`, `vector3(…)`, `{ x = …, y = …, z = … }` and JSON; Ctrl+V of a whole vector into any field fills all
  three (the focused field is re-synced a tick later, §37.4's defineModel note). The size default is `sm`, not
  `md`: three steppers side by side.

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
- **CoreColorPicker** — hex field + swatches + channel sliders (§53). `v-model` (`'#RRGGBB'`, upper-case;
  `'#RRGGBBAA'` with `alpha` while the colour is translucent), `alpha`, `swatches` (strings or `{ value,
  label }`; a 16-colour palette by default, `[]` hides the row), `popover` (a box-look trigger opening the panel
  in a CorePopover), `size` (the trigger), `placeholder` (`No colour`), `invalid`, `disabled`, `id` · — ·
  `update:modelValue` · `core-colorpicker core-colorpicker--inline|popover core-colorpicker--<size> is-open
  is-invalid is-disabled has-alpha` + `__anchor __trigger __chip __chip-fill __value __chevron __frame __panel
  __top __preview __channels __channel __channel-label __range __range--alpha __channel-value` · never
  `<input type="color">` (an OS popup the off-screen CEF never shows). Panel 296 px column, gap 14: a 44 × 30
  preview chip + an sm CoreInput with a `#` prefix (commits live on a full 3/6/8-digit value, on Enter and on
  blur; a bad value marks the field and keeps the colour), sm CoreSwatches in 8 columns, one row per channel:
  label (display 700 12 px), a real range painted through `::-webkit-slider-*` whose 12 px track is the live
  gradient of its own channel (`--core-cp-track`, inline), the alpha track over an 8 px checkerboard, a
  10 × 20 `--color-key` thumb with a 5 px accent halo on hover/focus, the value display 600 13 px tabular.
  Chips carry the checkerboard too. Popover trigger: the box look, a 26 px chip, the hex in display 600 15 px
  0.06 em, a chevron that turns when open.
- **CoreSchemaForm** — a whole form from `Core.Schema.public(fields)` (§53 over §43). `v-model` (the values
  object; a missing key shows its `default` or a neutral value and is filled on the first write), `fields`,
  `errors` (the server map exactly as `Core.Schema.checkAll` returns it — `{ name = code }`, nested codes with
  their path in front, `{ list = '2.pos.min' }`; flat path keys `list.2.pos` work too; array rows count from 1),
  `resolvers` (`{ player | model | ref | faction | item: (query, field) => Option[] | Promise }`), `messages`
  (wording per code, `{min}`-style holes), `inline` (CoreField settings rows), `disabled`, `submitLabel` (`''` =
  no button), `busy` · `footer` ({ submit, errors }) · `submit` (values — only when the advisory client check
  passes), `invalid` (errors), `update:modelValue` · exposes `submit/validate` · `core-schemaform
  core-schemaform--inline is-disabled` + `__group has-title __group-title __object is-bare is-invalid __legend
  __desc __error __reason __templates __template __duration __array __array-row __array-index __array-item
  __array-empty __array-add __bare __footer __empty` · controls per type: boolean → CoreSwitch · integer /
  number / heading → CoreNumberInput (`unit` as suffix; heading 0–359.99 °) · string / password (and any
  `secret`) → CoreInput · text → CoreTextarea · reason → CoreTextarea (2 rows, counter) + sm template buttons ·
  enum → CoreSelect (≤ 8 options), CoreChips (`multiple`, ≤ 8) or CoreCombobox (> 8) · color → CoreColorPicker
  `popover` · duration → preset chips (15m 1h 1d 1w, + Perm with `allowPermanent`) + a free `2h 30m` field ·
  vector3 / rotation → CoreVectorInput (`world` → the §43 box) · model / player / ref / faction / item →
  CoreCombobox over the resolver (model `creatable`; no resolver: a text field, a digits-only server id for
  `player`) · array → numbered rows of the item field drawn bare, a remove button each (stops at `minItems`),
  Add (stops at `maxItems`) · object → a framed group (white 2 %, hairline, radius 4, label-voice legend).
  `hidden` fields are skipped, the rest ordered by `order` (stable; unordered last) under their `group` (eyebrow
  voice over a hairline, in order of first appearance), `visibleWhen` re-evaluated on every change, `readonly`
  disables the control. The client check is ADVISORY (required, bounds, step, lengths, options, items, colour
  form, duration bounds — mirroring lib/schema) and runs from the first submit on; `errors` always wins.
  Per-field renderer and helpers live in `ui/src/kit/schema/` (`SchemaField.vue`, `schema.js`) — outside
  `components/`, so they are not registered and not in this catalogue.

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
- **CoreTable** — `columns: [{ key, label, align?, width?, format?(value, row), sortable? }]`, `rows`, `rowKey`
  (`id`), `selectable`, `v-model:selected` (the ROW KEY, never the index — rows get re-sorted), `dense`,
  `stickyHeader`, `empty`, `sortable` (every column sorts unless it says `sortable: false`), `v-model:sortKey`
  (`null`), `v-model:sortDir` (`asc`), `loading`, `loadingRows` (5) · `cell-<key>` ({ row, value, column }),
  `empty` · `row-click`, `update:sort` ({ key, dir }) ·
  root `core-table__wrap core-scroll is-sticky is-loading` (the scroll box, so a caller's `max-height` lands on
  it) around `<table class="core-table core-table--dense is-selectable is-loading">` + `__th __th--<align>
  is-sortable is-sorted __sort __sort-icon __body __row __row--skeleton __cell __cell--<align> __empty
  __progress __progress-fill` · header label voice `fg-faint` 34 px (dense 30) over a hairline, rows 44 px
  (dense 36) with white 6 % hairlines, hover white 3 % while selectable, selected `accent-soft` + a 2 px inset
  bar on the first cell (a collapsed table discards an inset shadow put on the `<tr>`). The `<tbody>` is the tab
  stop: ↑/↓ and Home/End move the selection, Enter/Space re-fires `row-click`. Sorting (§53) is presentation
  only: a sortable header is a button (label + a `sort` glyph at 55 %, `arrow-up` / `arrow-down` in `accent`
  and the label in `fg` once sorted, `aria-sort` on the `<th>`); a new column starts `asc`, the sorted one
  flips; the table NEVER reorders `rows` — the caller (usually the server) does on `update:sort`. `loading`: a
  2 px `--core-grad-accent` sweep (`core-indeterminate`) sticky on the top edge that takes no room, rows at
  55 %, `aria-busy`; with no rows it draws `loadingRows` CoreSkeleton rows instead of the empty line.
- **CoreVirtualList** — fixed-row-height virtualised list (§53). `items`, `itemHeight` (36), `keyField`
  (`id`; the index when a row has none), `overscan` (6), `endThreshold` (4 rows), `role` (`list`; `listbox`,
  `presentation`, `none` — rows are `listitem`s only under `list`), `empty` · default ({ item, index }),
  `empty` · `range` ({ start, end }, when the rendered window changes), `reach-end` (once per list length,
  near the bottom — a cursor loader) · exposes `scrollToIndex(index, align = 'auto'|'start'|'center'|'end')`,
  `measure()` · `core-virtuallist core-scroll is-empty` + `__spacer __window __row __empty` · the ROOT is the
  scroll box (give it a `height` / `max-height`; without one it grows to the list and renders every row); a
  spacer as tall as every row keeps the scrollbar honest and the rendered rows (viewport + `overscan` each side)
  ride ONE `transform: translateY()` on the window; rows are exactly `itemHeight` and clip. The viewport comes
  from a ResizeObserver, the offset from a passive scroll listener; start/end are number computeds, so a
  scroll inside the same window re-renders nothing.
- **CoreTree** — nested rows with expand / collapse and selection (§53). `items` (`[{ id, label, icon?, badge?,
  description?, disabled?, children? }]`), `v-model` (the selected key, an array with `multiple`),
  `v-model:expanded` (open keys; uncontrolled when unbound), `keyField` (`id`, then `value`), `childrenField`
  (`children`), `multiple`, `dense`, `indent` (16 px), `overscan` (8), `disabled`, `empty` (`Nothing here.`),
  `label` (aria-label) · `icon` ({ node, open, depth }), `label` ({ node, depth }), `badge` ({ node }),
  `trailing` ({ node, depth, open, selected } — its clicks never select the row), `empty` · `select` (node),
  `toggle` (node, open), `activate` (node — double click) · `core-tree core-tree--dense is-disabled is-multiple`
  + `__list __row is-selected is-active is-open is-disabled has-children __twisty is-hidden __icon __label
  __badge __trailing __empty` · the visible rows are FLATTENED and rendered through CoreVirtualList (32 px, dense
  28), so a caller's `max-height` on the root makes it scroll and only the rows on screen exist. The root is
  the one tab stop (`role="tree"`, aria-activedescendant; rows are `treeitem`s with level / posinset / setsize /
  expanded / selected). Rows: sans 14 px (dense 13) `fg-dim`, indent per level, a 20 px twisty (chevron-right
  turned 90° by `transform` when open, hidden on leaves, toggles on click), icon `fg-faint` (`accent` when
  selected), ellipsised label, an 18 px white 6 % count badge, trailing actions; hover white 4 %; selected
  `accent` 16 % + a 2 px inset bar (the select list's language); the keyboard cursor is a 1 px accent 55 %
  ring shown only while the tree has focus. ↑/↓ move, → opens or steps into the first child, ← closes or steps
  out to the parent, Home/End jump, Enter selects, Space toggles in `multiple`; click selects, Ctrl/⌘-click
  toggles and Shift-click selects the visible range from the anchor (`multiple`). A cursor whose row vanished
  climbs to its nearest visible ancestor.
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
  Background, Screen, Heading, Divider & Dash, Brand & Tagline · *Navigation*: Tabs, Menu, Chips, Stepper,
  Pagination · *Forms*: Field, Input & Textarea, Number Input, Select, Combobox, Vector Input, Checkbox,
  Radio & Radio Group, Switch, Slider, Swatches, Color Picker, Schema Form · *Data*: Progress, Ring, Stat Bar,
  Stat Row, Spinner & Skeleton, Badge & Tag, Avatar & Player Chip, Table, Virtual List, Tree, Key Value,
  Empty · *Game*: Slot & Grid, Hotbar, List & List Item,
  Objective & Tracker, Compass · *Feedback*: Alert, Toast, Dialog, Drawer, Popover, Context Menu, Tooltip.
  Each has a `Playground` (controls) and a `Gallery` story (a scene SFC in `stories/kit/scenes/` — the shipped
  bundle has no runtime compiler, so scenes are compiled SFCs or `h()`), and
  `Kit/Showcase/{MainMenu,Hud,Inventory,Map}`:
  the four mockups rebuilt from kit components only (the completeness proof; art in `stories/kit/assets/`,
  Storybook-only, never in `html/`). `storySort` puts `Kit` after `Built-ins`, Foundations and Showcase first.
  The seven §53 components (2026-09-26) each have a Playground and a Gallery (Schema Form also
  `Playground — settings rows`); Table's story also covers sorting and loading. Schema Form's fixtures live in
  `stories/kit/scenes/schemaFixtures.js` (`Core.Schema.public`-shaped data and fake resolvers — plain data, not a
  scene: the harness only globs `*.vue`).
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
| `shell:hud` | `hidden, keep = { resource … }` | §54 (2026-09-26): hides core's HUD widgets and the overlays of every owner not in `keep` |

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

**Note (2026-09-26, run W1-UI).** The props data of an id lives for the life of the shell; its wrapper follows the page
definition's `reactivity` and is fixed before the first mount — a page declared before its plugin loaded (every lazy
plugin) starts deep and is re-wrapped over the same data when the definition arrives. (`propsFor(id, mode?)` keeps
`{ raw, mode, proxy }`; Vue tracks by the raw target, so a proxy captured before the switch still sees every later
open/update/patch — only `===` identity between that early capture and the new wrapper changes. New export
`propsMode(id)`. Tests: `pages.test.ts` +2, `runtime-regression.js` +2 with the `fx_lazy_shallow` fixture page.)

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

## 40. Reusable gameplay development services

These additive APIs remain dependency-free. No existing progress, lifecycle hook, or menu return contract changes.
Stateful registrations are proxy services, captured under Registry.getCaller and automatically removed on owner stop;
mutation/removal is restricted to the owner. Client results are presentation only, never authority for rewards.

- `Core.Controls.acquire({ controls = { controlIds }, groups = { groupIds }? }) -> handle|nil`,
  `release(handle) -> boolean`, `releaseAll()`: independent reference-counted restrictions; one active-only
  frame loop and synchronous cleanup. Defaults to input group 0. Restrictions do not restore unrelated controls.
- `Core.Actions.run(options) -> completed, reason`: managed progress with existing `label`, `duration`,
  `canCancel`, optional animation (`dict`, `clip`, `flag`) or `scenario`, props (`model`, `bone`, `offset`,
  `rotation`), `disable` control ids and interruption flags (`allowDead`, `allowFalling`, `allowSwimming`,
  `allowRagdoll`). Single activity, busy refusal; `cancel()` and `isActive()`. Every exit releases owned
  assets/props/animation/control handles; ped replacement interrupts. UI.progress remains compatible.
- `Core.Geometry.normalize(definition)` and `contains(shape, coords)` are pure shared libraries. Shapes:
  sphere (`coords`, `radius`), box (`coords`, `size`, `rotation` degrees), polygon (`points`, `minZ`, `maxZ`).
  Finite bounded geometry and edge-inclusive containment work identically on server and client.
  `Core.Zones.add(definition) -> id|nil`, `remove(id)`, `removeAll()`, `contains(id, coords)` and
  `Core.Points.add({coords,distance,onEnter,onExit,nearby,interval?})` / remove / removeAll are client-owned
  services. Callbacks run on an adaptive spatial scan, not exported funcrefs every frame. Debug rendering
  uses the existing World scheduler. Zone callbacks receive id; point callbacks also receive distance.
- `Core.Player.context()` returns a snapshot of ped/vehicle/seat/weapon. `onContextChange(key, fn)` and
  `offContextChange(handle)` subscribe to core's single cache; no polling in plugin VMs. Core's existing
  pedChanged(ped, previous) observer is unchanged. Context is advisory and refreshed at a bounded interval.
- Streaming adds request/release pairs for texture dictionaries, Scaleform movies, script audio banks,
  and weapon assets. All waits are bounded, malformed arguments fail closed, timeout releases assets;
  Scaleform requests return a handle or nil, other requests return boolean.
- Lua input fields additionally support textarea/password/slider/searchable select/multi-select/date/time/color.
  Values are validated against the original schema on return (bounds, types, option membership, required),
  and cancelled forms still return nil. Menus add checkbox/side-scroll rows, onChange, nested items/back,
  metadata and progress, preserving ordinary `value|nil` selection results and non-serializable Lua values.
- `Core.UI.skillCheck({ difficulty = { 'easy'|'medium'|'hard'|{speed,areaSize} }, keys?, canCancel? })`
  returns boolean; `skillCheck.cancel()` / `skillCheck.isActive()` manage a bounded, owner-tracked modal.
  Each stage moves an indicator through a target window; configured keys must hit the window. Cleanup on
  close, pause, timeout, owner stop and core stop releases focus and resolves false. No server authority.
- `Core.Hooks.register(name, callback, {priority?,filter?,after?}) -> handle`, `remove(handle)`,
  `run(name, payload) -> allowed, reason` provide owner-scoped synchronous veto pipelines on both sides.
  Ascending priority then registration order, false or errors fail closed; filters skip nonmatches,
  after observers cannot change the decision. Existing Core.on/emitHook remain observers. Explicit
  server `money:beforeTransfer` runs before mutation, rejects reentrant transfers, and never bypasses
  source/destination/funds validation. Hook callbacks receive snapshots, not mutable transaction state.

Client caches, geometry, UI and action completion never substitute for server permission, distance,
cooldown or eligibility checks. No replicated state or new raw network transport is introduced. Server
menu changes use the existing validated callback transport with `core:ui:menuChange(token, change)`:
the source must have that current server-issued menu token; rows, values and ancestors are checked against
the server snapshot; changes are throttled to 100 ms and non-overlapping while a callback is suspended.
Owner stop sends token-matched `menu.close` through the existing `core:client:ui` event. The internal
`Registry.withCaller(owner, fn, ...)` scopes callbacks per coroutine and restores ownership even after errors
or yields; it is not available through exports. Ordinary lifecycle observers retain their existing behavior.

Limits: 8192 total client zones/points; geometry coordinates ±1000000, dimensions/radius ≤10000 and
polygons 3..256 vertices. The hierarchical spatial scan runs at 250 ms (1000 ms when empty); `nearby`
intervals are 100..60000 ms with scan precision. Debug geometry is drawn within at most 300 m of its centre.
Player context samples at most every 250 ms while subscribed, with on-demand stale reads otherwise;
slow subscribers receive a coalesced pending change. Streaming timeouts are finite and capped at 60000 ms.
Forms are bounded to 32 fields, select lists to 200 options, menus to 200 rows/eight levels. Skill checks
have 1..20 stages, 1..10 keys, speed 20..200, areaSize 5..80, and a derived watchdog capped at 120000 ms.
Required checkboxes must be true. Hook payload `money:beforeTransfer` is `{from,to,account,amount,reason}`.

**Note (2026-09-26, admin build, R2-CLIENT F5).** `Core.Controls.acquire({ all = true, except = { ids }?, groups? })`
disables a whole group with `DisableAllControlActions` plus one `EnableControlAction` per exception (a camera mode:
~6 natives per frame instead of one per control). With several handles on one group `all` wins; a control stays
enabled only when EVERY `all` handle excepts it and no list handle disables it; the per-frame plan is rebuilt on
acquire/release as dense arrays. Known limit: re-enabling an exception can undo another resource's disable of that
control if theirs ran earlier in the frame. Other pipelines core runs: `chat:beforeMessage` (§23), `admin:before`
(§51), `maps:beforeApply` (§52). Tests: `client_actions_tests.lua` 74.

Menu changes are acknowledged, not optimistic: the browser allows one outstanding change and commits its
display only after the bridge accepts it. Throttled/rejected changes retain the prior display; an unknown
transport outcome cancels the menu. Final selection waits for the outstanding change, and stale replies
cannot mutate a replacement menu. Acceptance means schema/state acceptance, not that a gameplay action
is authorized; notification callback errors are logged without changing the accepted row state.

---

# Admin platform additions (§41–§53, 2026-09-26 — Liam: "a dynamic admin system … easy to add new menus, settings through other plugins … like the MTA:SA Map Editor … also live place stuff as admin to make fun events")

Research: `resources/admin/research/RESEARCH.md` (+ R1–R7). The plugin contract is `resources/admin/DESIGN.md`. These
sections add the framework pieces every plugin (not only the admin resource) builds on. They are additive: no existing
signature changes meaning; where a default changes it is said explicitly. Every new stateful registration is owner-
tracked through `Core.Registry` and removed when its owner stops (§2.3). Every server entry point validates in the §3
order. Every native named here must be confirmed with `fxref show` in the session that writes the code (AGENTS §3).

## 41. UI input modes, Escape and hide policy (client/ui.lua, shell runtime, SDK)

A page can switch at runtime between "cursor over the UI" and "the game gets the input" without being unmounted —
the editor's fly ↔ cursor switch and its hold-RMB-to-look need it (research §3.3a).

```lua
Core.UI.registerPage(id, { type = 'page'|'overlay'|'modal', keepInput?, input?, escape?, onHide? }) -> bool
--   input  = 'ui' (default) | 'mixed' | 'look' | 'game'     (keepInput = true without `input` means 'mixed' — unchanged behaviour)
--   escape = 'close' (default) | 'event'   ('event': Escape does not close the page; the shell emits page event 'escape')
--   onHide = 'close' (default) | 'suspend' (§31 hidden transition keeps the page mounted instead of closing it)
Core.UI.setInput(id, mode) -> bool      -- owner of the page only (Registry owner == caller); works whether open or not
Core.UI.getInput(id) -> mode|nil
```

| mode | SetNuiFocus(focus, cursor) | SetNuiFocusKeepInput | meaning |
|---|---|---|---|
| `ui` | true, true | false | today's page: cursor over the UI, the game gets nothing |
| `mixed` | true, true | true | cursor over the UI **and** the game receives input (today's `keepInput = true`) |
| `look` | true, false | true | no cursor, the game receives input, the page still gets keyboard events — experimental, in-game probe §6.2 of the research |
| `game` | — | — | the page contributes **no** focus entry: it stays open and rendered, the focus stack is decided by the rest; the shell sets `pointer-events: none` on it |

- Overlays ignore `input` (they never take focus). Modals honour it like pages.
- `applyFocus()` (§38.9) skips page/modal entries whose mode is `game`; `cursor` = mode ~= 'look'; `keep` = mode is
  `mixed` or `look`. The native triple is still only written when it changes.
- Shell message `{ action = 'page:input', id, input }` on every change and inside `page:register`; the runtime stores it
  per page; the SDK exposes it read-only and reactive as `PageHandle.input` (`contract.ts`: `readonly input: PageInputMode`,
  `type PageInputMode = 'ui' | 'mixed' | 'look' | 'game'`). Additive — `API_VERSION` stays 1.
- `escape = 'event'`: when the page (or a modal above it that is itself `escape = 'event'`) is the top layer and no kit
  escape layer consumed the key, the store does not close it; it emits the page event `escape` (Lua:
  `Core.UI.on(id, 'escape', fn)`; SDK: the page's own `on('escape')`). The system layer and kit escape layers are unchanged.
- `onHide = 'suspend'`: the §31 hidden transition does not close the page; its focus entry is skipped while hidden; on
  show focus is re-applied. Modals are still cancelled on hide (§31.4). The page receives page events `suspend` / `resume`.
- The focus watchdog (§38.9) treats a suspended or `game` page as holding no focus.
- Tests: `client_ui_tests.lua` (focus triple per mode, `game` skipped, mode change while open, owner check, suspend/resume
  across hide/show, escape routing), `ui/tests/unit/layers.test.ts` + `pages.test.ts`, a `runtime-regression.js` check per
  new behaviour.

**Implementation notes (2026-09-26, run W1-UI).**
- **Validation.** `input`, `escape`, `onHide` must be one of their strings when present; anything else (wrong case, a
  number) makes `registerPage` return `false` with a `Log.error` instead of silently falling back (a typo like `'Game'`
  would otherwise ship a page that grabs the cursor). `input` wins over `keepInput`; `keepInput = true` alone is
  `'mixed'`, bit for bit the old behaviour.
- **Owner check.** `setInput` compares `Registry.getCaller()` with the page's owner strictly — core cannot switch a
  plugin's page either. The current mode again answers `true` and sends nothing. `getInput` is open to every caller.
  No server API (the §21 op whitelist is unchanged). Re-registering an open page with another mode re-applies focus.
- **Focus stack.** `focusStack()` skips a page/modal whose mode is `game` and the suspended page. **Chat** is dropped
  only when something that HOLDS focus sits above it, so the chat input works while a `game` page (fly mode) is open
  (before, any open page dropped it). The watchdog condition is `focusOwned and not chatTyping and not
  focusAboveChat()` (allocation-free).
- **Escape.** Lua routes nothing: the shell decides (`store.handleKeydown` → `Pages.escapePage`; `ui/src/store.js`
  was touched for this, because Escape and a close button both end in `closePage`) and posts `ui_event { page,
  event = 'escape' }`, which becomes `TriggerEvent('core:ui:<id>:escape')` → `Core.UI.on(id, 'escape', fn)`.
  `layers.ts` (`topModalId`, `modalIds`, `escapeTarget`) skips `game` ids, so a `game` modal never makes the page
  under it `inert` and is never the Escape target. Kit escape layers and built-ins keep precedence.
- **Deviation — `onHide = 'suspend'` is honoured for the exclusive page only.** Modals (plugin and built-in) are
  always cancelled on hide, overlays never closed (§31.4 unchanged). `suspend`/`resume` reach BOTH listeners (shell
  `page:event`, Lua `Core.UI.on(id, 'suspend')`); a suspend page opened while hidden starts suspended, so every
  `resume` pairs with a `suspend`; a page closed/replaced while suspended gets no `resume`; the `ui_ready` replay
  re-sends `page:event suspend` to the shell only. Unchanged: a non-suspend page opened while hidden takes focus at once.
- **Wire (Lua → NUI).** `page:register` carries `input` and `escape` (`keepInput` kept for older readers; `onHide`
  is never sent); `{ action = 'page:input', id, input }` on every change, open or not (it flushes the page's patch
  queue first); `{ action = 'page:event', id, event = 'suspend'|'resume', data = {} }`.
- **Shell/SDK.** `PageHost.vue` gives `game` layers inline `pointer-events: none` plus the utility
  `[&_*]:pointer-events-none!` (compiles flat, beats the kit's `pointer-events: auto`) and `data-core-input`.
  `contract.ts` (additive, `API_VERSION` stays 1): `PageInputMode`, `PageSystemEvent`, readonly reactive
  `PageHandle.input`, an `on(PageSystemEvent, fn)` overload that needs no `In` entry. Dev mock: `input`/`escape` per
  page, `lua.setInput(id, mode)`; suspend is not emulated. `/uiinspect` shows each page's mode and `esc→event`.
- **Page ids must be plain.** The NUI → Lua `ui_event` bridge (page events, `escape`, `Core.UI.on`), requests and
  feed channels accept only `^[%w_%-]+$` (≤ 64), so since the follow-up `registerPage` refuses any other id
  (`Log.error` + `false`; it used `Validate 'id'`, which let `:` through and produced pages that never heard an
  event). `Core.Admin` page/tab `page` fields follow the same rule (`admin_panel`, not `admin:panel`).
- **Limits.** `look` is untested in game (the §6.2 probe decides it). The click-through rule is `!important` on every
  descendant of a `game` layer: a page cannot keep one control clickable in `game` mode — switch the mode instead.
- Tests: `client_ui_tests.lua` suites `ui input modes` + `ui hide policy` (+100) and the plain-id checks (684 total), `ui/tests/unit/
  input-modes.test.ts` (mock ↔ runtime) + layers/pages/inspector cases, `runtime-regression.js` section 10b (+17).
- **`closed` lifecycle event (2026-09-26, after Liam's F10 soft-lock in the admin editor).** Every close of a page,
  modal or overlay now also reaches its Lua owner as `core:ui:<id>:closed { reason, by? }` (`UI.on(id, 'closed',
  fn)`): `'close'` (UI.close), `'replaced'` (another EXCLUSIVE page took the layer — `by` = its id; open modals go
  with it), `'closeAll'`, `'hidden'` (the shell hid a page that is not `onHide = 'suspend'`), `'unregister'`.
  Before, `UI.open` of a second exclusive page closed the first one silently: an owner that runs a camera or holds
  controls for its page (the admin editor under the F10 panel) kept running for a page that was gone and the player
  was stuck. The event is Lua only (the shell already hears `page:close`). Suite `page closed reasons`.

## 42. Raycasts from the rendered camera and from screen points (client/raycast.lua)

`Core.Raycast.fromCamera` uses the *gameplay* camera, which is wrong under a scripted camera (research §5.2 #3). Added:

```lua
Core.Raycast.screenToWorld(fx, fy) -> origin: vector3, direction: vector3|nil   -- fx, fy in 0..1 of the game viewport; GetWorldCoordFromScreenCoord
Core.Raycast.worldToScreen(coords) -> onScreen: boolean, fx, fy
Core.Raycast.fromScreen(fx, fy, distance = 1000, flags = -1, ignore = 0) -> hit, coords, normal, entity
Core.Raycast.fromRenderedCamera(distance = 1000, flags = -1, ignore = 0) -> hit, coords, normal, entity  -- GetFinalRenderedCamCoord/Rot
```
Arguments are validated (finite, 0..1, distance 0 < d ≤ 5000); BOOL out-values are read as `v == true or v == 1`
(§30.4). These are proxy calls — a per-frame tool (the editor) calls the natives in its own VM; these exist for the
occasional query. Tests in `tests/run_tests.lua` style with native stubs.

**Implementation notes (2026-09-26, run W1-UI).**
- Natives (fxref, all client): `GetWorldCoordFromScreenCoord(sx, sy) -> world, normal`, `GetScreenCoordFromWorldCoord`
  `-> BOOL, sx, sy`, `GetFinalRenderedCamCoord()`, `GetFinalRenderedCamRot(2)`,
  `StartExpensiveSynchronousShapeTestLosProbe(…, flags, entity, 7)`, `GetShapeTestResult`. Every BOOL, return and
  out-value, is read as `v == true or v == 1`; `between` now uses the same helper.
- Validation: `fx`/`fy` finite in 0..1 (edges included); `distance` nil → 1000, else finite, 0 < d ≤ 5000; `flags`
  nil → -1, `ignore` nil → 0, else whole numbers (`1.0` is passed as an integer).
- Refusals cast no probe and log nothing (query helpers): `screenToWorld` → `nil, nil`; `worldToScreen` →
  `false, nil, nil` (also off-screen / non-finite projection); `fromScreen` / `fromRenderedCamera` →
  `false, nil, nil, 0`. `screenToWorld` normalises the native's direction and answers `origin, nil` when it has no
  length. `fromRenderedCamera` ignores entity 0 by default, unlike `fromCamera` (the local ped).
- Tests: own suite `tests/raycast_tests.lua` (100 checks, native stubs) instead of `run_tests.lua`.

## 43. Field schemas (`Core.Schema`, lib `lib/schema/shared.lua`, pure, every VM)

One typed vocabulary for settings (§45), admin action arguments (§51) and map element fields (§52), so one kit form
renderer serves all three (research §4).

```lua
Core.Schema.field(def) -> field|nil, err         -- normalise one definition (copies; strips `validate` into a private slot)
Core.Schema.fields(list) -> fields|nil, err      -- array, 1..64, unique names
Core.Schema.check(field, value) -> ok, valueOrErr               -- validate one value; never coerces types
Core.Schema.checkAll(fields, values, { partial = false }) -> ok, out|errs   -- errs = { [name] = err }; unknown keys refused
Core.Schema.default(field) -> deep copy of the default (or nil)
Core.Schema.public(fields) -> JSON-safe array for the UI (no functions, secret defaults removed)
```

Common keys: `name` (`^[%a_][%w_]*$`, ≤ 48), `type`, `label`, `description`, `default`, `required`, `placeholder`,
`group`, `order`, `hidden`, `readonly`, `unit`, `secret`, `visibleWhen = { field = 'x', equals = v } | { field = 'x',
['in'] = { … } }`, `persistDefault` (default true), `validate` (callable, server-side only, `fn(value, all) -> ok, err`,
never sent to clients). Types and their keys:

| type | value | keys |
|---|---|---|
| `boolean` | boolean | — |
| `integer` / `number` | finite number (integer: no fraction) | `min`, `max`, `step` (value on the step grid from `min or 0`) |
| `string` / `text` (multiline) / `password` | string | `minLength`, `maxLength` (default 256, cap 4096), `pattern` (Lua pattern) + `patternMessage` |
| `reason` | string | as string; `minLength` default 3, `maxLength` 256, `templates = { strings }` (UI only) |
| `enum` | scalar, or array of scalars with `multiple = true` | `options` 1..200: `value` or `{ value, label, description }` |
| `array` | array | `items = field`, `minItems`, `maxItems` (≤ 1000) |
| `object` | table with exactly the declared keys | `fields = list` (nesting ≤ 4) |
| `color` | `'#RRGGBB'` or `'#RRGGBBAA'` | `alpha = true` allows the 8-digit form |
| `duration` | integer seconds ≥ 0 | `allowPermanent` (0 = permanent), `max` |
| `vector3` | `{ x, y, z }` finite | `min`/`max` (per component), `world = true` → x,y ±10000, z −1000..3000 |
| `heading` | number, normalised to [0, 360) | — |
| `rotation` | `{ x, y, z }` degrees, finite | — |
| `model` | model name `^[%w_%-]+$` ≤ 64 | `kinds = { 'prop'|'vehicle'|'ped'|'weapon' }` (the consumer checks existence) |
| `player` | server id integer 1..65535 | (the consumer checks it is loaded) |
| `ref` | element id string `^[%w_%-:]+$` ≤ 64 | `refType` (a §52 element type id) |
| `faction`, `item` | id string `^[%w_%-]+$` ≤ 64 | (the consumer checks existence) |

Errors are short machine strings (`'required'`, `'type'`, `'min'`, `'max'`, `'step'`, `'pattern'`, `'option'`,
`'length'`, `'items'`, `'unknown'`, `'custom:<text>'`). Tests: `tests/schema_tests.lua` (every type, bounds, nesting,
defaults, public view, refusal of unknown keys).

**Implementation notes (2026-09-26, run W1-SCHEMA).**
- **`name` is optional in `Schema.field`**, required in `Schema.fields` (lists, object `fields`): settings keys hold
  dots, so a setting's field has no `name` and `Settings.list` sets `name = key`.
- **Unknown definition keys are dropped, not refused** — only vocabulary keys are copied, so `public()` cannot leak
  anything. `checkAll` still refuses unknown VALUE keys (`'unknown'`, reporting stops after 16 keys).
- **Definition errors** name the bad key: `'type'`, `'min'`, `'options'`, `'depth'`, `'items.<err>'`,
  `'fields.<name>.<err>'`, `'default:<err>'`; in a list `'<name>.<err>'`, and the list itself `'count'` or
  `'duplicate:<name>'`. A default is checked with the built-in rules only (the plugin's `validate` is not run on it).
- **Nested value errors carry a path**, `'<index|name>.<err>'` (`'2.reason.length'`, 1-based indexes). `checkAll`
  returns `errs[name]` without the prefix and `errs['*']` for a non-table input (`'type'`) or a broken raw list
  (`'schema:<err>'`). Array/enum counting stops at `maxItems + 1`: a hostile payload costs bounded work.
- **`required`**: nil or `''` fails; a field hidden by `visibleWhen` (sibling value, or its default) is never
  required, but a value it is given is still checked. **`persistDefault`**: `checkAll` (not partial) and object
  values fill a missing value with the default unless `false`; `check` never fills.
- **Custom `validate`** runs after the built-in checks with `all` = the normalised output (nil for a single `check`);
  a throw → `'custom:error'`, a bare false → `'custom:invalid'`, text cut to 128 bytes. It lives in a weak-keyed
  private slot (kept by re-normalising); a copy that crossed a VM has none (functions do not cross JSON).
- **Normalisation**: fresh tables; vector3/rotation as `{ x, y, z }` (a `vector3` userdata is accepted); heading
  `v % 360`; whole floats of integer/duration/player as integers. **`duration`**: 0 passes with `allowPermanent`,
  otherwise `min` (default 0) and `max` apply. **`reason`**: `minLength` counts the trimmed text; the value is
  returned untouched. **`enum multiple`**: duplicates fail `'option'`. Lengths are bytes, not UTF-8 characters.
- **Addition — UI-only keys for CoreSchemaForm** (kept by `field()`/`public()`, validated, never read by `check`):
  common `icon` (≤ 32); `options[].icon` (≤ 32); `rows` (integer 2..20, `text` only); `presets` (`duration` only, ≤ 12
  integer seconds; `0` needs `allowPermanent`, every other preset must lie within `min`/`max`, so a preset is always a
  value `check` accepts). Refused as `'icon'`, `'options'`, `'rows'`, `'presets'`.
- Tests: `tests/schema_tests.lua` (317).

## 44. Permissions v2: catalogue, ranked groups in the DB, targeting (server/perms.lua, lib/callback)

Unchanged: `Perms.has/getGroup/setGroup/isAdmin/grant/revoke/list` and their check order (console → ACE → account →
character → group). Added:

```lua
Perms.define(perm, { label, description?, category?, default? }) -> bool
--   owner-tracked (kind 'permDef'); `default` = a group name that receives the grant ONCE: if the group's document does
--   not list the perm and never had it removed (group.removed[perm]), it is added. An owner's edit is never overwritten.
Perms.catalogue() -> array of { perm, label, description, category, owner, default }
Perms.groups() -> array of { name, label, weight, inherits = { names }, perms = { strings }, color? }
Perms.saveGroup(name, { label?, weight?, inherits?, perms?, color? }, actorSrc?) -> bool, err   -- actor needs 'core.perms.manage'
Perms.deleteGroup(name, actorSrc?) -> bool, err                  -- not 'user', no member online; members fall back to 'user' on load
Perms.getWeight(src) -> integer                                  -- console: math.huge; unknown/no session: 0
Perms.canTarget(actorSrc, targetSrc) -> bool, reason             -- console or self: true; else weight(actor) > weight(target)
Perms.effective(src) -> { [perm] = true }                        -- group chain + account + character (ACE not enumerable)
Perms.explain(src, perm) -> { allowed, via = 'console'|'ace'|'account'|'character'|'group:<name>'|nil }
Perms.grant(src, perm, scope?, { expiresAt? })                   -- temporary grants: expired entries are ignored and pruned on load
```

- Groups live in the collection `perm_groups` (doc id = name): `{ name, label, weight, inherits, perms, removed = {},
  color }`. First start seeds them from `Config.Perms.Groups` and the new `Config.Perms.Weights` (`user 0, helper 100,
  mod 200, admin 300, senior 400, owner 1000`); afterwards the DB is the source of truth and the config is only the seed.
- `inherits` is resolved recursively with a cycle guard; each group's resolved set is cached and invalidated on save.
  The existing "`core.admin` in a group implies the admin group's list" rule stays for compatibility.
- `Player.setGroup` accepts any group that exists in `perm_groups`.
- Hook `permsChanged (src|nil, what)` after every grant/revoke/setGroup/saveGroup/deleteGroup (src nil = a whole group
  changed); consumers (the admin rights snapshot, §51) refresh on it. Demotion takes effect immediately.
- `Core.Callback.register(name, schema?, fn, opts?)` gains `opts = { permission?, cooldownMs? }` enforced before `fn`
  exactly like `Net.on` (permission via `Core.Perms.has`, per-src cooldown) — lib change, every VM.
- New core perms (defined by core at start): `core.perms.manage`, `core.settings.view`, `core.audit.view`.
- Tests: `tests/perms_tests.lua` (seed, inheritance + cycles, weights, canTarget, define-once/never-overwrite, removed
  tracking, temporary grants, explain, hook emission) + the callback option in `tests/run_tests.lua`.

**Implementation notes (2026-09-26, run W1-PERMS; review rounds REVIEW-CORE M5/L2/L11 and R2-UI).**
- **Default change — the seed.** `Config.Perms.Groups` now seeds six groups (`user`, `helper`, `mod`, `admin`,
  `senior`, `owner`; cumulative lists for the pre-§44 code paths) with `Weights` (0/100/200/300/400/1000) and
  `Inherits` (each group inherits the one below). The config is only read into an EMPTY `perm_groups`.
- **Deviation — temporary grants live next to the arrays**: `tempPermissions = { [perm] = expiresAt }` (unix seconds)
  on the account document (`Player.setAccountData`) or the character data (`Player.setData`); `permissions` stays an
  array of plain strings, so every pre-§44 reader keeps working. `has` ignores an expired entry at once; the
  per-session cache build prunes and writes back; one `SetTimeout` per player (the soonest expiry, superseded by
  token) prunes, audits and emits `permsChanged(src, 'expired')`. A permanent grant removes a temporary one; a
  temporary grant of a permanently held perm is a no-op; `revoke` removes both. `expiresAt` must be in the future
  and ≤ 10 years ahead.
- **Caches**: grant state per src, dropped on `playerDataChanged` for `permissions`/`tempPermissions`, on
  `permsChanged (src, 'grants'|'group')` — which `Player.setAccountData` / `Player.setGroup` emit themselves, so an
  out-of-band write counts at once (L2) — on `playerLoaded` and `playerDropped`; nothing cached for a src without a
  session. Resolved group chains per group name, dropped whole on every saveGroup/deleteGroup/default grant/load.
- **Loading**: `perm_groups` is read inside a coroutine (first yieldable caller, else a thread) and eagerly on core's
  start; until then — and while the collection is degraded — checks run on the config seed held in memory (never
  written over the collection); a failed read retries after 30 s; `saveGroup`/`deleteGroup` answer `not_ready`.
  The load emits `permsChanged(nil, 'load')`.
- **explain** returns `{ allowed, via, group, expiresAt? }` (`group` = the player's group; `via = 'group:<name>'` names
  the first group of the resolved walk that lists the perm). **effective(0)** = every catalogued + group-listed perm.
- **Hook** `permsChanged (src|nil, what, detail)`, what ∈ `grant|revoke|group|grants|saveGroup|deleteGroup|define|
  expired|load`. `Player.setGroup` / `setAccountData` emit `(src, 'group')` / `(src, 'grants')`; `Perms.setGroup`
  emits `(src, 'group', name)` only when Player.setGroup did not; a grant through Perms produces `(src, 'grants')`
  (player.lua) and `(src, 'grant', perm)` (perms.lua) — listeners must be idempotent.
- **define**: the first owner keeps a perm (a second resource's define is ignored with a warning and answers true);
  `category` defaults to the prefix; `default` applies at once when the groups are loaded, else right after the load.
  Core defines the legacy rank perms (`core.helper/mod/admin/senior/owner`, no default), `core.perms.manage`
  [owner], `core.settings.view` [admin], `core.audit.view` [admin] and `Config.Admin.StaffPerm` (`core.admin.staff`)
  [helper]. `removed`: saveGroup marks every perm that leaves a list and clears it for every perm in the new one; a
  group CREATED by saveGroup marks every catalogued `default` naming it (that the creator did not list) as removed.
- **Addition — rank rules on group edits** (M5, privilege-escalation guard): a non-console actor may only save or
  delete groups weighted STRICTLY below its own (never its own or an equal one), may not set any weight ≥ its own,
  may inherit only from groups below it (`rank`), and may only ADD perms it holds itself (`Perms.has`) — listed
  directly or brought in by a newly added parent's chain (`not_held`); removing perms is free inside the groups it may
  edit. Editing `owner` therefore needs the console (or core). `deleteGroup` also refuses while another group
  inherits it (`inherited`). `actorSrc = nil` is core itself (no checks) — a plugin acting for a player passes the
  player's src. Cycles are refused at save (`cycle`) and tolerated at resolution. saveGroup/deleteGroup write audit
  rows `perms.saveGroup` / `perms.deleteGroup`, denials too (`message` = rank | not_held | no_permission);
  grant/revoke/setGroup/expiry keep `Log.audit('perms', …)`, mirrored by §46.
- **Callback options**: rate limit → schema → cooldown → permission → handler; `cooldown` is accepted as Net.on's
  spelling; invalid opts refuse the registration; the client accepts and ignores them. Since the R2-UI round every
  refusal is answered with its reason (§3.5 note): `await` returns `nil, 'rate_limit'|'schema'|'cooldown'|
  'permission'|'timeout'|'error'`. The permission gate costs one export hop per request in a plugin VM.
- Tests: `tests/perms_tests.lua` (241, including suite `callback opts` — not in `run_tests.lua` as the contract said),
  `tests/callback_tests.lua` (34, the refusal reasons). `server/perms.lua` is 891 lines: split the group management
  into its own file on the next addition.

## 45. Settings (`Core.Settings`, server/settings.lua + client read side)

Runtime-editable, schema-validated settings any plugin declares; a generic UI lists them (research §4).

```lua
-- server
Settings.define({ id = 'inventory', title, icon?, order?, properties = {
    ['inventory.maxWeight'] = { type = 'number', default = 30, min = 1, max = 500, label, description, group, order,
        scope = 'server', edit = '<perm>'?, view = '<perm>'?, replicate = false, secret = false, restart = false,
        config = <the plugin's config value, optional> },
} }) -> bool, err            -- owner-tracked (kind 'settings'); keys must start with '<id>.'; a key belongs to one owner
Settings.get(key) -> value                      -- effective: override > config > default (deep copy for tables)
Settings.set(key, value, actorSrc?, reason?) -> bool, err     -- actorSrc given: needs `edit` (default 'core.admin')
Settings.reset(key, actorSrc?, reason?) -> bool, err          -- deletes the override
Settings.inspect(key) -> { value, default, config, override, source = 'default'|'config'|'override' }
Settings.list(viewerSrc?) -> sections { id, title, icon, order, owner, properties = { public schema + value + source } }
--   viewerSrc filters by `view` (default 'core.settings.view'); secret values are never included (masked '••••')
Settings.onChange(prefix, fn(key, new, old)) -> handle     -- owner-swept; runs in a new thread after persist
Settings.offChange(handle)
-- client (proxy): only replicate = true keys
Settings.get(key) -> value;  client hook 'settingChanged' (key, new, old)
```

- Validation: `Core.Schema.check` (type → range/pattern → custom validate); invalid values are refused with the error,
  never coerced; a config value that fails validation falls back to the default with a console warning.
- Persistence: collection `settings` (doc id = key, `{ value, updatedAt, by }`), loaded at start; only overrides are
  stored. When the owner stops, its definitions go but its overrides stay in the DB (re-applied on the next define).
- Recursion guard: a `set` of key K from inside an onChange handler for K is refused (`'recursive'`).
- Replication: `replicate = true` keys are mirrored to `GlobalState['cs:' .. key]` (changes are rare admin actions); the
  client proxy reads GlobalState; core's client emits `settingChanged` from a GlobalState change handler. Secret keys
  can never replicate (define refuses the combination).
- Every set/reset writes an audit record (§46) `action = 'settings.set'`, `changes = {{ key, old, new }}` (secret: masked).
- Core defines its own sections at start: `maps.*` (§52 limits), `audit.*` (§46 retention) and `bans.*` (§47
  token matching and enrichment).
- Tests: `tests/settings_tests.lua`.

**Implementation notes (2026-09-26, run W1-SCHEMA).**
- **Deviation — document id = the key with `.` → `:`** (`inventory.maxWeight` → `settings/inventory:maxWeight`):
  Core.DB ids refuse dots and keys cannot contain `:`, so the mapping is a bijection. The document stores
  `{ key, value, updatedAt, by }`, `by = { kind = 'player'|'console'|'resource', src?, accountId?, name?, resource? }`.
- **Keys**: `<id>.<segment>(.<segment>)*` of `[%w_]`, ≤ 64 bytes (the DB id limit); section id `^[%a_][%w_]*$` ≤ 32;
  ≤ 128 properties per section.
- **`scope`**: only `'server'` (the default) is implemented; `'faction'`/`'player'` are refused (`'scope'`) rather
  than silently treated as server.
- **Load**: the async barrier of globals.lua — the first `get`/`set`/`list` or core's start preload runs
  `DB.all('settings')`, concurrent callers wait on one promise; `define` never needs it. A degraded collection leaves
  `get` on config/default and makes `set`/`reset` answer `'unavailable'` (retry ≤ every 10 s).
- **A stored override the current field refuses** (the owner tightened a bound) is ignored with one warning per
  definition; `source` falls back to config/default; it stays in the DB and `inspect(key).override` shows it.
- **Admission order** of set/reset: key → actor (0 or 1..65535) → reason (≤ 256) → load → existence → value
  (`Schema.check` incl. the plugin's `validate`) → recursion guard → permission. A permission refusal writes an audit
  row `result = 'denied'`.
- **Recursion guard** is "the resource whose handler for K is running right now may not set K" (`'recursive'`), which
  holds across yields and the export hop, where coroutine identity does not survive; other resources may write K.
- **onChange** fires only when the effective value changed (a set equal to the current value persists and audits,
  but replicates and notifies nothing); one new thread per change, handlers in registration order, deep copies,
  unmasked (server code), errors logged.
- **Audit**: set and reset both write `action = 'settings.set'` with `ctx = { op = 'set'|'reset', section }`,
  `source = actorSrc and 'api' or 'core'`, `actor = actorSrc or 'system'`; secret values masked. `inspect` masks
  secrets too — `get` is the only unmasked read (server only).
- **Replication**: one paced queue (40 keys per 1 s drain, like doors §16) writes the value effective at write time,
  skipping unchanged ones; the sorted index `GlobalState['cs:keys']` is written after the values once the queue is
  empty; a key that stops replicating is set to nil and leaves the index; core stop clears every mirrored key.
  **Client**: one global `AddStateBagChangeHandler` with a prefix test plus a last-seen cache seeded from `cs:keys`
  (20 × 500 ms boot retries) so `old` is right for keys that existed before the script started; a key leaving the
  index emits `settingChanged(key, nil, old)` exactly once; seeding emits nothing.
- **Core's own sections** (owner core): `maps` (order 800 — `maps.limits.elements` 3000, `perModel` 300,
  `uniqueModels` 200, `networked` 20, `networkedTotal` 200, `opsPerApply` 200, `maps.journalMax` 5000,
  `maps.journalMaxOps` 20000) and `audit` (order 900 — `retentionDays` 90, `maxRows` 50000, `logMaxRows` 20000) in
  settings.lua; `bans` (order 910, icon `gavel` — `tokenMatches` 2, `enrichTokens`, `enrichIdentifiers`, `failClosed`)
  is defined by server/bans.lua at start (§47).
- Tests: `tests/settings_tests.lua` (149).

## 46. Audit trail (`Core.Audit`, server/audit.lua)

`Log.audit` only prints (§3.4). This is the persisted, queryable trail (research §1.5).

```lua
Audit.record({ actor = src|0|'system', action = 'admin.kick', source? = 'menu'|'palette'|'chat'|'console'|'editor'|'api'|'core',
    targets? = { { type = 'player'|'account'|'vehicle'|'entity'|'map'|'setting'|'ban'|'group', id, name? } },
    changes? = { { key, old, new } }, reason?, ctx? = {}, result? = 'ok'|'denied'|'error', message? }) -> id
Audit.query({ action?, actionPrefix?, actorAccount?, target? = { type, id }, resource?, result?, from?, to?, text?,
    limit? = 50 (≤ 200), before? = cursor }) -> { rows, next }      -- newest first
Audit.get(id) -> row|nil
```

- A row: `{ id, ts (os.time() ms precision from GetGameTimer offset), actor = { kind = 'player'|'console'|'system', src?,
  accountId?, name?, group? }, action, source, resource (caller), targets, changes, reason, ctx, result, message }`.
  `actor = src` is resolved to the account snapshot at record time; player targets get `accountId` + `name` added.
- `resource` is the calling resource (`Registry.getCaller()`); strings are sanitised and bounded (message 512, reason
  256, 32 targets, 64 changes, values stringified ≤ 256).
- Storage: collection `audit`, append-only (never updated). Core.DB keeps collections in memory, so retention is
  bounded by the settings `audit.retentionDays` (90) and `audit.maxRows` (50000); a Cron job prunes daily, oldest first.
  Rows whose action starts with `sanction.` or `ban.` are exempt from `maxRows` (still subject to retention ×4).
- `Log.audit(category, src, fmt, …)` keeps printing and emitting the `audit` hook, and additionally records
  `{ actor = 'system', action = 'core.' .. category, targets = { player src }, message }`.
- Webhook: `result = 'ok'|'denied'` rows mirror to `Core.Webhook.send('audit', …)` (existing convar); denied rows
  are also mirrored to `Core.Webhook.send('audit_denied', …)` when that convar is set.
- View permission `core.audit.view` (enforced by consumers such as the admin plugin, not by `query` itself).
- Tests: `tests/audit_tests.lua`.

**Implementation notes (2026-09-26, run W1-AUDIT; review rounds M1 and R2-6/R2-9).**
- **Index.** `server/audit.lua` keeps one POSITIONAL array per row (`{ ts, id, action, actorAccount, result,
  resource, exempt, targetKeys, text }`, ~200 B + strings) ascending by (ts, id); Core.DB holds the full documents.
  Built at start through a `DB.find` predicate that reads each document in place and returns false (nothing is
  copied). `query` walks backwards with an early stop at `from`, binary-searches `to`/`before`, and does one `DB.get`
  per returned row (≤ 201) — never a `DB.find` per query. `targetKeys` is one string `|type:id|…|`; a player target
  also adds `|account:<id>|`, so `target = { type = 'account', id }` finds rows where that account's player was a
  target. `text` is a lower-cased haystack (action, actor name, message, reason, target names; ≤ 640 bytes).
- **Ids and time.** `ts` = `os.time()*1000` calibrated by `GetGameTimer()` (resynced on > 2 s drift, never backwards);
  id = `'a' .. %013d ts .. %03d seq` (sortable; after the index loads new ids start after the newest stored row).
  The page cursor is `'<ts>/<id>'` (a bare row id works too); `from`/`to` take ms, or seconds when < 1e11.
- **Never yields, never throws.** `record` builds the row under `pcall`; rows recorded before the index loaded are
  queued (≤ 2000, oldest dropped with a warning) and written by the loader; a degraded collection keeps them queued
  (retry every 30 s).
- **Bounds.** Strings via `Utils.sanitize`, cut on a UTF-8 boundary; change/ctx values: nil/boolean/finite numbers
  stay, strings ≤ 256, tables JSON-stringified ≤ 256; `ctx` ≤ 32 string keys; target `type` = `^[%w_%-]+$` ≤ 32 (any
  type, not only the listed ones); a `source` outside the list defaults to `'core'` for core, else `'api'`.
- **Filters never widen.** A filter key that is present but unusable (wrong type, over-long, a target without `id`)
  matches NOTHING instead of being ignored (also `Bans.list`'s `accountId`).
- **Addition — three retention pools** (R2-6), derived from the action (no stored field): `sanction.*`/`ban.*` →
  *exempt* (no row cap, retentionDays × 4); `core.<category>` whose category is not a staff category (`admin`, `perms`,
  `player`, `native`, `settings`, `maps`, `bans`) → *log*, capped by the new setting `audit.logMaxRows` (20000);
  everything else → *main* (`audit.maxRows`). Each pool is pruned oldest-first on its own; the overflow trigger
  (cap + max(500, cap/20)) is per pool, so a busy economy never evicts the admin trail. **Rate cap**: `recordLog`
  writes at most 20 rows per log-pool category per second; the rest is counted into the next row's `ctx.suppressed`
  (staff categories are never capped).
- **Retention** limits are CACHED (refreshed in the prune thread, never read in `record`). Prune = start +
  `Cron.at(4, 30)` + `Settings.onChange('audit.')` + the overflow trigger. The index swap is synchronous; DB deletes
  run in slices of 250 with a 50 ms pause. `Audit.prune()` and `recordLog` stay public (maintenance / the plugin-VM
  mirror). The Cron jobs, settings sections and watchers of audit.lua and bans.lua are registered from core's own
  threads, which are core's under the per-coroutine caller (§2.3 note) — no wrapper needed.
- **Webhooks.** `recordLog` rows are NOT posted to `audit` — webhook.lua's `audit` hook subscription already posts
  every `Log.audit` line, so each line reaches Discord exactly once. Other ok/denied rows go to `audit`, denied ones
  also to the new optional convar `core_webhook_audit_denied`; convars are checked before an embed is built.
- **Log.audit** (`lib/log/shared.lua`) keeps print + hook, then calls `Audit.recordLog(category, src, message)` —
  `rawget(Core, 'Audit')` inside core, the export proxy in a plugin VM, always under `pcall`. The category is made
  action-safe (`[^%w_.%-:]` → `_`); `src` ≤ 0 adds no target; `resource` is the plugin that logged the line.
- **§17 — `Cron.remove` is owner-checked** (R2-9, like `Hooks.remove`): only the job's owner or core removes it; the
  owner-stop sweep uses an internal remover.
- Tests: `tests/audit_tests.lua` (139, pools, rate cap and the Cron owner check included).

## 47. Bans on identifiers and tokens (`Core.Bans`, server/bans.lua; connect path in server/player.lua)

Replaces the license-only, online-only ban with its linear scan per connect (research §1.4).

```lua
Bans.add({ target = src | { accountId?, identifiers?, tokens?, name? }, reason, duration = seconds (0 = permanent),
    by = actorSrc|0, evidence? }) -> ban|nil, err          -- online target: identifiers + tokens collected now, then kicked
Bans.remove(banId, by, reason) -> bool, err                -- marks revoked (kept for history); clears account.banned
Bans.get(banId) -> ban|nil
Bans.list({ active? = true, text?, accountId?, limit? = 50, before? }) -> { rows, next }
Bans.check(identifiers, tokens) -> ban|nil                 -- O(#ids + #tokens) index lookups, active and unexpired only
Bans.forAccount(accountId) -> array
```

- A ban: `{ id, accountId?, name, identifiers = { 'license:…', 'discord:…', … }, tokens = { … }, reason, evidence?,
  by = { accountId?, name }, createdAt, expiresAt (0 = permanent), revoked? = { by, at, reason }, hits, lastHitAt }`.
  `ip:` identifiers are never stored.
- Index: in memory, `identifier|token → { [banId] = true }` for active bans, built at start, maintained on add/remove,
  expired bans dropped lazily on hit and by a daily Cron sweep.
- Connect (`playerConnecting` deferral in player.lua): identifiers via `GetNumPlayerIdentifiers/GetPlayerIdentifier`
  (skip `ip:`), tokens via `GetNumPlayerTokens/GetPlayerToken`; `Bans.check`; on a hit the ban is **enriched** with the
  new identifiers/tokens (catches a second account on the same PC), `hits`/`lastHitAt` updated, and the deferral is
  rejected with reason, expiry and ban id. `GetPlayerIdentifierByType(src, 'license:')` needs the colon (prefix match).
- `Player.ban(src, reason, seconds?, by?)` keeps its signature and delegates to `Bans.add`.
- Migration `DB.migrate('bans', 2, fn)`: old `{ license, until, by = string }` → the new shape.
- Every add/remove is audited (`ban.add` / `ban.remove`).
- Tests: `tests/bans_tests.lua` (index, expiry, enrichment, revoke, migration, connect path with stub natives).

**Implementation notes (2026-09-26, runs W1-AUDIT + W1-PLAYER; review rounds H2/M3/M4 and R2-3/R2-11/R2-12).**
- **Files.** `server/bans.lua` (Core.Bans) + `server/bans_identity.lua`, loaded right before it: the internal
  `Core.BanIdentity` (block-listed in the export) — identity reads (`GetNumPlayerIdentifiers`/`GetPlayerIdentifier`,
  `GetNumPlayerTokens`/`GetPlayerToken`), the online identity index (filled on `playerJoining`, ~15 natives per join,
  cleared on `playerDropped`, seeded from `GetPlayers()`), account lookup and the rank check.
- **Index.** `index[identifier or token] = { [banId] = true }`, `active[banId] = { expiresAt, accountId, keys }` and
  `accountActive[accountId] = n` (`account.banned` is cleared only with the last active ban of that account); built at
  start with a non-copying `DB.find` predicate. New ban ids are `'B' .. DB.nextId('bans')`; migrated v1 bans keep their
  uuid; documents carry `_v = 2`.
- **Connect.** `Bans.checkConnecting(src) -> ban, message | nil | nil, 'unavailable'` (INTERNAL, block-listed)
  collects identifiers (no `ip:`, ≤ 32) and tokens (≤ 64), picks the best active ban (permanent first, then the latest
  expiry), enriches it and returns the finished text: `You are permanently banned. Reason: <reason> (ban <id>)` /
  `You are banned until <YYYY-MM-DD HH:MM>. Reason: <reason> (ban <id>)` (used verbatim). `Bans.check` also answers
  `nil, 'unavailable'` while the collection cannot be read. **player.lua (M4)**: on `'unavailable'` it falls back to a
  license-only lookup that reads both document shapes; if that throws or `bans` is degraded, the deferral is refused
  ("Ban service unavailable, please try again in a minute.") unless the setting `bans.failClosed` is false. The license
  is read with `GetPlayerIdentifierByType(src, 'license:')` and accepted only with that prefix (`license2:` never
  passes as `license:`).
- **Matching and enrichment (M3).** An identifier matches on one overlap; tokens alone need `bans.tokenMatches`
  (**default 2**, 0 = never) DISTINCT tokens in one ban. `bans.enrichTokens` adds the refused player's unseen tokens;
  `bans.enrichIdentifiers` adds unseen identifiers only after an identifier match or ≥ 2 matching tokens, so one shared
  token never spreads a ban to a stranger's license/discord; an account-less ban learns an account only after an
  identifier match. Settings are cached (start + `Settings.onChange('bans.')`).
- **add and rank (H2).** `target = src` must be connected (`not_connected`); `{ accountId }` of an ONLINE account is
  treated like a src; offline it takes the stored `license` + `identifiers`. `duration` 0..100 years, `evidence`
  ≤ 512, `by` = src | 0 | nil (console) | a legacy name. Every banned identifier is mapped to the accounts holding it
  (`Player.findAccountsByIdentifier`) and to the online players the ban would refuse; a player `by` must outrank all
  of them (account weights < the actor's, `Perms.canTarget` for the online ones, the actor's own account/src
  excepted), else `nil, 'rank'`; when the account index is unreadable a player actor gets `'db'` (never a blind
  pass, R2-11). Console / nil / a legacy name are not rank-checked. The ban stores `accountIds` (every matched
  account, the explicit one first; one match also becomes `accountId`); `list({ accountId })` and `forAccount` find
  both. **Every online holder is kicked with the target** (this replaces the first round's "caught at the next
  connect"). The audit row `ban.add` targets the ban and the player/account, `ctx = { duration, expiresAt }`.
  `Player.ban` delegates to `Bans.add` with `by` = the actor src and writes no `Log.audit` line of its own.
- **Account index** (`server/getters.lua`, `Player.findAccountsByIdentifier`): built lazily by a non-copying `DB.find`
  walk, folded with live sessions, maintained on `playerJoining`/`playerLoaded`; every identifier type except `ip:` is
  stored (R2-3); stale entries are re-checked at query time; a miss re-reads `accounts` when the count changed or the
  index is older than 5 minutes; an index read from a degraded `accounts` is never cached (`nil, 'unavailable'`).
  `Player.setAccountData` refuses `identifiers` (a join is the only writer).
- **Expiry** lazily on a hit and by `Bans.sweep()` at start + `Cron.at(4, 40)`. `list({ active = false })` = every ban.
- **Migration v2**: `{ license, reason, by = 'name', until }` → `{ identifiers = { license }, tokens = {}, accountId +
  name from the account with that license, by = { name }, expiresAt = until, hits = 0 }`; expired v1 bans are kept
  (history) but never indexed. **R2-12**: when `accounts` cannot be read during the migration the document keeps
  `relink = '<license>'` and the start thread (every 60 s until done) and every `sweep()` link it later.
- **Why the settings exist.** Token matching + enrichment spread a ban to every account that shows one of its tokens;
  shared hardware (cafés, cloud gaming, VMs) could chain-ban strangers. `hits`/`lastHitAt` and `Bans.remove` are the
  tools to spot and undo a spread.
- Tests: `tests/bans_tests.lua` (193); the connect path, `Player.ban`, the index and the legacy commands in
  `tests/server_tests.lua` (suites `player admin`, `admin ranks`, `legacy commands`).

## 48. Sticky player states, teleport, account reader (server/player.lua, client/environment.lua, client/spawn.lua)

- `Player.setFrozen/setInvincible/setVisible/setControls(src, on)` store the value in the session (`session.states`) and
  the client re-applies them after `pedChanged`, respawn and every teleport; `Player.getStates(src) -> { frozen,
  invincible, visible, controls }`. Core stop still resets everything (§31 unchanged).
- `Spawn.teleport` no longer unfreezes a ped that is sticky-frozen.
- `Player.setCoords(src, coords, heading?, opts?)` — `opts = { withVehicle = false, fade = true, bucket? }`:
  `withVehicle` moves the vehicle the player drives (driver only) with its occupants; `fade = false` skips the screen
  fade; `bucket` changes the routing bucket first.
- `Player.getAccount(src) -> { id, name, group, identifiers, firstSeen, lastSeen, playtime, banned }` (read-only copy of
  the live account; no permissions list) and `Player.getAccountById(accountId)` (from the DB, offline players).
- `Player.setBucket` additionally emits the client event `core:client:bucketChanged (bucket)` to that player (§52 uses it).
- Tests: extend `tests/server_tests.lua` (states persistence, opts) — the owner of this section owns those edits.

**Implementation notes (2026-09-26, run W1-PLAYER; review rounds L2 and R2-3/R2-13).**
- Sticky states are session-only (not persisted): a reconnect starts from the defaults. The `core:client:loaded`
  payload carries `states`; the client applies a changed key at once and re-applies only NON-DEFAULT values after
  pedChanged / spawn / teleport, so core never undoes another resource's own freeze or invisibility.
  `client/environment.lua` hands controls/frozen/invincible/visible of `core:client:playerState` to the sticky store
  (`Player.setStates`, core-internal); health/armour are unchanged.
- `setCoords`: `withVehicle` is checked server-side (driver seat) and again client-side; the client asks for network
  control of the car for ≤ 1 s and falls back to moving the ped alone. With `bucket` + `withVehicle` the car
  (`SetEntityRoutingBucket`) follows; **the other riders change bucket only with `opts.moveRiders = true`** (R2-13:
  the caller vouches for its own rank checks on them — the admin plugin's teleport passes it after `canTarget`). Opts
  are sent to the client only when they differ from the plain faded teleport; the 4th arg of `core:client:teleport`
  is `{ withVehicle, fade }`. `Spawn.teleport` (and `spawnPlayer`) wait for `Core.Maps.waitAreaReady(coords, 3000)`
  when it exists, never unfreeze a sticky-frozen ped and re-apply sticky states.
- Account reader: `getAccountById` prefers the live session (index `byAccountId`); **additions** `Player.getGroup(src)`
  (the raw account group, no copy) and `Player.findAccountsByIdentifier(identifier)` (§47 notes).
  `Player.setAccountData` refuses `id`, `license` and `identifiers`; `'group'` emits `permsChanged (src, 'group')`,
  `'permissions'`/`'tempPermissions'` emit `permsChanged (src, 'grants')` (L2). `collectIdentifiers` stores every
  identifier type except `ip:` (R2-3).
- `CORE_STATE_KEYS` += `duty`, `staffModes`: the names stay RESERVED although core no longer writes those bags (§51
  notes — staff state goes by event), so no plugin can publish a look-alike.
- Size: `Player.getHealth/getArmour` and the `core:player:getInfo` callback moved from server/player.lua to
  server/getters.lua (no behaviour change) to keep player.lua under 900 lines.
- Tests: `tests/server_tests.lua` suites `player admin`, `admin ranks`, `legacy commands` (1108 total).

## 49. Target selectors (`Player.resolveTargets`, server/getters.lua; `lib/commands` param types)

```lua
Player.resolveTargets(actorSrc, selector, opts? = { max?, allowSelf? = true }) -> array of src | nil, err, candidates?
```
Grammar (comma = union, `!` = remove): `me`/`^` actor · numeric id / `$<id>` · `c:<charId>` · `r:<metres>` loaded
players within the radius of the actor's **server-side** coords (player grid, radius ≤ 500) · `#<group>` exactly that
group · `%<group>` weight ≥ that group's weight · `f:<faction>` · `*` all loaded · `others` all but the actor ·
anything else = partial name (case-insensitive; one match → it, several → `nil, 'ambiguous', candidates` (≤ 10)).
The result is de-duplicated, loaded players only, capped by `opts.max` (`'too_many'` above it). Permission checks on
multi-target selectors are the caller's job (§51 enforces scope caps). `@` (crosshair target) is resolved by the admin
plugin client-side and sent as an id.
`Core.Commands` gains param types `target` (exactly one player via `resolveTargets`) and `targets` (≥ 1); server only.
Tests: `tests/targets_tests.lua`.

**Implementation notes (2026-09-26, run W1-PLAYER; review rounds M2, L3 and R2-7).**
- Decisions beyond the grammar: (1) several partial-name matches with exactly ONE exact (case-insensitive) match
  resolve to it (`bob` → Bob, not ambiguous with Bobby); (2) an explicit single target that is missing (`99`, `c:x`,
  a name) fails the whole selector with `not_found`, while a `!` token that matches nobody is a no-op; (3) an empty
  result is `nil, 'no_match'` (or `'self'` when only `allowSelf = false` emptied it); (4) `r:` includes the actor
  (distance 0), radius in (0, 500]; (5) `#`/`%` try the group as written, then lower-cased; `f:` matches id, tag or
  name case-insensitively; (6) ≤ 256 characters and ≤ 32 tokens per selector. Order: first-seen; set tokens
  ascending src; `r:` nearest first.
- **Bounded work (M2, R2-7)**: tokens are de-duplicated (case-insensitively, except `c:`); at most **4 set tokens**
  (`*` `others` `r:` `f:` `#` `%`, removals included) and **8 distinct names** per selector (`bad_selector` above);
  removals resolve first and the union stops as soon as it passes `opts.max` (`too_many`, detail = max + 1). The
  loaded list, lower-cased names and the group table are read once per call (no per-player `getWeight`/`getInfo`).
- **Addition — `opts.basic`** (L3): only `me`, `^`, ids, `c:` and names; anything else → `nil, 'not_allowed', token`.
  The `target`/`targets` command params pass `basic = not Perms.has(src, Config.Admin.StaffPerm)` (console: full), and
  lib/commands throttles (100 ms per src) command lines whose selector has a name or set token (reply
  `target_too_fast`; id/me/^/c: lines are O(1) and not throttled).
- Error codes: `bad_actor`, `bad_selector`, `not_allowed`, `not_found`, `ambiguous` (3rd = `{ src, name }` ≤ 10),
  `no_self`, `no_origin`, `bad_radius`, `unknown_group`, `unknown_faction`, `self`, `no_match`, `too_many`.
- Command params: `target` = `resolveTargets(src, word, { max = 1, allowSelf, basic })` → one src; `targets` → an
  array; one word each. Declaring either on the client errors at register. A failed selector replies with a specific
  text (defaults built in; optional `Config.Texts` keys `target_not_found`, `target_ambiguous`, `target_too_many`,
  `target_self`, `target_unknown_group`, `target_unknown_faction`, `target_bad_radius`, `target_no_origin`,
  `target_bad_selector`, `target_not_allowed`, `target_too_fast`) instead of the usage line.
- Tests: `tests/targets_tests.lua` (154: every token, union/negation, ambiguity, caps, early stop, basic grammar,
  throttle, command params in the core VM, a plugin VM through the export proxy and the client VM).

## 50. Routing bucket allocation (`Core.Buckets`, server/buckets.lua)

```lua
Buckets.allocate({ label?, population = false, lockdown = 'strict'|'relaxed'|'inactive' = 'strict' }) -> bucket|nil
Buckets.release(bucket) -> bool                 -- owner only; players still inside are moved to bucket 0
Buckets.info(bucket) -> { owner, label }|nil
Buckets.list() -> array
```
Owner-tracked (kind 'bucket'), allocated from `Config.Buckets.Range = { 10000, 60000 }` (charcreator's studio uses
`1000 + src`, below the range). `allocate` applies `SetRoutingBucketPopulationEnabled` and
`SetRoutingBucketEntityLockdownMode`. Tests: `tests/buckets_tests.lua`.

**Implementation notes (2026-09-26, run W1-PERMS; review L11).**
- Ids are handed out round robin after the last allocated one (wrapping inside `Config.Buckets.Range`), so a
  just-released id is not reused at once; an exhausted range logs an error and answers nil. A `lockdown` outside
  `strict|relaxed|inactive`, a non-boolean `population` or a non-string `label` (kept ≤ 64) refuse the call.
- `release` is owner-only; core (caller `core`) may release any bucket. Evacuation is one pass over `GetPlayers()`
  with `GetPlayerRoutingBucket`; a loaded player goes through `Core.Player.setBucket(src, 0)` (so
  `core:client:bucketChanged` reaches the map runtime, L11), a connected player without a session gets the raw
  `SetPlayerRoutingBucket`. Release is rare (map close, owner stop), never on a timer. Entities left inside are not
  touched (their owner cleans them).
- The owner-stop sweep releases every bucket of the stopped resource; a core stop does not sweep (ids are free again
  after the restart). `info`/`list` also return `population` and `lockdown` (additive). §52's editor buckets are
  allocated AS core, so a plugin stopping does not release them; a map's `targetBucket` may not lie inside the range.
- Tests: `tests/buckets_tests.lua` (48).

## 51. Admin contributions and dispatch (`Core.Admin`, server/adminapi.lua)

Any plugin contributes admin categories, actions, pages and player tabs as **data plus a server handler**; core owns
the registry, the rights snapshot and the one dispatch path, so every action gets the same checks and audit no matter
who wrote it (research §1.2, §7.2). The `admin` resource is only the frontend and the built-in actions; a plugin never
needs `dependency 'admin'` — without the admin resource its registrations are simply not shown.

```lua
Admin.category{ id, label, icon?, order? = 100, permission? }
Admin.action{
  id,                      -- '^[%w_%-%.]+$' ≤ 64, globally unique (convention '<resource>.<verb>'); owner = caller
  category, label, description?, icon?, order? = 100,
  permission?,             -- default 'admin.' .. id; Perms.define'd automatically with `default`
  default? = 'admin',      -- the group that receives the permission once (§44)
  target = 'none'|'player'|'players'|'entity'|'coords',
  self? = true,            -- player targets may include the actor
  hierarchy? = true,       -- every player target must pass Perms.canTarget
  max? ,                   -- 1 for 'player', 50 for 'players'; also capped by Config.Admin.Scope[actor group]
  args? = { Core.Schema fields },
  reason? = 'none'|'optional'|'required',
  danger? = 'none'|'confirm'|'typed',
  cooldown? = 1,           -- seconds, per (actor, action)
  duty? = Config.Admin.RequireDuty,
  echo? = true,            -- tell on-duty staff (actor, action label, targets)
  command? = false|'name', -- also a chat command (target param first, then scalar args in order, reason as `rest`)
  key? = nil,              -- a default key the admin client may bind ('' / nil = unbound)
  hidden? = false,         -- palette/commands only
  handler = fn(ctx) -> ok?, message?, data?
}   -- ctx = { id, actor, targets (array of src | { entity, netId } | vector3), args, reason, source }
Admin.page{ id, category?, label, icon?, order?, permission?, page? = '<ui page id>', provider? = fn(ctx) -> blocks }
Admin.playerTab{ id, label, icon?, order?, permission?, page? = '<ui page id>', provider? = fn(ctx) -> blocks }
Admin.run(actorSrc, id, { targets?, args?, reason?, source?, confirm? }) -> ok, resultOrErr
Admin.snapshot(src) -> { rank = { group, weight, scope }, duty, categories, actions, pages, playerTabs }
Admin.setDuty(src, on) -> bool;  Admin.isOnDuty(src) -> bool
Admin.setMode(src, mode, on, data?) -> bool;  Admin.getModes(src) -> { [mode] = data|true }
Admin.staff(onDutyOnly?) -> array of src;  Admin.echo(text, { perm?, exclude? })
```

- All four registrations are owner-tracked (kinds `adminCategory`, `adminAction`, `adminPage`, `adminPlayerTab`); an
  id is owned by the first registrant; re-registering by the same owner replaces. Handlers/providers are callables
  (`Core.Utils.isCallable`); a provider runs on demand (one hop per view), never on a timer.
- `page` = the plugin's own UI page, opened by the admin frontend as a `modal` on top of the panel with
  `{ target? , params? }` as props (§38 — a plugin cannot render inside another plugin's page). `provider` = a schema
  page rendered by the admin frontend from blocks: `{ kind = 'keyvalue', title?, rows = {{ label, value }} }`,
  `{ kind = 'table', title?, columns = {{ key, label }}, rows (≤ 200) }`, `{ kind = 'text', text }`,
  `{ kind = 'stats', items = {{ label, value, icon? }} }`, `{ kind = 'actions', title?, ids = { actionIds } }`,
  `{ kind = 'form', title?, fields = schema, submit = actionId }`.
- **Dispatch** (`Admin.run`, the only way an action runs), in order; every refusal except cooldown writes an audit row
  with `result = 'denied'`:
  1. action exists → 2. actor loaded (console allowed) → 3. `Perms.has(actor, action.permission)` → 4. duty (console
  exempt) → 5. cooldown (actor, action) → 6. `Schema.checkAll(action.args, args)` → 7. reason policy → 8. targets:
  `player(s)`: array of ids or one selector string resolved with `Player.resolveTargets` (§49); each loaded; `self`;
  `hierarchy` (`Perms.canTarget`); count ≤ min(action max, `Config.Admin.Scope[group]`) · `entity`: `{ netId }` →
  `NetworkGetEntityFromNetworkId` + `DoesEntityExist` · `coords`: vector3 with world bounds → 9. `danger ~= 'none'`
  requires `confirm == true` → 10. `Core.Hooks.run('admin:before', { id, actor, targets, args })` (filter by id) →
  11. handler under `pcall` → 12. audit `ok`/`error` (`action = id`, `source`, targets, reason, `changes` if the handler
  returns them in `data.changes`) → 13. staff echo (`Core.Net.emitMany` to on-duty staff) → 14. observer hook
  `adminAction`.
- Transport (core-owned, rate-limited): callbacks `core:admin:snapshot`, `core:admin:run` (`{ id, targets?, args?, reason?,
  source?, confirm? }` → `{ ok, message?, data? }`, cooldown 100 ms), `core:admin:page` (`{ id, params? }` → blocks),
  `core:admin:playerTab` (`{ id, target }` → blocks); client events `core:admin:echo`, `core:admin:snapshotChanged`
  (to online staff via `emitMany`, debounced 1 s, after `permsChanged`, duty changes and (un)registrations).
- The snapshot contains only what the viewer may use (permission + duty), public fields only (no handlers, no
  `validate`). It is advisory: the server re-checks everything on `run`.
- **Duty** is a session flag mirrored to the server-written player state bag `duty`; **modes** (`noclip`, `vanish`,
  `spectate`, `god`, `editor`) are session state mirrored to `staffModes`; both are audited on change and cleared on
  drop. `server/security.lua` consults `getModes` before flagging invisibility/collision/teleport anomalies.
- Chat commands generated from `command` go through `Core.Commands` and then `Admin.run` with `source = 'chat'`.
- Config: `Config.Admin.RequireDuty = true`, `Config.Admin.Scope = { helper = 1, mod = 5, admin = 50, senior = 200,
  owner = 2000 }` (default 1 for unlisted groups), `Config.Admin.StaffPerm = 'core.admin.staff'`.
- Tests: `tests/admin_api_tests.lua` (every dispatch step and its audit row, snapshot filtering, owner sweep, selectors,
  duty, modes, command generation).

**Implementation notes (2026-09-26, run W2-ADMINAPI; review rounds H1/M1/M2/L1–L13, R2-CLIENT F1, R2-14, R2-15).**
- **Files**: `server/adminapi.lua` (registry, snapshot, provider blocks, duty/modes/staff/echo, the snapshot/page/
  playerTab callbacks) + `server/adminapi_dispatch.lua` (`Admin.run`, `core:admin:run`, chat commands). The private
  state goes from the first to the second through a one-shot metatable slot on `Core.Admin` (cleared once read, not
  reachable through the export, which resolves with rawget): the two files must stay ADJACENT in the manifest.
  `client/adminstate.lua` is the client half (below).
- **Deviation — no replicated staff state (R2-CLIENT F1).** Core writes NO `duty` / `staffModes` state bag: every
  client could read who is on duty, vanished or spectating. Duty and modes are session state sent by event —
  `core:admin:self { duty, modes = { [name] = true } }` to the player itself (every duty/mode change, a mode clear,
  once on `playerLoaded` for staff); `core:admin:staffState { src, duty, modes? }` to the on-duty staff through
  `Net.emitMany` (modes only while on duty; `{ src, duty = false }` when an on-duty member drops);
  `core:admin:staffStates { … }` once to a player that goes ON duty. The server hook `staffModeChanged (src, modes)`
  (a names map; `{}` on clear/drop) feeds §52.3's audience check. **`client/adminstate.lua`** caches self + the staff
  map (dropped when self goes off duty), fires the client hooks `staffSelfChanged (state)` and
  `staffStateChanged (src, state|nil)`, and adds the client proxy functions `Core.Admin.getSelf()` and
  `Core.Admin.getStaffStates()` (display only). `CORE_STATE_KEYS` keeps `duty` and `staffModes` reserved.
  `client/interactions.lua` ignores the interact key (E) while `getSelf().modes` has noclip, editor or spectate.
- **Registry caller per coroutine (M1, §2.3 note).** The `call` export dispatches through `withCaller`; a coroutine
  without its own entry is `'core'`, so a thread core starts never inherits a parked plugin call (on both sides).
- Registration errors are returned as `false, '<key>'` (the offending key, `args:<schema error>`,
  `page_or_provider`, `owned`) and logged. A registration needs no existing category; the snapshot lists a category
  only when the viewer may see it AND it holds a visible action or page. `page` must be a plain UI page id
  (`^[%w_%-]+$` ≤ 64; else `'page'`).
- `permission` defaults to `'admin.' .. id` LITERALLY (`admin.kick` → `admin.admin.kick`; pass `permission` to
  choose), refused above 64 characters; `default = false` defines the permission without a group.
- **Deviations in the dispatch**: (a) the player-target COUNT is checked before the hierarchy, and selectors resolve
  with `max = min(action max, scope)`; (b) the cooldown is stamped when the handler runs AND when the targets are
  refused (a refused selector costs a cooldown), never for the earlier refusals; (c) denied rows have a budget per
  (actor, action id) — one persisted row per 5 s, the refusals in between counted into that action's next row
  (`ctx.suppressed`, R2-14); every unknown id of an actor shares one budget (`core.admin.unknown`, `ctx.requested`);
  `unknown_action`/`not_loaded` of a non-staff actor are never persisted; (d) the audit row's `resource` is the
  action's owner, `ctx = { step, detail?, count?, coords?, suppressed? }`. `invalid_args` returns the `checkAll`
  errors as the 3rd value.
- **Targets**: `player(s)` take a selector string (resolved with `allowSelf = action.self`, so `*` quietly drops the
  actor of a `self = false` action while `me` is refused `self`), one id or an id array (≤ 2000 entries,
  de-duplicated, JSON floats accepted); `entity` takes `{ netId }` or `{ { netId } }` — **entity targets pass the
  hierarchy too** (a player ped via `IsPedAPlayer` → `NetworkGetEntityOwner` → `GetPlayerPed`, and every player in
  seats -1..14 of a vehicle; an unmatched player ped is refused `rank`); `coords` a vector3 or `{ x, y, z }`. The
  console has no scope cap (only the action max).
- `danger = 'typed'` is checked like `'confirm'` on the server (the typed text is a UI concern). A generated chat
  command is its own confirmation (`confirm = true`) and runs with `source = 'chat'` (`'console'` from src 0).
- **Chat commands**: the target param first (`target`/`targets`; entity → `netId`; coords → `x y z`), then args mapped
  boolean/integer/duration/player/number/heading/string-likes/scalar enums; an optional arg followed by a required
  param is left out; with `reason = 'none'` the last string arg becomes `rest`, else the reason is `rest`. Unmappable
  args or reserved arg names (target, targets, netId, x, y, z, reason) skip the command with a warning; an existing
  command is never replaced. `Core.Commands` checks the permission first, so a chat attempt without it is not audited.
- **Transport** (every callback StaffPerm-gated): `core:admin:snapshot` (1000 ms), `core:admin:page` /
  `core:admin:playerTab` (250 ms), `core:admin:run` (100 ms — H1: a non-staff request is answered nil before any work
  or audit row; an action meant for everyone is reached through its chat command or the owning plugin's own RPC).
  `core:admin:playerTab` refuses `rank` when the viewer may not target the player, unless the tab sets
  `hierarchy = false` (addition). A client may claim only `source` menu/palette/editor (else menu). Answers:
  snapshot | nil; `{ ok, page?, blocks? }` / `{ ok = false, error = 'unknown'|'no_permission'|'rank'|'payload'|
  'error' }`; run `{ ok = true, message?, data? }` / `{ ok = false, error, message, data? }`.
- **Addition**: pages and player tabs take `duty` (default `Config.Admin.RequireDuty`), enforced in the snapshot and
  the callbacks. Provider blocks are sanitised: ≤ 32 blocks, unknown kinds dropped, table rows ≤ 200 with only the
  declared columns, cells scalar ≤ 512 chars, text ≤ 4096, `actions.ids` filtered to what the viewer may use, a
  `form` whose `submit` the viewer may not use dropped, form fields through `Schema.public`.
- **Staff** = loaded holders of `Config.Admin.StaffPerm`, a set updated on `playerLoaded`, `permsChanged(src)`,
  `permsChanged(nil)` (coalesced: one walk per 1 s window) and `playerDropped`; runtime ACE changes are seen at the
  next permsChanged/load. Losing the staff permission ends the duty and the modes. Going off duty turns every mode
  off (each audited and sent). Duty/mode rows: `core.admin.duty` / `core.admin.mode` with `changes = {{ key, old,
  new }}`. Mode names are open (`^%a[%w_]*$` ≤ 32, ≤ 16 per player); clients only ever get `{ [mode] = true }` —
  mode data (spectate target, …) stays on the server (`getModes`). `Admin.staff()` is O(staff).
- `snapshotChanged`: one 1 s debounce over a pending set; no payload, the client refetches. The action echo
  `core:admin:echo { text, at, id, label, actor = { src, name }, targets (≤ 10), count }` goes to on-duty staff except
  the actor after an ok run; `Admin.echo` sends `{ text, at }`. `adminAction` runs after every executed handler (ok
  and error), never for refusals.
- **§4.8 legacy commands (R2-15)**: core's own staff commands (`/tp /tpto /bring /car /dv /setcash /setbank /givecash
  /givebank /setgroup /kick /ban /announce /revive /heal /weapon /weapons` and the `/tpm` handler) follow this
  section's duty rule (`Config.Admin.RequireDuty`; without Core.Admin they are refused), write an audit row
  `core.cmd.<name>` and echo to on-duty staff — but do NOT run `admin:before`. They check ranks themselves (`/kick`,
  `/ban`, `/bring`, money, `/setgroup`, `/weapons`, `/dv` occupants; `/tpto` refuses only a vanished/spectating
  higher-ranked target). `Config.Admin.LegacyCommands = false` registers none of them (servers with the admin plugin);
  `/id`, `/players` and `/faction` always stay. `/weapon(s)` moved from weapons.lua to admin.lua
  (`Weapons.isAllowed` is the public name rule).
- **security.lua**: there are no invisibility/collision/teleport detections yet; `Security.isStaffExempt(src, what)`
  maps what → sanctioning modes (invisible: vanish/noclip/spectate/editor; collision + teleport: noclip/spectate/
  editor; god: god/noclip/spectate/editor; speed: noclip/editor) and `report()` consults it for every kind.
- Tests: `tests/admin_api_tests.lua` (349, harness `tests/admin_harness.lua`), `tests/registry_caller_tests.lua` (26),
  `tests/client_registry_caller_tests.lua` (31), `tests/client_adminstate_tests.lua` (34); the legacy commands in
  `tests/server_tests.lua`.

## 52. Maps: element types, documents, live editing and the region runtime (`Core.Maps`)

Files: `server/maps.lua` (types, documents, apply, publish, journal, networked elements), `server/maps_regions.lua`
(regions, packs, subscriptions, pushes), `client/maps.lua` (window, cache, streaming, spawning). World content placed by
admins — permanent maps and **live event maps** — for every player, at 1,000–2,000 players. Designed from scratch for
low-churn, high-volume content (research §3.3g); it does not reuse the inventory's drop scoping.

**Since 2026-09-27 (phase D, §55.21.1)** Core.Maps is an authoring layer on `Core.Scene`: §52.1 and §52.2's API stand;
the networked-entity part of §52.2 and the whole region runtime of §52.3–§52.4a are superseded (each section says so).
Files now: server/maps_types.lua → maps_runtime.lua (the projector onto scene nodes) → maps.lua → maps_apply.lua;
client/maps_preview.lua (the editor view) → client/maps.lua (the facade).

### 52.1 Element types (the EDF successor)

```lua
Maps.defineType{
  id = 'garage:spot',       -- '^[%w_%-]+:[%w_%-]+$', owner-tracked (kind 'mapType')
  label, icon?, category? = 'Gameplay', description?,
  kind = 'prop'|'vehicle'|'ped'|'marker'|'hide'|'point'|'zone',
  model? = 'prop_name',     -- fixed model; otherwise prop/vehicle/ped types need a field `model` of Schema type 'model'
  fields? = { Schema fields },
  preview? = { { kind = 'marker', type, scale?, color? } | { kind = 'box', size } | { kind = 'sphere', radius }
               | { kind = 'label', text = 'literal or $field' } },     -- editor view only, declarative (no callbacks)
  transform? = { rotate = 'full'|'yaw'|'none' },
  networked? = false,       -- prop kind only: a server-created networked (physics) object
  limits? = { perMap? }, parents? = { typeIds },
  validate? = fn(record, ctx) -> ok, err,     -- server, on create/update; ctx = { mapId, actor, op }
  version? = 1, migrate? = fn(fields, fromVersion) -> fields,
}
Maps.types() -> public list (no functions)
```
Built-ins (owner core): `core:prop`, `core:physprop` (networked), `core:vehicle`, `core:ped`, `core:marker`,
`core:hide` (world model hide), `core:point`, `core:zone` (box, `size` + rotation). A record whose type is not
defined (its resource stopped or was removed) is **kept** and shown as a placeholder; it is never dropped.

### 52.2 Documents and modes

- Map `{ id, name, mode = 'draft'|'live', active, targetBucket = 0, publishedVersion, nextElementId, meta = { description },
  limits?, expiresAt?, createdAt, createdBy, updatedAt }` in collection `maps`; elements one document each in
  `map_elements` (id `<mapId>:<elementId>`) so a commit writes only what changed; published snapshots in `map_versions`
  (`{ mapId, version, elements, by, note, at }`); commands in `map_journal` (≤ `maps.journalMax` 5000 per map, pruned).
- Element `{ id, type, typeVersion, pos = {x,y,z}, rot = {x,y,z}, fields, layer = 'default', cam?, by, updatedAt }`
  (model **names**, Euler degrees, rotation order 2).
- **live** map: every change affects the world immediately in `targetBucket` while `active` (events: build while players
  watch); optional `expiresAt` → deactivated by Cron (not deleted); `Maps.clear` empties it in one command.
- **draft** map: `Maps.openDraft(id) -> bucket` allocates an editor bucket (§50) in which the draft is live for whoever
  is in that bucket (the editors); `closeDraft` releases it. The world sees the **published** snapshot (if `active`)
  in `targetBucket`; `publish` snapshots the draft, `rollback(version)` publishes a copy of an older snapshot.

```lua
Maps.create({ name, mode, targetBucket?, meta?, expiresAt? }, actor) -> map|nil, err
Maps.get(id) / Maps.list({ mode?, active?, text? }) / Maps.update(id, { name?, meta?, expiresAt?, targetBucket? }, actor)
Maps.delete(id, actor) / Maps.setActive(id, on, actor)
Maps.elements(id) -> array (the draft/live elements)
Maps.apply(id, ops, actor, { source?, expect? = { [elementId] = updatedAt } }) -> ok, applied | nil, err, detail
--   ops (≤ maps.limits.opsPerApply): { op = 'create', type, pos, rot?, fields?, layer? }
--                                    { op = 'update', id, set = { pos?, rot?, fields? (partial), layer? } }
--                                    { op = 'delete', id }
--   all-or-nothing; applied = { seq, ops = { { op, id, before?, after? } } }; `expect` → 'conflict' if changed since
Maps.invert(applied) -> ops                      -- for undo
Maps.publish(id, actor, note?) -> version / Maps.versions(id) / Maps.rollback(id, version, actor)
Maps.openDraft(id, actor) -> bucket / Maps.closeDraft(id)
Maps.clear(id, actor) -> ok, applied
Maps.journal(id, { limit?, before?, author? }) -> rows
Maps.respawn(id, elementId?)                     -- re-create destroyed networked elements
Maps.setModelValidator(fn(kind, model) -> ok, info)   -- one validator, owner-tracked; info.vehicleType for vehicles
Maps.on(typeId, fn(event, record, mapId)) -> handle   -- 'added'|'changed'|'removed' for ACTIVE world content, owner-swept
Maps.records(typeId) -> array                         -- active world content of that type
```
- `apply` validates every op before applying any: type (new elements need a defined type), world bounds, finite
  rotation (restricted by `transform.rotate`), `Schema.checkAll` on fields, model via the validator (props without a
  validator: name pattern only; vehicle/ped/physprop without one: refused), parents, per-type and per-map limits
  (`maps.limits.*` settings: elements 3000, perModel 300, uniqueModels 200, networked 20, networkedTotal 200,
  opsPerApply 200), `type.validate`, then `Core.Hooks.run('maps:beforeApply', …)`. Journaled; not audited per call
  (publish, rollback, clear, delete, setActive, create are audited).
- Networked elements (`core:vehicle`, `core:ped`, networked props) are created by the **server** when their content
  becomes active (`CreateVehicleServerSetter` / `CreatePed` / `CreateObjectNoOffset(…, true, true, true)` + rotation),
  put in the bucket (`SetEntityRoutingBucket` — server entities start in bucket 0), `SetEntityOrphanMode(e, 2)`, state
  bag `mapEl = '<mapId>:<id>'`; deleted with their element or when the content deactivates; not respawned
  automatically (`Maps.respawn`).
- Core.Maps is a trusted server API: callers authorise their users (the admin plugin checks editor permissions). The
  only client-facing endpoints are the read-only region callback and events below.

**Implementation notes (2026-09-26, run W2-MAPS) — §52.1/§52.2 server.**
- **Deviation — four files** instead of `server/maps.lua`: `maps_types.lua` → `maps_runtime.lua` → `maps.lua` →
  `maps_apply.lua` (manifest order required; each asserts its predecessor). They share the internal
  `Core.MapsRuntime`, block-listed in the export next to `MapRegions`. maps_runtime.lua is the MapRegions caller
  (looked up at call time, pcall'ed).
- Ids: maps `m<n>` (`DB.nextId('maps')`); element ids are digit strings counted per map; `apply` accepts integer or
  string ids (and `expect` keys). An element's `updatedAt` is a strictly increasing wall-clock MILLISECOND stamp; Core.DB
  overwrites a document's top-level `updatedAt` with seconds, so the element document stores it as `rev`. Map
  `createdAt/updatedAt/expiresAt` are unix seconds.
- Additive element key `info = { lod?, vehicleType? }` — the validator's answer, kept so activation never needs the
  validator (registered by a plugin that starts after core). Tuple lod = `info.lod` else 150; vehicles spawn with
  `info.vehicleType` else `'automobile'`. Validator results are cached per `<kind>:<model>` (≤ 4096) until it changes.
- **Additions to ops**: create may carry `id` (a free id) and `cam`; update takes `set.cam` and `replace = true`
  (fields replaced instead of merged). **Restore ops** (review L6): `{ op = 'create', id, restore = <record> }` and
  `{ op = 'update', id, restore = <record> }` bring back a raw earlier record — type (defined or not), fields,
  typeVersion, info, cam — with only position/rotation/layer checked (no Schema, model, `type.validate` or ref check
  on the restored element; limits, parents, `referenced` and the hook still run); an update-restore keeps the
  element's creator and needs the same type. **Deviation**: `invert(applied)` returns `ops, expect` and emits restore
  ops; expects are per step (after undoing one step, rebase the next on the undo's own `applied`). `expect` mismatch →
  `'conflict'`, detail `{ id, current }`. Automatic ids stop at 999 999 999 and an explicit id past it is refused
  (`'id'`, L7). Deleting an element another untouched element still references → `'referenced'` (detail `{ id, by }`;
  L8).
- Validation order: expect → per op (type, position/bounds, rotation, fields, layer, model) → refs → parents → limits →
  `type.validate` → `maps:beforeApply`. Rotation wraps to (-180, 180], 0.01; a `'yaw'` type refuses pitch/roll,
  `'none'` any. Bounds x/y ±10000, z −1000..3000.
- Limits refuse only an apply that RAISES a count above its limit (lowering a limit never blocks deletes/moves).
  Per-map `limits = { elements, perModel, uniqueModels, networked }` via create/update. `networkedTotal` counts
  networked elements of every ACTIVE context (a closed draft costs nothing) and is also checked by `setActive(true)`,
  `openDraft`, `publish`, `rollback`. Hides do not count as models. `parents`: only a newly introduced violation is
  refused. `ref` fields (top level) must name an element of the staged map (of `refType` when given). `migrate` runs
  when an element with an older `typeVersion` gets new fields, not at define time.
- Hook payload `maps:beforeApply`: `{ mapId, mode, actor = by, source, count, ops = first 200 { op, id, type, model?,
  pos } }`.
- **Placeholders**: a record of an undefined type is packed as kind 4 with flags 8|16 and hash 0 (editor view only)
  and re-rendered when the type returns; networked ones despawn meanwhile; pos/rot/layer stay editable, fields do
  not (`'type'`).
- Prop flags: collision unless `fields.collision == false`, frozen unless `fields.frozen == false`, unbreakable when
  `fields.unbreakable == true`. Marker `bob`/`face` are booleans, `dd` 2 decimals.
- **Networked entities**: one spawn worker (exists only while queued), 5 s existence wait (a cancelled spawn still
  waits so it can delete). Bucket → orphan mode 2 → state bags `mapEl = uid` and `mapCfg` (§52.4a addendum) →
  cosmetic RPC natives (plate, colours, doors, freeze, rotation). A change updates the entity in place when it can (notes below); core stop deletes
  every map entity.
- Activation per map (`R.syncMap`): live + active → working set in `targetBucket`; draft + active → published
  snapshot there; open draft → working set in its editor bucket. publish/rollback swap the target context by diff (id,
  type, updatedAt). Closing a draft clears its editor bucket with one `clearBucket` when nothing else renders into it.
  A `targetBucket` that is an open editor bucket is refused. The editor bucket is allocated AS core (owner core,
  population off, lockdown strict); the opener is owner-tracked (kind `mapsDraft`) and its stop closes the draft.
  `rollback` leaves the draft untouched (and dirty). Versions: the newest 20 kept (candidate setting).
- **Addition — events**: `Maps.on(typeId|'*', fn)` / `Maps.off(handle)` (kind `mapsListener`), delivered by one drain
  thread after the context pass; records carry `bucket`, `key` (`'<bucket>|<uid>'`) and `editor` (editor buckets emit
  too, so a gameplay type works in the editor's test). Not replayed: seed with `records()`.
- Audited: create, update (addition), delete, setActive (expiry: actor `'system'`, `ctx.reason = 'expired'`),
  publish, rollback, clear. Journal rows `{ mapId, seq, at (s), by, actor = { kind, src, name }, source, count, ops }`
  (M7): update entries store only the changed keys (+ `after.updatedAt`), a clear row is `{ clear = true, count, ids }`;
  each row weighs its stored ops, pruned per map to `maps.journalMax` rows AND the new setting `maps.journalMaxOps`
  (20000) weight (the newest row always stays) and server-wide to 200000 (the oldest rows of the heaviest map go
  first). `apply`/`clear` still RETURN full before/after records. `rollback` re-runs today's model validator
  (`'model'`/`'no_validator'`, detail `{ ids }`) and the per-map limits on the snapshot (L9). A `targetBucket` inside
  `Config.Buckets.Range` is refused (L10). Expiry: `Cron.every(10 s)` (warns when Cron is missing).
- Loading: one barrier for all four collections; journal/version indexes through a non-copying `DB.find` predicate;
  a degraded `maps`/`map_elements` makes the API answer `'unavailable'` (retry every 10 s). Callback
  `core:maps:types`: public data, no permission, 1000 ms cooldown. Registry kinds: `mapType`, `mapsModelValidator`,
  `mapsListener`, `mapsDraft`. Tests: `tests/maps_tests.lua` (301) + `tests/maps_store_tests.lua` (72; journal, clear,
  expiry, delete, rollback, persistence, async barrier), shared harness `tests/maps_harness.lua`.

**Implementation notes (2026-09-26, run UX C2) — networked elements updated in place, stable paint.**
- **Why**: every change re-created vehicles, peds and physics props (hide + show), so moving or rotating a vehicle
  gave it new random colours, a flicker and a new net id (Liam, editor test).
- **In place** (`maps_runtime.lua` `updateNet` → `moveInPlace`): a changed networked element keeps its entity when
  its type, kind and model are unchanged, the entity exists with `mapEl` = its uid in the context's bucket
  (`GetEntityRoutingBucket`), a CLIENT owns it (`NetworkGetEntityOwner >= 1`) and it is alive (vehicles/peds:
  `GetEntityHealth > 0`, the synced health node). The config goes out as context RPCs + the `mapCfg` bag (set only
  when it changed): plate (`SetVehicleNumberPlateText`), custom colour, `locked` on AND off
  (`SetVehicleDoorsLocked` 2 / 1), ped `frozen` on and off (`FreezeEntityPosition`), a cleared scenario
  (`ClearPedTasks`); invincible on / another scenario / a prop's `rot` ride `mapCfg` (the client applies "on"
  states). **Everything else keeps the respawn path**: another type/kind/model, the entity missing, dead, not
  ours or in another bucket, a server-owned entity (nobody has it in scope, so a re-creation is exact and unseen),
  and the three transitions only a re-creation undoes — a cleared plate, a cleared custom colour (the clearing
  natives are client-only; `SET_VEHICLE_COLOURS` does not clear it, GTA `commands_vehicle.cpp`) and a ped that
  stops being invincible (`SetEntityInvincible` is client-only). Instance states: still queued → nothing (the
  worker reads the latest element when it starts); being created or failed → re-created (the creating one is
  deleted once it appears, as before); configured → in place or re-created.
- **The pose goes to the owning client** — event `core:maps:pose (netId, uid, x, y, z, rx, ry, rz)`, sent only to
  `NetworkGetEntityOwner(entity)`: the server's `SET_ENTITY_COORDS` RPC adds the ped capsule's ground-to-root offset
  (~1 m) to peds and `GetDistanceFromCentreOfMassToBaseOfModel` to vehicles (GTA `commands_entity.cpp`,
  `SetPedCoordinates` OffsetZ, `SetCoordsOfScriptCar` bAddOffset), while the server-setter creation puts the ROOT at
  the authored position — a frozen ped would hover and a vehicle drop. client/maps.lua applies it with
  `SetEntityCoordsNoOffset(e, x, y, z, keepTasks = true, keepIK = false, warp = true)` + `SetEntityHeading(rz % 360)`
  (vehicles, peds — they are created with a heading) or `SetEntityRotation(rx, ry, rz, 2)` (physics props), only
  while it has network control and the entity's `mapEl` is that uid. **Verification**: `SetTimeout(2000)` later the
  server reads the synced `GetEntityCoords` / `GetEntityHeading` and re-creates the element at the target only when
  the move did NOT land (control migrated meanwhile): the entity is > 0.75 m (horizontal) from the target and within
  0.75 m of its pre-move pose — the pose before the last move or, for a burst of moves before one check, before the
  first (`prevPose`, `anchor`) — or, for vehicles and peds standing at the target position, its heading is > 20°
  off the target and within 20° of a pre-move heading. An entity that landed and then moved on (driven away, a
  kicked prop, a bumped ped) is left alone (review F2), and so is a vehicle with any occupant
  (`GetPedInVehicleSeat` seats −1..15 ≠ 0). Only the latest move of an instance is checked (`poseSeq`).
- **Reused handles (review F1)**: server entity handles are script-handle pool slots that the next entity gets once
  one is gone (a client may delete a map entity). The runtime therefore deletes an instance's entity (re-create,
  despawn, deactivation, core stop) and treats it as alive (`Maps.respawn`, `moveInPlace`, the pose check) only while
  `DoesEntityExist(e)` and `Entity(e).state.mapEl == uid` (`ours`); a foreign entity on the handle is never deleted,
  and the element counts as destroyed (respawn path). The one unchecked delete is the handle the create native just
  returned (an instance cancelled while it was being created). `Maps.respawn` also leaves an instance that is still
  being created alone now, as its contract said.
- **Stable paint**: `configureEntity` calls `SetVehicleColours(e, primary, secondary)` with a pair picked by
  `joaat(uid) % 22` from a curated list of normal paints (metallic black, graphite, silver, dark silver, shadow
  silver, gun metal, white, frost white, red, cabernet, orange, race yellow, green, racing green, dark blue, blue,
  bright blue, midnight blue, bronze, champagne, golden brown, purple); a set `color` (custom primary + secondary)
  is applied after it and wins. The same uid gets the same paint on every spawn and in the editor bucket as in the
  target bucket. `R.paintOf(uid)` is internal.
- **Fixed — lost spawns**: `queueSpawn` appended at `#spawnQueue + 1`; once the worker had nil'ed the consumed head,
  `#` read 0 and an instance queued while the worker waited on its last creation landed behind the head and was
  dropped. The queue now keeps an explicit tail.
- Also in place now: a type redefined by its owner (`refreshType`) and publish/rollback (`swapContext`) re-render
  unchanged or moved networked elements without re-creating them. Activation, deactivation, a draft opening or
  closing and a `targetBucket` change still create/delete (the content appears/disappears or changes bucket).
- Natives added (fxref + natives_cfx.json, server): `SetVehicleColours`, `ClearPedTasks`, `GetEntityRoutingBucket`,
  `GetEntityHealth`, `GetEntityCoords`, `GetEntityHeading`, `NetworkGetNetworkIdFromEntity`, `GetPedInVehicleSeat`,
  `NetworkGetEntityOwner` (shared); client: `SetEntityCoordsNoOffset`, `SetEntityHeading`.
- Tests: `tests/maps_tests.lua` 409 (was 301; new sections "networked elements updated in place, stable vehicle
  paint" and "review fixes" — reused handles, the pose check), `tests/client_maps_tests.lua` 250 (was 239; section
  19b2 the pose event). Harness: `H.owners[e]` /
  `H.owner` (NetworkGetEntityOwner), `H.rpcs` + `H.rpcCalls(name)`, `H.poses(from)`.

**Superseded (2026-09-27) by §55.21.1 — the networked-entity machinery.** Documents, modes, apply / invert / journal,
publish / rollback, drafts, limits and the events above stay. What went: the server's networked-entity worker, the
`mapEl` / `mapCfg` state bags, the in-place update (`updateNet` / `moveInPlace`), `core:maps:pose` and its 2 s
verification. Every shown element — vehicles, peds and networked props included — is now ONE `Core.Scene` node
(server/maps_runtime.lua is a projector); vehicles and physics props become networked only while the scene promotes
them (§55.15), and a move of a promoted node demotes it at the new pose. The stable paint survives: a map vehicle
takes `Scene.PAINTS[joaat(uid) % 22 + 1]` (the same list as above). `Maps.respawn` puts nodes back to their authored
state (§55.21.1 notes). The `networked` / `networkedTotal` limits still count vehicle, ped and networked-prop elements.

### 52.3 Server regions

- The world is cut into **regions** of `Config.Maps.RegionSize` (512 m), integer key `(rx + 32768) * 65536 + (ry + 32768)`.
  Per (bucket, region): `version` (monotonic), the active client-rendered element refs, and a **pack** — one string
  `json.encode({ v, e = { tuples } })` built lazily on the first request after a change and cached until the next one,
  so N clients fetching a region cost one encode. Tuple: `{ uid, kind, modelHash, x, y, z, rx, ry, rz, flags, lod, extra? }`
  (`flags`: 1 collision, 2 frozen, 4 unbreakable, 8 editor-only helper, 16 data kind — `point`/`zone` are packed for the
  editor view and ignored by the runtime).
- Callback `core:maps:window` (cooldown 250 ms): `{ c = centreKey, h = { [key] = version } }` (≤ 9 entries). The server
  takes the bucket from `GetPlayerRoutingBucket(src)` (never from the client), moves the player's subscription to the
  3×3 keys around `c`, answers `{ b = bucket, v = { [key] = version } }`, and sends every region whose version differs
  from `h[key]` with `TriggerLatentClientEvent('core:maps:pack', src, Config.Maps.LatentBps, bucket, key, pack)` (a
  Lua runtime helper, bandwidth-limited: a join or a teleport never floods the reliable channel). Empty regions are
  answered inline as version 0. The client's position is trusted only for *which public content to download*.
- Changes bump the region version and are coalesced per server tick: ≤ `Config.Maps.PushOpsMax` (32) element changes →
  `Core.Net.emitMany(subscribers, 'core:maps:delta', bucket, key, fromV, toV, opsJson)`; more → `core:maps:stale`
  (bucket, key, toV) and the clients re-fetch through the window callback. A client whose version ≠ `fromV` re-fetches.
- Subscriptions `subs[bucket][key] = { [src] = true }` change only when a client re-centres; cleared on drop and on a
  bucket change (`core:client:bucketChanged`, §48). No loop over players anywhere.

**Implementation notes (2026-09-26, run W2-REGIONS).**
- **Versions come from one module-wide counter; 0 = empty.** A region that runs empty is answered as 0 and its table
  is dropped; when it fills again it gets a fresh counter value, so a version never repeats with other content (no ABA
  across evict/recreate). "Monotonic per region" therefore holds for non-zero versions only.
- **Identity is (bucket, uid)**: the same uid may live in several buckets (a draft in its editor bucket and the
  published copy in `targetBucket`). A move across regions queues `del` + `put`; across buckets it is the caller's
  `remove` + `put`.
- The tuple shape is checked on `put` (a NaN would make rapidjson throw inside the flush); encodes are `pcall`ed (a
  delta that does not encode becomes a `stale`; a pack that does not encode is skipped and logged).
- **Flush before answer**: a window request first flushes pending pushes, so a new subscriber gets the fresh pack and
  never a delta it already has.
- **Addition — per-src pack budget** (anti-abuse): a token bucket per player, capacity `Config.Maps.PackBudgetBytes`
  (2,000,000) refilled linearly over `PackBudgetWindowMs` (10,000) — 200 kB/s sustained, 2 MB burst; a pack costs its
  string length; the centre region is served first; a pack larger than the whole capacity goes out from a full
  bucket into debt. Withheld keys are listed in the answer's `w` (§52.4a addendum); `stats().withheld` counts them.
- **Addition — per-subscription pack memory**: the server remembers which version of each window region it already
  sent to a src during the current subscription, so a client spamming the same window cannot multiply outbound
  bytes; the memory for a key goes when it leaves the window, all of it on a bucket change.
- `clearBucket` queues a stale (toV 0) per region that had content; a clear and a refill in one tick coalesce.
- Config: `RegionSize` read once (clamped 64..4096; the key encoding depends on it); `LatentBps` (≥ 1000) and
  `PushOpsMax` (0..1000, 0 = always stale) read live. Window validation: schema (≤ 2 keys, `c` integer 0..2^32-1,
  `h` ≤ 9 keys) before the cooldown, `h` entries (integer keys and versions ≥ 0) in the handler; only the 9 block keys
  are consulted. Bucket changes are detected at the next window request (`GetPlayerRoutingBucket`).
- **Addition — two audiences (review M6).** Data kinds and editor helpers (flags 16/8) reach EDITORS only: a src
  is an editor when Admin mode `editor` is on or its bucket is an open draft's editor bucket, decided per window
  request and stored per subscription. **Deviation from "one version per region"**: each region has a full version
  `v` (editors) and a public `pv` from the same counter (`pv = v` while nothing is hidden, 0 when nothing public is
  left), two cached packs, and deltas split per audience (a data-only edit sends the public nothing). A client still
  sees one version per region, and a number never names two contents, so a client that switches audience is always
  detected as stale by its `h`. A public client sees a region with nothing public as `v = 0`.
- **Losing the audience applies at once (R2-8)**: `MapRegions.reaudience(src)` downgrades an editor subscriber that
  left its bucket or the editor role, switches its subscriptions to public and sends `core:maps:stale (bucket, key,
  pv)` where the views differ; triggered by the `staffModeChanged` / `permsChanged` hooks, with a per-flush re-check
  of every editor target of a dirty region as the backstop (covers `setBucket` and the bucket evacuation). A GAIN
  still waits for the client's next window request.
- Extra internal helpers: `keyOf(x, y)`, `version(bucket, key) -> full, public`, `unsubscribe(src)`,
  `reaudience(src, modeOn?)`; `stats().hidden`; `put` also requires an integer `flags`.
- Risks: the budget bounds each client, not the server total; latent events need `sv_enableNetEventReassembly`
  (default true) or packs never arrive. Tests: `tests/maps_regions_tests.lua` (272).

**Implementation notes (2026-09-27, run M0 — the editor live-update bug).** The per-subscription pack memory is also
dropped on an AUDIENCE change — when a window request subscribes a src as the other audience, and when
`reaudience` downgrades an editor — so the new audience's packs are sendable again (before, the memory of what went
to the OLD audience could hold back the packs of the new one). Tests: `tests/maps_regions_tests.lua` 288.

**Superseded (2026-09-27) by §55.21.1.** The region runtime is gone: server/maps_regions.lua (`Core.MapRegions`,
also removed from the export block-list), the `core:maps:window` callback, the `core:maps:pack|delta|stale` events,
the region packs, the per-src pack budget and `Config.Maps.RegionSize … PackBudgetWindowMs`, and
`tests/maps_regions_tests.lua`. Map content streams as `Core.Scene` nodes (§55.5–§55.7: cells, journals, the
per-player pack budget); the editors-only audience of data kinds and helpers is the scene audience `{ editors =
true }` on `map:data` nodes. This section is kept as the record of the region design.

### 52.4 Client runtime (client/maps.lua)

- **Window**: a thread samples `GetFinalRenderedCamCoord()` (camera, so noclip/editor/spectate stream where you look)
  every 500 ms (1000 ms after 5 still samples) and re-centres when the camera is more than `WindowHysteresis` (64 m)
  outside the centre region; it sends its cached versions so unchanged regions cost nothing. Up to
  `CacheRegions` (25) regions stay cached after leaving the window (versions are re-checked on return).
- **Index**: elements of loaded regions go into a 64 m spawn grid; each element spawns within `r = clamp(lod, 30,
  MaxSpawnRadius 400)` of the camera and despawns beyond `r + 15`.
- **Streaming** (one thread): evaluates only when the camera moved ≥ 4 m since the last evaluation or content changed,
  visiting only grid cells within `MaxSpawnRadius`; queues spawns nearest-first (16 m distance rings, no full sort) and
  despawns; creates ≤ `SpawnPerFrame` (8) and deletes ≤ `DespawnPerFrame` (32) per frame, with `Wait(0)` **only while a
  queue is non-empty**, otherwise 100 ms (moving) / 500 ms (still). No allocation in the evaluation loop (reused
  arrays, integer keys). Cap `MaxLocalObjects` (1500): the farthest wanted elements beyond it stay unspawned.
- **Models**: ref-counted; `RequestModel` once, polled in the spawn step, 10 s timeout marks the element failed for the
  session (logged once); `SetModelAsNoLongerNeeded` 30 s after the last instance went.
- **Objects**: `CreateObjectNoOffset(hash, x, y, z, false, false, false)`, `SetEntityRotation(e, rx, ry, rz, 2, false)`,
  frozen/collision/unbreakable per flags, `SetEntityLodDist(e, lod)`; never `PlaceObjectOnGroundProperly` (positions
  are authored). **Markers**: gathered per evaluation within their draw distance, drawn by a per-frame loop that exists
  only while that list is non-empty (≤ 64). **Hides**: `CreateModelHide` on region load, `RemoveModelHide` on unload.
- Client API (proxy): `Maps.isAreaReady(coords, radius = 50) -> bool`, `Maps.waitAreaReady(coords, timeoutMs) -> bool`
  (teleports in §48 wait for it, so nobody lands before an event platform exists), `Maps.handleOf(uid) -> entity|nil`,
  `Maps.uidOf(entity) -> uid|nil`, `Maps.hold(uid)` / `Maps.release(uid)` (the runtime leaves a held element alone
  while an editor drags it), `Maps.setEditorView(on)` (owner-tracked: draws previews of data kinds and editor-only
  helpers within 150 m), `Maps.stats() -> { regions, elements, spawned, queued, models, failed }`.
- Budget: idle and still = one distance check per 500 ms; moving through dense content ≤ 0.05 ms average in resmon.

**Implementation notes (2026-09-26, run W2-MAPS-C).**
- **Deviation — three files**: `client/maps_spawn.lua` (engine: grid, evaluation, queues, models, objects, holds,
  readiness) → `client/maps_view.lua` (the one draw loop, hides, editor view) → `client/maps.lua` (wire, regions,
  window, API). They hand over through a one-shot global `CoreMapsEngine` that maps.lua clears; nothing internal is
  on `Core`, so the export cannot reach it.
- **Window**: sampled only once `LocalPlayer.state.loaded == true`; one request in flight, ≥ 300 ms apart,
  coalesced; `h` carries `pending or version` per key as integers; a nil answer retries after 2 s; a safety request
  every 60 s even when still. A different `b` resets everything; `v = 0` empties a region; `w[key]` keeps the cached
  content, marks the region not ready and re-asks after 2 s; a pack announced but not landed after 15 s is asked for
  again; an answer to a request sent before a local `bucketChanged` is ignored.
- **Editor audience**: the client listens to `staffSelfChanged` (seeded from `Core.Admin.getSelf()` at load); on an
  `editor` flip the window regions' versions are forgotten (content kept until the new packs land, regions not ready),
  cached out-of-window regions are dropped and the window is asked again; answers to requests sent before the flip are
  ignored.
- **Versions**: each region keeps `floor` = the highest non-zero version seen; a pack/delta at or below it is stale
  and ignored (a late pack never resurrects an emptied region); a delta applies only when `fromV == version`, else the
  region is re-fetched. Regions leaving the window stay cached (LRU, `CacheRegions`); cached regions keep their hides,
  their props never spawn.
- **Evaluation**: 64 m cells keyed like regions, props/markers/data kept apart per cell with conservative bounds and
  counts; a cell wholly out of range with nothing spawned, or wholly in range with every prop spawned or failed, is
  skipped. **Measured: 0 bytes allocated per steady-state evaluation.** Objects awaiting deletion still count
  against `MaxLocalObjects`.
- **Queues**: ≤ `SpawnPerFrame` creations, ≤ `DespawnPerFrame` deletions, ≤ 64 entries looked at per frame; `Wait(0)`
  only while a queue holds work, 50 ms polls while only models stream, else 100 ms / 500 ms; nothing loaded = a bare
  500 ms sleep with no native. A refused create (pool full) pauses creation for 1 s.
- **Models**: `IsModelInCdimage` + `IsModelValid` first (a missing model fails at once, never requested), then
  `IsModelAVehicle` / `IsModelAPed` (a vehicle or ped model in a prop tuple fails the same way — hardening); one
  `HasModelLoaded` poll per model at ≤ 20 Hz; 10 s timeout fails every element of that model for the session,
  logged once. **Objects**: flag 4 → `SetEntityInvincible` + `SetDisableFragDamage`; unchanged elements keep their
  objects across a new pack version; a changed position/rotation/lod with the same model and flags moves the object
  in place; another model or flags re-creates it; a uid that changes region hands its object over (no blink).
- **Holds** (kind `mapHold`): per uid, per owner; changes arriving meanwhile apply on release; a copy the server
  deleted while held stays until released. Holding does not stop a not-yet-spawned element from spawning.
- **Readiness**: every region overlapping the circle in the window, versioned, not pending, not withheld, in our
  bucket; then every prop within `min(radius, its r)` spawned, failed, capped or held. `waitAreaReady` re-centres on
  a target outside the window and polls every 50 ms (call it from a thread).
- **Deviation — hides** use `CreateModelHideExcludingScriptObjects(x, y, z, radius, hash, true)` instead of
  `CreateModelHide` (the runtime's own props of that model inside the radius stay visible), removed with
  `RemoveModelHide` on delete, eviction, emptying, bucket reset and core stop; a zero hash hides nothing.
- **Editor view** (kind `mapEditorView`): the type list is fetched once through `core:maps:types`; data kinds and
  helpers within 150 m (≤ `MaxMarkers`) are drawn from their type's `preview` when the tuple names its type
  (`extra.t`, §52.4a addendum), else per-kind defaults (point → small sphere, zone → its box, helper → 1 m box).
- **Networked map entities**: an entity state-bag handler on `mapCfg` plus a round-robin sweep (≤ 16 known entities
  per sample) apply the config only while this client has network control, once per control period: peds →
  `SetBlockingOfNonTemporaryEvents`, `SetEntityInvincible` if `invincible`, `FreezeEntityPosition` if `frozen`,
  `TaskStartScenarioInPlace` unless `IsPedUsingScenario`; vehicles → `SetVehicleDoorsLocked(veh, 2)` if `locked`;
  `rot` → `SetEntityRotation`. The net-id guard runs first; outside the handler the LIVE bag is read (`mapEl` must
  be present) because net ids are recycled; an id whose entity is absent for 10 consecutive sweeps is forgotten (F12;
  streaming back in fires the handler again)). The same client applies an in-place move, `core:maps:pose` (§52.4a), with
  `SetEntityCoordsNoOffset` (keep tasks, warp) and the heading (vehicles, peds) or rotation (props).
- **Markers** (F14): gathered within their `dd`, capped at 150 m; the draw loop reads `GetFinalRenderedCamRot(2)` once
  per frame and skips markers behind the camera.
- **Measured budgets** (counting stubs): nothing loaded 0 natives; loaded and still ~3 camera reads + 3 timers per
  second; worst spawn frame 39 natives (8 objects); despawn ≤ 32 × 2; 1 `DrawMarker` per marker per frame; editor
  previews: marker/sphere 1, box 12 `DrawLine`, label 10. `stats()` returns more fields than the contract listed
  (`CoreMapsClientStats` in types/core.lua). Tests: `tests/client_maps_tests.lua` (239).

**Implementation notes (2026-09-27, run M0 — the §55.22 fade-band fix applied, and the editor live-update bug).**
- **The radius bullet above is replaced** by the fade-band rule of §55.22: `S = GetLodscale()` (sampled once a second,
  clamped 0.1–20), `B = 20` (5 when lod ≤ 20), `r = lod·S + B + 10` capped at `MaxSpawnRadius` (now 500; an object
  over the cap gets `SetEntityLodDist(e, floor((cap − B − 10) / S))`), despawn beyond `r + max(20, 0.25·r)`. The
  30 m minimum radius is gone. Radii are re-derived on a > 5 % change of `S`, in slices of 500 props per frame (RV2
  F5). The evaluation's scan limit is the cap plus its despawn margin (625 m), and a cell out of range is judged by
  the LARGEST despawn radius.
- **Editor audience** (the bug: an `editor` flip could leave the view stale): the regions' versions are KEPT across
  a flip; the old audience's pending / wanted requests are voided, packs are parked until the new audience's window
  answer, and a version announced in that answer is accepted even when it is lower than the one held (the audiences
  have different versions, §52.3 notes).
- Budgets: + 1 `GetLodscale` per second; the worst spawn frame is 41 natives (was 39). `stats()` gains `lodScale` and
  `rescales`. Tests: `tests/client_maps_tests.lua` 294 (the allocation section's camera path moved 35 m for the new
  radii).

**Superseded (2026-09-27) by §55.21.1.** client/maps_spawn.lua and client/maps_view.lua are deleted and the runtime
above with them (window, regions, grid, queues, models, hides, the `mapCfg` / pose handlers, the M0 radius rule —
props follow §55.11 now). client/maps.lua is a facade over `Core.Scene` that keeps the §52.4 client API (§55.21.1
notes list what changed: string uids, the new `stats()` shape, a `waitAreaReady` that moves no window);
client/maps_preview.lua draws the editor view from `map:data` nodes. This section is kept as the record of the design.

### 52.4a Wire format and the internal region interface (binding for server/maps*.lua and client/maps.lua)

- Kind codes in tuples: `1` prop · `2` marker · `3` hide · `4` point · `5` zone (vehicles, peds and networked props are
  server entities and never packed). Tuple = `{ uid, kind, modelHash, x, y, z, rx, ry, rz, flags, lod, extra }` with
  coordinates rounded to 3 decimals, rotations to 2, `modelHash` a signed 32-bit int (0 for non-model kinds), `lod`
  an integer (props: the validator's `info.lod`, else 150), `extra`: marker `{ type, r, g, b, a, sx, sy, sz, dd, bob,
  face }`, hide `{ radius }`, zone `{ sx, sy, sz }`, otherwise absent. Flags: 1 collision · 2 frozen · 4 unbreakable ·
  8 editor-only helper · 16 data kind.
- Pack string: `json.encode({ v = version, e = { tuple, … } })`.
- `core:maps:window` callback: request `{ c = centreKey, h = { [key] = version } }`, answer `{ b = bucket, v = { [key] = version } }`
  (integer keys survive msgpack). `core:maps:pack (bucket, key, packString)` (latent). `core:maps:delta (bucket, key,
  fromV, toV, opsString)` with `opsString = json.encode({ { o = 'put', t = tuple } | { o = 'del', u = uid }, … })`.
  `core:maps:stale (bucket, key, toV)`. `core:client:bucketChanged (bucket)` (§48). Callback `core:maps:types` → the public
  type list (`Maps.types()`, for the editor view's preview descriptors).
- Internal server interface (not exported; `Core.MapRegions`, added to the export block-list): `MapRegions.put(bucket,
  uid, tuple)` adds or moves an element (the module remembers each uid's region), `MapRegions.remove(bucket, uid)`,
  `MapRegions.clearBucket(bucket)`, `MapRegions.stats()`. Each call bumps the affected region versions and queues the
  delta; one flush per server tick sends the coalesced deltas/stale notices. `server/maps.lua` is the only caller.

**Addenda (2026-09-26, agreed between W2-MAPS, W2-REGIONS and W2-MAPS-C; binding like the rest of §52.4a).**
- **Withheld packs.** The `core:maps:window` answer is `{ b = bucket, v = { [key] = version }, w = { [key] = true } }`.
  `w` is ALWAYS present (empty when nothing is withheld) and lists the keys whose pack the per-src byte budget
  (`Config.Maps.PackBudgetBytes` / `PackBudgetWindowMs`) withheld; their `v` is still reported. The client re-requests
  them after ~2 s (withheld keys are not remembered as sent, so they go out as soon as the budget allows).
- **Versions.** Non-zero versions only grow (one module-wide counter); `0` = empty. A pack or delta with a non-zero
  version at or below the one the client holds is old and ignored. The version a client sees is the one of ITS
  audience (full for editors, public otherwise, §52.3 notes); `core:maps:stale` may carry a public version.
- **Audience.** Tuples with flag 8 (editor helper) or 16 (data kind) are delivered to editors only (Admin mode `editor`
  or an open draft's editor bucket); the client re-requests its window after an `editor` flip.
- **Editor extras.** Data kinds (`point`, `zone`) and editor-only helpers (flag 8, records of an undefined type) also
  carry `extra.t = <type id>` and — when the type's `preview` has `{ kind = 'label', text = '$field' }` entries —
  `extra.f = { [field] = value }` for exactly those fields (scalars as strings, ≤ 64 chars; absent when none has a
  value). A zone's extra is therefore `{ sx, sy, sz, t, f? }`, a point's `{ t, f? }`, a placeholder's `{ t }`. The
  runtime ignores them; the editor view draws the type's preview from them.
- **`mapCfg` state bag** on networked map entities (next to `mapEl`), applied by the client that has network control
  (the server's cosmetic natives are fallible RPCs): peds `{ invincible, frozen, scenario? }`, vehicles `{ locked }`,
  networked physics props `{ rot = { x, y, z } }` (degrees, order 2).
- **`core:maps:pose (netId, uid, x, y, z, rx, ry, rz)`** (server → the entity's owning client, reliable): an
  in-place move of a networked map entity. The client applies it only with network control and `mapEl == uid`
  (after the `NetworkDoesEntityExistWithNetworkId` guard); vehicles/peds take `rz` as heading, props the full
  rotation (order 2). Not state: a client that takes control later never re-applies it.

**Superseded (2026-09-27) by §55.21.1.** None of this wire exists any more: no tuples, packs, `core:maps:window` /
`pack` / `delta` / `stale` / `pose`, no `mapEl` / `mapCfg` state bags, no `Core.MapRegions`. What remains of it: the
callback `core:maps:types` (the public type list for the editor view) and `core:client:bucketChanged` (§48). The
editor extras live on as the fields of the core-internal scene kind `map:data` (`t` type id, `k` element kind,
`size`, `f` label values), and every node a map projects carries `fields.mapEl = '<mapId>:<elementId>'` and
`fields.mapType`.

### 52.5 Config, scale, tests

`Config.Maps = { RegionSize = 512, WindowHysteresis = 64, CacheRegions = 25, LatentBps = 250000, PushOpsMax = 32,
MaxSpawnRadius = 400, SpawnPerFrame = 8, DespawnPerFrame = 32, MaxLocalObjects = 1500, MaxMarkers = 64 }`; limits are
`Core.Settings` keys `maps.limits.*`, `maps.journalMax`. Scale: the only movement-driven traffic is one small callback
per ~512 m of travel (2,000 players at 20 m/s ≈ 80 requests/s server-wide, nearly all "unchanged"); content crosses the
wire once per (client, region, version); a change reaches only the players holding that region. Tests:
`tests/maps_tests.lua` (types, apply validation and atomicity, limits, invert, expect/conflict, publish/rollback, live
vs draft activation, region packs + versions + coalesced pushes, subscriptions, networked lifecycle with stubs) and
`tests/client_maps_tests.lua` (window/hysteresis, cache, grid evaluation, queue budgets, model ref-counting, cap,
hold/release, area readiness).

**Implementation notes (2026-09-26).** `Config.Maps` also has `PackBudgetBytes = 2000000` and
`PackBudgetWindowMs = 10000` (§52.3 notes); settings `maps.journalMaxOps` (20000) joined `maps.journalMax`. Tests
as run: `tests/maps_tests.lua` 409 (was 301 before run UX C2) + `tests/maps_store_tests.lua` 72, `tests/maps_regions_tests.lua` 272,
`tests/client_maps_tests.lua` 250 (two `[bench]` lines).
In game (open): resmon flying through ≥ 1000 props within 400 m, DLC prop streaming, a teleport onto an event
platform, a hide over a world bench (it must come back), `mapCfg` on an entity placed before a client joined.

**Implementation notes (2026-09-27, run M0).** `Config.Maps.MaxSpawnRadius` is 500 (§52.4 M0 notes). Tests as run
after M0 (2026-09-27, before phase D): `tests/maps_tests.lua` 409, `tests/maps_store_tests.lua` 72,
`tests/maps_regions_tests.lua` 288, `tests/client_maps_tests.lua` 294.

**Superseded (2026-09-27) by §55.21.1 — config, scale and tests after phase D.** `Config.Maps = { MaxMarkers = 64 }`
(the editor view's preview budget) is all that is left; streaming, caps and budgets are `Config.Scene`'s, and core's
map nodes count against `Config.Scene.OwnerCaps.core` (60,000). Scale is §55's. Tests: `tests/maps_tests.lua` 328
(the projector against a recording fake Scene), `tests/maps_store_tests.lua` 200 (documents, apply validation and
limits, expect / events / restore), `tests/client_maps_tests.lua` 257 (the facade and the preview handler);
`tests/maps_regions_tests.lua` is deleted.

## 53. Kit additions (catalogue entries in §37.5; the §6 kit protocol applies to each)

| component | purpose / API sketch |
|---|---|
| `CoreVirtualList` | fixed-row-height virtualised list: `items`, `itemHeight`, `keyField`, `overscan`; default slot `{ item, index }`; `scrollToIndex()` |
| `CoreTree` | nested rows with expand/collapse, selection (single/multi), per-row icon/badge/trailing slot, keyboard (↑↓←→ Enter) |
| `CoreCombobox` | filterable select: `options` (or async `search(query)`), `multiple`, `creatable?`, virtualised when > 100 options |
| `CoreVectorInput` | `{ x, y, z }` (or rotation) as three `CoreNumberInput`s with shared `step`/`precision`, optional axis colours, `copy`/`paste` |
| `CoreColorPicker` | hex input + swatches + RGB(A) sliders (no native `<input type=color>` popup — CEF off-screen) |
| `CorePagination` | cursor/page controls: `page`, `pageCount?`, `hasNext`, `hasPrev`, size select |
| `CoreTable` (extended) | sortable columns (`sortable`, `sortKey`, `sortDir`, `update:sort`), `loading`, `empty` slot — server-side sorting stays the caller's |
| `CoreSchemaForm` | renders `Core.Schema.public` fields with kit controls (incl. the above), `visibleWhen`, groups, errors per field; `resolvers` prop supplies options for `player`/`model`/`ref`/`faction`/`item`; emits `update:modelValue`, `submit` |

**Implementation notes (2026-09-26, run W1-KIT).** The kit is 71 components (64 + the seven above; catalogue entries
in §37.5, stories in §37.7).
- **Helper files outside the catalogue**: CoreSchemaForm recurses through `ui/src/kit/schema/SchemaField.vue` with
  pure helpers in `ui/src/kit/schema/schema.js` (sort/group/visibleWhen/defaults/advisory check/error wording/duration
  parse + format/`normalizeErrors`). They live outside `kit/components/` on purpose: the registry stays at 71 and the
  SDK types list only the public tag.
- **CoreTable**: sorting is presentation only on both sides — the table never reorders rows. Added a table-level
  `sortable` default (a column's `sortable` overrides it), `v-model:sortKey` / `v-model:sortDir` next to `update:sort`,
  and `loadingRows`. Two-state toggle (asc ↔ desc), no "unsorted" third click.
- **CoreVirtualList** additions: `range` and `reach-end` emits (+ `endThreshold`) for cursor paging, a `role` prop
  (CoreTree and the combobox pass `presentation` so their own roles hold), an `empty` prop/slot, `measure()`.
- **CoreTree** additions: `v-model:expanded`, `keyField` / `childrenField`, `dense`, `indent`, `label`; emits
  `select`, `toggle`, `activate`. Always virtualised (it grows to its content when unconstrained).
- **CoreCombobox**: `search` REPLACES local filtering (the server filters); `creatable` also emits `create`; the
  virtualised row height is fixed (36, or 54 when any option has a description).
- **Deviation — CoreVectorInput's default `size` is `sm`** (the kit default is `md`): three steppers in a row. The kit
  keeps its own clipboard (module scope) because `navigator.clipboard` may be unavailable in the CEF; paste races the
  browser clipboard against 250 ms.
- **CoreColorPicker**: added `popover` (the form-row shape CoreSchemaForm uses) and a default palette; the model is
  upper-case and 8-digit only while translucent. **CorePagination**: `page` is 1-based; `hasNext`/`hasPrev` default
  to `null` (derived); `total`, `sizeLabel`, `siblings`, `change` added.
- **CoreSchemaForm vs §43**: errors are `checkAll`'s shape exactly — `{ name = code }` with nested paths PREFIXED to
  the code (`'2.pos.min'`, 1-based rows); `normalizeErrors` flattens that to path keys (`list.2.pos`) and stops at
  `custom:` so a message containing dots survives. The advisory check mirrors lib/schema's CHECK rules but is never
  authoritative (`submit` fires only when it passes; the server validates again). `duration` shows the field's
  `presets` (now a §43 UI-only key) or 15m / 1h / 1d / 1w (+ Perm), filtered by `min`/`max`. `number` without `step`
  shows 2 decimals, `integer` 0; `player` without a resolver is a digits-only text field; `secret` strings are
  password inputs (the public view has no default); `visibleWhen` is evaluated per nesting level; `messages`
  localises the English defaults; `custom:<text>` shows the text; `pattern` uses `patternMessage`.
- Chromium 103: no `:has()`, `color-mix()`, nesting, container queries, `dvh`, individual transforms or the banned
  filter; chevrons/twisties turn with `transform: rotate()`; the checkerboard is `repeating-conic-gradient`.
- **Limits**: CoreCombobox's label map grows with every option seen in that instance (bounded by what the resolver
  returns); CoreTree's parent walk on a vanished cursor is O(n), on that path only.
- Tests: `kit-regression.js` catalogue + mount-all entries for the seven, section 9c (84 checks), seven new
  interactive roots in §10 — `PASS 312/312` on the built `html/` (305 on the dev server, which skips §11); every new
  story's play function finishes; `gen-kit-types --check` → 71.

## 54. Editor focus: HUD hiding and key capture (client/ui.lua, lib/keys/client.lua, shell runtime) — 2026-09-26

Liam, after the first in-game run of the admin map editor: "The HUD and minimap show … The quick slots aren't usable
because of the inventory." A full-screen tool (the editor, a photo mode, a cutscene script) needs two things §31 and
§3.8 did not give it: the HUD layer out of the way WITHOUT hiding its own page (`Core.UI.hide` hides the whole shell and
closes the focused page), and its keys to itself — the inventory binds 1–5 through `Core.Keys`, the editor binds 1–9, and
both fired. Both APIs are owner-tracked reason sets with the §31.1 namespacing, reached from a plugin through the proxy.

### 54.1 Client API

```lua
Core.UI.hideHud(reason?) -> boolean     -- false only for an invalid reason; true when held afterwards (also if it was)
Core.UI.showHud(reason?) -> boolean     -- true when it removed the CALLER's reason
Core.UI.isHudHidden() -> boolean        -- at least one reason is held (by anyone)
Core.Keys.capture(reason?) -> boolean   -- same answers as hideHud
Core.Keys.release(reason?) -> boolean   -- same answers as showHud
Core.Keys.isCaptured() -> captured, byCaller   -- any capture held; does the CALLER hold one itself
Core.Keys.register({ …, whileCaptured = true })  -- this binding keeps firing while another resource captures
Core.on('hudHiddenChanged', function(hidden) end)   -- client hook, on the hidden <-> visible flip only
```

- Reasons follow §31.1 exactly (`reasonKeyFor`): pattern `^[%w_%-%.:]+$`, default `default`, ≤ 48 characters after
  prefixing; a plugin's reason is stored as `<resource>:<reason>`, core's verbatim; a plugin can never clear another
  one's — the owner is the engine's invoking resource, and a call that declares another resource's name is refused
  (§2.2), so `exports.core:call('admin', 'Keys', 'release', 'editor')` from any other resource fails. Registry kinds
  `uihud` and `keycapture`: a stopping owner drops every reason it held (the HUD, the radar and
  the keys come back with it).
- **The holder keeps its own things.** The owner resources holding a hideHud reason form the KEEP list: their overlay
  pages, their text UI and their key hints stay; a capture holder's own `Core.Keys` bindings keep firing.

### 54.2 HUD hiding — what goes and what stays

While ≥ 1 hideHud reason is held:

| element | while hidden | who does it |
|---|---|---|
| core's vitals strip (`Hud.vue`), stat bars (`StatsBars.vue`), world prompt layer (`WorldPrompts.vue`) | hidden | shell (`shell:hud`) |
| overlay pages (`type = 'overlay'`) whose owner is NOT in keep (the inventory hotbar) | hidden, never closed — state survives | shell |
| overlay pages of a holder (the admin HUD of the admin resource) | stay | shell |
| `Core.UI.textUI` / `Core.UI.keys` shown by a resource that holds no reason | taken off the screen, shown again afterwards | client/ui.lua |
| the §6.7 world prompts (native renderer) and `core_interact` | not drawn / does nothing | client/interactions.lua |
| GTA radar and native HUD | `DisplayRadar(false)` / `DisplayHud(false)` ONCE on the first reason | client/ui.lua |
| toasts, progress bar, spinner, shard, chat, pages, modals, built-in menus/dialogs | untouched | — |

- **Wire.** ONE Lua → NUI message: `{ action = 'shell:hud', hidden, keep = { resource, … } }` (keep sorted; an empty
  Lua table arrives as `{}`, which the shell reads as "nobody"). Sent on every change of `hidden` or of the keep list,
  and on `ui_ready` while hidden — BEFORE the overlays are re-opened, so a hidden one never flashes. The text UI / key
  hint suppression is ordinary `textui:*` / `keys:*` traffic after it.
- **Natives** (apiset client, HUD namespace, verified with `fxref show` 2026-09-26): `DisplayRadar(toggle)`,
  `DisplayHud(toggle)`, `IsRadarHidden()`, `IsHudHidden()`. In the game (`script/commands_hud.cpp`) `IS_RADAR_HIDDEN`
  is `!CScriptHud::bDisplayRadar` and `IS_HUD_HIDDEN` is `!CScriptHud::bDisplayHud` — pure read-backs of the two
  DISPLAY_* flags, no per-frame hides in them. So on the first reason core switches off only what reads as on and
  remembers it (`hudNatives.radar` / `.hud`); on the last reason (or the owner stop, or core's own stop) it switches
  back on ONLY what it switched off. A radar another script had hidden stays hidden. The BOOL readbacks are read by
  truthiness (AGENTS §8). `sf_minimap` follows the game radar, so it hides by itself.
- **§31.3 `hud` watcher.** `IsHudHidden()` turns true the moment §54 calls `DisplayHud(false)`; with
  `Config.UI.AutoHide.HudHidden = true` that would hide the WHOLE shell (and close the editor's page). The watcher
  therefore reads `IsHudHidden() and not hudNatives.hud` — a native HUD that §54 hid is not a `game:hud` reason. (This
  also answers §31.3's "semantics undocumented": the native reads the DISPLAY_HUD flag, nothing else.)
- **World prompts.** client/interactions.lua keeps ONE local flag from the `hudHiddenChanged` hook. The projection
  thread treats it like NUI focus — `Wait(250)`, nothing projected, drawn or sent (no new per-frame work, one boolean
  per iteration) — and on the way back sets `focusDirty` + `forceSend`, so the next frame re-projects and the `'nui'`
  renderer re-sends the whole set. The scan's text UI prompt goes through `Core.UI.textUI` and is suppressed there.
  `core_interact` returns at once while hidden (no prompt is visible, and E is the editor's "up" key).
- **Shell.** `store.hudHide = { hidden, keep }` (owned by `runtime/layers.ts`: `attachHudStore`, `applyHudHide`,
  `hudHidden()`, `overlayHidden(owner)`; an overlay without an owner counts as `core`). `App.vue` wraps the three core
  widgets and `PageHost.vue` every overlay in a `display: contents` element with `v-show` (`data-core-hud="vitals" |
  "stats" | "worldprompts"`, `data-core-overlay="<id>"`): no layout of its own, nothing unmounts, a hidden overlay keeps
  receiving props, patches and feeds. A malformed `shell:hud` (not `hidden === true`) is a VISIBLE HUD.
- **Hook.** `hudHiddenChanged(hidden)` fires once per flip (never for a second reason or a keep-list change), after the
  message and the natives, in core's VM and — as every hook — in every resource on the client.

### 54.3 Key capture — the press-time check across VMs

- `lib/keys/client.lua` is compiled into every VM; the capture state is not. `capture`, `release` and `isCaptured` are
  defined by core (client/ui.lua) on core's own `Core.Keys` lib table and NOT by the lib, so in a plugin VM they fall
  through to the import.lua proxy (`exports.core:call(resource, 'Keys', fn, …)`, §2.2) and the caller is known.
- A press runs the old cheap checks first (stale key-up, `whileFocused`/NUI focus/pause menu, debounce), then — unless
  the binding has `whileCaptured = true` — asks `ns.isCaptured()` ONCE: inside core that is core's function, in a plugin
  VM one export hop (multiple returns cross it: FiveM's Lua scheduler packs `{ ref(…) }` and unpacks it on the caller
  side). The press is swallowed when `captured and not byCaller`. The swallowed press does not start the debounce
  window and sets no `down` state, so its key-up stays silent; a key that went down BEFORE the capture still delivers
  its release. Nothing runs per frame; a failing answer (core stopped or restarting, an older core without §54) counts
  as "not captured" — a key never goes dead with core.
- **Why not a state bag.** A non-replicated `LocalPlayer.state:set(k, v, false)` IS visible to every resource on the
  client (`SET_STATE_BAG_VALUE` / `GET_STATE_BAG_VALUE` resolve the bag through the one `StateBagComponent` of the
  client's ResourceManager; strict mode only blocks REPLICATED client writes) and would save the export hop, but the
  value outlives core: a core restart or crash while a capture is held would leave every other resource's keys dead
  until somebody cleared it. The hop costs microseconds and happens once per key press.
- core's chat key (`client/chat.lua`) is `whileCaptured = true`. core's other `Core.Keys` bindings (vehicle lock) are
  swallowed like anyone's. Raw `RegisterKeyMapping` commands are not `Core.Keys` bindings and are not affected:
  `core_interact` is covered by the HUD hiding above, `core_door` asks `Core.Keys.isCaptured()` itself (see the
  notes); `core_cancel` only acts on a cancellable progress bar and is left alone.

### 54.4 Implementation notes (2026-09-26, run UX / package C1)

- **Deviation — key hints.** The brief named the text UI; `Core.UI.keys` (instructional buttons, bottom right) follows
  the same owner rule, because another resource's bar would sit on the editor's own full-width hint bar.
- **Owner of a text UI line.** `textUI.show` now remembers the calling resource (`Registry.getCaller()`) next to the
  free-form `owner` tag; only the resource decides the §54 rule. Core's interaction and door prompts are `core`.
- `reasonKeyFor(fn, reason)` takes the full API name for its log line (`UI.hide`, `UI.hideHud`, `Keys.capture`); the
  messages of `UI.hide`/`UI.show` are unchanged.
- **`core_door` (fixed by the orchestrator).** client/doors.lua binds E (`core_door`) with a raw key mapping, which
  the lib's capture check never sees: in the editor's fly mode (E = up) a door within 2 m of the parked ped toggled.
  `Doors.tryToggleNearest` now returns while `Core.Keys.isCaptured()` answers true (suite `door key capture`).
- **Limits.** Another script that calls `DisplayRadar(true)` while a reason is held shows the radar again; §54 does not
  re-assert it (once, by contract). `hudHiddenChanged` is not re-fired for a resource that starts while hidden — read
  `Core.UI.isHudHidden()` at start. The keep list is per resource, not per page.
- Tests: `client_ui_tests.lua` suites `hud hide` (reasons, owners, keep list, natives incl. a pre-hidden radar, hook,
  text UI + key hints, the §31 watcher, the ui_ready order, owner stop, core stop), `hud hide prompts` (nothing
  projected or sent while hidden, `core_interact`, re-send on show) and `key capture` (REAL VMs: core's client VM + two
  plugin VMs from import.lua whose proxy reaches core's `call` export; swallowed / own / `whileCaptured` / release /
  chat / owner stop / core down / a SPOOFED caller refused) — 795 total with the other packages' suites; `run_tests.lua` keys suite (+15: lib-side proxy use, cheap checks first,
  failure = not captured) — 417; `ui/tests/unit/layers.test.ts` (+2) — `# pass 216`; `runtime-regression.js` section
  9b (+11) — `PASS 212/212`; Storybook `Shell/HUD hidden (editor focus)` with a play function.

---

# Scene streaming (§55, 2026-09-26 — Liam: "an entity streaming system … objects, vehicles, NPCs, audio, live audio … fully synced … without destroying performance … without ugly plopping in / out … the best system in the world")

Research: `resources/research/entity-streaming/RESEARCH.md` (+ R1–R9; kept OUTSIDE this repository because two reports
cite Rockstar source paths). Decisions (Liam, 2026-09-26): name `Core.Scene`; build phases 0 + A + B + C + D in one run;
`increase_pool_size "Object" 2000` in server.cfg; the §52 fade-band fix now. Defaults he accepted: https-only audio with
an admin allow-list, no YouTube in core, voice speakers on Mumble with a pma-voice adapter, host NTP in slew mode.

## 55. Scene streaming (`Core.Scene`, `Core.Clock`)

### 55.0 Principles (each one is a research finding — do not trade them away)

1. **The server owns records, clients own presentation.** A *node* is a server record (`id, kind, owner, bucket, pose,
   parent, motion, fields, audience, ver`). Every interested client *materialises* it LOCALLY (a non-networked entity,
   an audio voice, a draw call, a trigger volume). OneSync is used only while a node is *promoted* (§55.15). Reason:
   OneSync makes a new entity relevant to a client only on that client's relevance pass — up to ~6.3 s at 2,000 players
   — with no fade, from pools of 80–250 (R1 §5, R8 §1).
2. **Interest is coarse and event-driven on the server, exact on the client.** Cells of 128 m (near grid) and 512 m
   (far grid) plus a per-bucket global set; membership changes only on focus crossings and node changes; one
   serialisation per cell change; the client does exact distances, hysteresis, caps, priorities and fades (R4 §11).
3. **Exist before visible.** GTA fades every entity over the 20 m past `lodDist × GetLodscale()` (5 m when lodDist ≤ 20),
   script objects included; only the creation fade is disabled for script objects. The materialiser creates beyond that
   band and deletes beyond it + hysteresis, so the engine reveals and hides props; explicit fades only for late arrivals
   (R3 §1, R9 §5.3, R5 §9).
4. **Motion and media are functions of one clock.** `Core.Clock` = OneSync's network time (client) = `GetGameTimer()`
   (server), ±5–20 ms. Paths, tweens, spins, keyframes, animation phases and audio play heads are descriptors evaluated
   locally; steady traffic ≈ 0 (R1 §3, R7 §2).
5. **One small reliable message per client per tick.** Script traffic is reliable-ordered only; latent events are paced
   and unordered; server Lua runs at 20 Hz. So: cell blobs encoded once, one coalesced event per client per 50 ms tick
   ≤ 16 KiB, versions on everything, big snapshots latent inside a byte budget, latest-state-wins (R1 §1, R7 §0.2).
6. **Never pop in view, never delete in view.** Late arrivals fade (props 0.3 s, peds 0.6 s); deletions wait until the
   thing is invisible or unseen for 1.5 s; peds and vehicles prefer out-of-view creation (Rockstar's own rules and
   `net_peds`, R3 §3, §9.3).
7. **Budgets come from FiveM's pools.** Object 3,300 (+2,000 via `increase_pool_size`), Peds 256, Vehicles 300 (not
   raisable), 256 game-wide alpha-override slots; a full pool is a client crash (R8 §1, R2 §C10–C11).

### 55.1 Files, load order, internal hand-offs

```
lib/clock/shared.lua              Core.Clock (lib, every VM: plugins too)
lib/scene/shared.lua              pure helpers every VM needs (kind id rules, radius-tier maths) — tiny
lib/scene/client.lua              plugin side of Core.Scene: handle(kind, handlers), on(...), off(...) (in-VM); the
                                  proxy fills handleOf/idOf/get/stats/isAreaReady/waitAreaReady/hold/release
shared/scene_codec.lua            Core.SceneCodec (internal, both core VMs): binary ops, quantisation (§55.8)
shared/scene_motion.lua           Core.SceneMotion (internal, both core VMs): motion descriptors (§55.9)
server/scene_kinds.lua            kind registry + the built-in kinds (§55.3, §55.12 fields)
server/scene_index.lua            cells, tiers, versions, journals, packs, movers re-cell (§55.5)
server/scene_interest.lua         focus, windows, rings, hysteresis, gated audiences (§55.6)
server/scene_flush.lua            the 20 Hz flush: outboxes, one event per client, latent packs, budgets (§55.7)
server/scene.lua                  Core.Scene server API, node store, persistence, owner cleanup, interact dispatch (§55.4)
server/scene_promote.lua          promotion / demotion / leases (§55.15)          -- phase C
server/scene_audio.lua            audio sources: URL resolution, allow-list, titles, cooldowns (§55.16)   -- phase B
server/scene_voice.lua            voice speaker sessions + adapter (§55.17)         -- phase B
client/scene_cache.lua            receive + decode, cells, nodes, LRU, focus reporter, resync (§55.10)
client/scene_materializer.lua     the engine: states, radii, priority, budgets, fades, visibility, caps (§55.11)
client/scene_kinds.lua            built-in entity kinds: prop, vehicle, ped (§55.12)
client/scene_fx.lua               built-in non-entity kinds: light, particle, marker, text, hide, zone, sound, group (§55.12)
client/scene_movers.lua           per-frame / tiered evaluation of LIVE movers (§55.9)
client/scene_promote.lua          hand-off local copy ↔ networked clone (§55.15)    -- phase C
client/scene_audio.lua            listener feed, occlusion probes, emitter bridge to the shell (§55.16)  -- phase B
client/scene_voice.lua            submix pool, speaker panning (§55.17)             -- phase B
client/scene.lua                  Core.Scene client API, plugin-kind bridge, hooks, /scene commands (§55.10, §55.13)
ui/src/runtime/audio/*.ts         the shell audio engine (§55.16)                   -- phase B
```

- **Manifest order** (fxmanifest.lua): `shared_scripts` gains `shared/scene_codec.lua`, `shared/scene_motion.lua`
  after `shared/ui_forms.lua`; `server_scripts` gains `server/scene_kinds.lua`, `server/scene_index.lua`,
  `server/scene_interest.lua`, `server/scene_flush.lua`, `server/scene.lua`, `server/scene_promote.lua`,
  `server/scene_audio.lua`, `server/scene_voice.lua` **right after `server/maps_apply.lua`** (Scene reads the Maps model
  validator lazily, never at load); `client_scripts` gains `client/scene_cache.lua`, `client/scene_materializer.lua`,
  `client/scene_kinds.lua`, `client/scene_fx.lua`, `client/scene_movers.lua`, `client/scene_promote.lua`,
  `client/scene_audio.lua`, `client/scene_voice.lua`, `client/scene.lua` **right after `client/maps.lua`**. The ORDER is
  load-bearing (AGENTS §8): each file asserts its predecessor.
- **Server hand-off**: `Core.SceneRuntime` (one table, created by scene_kinds.lua, filled by each file: `R.kinds`,
  `R.index`, `R.interest`, `R.flush`, `R.store`, later `R.promote`, `R.audio`, `R.voice`) — added to
  `INTERNAL_NAMESPACES` in server/api.lua together with `SceneCodec` and `SceneMotion`. Plugins reach only `Core.Scene`.
- **Client hand-off**: the one-shot global `CoreSceneRuntime` (created by client/scene_cache.lua, filled by each file,
  cleared by client/scene.lua — the §52 `CoreMapsEngine` pattern); `SceneCodec`, `SceneMotion` join `INTERNAL_NS` in
  client/api.lua. Nothing internal is reachable through the export.
- **Libs**: `LIB_MODULES` in import.lua gains `Clock = 'clock'` and `Scene = 'scene'` (the lib part of Scene is the
  in-VM registration; everything else is proxied, the `Core.UI` pattern).
- **Registry kinds** (owner-tracked, §2.3): `sceneNode` (non-persistent nodes of a stopped owner are removed; persistent
  ones stay), `sceneKind` (a stopped owner's kinds go; their nodes stay as placeholders), `sceneListener` (Scene.on),
  `sceneInteract` (onInteract handlers), `sceneModelInfo` (the model-info provider), `sceneHold` (client holds),
  `sceneVoice` (voice sessions).

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **Deviation — five more files** (Lua's 200-locals limit and file size forced the splits; each is internal):
  `server/scene_store.lua` (records, pose, parent / child sets, dependency bookkeeping, `Scene.on/onInteract/off`,
  persistence, the load barrier; it hands its internals ONCE to server/scene.lua through `R.storeInternal`, which
  scene.lua takes and clears) · `server/scene_gated.lua` (the audience half of `R.interest`: allows, gatedTargets,
  holders, PRIV sections) · `client/scene_focus.lua` (`C.focus`: focus reporter, resync requests, bucket changes) ·
  `client/scene_mat_assets.lua` (`C.assets`: ref-counted models / anim dicts / ptfx assets and interiors; `C.fades`:
  the slot-budgeted fade manager) · `client/scene_world.lua` (hide, zone, sound, group — it extends scene_fx.lua's
  `C.fx`, which keeps light, particle, marker, text and the draw loop).
- **Manifest order as built** (each file asserts its predecessor): shared `shared/scene_codec.lua`,
  `shared/scene_motion.lua` after `shared/ui_forms.lua`; server `scene_kinds → scene_index → scene_interest →
  scene_gated → scene_flush → scene_store → scene → scene_promote → scene_audio → scene_voice` right after
  `server/maps_apply.lua`; client `scene_cache → scene_focus → scene_mat_assets → scene_materializer → scene_kinds →
  scene_fx → scene_world → scene_movers → scene_promote → scene_audio → scene_voice → maps_preview → maps → scene`
  right after `client/spawn.lua` (phase D: client/maps_spawn.lua and maps_view.lua are gone; the map facade and its
  editor view sit INSIDE the scene block because they use `CoreSceneRuntime`, which client/scene.lua clears last);
  `server/vehicles_park.lua` right after `server/vehicles.lua` (one-shot global `CoreVehiclesPark`, §4.6 notes). The
  phase B/C server files assert only what they use (scene_audio: `R.store`, `R.kinds`); until they load,
  `Scene.promote / demote / lease / voice.* / audio.kill` answer `nil, 'unavailable'`.
- **Registry kinds** beyond the list: `sceneFocus` (server, `Scene.setFocus` pins) and `sceneHandler` (client,
  plugin-kind claims). Server `Scene.on` / `onInteract` handles are strings (`'sl:<n>'`, `'si:<n>'`), client handles
  integers.
- `server/api.lua` also block-lists the FUNCTION `Scene.prefetch` (Player.setCoords' own); `import.lua` gains
  `SUB_NAMESPACES.Scene = { voice, audio }`, so the proxy reaches `Core.Scene.voice.start` and `Core.Scene.audio.play`.
- `lib/scene/shared.lua` also carries `PAINTS` (22 stable vehicle paints) and `paintOf(id)`: one list for the
  server's promoted clones and every client's local copy. The shell audio engine is `ui/src/runtime/audio/*.ts`
  (§55.16 notes lists the modules).
- The research reports live in `resources/research/entity-streaming/` (outside the core repository); the dev-only
  probes are `resources/scene_probe` (§55.24 notes).

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
Two more splits, each with a one-shot hand-off and a
load-bearing manifest order: `server/scene_promote_api.lua` loads right after `server/scene_promote.lua` and takes its
internals once through `R.promoteInternal` (the entry points: `Scene.promote / demote / lease`, `R.promote.adopt`,
`beforeChange`, the report and applied events, interactions, `onEntityBucketChange`, player drops, the core stop);
`server/vehicles_fleet.lua` loads right after `server/vehicles_park.lua`, which now passes the one-shot global
`CoreVehiclesPark` on — vehicles_fleet.lua clears it (AutoPark, MaxParked, the boot and core-stop reconciliation).
Server order now: `… vehicles → vehicles_park → vehicles_fleet …` and `… scene_store → scene → scene_promote →
scene_promote_api → scene_audio → scene_voice`.

### 55.2 `Core.Clock` (lib `lib/clock/shared.lua`, every VM)

```lua
Clock.now() -> integer        -- u32 milliseconds: server GetGameTimer() & 0xFFFFFFFF;
                              -- client GetNetworkTimeAccurate() & 0xFFFFFFFF (OneSync's netTimeSync clock)
Clock.diff(a, b) -> integer   -- a - b as a signed 32-bit difference (wrap-safe; Lua values go negative after 24.9 days)
Clock.add(t, ms) -> integer   -- (t + ms) & 0xFFFFFFFF
Clock.at(ms) -> integer       -- Clock.add(Clock.now(), ms): future-stamped plans
Clock.ready() -> boolean      -- client: the network clock has synced once (non-zero and advancing); server: true
Clock.local2net(localMs) / Clock.net2local(netMs)   -- client only: map GetGameTimer() <-> network time (offset
                              -- sampled on each call to now(), filtered: max over the last 10 s)
```
- The client latches the value once per frame (`GetNetworkTimeAccurate` is frame-locked in GTA, R3 §5); `now()` costs
  one native at most once per frame (a frame counter from `GetFrameCount()` caches it).
- No sync protocol of our own. Probe P3 (§55.24) measures the error; if it shows > 50 ms p95, a min-RTT Cristian
  exchange over `Core.Callback` becomes the fallback (a `Config.Scene.ClockMode = 'network'|'callback'` switch).
- Ops rule (README): run the host's NTP in slew mode — FXServer's `GetGameTimer()` follows the system clock on Linux
  (R7 §3.3).
- Tests: `tests/run_tests.lua` suite `clock` (wrap-safe diff across 2^31 and 2^32, add/at, latch per frame, ready).

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- While the network time reads 0 — before the first sync, or again later — or the native is missing, `now()` answers
  `GetGameTimer() & 0xFFFFFFFF` plus the LAST known offset (0 until a network sample was seen), so the timeline
  stays continuous. `ready()` is sticky: true after two non-zero, advancing network samples, never false again.
- The offset filter is ten one-second slots (allocation-free, sampled once per frame through the latch); a slot from
  the future (a wrapped game timer) or older than 10 s no longer counts. `Clock.add` floors a fractional ms.
- Server: `local2net` / `net2local` are the identity, masked to u32.
- `Config.Scene.ClockMode` is in the config but nothing reads it yet: the `'callback'` fallback waits for probe P3.
- Tests: `run_tests.lua` 468 in all (suite `clock` included).

**In-game probe results (Liam, 2026-09-26 22:21 UTC, `scene_probe/data/report_20260926_222136.txt`).**
Probe P3: client network time − server time,
corrected by ping / 2 — mean 0.9 ms, p95 11.5 ms, max 24.5 ms, largest step 29.5 ms, inside the 50 ms p95 alarm:
`Config.Scene.ClockMode = 'network'` is confirmed and the callback fallback stays unbuilt.

### 55.3 Nodes and kinds

**Node** (server record; the client sees the same fields minus `owner`, `persist`, `audience`):

| field | type | notes |
|---|---|---|
| `id` | integer 1..2^31-1 | from one counter; persistent nodes keep theirs across restarts (the counter is stored) |
| `kind` | kind id | `'prop'`, `'vehicle'`, … (built-ins, no prefix) or `'<resource>:<name>'` (plugins) |
| `owner` | resource name | the creating resource (`Registry.getCaller()`); core for core's own |
| `bucket` | integer ≥ 0 | routing bucket; default 0 |
| `pos`, `rot` | vector3 / Euler degrees (order 2) | quantised on the wire to cm and centi-degrees (§55.8) |
| `parent` | node id or nil | a child rides with its root: no index entry, packed after the root, created after it, revealed with it; `offset`/`offrot` relative to the parent (or its bone: `bone`) |
| `motion` | descriptor or nil | §55.9; the node's pose at time t is `SceneMotion.pose(node, t)` |
| `fields` | table | kind fields, checked by the kind schema (§55.12) |
| `audience` | nil or table | nil = public in its bucket; otherwise gated (§55.6): `{ players = { src… } }`, `{ faction = id }`, `{ perm = 'x' }`, `{ editors = true }`, `{ near = radius }`, `{ fn = callable }` — combinable with `any`/`all` |
| `radius` | number (m) | stream radius; nil = computed by the kind (§55.12) |
| `tier` | `'S'`/`'M'`/`'L'`/`'G'` | derived from `radius`: S ≤ `TierS` (160), M ≤ `TierM` (448), L ≤ `TierL` (1500), G = `global = true` |
| `persist` | boolean | stored in Core.DB (§55.18); survives restarts and owner stops |
| `interact` | array or nil | interaction descriptors (§55.14) |
| `authority` | policy or nil | overrides the kind's promotion policy (§55.15) |
| `ver` | integer | bumps on every change (module-wide counter) |

**Kinds** (`server/scene_kinds.lua`):
```lua
Scene.defineKind({
    id = 'fireworks:battery',        -- '^[%w_%-]+:[%w_%-%.]+$' for plugins; built-ins are reserved plain ids
    class = 'custom',                -- 'prop'|'vehicle'|'ped'|'fx'|'audio'|'data'|'custom'
    fields = { Schema fields … },    -- Core.Schema list; a field may be { name, type = 'table', validate = fn } (free-form,
                                     -- JSON-safe, ≤ Config.Scene.MaxFieldBytes encoded), checked by `validate` only
    nearFields = { 'label' },        -- optional: sent to near-ring subscribers only (BigWorld detail levels)
    radius = 250 | fn(node) -> m,    -- optional; default by class (§55.11)
    handler = 'fireworks',           -- client handler resource (custom kinds); core for built-ins
    authority = { … },               -- default promotion policy (§55.15)
    budget = 'custom',               -- client cap bucket (Config.Scene.Caps key) — custom kinds get their own
}) -> ok, err
Scene.kinds() -> public list (no functions)
```
Owner-tracked (`sceneKind`). A node of an undefined kind is kept and delivered as a placeholder (kind index 0, never
materialised; the editor view may draw it) — the §52 rule. Kind indexes are per server session: the wire carries a
`u16` index and the client learns the table through `KINDS` ops (§55.8).

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **Deviation — `ver` is PER NODE** (RV1 F6), not a module-wide counter: 1 on spawn / load, +1 per change, a u32
  that wraps 4294967295 → 1 (never 0). Two versions of one node are compared with serial arithmetic
  (`d = ((new − old + 2^31) % 2^32) − 2^31`, newer iff `d > 0`), never with `<` / `<=` (the client does the same
  for cell versions, §55.10 notes).
- **Audiences as built**: exactly ONE key per table — `players` (1..256 srcs) | `faction` | `perm` | `editors =
  true` | `near` (0..200 m) | `fn` — composed with `any` / `all` (1..8 entries, nesting ≤ 3); anything else is
  `'audience'`. The EFFECTIVE audience is every level of the node's path (its own and each ancestor's must admit a
  player): `R.store.audienceOf(node)` → nil (public) | the one table (live) | `{ all = { root…node } }` (fresh). A
  child with its own audience is a gate head (§55.5 notes). Persistent nodes refuse `players` (server ids are per
  session, RV1 F8) and `fn` anywhere in the tree.
- **Quotas** (RV1 F3, F13; all `'limit'`): a root carries ≤ `Config.Scene.MaxChildren` (64) descendants; a plugin
  ≤ `Global.MaxPerOwner` (64) global nodes; a plugin introduces ≤ 256 distinct kind ids per server session (a kind
  id keeps its index for the session, so a restarted plugin gets its index back); ≤ 1,024 kinds at once.
- **Foreign parents** (RV1 F13): a node hangs under another resource's node only when that node allows it —
  `allowChildren = true | { resource… }` (≤ 16 names; a spawn / set option, server-side only, never sent); its
  owner and core always may; else `'owner'`.
- The kind table as built: `{ id, idx, class, classCode, fields, tables, names, nearFields, nearList, radius,
  handler, authority, budget, owner, builtin, dependency, filled, derived, clock, post, hasModel, intModel }` —
  `filled` = the server-filled fields (`lod`, `r`, `resolved`), `derived` = model-derived INPUT fields kept when
  given and filled when absent (the vehicle's `vtype`, run I1), `clock` = Clock-valued field paths (`anim.t0`, `t0`,
  `pausedAt`) that persist as phases (§55.18 notes), `post` = a built-in cross-field rule (the `audio.source` shape,
  the vehicle's vtype mapping), `intModel` = `model` also takes an integer hash.

### 55.4 Server API (`server/scene.lua`, proxy for plugins)

```lua
Scene.spawn(def) -> id | nil, err
--  def = { kind, pos, rot?, bucket? = 0, parent? , offset?, offrot?, bone?, motion?, fields?, audience?, radius?,
--          global? = false, persist? = false, interact?, authority?, model? (shorthand for fields.model) }
Scene.set(id, patch) -> ok, err            -- partial fields update (C1); nil values in patch delete optional fields
Scene.move(id, pos, rot?, opts?) -> ok     -- opts = { duration?, ease? } → a tween descriptor (C3); none → teleport
Scene.motion(id, descriptor | nil) -> ok   -- C3; t0 defaults to Clock.at(Config.Scene.Motion.PlanLeadMs)
Scene.attach(id, target, opts?) / Scene.detach(id)   -- target = { node = id } | { player = src } | { net = netId }
Scene.emit(id | { pos, bucket }, name, params?, opts?) -> ok   -- C4 one-shot; opts = { radius?, horizonMs? }
Scene.remove(id, opts?) -> ok              -- opts = { fade = true } (clients delete visibility-safely either way)
Scene.get(id) -> node copy | nil
Scene.query({ pos, radius, bucket? = 0, kind?, owner?, limit? = 256 }) -> array of node copies (index cells + exact test)
Scene.list({ owner?, kind?, bucket? }) -> array of ids
Scene.batch(fn) -> ...                     -- every change inside fn is flushed together (one version per cell)
Scene.on(event, kindOrId, fn) -> handle    -- server hooks: 'spawned'|'changed'|'removed'|'promoted'|'demoted'; off(handle)
Scene.onInteract(kindOrId, fn(src, nodeCopy, action, data)) -> handle
Scene.setModelInfo(fn(kind, model) -> { lod?, radius?, bbox?, vehicleType?, class? } | nil)   -- one provider, owner-tracked
Scene.stats() -> { nodes, byKind, cells, subscribers, bytesPerSecond, flushMs, … }
-- phase B/C (§55.15–§55.17): Scene.promote(id), Scene.demote(id), Scene.lease(id, src), Scene.voice.start/stop/list
```
- Validation order: kind known → fields (`Schema.checkAll`, then `validate` of `table` fields) → pose finite and inside
  the world (x/y ±10000, z −1000..3000) → rotation finite → model through the model-info chain (§55.12) → parent exists,
  same bucket, depth ≤ 4, no cycle → audience shape → limits (`MaxNodes` 100,000 server-wide, `MaxNodesPerOwner`
  20,000, `Global.MaxNodes` 256 global nodes) → `Core.Hooks.run('scene:beforeSpawn', …)` (spawn only).
- Owner rules: `set/move/motion/attach/detach/remove/emit` by the node's owner or core; everyone may read. The owner
  of a persistent node that stopped is still the owner (it may come back); `Scene.adopt(id)` (core only) re-owns.
- Hooks are observers; handlers get copies. Server-side cost of an API call is O(1) plus the node's cell work.
- The public client API and the proxy's plugin surface are in §55.10 and §55.13.

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **Signatures as built** (server/scene.lua; `on` / `onInteract` / `off` are server/scene_store.lua's):
  `spawn(def) -> id | nil, err, detail` (def also takes `allowChildren`; a child defaults to its parent's bucket) ·
  `set(id, patch, opts?) -> ok, err, detail` (patch merges into the fields and the result is checked whole; `opts =
  { remove = { names }, interact = list|false, audience = t|false, radius = m|false, allowChildren = … }`) ·
  `move(id, pos, rot?, { duration = 1..600000, ease = 'inout' }?)` (a teleport ends absolute motions, spin / osc
  survive; for a child or an attached node pos / rot are its offset / offrot, no tween) · `motion(id, desc|nil)`
  (roots only) · `attach(id, { node } | { player } | { net }, { offset?, offrot?, bone? }?)` · `remove(id,
  { fade? }?)` (a source's emitters go with it) · `emit(id | { pos, bucket? }, name, params?, { radius? = 1..TierL,
  horizonMs? = 0..30000 (2000) }?)` (name `^[%w_%-:%.]+$` ≤ 32, params ≤ 1 KiB, a positional event reaches 150 m by
  default) · `drive(id, pos, vel, yaw) -> ok, sent` (roots only, |vel| ≤ 300 m/s; §55.9 notes) · `query(q)`
  nearest first (radius ≤ 10,000, ≤ 4,096 results, gated nodes included) · `list(filter)` ascending ids ·
  `batch(fn, ...)` → fn's results | `nil, 'error'` (fn must not yield: a Wait splits the batch) · `adopt(id, owner?
  = 'core')` core only · `setFocus(src, pos|nil)` / `prefetch(src, pos)` refuse a src nobody is connected as
  (`GetPlayerName`, RV1 F11) · `stats()` adds `promote`, `audio`, `voice`, `persistent`, `global`, `loaded`.
- **Errors**: `'unavailable'` (not loaded yet) `'def'` `'kind'` `'fields'` (+ the Schema errors as detail) `'pos'`
  `'rot'` `'offset'` `'offrot'` `'bone'` `'motion'` `'motion_future'` (a plan whose t0 lies more than 24 h ahead:
  rebase could never move it) `'model'` `'parent'` `'deps'` `'audience'` `'interact'` `'authority'` `'radius'`
  `'global'` `'persist'` `'bucket'` `'limit'` `'hook'` (+ reason) `'missing'` `'owner'` `'dependency'` `'attach'`
  `'duration'` `'ease'` `'name'` `'params'` `'horizonMs'` `'vel'` `'yaw'` `'allowChildren'` `'rotOrder'`, and
  `R.audio.admit`'s `'audio_disabled'` | `'audio_streams'` | `'audio_rate'` — asked LAST for an `audio.source`, after
  `scene:beforeSpawn` (every pass costs a flood-guard token; §55.16 notes).
- **Addition (run I1) — `rotOrder`**: an optional integer 0..5 (default 2 = EULER_YXZ, GTA's) on a CHILD's spawn def,
  in `attach` opts and in `move` opts (kept when absent): the rotation order the clients apply `offrot` in
  (`AttachEntityToEntity`). Ignored on roots, persisted for children, copied by `Scene.get`, cleared on detach;
  `'rotOrder'` for anything else. Core.Attachments sends 1 (the pre-scene applier's and the community prop tables'
  order, §55.21.3).
- **Addition (run I1) — `Config.Scene.OwnerCaps[owner]`** overrides `MaxNodesPerOwner` for that owner: `{ core =
  60000 }` — core owns every map node, player attachment and parked car. The store drops a hook key's container once
  its last handle is gone (a leak fix; `R.store.hookStats()` is internal, for the tests).
- **Addition — `{ net }` attachments** keep the entity and its model; a sliced watcher (≤ 256 per second, only while
  such attachments exist) ends one whose net id no longer names that entity, at its last pose (RV1 F20). A dropped
  player's attachments end at their last pose too.
- Removals rebuild the children list of the root they hung under once per operation (an owner sweep once after the
  sweep): O(subtree), never per removed child (RV1 F3).
- Phase C is wired: `R.promote.beforeChange(node, what)` runs before move / motion / drive / attach / detach and a
  fields `set`; `R.promote.refuses(src, node, action)` before an interaction's dispatch; a promoted node's pose
  (`R.store.pose`) is its clone's.
- Internals beyond INTERFACES §4: `R.store.audienceOf(node)`, `kids(id)` (direct children, live), `copy`, `bump(node)
  -> ver`, `notify`, `each`, `loaded`, `flush`, `settle(node, x, y, z, rx, ry, rz)` (the index folds a finished plan
  into the base pose).

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
- **Core's reserve** (RV4 F3): `Config.Scene.CoreReserve = { nodes = 20000, persistent = 10000 }` — every owner but
  core is refused `'limit'` once the total reaches `MaxNodes − nodes` / `MaxPersistent − persistent`, so plugins can
  never starve maps, attachments and parked cars. `OwnerCaps` gained `inventory = 40000` (one node per ground drop).
- **Reserved fields** (RV4 F11): `mapEl`, `mapType` and `vehId` mean "core made this node". Only core may set, change or
  remove them — anyone else gets `'fields'` with the detail `{ [name] = 'reserved' }` — and no plugin kind may declare
  them (`defineKind` → `'fields:reserved:<name>'`).
- `R.store.follow(node, pos, rot, bucket, persistNow)` (internal, the promotion engine's only — never on Core.Scene):
  a promoted root's base pose follows its clone (index change `'follow'`, re-celled with the 8 m tolerance); a bucket
  move is a DEL in the old bucket and a PUT in the new one, children included, ids kept; moves under 5 cm and 1° are
  ignored; persisted at most once per 30 s, at once with `persistNow` or on a bucket move. No motion, no
  beforeChange, no hooks.

### 55.5 Index: grids, tiers, versions, journals, packs (`server/scene_index.lua`)

- **Grids**. `grid 0` = near cells of `Config.Scene.CellSize` (128 m), key `(cx + 32768) * 65536 + (cy + 32768)`,
  `cx = floor(x / 128)` — the player-grid encoding (§22.1); `grid 1` = far regions of `RegionSize` (512 m), same
  encoding; `grid 2` = the bucket's global set (key 0). Both sizes are read ONCE at start.
- **Membership by tier**: S and M nodes live in the near cell of their (root) position; L nodes in the far region; G in
  the global set. Children never have an entry: they are stored with their root (`root.children`, depth ≤ 4) and every
  op of a child is emitted in the root's cell right after the root's.
- **Variants** of a near cell: `near` (every node, every field) and `far` (M-tier nodes only, without `nearFields`).
  Each variant has its own version (`vNear`, `vFar`); regions and the global set have one (`v`). Versions come from ONE
  module-wide counter (never repeat, 0 = empty — the §52 rule). A change to an S node bumps `vNear` only.
- **Journal** per variant: the last `JournalOps` (64) entries or `JournalMs` (10 s), whichever is smaller; an entry is
  `{ from, to, blob }` where `blob = CELL(grid, key, variant, from, to, n) .. ops` (§55.8). Consecutive entries chain
  (`to` of one = `from` of the next), so "everything since version V" is a concatenation.
- **Pack** per variant: `CELL(grid, key, variant, 0, v, n) .. PUT…` for every node (roots + children, parent first),
  built lazily on first request after a change and cached until the next; a pose-only C2 change invalidates the cache
  without a version bump (clients converge through DR ops).
- **Ops per tick are coalesced per node** (latest wins): PUT absorbs later SET/MOVE/MOTION of the same node; SET merges
  field patches; MOVE/MOTION keep the last; DEL wins over everything and cancels a PUT of a node created and removed in
  the same tick (nothing is sent). A node moving to another cell emits `DEL(how = handover)` in the old cell and `PUT` in
  the new one in the SAME tick (the client keeps its entity).
- **Movers**: nodes with a motion descriptor or an attachment are re-evaluated at `Motion.ServerHz` (2 Hz) in one thread
  that exists only while movers exist: pose from `SceneMotion.pose(node, Clock.now())` (attachments: the target's
  server-known position — players through `PlayerGrid.positionOf`, net entities with `GetEntityCoords`) and re-celled
  only when ≥ `RecellTolerance` (8 m) past the cell border. A re-cell is a handover, never delete + create.
- Internal interface (`R.index`, used by scene.lua, scene_interest.lua, scene_flush.lua only):
```lua
R.index.put(node)                           -- insert or re-index (tier/cell from node.tier/pos); queues PUT
R.index.changed(node, what, data)           -- what = 'set'(patch) | 'move' | 'motion' | 'promote'(netId) | 'demote'
R.index.remove(node, how)                   -- queues DEL; how = 'normal'|'fade'
R.index.event(node|nil, pos, name, params, t, radius)   -- C4; not journaled; stored for this tick's flush
R.index.dr(node, t, x, y, z, vx, vy, vz, yaw)          -- C2; not journaled; latest per node per tick
R.index.drain() -> entries                  -- { bucket, grid, key, variant, from, to, blob } for every changed variant
R.index.pack(bucket, grid, key, variant) -> blob, v    -- cached
R.index.since(bucket, grid, key, variant, fromV) -> blob|nil   -- journal concatenation, nil when not covered
R.index.version(bucket, grid, key, variant) -> v       -- 0 when empty
R.index.gated(bucket, grid, key) -> array of gated nodes in that cell (§55.6)
R.index.transient() -> events, drs          -- this tick's C4/C2 items (drained by flush)
R.index.stats() -> table
```

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **The interface as built** (INTERFACES §4 wins over the block above): `drain() -> entries, gated, events, drs` —
  entries `{ bucket, grid, key, variant, from, to, blob, n, at, big? }`, gated items `{ node (the unit head), id, op,
  blob, n, public? }`, events and DR items carry `node` and `gate`; `event(node|nil, x, y, z, bucket, name, params, t,
  radius, horizonMs)`; `gatedIn(bucket, grid, key)`, `nodesIn` (roots only), `cellsNear`, `keyOf(grid, x, y)`,
  `gatedPut(head) -> blob, n` (deps, head, subtree; `'', 0` for a non-head), `pending()`. The file is 2,053 lines —
  accepted: one module of shared mutable state.
- **Versions move lazily**: the first change after the content was observed (drained, packed, `version()`) takes a
  fresh number and later changes of the tick reuse it, so one number names one content; masked to u32, the counter
  wraps to 1 (the index compares versions for equality only). A C2 pose change drops the pack but keeps the version.
- Coalescing as built: one op per node per entry — two or more kinds of change collapse into one PUT; a node created
  and removed in one tick sends nothing; `attach` (and a `set` whose patch names `a`) re-sends the whole node as PUT
  (offset / offrot / bone cannot ride a SET patch). Nodes cache their PUT ops (`node.opN` / `opF`, keyed by the flags
  byte) in place of `extraNear` / `extraFar`.
- **Gating (RV1 F1)** goes through `R.store.audienceOf`: a child with its own audience is a GATE HEAD — a gated unit
  with its subtree, registered in its root's cell (nested heads own their units). Public packs and entries never
  contain a unit's nodes; DELs go to the head the node was published under.
- **Tree (RV1 F3)**: direct-children sets, every walk O(subtree) — a root with 2,000 children: handover 356 → 2.3 ms,
  pack 215 → 0.8 ms, owner sweep 315 → 2.4 ms. More than 65,535 ops in one entry chain CELL sections.
- A variant nobody subscribes to on its ring skips the encode and clears its journal (`since()` → nil → the pack
  serves). An entry over MaxEventBytes is marked `big` and never goes out as one reliable event (RV1 F9, §55.7).
- **Movers (RV1 F19)**: a plan whose bounding box stays inside its cell ± RecellTolerance (spin, osc, orbit, bounded
  paths / keys / tweens) is PARKED in a heap and only woken at its finish or rebase time (sweep of 2,000 bobbing
  roots 8.8 ms → 0). A finished plan goes to `R.store.settle` (folded into the base pose); a `dr` plan only after 6
  heartbeats without a sample (≥ 10 s, 30 s by default); a plan near the end of Clock.diff's window is rebased (a
  `'motion'` change); every `dr()` sample re-cells a driven root.
- True idle: the first item a tick queues calls `R.flush.wake()` once (reset by the drain). Every encode is pcall'ed
  (a failing node is logged once and skipped).
- Bench (host Lua, pure-Lua msgpack): 50,000 nodes in 4,338 cells, 1,000 changes per tick ≈ 10 ms per drain,
  ≈ 750 B per node; packing all 4,336 cells once (a join storm) allocates 4.3 MB where it allocated 16.8 MB before
  RV1 F12.

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
Player-attached roots are grouped per player ("riders", RV4 F7):
one position read per player per sweep, and no work while the player stays inside the group's safe box; stats
`riders` / `riding` / `ridePasses`. Bench, 1,000 players × 12 attachments standing still: 29.6 → 1.7 ms per second.

### 55.6 Interest: focus, windows, rings, gated audiences (`server/scene_interest.lua`)

- **Focus report** (client → server, `core:scene:focus`, via `Core.Net.on`, schema-checked, cooldown
  `Focus.MinIntervalMs` 250): `(x, y, z, vx, vy, vz, seq, held)` — camera position, camera velocity (m/s), a sequence,
  and `held = { [gridKeyString] = version }` for cells the client still caches (≤ 48 entries). Sent when the focus moved
  ≥ `Focus.MinMove` (16 m), crossed a cell border, the bucket changed, or 5 s passed while moving.
- **Validation** (server): the server-known position `P` = `GetEntityCoords(GetPlayerPed(src))`; when the player is in
  an admin free-camera mode (`Core.Admin.getModes(src)` has `noclip`, `spectate` or `editor`) also
  `GetPlayerFocusPos(src)`; a server script may pin a focus with `Scene.setFocus(src, pos|nil)` (trusted, owner-tracked).
  A report farther than `slack = Focus.Slack (50 m) + Focus.MaxSpeed (90 m/s) × min(2 s, Δt)` from every allowed
  point is CLAMPED to the nearest allowed point (anti-scrape: a client cannot pull the content of a far area). The
  bucket always comes from `GetPlayerRoutingBucket(src)`.
- **Window** around the validated focus `F` and a lead point `L = F + clamp(v × Lead.Seconds (1.5 s), Lead.Max 150 m)`:
  near cells whose nearest point is ≤ `NearRing` (160 m) from F → ring 1; else ≤ `FarRing` (448 m) from F or L → ring 2;
  far regions ≤ `FarRegions` (1,024 m) from F or L; the bucket's global set always. Leaving: a cell drops a ring (or out)
  only when it is ≥ `LeaveMargin` (64 m) past the entry distance AND has been past it for `LeaveDwellMs` (3 s) — both
  timestamps kept per (src, cell).
- **Changes of the window** → for each added cell/variant: `SUB` + (`R.index.since(…, held)` when the client reported
  that variant's version and the journal covers it, else `R.index.pack`); for each removed one: `UNSUB`; a ring change
  = `UNSUB` + `SUB` of the other variant (+ its pack or journal). The server remembers per (src, cell) the version it
  last sent (`sent`), so a repeated report never resends bytes (§52's anti-amplification rule).
- **Backstop**: one thread slices the loaded players (every player once per `BackstopMs` 5 s, ≤ 2 natives each via
  `PlayerGrid.positionOf`, a new accessor on server/playergrid.lua): a player whose server position left the window's
  slack (lost or lying reports) gets a window computed from the server position.
- **Teleports**: `Scene.prefetch(src, pos)` (core-internal, called by `Player.setCoords` before it moves the player)
  subscribes the destination window at once; `Scene.waitAreaReady` on the client (§55.10) then gates the reveal (§48).
- **Bucket change** (`core:client:bucketChanged`, §48, or a different bucket at the next report): unsubscribe all,
  subscribe the new window, reset `sent`.
- **Gated audiences** never enter cell blobs. For each gated node in a subscribed near cell the audience is evaluated
  per subscriber: `players`, `faction` (`Core.Factions` of the character), `perm` (`Core.Perms.has`), `editors` (Admin
  mode `editor` or the player's bucket is an open draft's editor bucket, §52), `near = r` (exact distance from the
  server-known position ≤ r, re-checked by the backstop and on focus reports), `fn` (a callable from the owner,
  pcall'ed, ≤ 0.2 ms budget each). Matching subscribers get the node in the `PRIV` section of their stream; re-evaluated
  on node change, subscription change, and the hooks `factionChanged`, `permsChanged`, `staffModeChanged`,
  `bucketChanged`.
- Internal interface: `R.interest.subscribers(bucket, grid, key) -> map src → ring` (live table, never mutated by
  callers), `R.interest.sentVersion(src, grid, key)` / `setSent`, `R.interest.gatedTargets(node) -> array of srcs`,
  `R.interest.prefetch(src, pos)`, `R.interest.drop(src)`, `R.interest.stats()`.

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **Deviation — the audience half is its own file**, `server/scene_gated.lua` (loads between scene_interest.lua and
  scene_flush.lua and defines `allows`, `gatedTargets`, `gated(items)`, `syncCell`, `syncWindow`, `holders`,
  `privFlush`, `forgetGated`, `forgetHeld`, `gatedStats` on `R.interest`). Every Config key is read ONCE at load,
  clamped. Allowed focus points: the ped, `GetPlayerFocusPos` in the admin modes noclip / spectate / editor, a pin
  (`Scene.setFocus`), a prefetch target (for 10 s).
- **`sent = PENDING`**: an added cell/variant queues its SUB at once; its content (nothing when the held version is
  current, else the journal from it, else the pack) is filled by `R.interest.fill` right after the next drain (the
  index moves versions lazily), and the fill budget is asked after EVERY cell (≤ 4 ms of fills per tick; the rest
  resumes next tick). Journal answers spend the per-player pack budget like a pack; one over MaxEventBytes or the
  budget becomes the pack (RV1 F5).
- **Bucket change**: ANY change — Player.setBucket, the raw native (`onPlayerBucketChange`), or a report / backstop
  visit that reads another bucket — calls `R.flush.reset(src)`: everything queued for the old bucket (items and
  waiting packs) is purged, RESET (§55.8 notes) goes first in the next event and the new window subscribes from
  scratch — no UNSUBs, no held hints, gated holdings forgotten without DELs (RV1 F17, F18).
- **Resync** answers only a subscribed cell in its current variant, at most once per cell per 2 s, budgeted; a cell
  that became empty answers `SUB(grid, key, variant, 0)` to a client asking with v 0 (else a pending cell would
  re-ask every 15 s).
- **Gated delivery as built**: a unit's targets are the subscribers of its cell (a far-ring subscriber of a near cell
  only when the ROOT is M-tier) whose effective audience admits them (several keys in one table must all hold; fail
  closed on an unknown key, a malformed value or nesting > 8). `fn` MUST be synchronous: it runs in a runner
  coroutine, a yield counts as NOT allowed and is logged once per owner (RV1 F4); over 0.2 ms it is counted and
  logged once a minute. **Holders are tracked per node** (RV1 F15): a DEL reaches every src holding what was
  published, whatever head the node belongs to now (re-parent, reveal, detach). PRIV(n) counts OPS, not blobs (RV1
  F16); big PUT-only blobs are cut at op boundaries. `near` heads are indexed per cell, so focus reports and
  backstop visits re-gate O(window), never the bucket (RV1 F7); a global `permsChanged` re-gates 50 windows per
  frame. Hooks: `factionChanged`, `permsChanged`, `playerLoaded` (scene_gated.lua), `staffModeChanged`
  (scene_interest.lua); audience counters in `R.interest.stats()`.

### 55.7 Flush and transport (`server/scene_flush.lua`)

- One thread; while nothing is pending it sleeps 250 ms and does no work; otherwise it runs every `FlushMs` (50 ms =
  the server Lua tick).
- Per tick: `R.index.drain()` → for every entry, every subscriber whose ring matches the variant (near entries → ring
  1, far entries → ring 2, region/global → all) and whose `sent` version equals the entry's `from` gets the entry blob
  appended to its outbox (and `sent` = `to`); a subscriber that is behind or ahead gets the pack instead (resync).
  Then gated-node ops (`PRIV`), C4 events (subscribers of the event's cell within its radius, dropped when older than
  their horizon), C2 DR ops (rate-limited per node and ring: near 10 Hz, far 1 Hz), `KINDS` deltas for clients whose
  kind table is older than the server's.
- **One reliable event per client per tick**: `TriggerClientEventInternal('core:scene:s', src, payload, #payload)`
  with `payload = msgpack.pack_args(header .. outbox)`; `Config.Scene.MaxEventBytes` (16,384) per event — the rest waits
  for the next tick in priority order: UNSUB/SUB and DEL, then PUT of near rings, near updates, far updates, events.
  A client whose backlog exceeds `MaxBacklogBytes` (256 KiB) has its pending entries dropped and its subscriptions
  marked for resync (packs through the latent path) — never an unbounded queue.
- **Snapshots > MaxEventBytes go latent**: `TriggerLatentClientEvent('core:scene:p', src, LatentBps, blob)` (750,000
  B/s) within a per-player token bucket (`PackBudgetBytes` 2 MB, refilled over `PackBudgetWindowMs` 10 s — §52's
  anti-abuse budget); withheld packs are retried when the budget allows; the client queues ops of a cell whose pack is in
  flight (versions decide, latent events are unordered — R1 §1.3).
- Budget: the whole flush ≤ 2 ms per tick at 2,000 players (instrumented: `Scene.stats().flushMs` p50/p99; a tick over
  5 ms logs its counters once per minute).
- Internal: `R.flush.queue(src, blob, prio)`, `R.flush.queueLatent(src, blob)`, `R.flush.wake()`, `R.flush.stats()`.

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **Deviation — no idle sleep**: the thread exists only while something is pending (a queued item, a waiting pack, a
  capped DR op, `R.index.pending()`); `wake()` / `queue` / `queuePack` start it (its first step waits a frame, so a
  wake from inside an index call never runs a tick re-entrantly) and it ends after the first idle check — 0 natives
  while idle. `stats().running` tells.
- **Five queues per client**, in send order: control (SUB, UNSUB, KINDS), PRIV (`queuePriv`: gated sections, FIFO,
  never dropped and never counted by the backlog guard — a lost PRIV DEL would leak a gated node, RV1 F14), near,
  far, transient (expiring). `queue(src, blob, prio)`'s priorities 1..4 map onto control / near / far / transient.
  The event: header, RESET first after `R.flush.reset`, a KINDS delta when the client's table is older, then the
  queues in order up to MaxEventBytes (an item larger than that goes alone and counts as `oversized`); the payload is
  msgpack-packed once for `TriggerClientEventInternal`.
- **Packs**: `queuePack(src, blob, prio, key, latent?)` spends the per-player token bucket (a pack larger than the
  whole budget goes when it is full and leaves it in debt); `spend(src, bytes, force?)` charges journal answers and
  PRIV grants (forced: DELs are never held back). Small packs ride the reliable stream while its backlog stays under
  2 × MaxEventBytes; the rest leave as ONE `core:scene:p` latent event per client per tick (≤ 512 KiB), never before
  their SUB left; ≤ 1 MiB of pack bytes per tick server-wide, clients from a rotating start (bounds a join storm's
  frame). A newer pack of a key replaces a waiting one; `cancel` drops one whose cell left the window.
- An entry larger than MaxEventBytes is never one giant reliable event: its subscribers get `SUB(to)` and the
  cell's cached pack, forced latent (RV1 F9). C4 events and C2 DR ops of a node with an effective audience reach only
  the holders of its unit. Internal API as built: `queue`, `queuePriv`, `queuePack`, `queueLatent(src, blob, key)`,
  `spend`, `reset`, `cancel`, `cancelAll`, `drop`, `backlog`, `wake`, `stats`, `tickNow` (the bench).
- **Bench** (`tests/scene_bench.lua`, 2,000 players and 50,000 nodes offline, pure-Lua msgpack): steady state p50
  1.50 / p99 7.55 ms per tick, 1,617 B/s per client (mean).
- **Known limitation — join-storm garbage.** 2,000 simultaneous joins grow the Lua heap by 377 MiB (≈ 650 MiB before
  RV1 F12): join ticks p99 8.8 ms, the worst one a single ~200 ms GC cycle. Most of it (≈ 266 MiB) is the
  server-side concatenation of header and parts per recipient; the planned fix is multi-part payloads
  `(header, ...parts)` for `core:scene:s` / `core:scene:p` (the runtime msgpacks the varargs in C), dropping that
  concatenation.

### 55.8 Wire format (`shared/scene_codec.lua`, both core VMs)

Little-endian `string.pack` (Lua 5.4). A stream payload is `header .. op*`, header `<B I4` = format version 1, server
`Clock.now()` at the flush. Positions are `i4` centimetres, rotations `i2` centi-degrees normalised to (-180, 180],
velocities `i2` cm/s, times `I4` ms. `s1`/`s2` are length-prefixed strings; `extra`/`patch`/`params`/`meta` are
msgpack blobs (encoded once per change and cached on the node).

| op | code | layout after the opcode byte |
|---|---|---|
| `KINDS` | 0x01 | `H n`, n × (`H idx`, `s1 id`, `B class`, `s2 meta`) — meta = `{ near = {…}, budget, handler }` |
| `SUB` | 0x02 | `B grid`, `I4 key`, `B variant`, `I4 v` — subscribed; the content follows (CELL) or is in flight (latent) |
| `UNSUB` | 0x03 | `B grid`, `I4 key` — keep the content in the LRU (§55.10), stop expecting updates |
| `CELL` | 0x04 | `B grid`, `I4 key`, `B variant`, `I4 from` (0 = snapshot: replace), `I4 to`, `H n` — the next n node ops belong to it |
| `PRIV` | 0x05 | `H n` — the next n node ops are gated nodes (no cell version) |
| `PUT` | 0x10 | `I4 id`, `H kind`, `I4 ver`, `I4 parent`, `B flags`, `i4 x y z`, `i2 rx ry rz`, `H radius`, `s2 extra` |
| `SET` | 0x11 | `I4 id`, `I4 ver`, `s2 patch` |
| `MOVE` | 0x12 | `I4 id`, `I4 ver`, `i4 x y z`, `i2 rx ry rz` |
| `MOTION` | 0x13 | `I4 id`, `I4 ver`, `s2 motion` (empty = static) |
| `DEL` | 0x14 | `I4 id`, `I4 ver`, `B how` (0 normal, 1 handover, 2 fade) |
| `EVENT` | 0x15 | `I4 id` (0 = positional), `I4 t`, `i4 x y z`, `s1 name`, `s2 params` |
| `DR` | 0x16 | `I4 id`, `I4 t`, `i4 x y z`, `i2 vx vy vz`, `i2 yaw` |
| `PROMOTE` | 0x17 | `I4 id`, `I4 ver`, `H netId` |
| `DEMOTE` | 0x18 | `I4 id`, `I4 ver`, `i4 x y z`, `i2 rx ry rz` |

- `PUT.flags`: 1 motion present · 2 promoted · 4 placeholder (unknown kind) · 8 far variant (near fields omitted) ·
  16 interact present · 32 gated · 64 has children (they follow). `extra` = `{ f = fields, m = motion?, o = offset?,
  r = offrot?, b = bone?, a = attach?, i = interact?, n = netId? }`.
- Client → server: `core:scene:focus` (§55.6), `core:scene:resync (grid, key, variant, v)` (cooldown 100 ms, ≤ 16/s),
  `core:scene:interact (id, action, data?)` (§55.14), `core:scene:report (id, what, data?)` (§55.15). All through
  `Core.Net.on` (schema → cooldown → loaded → permission → distance).
- Codec API: `Codec.writer()` (buffer + `u8/u16/u32/i16/i32/s1/s2/done`), one encoder per op
  (`Codec.put(node, variant) -> string`, `Codec.set(id, ver, patchBlob)`, …), `Codec.header(now)`,
  `Codec.decode(blob, handler)` (calls `handler.kinds/sub/unsub/cell/priv/put/set/move/motion/del/event/dr/promote/
  demote` with decoded values; stops safely on a truncated or unknown op and reports `false, err`), `Codec.qpos(v)`,
  `Codec.qrot(deg)`, `Codec.upos(i)`, `Codec.urot(i)`. Round-trip identical in both VMs (suite `scene_codec_tests.lua`).

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **Addition — `RESET` 0x06, `B reason`** (`Codec.RESET`: 1 BUCKET, 2 EPOCH = the server restarted, 3 RESYNC =
  resync-all): the client drops everything it holds (LRU and parked packs included) and reports its focus at once.
  A control op like SUB — not one of a section's n; inside an unfinished CELL / PRIV section the decoder answers
  `'truncated'` (the rest of the section would land on dropped state), so the flush sends RESET FIRST and clears that
  client's queued outbox. `h.reset(reason)` gets the byte as sent (no ctx).
- **Encoders take scalars** (INTERFACES §2), not nodes: `Codec.put(id, kindIdx, ver, parent, flags, x, y, z, rx, ry,
  rz, radius, extraBlob)`, `set(id, ver, patchBlob)`, `move(id, ver, x, y, z, rx, ry, rz)`, `motion(id, ver,
  motionBlob)` (`''` = static), `del(id, ver, how)` (the names `'normal' | 'handover' | 'fade'` are accepted),
  `event(id, t, x, y, z, name, paramsBlob)` (id 0 = positional), `dr(id, t, x, y, z, vx, vy, vz, yaw)`, `promote(id,
  ver, netId)`, `demote(id, ver, x, y, z, rx, ry, rz)`, `sub`, `unsub`, `cell`, `priv(n)`, `kinds(list)` (a removed
  kind travels as `{ idx, id = '' }`), `reset(reason)`, `header(now)`. Also `Codec.writer()` (`u8 u16 u32 i16 i32 s1
  s2 raw done`), `OP_NAME`, `CLASS_NAME`, `uvel`/`qvel`, `msgpackLua` (the built-in subset) and `nativeMsgpack`.
- Quantisation clamps and never raises (NaN / ±inf → 0; radius → u16 whole metres); INTEGER fields go to
  `string.pack` unchanged and RAISE when out of range (a server bug is loud; an id is never rewritten into another);
  clock stamps wrap to u32. An `s1` string over 255 bytes is cut; an `s2` blob over 65,535 bytes RAISES (a cut
  msgpack blob would be garbage).
- **Blobs**: FiveM's `msgpack` when the VM has it, else a pure-Lua subset writing the same bytes (lua-cmsgpack's
  defaults: integers in the smallest form, every float as float64, a 1..n table as an array, the EMPTY table as an
  empty ARRAY 0x90, deeper than 16 levels = nil). FiveM's packer drops an `n` key next to a sequence (the
  `table.pack` form): never mix them in a scene blob. `Codec.pack(v) -> blob | nil, err` never raises (nil → `''`);
  `Codec.unpack('')` is nil.
- **Decoder**: bounds-checked before every read, never raises on hostile or truncated input (`false, 'header' |
  'version:<n>' | 'truncated' | 'unknown_op:<n>'`; the ops before the bad one were delivered); an error raised by a
  HANDLER propagates. Node ops get a reused `ctx = { section, grid, key, variant, from, to }` as their LAST argument
  (never keep it); blob arguments arrive decoded, and only when they decode to a table.
- `extra` keys as built: `f` fields · `m` motion · `o` offset · `r` offrot · `b` bone · `q` rotOrder (run I1: only
  when set and ≠ 2; the client's `node.rotOrder`, a change of it is an `'attach'` update, and both
  `AttachEntityToEntity` sites — kinds and the materialiser's `attachTo` — pass `rotOrder or 2`) · `a` attach
  (`{ p = src }` | `{ n = netId }`) · `i` interact · `n` netId (promoted) · `d` deps; `patch`: `f` changed fields · `x`
  removed names · `i` interact (whole) · `a` attach (false = detached) · `d` deps.
- Events as built: client → server `core:scene:focus`, `core:scene:resync` (server cooldown 62 ms ≈ 16/s; the
  client sends ≤ 1 per 110 ms), `core:scene:interact`, `core:scene:report`, `core:scene:voice:report` (§55.19 notes);
  server → client `core:scene:s`, `core:scene:p`, `core:scene:voice:targets | listen | unlisten`; the callback
  `core:scene:props` (server → the clone's owner); LOCAL client events `core:scene:kind (op, kind, id, view,
  target)` and `core:scene:ev (event, id, info)` (§55.13).

### 55.9 Motion (`shared/scene_motion.lua`, both core VMs; client movers in `client/scene_movers.lua`)

Descriptors (msgpack on the wire, validated by the server on `Scene.motion`, bounded sizes):
```lua
{ t = 'tween', t0, d, to = { x, y, z, rx?, ry?, rz? }, from? , e = 'linear'|'in'|'out'|'inout' }      -- from = pose at t0
{ t = 'path', t0, pts = { {x,y,z}, … ≤ 64 }, sp = m/s | d = ms, loop = 'once'|'loop'|'pingpong',
  curve = 'linear'|'catmull', face = 'path'|'fixed' }                                                  -- centripetal CR, arc-length LUT
{ t = 'spin', t0, axis = 'x'|'y'|'z', dps }                                                            -- relative to the base rotation
{ t = 'osc', t0, dir = {x,y,z}, amp, period, phase? }                                                  -- bob / sway, relative
{ t = 'orbit', t0, c = {x,y,z}, r, period, face? }
{ t = 'keys', t0, keys = { { t, x, y, z, rx?, ry?, rz? }, … ≤ 128 }, loop = bool, smooth = bool }
{ t = 'dr', t, p = {x,y,z}, v = {x,y,z}, yaw }                                                         -- C2 state (server-steered)
```
- `SceneMotion.pose(node, t) -> x, y, z, rx, ry, rz, moving` — pure, identical results in both VMs for quantised
  inputs; arc-length tables cached in a weak table keyed by the descriptor; `dr` extrapolates ≤ 1 s then holds.
- Plans are future-stamped: `t0` defaults to `Clock.at(Motion.PlanLeadMs)` (200 ms) so every client starts the same
  plan at the same time; a client that receives a plan late starts at the current phase with a 200 ms positional blend.
- **Client evaluation budget**: LIVE movers within `Motion.NearRadius` (50 m) and on screen every frame; other LIVE
  movers at `Motion.MidHz` (15 Hz); off-screen movers not at all (re-placed on their next evaluated frame). Entities are
  placed with `SetEntityCoordsNoOffset` + `SetEntityRotation` (kinematic, frozen); a per-frame loop exists only while
  movers are LIVE (§9 rule).
- **Server-steered movers (C2)**: `Scene.drive(id, pos, vel, yaw)` (server scripts) keeps the server's own
  dead-reckoned copy and sends a DR op only when that copy errs > 0.25 m (near) / 1 m (far) or > 3°, heartbeat 5 s,
  rate caps 10 Hz near / 1 Hz far; clients blend with projective velocity blending over the nominal interval and snap
  above 5 m (GTA's own threshold).
- **Platforms carrying players are promoted while occupied** (§55.15): GTA syncs riders only relative to networked
  objects (R7 §2.4).

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **API as built** (pure, no natives, no allocation once a path's table exists): `Motion.validate(desc) -> true,
  normalized | false, err`; `pose(bx, by, bz, brx, bry, brz, desc, t) -> x, y, z, rx, ry, rz, moving` (the scalar
  form, not `pose(node, t)`); `velocity(desc, t, bx?, by?, bz?)`; `finished(desc, t)`; `needsRebase(desc, t)`
  (|Clock.diff(t, t0)| > 2^30 ms ≈ 12.4 days) and `rebase(desc, t)` → a NEW descriptor with t0 = t and the same
  future: periodic phases move into `ph` (loop / pingpong paths, looping keys; ms), `phase` (osc; degrees) or `a0`
  (orbit; a spin folds the angle it turned into its `a0`); a finished tween / once path / non-looping keys becomes a
  1 ms tween that ended at t − 1 on the exact end pose; a `dr` past its 1 s horizon becomes its held point (v = 0).
- Descriptor details as built: `dr` keeps its sample time in `t0` (`t` is the type tag; default Clock.now());
  orbit `{ c, r, period, a0 (a GTA heading around c, 0 = north), cw, face = 'fixed'|'path'|'center' }`; osc `phase`
  in degrees, `dir` a unit vector; spin `axis` (default 'z') and `a0`; path defaults `loop = 'once'`, `curve =
  'linear'`, `face = 'fixed'`, `'loop'` CLOSES the path, `d` = the time of ONE pass, points closer than 1 mm merged,
  16 arc-length samples per segment (cached per descriptor, weak keys); keys: times relative to t0, strictly
  increasing, a missing key angle = the base angle, `smooth` = time-scaled Catmull-Rom. Durations, periods and key
  times ≤ 2^30 ms; before t0 every motion holds its Δt = 0 pose with `moving = false`.
- Server: a plan stamped more than 24 h ahead is refused (`'motion_future'`: rebase could never move it). The index's
  movers sweep rebases live descriptors and settles finished ones (§55.5 notes); `Scene.drive` makes the node's
  motion a `dr` on its first call (a MOTION op), then sends DR ops only past the thresholds (roots only).
- **Client movers as built** (client/scene_movers.lua, `C.movers.track(node, handle, handler, retarget?)`): "on
  screen" uses THIS frame's rendered camera against the materialiser's widened cone — one coord and one rotation read
  per frame while a mover is tracked (RV2 F11); an entity with an attach target rides it through
  `AttachEntityToEntity` (re-attached within 500 ms when the target entity changes: respawn, model swap, a
  re-created clone). **Blending** (RV2 F12): a new DR sample, a motion change or a late plan of a mover already on
  screen blends from what is rendered (pose and velocity) by projective velocity blending over the nominal interval
  (DR: 1000 / NearHz = 100 ms within NearRing, else 1000 / FarHz = 1 s; plans 200 ms), snapped beyond
  `DeadReckoning.Snap` (5 m). Each mover runs in its own pcall (a failing one is logged once and untracked); a motion
  that `finished()` is untracked once its blend ended. DR ticks never reach plugins or `changed` listeners.

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
The client movers loop sleeps 500 ms while it tracks only
engine-attached riders — one pass checks them all (RV5 F4: every Core.Attachments prop used to hold it at Wait(0));
`track()` starts a fresh loop (per-frame waits in 10 s: 625 → 0).

### 55.10 Client cache and API (`client/scene_cache.lua`, `client/scene.lua`)

- **Receive**: `core:scene:s` (one binary string per tick) and `core:scene:p` (latent packs) are decoded with
  `Codec.decode` in the event handler (never per frame). Per cell the client keeps `{ grid, key, variant, v, state =
  'pending'|'live'|'lru', nodes = { [id] = true } }`; per node the decoded record plus `ver`.
  - `CELL` with `from = 0` replaces the cell's content (nodes not in the snapshot leave the cell; a node that went to
    another cell is kept if that cell has it); `from = v` applies and sets `v = to`; any other `from` discards the ops
    and asks `core:scene:resync` (≤ 16/s, coalesced per cell). A node op with `ver ≤` the node's `ver` is ignored
    (out-of-order safe). `DEL(handover)` keeps the entity for a `PUT` of the same id later in the same payload.
  - Newest state per node per payload wins (head-of-line bursts, R7 §0.2); decoding a 16 KiB payload is ~20 µs of Lua
    (R1 §8).
- **LRU**: an `UNSUB`bed cell keeps its nodes (not materialised: the materialiser treats them as unwanted) for up to
  `ClientLruMs` (120 s), at most `ClientLruCells` (48) cells; the focus report lists their versions so a return costs a
  journal, not a pack.
- **Focus reporter** (one thread): samples `GetFinalRenderedCamCoord()` every 250 ms while moving, 1000 ms still, never
  before `LocalPlayer.state.loaded`; velocity from successive samples; sends per §55.6.
- **Public client API** (`client/scene.lua`; plugins reach it through the proxy, handlers through the lib):
```lua
Scene.get(id) -> read-only copy { id, kind, pos, rot, fields, parent, state } | nil
Scene.handleOf(id) -> entity | nil          Scene.idOf(entity) -> id | nil
Scene.isAreaReady(pos, radius = 50) -> bool  Scene.waitAreaReady(pos, radius, timeoutMs) -> bool   -- from a thread
Scene.hold(id) / Scene.release(id)           -- the runtime leaves the node's entity alone (editor drag); owner-tracked
Scene.on(event, kindOrId, fn) -> handle / Scene.off(handle)   -- 'live' | 'gone' | 'changed' | 'event' | 'enter' | 'exit'
Scene.stats() -> { cells, nodes, live, byState, byBudget, queued, fades, models, voices, bytesIn, … }
```
  Plugin `Scene.on` handlers run in the plugin's VM: the lib registers one local event handler and tells core (proxy
  `Scene.listen(kindOrId, event)`) that someone listens, so core triggers `core:scene:ev` only for listened
  kinds/ids — zero cost otherwise.
- Commands: `/scene` (stats), `/scene debug` (overlay: subscribed cells and rings, the nearest 32 nodes with their
  state and radii, queues, fades, budgets) — `Config.Scene.Debug` or ACE `core.admin`.

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **Deviation — the reporter is client/scene_focus.lua** (`C.focus`): samples at 250 ms moving / 1000 ms still, a
  jump of ≥ 150 m is a teleport (no velocity); reports go ≥ MinIntervalMs + 30 ms apart; `held` = the LRU cells'
  versions, newest first, ≤ 48, keyed `'<grid>:<key>:<variant>'` (the variant of the content held). Resync requests:
  ≤ 1 per 110 ms, ≤ 1 per cell per 2 s, deferred, never dropped (RV2 F10); a pending cell whose content never came
  re-asks every 15 s. A REAL `core:client:bucketChanged` (a known bucket, another one) drops the whole cache and
  reports at once — the first notice only seeds the bucket (RV2 F1); a change nobody told the client about arrives as
  the stream's RESET (`C.focus.onReset`, RV2 F14).
- **Cells** keep the cached content's variant and version (`cv`, `v`) next to the subscribed `variant`: a SUB at the
  held version is live at once; a newer one stays pending until its journal or pack lands; an older one is live
  (journal entries up to the held version are skipped); late packs of another variant are ignored. A latent
  snapshot stamped > 25 ms before its cell's SUB is ignored; one arriving BEFORE its SUB is parked (≤ 3 s, ≤ 16
  packs; RV2 F6). Live cells awaiting a resync buffer journal entries like pending ones.
- **Versions** of nodes and cells are compared wrap-aware (`vdiff` / `vnewer` / `vreached`, never `<`); a fresh node
  record has ver 0. A near PUT over a record that came from the far variant applies at the same ver (its near
  fields, RV2 F15); a PRIV DEL applies whatever its ver.
- Payloads over 16 KiB — and whatever arrives while one is in work — go to a worker that applies 256 node ops per
  frame in stream order (RV2 F17).
- **The C.mat protocol**: `add(node)` = the node entered the wanted set (subscribed or gated-and-present, kind known
  and handled, parent here), `remove(node, how)` = it left it (`how` 1 = handover: the entity is kept 1 s for a PUT
  of the same id), `update(node, what, data)` once per payload, `event(...)` after the node work; a subtree goes root
  first, links intact (RV2 F3). Dependency nodes never reach C.mat (a change is `update(node, 'dep')` of every
  dependent). A plugin kind is wanted only after the resource its `meta.handler` names has claimed it.
- **Public API as built**: `get(id)` (a copy; `state` = known | warm | staged | live | retiring | failed | off),
  `handleOf(id)` (the local copy → a plugin's late-bound entity → the promoted clone), `idOf(entity)` (+ clones),
  `isAreaReady(pos, radius = 50, ≤ 500)`, `waitAreaReady(pos, radius?, timeoutMs = 5000, ≤ 60000)` — it only waits
  (the teleport budgets follow the faded screen, RV2 F7), `hold(id) -> entity|nil`, `release(id) -> boolean`,
  `on` / `off` (core's VM: direct listeners), `listen` / `unlisten`, `claim` / `bind` (§55.13), `stats()` (the
  materialiser's, the cache's and the reporter's counters plus `plugin = { claims, waiting, bound, listens }`); lib
  helpers `validKindId`, `isPluginKind`, `tierOf`, `PAINTS`, `paintOf`. Listener events add `promoted` / `demoted`;
  `info = { event, kind, entity? (live), changes + fields (changed), name, params, age, pos (event), netId
  (promoted) }`.
- `/scene` also answers staff on duty (`Core.Admin.getSelf().duty`); the overlay refreshes at 2 Hz and only draws
  per frame, while it is on.

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
`Scene.isAreaReady` / `waitAreaReady` first ask the maps hand-off
`C.mapsPending(x, y, r)` (client/maps.lua, read at call time; absent or erroring = ignored): while the server still
projects a large map change around the point (§55.21.1 notes) the area is not ready — teleports wait for it; then the
cache and materialiser checks as before, with the same poll and timeout.

### 55.11 Materialiser (`client/scene_materializer.lua`)

The §52.4 engine generalised (zero-allocation evaluation, 64 m client cells with conservative bounds, rings, queues,
ref-counted assets), plus the anti-pop pipeline of R5 §9.

- **States**: `KNOWN` (cached, no game cost) → `WARM` (assets requested: model, anim dict, ptfx asset, audio preload) →
  `STAGED` (created; either beyond its visible range, or inside it at alpha 0 waiting for its fade slot) → `LIVE` →
  `RETIRING` (deletion wanted but deferred: visible and seen recently, or fading out) → `GONE` (entity deleted, assets
  released after `ModelLingerMs` 30 s). Counts per state and per budget class are kept incrementally.
- **Radii** (per node, recomputed when `GetLodscale()` — sampled every 1 s — changes by > 5 %, or the node changes):
  | class | `R_vis` | `R_in` (create) | `R_out` (delete) |
  |---|---|---|---|
  | prop | `L·S + B` (B = 20 m; 5 m when L ≤ 20) | `R_vis + 10 + lead` | `R_in(no lead) + max(20, 0.25·R_in)` |
  | vehicle | 500 (engine) | 255 | 311 |
  | ped | 240 (engine) | 130 in view / 75 out of view | 140 / 90 |
  | audio | range | range + 20 (enters silent) | range + 40 |
  | light | range × 3 | min(range × 3 + 50, 300) | R_in + 30 |
  | particle, marker, text | drawDistance | drawDistance + 10 | + 20 |
  | hide | — | radius + 150 | + 50 |
  | zone | — | bounding radius + 20 | + 20 |
  | custom | node radius | node radius | + max(20, 0.25·r) |
  `L` = the prop's lodDist (`fields.lod`, filled by the server's model-info chain, default 100), `S` = the LOD scale,
  `lead` = camera speed × `Lead.Seconds` (1.5 s) for nodes within ±60° of the velocity, ≤ 150 m. `R_warm = R_in + 50`.
  Props whose `R_in` exceeds `Radii.PropCap` (500 m) get `SetEntityLodDist(e, floor((cap − B − 10) / S))` so the engine
  band still lands inside our radius (a slightly shorter draw distance that fades beats a longer one that pops).
- **Priority**: late first (inside `R_vis` and not LIVE), then ascending `k = (d / R_in)² × (0.35 + 0.65 · f)` with
  `f = 0.5 − 0.5·cos α`, α between the camera forward (or the velocity above 8 m/s) and the node; bucketed into 32
  bins, no sort, no allocation.
- **Per-frame budgets** (`Wait(0)` only while a queue holds work, else 100 ms moving / 500 ms still):
  `Budgets.PropsPerFrame` 8 creations, `EntityPerFrame` 1 ped-or-vehicle, `CustomPerFrame` 2, `DeletesPerFrame` 32,
  `ModelRequestsPerFrame` 2 new requests, `ModelsInFlight` 30; ×`TeleportMultiplier` (10) while the screen is faded
  (`IsScreenFadedOut()` or a core teleport in progress).
- **Caps** (`Config.Scene.Caps`): props 3,000 (the server.cfg pool raise is part of this build; 1,500 without it),
  peds 48 (hard 64), vehicles 32 (hard 48), lights 32, particles 32, markers 64, texts 64, sounds 24, hides 200, custom
  64 per kind; distinct models: props 150, peds 20, vehicles 20. Core.Maps' objects count against the props cap until
  phase D. When a cap is full the farthest UNSEEN node is evicted; a visible one never; if every candidate is visible,
  creation stops. A swap needs the newcomer ≥ 10 m closer and ≥ 100 ms since the evicted node's release (MTA).
- **Pool guard**: own counters always; `#GetGamePool('CObject')` only after a failed create or while own props > 60 %
  of the cap, at most every 10 s; no new props above 85 % of the object pool (3,300; 5,300 raised). A refused create
  pauses that class for 1 s (§52).
- **Visibility-safe deletes**: per LIVE node `seenAt` (in the frustum — one camera read per evaluation, Lua dot
  products — and within `R_vis`). A wanted deletion runs at once when `d > R_vis` or unseen for `Visibility.UnseenMs`
  (1.5 s; 4 s for peds and vehicles); otherwise the node is `RETIRING` for up to `DeferMaxMs` (10 s), then fades out.
- **Fades** (explicit, only for late arrivals and in-view deletions): props 300 ms in / 450 ms out (screen-door),
  peds 600 ms, vehicles 400 ms (true alpha, ≤ 8 at once); stepped by frame time in one loop that exists only while a
  fade runs; `SetEntityAlpha(e, a, false)`, ended with `ResetEntityAlpha` (in) or `DeleteEntity` (out); at most
  `Fades.Max` (48) at once — a non-urgent late arrival WAITS for a slot; ramps start at 51 (below 50 nothing is drawn).
  Above `Speed.NoFadeAbove` (80 m/s) no fades (GTA does the same); above `Speed.SkipSmallAbove` (50 m/s) props whose
  projected size at `R_vis` is under 4 px are not created.
- **Physics and collision**: static props frozen (`fields.frozen`); `physics = 'local'` props are created frozen and
  unfrozen when `HasCollisionLoadedAroundEntity` and the camera is within 30 m; script peds/vehicles freeze themselves
  while ground collision is missing (R3 §6.4). `SetEntityLoadCollisionFlag` is never used.
- **Interiors**: nodes carry `fields.room = { interior, key }` when an editor placed them; otherwise
  `GetInteriorAtCoords` once per node. An interior node is created only after `IsInteriorReady(interior)` (polled at
  4 Hz while pending), then `ForceRoomForEntity(e, interior, key)` when a key is known.
- **Holds**: a held node's entity is never moved, re-created or deleted by the runtime; changes apply on release (§52).
- **Handover**: a node that changed cell keeps its entity; a node whose model/kind changed is re-created through the
  queues (fade rules apply).
- Internal interface (`C.mat`, used by the cache, kinds, movers, promote, audio): `add(node)`, `update(node, what)`,
  `remove(node, how)`, `event(node, name, params, age)`, `registerKind(kindClass, handler)`, `handleOf(id)`,
  `idOf(entity)`, `hold/release`, `areaReady(x, y, z, r)`, `setTeleport(on)`, `stats()`. Handler shape:
```lua
{ class = 'prop'|'vehicle'|'ped'|'fx'|'data'|'audio'|'custom', budget = 'props'|…,
  assets = fn(node) -> list of { type = 'model'|'anim'|'ptfx'|'audio', name|hash },   -- WARM
  radii = fn(node, S) -> rVis, rIn, rOut        -- optional (else the table above)
  create = fn(node, ctx) -> handle|true|nil     -- nil = failed (logged once per model)
  update = fn(node, handle, what), destroy = fn(node, handle),
  place = fn(node, handle, x, y, z, rx, ry, rz),  -- movers
  event = fn(node, handle, name, params, age),
  fade = 'engine'|'alpha'|'none'|'self' }        -- 'self': the handler fades (lights, particles, audio)
```

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **Deviation — client/scene_mat_assets.lua** holds the resources the materialiser drives: `C.assets` (models, anim
  dicts, ptfx assets requested once, ref-counted, polled at 20 Hz, failed after 10 s once per session with one log
  line, released ModelLingerMs after the last use; distinct models per class; model sanity and class checks;
  interiors) and `C.fades` (≤ Fades.Max at once, ≤ Fades.MaxVehicles vehicles, one loop only while a fade runs,
  ramps from alpha 51, a reversal continues from the current alpha). A fade-out ends in the owner's deletion or
  `DeleteEntity` without `ResetEntityAlpha`: the engine frees an override slot when its entity is deleted (research
  R5 §1, from the engine source), and a reset before a deletion that lands a frame later would flash the entity
  opaque. Probe P4 confirms the release in game.
- **States** add `FAILED` (an asset failed, create refused 3 times, or no bind within 5 s: never again this session)
  and `OFF` (no handler, placeholder kind). **Late binds**: a create may answer `C.mat.PENDING` (the plugin-kind
  bridge); the record stays STAGED until `C.mat.bound(node, entity | 0)`, 5 s at most. Update vocabulary: `'fields'`
  (data = the changed names) `'move'` `'motion'` `'dr'` `'kind'` `'radius'` `'attach'` `'interact'` `'dep'`;
  `update() == false` = re-create; handlers never hear `'dr'` (the movers place the entity).
- **Budget as built**: nothing known = a bare 500 ms sleep; otherwise one camera check (coord, rotation, screen fade)
  per 100 ms moving / 500 ms still, and the FULL evaluation only after ≥ 4 m or ≥ 10° or a content change (a thread
  evaluation yields a frame per 2,000 records). Movers and retiring records alone get a LIGHT pass — O(movers +
  retiring), no grid walk (RV2 F4). Priority: 2 × 16 bins (late arrivals first, then the rest), no sort.
  `GetLodscale` + `GetFinalRenderedCamFov` + `GetAspectRatio` once per second; a scale change re-derives the radii
  in slices of 500 records per frame (RV2 F5; the old client/maps_spawn.lua had it too until phase D), and the cell
  bounds / `maxReach` are rebuilt the same way, also when the widest record left (RV2 F18, at most once per 5 s).
- **Teleport mode** (×10 budgets, no fades, no deferred deletes) = the screen is faded out; `C.mat.setTeleport` only
  marks a core teleport in progress, and `Scene.waitAreaReady` never switches it on (RV2 F7).
- **Pool guard (RV2 F16)**: `Config.Scene.ObjectPool` (nil = learn it: 3,300 assumed, raised by a larger pool read,
  lowered by a create refused below it, each logged once; 5,300 with the server.cfg raise). No new props above 85 %
  of it; `GetGamePool('CObject')` is read at most every 10 s, only after a refused create or while own props are over
  60 % of the props cap.
- Caps are per budget key; a key without its own cap (`audio`) falls back to `Caps.custom` (64). Since phase D (run
  I1) the caps, budgets and the pool guard count nothing of Core.Maps any more: map props ARE scene nodes and count
  as props (the once-a-second `Core.Maps.stats()` sampling and `mapsHides` in the stats are gone).
- `C.mat` as built: `registerKind add update remove event bound PENDING handleOf idOf hold release areaReady
  setTeleport camera lodScale cone inView fadeIn fadeOut setListener targetOf attachTo compose evaluate stats shutdown
  isStopped` (`setListener` carries live / gone to `Scene.on`). Fades and movers run in their own guarded per-frame
  loops (a pcall per fade and per mover, RV2 F20).
- Bench (client_scene_mat's `[bench]` line, host Lua): 2,000 nodes along a 3 km road at 50 m/s — 0.079 ms per
  evaluation, 33 creations/s; 0 bytes allocated over 100 steady evaluations; the worst rescale frame (5,000 records)
  ≈ 1 ms.

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
- New client-only removal flavour `'world'` (3, never on the wire; RV6 F3): on a bucket change or a RESET(BUCKET) the
  old world's copies lose collision and are hidden the same frame, and are deleted at the next wake;
  `C.mat.worldReset()` also purges copies that were already fading out.
- Prompts clear the moment a node leaves (except on a hand-over) and come back if the node is revived (RV6 F4: a
  retiring entity's prompt stayed pressable, and `restart inventory` doubled every drop prompt).
- New natives: `SetEntityCollision`, `SetEntityVisible` (materialiser); client/scene_kinds.lua uses `GetEntityType`.

**In-game probe results (Liam, 2026-09-26 22:21 UTC, `scene_probe/data/report_20260926_222136.txt`).**
- **The fade band is CONFIRMED for script objects** (P1): `prop_bench_01a`, lodDist 120, S 1.0 — the engine's alpha
  rose linearly from 0 at ~140 m to 255 at ~120 m (32 @ 137.5 m … 235 @ 121.6 m) and the reverse walk faded out the
  same way, so creating beyond `lod·S + band` and letting the engine fade is right. (The probe's own "POP" verdict was
  wrong: it read the creation value 255 of an entity the engine had not scanned yet — AGENTS §8; fixed in the probe.)
- Alpha slots (P4): 256 granted to 300 props; `ResetEntityAlpha` frees a slot, `DeleteEntity` frees it (20 / 20 each),
  `SetEntityAlpha(e, 255)` does NOT — the §55.11 / AGENTS §8 rule stands.
- Pools (P5): 2,000 local objects created (CObject 456 → 2,473), 64 local peds (CPed 45 → 111), 48 local vehicles
  (CVehicle 136 → 181 with an ambient baseline of 136 of 300, so `Caps.vehicles` 64 leaves ~100 of headroom); ~45–54 ms
  per 100 objects created at once — why creation is budgeted per frame.
- P2 sampled only one context (on foot, third person: S = 1.0) and P6 crashed on the client's missing `os` library
  (fixed in the probe): both are to be re-run; the design (S sampled once a second) is unchanged.

### 55.12 Built-in kinds (fields; `server/scene_kinds.lua` schemas, client handlers in scene_kinds.lua / scene_fx.lua)

| kind | class / budget | fields (Schema; defaults) | client |
|---|---|---|---|
| `prop` | prop / props | `model`*, `frozen` = true, `collision` = true, `invincible` = false, `visible` = true, `tint` 0..15, `physics` = 'static' \| 'local' \| 'promote', `anim` = { dict, clip, loop = true, rate = 1, t0 }, `room`, server-filled `lod`, `r` | `CreateObjectNoOffset(hash, x, y, z, false, false, false)`, rotation order 2, `SetEntityLodDist`, freeze / collision / invincible + `SetDisableFragDamage`, `SetObjectTextureVariation`, entity anim phase = `(Clock.now() − t0) × rate` |
| `vehicle` | vehicle / vehicles | `model`*, `props` (CoreVehicleProps, validated like `Vehicles.saveProps`), `plate`, `locked` = false, `engine` = false, `lights` 0..2, `siren` = false, `doors` = { [door] = 0..1 }, `frozen` = true, `invincible` = false, `dirt` 0..15, server-filled `vtype` | local `CreateVehicle(hash, x, y, z, heading, false, false)`, pitch/roll by rotation, props through core's internal apply (no network-control wait), doors locked for the LOCAL copy (entering goes through promotion, §55.15), engine/lights/siren/doors, frozen while parked |
| `ped` | ped / peds | `model`*, `appearance` (§34 CoreAppearance) or `variation` = { components, props }, `scenario`, `anim` = { dict, clip, flag, loop, rate, t0 }, `weapon`, `invincible` = true, `frozen` = true, `blockEvents` = true, `health`, `room` | local `CreatePed(4, hash, x, y, z, heading, false, false)`, appearance via `Spawn.applyAppearance`, scenario or anim with clock phase, weapon, blocking events, no ragdoll while frozen+invincible |
| `light` | fx / lights | `type` = 'point' \| 'spot', `color`, `intensity` 0..100, `range` 0.1..100, `shadow` = false, `dir`, `falloff`, `inner`, `outer`, `flicker` = 'none' \| 'candle' \| 'neon' \| 'strobe', `seed` | one per-frame draw loop while any light is LIVE (`DrawLightWithRangeAndShadow` / `DrawSpotLightWithShadow`); intensity × fade × flicker(`Clock.now()`, seed) |
| `particle` | fx / particles | `asset`*, `name`*, `scale` = 1, `color`, `alpha` = 1, `drawDistance` = 150 | `RequestNamedPtfxAsset` in WARM, `UseParticleFxAsset` + `StartParticleFxLoopedAtCoord` (on the parent entity for children), alpha ramp with `SetParticleFxLoopedAlpha`, `StopParticleFxLooped` |
| `marker` | fx / markers | `type` 0..43, `scale`, `color`, `bob`, `face`, `rotate`, `drawDistance` = 50 | `DrawMarker` in the fx draw loop; alpha by the last 10 m of `drawDistance` |
| `text` | fx / texts | `text`* ≤ 128, `scale`, `font`, `color`, `outline`, `drawDistance` = 25 | `SetDrawOrigin` + text natives in the fx draw loop (the §6.5 text-label recipe) |
| `hide` | fx / hides | `model`*, `radius` 0.5..50 | `CreateModelHideExcludingScriptObjects` on LIVE, `RemoveModelHide` on GONE (the 256 map-change cap is shared: ≤ 200) |
| `zone` | data | `shape` (a `Core.Geometry` definition), `events` = true | containment against the player ped at 4 Hz while LIVE → local `enter`/`exit` events (advisory, never authority) |
| `sound` | fx / sounds | `name`*, `set`, `looped` = true, `range` = 30 | `GetSoundId` + `PlaySoundFromCoord` (`PlaySoundFromEntity` for children), `StopSound` + `ReleaseSoundId` |
| `group` | data | — | nothing; its children stream with it atomically |
| `audio.source`, `audio` | audio | §55.16 | §55.16 |

`*` = required. **Server model-info chain** for `prop`/`vehicle`/`ped`: `Scene.setModelInfo` provider → the §52 Maps
model validator (lazily, when registered) → defaults (prop `lod` 100, `r` 2; vehicle `vtype` 'automobile'). Results
cached per `<kind>:<model>` (≤ 4,096). The server cannot check that a model exists; the client fails a missing or
wrong-type model once per session and logs it (§52 rule).

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **Handler contract as built**: `create` → entity | `true` (a non-entity kind keeps its record itself: a handle
  the materialiser sees is always an entity) | nil (failed); `update` re-reads `node.fields` and diffs them against
  what the handler applied, so it does not depend on the exact `what` / `data` — `false` = re-create (a model
  change, a particle's asset / name, a text that lost its text); `destroy` tolerates an entity a fade-out already
  deleted. Handlers attach children and attach targets themselves (`AttachEntityToEntity` with all 16 arguments);
  player attachments are adopted and re-attached by the movers when the ped handle changes (§55.21.3).
- Every entity is created FROZEN; an unfrozen one wakes once its collision is loaded and the camera is within 100 m
  (`physics = 'local'` props: 30 m); movers stay frozen; the 30 s give-up counts only time near the camera (RV2 F19).
  One maintenance thread (250 ms, only while work is pending, pcall per tick, `warnOnce` per site) does the wakes,
  the ped anim-phase fix-ups and the ground snaps.
- **prop**: `snap = 'ground'` (§55.21.2) → `PlaceObjectOnGroundProperly` after create and after every re-placement,
  retried ≤ 5 times while the camera is within 20 m and the collision streams. **vehicle**: `lights` 0 / 1 / 2 = off /
  on / on + full beam; a local copy without `props.colorPrimary` gets `Scene.paintOf(id)` (the promoted clone gets
  the same paint, §55.15); props through `Core.Vehicles.setPropsLocal(veh, props) -> bool` (§6.8: the `setProps`
  apply without the network-control request, never yields).
- **fx** (client/scene_fx.lua: light, particle, marker, text): one draw loop, alive only while one of them is live or
  a fade runs, and per frame only while one is within its draw range (range × 3 / drawDistance; RV2 F21); ≤ 20
  text draw-origin groups and ≤ 4 shadowed spot lights per frame; a text over 99 bytes goes out as up to three
  `CELL_EMAIL_BCON` components (≤ 297 bytes); a spot light points along `dir`, else along the rotation, where
  (0, 0, yaw) points straight DOWN and pitch tilts it up; markers and texts fade `'self'` over the last 10 m of
  drawDistance. Every pass runs under pcall: the record that fails is dropped (and re-created by the materialiser).
- **world** (client/scene_world.lua: hide, zone, sound, group; `fade = 'none'`): zones test the player ped at 4 Hz
  and raise enter / exit through `C.emit` (`Scene.on`) and `C.fx.onZone` — never bridge both; a sphere / box
  without `coords` is centred on the node and follows movers; sound ids ≤ Caps.sounds; model hides ≤ Caps.hides —
  the game's 256 map-change slots are one budget for core (RV2 F13), and since phase D Core.Maps' hides are scene
  `hide` nodes, so Caps.hides covers them all; an over-budget record waits (FIFO) — a hide takes a slot only when
  another is released (run I1 removed the hides' 1-per-second retry), a waiting sound is also offered one at most
  once a second (the game can refuse sound ids); sounds hear the C4 events `play` / `stop`.
- Interactions are added at create (STAGED, not LIVE); a descriptor's `prompt = { world, offsetZ, range }` picks the
  world dot or the text UI; a new list that differs only in labels (a drop's count) relabels the live prompts
  (`Interactions.setLabel`). A `perm` descriptor's prompt shows for everyone — the server refuses the press.
- Server schema additions: prop `snap` (`'ground'`), `interact[].prompt` `{ world = bool, offsetZ = −5..5, range =
  1..50 }`. The fields and defaults as built are `BUILTIN` in server/scene_kinds.lua.
- Open in game: `CELL_EMAIL_BCON` for texts over 99 bytes; `SetVehicleDoorControl` partial ratios.
- **Phase D (run I1) — the model-info chain**: only a `Scene.setModelInfo` provider answering `false` REFUSES a model.
  The §52 Maps validator (the admin catalogue) is an info source only — a model it knows gives its `lod` /
  `vehicleType`, one it does not know gets the defaults — so addon / streamed models and weapon objects spawn with
  the admin plugin running; Maps enforces its allow-list itself at apply (`checkModelOf` on create, update and
  rollback). `model` of prop / vehicle / ped also takes an INTEGER hash (kept as is; it skips the Maps validator,
  which knows names only) and a `'0x%08X'` string, which clients decode to the signed hash.
- **Phase D (run I1) — fields**: prop, vehicle, ped, marker and hide gain `mapEl` (≤ 48) and `mapType` (≤ 64) —
  ordinary fields, never near-only, so every variant carries them (client/maps.lua indexes by `mapEl`). The vehicle
  gains `vehId` (≤ 64, `^[%w_%-:]+$`, parked cars), its `plate` pattern is `^[%w %-]*$`, and `vtype` is an INPUT: one
  of the 8 CreateVehicleServerSetter types (automobile, bike, boat, heli, plane, submarine, trailer, train) or a
  vehicles.meta name mapped onto one (quadbike / amphibious_* / submarinecar → automobile, blimp → heli); the model
  info fills it only when absent, and a model change re-derives it unless the same patch names one.
- **Phase D (run I1) — removing vehicle fields**: a local copy cannot take back what `setPropsLocal` applied, so
  removing `plate` or `dirt`, or a `props` key the copy already applied, answers `update() == false` and the local
  vehicle is re-created; colours and a props plate that the node's own `plate` covers are restored in place, and a
  plate change stays in place.

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
- The vehicle kind's `props` are clamped with the vehicles domain's `cleanProps` rules (`R.vehiclePropsNorm`: colour
  and mod indexes, healths, dirt and fuel in their native ranges; RV4 F1).
- `K.attach` passes `isPed = true` when the anchor is a ped — the retired applier's value (RV6 F10; one in-game probe
  decides the look, README checklist).
- A custom colour cleared with `false` (or already clear) no longer re-creates the car (RV5 F2).

### 55.13 Plugin kinds (`lib/scene/client.lua`)

```lua
-- server (the plugin): Core.Scene.defineKind({ id = 'fireworks:battery', class = 'custom', handler = 'fireworks', … })
-- client (the plugin's own VM):
Core.Scene.handle('fireworks:battery', {
    create = function(node) return entityOrNil end,   -- runs when core decides the node is wanted
    update = function(node, entityOrNil, changed) end,
    destroy = function(node, entityOrNil) end,
    event = function(node, entityOrNil, name, params, age) end,   -- optional
})
```
Core decides *when* (radius, budget, priority, fades via `fade = 'alpha'` on the returned entity, visibility-safe
deletes); the plugin decides *what*. One local event `core:scene:kind (op, kind, id, view)` per state change — never per
frame; the lib calls the handler and reports the returned entity with the proxy call `Scene.bind(id, entity|0)`, so
fades, `handleOf` and children work. A kind whose handler resource is not running stays `KNOWN`. Owner stop removes the
handler registration (Registry kind `sceneHandler`, client).

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- The local event is `core:scene:kind (op, kind, id, view, target)`: `target` = the claiming resource (every other
  VM ignores it); `op` = `create | update | destroy | event`; `view` = a copy `{ id, kind, pos, rot, fields, parent,
  radius, motion, interact, attach, offset, offrot, bone, netId, changed?, changedFields? }` (+ `event = { name,
  params, age }`). DR ticks are not forwarded (the movers place the bound entity).
- **Late binds**: a handler may yield (model streaming); create then answers `C.mat.PENDING`, the node stays STAGED,
  and core waits ≤ 5 s for `Scene.bind` (then `destroy(node, nil)` and the node fails once). `Scene.bind(id,
  entity | 0) -> true | false | false, 'refused'`: `'refused'` for a player ped, a networked entity or one core owns
  (RV2 F8; logged once per kind — the node counts as created without an entity and the plugin keeps its own);
  `false` = core no longer wants it (the lib destroys the entity itself).
- `Scene.claim(kind)`: a second resource is refused while the first runs. A core restart makes every VM claim and
  listen again; a core stop destroys that VM's plugin-kind entities through their handlers. The claim is what makes
  the kind wanted — a kind whose `meta.handler` resource never claims it stays KNOWN.

### 55.14 Interactions on nodes

`interact = { { action = 'use', label = 'Use', distance = 2.0, icon?, description?, perm?, cooldownMs = 500, data? }, … }`
(≤ 4 per node). While a node is LIVE the client adds one `Core.Interactions` entry per descriptor (entity target for
entity kinds, coords otherwise, the world prompt per `Config.Interactions.WorldPrompt`); a press sends
`core:scene:interact (id, action)`. Server: schema → cooldown (250 ms) → loaded → the node exists, is in the player's
bucket and not gated away from them → the descriptor exists → `perm` (`Core.Perms.has`) → distance from the server-known
player position to the node's server-evaluated pose ≤ `distance + 2 m` → `Scene.onInteract` handlers of the id, then of
the kind (pcall, copies). Promotion triggers (§55.15) listen to the same path (`enter`, `use`).

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **Descriptor as built**: `{ action (≤ 32, [%w_-], unique per node), label (≤ 64, default the action), distance
  (0.5..20, 2.0), icon?, description? (≤ 256), perm?, cooldownMs (0..60000, 500), data? (≤ 1 KiB), prompt? = {
  world?, offsetZ? (−5..5 m), range? (1..50 m) } }`, 1..4 per node; an empty list clears.
- **Server order as built**: `Core.Net.on` (schema: id 1..2^31−1, action `^[%w_%-]+$` ≤ 32, data any; 250 ms per
  player; loaded) → the node exists, is no dependency, is in the player's bucket → EVERY audience level of its path
  admits the player (RV1 F2) → the descriptor → `perm` → server distance to the node's pose (a promoted node: its
  clone's) ≤ distance + 2 m → the descriptor's cooldown (expiry stamps, ≤ 64 running per player; a full map
  refuses, never forgets — RV1 F10) → `R.promote.refuses` (a lease, §55.15) → data ≤ 1 KiB (last: the cheap checks
  decide first) → handlers of the id, then of the kind (copies, pcall) → `R.promote.onInteract` (action triggers).
- Client: entries are added while the node is STAGED or LIVE (§55.12 notes); on a promoted node the prompts follow
  the clone.

### 55.15 Promotion, demotion, leases (`server/scene_promote.lua`, `client/scene_promote.lua`) — phase C

- **Policy** (kind default, node override): `authority = { mode = 'local' | 'promote' | 'networked', proximity = m?,
  enter = bool, damage = bool, actions = { 'use', … }, restMs = 3000, idleMs = 20000, onDestroyed = 'remove' | 'keep' }`.
  Defaults: `prop` local; `vehicle` promote with `proximity = 20` (walking players), `enter`, `damage`; `ped` local
  (plugins opt in with `actions`). `networked` = promoted while any player is within `proximity` (platforms that carry
  players, R7 §2.4).
- **Triggers** (server): proximity — once per second, for promotable nodes in near cells that have near-ring
  subscribers, `PlayerGrid.candidates(nodePos, proximity)` + exact distance on foot; `enter` — client report
  `core:scene:report(id, 'enter')` when `GetVehiclePedIsTryingToEnter(ped)` is our local copy (checked at 4 Hz only while
  a local vehicle is within 6 m of the ped), distance ≤ 6 m; `damage` — the client's `gameEventTriggered`
  `CEventNetworkEntityDamage` naming a local copy (event-driven, no polling), distance ≤ 60 m; `actions` — the
  interaction path (§55.14); manual — `Scene.promote(id)`. Reports: cooldown 500 ms, ≤ 4/s per player.
- **Promote** (server): create by class — `CreateVehicleServerSetter(hash, vtype, x, y, z, heading)`,
  `CreatePed(4, hash, x, y, z, heading, true, true)`, `CreateObjectNoOffset(hash, x, y, z, true, true, dynamic)` +
  rotation; one spawn worker, 5 s existence wait (§52 pattern); `SetEntityRoutingBucket`, `SetEntityOrphanMode(e, 2)`,
  state bags `sn = id`, `snv = ver`, `snCfg = { props?, locked?, … }` (the owner client applies cosmetic config, the
  §52 `mapCfg` pattern); `node.promoted = { netId, entity, since }`; op `PROMOTE(id, ver, netId)`. Budgets:
  `Promote.MaxEntities` (1,000 server-wide), ≤ `Promote.MaxPropsPerArea` (32 per 256 m) — beyond that, refused and
  logged. Every server-side entity check uses `ours(e) = DoesEntityExist(e) and Entity(e).state.sn == id` (handles are
  reused, §52 review F1).
- **Hand-off** (client): the local copy stays LIVE until the clone exists (`NetworkDoesEntityExistWithNetworkId` →
  entity whose `sn` equals the id; polled at 10 Hz only while promotions are pending; up to `CloneWaitMs` 10 s — OneSync
  may need ~6 s at 2,000 players). Then: within 5 cm / 2° → delete the local copy in the same frame; otherwise fade the
  local copy out (300 ms) over the clone. An `enter` trigger then tasks the ped into the clone (`TaskEnterVehicle`).
- **Demote** (server, checked at 1 Hz per promoted node): no occupant (`GetPedInVehicleSeat` −1..15), speed <
  `RestSpeed` (0.05 m/s) for `restMs`, no player within `proximity` for `idleMs`, no lease → read pose
  (`GetEntityCoords`, `GetEntityRotation`); vehicles ask the owner client for props (`Callback.awaitClientTimeout`,
  1 s, validated like `saveProps`); snap to the authored pose if within 0.2 m / 2°; `ver + 1`; op `DEMOTE(id, ver,
  pose)`; clients create the local copy hidden (`SetEntityVisible(e, false)`) and reveal it the frame the clone is gone;
  the server deletes the clone `DeleteDelayMs` (500 ms) after the op. A destroyed clone applies `onDestroyed`.
- **Leases**: `Scene.lease(id, src, ms = 10000) -> seq | nil` (first request wins, renewable by the holder, stale
  sequence numbers refused); promoted-node interactions of other players are refused while leased.
- Hooks: server `promoted (id, netId)`, `demoted (id)`; client events `promoted`/`demoted` through `Scene.on`.

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **API as built** (`R.promote`, delegated from server/scene.lua): `promote(id) -> true | nil, err` (owner or core,
  queued; a gated node too), `demote(id) -> true | nil, 'not_promoted'` (forced, whatever the rest conditions),
  `lease(id, src, ms = LeaseMs, seq?) -> seq | nil, err` (the holder renews with its seq; `ms = 0` releases; errors
  `'missing' 'owner' 'src' 'ms' 'leased' 'stale' 'none'`; leased nodes never demote), `beforeChange(node, what) ->
  demoted?`, `refuses(src, node, action)`, `onInteract`, `policy(node)`, `get(id)`, `stats()`, `ours`. Server hooks
  (`Scene.on`) get the node copy: `promoted (copy, netId)`, `demoted (copy)`.
- **Policy defaults as built**: vehicle `{ promote, proximity 20, enter, damage }`; prop and ped `{ local }`; a prop
  with `physics = 'promote'` `{ local, damage }`; `restMs` 3000, `idleMs` 20000, **`onDestroyed = 'keep'`** (it
  demotes at the stored pose; `'remove'` removes the node). `enter`, `damage` and `actions` trigger in every mode;
  proximity needs `'promote'` (players on foot) or `'networked'` (any player). Gated nodes are promoted only manually
  (a clone reaches everyone).
- The proximity sweep runs at 1 Hz in 10 slices over nodes with a proximity policy (near cells with near-ring
  subscribers, PlayerGrid candidates + an exact distance). The server WRAPS `R.index.put` / `remove`: every root
  placement (spawn, load, kind change, re-parent) re-evaluates the policy; removing a promoted root drops its clone.
- Reports: 250 ms per player (≤ 4/s, Core.Net.on) + 500 ms per (player, node, what); `rest` counts only from the
  clone's owner (an early demote check — the server decides); enter ≤ 6 m, damaged ≤ 60 m. A motion node never rests
  (its descriptor is its own authority); the clone's owner drives it per frame.
- **`beforeChange` (the §55.21.1 rule)**: move / motion / drive / attach / detach and a fields `set` DEMOTE a promoted
  node first, synchronously (no props from the owner: the stored props stay); `set` / `motion` start from the clone's
  pose (the 0.2 m / 2° snap applies), the others bring their own pose; a queued promotion is cancelled; any other
  change (interact, audience, radius …) keeps the promotion. `stats().forced` counts them.
- **Client as built** (client/scene_promote.lua): the prop / vehicle / ped handlers are re-registered WRAPPED — a
  promoted root whose clone is here is LIVE without a local entity (the clone stands in: prompts, entity children);
  while a demotion waits for the clone to go, the new local copy is created hidden and revealed the frame it is gone;
  a stand-in whose clone leaves this client falls back to a local copy at the 1 s sweep; clones are polled at 10 Hz
  for CloneWaitMs, then at 1 Hz (a late clone still swaps). `C.promote.cloneOf(id)` / `idOfClone(entity)` feed
  `Scene.handleOf` / `idOf`. Triggers: enter (`GetVehiclePedIsTryingToEnter` at 4 Hz only while a local vehicle copy
  is within 6 m) and damage (`CEventNetworkEntityDamage` naming a local copy), each ≤ once per 2 s per node; the
  damage handler fails safe. The clone's owner applies `snCfg` once per control period (state-bag handler + a
  16-per-second sweep) and answers `core:scene:props` with `Vehicles.getProps` of the clone it controls; clones get
  the node's stable paint (`Scene.paintOf`) unless the props carry colours.
- Open in game: the victim argument of `CEventNetworkEntityDamage` for local entities; fx children of a promoted root.
- **Phase D (run D4+) — one-shot vehicle config**: a vehicle clone's props, lock, dirt and paint are applied ONCE —
  by its first owner, which then reports `core:scene:report(id, 'applied')`; the server checks that the sender owns
  the clone (`ours` + `NetworkGetEntityOwner`) and trims `snCfg` to `{ plate, invincible, frozen, applied = true }`,
  which every later owner applies. So an owner change never resets damage, fuel or a lock that changed since (a keys
  unlock survives). Core vehicle clones (§4.6 parked cars) take `locked` from their own bag, never from `snCfg`; map
  vehicles follow the same one-shot rule.
- **Phase D (run D4+) — the clone's model and type**: the spawn worker resolves the model from an integer (u32 or
  signed), a `'0x%08X'` string (any case) or a name (`R.promote.modelHash`, the signed form `GetHashKey` answers); the
  `CreateVehicleServerSetter` type is the node's `vtype`, else the model info, else automobile; an unusable model is
  refused.
- **Phase D (run D4+) — stop order**: `R.promote.beforeStop(fn)` registers core-internal work that must run when core
  stops BEFORE any clone is deleted (server/vehicles_park.lua hands every parked car's clone pose to its node there);
  explicit, idempotent, never an assumption about handler order.

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
FX1b; where the D4+ bullets above differ, these win.
- **Vehicle config split** (D-A): `snCfg = { props (COSMETIC), plate, paint?, invincible?, frozen?, once = { wear,
  locked, dirt } }`. EVERY new owner re-applies the cosmetic part (idempotent); only `once` is one-shot: the owner that
  applied it sends the new net event `core:scene:applied(id)` — its own event, no cooldown shared with the reports,
  500 ms guard per player + node, the sender must own the clone — the server strips `once`, and the client's 1 s sweep
  re-sends while the live bag still carries it (RV5 F1 / RV6 F1: a lost report no longer lets the next owner reset
  damage, fuel or a lock). `core:scene:report` is `enter` / `damaged` only; the dead `'rest'` path is gone (the 1 Hz
  monitor decides rest).
- **Wear** (D-A, RV4 F1): `Core.Scene.WEAR` / `splitProps` / `mergeWear` (lib/scene/shared.lua, every VM). A props
  read-back from a clone's network owner — the demotion's `core:scene:props`, the park-time `core:vehicles:props` —
  may change only the WEAR keys (engineHealth, bodyHealth, tankHealth 0..1000, dirtLevel 0..15, fuelLevel 0..100, the
  doors / windows / burstTyres / tyreHealth maps), merged over the stored props, for EVERY vehicle node; the plate
  comes from the node. Server wear samples (healths, dirt, burst tyres) count only once `once` was applied plus 1 s of
  sync grace; windows, doors and fuel come only from the owner's read-back.
- **Reserved share** (D-B, RV4 F9): proximity promotions may hold at most `Promote.ProximityShare` (0.7) of
  `MaxEntities`; at the cap an enter / manual / action promotion evicts the oldest proximity promotion that is at
  rest, unleased and empty.
- **Following** (D-C / D-D, RV4 F5 / F6): the 1 Hz monitor samples the clone's pose and bucket, and the node follows
  (`R.store.follow`) past 1 m / 5° or into another bucket, snapping back to its pre-promotion pose within 0.2 m / 2°;
  FXServer's `onEntityBucketChange(entity, bucket, oldBucket)` follows at once; the idle check uses the clone's
  bucket. A lost clone (gone or wrecked) demotes where it was last seen, with its last wear. Core stop: every clone's
  pose followed → the store and Core.DB flushed → the pre-stop hooks → the clones deleted.
- Hook `demoted (copy, info)`, `info = { reason = 'rest'|'manual'|'forced'|'evicted'|'lost'|'destroyed', destroyed,
  pos, rot, bucket, wear? }`.
- `Scene.demote` answers `'occupied'` for a vehicle clone with someone inside; a demotion aborts if someone got in
  during the props wait; someone getting in during the delete window keeps the clone and re-promotes the node with it
  (RV4 F12). `R.promote.adopt(id, entity)` (core-internal) makes an existing networked entity of the node's class its
  clone — how a live car is parked through the hand-off (RV6 F11).
- Client (RV6 F7, F12): a stand-in whose clone left this client shows nothing (phase `lost`); the local copy returns
  only through DEMOTE and a MOVE never re-creates it; the hidden demotion copy's fade-in is ended at once, so it is
  revealed opaque when the clone goes.
- Stats keys `lost`, `evicted`, `rescued`, `adopted`, `follows`, `refused.share`, `proximitySlots`. Accepted residuals:
  under fade-slot pressure a copy can still arrive late with a fade; the clone's owner can repair within the wear
  whitelist; a copy for a clone this client never saw is kept past CloneWaitMs.
- New natives: server `GetEntityRoutingBucket`, `GetVehicleEngineHealth`, `GetVehicleBodyHealth`,
  `GetVehiclePetrolTankHealth`, `GetVehicleDirtLevel`, `IsVehicleTyreBurst`, `GetEntityType`; client
  `ResetEntityAlpha`; the server event `onEntityBucketChange`.

**In-game probe results (Liam, 2026-09-26 22:21 UTC, `scene_probe/data/report_20260926_222136.txt`).**
Probe P7: a vehicle clone exists on the client 89 ms after
the event (148 ms after the server created it); 50 and 80 networked props all resolved, but of 120 only 80 did — a
client holds **≈ 80 networked OBJECT clones** (the CNetObjObject pool), so promoted props must stay rare
(`Promote.MaxPropsPerArea` 32 per 256 m area is inside it). P11: props 2 m above the ground landed on collision
(`HasCollisionLoadedAroundEntity` true after 0 ms near the player): the physics rule stands.

### 55.16 Audio (`server/scene_audio.lua`, `client/scene_audio.lua`, `ui/src/runtime/audio/*`) — phase B

- **Sources** are *dependency nodes* of kind `audio.source`: no pose, no index entry; a source's `PUT`/`SET` is emitted
  into every cell that holds one of its emitters (the index keeps `dependents[sourceId]`), before the emitter; the
  client ref-counts sources by their emitters. Fields: `type` = 'clip' | 'loop' | 'timeline' | 'stream' | 'voice',
  `url` (https) or `file` (`'@<resource>/<path>'`, served from `https://cfx-nui-<resource>/<path>`, must be in that
  resource's `files {}`), `items = { { url|file, duration } … ≤ 200 }` (timeline), `loop`, `t0` (default
  `Clock.at(200)`), `rate` = 1, `paused` + `pausedAt`, `offset`, `volume` 0..2, `category` = 'music' | 'sfx' | 'ambience'
  | 'voice', `title`; resolved stream info `{ url, codec, kind = 'mp3'|'ogg'|'hls' }` is filled by the server.
- **Emitters** are nodes of kind `audio` (tier by `range`): `source`* (an `audio.source` id), `range` 1..600 = 40,
  `volume` 0..2 = 1, `curve` = 'game' (GTA's table: 0 dB ≤ 5 m, −14 at 10, −31 at 20, −49 at 40, −62 at 64, −76 at 100,
  silent at `range`, R3 §8) | 'inverse' | 'linear', `ref` = 2 m, `cone` = { inner, outer, outerGain }, `priority` 1..5
  = 3, `occlusion` = true, `zone` (a `Core.Geometry` shape: inside → constant loudness, "fills the room"), attach or
  parent for moving emitters.
- **Server policy**: `url` must be https and its host must match `scene.audio.allowHosts` (a `Core.Settings` list the
  admins edit; empty = only `file` sources); playlists (m3u/pls/xspf) are resolved by the server through `Core.Http`
  (first entry, https, same host rules); the content type decides the codec — MP3, Ogg/Opus/Vorbis/FLAC and HLS (m3u8)
  pass, and AAC/M4A too: probe P8 (2026-09-26) showed FiveM's CEF plays AAC, so `Config.Scene.Audio.AllowAac = true` is
  the shipped default (false refuses AAC / M4A and AAC-only HLS masters again); synced content must
  be CBR MP3 or Opus/Vorbis (VBR MP3 seeks up to 0.6 s wrong, R6 §4). Titles of active streams are polled server-side
  (Icecast `status-json.xsl`, 20 s, only while the source has dependents in subscribed cells). `Scene.audio.kill(id|'all')`
  stops sources; plays created on behalf of a player (`by = src`) are rate-limited (1 per 5 s) and audited.
- **Client Lua** (`client/scene_audio.lua`): the materialiser handler of class `audio` (no entity, `fade = 'self'`)
  forwards sources and emitters to the shell (`audio:source`, `audio:emitter`, `audio:remove` messages, only on change);
  the **listener feed** (camera position, forward, up, velocity, `Clock.now()`, moving emitters' positions) is one
  pre-encoded `SendNuiMessage` string at 0–20 Hz — only while ≥ 1 emitter is materialised, only when the camera moved
  ≥ 0.25 m or turned ≥ 2°; **occlusion** = rules (listener vs emitter interior/room, in a closed vehicle, underwater) +
  ≤ 8 async LOS probes per second (`StartShapeTestLosProbe`, results polled, never the synchronous probe) for the
  nearest audible emitters; **volume** = `GetProfileSetting(Audio.ProfileSfx 300 | ProfileMusic 306) / 10` × the
  player's prefs (client KVP `core:audio:prefs`, `/audio` command); duck to 0 over 200 ms on the pause menu and §31 hide.
- **Shell engine** (`ui/src/runtime/audio/`: `index.ts` install + messages, `engine.ts` context/buses/arbiter,
  `sources.ts` decoders, `spatial.ts` per-voice graph, `sync.ts` clock + drift, `icy.ts` ICY/MSE MP3 streamer; hls.js
  loaded lazily as its own chunk): one `AudioContext` (`latencyHint: 'playback'`), buses music/sfx/ambience/voice →
  master → limiter; per voice `fan-out → Biquad (occlusion + air) → Gain (curve × occlusion × fade × volume) → Panner
  (equal-power; HRTF for ≤ 8 nearest when the player enables it) → bus (+ reverb send)`, every panner and listener param
  `automationRate = 'k-rate'` driven by `linearRampToValueAtTime` over the feed interval (15× cheaper, R6 §1.2),
  `rolloffFactor = 0`; two procedural reverb impulse responses (small room / large space) crossfaded by environment.
  Budgets: `Audio.Voices` 32 real (priority = audibility × priority class, +3 dB / 1 s hysteresis), the rest virtual with
  a clock-derived play head; `Audio.Decoders` 4 concurrent streams/timelines; `Audio.ClipCacheMb` 64 decoded clips (LRU);
  one decoder per source fanned out to every emitter. **Sync**: play head = `(netNow − t0) × rate + offset`, the page's
  `netNow` from the feed with a max-filter over 10 s; drift: dead band 25 ms, `playbackRate` 1 ± ≤ 0.02 below 750 ms,
  re-seek behind a 100 ms fade above; muted until the first lock. Gains ramp ≥ 5 ms (cuts), 30–100 ms (music edges),
  300–500 ms (LOD/steal); `stop()` after the ramp. Streams: MP3 Icecast via fetch + ICY demux + MSE (`audio/mpeg`), Ogg
  via `<audio>`, HLS via hls.js; `crossOrigin = 'anonymous'` on every media element; reconnect with backoff 1–30 s.
- Diagnostics: `/audiodebug` (voices real/virtual, decoders, per-timeline drift, clock offset).

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **Server policy as built** (`R.audio.check(fields)`, the `audio.source` post-check of every spawn / set): https
  only; the host must match `scene.audio.allowHosts` (`host`, `*.domain` = its subdomains, `*` = any); `file =
  '@<started resource>/<path>'` inside that resource's `files {}`; codec by extension — MP3, Ogg / Opus / Vorbis,
  FLAC, WebM pass, WAV for clips / loops / timelines, AAC / M4A while `AllowAac` (true since probe P8); playlists (m3u,
  m3u8, pls, xspf) only for `stream`, recognised by their content; an HLS master with only AAC variants is refused only
  with `AllowAac = false`; timeline
  items need a duration. It never blocks: `resolved = { url, codec, kind }` at once, or `{ pending = true }` answered
  later through `Scene.set` as core, or `{ error = code }`. The allow-list is checked when a source is created or
  changed, not again when the list changes (playing sources keep playing).
- **The server never fetches a stream body** (PerformHttpRequest would buffer a live stream for ever): a URL without
  a telling extension takes its codec from the origin's Icecast `status-json.xsl`, else MP3 is assumed; playlists are
  fetched (≤ 64 KiB, ≤ 2 requests at a time, answers cached: unused 10 min, failures 1 min). Titles: every 20 s, only
  for stream sources with an emitter in a subscribed cell, one status-json per origin (backed off 5 min after a
  failure).
- **`resolved.trusted`** (server-owned): false for remote URLs and for anything played on a player's behalf (kept
  while that content plays), true for resource files chosen by server code. The page decodes only trusted sources
  into PCM; untrusted clips / loops play through media elements (RV3 F9, the "decode bomb").
- **API as built**: `Scene.audio.play(def) -> id | nil, err, detail` (a spawn def of an `audio.source`, kind implied,
  or `{ id = sourceId, fields = patch }` to retarget; `by = src` = on that player's behalf: 1 play per 5 s per
  player, audited `scene.audio.play`; errors `'def' 'by' 'rate_limit' 'missing'` plus the spawn / set errors);
  `Scene.audio.kill(id | 'all', by?) -> true, n | false, 'missing'` (sources with their emitters, or emitters,
  whatever their owner; audited `scene.audio.kill`); `Scene.audio.stats()`. **Admission**: `R.audio.admit(def,
  owner) -> true | false, code`, called by Scene.spawn directly (not a hook) — `scene.audio.enabled` →
  `'audio_disabled'`, `scene.audio.maxStreams` stream sources server-wide → `'audio_streams'`, a flood guard per
  owning resource (a bucket of 120 spawns, 20 per second back; core exempt) → `'audio_rate'`.
- Settings section `scene` (group Audio): `scene.audio.enabled` (true, replicated: off = the clients drop all page
  audio, the nodes stay), `scene.audio.allowHosts` (≤ 64 patterns, replicated: sent as `hosts` with every
  `audio:source`, so redirects and HLS variants / segments / keys stay inside it), `scene.audio.maxStreams` (8, 0..64).
- **Client Lua as built** (client/scene_audio.lua): the `'audio'` handler (class audio, budget `'audio'` → Caps.audio
  or Caps.custom, radii range / +20 / +40); messages encoded with a fixed key order, sent only when their text
  changed; sources still resolving, failed ones and `'voice'` sources are not sent, nor their emitters. The feed
  goes out right after the first emitter reached the page, then on change (camera ≥ 0.25 m / ≥ 2°, a moving emitter
  ≥ 0.1 m, an occlusion value ≥ 0.02, environment, volumes, pause) and at least once a second (the page's clock
  mapping needs `t`), only while an emitter is materialised; map keys are `'n<id>'` (AGENTS §8). Occlusion is
  additive — another room .45, inside ↔ outside .85, line of sight .55 × the blocked fraction, a closed vehicle +.35,
  under water +.8, capped at 1 — with LOS probes from an 8-per-second token bucket, round-robin over the nearest
  audible outdoor emitters, smoothed (α 0.5). `/audio volume|hrtf|streams|offset|voices|debug|stats`,
  `/audiodebug`; a reloaded shell (hook `uiReady`) gets everything again. `C.audio.positionOf / occlusionOf /
  listener` serve client/scene_voice.lua.
- **Shell as built** (`ui/src/runtime/audio/`): `index.ts` (`installAudio()` subscribes the `audio:*` actions; the
  engine is its own chunk, `scene-audio.ts` → `html/assets/scene-audio.js`, imported on the first message; no
  AudioContext before the first source or emitter), `engine.ts` (context, buses → master → duck → limiter; suspended
  after 15 s with nothing in it; errors rate-limited), `mixer.ts` (the mixing pass), `arbiter.ts` (virtual → real
  voices: score = dB audibility + 6 dB × (priority − 3), floor −60 dB (−57 to enter), ≤ 4 real voices per source,
  +3 dB / 1 s incumbency; decoders +3 dB / 3 s), `spatial.ts` (the per-voice graph, k-rate panners, reverb),
  `curves.ts`, `sources.ts` (one decoder per source), `loader.ts` (a clip is decoded only when its DECODED size is
  bounded first), `cache.ts` (the clip LRU with pins), `deck.ts` + `media.ts` (media elements on the clock, drift
  control, retries with backoff), `streams.ts` + `icy.ts` (Icecast MP3 through fetch + ICY + MSE with paced reads and
  a stall watchdog; HLS through `hls.js/light`, a lazy chunk `html/assets/hls.light.js`; the rest through
  `<audio>`), `net.ts` (bounded fetches; the host rule applied to the FINAL URL after redirects), `sync.ts` (clock +
  drift; the lock = |e| ≤ 75 ms on 2 polls, fail-open after 4 s), `validate.ts`, `debug.ts`, `types.ts`. Dependency
  `hls.js` ^1.7.3 in ui/package.json.
- Wire additions to INTERFACES §6: `audio:source` + `hosts?`, `trusted?`; `audio:emitter` + `rx?, ry?, rz?` (a cone
  faces its node's rotation, RV3 F11); feed `moving` entries may carry `rx` / `rz`. NUI → Lua: page `audio`, events
  `error { id, code }` and `stats` through the `ui_event` bridge (`Core.UI.on('audio', …)`).

**In-game probe results (Liam, 2026-09-26 22:21 UTC, `scene_probe/data/report_20260926_222136.txt`).**
Probe P8: `http://` fails in the CEF (mixed content) —
https-only confirmed; **AAC IS SUPPORTED** (`audio/aac` and `audio/mp4; codecs="mp4a.40.2"` answer canPlay `probably`
with MSE, `AudioDecoder` takes mp4a.40.2; Opus, FLAC and WebM too; Ogg / FLAC / WAV without MSE) →
`Config.Scene.Audio.AllowAac = true` is the shipped default (the refusal path stays tested with the gate off:
scene_audio 241). The research's "no AAC in FiveM's CEF" is superseded. The https live-stream row was inconclusive
(the test stream answered 403 text/html) — re-run with another stream. P9: `outputLatency` 40 ms, audio clock −
wall clock 2.6 ms, `setInterval(200)` lateness p95 0.7 ms.

### 55.17 Voice through world speakers (`server/scene_voice.lua`, `client/scene_voice.lua`) — phase B

- `Scene.voice.start({ talker = src, speakers = { nodeIds }, fx = 'megaphone'|'pa'|'phone'|'radio'|'none', range = 60 })
  -> sessionId | nil, err`, `Scene.voice.stop(sessionId)`, `Scene.voice.list()`; trusted server API (plugins authorise);
  ≤ `Voice.MaxSessions` (16) server-wide, ≤ 1 per talker; audited; owner-tracked (`sceneVoice`).
- Server, every 500 ms per session: listeners = loaded players in the speakers' bucket within `range + 20 m` of any
  speaker (player grid), ≤ `Voice.MaxListeners` (64), minus the talker; the talker's client gets the add/remove list
  (`core:scene:voice:targets`), each listener `core:scene:voice:listen / unlisten (sessionId, talker, speakers, fx,
  range)`.
- Talker client: a **voice adapter** adds the listeners to the voice target of the running voice resource
  (`Scene.voice.setAdapter({ add = fn(list), remove = fn(list) })`; built-in adapter for pma-voice: its voice target
  (1) with `MumbleAddVoiceTargetPlayerByServerId` / `MumbleRemoveVoiceTargetPlayerByServerId`, re-applied after the
  resource rebuilds its targets). Without a voice resource the feature reports `'no_voice'`.
- Listener client: a fixed pool of `Voice.Submixes` (8) created once at core start (`CreateAudioSubmix('core_vs_<n>')`,
  then `AddAudioSubmixOutput(id, 0)` BEFORE any `SetAudioSubmixOutputVolumes` — pma-voice has the order backwards,
  R2 §B8), RadioFX parameters per `fx` preset (megaphone band 400–3,500 Hz + drive; phone 300–3,400 Hz; pa light
  band-pass; radio = the default preset). Per session, ONCE: `MumbleSetVolumeOverrideByServerId(talker, 1.0)` +
  `MumbleSetSubmixForServerId(talker, submix)`; then only `SetAudioSubmixOutputVolumes(submix, 0, fl, fr, rl, rr, c, 0)`
  at `Voice.PanHz` (15 Hz, a loop that exists only while a session is heard) with equal-power gains × the emitter curve
  summed over the speakers + the audio occlusion; end: override −1, submix −1. Never animate the override or flip the
  submix (the voice is rebuilt and drops out, R2 §B7). No free submix → volume-only fallback (no panning).
- Needs `setr voice_useNativeAudio true` (README). City-wide announcements are recorded clips (§55.16), not live voice.

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- **API as built** (`R.voice`, delegated from `Scene.voice.*`): `start({ talker = src, speakers = { nodeIds }, fx =
  'none', range = 60, onEnd? }) -> sessionId | nil, err` (range 1..600 m; 1..32 distinct speaker nodes of ONE
  bucket; `onEnd(sessionId, reason)` is called once for an end the owner did not ask for); `stop(sessionId) -> true |
  false, err` (the session's owner or core); `list()` (`{ id, owner, talker, speakers, fx, range, bucket, listeners,
  startedAt }`); `stats()` (`{ sessions, listeners }`). Errors: `'def' 'talker'` (not loaded) `'fx' 'range'
  'speakers' 'missing'` (no such node, or a dependency node) `'bucket' 'busy'` (≤ 1 per talker) `'limit'`
  (MaxSessions) `'owner'`. End reasons: `'stopped' 'owner' 'talker' 'dropped' 'speakers'` (every speaker removed)
  `'no_voice'`. Audit rows `scene.voice.start` / `scene.voice.stop`.
- Listeners (every 500 ms, one thread only while a session exists): hysteresis — join within range + 20 m, leave
  beyond range + 30 m; loaded players in the speakers' bucket, allowed by a gated speaker's audience, minus the
  talker, the nearest MaxListeners; candidates from Core.PlayerGrid (no natives), the bucket read only for players
  inside the distance; events through `Core.Net.emitMany`; `listen` is sent again when a speaker moved ≥ 1 m or went
  away (speaker positions in cm). `start()` runs the first selection at once, so the talker's client can answer
  `core:scene:voice:report (sessionId, 'no_voice')` when `MumbleIsConnected()` is false — that ends the session.
- **Deviation — the adapter is internal** (`C.voice.setAdapter`), not on `Scene.voice`: `'pma-voice'` when it runs
  (voice target 1, its `voiceTarget`; the listeners are added again right after its local `pma-voice:radioActive`
  (false) event and every second, because its radio / call / reconnect paths clear the target's players), else
  `'raw'` (`MumbleAddVoiceTargetPlayerByServerId` on `Config.Scene.Voice.Target`, default 1, re-applied every second);
  the re-apply loop exists only while a listener is held.
- **Listener side as built**: the submix pool is created once at start and cached by name (a core restart gets the
  same ids; there is no destroy native); RadioFX sits in effect slot 0, disabled until a session wants a preset; per
  heard session ONCE `MumbleSetVolumeOverrideByServerId(talker, 1.0)` + `MumbleSetSubmixForServerId(talker, submix)`,
  then only output volumes at PanHz, and only when a gain moved > 0.002. Gains per speaker: the camera-relative
  direction (read once per pan tick) → equal-power L/R × equal-power front / rear, × the §55.16 `'game'` curve, ×
  the node's occlusion (`C.audio.occlusionOf`, 0 … −15 dB); energies power-summed per channel, each ≤ 1. A moving
  speaker materialised here is read from its entity, every other one from the server's pose. pma-voice resets a
  talker's override / submix when he stops talking on its radio or leaves a radio / call: every heard session is
  routed again 300 ms after those events (the same values — a no-op where nothing was reset), except a talker on
  its radio right now. No free submix, or no `voice_useNativeAudio` (a submix routes voice only with it) → volume
  only: the override set ONCE to the summed gain of that moment (0.1..1), no panning.
- Open: the talker's own ped as an extra point for nearby listeners; a pma-voice call-routing override; the RadioFX
  presets by ear (probe P10).

**In-game probe results (Liam, 2026-09-26 22:21 UTC, `scene_probe/data/report_20260926_222136.txt`).**
Probe P10: 12 free submix ids (28..39) — the
`Voice.Submixes = 8` pool fits.

### 55.18 Persistence

`persist = true` nodes are stored in collection `scene_nodes`, one document per node, id `n<id>` (Core.DB id rules):
`{ id, kind, owner, bucket, pos, rot, parent, offset, offrot, bone, attach? (node targets only), motion (t0 stored as a
phase, re-anchored at load), fields, audience (serialisable forms only — `fn` audiences are not persistable), radius,
global, interact, authority }`; the id counter lives in `scene_meta:counter`. Writes are coalesced per node (≤ 1 per
second), loaded at start behind one barrier before `Core.onReady` listeners run; undefined kinds stay placeholders.
`MaxPersistent` 50,000. `/dbexport` covers the collection like any other.

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
- A motion is stored REBASED (`Motion.rebase` at the write: periodic phases folded in, a finished plan an ended tween)
  without its t0, the time phase in `mphase`; Clock-valued fields (`kind.clock`: `anim.t0`, a source's `t0` /
  `pausedAt`) are stored as phases in `clk`; both are re-anchored at load. Player / net attachments and `dr` motions
  are transient. A persistent node needs a persistent parent (and a persistent emitter a persistent source).
- Writes: one thread, only while something is dirty, ≤ 1 write per node per second, a final write on core stop.
- The barrier is a promise every API call passes: the first caller loads, callers meanwhile wait on it, one that
  cannot wait (or a failed load) gets `'unavailable'`; a failed load is retried at most every 10 s and leaves no half
  state. A stored audience that cannot be restored loads as `{ editors = true }` (logged).

### 55.19 Security table (all through `Core.Net.on` / `Core.Callback.register`, AGENTS §3 order)

| entry | schema | cooldown / rate | extra checks |
|---|---|---|---|
| `core:scene:focus` | 6 numbers finite, seq integer, `held` ≤ 48 integer pairs | 250 ms | bucket from the server; clamped to server-known positions + slack (§55.6) |
| `core:scene:resync` | grid 0..2, key u32, variant 1..3, v u32 | 100 ms, ≤ 16/s | only subscribed cells; answers ride the normal budget |
| `core:scene:interact` | id integer, action ≤ 32 chars, data ≤ 1 KiB | 250 ms | node exists, bucket, audience, descriptor, `perm`, server-side distance |
| `core:scene:report` | id integer, what ∈ {enter, damaged, rest}, data ≤ 256 B | 500 ms, ≤ 4/s | node promotable, distance (enter 6 m, damage 60 m), policy allows |
| `core:scene:props` (callback, server → owner) | CoreVehicleProps | 1 s timeout | validated like `saveProps`, only from the clone's owner |

Server-only APIs never have a client entry point. Every client-visible node is public in its bucket unless gated; the
subscription window cannot be moved far from the server-known position; per-player byte budgets and per-subscription
version memory bound amplification; audio URLs are server-resolved, https, allow-listed; clients never contact a host
a player supplied.

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).** As built (every
row through `Core.Net.on`: schema → cooldown → loaded, then the handler's checks):

| entry | schema | cooldown / rate | extra checks |
|---|---|---|---|
| `core:scene:focus` | 6 numbers, seq integer 0..u32, `held` table ≤ 48 entries (optional) | 250 ms | as above; a report whose bucket differs resets the window (§55.6 notes) |
| `core:scene:resync` | grid 0..2, key u32, variant 1..3, v u32 | 62 ms per player (≈ 16/s); one answer per cell per 2 s | subscribed cell in its current variant; journal or pack, budgeted |
| `core:scene:interact` | id 1..2^31−1, action `^[%w_%-]+$` ≤ 32, data any (≤ 1 KiB, checked last) | 250 ms + the descriptor's `cooldownMs` (≤ 64 running) | every audience level of the path, a lease (§55.14 notes) |
| `core:scene:report` | id 1..2^31−1, what `^%a+$` ≤ 8 ∈ {enter, damaged, rest, applied}, data ≤ 256 B | 250 ms per player (≤ 4/s) + 500 ms per (player, node, what) | bucket, audience, distance, policy; `rest` and `applied` (phase D, §55.15 notes) only from the clone's owner |
| `core:scene:voice:report` | sessionId 1..2^31−1, `'no_voice'` | 1000 ms | the session exists and the sender is its talker → it ends |
| `core:scene:props` (callback, server → owner) | CoreVehicleProps | 1 s timeout | validated by the vehicle kind like `saveProps` |
| `core:server:parkedLock` (phase D, §4.6 notes) | node id 1..2^31−1 | 500 ms, loaded | distance from the server's ped to the node (or its clone) ≤ `Vehicles.LockDistance`; the node parks a record in the player's bucket; the record's virtual keys; item-key cars ignored |
| `core:vehicles:props` (callback, server → the owning client, phase D) | netId | 1 s timeout (`awaitClientTimeout`) | answered only for a `coreVeh` entity the client controls; the answer is validated like `saveProps` before parking |

The audio page's NUI → Lua events (`audio` / `error`, `stats`) ride the `ui_event` bridge and change nothing on the
server.

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
These rows supersede the `core:scene:report` row above:

| entry | schema | cooldown / rate | extra checks |
|---|---|---|---|
| `core:scene:report` | id 1..2^31−1, what ∈ {enter, damaged}, data ≤ 256 B | 250 ms per player (≤ 4/s) + 500 ms per (player, node, what) | bucket, audience, distance (enter 6 m, damaged 60 m), policy |
| `core:scene:applied` | id 1..2^31−1 | 500 ms per (player, node); no cooldown shared with the reports | a live vehicle promotion not applied yet; `ours(clone)`; the sender owns the clone → `once` stripped from `snCfg` |

### 55.20 Config (`Config.Scene`) and settings

```lua
Scene = {
    CellSize = 128, RegionSize = 512,                        -- read once (key encoding)
    NearRing = 160, FarRing = 448, FarRegions = 1024, LeaveMargin = 64, LeaveDwellMs = 3000,
    TierS = 160, TierM = 448, TierL = 1500,
    FlushMs = 50, MaxEventBytes = 16384, MaxBacklogBytes = 262144, LatentBps = 750000,
    PackBudgetBytes = 2000000, PackBudgetWindowMs = 10000, JournalOps = 64, JournalMs = 10000,
    Focus = { MinMove = 16, MinIntervalMs = 250, Slack = 50, MaxSpeed = 90 }, BackstopMs = 5000,
    Lead = { Seconds = 1.5, Max = 150 },
    ClientLruCells = 48, ClientLruMs = 120000, ModelLingerMs = 30000,
    Caps = { props = 3000, peds = 48, vehicles = 32, lights = 32, particles = 32, markers = 64, texts = 64, sounds = 24,
             hides = 200, custom = 64, modelsProps = 150, modelsPeds = 20, modelsVehicles = 20 },
    Budgets = { PropsPerFrame = 8, EntityPerFrame = 1, CustomPerFrame = 2, DeletesPerFrame = 32,
                ModelRequestsPerFrame = 2, ModelsInFlight = 30, TeleportMultiplier = 10 },
    Radii = { Band = 20, SmallBand = 5, Margin = 10, Warm = 50, OutMin = 20, OutFactor = 0.25, PropCap = 500 },
    Fades = { PropInMs = 300, PropOutMs = 450, PedMs = 600, VehicleMs = 400, Max = 48, MaxVehicles = 8 },
    Visibility = { UnseenMs = 1500, ImportantUnseenMs = 4000, DeferMaxMs = 10000, SwapMargin = 10, SwapCooldownMs = 100 },
    Speed = { SkipSmallAbove = 50, NoFadeAbove = 80 },
    Motion = { NearRadius = 50, MidHz = 15, ServerHz = 2, RecellTolerance = 8, PlanLeadMs = 200 },
    DeadReckoning = { Near = 0.25, Far = 1.0, Degrees = 3, NearHz = 10, FarHz = 1, HeartbeatMs = 5000, Snap = 5 },
    Promote = { MaxEntities = 1000, MaxPropsPerArea = 32, CloneWaitMs = 10000, DeleteDelayMs = 500, RestSpeed = 0.05,
                LeaseMs = 10000, SwapDist = 0.05, SwapDeg = 2 },
    Audio = { Voices = 32, Decoders = 4, ClipCacheMb = 64, HrtfVoices = 8, ListenerHz = 20, LosProbesPerSecond = 8,
              ProfileSfx = 300, ProfileMusic = 306, AllowAac = true },   -- true since probe P8 (2026-09-26)
    Voice = { Submixes = 8, PanHz = 15, MaxListeners = 64, MaxSessions = 16 },
    Global = { MaxNodes = 256 }, MaxNodes = 100000, MaxNodesPerOwner = 20000, MaxPersistent = 50000,
    MaxFieldBytes = 8192, ClockMode = 'network', Debug = false,
}
```
Settings (`Core.Settings`, server): `scene.audio.enabled` (true), `scene.audio.allowHosts` (list of host patterns),
`scene.audio.maxStreams` (8 server-wide stream sources). server.cfg (README): `increase_pool_size "Object" 2000`,
`setr voice_useNativeAudio true` when voice speakers are used.

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1 and review rounds RV1–RV3).**
`shared/config.lua` has the block above plus `Global.MaxPerOwner = 64` (global nodes per plugin), `MaxChildren = 64`
(descendants per root) and `ObjectPool = 5300` (shipped 2026-09-27 to match the dev server.cfg raise; nil = learn it, 3,300 assumed;
§55.11 notes). Keys the code reads with a default although the config does not list them: `Caps.audio` (falls back
to `Caps.custom`, 64) and `Voice.Target` (1: the raw voice adapter's target). `ClockMode` is not read yet. Most keys
are read ONCE when core starts (clamped), so a change needs `restart core`. The settings section is `scene` (group
Audio; §55.16 notes): `scene.audio.enabled` and `scene.audio.allowHosts` replicate to clients,
`scene.audio.maxStreams` is 0..64.
Phase D added `OwnerCaps = { core = 60000 }` (per-owner overrides of `MaxNodesPerOwner`: map elements, player
attachments and parked cars all count as core), trimmed `Config.Maps` to `{ MaxMarkers = 64 }` (the editor view's
preview budget) and added `Config.Vehicles.AutoPark = true`, `AutoParkIdleMs = 30000`, `AutoParkRadius = 50`,
`AutoParkSweepMs = 10000` (§4.6 notes).

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
`Promote.ProximityShare = 0.7`, `CoreReserve = { nodes =
20000, persistent = 10000 }`, `OwnerCaps = { core = 60000, inventory = 40000 }`, `Caps.vehicles` 32 → 64 and
`Caps.modelsVehicles` 20 → 32 (parked-car density, RV4 F10; the probe measures dense lots), and
`Config.Vehicles.MaxParked = 20000`.

### 55.21 Migrations onto Core.Scene — phase D (addenda binding for the migration runs)

Liam (2026-09-27): "You can replace / remove Core.Maps if it's cleaner." Everything below keeps the PUBLIC surface
the admin editor and plugins use where that is cheap, and removes the old machinery.

#### 55.21.1 Core.Maps becomes an authoring layer on Core.Scene (supersedes §52.3, §52.4, §52.4a, §55.22)

- **What stays**: element types (`Maps.defineType`, §52.1), documents, draft/live modes, `Maps.apply` / `invert` /
  `publish` / `rollback` / `openDraft` / `closeDraft` / `clear` / `journal` / `versions`, editor buckets, expiry, the
  model validator, `Maps.on` / `Maps.records` (active-content events), audits and limits (§52.2). server/maps_types.lua,
  server/maps.lua, server/maps_apply.lua keep their API.
- **What goes**: server/maps_regions.lua (MapRegions, the `core:maps:window` callback, `core:maps:pack|delta|stale`),
  the networked-entity worker, `mapCfg`, `core:maps:pose` and the in-place pose checks in server/maps_runtime.lua,
  client/maps_spawn.lua and client/maps_view.lua, and their suites' sections. `MapRegions` / region settings leave
  config and api.lua.
- **server/maps_runtime.lua = a projector.** Each active context (map, bucket) projects each element onto ONE scene
  node, owner core, `persist = false` (maps persist their own documents; nodes are rebuilt at start), bucket = the
  context's bucket, `fields.mapEl = '<mapId>:<elementId>'`, `fields.mapType = typeId`. Kind mapping:
  | element kind | scene node |
  |---|---|
  | prop | `prop` { model, frozen, collision, invincible (= unbreakable), lod (info.lod) }; a networked prop type (`core:physprop`) gets `physics = 'promote'` |
  | vehicle | `vehicle` { model, plate, locked, props (color → custom colours), frozen = true } with the class default authority (promote on proximity/enter/damage) |
  | ped | `ped` { model, scenario, invincible, frozen, blockEvents }, authority local |
  | marker | `marker` { type, scale, color, bob, face, drawDistance } |
  | hide | `hide` { model, radius } |
  | point, zone, placeholder, editor helper | `map:data` (core-internal kind, class `data`) { t = type id, k = element kind, size?, f? = preview label fields }, `audience = { editors = true }` |
  `show` = spawn or `Scene.set`/`move` (same node id kept per (bucket, uid)); `hide` = `Scene.remove`; a context
  swap (publish/rollback) diffs by (uid, updatedAt) as today. `Maps.respawn(mapId, elementId?)` re-spawns the element's
  node (a promoted clone is demoted first). The `networked` / `networkedTotal` limits keep bounding vehicle and ped
  elements (they are local copies now; the client caps still apply).
- **Moving a promoted node** (an editor drags a map vehicle somebody walked up to): `Scene.move` / `Scene.set` on a
  promoted node demotes it at the NEW pose first (R.promote handles it; no clone is ever moved by the server).
- **client/maps.lua = a facade** (≤ ~250 lines) keeping the §52.4 client API for the admin editor: `handleOf(uid)`,
  `uidOf(entity)` (a local copy OR a promoted clone → node → `fields.mapEl`), `hold(uid)` / `release(uid)` (→
  `Scene.hold` / `release`, owner-tracked `mapHold` as today), `setEditorView(on)` (owner-tracked; turns the
  `map:data` previews on), `isAreaReady` / `waitAreaReady` (→ Scene), `stats()` (→ a Scene subset). The uid ↔ node map
  is kept from Scene `live`/`gone` of nodes that carry `fields.mapEl`.
- **client/maps_preview.lua** (new, loads after client/scene_movers.lua): the `map:data` handler — draws the type's
  `preview` descriptors (marker, sphere, box lines, label) only while the editor view is on, per-frame only while
  something is in range (the §52 editor view budgets); the type list comes from `core:maps:types` as today.
- **Admin editor (resources/admin)**: selection keeps `Core.Maps.uidOf`; the `mapEl` state-bag path and the drag
  ghosts for networked types are removed (every element is a local copy the editor moves while it holds it); anything
  that listened to `core:maps:pose` goes. The admin suites follow.
- Tests: maps_tests.lua (projector against a recording fake Scene: every kind mapping, contexts, swaps, respawn,
  limits), maps_store_tests.lua (unchanged), maps_regions_tests.lua deleted, client_maps_tests.lua rewritten (facade +
  preview handler), admin suites updated.

**Implementation notes (2026-09-27, phase D runs D1s, D1c, D1a and the orchestrator's follow-up).**
- **Server (D1s)** — server/maps_runtime.lua is the projector (`server/maps_regions.lua` and its suite are deleted,
  `MapRegions` left the export block-list). Deviations from the table above: a prop's `lod` is not passed — the
  scene's model-info chain fills it (§55.12); `map:data` is defined as core at core's `onResourceStart` (again on the
  first spawn if that failed), `k` ∈ `point` | `zone` | `placeholder`, fields `t`, `k`, `size`, `f` (≤ 16 label
  values), `mapEl`, `mapType`, radius 150 m; types without `invincible` / `frozen` / `blockEvents` fields give peds
  `true` (the old default was false). **Paint** (orchestrator follow-up): every map vehicle's props carry the paint of
  its UID, `Scene.PAINTS[R.joaat(uid) % #PAINTS + 1]` (the pre-migration formula, the same list as
  lib/scene/shared.lua; pinned: `m1:1` → 50, `m1:2` → 3, `m7:42` → 89, `m12:3` → 70, `event_arena:999` → 4) — the
  same across node re-creations, restarts and buckets; a set `color` is custom RGB on top (with the uid paint
  underneath), no `color` clears the custom colours explicitly.
- Every Scene call runs AS CORE (`Registry.withCaller('core', …)`), whoever called Core.Maps; refusals are logged at
  most once a minute per kind of failure. Nothing is projected before the scene store is loaded: one waiter thread
  (bounded waits, only while something waits) projects every context then. A change keeps the node id per (bucket,
  uid) — `Scene.move` for the pose, `Scene.set` for the changed fields (a promoted node is demoted by Scene first);
  another scene kind is remove + spawn (a new node id); closing a context removes its nodes one by one. A refused
  spawn is logged and stays missing until the element changes or `Maps.respawn`, which puts nodes back to their
  authored state (a missing node is spawned, a promoted, displaced or changed one is moved / reset) and returns how
  many it touched. `R.stats()` → `{ contexts, networked, nodes, waiting, listeners }`.
- Core owns every map node, so `Config.Scene.OwnerCaps.core = 60000` lifts core above `MaxNodesPerOwner`. Models
  stay validated at authoring time (maps_apply's `checkModelOf` on create, update and rollback); the scene itself no
  longer refuses a model the Maps validator does not know (§55.12 notes).
- **Client (D1c)** — client/maps.lua (263 lines) is the facade, client/maps_preview.lua (446) the editor view;
  client/maps_spawn.lua and client/maps_view.lua are deleted. The uid index is fed by WRAPPING `C.mat.add / update /
  remove` (the one seam every wanted node passes), not by `Scene.on` live / gone; holds go to `C.mat.hold / release`
  under the owner key `'maps:<resource>'` (a resource's Scene holds and Maps holds never release each other; a hold
  taken before the node arrives applies when it comes); uids are STRINGS (≤ 128); `handleOf(uid)` answers the local
  copy, else the promoted clone, else a copy a holder keeps; readiness is `cache.areaReady` + `mat.areaReady`, and
  `waitAreaReady` asks the focus reporter for a report but moves no window. `Maps.stats()` → `{ elements, spawned,
  held, queued, models, failed, previews, dataNodes, types, editorView }` (no objects / hides any more).
- **Previews** (client/maps_preview.lua, the `map:data` handler, class data, `fade = 'self'`): records within 160 m
  (let go past 190 m); drawn only while the editor view is on and a record is within 150 m, ≤ `Config.Maps.MaxMarkers`
  nearest first, ≤ 10 labels per frame, previews behind the camera skipped. The type list comes from
  `core:maps:types` when the view turns on (again once it is older than 60 s) and once for each unknown type id,
  attempts ≥ 1.5 s apart, 3 per fetch; `$size` and `#RRGGBBAA` colours work (the old view drew `core:zone` as a 1 m
  box).
- `Config.Maps` is `{ MaxMarkers = 64 }` only. `Spawn.teleport` waits on `Scene.waitAreaReady` (the same check
  `Maps.waitAreaReady` makes now). admin_probe's maps listener (the `core:maps:*` pushes) is retired. **Admin (D1a)**:
  the editor's `mapEl` state-bag path and the drag ghosts of networked types are gone (every element is a local copy
  it holds and moves); resources/admin records its side in its own DESIGN / PLAN (admin runner 3772 / 0).
- Tests: maps 328, maps_store 200 (apply validation, limits, expect / events / restore moved there), client_maps 257.

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).** FX3.
- **Slicing** (RV4 F2, RV6 F6): what is shown, the counts and the events change synchronously; the NODES follow. A
  change of ≤ 200 elements is reconciled inline; anything larger (an activation, a first publish, openDraft, a
  context closing, the boot projection, a type refresh, a clear) is queued per (context, element) — a later apply or
  deactivation supersedes a queued entry — and ONE worker thread makes ≤ 200 Scene calls per `Scene.batch`, then
  `Wait(0)`. Re-opening a closing context adopts its standing nodes; core stopping ends the threads; `R.stats()`
  gains `closing` / `pending` / `retrying` / `projecting`. Measured: a 3,000-element `setActive` costs 9–16 ms in the
  caller's tick (was 102–123 ms), then ~6–7 ms per slice. The node definitions and the `Maps.on` event queue moved to
  server/maps_types.lua (no manifest change). Known cost: server/maps.lua's activation limit check still walks every
  element (~25 ms per 20,000 elements, an admin action).
- **'limit' retry** (RV4 F3): a refused element is kept and retried — 5 s, doubling to 60 s while nothing gets placed;
  after a `'limit'` answer new spawns pause 1 s unless one of our nodes was removed. `Maps.respawn` retries at once:
  it still examines every element synchronously, only missing nodes past 200 queue, and its count includes the
  queued ones.
- **Fades** (RV5 F3): an apply's deletes, everything in an editor bucket and kind changes fade out; deactivations and
  publish swaps stay visibility-safe; client `uidOf` / `handleOf` keep answering while a removed copy still stands
  (`handleOf` only when no node carries the uid any more).
- **Authority** (RV6 F8): props, vehicles and peds in a draft's editor bucket get `{ mode = 'local', enter = false,
  damage = false }` (the editor never promotes); map vehicles in the target bucket get `{ mode = 'local' }` (enter,
  damage and actions still promote).
- **Readiness**: while a worker run lasts ≥ 3 slices, `GlobalState['core:mapsPending']` holds per-bucket boxes of the
  queued work (admin-triggered, rare and small — the one GlobalState write of the system); client `isAreaReady` /
  `waitAreaReady` (and through the hand-off `C.mapsPending`, `Scene.isAreaReady` / `waitAreaReady`) answer not-ready
  inside a box of the player's bucket.
- Natives: `GetGameTimer` (server/remote.lua), `AddStateBagChangeHandler` (client/maps.lua). Tests: maps 442,
  maps_store 200, client_maps 291; `tests/maps_harness.lua` lost its inert `mapEl` emulation.

#### 55.21.2 Inventory drops (resources/inventory, inventory DESIGN §3.4)

- server/drops.lua keeps documents, merging, the ground panel, the sweep and the admin index; the scoped delivery
  (§3.4.1: scope cells, subscriptions, `dropsAdd`/`dropsRemove`, the `inventory:drops` paging callback) is replaced by
  ONE scene node per drop: `kind = 'prop'`, owner inventory, bucket = the drop's bucket (0 when drops have none),
  `rot = { 0, 0, heading }`, `fields = { model, frozen = true, collision = false, snap = 'ground' }`, `interact = { {
  action = 'pickup', label = '<label> x<count>', distance = GroundRadius + PickupReach, prompt = { world = true,
  offsetZ = <model centre height>, range = PromptRange } } }`; pickup = `Scene.onInteract(nodeId, …)` → the existing
  pickup path; a count change = `Scene.set(id, {}, { interact = … })`; removal = `Scene.remove`. Nodes are rebuilt
  from `inventory_drops` at start (persist = false).
- client/drops.lua retires (the local objects, prompts and scope fetch are core's now).
- Core additions (§55.12 / §55.14): prop field `snap = 'ground'` (the client places the object on the ground after
  create — `PlaceObjectOnGroundProperly`, retried ≤ 5 times within 20 m while collision streams); interaction
  descriptor `prompt = { world, offsetZ, range }` (world prompt on/off per descriptor, §6.7).

**Implementation notes (2026-09-27, phase D run D2 and the integration).** Built as specified; resources/inventory
documents its side (its DESIGN §3.4.1, README). The nodes are rebuilt from the documents on every `Core.onReady`;
a node core refuses (its store still loading, a limit) is retried by the inventory's minute job; the ground panel,
merging and the sweep stay the inventory's. Gone: the `inventory:drops` paging callback, the scope subscriptions and
`dropsAdd` / `dropsRemove`, client/drops.lua and its shims. Weapon drops: the scene's model chain no longer refuses
models the admin catalogue lacks (run I1, §55.12 notes); the inventory's `Config.Drops.DefaultModel` fallback stays
as a safety net. Tests: the inventory runner 1995 / 0, fxlint 0 / 0 / 0.

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
FX4 (resources/inventory documents the details in its own
DESIGN §2.5, §3.4, §3.4.1). **Buckets** (RV6 F5): a drop lives in an explicit bucket, else the dropper's current one
when he is within 10 m, else 0; nodes, merging, the grid, the GROUND panel and the pushes are per bucket, and a pickup
of another bucket's drop answers `no_item`; old documents migrate to bucket 0. **Retry** (RV4 F4): the minute job
retries a queue of node-less drops, 50 per tick, stops a pass at the first `limit` / `unavailable`, and backs off 1 →
2 → 4 → 8 min (reset by an accepted node or a removed node of the inventory's), logging at most once a minute;
node-less drops stay pickable from the GROUND panel. Inventory runner 2127 / 0 (drops.lua split into drops.lua and
drops_jobs.lua).

#### 55.21.3 Player attachments (§20)

`Attachments.add/remove/clear/list` keep their API and persistence (`data.attachments`). Each attachment is one scene
`prop` node owned by core: `attach = { player = src }`, `bone`, `offset`, `offrot`, `fields = { model, collision =
false }`; created on `playerLoaded` (from the character data) and on `add`, removed on `remove` / `clear` /
`playerDropped`. The `attachments` player state bag is no longer written (the key stays reserved); client/remote.lua's
applier (state-bag handler + 2 s sweep) retires. The materialiser re-attaches when the target ped handle changes
(model swap, respawn).

**Implementation notes (2026-09-27, phase D run D3 and run I1).** server/remote.lua (836 lines) holds it;
client/remote.lua lost the applier.
1. Each node is spawned at the ped's position and attached with `Scene.attach(id, { player = src }, { bone, offset,
   offrot = rotation, rotOrder = 1 })` in the same synchronous run (the index coalesces both into one PUT); every
   Scene call runs AS CORE.
2. Fields `{ model, collision = false, frozen = false }`.
3. Nodes live in the player's routing bucket; `onPlayerBucketChange` makes them again in the new bucket.
4. An integer model hash is sent as `'0x%08X'` (clients decode it to the signed hash; since I1 the scene also takes
   integers).
5. Re-adding an id changes its node in place (a model change is `Scene.set`, a bone / offset / rotation change
   `Scene.attach` again).
6. Removals fade (`Scene.remove(id, { fade = true })`).
7. A refusal makes `add` answer `nil, 'scene refused the prop (<code>)'` and the entry is not stored; `unavailable`
   (the scene store still loading) or `attach` (no ped on the server yet) store the entry and queue the player for
   ONE retry thread (1 s pace, 32 players per server tick, alive only while somebody waits).
8. Validation: `model` a name `^[%w_%-]+$` ≤ 64 or an integer hash; `bone` a tag 0..65535 or a bone name, anything
   else 28422 (PH_R_Hand); each offset component ≤ 1000 m; ≤ 12 entries per player; readiness from
   `SceneRuntime.store.loaded()`.
Rotation order 1 (the old applier's and the community prop tables' `…, true, true, false, true, 1, true`) is kept
through the node's `rotOrder` (run I1) so stored offsets look the same; the scene's attach passes `detachWhenDead` /
`detachWhenRagdoll` = false (the node stays attached; the materialiser re-attaches on a new ped). Tests:
`tests/scene_attach_tests.lua` 259.

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).**
FX3. **Decision 7 changed** (RV4 F3): a `'limit'` refusal
(the scene is full: core's owner cap, the global node cap) no longer fails `add` — the entry is STORED, `add` returns
its id, and the node follows through the retry thread (5 s backoff doubling to 60 s while nothing gets placed; for 1 s
after a `'limit'` answer no new node is tried unless one of ours was removed). Other refusals still answer `nil,
'scene refused the prop (<code>)'`. `isPed = true` for ped anchors (§55.12 notes). Tests: `tests/scene_attach_tests.lua`
283.

#### 55.21.4 Parked vehicles (§4.6 persistence)

- `Vehicles.park(netId) -> nodeId | nil, err` (new): for a persisted vehicle — props from the owner client (or the
  record), delete the entity, create a persistent scene `vehicle` node (owner core, `fields = { model, props, plate,
  locked, vehId }`, the class default authority); the record gets `parked = nodeId` and stays `stored = false`.
- On promotion of a node with `fields.vehId` (hook `promoted`): Core.Vehicles adopts the clone — the §8 vehicle
  state bags (`coreVeh`, `locked`, `owner`, `keys`, `keyMode`, `plate`, `vehId`), `spawned[netId]`, hook
  `vehicleSpawned`; on demotion: props into the record, untrack, hook `vehicleDeleted`. netId-keyed APIs work while
  promoted; `Vehicles.getInfoByRecord(vehId)` answers either way.
- `Vehicles.spawnRecord(vehId, …)` on a parked record promotes its node instead of creating a second car;
  `Vehicles.store(netId | vehId)` (garage) removes the node. Automatic parking (`Config.Vehicles.AutoPark = true`): a
  10 s sweep parks persisted vehicles that are unoccupied, at rest for 30 s and have nobody within 50 m. Parked cars
  survive restarts as persistent nodes — no spawn storm at boot.
- Risk: `vehicle_system` (ensured in server.cfg, not in this workspace) may assume netIds stay stable for persistent
  vehicles; it must listen to `vehicleSpawned`/`vehicleDeleted` or key by `vehId`.

**Implementation notes (2026-09-27, phase D runs D4 and D4+).** The API, the record fields, AutoPark, the lock key on
a parked copy and the compatibility list are in §4.6's addition; the security rows (`core:server:parkedLock`,
`core:vehicles:props`, `core:scene:report 'applied'`) in §55.19's notes.
- **Deviation — a second file**: server/vehicles_park.lua (787 lines) loads right after server/vehicles.lua (685)
  and takes the live maps and helpers once through the one-shot global `CoreVehiclesPark` (asserted, then cleared);
  it wraps `spawnRecord`, `restoreRecord`, `store`, `delete` and `deleteRecord`. client/vehicles.lua (615) answers the
  callback `core:vehicles:props` and sends `core:server:parkedLock` for a parked car's local copy.
- `park` also takes a `vehId`; node fields add `vtype` (the record's `meta.vehType`); the model is the NAME when
  core knows it (`record.modelName`), else the hash. The scene hooks act only on core-owned `vehicle` nodes whose
  record parks them: promoted → the clone is adopted; demoted → props (the owner's, read at the demotion, else what
  `saveProps` took while promoted), pose, lock and keys go into the record and the node's fields follow; removed by
  anyone else → the record is out again.
- **One-shot `snCfg`** (D4+, §55.15 notes): only the clone's first owner applied props / lock / dirt / paint (the final
  round split it: cosmetics are re-applied by every owner, only wear / lock / dirt are one-shot — §55.15 final notes);
  core vehicle clones take `locked` from their own bag. **Stop order** (D4+): the clones' final poses go to their
  nodes through `R.promote.beforeStop` before any clone is deleted.
- The vehicle kind gained `vehId`, the `'0x%08X'` / integer model forms and the `vtype` input (run I1, §55.12 notes);
  a clone's model and type resolve through `R.promote.modelHash` and the node's `vtype`.
- Open: `vehicle_system` is not in this workspace (its dev-server symlink dangles), so nothing verified it against the
  new contract. Tests: `tests/scene_parked_tests.lua` 370, `tests/server_tests.lua` 1129 (vehicle section),
  `tests/scene_promote_tests.lua` 344.

**Implementation notes (2026-09-27, final review round RV4–RV6 / fix runs FX1a–FX4).** FX1a.
- **Deviation — a third file**: `server/vehicles_fleet.lua` (557 lines) loads right after `server/vehicles_park.lua`
  (758) and holds AutoPark, `MaxParked`, the boot check and park-at-stop; vehicles_park.lua passes the one-shot global
  `CoreVehiclesPark` on, vehicles_fleet.lua clears it. server/vehicles.lua is 777 lines, client/vehicles.lua 667.
- **Wear only** (RV4 F1): the park and demotion read-backs change only wear (`Scene.mergeWear`); every props write
  goes through `cleanProps` (native-range clamps, `props.plate` = the record's plate); cosmetics a key holder saved
  while the car was promoted win over the demotion read-back.
- Parked nodes spawn with `authority = { mode = 'local' }` (D-B: no proximity promotion; enter, damage and actions
  still promote); the boot check re-spawns older parked nodes with it.
- **Wrecks** (D-C, RV4 F5): a wrecked clone → the node is removed and the record keeps its last saved state marked
  `destroyed = true`; `restoreRecord`, `park` and the boot check refuse it (`'destroyed'`); `spawnRecord` brings it
  back and clears the mark. A lost (not wrecked) clone → the node and the record at its last pose with its last wear.
- `adopt` refuses an entity carrying `sn` (a scene clone) with `'scene_clone'` (RV4 F8). `setLocked` / `giveKeys` /
  `removeKeys` / `setOwner` accept a vehId: its live car, else the record and the parked node's lock (RV4 F13).
- **Stop and boot** (RV4 F14, RV6 F2): every live persisted car is parked at core stop (no spawn storm at boot, no car
  lost in limbo); the boot check parks out-records that have neither a node nor a car (not destroyed ones) and retries
  `'limit'` with backoff (10 s doubling to 5 min); `spawnRecord` answers `'already_spawned'` only while the record's
  car is live. A boot race is fixed (a car promoted during the boot check lost its node); records restore keys, lock
  and bucket, and positions carry the bucket.
- **MaxParked** (RV6 F9): past `Config.Vehicles.MaxParked` (20,000) the longest-unused parked car that is not
  promoted is garaged (node removed, record stored) and the hook `vehicleAutoStored (vehId, 'max_parked')` fires.
- **Live hand-off** (RV6 F11): a live car parks through `R.promote.adopt` + `Scene.demote` — the watchers' car never
  blinks out (fallback: frozen and locked for DeleteDelayMs + 500 ms, then gone).
- **Silent damage** (RV5): a parked car's local copy is created each time it streams in, so damage is applied quietly
  — a broken window is removed (`RemoveVehicleWindow`, not `SmashVehicleWindow`), a burst tyre gets `SetTyreHealth(veh,
  wheel, 0.0)` (flat, no burst), only listed entries that differ. client/vehicles.lua used 12 native names the runtime
  never generates (`GetVehicleExtraColour_5`, `GetVehicleLivery2`, …): `getProps` crashed in game; fixed (AGENTS §8).
- New natives: server `FreezeEntityPosition`, `GetEntityRoutingBucket`, `NetworkGetNetworkIdFromEntity`; client
  `RemoveVehicleWindow`, `SetTyreHealth` (+ the corrected names). Tests: `tests/scene_parked_tests.lua` 583,
  `tests/server_tests.lua` 1166.

### 55.22 Phase 0 — the §52 fade-band fix (amends §52.4)

`client/maps_spawn.lua`: element radius `r = clamp(lod, 30, 400)` / despawn `r + 15` is replaced by the §55.11 prop
rule: `S = GetLodscale()` (sampled every 1 s, radii recomputed on a > 5 % change), `B = 20` (5 when lod ≤ 20),
`r = lod·S + B + 10`, capped at `MaxSpawnRadius` (raised to 500; entities over the cap get `SetEntityLodDist(e,
floor((cap − B − 10) / S))`), despawn at `r + max(20, 0.25·r)`. The objects then exist before the camera reaches the
engine's fade band and leave only after it (research R3/R5/R9: today's radii create inside the visible range and
delete at ≈ 25 % alpha). Same change, same tests file: `tests/client_maps_tests.lua`.

**Implementation notes (2026-09-27, run M0).** Applied as written; the details (the 30 m minimum radius is gone, `S`
clamped 0.1–20, the scan limit = the cap + its despawn margin = 625 m, radii re-derived in slices of 500 per frame)
and the counts are in §52.4's M0 notes. **Superseded (2026-09-27) by §55.21.1**: client/maps_spawn.lua is deleted
and this rule with it — map props are `prop` nodes under §55.11's radii.

### 55.23 Tests, benchmarks, docs

- Suites (each on its own, `scripts/check.sh` runs them): `run_tests.lua` (`clock` + lib loader entries),
  `scene_codec_tests.lua`, `scene_motion_tests.lua` (identical results server/client), `scene_server_tests.lua` (API,
  kinds, validation, owners, persistence, audiences), `scene_index_tests.lua` (tiers, cells, versions, journals, packs,
  coalescing, handover, movers), `scene_interest_tests.lua` (focus validation, windows, rings, hysteresis, resync,
  flush budgets, latent), `client_scene_tests.lua` (decode/apply/versions/LRU, materialiser states, radii, priorities,
  budgets, caps, fades, visibility, kinds with native stubs; allocations per evaluation = 0), `scene_promote_tests.lua`,
  `scene_audio_tests.lua` (server policy + client Lua), `scene_voice_tests.lua`; node units
  `ui/tests/unit/audio-*.test.ts` (arbiter, curves, drift controller, ICY parser, sync) and a runtime-regression section
  (real Web Audio in Chromium 103).
- Benchmarks (`tests/scene_bench.lua`, numbers go to PLAN.md): server — 50,000 nodes, 2,000 simulated players (random
  walks + a 200-player hot spot), flush ms per tick p50/p99, crossings/s, bytes/s per client; client — 2,000 cached
  nodes along a camera path, ms and allocations per evaluation, creations per second.
- Docs with the code: README (API cheat sheet, server.cfg lines, in-game checklist), `types/core.lua` stubs for every
  public function, AGENTS §2 layout and §5 verification rows, PLAN.md run table.

**Implementation notes (2026-09-27, scene build runs A1–A6, B1–B3, C1, D1–D4, I1, FX1a–FX4 and review rounds RV1–RV6).**
The suites as run at the end of the build, after the final fix round (each on its own; `scripts/check.sh` runs them
all):

| suite | checks | covers |
|---|---|---|
| `run_tests.lua` | 468 | libs and loader, suite `clock` |
| `scene_codec_tests.lua` | 262 | every op both ways, quantisation, msgpack subset = runtime bytes, hostile input, RESET |
| `scene_motion_tests.lua` | 328 | every descriptor, velocity, finished, rebase / needsRebase |
| `scene_server_tests.lua` | 1061 | API, kinds, validation, owners, quotas, audiences, persistence, interact, drive, phase-D fields, rotOrder, OwnerCaps (over `tests/scene_server_harness.lua`: the real store and API, recording fakes of index / interest / flush) |
| `scene_index_tests.lua` | 851 | tiers, cells, lazy versions, journals, packs, coalescing, gate heads, handover, parked movers, benches |
| `scene_interest_tests.lua` | 582 | focus validation, windows, rings, hysteresis, resync, gated delivery, flush queues and budgets, RESET, the RV1 differential fuzz |
| `scene_audio_tests.lua` | 241 | server policy, admission, trusted, titles, client bridge, feed, occlusion |
| `scene_voice_tests.lua` | 290 | sessions, listener selection, adapters, submix pool, panning |
| `scene_promote_tests.lua` | 424 | policies, triggers, spawn worker, demotion, leases, beforeChange, the client hand-off, one-shot snCfg, clone model / vtype, beforeStop |
| `client_scene_cache_tests.lua` | 636 | decode / apply / versions / LRU / parked packs / worker, focus reporter, the public API, plugin bridge |
| `client_scene_mat_tests.lua` | 661 | states, radii, priorities, budgets, caps, pool guard, fades, visibility, movers, light pass, sliced rescale, `[bench]` |
| `client_scene_kinds_tests.lua` | 600 | prop / vehicle / ped, fx, world kinds, interactions, attachments, snap, paint |
| `scene_attach_tests.lua` | 283 | phase D: Core.Attachments on scene nodes (§55.21.3) |
| `scene_parked_tests.lua` | 583 | phase D: parked vehicles, AutoPark, the lock key on a parked copy (§55.21.4) |
| `maps_tests.lua` · `maps_store_tests.lua` · `client_maps_tests.lua` | 442 · 200 · 291 | phase D: the map projector, the documents / apply rules, the facade and the preview handler (§55.21.1); `maps_regions_tests.lua` is deleted |

`client_scene_tests.lua` became the three `client_scene_*` suites over the shared `tests/client_scene_harness.lua`.
With them: `server_tests.lua` 1166, `client_ui_tests.lua` 795, node units `# pass 377` (the audio units:
`ui/tests/unit/audio-{arbiter,cache,curves,engine,icy,loader,media,mixer,streams,sync,validate}.test.ts` +
`audio-fakes.ts`), browser suites shell 125 / kit 312 / runtime 240 (the runtime suite's section 15 drives the real
Web Audio engine). Benchmarks: `lua5.4 tests/scene_bench.lua [players] [nodes] [seconds] [nogc]` (defaults 2000
50000 30; `nogc` measures a join storm's heap growth) — the numbers in §55.7 notes; the client numbers are
client_scene_mat's `[bench]` line (§55.11 notes).

### 55.24 In-game probes (`resources/scene_probe`, dev-only — Liam runs `/sprobe <n>`, results go to the server console)

P1 engine fade of an existing script prop (create at `L·S + 40`, walk/drive in; again at `L·S − 10`) · P2
`GetLodscale()` across slider/scope/first person/aircraft · P3 clock alignment (two clients flash at server T+5 s) · P4
alpha slots (256, freeing, screen-door steps, vehicle pass) · P5 pools (local objects in steps of 100, with/without the
raise) · P6 create/delete cost per kind, model load latency · P7 clone arrival delay and `CNetObjObject` size · P8 NUI
codec matrix, `http://` and no-CORS streams · P9 NUI audio vs game sliders/pause/alt-tab, HRTF cost · P10 submix count,
output-volume ordering, 20 Hz panning without dropouts · P11 collision/interior after teleports · P12 latent vs
reliable ordering. Each has a fallback in RESEARCH.md §5.

**Implementation notes (2026-09-27, run P0).** Built as a STANDALONE resource (no dependency on core: it measures
engine facts) with a documented exception to AGENTS §3 "UI": its own never-focused plain-HTML `ui_page` for P8 / P9.
Deployed to the dev server as a symlink, never in server.cfg; access needs the ACE `scene_probe.use` or `command`.
`resources/scene_probe/README.md` is the operator's sheet: the run order (≈ 45 min, a second client for P3, P10 and
optionally P7), the safety notes (P5 can crash the game at a full Object pool; P4 and P10 consume game-session
resources), and a table of what each `RESULT` line decides here and in §55.11 / §55.16 / §55.17 / §55.20.
`/sprobe report` saves every player's lines to `scene_probe/data/`. Offline: `lua5.4 tests/probe_tests.lua` in the
resource → 134 passed; fxlint 0 / 0 / 0.

**In-game probe results (Liam, 2026-09-26 22:21 UTC, `scene_probe/data/report_20260926_222136.txt`).**
One run of every probe (a second
client for P3 / P10 where needed); the decisions landed in the sections named:

| probe | result | decision |
|---|---|---|
| P1 fade band | the engine faded the existing script prop in linearly over ~140 → 120 m (lodDist 120, S 1.0) and out the same way; the probe's "POP" read a stale, unscanned alpha (fixed in the probe; a replay gives FADE) | the fade band is confirmed for script objects (§55.11 notes); AGENTS §8 `GetEntityAlpha` gotcha |
| P2 LOD scale | S = 1.0000 in the one context sampled (on foot, third person) | unchanged (S sampled ≤ 1/s); **re-run** with the slider / scope / first-person / vehicle / aircraft contexts |
| P3 clock | network − server time, ping-corrected: mean 0.9 ms, p95 11.5 ms, max 24.5 ms; largest step 29.5 ms | `ClockMode = 'network'` confirmed (§55.2 notes) |
| P4 alpha slots | 256 granted to 300 props; `ResetEntityAlpha` and `DeleteEntity` free a slot, `SetEntityAlpha 255` does not | the §55.11 / AGENTS §8 rule confirmed |
| P5 pools | 2,000 local objects, 64 peds, 48 vehicles created (ambient vehicle baseline 136 of 300); ~45–54 ms per 100 objects in one go | caps hold; creation stays budgeted per frame (§55.11 notes) |
| P6 costs | crashed on `os` (the client VM has none) — fixed in the probe | **re-run**; AGENTS §8 `os` gotcha |
| P7 clones | a vehicle clone 89 ms after the event; 80 of 120 networked props resolved | ≈ 80 networked object clones per client (§55.15 notes) |
| P8 NUI codecs | `http://` fails (mixed content); AAC plays (MSE and `AudioDecoder`); the https test stream answered 403 | https-only confirmed; `AllowAac = true` (§55.16 notes); **re-run** the https stream row with another stream |
| P9 NUI audio | outputLatency 40 ms, audio − wall clock 2.6 ms, timer lateness p95 0.7 ms | the sync design stands (§55.16 notes) |
| P10 submixes | 12 free ids (28..39) | `Voice.Submixes = 8` fits (§55.17 notes) |
| P11 collision | props 2 m up landed on collision at once near the player | the physics rule stands (§55.15 notes) |
| P12 events | 9 / 9 arrived; a big reliable event delays its markers (head-of-line) | the byte budgets of §55.7 stand |

