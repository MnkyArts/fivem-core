// fx_throw_setup — the module is fine, `setup(ctx)` is not (core DESIGN §38.12).
//
// The definition (and its page map) exist, but the activation never reaches `ready`: phase `setup`,
// state `failed`, the plugin scope is disposed, the stylesheet link goes, and a page that was
// already open is taken through the failure path (`ui_event __error` + toast + `ui_close`) so a page
// that cannot render never keeps the cursor.
import { defineUIPlugin, definePage } from '@core/ui'
import Page from './Page.vue'

export default defineUIPlugin({
  pages: { fx_throw_setup: definePage({ component: Page }) },
  setup() {
    throw new Error('fx_throw_setup: setup() failed on purpose')
  },
})
