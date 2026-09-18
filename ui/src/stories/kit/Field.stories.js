// Kit/Forms Field — CoreField (DESIGN §37.5, Forms — text).
//
// The wrapper every control sits in. It owns the control's DOM id and hands it to the slot with
// `invalid`, so a caller wires label, control and message in one line. `inline` is the settings
// row of the mockups; without it the field is the stacked form field.
import { h, ref } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreField from '../../kit/components/CoreField.vue'
import CoreInput from '../../kit/components/CoreInput.vue'
import FieldGallery from './scenes/FieldGallery.vue'

export default {
  title: 'Kit/Forms/Field',
  component: CoreField,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Label + control + hint/error. An `error` replaces the hint rather than stacking under it — '
          + 'two messages under one control read as two problems. Stacked, the label wears the label voice '
          + '(display 600, 12 px, 0.14 em); inline, it drops to body copy, because a settings block reads as a '
          + 'list of sentences and not as a stack of captions. A control that needs no caption needs no field.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    label: { control: 'text' },
    hint: { control: 'text', description: 'Quiet help line. Hidden while `error` is set.' },
    error: { control: 'text', description: 'Its presence is what makes the field invalid.' },
    required: { control: 'boolean', description: 'Adds the coral asterisk after the label.' },
    inline: { control: 'boolean', description: 'The settings row: text left, control right, hairline under.' },
    controlWidth: { control: 'text', description: 'Width of the control column in an inline row.' },
  },
  args: {
    label: 'Character name',
    hint: 'Shown to everyone in range.',
    error: '',
    required: true,
    inline: false,
    controlWidth: '50%',
  },
}

export const Playground = {
  render: (args) => ({
    setup: () => {
      const value = ref('Mara Kessler')
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', maxWidth: '520px' } }, [
        h(CoreField, { ...args }, {
          default: ({ id, invalid }) => h(CoreInput, {
            id,
            invalid,
            icon: 'user',
            clearable: true,
            modelValue: value.value,
            'onUpdate:modelValue': (v) => { value.value = v },
          }),
        }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Character name')).toBeInTheDocument())
    // The label's `for` and the input's id are the same generated id.
    const label = canvasElement.querySelector('.core-field__label')
    const input = canvasElement.querySelector('.core-inputbox__el')
    expect(label.getAttribute('for')).toBe(input.getAttribute('id'))
    expect(canvasElement.querySelector('.core-field__required')).not.toBeNull()
  },
}

export const Invalid = {
  name: 'Invalid',
  args: { error: 'That name is already on the registry.', hint: 'Shown to everyone in range.' },
  render: Playground.render,
  parameters: {
    docs: {
      description: {
        story: 'With `error` set the field carries `is-invalid`, the slot receives `invalid: true` (which the '
          + 'control turns into its red border) and the hint is replaced by the message with its icon.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-field.is-invalid')).not.toBeNull())
    expect(canvasElement.querySelector('.core-field__hint')).toBeNull()
    expect(canvasElement.querySelector('.core-inputbox.is-invalid')).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(FieldGallery) }),
  parameters: {
    layout: 'fullscreen',
    docs: {
      story: { inline: false, height: '900px' },
      description: { story: 'A settings block of inline rows next to a stacked form, including two error states.' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Field')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-field--inline').length).toBeGreaterThan(3)
    expect(canvasElement.querySelectorAll('.core-field.is-invalid').length).toBe(2)
  },
}
