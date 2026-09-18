// Kit/Actions IconButton — CoreIconButton (DESIGN §37.5, Actions).
import { h } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import CoreIconButton from '../../kit/components/CoreIconButton.vue'
import { ICONS } from '../../kit/icons.js'
import IconButtonGallery from './scenes/IconButtonGallery.vue'

const NAMES = Object.keys(ICONS).sort()

export default {
  title: 'Kit/Actions/Icon Button',
  component: CoreIconButton,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A square CoreButton for a glyph alone — a panel header\'s close and sort actions, a '
          + 'map toolbar, a row\'s overflow menu. It wears the same fills and the same focus ring as '
          + 'CoreButton, so the two never drift apart. `label` is not decoration: it is the button\'s only '
          + 'accessible name and its native tooltip, so a caller always passes it.',
      },
      story: { inline: false, height: '200px' },
    },
  },
  argTypes: {
    icon: { control: 'select', options: NAMES },
    variant: { control: 'inline-radio', options: ['secondary', 'ghost', 'primary', 'danger', 'success'] },
    fade: { control: 'boolean', description: 'Primary only: the fading accent gradient.' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    round: { control: 'boolean', description: 'Circular instead of the 4 px radius.' },
    active: { control: 'boolean', description: 'Toggle-on.' },
    disabled: { control: 'boolean' },
    label: { control: 'text', description: 'aria-label and title.' },
  },
  args: { icon: 'filter', variant: 'secondary', fade: false, size: 'md', round: false, active: false, disabled: false, label: 'Filter markers' },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreIconButton, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-iconbtn')).not.toBeNull())
    const button = canvasElement.querySelector('.core-iconbtn')
    const box = button.getBoundingClientRect()
    expect(Math.round(box.width)).toBe(Math.round(box.height))
    expect(button.getAttribute('aria-label')).toBe('Filter markers')
    expect(button.querySelector('svg.core-icon')).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(IconButtonGallery) }),
  parameters: {
    docs: {
      story: { inline: false, height: '900px' },
      description: { story: 'Variants, sizes, `round`, the toggle state, disabled, and the two places it appears.' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreIconButton')).toBeInTheDocument())

    // The toggle really toggles, and a disabled one never reacts.
    const toggle = canvasElement.querySelector('.core-iconbtn.is-active')
    expect(toggle).not.toBeNull()
    await userEvent.click(toggle)
    await waitFor(() => expect(toggle.className).not.toContain('is-active'))
    const dead = canvasElement.querySelector('.core-iconbtn[disabled]')
    expect(dead).not.toBeNull()
    expect(getComputedStyle(dead).cursor).toBe('not-allowed')
  },
}
