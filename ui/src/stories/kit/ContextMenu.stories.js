// Kit/Feedback ContextMenu — CoreContextMenu (DESIGN §37.5, Feedback).
import { h, ref } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreContextMenu from '../../kit/components/CoreContextMenu.vue'
import ContextMenuGallery from './scenes/ContextMenuGallery.vue'

const ITEMS = [
  { value: 'use', label: 'Use', icon: 'medkit', kbd: 'E' },
  { value: 'equip', label: 'Equip', icon: 'hand', kbd: 'F' },
  { separator: true },
  { value: 'split', label: 'Split stack', icon: 'copy' },
  { value: 'give', label: 'Give to…', icon: 'users', disabled: true },
  { separator: true },
  { value: 'drop', label: 'Drop', icon: 'trash', kbd: 'DEL', danger: true },
]

export default {
  title: 'Kit/Feedback/Context Menu',
  component: CoreContextMenu,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The right-click menu: rows in the display voice over the same popup shell as the select '
          + 'list. It has no anchor ELEMENT, so it is placed with the kit\'s `placeFloating()` against a '
          + 'zero-size rect at `position` — which is what flips it upwards and pulls it back inside the '
          + 'viewport when it is summoned in a corner. The panel takes focus on open so ↑/↓ reach it however '
          + 'the menu was raised; separators navigate like disabled rows and are skipped. A click outside, '
          + 'Escape, a scroll, a resize or the window losing focus all close it.',
      },
      story: { inline: false, height: '380px' },
    },
  },
  argTypes: {
    open: { control: 'boolean' },
    items: { control: 'object', description: '`{ value, label, icon?, kbd?, danger?, disabled?, separator? }`' },
  },
  args: { open: true, items: ITEMS },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const open = ref(true)
      const picked = ref('—')
      return () => h('div', {
        class: 'pointer-events-auto',
        style: { padding: '40px', minHeight: '340px' },
        onContextmenu: (e) => { e.preventDefault(); open.value = true },
      }, [
        h('p', { class: 'core-label' }, 'right-click anywhere — last pick: ' + picked.value),
        h(CoreContextMenu, {
          ...args,
          open: args.open && open.value,
          position: { x: 160, y: 200 },
          'onUpdate:open': (v) => { open.value = v },
          onSelect: (item) => { picked.value = item.label },
        }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(document.querySelector('.core-contextmenu')).not.toBeNull())
    const menu = document.querySelector('.core-contextmenu')
    expect(menu.getAttribute('role')).toBe('menu')
    expect(menu.querySelectorAll('.core-contextmenu__item').length).toBe(5)
    expect(menu.querySelectorAll('.core-contextmenu__sep').length).toBe(2)
    expect(menu.querySelector('.is-danger')).not.toBeNull()
    expect(menu.querySelector('.core-contextmenu__kbd').textContent).toBe('E')
    expect(canvasElement).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(ContextMenuGallery) }),
  parameters: { docs: { story: { inline: false, height: '780px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Context menu')).toBeInTheDocument())
    const slot = canvasElement.querySelectorAll('.core-kitsection button')[0]
    slot.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 200, clientY: 240 }))
    await waitFor(() => expect(document.querySelector('.core-contextmenu')).not.toBeNull())
  },
}
