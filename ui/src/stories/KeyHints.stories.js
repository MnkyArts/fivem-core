// Key hints (DESIGN §21 `keys:show { items }` / `keys:hide`) — the shell's instructional
// buttons, bottom right: one row of [KEY] label pairs.
//
// Lua side: `Core.UI.keys.show({ { key = 'E', label = 'Interact' }, … })` / `.hide()` on
// the client, `Core.UI.keys.show(src, items)` / `.hide(src)` on the server. Output only:
// this draws the row, `Core.Keys` (§3.8) is what actually binds the key — keeping the two
// in sync is the caller's job.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import KeyHints from '../components/KeyHints.vue'
import { resetExtras } from '../store.js'
import { send, liveScene, note, clone } from './storeHelpers.js'

// KeyHints.vue anchors itself bottom-right, so the story just mounts it.
const view = () => h(KeyHints)

const show = liveScene((args) => {
  resetExtras()
  send({ action: 'keys:show', items: clone(args.items || []) })
}, view)

const call = (items) => 'Core.UI.keys.show({\n'
  + items.map((i) => "    { key = '" + i.key + "', label = '" + i.label + "' },").join('\n')
  + '\n})\n-- …when the player leaves the zone:\nCore.UI.keys.hide()'

const base = {
  parameters: {
    lua: {
      message: 'keys:show',
      note: 'The row is replaced wholesale by the next `keys:show` — there is no stack.',
    },
  },
  render: show,
}

export default {
  title: 'Built-ins/Key Hints',
  component: KeyHints,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The row an interaction zone, a minigame or a vehicle puts up to say which keys are '
          + 'live right now. `Core.Interactions` drives it the same way it drives the text UI. Items '
          + 'without a `key` are dropped in the store, so a malformed Lua table cannot render a blank cap.',
      },
    },
  },
  argTypes: {
    items: {
      control: 'object',
      description: 'Array of `{ key, label }`, in the order they should read left to right.',
      table: { category: 'keys:show' },
    },
  },
  args: { items: [{ key: 'E', label: 'Interact' }] },
}

export const Single = {
  ...base,
  name: 'One key',
  args: { items: [{ key: 'E', label: 'Interact' }] },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call([{ key: 'E', label: 'Interact' }]) },
    docs: { description: { story: 'The smallest useful row. The pill hugs its content, so one hint stays small.' } },
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.items[0].label)).toBeInTheDocument())
    expect(canvas.getByText(args.items[0].key)).toBeInTheDocument()
    expect(getComputedStyle(canvasElement.querySelector('.keys')).pointerEvents).toBe('none')
  },
}

export const Several = {
  ...base,
  name: 'A full row',
  args: {
    items: [
      { key: 'E', label: 'Interact' },
      { key: 'G', label: 'Enter as passenger' },
      { key: 'F2', label: 'Inventory' },
      { key: 'X', label: 'Cancel' },
    ],
  },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: call([
        { key: 'E', label: 'Interact' },
        { key: 'G', label: 'Enter as passenger' },
        { key: 'F2', label: 'Inventory' },
        { key: 'X', label: 'Cancel' },
      ]),
    },
    docs: {
      description: {
        story: 'What a vehicle or a job zone typically shows. Multi-character caps (`F2`) grow the '
          + 'box instead of shrinking the text, so every cap keeps the same height.',
      },
    },
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvasElement.querySelectorAll('.keys .hint').length).toBe(args.items.length))
    for (const item of args.items) {
      expect(canvas.getByText(item.key)).toBeInTheDocument()
      expect(canvas.getByText(item.label)).toBeInTheDocument()
    }
  },
}

export const KeysOnly = {
  ...base,
  name: 'Caps without labels',
  args: { items: [{ key: 'W' }, { key: 'A' }, { key: 'S' }, { key: 'D' }] },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: "Core.UI.keys.show({ { key = 'W' }, { key = 'A' }, { key = 'S' }, { key = 'D' } })" },
    docs: { description: { story: '`label` is optional — a bare cap row, for a minigame that only needs to show the controls.' } },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.keys .cap').length).toBe(4))
    expect(canvasElement.querySelector('.keys .label')).toBeNull()
  },
}

export const Overflow = {
  ...base,
  name: 'Too many (wraps)',
  args: {
    items: [
      { key: 'E', label: 'Interact' },
      { key: 'G', label: 'Enter as passenger' },
      { key: 'F2', label: 'Inventory' },
      { key: 'F3', label: 'Vehicle keys' },
      { key: 'M', label: 'Radial menu' },
      { key: 'X', label: 'Hands up' },
      { key: 'B', label: 'Point' },
    ],
  },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: 'Core.UI.keys.show(everyKeyYouCanThinkOf)   -- do not' },
    docs: {
      description: {
        story: 'The row wraps at `max-width: 64vw` rather than running off screen — but a wrapped '
          + 'second line grows UP into the spinner, so keep a row to four or five hints.',
      },
    },
  },
  render: liveScene((args) => {
    resetExtras()
    send({ action: 'keys:show', items: clone(args.items || []) })
  }, () => [h(KeyHints), note('max-width: 64vw -> the row wraps instead of clipping')]),
}

export const Hidden = {
  ...base,
  name: 'Hidden',
  args: { items: [{ key: 'E', label: 'Interact' }] },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: "Core.UI.keys.hide()   -- -> { action = 'keys:hide' }" },
    docs: { description: { story: '`keys:hide` empties the list as well as the flag, so nothing can flash back on the next show.' } },
  },
  render: liveScene((args) => {
    resetExtras()
    send({ action: 'keys:show', items: clone(args.items || []) })
    send({ action: 'keys:hide' })
  }, () => [h(KeyHints), note('keys:hide — nothing renders')]),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.keys')).toBeNull())
  },
}
