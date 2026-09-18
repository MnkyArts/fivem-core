// Fixture plugin entry — the shape DESIGN §38.7 documents, used by the SDK's build tests and by
// the browser smoke test of the dev host. The counters on `window.__alpha` are what proves a
// restart disposed the previous activation instead of stacking a second one on top.
import { defineUIPlugin, definePage } from '@core/ui'
import Page from './Page.vue'

interface AlphaProps { label: string }

interface AlphaProbe { setups: number; disposes: number; live: number; pings: number }

const probe: AlphaProbe = ((globalThis as unknown as { __alpha?: AlphaProbe }).__alpha
  ||= { setups: 0, disposes: 0, live: 0, pings: 0 })

export default defineUIPlugin({
  pages: {
    alpha: definePage<AlphaProps>({
      component: Page,
      onOpen(page) { page.emit('opened', { id: page.id }) },
    }),
    alpha_lazy: () => import('./Lazy.vue'),
  },
  setup(ctx) {
    probe.setups += 1
    probe.live += 1
    ctx.nui.on('ping', () => { probe.pings += 1 })
    return () => {
      probe.disposes += 1
      probe.live -= 1
      ctx.log('disposed')
    }
  },
})
