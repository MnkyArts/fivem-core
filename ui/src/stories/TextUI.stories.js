// Text UI pill (DESIGN §6.10 `textui:show`) — [key] + text, anchored on one of four edges.
//
// Lua side: `Core.UI.textUI.show(key, text, { position = 'bottom' })` / `.hide()` /
// `.isShown()`. All three are synchronous and return nothing useful — the pill is pure
// state, it never takes input (`pointer-events: none`) and never posts a callback.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import TextUI from '../components/TextUI.vue'
import { send, liveScene, note } from './storeHelpers.js'

const view = () => h(TextUI)

const show = liveScene((args) => send({
  action: 'textui:show',
  key: args.key,
  text: args.text,
  position: args.position,
}), view)

const call = (a) => (a.key ? "Core.UI.textUI.show('" + a.key + "', '" + a.text + "'" : "Core.UI.textUI.show(nil, '" + a.text + "'")
  + (a.position === 'bottom' ? ')' : ", { position = '" + a.position + "' })")
  + '\n-- …later\nCore.UI.textUI.hide()   -- -> { action = \'textui:hide\' }'

const base = {
  parameters: { lua: { message: 'textui:show', note: 'Hidden again with `textui:hide`; no callback either way.' } },
  render: show,
}

export default {
  title: 'Built-ins/Text UI',
  component: TextUI,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The "press E" prompt. `Core.Interactions` drives it automatically when the '
          + 'player walks into a zone, but any script can. It is one global pill: a second '
          + '`show` replaces the first, there is no stack.',
      },
    },
  },
  argTypes: {
    key: {
      control: 'text',
      description: 'Key cap. Empty / nil hides the box and leaves the text alone.',
      table: { category: 'textui:show' },
    },
    text: { control: 'text', description: 'Prompt text, one line (nowrap, max-width 42vw).', table: { category: 'textui:show' } },
    position: {
      control: 'radio',
      options: ['bottom', 'top', 'left', 'right'],
      description: 'Screen edge. Anything else falls back to `bottom`.',
      table: { category: 'textui:show', defaultValue: { summary: 'bottom' } },
    },
  },
  args: { position: 'bottom' },
}

export const Bottom = {
  ...base,
  name: 'Bottom (default)',
  args: { key: 'E', text: 'Open shop', position: 'bottom' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call({ key: 'E', text: 'Open shop', position: 'bottom' }) },
    docs: {
      description: {
        story: "```lua\nCore.UI.textUI.show('E', 'Open shop')\n```\nReturns nothing. `Core.UI.textUI.isShown()` "
          + 'reads the client-side flag back; the NUI never answers.',
      },
    },
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.text)).toBeInTheDocument())
    expect(canvas.getByText(args.key)).toBeInTheDocument()
    // The pill must stay click-through, or it would eat the game's mouse look.
    const pill = canvasElement.querySelector('.textui')
    expect(getComputedStyle(pill).pointerEvents).toBe('none')
  },
}

export const Top = {
  ...base,
  args: { key: 'G', text: 'Enter vehicle as passenger', position: 'top' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call({ key: 'G', text: 'Enter vehicle as passenger', position: 'top' }) },
  },
}

export const Left = {
  ...base,
  args: { key: 'H', text: 'Hand over the keys', position: 'left' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call({ key: 'H', text: 'Hand over the keys', position: 'left' }) },
  },
}

export const Right = {
  ...base,
  args: { key: 'F', text: 'Lockpick the door', position: 'right' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call({ key: 'F', text: 'Lockpick the door', position: 'right' }) },
  },
}

export const NoKey = {
  ...base,
  name: 'Without a key',
  args: { key: '', text: 'Waiting for the mechanic…', position: 'bottom' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call({ key: '', text: 'Waiting for the mechanic…', position: 'bottom' }) },
    docs: { description: { story: 'A status line rather than a prompt: pass `nil` as the key.' } },
  },
}

export const LongText = {
  ...base,
  name: 'Long text (clipped)',
  args: {
    key: 'E',
    text: 'Open the impound office terminal and pay the outstanding storage fee for this vehicle before it is crushed',
    position: 'bottom',
  },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: "Core.UI.textUI.show('E', longPrompt)   -- Utils.sanitize caps it long before this" },
    docs: {
      description: {
        story: 'The pill is `white-space: nowrap` with `max-width: 42vw`, so an over-long prompt '
          + 'ellipsises instead of wrapping — keep Lua-side text short.',
      },
    },
  },
  render: liveScene(
    (args) => send({ action: 'textui:show', key: args.key, text: args.text, position: args.position }),
    () => [h(TextUI), note('max-width: 42vw + nowrap -> the text ellipsises')]
  ),
}
