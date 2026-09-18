// Kit/Forms/Swatches — CoreSwatches (DESIGN §37.5, Forms — choice).
//
// The paint picker of a garage or a character creator. Real buttons with `aria-pressed`, one tab
// stop for the whole group, ← / → roving and picking as they go.
import { h, ref } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreSwatches from '../../kit/components/CoreSwatches.vue'
import SwatchesGallery from './scenes/SwatchesGallery.vue'

const PAINT = [
  { value: 'black', color: '#0a0a0c', label: 'Carbon Black' },
  { value: 'silver', color: '#c7ccd2', label: 'Brushed Silver' },
  { value: 'carmine', color: '#8c1c13', label: 'Carmine' },
  { value: 'coral', color: '#f6503f', label: 'Sunset Coral' },
  { value: 'navy', color: '#1d3557', label: 'Midnight Navy' },
  { value: 'gold', color: '#d9a441', label: 'Bullion Gold' },
]

export default {
  title: 'Kit/Forms/Swatches',
  component: CoreSwatches,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A colour out of a fixed palette — vehicle paint, hair, a faction colour. Selection is '
          + 'the kit\'s selection language: a 2 px ink gap and a 2 px `accent-hi` ring, never a filled block, '
          + 'and every swatch keeps a 1 px light inset line so a near-black paint still has an edge against '
          + 'the panel. A free colour (a hex field, a wheel) is not this component.',
      },
      story: { inline: false, height: '200px' },
    },
  },
  argTypes: {
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    shape: { control: 'inline-radio', options: ['square', 'circle'] },
    columns: { control: { type: 'number', min: 0, max: 8 } },
    disabled: { control: 'boolean' },
  },
  args: { size: 'md', shape: 'square', columns: 0, disabled: false },
}

export const Playground = {
  render: (args) => ({
    setup() {
      const paint = ref('coral')
      return () => h('div', { style: { padding: '48px' } }, [
        h(CoreSwatches, {
          ...args,
          items: PAINT,
          modelValue: paint.value,
          'onUpdate:modelValue': (v) => { paint.value = v },
        }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const swatches = await waitFor(() => {
      const list = canvasElement.querySelectorAll('.core-swatch')
      expect(list.length).toBe(6)
      return list
    })
    expect(swatches[3].getAttribute('aria-pressed')).toBe('true')
    // Only the selected swatch is in the tab order; the others are roved onto.
    expect(swatches[0].getAttribute('tabindex')).toBe('-1')
    swatches[1].click()
    await waitFor(() => expect(swatches[1].className).toContain('is-selected'))
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(SwatchesGallery) }),
  parameters: {
    docs: {
      description: { story: 'Vehicle paint, plain-string items, every size and shape, a grid with a disabled swatch, a disabled group.' },
      story: { inline: false, height: '1200px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Sunset Coral')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-swatch').length).toBeGreaterThan(40)
    expect(canvasElement.querySelectorAll('.core-swatch.is-selected').length).toBeGreaterThan(4)
    expect(canvasElement.querySelector('.core-swatch:disabled')).not.toBeNull()
  },
}
