// Kit/Forms Input — CoreInput and CoreTextarea (DESIGN §37.5, Forms — text).
//
// The two text fields share one story file because they share one look: the box of §37.5 (a dark
// well, a crisp hairline, coral focus with a soft halo). CoreInput puts it on the WRAPPER so an
// icon, a prefix, a suffix and the clear button sit inside one well; CoreTextarea stacks the same
// well into a column so the character counter lands inside the box.
import { h } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import CoreInput from '../../kit/components/CoreInput.vue'
import CoreTextarea from '../../kit/components/CoreTextarea.vue'
import InputGallery from './scenes/InputGallery.vue'

const frame = (child) => h('div', { class: 'pointer-events-auto', style: { padding: '48px', maxWidth: '420px' } }, child)

export default {
  title: 'Kit/Forms/Input & Textarea',
  component: CoreInput,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The single-line field. The root wears the box and the focus ring, the `<input>` inside is '
          + 'stripped bare — so a click anywhere in the box lands on the input, `is-focused` follows the inner '
          + 'element, and icon/prefix/suffix/clear all share one well. `inheritAttrs` is off: `type`, `aria-*` '
          + 'and any listener a caller adds land on the input. Numbers with a step belong in `CoreNumberInput`, '
          + 'a list of choices in `CoreSelect`.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    modelValue: { control: 'text', description: 'v-model — always a string here.' },
    type: { control: 'select', options: ['text', 'password', 'search', 'email', 'tel'] },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'], description: '30 / 40 / 52 px.' },
    icon: { control: 'select', options: ['', 'search', 'user', 'car', 'map-marker', 'lock'] },
    prefix: { control: 'text', description: 'Static text before the value (a dial code).' },
    suffix: { control: 'text', description: 'Static text after the value (`$`, `KG`).' },
    placeholder: { control: 'text' },
    clearable: { control: 'boolean', description: 'Shows the ✕ while there is a value.' },
    invalid: { control: 'boolean' },
    disabled: { control: 'boolean' },
    readonly: { control: 'boolean' },
    maxlength: { control: 'number' },
  },
  args: {
    modelValue: 'Mara Kessler',
    type: 'text',
    size: 'md',
    icon: 'user',
    prefix: '',
    suffix: '',
    placeholder: 'Character name',
    clearable: true,
    invalid: false,
    disabled: false,
    readonly: false,
  },
}

export const Playground = {
  // Args are read INSIDE the render function (README): the vue3 renderer mutates one reactive args
  // proxy instead of remounting, so writing the model back onto it keeps typing and the control in
  // sync with each other.
  render: (args) => ({
    setup: () => () => frame(h(CoreInput, {
      ...args,
      'onUpdate:modelValue': (v) => { args.modelValue = v },
    })),
  }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    const box = canvasElement.querySelector('.core-inputbox')
    const input = canvas.getByPlaceholderText('Character name')
    await userEvent.clear(input)
    await userEvent.type(input, 'Ana Vela')
    await waitFor(() => expect(input.value).toBe('Ana Vela'))
    // Focus lights the whole well, not just the inner element.
    expect(box.classList.contains('is-focused')).toBe(true)
    await userEvent.click(canvasElement.querySelector('.core-inputbox__clear'))
    await waitFor(() => expect(input.value).toBe(''))
  },
}

export const Textarea = {
  name: 'Textarea',
  args: { modelValue: 'Keeps a spare fuel can in every trunk she touches.', rows: 4, maxlength: 120, counter: true },
  argTypes: {
    rows: { control: { type: 'number', min: 2, max: 12 } },
    counter: { control: 'boolean', description: 'Puts `used / maxlength` inside the well.' },
    resize: { control: 'inline-radio', options: ['none', 'vertical'] },
  },
  render: (args) => ({
    setup: () => () => frame(h(CoreTextarea, {
      rows: args.rows,
      maxlength: args.maxlength,
      counter: args.counter,
      resize: args.resize,
      invalid: args.invalid,
      disabled: args.disabled,
      placeholder: 'Character biography',
      modelValue: args.modelValue,
      'onUpdate:modelValue': (v) => { args.modelValue = v },
    })),
  }),
  parameters: {
    docs: {
      description: {
        story: 'Same well, laid out as a column: the counter lives inside the box, so a stacked form keeps '
          + 'exactly one rectangle per control. Resizing is off by default — a drag handle inside a fixed '
          + 'game panel pulls the layout apart.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-textarea__el')).not.toBeNull())
    const counter = canvasElement.querySelector('.core-textarea__counter')
    expect(counter.textContent.trim()).toBe('49 / 120')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(InputGallery) }),
  parameters: {
    layout: 'fullscreen',
    docs: {
      story: { inline: false, height: '1180px' },
      description: { story: 'Every size, affix and state of both fields, with one input focused on mount.' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Input & Textarea')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-inputbox').length).toBeGreaterThan(8)
    expect(canvasElement.querySelector('.core-inputbox.is-invalid')).not.toBeNull()
    expect(canvasElement.querySelector('.core-inputbox.is-disabled')).not.toBeNull()
    expect(canvasElement.querySelector('.core-textarea__counter.is-over')).not.toBeNull()
  },
}
