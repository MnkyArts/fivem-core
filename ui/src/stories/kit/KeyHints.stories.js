// Kit/Actions KeyHints — CoreKeyHints (DESIGN §37.5, Actions).
// Not to be confused with `Built-ins/Key Hints`, which is the Lua-driven bar of §21; that one
// renders this component after §37.6.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreKeyHints from '../../kit/components/CoreKeyHints.vue'
import KeyHintsGallery from './scenes/KeyHintsGallery.vue'

const MAP = [
  { key: 'mouse-left', label: 'Pan' },
  { key: 'mouse-scroll', label: 'Zoom' },
  { key: 'R', label: 'Recenter' },
  { key: 'F', label: 'Show legend' },
]

export default {
  title: 'Kit/Actions/Key Hints',
  component: CoreKeyHints,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The instructional-button bar — GTA\'s bottom-right prompt row, and the footer of every '
          + 'kit screen. `bare` is the footer form (no fill, no border: CoreScreen\'s footer already draws '
          + 'the hairline); the framed form is for a HUD corner that has no chrome of its own. Items come '
          + 'as `{ key, label }` (what the shell\'s `keys:show` store sends), as `{ keys: [...], label }` '
          + 'for a combination, or as a plain string for a cap with no caption.',
      },
      story: { inline: false, height: '200px' },
    },
  },
  argTypes: {
    align: { control: 'inline-radio', options: ['start', 'end', 'between'] },
    bare: { control: 'boolean', description: 'No fill, border or padding.' },
    variant: { control: 'inline-radio', options: ['solid', 'outline'] },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    blur: { control: 'boolean', description: '§32 glass behind the bar.' },
    items: { control: 'object' },
  },
  args: { items: MAP, align: 'end', bare: false, variant: 'solid', size: 'md', blur: false },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreKeyHints, { ...args, style: { width: '640px' } }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-keyhints')).not.toBeNull())
    const bar = canvasElement.querySelector('.core-keyhints')
    expect(bar.querySelectorAll('.core-keyhint').length).toBe(4)
    expect(bar.className).toContain('core-keyhints--end')
    // The two mouse items draw glyphs, the other two draw caps.
    expect(bar.querySelectorAll('.core-key--mouse').length).toBe(2)
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(KeyHintsGallery) }),
  parameters: {
    controls: { disable: true },
    docs: {
      story: { inline: false, height: '1150px' },
      description: { story: 'The map footer of mockup 4, the framed bar, every alignment and size, both item shapes and the slots.' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreKeyHints')).toBeInTheDocument())
    // A bare string item is a cap with no caption — never `[ESC] ESC`.
    const shapes = canvasElement.querySelectorAll('.core-keyhints.is-bare')
    const last = shapes[shapes.length - 1].querySelectorAll('.core-keyhint')
    expect(last[last.length - 1].querySelector('.core-keyhint__label')).toBeNull()
  },
}
