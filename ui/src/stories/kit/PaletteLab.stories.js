// Kit/Foundations/Palette Lab — every candidate second colour next to the coral, side by side
// (src/lab/palette.js, dev only; not part of DESIGN §37 until one is picked). The toolbar's
// "Palette" / "Roles" menus apply the same lab to every OTHER story, e.g. the showcases.
//
// Also reachable without Storybook: ui/kit-preview.html?scene=PaletteLab&roles=split
import { h } from 'vue'
import PaletteLab from './scenes/PaletteLab.vue'

export default {
  title: 'Kit/Foundations/Palette Lab',
  parameters: {
    layout: 'fullscreen',
    // The columns carry their own lab; a page-wide one from the toolbar would fight them.
    paletteLab: false,
    docs: {
      description: {
        component: 'The kit has one accent and gives it five jobs: brand marks, the primary button, '
          + 'selection, form controls and focus. Each column hands some of those jobs to a second '
          + 'colour; the coral keeps the rest. Pick "Light", "Split" or "Swap" on the page, or use the '
          + '"Palette" and "Roles" toolbar menus on any other story (the showcases are the real test).',
      },
      story: { inline: false, height: '1500px' },
    },
  },
}

export const SideBySide = {
  name: 'Side by side',
  render: () => ({ setup: () => () => h(PaletteLab) }),
}
