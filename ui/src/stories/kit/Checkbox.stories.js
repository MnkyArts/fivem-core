// Kit/Forms/Checkbox — CoreCheckbox (DESIGN §37.5, Forms — choice).
//
// The map mockup's MAP FILTERS row: a 22 px box with a bold white tick on the accent gradient, an
// optional glyph between the box and the label. The component is a thin coat of paint on a real
// <input type="checkbox">, so everything below is the browser's behaviour, not the kit's.
import { h, ref } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreCheckbox from '../../kit/components/CoreCheckbox.vue'
import CheckboxGallery from './scenes/CheckboxGallery.vue'

export default {
  title: 'Kit/Forms/Checkbox',
  component: CoreCheckbox,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A boolean, or one entry of an array. The root is a `<label>` around a real '
          + '`<input type="checkbox">` restyled with `appearance: none`, which is why the whole row is a '
          + 'click target, Space toggles it and `indeterminate` is a DOM property rather than a third '
          + 'model value. Use it for filters and settings; for one-of-several use CoreRadioGroup, and for '
          + 'an on/off that takes effect immediately use CoreSwitch.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    label: { control: 'text' },
    description: { control: 'text' },
    icon: { control: 'text', description: 'Registry name — the glyph between box and label.' },
    indeterminate: { control: 'boolean' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    disabled: { control: 'boolean' },
  },
  args: {
    label: 'Fast Travel',
    description: '',
    icon: 'camp',
    indeterminate: false,
    size: 'md',
    disabled: false,
  },
}

export const Playground = {
  render: (args) => ({
    setup() {
      const on = ref(true)
      // Args are read INSIDE the render function: the vue3 renderer mutates one reactive proxy.
      return () => h('div', { style: { padding: '48px' } }, [
        h(CoreCheckbox, {
          ...args,
          modelValue: on.value,
          'onUpdate:modelValue': (v) => { on.value = v },
        }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const box = await waitFor(() => {
      const el = canvasElement.querySelector('.core-check input[type="checkbox"]')
      expect(el).not.toBeNull()
      return el
    })
    expect(box.checked).toBe(true)
    box.click()
    await waitFor(() => expect(canvasElement.querySelector('.core-check').className).not.toContain('is-checked'))
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(CheckboxGallery) }),
  parameters: {
    docs: {
      description: { story: 'The MAP FILTERS block of the map mockup, the array model, every size and state, and the legacy `.core-check` markup.' },
      story: { inline: false, height: '1500px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Map filters')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-check').length).toBeGreaterThan(15)
    // The array model really drives the boxes: three of the six filters start checked.
    const filters = canvasElement.querySelectorAll('.core-check.is-checked')
    expect(filters.length).toBeGreaterThan(2)
    expect(canvasElement.querySelector('.core-check input:indeterminate')).not.toBeNull()
  },
}
