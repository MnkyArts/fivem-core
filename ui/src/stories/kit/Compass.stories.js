// Kit/Game/Compass — CoreCompass (DESIGN §37.5, Game).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreCompass from '../../kit/components/CoreCompass.vue'
import CompassGallery from './scenes/CompassGallery.vue'

export default {
  title: 'Kit/Game/Compass',
  component: CoreCompass,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The heading band of mockup 2. One strip covering -180 to 540 degrees is built once — '
          + 'ticks every 15, cardinals every 45, every marker repeated a turn either side — and a single '
          + '`transform: translateX()` slides it under the coral triangle, so turning the camera costs one '
          + 'composited move and no allocation. Click-through, like every HUD element.',
      },
      story: { inline: false, height: '220px' },
    },
  },
  argTypes: {
    heading: { control: { type: 'range', min: 0, max: 359, step: 1 }, description: 'Where the player is looking, 0 = north.' },
    width: { control: { type: 'range', min: 240, max: 900, step: 20 }, description: 'Band width in px.' },
    fov: { control: { type: 'range', min: 60, max: 360, step: 10 }, description: 'Degrees shown end to end — pixels per degree = width / fov.' },
    showBearing: { control: 'boolean', description: 'Prints the numeric bearing under the band.' },
    labels: {
      control: 'inline-radio',
      options: ['all', 'cardinal'],
      description: "'all' labels every 45 degrees; 'cardinal' only N/E/S/W — what mockup 2 draws.",
    },
    markers: { control: 'object', description: '[{ heading, icon?, tone?, label? }]' },
  },
  args: {
    heading: 42,
    width: 560,
    fov: 270,
    showBearing: true,
    labels: 'all',
    markers: [{ heading: 42, icon: 'quest', tone: 'accent', label: 'Tower' }, { heading: 300, icon: 'store', tone: 'info' }],
  },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '64px 48px' } }, [
      h(CoreCompass, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-compass')).not.toBeNull())
    const compass = canvasElement.querySelector('.core-compass')
    expect(getComputedStyle(compass).pointerEvents).toBe('none')
    expect(compass.getAttribute('aria-label')).toBe('Heading 042')
    // 720 degrees of strip: a tick every 15 and a label every 45, both ends included.
    expect(compass.querySelectorAll('.core-compass__tick').length).toBe(49)
    expect(compass.querySelectorAll('.core-compass__label').length).toBe(17)
    // Two markers, each repeated a turn either side wherever that copy lands on the strip.
    expect(compass.querySelectorAll('.core-compass__marker').length).toBeGreaterThan(2)
    expect(compass.querySelector('.core-compass__needle')).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(CompassGallery) }),
  parameters: {
    docs: {
      description: { story: 'The mockup band with a live heading slider, markers, the width / fov relationship and three fixed headings.' },
      story: { inline: false, height: '1200px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Compass')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-compass').length).toBe(11)
    expect(canvasElement.querySelector('.core-compass__bearing')).not.toBeNull()
  },
}
