// Kit/Feedback Toast — CoreToast (DESIGN §37.5, Feedback; the skin of the shell's Notifications, §37.6).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreToast from '../../kit/components/CoreToast.vue'
import ToastGallery from './scenes/ToastGallery.vue'

export default {
  title: 'Kit/Feedback/Toast',
  component: CoreToast,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The notification card the shell stacks top right: 340 px, panel fill, one hairline, a '
          + '3 px tone bar and a kicker in the tone. Like every HUD surface it is click-through (§37.4) — '
          + 'only the ✕ takes the mouse — so a run of toasts can never eat a click meant for the game. '
          + '`count` is for a line that arrived again while the card was up, `progress` draws the time it '
          + 'has left along the bottom edge.',
      },
      story: { inline: false, height: '240px' },
    },
  },
  argTypes: {
    tone: { control: 'select', options: ['accent', 'neutral', 'success', 'warning', 'danger', 'info'] },
    title: { control: 'text', description: 'Display-voice kicker, drawn in the tone.' },
    message: { control: 'text', description: 'The line itself; the default slot wins over it.' },
    icon: { control: 'text', description: 'Registry name or raw path. Empty removes the glyph.' },
    count: { control: { type: 'number', min: 0, max: 99 }, description: 'Repeats; below 2 the pill is hidden.' },
    progress: { control: { type: 'range', min: 0, max: 1, step: 0.05 }, description: '0-1 of life left.' },
    dismissible: { control: 'boolean' },
    blur: { control: 'boolean', description: '§32 glass on the card.' },
  },
  args: {
    tone: 'success',
    title: 'Deposit',
    message: 'You banked $4,200 from the Paleto run.',
    icon: undefined,
    count: 0,
    progress: 0.7,
    dismissible: false,
    blur: false,
  },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '40px' } }, [h(CoreToast, { ...args })]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-toast')).not.toBeNull())
    const toast = canvasElement.querySelector('.core-toast')
    expect(toast.classList.contains('core-tone-success')).toBe(true)
    // HUD furniture: the card itself must never take the pointer (§37.4).
    expect(getComputedStyle(toast).pointerEvents).toBe('none')
    expect(toast.querySelector('.core-toast__lifefill').style.width).toBe('70%')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(ToastGallery) }),
  parameters: { docs: { story: { inline: false, height: '1300px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Toast')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-toast').length).toBeGreaterThan(12)
    expect(canvasElement.querySelector('.core-toast__count').textContent).toContain('x')
    expect(canvasElement.querySelector('.core-toast__life')).not.toBeNull()
  },
}
