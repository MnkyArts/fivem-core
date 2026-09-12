// Keyboard menu (DESIGN §6.10 `menu:open`) — arrow keys move, Enter picks, Esc cancels.
//
// Lua side: `Core.UI.menu.open{ title, items }` awaits and returns the chosen item's
// `value` (nil on Esc). What actually travels is an INDEX: client/ui.lua rewrites every
// item's `value` to its 1-based position, keeps the real values in a local table and maps
// the posted index back — that is how a Lua value of `false`, a table or a function still
// survives the round trip through JSON.
import { h } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import Menu from '../components/Menu.vue'
import { send, liveScene, clone } from './storeHelpers.js'
import { lastPost } from './luaBridge.js'

let seq = 0
const rid = () => 'sb-menu-' + ++seq

const view = () => h(Menu)

/** The one message this component listens to; `id` is Lua's pending-promise key. */
const build = (args) => send({
  action: 'menu:open',
  id: rid(),
  title: args.title,
  items: clone(args.items),
})

const open = liveScene(build, view)

const resolve = (name, body) => {
  if (name !== 'menu_result') return null
  if (body.value === null || body.value === undefined) return "Core.UI.menu.open{...}  ->  nil        -- Esc / cancelled"
  return "Core.UI.menu.open{...}  ->  " + JSON.stringify(body.value)
    + "\n-- client/ui.lua maps the posted index back to the item's own Lua value first."
}

const call = (title, items) => 'local choice = Core.UI.menu.open({\n'
  + "    title = '" + title + "',\n"
  + '    items = {\n'
  + items.map((i) => "        { label = '" + i.label + "'"
    + (i.description ? ", description = '" + i.description + "'" : '')
    + (i.icon ? ", icon = '" + i.icon + "'" : '')
    + ', value = ' + (typeof i.value === 'number' ? i.value : "'" + i.value + "'")
    + (i.disabled ? ', disabled = true' : '') + ' },').join('\n')
  + '\n    },\n})\n-- blocks the thread; choice is the item value, or nil when the player pressed Esc'

export default {
  title: 'Built-ins/Menu',
  component: Menu,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Centred modal list. `store.js` owns Escape (→ `menu_result { value = nil }`), '
          + 'the component owns ↑ ↓ (skipping `disabled` rows, wrapping) and Enter, and the mouse '
          + 'hover doubles as selection. While it is open `activeModal()` is `"menu"`, which is what '
          + 'makes Lua hold `SetNuiFocus(true, true)`.',
      },
    },
  },
  argTypes: {
    title: {
      control: 'text',
      description: 'Heading — `menu:open.title` (Lua sanitises it to 96 chars).',
      table: { category: 'menu:open' },
    },
    items: {
      control: 'object',
      description: '`{ label, description?, icon?, value, disabled? }[]`. Edit the array and the '
        + 'menu reopens live, exactly as a second `Core.UI.menu.open` would.',
      table: { category: 'menu:open' },
    },
  },
}

export const Basic = {
  name: 'Basic list',
  args: {
    title: 'Vehicle',
    items: [
      { label: 'Engine', description: 'Toggle the engine on or off', icon: '⚙', value: 'engine' },
      { label: 'Doors', description: 'Open or close a single door', icon: '🚪', value: 'doors' },
      { label: 'Trunk', description: 'Boot is empty', icon: '📦', value: 'trunk' },
      { label: 'Hand over keys', description: 'Requires another player nearby', icon: '🔑', value: 'keys', disabled: true },
      { label: 'Store in garage', description: 'Costs $75', icon: '🏠', value: 'store' },
    ],
  },
  parameters: {
    lua: {
      message: 'menu:open',
      callback: 'menu_result',
      resolve,
      call: call('Vehicle', [
        { label: 'Engine', description: 'Toggle the engine on or off', icon: '⚙', value: 'engine' },
        { label: 'Doors', description: 'Open or close a single door', icon: '🚪', value: 'doors' },
        { label: 'Trunk', value: 'trunk' },
        { label: 'Hand over keys', value: 'keys', disabled: true },
        { label: 'Store in garage', value: 'store' },
      ]),
      note: 'The play function drives ↓ then Enter, so the callback below is already there.',
    },
    docs: {
      description: {
        story: 'Descriptions, an icon column and a disabled entry. ↑ ↓ skip the disabled row.\n\n'
          + '```lua\nlocal choice = Core.UI.menu.open({ title = \'Vehicle\', items = { … } })\n'
          + 'if choice == \'engine\' then … end   -- nil means the player pressed Esc\n```\n\n'
          + 'Enter posts `menu_result { id, value }`; the Lua promise for `id` resolves with it.',
      },
    },
  },
  render: open,
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.items[0].label)).toBeInTheDocument())
    // Row 0 is selected on open; ↓ moves to row 1, Enter picks it.
    await userEvent.keyboard('{ArrowDown}{Enter}')
    await waitFor(() => expect(lastPost('menu_result')).toBeTruthy())
    expect(lastPost('menu_result').value).toBe(args.items[1].value)
    // menuResult() closes optimistically — Lua's `menu:close` afterwards is a no-op.
    await waitFor(() => expect(canvas.queryByText(args.items[0].label)).toBeNull())
    build(args) // reopen, so the story is still something you can drive by hand afterwards
  },
}

export const NoDescriptions = {
  name: 'Labels only',
  args: {
    title: 'Radio channel',
    items: [
      { label: 'Channel 1 — Dispatch', value: 1 },
      { label: 'Channel 2 — Patrol', value: 2 },
      { label: 'Channel 3 — Detectives', value: 3 },
      { label: 'Leave channel', value: 0 },
    ],
  },
  parameters: {
    lua: {
      message: 'menu:open',
      callback: 'menu_result',
      resolve,
      call: call('Radio channel', [
        { label: 'Channel 1 — Dispatch', value: 1 },
        { label: 'Channel 2 — Patrol', value: 2 },
        { label: 'Channel 3 — Detectives', value: 3 },
        { label: 'Leave channel', value: 0 },
      ]),
    },
    docs: {
      description: {
        story: 'No `description`/`icon` keys: the rows collapse to a single line. Numeric values '
          + 'come back as numbers, so `if choice == 0 then leave() end` works.',
      },
    },
  },
  render: open,
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Leave channel')).toBeInTheDocument())
    // Esc is the store's, not the component's: handleKeydown -> menuResult(null).
    await userEvent.keyboard('{Escape}')
    await waitFor(() => expect(lastPost('menu_result')).toBeTruthy())
    expect(lastPost('menu_result').value).toBe(null)
    build(args) // reopen for the reader
  },
}

export const LongList = {
  name: 'Long list (20, scrolls)',
  args: {
    title: 'Impound lot',
    items: Array.from({ length: 20 }, (_, k) => ({
      label: 'Slot ' + (k + 1),
      description: (k + 1) % 4 === 0 ? 'Reserved for staff' : 'Free — $' + ((k + 1) * 25) + ' per day',
      value: k + 1,
      disabled: (k + 1) % 4 === 0,
    })),
  },
  parameters: {
    lua: {
      message: 'menu:open',
      callback: 'menu_result',
      resolve,
      call: 'local slots = {}\nfor i = 1, 20 do\n'
        + "    slots[i] = { label = ('Slot %d'):format(i), value = i, disabled = i % 4 == 0 }\n"
        + "end\nlocal slot = Core.UI.menu.open({ title = 'Impound lot', items = slots })",
    },
    docs: {
      description: {
        story: '`.core-list` caps at 60vh and scrolls; arrow selection pulls the active row into '
          + 'view (`scrollIntoView({ block: "nearest" })`). Lua puts no cap on `items`.',
      },
    },
  },
  render: open,
}
