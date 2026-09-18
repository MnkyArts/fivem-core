// Kit/Game/List — CoreList and CoreListItem (DESIGN §37.5, Game).
// One file: a list is only ever a stack of its own rows, and the roving arrows, `v-model` and the
// divider rules live in the list while the look lives in the row.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreListItem from '../../kit/components/CoreListItem.vue'
import ListGallery from './scenes/ListGallery.vue'
import quest1 from './assets/quest-1.jpg'

export default {
  title: 'Kit/Game/List & List Item',
  component: CoreListItem,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The quest rows of mockup 4 — a log, a contract board, a garage. The list root class '
          + 'is `core-listview`, NEVER `core-list`: that legacy name belongs to the old menu `<ul>` in '
          + 'css/navigation.css. A row is the one place in the kit where the display voice is not '
          + 'uppercased. For a plain text menu use CoreMenu; for columns of values, CoreTable.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    title: { control: 'text', description: 'Display 700, 19 px, Title Case.' },
    subtitle: { control: 'text', description: 'Sans 14 px, fg-dim.' },
    trailing: { control: 'text', description: 'Bottom-right value: a distance, a price, a timer.' },
    icon: { control: 'text', description: 'Registry name or raw path, 26 px.' },
    iconTone: {
      control: 'select',
      options: ['accent', 'neutral', 'success', 'warning', 'danger', 'info'],
      description: 'Colour of that glyph.',
    },
    selected: { control: 'boolean' },
    completed: { control: 'boolean' },
    disabled: { control: 'boolean' },
    interactive: { control: 'boolean', description: 'false renders a <div>: no hover, no focus.' },
  },
  args: {
    image: quest1,
    icon: 'quest',
    iconTone: 'accent',
    title: 'A Brighter Tomorrow',
    subtitle: 'Main Story',
    trailing: '842 m',
    selected: true,
    completed: false,
    disabled: false,
    interactive: true,
  },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', maxWidth: '760px' } }, [
      h(CoreListItem, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-listitem')).not.toBeNull())
    const row = canvasElement.querySelector('.core-listitem')
    expect(row.tagName).toBe('BUTTON')
    expect(row.classList.contains('is-selected')).toBe(true)
    expect(canvasElement.querySelector('.core-listitem__title').textContent.trim()).toBe('A Brighter Tomorrow')
    expect(canvasElement.querySelector('.core-listitem__trailing').textContent.trim()).toBe('842 m')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(ListGallery) }),
  parameters: {
    docs: {
      description: { story: 'The mockup quest log, the same list with `dividers`, a contract board with a locked row, and single rows in every state.' },
      story: { inline: false, height: '1500px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    // A unique string: the quest title appears in both the card list and the divider list.
    await waitFor(() => expect(canvas.getByText('Night Haul to Paleto')).toBeInTheDocument())
    const list = canvasElement.querySelector('.core-listview')
    expect(list.querySelectorAll('.core-listitem').length).toBe(4)
    expect(list.querySelectorAll('.core-listitem[tabindex="0"]').length).toBe(1)
    expect(canvasElement.querySelector('.core-listview--dividers')).not.toBeNull()
    expect(canvasElement.querySelector('.core-listitem.is-completed')).not.toBeNull()
  },
}
