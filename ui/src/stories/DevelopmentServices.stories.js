// DESIGN §40: the actual shell widgets driven through their NUI messages.
import { h } from 'vue'
import { expect, userEvent, waitFor, within } from 'storybook/test'
import InputDialog from '../shell/InputDialog.vue'
import Menu from '../shell/Menu.vue'
import SkillCheck from '../shell/SkillCheck.vue'
import { clone, liveScene, send } from './storeHelpers.js'
import { lastPost } from './luaBridge.js'

let sequence = 0
const id = () => 'sb-development-' + ++sequence
const fields = [
  { name: 'notes', type: 'textarea', label: 'Delivery notes', default: 'Leave the package\nby the warehouse door' },
  { name: 'password', type: 'password', label: 'Access phrase', default: 'warehouse' },
  { name: 'volume', type: 'slider', label: 'Radio volume', min: 0, max: 100, step: 5, default: 45 },
  { name: 'equipment', type: 'multiselect', label: 'Equipment', searchable: true, default: ['radio'], options: [{ label: 'Radio', value: 'radio' }, { label: 'Toolkit', value: 'toolkit' }, { label: 'No tracker', value: false }] },
  { name: 'date', type: 'date', label: 'Delivery date', default: '2026-09-21' },
  { name: 'time', type: 'time', label: 'Delivery time', default: '14:30' },
  { name: 'color', type: 'color', label: 'Route colour', default: '#f6503f' },
]
const menuItems = [
  { label: 'Radio enabled', checked: true, value: 1, metadata: [{ label: 'Channel', value: 'Dispatch' }], progress: 65 },
  { label: 'Transmission power', value: 2, values: ['Low', 'Medium', 'High'], selected: 2 },
  { label: 'Advanced settings', value: 3, items: [{ label: 'Reset settings', value: 4 }, { label: 'Save preset', value: 5 }] },
  { label: 'Done', value: 6 },
]
const openForm = (args) => send({ action: 'input:open', id: id(), title: args.title, fields: clone(args.fields) })
const openMenu = (args) => send({ action: 'menu:open', id: id(), title: args.title, items: clone(args.items) })
const openCheck = (args) => send({ action: 'skillcheck:open', id: id(), difficulty: clone(args.difficulty), keys: clone(args.keys), canCancel: args.canCancel })

export default {
  title: 'Built-ins/Development services',
  parameters: { layout: 'fullscreen', docs: { description: { component: 'Dependency-free development widgets (§40). Lua validates results against the original schema. Skill checks only report presentation outcomes: permissions, timing and rewards remain server-authoritative.' } } },
}

export const RichForm = {
  name: 'Expanded input controls',
  args: { title: 'Prepare delivery', fields },
  render: liveScene(openForm, () => h(InputDialog)),
  parameters: { lua: { message: 'input:open', callback: 'input_result', call: "local values = Core.UI.input.open({ title = 'Prepare delivery', fields = {\n    { name = 'notes', type = 'textarea', label = 'Notes' },\n    { name = 'volume', type = 'slider', min = 0, max = 100, default = 45 },\n    { name = 'equipment', type = 'multiselect', searchable = true, options = { 'Radio', 'Toolkit' } },\n} })" } },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvasElement.querySelector('textarea')).toBeTruthy())
    await userEvent.click(canvas.getByRole('button', { name: 'OK' }))
    await waitFor(() => expect(lastPost('input_result')?.values?.volume).toBe(45))
    expect(lastPost('input_result').values.notes).toContain('\n')
    expect(lastPost('input_result').values.equipment).toEqual(['radio'])
    openForm(args)
  },
}

export const RichMenu = {
  name: 'Checkboxes, side-scroll and submenus',
  args: { title: 'Radio settings', items: menuItems },
  render: liveScene(openMenu, () => h(Menu)),
  parameters: { lua: { message: 'menu:open', callback: 'menu_change', call: "Core.UI.menu.open({ title = 'Radio settings', items = {\n    { label = 'Radio enabled', checked = true, value = 'enabled', onChange = function(value, checked) end },\n    { label = 'Power', values = { 'Low', 'High' }, selected = 1, value = 'power' },\n    { label = 'Advanced', items = { { label = 'Save', value = 'save' } } },\n} })" } },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Radio enabled')).toBeInTheDocument())
    await userEvent.click(canvas.getByText('Radio enabled'))
    await waitFor(() => expect(lastPost('menu_change')?.checked).toBe(false))
    await userEvent.click(canvas.getByText('Advanced settings'))
    await waitFor(() => expect(canvas.getByText('Reset settings')).toBeInTheDocument())
    await userEvent.keyboard('{Escape}')
    await waitFor(() => expect(canvas.getByText('Transmission power')).toBeInTheDocument())
    openMenu(args)
  },
}

export const TimingChallenge = {
  name: 'Cancellable multi-stage skill check',
  args: { difficulty: ['easy', 'medium', 'hard'], keys: ['e', 'q'], canCancel: true },
  render: liveScene(openCheck, () => h(SkillCheck)),
  parameters: { lua: { message: 'skillcheck:open', callback: 'skillcheck_result', call: "local passed = Core.UI.skillCheck({ difficulty = { 'easy', 'medium', 'hard' }, keys = { 'e', 'q' }, canCancel = true })\n-- Presentation only: the server still validates eligibility and elapsed time." }, docs: { description: { story: 'Press the indicated key when the cursor enters the highlighted window. Each stage changes key. A miss, wrong key, pause, or cancellation fails. Controls reopen the challenge.' } } },
  play: async ({ canvasElement, args }) => {
    await waitFor(() => expect(canvasElement.querySelector('.skillcheck-track')).toBeTruthy())
    await userEvent.keyboard('{Escape}')
    await waitFor(() => expect(lastPost('skillcheck_result')?.success).toBe(false))
    openCheck(args)
  },
}
