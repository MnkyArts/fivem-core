// Kit/Data — CoreAvatar and CorePlayerChip (DESIGN §37.5, Data — display).
//
// The chip is the avatar's one composed use, so both live in one file (and one title: a Storybook
// title cannot be a leaf and a folder at the same time).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreAvatar from '../../kit/components/CoreAvatar.vue'
import CorePlayerChip from '../../kit/components/CorePlayerChip.vue'
import AvatarGallery from './scenes/AvatarGallery.vue'
import avatar from './assets/avatar.jpg'

const STATUSES = ['', 'online', 'away', 'busy', 'offline']

export default {
  title: 'Kit/Data/Avatar & Player Chip',
  component: CoreAvatar,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A portrait with somewhere to fall back to. `size` takes a number as well as the '
          + 'four names, so the same component covers a 28 px chat line and a 76 px profile header; '
          + 'an empty `src` — or one that fails to load — shows the initials of up to two words of '
          + '`name` instead. **CorePlayerChip** is the composed form mockup 1 hangs in the top right '
          + 'of the main menu: portrait flush left, name and presence, then the level and its own '
          + '4 px XP rail. It is a HUD element, so its root is click-through.',
      },
    },
  },
  argTypes: {
    src: { control: 'text', description: 'Image url. Empty (or a 404) falls back to the initials.' },
    name: { control: 'text', description: 'Initials source and alt text.' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg', 'xl'], description: '28 / 40 / 56 / 76 px, or a number.' },
    shape: { control: 'inline-radio', options: ['square', 'circle'] },
    status: { control: 'inline-radio', options: STATUSES },
    ring: { control: 'boolean', description: '2 px accent-hi outline with a 2 px ink gap.' },
  },
  args: { src: avatar, name: 'Travis Kane', size: 'lg', shape: 'square', status: 'online', ring: false },
}

export const Playground = {
  // Args are spread INSIDE the render function: the vue3 renderer mutates one reactive proxy
  // instead of remounting, and reading them above would freeze the controls.
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '56px', display: 'flex', alignItems: 'center', gap: '20px' } }, [
      h(CoreAvatar, { ...args }),
      h('span', { class: 'core-label' }, args.name || 'no name'),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-avatar')).not.toBeNull())
    const el = canvasElement.querySelector('.core-avatar')
    expect(el.style.width).toBe('56px')
    expect(el.querySelector('.core-avatar__status')).not.toBeNull()
  },
}

export const Initials = {
  name: 'Playground — initials fallback',
  args: { src: '', name: 'Mila Ortega' },
  render: Playground.render,
  parameters: {
    docs: { description: { story: 'No `src`: the first letters of up to two words on a white 8 % plate. A broken url ends up here too, at runtime.' } },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('MO')).toBeInTheDocument())
  },
}

export const PlayerChip = {
  name: 'PlayerChip — playground',
  component: CorePlayerChip,
  argTypes: {
    name: { control: 'text' },
    avatar: { control: 'text' },
    level: { control: 'text' },
    levelLabel: { control: 'text' },
    progress: { control: { type: 'range', min: 0, max: 1, step: 0.01 }, description: '0–1, not 0–100.' },
    status: { control: 'inline-radio', options: STATUSES },
    subtitle: { control: 'text', description: 'Optional third line under the XP rail.' },
  },
  args: { name: 'Travis', avatar, level: 32, levelLabel: 'Lv.', progress: 0.56, status: 'online', subtitle: '' },
  render: (args) => ({
    setup: () => () => h('div', { style: { padding: '56px' } }, [h(CorePlayerChip, { ...args })]),
  }),
  parameters: {
    docs: { description: { story: 'Mockup 1, 1:1. Drag `progress` and the rail eases over 250 ms.' } },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('TRAVIS')).toBeInTheDocument())
    const chip = canvasElement.querySelector('.core-playerchip')
    expect(getComputedStyle(chip).pointerEvents).toBe('none')
    expect(canvasElement.querySelector('.core-playerchip__xpfill').style.width).toBe('56.00%')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(AvatarGallery) }),
  parameters: {
    docs: {
      description: { story: 'Sizes, shapes, the initials fallback, the ring, all four presence states — and the chip with both of its slots.' },
      story: { inline: false, height: '1500px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreAvatar · CorePlayerChip')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-avatar').length).toBeGreaterThan(15)
    expect(canvasElement.querySelectorAll('.core-playerchip').length).toBe(6)
    expect(canvasElement.querySelector('.core-avatar.is-ring')).not.toBeNull()
  },
}
