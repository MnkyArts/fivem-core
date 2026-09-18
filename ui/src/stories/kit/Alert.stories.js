// Kit/Feedback Alert — CoreAlert (DESIGN §37.5, Feedback).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreAlert from '../../kit/components/CoreAlert.vue'
import AlertGallery from './scenes/AlertGallery.vue'

export default {
  title: 'Kit/Feedback/Alert',
  component: CoreAlert,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The inline banner: a tone 10 % wash behind a tone hairline, with the 3 px tone bar down '
          + 'the left edge. It belongs INSIDE the panel it talks about — next to the field that is wrong, '
          + 'above the list that is empty. A message that has to follow the player around the world is a '
          + '`CoreToast`, and a question that must be answered before anything else happens is a `CoreDialog`. '
          + 'The glyph comes from the tone unless you pass one (`icon=""` removes it).',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    tone: { control: 'select', options: ['accent', 'neutral', 'success', 'warning', 'danger', 'info'] },
    variant: { control: 'inline-radio', options: ['soft', 'outline'] },
    title: { control: 'text', description: 'Display-voice headline.' },
    text: { control: 'text', description: 'Body copy; the default slot wins over it.' },
    icon: { control: 'text', description: 'Registry name or raw path. Empty removes the glyph.' },
    dismissible: { control: 'boolean', description: 'Shows the ✕, which only emits `dismiss`.' },
  },
  args: {
    tone: 'warning',
    variant: 'soft',
    title: 'Fuel low',
    text: '12 % left in the tank. Nearest pump is 480 m north on Route 68.',
    icon: undefined,
    dismissible: true,
  },
}

export const Playground = {
  // Props are read INSIDE the render function so the controls stay live (see ../storeHelpers.js).
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '40px', maxWidth: '660px' } }, [
      h(CoreAlert, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-alert')).not.toBeNull())
    const alert = canvasElement.querySelector('.core-alert')
    expect(alert.classList.contains('core-tone-warning')).toBe(true)
    expect(alert.classList.contains('core-alert--soft')).toBe(true)
    expect(alert.querySelector('.core-alert__close')).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(AlertGallery) }),
  parameters: { docs: { story: { inline: false, height: '1200px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Alert')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-alert').length).toBeGreaterThan(8)
    expect(canvasElement.querySelector('.core-alert--outline')).not.toBeNull()
    expect(canvasElement.querySelector('.core-alert__actions')).not.toBeNull()
  },
}
