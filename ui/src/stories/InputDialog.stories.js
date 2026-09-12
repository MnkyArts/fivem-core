// Input form (DESIGN §6.10 `input:open`) — text / number / select / checkbox + validation.
//
// Lua side: `local values = Core.UI.input.open({ title, fields, submit, cancel })` blocks and
// returns a table keyed by `field.name`, or nil when the player cancelled (Esc or the cancel
// button). Validation is the NUI's job: a failed submit posts nothing at all, so the Lua
// thread simply stays parked until the player fixes the form or backs out.
import { h, nextTick } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import InputDialog from '../components/InputDialog.vue'
import { send, liveScene, clone } from './storeHelpers.js'
import { lastPost } from './luaBridge.js'

const view = () => h(InputDialog)

let seq = 0
const rid = () => 'sb-input-' + ++seq

const build = (args) => send({
  action: 'input:open',
  id: rid(),
  title: args.title,
  submit: args.submit,
  cancel: args.cancel === '' ? false : args.cancel, // '' here == `cancel = false` in Lua
  fields: clone(args.fields),
})

const open = liveScene(build, view)

const resolve = (name, body) => {
  if (name !== 'input_result') return null
  if (!body.values) return 'Core.UI.input.open{...}  ->  nil        -- Esc / cancel button'
  const lines = Object.keys(body.values).map((k) => '    ' + k + ' = ' + JSON.stringify(body.values[k]) + ',')
  return 'Core.UI.input.open{...}  ->  {\n' + lines.join('\n') + '\n}'
}

const luaField = (f) => "        { name = '" + f.name + "', label = '" + (f.label || f.name) + "', type = '" + (f.type || 'text') + "'"
  + (f.default !== undefined ? ', default = ' + (typeof f.default === 'string' ? "'" + f.default + "'" : String(f.default)) : '')
  + (f.required ? ', required = true' : '')
  + (typeof f.min === 'number' ? ', min = ' + f.min : '')
  + (typeof f.max === 'number' ? ', max = ' + f.max : '')
  + (f.options ? ', options = { … }' : '')
  + ' },'

const call = (a) => 'local values = Core.UI.input.open({\n'
  + "    title = '" + a.title + "',\n"
  + "    submit = '" + a.submit + "',\n"
  + (a.cancel === '' ? '    cancel = false,\n' : "    cancel = '" + a.cancel + "',\n")
  + '    fields = {\n' + a.fields.map(luaField).join('\n') + '\n    },\n})\n'
  + 'if not values then return end   -- cancelled'

export default {
  title: 'Built-ins/Input Dialog',
  component: InputDialog,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Centred form. The component owns Tab (wrapping focus inside the panel) and '
          + 'Enter (submit, unless the cancel button has focus); `store.js` owns Escape → '
          + '`input_result { values = nil }`. Numbers come back as numbers, checkboxes as booleans, '
          + 'selects as the option `value`, everything else as a string.',
      },
    },
  },
  argTypes: {
    title: { control: 'text', description: 'Panel heading.', table: { category: 'input:open' } },
    submit: { control: 'text', description: 'Primary button label.', table: { category: 'input:open' } },
    cancel: {
      control: 'text',
      description: 'Secondary button label. Empty here == `cancel = false` in Lua: no second button.',
      table: { category: 'input:open' },
    },
    fields: {
      control: 'object',
      description: '`{ name, label, type, default?, required?, min?, max?, options?, placeholder? }[]` — '
        + 'edit and the dialog reopens with the new form.',
      table: { category: 'input:open' },
    },
  },
}

export const AllFieldTypes = {
  name: 'All field types',
  args: {
    title: 'Register vehicle',
    submit: 'Register',
    cancel: 'Cancel',
    fields: [
      { name: 'plate', label: 'Plate', type: 'text', default: 'LSPD 042', placeholder: 'e.g. 46EEK572', required: true },
      { name: 'seats', label: 'Seats', type: 'number', default: 4, min: 1, max: 8, required: true },
      {
        name: 'garage',
        label: 'Garage',
        type: 'select',
        default: 'pillbox',
        options: [
          { label: 'Pillbox Hill', value: 'pillbox' },
          { label: 'Legion Square', value: 'legion' },
          { label: 'Sandy Shores', value: 'sandy' },
        ],
      },
      { name: 'colour', label: 'Colour', type: 'select', options: ['Black', 'White', 'Police blue'] },
      { name: 'notes', label: 'Notes', type: 'text', placeholder: 'Optional' },
      { name: 'insured', label: 'Add insurance ($240)', type: 'checkbox', default: true },
    ],
  },
  parameters: {
    lua: {
      message: 'input:open',
      callback: 'input_result',
      resolve,
      call: call({
        title: 'Register vehicle',
        submit: 'Register',
        cancel: 'Cancel',
        fields: [
          { name: 'plate', label: 'Plate', type: 'text', default: 'LSPD 042', required: true },
          { name: 'seats', label: 'Seats', type: 'number', default: 4, min: 1, max: 8, required: true },
          { name: 'garage', label: 'Garage', type: 'select', default: 'pillbox', options: true },
          { name: 'colour', label: 'Colour', type: 'select', options: true },
          { name: 'notes', label: 'Notes', type: 'text' },
          { name: 'insured', label: 'Add insurance ($240)', type: 'checkbox', default: true },
        ],
      }),
      note: 'The play function retypes the plate and submits, so the result below is filled in.',
    },
    docs: {
      description: {
        story: 'Every `type` the dialog understands, with defaults applied; `options` take either '
          + '`{ label, value }` tables or plain strings (the string is used as both).\n\n'
          + '```lua\nlocal v = Core.UI.input.open({ … })\n-- v = { plate = "46EEK572", seats = 4, garage = "pillbox",\n'
          + '--       colour = "Black", notes = "", insured = true }\n```',
      },
    },
  },
  render: open,
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvasElement.querySelector('[data-field="plate"]')).toBeTruthy())
    const plate = canvasElement.querySelector('[data-field="plate"]')
    await userEvent.clear(plate)
    await userEvent.type(plate, '46EEK572')
    await userEvent.click(canvas.getByRole('button', { name: args.submit }))
    await waitFor(() => expect(lastPost('input_result')).toBeTruthy())
    const values = lastPost('input_result').values
    expect(values.plate).toBe('46EEK572')
    expect(values.seats).toBe(4)        // number field -> Lua number, not a string
    expect(values.garage).toBe('pillbox')
    expect(values.colour).toBe('Black') // no default -> first option
    expect(values.notes).toBe('')
    expect(values.insured).toBe(true)
    build(args) // reopen, so the form is still there to fill in by hand
  },
}

export const RequiredErrors = {
  name: 'Required errors (after submit)',
  args: {
    title: 'Wire transfer',
    submit: 'Send',
    cancel: 'Cancel',
    fields: [
      { name: 'iban', label: 'Account', type: 'text', placeholder: 'Account number', required: true },
      { name: 'amount', label: 'Amount', type: 'number', default: 0, min: 50, max: 25000, required: true },
      { name: 'reason', label: 'Reason', type: 'text', required: true },
      { name: 'confirm', label: 'I know this cannot be undone', type: 'checkbox', required: true },
    ],
  },
  parameters: {
    lua: {
      message: 'input:open',
      callback: 'input_result',
      resolve,
      call: call({
        title: 'Wire transfer',
        submit: 'Send',
        cancel: 'Cancel',
        fields: [
          { name: 'iban', label: 'Account', type: 'text', required: true },
          { name: 'amount', label: 'Amount', type: 'number', default: 0, min: 50, max: 25000, required: true },
          { name: 'reason', label: 'Reason', type: 'text', required: true },
          { name: 'confirm', label: 'I know this cannot be undone', type: 'checkbox', required: true },
        ],
      }),
      note: 'A failed submit posts NOTHING — the callback list below stays empty on purpose.',
    },
    docs: {
      description: {
        story: 'Validation happens on submit, not while typing: empty `required` fields and '
          + 'out-of-range numbers get a red "Required" / "Minimum 50" line, the first offender takes '
          + 'focus and the dialog stays open. No `input_result` is posted, so the Lua thread is '
          + 'still parked inside `Core.UI.input.open` — the player has to fix the form or cancel. '
          + 'Typing in a field clears its own error again.',
      },
    },
  },
  render: liveScene((args) => {
    build(args)
    // Show the error state without a click when the story is only being looked at.
    nextTick(() => {
      const btn = document.querySelector('[data-role="submit"]')
      if (btn) btn.click()
    })
  }, view),
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await userEvent.click(await waitFor(() => canvas.getByRole('button', { name: args.submit })))
    await waitFor(() => expect(canvas.getAllByText('Required').length).toBeGreaterThan(0))
    // `amount` defaults to 0, which is a number but below `min` -> its own message.
    expect(canvas.getByText('Minimum 50')).toBeInTheDocument()
    expect(lastPost('input_result')).toBeUndefined() // nothing goes back on a failed submit
    expect(canvas.getByText(args.title)).toBeInTheDocument() // still open
  },
}

export const NoCancel = {
  name: 'Submit only',
  args: {
    title: 'Name your character',
    submit: 'Continue',
    cancel: '',
    fields: [
      { name: 'first', label: 'First name', type: 'text', required: true },
      { name: 'last', label: 'Last name', type: 'text', required: true },
    ],
  },
  parameters: {
    lua: {
      message: 'input:open',
      callback: 'input_result',
      resolve,
      call: call({
        title: 'Name your character',
        submit: 'Continue',
        cancel: '',
        fields: [
          { name: 'first', label: 'First name', type: 'text', required: true },
          { name: 'last', label: 'Last name', type: 'text', required: true },
        ],
      }),
    },
    docs: {
      description: {
        story: '`cancel = false` drops the second button — but **Escape still cancels** and still '
          + 'returns nil, so a Lua flow that must not be skipped has to loop until it gets values.',
      },
    },
  },
  render: open,
}
