// fx_alpha — the main integration fixture (core DESIGN §38.15).
//
// Everything the runtime suite has to observe is COUNTED on `window.__fx.alpha` (see state.ts),
// because that is the only way to tell the three lifecycles apart from outside:
//   evals     module evaluation — once per URL, for the life of the page (§38.2)
//   setups    one per activation (every `plugin:register` with a new generation)
//   disposes  one per teardown (`plugin:unregister`, a newer generation, a hot re-activation)
//   hits      the `ctx.scope.listen` handler — a restart that leaked a listener counts twice
//
// MODULE SCOPE IS FOR DEFINITIONS ONLY: the only side effect is `evals++` in state.ts, which is
// exactly the thing a test needs to prove the rule holds.
import { defineUIPlugin, definePage } from '@core/ui'
import Page from './Page.vue'
import Hud from './Hud.vue'
import Confirm from './Confirm.vue'
import Shallow from './Shallow.vue'
import Bench from './Bench.vue'
import { VARIANT, counters } from './state.ts'

export { VARIANT, counters }

export interface AlphaProps {
  label?: string
  /** Set by the test: renders a child that throws while rendering (§38.12 crash isolation). */
  crash?: boolean
  slots?: unknown
  nested?: Record<string, unknown>
}

export type AlphaEvents = { hello: { at: number } }
export type AlphaIncoming = { ping: { n: number } }
export type AlphaRpc = { echo: { req: unknown; res: unknown } }

export default defineUIPlugin({
  pages: {
    fx_alpha: definePage<AlphaProps>({
      component: Page,
      onOpen() { counters.opens++ },
      onUpdate(_page, changed) { counters.updates++; counters.changed = changed.slice() },
      onClose() { counters.closes++ },
    }),
    fx_alpha_hud: definePage({ component: Hud }),
    fx_alpha_confirm: definePage({ component: Confirm }),
    // The other half of the patch contract: shallowReactive props + copy-on-write (§38.10).
    fx_alpha_shallow: definePage({ component: Shallow, reactivity: 'shallow' }),
    // ui/tests/bench.mjs: the same 200-slot page in both patch modes.
    fx_alpha_bench: definePage({ component: Bench }),
    fx_alpha_bench_shallow: definePage({ component: Bench, reactivity: 'shallow' }),
    // A page whose component is a LOADER: its chunk must not be fetched before the page opens.
    fx_alpha_lazy: definePage({ component: () => import('./Lazy.vue') }),
  },

  setup(ctx) {
    counters.setups++
    ctx.log('activated', ctx.generation, VARIANT)

    // Lua -> plugin channel (`Core.UI.send('fx_alpha', 'ping', …)`).
    ctx.nui.on('ping', (data: unknown) => {
      counters.pings++
      counters.lastPing = data
    })
    // Lua -> plugin request (`Core.UI.request('fx_alpha', 'echo', …)`).
    ctx.nui.handle('echo', (data: unknown) => ({ echoed: data, variant: VARIANT }))

    // An error with NO component tree around it: the shell can only attribute it by the origin in
    // its stack (§38.12). `scope.timeout` removes its own hook before it calls back, so the throw
    // escapes to `window.onerror` and the scope counts stay where they were.
    ctx.nui.on('boom-timer', () => {
      ctx.scope.timeout(() => { throw new Error('fx_alpha: timer callback exploded on purpose') }, 0)
    })

    // The scope's own bookkeeping: a restart that forgot to dispose counts two hits per event.
    ctx.scope.listen(window, 'fx-alpha-probe', () => { counters.hits++ })
    ctx.scope.interval(() => { counters.ticks++ }, 60000)

    return () => { counters.disposes++ }
  },
})
