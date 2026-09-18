// Kit/Feedback Popover — CorePopover (DESIGN §37.5, Feedback).
import { h, resolveComponent } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CorePopover from '../../kit/components/CorePopover.vue'
import PopoverGallery from './scenes/PopoverGallery.vue'

export default {
  title: 'Kit/Feedback/Popover',
  component: CorePopover,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'An opaque panel glued to its trigger. Chromium 103 has no anchor positioning and no '
          + 'Popover API, so the trigger slot is wrapped in an inline-flex span to give `useFloating` a rect, '
          + 'and the panel is teleported into `#core-overlays` and placed in viewport coordinates — flipped '
          + 'to the opposite side when the wanted one does not fit and clamped 8 px inside the edge. '
          + '`trigger="click"` toggles from the wrapper, `"hover"` opens on enter and closes 120 ms after '
          + 'the pointer leaves BOTH the trigger and the panel, `"manual"` leaves it to `v-model:open` (the '
          + 'slot\'s `toggle` is for that case — wiring it as well as the click trigger toggles twice). '
          + 'Escape always closes it, through the layer stack, so it never reaches the page behind.',
      },
      story: { inline: false, height: '360px' },
    },
  },
  argTypes: {
    open: { control: 'boolean' },
    trigger: { control: 'inline-radio', options: ['click', 'hover', 'manual'] },
    placement: {
      control: 'select',
      options: ['top', 'top-start', 'top-end', 'bottom', 'bottom-start', 'bottom-end', 'left', 'left-start', 'right', 'right-end'],
    },
    offset: { control: { type: 'number', min: 0, max: 24 } },
    matchWidth: { control: 'boolean' },
    blur: { control: 'boolean' },
  },
  args: { open: false, trigger: 'click', placement: 'bottom-start', offset: 8, matchWidth: false, blur: false },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const Btn = resolveComponent('CoreButton')
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '120px 40px' } }, [
        h(CorePopover, { ...args }, {
          trigger: () => h(Btn, { icon: 'user' }, () => 'Marek Novak'),
          default: () => [
            h('p', { class: 'core-label', style: { margin: '0 0 6px', color: 'var(--color-fg)' } }, 'Marek Novak'),
            h('p', { style: { margin: '0' } }, 'Quartermaster · rank 4 · on duty at the Sandy Shores garage since 01:20.'),
          ],
        }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-popover__anchor')).not.toBeNull())
    canvasElement.querySelector('.core-popover__anchor button').click()
    await waitFor(() => expect(document.querySelector('#core-overlays .core-popover')).not.toBeNull())
    const panel = document.querySelector('.core-popover')
    expect(getComputedStyle(panel).position).toBe('fixed')
    expect(getComputedStyle(panel).pointerEvents).toBe('auto')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(PopoverGallery) }),
  parameters: { docs: { story: { inline: false, height: '900px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Popover')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-popover__anchor').length).toBeGreaterThan(10)
  },
}
