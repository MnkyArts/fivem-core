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

`ui/src/Page.vue` in this template is a working page built from the kit (next section) — read its
comments, keep the shape, replace the content.

Need an extra runtime library (drag-and-drop, charts, …)? Copy `ui/package.json.example` to
`ui/package.json`, keep only that one dependency, and re-run `npm install` at the resources
folder — the import is bundled into the same single dist. Never list `vue` there.

### Styling — the UI kit

Nothing to install, nothing to configure, **no CSS file of your own**. Core ships a design system
(`DESIGN.md` §37): ~60 components registered globally on the shell's Vue app, so your page just
writes the tags and looks like the rest of the server:

```vue
<CoreScreen background="scrim">
    <CorePanel title="my_plugin" subtitle="What this page is for" blur>
        <template #actions><CoreIconButton icon="close" label="Close" variant="ghost" @click="close()" /></template>
        <CoreKeyValue :items="[{ label: 'Player', value: hud.name, icon: 'user' }]" />
        <template #footer>
            <CoreKeyHints bare :items="[{ key: 'ESC', label: 'Close' }]" />
        </template>
    </CorePanel>
</CoreScreen>
```

| group | components |
|---|---|
| actions | `CoreButton` `CoreIconButton` `CoreKey` `CoreKeyHint` `CoreKeyHints` `CorePrompt` `CorePromptGroup` |
| surfaces | `CorePanel` `CoreScreen` `CoreBackground` `CoreCard` `CoreHeading` `CoreDivider` `CoreDash` `CoreTagline` `CoreBrand` |
| navigation | `CoreTabs` `CoreMenu` `CoreChips` `CoreStepper` |
| forms | `CoreField` `CoreInput` `CoreTextarea` `CoreNumberInput` `CoreSelect` `CoreCheckbox` `CoreRadioGroup` `CoreRadio` `CoreSwitch` `CoreSlider` `CoreSwatches` |
| data | `CoreProgress` `CoreRing` `CoreStatBar` `CoreStatRow` `CoreSpinner` `CoreSkeleton` `CoreBadge` `CoreTag` `CoreAvatar` `CorePlayerChip` `CoreTable` `CoreKeyValue` `CoreEmpty` |
| game | `CoreSlot` `CoreSlotGrid` `CoreHotbar` `CoreList` `CoreListItem` `CoreObjective` `CoreTracker` `CoreCompass` |
| feedback | `CoreAlert` `CoreToast` `CoreDialog` `CoreDrawer` `CorePopover` `CoreContextMenu` `CoreTooltip` |
| foundation | `CoreIcon` (185 glyphs; `window.CoreUI.kit.registerIcons({ 'my-icon': 'M…' })` adds yours) |

Props follow one vocabulary: `size` (`sm|md|lg`), `tone`, `icon`, `disabled`, `v-model`, `items`.
The full API is `DESIGN.md` §37.5, the live version is core's Storybook (**Kit → …**, plus
**Docs → Design System**), and core's README has the same list with a page example.

For the bits the kit does not cover, Tailwind v4 is there (CSS-first, no config file): core's
stylesheet scans **your** sources — `@source "../../../*/ui/src/**/*.{vue,js}"` in
`core/ui/src/styles.css` — so every utility your page uses lands in core's single bundle. Layout
utilities (`flex`, `gap-*`, `w-*`, `mt-*`) on a kit tag always win over the kit's own rule.
**Colours, fonts and radii come from core's tokens, never from a literal value:**

| group | utilities |
|---|---|
| surfaces | `bg-ink` `bg-panel` `bg-panel-solid` `bg-panel-raise` `bg-panel-sunken` `bg-hud` `bg-backdrop` |
| hairlines | `border-border` `border-border-strong` |
| text | `text-fg` `text-fg-dim` `text-fg-faint` |
| accent and states | `text-accent` `bg-accent-soft` `text-success` `text-error` `text-warning` `text-info` |
| vitals and rarity | `text-health` `text-armour` `text-stamina` `text-hunger` `text-thirst` · `text-rarity-rare` `…-epic` `…-legendary` |
| shape | `rounded-ui` (6 px) `rounded-ui-sm` (4 px) `rounded-ui-xs` (3 px) `shadow-ui` `shadow-glow` `ease-ui` |
| type | `font-sans` (Barlow) `font-display` (Barlow Condensed) `font-mono` · `text-ui` (15 px) `text-ui-sm` (13 px) `text-ui-xs` (11 px) · `text-display` (24 px) `text-display-lg` (34 px) |

Class names work too — `core-panel` `core-btn` `core-input` `core-key` `core-label` `core-eyebrow`
`core-display` `core-text` and `core-interactive` (`pointer-events: auto`, which a plain `<div>` of
your own needs because the shell is click-through).

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

**FiveM's CEF is Chromium 103**: no `:has()`, no `color-mix()`, no CSS nesting, no container
queries, no `dvh`, no Popover API, and Tailwind's `translate-*` / `rotate-*` / `scale-*` utilities
emit properties Chrome only learned in 104 — write `[transform:translateX(-50%)]`.

**Never use `backdrop-filter` / `-webkit-backdrop-filter` or Tailwind's `backdrop-*` utilities** —
the game frame is not part of the CEF's compositing surface, so FiveM paints the filtered area as a
solid black box. For a glass panel pass **`blur`** to a kit panel (or put `data-core-blur` on your
own element): core draws a live, blurred copy of the game frame behind it, no JavaScript needed
(`:blur="18"` for a custom radius, `--core-glass-tint` for a custom tint). Panels only — never list
rows, and 12 or fewer on screen. See core's README, "Game blur (glass panels)".

Check the page without a build: `node ../core/ui/tests/kit-compile-check.mjs ui/src/Page.vue`.
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
