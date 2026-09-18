// Kit/Foundations — the three reference sheets of the design system (DESIGN §37.2, §37.7):
// what a colour token resolves to, what a type voice looks like, and which icons exist.
//
// Every story renders a compiled scene SFC from ./scenes — the shipped bundle has no runtime
// template compiler, so a story is `h()` or a scene, never a template string. The same scenes are
// reachable without Storybook through the dev harness:
//   ui/kit-preview.html?scene=FoundationsColors&bg=game
import { h } from 'vue'
import FoundationsColors from './scenes/FoundationsColors.vue'
import FoundationsType from './scenes/FoundationsType.vue'
import FoundationsIcons from './scenes/FoundationsIcons.vue'

/** CSF3 `render` for a scene with no controls: mount it, nothing else. */
const scene = (component) => () => ({ setup: () => () => h(component) })

export default {
  title: 'Kit/Foundations/Tokens',
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The layer under every component. Tokens live in the `@theme` block of '
          + '`src/styles.css` and are used as Tailwind utilities (`bg-panel`, `text-fg-dim`, '
          + '`border-border`, `rounded-ui`, `text-ui-sm`, `font-display`) or as `var(--…)` inside a '
          + 'kit CSS partial. A page never writes a literal colour, font family or radius: re-theming '
          + 'a server means overriding `--color-accent*`, `--core-accent-rgb` and the three accent '
          + 'gradients, and everything else follows.',
      },
      story: { inline: false, height: '760px' },
    },
  },
}

export const Colors = {
  name: 'Colour',
  render: scene(FoundationsColors),
  parameters: {
    docs: {
      description: {
        story: 'Every swatch prints the value the browser resolved, so a token that is missing or '
          + 'mistyped reads as "not defined" here instead of as an invisible control in game. The '
          + 'weave behind a swatch shows how translucent it is — panels sit over the game, not over black.',
      },
    },
  },
}

export const Type = {
  name: 'Type',
  render: scene(FoundationsType),
  parameters: {
    docs: {
      description: {
        story: 'Barlow Condensed for anything uppercase and tracked (headings, buttons, tabs, menu rows, '
          + 'labels, numbers), Barlow for body copy. Both are bundled under `src/kit/fonts` because the '
          + 'CEF cannot fetch the web — reach them through `--font-display` / `--font-sans`, never by name.',
      },
    },
  },
}

export const Icons = {
  name: 'Icons',
  render: scene(FoundationsIcons),
  parameters: {
    docs: {
      description: {
        story: 'The whole registry with a filter box. Find a name here before inventing one; a plugin '
          + 'adds its own with `window.CoreUI.kit.registerIcons({ "my-icon": "M…" })` (24 × 24 path data) '
          + 'or passes raw path data to any `icon` prop.',
      },
    },
  },
}
