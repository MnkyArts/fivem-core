// Kit/Forms Number input — CoreNumberInput (DESIGN §37.5, Forms — text).
//
// `[-] 12 [+]` on the box look. The model is always a NUMBER: the field keeps its own text while
// it is being typed (a half-written "1" or "-" is not thrown away and nothing clamps mid-keystroke)
// and commits — parse, clamp, round to `precision` — on blur and on Enter.
import { h, ref } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import CoreNumberInput from '../../kit/components/CoreNumberInput.vue'
import NumberInputGallery from './scenes/NumberInputGallery.vue'

export default {
  title: 'Kit/Forms/Number Input',
  component: CoreNumberInput,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'For a quantity with a step: how many rounds to buy, how many litres to pump, a HUD scale in '
          + 'percent. The buttons repeat while held (400 ms, then every 60 ms) and go disabled at the bounds, so '
          + 'a hold can never run past min/max; ↑/↓ step from the keyboard. For a free-form number with no step '
          + 'use CoreInput, for a value picked from a range use CoreSlider.',
      },
      story: { inline: false, height: '240px' },
    },
  },
  argTypes: {
    modelValue: { control: 'number', description: 'v-model — never a string.' },
    min: { control: 'number', description: '`null` = unbounded (the empty field then falls back to 0).' },
    max: { control: 'number' },
    step: { control: 'number' },
    precision: { control: 'number', description: 'Decimals kept on commit. Empty = as many as `step` has.' },
    suffix: { control: 'text', description: 'Unit after the number (`L`, `%`, `KG`).' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    invalid: { control: 'boolean' },
    disabled: { control: 'boolean' },
  },
  args: { modelValue: 12, min: 0, max: 60, step: 1, suffix: '', size: 'md', invalid: false, disabled: false },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', maxWidth: '260px' } },
      h(CoreNumberInput, { ...args, 'onUpdate:modelValue': (v) => { args.modelValue = v } })),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-number__el')).not.toBeNull())
    const [dec, inc] = canvasElement.querySelectorAll('.core-number__btn')
    const field = canvasElement.querySelector('.core-number__el')
    await userEvent.click(inc)
    await waitFor(() => expect(field.value).toBe('13'))
    await userEvent.click(dec)
    await waitFor(() => expect(field.value).toBe('12'))
    // ↑/↓ step from the field itself.
    field.focus()
    await userEvent.keyboard('{ArrowUp}{ArrowUp}')
    await waitFor(() => expect(field.value).toBe('14'))
  },
}

export const Clamping = {
  name: 'Typing clamps on blur',
  args: { modelValue: 4, min: 1, max: 20, step: 1 },
  render: (args) => ({
    setup: () => {
      const value = ref(args.modelValue)
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', maxWidth: '360px' } }, [
        h(CoreNumberInput, {
          min: args.min,
          max: args.max,
          step: args.step,
          modelValue: value.value,
          'onUpdate:modelValue': (v) => { value.value = v },
        }),
        h('p', { class: 'core-text', style: { marginTop: '14px' } },
          'model: ' + value.value + ' (' + typeof value.value + ')'),
      ])
    },
  }),
  parameters: {
    docs: {
      description: {
        story: 'Typing is free — 900 is allowed into the field and reaches the model unclamped, because clamping '
          + 'while a player is still typing eats the second digit of every number. Blur or Enter commits: clamp '
          + 'into `min`/`max`, round to `precision`, and the field is rewritten with the committed value.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    const field = canvasElement.querySelector('.core-number__el')
    await userEvent.clear(field)
    await userEvent.type(field, '900')
    await waitFor(() => expect(field.value).toBe('900'))
    await userEvent.keyboard('{Enter}')
    await waitFor(() => expect(field.value).toBe('20'))
    // An empty field commits to `min`, never to NaN.
    await userEvent.clear(field)
    await userEvent.tab()
    await waitFor(() => expect(field.value).toBe('1'))
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(NumberInputGallery) }),
  parameters: {
    layout: 'fullscreen',
    docs: {
      story: { inline: false, height: '1000px' },
      description: { story: 'Sizes, both bounds, decimal steps with units, and the invalid/disabled states.' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Number input')).toBeInTheDocument())
    // Two controls sit exactly on a bound, so at least two buttons must be disabled.
    expect(canvasElement.querySelectorAll('.core-number__btn[disabled]').length).toBeGreaterThan(1)
    expect(canvasElement.querySelector('.core-number.is-invalid')).not.toBeNull()
  },
}
