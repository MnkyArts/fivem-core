// fx_throw_eval — a plugin whose MODULE throws while it is evaluated (core DESIGN §38.12).
//
// The import rejects, so the shell never sees a definition: state `failed`, phase `evaluate`, links
// removed, one console.error, `ui_plugin { state: 'failed', error }` — and the rest of the shell,
// including every other plugin, keeps running. The `export default` below is never reached.
import { defineUIPlugin } from '@core/ui'

throw new Error('fx_throw_eval: module evaluation failed on purpose')

// eslint-disable-next-line no-unreachable
export default defineUIPlugin({ pages: {} })
