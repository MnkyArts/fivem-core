// core UI benchmarks — the in-page half (DESIGN §38.15). Driven by `ui/tests/bench.mjs`, which
// starts the servers, reloads the page for the startup samples and turns the JSON this returns into
// `ui/tests/BENCH.md`. It measures with `performance.now()` and a `PerformanceObserver`; nothing is
// simulated and nothing is averaged in here — the raw samples go back and bench.mjs takes medians.
//
// Everything runs against the BUILT shell and a REAL plugin bundle loaded over HTTP from another
// origin, so the numbers include fetch, evaluation, `setup`, Vue mount and the browser's own work.
(async () => {
  const RUNS = 11
  const SLOTS = 200
  // Named on purpose: the idle measurement below has to tell the harness's own timer apart from one
  // the shell or a plugin created.
  const sleep = (ms) => new Promise(function benchSleep(r) { setTimeout(r, ms) })
  const frame = () => new Promise((r) => requestAnimationFrame(() => r()))
  const send = (m) => window.__core.send(m)
  const q = (s) => document.querySelector(s)
  const nextTick = (fn) => window.Vue.nextTick(fn)

  // Long tasks (> 50 ms on the main thread) — the one number that says "the CEF stuttered".
  const longTasks = []
  let observer = null
  try {
    observer = new PerformanceObserver((list) => {
      for (const e of list.getEntries()) longTasks.push({ start: Math.round(e.startTime), ms: Math.round(e.duration) })
    })
    observer.observe({ entryTypes: ['longtask'] })
  } catch (err) { /* no longtask support: reported as null */ }
  const longTasksSince = (t) => longTasks.filter((l) => l.start >= t)

  const posts = []
  window.__core.setTransport({ resource: 'core', send: (name, body) => { posts.push({ name, body, at: performance.now() }) ; return Promise.resolve({}) } })
  const lastPost = (name, pred) => posts.filter((p) => p.name === name && (!pred || pred(p.body))).pop()

  const state = await fetch('/__control?op=state').then((r) => r.json())
  const ports = {}
  for (const r of state.resources) ports[r.name] = r.port
  const baseOf = (id) => 'http://127.0.0.1:' + ports[id] + '/ui/dist/'
  const manifestOf = async (id) => fetch(baseOf(id) + 'manifest.json').then((r) => r.json())

  const result = { runs: RUNS, slots: SLOTS, longTasks: observer ? [] : null }
  const waitFor = async (fn, ms) => {
    const end = performance.now() + (ms || 5000)
    for (;;) {
      if (fn()) return true
      if (performance.now() >= end) return false
      await sleep(5)
    }
  }
  /** performance.now() at the moment the plugin's `ui_plugin { state: 'ready' }` was posted. */
  const readyAt = (id) => {
    const p = posts.filter((x) => x.name === 'ui_plugin' && x.body.id === id && x.body.state === 'ready').pop()
    return p ? p.at : null
  }

  // ---------------------------------------------------------------- 1. plugin load: cold vs warm
  const alpha = await manifestOf('fx_alpha')
  let generation = 0
  const loadOnce = async () => {
    generation++
    const t0 = performance.now()
    const before = posts.length
    send({ action: 'plugin:register', id: 'fx_alpha', generation, base: baseOf('fx_alpha'), manifest: alpha })
    await waitFor(() => posts.slice(before).some((p) => p.name === 'ui_plugin' && p.body.state === 'ready'), 8000)
    return readyAt('fx_alpha') - t0
  }
  result.loadCold = [await loadOnce()]           // fetch + evaluate + setup, module cache empty
  result.loadWarm = []
  for (let i = 0; i < RUNS; i++) result.loadWarm.push(await loadOnce())   // cached module, new activation

  // ---------------------------------------------------------------- 2. page open latency
  // From the `page:open` message to the moment the component's root node is in the document.
  send({ action: 'page:register', id: 'fx_alpha', type: 'page', keepInput: false, owner: 'fx_alpha' })
  result.pageOpen = []
  for (let i = 0; i < RUNS; i++) {
    send({ action: 'page:close', id: 'fx_alpha' })
    await frame()
    const t0 = performance.now()
    send({ action: 'page:open', id: 'fx_alpha', props: { label: 'bench' + i } })
    await waitFor(() => q('.fx-alpha-page'), 3000)
    result.pageOpen.push(performance.now() - t0)
  }
  send({ action: 'page:close', id: 'fx_alpha' })

  // ---------------------------------------------------------------- 3. snapshot vs patch
  const makeSlots = () => {
    const out = []
    for (let i = 0; i < SLOTS; i++) out.push({ id: i + 1, name: 'item_' + i, count: i })
    return out
  }
  const counters = window.__fx.alpha
  const measurePage = async (pageId, mode) => {
    send({ action: 'page:register', id: pageId, type: 'page', keepInput: false, owner: 'fx_alpha' })
    const snapshot = { slots: makeSlots(), weight: 1 }
    const snapshotBytes = JSON.stringify({ action: 'page:open', id: pageId, props: snapshot }).length
    const out = { mode, snapshotBytes, snapshotMs: [], snapshotRenders: 0, mountMs: [], patchBytes: 0, patchApplyMs: [], patchRenderMs: [], patchRenders: 0 }

    // (a) FIRST open: the page mounts 200 children. Kept apart from the snapshot number below,
    //     which is the fair comparison to a patch: the same open page, a whole new payload.
    send({ action: 'page:close', id: pageId })
    await frame()
    let t = performance.now()
    send({ action: 'page:open', id: pageId, props: { slots: makeSlots(), weight: 0 } })
    await waitFor(() => q('.fx-alpha-bench'), 3000)
    await new Promise((r) => nextTick(r))
    out.mountMs.push(performance.now() - t)

    // (b) whole snapshot into an OPEN page: `Core.UI.open` again, 200 new slot objects.
    for (let i = 0; i < RUNS; i++) {
      const before = counters.slotRenders
      const t0 = performance.now()
      send({ action: 'page:open', id: pageId, props: { slots: makeSlots(), weight: i } })
      await new Promise((r) => nextTick(r))
      out.snapshotMs.push(performance.now() - t0)
      if (i === RUNS - 1) out.snapshotRenders = counters.slotRenders - before
    }
    // (c) one slot through `Core.UI.patch`. `performance.now()` is clamped to 100 us in Chromium,
    //     so a single apply reads as 0 — a batch of 200 is what gives the per-op cost.
    const op = { p: 'slots.7.count', v: 0 }
    out.patchBytes = JSON.stringify({ action: 'page:patch', id: pageId, ops: [op] }).length
    const batch = performance.now()
    for (let i = 0; i < 200; i++) send({ action: 'page:patch', id: pageId, ops: [{ p: 'slots.' + ((i % SLOTS) + 1) + '.count', v: i }] })
    out.patchBatchMs = (performance.now() - batch) / 200
    await new Promise((r) => nextTick(r))
    for (let i = 0; i < RUNS; i++) {
      const before = counters.slotRenders
      const t0 = performance.now()
      send({ action: 'page:patch', id: pageId, ops: [{ p: 'slots.7.count', v: 1000 + i }] })
      const applied = performance.now()
      await new Promise((r) => nextTick(r))
      out.patchApplyMs.push(applied - t0)
      out.patchRenderMs.push(performance.now() - t0)
      if (i === RUNS - 1) out.patchRenders = counters.slotRenders - before
    }
    send({ action: 'page:close', id: pageId })
    await frame()
    return out
  }
  result.deep = await measurePage('fx_alpha_bench', 'deep')
  result.shallow = await measurePage('fx_alpha_bench_shallow', 'shallow')

  // ---------------------------------------------------------------- 4. feeds under load
  // The overlay is the reader; messages go in as fast as a timer chain delivers them (a browser
  // clamps nested timeouts, so the ACHIEVED rate is reported next to the intended 1 kHz).
  send({ action: 'page:register', id: 'fx_alpha_hud', type: 'overlay', keepInput: false, owner: 'fx_alpha' })
  send({ action: 'page:open', id: 'fx_alpha_hud', props: {} })
  await waitFor(() => q('.fx-alpha-hud'), 3000)
  const feed = window.__CORE_UI_HOST__.useFeed('fx_alpha')
  let flushes = 0
  const stopWatch = window.Vue.watch(() => feed.speed, () => { flushes++ }, { flush: 'sync' })
  const feedStart = performance.now()
  const longBefore = longTasks.length
  let sent = 0
  await new Promise((resolve) => {
    const step = () => {
      const now = performance.now()
      if (now - feedStart >= 2000) return resolve()
      send({ action: 'feed', c: { fx_alpha: { speed: sent % 200, rpm: (sent % 100) / 100, gear: sent % 6 } } })
      sent++
      setTimeout(step, 1)
    }
    step()
  })
  const feedMs = performance.now() - feedStart
  stopWatch()
  result.feed = {
    ms: feedMs,
    messages: sent,
    messagesPerSec: Math.round((sent / feedMs) * 1000),
    flushes,
    flushesPerSec: Math.round((flushes / feedMs) * 1000),
    longTasks: longTasksSince(feedStart).length,
  }
  send({ action: 'page:close', id: 'fx_alpha_hud' })

  // ---------------------------------------------------------------- 5. idle with 10 plugins
  // "Nothing in the runtime runs a timer, observer or rAF while idle" (§38.6) — counted by wrapping
  // the schedulers, so what shows up is what the shell and the plugins really asked for.
  const beta = await manifestOf('fx_beta')
  for (let i = 1; i <= 10; i++) {
    send({ action: 'plugin:register', id: 'bench_' + i, generation: 1, base: baseOf('fx_beta'), manifest: Object.assign({}, beta, { id: 'bench_' + i }) })
  }
  await sleep(500)
  const counts = { setTimeout: 0, setInterval: 0, raf: 0, mutation: 0, performance: 0, posts: 0, harness: 0 }
  const who = []
  /** Whoever schedules while the shell is idle gets named — a number alone would not be actionable.
   *  Returns false for the harness's own `sleep`, which must not count against the shell. */
  const blame = (kind) => {
    const stack = String(new Error('idle ' + kind).stack || '').split('\n').slice(1, 5).map((s) => s.trim())
    if (stack.some((s) => s.indexOf('benchSleep') !== -1)) { counts.harness++; return false }
    if (who.length < 6) who.push({ kind, stack: stack.slice(0, 3) })
    return true
  }
  const real = {
    setTimeout: window.setTimeout, setInterval: window.setInterval,
    raf: window.requestAnimationFrame, MutationObserver: window.MutationObserver, PerformanceObserver: window.PerformanceObserver,
  }
  window.setTimeout = function (...a) { if (blame('setTimeout')) counts.setTimeout++; return real.setTimeout.apply(window, a) }
  window.setInterval = function (...a) { if (blame('setInterval')) counts.setInterval++; return real.setInterval.apply(window, a) }
  window.requestAnimationFrame = function (...a) { if (blame('raf')) counts.raf++; return real.raf.apply(window, a) }
  window.MutationObserver = function (...a) { counts.mutation++; return new real.MutationObserver(...a) }
  window.PerformanceObserver = function (...a) { counts.performance++; return new real.PerformanceObserver(...a) }
  const idleStart = performance.now()
  const postsBefore = posts.length
  await sleep(5000)
  counts.posts = posts.length - postsBefore
  const idlePosts = posts.slice(postsBefore).map((p) => p.name)
  result.idle = {
    seconds: (performance.now() - idleStart) / 1000,
    plugins: 10,
    timers: counts.setTimeout + counts.setInterval,
    setTimeout: counts.setTimeout,
    setInterval: counts.setInterval,
    raf: counts.raf,
    observers: counts.mutation + counts.performance,
    posts: counts.posts,
    postNames: idlePosts,
    scheduledBy: who,
    longTasks: longTasksSince(idleStart).length,
  }
  window.setTimeout = real.setTimeout
  window.setInterval = real.setInterval
  window.requestAnimationFrame = real.raf
  window.MutationObserver = real.MutationObserver
  window.PerformanceObserver = real.PerformanceObserver

  result.longTasks = longTasks.slice(0, 20)
  result.plugin = { fx_alpha: alpha, fx_beta: beta }
  for (let i = 1; i <= 10; i++) send({ action: 'plugin:unregister', id: 'bench_' + i })
  send({ action: 'plugin:unregister', id: 'fx_alpha' })
  if (observer) observer.disconnect()
  window.__core.resetTransport()
  return JSON.stringify(result)
})()
