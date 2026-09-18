// Kit/Feedback Tooltip — CoreTooltip (DESIGN §37.5, Feedback).
import { h, resolveComponent } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreTooltip from '../../kit/components/CoreTooltip.vue'
import TooltipGallery from './scenes/TooltipGallery.vue'

export default {
  title: 'Kit/Feedback/Tooltip',
  component: CoreTooltip,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The smallest surface in the kit: ink 96 %, a strong hairline, 13 px. It appears after '
          + '`delay` on hover and at once on focus, and goes away on leave, blur, Escape or any press. The '
          + 'bubble is teleported and `pointer-events: none`, so it can never be hovered — which is what '
          + 'keeps it from flickering on the edge of its own trigger. Escape deliberately does NOT take an '
          + 'Escape layer: a layer swallows the key, and a tooltip lying over an open dialog must not eat '
          + 'the press meant for the dialog. Give it `text` for a hint, or the `content` slot for the rich '
          + 'item card the inventory hangs off a slot (12 px padding, 280 px wide).',
      },
      story: { inline: false, height: '320px' },
    },
  },
  argTypes: {
    text: { control: 'text' },
    placement: {
      control: 'select',
      options: ['top', 'top-start', 'bottom', 'bottom-end', 'left', 'left-start', 'right', 'right-end'],
    },
    delay: { control: { type: 'number', min: 0, max: 1500, step: 50 }, description: 'ms before it shows on hover.' },
    disabled: { control: 'boolean' },
  },
  args: { text: 'Health — regenerates to 50 % out of combat.', placement: 'top', delay: 350, disabled: false },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const Btn = resolveComponent('CoreButton')
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '120px 40px' } }, [
        h(CoreTooltip, { ...args }, { default: () => h(Btn, { icon: 'heart' }, () => 'Hover or tab to me') }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-tooltip__anchor')).not.toBeNull())
    // Focus shows it without waiting for the delay.
    canvasElement.querySelector('.core-tooltip__anchor button').focus()
    await waitFor(() => expect(document.querySelector('#core-overlays .core-tooltip')).not.toBeNull())
    const tip = document.querySelector('.core-tooltip')
    expect(tip.getAttribute('role')).toBe('tooltip')
    expect(getComputedStyle(tip).pointerEvents).toBe('none')
    expect(canvasElement.querySelector('.core-tooltip__anchor').getAttribute('aria-describedby')).toBe(tip.id)
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(TooltipGallery) }),
  parameters: { docs: { story: { inline: false, height: '820px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Tooltip')).toBeInTheDocument())
    const anchors = canvasElement.querySelectorAll('.core-tooltip__anchor')
    expect(anchors.length).toBeGreaterThan(12)
    anchors[0].dispatchEvent(new MouseEvent('mouseenter'))
    await waitFor(() => expect(document.querySelector('.core-tooltip')).not.toBeNull())
  },
}
