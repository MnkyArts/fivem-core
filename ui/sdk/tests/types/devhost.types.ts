// Type-level test for `@core/ui/dev` (DESIGN §38.11). Nothing here runs — `vue-tsc --noEmit -p
// ui/tsconfig.json` is the assertion, and every `@ts-expect-error` FAILS the run when the error it
// expects stops happening.
//
// This mirrors `ui/sdk/templates/dev/{mock,host}.ts` line for line, because that pair is what every
// plugin copies: an interface-based Rpc map and an interface-based page map, wired through
// `createDevHost({ mock })`. Both were rejected before (`Rpc` was pinned to `never`, `Pages` was
// constrained to `Record<string, object>`), which is exactly what a plugin hits first.

import { defineUIPlugin } from '../../src/index.ts'
import { createDevHost, createMockTransport } from '../../src/dev/index.ts'

interface MyPageProps {
  title: string
  items: { id: string; label: string; count: number }[]
}

interface MyRpc {
  buy: { req: { id: string; amount: number }; res: { ok: boolean; balance: number } }
}

interface MyPages {
  my_plugin: MyPageProps
}

const mock = createMockTransport<MyRpc, MyPages>()
const { lua } = mock

const initialProps: MyPageProps = { title: 'My plugin', items: [] }

// The request fake: `data` and the return type both come from MyRpc.
lua.onRequest('buy', ({ id, amount }) => {
  void id
  return { ok: true, balance: amount * 25 }
}, { delayMs: 250 })

const plugin = defineUIPlugin({ pages: { my_plugin: {} } })

// ---------------------------------------------------------------- what must compile

const dev = createDevHost({
  id: 'my_plugin',
  plugin,
  mock,
  pages: { my_plugin: 'page' },
  props: { my_plugin: initialProps },
  open: 'my_plugin',
  background: 'game',
})

dev.open('my_plugin', initialProps)
dev.close('my_plugin')
void dev.restart()
const generation: number = dev.generation()

dev.lua.open('my_plugin', initialProps)
dev.lua.update('my_plugin', { title: 'Renamed' })
dev.lua.patch('my_plugin', 'items.1.count', 99)   // Lua's view, 1-based (§38.10)
dev.lua.patch('my_plugin', ['items', 2])          // no value = delete the second item
dev.lua.emit('my_plugin', 'flash', { id: 'water' })
dev.lua.feed('my_plugin', { speed: 132 })
void dev.lua.request('my_plugin', 'refresh')
dev.lua.onEvent('my_plugin', 'closed', () => {})
const host: number = dev.host.apiVersion
void generation
void host

// No generics at all still works (the defaults).
const loose = createDevHost({ id: 'other', plugin })
loose.open('whatever')

// ---------------------------------------------------------------- what must NOT compile

// @ts-expect-error — no such page id
dev.lua.open('nope', initialProps)

// @ts-expect-error — wrong props for my_plugin
dev.lua.open('my_plugin', { title: 42, items: [] })

// @ts-expect-error — wrong props in the host options
createDevHost({ id: 'my_plugin', plugin, mock, props: { my_plugin: { title: 1, items: [] } } })

// @ts-expect-error — `open` must name a declared page
createDevHost({ id: 'my_plugin', plugin, mock, open: 'nope' })

// @ts-expect-error — no such rpc name
lua.onRequest('nothing', () => 1)

// @ts-expect-error — `buy` answers { ok: boolean; balance: number }
lua.onRequest('buy', () => ({ ok: 'yes', balance: 1 }))
