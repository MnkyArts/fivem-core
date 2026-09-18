// Kit/Data — CoreKeyValue (DESIGN §37.5, Data — display).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreKeyValue from '../../kit/components/CoreKeyValue.vue'
import KeyValueGallery from './scenes/KeyValueGallery.vue'

const ITEMS = [
  { label: 'Rarity', value: 'Common', icon: 'diamond-outline' },
  { label: 'Type', value: 'Consumable', icon: 'medkit' },
  { label: 'In inventory', value: '3 / 10' },
  { label: 'Weight', value: '0.8 kg', icon: 'weight' },
  { label: 'Sell value', value: '$ 240', icon: 'cash', tone: 'success' },
]

export default {
  title: 'Kit/Data/Key Value',
  component: CoreKeyValue,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Facts, ruled. The label wears the *label voice* and the value the *display voice* '
          + '— the pairing mockup 3 uses for "3 / 10 · IN INVENTORY". `columns` only reflows the same '
          + '`items` array into a grid, so one detail panel and one wide profile header share a single '
          + 'source of truth. An item\'s `tone` paints its value and its glyph, which is how a red '
          + 'WANTED sits next to a green payout without a wrapper. For one big hero number use '
          + 'CoreStatRow instead; this is the compact spec block under it.',
      },
    },
  },
  argTypes: {
    columns: { control: { type: 'range', min: 1, max: 4, step: 1 } },
    items: { control: false },
  },
  args: { columns: 1 },
}

export const Playground = {
  // Args are spread inside the render function — that is what keeps the controls live.
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', maxWidth: '900px' } }, [
      h(CoreKeyValue, { ...args, items: ITEMS }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('3 / 10')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-kv__item').length).toBe(5)
    // The toned item paints its value through --tone, not through a colour of its own.
    expect(canvasElement.querySelector('.core-kv__item.is-toned.core-tone-success')).not.toBeNull()
  },
}

export const Columns = {
  name: 'Playground — two columns',
  args: { columns: 2 },
  render: Playground.render,
  parameters: {
    docs: { description: { story: 'The same rows, flowing left to right — every hairline still lines up across the grid.' } },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-kv')).not.toBeNull())
    expect(getComputedStyle(canvasElement.querySelector('.core-kv')).gridTemplateColumns.split(' ').length).toBe(2)
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(KeyValueGallery) }),
  parameters: {
    docs: {
      description: { story: 'One, two and four columns, the tone rules, the `value-<i>` slot, and the whole thing inside the panel it will really live in.' },
      story: { inline: false, height: '1300px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreKeyValue')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-kv').length).toBe(5)
    expect(canvasElement.querySelectorAll('.core-kv__item.is-toned').length).toBeGreaterThan(4)
  },
}
