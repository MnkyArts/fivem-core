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
      // A plugin restart drops and recreates the record (page:unregister + page:register). A page
      // store that captured `usePage(id).props` at its birth must keep working, so the props object
      // of an id is stable for the life of the shell (DESIGN §7.4).
      const propsBefore = typeof CoreUI.usePage === 'function' ? CoreUI.usePage('test').props : null
      send({ action: 'page:unregister', id: 'test' })
      send({ action: 'page:register', id: 'test', type: 'page', keepInput: false, style: null, script: null })
      check('page props keep their identity across unregister + register',
        !!propsBefore && CoreUI.usePage('test').props === propsBefore)
      send({ action: 'page:open', id: 'test', props: { greeting: 'again' } })
      await sleep(60)
      check('page:open after a re-register fills the same props object', !!propsBefore && propsBefore.greeting === 'again')
      send({ action: 'page:close', id: 'test' })
      await waitFor(() => !q('.test-page'), 1200)
      send({ action: 'page:unregister', id: 'test' })
    }

    // ---- 9. shell visibility (DESIGN §31) ---------------------------------
    // client/ui.lua hides the whole shell while it holds a reason (pause menu, screen fade,
    // cutscene, `Core.UI.hide`). Only the paint stops: nothing unmounts, so the state posted
    // before the flip is still there when it comes back.
    const vis = (el) => (el ? getComputedStyle(el).visibility : '')
    const root = q('.core-root')
    send({ action: 'notify', id: 91, message: 'Survives the pause menu', type: 'info', duration: 60000 })
    send({ action: 'textui:show', key: 'E', text: 'Hidden while paused', position: 'bottom' })
    await waitFor(() => hasText('Hidden while paused'))
    send({ action: 'shell:visible', visible: false, reasons: ['game:pause'] })
    await waitFor(() => vis(root) === 'hidden')
    check('shell:visible false hides .core-root', !!root && vis(root) === 'hidden')
    check('a hidden shell renders no text UI',
      !hasText('Hidden while paused') && !!q('.textui') && vis(q('.textui')) === 'hidden')
    send({ action: 'shell:visible', visible: true, reasons: [] })
    await waitFor(() => vis(root) === 'visible')
    check('shell:visible true restores the shell with the toast posted before it hid',
      vis(root) === 'visible' && hasText('Survives the pause menu') && hasText('Hidden while paused'))
    send({ action: 'textui:hide' })

    // ---- 10. game blur (DESIGN §32) ---------------------------------------
    // A browser has no FiveM render hook, so the probe finds the 1x1 placeholder and the source
    // becomes the painted dusk gradient. What a panel actually shows is the `.core-glass`
    // wrapper and its canvas, and `blur:set` has to be able to take both away again.
    const glassHost = root || document.body
    const glassMode = () => document.documentElement.dataset.gameBlur || ''
    check('game blur reports the fallback source in a browser', glassMode() === 'fallback')
    const glassPanel = document.createElement('div')
    glassPanel.setAttribute('data-core-blur', '')
    glassPanel.style.cssText = 'width:260px;height:150px;margin:40px'
    glassHost.appendChild(glassPanel)
    check('a data-core-blur panel gets a .core-glass canvas',
      await waitFor(() => !!glassPanel.querySelector('.core-glass > canvas'), 1500))
    send({ action: 'blur:set', enabled: false })
    await waitFor(() => !q('.core-glass') && glassMode() === 'off', 1500)
    check('blur:set enabled=false drops every .core-glass and reports off',
      !q('.core-glass') && glassMode() === 'off')
    send({ action: 'blur:set', enabled: true })
    await waitFor(() => glassMode() === 'fallback', 1500)
    glassPanel.remove()

    // ---- 11. chat (DESIGN §30.3) ------------------------------------------
    const chatSend = (line) => send({ action: 'chat:add', line: { name: 'Ada', kind: 'message', opacity: 1, ...line } })
    const openChat = async () => {
      send({ action: 'chat:open', open: true })
      await waitFor(() => !!q('.chat input') && document.activeElement === q('.chat input'))
      return q('.chat input')
    }
    const configureChat = (extra = {}) => send({ action: 'chat:suggestions', items: [
      { command: '/pm', description: 'Private message', params: [{ name: '<target>', type: 'player', help: 'Server ID' }, { name: '<message>', type: 'rest', help: 'Message text' }] },
      { command: '/ping', description: 'Check latency', params: [] },
      { command: '/ooc', description: 'Out-of-character chat', params: [{ name: '<message>', type: 'rest' }] },
      { command: '/ooc' },
    ], channels: [{ id: 'local', label: 'Local' }, { id: 'ooc', label: 'OOC', command: 'ooc' }], hideDelayMs: 180, ...extra })
    send({ action: 'chat:clear' })
    configureChat()
    chatSend({ id: 1, tag: '[DEV] ', text: 'hello from Ada' })
    check('chat:add renders the line', await waitFor(() => hasText('hello from Ada')))
    check('name separator and faction tag have literal spaces', q('.chat .line').textContent === '[DEV] Ada: hello from Ada')
    check('idle feed has no panel background', getComputedStyle(q('.chat .feed')).backgroundColor === 'rgba(0, 0, 0, 0)')
    check('chat fades after configured inactivity', await waitFor(() => getComputedStyle(q('.chat .feed')).visibility === 'hidden'))
    check('fading retains the line for reading history', !!q('.chat .line'))

    let chatInput = await openChat()
    check('T opens and focuses the input', !!chatInput && document.activeElement === chatInput)
    check('opening restores expired history', await waitFor(() => hasText('hello from Ada')))
    await sleep(250)
    check('chat never expires while typing', q('.feed').classList.contains('feed-visible'))
    setValue(chatInput, 'proximity hello')
    key('Tab')
    check('Tab does not destroy ordinary text', chatInput.value === 'proximity hello')
    key('Enter')
    check('Enter posts text and the active channel', await waitFor(() => posts.some(p => p.name === 'chat_send' && p.data.text === 'proximity hello' && p.data.channel === 'local')))
    check('input closes after send', await waitFor(() => !q('.chat input')))
    check('closing restarts idle fade', await waitFor(() => getComputedStyle(q('.feed')).visibility === 'hidden'))
    chatSend({ id: 2, text: 'new message wakes chat', opacity: 0.4 })
    check('new message wakes the feed', await waitFor(() => q('.feed').classList.contains('feed-visible')))
    check('proximity opacity remains server-owned', q('.chat .line:last-child').style.opacity === '0.4')
    chatInput = await openChat()
    check('reading mode restores proximity opacity', q('.chat .line:last-child').style.opacity === '1')
    setValue(chatInput, 'unsent draft')
    key('ArrowUp'); await tick()
    check('Up recalls previous sent text', chatInput.value === 'proximity hello')
    key('ArrowDown'); await tick()
    check('Down restores the unsent draft', chatInput.value === 'unsent draft')
    setValue(chatInput, '/p'); await tick()
    check('slash prefix displays matching commands below input', document.querySelectorAll('.command-option').length === 2 && q('.command-list').getBoundingClientRect().top > chatInput.getBoundingClientRect().bottom)
    check('command list includes descriptions and params', q('.command-list').textContent.includes('Private message') && q('.command-list').textContent.includes('<target>'))
    const beforeCommand = mark()
    key('ArrowDown'); await tick()
    check('Down highlights the next command without changing draft', q('[aria-selected="true"]').textContent.includes('/pm') && chatInput.value === '/p')
    key('ArrowUp'); await tick()
    check('Up navigates back through suggestions', q('[aria-selected="true"]').textContent.includes('/ping'))
    key('ArrowUp'); await tick()
    check('suggestion navigation wraps', q('[aria-selected="true"]').textContent.includes('/pm'))
    key('Enter'); await tick()
    check('Enter accepts partial command without executing it', chatInput.value === '/pm ' && !has(beforeCommand, 'chat_command'))
    check('first argument is highlighted with help and type', q('.param-active')?.textContent === '<target>' && q('#chat-argument-help')?.textContent.includes('Server ID') && q('#chat-argument-help')?.textContent.includes('player'))
    setValue(chatInput, '/pm 12 hello world'); await tick()
    check('rest argument stays highlighted across words', q('.param-active')?.textContent === '<message>')
    chatInput.setSelectionRange(5, 5)
    chatInput.dispatchEvent(new Event('select'))
    await tick()
    check('moving the caret updates the active argument', q('.param-active')?.textContent === '<target>')
    chatInput.setSelectionRange(chatInput.value.length, chatInput.value.length)
    chatInput.dispatchEvent(new Event('select'))
    await tick()
    key('Enter')
    check('complete command submits original slash line', await waitFor(() => find(beforeCommand, 'chat_command')?.data.raw === '/pm 12 hello world'))

    chatInput = await openChat()
    setValue(chatInput, '/oo'); await tick()
    check('duplicate command/channel suggestions collapse', document.querySelectorAll('.command-option').length === 1)
    key('Tab'); await tick()
    check('Tab completes command and appends a space', chatInput.value === '/ooc ')
    setValue(chatInput, 'composing text')
    const beforeIme = mark()
    chatInput.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', isComposing: true, bubbles: true, cancelable: true }))
    await tick()
    check('IME Enter does not submit', !!q('.chat input') && !has(beforeIme, 'chat_send'))
    chatInput.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', ctrlKey: true, bubbles: true, cancelable: true }))
    await tick()
    check('Ctrl+Tab changes channels', q('.chan-btn').textContent === 'OOC')
    chatInput.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', ctrlKey: true, shiftKey: true, bubbles: true, cancelable: true }))
    await tick()
    check('Ctrl+Shift+Tab reverses channels', q('.chan-btn').textContent === 'Local')
    configureChat({ maxLength: 5 })
    await tick()
    setValue(chatInput, 'äöü'); await tick()
    check('message limit counts UTF-8 bytes without splitting characters', chatInput.value === 'äö')
    key('Escape')
    check('Escape closes input', await waitFor(() => !q('.chat input')))
    await openChat()
    send({ action: 'shell:visible', visible: false })
    check('shell hide cancels chat', await waitFor(() => !q('.chat input')))
    check('visible chat lines cannot override shell visibility', getComputedStyle(q('.chat .feed')).visibility === 'hidden')
    send({ action: 'shell:visible', visible: true })
    await tick()
    check('shell restore does not reopen cancelled input', !q('.chat input'))
    await openChat()
    send({ action: 'menu:open', id: 'chat-focus-test', title: 'Modal takes focus', items: [] })
    check('modal takeover closes chat', await waitFor(() => !q('.chat input')))
    send({ action: 'menu:close' })
    await tick()

    configureChat({ history: 5, visibleLines: 2, hideDelayMs: 0 })
    send({ action: 'chat:clear' })
    for (let i = 0; i < 10; i++) chatSend({ id: i, text: 'history line ' + i })
    await tick()
    check('closed feed uses the configured visible line limit', document.querySelectorAll('.chat .line').length === 2)
    await sleep(250)
    check('zero delay explicitly disables idle fading', q('.feed').classList.contains('feed-visible'))
    await openChat()
    check('open history uses the configured retained line limit', document.querySelectorAll('.chat .line').length === 5)
    check('oldest history entries are pruned', !q('.feed').textContent.includes('history line 4') && q('.feed').textContent.includes('history line 5'))
    configureChat({ history: 80, visibleLines: 8, hideDelayMs: 8000 })
    for (let i = 0; i < 100; i++) chatSend({ text: 'scroll line ' + i })
    await tick()
    check('feed autoscrolls after new lines even at capacity', Math.abs(q('.feed').scrollHeight - q('.feed').clientHeight - q('.feed').scrollTop) < 2)
    key('PageUp'); await tick()
    check('PageUp reads older history without pointer focus', q('.feed').scrollTop < q('.feed').scrollHeight - q('.feed').clientHeight - 5)
    key('Escape'); await tick()
    send({ action: 'chat:clear' })
    check('chat:clear removes all history without an empty panel', await waitFor(() => !q('.chat .line') && getComputedStyle(q('.feed')).display === 'none'))

    say('PASS ' + pass + '/' + total)
    return out.join('\n')
  } finally {
    restore()
  }
})()
