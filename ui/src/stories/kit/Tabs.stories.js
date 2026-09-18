// Kit/Navigation/Tabs — CoreTabs, the screen switcher of the inventory and map mockups
// (DESIGN §37.5, Navigation).
import { h } from 'vue'
import { within, expect, waitFor, userEvent } from 'storybook/test'
import CoreTabs from '../../kit/components/CoreTabs.vue'
import TabsGallery from './scenes/TabsGallery.vue'

const SCREENS = ['Map', 'Inventory', 'Character', 'Skills', 'Journal']

export default {
  title: 'Kit/Navigation/Tabs',
  component: CoreTabs,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Top navigation: dim condensed caps, the active one white over a glowing coral '
          + 'underline that sits on the hairline. `v-model` is the selected value — bind it, or leave it '
          + 'off and the component keeps the value itself (starting on the first enabled tab). The row is '
          + 'ONE tab stop: ←/→ and Home/End move the selection and the focus together. Use it for the '
          + 'screens of a page; for a filter row inside a screen use CoreChips instead.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    items: { control: 'object', description: '`[{ value, label, icon?, badge?, disabled? }]`, or plain strings.' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'], description: 'Label 14 / 17 / 20 px.' },
    separators: { control: 'boolean', description: 'Hairline in the middle of every gap (the map header).' },
    stretch: { control: 'boolean', description: 'Tabs share the full width.' },
    line: { control: 'boolean', description: 'The hairline under the row that the underline rides on.' },
    prevKey: { control: 'text', description: 'Key cap before the row; clicking it selects the previous tab.' },
    nextKey: { control: 'text', description: 'Key cap after the row.' },
  },
  args: {
    items: SCREENS,
    size: 'md',
    separators: false,
    stretch: false,
    line: true,
    prevKey: '',
    nextKey: '',
  },
}

export const Playground = {
  // No `modelValue` on purpose: `defineModel` keeps the value locally, so the controls stay the
  // only state and clicking a tab still works. Args are spread INSIDE the render function — the
  // vue3 renderer mutates one reactive args proxy instead of remounting (see ../storeHelpers.js).
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '56px 48px' } }, [
      h(CoreTabs, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Character')).toBeInTheDocument())
    const tabs = canvasElement.querySelectorAll('.core-tab')
    // First enabled tab is active until something says otherwise.
    expect(tabs[0].classList.contains('is-active')).toBe(true)
    await userEvent.click(tabs[2])
    expect(tabs[2].classList.contains('is-active')).toBe(true)
    expect(tabs[2].getAttribute('aria-selected')).toBe('true')
    // Roving tabindex: exactly one tab stop in the row.
    expect(canvasElement.querySelectorAll('.core-tab[tabindex="0"]').length).toBe(1)
    await userEvent.keyboard('{ArrowRight}')
    expect(tabs[3].classList.contains('is-active')).toBe(true)
    await userEvent.keyboard('{Home}')
    expect(tabs[0].classList.contains('is-active')).toBe(true)
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(TabsGallery) }),
  parameters: { docs: { story: { inline: false, height: '1500px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreTabs')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-tabs').length).toBeGreaterThan(6)
    expect(canvasElement.querySelector('.core-tabs--separators')).not.toBeNull()
    expect(canvasElement.querySelector('.core-tab:disabled')).not.toBeNull()
  },
}
