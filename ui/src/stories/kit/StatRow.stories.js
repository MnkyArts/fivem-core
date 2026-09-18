// Kit/Data/StatRow — CoreStatRow, the hairline-framed detail stat of mockup 3 (DESIGN §37.5).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreStatRow from '../../kit/components/CoreStatRow.vue'
import { METER_TONES } from '../../kit/use.js'
import StatRowGallery from './scenes/StatRowGallery.vue'

const CARD = {
  width: '520px',
  padding: '22px 26px 24px',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui)',
  background: 'var(--color-panel-solid)',
}

export default {
  title: 'Kit/Data/Stat Row',
  component: CoreStatRow,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The detail stat of the inventory: a glyph, what the stat is in the display voice, and '
          + 'the number hard against the right edge — between two hairlines. Stacked rows share one line '
          + '(`.core-statrow + .core-statrow` turns the neighbour\'s top border transparent, so the 56 px '
          + 'rhythm is not disturbed), which is what makes a list of effects read as one block. `tone` '
          + 'colours the VALUE only, and it has no default: the mockup\'s `+75` is white, and a row that '
          + 'shouts every time stops meaning anything.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    icon: { control: 'text', description: 'Registry name or raw path, in the foreground colour.' },
    label: { control: 'text' },
    value: { control: 'text' },
    tone: { control: 'select', options: [''].concat(METER_TONES), description: 'Colours the value. Empty: `fg`.' },
    hairlines: { control: 'inline-radio', options: ['both', 'top', 'bottom', 'none'] },
  },
  args: { icon: 'heart', label: 'Health restore', value: '+75', tone: '', hairlines: 'both' },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h('div', { style: CARD }, [
        h(CoreStatRow, { ...args }),
        h('p', { class: 'core-flavor', style: { marginTop: '20px' } }, 'A small kit. A second chance.'),
      ]),
    ]),
  }),
  parameters: {
    docs: { description: { story: 'The item detail block of mockup 3, one row and its flavour line.' } },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-statrow')).not.toBeNull())
    const root = canvasElement.querySelector('.core-statrow')
    expect(root.classList.contains('core-statrow--line-both')).toBe(true)
    // No tone -> no tone class, and the value falls back to the foreground colour.
    expect(root.className.indexOf('core-tone-')).toBe(-1)
    expect(root.querySelector('.core-statrow__value').textContent.trim()).toBe('+75')
    expect(Math.round(root.getBoundingClientRect().height)).toBe(56)
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(StatRowGallery) }),
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: { story: 'The mockup\'s item detail, stacked weapon stats, every tone, the four hairline modes and the value slot.' },
      story: { inline: false, height: '900px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreStatRow')).toBeInTheDocument())
    const rows = canvasElement.querySelectorAll('.core-statrow')
    expect(rows.length).toBeGreaterThan(15)
    // Stacked rows share one hairline: the second row of a stack draws no top border of its own.
    const stacked = canvasElement.querySelectorAll('.core-statrow + .core-statrow')
    expect(stacked.length).toBeGreaterThan(0)
    expect(getComputedStyle(stacked[0]).borderTopColor).toBe('rgba(0, 0, 0, 0)')
    expect(canvasElement.querySelector('.core-statrow--line-none')).not.toBeNull()
    expect(canvasElement.querySelector('.core-statrow.core-tone-health')).not.toBeNull()
  },
}
