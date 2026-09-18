// Kit/Navigation/Menu — CoreMenu, the signature of the design: the active row is coral that
// dissolves to the right (DESIGN §37.5, Navigation).
//
// The title is `Kit/Navigation/Menu` and NOT `Built-ins/Menu`: the shell's keyboard menu
// (components/Menu.vue) is a different story with its own Lua contract. This one is the kit
// component a plugin page composes; the legacy `.core-list` markup it also styles is in the Gallery.
import { h } from 'vue'
import { within, expect, waitFor, userEvent } from 'storybook/test'
import CoreMenu from '../../kit/components/CoreMenu.vue'
import MenuGallery from './scenes/MenuGallery.vue'

const ITEMS = [
  { value: 'continue', label: 'Continue', icon: 'play' },
  { value: 'load', label: 'Load Game', icon: 'folder' },
  { value: 'settings', label: 'Settings', icon: 'settings' },
  { value: 'exit', label: 'Exit', icon: 'exit', danger: true },
]

export default {
  title: 'Kit/Navigation/Menu',
  component: CoreMenu,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The main menu, a category sidebar and a keyboard menu in one component. `v-model` is '
          + 'the ACTIVE row — ↑/↓ only move it (skipping disabled rows) and `select` fires separately on '
          + 'Enter, Space or a click, which is what lets a menu highlight a row while the player is still '
          + 'deciding. `selectOnHover` gives the main-menu feel; `fade` (on by default) is the dissolving '
          + 'coral gradient of the mockups, `:fade="false"` the solid one. Rows are square and full-bleed: '
          + 'the inset comes from the panel around it.',
      },
      story: { inline: false, height: '360px' },
    },
  },
  argTypes: {
    items: { control: 'object', description: '`[{ value, label, icon?, description?, trailing?, badge?, disabled?, danger? }]`.' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'], description: 'Row 38 / 56 / 70 px, label 15 / 18 / 25 px.' },
    fade: { control: 'boolean', description: 'Active row dissolves to the right instead of a solid gradient.' },
    selectOnHover: { control: 'boolean', description: 'Pointing at a row makes it active.' },
    loop: { control: 'boolean', description: '↑/↓ wrap around the ends.' },
  },
  args: { items: ITEMS, size: 'lg', fade: true, selectOnHover: false, loop: true },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '40px', maxWidth: '520px' } }, [
      h(CoreMenu, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Settings')).toBeInTheDocument())
    const rows = canvasElement.querySelectorAll('.core-menu__item')
    expect(rows[0].classList.contains('is-active')).toBe(true)
    // One tab stop, and it follows the active row.
    expect(canvasElement.querySelectorAll('.core-menu__item[tabindex="0"]').length).toBe(1)
    rows[0].focus()
    await userEvent.keyboard('{ArrowDown}')
    expect(rows[1].classList.contains('is-active')).toBe(true)
    await userEvent.keyboard('{End}')
    expect(rows[3].classList.contains('is-active')).toBe(true)
    expect(rows[3].classList.contains('is-danger')).toBe(true)
    await userEvent.click(rows[2])
    expect(rows[2].classList.contains('is-active')).toBe(true)
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(MenuGallery) }),
  parameters: { docs: { story: { inline: false, height: '1700px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreMenu')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-menu').length).toBeGreaterThan(3)
    expect(canvasElement.querySelector('.core-menu--lg')).not.toBeNull()
    expect(canvasElement.querySelector('.core-menu__item.is-danger')).not.toBeNull()
    // The legacy markup the shell still renders is styled by the same partial.
    expect(canvasElement.querySelector('ul.core-list .core-item.is-active')).not.toBeNull()
  },
}
