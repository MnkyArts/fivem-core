// Kit/Surfaces Card — CoreCard: the LAST PLAYED card of mockup 1 and the quest detail of mockup 4
// (DESIGN §37.5).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreCard from '../../kit/components/CoreCard.vue'
import CardGallery from './scenes/CardGallery.vue'
import lastplayed from './assets/lastplayed.jpg'

export default {
  title: 'Kit/Surfaces/Card',
  component: CoreCard,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Media plus text. `left` insets the picture inside the card padding with a 4 px radius; '
          + '`top` bleeds it to the top edge, dissolves it into the card colour and pulls the title up over '
          + 'the fade. An interactive card takes role/tabindex rather than being a `<button>`, because the '
          + '`meta` and `trailing` slots routinely hold buttons of their own — so do NOT use it as a plain '
          + 'button with a picture; that is CoreButton with an icon. Inside a panel use `variant="flat"` or '
          + '`"ghost"`: stacking a second shadowed surface on the first is what made the old pages look muddy.',
      },
      story: { inline: false, height: '360px' },
    },
  },
  argTypes: {
    variant: { control: 'inline-radio', options: ['default', 'flat', 'ghost'] },
    imagePosition: { control: 'inline-radio', options: ['left', 'top'] },
    mediaWidth: { control: { type: 'number' } },
    mediaHeight: { control: { type: 'number' } },
    eyebrow: { control: 'text' },
    title: { control: 'text' },
    uppercase: { control: 'boolean', description: 'false keeps a quest name in mixed case.' },
    subtitle: { control: 'text' },
    icon: { control: 'text', description: 'Registry name or raw path, before the subtitle.' },
    selected: { control: 'boolean' },
    interactive: { control: 'boolean' },
    disabled: { control: 'boolean' },
  },
  args: {
    variant: 'default',
    image: lastplayed,
    imagePosition: 'left',
    mediaWidth: 182,
    mediaHeight: 152,
    eyebrow: 'Last played',
    title: 'A Brighter Tomorrow',
    uppercase: true,
    subtitle: 'Northern Ridge',
    icon: 'map-marker',
    selected: false,
    interactive: false,
    disabled: false,
  },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '40px' } }, [
      h(CoreCard, { ...args, style: { width: '546px' } }, {
        meta: () => [
          h('span', [h('b', '72%'), ' Complete']),
          h('span', 'Mar 12, 2024  18:24'),
        ],
      }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-card')).not.toBeNull())
    const card = canvasElement.querySelector('.core-card')
    expect(card.classList.contains('core-card--media-left')).toBe(true)
    expect(card.querySelector('.core-card__image')).not.toBeNull()
    expect(card.querySelector('.core-card__meta')).not.toBeNull()
    // Not interactive: no role, no tab stop.
    expect(card.getAttribute('role')).toBeNull()
    expect(card.getAttribute('tabindex')).toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(CardGallery) }),
  parameters: {
    docs: {
      description: { story: 'Both shapes, every state, and cards with no picture at all.' },
      story: { inline: false, height: '1500px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreCard')).toBeInTheDocument())
    expect(canvasElement.querySelector('.core-card--media-top .core-card__fade')).not.toBeNull()
    expect(canvasElement.querySelector('.core-card.is-selected')).not.toBeNull()
    expect(canvasElement.querySelector('.core-card.is-disabled')).not.toBeNull()
    // Interactive cards are reachable by keyboard.
    const interactive = canvasElement.querySelector('.core-card.is-interactive:not(.is-disabled)')
    expect(interactive.getAttribute('tabindex')).toBe('0')
    expect(interactive.getAttribute('role')).toBe('button')
  },
}
