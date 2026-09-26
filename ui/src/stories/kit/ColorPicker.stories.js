// Kit/Forms/Color Picker — CoreColorPicker (DESIGN §53, §37.5 Forms — choice).
import { h, ref } from 'vue'
import { expect, waitFor } from 'storybook/test'
import CoreColorPicker from '../../kit/components/CoreColorPicker.vue'
import ColorPickerGallery from './scenes/ColorPickerGallery.vue'

export default {
  title: 'Kit/Forms/Color Picker',
  component: CoreColorPicker,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A colour as `#RRGGBB` (`#RRGGBBAA` with `alpha` while translucent): a hex field that commits on Enter '
          + 'or blur and marks a bad value instead of guessing, `swatches` (strings or `{ value, label }`, `[]` hides '
          + 'them), and a range per channel painted with its own live gradient. `popover` puts it behind a box-look '
          + 'trigger for a form row. No native colour input anywhere — FiveM\'s CEF renders off-screen and its popup '
          + 'would never appear.',
      },
      story: { inline: false, height: '420px' },
    },
  },
  argTypes: {
    alpha: { control: 'boolean' },
    popover: { control: 'boolean' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    invalid: { control: 'boolean' },
    disabled: { control: 'boolean' },
    swatches: { control: false },
  },
  args: { alpha: false, popover: false, size: 'md', invalid: false, disabled: false },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const color = ref('#F6503F')
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '360px' } }, [
        h(CoreColorPicker, { ...args, modelValue: color.value, 'onUpdate:modelValue': (v) => { color.value = v } }),
        h('p', { class: 'core-label', style: { marginTop: '14px' } }, 'value: ' + color.value),
      ])
    },
  }),
  play: async ({ canvasElement, args }) => {
    if (args.popover) return
    const root = await waitFor(() => {
      const el = canvasElement.querySelector('.core-colorpicker')
      expect(el).not.toBeNull()
      return el
    })
    const ranges = root.querySelectorAll('.core-colorpicker__range')
    expect(ranges.length).toBe(args.alpha ? 4 : 3)
    expect(root.querySelector('input[type="color"]')).toBeNull()
    // Moving the green channel rewrites the hex.
    ranges[1].value = '255'
    ranges[1].dispatchEvent(new Event('input', { bubbles: true }))
    await waitFor(() => expect(canvasElement.textContent).toContain('#F6FF3F'))
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(ColorPickerGallery) }),
  parameters: {
    docs: {
      description: { story: 'Inline with the default palette, alpha, custom swatches, the popover row (set, unset, invalid), no swatches, disabled.' },
      story: { inline: false, height: '900px' },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-colorpicker').length).toBe(8))
    expect(canvasElement.querySelectorAll('.core-colorpicker--popover').length).toBe(3)
    expect(canvasElement.querySelectorAll('.core-colorpicker__range--alpha').length).toBe(1)
  },
}
