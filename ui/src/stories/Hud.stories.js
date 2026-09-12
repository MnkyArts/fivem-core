// HUD (DESIGN §6.10 `hud:set`) — cash / bank / faction / name + server id.
//
// Lua side: `Core.UI.hud.set(partial)` and `Core.UI.hud.setVisible(bool)`. Scripts rarely
// call either: client/ui.lua watches the `player:<src>` state bags (cash, bank, name,
// faction, …), coalesces the changes and flushes ONE `hud:set` with only the keys that
// moved. Nothing comes back; the HUD is output only (`pointer-events: none`).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import Hud from '../components/Hud.vue'
import { send, liveScene, rail, note, clone } from './storeHelpers.js'

// Hud.vue has no positioning of its own — App.vue hangs it in the top-right rail.
const view = () => rail(h(Hud))

const set = liveScene((args) => send({
  action: 'hud:set',
  visible: args.visible,
  cash: args.cash,
  bank: args.bank,
  name: args.name,
  serverId: args.serverId,
  faction: args.faction ? clone(args.faction) : false,
}), view)

const money = (n) => '$' + Math.round(Number(n) || 0).toLocaleString('en-US')

export default {
  title: 'Built-ins/HUD',
  component: Hud,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: '`hud:set` is a PARTIAL update: only the keys present in the message are copied '
          + 'onto `store.hud` (`HUD_KEYS` filters the rest), so Lua can push `{ cash = 120 }` alone. '
          + '`window.CoreUI.hud` hands plugin pages the same object as a readonly reactive snapshot.',
      },
    },
  },
  argTypes: {
    visible: { control: 'boolean', description: '`Core.UI.hud.setVisible(bool)`.', table: { category: 'hud:set' } },
    cash: { control: { type: 'number', step: 100 }, description: 'Mirrors the `cash` state bag.', table: { category: 'hud:set' } },
    bank: { control: { type: 'number', step: 1000 }, description: 'Mirrors the `bank` state bag.', table: { category: 'hud:set' } },
    name: { control: 'text', description: 'Character name.', table: { category: 'hud:set' } },
    serverId: { control: { type: 'number', min: 0, step: 1 }, description: 'Server id; 0 hides the `#n` badge.', table: { category: 'hud:set' } },
    faction: {
      control: 'object',
      description: '`{ name, tag, color }` or `false` — the `faction` state bag verbatim.',
      table: { category: 'hud:set' },
    },
  },
  args: { visible: true, cash: 4238, bank: 182450, name: 'Liam Robinson', serverId: 12, faction: false },
}

export const Visible = {
  name: 'Visible (no faction)',
  parameters: {
    lua: {
      message: 'hud:set',
      call: 'Core.UI.hud.setVisible(true)\n'
        + '-- core pushes the numbers itself when the state bags change:\n'
        + 'Core.UI.hud.set({ cash = 4238, bank = 182450 })',
      note: 'Output only — the HUD has no NUI callback.',
    },
    docs: {
      description: {
        story: 'The everyday state. `Core.Money` writes the `cash` / `bank` bags server-side, the '
          + 'client bag handler calls `hud.set`, and one coalesced `hud:set` reaches the NUI.',
      },
    },
  },
  render: set,
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(money(args.cash))).toBeInTheDocument())
    expect(canvas.getByText(money(args.bank))).toBeInTheDocument()
    expect(canvas.getByText('#' + args.serverId)).toBeInTheDocument()
    expect(canvas.getByText(args.name)).toBeInTheDocument()
  },
}

export const WithFaction = {
  name: 'Visible (faction)',
  args: {
    cash: 1275,
    bank: 96310,
    faction: { name: 'Los Santos Police Department', tag: 'LSPD', color: '#5b8cff' },
  },
  parameters: {
    lua: {
      message: 'hud:set',
      call: '-- server, on hire:\nCore.Factions.setMember(src, \'lspd\', 3)\n'
        + "-- -> player:<src> state bag `faction` = { id = 'lspd', name = …, tag = 'LSPD', color = '#5b8cff', rank … }\n"
        + '-- -> client bag handler -> Core.UI.hud.set({ faction = bag.faction })',
    },
    docs: {
      description: {
        story: 'The faction row only renders when the bag is a table; `color` tints the tag chip '
          + 'inline, so a faction can brand itself without touching the shell CSS.',
      },
    },
  },
  render: set,
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.faction.tag)).toBeInTheDocument())
    expect(canvas.getByText(args.faction.name)).toBeInTheDocument()
    expect(getComputedStyle(canvas.getByText(args.faction.tag)).color).toBe('rgb(91, 140, 255)')
  },
}

export const Hidden = {
  name: 'Hidden',
  args: { visible: false },
  parameters: {
    lua: {
      message: 'hud:set',
      call: 'Core.UI.hud.setVisible(false)   -- -> { action = \'hud:set\', visible = false }',
    },
    docs: {
      description: {
        story: '`hud:set { visible = false }` — the HUD unmounts through its Transition, so the frame '
          + 'is intentionally empty apart from the story caption. The numbers are still in the store, '
          + 'so making it visible again needs no re-send.',
      },
    },
  },
  render: liveScene(
    (args) => send({
      action: 'hud:set',
      visible: args.visible,
      cash: args.cash,
      bank: args.bank,
      name: args.name,
      serverId: args.serverId,
      faction: args.faction ? clone(args.faction) : false,
    }),
    () => [rail(h(Hud)), note('hud:set { visible = false } — nothing renders')]
  ),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.hud')).toBeNull())
  },
}
