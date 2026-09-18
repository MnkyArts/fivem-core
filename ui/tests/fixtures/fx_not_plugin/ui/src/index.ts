// fx_not_plugin — the entry's default export is NOT a `defineUIPlugin(...)` result.
//
// The shell's gate is `default.__coreUIPlugin === true` (§38.6). It has to fail with one readable
// line — "entry has no `export default defineUIPlugin(...)`" — and mark the plugin `failed`, rather
// than throw somewhere deep inside `setup`.
//
// Note the shape: `defineUIPlugin` IS called, but something else is exported. A file that never
// calls it at all cannot be built — `coreUI()` fails the build with the same sentence (§38.13), so
// the only way this failure reaches a player's CEF is a bundle built by another tool or an entry
// whose exports were dropped (`preserveEntrySignatures`). That is exactly what is reproduced here.
import { defineUIPlugin } from '@core/ui'

export const real = defineUIPlugin({ pages: {} })

export default {
  pages: {},
  setup() {
    /* never called: the shell rejects the module before this could run */
  },
}
