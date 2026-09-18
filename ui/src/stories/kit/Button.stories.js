// Kit/Actions Button — CoreButton (DESIGN §37.5, Actions).
// The Playground spreads the args INSIDE the render function: the vue3 renderer mutates one
// reactive args proxy instead of remounting, so props read outside it would freeze the controls.
import { h } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import CoreButton from '../../kit/components/CoreButton.vue'
import ButtonGallery from './scenes/ButtonGallery.vue'

export default {
  title: 'Kit/Actions/Button',
  component: CoreButton,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Every button of the kit. `secondary` is the default and the quiet one; `primary` is '
          + 'the brand moment — the accent gradient, a white label and a coral drop glow — and there should '
          + 'be exactly one of it per screen. `fade` swaps the solid gradient for the mockups\' USE button: '
          + 'coral on the left, dissolved into the panel on the right. `loading` keeps the label, so the '
          + 'button never changes width mid-request, and `click` is swallowed while it is busy or disabled.',
      },
      story: { inline: false, height: '200px' },
    },
  },
  argTypes: {
    variant: { control: 'inline-radio', options: ['primary', 'secondary', 'ghost', 'danger', 'success'] },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    fade: { control: 'boolean', description: 'Primary only: the fading accent gradient.' },
    block: { control: 'boolean', description: 'Full width of the parent.' },
    icon: { control: 'text', description: 'Registry name or raw path — leading glyph.' },
    iconRight: { control: 'text', description: 'Same, trailing.' },
    kbd: { control: 'text', description: 'A key cap inside, leftmost: `[F] USE`.' },
    loading: { control: 'boolean', description: 'Spinner instead of the icon; clicks stop.' },
    active: { control: 'boolean', description: 'Toggle-on, not `:active`.' },
    disabled: { control: 'boolean' },
    label: { control: 'text', description: 'Story only — the default slot.' },
  },
  args: {
    variant: 'primary',
    size: 'md',
    fade: false,
    block: false,
    icon: 'cart',
    iconRight: '',
    kbd: '',
    loading: false,
    active: false,
    disabled: false,
    label: 'Buy vehicle',
  },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => {
      const { label, ...props } = args
      return h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
        h(CoreButton, { ...props }, () => label),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-btn')).not.toBeNull())
    const button = canvasElement.querySelector('.core-btn')
    expect(button.tagName).toBe('BUTTON')
    expect(button.getAttribute('type')).toBe('button')
    expect(button.className).toContain('core-btn--primary')
    expect(button.className).toContain('core-btn--md')
    expect(button.querySelector('svg.core-icon')).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(ButtonGallery) }),
  parameters: {
    docs: {
      story: { inline: false, height: '1700px' },
      description: {
        story: 'Every variant, size, slot and state, the two buttons the mockups show, and the bare '
          + '`core-btn` classes a plugin page may still be wearing.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreButton')).toBeInTheDocument())

    // The click contract: disabled swallows it, and so does `loading`.
    const count = canvasElement.querySelector('[data-role=count]')
    const dead = canvasElement.querySelector('[data-role=dead]')
    const buy = canvasElement.querySelector('[data-role=buy]')
    expect(count.textContent).toContain('0 purchase')
    await userEvent.click(dead, { pointerEventsCheck: 0 })
    expect(count.textContent).toContain('0 purchase')

    await userEvent.click(buy)
    await waitFor(() => expect(buy.className).toContain('is-loading'))
    expect(count.textContent).toContain('1 purchase')
    expect(buy.querySelector('.core-btn__spinner')).not.toBeNull()
    await userEvent.click(buy, { pointerEventsCheck: 0 })
    expect(count.textContent).toContain('1 purchase')
  },
}
