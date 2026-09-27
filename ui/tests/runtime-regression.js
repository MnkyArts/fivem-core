// core UI runtime-platform regression (DESIGN §38.15) — the built shell, real plugin bundles, one
// origin per resource.
//
//   node ui/tests/build-fixtures.mjs
//   node ui/tests/nui-serve.mjs --map core=8821:../.. --files 'core=html/**' \
//        --map fx_alpha=8822:.fixtures-dist/v1/fx_alpha … &
//   agent-browser open "http://127.0.0.1:8821/html/index.html"
//   agent-browser eval --stdin < ui/tests/runtime-regression.js
//
// `ui/tests/run-browser-suites.mjs` does all of that in one process tree — run that.
//
// The suite PLAYS LUA: it installs a transport through `window.__core.setTransport` (so every NUI
// callback the shell posts is captured and `ui_request` can be answered), and pushes `plugin:*`,
// `page:*`, `feed`, `focus` and `dev:set` messages in with `window.__core.send`. Nothing is
// monkey-patched and nothing is stubbed inside the shell: what runs is the built `html/` bundle
// importing content-hashed plugin modules over HTTP from other origins, exactly as in the CEF.
//
// Conventions (same as shell-regression.js): one async IIFE, `check(name, ok)` per assertion, a
// `FAIL <name>` line for every failure, `PASS n/m` as the last line.
(async () => {
  const out = []
  let pass = 0
  let total = 0
  const realLog = console.log
  const say = (l) => { out.push(l); try { realLog.call(console, l) } catch (e) {} }
  const note = (m) => say('NOTE ' + m)
  const check = (name, ok, detail) => {
    total++
    if (ok) pass++
    else say('FAIL ' + name + (detail === undefined ? '' : ' — ' + detail))
  }
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
  const q = (s) => document.querySelector(s)
  const css = (el, prop) => (el ? getComputedStyle(el)[prop] : null)
  async function waitFor(fn, ms) {
    const end = Date.now() + (ms || 3000)
    for (;;) {
      let ok = false
      // `fn` may be async (a control-endpoint poll) — a returned Promise is always truthy, so it
      // has to be awaited or the wait would pass on the first iteration.
      try { ok = !!(await fn()) } catch (e) { ok = false }
      if (ok) return true
      if (Date.now() >= end) return false
      await sleep(20)
    }
  }
  const frame = () => new Promise((r) => requestAnimationFrame(() => r()))

  // ---- the Lua side ------------------------------------------------------
  // `send` is a SendNUIMessage; the transport below is every RegisterNuiCallback at once.
  const send = (msg) => window.__core.send(msg)
  const posts = []
  let menuReply = null
  const NEVER = Symbol('never answers')
  /** `ui_request` handlers, keyed by the request name — this is `Core.UI.onRequest` in Lua. */
  const handlers = Object.create(null)
  const prevTransport = window.__core.setTransport({
    resource: 'core',
    send(name, body, signal, timeoutMs) {
      posts.push({ name, body })
      if (name === 'menu_change') return menuReply ? menuReply(body) : Promise.resolve({ ok: true, ...body })
      if (name !== 'ui_request') return Promise.resolve({})
      const fn = handlers[body && body.n]
      if (!fn) return Promise.resolve({ ok: false, error: { code: 'no_handler', message: 'no Lua handler "' + (body && body.n) + '"' } })
      if (fn === NEVER) {
        // Lua holds the callback for ever; the deadline is the caller's own AbortController
        // (`rawPost` -> `impl.send(… timeoutMs)`), so the mock owns it here.
        return new Promise((resolve, reject) => {
          const err = new Error('the NUI callback never answered')
          err.name = 'AbortError'
          setTimeout(() => reject(err), timeoutMs)
        })
      }
      try {
        return Promise.resolve(fn(body.d)).then(
          (data) => ({ ok: true, data }),
          (err) => ({ ok: false, error: { code: 'handler_error', message: String((err && err.message) || err) } }),
        )
      } catch (err) {
        return Promise.resolve({ ok: false, error: { code: 'handler_error', message: String((err && err.message) || err) } })
      }
    },
  })
  const mark = () => posts.length
  const since = (m) => posts.slice(m)
  const find = (m, name, pred) => since(m).filter((p) => p.name === name && (!pred || pred(p.body))).pop()
  const count = (m, name, pred) => since(m).filter((p) => p.name === name && (!pred || pred(p.body))).length

  // ---- the resources (`/__control` describes the farm, so nothing is duplicated here) ----
  const state = await fetch('/__control?op=state').then((r) => r.json())
  const ports = Object.create(null)
  const dirs = Object.create(null)
  for (const r of state.resources) { ports[r.name] = r.port; dirs[r.name] = r.dir }
  const origin = (id) => 'http://127.0.0.1:' + ports[id]
  const baseOf = (id) => origin(id) + '/ui/dist/'
  const control = (params) => fetch('/__control?' + params).then((r) => r.json())
  const requestsOf = async (id) => (await control('op=requests&res=' + id)).requests
  const fetched = (list, needle) => list.some((r) => r.path.indexOf(needle) !== -1 && r.status === 200)

  const generations = Object.create(null)
  const manifests = Object.create(null)
  /** One `plugin:register` exactly as client/ui_plugins.lua sends it. */
  async function register(id, opts) {
    const options = opts || {}
    const base = options.base || baseOf(id)
    const manifest = Object.assign(await fetch(base + 'manifest.json').then((r) => r.json()), options.manifest || {})
    manifests[id] = manifest
    generations[id] = (generations[id] || 0) + 1
    send({ action: 'plugin:register', id, generation: generations[id], base, manifest })
    return manifest
  }
  const pluginRec = (id) => window.CoreUI.plugins().filter((p) => p.id === id)[0] || null
  const settled = (id) => {
    const rec = pluginRec(id)
    return rec && (rec.state === 'ready' || rec.state === 'failed' || rec.state === 'incompatible')
  }
  const declare = (id, type, owner, keepInput) => send({ action: 'page:register', id, type: type || 'page', keepInput: !!keepInput, owner })
  const open = (id, props) => send({ action: 'page:open', id, props: props || {} })
  const close = (id) => send({ action: 'page:close', id })

  // §38.14 seams (dev only, `isDev`): the reactive store, the inspector snapshot (which lazy-loads
  // its chunk on the FIRST call — so the "not fetched early" check has to run before any inspect())
  // and the origin map that turns a test origin into a resource name for stack attribution.
  const store = window.__core.store
  const inspect = () => window.__core.inspect()
  const scopeOf = (snap, label) => snap.scopes.filter((s) => s.label === label)[0] || null
  const channelOf = (snap, name) => snap.channels.filter((c) => c.channel === name)[0] || null

  try {
    // No `dev` for the main run: a production shell is what players get. `loadTimeoutMs` is
    // applied either way, and the inspector is toggled explicitly at the end.
    send({ action: 'dev:set', enabled: false, log: false, inspector: false, loadTimeoutMs: 4000 })
    const sentinel = { boot: Date.now(), host: window.__CORE_UI_HOST__, app: q('#app') }
    await control('op=reset-requests')

    // ================================================================= 1. cross-origin load
    let m = mark()
    await register('fx_alpha')
    check('fx_alpha reaches ready from its own origin', await waitFor(() => pluginRec('fx_alpha') && pluginRec('fx_alpha').state === 'ready', 6000), JSON.stringify(pluginRec('fx_alpha')))
    const ready = find(m, 'ui_plugin', (b) => b.id === 'fx_alpha')
    check('ui_plugin reports ready with pages and a duration', !!ready && ready.body.state === 'ready' && ready.body.pages.length === 7 && typeof ready.body.ms === 'number', ready && JSON.stringify(ready.body))
    check('the module was evaluated exactly once', window.__fx.alpha.evals === 1, String(window.__fx.alpha.evals))
    check('setup ran exactly once', window.__fx.alpha.setups === 1, String(window.__fx.alpha.setups))
    check('the plugin stylesheet is a <link> the plugin owns', document.querySelectorAll('link[data-core-plugin="fx_alpha"][rel="stylesheet"]').length === 1)
    check('the static chunk got a modulepreload', !!q('link[rel="modulepreload"][data-core-plugin="fx_alpha"]'))
    // Before ANY inspect(): the inspector chunk must not have been fetched by simply booting.
    check('the inspector chunk is not fetched while nothing inspects', !fetched(await requestsOf('core'), '/assets/inspector.js'))
    const firstSnapshot = await inspect()
    const inspectorRequests = (await requestsOf('core')).filter((r) => r.path.indexOf('/assets/inspector.js') !== -1)
    check('the first __core.inspect() imports the chunk, exactly once', inspectorRequests.length === 1 && firstSnapshot && Array.isArray(firstSnapshot.scopes), JSON.stringify(inspectorRequests.map((r) => r.status)))
    const aliveScope = scopeOf(firstSnapshot, 'plugin:fx_alpha')
    check('the plugin scope holds exactly one listener and one timer', !!aliveScope && aliveScope.listeners === 1 && aliveScope.timers === 1, JSON.stringify(aliveScope))
    check('the snapshot knows the plugin, its module and its pages', firstSnapshot.plugins.some((p) => p.id === 'fx_alpha' && p.state === 'ready')
      && firstSnapshot.modules.some((m) => m.url.indexOf(baseOf('fx_alpha')) === 0 && m.state === 'loaded'), JSON.stringify(firstSnapshot.plugins))

    declare('fx_alpha', 'page', 'fx_alpha', true)
    m = mark()
    open('fx_alpha', { label: 'one', nested: { a: 1, keep: { deep: true } }, slots: ['s1', 's2'] })
    check('the plugin page mounted inside core\'s app', await waitFor(() => q('.fx-alpha-page'), 3000))
    const page = q('.fx-alpha-page')
    check('the page rendered its props', q('.fx-alpha-label').textContent === 'v1:one', q('.fx-alpha-label') && q('.fx-alpha-label').textContent)
    check('onOpen ran once for this open cycle', window.__fx.alpha.opens === 1, String(window.__fx.alpha.opens))
    check('the plugin stylesheet applied (scoped rule)', css(q('.fx-alpha-scoped'), 'borderLeftWidth') === '7px', css(q('.fx-alpha-scoped'), 'borderLeftWidth'))
    check('a plugin utility beats the kit class it sits on', css(q('.fx-alpha-btn'), 'paddingLeft') === '32px', css(q('.fx-alpha-btn'), 'paddingLeft'))
    check('the kit class itself still applies (the button is a CoreButton)', q('.fx-alpha-btn').classList.contains('core-btn'))
    check('a token utility resolves against core\'s tokens', css(page, 'backgroundColor') === 'rgba(11, 17, 22, 0.9)', css(page, 'backgroundColor'))
    const img = q('.fx-alpha-mark')
    check('an imported asset resolves against the PLUGIN origin', img.src.indexOf(baseOf('fx_alpha') + 'assets/mark.') === 0, img.src)
    check('and the plugin origin really served it', fetched(await requestsOf('fx_alpha'), '/assets/mark.'))

    // ---- one Vue, one reactivity graph
    check('the host publishes the shell\'s own Vue', window.__CORE_UI_HOST__.vue.ref === window.Vue.ref && window.__CORE_UI_HOST__.vue === window.CoreUI.Vue)
    check('the host reports the API version', window.__CORE_UI_HOST__.apiVersion === 1)
    send({ action: 'page:event', id: 'fx_alpha', event: 'ping', data: { n: 5 } })
    check('a ref created inside the plugin re-renders in the shell', await waitFor(() => q('.fx-alpha-counts').textContent === '1/1', 1500), q('.fx-alpha-counts').textContent)
    check('ctx.nui.on received the same plugin-channel event', window.__fx.alpha.pings === 1 && window.__fx.alpha.lastPing.n === 5)

    // ================================================================= 2. hot deploy, unknown plugin
    // Registered, declared and OPENED in the same tick — the page has to wait on the plugin's own
    // load promise (§38.6), not on a guess, and then mount with its `onOpen` run exactly once.
    m = mark()
    await register('fx_beta')
    declare('fx_beta', 'overlay', 'fx_beta')
    open('fx_beta', { title: 'beta' })
    check('a page:open that arrives before the plugin is ready waits for it', !q('.fx-beta-page') && await waitFor(() => q('.fx-beta-page'), 6000), JSON.stringify(pluginRec('fx_beta')))
    check('a resource core had never heard of loads while a page is open', pluginRec('fx_beta').state === 'ready', JSON.stringify(pluginRec('fx_beta')))
    check('onOpen ran once for a page that opened before its plugin', window.__fx.beta.opens === 1, String(window.__fx.beta.opens))
    check('the early open never went through the failure path', count(m, 'ui_close') === 0 && !find(m, 'ui_event', (b) => b.event === '__error'))
    check('the shell did not reload (same host object, same #app, same boot)', window.__CORE_UI_HOST__ === sentinel.host && q('#app') === sentinel.app)
    check('the open page was not touched by the hot deploy', q('.fx-alpha-page') === page)
    check('the second plugin renders next to the first', !!q('.fx-beta-page') && !!q('.fx-alpha-page'))
    check('each plugin got its own stylesheet', document.querySelectorAll('link[data-core-plugin="fx_beta"][rel="stylesheet"]').length === 1)
    check('the second plugin\'s utilities are its own', css(q('.fx-beta-btn'), 'paddingLeft') === '40px', css(q('.fx-beta-btn'), 'paddingLeft'))

    // ================================================================= 3. open before the plugin is ready
    m = mark()
    declare('fx_lazy', 'page', 'fx_lazy')
    // declared before the module exists: the props container starts deep (no definition yet)
    declare('fx_lazy_shallow', 'overlay', 'fx_lazy')
    const lazyManifest = await register('fx_lazy')
    check('a lazy plugin declares load: lazy', lazyManifest.load === 'lazy')
    await sleep(300)
    check('a lazy plugin imports nothing until a page of its own opens', window.__fx.lazy === undefined && !fetched(await requestsOf('fx_lazy'), lazyManifest.entry), JSON.stringify(await requestsOf('fx_lazy')))
    check('and its record sits in `registered`', pluginRec('fx_lazy').state === 'registered', pluginRec('fx_lazy').state)
    open('fx_lazy', { label: 'now' })
    check('the first page:open is what imports it', await waitFor(() => q('.fx-lazy-page'), 4000))
    check('a page that opened before the plugin was ready still mounts', q('.fx-lazy-page').textContent === 'now')
    check('the lazy plugin evaluated exactly once', window.__fx.lazy.evals === 1 && window.__fx.lazy.setups === 1)
    check('opening it replaced the exclusive page layer', !q('.fx-alpha-page'), 'fx_alpha should have been replaced')
    check('closing the exclusive page did not send ui_close (Lua closed it)', count(m, 'ui_close') === 0)
    close('fx_lazy')
    // §38.10: the definition's `reactivity: 'shallow'` wins even though page:register came first
    const lazyShallow = () => store.pages.fx_lazy_shallow
    check('a page declared before its lazy plugin loaded gets the definition\'s shallow props',
      lazyShallow().reactivity === 'shallow' && window.Vue.isShallow(lazyShallow().props),
      lazyShallow().reactivity + '/' + window.Vue.isShallow(lazyShallow().props))
    open('fx_lazy_shallow', { nested: { a: 'first' } })
    await waitFor(() => q('.fx-lazy-shallow') && q('.fx-lazy-shallow').textContent.trim() === 'first', 2000)
    const lazyNested = lazyShallow().props.nested
    send({ action: 'page:patch', id: 'fx_lazy_shallow', ops: [{ p: 'nested.a', v: 'second' }] })
    check('its nested values are not proxied and a nested patch copies along the path and renders',
      await waitFor(() => q('.fx-lazy-shallow').textContent.trim() === 'second', 2000)
        && !window.Vue.isReactive(lazyNested) && lazyShallow().props.nested !== lazyNested,
      q('.fx-lazy-shallow') && q('.fx-lazy-shallow').textContent)
    close('fx_lazy_shallow')
    open('fx_alpha', { label: 'one', nested: { a: 1, keep: { deep: true } }, slots: ['s1', 's2'] })
    await waitFor(() => q('.fx-alpha-page'), 2000)

    // ---- a lazy PAGE chunk of an eager plugin
    check('a lazy page\'s chunk is not preloaded', (manifests.fx_alpha.preload || []).every((f) => f.indexOf('Lazy') === -1), JSON.stringify(manifests.fx_alpha.preload))
    check('and not fetched before the page opens', window.__fx.alpha.lazyEvals === 0)
    declare('fx_alpha_lazy', 'overlay', 'fx_alpha')
    open('fx_alpha_lazy', {})
    check('opening it imports the chunk', await waitFor(() => q('.fx-alpha-lazy'), 3000))
    check('the chunk came from the plugin origin', fetched(await requestsOf('fx_alpha'), '/chunks/Lazy.'))
    close('fx_alpha_lazy')

    // ================================================================= 4. restart, same build
    // `plugin:register` with a newer generation IS the restart: the old activation is torn down
    // first. The module stays in the cache — its URL did not change — so nothing is re-imported.
    const propsBefore = window.CoreUI.usePage('fx_alpha').props
    let hits = window.__fx.alpha.hits
    window.dispatchEvent(new CustomEvent('fx-alpha-probe'))
    check('the plugin\'s window listener is installed exactly once', window.__fx.alpha.hits === hits + 1, String(window.__fx.alpha.hits - hits))
    m = mark()
    await register('fx_alpha')
    check('a same-build restart re-activates the CACHED module', await waitFor(() => window.__fx.alpha.setups === 2, 3000), 'setups=' + window.__fx.alpha.setups)
    check('the module was not evaluated again', window.__fx.alpha.evals === 1, String(window.__fx.alpha.evals))
    check('the previous activation was disposed exactly once', window.__fx.alpha.disposes === 1, String(window.__fx.alpha.disposes))
    check('the open page came back without a new page:open', await waitFor(() => q('.fx-alpha-page'), 2000))
    check('the shell never asked Lua to close it (open state is Lua\'s)', count(m, 'ui_close') === 0)
    check('props identity survived the restart (§7.4)', window.CoreUI.usePage('fx_alpha').props === propsBefore)
    hits = window.__fx.alpha.hits
    window.dispatchEvent(new CustomEvent('fx-alpha-probe'))
    check('the old listener set is gone — exactly one hit per event', window.__fx.alpha.hits === hits + 1, String(window.__fx.alpha.hits - hits))

    // ================================================================= 5. restart, NEW build
    // The control endpoint swaps the DIRECTORY behind fx_alpha's origin: same resource, new build,
    // exactly what `restart fx_alpha` does after `npm run build`.
    const v1Entry = manifests.fx_alpha.entry
    await control('op=swap&res=fx_alpha&dir=' + encodeURIComponent(dirs.fx_alpha.replace('/v1/', '/v2/')))
    m = mark()
    const v2 = await register('fx_alpha')
    check('the new build has a different entry file name', v2.entry !== v1Entry, v1Entry + ' -> ' + v2.entry)
    check('the new code runs', await waitFor(() => q('.fx-alpha-label') && q('.fx-alpha-label').textContent.indexOf('v2:') === 0, 5000), q('.fx-alpha-label') && q('.fx-alpha-label').textContent)
    check('the new module was evaluated (the old one stays cached)', window.__fx.alpha.evals === 2, String(window.__fx.alpha.evals))
    check('setup ran for the new activation', window.__fx.alpha.setups === 3 && window.__fx.alpha.disposes === 2, window.__fx.alpha.setups + '/' + window.__fx.alpha.disposes)
    check('exactly one stylesheet link is left for the plugin', document.querySelectorAll('link[data-core-plugin="fx_alpha"][rel="stylesheet"]').length === 1)
    check('the stylesheet points at the current build', q('link[data-core-plugin="fx_alpha"][rel="stylesheet"]').href === baseOf('fx_alpha') + v2.css[0])
    hits = window.__fx.alpha.hits
    window.dispatchEvent(new CustomEvent('fx-alpha-probe'))
    check('the old build\'s listeners are gone', window.__fx.alpha.hits === hits + 1, String(window.__fx.alpha.hits - hits))
    check('the shell did not reload for a new build', window.__CORE_UI_HOST__ === sentinel.host && q('#app') === sentinel.app)
    check('props identity survived the new build too', window.CoreUI.usePage('fx_alpha').props === propsBefore)
    check('the other plugin never noticed', !!q('.fx-beta-page') && window.__fx.beta.setups === 1)

    // ================================================================= 6. requests, both directions
    handlers.echo = (d) => ({ pong: d })
    handlers.fails = () => { throw new Error('lua handler exploded') }
    handlers.slow = NEVER
    const nui = window.__CORE_UI_HOST__.useNui('fx_alpha')
    check('nui.invoke resolves with the Lua handler\'s result', JSON.stringify(await nui.invoke('echo', { a: 1 })) === '{"pong":{"a":1}}')
    let failed = await nui.invoke('fails').then(() => null, (e) => e)
    check('a { ok: false } answer rejects with a typed NuiError', !!failed && failed.name === 'NuiError' && failed.code === 'handler_error', failed && failed.code)
    failed = await nui.invoke('nope').then(() => null, (e) => e)
    check('an unknown Lua handler rejects with no_handler', !!failed && failed.code === 'no_handler', failed && failed.code)
    const startedAt = Date.now()
    failed = await nui.invoke('slow', null, { timeoutMs: 200 }).then(() => null, (e) => e)
    check('a request that is never answered rejects with timeout', !!failed && failed.code === 'timeout', failed && failed.code)
    check('and it waited for its own timeout, not the default', Date.now() - startedAt < 2000, String(Date.now() - startedAt))
    m = mark()
    send({ action: 'page:request', id: 'fx_alpha', rid: 7, name: 'echo', data: { a: 1 } })
    check('Lua -> NUI: nui.handle answers with ui_response', await waitFor(() => find(m, 'ui_response', (b) => b.rid === 7), 1500))
    let answer = find(m, 'ui_response', (b) => b.rid === 7)
    check('the answer carries the handler\'s result', answer.body.ok === true && answer.body.data.echoed.a === 1 && answer.body.data.variant === 'v2', JSON.stringify(answer.body))
    m = mark()
    send({ action: 'page:request', id: 'fx_alpha', rid: 8, name: 'missing', data: {} })
    check('an unknown NUI handler answers no_handler', await waitFor(() => find(m, 'ui_response', (b) => b.rid === 8), 1500) && find(m, 'ui_response', (b) => b.rid === 8).body.error.code === 'no_handler')
    m = mark()
    send({ action: 'page:request', id: 'fx_beta', rid: 9, name: 'who', data: {} })
    await waitFor(() => find(m, 'ui_response', (b) => b.rid === 9), 1500)
    answer = find(m, 'ui_response', (b) => b.rid === 9)
    check('each plugin answers on its own channel', !!answer && answer.body.data.id === 'fx_beta', answer && JSON.stringify(answer.body))

    // ================================================================= 7. unregister while open
    m = mark()
    const inflight = nui.invoke('slow').then(() => null, (e) => e)
    await sleep(30)
    send({ action: 'plugin:unregister', id: 'fx_alpha' })
    const disposedErr = await inflight
    check('a pending invoke rejects with plugin_disposed', !!disposedErr && disposedErr.code === 'plugin_disposed', disposedErr && disposedErr.code)
    check('the page instance is gone', !q('.fx-alpha-page'))
    check('the stylesheet and the preloads went with it', document.querySelectorAll('link[data-core-plugin="fx_alpha"]').length === 0)
    check('the setup disposer ran', window.__fx.alpha.disposes === 3, String(window.__fx.alpha.disposes))
    hits = window.__fx.alpha.hits
    window.dispatchEvent(new CustomEvent('fx-alpha-probe'))
    check('the plugin scope is empty (no listener left)', window.__fx.alpha.hits === hits, String(window.__fx.alpha.hits - hits))
    const afterUnregister = await inspect()
    const deadScope = scopeOf(afterUnregister, 'plugin:fx_alpha')
    check('the scope is gone from the snapshot, or counts zero', !deadScope || (deadScope.listeners === 0 && deadScope.timers === 0 && deadScope.rafs === 0 && deadScope.hooks === 0), JSON.stringify(deadScope))
    check('its page scope went with it', !scopeOf(afterUnregister, 'page:fx_alpha'), JSON.stringify(scopeOf(afterUnregister, 'page:fx_alpha')))
    const deadChannel = channelOf(afterUnregister, 'fx_alpha')
    check('no request is left pending on the channel', !deadChannel || (deadChannel.pending === 0 && deadChannel.handlers === 0), JSON.stringify(deadChannel))
    check('and the plugin record is out of the store', !store.plugins.fx_alpha, JSON.stringify(Object.keys(store.plugins)))
    check('the shell did NOT close the page on its own (§38.6)', count(m, 'ui_close') === 0)
    check('the other plugin is untouched', !!q('.fx-beta-page'))
    m = mark()
    send({ action: 'page:request', id: 'fx_alpha', rid: 10, name: 'echo', data: {} })
    await waitFor(() => find(m, 'ui_response', (b) => b.rid === 10), 1500)
    check('its request handlers are gone too', find(m, 'ui_response', (b) => b.rid === 10).body.error.code === 'no_handler')

    await register('fx_alpha')
    await waitFor(() => window.__fx.alpha.setups === 4, 4000)
    check('re-registering after an unregister re-uses the cached module', window.__fx.alpha.evals === 2 && window.__fx.alpha.setups === 4, window.__fx.alpha.evals + '/' + window.__fx.alpha.setups)
    open('fx_alpha', { label: 'patched', nested: { a: 1, keep: { deep: true } }, slots: ['s1', 's2'] })
    await waitFor(() => q('.fx-alpha-page'), 3000)

    // ================================================================= 8. patches (§38.10)
    const props = window.CoreUI.usePage('fx_alpha').props
    const nestedBefore = props.nested
    const keepBefore = props.nested.keep
    const updatesBefore = window.__fx.alpha.updates
    send({ action: 'page:patch', id: 'fx_alpha', ops: [{ p: 'nested.a', v: 2 }] })
    await frame()
    check('a deep patch writes the leaf', props.nested.a === 2, JSON.stringify(props.nested))
    check('and mutates in place — the container keeps its identity', props.nested === nestedBefore)
    check('a sibling object is untouched', props.nested.keep === keepBefore)
    check('onUpdate got the changed top-level key', window.__fx.alpha.updates === updatesBefore + 1 && window.__fx.alpha.changed.join() === 'nested', window.__fx.alpha.changed.join())
    send({ action: 'page:patch', id: 'fx_alpha', ops: [{ p: 'slots.1', v: 'S1' }] })
    await frame()
    check('a list index is Lua\'s 1-based view', props.slots[0] === 'S1' && props.slots[1] === 's2', JSON.stringify(props.slots))
    send({ action: 'page:patch', id: 'fx_alpha', ops: [{ p: 'slots.3', v: 's3' }] })
    await frame()
    check('length + 1 appends', props.slots.length === 3 && props.slots[2] === 's3', JSON.stringify(props.slots))
    send({ action: 'page:patch', id: 'fx_alpha', ops: [{ p: 'slots.3' }] })
    await frame()
    check('an op without a value deletes (and the list shrinks)', props.slots.length === 2, JSON.stringify(props.slots))
    send({ action: 'page:patch', id: 'fx_alpha', ops: [{ p: 'nested.new.deep', v: 7 }] })
    await frame()
    check('missing intermediates are created as maps', props.nested.new.deep === 7, JSON.stringify(props.nested))
    send({ action: 'page:patch', id: 'fx_alpha_lazy', ops: [{ p: 'ghost', v: 1 }] })
    await frame()
    check('a patch for a page that is not open is ignored', window.CoreUI.usePage('fx_alpha_lazy').props.ghost === undefined)

    declare('fx_alpha_shallow', 'overlay', 'fx_alpha')
    open('fx_alpha_shallow', { nested: { a: 1 }, slots: [1, 2] })
    await waitFor(() => q('.fx-alpha-shallow'), 3000)
    const shallowProps = window.CoreUI.usePage('fx_alpha_shallow').props
    const shallowNested = shallowProps.nested
    send({ action: 'page:patch', id: 'fx_alpha_shallow', ops: [{ p: 'nested.a', v: 9 }] })
    await frame()
    check('a shallow page re-renders on a nested patch', await waitFor(() => q('.fx-alpha-shallow-a').textContent === '9', 1000), q('.fx-alpha-shallow-a').textContent)
    check('and it copied along the path instead of mutating', shallowProps.nested !== shallowNested && shallowNested.a === 1, JSON.stringify(shallowNested))
    close('fx_alpha_shallow')

    // ================================================================= 9. feeds (§38.10)
    m = mark()
    declare('fx_alpha_hud', 'overlay', 'fx_alpha')
    open('fx_alpha_hud', {})
    await waitFor(() => q('.fx-alpha-hud'), 3000)
    check('mounting a reader announces the feed channel', await waitFor(() => find(m, 'ui_feed', (b) => b.channel === 'fx_alpha' && b.active === true), 1500))
    send({ action: 'feed', c: { fx_alpha: { speed: 42 } } })
    check('a feed value reaches the component', await waitFor(() => q('.fx-alpha-speed').textContent === '42', 1000), q('.fx-alpha-speed').textContent)
    m = mark()
    close('fx_alpha_hud')
    await sleep(120)
    check(
      'the last unsubscribe announces it too',
      !!find(m, 'ui_feed', (b) => b.channel === 'fx_alpha' && b.active === false),
      'unmounted=' + !q('.fx-alpha-hud') + ' — useFeed() inside a COMPONENT is not bound to any scope'
      + ' (runtime/feeds.ts reads currentScope() only; host.useFeed ignores the injected page scope)',
    )

    // 1000 messages in ONE tick: the buffer keeps the latest value per key and one rAF copies it
    // into the reactive target, so a synchronous watcher must fire once or twice, never 1000 times.
    const feed = window.__CORE_UI_HOST__.useFeed('fx_alpha')
    let flushes = 0
    const stopWatch = window.Vue.watch(() => feed.speed, () => { flushes++ }, { flush: 'sync' })
    for (let i = 0; i < 1000; i++) send({ action: 'feed', c: { fx_alpha: { speed: i, rpm: i / 1000 } } })
    await frame()
    await frame()
    check('1000 feed messages in one tick cost at most two reactive flushes', flushes >= 1 && flushes <= 2, String(flushes))
    check('the latest value wins', feed.speed === 999, String(feed.speed))
    stopWatch()

    // ================================================================= 9b. §54 shell:hud — hiding the hud layer
    // Lua's half (reasons, owners, natives, text UI, ui_ready order) is tests/client_ui_tests.lua `hud hide`;
    // this is what the SHELL does with `shell:hud { hidden, keep }`: core's HUD widgets and every overlay whose
    // owner is not in `keep` stop painting (v-show) — nothing is closed, nothing unmounts.
    m = mark()
    open('fx_alpha_hud', {})
    await waitFor(() => q('.fx-alpha-hud'), 3000)
    send({ action: 'hud:set', visible: true, health: 80, armour: 40 })
    await waitFor(() => q('.hud'), 1500)
    const painted = (el) => !!el && el.getClientRects().length > 0   // display: none (here or above) has no boxes
    const hudParts = () => Array.from(document.querySelectorAll('[data-core-hud]'))
    const alphaHud = q('.fx-alpha-hud')
    check('before shell:hud both overlays and the vitals strip paint', painted(alphaHud) && painted(q('.fx-beta-page')) && painted(q('.hud')))
    send({ action: 'shell:hud', hidden: true, keep: ['fx_beta'] })
    await frame()
    check('shell:hud hides the overlay of a resource that holds no reason', !painted(q('.fx-alpha-hud')))
    check('and keeps the overlay of the resource that holds one', painted(q('.fx-beta-page')))
    check('core\'s vitals strip steps aside', !painted(q('.hud')))
    check('so do the world prompts and the stat bars (every data-core-hud wrapper)', hudParts().length === 3 && hudParts().every((el) => css(el, 'display') === 'none'), hudParts().map((el) => el.dataset.coreHud + '=' + css(el, 'display')).join())
    check('hidden, never unmounted: the same element, still open', q('.fx-alpha-hud') === alphaHud && store.overlays.fx_alpha_hud === true)
    send({ action: 'feed', c: { fx_alpha: { speed: 77 } } })
    check('a hidden overlay keeps updating underneath', await waitFor(() => q('.fx-alpha-speed').textContent === '77', 1000), q('.fx-alpha-speed').textContent)
    send({ action: 'shell:hud', hidden: true, keep: {} })   // Lua encodes an empty list as an object
    await frame()
    check('an empty keep (Lua {}) hides every overlay', !painted(q('.fx-beta-page')) && !painted(q('.fx-alpha-hud')))
    send({ action: 'shell:hud', hidden: false, keep: {} })
    await frame()
    check('shell:hud { hidden = false } brings everything back exactly as it was', painted(q('.fx-alpha-hud')) && q('.fx-alpha-hud') === alphaHud && painted(q('.fx-beta-page')) && painted(q('.hud')))
    check('the wrappers are display: contents again (no layout of their own)', hudParts().every((el) => css(el, 'display') === 'contents'), hudParts().map((el) => css(el, 'display')).join())
    check('hiding the hud never asked Lua to close anything', count(m, 'ui_close') === 0)
    close('fx_alpha_hud')
    send({ action: 'hud:set', visible: false })

    // ================================================================= 10. layers, inert, Escape
    declare('fx_alpha_confirm', 'modal', 'fx_alpha')
    declare('fx_alpha_shallow', 'modal', 'fx_alpha')
    open('fx_alpha_confirm', { question: 'first' })
    await waitFor(() => q('.fx-alpha-confirm'), 3000)
    open('fx_alpha_shallow', { nested: { a: 'second' } })
    await waitFor(() => q('.fx-alpha-shallow'), 3000)
    const layers = document.querySelectorAll('.modal-layer')
    check('modals stack above the page in open order', layers.length === 2 && css(layers[0], 'zIndex') === '30' && css(layers[1], 'zIndex') === '31', layers.length + ' ' + css(layers[0], 'zIndex') + '/' + css(layers[1], 'zIndex'))
    check('the page layer sits below them', css(q('.page-layer'), 'zIndex') === '20', css(q('.page-layer'), 'zIndex'))
    check('every layer under the top modal is inert', q('.page-layer').hasAttribute('inert') && layers[0].hasAttribute('inert'))
    check('the top modal is not inert', !layers[1].hasAttribute('inert'))
    // The mirrored stack outranks the shell's own guess: Lua says the FIRST modal is on top.
    send({ action: 'focus', focused: true, stack: [{ key: 'page:fx_alpha', layer: 'page', id: 'fx_alpha', owner: 'fx_alpha' }, { key: 'modal:fx_alpha_shallow', layer: 'modal', id: 'fx_alpha_shallow', owner: 'fx_alpha' }, { key: 'modal:fx_alpha_confirm', layer: 'modal', id: 'fx_alpha_confirm', owner: 'fx_alpha' }] })
    await frame()
    check('the shell mirrors Lua\'s focus stack for inert', !document.querySelectorAll('.modal-layer')[0].hasAttribute('inert') && document.querySelectorAll('.modal-layer')[1].hasAttribute('inert'))
    const sentStack = [
      { key: 'page:fx_alpha', layer: 'page', id: 'fx_alpha', owner: 'fx_alpha' },
      { key: 'modal:fx_alpha_confirm', layer: 'modal', id: 'fx_alpha_confirm', owner: 'fx_alpha' },
      { key: 'modal:fx_alpha_shallow', layer: 'modal', id: 'fx_alpha_shallow', owner: 'fx_alpha' },
    ]
    send({ action: 'focus', focused: true, stack: sentStack })
    await frame()
    check('store.focusStack mirrors Lua\'s stack entry for entry, top last',
      JSON.stringify(store.focusStack.map((e) => [e.key, e.layer, e.id, e.owner])) === JSON.stringify(sentStack.map((e) => [e.key, e.layer, e.id, e.owner])),
      JSON.stringify(store.focusStack))
    check('and the snapshot reports the same stack', JSON.stringify((await inspect()).focus.map((e) => e.key)) === JSON.stringify(sentStack.map((e) => e.key)))
    check('store.modals holds the open modals in open order', store.modals.join() === 'fx_alpha_confirm,fx_alpha_shallow', store.modals.join())
    const esc = () => window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
    /** Lua answers every `ui_close` with a new `focus` message; the mirror is never stale in game. */
    const focusStack = (...entries) => send({ action: 'focus', focused: entries.length > 0, stack: entries })
    const entry = (layer, id) => ({ key: layer + ':' + id, layer, id, owner: 'fx_alpha' })
    m = mark()
    esc()
    await sleep(60)
    check('Escape closes the TOP modal first', !!find(m, 'ui_close', (b) => b.page === 'fx_alpha_shallow') && !q('.fx-alpha-shallow'), JSON.stringify(since(m).map((p) => p.name + ':' + (p.body && p.body.page))))
    focusStack(entry('page', 'fx_alpha'), entry('modal', 'fx_alpha_confirm'))
    m = mark()
    esc()
    await sleep(60)
    check('then the modal below it', !!find(m, 'ui_close', (b) => b.page === 'fx_alpha_confirm') && !q('.fx-alpha-confirm'), JSON.stringify(since(m).map((p) => p.name + ':' + (p.body && p.body.page))))
    focusStack(entry('page', 'fx_alpha'))
    m = mark()
    esc()
    await sleep(60)
    check('then the page', !!find(m, 'ui_close', (b) => b.page === 'fx_alpha') && !q('.fx-alpha-page'), JSON.stringify(since(m).map((p) => p.name + ':' + (p.body && p.body.page))))
    check('a closed page layer leaves no inert attribute behind', !q('.page-layer'))
    focusStack()

    // ================================================================= 10b. input modes, Escape, suspend (§41)
    // Lua's half is in tests/client_ui_tests.lua; this is what the SHELL does with the three §41 fields.
    const alpha = window.__fx.alpha
    const mode = () => (q('.fx-alpha-mode') || {}).textContent
    // `page:register` with the §41 fields, exactly as client/ui.lua sends it
    send({ action: 'page:register', id: 'fx_alpha', type: 'page', owner: 'fx_alpha', input: 'ui', escape: 'event', keepInput: false })
    open('fx_alpha', { label: 'input' })
    focusStack(entry('page', 'fx_alpha'))
    check('§41: the page renders its input mode (PageHandle.input)', await waitFor(() => mode() === 'ui', 3000), mode())
    check('§41: a ui page layer takes the mouse', css(q('.page-layer'), 'pointerEvents') === 'auto' && q('.page-layer').getAttribute('data-core-input') === 'ui', css(q('.page-layer'), 'pointerEvents'))
    let escapesBefore = alpha.escapes
    m = mark()
    esc()
    await sleep(60)
    check('§41: Escape on an escape=event page does not close it', !!q('.fx-alpha-page') && count(m, 'ui_close') === 0, JSON.stringify(since(m).map((p) => p.name)))
    check('§41: the page heard its own escape event', alpha.escapes === escapesBefore + 1, String(alpha.escapes - escapesBefore))
    check('§41: Lua hears it as ui_event escape', !!find(m, 'ui_event', (b) => b.page === 'fx_alpha' && b.event === 'escape'))

    // page:input game — the page stays mounted, the layer and every control in it pass clicks through
    const pageNode = q('.fx-alpha-page')
    send({ action: 'page:input', id: 'fx_alpha', input: 'game' })
    focusStack()
    check('§41: page:input reaches PageHandle.input reactively', await waitFor(() => mode() === 'game', 1000), mode())
    check('§41: the same instance, not a remount', q('.fx-alpha-page') === pageNode)
    check('§41: a game layer lets clicks through', css(q('.page-layer'), 'pointerEvents') === 'none' && q('.page-layer').getAttribute('data-core-input') === 'game', css(q('.page-layer'), 'pointerEvents'))
    check('§41: and so does every kit control inside it', css(q('.fx-alpha-btn'), 'pointerEvents') === 'none', css(q('.fx-alpha-btn'), 'pointerEvents'))
    const btnBox = q('.fx-alpha-btn').getBoundingClientRect()
    const hitEl = document.elementFromPoint(btnBox.left + btnBox.width / 2, btnBox.top + btnBox.height / 2)
    check('§41: hit-testing passes through a game page', !hitEl || !q('.page-layer').contains(hitEl), hitEl ? hitEl.className : 'none')
    escapesBefore = alpha.escapes
    m = mark()
    esc()
    await sleep(60)
    check('§41: a game page is never the Escape target', alpha.escapes === escapesBefore && count(m, 'ui_close') === 0 && !!q('.fx-alpha-page'))

    send({ action: 'page:input', id: 'fx_alpha', input: 'ui' })
    focusStack(entry('page', 'fx_alpha'))
    check('§41: back to ui, the layer takes the mouse again', await waitFor(() => mode() === 'ui' && css(q('.page-layer'), 'pointerEvents') === 'auto' && css(q('.fx-alpha-btn'), 'pointerEvents') !== 'none', 1000), css(q('.fx-alpha-btn'), 'pointerEvents'))

    // a game MODAL above a ui page: Lua leaves it out of the stack, the shell must not guess it in
    send({ action: 'page:register', id: 'fx_alpha_confirm', type: 'modal', owner: 'fx_alpha', input: 'game', escape: 'close', keepInput: false })
    open('fx_alpha_confirm', { question: 'ghost' })
    await waitFor(() => q('.fx-alpha-confirm'), 3000)
    focusStack(entry('page', 'fx_alpha'))
    await frame()
    check('§41: a game modal does not make the page under it inert', !!q('.fx-alpha-confirm') && !q('.page-layer').hasAttribute('inert'))
    check('§41: its layer and its controls let clicks through', css(q('.modal-layer'), 'pointerEvents') === 'none' && css(q('.fx-alpha-ok'), 'pointerEvents') === 'none', css(q('.modal-layer'), 'pointerEvents') + '/' + css(q('.fx-alpha-ok'), 'pointerEvents'))
    escapesBefore = alpha.escapes
    m = mark()
    esc()
    await sleep(60)
    check('§41: Escape skips the game modal and reaches the page', alpha.escapes === escapesBefore + 1 && !find(m, 'ui_close') && !!q('.fx-alpha-confirm'), JSON.stringify(since(m).map((p) => p.name + ':' + (p.body && p.body.page))))
    close('fx_alpha_confirm')
    declare('fx_alpha_confirm', 'modal', 'fx_alpha')

    // onHide = 'suspend': Lua keeps the page open across the hidden transition and tells it so
    const suspendsBefore = alpha.suspends
    const resumesBefore = alpha.resumes
    send({ action: 'page:event', id: 'fx_alpha', event: 'suspend', data: {} })
    send({ action: 'focus', focused: false, stack: [] })
    send({ action: 'shell:visible', visible: false, reasons: ['game:pause'] })
    await frame()
    check('§41: a suspended page stays mounted while the shell is hidden', q('.fx-alpha-page') === pageNode && alpha.suspends === suspendsBefore + 1, String(alpha.suspends - suspendsBefore))
    send({ action: 'shell:visible', visible: true, reasons: [] })
    send({ action: 'page:event', id: 'fx_alpha', event: 'resume', data: {} })
    focusStack(entry('page', 'fx_alpha'))
    await frame()
    check('§41: resume reaches the same instance', q('.fx-alpha-page') === pageNode && alpha.resumes === resumesBefore + 1, String(alpha.resumes - resumesBefore))

    // leave the next sections what they expect: fx_alpha closed and declared plainly
    close('fx_alpha')
    declare('fx_alpha', 'page', 'fx_alpha')
    focusStack()

    // ================================================================= 11. every failure mode
    const failures = [
      ['fx_404', 'failed', /plugin\.doesnotexist\.js|Failed to fetch|error loading/i],
      ['fx_throw_eval', 'failed', /module evaluation failed on purpose/],
      ['fx_throw_setup', 'failed', /setup\(\) failed on purpose/],
      ['fx_not_plugin', 'failed', /export default defineUIPlugin/],
      ['fx_api2', 'incompatible', /built for core UI API 2, this core provides 1/],
    ]
    for (const [id, expected, re] of failures) {
      m = mark()
      if (id === 'fx_404') {
        generations[id] = 1
        send({ action: 'plugin:register', id, generation: 1, base: baseOf('fx_alpha'), manifest: { id, apiVersion: 1, entry: 'plugin.doesnotexist.js', css: [], build: 'x', load: 'eager', preload: [], pages: [] } })
      } else {
        await register(id)
      }
      const ok = await waitFor(() => settled(id), 6000)
      const rec = pluginRec(id)
      check(id + ' ends in state ' + expected, ok && rec.state === expected, rec && rec.state + ' ' + rec.error)
      check(id + ' explains itself', !!rec && re.test(String(rec.error)), rec && rec.error)
      const reported = find(m, 'ui_plugin', (b) => b.id === id)
      check(id + ' told Lua with ui_plugin', !!reported && reported.body.state === expected && typeof reported.body.error === 'string', reported && JSON.stringify(reported.body))
      check(id + ' left no stylesheet behind', document.querySelectorAll('link[data-core-plugin="' + id + '"]').length === 0)
    }
    check('the shell survived all five failures', !!q('.fx-beta-page') && window.__CORE_UI_HOST__ === sentinel.host)
    m = mark()
    q('.fx-beta-btn').click()
    await sleep(60)
    check('and the healthy plugin is still interactive', !!find(m, 'ui_event', (b) => b.page === 'fx_beta' && b.event === 'pong'))
    // A page whose plugin failed must not keep the cursor: it is closed through the §38.6 path.
    m = mark()
    declare('fx_throw_setup', 'page', 'fx_throw_setup')
    open('fx_throw_setup', {})
    await sleep(200)
    check(
      'a page of a failed plugin is closed instead of hanging',
      !!find(m, 'ui_close', (b) => b.page === 'fx_throw_setup') && !!find(m, 'ui_event', (b) => b.page === 'fx_throw_setup' && b.event === '__error'),
      'posts=' + JSON.stringify(since(m).map((p) => p.name)) + ' mounted=' + !!q('.fx-throw-setup-page')
      + ' (a setup-phase failure leaves the activation\'s page map in place, so the component still resolves)',
    )
    close('fx_throw_setup')

    // ================================================================= 12. crash isolation (§38.12)
    open('fx_alpha', { label: 'crashy', crash: true })
    await sleep(250)
    m = mark()
    open('fx_alpha', { label: 'crashy', crash: true })
    check('a render crash removes that instance', await waitFor(() => !q('.fx-alpha-page'), 2000))
    const crashErr = find(m, 'ui_error') || since(0).filter((p) => p.name === 'ui_error').pop()
    // `component` is the SFC's compiler-inferred `__name` (the file), which is what a developer
    // greps for; `defineOptions({ name })` is not consulted by runtime/errors.ts.
    // `component` is the crashing child's own name: an explicit `defineOptions({ name })` wins over
    // the file name the SFC compiler infers (the fixture is `Crash.vue`, the name is FxCrashChild).
    check('ui_error names the resource, the page and the component', !!crashErr && crashErr.body.plugin === 'fx_alpha' && crashErr.body.page === 'fx_alpha' && crashErr.body.component === 'FxCrashChild', crashErr && JSON.stringify(crashErr.body))
    check('and carries the stack of the plugin origin', !!crashErr && String(crashErr.body.stack).indexOf(origin('fx_alpha')) !== -1)
    check('a crashed focus-holding page asks Lua to close it', !!find(m, 'ui_close', (b) => b.page === 'fx_alpha'))
    check('the sibling plugin kept rendering', !!q('.fx-beta-page'))
    open('fx_alpha', { label: 'back' })
    check('the next page:open remounts a clean instance', await waitFor(() => q('.fx-alpha-page') && q('.fx-alpha-label').textContent === 'v2:back', 3000), q('.fx-alpha-label') && q('.fx-alpha-label').textContent)
    m = mark()
    q('.fx-alpha-throw').click()
    await sleep(80)
    check('a throwing event handler is reported', !!find(m, 'ui_error', (b) => /handler exploded/.test(b.message)), JSON.stringify(since(m).map((p) => p.name)))
    check('but the page keeps rendering', !!q('.fx-alpha-page'))

    // An error with no component around it: only the stack can say whose it is. In game that is the
    // `cfx-nui-<resource>` origin; here the suite maps the fixture's test origin onto the resource.
    m = mark()
    window.__core.setOriginMap({ [origin('fx_alpha')]: 'fx_alpha' })
    send({ action: 'page:event', id: 'fx_alpha', event: 'boom-timer' })
    await waitFor(() => find(m, 'ui_error', (b) => /timer callback exploded/.test(b.message)), 2000)
    const timerErr = find(m, 'ui_error', (b) => /timer callback exploded/.test(b.message))
    check('an uncaught error from a plugin timer reaches ui_error', !!timerErr, JSON.stringify(since(m).map((p) => p.name)))
    check('and the origin map attributes it to the plugin', !!timerErr && timerErr.body.plugin === 'fx_alpha' && timerErr.body.page === null, timerErr && JSON.stringify(timerErr.body))
    check('the shell survived an error outside every component tree', !!q('.fx-alpha-page') && !!q('.fx-beta-page'))
    const afterTimer = await inspect()
    check('the inspector kept it in its error log', afterTimer.errors.some((e) => /timer callback exploded/.test(e.message)))
    check('the plugin scope did not grow a timer (scope.timeout removes its own hook)', (scopeOf(afterTimer, 'plugin:fx_alpha') || {}).timers === 1, JSON.stringify(scopeOf(afterTimer, 'plugin:fx_alpha')))
    window.__core.setOriginMap(null)

    // ================================================================= 13. the legacy surface
    window.CoreUI.registerPage('fx_legacy', {
      name: 'FxLegacy',
      setup() { return () => window.Vue.h('div', { class: 'fx-legacy' }, 'legacy') },
    })
    declare('fx_legacy', 'overlay', null)
    open('fx_legacy', {})
    check('CoreUI.registerPage still renders a page with no owner plugin', await waitFor(() => q('.fx-legacy'), 2000))
    close('fx_legacy')

    // ================================================================= 14. the inspector panel
    // The chunk was already imported by `__core.inspect()` above, so this is about the PANEL: one
    // chunk for both entry points (the seam and `<Inspector>`), one fetch for the whole session.
    send({ action: 'dev:set', enabled: true, log: false, inspector: false, loadTimeoutMs: 4000 })
    send({ action: 'inspector:toggle' })
    check('inspector:toggle mounts the panel', await waitFor(() => store.dev.inspector && document.body.innerText.indexOf('fx_beta') !== -1, 4000), String(store.dev.inspector))
    check('and needed no second fetch of the chunk', (await requestsOf('core')).filter((r) => r.path.indexOf('/assets/inspector.js') !== -1).length === 1)
    send({ action: 'inspector:toggle' })
    await frame()
    check('toggling it off unmounts it again', store.dev.inspector === false)
    send({ action: 'dev:set', enabled: false, log: false, inspector: false, loadTimeoutMs: 4000 })

    // ================================================================= 14. development services (§40)
    // Actual DOM controls and the real NUI result transport; no source-text assertions.
    send({ action: 'focus', focused: false, stack: [] })
    send({ action: 'shell:visible', visible: true })
    const press = (key, target = window) => target.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }))
    const field = (name) => q('.dlg [data-field="' + name + '"]')
    const edit = (el, value) => { if (el) { el.value = value; el.dispatchEvent(new Event('input', { bubbles: true })) } }
    m = mark()
    send({ action: 'input:open', id: 'c40-form', title: 'Development fields', fields: [
      { name: 'notes', label: 'Notes', type: 'textarea', default: 'First line' },
      { name: 'secret', label: 'Secret', type: 'password', default: 'private' },
      { name: 'volume', label: 'Volume', type: 'slider', min: 0, max: 10, step: 1, default: 3 },
      { name: 'roles', label: 'Roles', type: 'multiselect', searchable: true, options: [{ label: 'Alpha', value: 'alpha' }, { label: 'Disabled', value: false }] },
      { name: 'enabled', label: 'Enabled', type: 'select', options: [{ label: 'No', value: false }, { label: 'Yes', value: true }], default: false },
      { name: 'day', label: 'Day', type: 'date', default: '2026-09-21' },
      { name: 'time', label: 'Time', type: 'time', default: '12:34' },
      { name: 'color', label: 'Color', type: 'color', default: '#abcdef' },
    ] })
    await frame()
    check('expanded form renders textarea/password/range/date/time/color controls', !!q('.dlg textarea') && !!q('.dlg input[type="password"]') && !!q('.dlg input[type="range"]') && !!q('.dlg input[type="date"]') && !!q('.dlg input[type="time"]') && !!q('.dlg input[type="color"]'))
    const multiline = q('.dlg textarea')
    edit(multiline, 'First line\nSecond line')
    press('Enter', multiline)
    check('textarea Enter does not submit the form', !find(m, 'input_result'))
    edit(q('.dlg input[type="range"]'), '7')
    const falseChoice = Array.from(field('roles')?.querySelectorAll('label') || []).find((el) => el.textContent.includes('Disabled'))
    falseChoice?.click()
    edit(field('roles')?.querySelector('input[type="search"]'), 'Alpha')
    await frame()
    check('searchable multi-select filters by label', field('roles')?.textContent.includes('Alpha') && !field('roles')?.textContent.includes('Disabled'))
    q('.dlg [data-role="submit"]')?.click()
    await frame()
    const expandedValues = find(m, 'input_result')?.body.values
    check('expanded form submits multiline/password/numeric slider', expandedValues?.notes === 'First line\nSecond line' && expandedValues.secret === 'private' && expandedValues.volume === 7)
    check('expanded form preserves false option and hidden multiselect choice', expandedValues?.enabled === false && Array.isArray(expandedValues?.roles) && expandedValues.roles.length === 1 && expandedValues.roles[0] === false)
    check('date/time/color round-trip unchanged', expandedValues?.day === '2026-09-21' && expandedValues.time === '12:34' && expandedValues.color === '#abcdef')

    m = mark()
    send({ action: 'input:open', id: 'c40-form-validation', fields: [
      { name: 'amount', type: 'number', min: 0, step: 2 },
      { name: 'note', type: 'text', minLength: 2, maxLength: 4 },
    ] })
    await frame()
    edit(field('amount'), '3')
    edit(field('note'), 'ok')
    q('.dlg [data-role="submit"]')?.click()
    await frame()
    check('off-step numeric input stays editable without a result', store.input.visible && !find(m, 'input_result') && !!q('.dlg [data-error="amount"]'))
    edit(field('amount'), '4')
    edit(field('note'), '')
    q('.dlg [data-role="submit"]')?.click()
    await frame()
    check('optional empty string still obeys declared minLength', store.input.visible && !find(m, 'input_result') && !!q('.dlg [data-error="note"]'))
    edit(field('note'), 'ééé')
    q('.dlg [data-role="submit"]')?.click()
    await frame()
    check('string maximum uses Lua-compatible UTF-8 byte length', store.input.visible && !find(m, 'input_result') && !!q('.dlg [data-error="note"]'))
    edit(field('note'), 'éé')
    q('.dlg [data-role="submit"]')?.click()
    await frame()
    check('corrected form submits numeric step and UTF-8-bound values', !store.input.visible && find(m, 'input_result')?.body.values.amount === 4 && find(m, 'input_result')?.body.values.note === 'éé')

    m = mark()
    send({ action: 'menu:open', id: 'c40-menu-ack', items: [
      { label: 'Toggle', value: 1, checked: false }, { label: 'Finish', value: 2 },
    ] })
    await frame()
    menuReply = () => Promise.resolve({ ok: false })
    q('.menu [data-index="0"]')?.click()
    await frame()
    check('rejected menu change preserves displayed checkbox', store.menu.items[0]?.checked === false && store.menu.visible)
    let resolveMenuChange
    menuReply = () => new Promise((resolve) => { resolveMenuChange = resolve })
    q('.menu [data-index="0"]')?.click()
    await frame()
    check('pending menu change is not displayed optimistically', store.menu.items[0]?.checked === false)
    q('.menu [data-index="1"]')?.click()
    await frame()
    check('selection waits for pending menu change acknowledgement', store.menu.visible && !find(m, 'menu_result'))
    resolveMenuChange?.({ ok: true })
    await frame()
    check('acknowledged menu change updates displayed checkbox', store.menu.items[0]?.checked === true)
    q('.menu [data-index="0"]')?.click()
    await frame()
    send({ action: 'menu:open', id: 'c40-menu-replacement', items: [{ label: 'Replacement', value: 1, checked: false }] })
    await frame()
    resolveMenuChange?.({ ok: true })
    await frame()
    check('late change acknowledgement cannot mutate replacement menu', store.menu.id === 'c40-menu-replacement' && store.menu.items[0]?.checked === false)
    menuReply = null
    send({ action: 'menu:close' })
    await frame()

    m = mark()
    send({ action: 'menu:open', id: 'c40-menu', title: 'Development menu', items: [
      { label: 'Enabled', value: 1, checked: false, metadata: [{ label: 'Mode', value: 'Preview' }], progress: 35 },
      { label: 'Quality', value: 2, values: ['Low', 'High'], selected: 1 },
      { label: 'More', value: 3, items: [{ label: 'Nested choice', value: 4 }] },
    ] })
    await frame()
    check('menu displays metadata and progress', !!q('.menu dl') && q('.menu dl')?.textContent.includes('Preview') && !!q('.menu .core-progress'))
    q('.menu [data-index="0"]')?.click()
    await frame()
    check('checkbox menu posts change without closing', find(m, 'menu_change')?.body.checked === true && store.menu.visible && !find(m, 'menu_result'))
    press('ArrowDown'); press('ArrowRight')
    await frame()
    check('side-scroll menu posts 1-based selected index', !!find(m, 'menu_change', (b) => b.value === 2 && b.selected === 2))
    q('.menu [data-index="2"]')?.click()
    await frame()
    check('submenu opens without resolving parent', q('.menu')?.textContent.includes('Nested choice') && !find(m, 'menu_result'))
    press('Escape')
    await frame()
    check('submenu Escape goes back rather than closing menu', store.menu.visible && q('.menu')?.textContent.includes('Quality') && !find(m, 'menu_result'), JSON.stringify({visible:store.menu.visible,text:q('.menu')?.textContent,posts:since(m)}))
    q('.menu [data-index="2"]')?.click()
    await frame()
    q('.menu [data-index="0"]')?.click()
    await frame()
    check('nested menu returns original unique row id', find(m, 'menu_result')?.body.value === 4)

    const startCheck = (id, extra = {}) => send({ action: 'skillcheck:open', id, difficulty: [{ speed: 200, areaSize: 80 }], keys: ['e'], canCancel: true, ...extra })
    m = mark()
    startCheck('c40-hit', { difficulty: [{ speed: 200, areaSize: 80 }, { speed: 200, areaSize: 80 }], keys: ['e', 'q'] })
    const inWindow = () => { const pos = Number(q('.skillcheck-track')?.getAttribute('aria-valuenow')); return pos >= 30 && pos <= 65 }
    check('skill-check indicator actually advances into target', await waitFor(inWindow, 1200))
    press('e'); await frame()
    check('skill-check advances stage without early result', store.skillcheck.visible && !find(m, 'skillcheck_result'))
    await waitFor(inWindow, 1200); press('q'); await frame()
    check('all timed stages must succeed', find(m, 'skillcheck_result')?.body.success === true && !store.skillcheck.visible)
    m = mark(); startCheck('c40-wrong'); await frame(); press('x'); await frame()
    check('wrong key fails skill-check', find(m, 'skillcheck_result')?.body.success === false)
    m = mark(); startCheck('c40-miss', { difficulty: [{ speed: 200, areaSize: 5 }] }); await frame()
    check('missed timing window expires', await waitFor(() => find(m, 'skillcheck_result')?.body.success === false, 1500))
    m = mark(); startCheck('c40-old'); await frame(); startCheck('c40-new'); await frame()
    send({ action: 'skillcheck:close', id: 'c40-old' }); await frame()
    check('stale close cannot dismiss replacement skill-check', store.skillcheck.visible && store.skillcheck.id === 'c40-new')
    press('Escape'); await frame()
    check('Escape cancels replacement exactly once', count(m, 'skillcheck_result', (b) => b.id === 'c40-new' && b.success === false) === 1)
    m = mark(); startCheck('c40-pause'); await frame(); send({ action: 'shell:visible', visible: false, reasons: ['pause'] }); await frame()
    check('hidden shell cancels skill-check', find(m, 'skillcheck_result')?.body.success === false && !store.skillcheck.visible)
    send({ action: 'shell:visible', visible: true }); await frame()
    m = mark(); startCheck('c40-close'); await frame(); send({ action: 'skillcheck:close', id: 'c40-close' }); await sleep(600)
    check('host close stops animation and late result', !store.skillcheck.visible && !find(m, 'skillcheck_result'))

    // ================================================================= 15. scene audio engine (§55.16)
    // The REAL Web Audio engine of the built shell, driven through the same `audio:*` messages Lua
    // sends. The tone is a WAV generated here and handed over as a blob: URL (dev pages accept it).
    // Signal-level checks need a RUNNING context: FiveM's CEF has autoplay-policy=no-user-gesture-
    // required; a stock headless Chrome holds the context suspended, so run the suites with
    // AGENT_BROWSER_ARGS=--autoplay-policy=no-user-gesture-required to include them.
    {
      const A = window.__core.audio
      check('audio: the dev seam exists', !!A)
      check('audio: no engine and no AudioContext before the first audio:* message', !!A && A.stats().context === null)
      const toneUrl = (() => {
        const sr = 48000
        const n = sr
        const buf = new ArrayBuffer(44 + n * 2)
        const v = new DataView(buf)
        const w = (o, str) => { for (let i = 0; i < str.length; i++) v.setUint8(o + i, str.charCodeAt(i)) }
        w(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); w(8, 'WAVE'); w(12, 'fmt ')
        v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true); v.setUint32(24, sr, true)
        v.setUint32(28, sr * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true); w(36, 'data'); v.setUint32(40, n * 2, true)
        for (let i = 0; i < n; i++) v.setInt16(44 + i * 2, Math.round(Math.sin((2 * Math.PI * 440 * i) / sr) * 0.5 * 32767), true)
        return URL.createObjectURL(new Blob([buf], { type: 'audio/wav' }))
      })()
      const NET = 7000000
      const net = () => Math.floor(NET + performance.now())
      const afeed = (extra) => send(Object.assign({
        action: 'audio:feed', t: net(), lx: 0, ly: 0, lz: 0, fx: 0, fy: 1, fz: 0, ux: 0, uy: 0, uz: 1,
        master: 1, music: 1, sfx: 1, ambience: 1, paused: false,
      }, extra || {}))
      const aloop = (id) => send({ action: 'audio:source', id, type: 'loop', url: toneUrl, t0: net(), category: 'sfx' })
      const aemit = (id, source, x, y) => send({ action: 'audio:emitter', id, source, x, y, z: 0, range: 40, curve: 'linear', ref: 1 })
      afeed()
      aloop(9001)
      aemit(9101, 9001, 2, 3)
      check('audio: the engine chunk loads on the first message', (await A.ready()) === true)
      const first = A.stats()
      check('audio: one AudioContext after the first source', !!first.context, JSON.stringify(first))
      check('audio: a real sample rate', !!first.context && first.context.sampleRate >= 22050)
      const running = !!first.context && first.context.state === 'running'
      if (!running) note('AudioContext is ' + (first.context && first.context.state) + ' — the browser holds autoplay; signal checks skipped (FiveM: autoplay-policy=no-user-gesture-required)')
      check('audio: the decoded tone becomes a real voice', await waitFor(() => A.stats().voices.real === 1, 5000), JSON.stringify(A.stats().voices))
      const info = A.inspect(9101)
      check('audio: every panner param is k-rate', !!info && !!info.voice && info.voice.pannerRates.length === 6 && info.voice.pannerRates.every((r) => r === 'k-rate'), JSON.stringify(info && info.voice))
      check('audio: every listener param is k-rate', !!info && info.listenerRates.length === 9 && info.listenerRates.every((r) => r === 'k-rate'), JSON.stringify(info && info.listenerRates))
      check('audio: the panner only pans (rolloffFactor 0, equal-power)', !!info && !!info.voice && info.voice.rolloff === 0 && info.voice.model === 'equalpower')
      check('audio: the occlusion/air lowpass is k-rate', !!info && !!info.voice && info.voice.filterRates.every((r) => r === 'k-rate'))
      check('audio: the voice level follows the linear curve (5 m of 40, ref 1)', !!info && Math.abs(info.level - (1 - (Math.hypot(2, 3) - 1) / 39)) < 1e-6, info && String(info.level))
      if (running) {
        // a new context's output clock needs ~0.2–0.4 s before a loop is scheduled on it
        let peak = 0
        const heard = await waitFor(async () => { peak = await A.level(120); return peak > 0.02 }, 3000)
        check('audio: the tone reaches the output (limiter tap)', heard, 'peak ' + peak)
      }
      send({ action: 'audio:prefs', maxVoices: 2 })
      for (let i = 0; i < 4; i++) {
        aloop(9002 + i)
        aemit(9102 + i, 9002 + i, 4 + i * 3, 0)
      }
      check('audio: maxVoices 2 — two real voices, three virtual', await waitFor(() => { const v = A.stats().voices; return v.real === 2 && v.virtual === 3 }, 4000), JSON.stringify(A.stats().voices))
      check('audio: the nearest emitters are the real ones', A.inspect(9101).real && A.inspect(9102).real && !A.inspect(9105).real)
      send({ action: 'audio:prefs', maxVoices: 32 })
      check('audio: lifting the budget makes all five real', await waitFor(() => A.stats().voices.real === 5, 3000), JSON.stringify(A.stats().voices))
      send({ action: 'audio:remove', ids: [9101], fadeMs: 300 })
      await sleep(80)
      const mid = A.stats().voices
      check('audio: remove fades — the chain is still alive 80 ms into a 300 ms fade', mid.fading >= 1 && mid.real === 4, JSON.stringify(mid))
      check('audio: remove — released after the fade', await waitFor(() => A.stats().voices.fading === 0, 1500), JSON.stringify(A.stats().voices))
      const am = mark()
      send({ action: 'audio:source', id: 9200, type: 'clip', url: 'ftp://example.com/x.mp3' })
      check('audio: a bad URL reaches Lua as ui_event audio:error { id, code }', await waitFor(() => find(am, 'ui_event', (b) => b.page === 'audio' && b.event === 'error' && !!b.data && b.data.id === 9200 && b.data.code === 'bad_url'), 1000))
      send({ action: 'audio:remove', ids: [9001, 9002, 9003, 9004, 9005, 9102, 9103, 9104, 9105], fadeMs: 20 })
      check('audio: everything removed', await waitFor(() => { const st = A.stats(); return st.voices.real === 0 && st.voices.fading === 0 && st.sources.total === 0 && st.emitters === 0 }, 2000), JSON.stringify(A.stats()))
      // RV3 F9, the decode bound: 60 s of 8 kHz 8-bit mono is only 480 KB, but would decode to 23 MB of float
      // PCM. The browser's own demuxer measures it (a metadata-only probe) and it plays through an element.
      const longUrl = (() => {
        const sr = 8000
        const n = sr * 60
        const buf = new ArrayBuffer(44 + n)
        const v = new DataView(buf)
        const w = (o, str) => { for (let i = 0; i < str.length; i++) v.setUint8(o + i, str.charCodeAt(i)) }
        w(0, 'RIFF'); v.setUint32(4, 36 + n, true); w(8, 'WAVE'); w(12, 'fmt ')
        v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true); v.setUint32(24, sr, true)
        v.setUint32(28, sr, true); v.setUint16(32, 1, true); v.setUint16(34, 8, true); w(36, 'data'); v.setUint32(40, n, true)
        for (let i = 0; i < n; i++) v.setUint8(44 + i, 128 + Math.round(Math.sin((2 * Math.PI * 330 * i) / sr) * 60))
        return URL.createObjectURL(new Blob([buf], { type: 'audio/wav' }))
      })()
      const decodesBefore = A.stats().loader.decodes
      send({ action: 'audio:source', id: 9300, type: 'loop', url: longUrl, t0: net(), category: 'sfx' })
      send({ action: 'audio:emitter', id: 9400, source: 9300, x: 2, y: 2, z: 0, range: 40, curve: 'linear', ref: 1 })
      check('audio: a short file that is 60 s long is measured and routed to a media element', await waitFor(() => A.stats().sources.large === 1, 4000), JSON.stringify(A.stats().sources))
      check('audio: … never through decodeAudioData', A.stats().loader.decodes === decodesBefore, JSON.stringify(A.stats().loader))
      check('audio: … and still becomes a real voice (decoder granted)', await waitFor(() => !!A.inspect(9400) && A.inspect(9400).real, 4000), JSON.stringify(A.inspect(9400)))
      if (running) {
        let longPeak = 0
        const heardLong = await waitFor(async () => { longPeak = await A.level(120); return longPeak > 0.02 }, 4000)
        check('audio: the element-played file reaches the output', heardLong, 'peak ' + longPeak)
      }
      send({ action: 'audio:remove', ids: [9400, 9300], fadeMs: 20 })
      check('audio: the element source is released', await waitFor(() => A.stats().sources.total === 0, 2000))
      // trusted = false (a play on a player's behalf): never decoded, whatever its size — an element plays it
      const decodesUntrusted = A.stats().loader.decodes
      send({ action: 'audio:source', id: 9310, type: 'loop', url: toneUrl, t0: net(), category: 'sfx', trusted: false })
      send({ action: 'audio:emitter', id: 9410, source: 9310, x: 2, y: 2, z: 0, range: 40, curve: 'linear', ref: 1 })
      check('audio: an untrusted source becomes a real voice through a media element', await waitFor(() => !!A.inspect(9410) && A.inspect(9410).real, 4000), JSON.stringify(A.inspect(9410)))
      check('audio: … without decodeAudioData', A.stats().loader.decodes === decodesUntrusted && A.stats().sources.decoders >= 1, JSON.stringify(A.stats()))
      if (running) {
        let untrustedPeak = 0
        const heardUntrusted = await waitFor(async () => { untrustedPeak = await A.level(120); return untrustedPeak > 0.02 }, 4000)
        check('audio: the untrusted element reaches the output', heardUntrusted, 'peak ' + untrustedPeak)
      }
      send({ action: 'audio:remove', ids: [9410, 9310], fadeMs: 20 })
      check('audio: the untrusted source is released', await waitFor(() => A.stats().sources.total === 0, 2000))
      URL.revokeObjectURL(longUrl)
      URL.revokeObjectURL(toneUrl)
    }

    say('PASS ' + pass + '/' + total)
    return out.join('\n')
  } finally {
    // Leave the shell as we found it: no plugin registered, the real transport back in place.
    for (const id of ['fx_alpha', 'fx_beta', 'fx_lazy', 'fx_404', 'fx_throw_eval', 'fx_throw_setup', 'fx_not_plugin', 'fx_api2']) {
      try { send({ action: 'plugin:unregister', id }) } catch (e) { /* the shell is already gone */ }
    }
    try { window.__core.setTransport(prevTransport) } catch (e) { window.__core.resetTransport() }
  }
})()
