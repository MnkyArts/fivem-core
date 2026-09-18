// fx_api2 — a plugin built for a DIFFERENT core UI API version (core DESIGN §38.12).
//
// It is built normally (so it is a real, working bundle) and `ui/tests/build-fixtures.mjs` then
// rewrites the `2` into both places the gate looks at:
//   1. manifest.json `apiVersion`  — checked before the import, in Lua and again in the shell,
//   2. the `apiVersion: 1` the SDK stamped into the bundle — the second gate, after evaluation.
// The expected outcome is state `incompatible` (not `failed`) and a message naming BOTH numbers.
import { defineUIPlugin, definePage } from '@core/ui'
import Page from './Page.vue'

export default defineUIPlugin({
  pages: { fx_api2: definePage({ component: Page }) },
  setup(ctx) {
    ctx.log('fx_api2 must never reach setup')
  },
})
