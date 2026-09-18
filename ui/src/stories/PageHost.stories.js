// Plugin page host (DESIGN §7.4) — a page bundle registers a component through
// window.CoreUI.registerPage(id, component) and Lua opens it with `page:open`.
//
// Lua side: `Core.UI.registerPage(id, { type })` declares the page, `Core.UI.open(id, props)`
// shows it and grabs focus, `Core.UI.send(id, event, data)` pushes into it, and
// `Core.UI.on(id, event, fn)` receives what the page emits (an `ui_event` callback becomes
// `TriggerEvent('core:ui:<id>:<event>', data)` on the client).
//
// Both sample components are built with h(): the shipped NUI bundle is the runtime-only
// Vue build, so a real plugin page cannot use a template string either.
import { h, ref } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import PageHost from '../shell/PageHost.vue'
import Notifications from '../shell/Notifications.vue'
import { send, liveScene, rail, clone } from './storeHelpers.js'
import { lastPost } from './luaBridge.js'

// The toast rail rides along: a page raises toasts through CoreUI.notify, and the host
// itself warns with one when a bundle never showed up.
const view = () => [h(PageHost), rail(h(Notifications))]

const PAGE_ID = 'sb_demo_shop'
const OVERLAY_ID = 'sb_demo_duty'

const money = (n) => '$' + Math.round(Number(n) || 0).toLocaleString('en-US')

/** A full-screen page: centred panel, buys through CoreUI.emit, closes through CoreUI.close. */
const ShopPage = {
  name: 'DemoShopPage',
  props: { props: { type: Object, default: () => ({}) } },
  setup (vm) {
    const CoreUI = window.CoreUI
    const page = CoreUI.usePage(PAGE_ID)
    const selected = ref(0)
    const items = () => (Array.isArray(vm.props.items) ? vm.props.items : [])

    const buy = (item, i) => {
      selected.value = i
      page.emit('buy', { item: item.id, price: item.price }) // -> ui_event -> core:ui:<page>:buy
      CoreUI.notify({ title: 'Sold', message: item.label + ' — ' + money(item.price), type: 'success' })
    }

    return () => h('div', { class: 'core-backdrop', style: { zIndex: 1 } }, [
      h('div', { class: 'core-panel', style: { width: '520px', maxWidth: '86vw', padding: '18px' } }, [
        h('header', { style: { display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: '12px' } }, [
          h('h2', { class: 'core-title', style: { margin: 0 } }, vm.props.title || 'Shop'),
          h('span', { class: 'core-text' }, 'Cash ' + money(CoreUI.hud.cash)),
        ]),
        h('p', { class: 'core-text', style: { marginTop: '4px' } },
          'Registered by a plugin bundle, opened with page:open — this panel is the plugin\'s own markup.'),
        h('ul', { class: 'core-list', style: { marginTop: '12px' } }, items().map((item, i) => h('li', {
          key: item.id,
          class: ['core-item', i === selected.value ? 'is-active' : ''],
          onClick: () => buy(item, i),
        }, [
          h('span', { style: { minWidth: '22px', textAlign: 'center' } }, item.icon || '•'),
          h('span', { style: { display: 'flex', flexDirection: 'column', minWidth: 0, flex: '1 1 auto' } }, [
            h('span', { style: { fontSize: '13px' } }, item.label),
            h('span', { class: 'core-text', style: { fontSize: '10px' } }, item.description || ''),
          ]),
          h('span', { style: { fontVariantNumeric: 'tabular-nums', color: 'var(--core-success)' } }, money(item.price)),
        ]))),
        h('div', { style: { display: 'flex', justifyContent: 'flex-end', gap: '8px', marginTop: '14px' } }, [
          h('button', { class: 'core-btn', type: 'button', onClick: () => page.close() }, 'Close (Esc)'),
          h('button', { class: 'core-btn core-btn--primary', type: 'button', onClick: () => buy(items()[selected.value] || {}, selected.value) }, 'Buy selected'),
        ]),
      ]),
    ])
  },
}

/** An overlay: shown next to the game, never takes input (the overlay layer is click-through). */
const DutyOverlay = {
  name: 'DemoDutyOverlay',
  props: { props: { type: Object, default: () => ({}) } },
  setup (vm) {
    return () => h('div', {
      class: 'core-panel',
      style: {
        position: 'fixed', left: '16px', top: '16px', width: '210px', padding: '10px 12px', pointerEvents: 'none',
      },
    }, [
      h('div', { style: { display: 'flex', alignItems: 'center', gap: '8px' } }, [
        h('span', {
          style: {
            width: '7px', height: '7px', borderRadius: '999px',
            background: vm.props.onDuty ? 'var(--core-success)' : 'var(--core-text-faint)',
          },
        }),
        h('strong', { style: { fontSize: '12px', letterSpacing: '0.04em' } }, vm.props.label || 'Off duty'),
      ]),
      h('p', { class: 'core-text', style: { marginTop: '6px' } }, vm.props.detail || ''),
    ])
  },
}

const resolve = (name, body) => {
  if (name === 'ui_event') {
    if (body.event === '__error') return "PageHost gave up after 5 s -> TriggerEvent('core:ui:" + body.page + ":__error')"
    return "TriggerEvent('core:ui:" + body.page + ':' + body.event + "', " + JSON.stringify(body.data) + ')'
      + '\n-- i.e. the Core.UI.on(' + JSON.stringify(body.page) + ', ' + JSON.stringify(body.event) + ', fn) handler runs'
  }
  if (name === 'ui_close') return "Core.UI.close('" + body.page + "')   -- page hidden, SetNuiFocus(false, false)"
  return null
}

export default {
  title: 'Built-ins/Page Host',
  component: PageHost,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'One dist for everybody: plugin pages are compiled INTO core\'s bundle '
          + '(`src/plugins.js` globs `*/ui/src/index.js`) and register themselves before mount, so '
          + '`page:register` usually carries `script: null`. The host still supports the URL form '
          + '(`script` / `style`) for prebuilt third-party bundles, and waits up to 5 s for a '
          + 'component that has not registered yet.',
      },
    },
  },
  argTypes: {
    title: { control: 'text', description: '`page:open.props.title` — a prop of the plugin page, not of the shell.', table: { category: 'page:open props' } },
    items: { control: 'object', description: 'The shop rows the sample page renders.', table: { category: 'page:open props' } },
    cash: { control: { type: 'number', step: 100 }, description: '`hud:set.cash`; the page reads it through `CoreUI.hud`.', table: { category: 'hud:set' } },
  },
}

export const OpenPage = {
  name: 'Open page',
  args: {
    cash: 8420,
    title: 'Ammu-Nation — Pillbox Hill',
    items: [
      { id: 'vest', icon: '🦺', label: 'Body armour', description: 'Full plate, 100 %', price: 1200 },
      { id: 'medkit', icon: '🧰', label: 'First aid kit', description: 'Heals 50 % out of combat', price: 350 },
      { id: 'radio', icon: '📻', label: 'Handheld radio', description: 'Needs a channel from dispatch', price: 700 },
      { id: 'repair', icon: '🔧', label: 'Repair kit', description: 'One engine repair, takes 20 s', price: 950 },
    ],
  },
  parameters: {
    lua: {
      message: 'page:register → page:open',
      callback: 'ui_event / ui_close',
      resolve,
      call: "Core.UI.registerPage('sb_demo_shop', { type = 'page', keepInput = false })\n\n"
        + "Core.UI.on('sb_demo_shop', 'buy', function(data)\n"
        + '    -- data = { item = \'vest\', price = 1200 }\n'
        + '    Core.UI.notify({ message = \'Bought \' .. data.item, type = \'success\' })\n'
        + 'end)\n\n'
        + "Core.UI.open('sb_demo_shop', {\n"
        + "    title = 'Ammu-Nation — Pillbox Hill',\n"
        + '    items = shopItems,\n'
        + '})   -- SetNuiFocus(true, true) while it is open',
      note: 'The play function clicks the first row, so you can see the ui_event that Lua turns into a client event.',
    },
    docs: {
      description: {
        story: 'The real §7.4 order: `page:register` (metadata), then the bundle\'s '
          + '`CoreUI.registerPage(id, component)`, then `page:open` with props. Clicking a row calls '
          + '`CoreUI.emit(\'buy\', …)` → `ui_event` → `TriggerEvent(\'core:ui:sb_demo_shop:buy\', data)` '
          + 'on the client; Close / Esc posts `ui_close { page }` and Lua drops focus. `Core.UI.open` '
          + 'returns a boolean (did it open), not a value — pages are a conversation, not a prompt.',
      },
    },
  },
  render: liveScene((args) => {
    send({ action: 'hud:set', visible: false, cash: args.cash })
    send({ action: 'page:register', id: PAGE_ID, type: 'page', keepInput: false })
    window.CoreUI.registerPage(PAGE_ID, ShopPage)
    send({ action: 'page:open', id: PAGE_ID, props: { title: args.title, items: clone(args.items) } })
  }, view),
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    // The bundle registered before `page:open`, so the panel is there on the first frame.
    await waitFor(() => expect(canvas.getByText(args.title)).toBeInTheDocument())
    expect(canvas.getByText('Cash ' + money(args.cash))).toBeInTheDocument()
    await userEvent.click(canvas.getByText(args.items[0].label))
    await waitFor(() => expect(lastPost('ui_event')).toBeTruthy())
    const body = lastPost('ui_event')
    expect(body.page).toBe(PAGE_ID)
    expect(body.event).toBe('buy')
    expect(body.data).toEqual({ item: args.items[0].id, price: args.items[0].price })
    // CoreUI.notify raised a local toast — no Lua round trip for that one.
    await waitFor(() => expect(canvas.getByText('Sold')).toBeInTheDocument())
  },
}

export const OpenOverlay = {
  name: 'Overlay',
  args: { onDuty: true, label: 'LSPD — on duty', detail: 'Unit 12-A · Sector 4 · 3 calls pending' },
  argTypes: {
    onDuty: { control: 'boolean', description: 'Prop of the sample overlay (tints the dot).', table: { category: 'page:open props' } },
    label: { control: 'text', table: { category: 'page:open props' } },
    detail: { control: 'text', table: { category: 'page:open props' } },
    title: { table: { disable: true } },
    items: { table: { disable: true } },
    cash: { table: { disable: true } },
  },
  parameters: {
    lua: {
      message: 'page:register → page:open',
      callback: 'ui_event / ui_close',
      resolve,
      call: "Core.UI.registerPage('sb_demo_duty', { type = 'overlay' })\n"
        + "Core.UI.open('sb_demo_duty', { onDuty = true, label = 'LSPD — on duty', detail = … })\n\n"
        + '-- later, without reopening anything:\n'
        + "Core.UI.send('sb_demo_duty', 'calls', { pending = 4 })   -- -> page:event -> CoreUI.on(...)",
      note: 'An overlay never takes focus, so it posts nothing unless the page itself emits.',
    },
    docs: {
      description: {
        story: 'Same flow with `type = "overlay"`: it lands in `store.overlays`, renders in the '
          + 'click-through layer and never grabs NUI focus, so several can be up at once next to an '
          + 'open page. Escape does not close overlays — only `Core.UI.close(id)` does.',
      },
    },
  },
  render: liveScene((args) => {
    send({ action: 'page:register', id: OVERLAY_ID, type: 'overlay', keepInput: false })
    window.CoreUI.registerPage(OVERLAY_ID, DutyOverlay)
    send({ action: 'page:open', id: OVERLAY_ID, props: { onDuty: args.onDuty, label: args.label, detail: args.detail } })
  }, view),
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.label)).toBeInTheDocument())
    expect(canvas.getByText(args.detail)).toBeInTheDocument()
    expect(lastPost('ui_event')).toBeUndefined() // an overlay is output only
  },
}

export const NotRegistered = {
  name: 'Opened before the bundle registered',
  argTypes: {
    title: { table: { disable: true } },
    items: { table: { disable: true } },
    cash: { table: { disable: true } },
  },
  parameters: {
    lua: {
      message: 'page:register → page:open',
      callback: 'ui_event { event = "__error" }',
      resolve,
      call: "Core.UI.registerPage('sb_missing_page', { type = 'page' })\n"
        + "Core.UI.open('sb_missing_page')   -- nothing in the bundle ever calls registerPage for this id\n\n"
        + "Core.UI.on('sb_missing_page', '__error', function()\n"
        + '    Core.Log.error(\'UI page never registered\')\nend)',
      note: 'Give it five seconds — whenRegistered() times out at 5000 ms.',
    },
    docs: {
      description: {
        story: 'A `page:open` for an id no bundle ever registered: `whenRegistered` waits 5 s, then '
          + 'PageHost posts `ui_event { event = "__error" }` and drops an error toast. Nothing renders '
          + 'until then — this is what a typo in the page id looks like.',
      },
    },
  },
  render: liveScene(() => {
    send({ action: 'page:register', id: 'sb_missing_page', type: 'page' })
    send({ action: 'page:open', id: 'sb_missing_page', props: {} }) // no bundle ever registers it
  }, view),
}
