# core — integrator guide

`core` is one resource that owns the framework: player sessions and persistence, money, factions, vehicles,
permissions, the world (markers, labels, blips, interactions) and **one** CEF page for the whole server.
It is Rebar-inspired — deep reusable APIs on both sides instead of a thin event bus.
A **plugin is just another resource**: `dependency 'core'` plus `'@core/import.lua'` first in `shared_scripts`
gives it the `Core` global, lets it start/stop on its own, and everything it registered inside core (markers,
blips, labels, interactions, UI pages) is removed automatically the moment it stops. That includes its
**frontend**: a plugin builds and ships its own UI bundle, core loads it into the one CEF page at runtime,
and `restart <plugin>` is the whole deploy loop (§38, "UI plugins").
**The server owns every gameplay fact** — money, factions, ownership, permissions, spawns; the client renders,
reads input and asks.

`DESIGN.md` next to this file is the binding contract; this README is its front door and every `§` points into it.

**Still not in core, deliberately** — write these as plugins: inventory/items, jobs, character creator,
garages, housing, voice, radial menu, nametags. (Wave 2 added needs, chat, time/weather, doors, weapons,
Discord webhooks and a MySQL adapter — see "Wave 2 APIs".)

## Install

Exactly what the dev server runs (`server.cfg`, applied 2026-09-12):

```cfg
ensure mapmanager
ensure spawnmanager
# ensure basic-gamemode   # disabled: core spawns players itself
# ensure chat             # REMOVED 2026-09-13: core's CEF chat replaces it (DESIGN §23)
ensure core               # always above every plugin that depends on it
ensure core_example       # the reference plugin (optional)

add_principal identifier.fivem:XXXX group.admin   # your admin identifier
add_ace group.admin core.admin allow              # /car /tp /setcash /setgroup /ban ...
add_ace group.admin core.mod allow                # /kick /announce /revive /heal, staff chat
set sv_stateBagStrictMode true                    # only the server may write state bags; core relies on it
# set core_webhook_audit "https://discord.com/api/webhooks/..."   # optional Discord mirror of the audit hook
```

`core` calls `exports.spawnmanager:setAutoSpawn(false)` on start and spawns the player itself from the character
document, so leaving `basic-gamemode` on means two spawns fighting. `spawnmanager` itself stays loaded.
`Core.Perms.has` checks `IsPlayerAceAllowed` first and falls back to the group stored on the account, so
`/setgroup <player> admin` also works without an ACE line (`Config.Perms.Groups`: `user`, `mod`, `admin`).
Every bag key core uses is written server-side and only read on the client (§8), so strict mode costs nothing
and stops a client forging `cash`, `faction` or a vehicle's `locked`.

**Operating it**: FXServer caches manifests — after adding or removing script files run `refresh` before
`ensure core`, otherwise the restart silently runs the old file list. `ensure core` also restarts every
resource that declares `dependency 'core'`. Status (2026-09-15): fxlint clean, 385 lib + 720 server + 999 interiors offline
checks green, shell regression 107/107 (2026-09-18), Storybook play functions green, both resources start clean on the dev
server; **the in-game checklist below has not been run yet**.

The wave-2 keys in `shared/config.lua` worth a look before you go live (§28):

| key | default | why you would change it |
|---|---|---|
| `Config.Security.EntityLockdown` | `'inactive'` | `'relaxed'` (only known models) or `'strict'` (no client-created entities) on bucket 0 — turn it up once every plugin spawns through `Core.Vehicles`, or client-side props stop appearing |
| `Config.Camera.DisableIdleCam` | `true` | switches GTA's AFK/idle cameras off (on foot, passenger, cinematic vehicle idle): they trip the cinematic auto-hide and closed open pages (§35); `false` restores the game's pans |
| `Config.Chat.Mode` | `'proximity'` | `'global'` makes plain chat reach the whole server; with `'proximity'` (the default) plain chat fades with distance — see "Chat (§23)" |
| `Config.Chat.FadeMeters` | `{ near = 20, far = 90 }` | full opacity inside `near`, fading to 0 at `far`; proximity lines deliver out to `far` |
| `Config.Chat.HideDelayMs` | `8000` | fade the feed after inactivity; `0` keeps it visible. Opening chat restores retained history |
| `Config.Chat.VisibleLines` | `8` | recent lines shown while closed (1–30); opening shows retained history |
| `Config.Chat.History` | `80` | received/sent history cap (1–200) |
| `Config.Chat.MaxLength` | `200` | plain message limit in UTF-8 bytes (1–256); the input uses the same limit |
| `Config.Chat.Format` | `nil` | optional custom format, e.g. `'{tag}{name}: {msg}'`; unset preserves separate name/message styling |
| `Config.World.TimeScale` | `30` | game seconds per real second — `30` is a 48-minute day, `1` is real time, `0` freezes the clock |
| `Config.Locale` | `'en'` | `'de'` ships too; adds `<resource>/locales/<lang>.json` lookups for `Core.Locale.t` (§26) |
| `Config.DB.Adapter` | `'kvp'` | `'postgres'` is the production backend (setup under "Where data lives"); `'mysql'` switches to the oxmysql adapter — **untested**, see "DB tools" below |
| `Config.Interiors.Enabled` | `true` | master switch for the §36 IPL loader (`false` loads nothing — only for debugging map issues) |
| `Config.Interiors.<group>` | per-group | `base heists bikers casino tuner …` default on; `north_yankton ufo red_carpet` default off; newer DLC groups self-gate on the game build / DLC (`/interiors` prints the effective state) |

Discord logging is a convar, never a config value, so the URL never lands in git:

```cfg
set core_webhook_audit "https://discord.com/api/webhooks/..."   # mirrors the `audit` hook
```

Any `core_webhook_<name>` convar makes `Core.Webhook.send('<name>', …)` work; an unset one is a silent no-op.

### Build the UI

`html/` is the build output of `ui/` and is what `ui_page 'html/index.html'` serves. It holds **the shell and
the kit only** — a plugin builds and ships its own frontend (§38, "UI plugins" below). The toolchain is
installed **once for the whole resources folder** — it is an npm workspace (`resources/package.json`), so
there is a single hoisted `resources/node_modules` and no resource carries a Vite install of its own:

```bash
cd ..                 # the folder core and your plugins live in
npm install           # once, and again whenever a plugin adds a library
npm run build:ui      # core's shell first, then every plugin that has a build script
```

`build:ui` is `npm run build --workspaces --if-present`. The two halves can also be built on their own, and
that is the normal day-to-day loop — a plugin build takes about a second and never touches core:

```bash
cd core/ui && npm run build            # -> ../html/index.html + html/assets/app.js + app.css
npm run build -w inventory-ui          # one plugin, from the resources folder -> inventory/ui/dist
cd inventory/ui && npm run build       # the same thing from inside the plugin
```

A plugin's npm workspace name is `<resource>-ui` (`inventory-ui`, `core_example-ui`), and `npm install -w`
wants that **name**, not the folder path. Both `core/html` and every `<plugin>/ui/dist` are committed: they
are what players download.

After a core UI change: `refresh; restart core`. After a plugin UI change: `restart <plugin>` — core is
neither rebuilt nor restarted and the CEF never reloads (see "The three dev loops").

TypeScript is pinned to `^5.9.3` in `core/ui/package.json` on purpose — a bare `npm i typescript` installs
TS 7, which `vue-tsc` 3.3.x cannot load. `npm run typecheck` in `core/ui` (or in a plugin's `ui/`) runs
`vue-tsc --noEmit`.

### Where data lives

Collections (`accounts`, `characters`, `factions`, `vehicles`, `bans`) live in `Core.DB` — an in-memory document store backed by the server's KVP file, flushed every 5 s and on stop, so no database is needed to run.
`Core.DB.setAdapter({ loadAll, put, remove, flush })` is the seam for MySQL/Redis; nothing else changes (§4.1).

#### Postgres

The recommended production backend (§33). Every document lands in one `core_documents` table
(`collection`, `id`, `data jsonb`, `updated_at`), written through on each change; KVP stays the
zero-setup default, so none of this is needed to run core.

```bash
docker run -d --name core-postgres --restart unless-stopped -e POSTGRES_USER=core -e POSTGRES_PASSWORD=<choose> -e POSTGRES_DB=core -p 127.0.0.1:5432:5432 -v core-pgdata:/var/lib/postgresql/data postgres:16-alpine
```

```cfg
exec core_pg.cfg   # in server.cfg; core_pg.cfg holds one line and never leaves the server:
set core_pg_url "postgres://core:<password>@127.0.0.1:5432/core"
```

Nothing to install on the server: the `pg` driver is bundled into `server/db_pg.js` (committed). Only when you
change `server/pg/index.js` or upgrade the driver, rebuild it from the UI toolchain:

```bash
cd resources/core/ui && npm run build:server   # esbuild → server/db_pg.js (first line: fxlint-disable-file)
```

Do not put a `package.json` or `node_modules` into the resource folder: FXServer's Node sandbox refuses to read
modules behind the symlinked resource path, and the server's `yarn` builder would run on every start.

Migrating an existing KVP server, in this order (§33.4):

1. on the running server: `/dbexport` — writes `data/export-<timestamp>.json`
2. load it straight into Postgres, outside the server: `CORE_PG_URL="postgres://…" node scripts/pg-import.js data/export-<timestamp>.json --replace`
3. set `Config.DB.Adapter = 'postgres'` in `shared/config.lua`, then `refresh` and `restart core` — every session
   (players who are online included) reloads from Postgres and finds its data already there
4. verify: `docker exec core-postgres psql -U core -d core -c "SELECT collection, count(*) FROM core_documents GROUP BY 1"`

Order matters: `/dbimport … replace` from the console also works, but only while **no player is connected** —
a session that loaded from the empty database before the import is autosaved over the imported rows.

`server/db_pg.js` owns the pool (max 4, 10 s statement timeout) and refuses every resource but core;
`server/db_pg.lua` is the adapter. An empty `core_pg_url` logs one error line and leaves core on KVP, and a
backend that stops answering degrades the affected collection (empty reads, refused writes) instead of
overwriting it. `CORE_PG_URL="…" node tests/pg_smoke.js` round-trips a document through a real server.

## Writing a plugin

> Functions cross resource boundaries as *function references* — callable tables, not Lua functions. Passing
> `onInteract = function(...) end` into core just works; but if you expose an API to other plugins
> (`Core.Api.register`) or accept callbacks yourself, test them with `Core.Utils.isCallable(v)`, never
> `type(v) == 'function'`.

Copy `templates/plugin/` (or `core_example/`) next to `core`, rename it, and start it after core.

```lua
fx_version 'cerulean'
game 'gta5'
dependency 'core'

shared_scripts { '@core/import.lua', 'shared/config.lua' }
client_scripts { 'client/*.lua' }
server_scripts { 'server/*.lua' }

-- only if the plugin shows a page (see "UI plugins"): the opt-in plus the files the CEF may fetch
core_ui 'ui/dist'
files { 'locales/*.json', 'ui/dist/**' }
```

**The one rule that bites people:** anything that registers something *inside* core — pages, markers, text
labels, blips, interactions — goes in `Core.onReady(fn)`, because it must be re-created after a core restart
and `onReady` replays it. Everything that lives in your own VM — `Core.Net.on`, `Core.Callback.register`,
`Core.Commands.register`, `Core.Keys.register`, `Core.UI.on`, `Core.on(hook, …)` — stays at file scope.
You never write an `onResourceStop` cleanup: core's owner registry does it (§2.3).

```lua
-- server/main.lua ------------------------------------------------------------
Core.Callback.register('my_plugin:getPrice', function(src)
    return Config.Price                               -- the server owns the number
end)

Core.Net.on('my_plugin:server:buy', {}, function(src)
    if not Core.Money.remove(src, 'cash', Config.Price, 'snack') then
        Core.Notify.send(src, 'Not enough cash', 'error')
        return
    end
    Core.Net.emit(src, 'my_plugin:client:bought', Config.Heal)
end, {
    cooldown = 1000,                                  -- at most one buy per second per player
    distance = { coords = Config.Shop, max = 4.0 },   -- must really be standing there
})

-- client/main.lua ------------------------------------------------------------
Core.Net.on('my_plugin:client:bought', { 'integer' }, function(heal)
    local ped = PlayerPedId()
    SetEntityHealth(ped, math.min(GetEntityHealth(ped) + heal, GetEntityMaxHealth(ped)))
end)

Core.Keys.register({
    name = 'shop', key = 'F5', description = 'Shop price',
    onPress = function()
        local price = Core.Callback.await('my_plugin:getPrice')
        Core.UI.notify({ message = ('Snacks cost %s'):format(Core.Utils.formatMoney(price or 0)) })
    end,
})

Core.onReady(function()                               -- runs again after every core restart
    Core.Interactions.add({
        coords = Config.Shop, radius = 2.0, label = 'Buy a snack',
        marker = { type = 1, size = vector3(1.5, 1.5, 0.5), color = { 0, 255, 255, 140 }, offsetZ = -0.9 },
        worldPrompt = true,                           -- §6.7: a 3D interaction dot instead of the bottom pill
        onInteract = function()
            if Core.UI.progress({ label = 'Buying...', duration = 2000, canCancel = true }) then
                Core.Net.emit('my_plugin:server:buy')
            end
        end,
    })
end)
```

`worldPrompt` is opt-in per interaction: `true`, or `{ range = 6.0, offsetZ = 0.3, icon = 'package',
description = '3 crates' }` to tune the dot (range in metres — how far the dot is DRAWN, keep it close to the
interaction, `offsetZ` floats it above the target, `icon` is a kit icon name). Core draws the dot on the
interaction's world point — an idle ring while the player is near, and the `E` cap plus the label the moment
the player *looks* at it. Two renderers, `Config.Interactions.WorldPrompt.Renderer`:

- `'native'` (default) — drawn in the game's render thread, **zero NUI messages**; the NP/qtarget-class path.
  Every frame draws, but the script-side projection and the look-at test only run every 33 ms (the render
  thread does the drawing projection), and an entity target's coordinates are re-read per frame only while
  they actually change — a resting prop is read once per 250 ms. An idle dot is ONE runtime-generated
  composite sprite (plus a pulse ring while it is in reach): 3 native calls per frame for an out-of-reach dot,
  4 for one in reach. The ONE looked-at hint follows
  `Config.Interactions.WorldPrompt.Hint`: `'scaleform'` (default) draws it as a single Scaleform movie
  (`stream/core_hint.gfx`, 5 native calls per frame instead of 26 — rebuild it with
  `scripts/build-hint-gfx.sh` and commit the `.gfx`, then `refresh` before `restart core`), `'sprites'` draws
  the `DrawSprite` + HUD text hint, which is also the automatic fallback while the movie loads or if it never
  does. That sprite hint's band is the kit's `--color-hud` bar and both text runs use the kit's own Barlow
  Condensed (600 label / 700 cap), streamed as `stream/barlow_condensed{,_bold}.gfx` and registered with
  `RegisterFontFile`/`RegisterFontId` (regenerate with `scripts/build-font-gfx.sh`; commit the `.gfx`).
- `'nui'` — the shell's `CoreInteractionDot` (§37.5), fed by throttled `worldprompts:set` messages.

Either way the dot replaces that entry's `Core.UI.textUI` pill; every other interaction and every other
text-UI producer is untouched. The dot is `disabled` (outline lock) while the ped is farther than the entry's
`radius`, and a disabled dot never fires. `Config.Interactions.WorldPrompt.Enabled = true` makes every
interaction without an explicit `worldPrompt` behave that way. Picking up a dot needs no code: core handles
the projection and the look-to-focus, the plugin only registers the entry.

`core_example/` is the same thing fully built out, page included. Prefix every event, callback and page id with your resource name so two plugins never collide.

**Appearance.** A full freemode look — head blend, components, props, face features, head overlays, hair
colour and eye colour (§34) — is stored with `Core.Player.setModel(src, model, appearance)` *after* your
plugin validated the table; core checks the shape only, and clamps rather than rejects. Core then re-applies
all seven groups on every spawn, respawn and model switch, so a character creator never hooks respawns. A
partial table applies only the keys it carries — `Core.Spawn.applyAppearance(ped, { faceFeatures = { [3] = 0.4 } })`
is the client-side live preview. A `components` or `props` entry may also carry `collection` + `localDrawable`,
FiveM's collection-local ids, which stay valid across title updates where a global `drawable` index shifts
(§34.5). Core prefers that pair whenever the game reports it as valid and falls back to the global `drawable`
otherwise, so `drawable` stays mandatory.

## API cheat sheet

### Shared libs — compiled into *your* VM, no export hop (§3)

**`Core.Utils`** (§3.1)

| functions | purpose |
|---|---|
| `isInteger` `isNumber` `isString(v, maxLen?)` `isBool` `isTable` `isVector3` `isFunction` | type guards, never throw |
| `clamp(n, lo, hi)` `round(n, decimals?)` `lerp(a, b, t)` | number helpers |
| `deepCopy(t)` `merge(base, override)` `keys` `values` `count` `isEmpty` | table helpers |
| `contains(arr, v)` `indexOf` `removeValue` `map(t, fn)` `filter` `find` | array helpers |
| `split(s, sep)` `trim` `startsWith` `endsWith` `capitalize` `truncate(s, n)` | string helpers |
| `sanitize(s, maxLen)` | strip control chars, trim, cut — run it on every string a player typed |
| `uuid()` `randomInt(lo, hi)` `randomString(len, alphabet?)` | ids and randomness |
| `formatMoney(n)` `hash(s)` `now()` | `'$1,234'`, `GetHashKey`, `GetGameTimer` |
| `tableToVector3(t)` `vector3ToTable(v)` `jsonSafe(v)` | vectors ↔ JSON-safe tables (needed before `DB`/NUI) |

**`Core.Math`** (§3.2)

| functions | purpose |
|---|---|
| `distance(a, b)` `distance2d(a, b)` | vector distance, 3D / flat |
| `headingToDirection(h)` `directionToHeading(dir)` `normalizeHeading(h)` `rotationToDirection(rot)` | heading ↔ direction |
| `offset(coords, heading, forward, right, up)` | a point relative to a heading |
| `isInsideSphere(p, center, radius)` `isInsideBox(p, min, max)` | zone tests |
| `deg2rad(d)` `rad2deg(r)` `roundVector(v, decimals)` | conversions |

**`Core.Validate`** (§3.3) — the one input validator; returns `ok, err`, never throws

| function | purpose |
|---|---|
| `check(schema, ...)` | positional args against a schema array — use it on every payload |
| `checkTable(schema, t)` | keyed table against `{ key = spec }` |
| `value(spec, v)` | a single value |

Specs: `'integer' 'number' 'string' 'boolean' 'table' 'function' 'any' 'vector3' 'netId' 'src' 'id'`,
`{ 'integer', min =, max = }`, `{ 'string', min =, max =, pattern = }`, `{ 'enum', 'cash', 'bank' }`,
`{ 'array', of =, max = }`, `{ 'table', keys = {…}, max = }`; a trailing `?` or `optional = true` allows `nil`.

**`Core.Log`** (§3.4) · **`Core.Callback`** (§3.5) · **`Core.Net`** (§3.6) · **`Core.Commands`** (§3.7)

| function | purpose |
|---|---|
| `Log.info(fmt, …)` `warn` `error` `debug` | `string.format` style; `debug` is a no-op unless `Config.Debug` |
| `Log.audit(category, src, fmt, …)` | server only; also fires the `audit` hook for a logging plugin |
| `Callback.register(name, fn)` | server: `fn(src, …)`; client: `fn(…)` |
| `Callback.await(name, …)` | client → server, awaits; `nil` on timeout/error |
| `Callback.awaitClient(src, name, …)` | server → one client, awaits; `nil` on timeout/error |
| `Net.on(name, schema, handler, opts?)` | validated handler; server `opts`: `cooldown`, `requireLoaded`, `permission`, `distance`, `onReject` |
| `Net.emit(src, name, …)` / `Net.emit(name, …)` | server → one client / client → server |
| `Net.emitMany(targets, name, …)` | server → a list of srcs; the payload is packed once. Scoped delivery ("the players near X") |
| `Net.broadcast(name, …)` | server → everyone; never from a loop, never for something only nearby players need (one reliable packet per connected client) |
| `Commands.register(name, opts, handler)` | `opts`: `description`, `params`, `permission`, `allowConsole`; auto usage text + chat suggestions |

**Client-only libs** (§3.8–§3.12)

| function | purpose |
|---|---|
| `Keys.register({ name, key, description, mapper?, onPress, onRelease?, debounce? })` | rebindable keybind, zero per-frame cost |
| `Streaming.requestModel/requestAnimDict/requestAnimSet/requestPtfx/requestCollision` (+ `release*`) | load with a timeout, then release |
| `Anim.play(ped, dict, clip, opts)` `Anim.stop(ped, dict?, clip?)` `Anim.isPlaying(ped, dict, clip)` | animations, dict handled for you |
| `Player.isLoaded()` `get(key)` `getServerId()` `getPed()` `getCoords()` `getHeading()` `getFaction()` `isDead()` | state-bag reads, no hop |
| `Player.onChange(key, fn)` | react to a replicated key changing |
| `UI.on(pageId, event, fn)` `UI.off(handle)` | receive events your page posts |

### Server (§4) — run inside core, reached through the proxy

| namespace | functions |
|---|---|
| `Core.DB` §4.1 | `create(coll, doc)` `get` `set` `update(coll, id, partial)` `delete` `find(coll, match)` `findOne` `all` `count` `flush()` `setAdapter(a)` |
| `Core.Player` §4.2 | `isLoaded(src)` `getInfo` `getData(src, path)` `setData(src, path, v)` `save` `saveAll` `getPlayers` `forEach` `count` |
| | `getSrcByCharId` `getName` `getLicense` `getPed` `getCoords` `setCoords` `setModel` `setBucket` `getBucket` |
| | `kick(src, reason)` `ban(src, reason, seconds?, by?)` `notify` `respawn(src, coords?, heading?)` |
| `Core.Money` §4.3 | `get(src, account)` `add` `remove` `set` `canAfford` `transfer(from, to, account, amount, reason?)` — integers only |
| `Core.Perms` §4.4 | `has(src, perm)` `getGroup(src)` `setGroup(src, group)` `isAdmin(src)` |
| `Core.Factions` §4.5 | `create(src, name, tag, opts?)` `disband` `get(id)` `list()` `getPlayerFaction(src)` `getMembers(id)` `hasPerm(src, perm)` |
| | `invite` `acceptInvite` `declineInvite` `leave` `kick(src, charId)` `setRank` `setRankDef` `addRank` `removeRank` `setOwner` `update` |
| | `deposit(src, amount)` `withdraw` `getBank(id)` `setMeta(id, k, v)` `getMeta(id, k)` |
| `Core.Vehicles` §4.6 | `spawn(opts)` `delete(netId)` `exists` `getEntity` `getInfo` `setLocked` `isLocked` `list()` |
| | `giveKeys(netId, charId)` `removeKeys` `hasKeys(src, netId)` `setOwner` `getOwner` `getPlayerVehicles(src)` — `keyMode = 'virtual'` is default; `'item'` leaves virtual keys empty for a domain plugin's physical-key check |
| | `persist(netId)` `getRecords(charId)` `getRecord(vehId)` `spawnRecord` `restoreRecord` `adopt(netId, opts)` `store(netId)` `saveProps` `deleteRecord` |
| `Core.Notify` §4.7 | `send(src, message, type?, duration?)` `broadcast(message, type?)` — types `info` `success` `error` `warning` |

Sugar: `Core.Player(src)` gives a handle — `Core.Player(src):getInfo()` and `Core.Player(src).money:add('cash', 10)`.

### Client (§6) — run inside core, reached through the proxy

| namespace | functions |
|---|---|
| `Core.Spawn` §6.1 | `spawnPlayer(opts)` `applyAppearance(ped, appearance)` `teleport(coords, heading?)` `setModel(model, appearance?)` |
| | `appearance` (§34, every group optional, applied in this order): `headBlend` `components` `props` `faceFeatures` `headOverlays` `hairColor` `eyeColor` |
| `Core.Player` §6.2 | `getData(key)` `refresh()` (on top of the lib reads above) |
| `Core.Markers` §6.4 | `add(opts)` `update(id, partial)` `remove(id)` `removeAll()` |
| `Core.TextLabels` §6.5 | `add(opts)` `setText(id, text)` `update(id, partial)` `remove(id)` `removeAll()` |
| `Core.Blips` §6.6 | `add(opts)` `update` `setLabel` `setCoords` `setRoute` `getHandle` `remove` `removeAll` `setWaypoint(coords)` `getWaypoint()` |
| `Core.Interactions` §6.7 | `add(opts)` `remove(id)` `removeAll()` `setEnabled(id, bool)` `setLabel(id, text)` `getActive()` |
| | `worldPrompt = true \| { range, offsetZ, icon, description }` — opt-in 3D dot; per-entry default is `Config.Interactions.WorldPrompt.Enabled` |
| `Core.Vehicles` §6.8 | `getClosest(coords?, radius?)` `getCurrent()` `isDriver()` `getSeat()` `getNetId(veh)` `fromNetId(netId, timeout?)` |
| | `getProps(veh)` `setProps` `getPlate` `getDisplayName` `hasKeys(veh)` `isLocked` `toggleLock(veh?)` `setEngine` `repair` `saveProps` |
| `Core.Raycast` §6.9 | `fromCamera(distance?, flags?, ignoreEntity?)` `between(from, to, …)` `getEntityInFront(distance?)` |
| `Core.Interiors` §36 | `request(ipl)` `remove(ipl)` `isActive(ipl)` — owner-tracked IPLs; `activateSet(coords, set)` `deactivateSet` `isSetActive` `refreshAt(coords)` — interior entity sets; `listGroups()` |
| `Core.UI` §6.10 | `registerPage(id, opts?)` `unregisterPage` `open(id, props?)` `close(id?)` `closeAll()` `isOpen(id)` `getOpenPage()` `isFocused()` `send(id, event, data)` |
| | `notify` · `textUI.show/hide/isShown` · `progress` + `progress.cancel` · `menu.open/close` · `input.open` · `alert` · `hud.set/setVisible` |
| | §38 state: `update(id, partial)` `patch(id, path, value)` `feed([channel,] values)` `isFeedActive(channel?)` |
| | §38 requests: `onRequest(name, fn)` `offRequest(name)` `request(target, name, data?, timeoutMs?)` |
| | §38 plugins: `plugins()` `isPluginReady(resource?)`; hooks `uiPluginReady (id)` / `uiPluginFailed (id, error)` |
| | §31 `hide(reason?)` `show(reason?)` `isHidden()` `hiddenReasons()` `setAutoHide(name, bool)` — auto-hide over the pause menu, fades and cutscenes; hook `uiVisibility (visible, reasons)` |

Also on `Core` itself: `Core.name` `isServer` `isClient` `isCore` `version` `Config` (core's config, read-only),
`Core.on(hook, fn)` `Core.emitHook(hook, …)` `Core.isReady()` `Core.onReady(fn)` `Core.onPlayerLoaded(fn)` (§2.4).

## UI

One CEF page hosts everything. The built-ins need no HTML of your own — call them from Lua:

```lua
Core.UI.notify({ message = 'Saved', type = 'success', duration = 4000 })  -- or Core.UI.notify('Saved', 'success')
Core.UI.textUI.show('E', 'Open the shop')                                 -- bottom pill; .hide() / .isShown()
local ok = Core.UI.progress({ label = 'Lockpicking...', duration = 4000, canCancel = true })  -- false = cancelled
local pick = Core.UI.menu.open({ title = 'Shop', items = { { label = 'Snack', description = '$5', value = 'snack' } } })
local vals = Core.UI.input.open({ title = 'Plate', fields = { { name = 'plate', label = 'Plate', type = 'text' } } })
if Core.UI.alert({ title = 'Sell', message = 'Sell this car?', confirm = 'Sell' }) then --[[ … ]] end
```

`progress`, `menu.open`, `input.open` and `alert` await their result, so call them from a thread, command or
event handler — never at file scope.

### Visibility (pause menu, fades, cutscenes)

The NUI layer is composited above *everything* the game draws, so on its own the HUD, the text UI pill and
your notifications would sit on top of the ESC map. core watches for that itself: **one** 200 ms thread
(`Config.UI.AutoHide`) reads at most six booleans and hides the whole shell — `.core-root` gets
`visibility: hidden; pointer-events: none` — while any of them is true. Nothing is polled per frame and a
NUI message only goes out when the visible state actually flips.

| `Config.UI.AutoHide` key | default | the shell hides while | reason key |
|---|---|---|---|
| `IntervalMs` | `200` | — | the poll interval; never set it to `0` |
| `PauseMenu` | `true` | the ESC menu / map is open | `game:pause` |
| `ScreenFade` | `true` | the screen is faded out or fading out | `game:fade` |
| `PlayerSwitch` | `true` | the player-switch cinematic runs | `game:switch` |
| `Warning` | `true` | a warning screen is up | `game:warning` |
| `HudHidden` | `false` | the game HUD is hidden | `game:hud` — off on purpose: `IsHudHidden`'s exact semantics are undocumented, and a wrong reading would hide the shell for good |
| `Cinematic` | `true` | the cinematic camera renders | `game:cinematic` |

Hiding is a **set of reasons**, not a flag, so two callers can never fight over it: the shell is hidden
while the set is not empty, and every key is namespaced by its owner — core's watchers own `game:*`, the
server API owns `server:*`, and a plugin's `Core.UI.hide('cutscene')` is stored as `<resource>:cutscene`.
A plugin can only clear its own reason, and every reason it holds is dropped when the resource stops, so a
crashed cutscene script cannot leave the shell hidden.

```lua
-- client (§31.2) — the reason defaults to 'default'
Core.UI.hide('cutscene')                  -- adds <resource>:cutscene; returns true
Core.UI.show('cutscene')                  -- true when it removed one; never touches game:* or server:*
Core.UI.isHidden()                        -- true while any reason is set
Core.UI.hiddenReasons()                   -- { 'game:pause', 'my_plugin:cutscene' } — admin/debug tooling
Core.UI.setAutoHide('cinematic', false)   -- pause|fade|switch|warning|hud|cinematic; also clears game:<name>
Core.on('uiVisibility', function(visible, reasons) end)   -- fires on the flip only, never per reason

-- server (§31.5), for one player
Core.UI.hide(src, 'cutscene')             -- stored on that client as server:cutscene
Core.UI.show(src, 'cutscene')
```

While it is hidden the shell keeps **running**: progress bars still complete, notifications still expire,
HUD values still update, and showing again does nothing but flip the flag — whatever is still active
reappears. The one exception is focus, because a player must never be stuck behind an invisible element
that holds the cursor: the hidden transition closes the open built-in modal (menu / input / alert resolve
with exactly what ESC gives them) and the focused page (`page:close`, its `close` event fires as usual).
**Hiding with a modal open equals cancelling it** — that is documented behaviour, not a bug. Overlay pages,
the text UI, key hints, the spinner, the shard and the progress bar are only hidden, never cancelled.
Server reasons are fire-and-forget: they follow the session and are gone when the NUI reloads.

### UI plugins

There is still exactly **one** CEF page, one Vue, one kit and one focus owner — core's. What changed (§38) is
where a page's *code* lives: every resource now owns, builds, ships and restarts its own frontend, and core
imports it at runtime from `https://cfx-nui-<resource>/ui/dist/`. Core is never rebuilt for a plugin, and a
resource core has never seen can bring a UI along.

#### What a plugin ships

`scripts/new-plugin.sh <name>` writes all of this; `templates/plugin/ui/` and `core_example/ui/` are the
worked examples.

```
my_plugin/
  fxmanifest.lua        dependency 'core'   core_ui 'ui/dist'   files { 'ui/dist/**' }
  ui/package.json       name '<resource>-ui'; scripts dev / dev:game / build / typecheck; devDep '@core/ui'
  ui/vite.config.ts     export default defineConfig({ plugins: [coreUI()] })
  ui/tsconfig.json      { "extends": "@core/ui/tsconfig.plugin.json", "include": ["src", "dev"] }
  ui/.gitignore         .core-ui/ and node_modules/ — dist/ is NOT ignored, it is committed
  ui/src/index.ts       export default defineUIPlugin({ pages: { … }, setup(ctx) { … } })
  ui/src/Page.vue       the page itself
  ui/dev/host.ts        createDevHost({ id, plugin, mock }) — the browser dev loop; never shipped
  ui/dev/mock.ts        typed mock data + fake Lua for it;                never shipped
  ui/dist/              BUILD OUTPUT, committed like core/html — manifest.json, plugin.<hash>.js/.css
```

Two lines in `fxmanifest.lua` are the whole opt-in:

```lua
core_ui 'ui/dist'                        -- core reads ui/dist/manifest.json from THIS resource
files { 'locales/*.json', 'ui/dist/**' } -- only listed files are packed for the client and fetchable
```

Never let a `client_scripts` glob reach into `ui/dist` — FiveM serves those files as garbage. `vue` never
belongs in the plugin's `package.json`: the shell hands it over at runtime, so there is exactly one Vue.

#### The entry — definitions at module scope, side effects in `setup`

```ts
// my_plugin/ui/src/index.ts
import { defineUIPlugin, definePage } from '@core/ui'
import Page from './Page.vue'

export interface MyPluginProps { title?: string }
// Event and RPC maps are `type`, not `interface`: only a type alias carries the implicit index
// signature the SDK's `Record<string, …>` constraints need.
export type MyPluginEvents = { hello: { at: number } }
export type MyPluginIncoming = { greeting: { text: string } }
export type MyPluginRpc = { ping: { req: Record<string, never>; res: { pong: boolean } } }

export default defineUIPlugin({
    pages: {
        my_plugin: definePage<MyPluginProps>({ component: Page }),
        // a big, rarely opened page: component: () => import('./Big.vue')
        // more ids (an overlay, a modal) are more entries here
    },
    setup(ctx) {
        ctx.log('activated, generation', ctx.generation)      // only prints with Config.UI.Dev.Log
        ctx.nui.on('somethingGlobal', handler)                // Lua -> plugin, outside any page
        ctx.nui.handle('whoAreYou', () => ({ id: ctx.id }))   // Core.UI.request answers here
        ctx.scope.listen(window, 'blur', onBlur)              // removed on dispose
        ctx.scope.interval(tick, 1000)                        // cleared on dispose
    },
})
```

**Module scope is for definitions only.** The browser pins an ES module by URL for the life of core's page, so
this file is evaluated once and then cached — while `setup(ctx)` runs once per *activation*, i.e. on every
start of the resource. A listener, timer, subscription or store created next to the imports survives a
`restart` and fires twice; the same thing created through `ctx.scope` (or `ctx.nui`) is disposed with the
plugin. `setup` must be **synchronous**: a returned Promise is warned about — start async work inside it and
clean it up through `ctx.scope`. `setup` may return a disposer, which runs before the scope itself.

#### Inside a page component

```vue
<script setup lang="ts">
import { NuiError, useHud, useNui, usePage } from '@core/ui'
import type { MyPluginEvents, MyPluginIncoming, MyPluginProps, MyPluginRpc } from './index.ts'

// No id inside a page component: usePage() resolves the page being rendered. `props` is the ONE
// reactive object of this page id for the life of the shell — Lua's open/update/patch mutate it.
const { props, emit, on, close } = usePage<MyPluginProps, MyPluginEvents, MyPluginIncoming>()
const hud = useHud()                       // readonly reactive HUD
const nui = useNui<MyPluginRpc>()          // this plugin's own channel (= the resource name)

on('greeting', (d) => { reply.value = d.text })   // dies with the page — no onUnmounted(off)
emit('hello', { at: Date.now() })                 // fire and forget
const { pong } = await nui.invoke('ping')         // request/response; rejects with NuiError
</script>
```

| SDK export | what it gives you |
|---|---|
| `defineUIPlugin(def)` · `definePage<Props>(def)` | the entry's default export · one page (`component`, `onOpen`, `onUpdate`, `onClose`, `keepAlive`, `reactivity`) |
| `usePage<Props, Out, In>(id?)` | `{ id, props, isOpen, emit, on, close }` — no id inside a page component |
| `useNui<Rpc, Out, In>(channel?)` | `{ channel, emit, invoke, on, handle }` — the plugin's channel, not tied to a page |
| `useScope()` | the current scope: `onDispose` `listen` `timeout` `interval` `raf`, all auto-disposed |
| `useFeed<T>(channel?)` | a `shallowReactive` telemetry target fed by `Core.UI.feed` (one rAF per frame) |
| `useHud()` · `usePlayerState()` · `useStats()` | the shell's readonly reactive state |
| `t(key, vars)` · `notify(...)` · `playSound(name, set?)` · `registerIcons(icons)` | core's string table, a local toast, `PlaySoundFrontend`, extra kit glyphs |
| `NuiError` | what a rejected `invoke` throws: `.code` is one of the codes in the cheat sheet below |

`defineUIPlugin` and `definePage` are pure and run at module evaluation; every other export resolves the host
lazily and throws a clear error outside the shell. Generics stay one level deep — a props interface, an event
map, an rpc map; nothing is inferred across the Lua boundary.

#### Lua side (unchanged signatures)

```lua
Core.onReady(function()   -- registration lives in core, so it must be replayed after a core restart
    Core.UI.registerPage('my_plugin', { type = 'page' })    -- 'page' | 'overlay' | 'modal'
end)
Core.UI.open('my_plugin', { title = 'Hi' })             -- props snapshot; 'page' takes focus
Core.UI.send('my_plugin', 'greeting', { text = 'Hi' })  -- Lua -> page (an id or a plugin channel)
Core.UI.on('my_plugin', 'hello', function(data) end)    -- page -> Lua, at file scope
Core.UI.onRequest('ping', function(data) return { pong = true } end)   -- answers nui.invoke('ping')
```

Lua stays the authority on page ids, types and ownership: the `pages` list in `manifest.json` is tooling and
diagnostics only. Every id still needs its own `Core.UI.registerPage`.

`props` is reactive and **stable** for the life of the shell: a second `open`, an `update` or a `patch`
mutates the same object instead of replacing it, so scroll position and local state survive — and a module
singleton that captured `props` keeps working across a plugin restart.

#### Styling

What the page *draws* is the UI kit (next section): `<CoreScreen>`, `<CorePanel>`, `<CoreButton>`,
`<CoreSlotGrid>` … are registered globally on core's Vue app, so a page imports no component and resolves the
tag at render time. The plugin's own stylesheet holds **only** the Tailwind utilities its sources use (inside
`@layer utilities`, generated against core's tokens by reference) plus its SFC `<style scoped>` blocks — no
preflight, no `:root` tokens, no kit classes. Cascade layers are document-wide and core declares the order
first, so a plugin utility still beats a kit class.

```css
/* a scoped <style> that uses @apply has to point Tailwind at the theme first */
@reference "@core/ui/reference.css";
```

That is a package specifier now, not a relative path into core's source tree. Tokens only — never a literal
colour, font family or radius — and an unscoped global selector in plugin CSS is a bug (nothing can take it
back cleanly): prefix or scope it.

An extra runtime library (drag-and-drop, icons, charts) goes in the plugin's own `ui/package.json`
`dependencies` + `npm install` at the resources folder; it is bundled into **that plugin's** `ui/dist`.

#### `window.CoreUI` (legacy)

`window.CoreUI` is still there for tests, stories and old pages — `Vue`, `registerPage`, `usePage`, `emit`,
`on`, `close`, `post`, `hud`, `state`, `stats`, `minimap`, `lang`, `t`, `playSound`, `notify`,
`whenRegistered`, `kit`, `gameBlur`. New plugins use `@core/ui`. A `CoreUI.on` made inside `setup` or a
component is scoped like the SDK's; one made at module scope is never cleaned up and logs a dev warning.
The exact NUI protocol is DESIGN §6.10 plus §38.5. No CDNs, no web fonts: no network.

### The three dev loops

| loop | command | what you get |
|---|---|---|
| **browser, no game** (the default) | `cd my_plugin/ui && npm run dev` | core's real shell, real kit, real focus stack and a typed fake Lua, all in the plugin's own Vite server — one module graph, one Vue, native HMR for the plugin *and* the shell |
| **in game, plugin-only rebuild** | `npm run build` (or `build -- --watch`), then `restart my_plugin` | new hash → new URL → new code. No core rebuild, no core restart, no NUI reload |
| **in game, dev server** (opt-in) | `npm run dev:game` + `/uidev my_plugin http://localhost:5173` | the in-game shell imports from Vite instead of the build; `/uidev my_plugin off` returns to it |

The browser loop is driven by the plugin's `ui/dev/host.ts`, which calls `createDevHost({ id, plugin, mock })`
from `@core/ui/dev`. An `ui/index.html` is **optional** — with none, `coreUI()` serves one from memory
pointing at `dev/host.ts`, so the whole browser dev loop is two files in the plugin and no HTML to maintain
(without either, the dev server answers with a 500 that prints the four lines `host.ts` needs). The mock
(`createMockTransport()`, `ui/dev/mock.ts`) is typed: initial pages and props, `onRequest(name, fn)` fakes for
`nui.invoke`, `emitToPage`, `patch`, `feed`, and `restart()`, which replays `plugin:unregister` →
`plugin:register` (generation + 1) and is the proof your cleanup works. The same mock transport backs the
Storybook stories and the unit tests. Nothing under `ui/dev/` is ever built into `ui/dist` — `npm run build`
only ever looks at `src/index.ts`, and `ui/dev/` is outside the resource's `files {}`.

The in-game dev server needs `Config.UI.Dev.Enabled = true` (production never reads `Config.UI.Dev` at all)
and only works on **`localhost`** — secure-context rules; if the game and the editor are on different
machines, forward the port so the game sees `localhost:5173`. With a production shell a hot update
re-activates the plugin and the props survive (they belong to the shell); build the shell with
`npm run build:dev` in `core/ui` to keep Vue's HMR runtime and have SFC edits patch in place instead.

### Page state: open, update, patch, feed

FiveM pays two JSON encodes, two parses, a UTF-16 conversion, an IPC hop and a structured clone for **every**
`SendNUIMessage`, and the cost is proportional to the payload — so send the snapshot once and the deltas
afterwards. A 200-slot inventory measures 7 947 B for the snapshot against 81 B for one slot
(`ui/tests/BENCH.md`).

```lua
Core.UI.open('inventory', { slots = all, maxWeight = 120 })     -- snapshot, once
Core.UI.update('inventory', { weight = 84.5, maxWeight = 130 }) -- shallow merge of top-level keys
Core.UI.patch('inventory', 'slots.12', slot)                    -- one value; nil deletes the key
Core.UI.feed({ speed = 132, rpm = 0.71, gear = 4 })             -- telemetry, channel = calling resource
```

`update` and `patch` are queued per page and flushed on the next tick as **one** message; any other message
for that page (`open`, `close`, `send`, `request`, `unregisterPage`) flushes the queue first, so a page never
sees an event before the state change that preceded it in Lua. Core applies the same ops to its replay copy,
so a shell reload restores current state. On a page that is not showing both do nothing and return `false`
without a log line — a producer may push blindly.

**A path addresses the Lua table you passed to `open` — Lua's view, 1-based.** A segment that indexes a list
(a sequence, or an empty table) with `1 ≤ n ≤ #t + 1` writes `t[n]` in Lua and `arr[n - 1]` in the page
(`#t + 1` appends); everything else is a map key. An index outside a list, or a delete in its middle, is a
hole: it still applies, but it warns — send such a list whole with `update`. Collections addressed by id are
therefore best **keyed by strings** (`slots = { ['12'] = … }`); lists stay lists. At most 8 segments deep,
charset `[%w_%-]`, at most 64 ops per flush (more becomes one `open` snapshot instead).

`feed` is for telemetry that changes many times a second: the latest value per key wins in Lua, at most one
message per `Config.UI.FeedIntervalMs` leaves the client, and in the page one `requestAnimationFrame` per
frame copies it into the `shallowReactive` object `useFeed<T>()` returns. `Core.UI.isFeedActive(channel?)` is
true only while a mounted component reads that feed, so the producer loop can sleep when nobody is looking.
Interaction-critical traffic (`open`, `close`, focus, events, requests, results) is never delayed.

Both exist server-side for one player: `Core.UI.update(src, id, partial)` and
`Core.UI.patch(src, id, path, value)`.

### Requests (a real RPC, both directions)

Events stay events — nothing that does not need an answer becomes a request.

```lua
-- page -> Lua: answers nui.invoke('greet', { name = 'Liam' }) on the CALLER's channel
Core.UI.onRequest('greet', function(data)
    return { text = 'Hello ' .. tostring(data.name) }   -- may yield: Core.Callback.await works here
end)
Core.UI.offRequest('greet')

-- Lua -> page: target is a page id or a plugin channel (the resource name)
local ok, result = Core.UI.request('my_plugin', 'whoAreYou', {}, 5000)   -- yields
```

`request` returns `ok, resultOrErrorCode`; `timeoutMs` is clamped to `1000..Config.UI.RequestMaxMs`. On the
page side a rejected `nui.invoke` throws a `NuiError` whose `.code` is one of:

| code | when |
|---|---|
| `timeout` | nobody answered in time (both sides have their own timeout) |
| `aborted` | the caller's `AbortSignal` fired |
| `no_handler` | no `onRequest` / `nui.handle` under that name |
| `handler_error` | the handler threw; the message comes along |
| `bad_request` · `bad_result` | the payload or the result could not be encoded |
| `resource_stopped` · `plugin_disposed` | the owner went away mid-flight |
| `transport` | the NUI fetch itself failed |

Lua's side can additionally answer `not_ready` (the plugin is not running), `shell_reloaded` and `no_target`.
A handler registered with `onRequest` is tracked by `Core.Registry`, so it dies with the resource — you never
write the cleanup.

### Knowing whether a plugin is up

```lua
Core.UI.plugins()              -- CoreUIPluginInfo[]: { id, state, generation, build, error?, ms? }
Core.UI.isPluginReady()        -- the calling resource; isPluginReady('inventory') for another
Core.on('uiPluginReady', function(id) end)
Core.on('uiPluginFailed', function(id, err) end)
```

`state` is `registered` · `loading` · `ready` · `failed` · `incompatible`. `generation` counts activations, so
a restart is n+1. Opening a page whose plugin is still loading simply waits for it.

Three client commands come with the platform:

| command | needs | what it does |
|---|---|---|
| `/uiplugins` | — | one line per known UI plugin: id, state, generation, build, error. The first thing to look at when a page stays blank |
| `/uidev <resource> <http://localhost:PORT\|off>` | `Config.UI.Dev.Enabled` | point one plugin at its Vite dev server, or back at its build. The origin survives a `restart` of that plugin and is cleared only by `off` |
| `/uiinspect` | `Config.UI.Dev.Enabled` | toggle the shell's inspector panel: plugin states, module cache, pages, the focus stack, per-scope listener/timer counts, pending requests, messages/s and bytes/s, feed rates, long tasks, the last 50 errors. Its chunk is only fetched on the first toggle |

#### `Config.UI` keys (§38)

| key | default | what it does |
|---|---|---|
| `FeedIntervalMs` | `50` | how often coalesced `Core.UI.feed` telemetry leaves Lua; clamped to 16–1000 |
| `RequestTimeoutMs` | `10000` | the default timeout of `Core.UI.request` and of a held `ui_request` |
| `RequestMaxMs` | `30000` | the ceiling an explicit `timeoutMs` is clamped to |
| `PluginLoadTimeoutMs` | `8000` | how long the shell waits for a plugin's module before it gives up on an open |
| `Dev.Enabled` | `false` | the master switch for `/uidev`, `/uiinspect` and everything below. Production never reads the rest |
| `Dev.Inspector` | `false` | open the inspector panel from the start |
| `Dev.Log` | `false` | the shell's grep-able lifecycle lines (`[UI] inventory ready in 38 ms (2 pages)`), and what `ctx.log` prints |
| `Dev.Servers` | `{}` | seeds `/uidev` for the session: `{ inventory = 'http://localhost:5173' }` |

### Design system (UI kit)

Every screen — the shell's own built-ins and every plugin page — is built from **one** kit (DESIGN §37),
so nothing drifts apart. The look is Liam's four mockups: blue-black translucent slate, one coral accent
(`#f6503f`) with two gradient recipes, Barlow Condensed for anything that shouts and Barlow for prose,
6 px panels / 4 px controls, hairline borders, near-white key caps. Three layers, each usable on its own:

| layer | where | what it is |
|---|---|---|
| tokens | the `@theme static` blocks of `ui/sdk/theme.css` (imported by `ui/src/styles.css`, referenced by every plugin build) | every colour, font, radius, shadow, size — each one also a Tailwind utility (`bg-panel`, `text-fg-dim`, `rounded-ui`, `font-display`, `text-display-lg`) |
| classes | `ui/src/kit/css/*.css` | the `.core-*` vocabulary (`core-btn`, `core-panel`, `core-slot`, …); plain HTML may wear them |
| components | `ui/src/kit/components/Core*.vue` | ~60 tags registered **globally** on the shell's one Vue app — `<CoreButton>` works in any page with no import |

#### The tags

Grouped as in DESIGN §37.5, which is the full API (props · slots · emits · classes · exact look):

| group | components |
|---|---|
| foundation | **CoreIcon** a registry glyph (`kit/icons.js`, 185 names, 24 × 24, `currentColor`) |
| actions | **CoreButton** every button (`primary` `secondary` `ghost` `danger` `success`, `fade`, `kbd`, `loading`, `block`) · **CoreIconButton** square icon-only · **CoreKey** a key cap or mouse glyph · **CoreKeyHint** cap + caption · **CoreKeyHints** the hint bar of a footer · **CorePrompt** `[F] ENTER VEHICLE` · **CorePromptGroup** stacked prompts |
| surfaces | **CorePanel** the bordered panel (title/subtitle/eyebrow, `actions` + `footer` slots, `blur`) · **CoreScreen** full-page scaffold (header · body · footer) · **CoreBackground** the scrim over the game · **CoreCard** media + text card · **CoreHeading** title block with the `//` marker · **CoreDivider** hairline · **CoreDash** the short accent bar · **CoreTagline** stacked wide-tracked lines · **CoreBrand** logo lockup |
| navigation | **CoreTabs** top row with the glowing underline · **CoreMenu** vertical rows (main menu, sidebar) · **CoreChips** filter chips / segmented control · **CoreStepper** `‹ value ›` cycler |
| forms — text | **CoreField** label + control + hint/error (`inline` = settings row) · **CoreInput** text field · **CoreTextarea** with counter · **CoreNumberInput** `[−] 12 [+]` · **CoreSelect** dropdown (`box` or the inline `SORT: RECENT ⌄`) |
| forms — choice | **CoreCheckbox** · **CoreRadioGroup** / **CoreRadio** (`radio` or `card`) · **CoreSwitch** · **CoreSlider** · **CoreSwatches** colour picker |
| data — meters | **CoreProgress** linear bar (`inline`, `segments`, threshold tones) · **CoreRing** radial · **CoreStatBar** HUD vital · **CoreStatRow** detail stat between hairlines · **CoreSpinner** · **CoreSkeleton** |
| data — display | **CoreBadge** count pip · **CoreTag** small chip (tones + rarities) · **CoreAvatar** · **CorePlayerChip** avatar · name · level · XP · **CoreTable** · **CoreKeyValue** ruled label/value rows · **CoreEmpty** empty state |
| game | **CoreSlot** item slot · **CoreSlotGrid** the inventory grid · **CoreHotbar** · **CoreList** / **CoreListItem** rich rows · **CoreObjective** · **CoreTracker** HUD quest card · **CoreCompass** heading strip · **CoreInteractionDot** world interaction dot → key prompt |
| feedback | **CoreAlert** inline banner · **CoreToast** notification card · **CoreDialog** modal (focus trap, escape layers) · **CoreDrawer** side sheet · **CorePopover** anchored panel · **CoreContextMenu** right-click menu · **CoreTooltip** · **CoreShard** centre-screen banner |

Props follow one vocabulary: `size` (`sm|md|lg`), `tone` (`accent|neutral|success|warning|danger|info`,
plus the meter tones `health|armour|stamina|hunger|thirst|oxygen|stress` where a meter takes one),
`icon` (a registry name or raw path data), `disabled`, `v-model` for anything carrying a value, and
`items` for anything listing things (strings or `{ value, label, icon?, description?, disabled? }`).

#### A page, in full

```vue
<script setup lang="ts">
import { ref } from 'vue'
import { usePage } from '@core/ui'
const { props, emit, close } = usePage<MyPluginProps>()   // props / emit / on / close
const tab = ref('bag')
const selected = ref(null)
</script>

<template>
    <CoreScreen background="scrim" blur>
        <template #nav>
            <CoreTabs v-model="tab" :items="[{ value: 'bag', label: 'Bag' }, { value: 'crate', label: 'Crate' }]" />
        </template>

        <CorePanel title="Inventory" subtitle="Gear up for what's next." slash scroll>
            <template #actions><CoreButton icon="sort" size="sm">Sort</CoreButton></template>
            <CoreSlotGrid v-model:selected="selected" :items="props.items || []" :columns="6" :slots="24" />
            <template #footer>
                <CoreButton variant="primary" kbd="F" :disabled="!selected"
                    @click="emit('use', { id: selected })">Use</CoreButton>
            </template>
        </CorePanel>

        <template #footer-end>
            <CoreKeyHints bare :items="[{ key: 'ESC', label: 'Close' }, { key: 'F', label: 'Use' }]" />
        </template>
    </CoreScreen>
</template>
```

`templates/plugin/ui/src/Page.vue` is the same thing in its smallest form, `core_example/ui/src/Page.vue`
the annotated one; every component has a Storybook story under **Kit/** with a playground and a gallery,
**Kit → Showcase** rebuilds the four mockups from kit parts only, and **Docs → Design System** is this
section inside Storybook.

#### Tokens

Utilities and CSS variables are the same names. Opacity modifiers (`bg-accent/10`) only work on the
**hex** tokens — Tailwind cannot resolve an `rgba()`/`var()` token and Chromium 103 has no `color-mix()`.

| group | utilities / variables | value |
|---|---|---|
| surfaces | `bg-ink` `bg-panel` `bg-panel-solid` `bg-panel-raise` `bg-panel-sunken` `bg-panel-popup` `bg-hud` `bg-backdrop` | `#060b0f` · `rgba(11,17,22,.90)` · `#0d1419` · white 3.5 % · black 30 % · `rgba(11,17,22,.98)` · `rgba(8,12,16,.68)` · `rgba(4,8,11,.62)` |
| hairlines | `border-border` `border-border-strong` | white 12 % · white 22 % |
| text | `text-fg` `text-fg-dim` `text-fg-faint` · `bg-key` `text-key-fg` | `#f3f5f7` · 66 % · 40 % · `#fbfbfb` · `#11161b` |
| accent | `text-accent` `bg-accent-hi` `bg-accent-lo` `bg-accent-soft` `text-on-accent` | `#f6503f` · `#ff6351` · `#d53e2f` · `rgba(246,80,63,.16)` · `#fff` |
| states | `text-success` `text-warning` `text-error` `text-info` | `#3fd67f` · `#f5a623` · `#ff4560` · `#55b6f7` |
| vitals | `text-health` `text-armour` `text-stamina` `text-hunger` `text-thirst` `text-oxygen` `text-stress` (also the meter `tone` names) | `#fa5246` `#5dbbf7` `#5de395` `#f5a623` `#4fd1e8` `#9fd8ff` `#b68cff` |
| rarity | `text-rarity-common` `text-rarity-uncommon` `text-rarity-rare` `text-rarity-epic` `text-rarity-legendary` | `#aeb6bf` `#5de395` `#5dbbf7` `#b68cff` `#f5a623` |
| shape | `rounded-ui` `rounded-ui-sm` `rounded-ui-xs` · `shadow-ui` `shadow-ui-sm` `shadow-ui-lg` `shadow-glow` `shadow-glow-sm` · `ease-ui` | 6 / 4 / 3 px · the panel shadows · the coral selection glow · `cubic-bezier(.22,.61,.36,1)` |
| type | `font-sans` `font-display` `font-mono` · `text-ui-xs` `text-ui-sm` `text-ui` `text-ui-lg` · `text-display-sm` `text-display` `text-display-lg` `text-display-xl` · `tracking-display` `tracking-label` `tracking-eyebrow` | Barlow · Barlow Condensed · Cascadia Mono · 11 / 13 / 15 / 17 px · 18 / 24 / 34 / 48 px · 0.04 / 0.14 / 0.32 em |
| motion | `animate-core-fade-in` `animate-core-slide-in` `animate-core-pop-in` `animate-core-slide-up` `animate-core-spin` `animate-core-shimmer` `animate-core-pulse` | the kit's entrances and loops |
| recipes (`:root`, not utilities) | `--core-grad-accent` `--core-grad-accent-fade` `--core-grad-accent-fade-out` `--core-grad-sheen` · `--core-accent-rgb` (and `-ink-` `-panel-` `-error-` `-success-` `-warning-` `-info-`) · `--core-h-sm` `--core-h-md` `--core-h-lg` · `--core-focus` | the two accent gradients + the panel sheen · `r g b` triplets, because alpha is written `rgb(var(--core-accent-rgb) / 0.16)` · control heights 30 / 40 / 52 px · the focus halo |

Three type voices carry the whole look and exist as classes too: `core-display` (700, tight tracking),
`core-label` (600, 12 px, 0.14 em) and `core-eyebrow` (500, 13 px, 0.32 em — the wide subtitle under a
heading), next to `core-title`, `core-text`, `core-flavor` and `core-num` (tabular figures).

#### Rules for a page

- **Compose, do not restyle.** Reach for a `<Core…>` tag first; write custom CSS only for what the kit
  lacks, and then over the tokens — **never a literal colour, font family or radius** in a page.
- **Utilities win.** The kit's classes are imported into the `components` layer, so `class="w-full mt-4"`
  on a kit tag always beats the kit's own rule. Layout utilities (`flex`, `gap-*`, `min-w-0`) are fine;
  colour and type belong to the kit.
- **Chromium 103.** No `:has()`, no `color-mix()`, no CSS nesting, no container queries, no `dvh`, no
  Popover API, no `calc(infinity)`, no `oklch()`. Tailwind's `translate-*` / `rotate-*` / `scale-*`
  utilities emit the individual transform properties (Chrome 104+) and silently do nothing in game —
  write `[transform:translateX(-50%)]`.
- **Glass is a prop.** `blur` on CorePanel, CoreScreen / CoreBackground, CoreDialog, CoreDrawer and
  CorePopover sets `data-core-blur` (`true` = `Config.UI.Blur.Strength`, a number = that radius). Panels
  only, ≤ 12 on screen, never on rows, slots, chips or list items — every consumer costs a canvas copy
  per frame (next section).
- **Never use `backdrop-filter` / `-webkit-backdrop-filter` or Tailwind's `backdrop-*` utilities** — the
  game frame is not part of the CEF's compositing surface, so FiveM paints the filtered area as a solid
  black box. That ban is absolute; `data-core-blur` is the replacement.
- **The shell is click-through.** Interactive kit roots set `pointer-events: auto` themselves; a plain
  `<div>` of your own that must take the mouse needs `core-interactive`.

#### Re-theming

A server changes the whole shell's colour by overriding five values — everything else is derived:

```css
:root {
    --color-accent: #f6503f;  --color-accent-hi: #ff6351;  --color-accent-lo: #d53e2f;
    --color-accent-soft: rgba(246, 80, 63, 0.16);
    --core-accent-rgb: 246 80 63;                                   /* alpha recipes read this */
    --core-grad-accent: linear-gradient(90deg, #ff5a49 0%, #f6503f 45%, #ee4339 100%);
    --core-grad-accent-fade: linear-gradient(90deg, #fd5443 0%, #f6503f 18%, rgb(246 80 63 / 0.18) 100%);
    --core-grad-accent-fade-out: linear-gradient(90deg, #fd5443 0%, #f6503f 16%, rgb(246 80 63 / 0.04) 100%);
}
```

#### Icons and fonts

`ui/src/kit/icons.js` ships 185 filled glyphs on a 24 × 24 grid (path data from Material Design Icons,
Apache-2.0). Every `icon` prop takes a registry name **or** raw path data, and a plugin adds its own:

```js
import { registerIcons } from '@core/ui'
registerIcons({ 'my-icon': 'M12 2 2 22h20L12 2z' })   // then icon="my-icon"
```

`Barlow` and `Barlow Condensed` are bundled as woff2 in `ui/src/kit/fonts/` (SIL OFL 1.1, `OFL.txt` next
to them) because the CEF has no network — never add a web font, a CDN or an `@import url(...)`.

#### Tailwind mechanics

The CSS is **Tailwind CSS v4**, CSS-first: `@tailwindcss/vite` and one entry stylesheet per bundle. No
`tailwind.config.js`, no PostCSS. The tokens themselves live in **one** file, `ui/sdk/theme.css`, which
contains nothing but `@theme static` blocks (Tailwind refuses `theme(reference)` on anything else); core's
`ui/src/styles.css` imports it next to the `:root` recipes and the ten kit partials, and every plugin build
references the same file.

Core's sheet starts with `@import "tailwindcss" source(none)` plus explicit `@source` lines. That is
deliberate: Tailwind's automatic source detection walks up to the workspace root and would quietly compile
every plugin's utilities back into core's bundle. A plugin's own sheet is generated by `coreUI()` from a real
file (`<plugin>/ui/.core-ui/entry.css`) and emits only the utilities that plugin uses.

A scoped `<style>` block is compiled on its own, so `@apply` inside one needs the theme pointed out first —
by package specifier, from anywhere:

```css
@reference "@core/ui/reference.css";
```

It emits nothing; only the tokens are read. Utilities in the template need no `@reference`. Token utilities
compile to `var(--color-panel, <fallback>)`, so a server re-theme still wins inside a plugin's bundle, and
opacity modifiers (`bg-error/15`) are safe — Tailwind emits a literal fallback colour first and keeps the
`color-mix()` behind `@supports`, so Chromium 103 paints the fallback (`coreUI()`'s lint accepts exactly that
form and still fails a hand-written, unguarded `color-mix()`).

#### Checking a page

```bash
cd core/ui
node tests/kit-compile-check.mjs ../../my_plugin/ui/src/Page.vue   # compiles the SFC + the CEF lint, no build
npm run dev                                                        # Vite on 5173: index.html is the live shell
#   http://localhost:5173/kit-preview.html?scene=<SceneName>&bg=game|keyart|menu|ink — one kit scene, no Storybook
npm run storybook                                                  # Kit/… stories: every component, every state
cd ../../my_plugin/ui && npm run typecheck                         # vue-tsc over the plugin's own sources
```

`node core/ui/scripts/check-plugins.mjs` (also `npm run check:ui` at the resources folder) validates every
plugin at once: duplicate plugin ids, duplicate page ids across resources, a `dist` older than its `src`, and
manifests that do not validate.

Three browser suites guard the shell — run them together with `node ui/tests/run-browser-suites.mjs`, which
builds the fixture plugins, starts one HTTP origin per fixture resource with FiveM's exact headers and drives
all three through agent-browser: `shell-regression.js` for the built-ins and the protocol (101 checks),
`kit-regression.js` for the kit (195 — every catalogue name mounts without a Vue warning, the interactive
contracts hold, the fonts resolve, no rule in the built CSS uses a Chromium-103-unsafe feature), and
`runtime-regression.js` for the platform itself (152 — cross-origin load, hot deploy, restart with a new
build, lazy load, every failure mode, modal layering, feeds).

### Game blur (glass panels)

A CSS filter cannot see the game, but FiveM's NUI core can: it hooks `glTexParameterf` and binds the
game's back buffer to a WebGL texture — the same hook the FiveM main menu draws its own blurred
background with. core copies that frame into one small hidden canvas `Fps` times a second, and behind
every element carrying `data-core-blur` it inserts a `.core-glass` wrapper (`z-index: -1`, inset 0)
holding a blurred crop of it. The wrapper paints the panel colour itself, so a glass panel looks like
the normal one with the game showing through, border and all.

```vue
<CorePanel blur>                                               <!-- Config.UI.Blur.Strength -->
<CorePanel :blur="18">                                         <!-- 18 px, this panel only -->
<section class="core-panel" data-core-blur>                    <!-- the same thing without the kit -->
<section class="core-panel" data-core-blur="0">                <!-- no glass on this panel -->
<section class="core-panel" data-core-blur style="--core-glass-tint: rgba(20, 14, 14, 0.66)">
```

A page needs **no JavaScript at all** — the attribute is the whole API (the kit's `blur` prop only
sets it), and it works on an element that appears later. `--core-glass-tint` on the element overrides
the panel colour the wrapper paints (default `--color-panel-glass`, `rgba(11,17,22,.64)`).

Each consumer costs one small canvas copy per frame, so put it on **panels, never on list rows** or
per-item elements, and keep **12 or fewer on screen** — core's own ten built-ins (the three modals,
the HUD box, the stat bars, each toast, the text UI pill, the progress box, the key hints and the
spinner) already carry it. The loop runs only while the blur is enabled, at least one consumer is
visible, the shell is visible (§31) and the tab is not hidden; otherwise it stops completely.

| `Config.UI.Blur` key | default | what it does |
|---|---|---|
| `Enabled` | `true` | draw the glass at all; `false` removes every wrapper and stops the loop |
| `Strength` | `4` | blur radius in CSS px (0–40) — the default for an attribute without a value; tune it in-game with `/uiblur` first |
| `Fps` | `30` | copies per second (5–60); `setTimeout`, never a full-rate `requestAnimationFrame` |
| `Scale` | `0.5` | resolution of the copy (0.1–1). It is blurred anyway, so half is plenty |

```lua
Core.UI.setBlur(false)   -- client; session-scoped override of Enabled, re-sent on a NUI reload
Core.UI.setBlur(true)    -- back on; returns true
Core.UI.setBlur(true, { strength = 3, scale = 0.5, fps = 30 })   -- numeric overrides of the tunables
-- in-game tuning without a restart: /uiblur (prints), /uiblur off|on, /uiblur 3 [0.5] [30]
-- /uiblur diag prints the shell's blur state to the F8 console (mode live|fallback|off, probe pixels,
-- the first panel's copied pixel); /uiblur test runs the hook-recipe experiment (DESIGN §32.2)
```

Outside the CEF (a browser, this repo's Storybook) there is no hook: core probes once and falls back
to a procedural gradient so the effect stays visible while you build a page. `<html>` reports which
one is running — `data-game-blur="live" | "fallback" | "off"`.

## Hooks, events and state bags

Hooks are local events on the same side: `Core.on('playerLoaded', fn)` / `Core.emitHook('name', …)` (§8).

| side | hook | args |
|---|---|---|
| server | `ready` | — |
| server | `playerLoaded` / `playerSaved` / `playerDied` / `playerRespawned` | `src` |
| server | `playerDropped` | `src, charId` (before the session is removed) |
| server | `moneyChanged` | `src, account, amount, delta, reason` |
| server | `factionChanged` / `factionUpdated` | `src, summary\|nil` / `factionId` |
| server | `vehicleSpawned` / `vehicleDeleted` | `netId, info` / `netId` |
| server | `audit` | `category, src, message` |
| client | `ready` / `playerLoaded` / `playerDied` / `playerRespawned` / `uiReady` | — |
| client | `pedChanged` | `ped, previous` — the player's ped entity changed (model swap, spawn); re-apply ped-bound state (config flags, attachments) here. Not replayed for a resource that starts later |

State bags are server-written, client-read. Read them with `Core.Player.get(key)` or `Entity(veh).state.x`.

| bag | keys |
|---|---|
| `player:<src>` | `loaded` `name` `charId` `group` `cash` `bank` `faction` (summary or `false`) `dead` |
| `entity:<netId>` (core vehicles) | `coreVeh` `locked` `owner` `keys` `keyMode` `plate` `vehId` `coreProps` (optional persisted props) |
| `GlobalState` | `core:ready`, `faction:<id>` = `{ name, tag, color, memberCount }` or `false` |

## Commands

| command | perm | what it does |
|---|---|---|
| `/id` · `/players` | — | your server id + name · connected players (≤ 20 listed) |
| `/car <model> [plate]` · `/dv` | `core.admin` | spawn a vehicle and warp in · delete the one you are in or the nearest within 5 m |
| `/tp <x> <y> <z>` · `/tpm` · `/tpto <player>` · `/bring <player>` | `core.admin` | teleport to coords · to your waypoint · to a player · a player to you |
| `/setcash` `/setbank` `/givecash` `/givebank` `<player> <amount>` | `core.admin` | set or add money |
| `/setgroup <player> <group>` | `core.admin` (console always) | `user` / `mod` / `admin` |
| `/kick <player> [reason…]` · `/ban <player> <hours> [reason…]` | `core.mod` / `core.admin` | `0` hours = permanent |
| `/announce <message…>` · `/revive [player]` · `/heal [player]` | `core.mod` | broadcast · respawn where they stand · health + armour |
| `/faction <action> …` | — | chat front-end over `Core.Factions` |

`/faction create <name> <tag>` · `invite <player id>` · `accept` · `leave` · `kick <charId>` ·
`rank <charId> <rank>` · `info` · `list`. Disband and the rest of the API are the §5.2 callbacks, for a faction UI plugin.

## Wave 2 APIs

Same access as §4/§6 — through the proxy, from any plugin VM. Server-side unless a row says *(client)*.

### Server-driven world controllers (§15)

Markers, blips, text labels and interactions defined **on the server** — for everyone (`addGlobal`) or
for one player (`addFor`). The handlers stay in your server VM, so an interaction never has to trust what
the client claims. Option shapes are the client ones (§6.4–§6.7), minus entity/models.

| function | notes |
|---|---|
| `Core.Markers.addGlobal(opts)` · `addFor(src, opts)` | returns an id string, `nil` on a bad payload |
| `Core.Blips` · `Core.TextLabels` · `Core.Interactions` | the same four functions each |
| `Core.<Kind>.updateGlobal(id, partial)` · `removeGlobal(id)` | work on `addFor` ids too; handlers can be replaced |

Interactions also take `onInteract(src, ctx)`, `onEnter(src, ctx)`, `onExit(src, ctx)`,
`canInteract(src) -> bool` (asked once on enter; an error in it denies) and `cooldown` (ms per player,
default 500). `ctx` is `{ id, coords, distance, data }`. Entries belong to the resource that created
them, so stopping it removes them; clients get a snapshot on `playerLoaded` and one delta per change.

```lua
Core.onReady(function()                                      -- replayed after a core restart
    Core.Interactions.addGlobal({
        coords = vector3(25.7, -1347.3, 29.5), radius = 2.0, label = 'Empty the register', cooldown = 2000,
        marker = { type = 1, size = vector3(1.2, 1.2, 0.5), color = { 255, 90, 90, 140 }, offsetZ = -0.9 },
        canInteract = function(src) return Core.Perms.has(src, 'core.mod') end,   -- asked once, on enter
        onInteract = function(src, ctx)                      -- runs ON THE SERVER
            Core.Money.add(src, 'cash', 250, 'register')
            Core.Notify.send(src, ('$250 from %s'):format(ctx.id), 'success')
        end,
    })
end)
```

### Doors (§16)

| function | purpose |
|---|---|
| `Core.Doors.register(opts) -> id` · `unregister(id)` · `get(id)` · `list()` | `{ id, model, coords, locked, perms, autoLockMs?, meta? }`; persisted, and re-`register` keeps the stored `locked` |
| `setLocked(id, locked, src?) -> bool` · `toggle(src, id) -> bool, err` | force · the permission-checked path |
| `canUse(src, id) -> bool` · `getNearest(src, radius = 3.0) -> id\|nil` | |
| `Core.Doors.tryToggleNearest()` *(client)* | what the interact key calls within `Config.Doors.InteractDistance` |

`perms` entries are `'core.admin'`, `'faction:<id>'` or `'faction:<id>:<minRank>'`; an empty list means
anyone. State rides on `GlobalState['door:<id>']`. Hooks: `doorLocked` / `doorUnlocked` `(id, src|nil)`.

**Is it the right door?** A door whose `model` does not match the object at `coords` controls nothing.
Two safety nets: the client warns once per session in the F8 console (`door <id>: no object with model …`)
as soon as the area is streamed in, and `/doorfind` prints the model hash, coords and heading of the object
you look at (or the nearest one within 3 m), tells you whether a registered core door sits there and whether
its model matches, and prints a ready `Core.Doors.register` line. Paste the printed number as `model = <hash>`;
a name works too when you know it.

### World, Screen, Cron (§17)

| function | purpose |
|---|---|
| `Core.World.setTime(h, m, s?)` `getTime()` `freezeTime(bool)` `isTimeFrozen()` | the global clock |
| `Core.World.setWeather(type, transitionSec = 15)` `getWeather()` | `type` is validated against `Config.World.Weathers` |
| `setTimeFor(src, h, m)` `clearTimeFor(src)` `setWeatherFor(src, type, sec)` `clearWeatherFor(src)` | per-player override, targeted |
| `Core.Screen.fade/unfade/blur/unblur(src, ms)` | screen fades and blur |
| `Core.Screen.effect(src, name, ms, looped)` `clearEffect` `clearEffects` `timecycle(src, name, strength?)` `clearTimecycle` | animpostfx and timecycle |
| `Core.Player.setControls/setFrozen/setInvincible/setVisible(src, bool)` | ped control |
| `Core.Player.setHealth/setArmour/getHealth/getArmour(src)` | server natives where they exist |
| `Core.Cron.every(intervalMs, fn, opts?)` `at(h, m, fn)` `schedule('*/5 * * * *', fn)` `remove(id)` `list()` | the three adders return an id; `every` has a 1000 ms floor, `at`/`schedule` use the server wall clock |

`Config.World.TimeScale` is game seconds per real second (`30` = a 48-minute day); the clock writes
`GlobalState['core:time']` only when the game minute changes, and `Config.World.WeatherCycle` (`nil` =
manual) drives weather. Hooks: `timeChanged (h, m)`, `weatherChanged (type)`.

### Stats (§18)

| function | purpose |
|---|---|
| `Core.Stats.get(src, name)` `getAll(src)` `set` `add` `sub` `reset(src, name?)` `define(name, def)` | stored in `data.stats`, clamped to the def; `define` runs at start, before players load |
| `Core.Stats.get(name)` `getAll()` `onChange(fn)` *(client)* | reads `LocalPlayer.state.stats`, no hop |

Defs live in `Config.Stats.Defs` (`min`, `max`, `default`, `decayPerMinute`, `thresholds`, `hud`); one
thread decays every player once per `Config.Stats.TickMs`, and `hud = true` puts a bar in the HUD. Hooks:
`statChanged (src, name, value)` (never on decay) and `statThreshold (src, name, threshold, value)`.

### Weapons (§19)

| function | purpose |
|---|---|
| `Core.Weapons.give(src, weapon, ammo = 0, opts?) -> bool` | `opts.tint`, `opts.components`; persisted in `data.weapons` |
| `remove(src, weapon)` `clear(src)` `setAmmo` `addAmmo` `has(src, weapon)` `getLoadout(src)` `apply(src)` | `apply` pushes the whole loadout; it already runs on spawn and respawn |

Names are `WEAPON_*`, checked against `Config.Weapons.Allowed` when that list is set. The client sends
an ammo snapshot every `Config.Weapons.SnapshotIntervalMs`; the server only lets ammo go **down** from
it, so increases always come from `addAmmo`. Hook `weaponsChanged (src)`.

### Remote player control (§20)

| function | purpose |
|---|---|
| `Core.Native.invoke(src, name, …)` · `invokeWithResult(src, name, …)` | allowlisted by `Config.Native.Allow` (`nil` = any global matching `^%u[%w_]+$`) |
| `Core.Anim.play(src, dict, clip, opts?)` · `Core.Anim.stop(src)` | drives the client `Core.Anim` lib (§3.10) |
| `Core.Audio.playFrontend(src, name, set)` · `playAt(coords, name, set, range?)` | `playAt` reaches everyone in range (≤ 20 targets); the same without `src`, plus `stop(id)`, is the `lib/audio` namespace *(client)* |
| `Core.Attachments.add(src, { id?, model, bone, offset, rotation })` `remove(src, id)` `clear(src)` `list(src)` | persisted in `data.attachments`, replicated so **every** client sees the prop |
| `Core.Waypoint.set(src, coords)` `clear(src)` `get(src)` · `Core.Raycast.fromPlayer(src, distance = 10.0) -> hit, coords, netId` | `get` and the raycast await the client |
| `Core.Screenshot.take(src, opts?) -> url\|nil` | needs `screenshot-basic` started, otherwise `nil, 'unavailable'` |
| `Core.Player.setReplicated(src, key, value)` | your own `Player(src).state` keys; core's §8 keys are refused |

### Server-side UI (§21)

Every built-in from the "UI" section above, callable **from the server** with a `src` in front. The
awaiting ones block the server coroutine until that one player answers, so call them from a command,
a net handler or a thread — never at file scope.

```lua
local pick = Core.UI.menu.open(src, { title = 'Shop', items = { { label = 'Snack', value = 'snack' } } })
if pick == 'snack' then Core.UI.shard(src, { title = 'Bought', style = 'success' }) end
```

| function | purpose |
|---|---|
| `Core.UI.open(src, id, props?)` `close(src, id?)` `send(src, id, event, data)` | plugin pages, driven from the server |
| `Core.UI.update(src, id, partial)` · `Core.UI.patch(src, id, path, value)` (§38.10) | shallow-merge top-level keys · set one value (`nil` deletes); same queue, same 1-based Lua-view paths as the client form |
| `Core.UI.notify(src, …)` · `textUI.show(src, key, text, opts?)` / `textUI.hide(src)` | alias of `Core.Notify.send`, and the bottom pill |
| `Core.UI.progress(src, opts) -> bool` · `menu.open(src, opts) -> value\|nil` | awaits; `nil`/`false` means ESC, cancel or timeout |
| `Core.UI.input.open(src, opts) -> values\|nil` · `alert(src, opts) -> bool` | awaits |
| `Core.UI.keys.show(src, { { key = 'E', label = 'Interact' }, … })` / `keys.hide(src)` | instructional buttons |
| `Core.UI.shard(src, { title, subtitle?, duration = 4000, style = 'wasted'\|'success'\|'info' })` · `spinner.show(src, text)` / `spinner.hide(src)` · `hud.setVisible(src, bool)` | the big centre card, the spinner, the HUD toggle |
| `Core.UI.hide(src, reason?)` / `Core.UI.show(src, reason?)` (§31) | hide the whole shell for one player — stored client-side as `server:<reason>`; see "Visibility" under UI |

The same `keys`, `shard`, `spinner` and `hud` calls exist on the client without the `src`. The HUD now
also shows health, armour, speed, street/zone and a bar per `hud = true` stat.

### Getters, Globals, Services, Api, Perms (§22)

| function | purpose |
|---|---|
| `Core.Player.getClosest(src, maxDist = 50.0) -> src, dist` · `getInRange(coords, range)` | |
| `Core.Player.findByName(name)` `findByPartialName(part)` `getInVehicle(netId)` `isNear(src, coords, range)` `getStreet(src)` | `getStreet` awaits the client |
| `Core.Vehicles.getInRange(coords, range)` `getDriver` `getPassengers` `getClosestToPlayer(src, maxDist = 20.0)` `setData(netId\|vehId, key, value)` / `getData` | core vehicles only; `setData` writes record meta |
| `Core.Globals.get(key, default?)` `set(key, value, mirror?)` `increment(key, delta = 1)` `unset(key)` | persisted server-wide; `mirror = true` also writes `GlobalState['g:<key>']` |
| `Core.Services.register(name, impl)` `get(name)` `has(name)` `unregister(name)` · `Core.Api.register(name, table)` / `Api.get(name)` | swappable interfaces · plugin-to-plugin tables |
| `Core.Perms.grant(src, perm, scope = 'account'\|'character')` `revoke(src, perm, scope)` `list(src)` | on top of ACE and the config group |

Core registers `notification`, `currency`, `death`, `time` and `weather` itself; `items` stays empty until
an inventory plugin fills it — write against `Core.Services.get('items')` and any inventory works.

**Proximity is indexed, not looped (§22.1).** `getClosest`, `getInRange` and every proximity chat route go
through `server/playergrid.lua`, a server-side grid of `Config.World.PlayerGridSize` (128 m) cells that one
staggered thread refreshes — two natives per player, every player once per 2 s. A query takes the players of
the cells the circle touches (plus 64 m of slack for that staleness) and then does the **exact** distance test
with live coordinates, so results are unchanged; at 1,000–2,000 players it just no longer costs three natives
per player per call. `Core.PlayerGrid` is internal (blocked in the export like `Core.Registry`): use the
getters. A player who teleports further than 64 m can be missed by a query for at most one refresh period.

### Vehicle records and key modes

`Core.Vehicles` owns the live entity and its generic record, including the complete property payload (custom colors, extras, liveries, wheel/mod/toggle maps, dirt, tyre health/bursts, doors, window intactness and lights). `stored = true` means deliberately garaged; `stored = false` means the vehicle belongs in the world. A clean core stop preserves that world state and captures the final server position before deleting only the obsolete runtime entity. A domain plugin restores out records with `restoreRecord`, which refuses stored records and duplicate vehIds. `adopt` promotes an existing network vehicle (for example, a server-validated hotwired ambient car) into the same server-owned persistent contract. Restored props are projected through `coreProps` and refreshed only when a validated saved-property payload changes, so any client that streams the vehicle can apply them even if its owner is offline. Property maps use GTA's zero-based native ids and safely survive JSON round trips. Plates are trimmed/uppercased and unique across both stored records and live entities; the default `LS-` prefix produces values such as `LS-48291`. GTA cannot distinguish a lowered window from a broken one through `IsVehicleWindowIntact`, so both persist as non-intact. `spawn` defaults to `keyMode = 'virtual'`, which inserts the owner into the replicated `keys` map and keeps existing `U` lock behaviour. A domain plugin that issues a physical inventory key must spawn with `keyMode = 'item'`: core still records the owner, but grants no virtual key. Core's `U` route then no-ops without a misleading error, allowing that plugin to bind `U` and validate the actual item before calling `Core.Vehicles.setLocked`.
`Core.Api` hands a live table across resources, so **every call costs two msgpack hops**: fine for wiring,
never for per-frame work. A table leaves `Api.get` the moment its owning resource stops.

### Chat (§23)

Core's chat is its own CEF feed + input (shell `Chat.vue`, `client/chat.lua`, `server/chat.lua`); the stock
`chat` resource is **not needed**. Stop it with `stop chat` in the server console and remove its startup
entry (including any resource-group startup that includes it). Its independent NUI competes for `T`;
cancelling `chatMessage` cannot hide it. Core separately disables **GTA's native multiplayer text chat**
on startup/NUI reload and restores it when core stops. No per-frame control polling is used.

The feed is top-left, unboxed, and fades after eight seconds without activity. `T` restores history
at full opacity and opens a slim keyboard-only input. New messages wake the feed. Controls:

- `/` opens a filtered command list **below** the input, with descriptions and argument signatures.
- `↑` / `↓` selects a command without changing your text; `Tab` accepts, `Shift+Tab` selects backwards.
- `Enter` completes a partial/selected command first; otherwise it sends. `Esc` cancels.
- After `/command `, the argument at your caret is highlighted with help, type and optional/required
  status. Quoted arguments and multiword `rest` parameters are supported; Tab never overwrites plain text.
- Without a command list, `↑` / `↓` recalls sent history, restoring your unsent draft when returning down.
  `PageUp` / `PageDown` scrolls received history. `Ctrl+Tab` / `Ctrl+Shift+Tab` changes channels.

Core and plugin `Core.Commands` registrations supply the metadata; server permissions still decide
which commands/channels are shown and allowed. Each open refreshes the snapshot (rate-limited), and
stopped plugins lose their suggestions. Raw `RegisterCommand` registrations need `Core.Commands.register`
to appear with typed hints; the engine still executes them normally. No guessed player-name completion.

| function | purpose |
|---|---|
| `Core.Chat.send(src, message, opts?)` | `opts = { color = {r,g,b}, prefix = 'SYSTEM', channel? }` — one CEF line |
| `Core.Chat.broadcast(message, opts?)` · `sendNear(coords, range?, message, opts?)` | announcements / proximity (each recipient gets their own opacity) |
| `Core.Chat.registerChannel(name, { command, permission?, format, global?, staffOnly?, faction?, color?, range?, description? })` | adds the `/command` for you |
| `Core.Chat.setFilter(fn(src, channel, msg) -> bool)` | returning `false` vetoes the message |
| `Core.Chat.clear(src)` | wipes one player's feed |
| `Core.Chat.suggestions(src)` | permitted channel commands with descriptions and message-argument metadata |
| `Core.Commands.get(name)` · `execute(name, src, args, raw)` (server) · `suggestions(src)` | the command seam the CEF input uses (§30.2) |

Built-in channels: plain text → **local** (proximity, fades with distance), `/ooc` (global), `/fc`
(faction members only — the chip only appears for faction members), `/s` scream (doubled range, always
full opacity, rendered louder), `/me` (nearby action), `/a` staff (needs `core.mod`) and `/pm <id>
<message…>`. A `/command` typed into the input runs through the engine's command path (client
`ExecuteCommand`; server commands execute with the player's identity and core's permission wrapper —
never as console). Core also sends join/leave system lines and owns console `say`. Hook:
`chatMessage (src, channel, msg)`.

### Http and Webhook (§24)

| function | purpose |
|---|---|
| `Core.Http.fetch(url, { method, body, headers, timeoutMs = 10000 }) -> status, body, headers` | awaits; table bodies are JSON-encoded, JSON responses decoded |
| `Core.Http.route(method, path, handler(req) -> status, body, headers?)` | endpoints on the server's own port; `req = { method, path, query, headers, body }` |
| `Core.Http.setToken(name, convarName)` · `getToken(name)` · `Core.Webhook.send(name, { title, description, color, fields })` | secrets come from convars only; the embed goes to convar `core_webhook_<name>` |

Webhook posts are batched (at most one request per 2 s per webhook, up to 10 embeds), and core mirrors
the `audit` hook into `core_webhook_audit` automatically when that convar is set.

### Security (§25)

`Config.Security` is the whole surface: `EntityLockdown`, `EnforceLoadout`, `BlockExplosions`,
`MaxWeaponDamageMultiplier` + `WeaponDamage[hash]`, `KickOnDetect`. Core watches `weaponDamageEvent` and
`explosionEvent`, always using the server-provided `sender`, never a player id from the payload.
`Core.Security.setDamageFilter(fn(sender, data) -> bool)` vetoes a damage event before the built-in
checks. Hooks: `weaponDamage (sender, data)`, `explosion (sender, data)`, `cheatDetected (src, kind, details)`.

### Locale (§26)

```lua
Core.Locale.t('greeting', { name = 'Liam' })   -- your locales/en.json first, then core's; '{{name}}' substituted
```

`t(key, vars?)` resolves your resource's `locales/<lang>.json` → core's → `Config.Texts` → the key
itself, so a missing translation degrades instead of erroring; `setLanguage`, `has`, `getLanguage` and
`all` round it out. List `'locales/*.json'` in your `files {}` and use `{{var}}`, not `%s`.

### DB tools (§22, §27)

| function | purpose |
|---|---|
| `Core.DB.nextId(name) -> integer` | a persistent counter, for human-readable ids |
| `Core.DB.migrate(collection, version, fn(doc) -> doc)` | register at start; runs once per collection, documents carry `_v` |
| `Core.DB.export(path?) -> path` · `import(path, mode = 'merge'\|'replace') -> count` | JSON under `core/data/` |

`Config.DB.Adapter = 'mysql'` swaps the KVP store for `server/db_mysql.lua` (oxmysql, table
`core_documents`), falling back to KVP with an error line when oxmysql is not started. **That adapter has
never run against a real database** — it follows oxmysql's documented `query_async`/`execute` shape and is
untested. Verify the export names against the version you deploy, and take a `/dbexport` before switching.

### New commands

| command | perm | what it does |
|---|---|---|
| `/weapon <player> <WEAPON_NAME> [ammo]` · `/weapons clear <player>` | `core.admin` | give a weapon (persisted in the loadout) · wipe a loadout |
| `/dbexport` · `/dbimport <file> [replace]` | console only | writes `data/export-<timestamp>.json` · reads one back; `replace` wipes each collection first |
| `/uiplugins` · `/uidev <res> <origin\|off>` · `/uiinspect` | client; the last two need `Config.UI.Dev.Enabled` | the UI platform's diagnostics — see "Knowing whether a plugin is up" |

### Tooling (§27)

```bash
core/scripts/new-plugin.sh shop_robbery   # scaffolds ../shop_robbery from templates/plugin, ui/ included
core/scripts/check.sh [--full]            # the gate before a deploy (--full adds the browser suites + Storybook)
npm run check:ui                          # at the resources folder: validate every plugin's ui/dist
```

`new-plugin.sh` validates the name (`^[a-z][a-z0-9_]*$`), refuses to overwrite an existing resource,
rewrites every placeholder and prints the next steps. `check.sh` stops at the first failure, in nine steps:
`luac5.4 -p` over every `.lua`; `fxlint` on core and `core_example` (skipped with a notice when it is not on
`PATH`); the Lua suites (`run_tests`, `client_chat_tests`, `client_interiors_tests`, `client_ui_tests`,
`server_tests`); `node --test` over the chat model, `ui/tests/unit` and `ui/sdk/tests`;
`vue-tsc --noEmit -p ui/tsconfig.json`; `gen-kit-types --check` and `check-plugins.mjs`; the shell build; and
with `--full` the three browser suites (`ui/tests/run-browser-suites.mjs`) plus the Storybook build.

`.github/workflows/core-ci.yml` runs the same thing on every push and pull request (Ubuntu, Lua 5.4,
Node 22, `npm ci` at the workspace root, then the syntax loop, the suites and the UI + Storybook
builds). fxlint is deliberately **not** in CI: it needs the local native database, so it stays local.

`types/core.lua` types every namespace above for the Lua Language Server and `../.luarc.json` wires it
up — see "Editor support (LuaLS)" below.

## In-game test checklist

`resmon 1` needs the client started with `+set moo 31337`. Steps 3, 4, 7 and 8 are the negative tests: they must *fail quietly*, with nothing changed server-side.

1. Fresh join → you spawn at LSIA arrivals, the HUD shows your name, id, `$5,000` cash / `$25,000` bank, and a `core_example loaded` notification appears (the `playerLoaded` hook).
2. `/car adder` as an admin → the car spawns and you are warped in; press `U` → "Vehicle locked" notify and the doors lock, `U` again unlocks.
3. **No keys:** a second player stands at your car and presses `U` → "You have no keys for this vehicle"; the doors do not move.
4. **No permission:** a player without `core.admin` runs `/car adder` → a "You are not allowed to do that" notification and no vehicle; the same for `/tp`, `/setcash` and `/ban`.
5. Walk toward the Strawberry 24/7 → a blip on the map, the cyan marker within 30 m, the "Example 24/7" label within 15 m, the `[E] Buy a snack ($5)` pill within 2 m.
6. Press `E` → a 2 s progress bar → cash −$5, +25 health, a notification; press `X` during the bar → it cancels and nothing is charged.
7. **Distance:** stand ~10 m away and run `TriggerServerEvent('core_example:server:buySnack')` in `F8` → nothing happens, no money moves, no error.
8. **Cooldown:** stand in the marker and spam `E` for 10 s → at most one purchase per second, the rest is dropped silently, no kick and no duplicate charge.
9. Press `F5` (or `/example`) → the page opens with a cursor and your HUD values; `ESC` → it closes and the cursor is gone.
10. `restart core_example` while the page is open → the page closes, focus is released, and the blip, marker, label and interaction all disappear with no leftovers.
11. `/faction create Test TST` → $25,000 leaves the bank and the HUD shows `TST`; invite a second player, they run `/faction accept` → both see it; `/faction leave` clears it.
12. Die → "Respawn in 8 s" counts down → you respawn at the nearest hospital and `dead` goes false; `/revive <id>` from the console works too. Then reconnect → position, money and faction persisted; `restart core` while online → **no** re-spawn, HUD refreshed, core_example's registrations back. Finally `resmon 1`: idle far away `0.00–0.02 ms`, standing in the marker `< 0.06 ms`.

Wave 2 (§15–§26). Steps 13 and 15 are the negative tests — same rule: they must fail quietly. The FXServer console cannot evaluate Lua, so where a step calls a `Core.*` function, wrap it in a throwaway `Core.Commands.register` in `core_example/server/main.lua` first.

13. **Door, with and without permission:** walk into the Mission Row police station and to the `example_backroom` door from the lobby to the back offices (`450.10, -985.74, 30.84`), look at it and run `/doorfind` — it must say the model matches → the `[E] Lock / unlock door` pill appears within 2 m. As `core.mod`, press `E` → the door unlocks, `E` again re-locks it, and a second player standing there sees the door move too (it rides on `GlobalState`). Without `core.mod` → "You do not have access to this door" and the door does not move. Then `restart core` → the lock state is back as you left it.
14. **Server-driven interaction:** step into the orange marker 3 m east of the 24/7 (`Server-side snack ($5)`) and press `E` → cash −$5, a green **YUM / Server-side snack** shard, and `server snack for <id> at … m` in the *server* log (`fxserver logs --resource core_example`, needs `Config.Debug`). The handler ran on the server; the client only reported the press.
15. **Server-side distance and cooldown:** from ~10 m away run `TriggerServerEvent('core:server:worldInteract', '<id>')` in `F8` → nothing happens, no money moves. Spam `E` in the marker for 10 s → at most one purchase per second.
16. **Weapons persist:** `/weapon <your id> WEAPON_PISTOL 50` → the pistol appears with 50 rounds. Fire ~10, wait for the 60 s snapshot (or die), then `/quit` and reconnect → the pistol is back with the *reduced* ammo. `/weapons clear <your id>` → it is gone and stays gone after a relog. Bonus negative: `/weapon` as a non-admin → "You are not allowed to do that".
17. **Time and weather for everyone:** with a second player connected, `Core.World.setTime(2, 0)` and `Core.World.setWeather('THUNDER', 5)` → **both** clients go to 02:00 and roll into thunder within ~5 s. `Core.World.setWeatherFor(<id>, 'XMAS', 2)` changes that one player only, `clearWeatherFor` puts them back, and `Core.World.freezeTime(true)` stops the clock for everyone.
18. **Stats decay and thresholds:** watch the hunger/thirst bars in the HUD — they drop by `decayPerMinute` every `TickMs`. Put one just above a threshold (`Core.Stats.set(<id>, 'hunger', 26)`) and let it decay past 25 → the threshold notification fires **once**, not every tick. Buy a snack → hunger jumps +20 and the bar follows immediately.
19. **Chat channels (CEF):** stop the stock `chat` resource, then press `T` → only core's slim top-left input opens, keyboard-only, no GTA chat. Send plain text → `Name: message` has a visible space. After eight seconds the feed fades; `T` restores history. Type `/p`, navigate with arrows and complete `/pm` with Tab → `<target>` is highlighted; enter an id and a space → `<message>` is highlighted, including across words. Move the caret back → the hint follows. Check `/car`'s optional plate hint as an admin, plugin commands after plugin restart, PageUp/PageDown, unsent draft restoration, Escape, and pause/menu focus takeover. A second player within ~20 m sees local text at full opacity, one at ~50 m sees it faded, one 300 m away sees nothing. `/s WRENCH` reaches ~60 m at full opacity. `/fc warehouse run` reaches only your faction, `/a test` only `core.mod` staff, `/pm <id> hi` only that player, `/ooc hi` everyone. Spam → cooldown drops extras. F8 `TriggerServerEvent('core:server:chat:send', 'hi', 'a')` as non-staff → nothing is delivered. Confirm no duplicate chat opens with `T` or the GTA team-chat key, and check idle resmon; offline tests cannot verify these native/game behaviours.
20. **Server-opened menu, key hints and shard:** run `/exmenu` → a menu opens on *your* screen although `server/main.lua` called it; pick "Heal me" → health goes to 200 and a green **HEALED** shard slides in; press `ESC` instead → the menu returns `nil` and nothing happens. Walk into the 24/7 marker → the `[E]` key hints appear on `onEnter` and go on `onExit`; `restart core_example` while they are up → they disappear with it, no leftovers.

UI visibility (§31). Step 22 is where the two keyboards meet: while the NUI holds focus the game never sees `ESC`.

21. **The shell hides behind the pause menu:** stand in the 24/7 marker so the HUD, the stat bars and the `[E]` pill are all up, raise a long notification, then press `ESC` → the moment the map opens *everything* core draws is gone, and it is all back unchanged (same values, the toast with its remaining time) when you close it. `Core.Screen.fade(<id>, 800)` does the same for a fade. Then hide it by hand: `Core.UI.hide('test')` from a throwaway **client** command in `core_example/client/main.lua` → the shell stays gone until `Core.UI.show('test')`, `Core.UI.isHidden()` is `true` and `Core.UI.hiddenReasons()` lists `core_example:test`; `restart core_example` while it still holds that reason → the shell comes straight back (the plugin's `uihide` registrations die with it).
22. **A modal cancels instead of hiding:** run `/exmenu` and press `ESC` **once** while the menu is up → the NUI has focus, so the menu swallows the key, returns `nil` and closes; the pause menu does **not** open. Press `ESC` again → now the pause menu opens and the rest of the shell hides with it. Same rule from the server: `Core.UI.hide(<id>, 'cutscene')` with the menu open → the menu closes with `nil` and focus is released, no invisible cursor left behind (hiding with a modal open equals cancelling it).

Idle cameras (§35).

24. **No AFK pan:** stand still for 45 s on foot, then as a passenger, then let a car roll without input — the camera never starts its cinematic pan and an open page (`/exmenu`, the inventory) stays open; set `Config.Camera.DisableIdleCam = false`, `restart core` → the pans are back.

Interiors (§36).

25. **The map is whole:** fly to the heist carrier (`3082, -4717`), the casino (`926, 45`), a tuner shop (`-1350, 160`) and the Cayo gate area — exteriors and shells are streamed, no holes. `/interiors` lists every group as `on` except `north_yankton ufo red_carpet` (`off`) and any group your game build gates out (`gated`). Set `Config.Interiors.casino = false`, `restart core` → the casino doors row is gone from the list; set it back → it loads again.

Game blur (§32).

23. **Glass panels:** run `/exmenu` and look at the game *behind* the menu panel — it is blurred, and it keeps up as you turn the camera (the HUD box, the toasts and the `[E]` pill are glass too). `resmon 1` on `core` must not move measurably: the copy runs in the CEF, not in the script. Set `Config.UI.Blur.Enabled = false`, `restart core` → the panels are flat `bg-panel` again and nothing else changes; a throwaway client command calling `Core.UI.setBlur(false)` does the same without a restart, and `Core.UI.setBlur(true)` brings it back.

Runtime UI platform (§38). Step 27 is the one that decides whether the whole architecture works in the real CEF; everything after it assumes it passed.

26. **Deploy:** `refresh`, `restart core`, then `ensure core_example inventory charcreator trucking`. The *server* console shows one `<res>: UI plugin ok (build …, N css)` line per plugin and no `core_ui` error; the *client* console (`F8`) shows one `<res>: UI plugin ready in N ms (n pages)` per plugin and no `failed` / `incompatible` line. `/uiplugins` lists all four in state `ready`.
27. **Cross-resource ES module import in the real CEF 103** — the #1 risk. Step 26 showing `ready` for every plugin *is* the proof: core's page imported `https://cfx-nui-<res>/ui/dist/plugin.<hash>.js` from four other origins and attached their stylesheets. If a plugin stays `failed during fetch` or `failed during evaluate`, open NUI DevTools (`nui_devtools` or `http://localhost:13172`) and read the console and network tabs there.
28. **core_example, the new request path:** `F5` → the page opens with your HUD values; type a name and press Greet → the reply arrives over `Core.UI.onRequest('greet', …)` ↔ `nui.invoke('greet')`. The Menu demo → "Ask a question" still arrives as a plain event (`Core.UI.send`). `ESC` closes it and the cursor is gone.
29. **inventory, restarted without core:** `TAB` opens the grid; drag between panels, split a stack, right-click an item, use hotbar `1`–`5` and the overlay. Then `restart inventory` **without touching core** → re-open: the page comes back and every action fires exactly **once** (no doubled sounds, emits or toasts — that is the module-scope rule holding), while the HUD and chat never flicker because core's NUI did not reload.
30. **charcreator and trucking:** `/charcreator` → all seven tabs; the stylesheet moved under `.cc-root`, so the tab strip, tiles, active blocks, sliders and swatches must look unchanged — and the soft warning/success tints are now *visible* (they were invisible `color-mix()` before). `/truck`, `/tcompany` and `/dispatch` (the server-opened page must render even right after a restart); run a delivery → the `trucking_hud` overlay card sits horizontally centred.
31. **Hot deploy of a resource core has never seen:** `core/scripts/new-plugin.sh casino`, `npm install` at `resources/`, `npm run build -w casino-ui`, then `refresh` and `ensure casino` → its page opens, and core was neither rebuilt nor restarted. `stop casino` → the page is gone, the cursor is free, `/uiplugins` no longer lists it and nothing else is disturbed.
32. **The deploy loop:** edit a page, `npm run build` in `<plugin>/ui`, `restart <plugin>` → the new UI is live. No core rebuild, no core restart, no NUI reload.
33. **Crash isolation:** temporarily `throw` in a page's `setup` or template → a "UI page … crashed" toast, the cursor is released, and the HUD, chat and every other plugin stay alive; `F8` shows `UI error in <res>/<page> <Component>: …`. Remove the throw and re-open → it mounts again.
34. **Focus nesting:** from a page, open a second page declared `{ type = 'modal' }` → `ESC` closes the modal first and focus *plus* `keepInput` return to the page underneath; `ESC` again closes the page.
35. **Dev loops (optional):** set `Config.UI.Dev.Enabled = true`. `npm run dev:game` in a plugin + `/uidev <res> http://localhost:5173` → edit an SFC and the page updates with no `restart`; `/uidev <res> off` returns to the build. `/uiinspect` opens the inspector panel. (Game and editor on different machines: forward the port so the game sees `localhost:5173`.)
36. **World interaction dots (§6.7):** with `worldPrompt = true` — `core_example`'s snack interaction and every rendered inventory ground drop are — walk toward the point: a dot sits on it and the bottom pill is gone for that interaction. Look at the dot → the ring collapses into the `E` cap with its label; look away → back to the ring. Press `E` → the action (or the pickup) fires exactly **once**. Stand still looking at a dot → no NUI messages and `resmon 1` on **core** stays at the idle figure; walk while looking → the dot follows the world point smoothly. Out of `range` → gone; inside `range` but beyond the entry's `radius` → the outline lock and `E` does nothing. `restart core` while dots are up → they come back with the registrations, nothing doubled.

## Troubleshooting

Read the server side with `fxserver logs --errors --resource <name>`, the client side with `F8`.

| symptom | meaning and fix |
|---|---|
| `attempt to call a nil value` | a native that does not exist on this side (check it with `fxref`), or a `Core.X.y` call before core started — move it into `Core.onReady` |
| `attempt to index a nil value` | an unvalidated payload field; put a `Core.Validate` schema on the `Net.on` or callback |
| `attempt to compare nil with number` | a missing type check on an argument — same fix |
| `event was not safe for net` | the handler needs `RegisterNetEvent`; `Core.Net.on` does that for you |
| `Reliable network event overflow` | you are emitting from a loop — add a `cooldown`, or batch the payload |
| `attempt to index a nil value (global 'Core')` | `'@core/import.lua'` is missing from `shared_scripts`, is not first, or `dependency 'core'` is missing |
| the page never opens, or opens blank | `/uiplugins` first. `failed`/`incompatible` names the reason; no line at all means core never saw the resource — check `core_ui 'ui/dist'` in its `fxmanifest.lua` and the server console, which validates every plugin at start-up (`<res>: UI plugin ok (build …)` per plugin) |
| `/uiplugins` says `failed during fetch` | `ui/dist/**` is not in `files {}`, so FiveM serves a 404. Only listed files are packed for the client |
| the plugin's files are served as garbage | a `client_scripts` glob also matches inside `ui/dist` — narrow it. The server prints a warning for this at start-up |
| a file in `ui/dist` 404s although the glob is right | the whole vfs path `resources:/<res>/<dir>/<file>` is cut at **255 characters** — shorten the resource or folder name |
| a new plugin does not exist / a manifest change is ignored | `refresh` is needed for a **new resource folder** and for a **new manifest entry**; new *files* under an existing `files {}` glob ship on `restart <res>` alone |
| the UI is stale after a rebuild | rebuild the **plugin** and `restart <plugin>` — never core. If the build itself looks wrong, `rm -rf <plugin>/ui/.core-ui` and build again |
| `setup() must be synchronous` in the console | `setup(ctx)` returned a Promise. Start the async work inside it and clean it up through `ctx.scope` |
| an action fires twice after a restart | a listener, timer or subscription at module scope. Module scope is definitions only — move it into `setup(ctx)` |
| `was built for core UI API n, this core provides m` | the plugin and core disagree on `API_VERSION`: rebuild the plugin against this core's `@core/ui`, or update core |
| the cursor is stuck | `ESC` posts `ui_close`; a 500 ms watchdog also drops focus when nothing is open, and `restart core` always releases it. A page whose plugin failed or whose component crashed is closed by the shell for exactly this reason |
| everything vanished after `restart core` | registrations that were not inside `Core.onReady` — only `onReady` is replayed on a core restart |

For anything inside the CEF itself, open **NUI DevTools**: the `nui_devtools` console command, or
`http://localhost:13172` in a browser on the same machine. That is where a cross-origin `import()` failure,
a CSS rule that did not survive Chromium 103 or a Vue warning is actually readable.

## Editor support (LuaLS)

Every `Core.*` API is typed for the [Lua Language Server](https://luals.github.io) (the `sumneko.lua`
VS Code extension), so plugins get autocomplete, parameter hints and hover docs without importing
anything.

**`core/types/core.lua`** is a `---@meta` definition file: the `Core` class, one `---@class Core.<Ns>`
per namespace (Utils, Math, Validate, Log, Callback, Net, Commands, Keys, Streaming, Anim, Audio,
Locale, Player, UI, Markers, TextLabels, Blips, Interactions, Vehicles, Raycast, Spawn, World, Screen,
Cron, DB, Money, Perms, Factions, Notify, Doors, Stats, Weapons, Native, Attachments, Waypoint,
Screenshot, Globals, Services, Api, Chat, Http, Webhook, Security, Registry), typed option tables
(`CoreMarkerOptions`, `CoreInteractionOptions`, `CoreVehicleProps`, `CoreMenuOptions`, …) and aliases
for the enums (`CoreHook`, `CoreNotifyType`, `CorePageType`, `CoreWeather`, …). It is documentation
only: it is **not** in `fxmanifest.lua`, is never loaded at runtime and never shipped to a client.
Functions that only exist on one side carry a `(server)` / `(client)` marker in their description, and
`Core.on` has typed overloads for the common hooks, so `Core.on('moneyChanged', function(src, account,
amount, delta, reason) end)` is fully typed.

**`resources/.luarc.json`** wires it up for the whole `resources/` folder: `runtime.version` is
`Lua 5.4`, `workspace.library` contains `core/types`, `workspace.checkThirdParty` is off, and
`diagnostics.globals` lists the globals the FXServer runtime injects (`Core`, `Config`, `vector3`,
`GlobalState`, `LocalPlayer`, `exports`, `CreateThread`, `Wait`, …) so they stop showing up as
undefined. Open `resources/` as the workspace root (not a single resource) and the settings apply to
core and every plugin at once.

**FiveM natives** are not in this file — there are ~6000 of them and they change with every game build.
Install the [`cfxlua-vscode`](https://marketplace.visualstudio.com/items?itemName=overextended.cfxlua-vscode)
addon (the `@citizenfx` typings), which adds the native definitions as a LuaLS library and splits them
per side; combined with `core/types` you get completion for both `Core.*` and `GetEntityCoords(...)`.
If you prefer to point at a checkout instead, add its path to `workspace.library` next to `core/types`.

Keep `types/core.lua` in sync by hand when you change a public API — `DESIGN.md` §3–§6 and §15–§26 are
the contract, the meta file mirrors it.
