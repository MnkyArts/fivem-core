// Kit/Surfaces Panel — CorePanel, the bordered dark panel every screen is built from (DESIGN §37.5).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CorePanel from '../../kit/components/CorePanel.vue'
import PanelGallery from './scenes/PanelGallery.vue'

export default {
  title: 'Kit/Surfaces/Panel',
  component: CorePanel,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A translucent slate fill over the game, a 1 px hairline, 6 px radius, a deep soft shadow '
          + 'and a faint 120 px sheen down from the top edge. Padding lives on the header, body and footer — '
          + 'never on the root — so a bare `<div class="core-panel">` works and a full-bleed grid sits happily '
          + 'in a `padding="none"` body. Reach for `variant="flat"` (not another panel) when you need a well '
          + 'INSIDE a panel: nesting two shadowed surfaces is what made the old pages look muddy. '
          + '`variant="hud"` is the flat 4 px plate for a surface that lives ON the game — thinner fill, '
          + 'brighter hairline, no sheen — and it never takes `blur`, because the HUD is up all the time.',
      },
      story: { inline: false, height: '420px' },
    },
  },
  argTypes: {
    variant: { control: 'inline-radio', options: ['default', 'solid', 'flat', 'ghost', 'hud'] },
    padding: { control: 'inline-radio', options: ['none', 'sm', 'md', 'lg'] },
    headingSize: { control: 'inline-radio', options: ['sm', 'md', 'lg', 'xl'] },
    title: { control: 'text' },
    subtitle: { control: 'text', description: 'Eyebrow voice, under the title.' },
    eyebrow: { control: 'text', description: 'Label voice, above the title.' },
    slash: { control: 'boolean', description: 'The // marker and an italic title.' },
    accent: { control: 'boolean', description: 'A 2 px coral line fading out along the top edge.' },
    scroll: { control: 'boolean', description: 'The body scrolls instead of growing.' },
    blur: { control: 'boolean', description: 'Glass — data-core-blur (§32). One per page.' },
    tag: { control: 'text' },
  },
  args: {
    variant: 'default',
    padding: 'md',
    headingSize: 'md',
    title: 'Inventory',
    subtitle: "Gear up for what's next.",
    eyebrow: '',
    slash: false,
    accent: false,
    scroll: false,
    blur: false,
    tag: 'section',
  },
}

export const Playground = {
  // The args have to be read INSIDE the render function or the controls stop being live
  // (the vue3 renderer mutates one reactive proxy instead of remounting — see ../storeHelpers.js).
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '40px', maxWidth: '620px' } }, [
      h(CorePanel, { ...args }, {
        default: () => h('p', { class: 'core-text' },
          'Nine slots free. Drop a weapon here to stow it, or drag it onto the hotbar.'),
        footer: () => [
          h('span', { class: 'core-label' }, 'Weight'),
          h('span', { class: 'core-num text-ui-sm', style: { marginLeft: 'auto', color: 'var(--color-fg)' } }, '18.5 / 30.0'),
        ],
      }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-panel')).not.toBeNull())
    const panel = canvasElement.querySelector('.core-panel')
    expect(panel.classList.contains('core-panel--default')).toBe(true)
    expect(panel.classList.contains('core-panel--pad-md')).toBe(true)
    // Padding is on the parts, never on the root.
    expect(getComputedStyle(panel).paddingTop).toBe('0px')
    expect(panel.querySelector('.core-panel__header')).not.toBeNull()
    expect(panel.querySelector('.core-panel__footer')).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(PanelGallery) }),
  parameters: {
    docs: {
      description: { story: 'Variants, the padding scale, headings, accent, footer, scroll, glass and the bare class.' },
      story: { inline: false, height: '1900px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CorePanel')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-panel').length).toBeGreaterThan(10)
    expect(canvasElement.querySelector('.core-panel.has-accent')).not.toBeNull()
    expect(canvasElement.querySelector('.core-panel[data-core-blur]')).not.toBeNull()
  },
}
