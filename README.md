# core — integrator guide

`core` is one resource that owns the framework: player sessions and persistence, money, factions, vehicles,
permissions, the world (markers, labels, blips, interactions) and **one** CEF page for the whole server.
It is Rebar-inspired — deep reusable APIs on both sides instead of a thin event bus.
A **plugin is just another resource**: `dependency 'core'` plus `'@core/import.lua'` first in `shared_scripts`
gives it the `Core` global, lets it start/stop on its own, and everything it registered inside core (markers,
blips, labels, interactions, UI pages) is removed automatically the moment it stops.
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
ensure chat
ensure spawnmanager
# ensure basic-gamemode   # disabled: core spawns players itself
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
resource that declares `dependency 'core'`. Status (2026-09-12): fxlint clean, 379 lib + 554 server offline
checks green, UI regression 49/49, Storybook 37 play functions green, both resources start clean on the dev
server; **the in-game checklist below has not been run yet**.

The wave-2 keys in `shared/config.lua` worth a look before you go live (§28):

| key | default | why you would change it |
|---|---|---|
| `Config.Security.EntityLockdown` | `'inactive'` | `'relaxed'` (only known models) or `'strict'` (no client-created entities) on bucket 0 — turn it up once every plugin spawns through `Core.Vehicles`, or client-side props stop appearing |
| `Config.Chat.Mode` | `'global'` | `'proximity'` limits normal chat to `Config.Chat.ProximityRange` (20 m); `/ooc` stays global either way |
| `Config.World.TimeScale` | `30` | game seconds per real second — `30` is a 48-minute day, `1` is real time, `0` freezes the clock |
| `Config.Locale` | `'en'` | `'de'` ships too; adds `<resource>/locales/<lang>.json` lookups for `Core.Locale.t` (§26) |
| `Config.DB.Adapter` | `'kvp'` | `'mysql'` switches to the oxmysql adapter — **untested**, see "DB tools" below |

Discord logging is a convar, never a config value, so the URL never lands in git:

```cfg
set core_webhook_audit "https://discord.com/api/webhooks/..."   # mirrors the `audit` hook
```

Any `core_webhook_<name>` convar makes `Core.Webhook.send('<name>', …)` work; an unset one is a silent no-op.

### Build the UI

`html/` is the build output of `ui/` and is what `ui_page 'html/index.html'` serves. The toolchain is installed
**once for the whole resources folder** — it is an npm workspace (`resources/package.json`), so there is a single
hoisted `resources/node_modules` and no resource carries a Vite install of its own:

```bash
cd ..                 # the folder core and your plugins live in
npm install           # once, and again whenever a plugin adds a library
cd core/ui
npm run build         # -> ../html/index.html + html/assets/app.js + app.css
```

That one build also compiles **every plugin page** it finds — each sibling resource with a `ui/src/index.js`
(see `ui/src/plugins.js`) — into the same bundle, so players download core's `html/` and nothing else. Rebuild
after every change under any `ui/src/`, then `refresh; restart core`. For development, `npm run dev` (Vite on
port 5173, plugin sources included) and `npm run storybook` run on the same files.

### Where data lives

Collections (`accounts`, `characters`, `factions`, `vehicles`, `bans`) live in `Core.DB` — an in-memory document store backed by the server's KVP file, flushed every 5 s and on stop, so no database is needed to run.
`Core.DB.setAdapter({ loadAll, put, remove, flush })` is the seam for MySQL/Redis; nothing else changes (§4.1).

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
-- no `files {}` for a UI page: ui/src is compiled into core's shell (see "Plugin pages")
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
        onInteract = function()
            if Core.UI.progress({ label = 'Buying...', duration = 2000, canCancel = true }) then
                Core.Net.emit('my_plugin:server:buy')
            end
        end,
    })
end)
```

`core_example/` is the same thing fully built out, page included. Prefix every event, callback and page id with your resource name so two plugins never collide.

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
| `Net.broadcast(name, …)` | server → everyone; never from a loop |
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
| | `giveKeys(netId, charId)` `removeKeys` `hasKeys(src, netId)` `setOwner` `getOwner` `getPlayerVehicles(src)` |
| | `persist(netId)` `getRecords(charId)` `getRecord(vehId)` `spawnRecord` `store(netId)` `saveProps` `deleteRecord` |
| `Core.Notify` §4.7 | `send(src, message, type?, duration?)` `broadcast(message, type?)` — types `info` `success` `error` `warning` |

Sugar: `Core.Player(src)` gives a handle — `Core.Player(src):getInfo()` and `Core.Player(src).money:add('cash', 10)`.

### Client (§6) — run inside core, reached through the proxy

| namespace | functions |
|---|---|
| `Core.Spawn` §6.1 | `spawnPlayer(opts)` `applyAppearance(ped, appearance)` `teleport(coords, heading?)` `setModel(model, appearance?)` |
| `Core.Player` §6.2 | `getData(key)` `refresh()` (on top of the lib reads above) |
| `Core.Markers` §6.4 | `add(opts)` `update(id, partial)` `remove(id)` `removeAll()` |
| `Core.TextLabels` §6.5 | `add(opts)` `setText(id, text)` `update(id, partial)` `remove(id)` `removeAll()` |
| `Core.Blips` §6.6 | `add(opts)` `update` `setLabel` `setCoords` `setRoute` `getHandle` `remove` `removeAll` `setWaypoint(coords)` `getWaypoint()` |
| `Core.Interactions` §6.7 | `add(opts)` `remove(id)` `removeAll()` `setEnabled(id, bool)` `setLabel(id, text)` `getActive()` |
| `Core.Vehicles` §6.8 | `getClosest(coords?, radius?)` `getCurrent()` `isDriver()` `getSeat()` `getNetId(veh)` `fromNetId(netId, timeout?)` |
| | `getProps(veh)` `setProps` `getPlate` `getDisplayName` `hasKeys(veh)` `isLocked` `toggleLock(veh?)` `setEngine` `repair` `saveProps` |
| `Core.Raycast` §6.9 | `fromCamera(distance?, flags?, ignoreEntity?)` `between(from, to, …)` `getEntityInFront(distance?)` |
| `Core.UI` §6.10 | `registerPage` `unregisterPage` `open(id, props?)` `close(id?)` `closeAll()` `isOpen(id)` `getOpenPage()` `isFocused()` `send(id, event, data)` |
| | `notify` · `textUI.show/hide/isShown` · `progress` + `progress.cancel` · `menu.open/close` · `input.open` · `alert` · `hud.set/setVisible` |
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

### Plugin pages

A page is a Vue SFC in the plugin's own `ui/src/`, compiled into core's shell when `core/ui` is built. Plugins
ship **no UI files at all**: no Vite config, no `dist`, no `files {}` entry, no `node_modules`.

```js
// <plugin>/ui/src/index.js — core/ui/src/plugins.js picks this up at build time
export const id = 'my_plugin'
export { default } from './Page.vue'
```

```lua
Core.onReady(function()   -- registration lives in core, so it must be replayed after a core restart
    Core.UI.registerPage('my_plugin', { type = 'page' })    -- no script/style: core already has the component
end)
Core.UI.open('my_plugin', { stats = stats })            -- props; 'page' takes focus, 'overlay' does not
Core.UI.send('my_plugin', 'greeting', { text = 'Hi' })  -- Lua -> page
Core.UI.on('my_plugin', 'greet', function(data) end)    -- page -> Lua, at file scope
```

```js
const { props, emit, on, close } = window.CoreUI.usePage('my_plugin')   // inside Page.vue
on('greeting', d => { reply.value = d.text })
emit('greet', { name: name.value })
```

Needs an extra runtime library (drag-and-drop, charts, …)? Give the plugin a `ui/package.json` with just that
dependency and re-run `npm install` at the resources folder — the import is bundled into the same single dist.
`vue` never belongs there: the shell provides it. (`registerPage` still accepts `script`/`style` paths for a
self-hosted bundle, but nothing ships that way any more.)

`window.CoreUI` also exposes `Vue`, `hud` (live HUD snapshot) and `post`. The exact NUI protocol
(`page:register`, `page:open`, `ui_event`, `menu_result`, …) is DESIGN §6.10. No CDNs, no web fonts: no network.

### Styling with Tailwind

The shell's CSS is **Tailwind CSS v4**, CSS-first: `@tailwindcss/vite` in `ui/vite.config.js` and one
entry stylesheet, `ui/src/styles.css`, which holds the `@theme` tokens, the shared `.core-*` classes
and the base layer. There is no `tailwind.config.js` and no PostCSS step.

A plugin page gets all of it for free: `styles.css` also scans the sibling resources
(`@source "../../../*/ui/src/**/*.{vue,js}"`), so utilities used in `<plugin>/ui/src` are emitted into
core's one bundle. Plugins install nothing — `cd core/ui && npm run build` rebuilds the shell *and*
every plugin page's CSS at once (`core/html/assets/app.css`).

The design tokens are ordinary utilities, opacity modifiers included (`bg-accent/10`):

| group | utilities | value |
|---|---|---|
| surfaces | `bg-panel` `bg-panel-solid` `bg-panel-raise` `bg-backdrop` | `rgba(14,16,20,.86)` · `#0e1014` · `rgba(255,255,255,.04)` · `rgba(0,0,0,.28)` |
| hairlines | `border-border` `border-border-strong` | `rgba(255,255,255,.08)` · `rgba(255,255,255,.16)` |
| text | `text-fg` `text-fg-dim` `text-fg-faint` | `#f2f4f8` · 62 % · 38 % |
| accent | `text-accent` `bg-accent-soft` | `#5b8cff` · `rgba(91,140,255,.18)` |
| states | `text-success` `text-error` `text-warning` `text-info` | `#3ddc84` · `#ff5d5d` · `#ffb347` · `#5b8cff` |
| shape | `rounded-ui` `rounded-ui-sm` `shadow-ui` `ease-ui` | 8 px · 5 px · `0 8px 28px rgba(0,0,0,.45)` · `cubic-bezier(.22,.61,.36,1)` |
| type | `font-sans` `font-mono` · `text-ui` `text-ui-sm` `text-ui-xs` | system stack · Cascadia Mono · 14 / 12 / 10 px |
| motion | `animate-core-slide-in` `animate-core-fade-in` `animate-core-pop-in` | the shell's three entrances |

Prefer the shared component classes over rebuilding a panel by hand — they are what the built-in
menus and dialogs are made of, so a page written with them cannot drift from the shell:

| class | what it is |
|---|---|
| `core-panel` `core-modal` `core-backdrop` | the dark panel, its 320–460 px modal padding, the dimmed full-screen layer |
| `core-title` `core-text` `core-label` | 15 px heading, dimmed body copy, uppercase micro-label |
| `core-btn` + `core-btn--primary` / `--ghost` / `--danger` | the button, its three variants, `[disabled]` handled |
| `core-field` `core-input` `core-select` `core-check` `core-key` | form row, text field, select, checkbox row, keycap |
| `core-list` `core-item` (+ `.is-active` / `.is-disabled`) | scrollable list and its rows |
| `core-interactive` | `pointer-events: auto` — the shell is click-through, so anything clickable needs it |

```vue
<div class="core-panel core-interactive w-[380px] font-sans text-fg">
    <h1 class="core-title">my_plugin</h1>
    <p class="text-ui-sm text-fg-dim">Utilities and tokens, no stylesheet of your own.</p>
    <button class="core-btn core-btn--primary mt-3" @click="close()">Close</button>
</div>
```

A scoped `<style>` block is compiled on its own, so `@apply` inside one needs the theme pointed out
first — relative to the file, which from a plugin is
`@reference "../../../core/ui/src/styles.css";` (`<plugin>/ui/src` → the resources folder → core).
It emits nothing; only the tokens are read. Utilities in the template need no `@reference`.

**Never use `backdrop-filter` / `-webkit-backdrop-filter` or Tailwind's `backdrop-*` utilities** — the
game frame is not part of the CEF's compositing surface, so FiveM paints the filtered area as a solid
black box. That ban stays; for a glass panel put **`data-core-blur`** on the panel instead (next
section). `core/ui/src/styles.css` documents the same rule.

### Game blur (glass panels)

A CSS filter cannot see the game, but FiveM's NUI core can: it hooks `glTexParameterf` and binds the
game's back buffer to a WebGL texture — the same hook the FiveM main menu draws its own blurred
background with. core copies that frame into one small hidden canvas `Fps` times a second, and behind
every element carrying `data-core-blur` it inserts a `.core-glass` wrapper (`z-index: -1`, inset 0)
holding a blurred crop of it. The wrapper paints the panel colour itself, so a glass panel looks like
the normal one with the game showing through, border and all.

```vue
<section class="core-panel core-interactive" data-core-blur>   <!-- Config.UI.Blur.Strength -->
<section class="core-panel" data-core-blur="18">               <!-- 18 px, this panel only -->
<section class="core-panel" data-core-blur="0">                <!-- no glass on this panel -->
<section class="core-panel" data-core-blur style="--core-glass-tint: rgba(20, 14, 14, 0.66)">
```

A page needs **no JavaScript at all** — the attribute is the whole API, and it works on an element
that appears later. `--core-glass-tint` on the element overrides the panel colour the wrapper paints
(default `--color-panel-glass`, `rgba(14,16,20,.62)`).

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

State bags are server-written, client-read. Read them with `Core.Player.get(key)` or `Entity(veh).state.x`.

| bag | keys |
|---|---|
| `player:<src>` | `loaded` `name` `charId` `group` `cash` `bank` `faction` (summary or `false`) `dead` |
| `entity:<netId>` (core vehicles) | `coreVeh` `locked` `owner` `keys` `plate` `vehId` |
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
`Core.Api` hands a live table across resources, so **every call costs two msgpack hops**: fine for wiring,
never for per-frame work. A table leaves `Api.get` the moment its owning resource stops.

### Chat (§23)

Core intercepts the default `chat` resource's `chatMessage`, cancels its broadcast and re-sends with
its own format, cooldown and sanitising.

| function | purpose |
|---|---|
| `Core.Chat.send(src, message, opts?)` | `opts = { color = {r,g,b}, prefix = 'SYSTEM', multiline = false }` |
| `Core.Chat.broadcast(message, opts?)` · `sendNear(coords, range, message, opts?)` | announcements / proximity |
| `Core.Chat.registerChannel(name, { command, permission?, format, global, staffOnly?, color?, range? })` | adds the `/command` for you |
| `Core.Chat.setFilter(fn(src, channel, msg) -> bool)` | returning `false` vetoes the message |

Built-ins: `/ooc` (global), `/me` (`* {name} {msg}`, nearby only), `/a` (staff, needs `core.mod`) and
`/pm <id> <message…>`. Normal chat follows `Config.Chat.Mode`. Hook: `chatMessage (src, channel, msg)`.

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

### Tooling (§27)

```bash
core/scripts/new-plugin.sh shop_robbery   # scaffolds ../shop_robbery from templates/plugin
core/scripts/check.sh [--full]            # the gate before a deploy (--full adds the Storybook build)
```

`new-plugin.sh` validates the name (`^[a-z][a-z0-9_]*$`), refuses to overwrite an existing resource,
rewrites every placeholder and prints the next steps. `check.sh` stops at the first failure: `luac5.4 -p`
over every `.lua`, `fxlint` on core and `core_example` (skipped with a notice when it is not on `PATH`),
both offline test suites, and the UI build.

`.github/workflows/core-ci.yml` runs the same thing on every push and pull request (Ubuntu, Lua 5.4,
Node 22, `npm ci` at the workspace root, then the syntax loop, both suites and the UI + Storybook
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

13. **Door, with and without permission:** walk to the `example_backroom` door at `24.9, -1345.4, 29.5` → the `[E] Lock / unlock door` pill appears within 2 m. As `core.mod`, press `E` → the door unlocks, `E` again re-locks it, and a second player standing there sees the door move too (it rides on `GlobalState`). Without `core.mod` → "You do not have access to this door" and the door does not move. Then `restart core` → the lock state is back as you left it.
14. **Server-driven interaction:** step into the orange marker 3 m east of the 24/7 (`Server-side snack ($5)`) and press `E` → cash −$5, a green **YUM / Server-side snack** shard, and `server snack for <id> at … m` in the *server* log (`fxserver logs --resource core_example`, needs `Config.Debug`). The handler ran on the server; the client only reported the press.
15. **Server-side distance and cooldown:** from ~10 m away run `TriggerServerEvent('core:server:worldInteract', '<id>')` in `F8` → nothing happens, no money moves. Spam `E` in the marker for 10 s → at most one purchase per second.
16. **Weapons persist:** `/weapon <your id> WEAPON_PISTOL 50` → the pistol appears with 50 rounds. Fire ~10, wait for the 60 s snapshot (or die), then `/quit` and reconnect → the pistol is back with the *reduced* ammo. `/weapons clear <your id>` → it is gone and stays gone after a relog. Bonus negative: `/weapon` as a non-admin → "You are not allowed to do that".
17. **Time and weather for everyone:** with a second player connected, `Core.World.setTime(2, 0)` and `Core.World.setWeather('THUNDER', 5)` → **both** clients go to 02:00 and roll into thunder within ~5 s. `Core.World.setWeatherFor(<id>, 'XMAS', 2)` changes that one player only, `clearWeatherFor` puts them back, and `Core.World.freezeTime(true)` stops the clock for everyone.
18. **Stats decay and thresholds:** watch the hunger/thirst bars in the HUD — they drop by `decayPerMinute` every `TickMs`. Put one just above a threshold (`Core.Stats.set(<id>, 'hunger', 26)`) and let it decay past 25 → the threshold notification fires **once**, not every tick. Buy a snack → hunger jumps +20 and the bar follows immediately.
19. **Chat channels:** `/ooc hello` reaches everyone; `/me waves` shows `* <name> waves` only to players within 20 m; `/a test` is visible to `core.mod` staff only and rejected for everyone else; `/pm <id> hi` reaches exactly that player and echoes to you. Spam any of them → the cooldown drops the extras silently. Set `Config.Chat.Mode = 'proximity'`, `restart core` → plain chat is now range-limited while `/ooc` stays global.
20. **Server-opened menu, key hints and shard:** run `/exmenu` → a menu opens on *your* screen although `server/main.lua` called it; pick "Heal me" → health goes to 200 and a green **HEALED** shard slides in; press `ESC` instead → the menu returns `nil` and nothing happens. Walk into the 24/7 marker → the `[E]` key hints appear on `onEnter` and go on `onExit`; `restart core_example` while they are up → they disappear with it, no leftovers.

UI visibility (§31). Step 22 is where the two keyboards meet: while the NUI holds focus the game never sees `ESC`.

21. **The shell hides behind the pause menu:** stand in the 24/7 marker so the HUD, the stat bars and the `[E]` pill are all up, raise a long notification, then press `ESC` → the moment the map opens *everything* core draws is gone, and it is all back unchanged (same values, the toast with its remaining time) when you close it. `Core.Screen.fade(<id>, 800)` does the same for a fade. Then hide it by hand: `Core.UI.hide('test')` from a throwaway **client** command in `core_example/client/main.lua` → the shell stays gone until `Core.UI.show('test')`, `Core.UI.isHidden()` is `true` and `Core.UI.hiddenReasons()` lists `core_example:test`; `restart core_example` while it still holds that reason → the shell comes straight back (the plugin's `uihide` registrations die with it).
22. **A modal cancels instead of hiding:** run `/exmenu` and press `ESC` **once** while the menu is up → the NUI has focus, so the menu swallows the key, returns `nil` and closes; the pause menu does **not** open. Press `ESC` again → now the pause menu opens and the rest of the shell hides with it. Same rule from the server: `Core.UI.hide(<id>, 'cutscene')` with the menu open → the menu closes with `nil` and focus is released, no invisible cursor left behind (hiding with a modal open equals cancelling it).

Game blur (§32).

23. **Glass panels:** run `/exmenu` and look at the game *behind* the menu panel — it is blurred, and it keeps up as you turn the camera (the HUD box, the toasts and the `[E]` pill are glass too). `resmon 1` on `core` must not move measurably: the copy runs in the CEF, not in the script. Set `Config.UI.Blur.Enabled = false`, `restart core` → the panels are flat `bg-panel` again and nothing else changes; a throwaway client command calling `Core.UI.setBlur(false)` does the same without a restart, and `Core.UI.setBlur(true)` brings it back.

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
| the page never opens | core's UI was not rebuilt after the page changed (`cd core/ui && npm run build`), the plugin has no `ui/src/index.js`, or its `export const id` differs from the id in `Core.UI.registerPage` |
| the cursor is stuck | `ESC` posts `ui_close`; a 500 ms watchdog also drops focus when nothing is open, and `restart core` always releases it |
| everything vanished after `restart core` | registrations that were not inside `Core.onReady` — only `onReady` is replayed on a core restart |

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
