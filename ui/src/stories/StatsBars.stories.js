// Stat bars (DESIGN §18 + §21 `stats:set`) — one thin bar per `Config.Stats` def with
// `hud = true`, stacked directly under the HUD in the top-right rail.
//
// Lua side: nothing calls this by hand. The server decays `data.stats` once per
// `Config.Stats.TickMs`, replicates the whole table as `Player(src).state.stats`, and
// `client/ui.lua` turns that bag into ONE `stats:set` carrying `{ value, min, max }` per
// stat. Scripts move the numbers with `Core.Stats.add(src, 'hunger', -10)` and read them
// back with `Core.Stats.get(name)`; the bars follow on their own. Output only.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import StatsBars from '../components/StatsBars.vue'
import Hud from '../components/Hud.vue'
import { resetExtras } from '../store.js'
import { send, liveScene, rail, note, clone } from './storeHelpers.js'

// StatsBars.vue has no positioning of its own — App.vue hangs it in the top-right rail,
// under Hud.vue and above the toast stack.
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
          + 'two messages.',
      },
    },
  },
  argTypes: {
    stats: {
      control: 'object',
      description: '`{ [name] = { value, min, max } }` — the message body verbatim. `label` is optional.',
      table: { category: 'stats:set' },
    },
  },
  args: { stats: { hunger: { value: 62, min: 0, max: 100 }, thirst: { value: 44, min: 0, max: 100 } } },
}

export const Default = {
  ...base,
  name: 'Healthy',
  args: { stats: { hunger: { value: 62, min: 0, max: 100 }, thirst: { value: 44, min: 0, max: 100 } } },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: call({ hunger: { value: 62 }, thirst: { value: 44 } }),
    },
    docs: { description: { story: 'The two defs core ships. Both above 25 %, so both bars stay on the accent colour.' } },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvasElement.querySelectorAll('.stats .stat').length).toBe(2))
    expect(canvas.getByText('hunger')).toBeInTheDocument()
    // sorted by name, never in Lua table order
    expect(Array.from(canvasElement.querySelectorAll('.stats .lbl')).map((e) => e.textContent))
      .toEqual(['hunger', 'thirst'])
    expect(canvasElement.querySelector('.stats .stat').classList.contains('is-ok')).toBe(true)
  },
}

export const Thresholds = {
  ...base,
  name: 'Warning and critical',
  args: {
    stats: {
      hunger: { value: 22, min: 0, max: 100 },
      thirst: { value: 7, min: 0, max: 100 },
      stamina: { value: 80, min: 0, max: 100 },
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
        story: 'Amber under 25 %, red under 10 %. `stamina` is a plugin-defined stat (`Core.Stats.define`) '
          + 'to show that the stack is not limited to core\'s two.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.stats .stat').length).toBe(3))
    const level = (i) => canvasElement.querySelectorAll('.stats .stat')[i].className
    expect(level(0)).toContain('is-warning')  // hunger 22 %
    expect(level(1)).toContain('is-ok')       // stamina 80 %
    expect(level(2)).toContain('is-error')    // thirst 7 %
    expect(canvasElement.querySelectorAll('.stats .fill')[2].style.width).toBe('7%')
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
    expect(canvasElement.querySelector('.stats .fill').style.width).toBe('50%')
  },
}

export const UnderTheHud = {
  ...base,
  name: 'Under the HUD (full rail)',
  args: {
    stats: { hunger: { value: 62, min: 0, max: 100 }, thirst: { value: 18, min: 0, max: 100 } },
  },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      message: 'hud:set + stats:set',
      call: '-- client/hudfeed.lua, at most every 250 ms and only on change:\n'
        + 'Core.UI.hud.set({ health = 68, armour = 40, speed = 87, street = …, zone = … })\n'
        + '-- the bars come from the stats bag, independently of the feed',
    },
    docs: {
      description: {
        story: 'How it actually looks in game: the HUD with its §21 rows (health / armour bars, speed, '
          + 'street + zone) and the stat stack under it. The 54 px label column is shared by both, so '
          + 'the four bars line up across the two panels.',
      },
    },
  },
  render: liveScene((args) => {
    resetExtras()
    send({
      action: 'hud:set',
      visible: true,
      cash: 4238,
      bank: 182450,
      name: 'Liam Robinson',
      serverId: 12,
      faction: { name: 'Los Santos Police Department', tag: 'LSPD', color: '#5b8cff' },
      health: 68,
      armour: 40,
      speed: 87,
      street: 'Vespucci Boulevard',
      zone: 'Del Perro',
    })
    setStats(args.stats)
  }, () => rail(h(Hud), h(StatsBars))),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvasElement.querySelectorAll('.stats .stat').length).toBe(2))
    expect(canvas.getByText('87')).toBeInTheDocument()
    expect(canvas.getByText('Vespucci Boulevard')).toBeInTheDocument()
    // health 68 % is fine, armour is always accent-blue
    expect(canvasElement.querySelector('.hud .bar').className).toContain('is-ok')
    expect(canvasElement.querySelectorAll('.hud .fill')[0].style.width).toBe('68%')
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
      call: 'Config.Stats.Enabled = false   -- or no def has hud = true',
    },
    docs: {
      description: {
        story: 'With `Config.Stats.Enabled = false` the bag is never written, no `stats:set` arrives '
          + 'and the panel is not rendered at all — the HUD keeps its place in the rail.',
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
