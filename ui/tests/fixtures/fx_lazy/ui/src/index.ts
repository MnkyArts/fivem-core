// fx_lazy — a plugin built with `coreUI({ load: 'lazy' })` (core DESIGN §38.15).
//
// `manifest.load = 'lazy'` means the shell records the registration and imports NOTHING until the
// first `page:open` of one of its pages. The counter below is therefore the assertion: it stays 0
// after `plugin:register`, and the server must have seen no request for the entry either.
import { defineUIPlugin, definePage } from '@core/ui'
import Page from './Page.vue'

export interface LazyCounters { evals: number; setups: number }

const bag = ((globalThis as unknown as { __fx?: Record<string, unknown> }).__fx ||= {})
export const counters: LazyCounters = ((bag as Record<string, unknown>).lazy ||= { evals: 0, setups: 0 }) as LazyCounters

counters.evals++

export default defineUIPlugin({
  pages: { fx_lazy: definePage({ component: Page }) },
  setup() { counters.setups++ },
})
