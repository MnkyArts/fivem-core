// Confirm / alert panel (DESIGN §6.10 `alert:open`) — Enter confirms, Esc cancels.
//
// Lua side: `local ok = Core.UI.alert({ title, message, confirm, cancel })` blocks and
// returns a boolean. There is no third answer: Escape, the cancel button and a closed NUI
// all resolve `false`, so `if not ok then return end` is always safe.
import { h } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import AlertDialog from '../shell/AlertDialog.vue'
import { send, liveScene, clone } from './storeHelpers.js'
import { lastPost } from './luaBridge.js'

const view = () => h(AlertDialog)

let seq = 0
const rid = () => 'sb-alert-' + ++seq

const build = (args) => send({
  action: 'alert:open',
  id: rid(),
  title: args.title,
  message: clone(args.message),
  confirm: args.confirm,
  cancel: args.cancel === '' ? false : args.cancel, // '' here == `cancel = false` in Lua
})

const open = liveScene(build, view)

const resolve = (name, body) => (name === 'alert_result'
  ? 'Core.UI.alert{...}  ->  ' + (body.confirmed ? 'true     -- confirm button / Enter' : 'false    -- cancel button / Esc')
  : null)

const call = (a) => 'local ok = Core.UI.alert({\n'
  + "    title = '" + a.title + "',\n"
  + '    message = ' + (Array.isArray(a.message) ? 'table.concat(lines, \'\\n\')' : "'" + String(a.message).split('\n')[0] + "…'") + ',\n'
  + "    confirm = '" + a.confirm + "',\n"
  + (a.cancel === '' ? '    cancel = false,\n' : "    cancel = '" + a.cancel + "',\n")
  + '})\nif not ok then return end'

export default {
  title: 'Built-ins/Alert Dialog',
  component: AlertDialog,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The yes/no modal. The confirm button takes focus on open, Tab cycles between '
          + 'the buttons, Enter answers with whichever one has focus and Escape (owned by `store.js`) '
          + 'always answers `false`. `message` may be a string or an array of lines; the panel '
          + 'renders it `white-space: pre-line`, capped at 50vh with its own scrollbar.',
      },
    },
  },
  argTypes: {
    title: { control: 'text', description: 'Heading.', table: { category: 'alert:open' } },
    message: { control: 'text', description: 'Body. A Lua array of lines is joined with newlines.', table: { category: 'alert:open' } },
    confirm: { control: 'text', description: 'Primary button label.', table: { category: 'alert:open' } },
    cancel: {
      control: 'text',
      description: 'Secondary button label. Empty here == `cancel = false` in Lua.',
      table: { category: 'alert:open' },
    },
  },
}

export const ConfirmAndCancel = {
  name: 'Confirm + cancel',
  args: {
    title: 'Sell this vehicle?',
    message: 'The Bravado Buffalo STX will be sold to the dealership for $18,400.\nThis cannot be undone.',
    confirm: 'Sell it',
    cancel: 'Keep it',
  },
  parameters: {
    lua: {
      message: 'alert:open',
      callback: 'alert_result',
      resolve,
      call: call({ title: 'Sell this vehicle?', message: 'The Bravado Buffalo STX will be sold…', confirm: 'Sell it', cancel: 'Keep it' }),
      note: 'The play function presses Enter with the confirm button focused.',
    },
    docs: {
      description: {
        story: 'Both buttons. The confirm button is focused on open, so a player who mashes Enter '
          + 'says yes — put the destructive answer in `cancel` if that matters.\n\n'
          + '```lua\nif Core.UI.alert({ title = …, confirm = \'Sell it\', cancel = \'Keep it\' }) then\n'
          + '    sellVehicle()\nend\n```',
      },
    },
  },
  render: open,
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    const confirmBtn = await waitFor(() => {
      const el = canvasElement.querySelector('[data-role="confirm"]')
      expect(el).toBeTruthy()
      return el
    })
    await waitFor(() => expect(canvasElement.ownerDocument.activeElement).toBe(confirmBtn))
    await userEvent.keyboard('{Enter}')
    await waitFor(() => expect(lastPost('alert_result')).toBeTruthy())
    expect(lastPost('alert_result').confirmed).toBe(true)
    await waitFor(() => expect(canvas.queryByRole('alertdialog')).toBeNull())
    build(args) // reopen, so the story is still something you can answer by hand
  },
}

export const ConfirmOnly = {
  name: 'Confirm only',
  args: {
    title: 'Impounded',
    message: 'Your vehicle was impounded while you were offline. Collect it at the depot on Davis Avenue.',
    confirm: 'Understood',
    cancel: '',
  },
  parameters: {
    lua: {
      message: 'alert:open',
      callback: 'alert_result',
      resolve,
      call: call({ title: 'Impounded', message: 'Your vehicle was impounded…', confirm: 'Understood', cancel: '' }),
    },
    docs: {
      description: {
        story: '`cancel = false` from Lua drops the second button entirely — an acknowledgement, not '
          + 'a question. Escape still exists and still returns `false`, so treat the answer as '
          + '"dismissed", not "agreed".',
      },
    },
  },
  render: open,
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.title)).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-btn')).toHaveLength(1)
    await userEvent.click(canvas.getByRole('button', { name: args.confirm }))
    await waitFor(() => expect(lastPost('alert_result')).toBeTruthy())
    expect(lastPost('alert_result').confirmed).toBe(true)
    build(args) // reopen for the reader
  },
}

export const Danger = {
  name: 'Long message (Esc cancels)',
  args: {
    title: 'Leave the faction?',
    message: [
      'Leaving the Los Santos Police Department removes your rank, your fleet access and every stored duty weapon.',
      '',
      'Your personal property is not affected.',
      'Rejoining requires an invite from a command-rank officer.',
    ],
    confirm: 'Leave',
    cancel: 'Stay',
  },
  argTypes: {
    message: { control: 'object', description: 'Array of lines, joined with newlines by the component.', table: { category: 'alert:open' } },
  },
  parameters: {
    lua: {
      message: 'alert:open',
      callback: 'alert_result',
      resolve,
      call: call({ title: 'Leave the faction?', message: [], confirm: 'Leave', cancel: 'Stay' }),
      note: 'The play function presses Escape instead of clicking — same callback, confirmed = false.',
    },
    docs: {
      description: {
        story: 'A multi-line `message` (Lua array) and the cancel path: Escape is handled by '
          + '`store.handleKeydown`, not by this component, and posts `alert_result { confirmed = false }` '
          + 'so `Core.UI.alert` returns **false**.',
      },
    },
  },
  render: open,
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.title)).toBeInTheDocument())
    await userEvent.keyboard('{Escape}')
    await waitFor(() => expect(lastPost('alert_result')).toBeTruthy())
    expect(lastPost('alert_result').confirmed).toBe(false)
    await waitFor(() => expect(canvas.queryByRole('alertdialog')).toBeNull())
    build(args) // reopen for the reader
  },
}
