// Kit/Showcase Inventory — mockup 3 rebuilt from kit components only (DESIGN §37.7).
// The completeness proof for the inventory screen: category CoreMenu, CoreSlotGrid, the inline
// CoreSelect, the capacity CoreProgress and the detail panel, all alive (select a slot, sort the
// bag, press USE). Art in stories/kit/assets is Storybook-only and never reaches html/.
import { h } from 'vue'
import { within, expect, waitFor, userEvent } from 'storybook/test'
import ShowcaseInventory from './scenes/ShowcaseInventory.vue'

export default {
  title: 'Kit/Showcase/Inventory',
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Mockup 3 at 1920 × 1080, built from `<Core…>` tags, Tailwind layout utilities and the '
          + 'base type classes — no custom CSS and no literal colours. Click a slot to re-read the detail '
          + 'panel, switch a category to filter the bag, change SORT to re-order it, press USE for a CoreToast.',
      },
      story: { inline: false, height: '1000px' },
    },
  },
}

export const Screen = {
  render: () => ({ setup: () => () => h(ShowcaseInventory) }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvasElement.querySelector('.core-screen')).not.toBeNull())

    // The frame of the mockup: header, three panels, footer.
    expect(canvasElement.querySelector('.core-screen__header')).not.toBeNull()
    expect(canvasElement.querySelector('.core-screen__footer')).not.toBeNull()
    expect(canvasElement.querySelectorAll('.core-panel').length).toBe(3)
    expect(canvasElement.querySelectorAll('.core-slot').length).toBe(12)
    await waitFor(() => expect(canvas.getByText('Med Kit')).toBeInTheDocument())

    // Selecting a slot re-reads the detail panel.
    const slots = canvasElement.querySelectorAll('.core-slot')
    await userEvent.click(slots[1])
    await waitFor(() => expect(canvas.getByText('Water Bottle')).toBeInTheDocument())
    expect(slots[1].classList.contains('is-selected')).toBe(true)

    // The category menu filters the grid down to the weapons.
    const weapons = canvas.getByRole('menuitem', { name: /weapons/i })
    await userEvent.click(weapons)
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-slot:not(.is-empty)').length).toBe(2))
  },
}
