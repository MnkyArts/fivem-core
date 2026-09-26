// core UI runtime — the mirrored focus stack, z-order and Escape routing (DESIGN §38.9).
//
// FiveM's NUI focus is ONE global flag and only a resource with a frame may set it, so `client/ui.lua`
// owns the stack and the shell only MIRRORS it: nothing here calls a native, nothing here decides who
// has the cursor. What the mirror is for is the two things Lua cannot do — `inert` on the layers under
// an open modal, and the order Escape travels in.
//
// Rank: chat 1 < page 2 < modal 3 < system 4; the top entry is the highest rank, then the most recent
// (Lua sends the stack top LAST).
//
// §41: a page or modal in `game` input mode holds no focus — Lua leaves it out of the stack, and the
// helpers below skip it in the shell's own fallback too, so it is never the Escape target and never
// makes the layers under it `inert`.

import type { FocusEntry, FocusLayer, MsgShellHud } from './protocol.ts'
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

/** §41: the input mode of a page id. `pages.ts` installs the real lookup; alone, everything is `ui`. */
let inputOf: (id: string) => string = () => 'ui'
export function setInputSource(fn: (id: string) => string): void {
  inputOf = fn
}

/** Does this page/modal id hold focus by its input mode (everything but `game`)? */
function holdsFocus(id: string): boolean {
  return inputOf(id) !== 'game'
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
    if (entry.layer === 'modal' && entry.id && holdsFocus(entry.id)) return entry.id
  }
  const own = modalSource()
  for (let i = own.length - 1; i >= 0; i--) if (holdsFocus(own[i])) return own[i]
  return null
}

export function modalIds(): string[] {
  const out: string[] = []
  for (const entry of state.focusStack) if (entry.layer === 'modal' && entry.id && holdsFocus(entry.id)) out.push(entry.id)
  return out.length ? out : modalSource().filter(holdsFocus)
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

/** Where Escape goes next (§38.9): kit layers already ran in the capture phase. A `game` page or
 *  modal is never the target (§41) — what it does with Escape is decided by `pages.escapePage`. */
export function escapeTarget(builtinModal: string | null, openPage: string | null): 'builtin' | 'modal' | 'page' | null {
  if (builtinModal) return 'builtin'
  if (topModalId()) return 'modal'
  if (openPage && holdsFocus(openPage)) return 'page'
  return null
}

// ---------------------------------------------------------------- §54: hiding the `hud` layer
//
// The `hud` layer (rank 0 above: overlays + core's HUD widgets) is the one that `Core.UI.hideHud`
// hides. Lua sends `shell:hud { hidden, keep }`; the shell hides core's own widgets (App.vue) and
// every overlay whose OWNER is not in `keep` (PageHost.vue) — with `v-show`, so nothing unmounts and
// an overlay's state survives the editor session. A page, a modal, a toast or a built-in modal is
// never touched: they are not the HUD.

export interface HudHideSlice {
  hidden: boolean
  keep: string[]
}

const KEEP_MAX = 64

let hudHide: HudHideSlice = { hidden: false, keep: [] }

export function attachHudStore(slice: HudHideSlice): void {
  hudHide = slice
}

/** `shell:hud` — replaced IN PLACE (`keep` keeps its identity). A malformed message shows the HUD:
 *  the safe answer for a player is a visible HUD, never one that stays hidden for good. */
export function applyHudHide(msg: Partial<MsgShellHud> | null | undefined): void {
  const raw = msg && Array.isArray(msg.keep) ? (msg.keep as unknown[]) : []
  const keep: string[] = []
  for (const owner of raw) {
    if (typeof owner === 'string' && owner !== '' && keep.indexOf(owner) === -1) keep.push(owner)
    if (keep.length >= KEEP_MAX) break
  }
  const hidden = !!(msg && msg.hidden === true)
  if (hudHide.hidden !== hidden) log('hud → ' + (hidden ? 'hidden, keep ' + (keep.join(',') || 'none') : 'visible'))
  hudHide.hidden = hidden
  hudHide.keep.splice(0, hudHide.keep.length, ...(hidden ? keep : []))
}

/** True while core's own HUD widgets are hidden (at least one hideHud reason is held). */
export function hudHidden(): boolean {
  return hudHide.hidden
}

/** Is an overlay of this owner hidden right now? An overlay without an owner is core's. */
export function overlayHidden(owner?: string | null): boolean {
  if (!hudHide.hidden) return false
  return hudHide.keep.indexOf(owner || 'core') === -1
}

/** Story/test helper. */
export function resetLayers(): void {
  state.focused = false
  state.focusStack.splice(0, state.focusStack.length)
  hudHide.hidden = false
  hudHide.keep.splice(0, hudHide.keep.length)
}
