// Kit/Showcase/Main Menu — mockup 1 rebuilt from kit components only (DESIGN §37.7).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import ShowcaseMainMenu from './scenes/ShowcaseMainMenu.vue'

export default {
  title: 'Kit/Showcase/Main Menu',
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The first of Liam\'s four mockups, rebuilt with nothing but globally registered '
          + '`<Core…>` tags, Tailwind layout utilities and the base type classes — no custom CSS, no '
          + 'literal colours. CoreBackground (`left`) carries the key art, CoreBrand the lockup, the `lg` '
          + 'CoreMenu the four rows whose active one dissolves into the art, CoreCard the LAST PLAYED '
          + 'panel, CorePlayerChip and CoreTagline the top right, CoreDash the footer rule. It is alive: '
          + 'the menu follows the pointer and the arrow keys, a selection raises a CoreToast and EXIT '
          + 'opens a CoreDialog.',
      },
      story: { inline: false, height: '1080px' },
    },
  },
}

export const Screen = {
  render: () => ({ setup: () => () => h(ShowcaseMainMenu) }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Wayfinder')).toBeInTheDocument())

    // The composition: every piece of the mockup is a kit component.
    expect(canvasElement.querySelector('.core-bg--left')).not.toBeNull()
    expect(canvasElement.querySelector('.core-brand--lg')).not.toBeNull()
    expect(canvasElement.querySelector('.core-playerchip')).not.toBeNull()
    expect(canvasElement.querySelector('.core-tagline.has-rule')).not.toBeNull()
    expect(canvasElement.querySelector('.core-card--media-left')).not.toBeNull()

    const rows = canvasElement.querySelectorAll('.core-menu--lg .core-menu__item')
    expect(rows.length).toBe(4)
    expect(rows[0].classList.contains('is-active')).toBe(true)

    // Alive: picking LOAD GAME moves the coral row and raises a toast.
    rows[1].click()
    await waitFor(() => expect(rows[1].classList.contains('is-active')).toBe(true))
    await waitFor(() => expect(canvasElement.querySelector('.core-toast')).not.toBeNull())

    // EXIT opens the dialog instead — it teleports to #core-overlays, outside the canvas.
    rows[3].click()
    await waitFor(() => expect(document.querySelector('.core-dialog')).not.toBeNull())
    document.querySelector('.core-dialog__close, .core-dialog button').click()
  },
}
