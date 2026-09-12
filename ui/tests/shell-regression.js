// core UI shell regression test (DESIGN §7.5).
//   (cd resources/core/html && python3 -m http.server 8731 &)   # file:// blocks ES modules (CORS)
//   agent-browser open "http://127.0.0.1:8731/index.html"
//   cat resources/core/ui/tests/shell-regression.js | agent-browser eval --stdin
// Drives the dev shim (window.__core.send) through every built-in action and asserts the
// NUI callbacks the shell posted back. The last output line is "PASS n/m"; every failed
// check gets its own FAIL line, notes get a NOTE line.
//
// Capture: ui/src/bridge.js has no posts array - in dev mode post() does
// console.log('[core:ui] post', name, body), so the log is patched here (and window.fetch
// for a real NUI bridge). `ui_ready` is posted at mount, before this script can hook the
// log, so check it separately with:  agent-browser console | grep "post ui_ready"
(async () => {
  const out = []
  let pass = 0
  let total = 0
  const q = (s) => document.querySelector(s)
  const text = () => document.body.innerText || ''
  // innerText is the RENDERED text, so `text-transform: uppercase` titles come back upper case.
  const hasText = (s) => text().toLowerCase().indexOf(String(s).toLowerCase()) !== -1
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
  const tick = () => sleep(40)
  const say = (l) => { out.push(l); try { realLog.call(console, l) } catch (e) {} }
  const note = (m) => say('NOTE ' + m)
  const check = (name, ok) => { total++; if (ok) pass++; else say('FAIL ' + name) }
  async function waitFor (fn, ms) {
    const end = Date.now() + (ms || 1500)
    for (;;) {
      let ok = false
      try { ok = !!fn() } catch (e) { ok = false }
      if (ok) return true
      if (Date.now() >= end) return false
      await sleep(25)
    }
  }

  // ---- post capture -------------------------------------------------------
  const shim = window.__core || {}
  const posts = []
  let arr = null
  for (const k of ['posts', 'sent', 'calls']) { if (Array.isArray(shim[k])) { arr = shim[k]; break } }
  const realLog = console.log
  const realFetch = window.fetch
  console.log = function (a, b, c) {
    if (a === '[core:ui] post' && typeof b === 'string') posts.push({ name: b, data: c })
    return realLog.apply(console, arguments)
  }
  window.fetch = function (url, opt) {
    try { posts.push({ name: String(url).split('/').pop(), data: (opt && opt.body) ? JSON.parse(opt.body) : null }) } catch (e) {}
    return realFetch.apply(this, arguments)
  }
  const restore = () => { console.log = realLog; window.fetch = realFetch }
  function norm (e) {
    if (Array.isArray(e)) return { name: e[0], data: e[1] }
    if (e && typeof e === 'object') return { name: String(e.name || e.action || e.callback || '').split('/').pop(), data: e.data !== undefined ? e.data : e }
    return { name: String(e), data: null }
  }
  const mark = () => ({ p: posts.length, a: arr ? arr.length : 0 })
  function since (m) {
    const a = posts.slice(m.p)
    const b = arr ? arr.slice(m.a).map(norm) : []
    return a.concat(b.filter((x) => !a.some((y) => y.name === x.name && JSON.stringify(y.data) === JSON.stringify(x.data))))
  }
  const find = (m, n) => since(m).filter((p) => p.name === n).pop()
  const has = (m, n) => !!find(m, n)

  // ---- input helpers ------------------------------------------------------
  const CODES = { Enter: 13, Escape: 27, Backspace: 8, Tab: 9, ArrowUp: 38, ArrowDown: 40 }
  function key (k, shift) {
    const t = (document.activeElement && document.activeElement !== document.body) ? document.activeElement : document
    const ev = new KeyboardEvent('keydown', {
      key: k, code: k.length === 1 ? 'Key' + k.toUpperCase() : k, shiftKey: !!shift, bubbles: true, cancelable: true,
    })
    const kc = CODES[k] || k.toUpperCase().charCodeAt(0)
    try {
      Object.defineProperty(ev, 'keyCode', { get: () => kc })
      Object.defineProperty(ev, 'which', { get: () => kc })
    } catch (e) {}
    t.dispatchEvent(ev)
  }
  function setValue (el, v) {
    el.value = v
    el.dispatchEvent(new Event('input', { bubbles: true }))
    el.dispatchEvent(new Event('change', { bubbles: true }))
  }
  const setCheck = (el, on) => { el.checked = on; el.dispatchEvent(new Event('change', { bubbles: true })) }
  const send = (msg) => window.__core.send(msg)

  try {
    // ---- 0. shell ---------------------------------------------------------
    if (typeof shim.send !== 'function') {
      say('FAIL dev shim window.__core.send missing - open html/index.html directly (no GetParentResourceName)')
      say('PASS 0/1')
      return out.join('\n')
    }
    check('app mounted', !!q('#app') && q('#app').childElementCount > 0)
    check('window.CoreUI exposed', !!window.CoreUI && typeof window.CoreUI.registerPage === 'function')
    if (arr) check('ui_ready posted on mount', arr.map(norm).some((p) => p.name === 'ui_ready'))
    else note('ui_ready is posted before this script runs and the dev shim keeps no posts array - not checked')

    // ---- 1. notify --------------------------------------------------------
    send({ action: 'notify', id: 1, message: 'Regression notify', type: 'success', duration: 700, title: 'Notice' })
    await waitFor(() => hasText('Regression notify'))
    check('notify renders the message', hasText('Regression notify'))
    check('notify renders the title', hasText('Notice'))

    // ---- 2. text UI -------------------------------------------------------
    send({ action: 'textui:show', key: 'E', text: 'Open shop', position: 'bottom' })
    await waitFor(() => hasText('Open shop'))
    check('textui:show renders the text', hasText('Open shop'))
    check('textui:show renders the key with the text', Array.from(document.querySelectorAll('body *'))
      .some((el) => (el.innerText || '').toLowerCase().indexOf('open shop') !== -1 && /(^|\W)E(\W|$)/i.test(el.innerText || '')))
    send({ action: 'textui:hide' })
    check('textui:hide clears the pill', await waitFor(() => !hasText('Open shop')))
    check('notify auto-dismisses after its duration', await waitFor(() => !hasText('Regression notify'), 2500))

    // ---- 3. progress ------------------------------------------------------
    let m = mark()
    send({ action: 'progress:start', id: 11, label: 'Hotwiring', duration: 5000, canCancel: true })
    await waitFor(() => hasText('Hotwiring'))
    check('progress:start renders the label', hasText('Hotwiring'))
    key('x')
    await waitFor(() => has(m, 'progress_cancel'), 1200)
    const pc = find(m, 'progress_cancel')
    check('x posts progress_cancel', !!pc)
    check('progress_cancel carries the id', !!pc && !!pc.data && String(pc.data.id) === '11')
    check('progress bar hides on cancel', await waitFor(() => !hasText('Hotwiring')))
    send({ action: 'progress:stop', id: 11 })
    await tick()

    // ---- 4. menu ----------------------------------------------------------
    m = mark()
    send({ action: 'menu:open', id: 21, title: 'Test Menu', items: [
      { label: 'First item', value: 'one', icon: 'A' },
      { label: 'Second item', description: 'with description', value: 'two' },
      { label: 'Locked item', value: 'three', disabled: true },
    ] })
    await waitFor(() => hasText('Second item'))
    const sel = () => { const e = q('[role="menuitem"][aria-selected="true"]'); return e ? (e.innerText || '') : '' }
    const selHas = (s) => sel().toLowerCase().indexOf(s.toLowerCase()) !== -1
    check('menu:open renders every item', hasText('First item') && hasText('Locked item'))
    check('menu renders the description', hasText('with description'))
    check('menu highlights the first item on open', selHas('First item'))
    key('ArrowDown'); await tick()
    check('ArrowDown moves the highlight', selHas('Second item'))
    key('ArrowDown'); await tick()
    check('ArrowDown skips the disabled item and wraps', selHas('First item'))
    key('ArrowUp'); await tick()
    check('ArrowUp wraps back past the disabled item', selHas('Second item'))
    key('Enter')
    await waitFor(() => has(m, 'menu_result'))
    const mr = find(m, 'menu_result')
    check('Enter posts menu_result', !!mr)
    check('menu_result carries id + selected value', !!mr && !!mr.data && String(mr.data.id) === '21' && mr.data.value === 'two')
    check('menu closes after a selection', await waitFor(() => !hasText('Second item')))

    // ---- 5. input dialog --------------------------------------------------
    m = mark()
    send({ action: 'input:open', id: 31, title: 'Test Input', submit: 'Save', cancel: 'Back', fields: [
      { name: 'plate', label: 'Plate', type: 'text', required: true, placeholder: 'ABC 123' },
      { name: 'amount', label: 'Amount', type: 'number', default: 5, min: 1, max: 10 },
      { name: 'colour', label: 'Colour', type: 'select', options: [{ label: 'Red', value: 'red' }, 'blue'] },
      { name: 'agree', label: 'Agree', type: 'checkbox', default: false },
    ] })
    await waitFor(() => !!q('[data-field="plate"]'))
    check('input:open renders every field', ['plate', 'amount', 'colour', 'agree'].every((n) => !!q('[data-field="' + n + '"]')))
    check('select takes object and plain-string options',
      Array.from(document.querySelectorAll('[data-field="colour"] option')).map((o) => o.textContent).join(',') === 'Red,blue')
    check('number field takes its default', q('[data-field="amount"]').value === '5')
    key('Enter'); await tick()
    check('a required field blocks submit', !has(m, 'input_result'))
    check('a required field shows an inline error', !!q('[data-error="plate"]'))
    setValue(q('[data-field="plate"]'), 'XYZ 789'); await tick()
    check('the error clears once the field is filled', !q('[data-error="plate"]'))
    setValue(q('[data-field="amount"]'), '99')
    key('Enter'); await tick()
    check('number max blocks submit and shows an error', !has(m, 'input_result') && !!q('[data-error="amount"]'))
    setValue(q('[data-field="amount"]'), '7')
    setValue(q('[data-field="colour"]'), 'blue')
    setCheck(q('[data-field="agree"]'), true)
    await tick()
    q('[data-field="plate"]').focus()
    key('Tab'); await tick()
    check('Tab moves focus to the next control', document.activeElement === q('[data-field="amount"]'))
    key('Enter')
    await waitFor(() => has(m, 'input_result'))
    const ir = find(m, 'input_result')
    const iv = (ir && ir.data && ir.data.values) || null
    check('Enter posts input_result', !!ir)
    check('input_result carries the id', !!ir && !!ir.data && String(ir.data.id) === '31')
    check('input_result values are typed correctly',
      !!iv && iv.plate === 'XYZ 789' && iv.amount === 7 && iv.colour === 'blue' && iv.agree === true)
    check('input dialog closes after submit', await waitFor(() => !q('[data-field="plate"]')))

    // ---- 6. alert ---------------------------------------------------------
    m = mark()
    send({ action: 'alert:open', id: 41, title: 'Test Alert', message: 'Line one\nLine two', confirm: 'Yes', cancel: 'No' })
    await waitFor(() => hasText('Line one'))
    check('alert renders a multi-line message', hasText('Line one') && hasText('Line two'))
    check('alert renders confirm and cancel buttons', !!q('[data-role="confirm"]') && !!q('[data-role="cancel"]'))
    key('Enter')
    await waitFor(() => has(m, 'alert_result'))
    const ar = find(m, 'alert_result')
    check('Enter posts alert_result', !!ar)
    check('alert_result is confirmed with the id', !!ar && !!ar.data && ar.data.confirmed === true && String(ar.data.id) === '41')
    check('alert closes after confirm', await waitFor(() => !hasText('Line one')))

    // ---- 7. hud -----------------------------------------------------------
    send({ action: 'hud:set', visible: true, cash: 1234, bank: 56789, name: 'Tester', serverId: 7,
      faction: { name: 'Police', tag: 'LSPD', color: '#5b8cff' } })
    await waitFor(() => /1[.,\s']?234/.test(text()))
    check('hud renders cash', /1[.,\s']?234/.test(text()))
    check('hud renders bank', /56[.,\s']?789/.test(text()))
    check('hud renders the faction or the player name',
      hasText('LSPD') || hasText('Police') || hasText('Tester'))

    // ---- 8. plugin page host ----------------------------------------------
    const CoreUI = window.CoreUI
    if (!CoreUI || typeof CoreUI.registerPage !== 'function') {
      check('window.CoreUI.registerPage available', false)
    } else {
      send({ action: 'page:register', id: 'test', type: 'page', keepInput: false, style: null,
        script: 'data:text/javascript,window.__pageScriptRan=true' })
      check('page:register injects and runs the plugin script', await waitFor(() => window.__pageScriptRan === true, 1500))
      CoreUI.registerPage('test', { template: '<div class="test-page">hello</div>' })
      const events = []
      const off = typeof CoreUI.on === 'function' ? CoreUI.on('test', 'ping', (d) => events.push(d)) : null
      send({ action: 'page:open', id: 'test', props: { greeting: 'hi' } })
      let rendered = await waitFor(() => !!q('.test-page'), 2500)
      if (!rendered && window.Vue && typeof window.Vue.h === 'function') {
        note('the template option did not render - retried with a render function (the vue bundle has no runtime compiler)')
        CoreUI.registerPage('test', { render: () => window.Vue.h('div', { class: 'test-page' }, 'hello') })
        send({ action: 'page:close', id: 'test' }); await sleep(60)
        send({ action: 'page:open', id: 'test', props: { greeting: 'hi' } })
        rendered = await waitFor(() => !!q('.test-page'), 2500)
      }
      check('page:open renders the registered component', rendered && q('.test-page').textContent.toLowerCase().indexOf('hello') !== -1)
      send({ action: 'page:event', id: 'test', event: 'ping', data: { n: 1 } })
      await sleep(80)
      check('page:event reaches a CoreUI.on listener', events.length === 1 && !!events[0] && events[0].n === 1)
      m = mark()
      key('Escape')
      await waitFor(() => has(m, 'ui_close'), 900)
      const uc = find(m, 'ui_close')
      check('Escape on an open page posts ui_close', !!uc && (!uc.data || uc.data.page === 'test'))
      send({ action: 'page:close', id: 'test' })
      check('page:close removes the page', await waitFor(() => !q('.test-page'), 1200))
      if (typeof off === 'function') off()
      send({ action: 'page:unregister', id: 'test' })
    }

    say('PASS ' + pass + '/' + total)
    return out.join('\n')
  } finally {
    restore()
  }
})()
