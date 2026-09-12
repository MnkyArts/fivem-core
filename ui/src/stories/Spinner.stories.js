// Busy spinner (DESIGN §21 `spinner:show` / `spinner:hide`) — GTA's bottom-right loading
// prompt: one line of text with a turning ring after it.
//
// Lua side: `Core.UI.spinner.show(text)` / `Core.UI.spinner.hide()` on the client,
// `Core.UI.spinner.show(src, text)` / `.hide(src)` on the server. Neither returns
// anything and nothing is posted back — unlike `progress`, the spinner has no duration
// and no cancel key, so every `show` NEEDS a matching `hide` (wrap it in a finally).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import Spinner from '../components/Spinner.vue'
import { resetExtras } from '../store.js'
import { send, liveScene, note } from './storeHelpers.js'

// Spinner.vue anchors itself bottom-right (above the key hints), so the story just mounts it.
const view = () => h(Spinner)

const show = liveScene((args) => {
  resetExtras()
  send({ action: 'spinner:show', text: args.text })
}, view)

const call = (a) => "Core.UI.spinner.show('" + a.text + "')\n"
  + 'local ok = pcall(doTheSlowThing)\n'
  + 'Core.UI.spinner.hide()   -- -> { action = \'spinner:hide\' }'

const base = {
  parameters: {
    lua: { message: 'spinner:show', note: 'No callback, no timeout: it stays up until `spinner:hide`.' },
  },
  render: show,
}

export default {
  title: 'Built-ins/Spinner',
  component: Spinner,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'For work with no measurable progress — a server round trip, a DB write, waiting '
          + 'on another player. When you DO know how long it takes, use `progress` instead: it has a '
          + 'bar, a cancel key and a promise. One global spinner, a second `show` just replaces the text.',
      },
    },
  },
  argTypes: {
    text: {
      control: 'text',
      description: 'One line, ellipsised at 42vw. Empty leaves a bare ring.',
      table: { category: 'spinner:show' },
    },
  },
  args: { text: 'Contacting dispatch' },
}

export const Default = {
  ...base,
  name: 'With text',
  args: { text: 'Contacting dispatch' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call({ text: 'Contacting dispatch' }) },
    docs: {
      description: {
        story: 'The everyday shape. Text left, ring right — the same order the game uses, so it reads '
          + 'as part of GTA rather than as a web spinner.',
      },
    },
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.text)).toBeInTheDocument())
    expect(canvasElement.querySelector('.spinner .ring')).not.toBeNull()
    expect(getComputedStyle(canvasElement.querySelector('.spinner')).pointerEvents).toBe('none')
  },
}

export const NoText = {
  ...base,
  name: 'Ring only',
  args: { text: '' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: 'Core.UI.spinner.show()   -- text is optional' },
    docs: { description: { story: 'A bare ring when the caller has nothing useful to say.' } },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.spinner')).not.toBeNull())
    expect(canvasElement.querySelector('.spinner .text')).toBeNull()
  },
}

export const LongText = {
  ...base,
  name: 'Long text (clipped)',
  args: { text: 'Waiting for the mechanic to accept the repair job you requested at the docks' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: 'Core.UI.spinner.show(longLine)   -- keep it short, it does not wrap' },
    docs: {
      description: {
        story: 'The pill is `white-space: nowrap` with `max-width: 42vw`, so an over-long line '
          + 'ellipsises instead of wrapping into the key hints below it.',
      },
    },
  },
  render: liveScene((args) => {
    resetExtras()
    send({ action: 'spinner:show', text: args.text })
  }, () => [h(Spinner), note('max-width: 42vw + nowrap -> the text ellipsises')]),
}

export const Hidden = {
  ...base,
  name: 'Hidden',
  args: { text: 'Contacting dispatch' },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: "Core.UI.spinner.show('Contacting dispatch')\n"
        + "Core.UI.spinner.hide()   -- -> { action = 'spinner:hide' }",
    },
    docs: {
      description: {
        story: '`spinner:hide` clears the text with the flag, so a later `spinner:show` never '
          + 'flashes the previous line. The frame is empty apart from the caption.',
      },
    },
  },
  render: liveScene((args) => {
    resetExtras()
    send({ action: 'spinner:show', text: args.text })
    send({ action: 'spinner:hide' })
  }, () => [h(Spinner), note('spinner:hide — nothing renders')]),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.spinner')).toBeNull())
  },
}
