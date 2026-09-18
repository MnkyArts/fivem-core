// Kit/Data/Progress — CoreProgress, the linear meter (DESIGN §37.5, Data — meters).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreProgress from '../../kit/components/CoreProgress.vue'
import { METER_TONES } from '../../kit/use.js'
import ProgressGallery from './scenes/ProgressGallery.vue'

export default {
  title: 'Kit/Data/Progress',
  component: CoreProgress,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'One bar for every linear read-out: the inventory capacity row of the mockup, a '
          + 'magazine, a vital, an upload, the XP line of the player chip. The track is always white 12 % '
          + 'and only the fill changes — the brand gradient on `accent`, a near-white ramp on `neutral`, the '
          + 'flat tone colour otherwise. `warnBelow` / `dangerBelow` swap the TONE CLASS rather than a '
          + 'colour, so a re-themed server keeps owning the palette. For work with no measurable progress '
          + 'use `indeterminate` (or a CoreSpinner); for a radial read-out, CoreRing.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    value: { control: { type: 'range', min: 0, max: 100, step: 0.5 } },
    max: { control: 'number' },
    size: { control: 'inline-radio', options: ['xs', 'sm', 'md', 'lg'], description: '2 / 4 / 8 / 12 px.' },
    tone: { control: 'select', options: METER_TONES },
    color: { control: 'text', description: 'Any CSS colour — wins over the tone.' },
    label: { control: 'text' },
    icon: { control: 'text', description: 'Registry name or raw path, drawn in the tone.' },
    showValue: { control: 'boolean' },
    valueText: { control: 'text', description: 'A finished string; replaces the read-out entirely.' },
    inline: { control: 'boolean', description: 'One row: glyph · caption · bar · value (the capacity bar).' },
    segments: { control: { type: 'range', min: 0, max: 30, step: 1 }, description: 'Cells with a 2 px gap; 0 = a solid bar.' },
    indeterminate: { control: 'boolean' },
    warnBelow: { control: { type: 'range', min: 0, max: 100, step: 1 } },
    dangerBelow: { control: { type: 'range', min: 0, max: 100, step: 1 } },
    format: { table: { disable: true } },
  },
  args: {
    value: 62,
    size: 'md',
    tone: 'accent',
    color: '',
    label: 'Contract progress',
    icon: '',
    showValue: true,
    valueText: '',
    inline: false,
    segments: 0,
    indeterminate: false,
    warnBelow: 0,
    dangerBelow: 0,
  },
}

export const Playground = {
  // The args proxy is mutated in place instead of remounting, so the spread has to happen INSIDE
  // the render function or the controls stop moving the bar (see ../storeHelpers.js).
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '620px' } }, [
      h(CoreProgress, { ...args }),
    ]),
  }),
  parameters: {
    docs: {
      description: {
        story: 'Turn `inline` on with `icon: backpack`, `tone: neutral` and `max: 30` to rebuild the '
          + 'capacity row of mockup 3 — the `/ 30.0` half dims itself.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-progress')).not.toBeNull())
    const root = canvasElement.querySelector('.core-progress')
    const track = root.querySelector('.core-progress__track')
    expect(root.classList.contains('core-tone-accent')).toBe(true)
    expect(track.getAttribute('role')).toBe('progressbar')
    expect(track.getAttribute('aria-valuenow')).toBe('62')
    expect(track.getAttribute('aria-valuemax')).toBe('100')
    expect(parseFloat(root.querySelector('.core-progress__fill').style.width)).toBe(62)
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(ProgressGallery) }),
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: { story: 'Sizes, tones, vitals, the capacity row, segments, thresholds, indeterminate and a custom colour.' },
      story: { inline: false, height: '900px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreProgress')).toBeInTheDocument())
    // A threshold swaps the tone class: 80 stays info, 20 warns, 6 is danger.
    const fuel = [...canvasElement.querySelectorAll('.core-progress')]
      .filter((el) => (el.textContent || '').indexOf('Fuel — ') !== -1)
    expect(fuel.length).toBe(3)
    expect(fuel[0].classList.contains('core-tone-info')).toBe(true)
    expect(fuel[1].classList.contains('core-tone-warning')).toBe(true)
    expect(fuel[2].classList.contains('core-tone-danger')).toBe(true)
    // The capacity row prints the fraction with the max half dimmed.
    const capacity = canvasElement.querySelector('.core-progress--inline .core-progress__value')
    expect(capacity.textContent.replace(/\s+/g, ' ')).toBe('18.5 / 30.0')
    expect(capacity.querySelector('.core-progress__max')).not.toBeNull()
    expect(canvasElement.querySelectorAll('.core-progress.is-segmented').length).toBe(3)
    expect(canvasElement.querySelector('.core-progress.is-indeterminate')).not.toBeNull()
  },
}
