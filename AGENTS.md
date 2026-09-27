# Working on `core` — rules for agents

`core` is a FiveM framework resource (Lua 5.4, standalone, no ox_lib) for a "GTA Online with factions and
rules" server: server-owned sessions, money, factions, vehicles, world APIs, doors, stats, weapons, chat and
one single Vue/Tailwind CEF that every plugin renders into. Plugins are ordinary FiveM resources that depend
on `core`. This file is the working agreement for anyone (human or agent) changing core or writing a plugin.

## 1. Where the truth lives

| file | role |
|---|---|
| `DESIGN.md` | **The binding contract.** ~7,450 lines, sections §0–§55. Later sections override earlier ones; §14, §29, §30, §30.1 are implementation notes and review-driven changes; **§37 is the design system** (tokens, classes, the component catalogue — it replaces the old §7.2 look); **§38 is the runtime UI platform** and supersedes §7.1, §7.4, §6.10's focus paragraph and §9's message budget; **§39 is the vitals HUD** (the bottom-left strip: mic tile, HEALTH / ARMOR plates, food / drink bars) and supersedes the HUD of §7.2 / §21 and the `Hud` / `StatsBars` rows of §37.6; **§41–§53 are the admin platform** (each section ends in "Implementation notes (2026-09-26)" — the deviations are stated there); **§54 is editor focus** (HUD hiding, key capture); **§55 is scene streaming** (`Core.Scene`, `Core.Clock`; each subsection ends in "Implementation notes (2026-09-27 …)", and §55.21 phase D — done 2026-09-27 — supersedes the §52.3 / §52.4 region runtime and parts of §20 and §4.6). Read the section you touch before editing code, and update it *with* the code — never after, never not. |
| `ui/sdk/src/contract.ts` | **The TypeScript half of the contract** (§38.6): `API_VERSION`, `CoreUIHost` and every type the shell and a plugin share. Both sides import it, so the compiler proves the shell implements what the SDK calls. Change it and DESIGN §38 in the same commit; a breaking change bumps `API_VERSION`. |
| `README.md` | Integrator guide: install, config keys, API cheat sheet, plugin how-to, in-game checklist, troubleshooting. Update it whenever an API, config key or command changes. |
| `PLAN.md` | History of the build runs (who owned which file). Append a run table for multi-agent work. |
| `types/core.lua` | LuaLS stubs for every public function (`resources/.luarc.json` wires them). New API ⇒ new stub. |
| `AGENTS.md` | This file. `CLAUDE.md` only points here. |

DESIGN §40 adds dependency-free geometry/zones/points, controls/actions, player context, streaming helpers,
rich forms/menus, skill checks and cancellable hook pipelines. Keep client results advisory and preserve
owner cleanup and coroutine-scoped callback ownership.

DESIGN §41–§53 add the admin platform that every plugin can use: page input modes / Escape / hide policy (§41),
rendered-camera raycasts (§42), `Core.Schema` (§43), permissions v2 with ranked groups in `perm_groups` (§44),
`Core.Settings` (§45), `Core.Audit` (§46), `Core.Bans` (§47), sticky player states + teleport options + account
reader (§48), target selectors (§49), `Core.Buckets` (§50), `Core.Admin` contributions and the one dispatch path
(§51), `Core.Maps` (§52; since phase D an authoring layer on Core.Scene) and seven kit components (§53). The admin
plugin itself — panel, editor, sanctions, reports — is `resources/admin` with its own `DESIGN.md`; core never depends
on it.

DESIGN §55 adds `Core.Scene`: server-owned nodes (props, vehicles, peds, lights, particles, markers, texts, hides,
zones, sounds, positional audio, voice speakers, plugin kinds) streamed by interest cells and materialised LOCALLY on
each client (non-networked entities; OneSync only while a node is promoted), motion and media on one clock
(`Core.Clock`), a binary wire, budgets from FiveM's pools. Phase D (2026-09-27) moved `Core.Maps`, inventory drops,
player attachments and parked vehicles onto it (§55.21).

## 2. Layout

```
import.lua              plugin-side loader: `Core` global, lazy libs, ONE export proxy (exports.core:call)
shared/config.lua       every tunable (Config.*); plugins read core's copy as Core.Config
shared/ui_manifest.lua  UIManifest.API_VERSION / dirOk / validate — the plugin manifest rules, both VMs (§38.4)
lib/<module>/{shared,client,server}.lua   pure libs compiled INTO each plugin VM (no export hop)
server/*.lua            stateful modules (api, player, playergrid, money, factions, vehicles, doors, ui, …)
server/db.lua           registers core's own migrations (sql/0001_core_schema.sql, sql/0002_core_legacy_import.sql)
                        and `/dbstatus` — nothing else (§56.6, §56.11)
server/player_store.lua row ↔ session mapping, loads, creates, queued writes, the connect-time ban gate (§56.12) —
                        hands over to server/player.lua through the one-shot global CorePlayerStore (keep the two
                        adjacent in the manifest)
server/audit.lua        Core.Audit (§46): append-only trail in `audit_log` (queued appends, SQL queries), three retention
                        pools; server/bans.lua = Core.Bans (§47: one indexed connect query over ban_identifiers/ban_tokens;
                        Bans.checkConnecting is internal, block-listed)
server/bans_identity.lua internal Core.BanIdentity (§47): identity reads, online holder index, rank check — loads RIGHT
                        before bans.lua (which errors otherwise); block-listed in api.lua
server/buckets.lua      Core.Buckets (§50); server/settings.lua = Core.Settings (§45) + core's maps/audit sections
server/adminapi.lua     Core.Admin (§51): registry, snapshot, duty/modes/staff/echo; adminapi_dispatch.lua = Admin.run,
                        core:admin:run, chat commands — the two MUST stay adjacent in the manifest (private hand-off)
server/maps_*.lua       Core.Maps (§52, §55.21.1): maps_types → maps_runtime (the PROJECTOR: every shown element is one
                        Core.Scene node owned by core, fields.mapEl = the uid) → maps → maps_apply (order required; they
                        share the internal Core.MapsRuntime). maps_regions.lua / Core.MapRegions are gone
server/vehicles_park.lua parked vehicles (§4.6 notes, §55.21.4): loads RIGHT AFTER server/vehicles.lua and takes its
                        live maps through the one-shot global CoreVehiclesPark (asserted) — park, getInfoByRecord, the
                        vehId setters, the wrapped record calls, core:server:parkedLock — and passes the global on to
server/vehicles_fleet.lua (right after it; clears the global): AutoPark, MaxParked, the boot check, park-at-stop
server/scene_*.lua      Core.Scene (§55), ORDER REQUIRED (each asserts its predecessor): scene_kinds (creates the
                        internal Core.SceneRuntime: kinds, validators) → scene_index (cells, versions, journals, packs,
                        movers) → scene_interest (focus, windows) → scene_gated (audiences, PRIV) → scene_flush (the
                        20 Hz flush) → scene_store (records, hooks, persistence; hands over once via R.storeInternal)
                        → scene (the API) → scene_promote (the promotion engine) → scene_promote_api (its entry points:
                        takes R.promoteInternal once) → scene_audio → scene_voice; all right after maps_apply.lua
server/ui_plugins.lua   start-up validation of every resource's ui/dist, printed to the SERVER console
client/*.lua            world scan, interactions, markers, doors, ui shell bridge, blur, visibility, …
client/ui_plugins.lua   discovery (core_ui metadata → manifest.json), plugin:register/unregister, /uiplugins /uidev /uiinspect
client/settings.lua     the replicated read side of Core.Settings (GlobalState cs:<key>, hook settingChanged)
client/adminstate.lua   the private staff state (§51): core:admin:self/staffState(s) → Core.Admin.getSelf/getStaffStates,
                        hooks staffSelfChanged/staffStateChanged; loads right after shared/hooks.lua (before its readers)
client/maps*.lua        the map client (§55.21.1): maps_preview (the map:data editor view) → maps (the §52.4 API as a
                        facade over Core.Scene); both sit INSIDE the scene block (between scene_voice and scene: they
                        use CoreSceneRuntime). maps_spawn.lua / maps_view.lua are gone
client/scene_*.lua      the client half of Core.Scene (§55.10–§55.17), ORDER REQUIRED: scene_cache (creates the one-shot
                        global CoreSceneRuntime) → scene_focus → scene_mat_assets → scene_materializer → scene_kinds →
                        scene_fx → scene_world → scene_movers → scene_promote → scene_audio → scene_voice →
                        maps_preview → maps → scene (API, /scene, plugin-kind bridge; clears the global); all right
                        after client/spawn.lua
shared/scene_codec.lua  Core.SceneCodec (§55.8, the binary wire) + shared/scene_motion.lua = Core.SceneMotion (§55.9,
                        pure motion maths): internal, both core VMs, block-listed in server/api.lua and client/api.lua
lib/clock/shared.lua    Core.Clock (§55.2): one u32 ms timeline — server GetGameTimer = client network time; every VM
lib/scene/              shared.lua (kind-id / tier / stable-paint helpers, every VM) + client.lua (Scene.handle / on /
                        off in the CALLER's VM); the rest of Core.Scene is proxied
lib/schema/shared.lua   Core.Schema (§43): the field vocabulary of settings, admin args and map elements; pure, every VM
lib/db/server.lua       Core.DB (§56.5): the relational database lib — SERVER ONLY (no lib/db/shared.lua; the client
                        never sees Core.DB), compiled into every server VM, one export hop into the core_db resource
sql/                    core's own migrations, immutable once applied (§56.6/§56.7): 0001_core_schema.sql (the
                        schema) → 0002_core_legacy_import.sql (imports core_documents once, renames it
                        legacy_documents)
ui/                     Vite 7 + Vue 3.5 + Tailwind v4 shell, Storybook 10, the SDK, the browser suites
ui/sdk/                 npm workspace package `@core/ui` (§38.7): src/contract.ts, src/index.ts (the facade),
                        src/client.d.ts (generated kit tags), src/dev/ (dev host + mock), vite/index.mjs = coreUI(),
                        theme.css (THE @theme token file), reference.css, tsconfig.plugin.json, templates/
ui/src/runtime/*.ts     the platform (§38.6): protocol, transport, scope, plugins, pages, layers, feeds, errors,
                        host, inspector; `ui/src/shell.ts` = createShell(), `ui/src/main.ts` = the entry
ui/src/runtime/audio/   the Core.Scene audio engine (§55.16): index (installAudio, `audio:*` messages) → the lazy chunk
                        scene-audio.ts (engine, mixer, arbiter, spatial, curves, sources, loader, cache, deck, media,
                        streams, icy, net, sync, validate, debug, types); hls.js/light is its own lazy chunk
ui/src/shell/           the Lua-driven widgets (HUD, toasts, prompts, menu/input/alert…) as kit compositions — no drawing of their own
ui/src/kit/             the design system (§37): css/*.css classes → components/Core*.vue (globally registered),
                        plus icons.js, use.js, fonts/ (bundled Barlow, OFL); the tokens live in ui/sdk/theme.css
ui/kit-preview.html     dev-only harness: ?scene=<SceneName>&bg=game|keyart|menu|ink mounts one kit scene
ui/scripts/             gen-kit-types.mjs (→ sdk/src/client.d.ts), check-plugins.mjs (every plugin's dist)
ui/tests/               unit/ (node --test over the runtime, type stripping; ui/sdk/tests/ does the SDK),
                        nui-serve.mjs (one ORIGIN per resource, FiveM's headers) + fixtures/ + build-fixtures.mjs,
                        {shell,kit,runtime}-regression.js, run-browser-suites.mjs, bench.mjs → BENCH.md
html/                   the built SHELL (COMMITTED); a plugin's own frontend is its committed <plugin>/ui/dist
templates/plugin/       scaffold used by scripts/new-plugin.sh <name>, ui/ included
tests/                  offline suites: run_tests.lua (libs/loader), server_tests.lua (a thin driver: requires
                        server_harness.lua + the per-suite files under server/*.lua — same command, same counts),
                        client_ui_tests.lua (focus stack, discovery, requests, patches, feeds), client_chat_tests.lua,
                        db_tests.lua (§56.10.3: the Core.DB lib over the bridge — marshalling, every awaited/queued
                        call, transaction/stream, migrate, removed-name errors); pgbridge.lua (the Lua side of the
                        DB test bridge, §56.10.2: bridge.start/install/reset/recreate/sql/fail/stop) + tests/server/
                        (the per-suite files server_harness.lua requires: api, chat, db, factions, globals,
                        legacy_commands, money, perms, player, player_admin, playergrid, stats, ui, ui_plugins,
                        vehicles, world);
                        §41–§53: raycast, schema, settings, perms, buckets, audit, bans, targets, admin_api,
                        registry_caller, client_registry_caller, client_adminstate, callback, maps, maps_store,
                        client_maps, chat_hook (<name>_tests.lua, each on its own); admin_harness.lua and
                        maps_harness.lua are shared harnesses, not suites; §55: scene_codec, scene_motion, scene_server,
                        scene_index, scene_interest, scene_audio, scene_voice, scene_promote, client_scene_cache,
                        client_scene_mat, client_scene_kinds, scene_attach, scene_parked; scene_server_harness.lua and
                        client_scene_harness.lua are
                        harnesses; scene_bench.lua is the server benchmark (by hand, not in check.sh)
scripts/                check.sh (offline gate), new-plugin.sh, test-db.sh (up/down the throwaway CORE_TEST_PG_URL
                        database, §56.10.1), build-font-gfx.sh + font-to-gfx.java
                        (Barlow -> stream/barlow_condensed.gfx), build-hint-gfx.sh + hint-to-gfx.java + hint.as
                        (the world-prompt key hint -> stream/core_hint.gfx); FFDec is build-time only, never shipped
stream/                 barlow_condensed{,_bold}.gfx — Scaleform GFx font libraries (600/700) for the native
                        world prompts (§6.7); core_hint.gfx — that renderer's looked-at hint as ONE Scaleform
                        movie (stage 1400x64, SET_HINT/HIDE); built by scripts/build-font-gfx.sh, build-hint-gfx.sh
data/                   runtime files (exports); ignored except .gitkeep
```

Neighbours in `resources/`: `core_db` (§56 — the separate resource `Core.DB` talks to: pool, write-behind queue,
migration runner, table helpers; own `README.md`, own git repo; its committed `dist/core_db.js` is built with
`npm run build -w core_db-build` from `resources/`; `core` declares `dependency 'core_db'`, so `ensure core`
starts it first); `core_example` (the reference plugin — copy its patterns), the npm workspace root
`package.json` (`core/ui`, `core/ui/sdk`, every `*/ui`; scripts `build:ui`, `check:ui`), `.luarc.json`;
`scene_probe` (DEV-ONLY in-game probes for §55.24 — standalone, its own never-focused `ui_page`, never in server.cfg;
Liam runs `/sprobe <n>` in the order of its README; offline suite `tests/probe_tests.lua`); `research/entity-streaming/`
(RESEARCH.md + R1–R9, the findings behind §55 — kept OUTSIDE the core repository because two reports cite Rockstar
source paths; core's docs cite them by report and section, e.g. "R3 §1").

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
triggers events, reads state bags or iterates pools. Target 0.00–0.01 ms idle in resmon. resmon's "CPU msec" is
the resource's OWN time averaged over the last 64 frames: a per-frame loop of ~20 µs IS a constant 0.02 ms, and one
tick costing X shows as X/64 for a second — so periodic scans must not allocate (GC lands in whichever tick
triggers it), and `GetGamePool` (walks the pool, packs and unpacks a fresh table) never runs on a fast timer.
Ped-bound state (config flags, attachments) is re-applied from the client hook `pedChanged`, not by polling the ped.

**Scale.** The server is planned for 1,000–2,000 players. `Core.Net.broadcast` / `TriggerClientEvent(-1)` is one
reliable packet per connected client: never use it for anything positional or player-triggered — keep a
subscription per area and send with `Core.Net.emitMany(targets, …)` (payload packed once). No loop over all players
on a timer, no client cache of server-wide data, entity state bags for per-entity data (they only reach clients that
hold the entity). The inventory's scoped drops (inventory DESIGN §3.4.1) are the worked example.

**Ownership.** Everything a plugin registers through core (markers, blips, labels, interactions, pages, doors,
hide reasons, …) is tracked by `Core.Registry` under the calling resource and removed when it stops. New
registries follow that pattern. Internal names are blocked through the export: `Registry`, the whole `DB`
namespace (§56.1 — reached through the export it would run inside core's VM and act as core, so it is refused
entirely), `Player.loadSession/loadAllConnected/startAutosave/stopAutosave/getAccountData/saveAll`,
`Settings.isLoaded`, `Bans.checkConnecting` (`server/api.lua`'s `INTERNAL_NAMESPACES`/`INTERNAL_FUNCTIONS` are
the exact, current lists).

**Secrets.** Only convars (`core_pg_url` in `core_pg.cfg`, `core_webhook_*`), never a file in the resource,
never logged, never printed by a tool. `server.cfg`, `sv_licenseKey` and `rcon_password` are never shown.

**UI.** One CEF page, one Vue, one kit, one focus owner — all core's (§38). A plugin **owns its frontend**:
`<plugin>/ui/src/index.ts` exporting `defineUIPlugin(...)`, built with `coreUI()` from `@core/ui/vite` into a
committed `<plugin>/ui/dist`, opted in with `core_ui 'ui/dist'` + `files { 'ui/dist/**' }`, imported by core
at runtime. Never a `ui_page`, a `SetNuiFocus`, a `SendNUIMessage` or a `RegisterNuiCallback` in a plugin —
focus is a stack core alone owns, and `Core.UI.registerPage` stays the authority on page id, type and owner.
**Module scope is for definitions only**; every side effect goes in `setup(ctx)` and dies with `ctx.scope`.
Output file names are content-hashed because the browser pins an ES module by URL for the life of core's
page — never re-import one URL and expect new code. Changing the shell↔plugin contract means editing
`ui/sdk/src/contract.ts` **and** DESIGN §38 together; a breaking change bumps `API_VERSION` in both.
**Every page is composed from the kit's
`<Core…>` components** (§37.5 is their API) — custom CSS only for what the kit lacks, and then over the
tokens (`bg-panel`, `text-fg-dim`, `rounded-ui`, `font-display`, `--core-grad-accent`, …): never a literal
colour, font family or radius, never a scoped style block in a kit component. Kit classes live in the
components layer, so a utility on a tag always wins. Chromium 103: no `:has()`, no `color-mix()`, no CSS
nesting, no container queries, no `dvh`, no Popover API, no individual `translate`/`rotate`/`scale`
(write `transform:`, never Tailwind's `translate-*`/`rotate-*`/`scale-*`). **Never `backdrop-filter`** —
it paints a black box in the CEF; glass is the `blur` prop (= `data-core-blur`) and only on panels
(CorePanel, CoreScreen/CoreBackground, CoreDialog, CoreDrawer, CorePopover), ≤ 12 on screen. Never write
`*/` inside a CSS comment and never spell the banned token in a source comment (Tailwind scans it).
The root font is 16px, body `--text-ui` (15px). The shell auto-hides on the pause menu and fades (§31);
a modal that is hidden is cancelled.

**Server files.** No `package.json` or `node_modules` inside a resource: FXServer's Node sandbox refuses to
read modules behind the symlinked resource path and the server's `yarn` builder would run on every start.
Node code now lives only in `core_db` (bundled: `npm run build -w core_db-build` from `resources/` → the
committed `core_db/dist/core_db.js`, first line `// fxlint-disable-file`); core itself ships no Node code.

**Manifest edits.** After adding a file to `fxmanifest.lua`: `refresh` on the server console, then
`restart core`, then `ensure core_example` (a dependant is stopped by the restart).

## 4. Writing a plugin

1. `core/scripts/new-plugin.sh <name>` (copies `templates/plugin`, replaces the placeholders). Manifest:
   `dependency 'core'` and `shared_scripts { '@core/import.lua', 'shared/config.lua' }`. That gives the
   global `Core` in every VM; wait for `Core.onReady(fn)` (server and client) or `Core.onPlayerLoaded(fn)`.
2. Libs run in *your* VM: `Core.Utils`, `Math`, `Validate`, `Log`, `Callback`, `Net`, `Commands`, `Keys`,
   `Streaming`, `Anim`, `Player` (client), `UI.on/off` (client), `Locale`, `Audio`, and (server only) `Core.DB`
   — the relational database lib, no export hop (§56). Everything else stateful goes through the proxy:
   `Core.Player(src)`, `Core.Money`, `Core.Factions`, `Core.Vehicles`, `Core.Doors`,
   `Core.Markers/Blips/TextLabels/Interactions.addGlobal/addFor`, `Core.UI.menu.open(src, …)`,
   `Core.UI.hide/show`, `Core.Chat`, `Core.Http`, `Core.Cron`, `Core.Stats`, `Core.Weapons`, `Core.Perms`.
   Signatures: README "API cheat sheet" and `types/core.lua`.
3. Server rules: register events with `Core.Net.on(name, schema, handler, opts)` (schema, cooldown, distance
   and permission are declarative in `opts`), commands with `Core.Commands.register`, RPC with `Core.Callback.register`.
   Persist with your own tables, migrated at file scope with `Core.DB.migrate({ 'sql/0001_init.sql' })` (§56.9)
   — never your own files, never a second database. Money only through `Core.Money`.
4. Client rules: interactions/markers through core's APIs (one scan loop for everyone), text UI through
   `Core.UI.textUI` (owner-tagged), keys through core's key mapping helpers.
5. UI plugin (§38): `ui/src/index.ts` default-exports `defineUIPlugin({ pages, setup })`, `ui/vite.config.ts`
   is `defineConfig({ plugins: [coreUI()] })`, the manifest gets `core_ui 'ui/dist'` + `files { 'ui/dist/**' }`.
   In a page: `usePage<Props, Out, In>()` (no id inside the component), `useNui<Rpc>()` for
   `invoke`/`handle`, `useScope()`, `useFeed<T>()`; in Lua `Core.UI.registerPage/open/send/on` plus
   `update`/`patch`/`feed`/`onRequest`/`request`. Build it from the kit (`<CoreScreen>`, `<CorePanel>`,
   `<CoreButton>`, `<CoreKeyHints>`, … — globally registered, so no import and no CSS of your own;
   `@reference "@core/ui/reference.css";` when a scoped block uses `@apply`; catalogue in DESIGN §37.5,
   README "Design system (UI kit)", `templates/plugin/ui/` and `core_example/ui/` are the worked examples).
   Check it with `node ui/tests/kit-compile-check.mjs <file>` and `npm run typecheck` in the plugin's `ui/`,
   then `npm run build` there and `restart <plugin>` — **never rebuild core for a plugin**. Dev loops:
   `npm run dev` (browser, real shell + mock Lua), `npm run build` + `restart` (in game), `npm run dev:game`
   + `/uidev <res> http://localhost:5173` (in game, HMR; needs `Config.UI.Dev.Enabled`). A story in
   `core/ui/src/stories` is welcome but not required for plugins.
6. Locale strings in `locales/<lang>.json` (list them in `files {}`), read with `Core.Locale.t`.
7. Test offline first (`fxlint <plugin>`, `luac5.4 -p`), then deploy (`fxserver deploy <dir>`), `refresh`,
   `ensure <plugin>`, and hand the in-game checklist to the human — agents do not test in-game.

`core_example` demonstrates every one of these (server callbacks, validated buy event, server menu, global
interaction, door, cron, locale, a compiled page).

## 5. Verification — run these yourself, do not trust a report

| what | command | expect |
|---|---|---|
| the whole offline gate (11 steps) | `scripts/check.sh` (`--full` adds the browser suites + Storybook) | exits 0 |
| the test database (prerequisite for the two DB rows below) | `scripts/test-db.sh up` (creates the role/database `core_test`/`core_test` in the `core-postgres` container, idempotent; `CORE_TEST_PG_URL` overrides the URL, default `postgres://core_test:core_test@127.0.0.1:5432/core_test`) | `test-db: ready (...)`; a suite that needs it and cannot reach it fails with "the test database is unreachable — run scripts/test-db.sh up" |
| libs and loader (suite `clock` included) | `lua5.4 tests/run_tests.lua` | `468 passed, 0 failed` |
| development services | `lua5.4 tests/{geometry,client_zones,client_actions,context_streaming,hooks,ui_forms}_tests.lua` (run each separately; `scripts/check.sh` does this) | respectively 190, 36, 74, 122, 94, 98 passed; 0 failed |
| admin platform (§41–§53) | `lua5.4 tests/{raycast,schema,settings,perms,buckets,audit,bans,targets,admin_api,registry_caller,client_registry_caller,client_adminstate,callback,maps,maps_store,client_maps,chat_hook}_tests.lua` (run each separately; `scripts/check.sh` does this) | respectively 100, 338, 218, 272, 48, 198, 286, 154, 349, 26, 31, 34, 34, 443, 267, 291, 52 passed; 0 failed (settings / perms / audit / bans / maps / maps_store re-baselined onto the DB bridge, §56.8 note 10) |
| scene streaming (§55) | `lua5.4 tests/{scene_codec,scene_motion,scene_server,scene_index,scene_interest,scene_audio,scene_voice,scene_promote,client_scene_cache,client_scene_mat,client_scene_kinds,scene_attach,scene_parked}_tests.lua` (run each separately; `scripts/check.sh` does this) | respectively 262, 328, 1100, 851, 582, 241, 290, 424, 636, 661, 600, 283, 604 passed; 0 failed (scene_server / scene_parked re-baselined onto the DB bridge) |
| scene benchmark (by hand) | `lua5.4 tests/scene_bench.lua [players] [nodes] [seconds] [nogc]` (defaults 2000 50000 30; `nogc` = a join storm's heap growth) | a result table, exit 0 — compare with DESIGN §55.7 notes (p50 1.50 / p99 7.55 ms per tick) |
| the scene probes, offline | `cd ../scene_probe && lua5.4 tests/probe_tests.lua`; `fxlint resources/scene_probe` | `scene_probe: 134 passed, 0 failed`; `0 error(s), 0 warning(s), 0 info(s)` |
| the DB lib over the bridge (§56.10.3: marshalling, every awaited/queued call, transaction/stream, migrate, removed-name errors) | `lua5.4 tests/db_tests.lua` (needs the test database) | `db: 273 passed, 0 failed` |
| server modules | `lua5.4 tests/server_tests.lua` (a thin driver over `server_harness.lua` + `tests/server/*.lua`; needs the test database) | `1568 passed, 0 failed` |
| client UI (focus stack, discovery, requests, patches, feeds, world prompts, HUD keys + feed, §41 input modes + hide policy + plain ids, §54 HUD hiding + key capture) | `lua5.4 tests/client_ui_tests.lua` | `client ui: 795 passed, 0 failed` |
| chat client | `lua5.4 tests/client_chat_tests.lua` | `client chat: 40 passed, 0 failed` |
| runtime + SDK units (the §55.16 audio engine's `audio-*.test.ts` included) | `node --test 'ui/tests/unit/**/*.test.ts' 'ui/sdk/tests/*.test.mjs'` (globs, never directories) | `# pass 377`, `# fail 0` |
| types | `npx vue-tsc --noEmit -p ui/tsconfig.json` | no output, exit 0 |
| generated kit tags | `node ui/scripts/gen-kit-types.mjs --check` | `up to date (71 kit components)` |
| every plugin's dist | `node ui/scripts/check-plugins.mjs` | `0 error(s), 0 warning(s)` for every discovered plugin |
| rulebook lint | `fxlint resources/core` (and the plugin) | `0 error(s), 0 warning(s)` |
| shell bundle | `cd ui && npm run build` | writes `html/`, no CSS warnings |
| a plugin's bundle | `npm run build -w <resource>-ui` (from `resources/`) | writes `<plugin>/ui/dist`, ~1 s |
| kit compile check | `node ui/tests/kit-compile-check.mjs` | `0 error(s)` |
| the three browser suites | `node ui/tests/run-browser-suites.mjs` (builds the fixtures, starts one origin per fixture resource, drives agent-browser; the servers must stay in its process tree) | `PASS 125/125`, `PASS 312/312`, `PASS 240/240` (shell, kit, runtime — section 15 of the runtime suite drives the real Web Audio engine) |
| Storybook | `cd ui && npm run build-storybook` | builds; play functions green |
| core_db (pool, catalog, sqlgen, helpers, tx, migrations, queue) | `node --test core_db/tests/*.test.mjs` (from `resources/`; or `node --test ../core_db/tests/*.test.mjs` from `core/`; globs, never a directory; needs the test database) | `# pass 81`, `# fail 0` |
| benchmarks | `node ui/tests/bench.mjs` | rewrites `ui/tests/BENCH.md` (never hand-edit it) |
| live | `fxserver logs --errors --resource core`, `fxclient logs --errors` | nothing new |

In-game diagnostics that exist for a reason: `/uiplugins` (every UI plugin's state — the first thing to look
at when a page stays blank), `/uidev <res> <origin|off>` and `/uiinspect` (both need `Config.UI.Dev.Enabled`),
`/uiblur diag` / `/uiblur test` (game blur state and hook recipes), `/doorfind` (door models, registered
doors), `/dbstatus` (console: `core_db` health, pool, queue and migrations, §56), `/id`, `/scene` and `/scene debug` (Core.Scene counters and the overlay:
the nearest nodes with their state — `Config.Scene.Debug`, ACE `core.admin` or staff on duty), `/audio` and
`/audiodebug` (world-audio preferences, the audio engine's voices, decoders and drift). Server side:
`Core.Scene.stats()` (flush ms p50 / p99, bytes per second, every module's counters). Inside the CEF: `nui_devtools` /
`localhost:13172`.

## 6. Change protocol

- Contract first: put the section in `DESIGN.md`, then implement, then README/types/Storybook/tests.
- New server logic ⇒ checks in `tests/server_tests.lua` (stubs in `tests/stubs.lua`); new lib ⇒
  `tests/run_tests.lua`; **new client UI logic (focus, discovery, requests, patches, feeds) ⇒
  `tests/client_ui_tests.lua`**; **new runtime behaviour ⇒ a `ui/tests/unit/*.test.ts` case AND a check in
  `ui/tests/runtime-regression.js`**; **SDK change ⇒ `ui/sdk/tests/*.test.mjs`** (and `contract.ts` + DESIGN
  §38 in the same commit); new shell action ⇒ a regression check and a story; **new kit component ⇒ a
  catalogue entry in DESIGN §37.5, its CSS in the group's `ui/src/kit/css/*.css` partial, a
  `Kit/<Group>/<Name>` story with a playground and a gallery scene, and a check in
  `ui/tests/kit-regression.js`** (plus the tag list in README's "Design system (UI kit)" and
  `ui/src/stories/docs/DesignSystem.mdx`).
- Every subagent gets exact file ownership; parallel runs never share a file; scratch files live in the
  session scratchpad under a run-named folder. Implementers report line counts and test results; the
  orchestrator re-runs lint and tests itself before believing them.
- Commits: `<area>: <imperative summary>` (`ui:`, `doors:`, `db:`, `client:`), body says *why*. `html/` and
  every `<plugin>/ui/dist/` are committed on purpose; `data/`, `node_modules/`, `storybook-static/` and
  `<plugin>/ui/.core-ui/` are not.
- Rebar was the inspiration for the API surface only. Never copy its code; FiveM's resource system, state
  bags and OneSync are the design, not an alt:V port.

## 7. Database

Relational Postgres behind a separate resource, `core_db` (§56) — no document store, no KVP, no MySQL adapter.
`Core.DB` (`lib/db/server.lua`, server only) has two call classes: **awaited** (`query single scalar execute
batch transaction stream nextId flush` + the table helpers `insert insertMany select first count update delete
upsert`) yield and answer `result | nil, err`; **queued** (`save patch remove append enqueue`) and `migrate`
never yield and answer `true | false, err`, landing within one flush interval, coalesced per row. Schema
changes are new numbered migration files only (`sql/000n_*.sql`, run with `Core.DB.migrate({ ... })` at file
scope) — immutable once applied, never edited in place. Back up with `pg_dump -Fc` / `pg_restore`; never
`restart core_db` on a live server (it stops core and every plugin with it) — restart `core` instead.

## 8. Gotchas we already paid for

- `files {}` / script globs only wildcard the LAST path segment (`ResourceMetaDataComponent.cpp`: the part before the
  last `/` must exist literally): `data/*/meta.json` matches nothing and the server warns "could not find file". Use
  `data/3751/*.json`, `**`, or explicit paths (admin's catalogue lists its build folder).
- FXServer caches manifests: `refresh` before `ensure` or a new file "does not exist". A NEW file under an
  existing `files {}` glob needs only `restart <res>`; a NEW manifest entry or resource folder needs `refresh`.
- The NUI render hook (game blur) binds unreliably on the first try; the shell re-issues the sequence on a
  backoff. Plain 0..1 texture mapping is upright in the client; FxDK's mirrored mapping is wrong here.
- Tailwind's `@source` needs a file glob (`…/*/ui/src/**/*.{vue,js}`); a bare directory matches nothing.
- An ES module is pinned in the document's module map **by URL** for the life of core's page: content-hashed
  file names are load-bearing, and re-importing one URL never runs new code.
- Vite's app build drops the entry's exports unless `preserveEntrySignatures: 'strict'` — the shell then
  reports "no `export default defineUIPlugin(...)`" for a build that looked perfectly fine.
- Tailwind refuses `theme(reference)` on a file that is not `@theme`-only: the tokens live alone in
  `ui/sdk/theme.css`, the `:root` recipes are host-only in `ui/src/recipes.css`.
- Tailwind's automatic source detection walks up to the **workspace root**: core's sheet must start with
  `@import "tailwindcss" source(none)` + explicit `@source` lines, or every plugin's utilities land in core.
- Tailwind scans `.js`/`.mjs` too, so a string inside JS that merely *looks* like a utility becomes real CSS.
  Build such needles from pieces (`'back' + 'drop'`) — the lint scripts and the regressions all do.
- `npm i typescript` installs TS 7 and breaks `vue-tsc` 3.3.x: TypeScript is pinned `^5.9.3`.
- `npm install -w` / `npm run -w` want the workspace **name** (`-w inventory-ui`), not the folder path.
- `node --test` needs globs, not directories: a positional directory is run as a module instead of searched.
- Production Vue hands `onErrorCaptured` an error-code URL instead of the message; the dev build has the text.
  A throw in an event handler runs in its own try/catch, so one bad listener never unmounts the page.
- In a first-party plugin's CSS, token **opacity modifiers** (`bg-error/15`) are fine — Tailwind emits a literal
  fallback and keeps the `color-mix()` behind `@supports`, which `coreUI()`'s lint accepts — but individual `translate-*`/`rotate-*`/`scale-*`
  utilities are still banned; Chromium 103 ignores them silently.
- Tailwind's rem scale assumes a 16px root; the shell keeps it and sets 14px on `body` only.
- Tailwind v4's `max-[…]:` / `min-[…]:` variants compile to media-query RANGE syntax (`width < 1700px`), which
  Chromium 103 does not parse — the rule silently never applies. Write the classic query through an arbitrary
  variant: `[@media(max-width:1699px)]:bottom-[22vh]` (Progress.vue, DESIGN §39.4).
- A skewed kit shape (`skewX` on a wrapper, content un-skewed inside): the inner `transform-origin` must be the
  OUTER shape's centre line, not the inner box's, or the two skews leave a horizontal offset of
  `tan(angle) · Δy` (CoreVital: 8.75 mockup px before it was found by overlaying the render on the mockup).
- A door whose model hash does not match the object at its coords controls nothing — `/doorfind`.
- State-bag change handlers never fire for keys that existed before the script started: seed on load.
- Console commands run as `src == 0`; devtools `fxclient exec --server` is that console.
- `SaveResourceFile` cannot create directories: `data/.gitkeep` keeps `data/` present for `/dbexport`.
- A BOOL native answers `false` or the INTEGER `1` (default invoke route) or a real boolean (direct route,
  `use_experimental_fxv2_oal`); a BOOL OUT-value is the integer `0`/`1` on the default route and `0` is truthy in
  Lua. Read returns by truthiness, out-values as `v == true or v == 1` — never `== true` / bare `not v` (DESIGN
  §30.4). A stub that answers `true` hides this: `Raycast.between` reported every miss as a hit for that reason.
- Page ids and feed channels must be PLAIN (`^[%w_%-]+$`, ≤ 64): the NUI → Lua `ui_event` bridge (page events,
  `escape`, `Core.UI.on`), requests and `UI.feed` channels/keys refuse anything else. `registerPage` used to accept
  `:` (a page `admin:panel` registered and then never heard an event); it refuses such ids now, and so does
  `Core.Admin`'s `page` field (DESIGN §41 notes).
- `<CoreSchemaForm :errors>` takes `Core.Schema.checkAll`'s map AS IS: `{ name = code }` with nested paths PREFIXED to
  the code (`{ list = '2.pos.min' }`, array rows 1-based) — not `{ ['list.2.pos'] = 'min' }` (flat path keys work
  too). The form's own check is advisory; the server's errors always win.
- **Awaited `Core.DB` calls yield** — re-check state after one (a session, a record, a cached flag) instead of
  trusting what you read before the call: another handler may have run in between (inventory's `Access.live`,
  maps' generation counter are the worked examples).
- An **empty Lua table crosses msgpack as `[]`**: a `jsonb` column that must stay an object on an empty write
  needs `Core.DB.json({})` cast `$n::jsonb` explicitly in raw SQL — the table helpers know each column's type
  and do this for you, but a raw `query`/`execute` does not.
- A raw queued `Core.DB.enqueue(sql, params)` (no `key`) is a **coalescing barrier**: every entry queued before
  it must flush before it and every entry queued after it waits behind it. A **keyed** one (`enqueue(sql,
  params, key)`) instead replaces the owner's older entry with that same key and runs at the newer position.
- Migration SQL **never qualifies a table with `public.`**: the test bridges run every suite in its own
  Postgres schema (`search_path = t_<pid>, public`), so a hard-coded `public.` breaks isolation and points at
  the wrong table under test.
- A plugin's legacy-collection import must **RAISE** while `core_documents` still exists for it (a plugin that
  has not migrated its own collections yet) — it must never silently skip and leave the plugin starting on an
  empty table (§56.7).
- `Core.Vehicles.setData`/`getData` are one **atomic SQL** `UPDATE`/`SELECT` on `vehicles.meta` — never read
  the record into memory, change `meta` there and write the whole record back: that races a concurrent
  `setData` and can drop its change.
- A **queued** write (`save`/`patch`/`append`) to a row with a foreign key is validated at enqueue time but
  applied later: if the referenced row is gone by the time the flush commits, the whole entry is **dropped**
  (`core:hook:dbWriteFailed`) — validate the reference yourself before queuing a write that depends on it
  (vehicles' `characterExists` check before persisting a car).
- A private hand-off between server files (Core.Admin → adminapi_dispatch.lua, bans_identity.lua → bans.lua, the four
  `server/maps*.lua` files, client/adminstate.lua before its readers) makes their manifest ORDER load-bearing: a
  file that asserts its predecessor errors at start when moved.
- The Registry caller is PER COROUTINE (DESIGN §2.3 note): inside a coroutine `getCaller()` is that coroutine's own
  entry or `'core'` — a thread started from a plugin's export call does NOT inherit the plugin. A test that simulates
  a plugin must set the caller inside the calling thread (`withCaller`), not on the main thread before it.
- `Core.Callback.await*` answers `nil, err` on a refusal (`rate_limit|schema|cooldown|permission|timeout|error`); a
  consumer that forwards results to a page must pass `err` on, or the UI cannot tell a refusal from an empty answer.
- Staff state (duty, modes) is never a state bag — every client could read who is vanished. It goes by event to the
  player and the on-duty staff (`client/adminstate.lua`); `duty`/`staffModes` stay reserved in `CORE_STATE_KEYS`.
- `SetEntityDrawOutline` on a PED (NPC or player) crashes the client: FiveM's outline pass calls the ped's draw handler
  outside the scene and the render thread resolves a null draw-list address (`GTA5+16CE6CD`, citizenfx/fivem#1425; the
  admin inspector did it on 2026-09-26). Objects, vehicles and buildings are fine. Check `GetEntityType(e) ~= 1` before
  every outline; the native's own docs call it SDK-only.
- Only ONE exclusive page (`type = 'page'`) is open at a time: `UI.open` of another one closes the first. Its owner
  hears `closed { reason = 'replaced', by }` (DESIGN §41 notes) — a page that runs a camera or holds controls must
  handle it (the admin editor parks and re-opens when the page on top closes) or the player soft-locks.
- `GetEntityArchetypeName` throws ("exception at address extra-natives-five.dll") for an entity without an archetype
  — FiveM reads `entity->GetArchetype()->hash` with no null check. Call it through `pcall` wherever the entity comes
  from a ray / pick / pool (the admin editor's LMB binding died on it).
- A Lua table sent as JSON whose keys are digit strings becomes a LIST in the browser; key such maps with a prefix
  (the admin editor keys elements `'e' .. id`).
- A STATEFUL function on a LIB namespace (`Core.Keys.capture`, DESIGN §54) must never be defined by the lib file: the lib
  runs in every VM and the import.lua proxy only fills in what the lib table LACKS. core defines it on its own copy
  (client/ui.lua), plugins reach it through the proxy. The proxy caches each closure with `rawset`, so `rawget` on a
  plugin's lib table cannot tell a lib function from a proxied one — test `capture`, not a name a press already used.
- The `call` export's first argument is only a DECLARATION: the owner is `GetInvokingResource()` on both sides and a
  mismatching name is refused (DESIGN §2.2). A test that calls `stubs.exports.core.call(name, …)` directly acts as
  `name` (no invoking resource); one that goes through `env.exports.core:call(…)` acts as that VM's resource.
- `IsHudHidden()` / `IsRadarHidden()` are pure read-backs of the `DISPLAY_HUD` / `DISPLAY_RADAR` flags (GTA
  `commands_hud.cpp`), so core's own `DisplayHud(false)` (§54 `Core.UI.hideHud`) reads as "the game hid the HUD": the §31
  `hud` watcher excludes it, or `Config.UI.AutoHide.HudHidden = true` would hide the whole shell and close the editor.
- GTA fades EVERY entity over the 20 m just past `lodDist × GetLodscale()` (5 m when lodDist ≤ 20) — script objects
  included; creating one only switches its CREATION fade off. An object created inside that band shows at the band's
  alpha (a pop), one deleted inside it vanishes at ≈ 25 % alpha. Create beyond `lod·S + 20 m + margin`, delete beyond
  that + hysteresis, and the engine fades for free (DESIGN §55.0, §55.22; research R3 §1 / R9 §5.3; probe P1).
- `SetEntityAlpha` holds one of **256 alpha-override slots game-wide** (shared with every script and the netcode) until
  `ResetEntityAlpha`; below alpha 50 nothing is drawn (ramps start at 51); props and peds fade screen-door, vehicles in
  true alpha. Budget the fades (`Fades.Max` 48) and end a fade-in with `ResetEntityAlpha` (R2 §C11). The entity's
  deletion frees its slot as well (engine behaviour, research R5 §1), so a fade-out may end in a plain delete — never
  reset the alpha of an entity that is still drawn for another frame (it flashes opaque); probe P4 confirms it in game.
  `NetworkFadeInEntity` / `NetworkFadeOutEntity` do NOTHING on local entities.
- `GetNetworkTimeAccurate()` (client) is OneSync's network time on the server's `GetGameTimer()` timeline (±5–20 ms):
  the one shared clock, `Core.Clock`. It reads 0 until the first sync (`Core.Clock.ready()`), and the Lua values go
  negative after 24.9 days and wrap at 2^32 — mask with `& 0xFFFFFFFF` and compare only with `Core.Clock.diff`
  (signed 32-bit), never `<`. Scene node and cell versions wrap too (to 1) and use the same serial arithmetic.
- Latent events (`TriggerLatentClientEvent`) are paced and UNORDERED relative to reliable events: a big pack can land
  before the reliable SUB that announced it, or long after newer changes. Version everything and let versions decide
  (the scene client parks a pack that beats its SUB). Probe P12 measures it.
- The scene stream's `RESET` op inside an unfinished CELL / PRIV section makes the decoder answer `'truncated'` (the
  rest of the section would land on dropped state): the flush puts RESET FIRST and clears that client's queued outbox.
- FiveM's `msgpack` packs a sequence with an `n` key (the `table.pack` shape) as an ARRAY and DROPS `n`, and packs the
  empty table `{}` as an empty ARRAY (0x90) — an empty map arrives as an array. Never mix a sequence with `n` in a blob;
  read `{}` and `[]` alike (shared/scene_codec.lua's pure-Lua fallback writes the same bytes).
- Lua 5.4 allows at most 200 local variables per function, and a big module's main chunk counts every top-level
  `local`: past it the file stops compiling ("too many local variables (limit is 200) in main function"). Group settings
  and cold-path lookups into one table (`K`, `T` in client/scene_materializer.lua) or split the file along a one-shot
  hand-off (DESIGN §55.1 notes).
- `AttachEntityToEntity` takes 16 arguments (the last three: rotationOrder, fixedRot, p15) — pass all of them: core runs
  `use_experimental_fxv2_oal`, and `tests/client_scene_harness.lua` asserts exactly 16.
- Voice (client/scene_voice.lua, from the FiveM and pma-voice sources, R2 §B6–§B8; probe P10 confirms in game): a
  talker's Mumble volume override or submix that CHANGES recreates his voice (a 20–40 ms dropout; the same value is a
  no-op) — set both ONCE per session and animate only `SetAudioSubmixOutputVolumes`. `AddAudioSubmixOutput(id, 0)` must
  come BEFORE the first `SetAudioSubmixOutputVolumes` (pma-voice has the order backwards, so its volumes never apply); a
  submix routes a voice only with `setr voice_useNativeAudio true`; submix ids are never freed (no destroy native) —
  create one fixed pool at start and cache it by name.
- `GetAnimDuration` answers SECONDS (the Rockstar header), not milliseconds. Server `GetEntityHealth` answers 0 until a
  client has synced the entity — a "destroyed" check on a fresh clone must wait for the first sync.
- `PerformHttpRequest` buffers the whole response: pointed at a live stream it never completes and grows without end.
  The server never fetches a stream body — the codec comes from the extension or the Icecast `status-json.xsl`.
- Chromium's `decodeAudioData` allocates float PCM for the file's WHOLE duration at the context rate, whatever the
  compressed size (1 MB of 6 kbps Opus = ~550 MB): bound the DECODED size before decoding, never trust a byte cap
  (ui/src/runtime/audio/loader.ts, review RV3 F9).
- Core code that creates scene nodes for core (the maps projector, Core.Attachments, parked cars) calls Core.Scene
  AS CORE — `Registry.withCaller('core', Scene.spawn, …)`. Called plainly, the node belongs to whichever plugin's
  export call triggered it and is swept (or refused as `'owner'`) when that plugin stops. Core's node budget is
  `Config.Scene.OwnerCaps.core`.
- Since phase D a persisted car's netId is NOT stable: parking deletes the entity (a scene node takes over) and every
  promotion makes a new clone. Key cars by `vehId`; `vehicleDeleted` / `vehicleSpawned` fire at every park and
  promotion; a plain `DeleteEntity` on a clone brings the car back at its parking spot (use `Vehicles.delete` /
  `store`); entity state bags set on a clone are gone after it parks (DESIGN §4.6 notes).
- Config that "whoever owns the entity" applies from a state bag is applied again at EVERY owner change. Split it: the
  cosmetic part is idempotent and every owner re-applies it; the one-shot part (a vehicle clone's wear, lock and dirt,
  `snCfg.once`) is applied once and acknowledged on its OWN event (`core:scene:applied(id)` — never behind a cooldown
  shared with other reports, which silently drops it; the client re-sends while the bag still carries it) and the
  server strips it — or the next owner resets damage, fuel and a lock that changed since.
- A model hash comes as a SIGNED int (`GetHashKey`), an unsigned u32 or a `'0x%08X'` string (the scene's string
  form): normalise before creating or comparing (`R.promote.modelHash` server side, `hashOf` in client/scene_kinds.lua).
- The admin catalogue (the Maps model validator) is not a list of every model: weapon objects and addon models are
  missing. It must never gate a scene spawn — only a `Scene.setModelInfo` provider answering `false` refuses a model;
  Maps enforces its allow-list when an admin applies an element (DESIGN §55.12 notes).
- Work that needs promoted clones alive when core stops registers `R.promote.beforeStop(fn)` — never rely on the order
  of core's own `onResourceStop` handlers (parked cars hand their clones' poses to their nodes there).
- Native NAMES: fxref (nativedb) prints names the FiveM runtime never generates — client/vehicles.lua called 12 of them
  (`GetVehicleExtraColour_5`, `GetVehicleLivery2`, the xenon and neon colour names, …) and `getProps` raised in game
  while every offline suite passed (the stubs define whatever you call). Check the name against
  `fivem-dev-kit/data/cache/natives.json` / `natives_cfx.json` (the runtime's Lua names and aliases), not only fxref.
- `GetEntityAlpha` shows the engine's LOD fade only for an entity the engine SCANS (on screen, inside `lodDist × S` +
  the band); a culled or off-screen entity keeps its last value — 255 from its creation. Probe P1 read that stale 255 as
  a "pop"; count only frames where the entity is in view and inside the band.
- The CLIENT Lua VM has no `os` library at all (`os.clock`, `os.time` are nil — the server has them): time client code
  with `GetGameTimer()` / `Core.Clock` (probe P6 crashed on `os`).
