// Stat bars (DESIGN §18 + §21 `stats:set`, §39.4) — the top-right rail plate, one thin bar per
// `Config.Stats` def that did NOT claim a vital slot.
//
// Lua side: nothing calls this by hand. The server decays `data.stats` once per
// `Config.Stats.TickMs`, replicates the whole table as `Player(src).state.stats`, and
// `client/ui.lua` turns that bag into ONE `stats:set` carrying `{ value, min, max, slot?, icon? }`
// per stat. Scripts move the numbers with `Core.Stats.add(src, 'hunger', -10)` and read them back
// with `Core.Stats.get(name)`; the bars follow on their own. Output only.
//
// §39.4 split the stack in two. A def with `hud = 'health'` / `'armour'` arrives with a `slot`
// and is drawn by Hud.vue as the bar cut out of that plate — this plate skips it. So with the
// two defs core ships (hunger -> health, thirst -> armour) the rail is EMPTY, and everything
// here is what a plugin adds on top with `Core.Stats.define`.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import StatsBars from '../shell/StatsBars.vue'
import Hud from '../shell/Hud.vue'
import { resetExtras } from '../store.js'
import { send, liveScene, rail, note, clone } from './storeHelpers.js'

// StatsBars.vue has no positioning of its own — App.vue hangs it in the top-right rail,
// above the toast stack. (The HUD strip left the rail in §39.4; it places itself.)
const view = () => rail(h(StatsBars))

/** `stats:set` carries the stat names at the TOP level, like `hud:set` carries its fields. */
const setStats = (stats) => send(Object.assign({ action: 'stats:set' }, clone(stats || {})))

const show = liveScene((args) => {
  resetExtras()
  setStats(args.stats)
}, view)

const call = (stats) => '-- server, whenever something should cost a need:\n'
  + Object.keys(stats).sort().map((n) => "Core.Stats.set(src, '" + n + "', " + stats[n].value + ')').join('\n')
  + '\n-- -> Player(src).state.stats -> client/ui.lua -> one stats:set'

const base = {
  parameters: {
    lua: {
      message: 'stats:set',
      note: 'A whole-table replace: a stat missing from the message loses its bar.',
    },
  },
  render: show,
}

export default {
  title: 'Built-ins/Stat Bars',
  component: StatsBars,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Needs, at a glance. Each bar is `(value - min) / (max - min)`, and the fill '
          + 'follows the def\'s thresholds (§18): accent above 25 %, amber under it, red under 10 % '
          + '(the label turns red too, so a drained stat is readable without looking at the bar). '
          + 'Lua tables have no order, so the stack is sorted by name and never reshuffles between '
          + 'two messages.\n\n'
          + 'Only stats WITHOUT a `slot` land here (§39.4) — a `slot` means the bar belongs under '
          + 'the HEALTH or ARMOR plate of the HUD strip instead, so no stat is ever drawn twice.',
      },
    },
  },
  argTypes: {
    stats: {
      control: 'object',
      description: '`{ [name] = { value, min, max, slot?, icon? } }` — the message body verbatim. '
        + '`label` is optional; `slot` moves the bar to the HUD strip.',
      table: { category: 'stats:set' },
    },
  },
  args: { stats: { stamina: { value: 62, min: 0, max: 100 }, stress: { value: 44, min: 0, max: 100 } } },
}

export const Default = {
  ...base,
  name: 'Healthy',
  args: { stats: { stamina: { value: 62, min: 0, max: 100 }, stress: { value: 44, min: 0, max: 100 } } },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: "Core.Stats.define('stamina', { min = 0, max = 100, default = 100, hud = true })\n"
        + "Core.Stats.define('stress', { min = 0, max = 100, default = 0, hud = true })\n"
        + call({ stamina: { value: 62 }, stress: { value: 44 } }),
    },
    docs: {
      description: {
        story: 'Two plugin stats with `hud = true` — no slot, so both take a rail row. Above 25 % '
          + 'each wears its own vital tone.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvasElement.querySelectorAll('.stats .stat').length).toBe(2))
    expect(canvas.getByText('stamina')).toBeInTheDocument()
    // sorted by name, never in Lua table order
    expect(Array.from(canvasElement.querySelectorAll('.stats .core-progress__label')).map((e) => e.textContent))
      .toEqual(['stamina', 'stress'])
    expect(canvasElement.querySelector('.stats .stat').classList.contains('is-ok')).toBe(true)
  },
}

export const Thresholds = {
  ...base,
  name: 'Warning and critical',
  args: {
    stats: {
      stamina: { value: 80, min: 0, max: 100 },
      stress: { value: 22, min: 0, max: 100 },
      oxygen: { value: 7, min: 0, max: 100 },
    },
  },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: '-- decay does this on its own; the crossing fires the hook:\n'
        + "Core.Hooks.on('statThreshold', function (src, name, threshold, value)\n"
        + "    Core.UI.notify(src, name .. ' is at ' .. value, 'warning')\nend)",
      note: 'Thresholds are `Config.Stats.Defs[name].thresholds = { 25, 10 }` — the same numbers the bar colours use.',
    },
    docs: {
      description: {
        story: 'Amber under 25 %, red under 10 %. All three are plugin-defined stats '
          + '(`Core.Stats.define`) — core\'s own two live under the HUD plates now.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.stats .stat').length).toBe(3))
    const level = (i) => canvasElement.querySelectorAll('.stats .stat')[i].className
    expect(level(0)).toContain('is-error')    // oxygen 7 %
    expect(level(1)).toContain('is-ok')       // stamina 80 %
    expect(level(2)).toContain('is-warning')  // stress 22 %
    expect(canvasElement.querySelectorAll('.stats .core-progress__fill')[0].style.width).toBe('7%')
  },
}

export const CustomRange = {
  ...base,
  name: 'Custom range and label',
  args: { stats: { armour_plates: { value: 3, min: 0, max: 6, label: 'Plates' } } },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: "Core.Stats.define('armour_plates', { min = 0, max = 6, default = 6, hud = true })\n"
        + "Core.Stats.set(src, 'armour_plates', 3)",
    },
    docs: {
      description: {
        story: '`min` / `max` are not assumed to be 0..100 — the fill is the fraction of the span, so '
          + '3 of 6 is half a bar. An optional `label` replaces the stat name in the column.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Plates')).toBeInTheDocument())
    expect(canvasElement.querySelector('.stats .core-progress__fill').style.width).toBe('50%')
  },
}

export const SlottedAndRail = {
  ...base,
  name: 'Slotted vs rail (the whole split)',
  args: {
    stats: {
      hunger: { value: 62, min: 0, max: 100, label: 'Hunger', slot: 'health', icon: 'hud-food' },
      thirst: { value: 18, min: 0, max: 100, label: 'Thirst', slot: 'armour', icon: 'hud-drink' },
      stress: { value: 44, min: 0, max: 100 },
    },
  },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      message: 'hud:set + stats:set',
      call: '-- shared/config.lua, the two defs core ships:\n'
        + "Config.Stats.Defs.hunger = { …, hud = 'health', icon = 'hud-food' }\n"
        + "Config.Stats.Defs.thirst = { …, hud = 'armour', icon = 'hud-drink' }\n"
        + "-- a plugin's own need, with no plate to hang under:\n"
        + "Core.Stats.define('stress', { min = 0, max = 100, default = 0, hud = true })",
      note: '`hud` is `true` (rail row) | `\'health\'` | `\'armour\'` (a bar under that plate) | `false`.',
    },
    docs: {
      description: {
        story: 'One message, two destinations. `hunger` and `thirst` carry a `slot`, so they are '
          + 'the bars cut out of the HEALTH and ARMOR plates bottom left; `stress` has none, so it '
          + 'is the single row left in the rail top right. Nothing is drawn twice, and a plugin '
          + 'still has somewhere to put a need that does not fit a vital.',
      },
    },
  },
  render: liveScene((args) => {
    resetExtras()
    send({ action: 'hud:set', visible: true, health: 68, armour: 40, talking: false })
    setStats(args.stats)
  }, () => [h(Hud), rail(h(StatsBars))]),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvasElement.querySelector('.hud__vital.is-health')).toBeTruthy())
    // exactly one rail row, and it is the unslotted stat
    await waitFor(() => expect(canvasElement.querySelectorAll('.stats .stat').length).toBe(1))
    expect(canvas.getByText('stress')).toBeInTheDocument()
    expect(canvas.queryByText('Hunger')).toBeNull()
    // …because hunger is the bar under the HEALTH plate: 62 % of its span
    const health = canvasElement.querySelector('.hud__vital.is-health')
    expect(health.style.getPropertyValue('--core-vital-sub').trim()).toBe('0.62')
    expect(canvasElement.querySelector('.hud__vital.is-armour').classList.contains('is-sub-warning')).toBe(true)
  },
}

export const Empty = {
  ...base,
  name: 'No stats',
  args: { stats: {} },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: 'Config.Stats.Enabled = false   -- or every def has hud = false / a slot',
    },
    docs: {
      description: {
        story: 'With `Config.Stats.Enabled = false` the bag is never written, no `stats:set` '
          + 'arrives and the plate is not rendered at all. This is also what the DEFAULT config '
          + 'looks like: hunger and thirst both claim a slot, so the rail keeps nothing.',
      },
    },
  },
  render: liveScene((args) => {
    resetExtras()
    setStats(args.stats)
  }, () => [rail(h(StatsBars)), note('stats:set {} — the panel is not rendered')]),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.stats')).toBeNull())
  },
}
