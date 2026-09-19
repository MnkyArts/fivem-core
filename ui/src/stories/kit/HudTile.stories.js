// Kit/Game/Hud Tile — CoreHudTile, the voice tile of the vitals strip (DESIGN §39).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreHudTile from '../../kit/components/CoreHudTile.vue'
import HudTileGallery from './scenes/HudTileGallery.vue'

const FRAME = { padding: '48px' }

export default {
  title: 'Kit/Game/Hud Tile',
  component: CoreHudTile,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The slanted dark tile that opens the vitals strip of §39: core\'s voice read-out. '
          + 'Same unit system as CoreVital (`font-size: var(--core-hud-unit, 24px)`, 1em = 100 px of the '
          + 'mockup) and the same 20° lean — but only the SHAPE is skewed. The glyph is a sibling, '
          + 'centred with a negative margin of half its own box, because a sheared mic reads as a broken '
          + 'one. `active` is "you are transmitting" (a thick `fg` ring and a soft white glow), `dimmed` '
          + 'drops the glyph to 40 %. The height is `--core-hudtile-h`, not a prop: 2.05em next to a full '
          + 'vital, 1.57em next to a `--solo` one. Click-through, like every HUD read-out.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    icon: { control: 'text', description: 'Registry name or raw path — `hud-mic` / `hud-mic-off`.' },
    active: { control: 'boolean', description: 'Transmitting: the bright ring and the glow.' },
    dimmed: { control: 'boolean', description: 'Muted / idle: the glyph at 40 %.' },
    label: { control: 'text', description: 'Accessible name. Empty = decoration, hidden from the a11y tree.' },
    unit: { control: 'text', description: '`--core-hud-unit`: a number is px, a string is any CSS length. '
      + 'Empty = inherit (the kit default is 24px, what the shell runs at; `Config.Hud.Scale = 2` is 48px).' },
  },
  args: { icon: 'hud-mic', active: true, dimmed: false, label: 'Voice', unit: '100px' },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: FRAME }, [h(CoreHudTile, { ...args })]),
  }),
  parameters: {
    docs: {
      description: {
        story: 'At `unit: 100px` the tile is exactly mockup-sized (225 × 205 px). Toggle `active` for '
          + 'the transmitting ring and `dimmed` for the muted glyph; swap `icon` to `hud-mic-off` for the '
          + 'crossed-out twin.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-hudtile')).not.toBeNull())
    const root = canvasElement.querySelector('.core-hudtile')
    expect(root.classList.contains('is-active')).toBe(true)
    expect(root.classList.contains('is-dimmed')).toBe(false)
    expect(root.getAttribute('role')).toBe('img')
    expect(root.getAttribute('aria-label')).toBe('Voice')
    expect(root.hasAttribute('aria-hidden')).toBe(false)
    expect(getComputedStyle(root).pointerEvents).toBe('none')
    expect(getComputedStyle(root).fontSize).toBe('100px')
    // 2.25 × 2.05 em, and only the shape leans.
    expect(Math.round(root.getBoundingClientRect().width)).toBe(225)
    expect(Math.round(root.getBoundingClientRect().height)).toBe(205)
    expect(getComputedStyle(root.querySelector('.core-hudtile__shape')).transform).toContain('matrix(1, 0, -0.36')
    expect(getComputedStyle(root.querySelector('.core-hudtile__icon')).transform).toBe('none')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(HudTileGallery) }),
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: { story: 'The tile in the strip at mockup size, its four states, the two heights `--core-hudtile-h` is made for, and what `unit` does.' },
      story: { inline: false, height: '1100px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreHudTile')).toBeInTheDocument())
    const tiles = canvasElement.querySelectorAll('.core-hudtile')
    expect(tiles.length).toBeGreaterThan(8)
    expect(canvasElement.querySelector('.core-hudtile.is-active')).not.toBeNull()
    expect(canvasElement.querySelector('.core-hudtile.is-dimmed')).not.toBeNull()
    // The muted twin is a different glyph, not a different colour.
    const muted = canvasElement.querySelectorAll('.core-hudtile.is-dimmed .core-hudtile__icon path')
    expect(muted.length).toBeGreaterThan(0)
    expect(getComputedStyle(canvasElement.querySelector('.core-hudtile.is-dimmed .core-hudtile__icon')).opacity).toBe('0.4')
    // The tile stands next to the vitals it was measured against.
    expect(canvasElement.querySelector('.core-vital')).not.toBeNull()
  },
}
