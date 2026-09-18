// Kit/Data/StatBar — CoreStatBar, the HUD vital of mockup 2 (DESIGN §37.5, Data — meters).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreStatBar from '../../kit/components/CoreStatBar.vue'
import { METER_TONES } from '../../kit/use.js'
import StatBarGallery from './scenes/StatBarGallery.vue'

const PLATE = {
  display: 'inline-flex',
  flexDirection: 'column',
  gap: '9px',
  padding: '12px 16px',
  borderRadius: 'var(--radius-ui-sm)',
  background: 'rgba(6, 11, 15, 0.55)',
}

export default {
  title: 'Kit/Data/Stat Bar',
  component: CoreStatBar,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'One HUD vital: a glyph in the vital\'s colour, a chunky flat bar in a dark well, a big '
          + 'condensed number. It is a read-out on top of the game, so the row is click-through — and the '
          + 'number is left-aligned with a floor width, because a plate that resizes when health drops from '
          + '100 to 75 is worse than no plate at all. Under `lowBelow` the GLYPH pulses; the bar itself never '
          + 'moves. The plate around a stack of these belongs to the page, not to the kit — use CoreProgress '
          + 'for a labelled meter inside a panel.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    icon: { control: 'text', description: 'Registry name or raw path, drawn in the tone.' },
    value: { control: { type: 'range', min: 0, max: 100, step: 1 } },
    max: { control: 'number' },
    tone: { control: 'select', options: METER_TONES },
    iconTone: { control: 'inline-radio', options: ['tone', 'fg'], description: 'Glyph in the vital\'s colour, or white with the colour left in the bar.' },
    width: { control: { type: 'range', min: 80, max: 400, step: 10 }, description: 'The BAR width in px.' },
    showValue: { control: 'boolean' },
    lowBelow: { control: { type: 'range', min: 0, max: 100, step: 1 }, description: '0 switches the pulse off.' },
  },
  args: { icon: 'heart', value: 75, max: 100, tone: 'health', iconTone: 'tone', width: 220, showValue: true, lowBelow: 25 },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h('div', { style: PLATE }, [h(CoreStatBar, { ...args })]),
    ]),
  }),
  parameters: {
    docs: {
      description: {
        story: 'The box is the mockup\'s plate (ink 55 %, radius 4, padding 12 16) — plain markup, so a '
          + 'page can stack as many rows in it as its HUD needs. Drag the value under 25 to see the glyph pulse.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-statbar')).not.toBeNull())
    const root = canvasElement.querySelector('.core-statbar')
    expect(root.classList.contains('core-tone-health')).toBe(true)
    expect(root.classList.contains('is-low')).toBe(false)
    expect(getComputedStyle(root).pointerEvents).toBe('none')
    const track = root.querySelector('.core-statbar__track')
    expect(track.getAttribute('role')).toBe('progressbar')
    expect(track.style.width).toBe('220px')
    expect(parseFloat(root.querySelector('.core-statbar__fill').style.width)).toBe(75)
    expect(root.querySelector('.core-statbar__value').textContent).toBe('75')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(StatBarGallery) }),
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: { story: 'The three-bar plate of mockup 2, all seven vitals, the low warning, and what `width` / `max` / `showValue` do.' },
      story: { inline: false, height: '900px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreStatBar')).toBeInTheDocument())
    const bars = canvasElement.querySelectorAll('.core-statbar')
    expect(bars.length).toBeGreaterThan(15)
    // The mockup plate: 100 / 75 / 80, and a full bar really is full.
    expect(parseFloat(bars[0].querySelector('.core-statbar__fill').style.width)).toBe(100)
    expect(bars[0].querySelector('.core-statbar__value').textContent).toBe('100')
    // Low rows pulse their glyph, and `lowBelow: 0` opts out.
    const low = canvasElement.querySelectorAll('.core-statbar.is-low')
    expect(low.length).toBeGreaterThan(0)
    expect(getComputedStyle(low[0].querySelector('.core-statbar__icon')).animationName).toBe('core-pulse')
    // iconTone="fg": the colour stays in the bar, the glyph goes white.
    const white = canvasElement.querySelector('.core-statbar--icon-fg')
    expect(getComputedStyle(white.querySelector('.core-statbar__icon')).color).toBe('rgb(243, 245, 247)')
    expect(getComputedStyle(white.querySelector('.core-statbar__fill')).backgroundColor).toBe('rgb(93, 187, 247)')
  },
}
