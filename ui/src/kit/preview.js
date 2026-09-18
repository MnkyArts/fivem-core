// core UI kit — the dev harness behind ui/kit-preview.html (DESIGN §37.7).
//
//   http://127.0.0.1:<port>/kit-preview.html?scene=<SceneName>&bg=game|keyart|menu|ink|none
//
// Mounts exactly one scene SFC from `src/stories/kit/scenes/` with the kit installed, the way an
// implementer or a reviewer screenshots a component next to the mockup. Without `scene` it lists
// every scene it can find. `scene`/`bg` are QUERY parameters on purpose: changing one reloads the
// page (a hash change would not), so every screenshot starts from a clean app.
//
// Dev server only — Vite's build input is index.html, so nothing here ever reaches `html/`.
//
// Same boot order as src/main.js: `window.Vue` first, then installCoreUI (pages read
// `window.CoreUI`), installKit before the mount, installGameBlur after it so `blur` props show
// real glass — in a browser the probe fails and gameblur.js falls back to its own gradient.
import * as Vue from 'vue'

window.Vue = Vue

import '../styles.css'
import { installCoreUI } from '../coreui.js'
import { installGameBlur } from '../gameblur.js'
import keyartUrl from '../stories/kit/assets/keyart.jpg'
import keyartMenuUrl from '../stories/kit/assets/keyart-menu.jpg'

const { h, markRaw, reactive, createApp } = Vue

// LAZY glob: one broken scene must not take the whole harness (and everyone else's preview)
// down with it — the import only runs for the scene that was actually asked for.
const loaders = import.meta.glob('../stories/kit/scenes/*.vue')
const scenes = {}
for (const file of Object.keys(loaders)) {
  scenes[file.slice(file.lastIndexOf('/') + 1, -4)] = loaders[file]
}

const params = new URLSearchParams(window.location.search)
const sceneName = (params.get('scene') || '').trim()
const bg = (params.get('bg') || 'game').trim()
// The shell's root is `fixed inset-0` and scrolls inside itself, so the DOCUMENT never grows and a
// full-page screenshot only ever captures one viewport. `&scroll=page` lets the root grow with its
// content instead — one `agent-browser screenshot --full` then holds the whole gallery.
const pageScroll = params.get('scroll') === 'page'

// The same stack .storybook/preview.js paints (and the same colours gameblur.js falls back to):
// a dusk street — cool key light top left, warm sodium bounce bottom right. The NUI itself is
// transparent over GTA, so a translucent panel cannot be judged without something behind it.
const GAME_BG = [
  'radial-gradient(1200px 720px at 18% 12%, rgba(108, 138, 184, 0.34), rgba(0, 0, 0, 0) 62%)',
  'radial-gradient(900px 620px at 86% 82%, rgba(198, 128, 68, 0.20), rgba(0, 0, 0, 0) 58%)',
  'radial-gradient(1500px 900px at 50% 118%, rgba(8, 11, 16, 0.88), rgba(0, 0, 0, 0) 68%)',
  'linear-gradient(168deg, #27323f 0%, #1b2330 38%, #131922 68%, #0b0f15 100%) #0b0f15',
].join(', ')

const state = reactive({ component: null, error: null })

function fail (err, what) {
  console.error('[kit-preview] ' + what, err)
  state.error = (err && err.stack) || String(err)
}

/** Behind everything, click-through; `none` leaves the page transparent. Fixed to the viewport
 *  like the game is — except under `scroll=page`, where it has to cover the whole tall page
 *  instead, or a full-page screenshot ends on bare white below the first screen. */
function backgroundNode () {
  if (bg === 'none') return null
  const style = { position: pageScroll ? 'absolute' : 'fixed', inset: '0', zIndex: '0', pointerEvents: 'none' }
  if (bg === 'ink') style.background = '#060b0f'
  else if (bg === 'keyart' || bg === 'menu') {
    style.backgroundImage = 'url(' + (bg === 'menu' ? keyartMenuUrl : keyartUrl) + ')'
    style.backgroundSize = 'cover'
    style.backgroundPosition = 'center'
  } else style.background = GAME_BG
  return h('div', { class: 'core-kit-preview__bg', style })
}

/** Errors land on the PAGE, not only in the console — a screenshot has to show them. */
function errorNode () {
  return h('pre', {
    style: {
      position: 'relative',
      zIndex: '2',
      margin: '32px',
      padding: '16px 18px',
      maxWidth: '1100px',
      border: '1px solid #ff4560',
      borderRadius: '4px',
      background: 'rgba(255, 69, 96, 0.10)',
      color: '#ff9aa6',
      font: '400 12px/1.6 ui-monospace, Consolas, monospace',
      whiteSpace: 'pre-wrap',
      overflowX: 'auto',
    },
  }, state.error)
}

const linkStyle = {
  display: 'block',
  padding: '9px 14px',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui-sm)',
  background: 'var(--color-panel)',
  color: 'var(--color-fg)',
  textDecoration: 'none',
}

function indexNode () {
  // KitStage / KitSection are the frame every gallery is built from, not scenes of their own —
  // they render as an empty page. They stay loadable by URL, they are just not worth listing.
  const names = Object.keys(scenes).filter((name) => name !== 'KitStage' && name !== 'KitSection').sort()
  const backgrounds = ['game', 'keyart', 'menu', 'ink', 'none']
  return h('div', { style: { position: 'relative', zIndex: '1', padding: '40px', maxWidth: '1100px' } }, [
    h('p', { class: 'core-eyebrow' }, 'core ui kit'),
    h('h1', { class: 'core-display core-display--lg', style: { margin: '8px 0 0' } }, 'Scene preview'),
    h('div', { style: { width: '28px', height: '3px', margin: '14px 0 18px', background: 'var(--color-accent)' } }),
    h('p', { class: 'core-text', style: { maxWidth: '74ch' } },
      'One scene per page: ?scene=<SceneName>&bg=' + backgrounds.join('|') + '. '
      + 'Scenes live in src/stories/kit/scenes and are the same SFCs the Gallery stories render. '
      + 'Add &scroll=page when you want one full-page screenshot of a tall gallery — the default root '
      + 'is the shell’s own fixed, self-scrolling one.'),
    h('p', { class: 'core-label', style: { margin: '26px 0 10px' } }, 'background — ' + bg),
    h('div', { style: { display: 'flex', flexWrap: 'wrap', gap: '8px' } }, backgrounds.map((name) => h('a', {
      href: '?' + (sceneName ? 'scene=' + encodeURIComponent(sceneName) + '&' : '') + 'bg=' + name,
      style: Object.assign({}, linkStyle, name === bg
        ? { borderColor: 'var(--color-accent)', color: 'var(--color-accent)' }
        : null),
    }, name))),
    h('p', { class: 'core-label', style: { margin: '26px 0 10px' } }, names.length + ' scene(s)'),
    names.length
      ? h('div', {
        style: {
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fill, minmax(240px, 1fr))',
          gap: '8px',
        },
      }, names.map((name) => h('a', {
        href: '?scene=' + encodeURIComponent(name) + '&bg=' + encodeURIComponent(bg),
        style: linkStyle,
      }, name)))
      : h('p', { class: 'core-flavor' }, 'No scenes in src/stories/kit/scenes yet.'),
  ])
}

const Root = {
  setup () {
    return () => h('div', {
      class: 'core-root pointer-events-auto text-fg antialiased '
        + (pageScroll ? 'relative min-h-screen' : 'fixed inset-0 overflow-auto'),
    }, [
      backgroundNode(),
      state.error
        ? errorNode()
        : h('div', { style: { position: 'relative', zIndex: '1', minHeight: '100%' } }, [
          state.component ? h(state.component) : (sceneName ? null : indexNode()),
        ]),
      // §37.3: the Teleport target of every kit popup, inside .core-root so §31 hides it too.
      h('div', { id: 'core-overlays', class: 'core-overlays' }),
    ])
  },
}

async function boot () {
  const CoreUI = installCoreUI()

  // Both belong to the design-system run and may still be half-written in a parallel session;
  // a dynamic import keeps the harness (and the scene list) alive when one of them is not there.
  try { await import('./fonts.css') } catch (err) { console.warn('[kit-preview] no kit/fonts.css yet', err) }
  let kit = null
  try { kit = await import('./index.js') } catch (err) { fail(err, 'kit/index.js failed to load') }

  if (sceneName) {
    const loader = scenes[sceneName]
    if (!loader) {
      fail('Unknown scene "' + sceneName + '".\nKnown scenes: ' + (Object.keys(scenes).sort().join(', ') || '(none)'),
        'unknown scene')
    } else {
      try {
        const module = await loader()
        // markRaw: a component in a reactive object would be proxied, and Vue warns about it.
        state.component = markRaw(module.default || module)
      } catch (err) { fail(err, 'scene "' + sceneName + '" failed to load') }
    }
  }

  const app = createApp(Root)
  app.config.errorHandler = (err, instance, info) => fail(err, 'vue error (' + info + ')')
  if (kit && typeof kit.installKit === 'function') kit.installKit(app)
  app.mount('#app')

  // styles.css pins html, body AND #app to the viewport (`position: fixed; inset: 0;
  // overflow: hidden` — the CEF page never scrolls). `scroll=page` has to undo all three or the
  // document still cannot grow past one screen and `screenshot --full` keeps returning one viewport.
  if (pageScroll) {
    for (const el of [document.documentElement, document.body]) {
      el.style.height = 'auto'
      el.style.overflow = 'visible'
    }
    const app = document.getElementById('app')
    app.style.position = 'static'
    app.style.overflow = 'visible'
  }

  if (kit) CoreUI.kit = { components: kit.components, registerIcons: kit.registerIcons, icons: kit.ICONS }
  CoreUI.gameBlur = installGameBlur(document.getElementById('app'))
  document.title = 'kit — ' + (sceneName || 'scenes')
}

boot()
