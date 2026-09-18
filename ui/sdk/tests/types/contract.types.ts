// Type-level test for the SDK's public generics (DESIGN §38.7). Nothing here runs: `vue-tsc
// --noEmit -p ui/tsconfig.json` is the assertion, and every `@ts-expect-error` line FAILS the run
// when the error it expects stops happening.
//
// The point: a plugin declares its props, events and rpc map as INTERFACES — which is what the
// platform's own examples show — and an interface has no implicit index signature, so a
// `Record<string, …>` constraint would reject it.

import { defineUIPlugin, definePage, useNui, usePage } from '../../src/index.ts'
import type { NuiHandle, PageHandle } from '../../src/index.ts'

interface InventoryProps {
  items: { id: string; count: number }[]
  maxWeight: number
}

interface InventoryEvents {
  moveItem: { from: number; to: number; amount: number }
  closed: undefined
}

interface InventoryIncoming {
  sync: { rev: number }
}

interface InventoryRpc {
  split: { req: { slot: number; amount: number }; res: { ok: boolean } }
  price: { req: string; res: number }
}

// ---------------------------------------------------------------- what must compile

const page: PageHandle<InventoryProps, InventoryEvents, InventoryIncoming> = usePage<InventoryProps, InventoryEvents, InventoryIncoming>()
const nui: NuiHandle<InventoryRpc, InventoryEvents, InventoryIncoming> = useNui<InventoryRpc, InventoryEvents, InventoryIncoming>()

const weight: number = page.props.maxWeight
const first: string = page.props.items[0].id
page.emit('moveItem', { from: 1, to: 2, amount: 5 })
page.on('sync', (data) => { const rev: number = data.rev; void rev })
page.close()

nui.emit('moveItem', { from: 0, to: 1, amount: 1 })
const off = nui.on('sync', () => {})
off()

async function requests(): Promise<void> {
  const split = await nui.invoke('split', { slot: 3, amount: 2 })
  const ok: boolean = split.ok
  const price: number = await nui.invoke('price', 'water')
  void ok
  void price
}

// A type alias must keep working too.
type AliasEvents = { ping: { at: number } }
const aliased = usePage<InventoryProps, AliasEvents>()
aliased.emit('ping', { at: 1 })

// The default type arguments stay usable with no generics at all.
const loose = usePage()
loose.emit('anything', { whatever: true })

export default defineUIPlugin({
  pages: {
    inventory: definePage<InventoryProps>({
      component: {},
      keepAlive: true,
      reactivity: 'shallow',
      onOpen(p) { void p.props.maxWeight },
      onUpdate(p, changed) { void p.id; void changed.length },
    }),
  },
  setup(ctx) {
    ctx.nui.on('sync', () => {})
    ctx.scope.onDispose(() => {})
    ctx.log('ready', ctx.generation, ctx.build, ctx.dev)
    return () => {}
  },
})

void weight
void first
void requests

// ---------------------------------------------------------------- what must NOT compile

// @ts-expect-error — no such event in InventoryEvents
page.emit('nope', { from: 1, to: 2, amount: 1 })

// @ts-expect-error — wrong payload shape for moveItem
page.emit('moveItem', { from: 'one', to: 2, amount: 3 })

// @ts-expect-error — `sync` carries { rev: number }, not a string
page.on('sync', (data: string) => { void data })

// @ts-expect-error — no such prop
const missing: number = page.props.nothingHere
void missing

// @ts-expect-error — `split` answers { ok: boolean }, not a number
const wrongResult: Promise<number> = nui.invoke('split', { slot: 1, amount: 1 })
void wrongResult

// @ts-expect-error — `price` takes a string
void nui.invoke('price', { slot: 1 })
