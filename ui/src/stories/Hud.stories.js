// The vitals HUD (DESIGN §39) — the mic tile, the HEALTH plate and the ARMOR plate as one
// strip next to the minimap, with the food / drink bars cut out of the two plates.
//
// Lua side: nothing calls this by hand either. `client/hudfeed.lua` ticks at 100 ms while the
// HUD is visible, reads `MumbleIsPlayerTalking` every tick and health / armour every 250 ms,
// and pushes ONLY what changed through `Core.UI.hud.set` — an idle, silent player sends
// nothing. The bars come from the stats bag: a `Config.Stats` def with `hud = 'health'` /
// `'armour'` arrives in `stats:set` carrying a `slot`, and that is what puts it under a plate
// instead of in the rail. Output only; the whole strip is `pointer-events: none`.
import { h } from 'vue'
import { expect, waitFor } from 'storybook/test'
import Hud from '../shell/Hud.vue'
import { resetExtras } from '../store.js'
import { send, liveScene, note } from './storeHelpers.js'

// §39.4: the strip places itself (`position: fixed`, `hud.anchor`) — App.vue hangs it straight
// in `.core-root`, not in the top-right rail, so the story needs no wrapper at all.
const view = () => h(Hud)

/** The two defs core ships, both slotted under a plate. `null` sends no `stats:set` at all. */
function stats (args) {
  if (args.hunger === null || args.thirst === null) return null
  return {
    hunger: { value: args.hunger, min: 0, max: 100, label: 'Hunger', slot: 'health', icon: 'hud-food' },
    thirst: { value: args.thirst, min: 0, max: 100, label: 'Thirst', slot: 'armour', icon: 'hud-drink' },
  }
}

/** One `hud:set` + one `stats:set`, exactly the two messages the game sends. */
const build = (args) => {
  resetExtras()
  send({
    action: 'hud:set',
    visible: args.visible,
    health: args.health,
    armour: args.armour,
    talking: args.talking,
    muted: args.muted,
    anchor: args.anchor,
    scale: args.scale,
  })
  const table = stats(args)
  if (table) send(Object.assign({ action: 'stats:set' }, table))
}

const show = liveScene(build, view)

const vital = (el, which) => el.querySelector('.hud__vital.is-' + which)
const cssVar = (el, name) => (el ? el.style.getPropertyValue(name).trim() : null)

export default {
  title: 'Built-ins/HUD',
  component: Hud,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'One parallelogram per vital, its bottom slice cut off and used as the food / '
          + 'drink bar (§39.1). The value never becomes a width: `--core-vital-value` is a 0..1 '
          + 'custom property and the CSS clips the white fill inside the skewed shape, which is '
          + 'why every slanted edge on screen has the same 20°.\n\n'
          + '`hud:set` is a PARTIAL update — only the keys present in the message are copied onto '
          + '`store.hud` (`HUD_KEYS` filters the rest), so `{ health = 81 }` alone is a valid '
          + 'message. Cash, bank, faction, name, speed and street are still in the store for '
          + '`useHud()`, they are simply no longer drawn by core.',
      },
    },
  },
  argTypes: {
    visible: { control: 'boolean', description: '`Core.UI.hud.setVisible(bool)`.', table: { category: 'hud:set' } },
    health: { control: { type: 'range', min: 0, max: 100, step: 1 }, description: '0–100. Under 25 the heart pulses (`is-low`).', table: { category: 'hud:set' } },
    armour: { control: { type: 'range', min: 0, max: 100, step: 1 }, description: '0–100. Never pulses — an empty vest is normal.', table: { category: 'hud:set' } },
    talking: {
      control: 'radio',
      options: [null, false, true],
      description: '`MumbleIsPlayerTalking`. **null = no voice feed at all**, so there is no tile.',
      table: { category: 'hud:set' },
    },
    muted: { control: 'boolean', description: '`not MumbleIsConnected()` — `hud-mic-off` at 40 %.', table: { category: 'hud:set' } },
    anchor: {
      control: 'radio',
      options: ['bottom-left', 'minimap'],
      description: '`Config.Hud.Anchor` — the only two placements. `bottom-left` (default) is a '
        + 'fixed 24 px from both edges and never reads the map rect; `minimap` follows the live '
        + 'minimap rect. A bottom-centre / bottom-right strip was cut because it lands on the '
        + 'progress bar, the text UI, the key hints and the spinner. Anything else → `bottom-left`.',
      table: { category: 'hud:set' },
    },
    scale: {
      control: { type: 'range', min: 0.5, max: 2, step: 0.05 },
      description: '`Config.Hud.Scale` — multiplies `--core-hud-unit`, which is a FIXED 24 px '
        + '(the strip is ~351 × 76 px), not a viewport unit: the rail and the progress panel are '
        + 'fixed px too. 0.5 → 12 px, 2 → 48 px; anything outside is clamped.',
      table: { category: 'hud:set' },
    },
    hunger: { control: { type: 'range', min: 0, max: 100, step: 1 }, description: '`slot = "health"` — the bar under the HEALTH plate.', table: { category: 'stats:set' } },
    thirst: { control: { type: 'range', min: 0, max: 100, step: 1 }, description: '`slot = "armour"` — the bar under the ARMOR plate.', table: { category: 'stats:set' } },
  },
  args: {
    visible: true, health: 100, armour: 100, talking: false, muted: false,
    anchor: 'bottom-left', scale: 1, hunger: 80, thirst: 78,
  },
}

const luaFeed = '-- client/hudfeed.lua, one 100 ms thread while the HUD is visible:\n'
  + 'Core.UI.hud.set({ health = 100, armour = 100, talking = false, muted = false })\n'
  + '-- the bars ride the stats bag, independently of the feed:\n'
  + "Core.Stats.set(src, 'hunger', 80)   -- Defs.hunger.hud = 'health', icon = 'hud-food'\n"
  + "Core.Stats.set(src, 'thirst', 78)   -- Defs.thirst.hud = 'armour', icon = 'hud-drink'"

export const Default = {
  name: 'Full strip',
  render: show,
  parameters: {
    lua: {
      message: 'hud:set + stats:set',
      call: luaFeed,
      note: 'Only changed values are pushed, so a healthy idle player costs one message per state change.',
    },
    docs: {
      description: {
        story: 'The mockup state: both plates full, both bars nearly full, the mic idle. Drag '
          + '**health** to watch the white fill clip back along the 20° edge and the label go '
          + 'two-tone, and **scale** to see the whole strip resize off one variable.',
      },
    },
  },
  play: async ({ canvasElement, args }) => {
    await waitFor(() => expect(canvasElement.querySelector('.hud')).toBeTruthy())
    // The label exists TWICE, pixel-identical (§39.3): once on the track, once in the fill.
    expect(canvasElement.querySelectorAll('.hud__vital.is-health .core-vital__label').length).toBe(2)
    expect(canvasElement.querySelectorAll('.hud__vital').length).toBe(2)
    expect(canvasElement.querySelectorAll('.hud__tile').length).toBe(1)
    expect(cssVar(vital(canvasElement, 'health'), '--core-vital-value')).toBe('1')
    // 80 % of the span -> 0.8, and the plate is NOT --solo because the slot is filled
    expect(cssVar(vital(canvasElement, 'health'), '--core-vital-sub')).toBe('0.8')
    expect(vital(canvasElement, 'health').classList.contains('core-vital--solo')).toBe(false)
    expect(vital(canvasElement, 'health').classList.contains('is-low')).toBe(false)
    expect(canvasElement.querySelector('.hud__tile').classList.contains('is-active')).toBe(false)
    expect(args.talking).toBe(false)
  },
}

export const Talking = {
  name: 'Transmitting',
  args: { talking: true, health: 86, armour: 64, hunger: 72, thirst: 55 },
  render: show,
  parameters: {
    lua: {
      message: 'hud:set',
      call: '-- every 100 ms tick, BOOL read as `v == true or v == 1` (§30.4):\n'
        + 'Core.UI.hud.set({ talking = MumbleIsPlayerTalking(PlayerId()) })\n'
        + '\n-- a voice resource that wants the tile for itself:\n'
        + 'Config.Hud.ShowVoice = false\n'
        + 'Core.UI.hud.set({ talking = true, muted = false })',
    },
    docs: {
      description: {
        story: '`talking = true` puts a thick `fg` ring and a soft white glow on the tile. The '
          + 'ring repeats the idle tile\'s drop shadow on purpose — `box-shadow` is one property, '
          + 'so a state that only named the ring would flatten the tile onto a bright sky.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    const tile = () => canvasElement.querySelector('.hud__tile')
    await waitFor(() => expect(tile()).toBeTruthy())
    await waitFor(() => expect(tile().classList.contains('is-active')).toBe(true))
    expect(tile().classList.contains('is-dimmed')).toBe(false)
    expect(cssVar(vital(canvasElement, 'armour'), '--core-vital-value')).toBe('0.64')
  },
}

export const Muted = {
  name: 'Muted',
  args: { talking: true, muted: true },
  render: show,
  parameters: {
    lua: {
      message: 'hud:set',
      call: '-- every 1000 ms: no Mumble connection means the player cannot transmit at all\n'
        + 'Core.UI.hud.set({ muted = not MumbleIsConnected() })',
      note: 'Muted wins over talking: the glyph swaps to `hud-mic-off` and the ring never lights.',
    },
    docs: {
      description: {
        story: 'The muted twin is the same glyph knocked out by a slash, at 40 % (`is-dimmed`). '
          + 'Even with `talking = true` the tile stays idle — you are not being heard.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    const tile = () => canvasElement.querySelector('.hud__tile')
    await waitFor(() => expect(tile()).toBeTruthy())
    await waitFor(() => expect(tile().classList.contains('is-dimmed')).toBe(true))
    expect(tile().classList.contains('is-active')).toBe(false)
    expect(tile().getAttribute('aria-label')).toBe('Microphone muted')
  },
}

export const Low = {
  name: 'Low health, hungry, parched',
  args: { health: 18, armour: 12, hunger: 20, thirst: 6 },
  render: show,
  parameters: {
    lua: {
      message: 'hud:set + stats:set',
      call: '-- nothing special: the same two messages, other numbers\n'
        + 'Core.UI.hud.set({ health = 18, armour = 12 })\n'
        + "Core.Stats.set(src, 'hunger', 20)\nCore.Stats.set(src, 'thirst', 6)",
      note: 'Thresholds are the kit\'s: `lowBelow` 25 on the plate, `subWarnBelow` 25 / `subDangerBelow` 10 on the bar.',
    },
    docs: {
      description: {
        story: 'Three warnings at once. Health under 25 % pulses the heart (`is-low`) and nothing '
          + 'else moves; the hunger bar is amber (`is-sub-warning`), the thirst bar red with a '
          + 'pulsing cup (`is-sub-danger`). Armour at 12 % is silent — an empty vest is normal.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.hud__vital.is-health')).toBeTruthy())
    const health = vital(canvasElement, 'health')
    const armour = vital(canvasElement, 'armour')
    await waitFor(() => expect(health.classList.contains('is-low')).toBe(true))
    expect(cssVar(health, '--core-vital-value')).toBe('0.18')
    expect(health.classList.contains('is-sub-warning')).toBe(true)
    expect(armour.classList.contains('is-sub-danger')).toBe(true)
    // lowBelow = 0 on armour: the plate is at 12 % and still does not pulse
    expect(armour.classList.contains('is-low')).toBe(false)
  },
}

export const NoArmour = {
  name: 'No armour',
  args: { health: 74, armour: 0, hunger: 64, thirst: 41 },
  render: show,
  parameters: {
    lua: {
      message: 'hud:set',
      call: 'Core.UI.hud.set({ armour = 0 })\n'
        + '-- hiding the plate outright is a config decision, not a value:\n'
        + 'Config.Hud.ShowArmour = false   -- the feed stops sending `armour` at all',
      note: '`armour = 0` draws an empty plate; only a missing key (null in the store) removes it.',
    },
    docs: {
      description: {
        story: 'An empty vest. The plate keeps its place in the strip with the shield and the '
          + 'label on the dark track — `lowBelow = 0`, so nothing pulses and nothing turns red. '
          + 'With `Config.Hud.ShowArmour = false` the key never arrives and the plate is gone '
          + 'instead, which is the `health !== null` / `armour !== null` guard in the shell.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(vital(canvasElement, 'armour')).toBeTruthy())
    expect(cssVar(vital(canvasElement, 'armour'), '--core-vital-value')).toBe('0')
    expect(vital(canvasElement, 'armour').classList.contains('is-low')).toBe(false)
    expect(canvasElement.querySelectorAll('.hud__vital').length).toBe(2)
  },
}

export const NoStats = {
  name: 'No stats (solo plates)',
  args: { hunger: null, thirst: null, health: 92, armour: 55 },
  render: show,
  parameters: {
    lua: {
      message: 'hud:set',
      call: 'Config.Stats.Enabled = false        -- or no def has hud = "health" / "armour"\n'
        + '-- no stats:set arrives, so both plates lose their cut',
    },
    docs: {
      description: {
        story: 'Without a slotted stat a vital is `--solo`: no cut, no bar, no glyph underneath, '
          + 'and the plate wears all four outer radii. The shell shrinks the mic tile with them '
          + 'by setting `--core-hudtile-h: 1.57em` on the strip — the tile reads that variable '
          + 'instead of taking a prop, so nothing in the kit has to know about the strip.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.hud')).toBeTruthy())
    const strip = canvasElement.querySelector('.hud')
    await waitFor(() => expect(vital(canvasElement, 'health').classList.contains('core-vital--solo')).toBe(true))
    expect(vital(canvasElement, 'armour').classList.contains('core-vital--solo')).toBe(true)
    expect(cssVar(vital(canvasElement, 'health'), '--core-vital-sub')).toBe('')
    expect(strip.style.getPropertyValue('--core-hudtile-h').trim()).toBe('1.57em')
    expect(canvasElement.querySelector('.core-vital__bar')).toBeNull()
  },
}

export const Hidden = {
  name: 'Hidden',
  args: { visible: false },
  render: liveScene(build, () => [view(), note('hud:set { visible = false } — nothing renders')]),
  parameters: {
    lua: {
      message: 'hud:set',
      call: "Core.UI.hud.setVisible(false)   -- -> { action = 'hud:set', visible = false }",
    },
    docs: {
      description: {
        story: '`hud:set { visible = false }` — the strip leaves through its `core-slide-up` '
          + 'transition, so the frame is intentionally empty apart from the caption. Every number '
          + 'stays in the store (and in `useHud()`), so showing it again needs no re-send.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.hud')).toBeNull())
  },
}
