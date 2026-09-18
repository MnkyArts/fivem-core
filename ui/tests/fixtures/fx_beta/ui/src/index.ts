// fx_beta — the SECOND plugin (core DESIGN §38.15).
//
// Its whole job is coexistence: two resources own two modules, two stylesheets, two scopes and two
// channels in ONE document. Whatever fx_alpha does — fail, crash, restart, unregister — fx_beta's
// page must keep rendering and its listeners must keep firing.
import { defineUIPlugin, definePage } from '@core/ui'
import Page from './Page.vue'

export interface BetaProps { title?: string }

export interface BetaCounters { evals: number; setups: number; disposes: number; hits: number; opens: number }

const bag = ((globalThis as unknown as { __fx?: Record<string, unknown> }).__fx ||= {})
export const counters: BetaCounters = ((bag as Record<string, unknown>).beta ||= {
  evals: 0, setups: 0, disposes: 0, hits: 0, opens: 0,
}) as BetaCounters

counters.evals++

export default defineUIPlugin({
  pages: {
    // `onOpen` must run exactly ONCE per open cycle, including when `page:open` arrived before this
    // module had even been fetched (§38.6 F2) — that is what `opens` is counted for.
    fx_beta: definePage<BetaProps>({ component: Page, onOpen() { counters.opens++ } }),
  },

  setup(ctx) {
    counters.setups++
    ctx.nui.handle('who', () => ({ id: ctx.id, generation: ctx.generation }))
    ctx.scope.listen(window, 'fx-beta-probe', () => { counters.hits++ })
    return () => { counters.disposes++ }
  },
})
