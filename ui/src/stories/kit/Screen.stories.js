// Kit/Surfaces Screen — CoreScreen, the full-page scaffold of mockups 3 and 4 (DESIGN §37.5).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreScreen from '../../kit/components/CoreScreen.vue'
import CorePanel from '../../kit/components/CorePanel.vue'
import CoreBrand from '../../kit/components/CoreBrand.vue'
import CoreTagline from '../../kit/components/CoreTagline.vue'
import CoreDash from '../../kit/components/CoreDash.vue'
import ScreenGallery from './scenes/ScreenGallery.vue'
import keyart from './assets/keyart.jpg'

// CoreScreen fills the page layer, so the Playground gives it a relative box of a known size.
const FRAME = {
  position: 'relative',
  margin: '40px',
  height: '540px',
  overflow: 'hidden',
  borderRadius: 'var(--radius-ui)',
  border: '1px solid var(--color-border)',
}

export default {
  title: 'Kit/Surfaces/Screen',
  component: CoreScreen,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A CoreBackground at z 0 with header / body / footer above it. The header is 76 px with '
          + 'brand, nav and status; the body takes the rest; the footer is 64 px over 90 % ink. Both bars are '
          + 'rendered only when one of their slots is filled, so `<CoreScreen>` with nothing but a body is a '
          + 'scrim and a padded column. The `background` slot replaces the whole background — that is how a '
          + 'page swaps in a live map or a video without losing the frame.',
      },
      story: { inline: false, height: '640px' },
    },
  },
  argTypes: {
    background: {
      control: 'select',
      options: ['scrim', 'left', 'right', 'top', 'bottom', 'bars', 'vignette', 'solid', 'none'],
    },
    dim: { control: { type: 'range', min: 0, max: 1, step: 0.05 } },
    padded: { control: 'boolean' },
    navAlign: {
      control: 'inline-radio',
      options: ['space', 'center', 'start'],
      description: 'space shares the leftover room · center pins the nav to the middle of the SCREEN · start hangs it off the brand.',
    },
    blur: { control: 'boolean' },
  },
  args: { background: 'scrim', dim: 0.7, padded: true, navAlign: 'space', blur: false },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: FRAME }, [
      h(CoreScreen, { ...args, image: keyart }, {
        brand: () => h(CoreBrand, { size: 'sm', name: 'Wayfinder' }),
        status: () => h(CoreTagline, { rule: 'accent', lines: ['Worlds', 'Are better', 'With stories.'] }),
        default: () => h(CorePanel, { title: 'Inventory', subtitle: "Gear up for what's next.", padding: 'lg' }, {
          default: () => h('p', { class: 'core-text' }, 'Body placeholder.'),
        }),
        'footer-start': () => h('span', { class: 'core-label', style: { color: 'var(--color-fg)' } }, 'Wayfinder'),
        'footer-end': () => [
          h('span', { class: 'core-label' }, 'Built for worlds yet to be explored.'),
          h(CoreDash, { width: 34 }),
        ],
      }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-screen')).not.toBeNull())
    const screen = canvasElement.querySelector('.core-screen')
    expect(screen.querySelector('.core-screen__header')).not.toBeNull()
    expect(screen.querySelector('.core-screen__footer')).not.toBeNull()
    expect(screen.querySelector('.core-bg')).not.toBeNull()
    expect(getComputedStyle(screen.querySelector('.core-screen__header')).height).toBe('76px')
  },
}

export const BodyOnly = {
  name: 'Body only',
  args: { background: 'vignette', dim: 0.8 },
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: FRAME }, [
      h(CoreScreen, { ...args, image: keyart }, {
        default: () => h(CorePanel, { title: 'Confirm', subtitle: 'No header, no footer' }, {
          default: () => h('p', { class: 'core-text' }, 'Nothing filled a header or footer slot, so neither bar exists.'),
        }),
      }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-screen')).not.toBeNull())
    expect(canvasElement.querySelector('.core-screen__header')).toBeNull()
    expect(canvasElement.querySelector('.core-screen__footer')).toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(ScreenGallery) }),
  parameters: {
    docs: {
      description: { story: 'The inventory frame of mockup 3 rebuilt with placeholders, plus the bar-less shapes.' },
      story: { inline: false, height: '1400px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreScreen')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-screen').length).toBe(3)
    expect(canvasElement.querySelectorAll('.core-screen__header').length).toBe(2)
  },
}
