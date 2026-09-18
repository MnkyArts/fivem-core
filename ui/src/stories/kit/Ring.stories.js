// Kit/Data/Ring — CoreRing, radial progress (DESIGN §37.5, Data — meters).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreRing from '../../kit/components/CoreRing.vue'
import { METER_TONES } from '../../kit/use.js'
import RingGallery from './scenes/RingGallery.vue'

export default {
  title: 'Kit/Data/Ring',
  component: CoreRing,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Progress where a bar does not fit: a hotbar cooldown, a timer over a world marker, a '
          + 'compact stat in a panel header. One SVG circle with `stroke-dasharray` and a shrinking '
          + '`stroke-dashoffset`, butt caps, and an arc that starts at 12 o\'clock — through the SVG '
          + '`transform` attribute, never a CSS transform (Chromium 103 drops the individual transform '
          + 'properties a utility would emit). The centre is a slot: the value in the display voice by '
          + 'default, a glyph with `icon`, anything else through the slot.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    value: { control: { type: 'range', min: 0, max: 100, step: 1 } },
    max: { control: 'number' },
    size: { control: { type: 'range', min: 20, max: 160, step: 2 }, description: 'Outer diameter in px.' },
    thickness: { control: { type: 'range', min: 1, max: 16, step: 1 }, description: 'Stroke of the well and the arc.' },
    tone: { control: 'select', options: METER_TONES },
    color: { control: 'text', description: 'Any CSS colour — wins over the tone.' },
    icon: { control: 'text', description: 'Registry name or raw path, drawn instead of the value.' },
  },
  args: { value: 72, max: 100, size: 96, thickness: 6, tone: 'accent', color: '', icon: '' },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreRing, { ...args }),
    ]),
  }),
  parameters: {
    docs: {
      description: {
        story: 'Set `icon: heart` and `tone: health` for the compact vital, or drop the value to 0 to '
          + 'see the well on its own.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-ring')).not.toBeNull())
    const root = canvasElement.querySelector('.core-ring')
    expect(root.getAttribute('role')).toBe('progressbar')
    expect(root.getAttribute('aria-valuenow')).toBe('72')
    expect(root.classList.contains('core-tone-accent')).toBe(true)
    const arc = root.querySelector('.core-ring__fill')
    // 96 px across a 6 px stroke -> r 45, C 282.7; 72 % leaves 28 % of it as the offset.
    const circumference = Number(arc.getAttribute('stroke-dasharray'))
    expect(Math.round(circumference)).toBe(283)
    expect(Math.round(Number(arc.getAttribute('stroke-dashoffset')))).toBe(79)
    expect(arc.getAttribute('transform')).toBe('rotate(-90 48 48)')
    expect(root.querySelector('.core-ring__value').textContent).toBe('72')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(RingGallery) }),
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: { story: 'Sizes, tones, the vitals with a glyph in the centre, 0 to 100, every thickness, and the centre slot.' },
      story: { inline: false, height: '900px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreRing')).toBeInTheDocument())
    const rings = canvasElement.querySelectorAll('.core-ring')
    expect(rings.length).toBeGreaterThan(20)
    // A full ring closes the circle: no offset left at all.
    const done = [...rings].filter((el) => el.getAttribute('aria-valuenow') === '100')
    expect(done.length).toBeGreaterThan(0)
    expect(Math.round(Number(done[0].querySelector('.core-ring__fill').getAttribute('stroke-dashoffset')))).toBe(0)
    expect(canvasElement.querySelector('.core-ring .core-icon')).not.toBeNull()
  },
}
