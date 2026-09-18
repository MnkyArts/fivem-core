// Fixture: the fake Lua side of the dev host (never built, never shipped).
import { createMockTransport } from '@core/ui/dev'

export interface AlphaProps {
  label: string
  items: { id: string; count: number }[]
}
interface AlphaRpc { echo: { req: { text: string }; res: { text: string } } }
interface AlphaPages { alpha: AlphaProps; alpha_lazy: AlphaProps }

export const mock = createMockTransport<AlphaRpc, AlphaPages>()

mock.lua.onRequest('echo', ({ text }) => ({ text: text.toUpperCase() }), { delayMs: 10 })

export const initialProps: AlphaProps = {
  label: 'dev',
  items: [{ id: 'a', count: 1 }, { id: 'b', count: 2 }],
}
