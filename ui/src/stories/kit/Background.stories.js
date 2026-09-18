// Kit/Surfaces Background — CoreBackground, the scrim between the game and a full screen (DESIGN §37.5).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreBackground from '../../kit/components/CoreBackground.vue'
import BackgroundGallery from './scenes/BackgroundGallery.vue'
import keyart from './assets/keyart.jpg'

const VARIANTS = ['scrim', 'left', 'right', 'top', 'bottom', 'bars', 'vignette', 'solid', 'none']

// The component is absolute/inset-0, so the Playground gives it a positioned box with the key art
// behind it — a scrim cannot be judged over an empty page.
const stage = (args) => h('div', {
  class: 'pointer-events-auto',
  style: {
    position: 'relative',
    margin: '40px',
    height: '420px',
    overflow: 'hidden',
    borderRadius: 'var(--radius-ui)',
    border: '1px solid var(--color-border)',
    backgroundImage: 'url(' + keyart + ')',
    backgroundSize: 'cover',
    backgroundPosition: 'center',
  },
}, [h(CoreBackground, { ...args })])

export default {
  title: 'Kit/Surfaces/Background',
  component: CoreBackground,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Absolute, inset 0, click-through, z 0. Every variant reads one number — the `dim` prop — '
          + 'so a whole page darkens with a single value, and the optional `image` layer sits UNDER the scrim '
          + 'for key art, a map or a blurred still. `left` is the main menu of mockup 1: all but opaque on the '
          + 'left third and gone by 62 % of the width. Only one background per page carries `blur` (§32.1).',
      },
      story: { inline: false, height: '520px' },
    },
  },
  argTypes: {
    variant: { control: 'select', options: VARIANTS },
    dim: { control: { type: 'range', min: 0, max: 1, step: 0.05 } },
    fade: {
      control: { type: 'range', min: 0.05, max: 1, step: 0.05 },
      description: 'How far top/bottom/left/right reach transparent, as a fraction of the box.',
    },
    pattern: { control: 'inline-radio', options: ['none', 'grid'] },
    image: { control: 'text' },
    position: { control: 'text', description: 'background-position of the image layer — "center 30%", "right center", …' },
    blur: { control: 'boolean' },
  },
  args: { variant: 'left', dim: 0.94, fade: 0.62, pattern: 'none', image: '', position: 'center', blur: false },
}

export const Playground = {
  render: (args) => ({ setup: () => () => stage({ ...args }) }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-bg')).not.toBeNull())
    const bg = canvasElement.querySelector('.core-bg')
    expect(bg.classList.contains('core-bg--left')).toBe(true)
    // Click-through, always: the scrim must never eat a click meant for the page above it.
    expect(getComputedStyle(bg).pointerEvents).toBe('none')
    expect(bg.querySelector('.core-bg__scrim')).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(BackgroundGallery) }),
  parameters: {
    docs: {
      description: { story: 'Every variant over the key art, the dim scale, the image and grid layers, and extra layers.' },
      story: { inline: false, height: '1500px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreBackground')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-bg').length).toBeGreaterThan(12)
    expect(canvasElement.querySelector('.core-bg__pattern')).not.toBeNull()
    expect(canvasElement.querySelector('.core-bg__image')).not.toBeNull()
    // `none` draws no scrim at all.
    expect(canvasElement.querySelector('.core-bg--none .core-bg__scrim')).toBeNull()
  },
}
