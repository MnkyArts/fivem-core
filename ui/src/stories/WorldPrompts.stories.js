// World interaction dots (DESIGN §6.7 `worldprompts:set`) — CoreInteractionDot mounted by the
// shell at the projected world position: idle a ring around a core, focused (the player LOOKS at
// it) the [E] cap + band, disabled the outline lock.
//
// There is no Lua API behind the message: client/interactions.lua projects its enabled
// `.worldPrompt` entries and sends the WHOLE visible set — the stories push the same whole-set
// payload through the dev shim. An empty list clears the layer.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import WorldPrompts from '../shell/WorldPrompts.vue'
import { resetExtras } from '../store.js'
import { send, liveScene, note, clone } from './storeHelpers.js'

// 0.5 / 0.75 multiply the viewport to exact px, so the play function can assert the projected
// pixel position without an epsilon.
const FOCUSED = {
  id: 'crate', x: 0.5, y: 0.75, focused: true,
  keys: 'E', label: 'Pick up the crate', description: 'Stashed weapons',
}
const IDLE = { id: 'locker', x: 0.3, y: 0.4, keys: 'E', label: 'Open the locker' }

const view = () => h(WorldPrompts)

const show = liveScene((args) => {
  resetExtras()
  send({ action: 'worldprompts:set', items: clone(args.items || []) })
}, view)

const call = (items) => "{ action = 'worldprompts:set', items = {\n"
  + items.map((i) => "    { id = '" + i.id + "', x = " + i.x + ', y = ' + i.y
    + ', focused = ' + (i.focused ? 'true' : 'false')
    + ', disabled = ' + (i.disabled ? 'true' : 'false')
    + ", keys = '" + (i.keys || 'E') + "', label = '" + (i.label || '') + "' },")
    .join('\n')
  + "\n} }   -- whole set, sent by client/interactions.lua; { items = {} } clears"

const base = {
  parameters: {
    lua: {
      message: 'worldprompts:set',
      note: 'The set is replaced wholesale — there is no add/remove and no per-dot message.',
    },
  },
  render: show,
}

export default {
  title: 'Built-ins/World Prompts',
  component: WorldPrompts,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The 3D interaction marker. `worldPrompt = true` on a `Core.Interactions` entry '
          + 'replaces the bottom pill with a dot projected onto its world position; the entry the '
          + 'player looks at becomes the [E] cap + band and is the one `core_interact` fires. One '
          + 'whole-set message per change, nearest first; an empty list clears the layer.',
      },
    },
  },
  argTypes: {
    items: {
      control: 'object',
      description: 'Array of `{ id, x, y, keys, label, icon?, description?, focused?, disabled? }` '
        + '— normalized screen coords (0..1), bounded text fields.',
      table: { category: 'worldprompts:set' },
    },
  },
  args: { items: [clone(FOCUSED), clone(IDLE)] },
}

export const FocusedAndIdle = {
  ...base,
  name: 'Looked-at + idle',
  args: { items: [clone(FOCUSED), clone(IDLE)] },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call([FOCUSED, IDLE]) },
    docs: {
      description: { story: 'The dot under the reticle opens cap + band; the others stay the idle ring.' },
    },
  },
  play: async ({ canvasElement, args }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-interaction-dot').length).toBe(args.items.length))
    const [focused, idle] = canvasElement.querySelectorAll('.core-interaction-dot')
    // Projected pixel position: x/y arrive normalized, the widget multiplies by the viewport and
    // carries the point as a composited transform on the wrapper (the dot itself is the 0 x 0
    // anchor). Inline style = the target, so a running transition never flakes the assertion.
    const at = (item) => 'translate3d(' + (item.x * window.innerWidth) + 'px,' + (item.y * window.innerHeight) + 'px,0)'
    expect(focused.parentElement.style.transform).toBe(at(args.items[0]))
    expect(focused.className).toContain('is-focused')
    // Focused: the [E] cap and the band are on and carry the key + label.
    expect(getComputedStyle(focused.querySelector('.core-interaction-dot__cap')).opacity).toBe('1')
    expect(within(focused).getByText(args.items[0].keys)).toBeInTheDocument()
    expect(within(focused).getByText(args.items[0].label)).toBeInTheDocument()
    // Idle: the same cap markup exists but sits at opacity 0 — painted as the dot only.
    expect(idle.className).not.toContain('is-focused')
    expect(getComputedStyle(idle.querySelector('.core-interaction-dot__cap')).opacity).toBe('0')
    // The whole layer is click-through (§37.4) — a dot may never eat the game's mouse look.
    expect(getComputedStyle(focused.parentElement).pointerEvents).toBe('none')
  },
}

export const OutOfReach = {
  ...base,
  name: 'Out of reach (locked)',
  args: { items: [clone(FOCUSED), { ...clone(IDLE), disabled: true }] },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call([FOCUSED, { ...IDLE, disabled: true }]) },
    docs: {
      description: {
        story: 'A dot farther than the entry\'s `radius` is `disabled` — the outline lock cap — '
          + 'and never pulses; in a focus tie an in-reach dot beats it (§6.7).',
      },
    },
  },
  play: async ({ canvasElement, args }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-interaction-dot.is-disabled')).not.toBeNull())
    const disabled = canvasElement.querySelector('.core-interaction-dot.is-disabled')
    expect(disabled.querySelector('.core-interaction-dot__cap')).not.toBeNull()
    expect(disabled.parentElement.style.transform).toBe('translate3d('
      + (args.items[1].x * window.innerWidth) + 'px,' + (args.items[1].y * window.innerHeight) + 'px,0)')
  },
}

export const Cleared = {
  ...base,
  name: 'Cleared',
  args: { items: [] },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: "{ action = 'worldprompts:set', items = {} }   -- walked out / behind the camera" },
    docs: {
      description: { story: 'An empty list clears the layer — the widget itself stays mounted, so the next set needs no remount.' },
    },
  },
  render: liveScene((args) => {
    resetExtras()
    send({ action: 'worldprompts:set', items: clone(args.items || []) })
  }, () => [h(WorldPrompts), note('items = {} — the layer stays, no dots render')]),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-interaction-dot').length).toBe(0))
    expect(canvasElement.querySelector('[aria-hidden="true"]')).not.toBeNull()
  },
}
