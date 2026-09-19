// Kit/Data/Vital — CoreVital, one plate of the vitals HUD (DESIGN §39).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreVital from '../../kit/components/CoreVital.vue'
import { METER_TONES } from '../../kit/use.js'
import VitalGallery from './scenes/VitalGallery.vue'

// The sub glyph hangs below the plate, so the story frame leaves it room.
const FRAME = { padding: '48px 48px 120px' }

export default {
  title: 'Kit/Data/Vital',
  component: CoreVital,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Liam\'s HUD mockup as ONE rounded parallelogram whose bottom slice is cut off and '
          + 'used as the food / drink bar. Everything is `em` over `--core-hud-unit` (1em = 100 px of the '
          + 'mockup; the shell runs it at a fixed 24 px, ~351 x 76 px for the whole strip), so one number '
          + 'scales the whole strip. The value never becomes a '
          + 'width: it is published as a 0..1 custom property and the white plate is clipped with '
          + '`clip-path: inset(...)` INSIDE the skewed shape, which is why the progress edge leans at the '
          + 'parallelogram\'s own 20°. Icon and label exist twice, pixel-identical — that is what splits '
          + 'the label into plate ink and track white along the clip edge. A change is never a jump: a '
          + 'second layer with the same clip target trails the fill on a loss (red, 0.65s behind a 0.3s '
          + 'fill) and leads it on a gain (green, 0.15s ahead of a 0.55s fill) — §39.3.1. Click-through, '
          + 'like every HUD read-out; the strip around it (gap, placement) belongs to the shell, not to '
          + 'the kit.',
      },
      story: { inline: false, height: '360px' },
    },
  },
  argTypes: {
    label: { control: 'text', description: 'Plate text (uppercased by the CSS) and the a11y name.' },
    icon: { control: 'text', description: 'Registry name or raw path — the plate glyph.' },
    tone: { control: 'select', options: METER_TONES, description: '`--tone` on the track, `--color-plate-<tone>` on the white fill (health, armour).' },
    value: { control: { type: 'range', min: 0, max: 100, step: 1 } },
    max: { control: 'number' },
    lowBelow: { control: { type: 'range', min: 0, max: 100, step: 1 }, description: '0 switches the glyph pulse off.' },
    subValue: { control: { type: 'range', min: 0, max: 100, step: 1 }, description: 'null drops the cut, the bar and the sub glyph (`--solo`).' },
    subMax: { control: 'number' },
    subIcon: { control: 'text', description: 'The glyph under the bar.' },
    subLabel: { control: 'text', description: 'The a11y name of the bar — the plate label says nothing about it.' },
    subWarnBelow: { control: { type: 'range', min: 0, max: 100, step: 1 } },
    subDangerBelow: { control: { type: 'range', min: 0, max: 100, step: 1 } },
    unit: { control: 'text', description: '`--core-hud-unit`: a number is px, a string is any CSS length. '
      + 'Empty = inherit (the kit default is 24px, what the shell runs at; `Config.Hud.Scale = 2` is 48px).' },
  },
  args: {
    label: 'Health',
    icon: 'hud-heart',
    tone: 'health',
    value: 81,
    max: 100,
    lowBelow: 25,
    subValue: 80,
    subMax: 100,
    subIcon: 'hud-food',
    subLabel: 'Hunger',
    subWarnBelow: 25,
    subDangerBelow: 10,
    unit: '100px',
  },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: FRAME }, [h(CoreVital, { ...args })]),
  }),
  parameters: {
    docs: {
      description: {
        story: 'At `unit: 100px` the plate is exactly mockup-sized. Drag `value` and watch the label '
          + 'split along the clip edge; drag `subValue` under 25 and then under 10 for the two bar states. '
          + 'The change effect of §39.3.1 needs no control of its own: every move of the `value` slider '
          + 'already drives it (drag DOWN for the red chunk, UP for the green one) — it is a watcher on '
          + 'the percentage, so whatever moves the plate moves the chunk. The Gallery below has a row '
          + 'that cycles by itself if you would rather just watch it.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-vital')).not.toBeNull())
    const root = canvasElement.querySelector('.core-vital')
    expect(root.classList.contains('core-tone-health')).toBe(true)
    expect(root.classList.contains('core-vital--solo')).toBe(false)
    expect(root.getAttribute('role')).toBe('progressbar')
    expect(root.getAttribute('aria-valuenow')).toBe('81')
    expect(root.style.getPropertyValue('--core-vital-value').trim()).toBe('0.81')
    expect(root.style.getPropertyValue('--core-hud-unit').trim()).toBe('100px')
    expect(getComputedStyle(root).pointerEvents).toBe('none')
    expect(getComputedStyle(root).fontSize).toBe('100px')
    // The content is drawn twice — once on the track, once inside the clipped fill.
    expect(canvasElement.querySelectorAll('.core-vital__content').length).toBe(2)
    expect(root.querySelector('.core-vital__fill').getAttribute('aria-hidden')).toBe('true')
    expect(getComputedStyle(root.querySelector('.core-vital__fill')).clipPath).toContain('inset(')
    const bar = root.querySelector('.core-vital__bar')
    expect(bar.getAttribute('role')).toBe('progressbar')
    expect(bar.getAttribute('aria-label')).toBe('Hunger')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(VitalGallery) }),
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: { story: 'The whole strip at mockup size and at the 24 px it really runs at, the self-driving '
        + '"Loss and gain" row of §39.3.1 (one step every 1.4s, at both sizes), the two bar thresholds, the low '
        + 'pulse, a `--solo` plate, the tones and what `unit` does.' },
      story: { inline: false, height: '1500px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreVital')).toBeInTheDocument())
    const vitals = canvasElement.querySelectorAll('.core-vital')
    expect(vitals.length).toBeGreaterThan(12)
    // The mockup row: a full plate really is full, and the tile opens the strip.
    expect(vitals[0].style.getPropertyValue('--core-vital-value').trim()).toBe('1')
    expect(canvasElement.querySelector('.core-hudtile')).not.toBeNull()
    // §39.3.1: every plate carries the chunk layer, and a plate that is not changing right now
    // shows it as fully transparent (two edges on one line would otherwise fringe the fill).
    const restChunk = vitals[0].querySelector('.core-vital__chunk')
    expect(restChunk).not.toBeNull()
    expect(vitals[0].querySelector('.core-vital__subchunk')).not.toBeNull()
    expect(getComputedStyle(restChunk).backgroundColor).toBe('rgba(0, 0, 0, 0)')
    expect(vitals[0].classList.contains('is-loss')).toBe(false)
    expect(vitals[0].classList.contains('is-gain')).toBe(false)
    // Both bar thresholds are on the page, and only one class at a time.
    const warn = canvasElement.querySelector('.core-vital.is-sub-warning')
    const danger = canvasElement.querySelector('.core-vital.is-sub-danger')
    expect(warn).not.toBeNull()
    expect(danger).not.toBeNull()
    expect(danger.classList.contains('is-sub-warning')).toBe(false)
    expect(getComputedStyle(warn.querySelector('.core-vital__subfill')).backgroundColor).toBe('rgb(245, 166, 35)')
    expect(getComputedStyle(danger.querySelector('.core-vital__subfill')).backgroundColor).toBe('rgb(255, 69, 96)')
    // A solo plate has no bar and no sub glyph at all.
    const solo = canvasElement.querySelector('.core-vital--solo')
    expect(solo.querySelector('.core-vital__bar')).toBeNull()
    expect(solo.querySelector('.core-vital__subicon')).toBeNull()
    // Low pulses the glyph, `lowBelow: 0` opts out.
    const low = canvasElement.querySelector('.core-vital.is-low')
    expect(getComputedStyle(low.querySelector('.core-vital__icon')).animationName).toBe('core-pulse')
  },
}
