// Kit/Game/Interaction Dot — CoreInteractionDot (DESIGN §37.5, Game).
// The playground is wrapped in a positioned box, because the component is a 0 x 0 anchor: `x`/`y`
// place it inside that box the way a world-to-screen projection would.
import { h } from 'vue'
import { expect, waitFor } from 'storybook/test'
import CoreInteractionDot from '../../kit/components/CoreInteractionDot.vue'
import InteractionDotGallery from './scenes/InteractionDotGallery.vue'

export default {
  title: 'Kit/Game/Interaction Dot',
  component: CoreInteractionDot,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The marker that says "you can interact here". Idle it is a 14 px ring around a '
          + '6 px white core, both haloed so they read over any scene; `focused` (the player is '
          + 'looking at it) collapses the ring and puts a solid CoreKey on the SAME point while the '
          + 'band slides out from behind it. A HUD element: click-through, no emits — the game '
          + 'decides what happens when the key is pressed. Use CorePrompt instead when the action '
          + 'belongs to a fixed corner of the screen rather than to a point in the world.',
      },
      story: { inline: false, height: '320px' },
    },
  },
  argTypes: {
    focused: { control: 'boolean', description: 'The player is looking at it.' },
    keys: { control: 'text', description: "'E', or ['SHIFT', 'E'] for a combination." },
    label: { control: 'text' },
    icon: { control: 'text', description: 'Registry name or raw path.' },
    description: { control: 'text', description: 'Second line: the cost, the cooldown, why it is blocked.' },
    progress: { control: { type: 'range', min: 0, max: 1, step: 0.01 }, description: 'Hold-to-interact, drawn on the cap.' },
    disabled: { control: 'boolean', description: 'Locked or out of reach: greyed out, outline lock cap.' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    side: { control: 'inline-radio', options: ['right', 'left'], description: 'Which way the band opens.' },
    pulse: { control: 'boolean', description: 'A slow attention ring while idle.' },
  },
  args: {
    focused: true,
    keys: 'F',
    label: 'Enter Vehicle',
    icon: 'steering',
    description: '',
    progress: 0,
    disabled: false,
    size: 'md',
    side: 'right',
    pulse: true,
  },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', {
      style: { position: 'relative', width: '720px', height: '220px', margin: '40px' },
    }, [
      h(CoreInteractionDot, { ...args, x: args.side === 'left' ? 640 : 80, y: 110 }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-interaction-dot')).not.toBeNull())
    const root = canvasElement.querySelector('.core-interaction-dot')
    // HUD element: it is painted over the world and never takes the mouse (§37.4).
    expect(getComputedStyle(root).pointerEvents).toBe('none')
    expect(root.classList.contains('is-focused')).toBe(true)
    // The cap replaces the dot on the SAME point: the two centres have to agree.
    const dot = root.querySelector('.core-interaction-dot__dot').getBoundingClientRect()
    const cap = root.querySelector('.core-interaction-dot__cap').getBoundingClientRect()
    expect(Math.abs((dot.left + dot.width / 2) - (cap.left + cap.width / 2))).toBeLessThan(1)
    expect(Math.abs((dot.top + dot.height / 2) - (cap.top + cap.height / 2))).toBeLessThan(1)
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(InteractionDotGallery) }),
  parameters: {
    docs: {
      description: {
        story: 'The key art with markers on plausible world points: idle dots on a hatch, a crate '
          + 'and a fuse box, the focused truck with its second action, a locked door, a hold in '
          + 'progress and one dot at the right edge whose band opens the other way — then the sizes, '
          + 'the states, the tones and a switch that plays the look-at transition.',
      },
      story: { inline: false, height: '1800px' },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-interaction-dot').length).toBeGreaterThan(10))
    expect(canvasElement.querySelector('.core-interaction-dot.is-disabled')).not.toBeNull()
    expect(canvasElement.querySelector('.core-interaction-dot--left')).not.toBeNull()
    expect(canvasElement.querySelector('.core-interaction-dot__option')).not.toBeNull()
    expect(canvasElement.querySelector('.core-interaction-dot.is-pulse .core-interaction-dot__pulse')).not.toBeNull()
  },
}
