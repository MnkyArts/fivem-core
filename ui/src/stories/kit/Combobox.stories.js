// Kit/Forms/Combobox — CoreCombobox (DESIGN §53, §37.5 Forms — text).
import { h, ref } from 'vue'
import { expect, waitFor } from 'storybook/test'
import CoreCombobox from '../../kit/components/CoreCombobox.vue'
import ComboboxGallery from './scenes/ComboboxGallery.vue'

const OPTIONS = [
  { value: 'lspd', label: 'LSPD', description: 'Los Santos Police' },
  { value: 'bcso', label: 'BCSO', description: 'Blaine County Sheriff' },
  { value: 'ems', label: 'EMS', description: 'Pillbox Medical' },
  { value: 'mechanic', label: 'Mechanic', description: 'Benny’s Original Motor Works' },
  { value: 'ballas', label: 'Ballas' },
  { value: 'families', label: 'Families' },
  { value: 'vagos', label: 'Vagos', disabled: true },
]

export default {
  title: 'Kit/Forms/Combobox',
  component: CoreCombobox,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The filterable select: `options` (strings or `{ value, label, description?, icon?, disabled? }`) '
          + 'filtered as you type, or an async `search(query)` that replaces them (debounced by `debounce`, stale '
          + 'answers dropped). `multiple` keeps an array and renders tags; `creatable` offers the typed text as a '
          + 'new value (and emits `create`); past `virtualThreshold` (100) rows the list is virtualised. Focus never '
          + 'leaves the input; Escape closes the list through the kit\'s escape layer before the page sees it.',
      },
      story: { inline: false, height: '420px' },
    },
  },
  argTypes: {
    multiple: { control: 'boolean' },
    creatable: { control: 'boolean' },
    clearable: { control: 'boolean' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    placeholder: { control: 'text' },
    invalid: { control: 'boolean' },
    disabled: { control: 'boolean' },
    options: { control: false },
  },
  args: { multiple: false, creatable: false, clearable: true, size: 'md', placeholder: 'Search…', invalid: false, disabled: false },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const value = ref(args.multiple ? ['lspd'] : 'ems')
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '420px' } }, [
        h(CoreCombobox, {
          ...args,
          options: OPTIONS,
          modelValue: value.value,
          'onUpdate:modelValue': (v) => { value.value = v },
        }),
        h('p', { class: 'core-label', style: { marginTop: '14px' } }, 'value: ' + JSON.stringify(value.value)),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const input = await waitFor(() => {
      const el = canvasElement.querySelector('.core-combobox__input')
      expect(el).not.toBeNull()
      return el
    })
    expect(input.value).toBe('EMS')
    input.focus()
    input.value = 'bla'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    const popup = await waitFor(() => {
      const el = document.querySelector('.core-combobox__popup')
      expect(el).not.toBeNull()
      return el
    })
    await waitFor(() => expect(popup.querySelectorAll('.core-combobox__option').length).toBe(1))
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
    await waitFor(() => expect(input.value).toBe('BCSO'))
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(ComboboxGallery) }),
  parameters: {
    docs: {
      description: { story: 'Local filter, multiple with tags, creatable, the async player picker, 5 000 virtualised models, invalid and disabled.' },
      story: { inline: false, height: '900px' },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-combobox').length).toBe(7))
    expect(canvasElement.querySelectorAll('.core-combobox__tag').length).toBe(3)
    expect(canvasElement.querySelector('.core-combobox.is-invalid')).not.toBeNull()
    expect(canvasElement.querySelector('.core-combobox.is-disabled')).not.toBeNull()
  },
}
