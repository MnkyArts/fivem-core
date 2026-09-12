# Working on `core` — rules for agents

`core` is a FiveM framework resource (Lua 5.4, standalone, no ox_lib) for a "GTA Online with factions and
rules" server: server-owned sessions, money, factions, vehicles, world APIs, doors, stats, weapons, chat and
one single Vue/Tailwind CEF that every plugin renders into. Plugins are ordinary FiveM resources that depend
on `core`. This file is the working agreement for anyone (human or agent) changing core or writing a plugin.

## 1. Where the truth lives

| file | role |
|---|---|
| `DESIGN.md` | **The binding contract.** ~1,900 lines, sections §0–§33. Later sections override earlier ones; §14, §29, §30, §30.1 are implementation notes and review-driven changes. Read the section you touch before editing code, and update it *with* the code — never after, never not. |
| `README.md` | Integrator guide: install, config keys, API cheat sheet, plugin how-to, in-game checklist, troubleshooting. Update it whenever an API, config key or command changes. |
| `PLAN.md` | History of the build runs (who owned which file). Append a run table for multi-agent work. |
| `types/core.lua` | LuaLS stubs for every public function (`resources/.luarc.json` wires them). New API ⇒ new stub. |
| `AGENTS.md` | This file. `CLAUDE.md` only points here. |

## 2. Layout

```
import.lua              plugin-side loader: `Core` global, lazy libs, ONE export proxy (exports.core:call)
shared/config.lua       every tunable (Config.*); plugins read core's copy as Core.Config
lib/<module>/{shared,client,server}.lua   pure libs compiled INTO each plugin VM (no export hop)
server/*.lua            stateful modules (api, db, db_pg, player, money, factions, vehicles, doors, ui, …)
client/*.lua            world scan, interactions, markers, doors, ui shell bridge, blur, visibility, …
server/pg/index.js      Node source of the Postgres bridge → bundled into server/db_pg.js (committed)
ui/                     Vite 7 + Vue 3.5 + Tailwind v4 shell, Storybook 10, tests/shell-regression.js
html/                   the built shell (COMMITTED — players download this, and only this)
templates/plugin/       scaffold used by scripts/new-plugin.sh <name>
tests/                  offline suites: run_tests.lua (libs/loader), server_tests.lua (server modules), pg_smoke.js
scripts/                check.sh (offline gate), new-plugin.sh, pg-import.js
data/                   runtime files (exports); ignored except .gitkeep
```

Neighbours in `resources/`: `core_example` (the reference plugin — copy its patterns), the npm workspace root
`package.json` (`core/ui` + every `*/ui`), `.luarc.json`.

## 3. Non-negotiable rules

**Authority.** The server decides; the client is an input device and a renderer. Every net event and
callback validates in this order: type → range/existence → cooldown → distance → permission → act.
`local src = source` is the first line of a server handler. Never trust ids, prices, amounts or coords
from a payload.

**Natives.** Never write a native from memory. Confirm every one with `fxref show <Name>` (name, argument
order, apiset) in the session you use it, and list the natives a file uses in its header comment.

**Callbacks from plugins are callable *tables*, not functions.** A function passed across the export hop
arrives as a table with `__call`. Test with `Core.Utils.isCallable(v)`; `type(v) == 'function'` is a bug.

**Network ids.** Call `NetworkDoesEntityExistWithNetworkId(netId)` before `NetworkGetEntityFromNetworkId`
or `GetEntityFromStateBagName('entity:…')`. FiveM logs `GetNetworkObject: no object by ID` for every id the
client does not hold, and entity state bags reach out-of-scope clients (DESIGN §30.1).

**Performance.** No `Wait(0)` loop unless something is drawn *right now*; adaptive sleeps otherwise. Keys go
through `RegisterKeyMapping` + `+cmd`/`-cmd`, never polled. Nothing per frame that allocates, encodes JSON,
triggers events, reads state bags or iterates pools. Target 0.00–0.02 ms idle in resmon.

**Ownership.** Everything a plugin registers through core (markers, blips, labels, interactions, pages, doors,
hide reasons, …) is tracked by `Core.Registry` under the calling resource and removed when it stops. New
registries follow that pattern. Internal names are blocked through the export (`Registry`, `DB.setAdapter`,
`DB.markDegraded`, `Player.loadSession/loadAllConnected/startAutosave/stopAutosave`).

**Secrets.** Only convars (`core_pg_url` in `core_pg.cfg`, `core_webhook_*`), never a file in the resource,
never logged, never printed by a tool. `server.cfg`, `sv_licenseKey` and `rcon_password` are never shown.

**UI.** One dist: a plugin page is `<plugin>/ui/src/index.js` + `Page.vue`, compiled into core's bundle
(`cd core/ui && npm run build`), and plugins ship no UI files. Tailwind v4 tokens (`bg-panel`, `text-fg-dim`,
`rounded-ui`, `text-ui-sm`, …) and the `.core-*` classes; the root font is 16px, body 14px. **Never
`backdrop-filter`** — it paints a black box in the CEF; glass is `data-core-blur` on the panel. Never write
`*/` inside a CSS comment and never spell the banned token in a source comment (Tailwind scans it).
The shell auto-hides on the pause menu and fades (§31); a modal that is hidden is cancelled.

**Server files.** No `package.json` or `node_modules` inside a resource: FXServer's Node sandbox refuses to
read modules behind the symlinked resource path and the server's `yarn` builder would run on every start.
Node code is bundled (`npm run build:server` in `core/ui` → `server/db_pg.js`, first line
`// fxlint-disable-file`).

**Manifest edits.** After adding a file to `fxmanifest.lua`: `refresh` on the server console, then
`restart core`, then `ensure core_example` (a dependant is stopped by the restart).

## 4. Writing a plugin

1. `core/scripts/new-plugin.sh <name>` (copies `templates/plugin`, replaces the placeholders). Manifest:
   `dependency 'core'` and `shared_scripts { '@core/import.lua', 'shared/config.lua' }`. That gives the
   global `Core` in every VM; wait for `Core.onReady(fn)` (server and client) or `Core.onPlayerLoaded(fn)`.
2. Libs run in *your* VM: `Core.Utils`, `Math`, `Validate`, `Log`, `Callback`, `Net`, `Commands`, `Keys`,
   `Streaming`, `Anim`, `Player` (client), `UI.on/off` (client), `Locale`, `Audio`. Everything stateful goes
   through the proxy: `Core.Player(src)`, `Core.Money`, `Core.Factions`, `Core.Vehicles`, `Core.Doors`,
   `Core.Markers/Blips/TextLabels/Interactions.addGlobal/addFor`, `Core.UI.menu.open(src, …)`,
   `Core.UI.hide/show`, `Core.Chat`, `Core.Http`, `Core.Cron`, `Core.Stats`, `Core.Weapons`, `Core.DB`
   (documents), `Core.Perms`. Signatures: README "API cheat sheet" and `types/core.lua`.
3. Server rules: register events with `Core.Net.on(name, schema, handler, opts)` (schema, cooldown, distance
   and permission are declarative in `opts`), commands with `Core.Commands.register`, RPC with `Core.Callback.register`.
   Persist with `Core.DB` collections, never your own files. Money only through `Core.Money`.
4. Client rules: interactions/markers through core's APIs (one scan loop for everyone), text UI through
   `Core.UI.textUI` (owner-tagged), keys through core's key mapping helpers.
5. UI page: `ui/src/index.js` exports `id` and the component; the page receives props from
   `Core.UI.open(src, id, props)` and talks back with `usePage()` events. Rebuild core's UI. A story in
   `core/ui/src/stories` is welcome but not required for plugins.
6. Locale strings in `locales/<lang>.json` (list them in `files {}`), read with `Core.Locale.t`.
7. Test offline first (`fxlint <plugin>`, `luac5.4 -p`), then deploy (`fxserver deploy <dir>`), `refresh`,
   `ensure <plugin>`, and hand the in-game checklist to the human — agents do not test in-game.

`core_example` demonstrates every one of these (server callbacks, validated buy event, server menu, global
interaction, door, cron, locale, a compiled page).

## 5. Verification — run these yourself, do not trust a report

| what | command | expect |
|---|---|---|
| syntax + lint + libs + server + UI build | `scripts/check.sh` (`--full` adds Storybook) | exits 0 |
| libs and loader | `lua5.4 tests/run_tests.lua` | `379 passed, 0 failed` |
| server modules | `lua5.4 tests/server_tests.lua` | `628 passed, 0 failed` |
| rulebook lint | `fxlint resources/core` (and the plugin) | `0 error(s), 0 warning(s)` |
| shell bundle | `cd ui && npm run build` | writes `html/`, no CSS warnings |
| shell regression | serve `html/` over HTTP (`python3 -m http.server 8765 --directory html`), `agent-browser open http://127.0.0.1:8765/index.html`, `agent-browser eval --stdin < ui/tests/shell-regression.js` | `PASS 52/52` (file:// blocks ES modules) |
| Storybook | `cd ui && npm run build-storybook` | builds; play functions green |
| Postgres bridge | `cd ui && npm run build:server`; `CORE_PG_URL=… node tests/pg_smoke.js` | `pg_smoke: PASS` |
| live | `fxserver logs --errors --resource core`, `fxclient logs --errors` | nothing new |

In-game diagnostics that exist for a reason: `/uiblur diag` / `/uiblur test` (game blur state and hook
recipes), `/doorfind` (door models, registered doors), `/dbexport` and `/dbimport` (console), `/id`.

## 6. Change protocol

- Contract first: put the section in `DESIGN.md`, then implement, then README/types/Storybook/tests.
- New server logic ⇒ checks in `tests/server_tests.lua` (stubs in `tests/stubs.lua`); new lib ⇒
  `tests/run_tests.lua`; new shell action ⇒ a regression check and a story.
- Every subagent gets exact file ownership; parallel runs never share a file; scratch files live in the
  session scratchpad under a run-named folder. Implementers report line counts and test results; the
  orchestrator re-runs lint and tests itself before believing them.
- Commits: `<area>: <imperative summary>` (`ui:`, `doors:`, `db:`, `client:`), body says *why*. `html/`
  is committed on purpose; `data/`, `node_modules/`, `storybook-static/` are not.
- Rebar was the inspiration for the API surface only. Never copy its code; FiveM's resource system, state
  bags and OneSync are the design, not an alt:V port.

## 7. Database

`Core.DB` is a document store (collections of JSON documents, cached in memory, written through). Adapters:
`kvp` (zero setup), `postgres` (production: `core_documents` with `jsonb`, DESIGN §33), `mysql` (oxmysql,
untested). Switching backends: `/dbexport` → `scripts/pg-import.js … --replace` → set the adapter → `refresh`
+ `restart core`. `/dbimport` is only safe with no player online. Schema changes are `DB.migrate` functions,
never manual edits of live rows.

## 8. Gotchas we already paid for

- FXServer caches manifests: `refresh` before `ensure` or a new file "does not exist".
- The NUI render hook (game blur) binds unreliably on the first try; the shell re-issues the sequence on a
  backoff. Plain 0..1 texture mapping is upright in the client; FxDK's mirrored mapping is wrong here.
- Tailwind's `@source` needs a file glob (`…/*/ui/src/**/*.{vue,js}`); a bare directory matches nothing.
- Tailwind's rem scale assumes a 16px root; the shell keeps it and sets 14px on `body` only.
- A door whose model hash does not match the object at its coords controls nothing — `/doorfind`.
- State-bag change handlers never fire for keys that existed before the script started: seed on load.
- Console commands run as `src == 0`; devtools `fxclient exec --server` is that console.
- `SaveResourceFile` cannot create directories: `data/.gitkeep` keeps `data/` present for `/dbexport`.
