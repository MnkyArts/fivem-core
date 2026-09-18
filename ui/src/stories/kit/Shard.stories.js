// Kit/Feedback Shard — CoreShard (DESIGN §37.5, Feedback; the skin of the shell's Shard, §37.6).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreShard from '../../kit/components/CoreShard.vue'
import ShardGallery from './scenes/ShardGallery.vue'

export default {
  title: 'Kit/Feedback/Shard',
  component: CoreShard,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The loud one: the centre-screen banner of the base game ("WASTED", "MISSION '
          + 'PASSED"). A full-bleed band that fades out towards both screen edges, a tinted hairline '
          + 'along its top and bottom, the title in the display voice over an eyebrow-voice line. '
          + 'The style is a tone — `wasted` is danger, `success` is success, `info` the accent — and '
          + 'the band brings no position of its own, so the caller places it (the shell hangs it at '
          + '`top-[24vh] z-45` and keys it with `store.shard.seq`, which replays the animation when a '
          + 'second shard arrives). Click-through: the game is still running underneath. '
          + 'The wire field of `shard:show` is `style`, but the prop is `variant`: Vue parses any '
          + 'prop called `style` as CSS as soon as props are merged, and a `<Transition>` merges.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    variant: {
      control: 'inline-radio',
      options: ['wasted', 'success', 'info'],
      description: '`shard:show { style }`. Tints the title and the two hairlines; anything else falls back to `info`.',
    },
    title: { control: 'text', description: 'The big line; uppercase, wraps inside 86 vw.' },
    subtitle: { control: 'text', description: 'Optional eyebrow line; omitted when empty.' },
  },
  args: { variant: 'wasted', title: 'Wasted', subtitle: 'You lost $500' },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { style: { padding: '40px 0' } }, [h(CoreShard, { ...args })]),
  }),
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.title)).toBeInTheDocument())
    const shard = canvasElement.querySelector('.core-shard')
    expect(shard.classList.contains('core-shard--wasted')).toBe(true)
    expect(shard.classList.contains('core-tone-danger')).toBe(true)
    // It must never eat a click: the game keeps running underneath (§37.4).
    expect(getComputedStyle(shard).pointerEvents).toBe('none')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(ShardGallery) }),
  parameters: { docs: { story: { inline: false, height: '1200px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Shard')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-shard').length).toBe(5)
    // Title only: the subtitle row is not rendered at all.
    expect(canvas.getByText('Busted').parentElement.querySelector('.core-shard__subtitle')).toBeNull()
  },
}
