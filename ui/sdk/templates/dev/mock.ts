// <resource>/ui/dev/mock.ts — the fake Lua side of `npm run dev` (core DESIGN §38.11).
//
// This file never ships: `ui/dev/` is not in the resource's `files {}` and `npm run build` never
// looks at it. Everything here is what `client/main.lua` would do, so the page you develop in the
// browser is the page the game opens — same shell, same kit, same focus stack.

import { createMockTransport } from '@core/ui/dev'

/** The props Lua passes to `Core.UI.open('my_plugin', props)`. Keep it in one place: the page
 *  imports the same type with `usePage<MyPageProps>()`. */
export interface MyPageProps {
  title: string
  items: { id: string; label: string; count: number }[]
}

/** What the page may `nui.invoke(…)`: `{ name: { req, res } }`. */
interface MyRpc {
  buy: { req: { id: string; amount: number }; res: { ok: boolean; balance: number } }
}

/** `{ pageId: propsType }` — makes `lua.open('my_plugin', …)` type-checked. */
interface MyPages {
  my_plugin: MyPageProps
}

export const mock = createMockTransport<MyRpc, MyPages>()
export const { lua } = mock

export const initialProps: MyPageProps = {
  title: 'My plugin',
  items: [
    { id: 'water', label: 'Water', count: 2 },
    { id: 'bread', label: 'Bread', count: 1 },
  ],
}

// A request fake: the page's `await nui.invoke('buy', …)` lands here. `delayMs` is what a
// `Core.Callback.await` round trip feels like — good for testing the loading state.
let balance = 500
lua.onRequest('buy', ({ id, amount }) => {
  const cost = amount * 25
  if (cost > balance) throw new Error('not enough cash for ' + id)   // -> NuiError('handler_error')
  balance -= cost
  return { ok: true, balance }
}, { delayMs: 250 })

// What the page emits (`page.emit` / `nui.emit`) — Lua's `Core.UI.on(…)`.
lua.onEvent('my_plugin', 'closed', () => console.log('[mock] the page closed itself'))

/** Call `__dev.lua` helpers from the console while the page is open, e.g.
 *    __dev.lua.patch('my_plugin', 'items.1.count', 99)   // one leaf, not a re-send (§38.10)
 *    __dev.lua.patch('my_plugin', 'items.2')             // no value = delete the SECOND item
 *    __dev.lua.update('my_plugin', { title: 'Renamed' }) // shallow merge of top-level keys
 *    __dev.lua.emit('my_plugin', 'flash', { id: 'water' })
 *    __dev.lua.feed('my_plugin', { speed: 132 })         // useFeed(), one rAF per frame
 *  A path addresses the LUA table you passed to `open` — Lua's view, 1-based: exactly what
 *  `Core.UI.patch` takes in Lua. `items.1` is the FIRST item and `items.<length + 1>` appends. */
export function bumpFirstItem(): void {
  const first = initialProps.items[0]
  lua.patch('my_plugin', ['items', 1, 'count'], first.count + 1)
}
