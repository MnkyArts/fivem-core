// Kit/Foundations Icon — CoreIcon, the one Foundation component (DESIGN §37.5).
//
// The title is NOT `Kit/Foundations/Icon`: `Foundations.stories.js` already claims
// `Kit/Foundations` as a leaf, and a leaf cannot also be a folder in Storybook's index — the two
// entries collide. A sibling title keeps both in the same place in the sidebar.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreIcon from '../../kit/components/CoreIcon.vue'
import { ICONS } from '../../kit/icons.js'
import IconGallery from './scenes/IconGallery.vue'

const NAMES = Object.keys(ICONS).sort()

export default {
  title: 'Kit/Foundations/Icon',
  component: CoreIcon,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A registry glyph: one inline `<svg viewBox="0 0 24 24" fill="currentColor">` with a '
          + 'single path. Because it draws in `currentColor` it is never given a colour of its own — '
          + 'colour the parent (or let the owning component\'s `tone` do it) and the glyph follows. '
          + '`name` takes a registry key or raw 24 × 24 path data, `path` forces raw data, and an unknown '
          + 'name renders nothing and warns once per name.',
      },
      story: { inline: false, height: '620px' },
    },
  },
  argTypes: {
    name: { control: 'select', options: NAMES, description: 'Registry name (or raw path data).' },
    size: { control: 'inline-radio', options: ['xs', 'sm', 'md', 'lg', 'xl'], description: '14 / 16 / 20 / 24 / 32 px, or a number.' },
    spin: { control: 'boolean', description: 'Turns the glyph — loading states.' },
    title: { control: 'text', description: 'Accessible name. Empty = decoration, hidden from the a11y tree.' },
    path: { control: 'text', description: 'Explicit raw 24 × 24 path data; wins over `name`.' },
  },
  args: { name: 'medkit', size: 'xl', spin: false, title: '', path: '' },
}

export const Playground = {
  // The vue3 renderer mutates ONE reactive args proxy instead of remounting (see the note on
  // `liveScene` in ../storeHelpers.js), so the props have to be read INSIDE the render function —
  // spreading them there is what keeps the controls live.
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h('div', { class: 'text-accent', style: { display: 'flex', alignItems: 'center', gap: '16px' } }, [
        h(CoreIcon, { ...args }),
        h('span', { class: 'core-label' }, args.name || args.path || '—'),
      ]),
    ]),
  }),
  parameters: {
    docs: {
      description: {
        story: 'The `text-accent` on the wrapper is doing the colouring — change it to `text-success` '
          + 'and the same glyph turns green.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('svg.core-icon')).not.toBeNull())
    const svg = canvasElement.querySelector('svg.core-icon')
    expect(svg.getAttribute('viewBox')).toBe('0 0 24 24')
    expect(svg.getAttribute('width')).toBe('32')
    expect(svg.querySelector('path')).not.toBeNull()
    // No `title` -> decoration, so screen readers skip it.
    expect(svg.getAttribute('aria-hidden')).toBe('true')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(IconGallery) }),
  parameters: {
    docs: {
      description: { story: 'Sizes, colour by inheritance, `spin`, raw path data and the unknown-name fallback.' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreIcon')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('svg.core-icon').length).toBeGreaterThan(20)
    expect(canvasElement.querySelector('svg.core-icon.is-spin')).not.toBeNull()
  },
}
