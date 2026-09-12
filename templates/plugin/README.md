# `my_plugin` — plugin template for `core`

A copy-me skeleton for a resource that builds on the `core` framework: manifest, shared config,
client and server entry points, and an optional Vue page. Everything in it is either a
one-line stub or a commented example — nothing runs until you uncomment it.

## 1. Copy and rename

```bash
cp -r core/templates/plugin resources/my_plugin        # next to core/, not inside it
cd resources/my_plugin
grep -rl my_plugin . | xargs sed -i 's/my_plugin/shop_robbery/g'   # your resource name
```

The name you pick must match in three places (the `grep`/`sed` above covers all of them):

| Place | What it is |
|---|---|
| the folder name | the resource name FXServer starts |
| `ui/src/index.js` → `export const id = 'my_plugin'` | the page id |
| `client/main.lua` → `Core.UI.registerPage('my_plugin', …)` | the same page id |

Event names (`my_plugin:server:doThing`) are yours; prefix them with the resource name so two
plugins never collide. Also set `author`, `description` and `version` in `fxmanifest.lua`.

Start it after core:

```cfg
ensure core
ensure my_plugin
```

`dependency 'core'` in the manifest enforces the order, and `@core/import.lua` gives every file
in the resource the global `Core` table. Restarting `core` does not break the plugin: registrations
inside `Core.onReady` are replayed automatically.

## 2. Write the plugin

- `shared/config.lua` — the resource's `Config` global, loaded in both VMs.
- `client/main.lua` — everything that registers *into* core (markers, blips, text labels,
  interactions, UI pages) inside `Core.onReady`; keys, callbacks and net handlers at file scope.
- `server/main.lua` — `Core.Net.on` handlers, `Core.Callback.register`, `Core.Commands.register`.
  The server owns money, factions and vehicles; the client only ever asks.

Split into more files when it grows — `client/*.lua` and `server/*.lua` are globbed by the manifest.

## 3. Add a UI page (optional)

Only if the plugin shows a page — and it ships **no UI files**: no Vite config, no `dist`, no
`node_modules`, no `files {}` entry. `ui/src/index.js` names the page and exports the component;
core's shell compiles it into its own bundle, so players download `core/html` and nothing else.

```js
// ui/src/index.js
export const id = 'my_plugin'
export { default } from './Page.vue'
```

The toolchain is installed **once for the whole resources folder** — it is an npm workspace, so
there is a single hoisted `node_modules` next to `core/`:

```bash
cd /path/to/resources && npm install    # once
cd core/ui && npm run build             # -> core/html, with every plugin page inside
```

Then:

1. uncomment the `Core.UI.registerPage('my_plugin', { type = 'page' })` call in `client/main.lua`
   (no `script`/`style` paths — core already has the component);
2. open it from Lua with `Core.UI.open('my_plugin', { title = 'Hi' })` and receive the page's
   events with `Core.UI.on('my_plugin', 'hello', function(data) end)`.

Rebuild **core's** UI after every page change, then `refresh; restart core`. While developing,
`cd core/ui && npm run dev` (Vite, port 5173) and `npm run storybook` serve these sources live.

Inside the page, `window.CoreUI.usePage(id)` gives `{ props, emit, on, close }` and
`window.CoreUI.hud` is the live HUD snapshot; `import ... from 'vue'` resolves to the one Vue
instance the shell owns. No external fonts or CDNs: the CEF has no network.

Need an extra runtime library (drag-and-drop, charts, …)? Copy `ui/package.json.example` to
`ui/package.json`, keep only that one dependency, and re-run `npm install` at the resources
folder — the import is bundled into the same single dist. Never list `vue` there.

### Styling — Tailwind CSS v4

Nothing to install, nothing to configure, no CSS file of your own. Core's stylesheet is Tailwind v4
(CSS-first, `@tailwindcss/vite`) and it scans **your** sources too — `@source "../../../*/ui/src/**/*.{vue,js}"`
in `core/ui/src/styles.css` — so every utility your page uses is emitted into core's single bundle.

```vue
<div class="core-panel core-interactive w-[380px] font-sans text-fg">
    <h1 class="core-title">my_plugin</h1>
    <p class="text-ui-sm text-fg-dim">Plain utilities, plus core's own tokens.</p>
    <button class="core-btn core-btn--primary mt-3" @click="close()">Close</button>
</div>
```

The shell's design tokens are ordinary utilities (opacity modifiers such as `bg-accent/10` work too):

| group | utilities |
|---|---|
| surfaces | `bg-panel` `bg-panel-solid` `bg-panel-raise` `bg-backdrop` |
| hairlines | `border-border` `border-border-strong` |
| text | `text-fg` `text-fg-dim` `text-fg-faint` |
| accent and states | `text-accent` `bg-accent-soft` `text-success` `text-error` `text-warning` `text-info` |
| shape | `rounded-ui` (8 px) `rounded-ui-sm` (5 px) `shadow-ui` `ease-ui` |
| type | `font-sans` `font-mono` · `text-ui` (14 px) `text-ui-sm` (12 px) `text-ui-xs` (10 px) |

The `.core-*` component classes give a page the exact look of the built-in menus and dialogs:
`core-panel` `core-modal` `core-backdrop` `core-title` `core-text` `core-label`
`core-btn` (+ `core-btn--primary` / `--ghost` / `--danger`) `core-field` `core-input` `core-select`
`core-check` `core-key` `core-list` `core-item` (`.is-active` / `.is-disabled`) and `core-interactive`
(`pointer-events: auto`, which a page needs because the shell is click-through).

A scoped `<style>` block is compiled on its own, so `@apply` has to be pointed at the theme first —
the path is relative to **your** `ui/src/`:

```vue
<style scoped>
@reference "../../../core/ui/src/styles.css";   /* <plugin>/ui/src -> resources/ -> core */

.card { @apply rounded-ui-sm border border-border bg-panel-raise px-2.5 py-2; }
</style>
```

`@reference` only reads that file (tokens, `.core-*`, custom utilities) and emits nothing, so the
bundle keeps one copy of the CSS. Utilities written in the template need no `@reference`.

**Never use `backdrop-filter` / `-webkit-backdrop-filter` or Tailwind's `backdrop-*` utilities** —
the game frame is not part of the CEF's compositing surface, so FiveM paints the filtered area as a
solid black box. For a glass panel put **`data-core-blur`** on the panel element instead: core draws
a live, blurred copy of the game frame behind it, no JavaScript needed (`data-core-blur="18"` for a
custom radius, `--core-glass-tint` for a custom tint). Panels only — never list rows. See core's
README, "Game blur (glass panels)".

New classes only reach the game after core's UI is rebuilt (`cd core/ui && npm run build`).

## 4. Where the APIs are documented

`../../DESIGN.md` is the contract; `../../README.md` is the integrator guide and cheat sheet.

| Topic | Section |
|---|---|
| Manifest, load order, `Core` global | §1, §2 |
| `Core.onReady`, hooks, restarts | §2.4 |
| Utils / Math / Validate / Log | §3.1–§3.4 |
| `Core.Callback`, `Core.Net`, `Core.Commands` | §3.5–§3.7 |
| `Core.Keys`, `Core.Streaming`, `Core.Anim`, client `Core.Player` | §3.8–§3.11 |
| `Core.DB`, `Core.Player`, `Core.Money`, `Core.Perms`, `Core.Factions` (server) | §4.1–§4.5 |
| `Core.Vehicles`, `Core.Notify` (server) | §4.6, §4.7 |
| What a net event is allowed to do (security table) | §5 |
| `Core.Spawn`, markers, text labels, blips, interactions, raycast (client) | §6.1–§6.9 |
| `Core.UI` (notify, text UI, progress, menu, input, alert, pages) | §6.10 |
| Page bundles and `window.CoreUI` | §7.4 |
| State bags and `GlobalState` keys | §8 |
| Performance budget | §9 |
| A full worked example | `core_example/` and §11 |
