# Kit stories — how to write one (DESIGN §37.7)

One `<Name>.stories.js` per component, its scenes in `scenes/`, art in `assets/` (Storybook and the dev harness only — never in `html/`).

```js
import { h } from 'vue'
import CoreButton from '../../kit/components/CoreButton.vue'   // Playground only
import ButtonGallery from './scenes/ButtonGallery.vue'

export default {
  title: 'Kit/Actions/Button',          // groups: Actions Surfaces Navigation Forms Data Game Feedback
  component: CoreButton,
  parameters: {
    layout: 'fullscreen',
    docs: { description: { component: 'One paragraph: what it is for and when NOT to use it.' } },
  },
  argTypes: { variant: { control: 'select', options: ['primary', 'secondary', 'ghost'] } },
  args: { variant: 'primary', size: 'md' },
}

export const Playground = {
  render: (args) => ({ setup: () => () => h(CoreButton, { ...args }, () => 'Use') }),
}

export const Gallery = { render: () => ({ setup: () => () => h(ButtonGallery) }) }
```

* **CSF3, plain JS, no template strings** — the shipped bundle has no runtime template compiler, so
  a story is `h()` or a compiled scene SFC. `render` returns a component *options object*.
* **Controls stay live only if the args are read inside the render function.** The vue3 renderer
  mutates one reactive args proxy instead of remounting (the `liveScene` note in
  `../storeHelpers.js`), so spread `{ ...args }` in the returned render function, never above it.
* Enums get `options`; a `play` proving the interactive contract (click, `v-model`, Escape) is welcome.

## Scenes

* `scenes/<Name>Gallery.vue`, built from `scenes/KitStage.vue` (`title`, `description`, `width`,
  `center`, `padded`) and `scenes/KitSection.vue` (`label`, `layout: row|column|grid`, `columns`,
  `gap`, `note`). Import those two — they are story plumbing, not kit components.
* Everything else is a **global tag** — `<CoreButton>`, `<CoreIcon>`, no import at all: exactly how a
  plugin page uses the kit (`installKit` registers them on the one app). Art:
  `import keyart from '../assets/keyart.jpg'`.
* Tokens and `.core-*` classes only; layout utilities are fine. No literal colour, font or radius,
  no transform utility family (Tailwind v4 emits the individual properties and Chromium 103 drops
  them — write `transform:` in the group's CSS partial), and glass is the `blur` prop.

## Preview one scene without Storybook

```
cd ui && npx vite --port 5311            # Vite binds localhost, not 127.0.0.1
http://localhost:5311/kit-preview.html?scene=ButtonGallery&bg=game|keyart|menu|ink|none
```

No `scene` lists every scene it found. One page = one scene, so a screenshot is reproducible, and a
failed import is drawn on the page in red instead of only in the console. Add `&scroll=page` for a
`screenshot --full` of a tall gallery: the default root is the shell's own `fixed inset-0` one, so
the document never grows and a full-page capture would stop at the first viewport.

## Before handing back

`node ui/tests/kit-compile-check.mjs ui/src/stories/kit ui/src/kit` → 0 errors: it compiles every SFC,
syntax-checks the JS and lints the CSS for the Chromium 103 list of §37.4. It touches nothing, so it is
safe while another agent is still building (`npm run build` would empty `html/`).
