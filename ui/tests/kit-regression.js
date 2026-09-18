// core UI kit regression test (DESIGN §37.7).
//   built shell:  (cd resources/core && python3 -m http.server 8765 --directory html &)
//                 agent-browser open "http://127.0.0.1:8765/index.html"
//   dev server:   (cd resources/core/ui && npx vite --port 5336 &)
//                 agent-browser open "http://localhost:5336/index.html"
//   then:         agent-browser eval --stdin < resources/core/ui/tests/kit-regression.js
//
// Runs against BOTH pages. It mounts kit components into scratch containers inside `.core-root`
// with `window.CoreUI.Vue` (createApp + h) and `window.CoreUI.kit.components` — no imports, no
// bundler — and drives them with real DOM events. Every case unmounts itself, drops its container
// and empties `#core-overlays`, so the shell underneath is exactly as it was.
//
// The last output line is "PASS n/m"; every failed check gets its own FAIL line with the detail,
// notes get a NOTE line. Two deliberate asymmetries between the two pages:
//   * §11 (the Chromium 103 CSS lint) only runs where a built `assets/app.css` exists — the dev
//     server answers that path with the SPA fallback HTML — so the built page runs more checks;
//   * Vue's own warnings only exist in the dev bundle, so §2's warn collector is sharp on the dev
//     server and vacuous on the build. The console spy next to it works on both.
//
// Keyboard: a synthetic KeyboardEvent never triggers a browser's native activation behaviour, so
// `press(el)` dispatches the keydown and then, when the component did not preventDefault and the
// target is an enabled <button>, the click the browser would have produced. That is what Enter on
// a focused CoreMenu row / CoreTab / CoreChip really is.
//
// Never spell the banned CSS filter property in this file: Tailwind's automatic source detection
// reads `ui/tests/*.js`, and a literal would generate the utility it is here to forbid. §11 builds
// the needle from pieces.
(async () => {
  const out = []
  let pass = 0
  let total = 0
  const realLog = console.log
  const say = (l) => { out.push(l); try { realLog.call(console, l) } catch (e) {} }
  const note = (m) => say('NOTE ' + m)
  const check = (name, ok, detail) => {
    total += 1
    if (ok) { pass += 1; return true }
    say('FAIL kit: ' + name + (detail === undefined || detail === null || detail === '' ? '' : ' — ' + detail))
    return false
  }
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
  /** The `core-pop` enter animates a transform, so geometry is only true once it is at rest. */
  const settle = () => sleep(320)

  const V = window.CoreUI && window.CoreUI.Vue
  const K = window.CoreUI && window.CoreUI.kit
  if (!V || typeof V.createApp !== 'function' || !K || !K.components) {
    say('FAIL kit: window.CoreUI.Vue + window.CoreUI.kit available — open the shell page, not a scene')
    say('PASS 0/1')
    return out.join('\n')
  }
  const h = V.h
  const nextTick = () => V.nextTick()
  const tick = async (n) => { for (let i = 0; i < (n || 2); i += 1) await nextTick(); await sleep(0) }
  const NAMES = Object.keys(K.components)
  const root = document.querySelector('.core-root') || document.body
  const overlays = () => document.getElementById('core-overlays') || document.body
  const clearOverlays = () => { const o = document.getElementById('core-overlays'); if (o) o.innerHTML = '' }
  const near = (a, b, eps) => Math.abs(Number(a) - Number(b)) <= (eps === undefined ? 0.5 : eps)
  const px = (el, prop) => getComputedStyle(el).getPropertyValue(prop).trim()

  async function waitFor (fn, ms) {
    const end = Date.now() + (ms || 1200)
    for (;;) {
      let ok = false
      try { ok = !!fn() } catch (e) { ok = false }
      if (ok) return true
      if (Date.now() >= end) return false
      await sleep(20)
    }
  }

  // ---- mounting ------------------------------------------------------------------------------
  // One Vue app per case, every kit component registered on it (a component's own children —
  // CoreIcon inside CoreButton — resolve globally, §37.3), with a warn/error collector and a
  // console spy so an unknown icon or a stray console.error is a failure too.
  const live = []
  const HOST_STYLE = 'position:fixed;left:0;top:0;width:100%;height:100%;pointer-events:none'

  function mountCase (options, hostStyle) {
    const el = document.createElement('div')
    el.className = 'kit-regression-host'
    el.style.cssText = hostStyle === undefined ? HOST_STYLE : hostStyle
    root.appendChild(el)
    const warns = []
    const app = V.createApp(options)
    app.config.warnHandler = (m) => warns.push('vue: ' + m)
    app.config.errorHandler = (e) => warns.push('error: ' + (e && e.message ? e.message : e))
    for (const n of NAMES) app.component(n, K.components[n])
    const realWarn = console.warn
    const realError = console.error
    console.warn = function (a) { warns.push('console.warn: ' + String(a)); return realWarn.apply(console, arguments) }
    console.error = function (a) { warns.push('console.error: ' + String(a)); return realError.apply(console, arguments) }
    let vm = null
    try { vm = app.mount(el) } finally { console.warn = realWarn; console.error = realError }
    const c = {
      el,
      app,
      vm,
      warns,
      q: (s) => el.querySelector(s),
      all: (s) => Array.from(el.querySelectorAll(s)),
      oq: (s) => overlays().querySelector(s),
      oall: (s) => Array.from(overlays().querySelectorAll(s)),
      async destroy () {
        const i = live.indexOf(c)
        if (i !== -1) live.splice(i, 1)
        try { app.unmount() } catch (e) {}
        el.remove()
        clearOverlays()
        await tick(1)
      },
    }
    live.push(c)
    return c
  }

  const eventProp = (e) => 'on' + String(e).replace(/(^|-)([a-z])/g, (m, d, ch) => ch.toUpperCase())

  /** Mounts one component with a live v-model and optional emit recorders. */
  function mountCtl (name, props, opts) {
    const o = opts || {}
    const modelProp = o.modelProp || 'modelValue'
    const st = V.reactive({ value: props ? props[modelProp] : undefined, events: [] })
    const listeners = {}
    for (const e of (o.events || [])) listeners[eventProp(e)] = (...a) => st.events.push({ name: e, args: a })
    const c = mountCase({
      render () {
        const p = Object.assign({}, props, listeners)
        p[modelProp] = st.value
        p['onUpdate:' + modelProp] = (v) => { st.value = v }
        return h(K.components[name], p, o.slots || null)
      },
    }, o.hostStyle)
    c.st = st
    c.emitted = (e) => st.events.filter((x) => x.name === e)
    c.last = (e) => c.emitted(e).slice(-1)[0]
    return c
  }

  // ---- input -----------------------------------------------------------------------------------
  const kd = (el, key, init) => {
    const ev = new KeyboardEvent('keydown', Object.assign({ key, bubbles: true, cancelable: true }, init))
    el.dispatchEvent(ev)
    return ev
  }
  /** Keydown + the click a browser would add on an enabled <button> (see the header). */
  const press = (el, key) => {
    const ev = kd(el, key || 'Enter')
    const isButton = el.tagName === 'BUTTON' || el.getAttribute('role') === 'button'
    if (!ev.defaultPrevented && isButton && !el.disabled) el.click()
    return ev
  }
  const setValue = (el, v) => { el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })) }
  const fireChange = (el) => el.dispatchEvent(new Event('change', { bubbles: true }))
  const pointerAt = (el, type, init) =>
    el.dispatchEvent(new PointerEvent(type, Object.assign({ bubbles: true, cancelable: true, button: 0 }, init)))
  const mouse = (el, type) => el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true }))

  try {
    say('NOTE kit regression — ' + NAMES.length + ' components, ' + Object.keys(K.icons || {}).length + ' icons')

    // ---- 1. registry (§37.5 catalogue) ---------------------------------------------------------
    // Hard-coded on purpose: the point is that the CATALOGUE and the bundle agree, so reading the
    // list back out of `K.components` would check nothing.
    const CATALOGUE = [
      'CoreIcon',
      'CoreButton', 'CoreIconButton', 'CoreKey', 'CoreKeyHint', 'CoreKeyHints', 'CorePrompt', 'CorePromptGroup',
      'CorePanel', 'CoreCard', 'CoreBackground', 'CoreScreen', 'CoreHeading', 'CoreDivider', 'CoreDash',
      'CoreTagline', 'CoreBrand',
      'CoreTabs', 'CoreMenu', 'CoreChips', 'CoreStepper',
      'CoreField', 'CoreInput', 'CoreTextarea', 'CoreNumberInput', 'CoreSelect',
      'CoreCheckbox', 'CoreRadioGroup', 'CoreRadio', 'CoreSwitch', 'CoreSlider', 'CoreSwatches',
      'CoreProgress', 'CoreRing', 'CoreStatBar', 'CoreStatRow', 'CoreSpinner', 'CoreSkeleton',
      'CoreBadge', 'CoreTag', 'CoreAvatar', 'CorePlayerChip', 'CoreTable', 'CoreKeyValue', 'CoreEmpty',
      'CoreSlot', 'CoreSlotGrid', 'CoreHotbar', 'CoreList', 'CoreListItem', 'CoreObjective', 'CoreTracker',
      'CoreCompass', 'CoreInteractionDot',
      'CoreAlert', 'CoreToast', 'CoreShard', 'CoreDialog', 'CoreDrawer', 'CorePopover', 'CoreContextMenu',
      'CoreTooltip',
    ]
    const missing = CATALOGUE.filter((n) => !K.components[n])
    const extra = NAMES.filter((n) => CATALOGUE.indexOf(n) === -1)
    check('every §37.5 catalogue component is registered', missing.length === 0, missing.join(', '))
    check('the bundle registers nothing the catalogue does not name', extra.length === 0,
      'extra: ' + extra.join(', '))
    check('catalogue size matches the bundle', CATALOGUE.length === NAMES.length,
      CATALOGUE.length + ' catalogue vs ' + NAMES.length + ' registered')
    const iconNames = Object.keys(K.icons || {})
    check('CoreUI.kit.icons has at least 150 glyphs', iconNames.length >= 150, iconNames.length + ' icons')
    check('CoreUI.kit.registerIcons is callable', typeof K.registerIcons === 'function')

    const PROBE_ICON = 'kit-regression-probe'
    const PROBE_PATH = 'M3 3H21V7H3Z'
    const added = typeof K.registerIcons === 'function' ? K.registerIcons({ [PROBE_ICON]: PROBE_PATH }) : []
    check('registerIcons reports the name it added',
      Array.isArray(added) && added.indexOf(PROBE_ICON) !== -1, JSON.stringify(added))
    let c = mountCase({ render: () => h(K.components.CoreIcon, { name: PROBE_ICON, size: 'lg' }) })
    check('CoreIcon renders a registered glyph', c.q('path') && c.q('path').getAttribute('d') === PROBE_PATH,
      c.q('path') ? c.q('path').getAttribute('d') : 'no <path>')
    check('CoreIcon sizes the svg from the size token',
      c.q('svg') && c.q('svg').getAttribute('width') === '24', c.q('svg') && c.q('svg').getAttribute('width'))
    await c.destroy()
    c = mountCase({ render: () => h(K.components.CoreIcon, { path: PROBE_PATH }) })
    check('CoreIcon takes raw path data', c.q('path') && c.q('path').getAttribute('d') === PROBE_PATH)
    await c.destroy()
    delete K.icons[PROBE_ICON]

    // ---- 2. mount-all smoke --------------------------------------------------------------------
    const ITEMS = [{ value: 'a', label: 'Alpha' }, { value: 'b', label: 'Bravo' }, { value: 'c', label: 'Charlie' }]
    const MOUNT = {
      CoreAlert: [{ tone: 'info', title: 'Alert', text: 'Body' }, () => 'body'],
      CoreAvatar: [{ name: 'Ada Byron', status: 'online' }],
      CoreBackground: [{ variant: 'scrim' }],
      CoreBadge: [{ value: 3 }],
      CoreBrand: [{ name: 'CORE', tagline: 'Los Santos' }],
      CoreButton: [{ variant: 'primary', kbd: 'F' }, () => 'Use'],
      CoreCard: [{ title: 'Card', subtitle: 'Sub', eyebrow: 'Last played' }, () => 'body'],
      CoreCheckbox: [{ modelValue: false, label: 'Check' }],
      CoreChips: [{ items: ITEMS, modelValue: 'a' }],
      CoreCompass: [{ heading: 90, markers: [{ heading: 180, label: 'WP' }], showBearing: true }],
      CoreInteractionDot: [{ focused: true, keys: 'F', label: 'Enter vehicle', icon: 'steering', x: 200, y: 120, options: [{ keys: 'R', label: 'Open trunk' }] }],
      CoreContextMenu: [{ open: true, position: { x: 40, y: 40 }, items: ITEMS }],
      CoreDash: [{ width: 28 }],
      CoreDialog: [{ open: true, title: 'Dialog', subtitle: 'Sub' }, () => 'body'],
      CoreDivider: [{ label: 'or' }],
      CoreDrawer: [{ open: true, title: 'Drawer' }, () => 'body'],
      CoreEmpty: [{ icon: 'close', title: 'Nothing', text: 'here' }],
      CoreField: [{ label: 'Label', hint: 'Hint' }, () => 'control'],
      CoreHeading: [{ title: 'Heading', subtitle: 'Sub', slash: true }],
      CoreHotbar: [{ items: [{ id: 1, count: 2 }], active: 0 }],
      CoreIcon: [{ name: 'check' }],
      CoreIconButton: [{ icon: 'close', label: 'Close' }],
      CoreInput: [{ modelValue: 'x', placeholder: 'p', clearable: true }],
      CoreKey: [{ label: 'F' }],
      CoreKeyHint: [{ keys: 'F', label: 'Use' }],
      CoreKeyHints: [{ items: [{ key: 'F', label: 'Use' }] }],
      CoreKeyValue: [{ items: [{ label: 'A', value: '1' }] }],
      CoreList: [{ items: [{ id: 1, title: 'Row' }], modelValue: 1 }],
      CoreListItem: [{ title: 'Row', subtitle: 'Sub' }],
      CoreMenu: [{ items: ITEMS, modelValue: 'a' }],
      CoreNumberInput: [{ modelValue: 3, min: 0, max: 9 }],
      CoreObjective: [{ text: 'Do it', state: 'active' }],
      CorePanel: [{ title: 'Panel', subtitle: 'Sub' }, () => 'body'],
      CorePlayerChip: [{ name: 'Ada', level: 5, progress: 0.4 }],
      CorePopover: [{ open: true, trigger: 'manual' }, () => 'pop'],
      CoreProgress: [{ value: 40, label: 'HP', showValue: true }],
      CorePrompt: [{ keys: 'F', label: 'Enter' }],
      CorePromptGroup: [{ items: [{ keys: 'F', label: 'Enter' }] }],
      CoreRadio: [{ value: 'a', label: 'A', modelValue: 'a' }],
      CoreRadioGroup: [{ items: ITEMS, modelValue: 'a' }],
      CoreRing: [{ value: 40 }],
      CoreScreen: [{ background: 'scrim' }, () => 'body'],
      CoreSelect: [{ items: ITEMS, modelValue: 'a' }],
      CoreShard: [{ title: 'WASTED', variant: 'wasted' }],
      CoreSkeleton: [{ lines: 2 }],
      CoreSlider: [{ modelValue: 40, label: 'FOV', showValue: true }],
      CoreSlot: [{ count: 3, rarity: 'rare', hotkey: '1', durability: 0.4 }],
      CoreSlotGrid: [{ items: [{ id: 1, count: 2 }], columns: 2, slots: 4 }],
      CoreSpinner: [{ label: 'Loading' }],
      CoreStatBar: [{ icon: 'check', value: 80 }],
      CoreStatRow: [{ icon: 'check', label: 'Health', value: '+75' }],
      CoreStepper: [{ items: ITEMS, modelValue: 'a', showCount: true }],
      CoreSwatches: [{ items: ['#f6503f', '#5dbbf7'], modelValue: '#f6503f' }],
      CoreSwitch: [{ modelValue: true, label: 'On' }],
      CoreTable: [{ columns: [{ key: 'a', label: 'A' }], rows: [{ id: 1, a: 'x' }] }],
      CoreTabs: [{ items: ITEMS, modelValue: 'a' }],
      CoreTag: [{ label: 'Tag', rarity: 'epic' }],
      CoreTagline: [{ lines: ['one', 'two'], rule: true }],
      CoreTextarea: [{ modelValue: 'x', rows: 2, counter: true, maxlength: 20 }],
      CoreToast: [{ tone: 'success', title: 'Saved', message: 'ok', dismissible: true }],
      CoreTooltip: [{ text: 'Tip' }, () => 'anchor'],
      CoreTracker: [{ title: 'Quest', text: 'Go', distance: '120 m' }],
    }
    const noProps = NAMES.filter((n) => !MOUNT[n])
    const threw = []
    const warned = []
    const empty = []
    for (const name of NAMES) {
      const spec = MOUNT[name] || [{}]
      let mc = null
      try {
        mc = mountCase({ render: () => h(K.components[name], spec[0], spec[1] ? { default: spec[1] } : null) })
        await tick(1)
        if (mc.warns.length) warned.push(name + ' -> ' + mc.warns.join(' | ').slice(0, 160))
        if (mc.el.childElementCount === 0 && overlays().childElementCount === 0) empty.push(name)
      } catch (e) {
        threw.push(name + ' -> ' + (e && e.message ? e.message : e))
      }
      if (mc) await mc.destroy()
      else clearOverlays()
    }
    check('every component has a minimal-props entry in this suite', noProps.length === 0, noProps.join(', '))
    check('every component mounts without throwing', threw.length === 0, threw.join(' ;; '))
    check('every component mounts without a Vue warning or a console warning',
      warned.length === 0, warned.join(' ;; '))
    check('every component renders something', empty.length === 0, 'rendered nothing: ' + empty.join(', '))
    note('Vue strips its warnings from a production bundle — the warn collector is only sharp on the dev server')

    // ---- 3. fonts (§37.1, kit/fonts.css) -------------------------------------------------------
    // check() reports false on a fresh page until a glyph of that face has actually been painted,
    // so every weight the kit names is loaded first.
    const FACES = ["400 16px 'Barlow'", "500 16px 'Barlow'", "600 16px 'Barlow'",
      "500 16px 'Barlow Condensed'", "600 16px 'Barlow Condensed'", "700 16px 'Barlow Condensed'"]
    try { await Promise.all(FACES.map((f) => document.fonts.load(f, 'AgN0'))) } catch (e) { note('font load: ' + e.message) }
    check('the bundled Barlow resolves', document.fonts.check("16px 'Barlow'"))
    check('the bundled Barlow Condensed resolves', document.fonts.check("16px 'Barlow Condensed'"))
    check('every weight the kit names is loaded', FACES.every((f) => document.fonts.check(f)),
      FACES.filter((f) => !document.fonts.check(f)).join(', '))
    const bodyFont = getComputedStyle(document.body).fontFamily
    check('the shell body asks for Barlow first', /barlow/i.test(bodyFont), bodyFont)

    // ---- 4. CoreButton (§37.5, Actions) --------------------------------------------------------
    {
      const clicks = []
      c = mountCase({
        render: () => h(K.components.CoreButton, {
          variant: 'primary', size: 'lg', fade: true, block: true, active: true, kbd: 'F', icon: 'check',
          onClick: (e) => clicks.push(e),
        }, { default: () => 'Use' }),
      })
      const btn = c.q('button')
      const cls = btn ? btn.className : ''
      check('CoreButton renders a real <button>', !!btn && btn.tagName === 'BUTTON')
      check('CoreButton wears its variant and size class', /core-btn--primary/.test(cls) && /core-btn--lg/.test(cls), cls)
      check('CoreButton wears is-fade / is-block / is-active',
        /is-fade/.test(cls) && /is-block/.test(cls) && /is-active/.test(cls), cls)
      check('CoreButton renders the key cap and the icon', !!c.q('.core-btn__kbd') && !!c.q('.core-btn__icon'))
      btn.click()
      await tick()
      check('a click on CoreButton emits click', clicks.length === 1, clicks.length + ' emits')
      await c.destroy()
    }
    {
      const clicks = []
      c = mountCase({ render: () => h(K.components.CoreButton, { disabled: true, onClick: () => clicks.push(1) }, { default: () => 'No' }) })
      c.q('button').click()
      await tick()
      check('disabled swallows the click', clicks.length === 0, clicks.length + ' emits')
      check('disabled sets the native attribute and is-disabled',
        c.q('button').disabled === true && /is-disabled/.test(c.q('button').className))
      await c.destroy()
    }
    {
      const clicks = []
      c = mountCase({ render: () => h(K.components.CoreButton, { loading: true, icon: 'check', onClick: () => clicks.push(1) }, { default: () => 'Busy' }) })
      c.q('button').click()
      await tick()
      check('loading swallows the click', clicks.length === 0, clicks.length + ' emits')
      check('loading swaps the icon for a spinner and keeps the label',
        !!c.q('.core-btn__spinner') && !c.q('.core-btn__icon') && /busy/i.test(c.q('.core-btn__label').textContent))
      check('loading reports aria-busy', c.q('button').getAttribute('aria-busy') === 'true')
      await c.destroy()
    }

    // ---- 5. v-model controls (§37.4: value carriers use v-model) --------------------------------
    {
      c = mountCtl('CoreCheckbox', { modelValue: false, label: 'Filter' })
      const box = c.q('input[type="checkbox"]')
      check('CoreCheckbox is a <label> around a real checkbox', !!c.q('label.core-check') && !!box)
      box.click()
      await tick()
      check('CoreCheckbox turns a boolean model on', c.st.value === true, String(c.st.value))
      check('the checked box wears is-checked', /is-checked/.test(c.q('.core-check').className))
      box.click()
      await tick()
      check('CoreCheckbox turns a boolean model off', c.st.value === false, String(c.st.value))
      await c.destroy()

      c = mountCtl('CoreCheckbox', { modelValue: ['a'], value: 'b', label: 'B' })
      c.q('input').click()
      await tick()
      check('CoreCheckbox adds its value to an array model', JSON.stringify(c.st.value) === '["a","b"]', JSON.stringify(c.st.value))
      c.q('input').click()
      await tick()
      check('CoreCheckbox removes its value from an array model', JSON.stringify(c.st.value) === '["a"]', JSON.stringify(c.st.value))
      await c.destroy()

      c = mountCtl('CoreCheckbox', { modelValue: false, indeterminate: true })
      await tick()
      check('indeterminate is written on the DOM property, not as an attribute',
        c.q('input').indeterminate === true && !c.q('input').hasAttribute('indeterminate'))
      await c.destroy()
    }
    {
      c = mountCtl('CoreRadioGroup', { items: ITEMS, modelValue: 'a' })
      const radios = c.all('input[type="radio"]')
      check('CoreRadioGroup renders one native radio per item', radios.length === 3, radios.length + ' inputs')
      check('the group shares one name', !!radios[0].name && radios[0].name === radios[2].name, radios[0].name)
      radios[1].click()
      await tick()
      check('CoreRadioGroup writes the clicked value', c.st.value === 'b', String(c.st.value))
      check('the checked option wears is-checked', /is-checked/.test(c.all('.core-radio')[1].className))
      await c.destroy()
    }
    {
      c = mountCtl('CoreSwitch', { modelValue: false, label: 'Nightvision' })
      const sw = c.q('.core-switch__input')
      check('CoreSwitch reports role=switch', sw.getAttribute('role') === 'switch')
      sw.click()
      await tick()
      check('CoreSwitch turns on', c.st.value === true, String(c.st.value))
      check('the on switch wears is-on', /is-on/.test(c.q('.core-switch').className))
      await c.destroy()
    }
    {
      c = mountCtl('CoreSlider', { modelValue: 20, min: 0, max: 100, step: 1, label: 'FOV', showValue: true },
        { events: ['change'] })
      const rng = c.q('input[type="range"]')
      setValue(rng, '62')
      await tick()
      check('CoreSlider updates the model while dragging', c.st.value === 62, String(c.st.value))
      check('CoreSlider does not emit change while dragging', c.emitted('change').length === 0)
      fireChange(rng)
      await tick()
      check('CoreSlider emits change on release',
        c.emitted('change').length === 1 && c.last('change').args[0] === 62, JSON.stringify(c.st.events))
      check('CoreSlider cuts the track at the value', px(c.q('.core-slider'), '--core-slider-pct') === '62%',
        px(c.q('.core-slider'), '--core-slider-pct'))
      check('CoreSlider prints the read-out', /62/.test(c.q('.core-slider__value').textContent))
      await c.destroy()
    }
    {
      c = mountCtl('CoreNumberInput', { modelValue: 3, min: 0, max: 5, step: 1 })
      const field = c.q('.core-number__el')
      pointerAt(c.q('.core-number__btn--inc'), 'pointerdown')
      window.dispatchEvent(new PointerEvent('pointerup'))
      await tick()
      check('the + button steps up', c.st.value === 4, String(c.st.value))
      pointerAt(c.q('.core-number__btn--dec'), 'pointerdown')
      window.dispatchEvent(new PointerEvent('pointerup'))
      await tick()
      check('the − button steps down', c.st.value === 3, String(c.st.value))
      field.focus()
      kd(field, 'ArrowUp')
      await tick()
      check('ArrowUp steps the field', c.st.value === 4, String(c.st.value))
      await c.destroy()

      c = mountCtl('CoreNumberInput', { modelValue: 5, min: 0, max: 5, step: 1 })
      const at = c.q('.core-number__el')
      check('the + button disables itself at max', c.q('.core-number__btn--inc').disabled === true)
      at.focus()
      kd(at, 'ArrowUp')
      await tick()
      check('ArrowUp clamps at max', c.st.value === 5, String(c.st.value))
      setValue(at, '99')
      kd(at, 'Enter')
      await tick()
      check('Enter commits a typed value and clamps it', c.st.value === 5 && at.value === '5',
        c.st.value + ' / "' + at.value + '"')
      await c.destroy()
    }
    {
      c = mountCtl('CoreStepper', { items: ITEMS, modelValue: 'a' })
      check('the prev chevron disables itself at the first item', c.q('.core-stepper__btn--prev').disabled === true)
      c.q('.core-stepper__btn--next').click()
      await tick()
      check('CoreStepper cycles items forward', c.st.value === 'b', String(c.st.value))
      check('the centre prints the item label', c.q('.core-stepper__label').textContent.trim() === 'Bravo')
      c.q('.core-stepper__btn--prev').click()
      await tick()
      check('CoreStepper cycles items back', c.st.value === 'a', String(c.st.value))
      kd(c.q('.core-stepper__value'), 'ArrowRight')
      await tick()
      check('ArrowRight steps the spinbutton', c.st.value === 'b', String(c.st.value))
      await c.destroy()

      c = mountCtl('CoreStepper', { min: 0, max: 10, step: 2, modelValue: 10, loop: true, showCount: true })
      c.q('.core-stepper__btn--next').click()
      await tick()
      check('a looping numeric stepper wraps past max', c.st.value === 0, String(c.st.value))
      check('showCount prints n / max', c.q('.core-stepper__count').textContent.trim() === '0 / 10',
        c.q('.core-stepper__count').textContent)
      await c.destroy()
    }

    {
      c = mountCtl('CoreChips', { items: ITEMS, modelValue: 'a' })
      c.all('.core-chip')[1].click()
      await tick()
      check('CoreChips selects the clicked chip', c.st.value === 'b', String(c.st.value))
      check('the active chip wears is-active', /is-active/.test(c.all('.core-chip')[1].className))
      c.all('.core-chip')[1].click()
      await tick()
      check('without allowEmpty the active chip stays on', c.st.value === 'b', String(c.st.value))
      await c.destroy()

      // Fresh instance: the roving index starts on the active chip, so the arrow move is
      // predictable (clicking a chip also moves it, which is why this is not the case above).
      c = mountCtl('CoreChips', { items: ITEMS, modelValue: 'a' })
      kd(c.all('.core-chip')[0], 'ArrowRight')
      await tick()
      check('← / → move the chip focus without changing the filter',
        document.activeElement === c.all('.core-chip')[1] && c.st.value === 'a',
        (document.activeElement && document.activeElement.textContent) + ' / ' + String(c.st.value))
      await c.destroy()

      c = mountCtl('CoreChips', { items: ITEMS, modelValue: 'b', allowEmpty: true })
      c.all('.core-chip')[1].click()
      await tick()
      check('allowEmpty lets the active chip switch off', c.st.value === null, String(c.st.value))
      await c.destroy()

      c = mountCtl('CoreChips', { items: ITEMS, modelValue: ['a'], multiple: true })
      c.all('.core-chip')[2].click()
      await tick()
      check('multiple pushes onto the array model', JSON.stringify(c.st.value) === '["a","c"]', JSON.stringify(c.st.value))
      c.all('.core-chip')[0].click()
      await tick()
      check('multiple removes from the array model', JSON.stringify(c.st.value) === '["c"]', JSON.stringify(c.st.value))
      await c.destroy()
    }
    {
      const TABS = [{ value: 'a', label: 'MAP' }, { value: 'b', label: 'LOCKED', disabled: true }, { value: 'c', label: 'GEAR' }]
      c = mountCtl('CoreTabs', { items: TABS, modelValue: 'a' }, { events: ['change'] })
      check('CoreTabs marks the active tab', c.all('.core-tab')[0].getAttribute('aria-selected') === 'true')
      check('only the active tab is in the tab order',
        c.all('.core-tab').map((t) => t.getAttribute('tabindex')).join(',') === '0,-1,-1')
      c.all('.core-tab')[2].click()
      await tick()
      check('a click selects a tab and emits change',
        c.st.value === 'c' && c.emitted('change').length === 1, String(c.st.value))
      kd(c.all('.core-tab')[2], 'Home')
      await tick()
      check('Home selects the first enabled tab', c.st.value === 'a', String(c.st.value))
      kd(c.all('.core-tab')[0], 'ArrowRight')
      await tick()
      check('ArrowRight skips the disabled tab', c.st.value === 'c', String(c.st.value))
      check('the arrow key moved the focus with the selection', document.activeElement === c.all('.core-tab')[2])
      kd(c.all('.core-tab')[2], 'End')
      await tick()
      check('End selects the last enabled tab', c.st.value === 'c', String(c.st.value))
      c.all('.core-tab')[1].click()
      await tick()
      check('a disabled tab cannot be clicked', c.st.value === 'c', String(c.st.value))
      await c.destroy()
    }
    {
      const ROWS = [{ value: 'a', label: 'Play' }, { value: 'b', label: 'Locked', disabled: true }, { value: 'c', label: 'Quit', danger: true }]
      c = mountCtl('CoreMenu', { items: ROWS, modelValue: 'a' }, { events: ['select'] })
      check('CoreMenu marks the active row', /is-active/.test(c.all('.core-menu__item')[0].className))
      check('a danger row wears is-danger', /is-danger/.test(c.all('.core-menu__item')[2].className))
      kd(c.all('.core-menu__item')[0], 'ArrowDown')
      await tick()
      check('ArrowDown skips the disabled row', c.st.value === 'c', String(c.st.value))
      check('the active row takes the focus', document.activeElement === c.all('.core-menu__item')[2])
      press(c.all('.core-menu__item')[2], 'Enter')
      await tick()
      check('Enter on the active row emits select',
        c.emitted('select').length === 1 && c.last('select').args[0].value === 'c', JSON.stringify(c.st.events.length))
      kd(c.all('.core-menu__item')[2], 'ArrowDown')
      await tick()
      check('ArrowDown wraps past the disabled row', c.st.value === 'a', String(c.st.value))
      await c.destroy()

      c = mountCtl('CoreMenu', { items: ITEMS, modelValue: 'a', selectOnHover: true })
      mouse(c.all('.core-menu__item')[1], 'mouseenter')
      await tick()
      check('selectOnHover activates the hovered row', c.st.value === 'b', String(c.st.value))
      await c.destroy()
    }
    {
      c = mountCtl('CoreInput', { modelValue: '', placeholder: 'Plate', clearable: true }, { events: ['enter', 'clear'] })
      const field = c.q('.core-inputbox__el')
      check('clearable hides the clear button while the field is empty', !c.q('.core-inputbox__clear'))
      setValue(field, 'XYZ 789')
      await tick()
      check('CoreInput writes what is typed to the model', c.st.value === 'XYZ 789', String(c.st.value))
      kd(field, 'Enter')
      await tick()
      check('Enter emits enter with the value',
        c.emitted('enter').length === 1 && c.last('enter').args[0] === 'XYZ 789', JSON.stringify(c.st.events))
      field.focus()
      await tick()
      check('focusing the field lights the box', /is-focused/.test(c.q('.core-inputbox').className),
        c.q('.core-inputbox').className)
      check('clearable shows the clear button once there is a value', !!c.q('.core-inputbox__clear'))
      c.q('.core-inputbox__clear').click()
      await tick()
      check('the clear button empties the model and emits clear',
        c.st.value === '' && c.emitted('clear').length === 1, String(c.st.value))
      await c.destroy()
    }
    {
      const OPTS = [{ value: 'a', label: 'Alpha' }, { value: 'b', label: 'Bravo', disabled: true }, { value: 'c', label: 'Charlie' }]
      c = mountCtl('CoreSelect', { items: OPTS, modelValue: 'a' }, { events: ['open', 'close'] })
      const trigger = c.q('.core-selectbox__trigger')
      const popup = () => overlays().querySelector('.core-selectbox__popup')
      const activeOpt = () => (popup() ? popup().querySelector('.core-selectbox__option.is-active') : null)
      check('a closed select prints the selected label', /alpha/i.test(c.q('.core-selectbox__value').textContent))
      trigger.click()
      await tick()
      check('a click on the trigger opens the popup', !!popup() && c.emitted('open').length === 1)
      check('the popup is teleported into #core-overlays', !!popup() && !!popup().closest('#core-overlays'))
      check('the trigger reports aria-expanded and the open class',
        trigger.getAttribute('aria-expanded') === 'true' && /is-open/.test(c.q('.core-selectbox').className))
      kd(trigger, 'ArrowDown')
      await tick()
      check('ArrowDown skips the disabled option',
        !!activeOpt() && activeOpt().getAttribute('data-index') === '2',
        activeOpt() && activeOpt().getAttribute('data-index'))
      kd(trigger, 'Enter')
      await tick()
      const closed = await waitFor(() => !popup(), 800) // the popup leaves through a transition
      check('Enter picks the active option and closes',
        c.st.value === 'c' && closed && c.emitted('close').length === 1,
        c.st.value + ' / closed=' + closed + ' / close emits=' + c.emitted('close').length)
      kd(trigger, 'ArrowDown')
      await tick()
      check('ArrowDown on a closed select opens it', !!popup())
      kd(trigger, 'a')
      await tick()
      check('typing jumps to the first matching label',
        !!activeOpt() && activeOpt().getAttribute('data-index') === '0',
        activeOpt() && activeOpt().getAttribute('data-index'))
      pointerAt(document.body, 'pointerdown')
      check('an outside pointerdown closes the popup', await waitFor(() => !popup(), 800))
      trigger.click()
      await tick()
      check('the selected option carries a check mark', !!popup() && !!popup().querySelector('.is-selected .core-selectbox__check'))
      await c.destroy()
      check('unmounting the select takes its popup with it', !overlays().querySelector('.core-selectbox__popup'))
    }

    {
      c = mountCtl('CoreSwatches', { items: ['#f6503f', '#5dbbf7', '#3fd67f'], modelValue: '#f6503f' })
      check('CoreSwatches paints each swatch with its colour',
        c.all('.core-swatch')[0].style.backgroundColor === 'rgb(246, 80, 63)',
        c.all('.core-swatch')[0].style.backgroundColor)
      c.all('.core-swatch')[1].click()
      await tick()
      check('CoreSwatches picks the clicked colour', c.st.value === '#5dbbf7', String(c.st.value))
      check('the picked swatch wears is-selected and aria-pressed',
        /is-selected/.test(c.all('.core-swatch')[1].className) && c.all('.core-swatch')[1].getAttribute('aria-pressed') === 'true')
      kd(c.all('.core-swatch')[1], 'ArrowRight')
      await tick()
      check('→ roves and picks the next swatch', c.st.value === '#3fd67f', String(c.st.value))
      await c.destroy()
    }
    {
      c = mountCtl('CoreSlotGrid',
        { items: [{ id: 'x', count: 1 }, { id: 'y', count: 2 }, { id: 'z', count: 3 }], columns: 2, slots: 6 },
        { modelProp: 'selected', events: ['select'] })
      const cells = () => c.all('.core-slot')
      check('slots pads the grid up to the capacity', cells().length === 6, cells().length + ' cells')
      check('the padding cells are empty', cells().slice(3).every((el) => /is-empty/.test(el.className)))
      cells()[1].click()
      await tick()
      check('a click selects the cell and emits select',
        c.st.value === 'y' && c.emitted('select').length === 1 && c.last('select').args[0].id === 'y', String(c.st.value))
      check('the selected cell wears is-selected', /is-selected/.test(cells()[1].className))
      cells()[1].focus()
      kd(cells()[1], 'ArrowDown')
      await tick()
      check('ArrowDown jumps a whole row', document.activeElement === cells()[3])
      kd(cells()[3], 'ArrowRight')
      await tick()
      check('ArrowRight walks to the next cell', document.activeElement === cells()[4])
      cells()[5].click()
      await tick()
      check('an empty cell cannot be selected', c.st.value === 'y', String(c.st.value))
      await c.destroy()
    }
    {
      c = mountCtl('CoreList', { items: [{ id: 1, title: 'Repossess' }, { id: 2, title: 'Chop shop' }], modelValue: null },
        { events: ['select'] })
      const rows = () => c.all('.core-listitem')
      check('CoreList renders one row per item and uses the listview class',
        rows().length === 2 && !!c.q('.core-listview'), rows().length + ' rows')
      rows()[1].click()
      await tick()
      check('CoreList selects the clicked row',
        c.st.value === 2 && c.last('select').args[0].title === 'Chop shop', String(c.st.value))
      check('the selected row wears is-selected', /is-selected/.test(rows()[1].className))
      rows()[1].focus()
      kd(rows()[1], 'ArrowUp')
      await tick()
      check('↑ roves to the row above', document.activeElement === rows()[0])
      await c.destroy()
    }
    {
      c = mountCtl('CoreTable', {
        columns: [{ key: 'name', label: 'NAME' }, { key: 'n', label: 'QTY', align: 'right' }],
        rows: [{ id: 1, name: 'Ada', n: 1 }, { id: 2, name: 'Bob', n: 2 }],
        selectable: true, selected: null,
      }, { modelProp: 'selected', events: ['row-click'] })
      const trs = () => c.all('.core-table__row')
      check('CoreTable prints the column labels',
        c.all('.core-table__th').map((t) => t.textContent).join(',') === 'NAME,QTY')
      check('a column align lands on the cell class', /--right/.test(c.all('.core-table__cell')[1].className))
      trs()[1].click()
      await tick()
      check('a selectable table selects the clicked row key',
        c.st.value === 2 && c.emitted('row-click').length === 1, String(c.st.value))
      check('the selected row wears is-selected', /is-selected/.test(trs()[1].className))
      kd(c.q('.core-table__body'), 'ArrowUp')
      await tick()
      check('↑ moves the table selection', c.st.value === 1, String(c.st.value))
      await c.destroy()
    }

    // ---- 6. Escape layers (§37.4) --------------------------------------------------------------
    // The store closes the open page on a BUBBLING window keydown; a kit popup registers a layer
    // whose CAPTURING listener stops the event dead. A bubbling window spy is therefore exactly
    // the store's seat: it must stay blind while a popup is open and see the key once it is not.
    function escapeSpy () {
      const hits = []
      const fn = (e) => { if (e.key === 'Escape' || e.key === 'Esc') hits.push(1) }
      window.addEventListener('keydown', fn)
      return {
        seen: () => hits.length,
        esc: () => kd(document.body, 'Escape'),
        stop: () => window.removeEventListener('keydown', fn),
      }
    }
    {
      const spy = escapeSpy()
      try {
        let mark = spy.seen()
        spy.esc()
        check('with nothing open Escape reaches the store\'s window listener', spy.seen() === mark + 1,
          spy.seen() - mark + ' hits')

        c = mountCtl('CoreSelect', { items: ITEMS, modelValue: 'a' })
        c.q('.core-selectbox__trigger').click()
        await tick()
        mark = spy.seen()
        spy.esc()
        await tick()
        check('an open select popup swallows Escape', spy.seen() === mark, spy.seen() - mark + ' hits')
        check('…and closes on it', await waitFor(() => !overlays().querySelector('.core-selectbox__popup'), 800))
        mark = spy.seen()
        spy.esc()
        check('the next Escape reaches the window again', spy.seen() === mark + 1, spy.seen() - mark + ' hits')
        await c.destroy()

        c = mountCtl('CorePopover', { open: true, trigger: 'manual' }, { modelProp: 'open', slots: { default: () => 'panel' } })
        await tick()
        mark = spy.seen()
        spy.esc()
        await tick()
        check('an open popover swallows Escape', spy.seen() === mark, spy.seen() - mark + ' hits')
        check('…and closes on it', c.st.value === false, String(c.st.value))
        await c.destroy()

        c = mountCtl('CoreContextMenu', { open: true, position: { x: 120, y: 120 }, items: ITEMS },
          { modelProp: 'open', events: ['select'] })
        await tick()
        mark = spy.seen()
        spy.esc()
        await tick()
        check('an open context menu swallows Escape', spy.seen() === mark, spy.seen() - mark + ' hits')
        check('…and closes on it', c.st.value === false, String(c.st.value))
        await c.destroy()

        c = mountCtl('CoreDialog', { open: true, title: 'Modal' }, { modelProp: 'open', slots: { default: () => 'body' } })
        await tick(3)
        mark = spy.seen()
        spy.esc()
        await tick(2)
        check('an open dialog swallows Escape', spy.seen() === mark, spy.seen() - mark + ' hits')
        check('…and closes on it', c.st.value === false, String(c.st.value))
        await c.destroy()

        // Nested: a select inside a dialog. The inner layer is on top, so the first Escape must
        // close the list and leave the modal standing.
        const nest = V.reactive({ open: true })
        c = mountCase({
          render: () => h(K.components.CoreDialog, {
            open: nest.open, title: 'Nested', 'onUpdate:open': (v) => { nest.open = v },
          }, { default: () => h(K.components.CoreSelect, { items: ITEMS, modelValue: 'a' }) }),
        })
        await tick(3)
        const nestedTrigger = overlays().querySelector('.core-selectbox__trigger')
        check('the select renders inside the teleported dialog', !!nestedTrigger)
        nestedTrigger.click()
        await tick()
        check('the nested select opens its popup', !!overlays().querySelector('.core-selectbox__popup'))
        mark = spy.seen()
        spy.esc()
        await tick(2)
        check('the first Escape closes the inner popup only',
          nest.open === true && await waitFor(() => !overlays().querySelector('.core-selectbox__popup'), 800),
          'dialog open=' + nest.open)
        check('the inner popup swallowed that Escape', spy.seen() === mark, spy.seen() - mark + ' hits')
        spy.esc()
        await tick(2)
        check('the second Escape closes the dialog', nest.open === false, String(nest.open))
        check('the dialog swallowed it too', spy.seen() === mark, spy.seen() - mark + ' hits')
        mark = spy.seen()
        spy.esc()
        check('with every layer popped Escape reaches the window again', spy.seen() === mark + 1)
        await c.destroy()
      } finally {
        spy.stop()
      }
    }

    // ---- 7. CoreDialog focus + close reasons (§37.5, Feedback) ---------------------------------
    {
      const st = V.reactive({ open: false, reasons: [] })
      c = mountCase({
        render: () => [
          h('button', { class: 'kit-opener', type: 'button', onClick: () => { st.open = true } }, 'Open'),
          h(K.components.CoreDialog, {
            open: st.open,
            title: 'Sell vehicle',
            subtitle: 'This cannot be undone',
            'onUpdate:open': (v) => { st.open = v },
            onClose: (reason) => st.reasons.push(reason),
          }, {
            default: () => h('p', 'The Sultan leaves the garage for $18,400.'),
            footer: () => [
              h(K.components.CoreButton, {}, { default: () => 'Cancel' }),
              h(K.components.CoreButton, { variant: 'primary' }, { default: () => 'Sell' }),
            ],
          }),
        ],
      })
      const opener = c.q('.kit-opener')
      const panel = () => overlays().querySelector('.core-dialog')
      opener.focus()
      check('the opener holds the focus before the dialog opens', document.activeElement === opener)
      opener.click()
      await tick(3)
      await sleep(30)
      check('the dialog teleports into #core-overlays', !!panel() && !!panel().closest('#core-overlays'))
      check('the dialog reports role=dialog + aria-modal',
        !!panel() && panel().getAttribute('role') === 'dialog' && panel().getAttribute('aria-modal') === 'true')
      check('focus moves inside the dialog on open', !!panel() && panel().contains(document.activeElement),
        document.activeElement && document.activeElement.className)
      const stops = Array.from(panel().querySelectorAll('button'))
      const first = stops[0]
      const last = stops[stops.length - 1]
      check('the dialog has a focus cycle to trap', stops.length >= 3, stops.length + ' focusables')
      last.focus()
      kd(last, 'Tab')
      await tick()
      check('Tab past the last control wraps to the first', document.activeElement === first,
        document.activeElement && document.activeElement.textContent)
      kd(first, 'Tab', { shiftKey: true })
      await tick()
      check('Shift+Tab before the first control wraps to the last', document.activeElement === last,
        document.activeElement && document.activeElement.textContent)
      kd(document.body, 'Escape')
      await tick(3)
      check('Escape closes a closable dialog with reason "escape"',
        st.open === false && st.reasons.slice(-1)[0] === 'escape', JSON.stringify(st.reasons))
      check('focus returns to the opener on close', document.activeElement === opener,
        document.activeElement && document.activeElement.className)
      await waitFor(() => !panel(), 800)

      opener.click()
      await tick(3)
      pointerAt(overlays().querySelector('.core-backdrop'), 'pointerdown')
      await tick(2)
      check('a backdrop pointerdown closes with reason "backdrop"',
        st.open === false && st.reasons.slice(-1)[0] === 'backdrop', JSON.stringify(st.reasons))
      await waitFor(() => !panel(), 800)

      opener.click()
      await tick(3)
      panel().querySelector('.core-dialog__close').click()
      await tick(2)
      check('the ✕ closes with reason "button"',
        st.open === false && st.reasons.slice(-1)[0] === 'button', JSON.stringify(st.reasons))
      await c.destroy()
    }
    {
      const spy = escapeSpy()
      const st = V.reactive({ open: true, reasons: [] })
      c = mountCase({
        render: () => h(K.components.CoreDialog, {
          open: st.open, persistent: true, title: 'Uploading',
          'onUpdate:open': (v) => { st.open = v },
          onClose: (reason) => st.reasons.push(reason),
        }, { default: () => 'Do not close this.' }),
      })
      await tick(3)
      const mark = spy.seen()
      spy.esc()
      await tick(2)
      check('persistent ignores Escape', st.open === true, String(st.open))
      check('persistent still swallows Escape, so the page behind it survives',
        spy.seen() === mark, spy.seen() - mark + ' hits')
      pointerAt(overlays().querySelector('.core-backdrop'), 'pointerdown')
      await tick(2)
      check('persistent ignores a backdrop click', st.open === true, String(st.open))
      overlays().querySelector('.core-dialog__close').click()
      await tick(2)
      check('persistent still closes through the ✕',
        st.open === false && st.reasons.slice(-1)[0] === 'button', JSON.stringify(st.reasons))
      spy.stop()
      await c.destroy()
    }

    // ---- 8. floating placement (§37.4: placeFloating flips, then clamps) -----------------------
    {
      const MANY = ['Inspect', 'Use', 'Split stack', 'Give', 'Drop', 'Destroy']
      // Opened AFTER the mount, the way a right-click opens it: a popup created already open
      // focuses itself one microtask before onMounted swaps its Teleport target, and moving a
      // focused node blurs it (see the report note on CoreContextMenu.vue).
      c = mountCtl('CoreContextMenu',
        { open: false, position: { x: window.innerWidth - 2, y: window.innerHeight - 2 }, items: MANY },
        { modelProp: 'open', events: ['select'] })
      await tick()
      c.st.value = true
      await tick(3)
      await settle()
      const menu = overlays().querySelector('.core-contextmenu')
      const r = menu ? menu.getBoundingClientRect() : null
      check('a context menu opened in the bottom-right corner is fully inside the viewport',
        !!r && r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight,
        r && JSON.stringify({ l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom), vw: window.innerWidth, vh: window.innerHeight }))
      check('it keeps the 8 px gap to the viewport edge',
        !!r && r.right <= window.innerWidth - 7 && r.bottom <= window.innerHeight - 7,
        r && (window.innerWidth - r.right) + ' / ' + (window.innerHeight - r.bottom))
      check('the context menu takes the focus so the arrows reach it', document.activeElement === menu)
      kd(menu, 'ArrowDown')
      await tick()
      check('ArrowDown lights the first row', !!menu.querySelector('.core-contextmenu__item.is-active'))
      menu.querySelectorAll('.core-contextmenu__item')[1].click()
      await tick()
      check('a click emits select with the row and closes the menu',
        c.emitted('select').length === 1 && c.last('select').args[0].label === 'Use' && c.st.value === false,
        JSON.stringify(c.st.events.length) + ' / open=' + c.st.value)
      await c.destroy()
      // Created ALREADY open: the popups resolve their Teleport target at setup (a lookup of the
      // existing #core-overlays), so the panel is never moved after it took the focus (§37.4).
      c = mountCtl('CoreContextMenu',
        { open: true, position: { x: 200, y: 200 }, items: MANY },
        { modelProp: 'open', events: ['select'] })
      await tick(3)
      await settle()
      const menu2 = overlays().querySelector('.core-contextmenu')
      check('a context menu created already open lands in #core-overlays and keeps the focus',
        !!menu2 && menu2.contains(document.activeElement),
        (menu2 ? 'in overlays' : 'not in overlays') + ' / active=' + (document.activeElement && document.activeElement.className))
      await c.destroy()
    }
    {
      // Interaction dot: the idle dot and the focused cap sit on the SAME anchor point, and looking
      // at it (focused) is what reveals the key and the label.
      c = mountCtl('CoreInteractionDot',
        { focused: false, keys: 'F', label: 'Enter vehicle', icon: 'steering', x: 300, y: 200, options: [{ keys: 'R', label: 'Open trunk' }] },
        { modelProp: 'focused', hostStyle: 'position:fixed;left:0;top:0;width:800px;height:500px;pointer-events:none' })
      await tick()
      const root = c.q('.core-interaction-dot')
      const dot = c.q('.core-interaction-dot__dot')
      const dotRect = dot ? dot.getBoundingClientRect() : null
      const idleCap = c.q('.core-interaction-dot__cap')
      check('an idle interaction dot shows its dot and keeps the cap invisible',
        !!dot && !root.classList.contains('is-focused')
          && (!idleCap || parseFloat(getComputedStyle(idleCap).opacity) < 0.05 || getComputedStyle(idleCap).visibility === 'hidden'),
        idleCap && 'cap opacity ' + getComputedStyle(idleCap).opacity + ' visibility ' + getComputedStyle(idleCap).visibility)
      check('the dot is absolutely placed at x/y',
        !!dotRect && Math.abs((dotRect.left + dotRect.width / 2) - 300) < 2 && Math.abs((dotRect.top + dotRect.height / 2) - 200) < 2,
        dotRect && Math.round(dotRect.left + dotRect.width / 2) + ',' + Math.round(dotRect.top + dotRect.height / 2))
      check('an interaction dot is click-through', getComputedStyle(root).pointerEvents === 'none')
      c.st.value = true
      await tick(2)
      await settle()
      const cap = c.q('.core-interaction-dot__cap')
      const capRect = cap ? cap.getBoundingClientRect() : null
      check('focusing the dot reveals the key cap and the label',
        root.classList.contains('is-focused') && !!cap && /Enter vehicle/i.test(root.textContent) && /Open trunk/i.test(root.textContent))
      check('the cap sits on the same anchor as the dot',
        !!capRect && Math.abs((capRect.left + capRect.width / 2) - 300) < 2 && Math.abs((capRect.top + capRect.height / 2) - 200) < 2,
        capRect && Math.round(capRect.left + capRect.width / 2) + ',' + Math.round(capRect.top + capRect.height / 2))
      await c.destroy()
    }
    {
      const MANY = ['Recent', 'Oldest', 'Rarity', 'Name', 'Weight', 'Value']
      c = mountCtl('CoreSelect', { items: MANY, modelValue: 'Recent' },
        { hostStyle: 'position:fixed;left:60px;bottom:14px;width:240px;pointer-events:none' })
      const trigger = c.q('.core-selectbox__trigger')
      trigger.click()
      await tick(3)
      await settle() // the `core-pop` enter scales the panel; measure only once it is at rest
      const popup = overlays().querySelector('.core-selectbox__popup')
      const pr = popup ? popup.getBoundingClientRect() : null
      const tr = trigger.getBoundingClientRect()
      check('a select at the bottom edge flips its popup upward',
        !!pr && pr.bottom <= tr.top + 1,
        pr && 'popup bottom ' + Math.round(pr.bottom) + ' vs trigger top ' + Math.round(tr.top))
      check('the flipped popup stays inside the viewport',
        !!pr && pr.top >= 0 && pr.bottom <= window.innerHeight,
        pr && Math.round(pr.top) + '..' + Math.round(pr.bottom))
      check('matchWidth makes the box popup at least as wide as the trigger',
        !!pr && pr.width >= tr.width - 1, pr && Math.round(pr.width) + ' vs ' + Math.round(tr.width))
      await c.destroy()
    }
    {
      c = mountCase({
        render: () => h(K.components.CoreTooltip, { text: 'Locked behind rank 12', delay: 150 },
          { default: () => h('button', { class: 'kit-tip', type: 'button' }, 'Hover me') }),
      }, 'position:fixed;left:420px;top:420px')
      const anchor = c.q('.core-tooltip__anchor')
      const tip = () => overlays().querySelector('.core-tooltip')
      mouse(anchor, 'mouseenter')
      await sleep(60)
      check('the tooltip waits out its delay before showing', !tip())
      check('the tooltip appears after its delay', await waitFor(() => !!tip(), 900))
      check('the tooltip carries its text', !!tip() && tip().textContent.indexOf('rank 12') !== -1)
      const trr = tip() ? tip().getBoundingClientRect() : null
      check('the tooltip is placed inside the viewport',
        !!trr && trr.top >= 0 && trr.left >= 0 && trr.right <= window.innerWidth && trr.bottom <= window.innerHeight)
      mouse(anchor, 'mouseleave')
      check('mouseleave takes the tooltip away', await waitFor(() => !tip(), 900))
      await c.destroy()
    }

    // ---- 9. meters (§37.5, Data — meters) ------------------------------------------------------
    {
      c = mountCase({ render: () => h(K.components.CoreProgress, { value: 25, min: 0, max: 200, label: 'CAPACITY', showValue: true }) })
      const track = c.q('.core-progress__track')
      check('the fill width is (value − min) / (max − min)', c.q('.core-progress__fill').style.width === '12.5%',
        c.q('.core-progress__fill').style.width)
      check('the track reports aria-valuenow / min / max',
        track.getAttribute('aria-valuenow') === '25' && track.getAttribute('aria-valuemin') === '0'
        && track.getAttribute('aria-valuemax') === '200')
      check('the read-out prints the value over the max', /25\s*\/\s*200/.test(c.q('.core-progress__value').textContent),
        c.q('.core-progress__value').textContent)
      await c.destroy()

      c = mountCase({ render: () => h(K.components.CoreProgress, { value: 18, tone: 'health', warnBelow: 35, dangerBelow: 10 }) })
      check('under warnBelow the bar switches to the warning tone',
        /core-tone-warning/.test(c.q('.core-progress').className), c.q('.core-progress').className)
      await c.destroy()
      c = mountCase({ render: () => h(K.components.CoreProgress, { value: 5, tone: 'health', warnBelow: 35, dangerBelow: 10 }) })
      check('under dangerBelow the bar switches to the danger tone',
        /core-tone-danger/.test(c.q('.core-progress').className), c.q('.core-progress').className)
      await c.destroy()
      c = mountCase({ render: () => h(K.components.CoreProgress, { value: 60, tone: 'health', warnBelow: 35, dangerBelow: 10 }) })
      check('above every threshold the bar keeps its own tone',
        /core-tone-health/.test(c.q('.core-progress').className), c.q('.core-progress').className)
      await c.destroy()

      c = mountCase({ render: () => h(K.components.CoreProgress, { value: 30, segments: 6 }) })
      check('segments cuts the track into cells',
        /is-segmented/.test(c.q('.core-progress').className) && px(c.q('.core-progress'), '--core-progress-cells') === '6',
        px(c.q('.core-progress'), '--core-progress-cells'))
      await c.destroy()
      c = mountCase({ render: () => h(K.components.CoreProgress, { indeterminate: true }) })
      check('an indeterminate bar drops aria-valuenow',
        !c.q('.core-progress__track').hasAttribute('aria-valuenow') && /is-indeterminate/.test(c.q('.core-progress').className))
      await c.destroy()
    }
    {
      c = mountCase({ render: () => h(K.components.CoreRing, { value: 25, max: 100, size: 48, thickness: 4 }) })
      const fill = c.q('.core-ring__fill')
      const circumference = 2 * Math.PI * 22 // r = (size − thickness) / 2
      check('the ring dash array is the circle circumference',
        near(fill.getAttribute('stroke-dasharray'), circumference, 0.01), fill.getAttribute('stroke-dasharray'))
      check('the ring dash offset is (1 − value / max) × circumference',
        near(fill.getAttribute('stroke-dashoffset'), circumference * 0.75, 0.01), fill.getAttribute('stroke-dashoffset'))
      check('the arc starts at 12 o\'clock through the SVG transform ATTRIBUTE',
        String(fill.getAttribute('transform')).replace(/\s+/g, ' ') === 'rotate' + '(-90 24 24)',
        fill.getAttribute('transform'))
      check('the ring reports its value to assistive tech',
        c.q('.core-ring').getAttribute('aria-valuenow') === '25')
      await c.destroy()
    }
    {
      c = mountCase({ render: () => h(K.components.CoreStatBar, { icon: 'check', value: 12, max: 100, lowBelow: 25 }) })
      check('a vital under lowBelow wears is-low', /is-low/.test(c.q('.core-statbar').className),
        c.q('.core-statbar').className)
      check('the statbar fill follows the value', c.q('.core-statbar__fill').style.width === '12%',
        c.q('.core-statbar__fill').style.width)
      check('the statbar prints a rounded value', c.q('.core-statbar__value').textContent.trim() === '12')
      await c.destroy()
      c = mountCase({ render: () => h(K.components.CoreStatBar, { icon: 'check', value: 80, lowBelow: 25 }) })
      check('a healthy vital does not wear is-low', !/is-low/.test(c.q('.core-statbar').className))
      await c.destroy()
    }

    // ---- 10. pointer events (§37.4: the shell is click-through) --------------------------------
    {
      const HUD = [
        ['CorePrompt', { keys: 'F', label: 'Enter vehicle' }, '.core-prompt'],
        ['CoreTracker', { title: 'Repossess', text: 'Reach the garage', distance: '120 m' }, '.core-tracker'],
        ['CoreCompass', { heading: 90 }, '.core-compass'],
        ['CoreInteractionDot', { keys: 'E', label: 'Search' }, '.core-interaction-dot'],
        ['CoreStatBar', { icon: 'check', value: 60 }, '.core-statbar'],
        ['CoreToast', { tone: 'info', title: 'Saved', message: 'ok' }, '.core-toast'],
        ['CoreShard', { title: 'WASTED', variant: 'wasted' }, '.core-shard'],
        ['CorePlayerChip', { name: 'Ada', level: 5, progress: 0.4 }, '.core-playerchip'],
      ]
      const INTERACTIVE = [
        ['CoreButton', {}, '.core-btn', () => 'Use'],
        ['CoreIconButton', { icon: 'close', label: 'Close' }, '.core-iconbtn'],
        ['CoreTabs', { items: ITEMS }, '.core-tabs'],
        ['CoreMenu', { items: ITEMS }, '.core-menu'],
        ['CoreChips', { items: ITEMS }, '.core-chips'],
        ['CoreInput', { modelValue: '' }, '.core-inputbox'],
        ['CoreSelect', { items: ITEMS }, '.core-selectbox'],
        ['CoreSlot', { count: 1 }, '.core-slot'],
        ['CorePrompt', { keys: 'F', label: 'Buy', interactive: true }, '.core-prompt'],
      ]
      const wrong = []
      for (const [name, props, sel, slot] of HUD) {
        c = mountCase({ render: () => h(K.components[name], props, slot ? { default: slot } : null) })
        await tick(1)
        const el = c.q(sel)
        const pe = el ? getComputedStyle(el).pointerEvents : 'missing'
        if (pe !== 'none') wrong.push(name + ' = ' + pe)
        if (name === 'CorePrompt') {
          check('the scratch host really is click-through',
            getComputedStyle(c.el).pointerEvents === 'none', getComputedStyle(c.el).pointerEvents)
        }
        await c.destroy()
      }
      check('every HUD-type root computes pointer-events: none', wrong.length === 0, wrong.join(', '))
      const deaf = []
      for (const [name, props, sel, slot] of INTERACTIVE) {
        c = mountCase({ render: () => h(K.components[name], props, slot ? { default: slot } : null) })
        await tick(1)
        const el = c.q(sel)
        const pe = el ? getComputedStyle(el).pointerEvents : 'missing'
        if (pe !== 'auto') deaf.push(name + ' ' + sel + ' = ' + pe)
        await c.destroy()
      }
      check('every interactive root computes pointer-events: auto inside a click-through parent',
        deaf.length === 0, deaf.join(', '))
    }

    // ---- 11. Chromium 103 lint on the BUILT css (§37.4) ----------------------------------------
    // Only the build has `assets/app.css`; the dev server answers that path with the SPA fallback
    // HTML, so the section announces itself and steps aside. The needles are assembled from pieces
    // because Tailwind's automatic source detection reads this file.
    {
      let css = null
      try {
        const res = await fetch('./assets/app.css')
        const type = String(res.headers.get('content-type') || '')
        const body = res.ok ? await res.text() : ''
        if (res.ok && (type.indexOf('css') !== -1 || body.trim().charAt(0) !== '<')) css = body
      } catch (e) {
        note('assets/app.css could not be fetched: ' + e.message)
      }
      if (css === null) {
        note('no built assets/app.css on this page (dev server) — the CSS lint is skipped; run the '
          + 'suite against html/index.html for it')
      } else {
        note('linting the built app.css (' + css.length + ' bytes)')
        // A declaration is `<prop>:` right after `{`, `;` or a newline — which is what tells the
        // banned filter apart from its harmless mention inside a `transition-property` list.
        const FILTER = 'backdrop' + '-' + 'filter'
        const declRe = (prop) => new RegExp('(^|[{;])\\s*(-webkit-)?' + prop + '\\s*:', 'g')
        const hits = (re) => (css.match(re) || []).length
        check('no :has() in the built css', hits(/:has\(/g) === 0, hits(/:has\(/g) + ' hits')
        check('no @container at-rule in the built css',
          hits(/(^|[^\\A-Za-z0-9_-])@container[\s({]/g) === 0,
          'the `.\\@container` utility class is not one: ' + hits(/@container/g) + ' raw occurrences')
        check('the banned filter property is never declared', hits(declRe(FILTER)) === 0,
          hits(declRe(FILTER)) + ' declarations')
        const mentions = hits(new RegExp(FILTER, 'g'))
        if (mentions > 0) note('the banned filter is named ' + mentions + ' time(s) outside a declaration '
          + "(Tailwind's `transition` utility lists it as a transition-property) — harmless, nothing paints")
        // §37.4 forbids the individual transform properties in KIT css. A Tailwind utility a plugin
        // page uses lands in the same bundle, so every hit is traced back to its selector: from a
        // `.core-…` rule it is a failure, anything else is a warning with the value.
        const transformRe = /(^|[{;])\s*(translate|rotate|scale)\s*:\s*([^;{}]+)/g
        const found = []
        let m = transformRe.exec(css)
        while (m) {
          const brace = css.lastIndexOf('{', m.index)
          const before = Math.max(css.lastIndexOf('}', brace), css.lastIndexOf('{', brace - 1))
          found.push({ prop: m[2], value: m[3].trim(), selector: css.slice(before + 1, brace).trim() })
          m = transformRe.exec(css)
        }
        const fromKit = found.filter((d) => d.selector.indexOf('.core-') !== -1)
        check('no kit class declares an individual translate / rotate / scale property',
          fromKit.length === 0, fromKit.map((d) => d.selector + ' { ' + d.prop + ': ' + d.value + ' }').join(' ;; '))
        for (const d of found) {
          note('WARN `' + d.prop + ': ' + d.value.slice(0, 50) + '` in `' + d.selector.slice(0, 50) + '` — '
            + (d.value.indexOf('--tw-') !== -1
              ? 'a page uses a Tailwind transform utility'
              : 'a utility or page rule, not a kit class (the kit partials are proven clean by '
                + 'node ui/tests/kit-compile-check.mjs)'))
        }
        // `@supports (color:color-mix(in lab,red,red))` carries `color-mix(` in its CONDITION, so
        // the heads are stepped over and only the bodies are searched.
        const stray = []
        let depth = 0
        const supports = []
        for (let i = 0; i < css.length;) {
          const ch = css[i]
          if (ch === '"' || ch === "'") {
            const quote = ch
            i += 1
            while (i < css.length && css[i] !== quote) i += (css[i] === '\\' ? 2 : 1)
            i += 1
            continue
          }
          if (ch === '@' && css.startsWith('@supports', i)) {
            const brace = css.indexOf('{', i)
            if (brace === -1) break
            depth += 1
            supports.push(depth)
            i = brace + 1
            continue
          }
          if (ch === '{') { depth += 1; i += 1; continue }
          if (ch === '}') {
            if (supports.length && supports[supports.length - 1] === depth) supports.pop()
            depth -= 1
            i += 1
            continue
          }
          if (ch === 'c' && css.startsWith('color-mix(', i)) {
            if (supports.length === 0) stray.push(css.slice(Math.max(0, i - 40), i + 40))
            i += 10
            continue
          }
          i += 1
        }
        check('every color-mix() sits inside an @supports block', stray.length === 0,
          stray.length + ' outside: ' + stray.slice(0, 2).join(' ;; '))
        check('the kit classes made it into the bundle',
          css.indexOf('.core-btn') !== -1 && css.indexOf('.core-slotgrid') !== -1 && css.indexOf('.core-dialog') !== -1)
        check('the bundled fonts are declared', /@font-face/.test(css) && /Barlow/.test(css))
      }
    }

    say('PASS ' + pass + '/' + total)
    return out.join('\n')
  } finally {
    for (const c of live.slice()) { try { c.app.unmount() } catch (e) {} ; c.el.remove() }
    live.length = 0
    clearOverlays()
  }
})()
