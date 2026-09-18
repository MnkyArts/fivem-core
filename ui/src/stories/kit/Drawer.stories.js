// Kit/Feedback Drawer — CoreDrawer (DESIGN §37.5, Feedback).
import { h, ref, resolveComponent } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreDrawer from '../../kit/components/CoreDrawer.vue'
import DrawerGallery from './scenes/DrawerGallery.vue'

export default {
  title: 'Kit/Feedback/Drawer',
  component: CoreDrawer,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The side sheet: the dialog\'s panel language pinned to a viewport edge over the full '
          + 'height, entering with the 18 px slide of §37.1 (`core-slide-left` comes in from the right). '
          + 'Same Escape layer, same focus trap, same `close(reason)`. Use it for the long list a dialog '
          + 'cannot hold — a crew log, a filter column, a vehicle\'s modification history — when the player '
          + 'should keep seeing the screen they were on. It is always fixed, so there is no inline variant: '
          + 'the story below opens one over the frame.',
      },
      story: { inline: false, height: '520px' },
    },
  },
  argTypes: {
    open: { control: 'boolean' },
    side: { control: 'inline-radio', options: ['right', 'left'] },
    width: { control: { type: 'number', min: 240, max: 720, step: 20 } },
    title: { control: 'text' },
    subtitle: { control: 'text', description: 'Eyebrow voice, under the title.' },
    closable: { control: 'boolean' },
    backdrop: { control: 'boolean' },
    blur: { control: 'boolean' },
  },
  args: {
    open: true,
    side: 'right',
    width: 420,
    title: 'Crew log',
    subtitle: 'Del Perro · last 4 hours',
    closable: true,
    backdrop: true,
    blur: true,
  },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const Btn = resolveComponent('CoreButton')
      const open = ref(true)
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '40px' } }, [
        h(Btn, { onClick: () => { open.value = true } }, () => 'Open the sheet'),
        h(CoreDrawer, { ...args, open: args.open && open.value, 'onUpdate:open': (v) => { open.value = v } }, {
          default: () => 'Escape, the ✕ and a click on the scrim all close it and report which one it was.',
          footer: () => [h(Btn, { variant: 'ghost', size: 'sm', onClick: () => { open.value = false } }, () => 'Close')],
        }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(document.querySelector('.core-drawer')).not.toBeNull())
    const drawer = document.querySelector('.core-drawer')
    expect(drawer.getAttribute('aria-modal')).toBe('true')
    expect(drawer.classList.contains('core-drawer--right')).toBe(true)
    expect(drawer.style.width).toBe('420px')
    expect(canvasElement).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(DrawerGallery) }),
  parameters: { docs: { story: { inline: false, height: '620px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Drawer')).toBeInTheDocument())
    // The right-hand sheet opens on mount, so the scene never screenshots empty.
    await waitFor(() => expect(document.querySelector('.core-drawer--right')).not.toBeNull())
  },
}
