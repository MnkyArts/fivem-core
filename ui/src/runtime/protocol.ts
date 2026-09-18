// core UI runtime — the wire, as types (DESIGN §6.10 table, §38.5).
//
// Types ONLY: this file is `import type`-d by every runtime module and by the unit tests, so it
// must never emit a byte of JavaScript. Both directions live here because they are one protocol:
// Lua -> NUI is a `SendNUIMessage` payload discriminated by `action`, NUI -> Lua is a
// `RegisterNuiCallback` body discriminated by the callback NAME (the URL path, not a field).

import type { NuiErrorShape, PluginManifest } from '../../sdk/src/contract.ts'

// ---------------------------------------------------------------- shared shapes

export type PageType = 'page' | 'overlay' | 'modal'
/** §38.9: rank order. `hud` never enters the stack — overlays take no focus. */
export type FocusLayer = 'chat' | 'page' | 'modal' | 'system'

export interface FocusEntry {
  key: string
  layer: FocusLayer
  id?: string
  owner?: string
}

/** One patch op. `v` ABSENT (not `null`) deletes the key — `null` is a legal value. */
export interface PatchOp {
  p: string
  v?: unknown
}

export interface PluginDevInfo {
  /** `http://localhost:5173` — the plugin's own Vite dev server (§38.11 path 3). */
  origin: string
}

// ---------------------------------------------------------------- Lua -> NUI (`action`)

export interface MsgPluginRegister {
  action: 'plugin:register'
  id: string
  generation: number
  base: string
  manifest: PluginManifest
  dev?: PluginDevInfo | null
}
export interface MsgPluginUnregister { action: 'plugin:unregister'; id: string }

export interface MsgPageRegister {
  action: 'page:register'
  id: string
  type?: PageType
  keepInput?: boolean
  /** NEW in §38: the resource that owns the page. Absent = legacy/core-owned. */
  owner?: string | null
}
export interface MsgPageUnregister { action: 'page:unregister'; id: string }
export interface MsgPageOpen { action: 'page:open'; id: string; props?: Record<string, unknown> | null }
export interface MsgPageClose { action: 'page:close'; id?: string | null }
export interface MsgPagePatch { action: 'page:patch'; id: string; ops: PatchOp[] }
export interface MsgPageEvent { action: 'page:event'; id: string; event: string; data?: unknown }
export interface MsgPageRequest { action: 'page:request'; id: string; rid: string | number; name: string; data?: unknown }

export interface MsgFeed { action: 'feed'; c: Record<string, Record<string, unknown>> }
export interface MsgFocus { action: 'focus'; focused?: boolean; stack?: FocusEntry[] }
export interface MsgDevSet {
  action: 'dev:set'
  enabled?: boolean
  log?: boolean
  inspector?: boolean
  loadTimeoutMs?: number
}
export interface MsgInspectorToggle { action: 'inspector:toggle' }

/** Everything §38 adds. The built-in widget actions keep their §6.10 shapes (see store.js). */
export type LuaToNui =
  | MsgPluginRegister | MsgPluginUnregister
  | MsgPageRegister | MsgPageUnregister | MsgPageOpen | MsgPageClose
  | MsgPagePatch | MsgPageEvent | MsgPageRequest
  | MsgFeed | MsgFocus | MsgDevSet | MsgInspectorToggle

export type LuaToNuiAction = LuaToNui['action']

// ---------------------------------------------------------------- NUI -> Lua (callback name)

/** `ui_request` — held by Lua until the handler answers, the timeout fires or the owner stops. */
export interface CbUiRequest { c: string; n: string; d?: unknown; t: number }
/** The answer Lua posts back for `ui_request` (and the shape `ui_response` carries the other way). */
export type RequestResult =
  | { ok: true; data?: unknown }
  | { ok: false; error: NuiErrorShape }

/** `ui_response` — the shell answering a Lua-initiated `page:request`. */
export interface CbUiResponse { rid: string | number; ok: boolean; data?: unknown; error?: NuiErrorShape }

export type PluginState = 'registered' | 'loading' | 'ready' | 'failed' | 'incompatible'

/** `ui_plugin` — the load result of one activation. Stale generations are ignored by Lua. */
export interface CbUiPlugin {
  id: string
  generation: number
  state: PluginState
  error?: string | null
  ms?: number | null
  pages: string[]
}

/** `ui_error` — one attributed failure; Lua prints it rate-limited (≤ 5/s). */
export interface CbUiError {
  plugin?: string | null
  page?: string | null
  component?: string | null
  message: string
  stack?: string | null
  info?: string | null
}

/** `ui_feed` — first subscriber / last unsubscribe of a feed channel. */
export interface CbUiFeed { channel: string; active: boolean }

export interface CbUiEvent { page: string; event: string; data?: unknown }
export interface CbUiClose { page: string }

export interface NuiToLua {
  ui_request: CbUiRequest
  ui_response: CbUiResponse
  ui_plugin: CbUiPlugin
  ui_error: CbUiError
  ui_feed: CbUiFeed
  ui_event: CbUiEvent
  ui_close: CbUiClose
  ui_ready: Record<string, never>
  ui_sound: { name: string; set: string | null }
}

export type NuiCallbackName = keyof NuiToLua
