// Kit/Forms/Vector Input — CoreVectorInput (DESIGN §53, §37.5 Forms — text).
import { h, ref } from 'vue'
import { expect, waitFor } from 'storybook/test'
import CoreVectorInput from '../../kit/components/CoreVectorInput.vue'
import VectorInputGallery from './scenes/VectorInputGallery.vue'

export default {
  title: 'Kit/Forms/Vector Input',
  component: CoreVectorInput,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: '`{ x, y, z }` as three CoreNumberInputs sharing `step` / `precision`; `min` / `max` are a number or '
          + 'per-axis `{ x, y, z }`. Axis caps wear the gizmo colours (`axisColors`), `rotation` adds the ° suffix, '
          + '`labels` renames the caps. Copy writes `x, y, z` (to the browser clipboard when the CEF allows it, and '
          + 'always to the kit\'s own); paste reads `1, 2, 3`, `vector3(1, 2, 3)`, `{ x = 1, … }` or JSON. Emits '
          + '`copy` (text) and `paste` (vector).',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    step: { control: { type: 'number', min: 0.001, step: 0.001 } },
    rotation: { control: 'boolean' },
    axisColors: { control: 'boolean' },
    copyable: { control: 'boolean' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    invalid: { control: 'boolean' },
    disabled: { control: 'boolean' },
  },
  args: { step: 0.01, rotation: false, axisColors: true, copyable: true, size: 'sm', invalid: false, disabled: false },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const v = ref({ x: 215.4, y: -810.02, z: 30.73 })
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '680px' } }, [
        h(CoreVectorInput, { ...args, modelValue: v.value, 'onUpdate:modelValue': (n) => { v.value = n } }),
        h('p', { class: 'core-label', style: { marginTop: '14px' } }, 'value: ' + JSON.stringify(v.value)),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const root = await waitFor(() => {
      const el = canvasElement.querySelector('.core-vector')
      expect(el).not.toBeNull()
      return el
    })
    expect(root.querySelectorAll('.core-number').length).toBe(3)
    // A pasted vector fills all three fields, whichever one had focus.
    const field = root.querySelector('.core-vector__cell--y input')
    const data = new DataTransfer()
    data.setData('text', 'vector3(1.5, -2.25, 3)')
    field.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }))
    await waitFor(() => expect(root.querySelector('.core-vector__cell--z input').value).toBe('3.00'))
    expect(root.querySelector('.core-vector__cell--x input').value).toBe('1.50')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(VectorInputGallery) }),
  parameters: {
    docs: {
      description: { story: 'World position with bounds, copy → paste, rotation, sizes, neutral caps, the narrow wrap, invalid and disabled.' },
      story: { inline: false, height: '1100px' },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-vector').length).toBe(9))
    expect(canvasElement.querySelectorAll('.core-vector.has-axis-colors').length).toBe(8)
  },
}
