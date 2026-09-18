// Kit/Actions Key — CoreKey and its caption sibling CoreKeyHint (DESIGN §37.5, Actions).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreKey from '../../kit/components/CoreKey.vue'
import CoreKeyHint from '../../kit/components/CoreKeyHint.vue'
import KeyGallery from './scenes/KeyGallery.vue'

export default {
  title: 'Kit/Actions/Key & Key Hint',
  component: CoreKey,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The key cap of the mockups: a solid near-white tile with dark condensed text, a 2 px '
          + 'lip under it, 3 px radius. A wide label (`ESC`, `SPACE`) grows it sideways — the height never '
          + 'changes. The five mouse labels (`mouse`, `mouse-left`, `mouse-right`, `mouse-middle`, '
          + '`mouse-scroll`) draw a line glyph at cap height instead of a tile, because a mouse button is '
          + 'not a key. `progress` (0-1) fills the hold bar along the bottom edge and is bound straight to '
          + 'a transform, so a client may drive it every frame. CoreKeyHint puts a caption next to one or '
          + 'more caps; CoreKeyHints lines those up into a bar.',
      },
      story: { inline: false, height: '180px' },
    },
  },
  argTypes: {
    label: { control: 'text', description: 'Cap text, or one of the five mouse names.' },
    variant: { control: 'inline-radio', options: ['solid', 'outline'] },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    pressed: { control: 'boolean' },
    progress: { control: { type: 'range', min: 0, max: 1, step: 0.01 }, description: '0-1 hold-to-confirm.' },
  },
  args: { label: 'F', variant: 'solid', size: 'md', pressed: false, progress: 0 },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', {
      class: 'pointer-events-auto',
      style: { padding: '48px', display: 'flex', alignItems: 'center', gap: '18px' },
    }, [
      h(CoreKey, { ...args }),
      h('span', { class: 'core-label' }, 'hold to confirm'),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-key')).not.toBeNull())
    const cap = canvasElement.querySelector('.core-key')
    expect(cap.className).toContain('core-key--solid')
    expect(cap.textContent.trim()).toBe('F')
    const box = cap.getBoundingClientRect()
    expect(Math.round(box.height)).toBe(26)
  },
}

export const Hint = {
  name: 'CoreKeyHint',
  render: () => ({
    setup: () => () => h('div', {
      class: 'pointer-events-auto',
      style: { padding: '48px', display: 'flex', flexDirection: 'column', gap: '16px', alignItems: 'flex-start' },
    }, [
      h(CoreKeyHint, { keys: 'ESC', label: 'Back' }),
      h(CoreKeyHint, { keys: ['SHIFT', 'F'], label: 'Enter as passenger' }),
      h(CoreKeyHint, { keys: 'mouse-right', label: 'Aim' }),
      h(CoreKeyHint, { k: 'TAB', label: 'Inventory', variant: 'outline' }),
    ]),
  }),
  parameters: {
    controls: { disable: true },
    docs: { description: { story: '`keys` takes one key or a list; `k` is the short alias. The caption is display 500, uppercase, 0.1 em.' } },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-keyhint').length).toBe(4))
    // A combination renders two caps 4 px apart, inside one hint.
    const combo = canvasElement.querySelectorAll('.core-keyhint')[1]
    expect(combo.querySelectorAll('.core-key').length).toBe(2)
    // A mouse label draws a glyph, not a tile.
    const mouse = canvasElement.querySelectorAll('.core-keyhint')[2].querySelector('.core-key')
    expect(mouse.className).toContain('core-key--mouse')
    expect(mouse.querySelector('svg.core-icon')).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(KeyGallery) }),
  parameters: {
    controls: { disable: true },
    docs: {
      story: { inline: false, height: '1300px' },
      description: { story: 'Both variants, the three sizes, wide labels, every mouse glyph, the pressed state and a hold that runs.' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreKey · CoreKeyHint')).toBeInTheDocument())
    const running = canvasElement.querySelector('[data-role=hold]')
    await waitFor(() => expect(running.querySelector('.core-key__progress')).not.toBeNull())
    // The hold bar is a pure transform, so it is measurable without waiting for a transition.
    const bar = running.querySelector('.core-key__progress')
    expect(getComputedStyle(bar).transform).toContain('matrix')
  },
}
