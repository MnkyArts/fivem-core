// core UI runtime — the mirrored focus stack, z-order and Escape routing (DESIGN §38.9).
//
// FiveM's NUI focus is ONE global flag and only a resource with a frame may set it, so `client/ui.lua`
// owns the stack and the shell only MIRRORS it: nothing here calls a native, nothing here decides who
// has the cursor. What the mirror is for is the two things Lua cannot do — `inert` on the layers under
// an open modal, and the order Escape travels in.
//
// Rank: chat 1 < page 2 < modal 3 < system 4; the top entry is the highest rank, then the most recent
// (Lua sends the stack top LAST).

import type { FocusEntry, FocusLayer } from './protocol.ts'
import { log } from './plugins.ts'

export interface LayerStoreSlice {
  focused: boolean
  focusStack: FocusEntry[]
}

const RANK: Record<FocusLayer, number> = { chat: 1, page: 2, modal: 3, system: 4 }

let state: LayerStoreSlice = { focused: false, focusStack: [] }

export function attachLayerStore(slice: LayerStoreSlice): void {
  state = slice
}

function normalize(raw: unknown): FocusEntry | null {
  if (!raw || typeof raw !== 'object') return null
  const e = raw as Record<string, unknown>
  const layer = e.layer as FocusLayer
  if (!RANK[layer]) return null
  return {
    key: String(e.key || layer),
    layer,
    id: e.id != null ? String(e.id) : undefined,
    owner: e.owner != null ? String(e.owner) : undefined,
  }
}

/** `focus { focused, stack }` — the stack is replaced IN PLACE so `store.focusStack` keeps identity. */
export function applyFocus(msg: { focused?: boolean; stack?: unknown[] } | null | undefined): void {
  const before = topEntry()
  state.focused = !!(msg && msg.focused)
  const next: FocusEntry[] = []
  const raw = msg && Array.isArray(msg.stack) ? msg.stack : []
  for (const entry of raw) {
    const e = normalize(entry)
    if (e) next.push(e)
  }
  state.focusStack.splice(0, state.focusStack.length, ...next)
  // §38.14: one grep-able line per change of who owns the cursor. Silent unless `dev:set { log }`.
  const after = topEntry()
  if ((before ? before.key : null) !== (after ? after.key : null)) log('focus → ' + (after ? after.key : 'none'))
}

export function focusStack(): readonly FocusEntry[] {
  return state.focusStack
}

/** The entry that owns the cursor right now (highest rank, then most recent), or null. */
export function topEntry(): FocusEntry | null {
  let top: FocusEntry | null = null
  for (const entry of state.focusStack) {
    if (!top || RANK[entry.layer] >= RANK[top.layer]) top = entry
  }
  return top
}

/** The open modal pages, in open order — the shell's own truth when Lua sent no stack yet
 *  (Storybook, the dev host, a `page:open` that landed before its `focus`). */
let modalSource: () => string[] = () => []
export function setModalSource(fn: () => string[]): void {
  modalSource = fn
}

/** The id of the topmost plugin modal, or null. Escape and `inert` both key off this. */
export function topModalId(): string | null {
  for (let i = state.focusStack.length - 1; i >= 0; i--) {
    const entry = state.focusStack[i]
    if (entry.layer === 'modal' && entry.id) return entry.id
  }
  const own = modalSource()
  return own.length ? own[own.length - 1] : null
}

export function modalIds(): string[] {
  const out: string[] = []
  for (const entry of state.focusStack) if (entry.layer === 'modal' && entry.id) out.push(entry.id)
  return out.length ? out : modalSource()
}

export function hasSystemLayer(): boolean {
  for (const entry of state.focusStack) if (entry.layer === 'system') return true
  return false
}

/**
 * `inert` for a layer while a modal is open (Chromium 102+, so the CEF has it). The top modal is
 * never inert; everything focusable below it is, which is what stops a Tab from walking out of a
 * confirm dialog into the page behind it.
 */
export function isInert(layer: 'page' | 'modal' | 'overlay', id?: string | null): boolean {
  const top = topModalId()
  if (!top) return false
  if (layer === 'modal') return id !== top
  return true
}

/** Where Escape goes next (§38.9): kit layers already ran in the capture phase. */
export function escapeTarget(builtinModal: string | null, openPage: string | null): 'builtin' | 'modal' | 'page' | null {
  if (builtinModal) return 'builtin'
  if (topModalId()) return 'modal'
  if (openPage) return 'page'
  return null
}

/** Story/test helper. */
export function resetLayers(): void {
  state.focused = false
  state.focusStack.splice(0, state.focusStack.length)
}
