// Fixture: the dev-host entry `npm run dev` serves. The boot stamp is how the browser smoke test
// tells an HMR patch (same stamp) from a full reload (new stamp).
import { createDevHost } from '@core/ui/dev'
import plugin from '../src/index.ts'
import { initialProps, mock } from './mock.ts'

;(window as unknown as { __boot: number }).__boot ||= Date.now() + Math.random()

createDevHost({
  id: 'alpha',
  plugin,
  mock,
  pages: { alpha: 'page', alpha_lazy: 'modal' },
  props: { alpha: initialProps, alpha_lazy: initialProps },
  open: 'alpha',
  background: 'game',
})
