// Kit/Data — CoreBadge and CoreTag (DESIGN §37.5, Data — display).
//
// One file for both because they are the same idea at two sizes: a badge counts, a tag names. The
// title carries both names — a Storybook title cannot be a leaf AND a folder, so `Kit/Data/Badge`
// could not also hold `Kit/Data/Badge/Tag`.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreBadge from '../../kit/components/CoreBadge.vue'
import CoreTag from '../../kit/components/CoreTag.vue'
import { ICONS } from '../../kit/icons.js'
import BadgeGallery from './scenes/BadgeGallery.vue'

const TONES = ['accent', 'neutral', 'success', 'warning', 'danger', 'info']
const RARITIES = ['', 'common', 'uncommon', 'rare', 'epic', 'legendary']
const ICON_NAMES = [''].concat(Object.keys(ICONS).sort())

export default {
  title: 'Kit/Data/Badge & Tag',
  component: CoreBadge,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A **badge** is a count or a "something changed" pip: it hangs off a glyph, a tab '
          + 'or a row and never stands on its own. A **tag** names something — a rarity, a vehicle '
          + 'state, a filter the player can drop again. Both take their colour from the tone classes '
          + 'of `css/base.css`, so `tone` and `rarity` are the same machinery: a rarity simply wins, '
          + 'because its class lands last on the root. Reach for CoreStatRow or CoreKeyValue instead '
          + 'when the thing you are showing is a *value* rather than a label.',
      },
    },
  },
  argTypes: {
    value: { control: 'text', description: 'The count or short word. Ignored when `dot` is set.' },
    max: { control: { type: 'number', min: 1 }, description: 'Numbers above this print as `<max>+`.' },
    tone: { control: 'inline-radio', options: TONES },
    variant: { control: 'inline-radio', options: ['solid', 'soft', 'outline'] },
    dot: { control: 'boolean', description: 'A bare 8 px pip — no value, no padding.' },
    pulse: { control: 'boolean', description: 'Adds the breathing tone halo (`core-pulse`).' },
  },
  args: { value: 7, max: 99, tone: 'accent', variant: 'solid', dot: false, pulse: false },
}

export const Playground = {
  // The vue3 renderer mutates ONE reactive args proxy instead of remounting, so the props have to
  // be spread INSIDE the render function or the controls go dead (see ../storeHelpers.js).
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '56px', display: 'flex', alignItems: 'center', gap: '20px' } }, [
      h(CoreBadge, { ...args }),
      h('span', { class: 'core-label' }, 'unread dispatch calls'),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-badge')).not.toBeNull())
    const badge = canvasElement.querySelector('.core-badge')
    expect(badge.classList.contains('core-badge--solid')).toBe(true)
    expect(badge.classList.contains('core-tone-accent')).toBe(true)
  },
}

export const Overflow = {
  name: 'Playground — 99+',
  args: { value: 128 },
  render: Playground.render,
  parameters: {
    docs: { description: { story: 'A numeric value over `max` prints `99+`; a non-numeric one (`NEW`, `LIVE`) is printed as it stands.' } },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('99+')).toBeInTheDocument())
  },
}

export const TagPlayground = {
  name: 'Tag — playground',
  component: CoreTag,
  argTypes: {
    label: { control: 'text' },
    icon: { control: 'select', options: ICON_NAMES },
    tone: { control: 'inline-radio', options: TONES },
    rarity: { control: 'inline-radio', options: RARITIES, description: 'Wins over `tone`.' },
    variant: { control: 'inline-radio', options: ['soft', 'solid', 'outline', 'dark'] },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'], description: '20 / 24 / 30 px.' },
    removable: { control: 'boolean' },
  },
  args: { label: 'Consumable', icon: 'medkit', tone: 'success', rarity: '', variant: 'soft', size: 'md', removable: false },
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '56px' } }, [h(CoreTag, { ...args })]),
  }),
  parameters: {
    docs: {
      description: {
        story: 'Set `rarity` and watch `tone` stop mattering. `variant="dark"` is mockup 2\'s HUD '
          + 'clock plate: ink 78 %, no border, `fg` text — and the tone stays on the glyph.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-tag')).not.toBeNull())
    expect(canvasElement.querySelector('.core-tag').classList.contains('core-tone-success')).toBe(true)
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(BadgeGallery) }),
  parameters: {
    docs: {
      description: { story: 'Every variant, tone, rarity, size and state — plus the removable filter row and the HUD clock.' },
      story: { inline: false, height: '1400px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreBadge · CoreTag')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-badge').length).toBeGreaterThan(20)
    expect(canvasElement.querySelector('.core-tag--dark')).not.toBeNull()
    // The removable row: clicking the ✕ drops that filter.
    const before = canvasElement.querySelectorAll('.core-tag__remove').length
    expect(before).toBe(3)
    canvasElement.querySelectorAll('.core-tag__remove')[0].click()
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-tag__remove').length).toBe(before - 1))
  },
}
