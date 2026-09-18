// Kit/Game/Slot — CoreSlot and CoreSlotGrid (DESIGN §37.5, Game).
// Two components in one file because a slot is never shipped alone: the grid is what pads a bag
// to its capacity, roves the arrow keys in 2D and owns `v-model:selected`.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreSlot from '../../kit/components/CoreSlot.vue'
import SlotGallery from './scenes/SlotGallery.vue'
import medkit from './assets/item-medkit.jpg'

export default {
  title: 'Kit/Game/Slot & Grid',
  component: CoreSlot,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The item cell of mockup 3 — inventory, hotbar, loot box, shop. It is a `<button>` so '
          + 'it is reachable by keyboard on its own; `disabled` is announced with `aria-disabled` rather '
          + 'than the native attribute, because a dimmed cell must still be focusable for CoreSlotGrid\'s '
          + 'arrow keys to walk past it. Do NOT use it for a row with a label — that is CoreListItem.',
      },
      story: { inline: false, height: '360px' },
    },
  },
  argTypes: {
    count: { control: 'number', description: 'Stack size, bottom right. `null` hides it.' },
    hotkey: { control: 'text', description: 'Key cap top left — the hotbar\'s 1…4.' },
    badge: { control: 'text', description: 'Short text badge, top right.' },
    rarity: {
      control: 'inline-radio',
      options: ['', 'common', 'uncommon', 'rare', 'epic', 'legendary'],
      description: 'A 2 px line and a faint bloom along the bottom edge.',
    },
    durability: { control: { type: 'range', min: 0, max: 1, step: 0.01 }, description: '0–1. Green, amber under 50 %, red under 20 %.' },
    selected: { control: 'boolean' },
    disabled: { control: 'boolean' },
    empty: { control: 'boolean', description: 'Draws nothing inside and never hovers.' },
    size: { control: { type: 'range', min: 56, max: 200, step: 4 }, description: 'Cell width in px; unset fills the grid cell.' },
    ratio: { control: 'text', description: "`aspect-ratio` — '1 / 1' in a grid, '5 / 4' in the hotbar." },
    label: { control: 'text', description: 'Tooltip and accessible name.' },
  },
  args: {
    image: medkit,
    count: 3,
    hotkey: '',
    badge: '',
    rarity: '',
    durability: null,
    selected: true,
    disabled: false,
    empty: false,
    size: 140,
    ratio: '1 / 1',
    label: 'Med Kit',
  },
}

export const Playground = {
  // Args are read INSIDE the render function so the controls stay live (see ./README.md).
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreSlot, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-slot')).not.toBeNull())
    const slot = canvasElement.querySelector('.core-slot')
    expect(slot.tagName).toBe('BUTTON')
    expect(slot.getAttribute('type')).toBe('button')
    expect(slot.classList.contains('is-selected')).toBe(true)
    expect(canvasElement.querySelector('.core-slot__count').textContent.trim()).toBe('3')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(SlotGallery) }),
  parameters: {
    docs: {
      description: {
        story: 'The 4 x 3 bag of mockup 3 (click a cell, or Tab in and use the arrow keys), then every '
          + 'state, all five rarities, the durability thresholds, the glyph fallback and the size range.',
      },
      story: { inline: false, height: '1400px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Inventory')).toBeInTheDocument())
    const grid = canvasElement.querySelector('.core-slotgrid')
    // 7 items padded to the bag's 12 slots, and exactly one tab stop for the whole grid.
    expect(grid.querySelectorAll('.core-slot').length).toBe(12)
    expect(grid.querySelectorAll('.core-slot.is-empty').length).toBe(5)
    expect(grid.querySelectorAll('.core-slot[tabindex="0"]').length).toBe(1)
    expect(grid.querySelector('.core-slot.is-selected')).not.toBeNull()
  },
}
