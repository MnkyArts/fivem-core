// my_plugin — UI plugin entry (core DESIGN §38.3, §38.7).
//
// This resource builds its own frontend: `npm run build` in this folder writes ui/dist, the
// fxmanifest opts in with `core_ui 'ui/dist'` + `files { 'ui/dist/**' }`, and core imports the
// module at runtime from https://cfx-nui-my_plugin/ui/dist/. Deploying a UI change is
// `npm run build` + `restart my_plugin` — core is never rebuilt and the CEF never reloads.
//
// MODULE SCOPE IS FOR DEFINITIONS ONLY (§38.2): the browser keeps this module for the life of
// core's page, while `setup(ctx)` runs once per activation (every start of this resource). Put
// every side effect in `setup` — `ctx.scope` disposes it again when the resource stops, so a
// restart can never leave a second listener behind.
//
// The page id is the one client/main.lua declares:
//   Core.UI.registerPage('my_plugin', { type = 'page' })
import { defineUIPlugin, definePage } from '@core/ui'
import Page from './Page.vue'

/** What `Core.UI.open('my_plugin', …)` sends. One interface per page — declare it here, use it in
 *  Page.vue, and the compiler catches a prop the Lua side renamed. */
export interface MyPluginProps {
    title?: string
}

// One interface per direction. The names are what `usePage<Props, Out, In>()` and `useNui<Rpc>()`
// take, so a renamed event is a compile error on both sides of the wire.

/** page → Lua, fire and forget (`Core.UI.on('my_plugin', event, fn)` in client/main.lua). */
export interface MyPluginEvents {
    hello: { at: number }
}

/** Lua → page (`Core.UI.send('my_plugin', event, data)`). */
export interface MyPluginIncoming {
    greeting: { text: string }
}

/** page → Lua, request/response (`Core.UI.onRequest(name, fn)`, §38.8). Delete if unused. */
export interface MyPluginRpc {
    ping: { req: Record<string, never>; res: { pong: boolean } }
}

export default defineUIPlugin({
    pages: {
        // Eager: the component is in the entry chunk, so opening the page costs no second fetch.
        // A big, rarely opened page uses `component: () => import('./Page.vue')` instead.
        my_plugin: definePage<MyPluginProps>({ component: Page }),
        // More ids of the same plugin (an overlay, a modal) are more entries here; each one still
        // needs its own Core.UI.registerPage in Lua, which stays the authority on type and owner.
    },

    setup(ctx) {
        // `ctx.log` only prints with Config.UI.Dev.Log — it costs nothing in production.
        ctx.log('activated, generation', ctx.generation)

        // Anything registered here is torn down with the plugin, in this order: the function
        // returned below, then everything on `ctx.scope`, then the pages.
        //
        //   ctx.nui.on('somethingGlobal', handler)        // Lua -> plugin, outside any page
        //   ctx.nui.handle('whoAreYou', () => ({ id: ctx.id }))   // Core.UI.request answers here
        //   ctx.scope.listen(window, 'blur', onBlur)      // removed on dispose
        //   ctx.scope.interval(tick, 1000)                // cleared on dispose
    },
})
