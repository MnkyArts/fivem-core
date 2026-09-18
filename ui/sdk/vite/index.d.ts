// Types for @core/ui/vite (DESIGN §38.13). The implementation is index.mjs.

import type { PluginOption } from 'vite'

export interface CoreUIOptions {
  /** The plugin id. Defaults to the resource folder name and MUST equal it when given. */
  id?: string
  /** `'eager'` (default) imports the bundle right after registration, `'lazy'` on the first page open. */
  load?: 'eager' | 'lazy'
  /** Dev-server port (default 5173). `vite --mode game` also pins the origin and the HMR socket to it. */
  port?: number
  /** Put everything from node_modules into `chunks/vendor.<hash>.js` instead of the entry. */
  vendorChunk?: boolean
}

/**
 * The whole build config of a core UI plugin: Vue SFC + Tailwind, the host-provided `vue`, the
 * utilities-only stylesheet, hashed output, `manifest.json` and the two dev modes.
 */
export declare function coreUI(options?: CoreUIOptions): PluginOption[]

/** The virtual `vue` module's source — exported for the SDK's own tests. */
export declare function vueShimSource(names: string[], options?: { pure?: boolean }): string

export default coreUI
