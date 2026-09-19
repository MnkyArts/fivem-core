// Game blur (DESIGN §32) — the glass every `data-core-blur` panel gets.
//
// A CSS backdrop filter cannot see the game: the NUI page is transparent and there is nothing
// behind it inside the CEF. FiveM's NUI core instead hands the game's back buffer to WebGL
// (the same hook the FiveM main menu draws its blurred background with), so `gameblur.js`
// copies that frame into one small canvas at `Fps` and puts a blurred crop of it behind every
// element carrying the attribute. In a browser there is no hook, so the module falls back to a
// procedural dusk gradient — `<html data-game-blur="fallback">` — which is what you see here
// and what the play function asserts.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import App from '../App.vue'
import { send, liveScene, store, clone, HOLD_MS } from './storeHelpers.js'

const view = () => h(App)

let seq = 0
const rid = (p) => 'sb-blur-' + p + '-' + ++seq

/** The one message the controls drive — exactly what client/ui.lua sends on `ui_ready`. */
const setBlur = (args) => send({
  action: 'blur:set',
  enabled: args.enabled,
  strength: args.strength,
  fps: args.fps,
  scale: args.scale,
})

/** Every PANEL in this scene is a blur consumer, so they can be compared against each other:
 *  the stat plate, the toast card, the text UI pill and the menu panel all carry the attribute.
 *  The vitals strip deliberately does NOT — its plates are opaque white and its tile is a flat
 *  dark shape (§39.2), so it is in the picture only to show what a non-consumer looks like next
 *  to glass. The menu and the toast are only sent once — dragging a slider must not reopen the
 *  modal or make the toast's count badge climb; the glass follows `blur:set` alone. */
function blurScene (args) {
  send({ action: 'hud:set', visible: true, health: 86, armour: 64, talking: false })
  send({
    action: 'stats:set',
    hunger: { value: 72, min: 0, max: 100, label: 'Hunger', slot: 'health', icon: 'hud-food' },
    thirst: { value: 41, min: 0, max: 100, label: 'Thirst', slot: 'armour', icon: 'hud-drink' },
    stress: { value: 58, min: 0, max: 100 },
  })
  if (!store.notifications.length) {
    send({
      action: 'notify',
      id: rid('n'),
      type: 'info',
      title: 'Dispatch',
      message: 'Every panel here carries data-core-blur — the rail, the pill and the modal.',
      duration: HOLD_MS,
    })
  }
  send({ action: 'textui:show', key: 'E', text: 'Search the vehicle', position: 'bottom' })
  if (!store.menu.visible) {
    send({ action: 'menu:open', id: rid('m'), title: args.menuTitle, items: clone(args.items) })
  }
  setBlur(args)
}

export default {
  title: 'Shell/Game blur',
  component: App,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'One hidden source canvas holds the current game frame; each consumer gets a '
          + '`.core-glass` wrapper (`z-index: -1`, inset 0) holding a canvas that is `drawImage`d '
          + 'from the matching region of that source and CSS-blurred. The wrapper also paints the '
          + 'panel tint (`--core-glass-tint`), because inside an isolated element a negative-z '
          + 'child would otherwise sit *above* the element\'s own `bg-panel`.',
      },
    },
  },
  argTypes: {
    enabled: {
      control: 'boolean',
      description: '`Config.UI.Blur.Enabled` / `Core.UI.setBlur(bool)`. Off removes every '
        + '`.core-glass` wrapper and stops the frame loop completely — zero cost, not a paused one.',
      table: { category: 'blur:set' },
    },
    strength: {
      control: { type: 'range', min: 0, max: 40, step: 1 },
      description: 'Blur radius in CSS px (clamped 0–40). `data-core-blur="18"` overrides it for '
        + 'one panel; `data-core-blur="0"` switches that panel off.',
      table: { category: 'blur:set' },
    },
    scale: {
      control: { type: 'range', min: 0.1, max: 1, step: 0.05 },
      description: 'Resolution of the copy (0.1–1). It is blurred anyway, so 0.5 is the default — '
        + 'a quarter of the pixels.',
      table: { category: 'blur:set' },
    },
    fps: {
      control: { type: 'range', min: 5, max: 60, step: 5 },
      description: 'Frames per second of the copy loop (5–60). `setTimeout`, never '
        + '`requestAnimationFrame` at full rate.',
      table: { category: 'blur:set' },
    },
    menuTitle: { control: 'text', table: { category: 'menu:open' } },
    items: { control: 'object', table: { category: 'menu:open' } },
  },
  args: {
    enabled: true,
    strength: 10,
    fps: 30,
    scale: 0.5,
  },
}

export const Glass = {
  name: 'Glass panels',
  args: {
    menuTitle: 'Vehicle — Buffalo STX',
    items: [
      { label: 'Engine', description: 'Toggle the engine on or off', icon: '⚙', value: 'engine' },
      { label: 'Doors', description: 'Open or close a single door', icon: '🚪', value: 'doors' },
      { label: 'Search boot', description: 'Takes 20 seconds', icon: '📦', value: 'search' },
      { label: 'Impound', description: 'Police only', icon: '🚔', value: 'impound' },
    ],
  },
  parameters: {
    lua: {
      message: 'blur:set (+ hud:set + stats:set + notify + textui:show + menu:open)',
      call: '-- shared/config.lua: the only knobs. client/ui.lua sends them once on ui_ready\n'
        + '-- and again on every Core.UI.setBlur call — nothing is polled per frame.\n'
        + 'Config.UI.Blur = { Enabled = true, Strength = 4, Fps = 30, Scale = 0.5 }\n'
        + '\n'
        + '-- client: session-scoped override of Enabled, re-sent when the NUI reloads\n'
        + 'Core.UI.setBlur(false)   -- drop the glass for this player, this session\n'
        + 'Core.UI.setBlur(true)    -- and back\n'
        + 'Core.UI.setBlur(true, { strength = 3 })   -- numeric strength/fps/scale overrides\n'
        + '-- in-game tuning without a restart: /uiblur 3 [scale] [fps], /uiblur off|on\n'
        + '\n'
        + '-- A plugin page needs no JavaScript at all; the attribute IS the API:\n'
        + '--   <section class="core-panel" data-core-blur>       -- Config.UI.Blur.Strength\n'
        + '--   <section class="core-panel" data-core-blur="18">  -- 18 px for this panel only\n'
        + '--   <section class="core-panel" data-core-blur="0">   -- no glass on this panel\n'
        + '-- and `style="--core-glass-tint: rgba(20,14,14,.66)"` recolours the panel above it.',
      note: 'Fire and forget: `blur:set` has no NUI callback. One small canvas copy per consumer '
        + 'per frame, so consumers are panels — never list rows or per-item elements — and the '
        + 'shell keeps its own count at 12 or fewer on screen.',
    },
    docs: {
      description: {
        story: 'The stat plate, the toast card, the `[E]` pill and the menu panel are all blur '
          + 'consumers — the vitals strip bottom left is not, by design. Drag **strength** and '
          + 'watch the gradient behind the panels soften; **scale** '
          + 'changes how many pixels are copied (it is blurred anyway, so 0.5 is plenty) and '
          + '**fps** how often. Turning **enabled** off removes every `.core-glass` wrapper and '
          + 'stops the loop — the panels fall back to their flat `bg-panel`.\n\n'
          + 'In this browser there is no FiveM render hook, so the source is the fallback '
          + 'gradient (`<html data-game-blur="fallback">`) painted in the same colours as the '
          + 'preview backdrop. In game it is the live frame at `Fps`.',
      },
    },
  },
  render: liveScene(blurScene, view),
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    // The menu is a CoreDialog now (§37.6) — its root is `.core-dialog`, and `class="menu"`
    // falls through onto that panel (CoreDialog is `inheritAttrs: false`).
    const panel = () => canvasElement.querySelector('.core-dialog.menu')
    const glasses = () => document.querySelectorAll('.core-glass')

    await waitFor(() => expect(canvas.getByText(args.menuTitle)).toBeInTheDocument())
    // No hook outside the CEF: the module probes once, sees the placeholder colour and paints
    // its own gradient instead. `off` would mean no WebGL at all.
    expect(document.documentElement.dataset.gameBlur).toBe('fallback')

    // The MutationObserver picks the panel up and the first frame draws into its canvas.
    await waitFor(() => expect(panel().querySelector('.core-glass canvas')).toBeTruthy(), { timeout: 1500 })

    send({ action: 'blur:set', enabled: false })
    await waitFor(() => expect(glasses().length).toBe(0))
    expect(canvas.getByText(args.menuTitle)).toBeInTheDocument() // the panel itself is untouched

    setBlur(args) // back to whatever the controls say, so the story stays pokeable
    if (args.enabled) await waitFor(() => expect(glasses().length).toBeGreaterThan(0))
  },
}
