// Kit/Showcase/HUD — mockup 2 rebuilt from kit components only (DESIGN §37.7).
import { h } from 'vue'
import { expect, waitFor } from 'storybook/test'
import ShowcaseHud from './scenes/ShowcaseHud.vue'

export default {
  title: 'Kit/Showcase/HUD',
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The second mockup — the HUD over the live game — rebuilt with nothing but globally '
          + 'registered `<Core…>` tags and Tailwind layout utilities. CoreStatBar rows on a `bg-hud` plate, '
          + 'CoreCompass on the centre line, a `dark` CoreTag clock, CoreTracker under the minimap, two '
          + 'CorePrompts on the truck and the CoreHotbar on the bottom edge. The minimap is a PLACEHOLDER: '
          + 'the round map belongs to the game, the CEF only leaves the hole. The demo strip bottom left is '
          + 'not in the mockup — it is what makes the vitals and the compass move.',
      },
      story: { inline: false, height: '1080px' },
    },
  },
}

export const Screen = {
  render: () => ({ setup: () => () => h(ShowcaseHud) }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-compass')).not.toBeNull())

    // Every piece of the mockup is a kit component.
    expect(canvasElement.querySelector('.core-bg--vignette')).not.toBeNull()
    expect(canvasElement.querySelectorAll('.core-statbar').length).toBe(3)
    expect(canvasElement.querySelector('.core-tag--dark')).not.toBeNull()
    expect(canvasElement.querySelector('.core-tracker')).not.toBeNull()
    expect(canvasElement.querySelectorAll('.core-prompt').length).toBe(2)
    expect(canvasElement.querySelectorAll('.core-hotbar .core-slot').length).toBe(4)

    // HUD furniture never takes the mouse (§37.4) — the hotbar and the demo strip do.
    expect(getComputedStyle(canvasElement.querySelector('.core-tracker')).pointerEvents).toBe('none')

    // Alive: a hit moves the bars, a hotbar cell selects and raises a toast.
    const full = canvasElement.querySelector('.core-statbar__fill').style.width
    canvasElement.querySelectorAll('.core-btn')[0].click()
    await waitFor(() => expect(canvasElement.querySelector('.core-statbar__fill').style.width).not.toBe(full))
    await waitFor(() => expect(canvasElement.querySelector('.core-toast')).not.toBeNull())

    const cells = canvasElement.querySelectorAll('.core-hotbar .core-slot')
    cells[2].click()
    await waitFor(() => expect(cells[2].classList.contains('is-selected')).toBe(true))
  },
}
