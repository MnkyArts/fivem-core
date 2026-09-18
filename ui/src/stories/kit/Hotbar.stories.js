// Kit/Game/Hotbar — CoreHotbar (DESIGN §37.5, Game).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreHotbar from '../../kit/components/CoreHotbar.vue'
import HotbarGallery from './scenes/HotbarGallery.vue'
import pistol from './assets/item-pistol.jpg'
import medkit from './assets/item-medkit.jpg'
import water from './assets/item-water.jpg'
import binoculars from './assets/item-binoculars.jpg'

const belt = [
  { id: 'pistol', image: pistol, count: 12, label: 'Combat Pistol' },
  { id: 'medkit', image: medkit, count: 4, label: 'Med Kit' },
  { id: 'water', image: water, count: 6, label: 'Bottled Water' },
  { id: 'binoculars', image: binoculars, count: 1, label: 'Field Binoculars' },
]

export default {
  title: 'Kit/Game/Hotbar',
  component: CoreHotbar,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The belt of mockup 2: CoreSlot cells in the 5 / 4 landscape ratio, each with a solid '
          + 'key cap. It sits on the bare game, so its cells bring their own translucent panel fill '
          + 'instead of the `panel-raise` that only works on top of a panel. `active` is an INDEX — the '
          + 'number key the player pressed — not an item id; for a bag, use CoreSlotGrid.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    active: { control: { type: 'range', min: -1, max: 3, step: 1 }, description: 'Index of the drawn cell; -1 = holstered.' },
    slotWidth: { control: { type: 'range', min: 56, max: 160, step: 4 }, description: 'Cell width in px.' },
    ratio: { control: 'text', description: "`aspect-ratio` of a cell — '5 / 4' in the mockup." },
    keys: { control: 'object', description: 'Key cap labels. Null = 1…n.' },
  },
  args: { items: belt, active: 0, slotWidth: 96, ratio: '5 / 4', keys: null },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreHotbar, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-hotbar')).not.toBeNull())
    const slots = canvasElement.querySelectorAll('.core-hotbar .core-slot')
    expect(slots.length).toBe(4)
    expect(slots[0].classList.contains('is-selected')).toBe(true)
    // The caps default to 1…n when no item carries its own `hotkey`.
    expect(slots[3].querySelector('.core-slot__hotkey').textContent.trim()).toBe('4')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(HotbarGallery) }),
  parameters: {
    docs: {
      description: { story: 'The mockup belt, a clickable one, a full belt with rarity / wear / a locked and two free cells, and the size range.' },
      story: { inline: false, height: '1100px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Hotbar')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-hotbar').length).toBeGreaterThan(3)
    expect(canvasElement.querySelector('.core-hotbar .core-slot.is-empty')).not.toBeNull()
  },
}
