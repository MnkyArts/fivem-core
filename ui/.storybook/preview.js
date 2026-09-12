// Storybook preview for the core NUI shell.
// Boots the same globals main.js does (window.Vue -> installCoreUI, then installGameBlur)
// so plugin pages can register through window.CoreUI and every `data-core-blur` panel gets
// its glass, paints a muted "game" backdrop behind the translucent panels, hands every story
// a freshly reset store, and taps the Lua wire (src/stories/luaBridge.js -> Actions panel +
// the custom "Lua" panel).
import * as Vue from 'vue'

window.Vue = Vue // must be set before installCoreUI(), exactly like main.js

import '../src/styles.css'
import { installCoreUI } from '../src/coreui.js'
import { installGameBlur } from '../src/gameblur.js'
import { resetStore } from '../src/stories/storeHelpers.js'
import { luaChannel, withoutLog } from '../src/stories/luaBridge.js'

installCoreUI()

// main.js installs this on #app; here it watches the whole preview body, so a story's panels
// get their glass wherever the story mounts them. There is no FiveM render hook in a browser,
// so the probe fails and the module falls back to its own gradient source
// (root <html> reports data-game-blur="fallback") — the same colours as GAME_BG below.
installGameBlur(document.body)

// The NUI page itself is transparent over GTA. Without something behind it the
// translucent panels (and the blurred copy `data-core-blur` puts behind them) cannot be
// judged, so the preview gets a dusk-street-ish gradient: cool key light top-left, warm
// sodium bounce bottom-right. The fallback blur source paints the same colours.
const GAME_BG = [
  'radial-gradient(1200px 720px at 18% 12%, rgba(108, 138, 184, 0.34), rgba(0, 0, 0, 0) 62%)',
  'radial-gradient(900px 620px at 86% 82%, rgba(198, 128, 68, 0.20), rgba(0, 0, 0, 0) 58%)',
  'radial-gradient(1500px 900px at 50% 118%, rgba(8, 11, 16, 0.88), rgba(0, 0, 0, 0) 68%)',
  'linear-gradient(168deg, #27323f 0%, #1b2330 38%, #131922 68%, #0b0f15 100%) #0b0f15',
].join(', ')

// styles.css makes html/body transparent for the CEF; the backgrounds addon only
// repaints `.sb-show-main` (the body), so <html> gets the same fill as a floor.
const floor = document.createElement('style')
floor.textContent = [
  'html { background: ' + GAME_BG + ' !important; }',
  // The MDX pages in src/stories/docs are mostly wide protocol tables. Storybook's docs CSS
  // lets a table grow past the page instead of wrapping, and every `code` span inside a cell
  // is nowrap, so both have to be undone or the last column runs off the right edge.
  '.sbdocs-content table { table-layout: fixed; width: 100%; }',
  '.sbdocs-content th, .sbdocs-content td { vertical-align: top; word-break: break-word; }',
  '.sbdocs-content td code, .sbdocs-content th code { white-space: normal; }',
].join('\n')
document.head.appendChild(floor)

export const parameters = {
  layout: 'fullscreen',
  backgrounds: {
    options: {
      game: { name: 'Game', value: GAME_BG },
      night: { name: 'Night', value: '#07090d' },
      noon: { name: 'Noon', value: 'linear-gradient(170deg, #9fb4c9 0%, #6d8399 60%, #4d5f72 100%) #4d5f72' },
    },
  },
  docs: {
    // One iframe per example. It has to be an iframe: `store.js` is a module singleton, so two
    // inline examples on one docs page would fight over the same `store.menu` and every canvas
    // would render the last one's state. Each iframe DOES run the story's play function (that
    // is not something the Story block can switch off), which is why the play functions below
    // re-send their message at the end — the example stays interactive afterwards.
    story: { inline: false, height: '460px' },
  },
  options: {
    storySort: {
      order: ['Docs', ['Introduction', 'Protocol', 'Plugin Pages'], 'Shell', 'Built-ins', '*'],
    },
  },
}

export const initialGlobals = {
  backgrounds: { value: 'game' },
}

// Every story gets an autodocs page (title + description + Controls + the Lua snippet).
export const tags = ['autodocs']

// Outermost first: one clean shell per story, then the Lua taps. The reset runs OUTSIDE the
// taps so its own `*:close` messages are muted instead of landing in the Lua panel. Both
// return `storyFn()` untouched, so the vue3 renderer short-circuits the wrappers entirely
// (decorateStory: decorated === story).
export const decorators = [
  luaChannel,
  (storyFn) => {
    withoutLog(resetStore)
    return storyFn()
  },
]
