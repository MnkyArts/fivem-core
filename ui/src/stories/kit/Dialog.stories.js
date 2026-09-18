// Kit/Feedback Dialog — CoreDialog (DESIGN §37.5, Feedback; the skin of AlertDialog / InputDialog / Menu).
import { h, resolveComponent } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreDialog from '../../kit/components/CoreDialog.vue'
import DialogGallery from './scenes/DialogGallery.vue'

export default {
  title: 'Kit/Feedback/Dialog',
  component: CoreDialog,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The modal: the mockups\' detail-card surface (panel fill, one hairline, 6 px corners, a '
          + 'deep shadow) with the 2 px fading tone line along the top edge and a darker footer under a '
          + 'hairline. Focus moves in on open — the first `[autofocus]`, else the first button — Tab is '
          + 'trapped inside, and focus returns where it came from on close. Escape goes through the kit\'s '
          + 'layer stack, so a popover opened inside the dialog eats the first press (§37.4). `closable: '
          + 'false` removes every way out but the footer; `persistent` keeps only the ✕ and the footer. '
          + 'The Playground renders inline (`:teleport="false" :backdrop="false"`) so it stays in the frame.',
      },
      story: { inline: false, height: '420px' },
    },
  },
  argTypes: {
    open: { control: 'boolean' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg', 'xl'], description: '360 / 460 / 640 / 860 px.' },
    tone: { control: 'select', options: ['accent', 'neutral', 'success', 'warning', 'danger', 'info'] },
    title: { control: 'text' },
    subtitle: { control: 'text', description: 'Eyebrow voice, under the title.' },
    icon: { control: 'text', description: 'Fills the 40 px tone tile in front of the title.' },
    closable: { control: 'boolean' },
    persistent: { control: 'boolean' },
    backdrop: { control: 'boolean' },
    teleport: { control: 'boolean' },
    blur: { control: 'boolean' },
  },
  args: {
    open: true,
    size: 'sm',
    tone: 'danger',
    title: 'Sell this vehicle?',
    subtitle: 'Sultan RS · Legion Square',
    icon: 'warning',
    closable: true,
    persistent: false,
    backdrop: false,
    teleport: false,
    blur: true,
  },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const Btn = resolveComponent('CoreButton')
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '40px' } }, [
        h(CoreDialog, { ...args }, {
          default: () => 'The dealer offers $68,400, which is 40 % of what you paid. The upgrades do not '
            + 'come back and the plate is released to the pool.',
          footer: () => [
            h(Btn, { variant: 'ghost', size: 'sm' }, () => 'Keep it'),
            h(Btn, { variant: 'danger', size: 'sm' }, () => 'Sell'),
          ],
        }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-dialog')).not.toBeNull())
    const dialog = canvasElement.querySelector('.core-dialog')
    expect(dialog.getAttribute('role')).toBe('dialog')
    expect(dialog.getAttribute('aria-modal')).toBe('true')
    expect(dialog.classList.contains('core-dialog--sm')).toBe(true)
    expect(dialog.classList.contains('core-tone-danger')).toBe(true)
    expect(dialog.querySelector('.core-dialog__icontile')).not.toBeNull()
    expect(dialog.querySelector('.core-dialog__footer')).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(DialogGallery) }),
  parameters: { docs: { story: { inline: false, height: '1100px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Dialog')).toBeInTheDocument())
    // Two inline dialogs are always on screen; the other three live behind their buttons.
    expect(canvasElement.querySelectorAll('.core-dialog').length).toBe(2)
    expect(canvasElement.querySelector('.core-dialog--sm')).not.toBeNull()
  },
}
