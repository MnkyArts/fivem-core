// my_plugin — the fake Lua side of `npm run dev` (core DESIGN §38.11).
//
// Everything here is what `client/main.lua` would do, so the page you develop in the browser is the
// page the game opens: same shell, same kit, same focus stack. Never shipped.
//
// The types come from src/index.ts — one declaration for the page, the mock and Lua's contract.
import { createMockTransport } from '@core/ui/dev'
import type { MyPluginIncoming, MyPluginProps, MyPluginRpc } from '../src/index.ts'

/** `{ pageId: propsType }` — makes `lua.open('my_plugin', …)` and `lua.update` type-checked. */
interface MyPluginPages {
  my_plugin: MyPluginProps
}

export const mock = createMockTransport<MyPluginRpc, MyPluginPages>()
export const { lua } = mock

/** What `Core.UI.open('my_plugin', props)` passes. */
export const initialProps: MyPluginProps = {
  title: 'props of Core.UI.open show up here',
}

// A request fake: the page's `await nui.invoke('ping')` lands here. `delayMs` is what a
// `Core.Callback.await` round trip feels like — the right way to see a loading state.
lua.onRequest('ping', () => ({ pong: true }), { delayMs: 200 })

// What the page emits (`page.emit` / `nui.emit`) — Lua's `Core.UI.on('my_plugin', …)`. Answering
// with `lua.emit` is `Core.UI.send` and closes the loop.
lua.onEvent('my_plugin', 'hello', (data) => {
  console.log('[mock] hello', data)
  const reply: MyPluginIncoming['greeting'] = { text: 'Hello from the mock Lua side' }
  lua.emit('my_plugin', 'greeting', reply)
})

/** Console helpers while the page is open — `__dev.lua` is the same object:
 *    __dev.lua.update('my_plugin', { title: 'Renamed' })   // shallow merge of top-level keys
 *    __dev.lua.patch('my_plugin', 'title', 'One leaf')     // one leaf, not a re-send (§38.10)
 *    __dev.lua.emit('my_plugin', 'greeting', { text: 'hi' })
 *    __dev.lua.close('my_plugin')
 *  A patch path addresses the LUA table passed to `open` — Lua's view, 1-based: `items.1` is the
 *  FIRST element and `items.<length + 1>` appends. */
