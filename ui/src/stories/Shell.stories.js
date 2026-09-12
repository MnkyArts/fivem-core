// The whole shell (App.vue, DESIGN §7.2): every widget at once, over the game backdrop.
// Useful for judging spacing and z-order between the rail, the pill and the modals — and
// for seeing that the widgets are independent: one `SendNUIMessage` per widget, no layout
// negotiation between them.
import { h } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import App from '../App.vue'
import { send, liveScene, store, clone, HOLD_MS } from './storeHelpers.js'
import { lastPost } from './luaBridge.js'

const view = () => h(App)

let seq = 0
const rid = (p) => 'sb-shell-' + p + '-' + ++seq

function hud (args) {
  send({
    action: 'hud:set',
    visible: true,
    cash: args.cash,
    bank: args.bank,
    name: 'Liam Robinson',
    serverId: 12,
    faction: args.faction ? { name: 'Los Santos Police Department', tag: 'LSPD', color: '#5b8cff' } : false,
  })
}

/** Playground: five independent messages, exactly the order a Lua flow would send them. */
function playground (args) {
  hud(args)
  send({ action: 'notify', id: rid('n1'), type: 'success', title: 'On duty', message: 'Signed in as unit 12-A.', duration: HOLD_MS })
  send({ action: 'notify', id: rid('n2'), type: 'warning', title: 'Dispatch', message: '10-31 in progress on Vespucci Boulevard.', duration: HOLD_MS })
  send({ action: 'textui:show', key: args.promptKey, text: args.prompt, position: 'bottom' })
  send({ action: 'progress:start', id: rid('p'), label: args.progressLabel, duration: 4 * 60 * 1000, canCancel: true })
  store.progress.startedAt = Date.now() - (Number(args.elapsed) || 0) // start the fill part way across
}

/** The same live rail, plus the §31 visibility flip the `hidden` control drives. */
function visibilityScene (args) {
  hud(args)
  send({ action: 'textui:show', key: args.promptKey, text: args.prompt, position: 'bottom' })
  // Posted once: an identical toast coalesces into a `count` badge, so re-sending it on every
  // toggle would only make the badge climb. The point of the story is that ONE message flips
  // the shell and nothing else moves.
  if (!store.notifications.length) {
    send({
      action: 'notify',
      id: rid('n'),
      type: 'info',
      title: 'Dispatch',
      message: 'Toasts keep expiring while the shell is hidden — nothing is unmounted.',
      duration: HOLD_MS,
    })
  }
  send({ action: 'shell:visible', visible: !args.hidden, reasons: args.hidden ? [args.reason] : [] })
}

/** A modal over the live rail. */
function menuScene (args) {
  hud(args)
  send({ action: 'notify', id: rid('n'), type: 'info', message: 'Radio channel 2 joined.', duration: HOLD_MS })
  send({ action: 'textui:show', key: args.promptKey, text: args.prompt, position: 'bottom' })
  send({ action: 'menu:open', id: rid('m'), title: args.menuTitle, items: clone(args.items) })
}

export default {
  title: 'Shell',
  component: App,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'App.vue mounts every built-in at once: `<Hud>` and `<Notifications>` in the '
          + 'top-right rail, `<TextUI>` and `<Progress>` bottom centre, `<PageHost>` in the middle '
          + 'and the three modals on top (z-index 50). Everything is `pointer-events: none` except '
          + 'an open modal or page, which is what lets the player keep playing while a toast is up.',
      },
    },
  },
  argTypes: {
    cash: { control: { type: 'number', step: 100 }, table: { category: 'hud:set' } },
    bank: { control: { type: 'number', step: 1000 }, table: { category: 'hud:set' } },
    faction: { control: 'boolean', description: 'Show the LSPD row in the HUD.', table: { category: 'hud:set' } },
    prompt: { control: 'text', description: '`textui:show.text`.', table: { category: 'textui:show' } },
    promptKey: { control: 'text', description: '`textui:show.key`.', table: { category: 'textui:show' } },
  },
  args: { cash: 4238, bank: 182450, faction: true, promptKey: 'E' },
}

export const Playground = {
  name: 'Playground',
  args: {
    prompt: 'Search the vehicle',
    progressLabel: 'Searching the boot',
    elapsed: 95000,
  },
  argTypes: {
    progressLabel: { control: 'text', table: { category: 'progress:start' } },
    elapsed: { control: { type: 'number', step: 1000 }, description: 'Story-only: how far the bar has already run.', table: { category: 'story' } },
  },
  parameters: {
    lua: {
      message: 'hud:set + notify ×2 + textui:show + progress:start',
      callback: 'progress_cancel / progress_done',
      resolve: (name, body) => (name === 'progress_cancel'
        ? 'Core.UI.progress{...}  ->  false    -- the player pressed X'
        : (name === 'progress_done' ? 'Core.UI.progress{...}  ->  true' : null)),
      call: "Core.UI.hud.setVisible(true)\n"
        + "Core.UI.notify({ title = 'On duty', message = 'Signed in as unit 12-A.', type = 'success' })\n"
        + "Core.UI.notify({ title = 'Dispatch', message = '10-31 in progress…', type = 'warning' })\n"
        + "Core.UI.textUI.show('E', 'Search the vehicle')\n"
        + "local done = Core.UI.progress({ label = 'Searching the boot', duration = 20000, canCancel = true })\n"
        + 'Core.UI.textUI.hide()\nif not done then return end',
      note: 'Five independent messages. Only the progress call blocks the Lua thread.',
    },
    docs: {
      description: {
        story: 'HUD + two toasts + the text UI pill + a running progress bar, all driven through '
          + '`window.__core.send` exactly as Lua would. Everything here is click-through, so the game '
          + 'behind stays playable — press **x** to cancel the bar and watch `progress_cancel` appear '
          + 'in the Lua panel.',
      },
    },
  },
  render: liveScene(playground, view),
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.prompt)).toBeInTheDocument())
    expect(canvas.getByText('On duty')).toBeInTheDocument()
    expect(canvas.getByText(args.progressLabel)).toBeInTheDocument()
    await userEvent.keyboard('x') // cancels the bar; the pill and the toasts are untouched
    await waitFor(() => expect(lastPost('progress_cancel')).toBeTruthy())
    expect(canvas.getByText(args.prompt)).toBeInTheDocument()
    playground(args) // re-arm everything, so the story stays something you can poke at
  },
}

export const MenuOverHud = {
  name: 'Menu over HUD',
  args: {
    prompt: 'Interact with the vehicle',
    menuTitle: 'Vehicle — Buffalo STX',
    items: [
      { label: 'Engine', description: 'Toggle the engine on or off', icon: '⚙', value: 'engine' },
      { label: 'Doors', description: 'Open or close a single door', icon: '🚪', value: 'doors' },
      { label: 'Search boot', description: 'Takes 20 seconds', icon: '📦', value: 'search' },
      { label: 'Hand over keys', description: 'Requires another player nearby', icon: '🔑', value: 'keys', disabled: true },
      { label: 'Impound', description: 'Police only', icon: '🚔', value: 'impound' },
    ],
  },
  argTypes: {
    menuTitle: { control: 'text', table: { category: 'menu:open' } },
    items: { control: 'object', table: { category: 'menu:open' } },
  },
  parameters: {
    lua: {
      message: 'hud:set + notify + textui:show + menu:open',
      callback: 'menu_result',
      resolve: (name, body) => (name === 'menu_result'
        ? 'Core.UI.menu.open{...}  ->  ' + (body.value == null ? 'nil' : JSON.stringify(body.value))
        : null),
      call: "Core.UI.textUI.show('E', 'Interact with the vehicle')\n"
        + "local choice = Core.UI.menu.open({ title = 'Vehicle — Buffalo STX', items = items })\n"
        + "if choice == 'search' then\n"
        + "    Core.UI.progress({ label = 'Searching the boot', duration = 20000, canCancel = true })\n"
        + 'end',
      note: 'While the menu is up, client/ui.lua holds SetNuiFocus(true, true) — that is why the cursor appears.',
    },
    docs: {
      description: {
        story: 'A modal on top of the live HUD: the menu backdrop dims the game, takes pointer '
          + 'events and owns the keyboard (arrows / Enter / Esc) while the rail keeps updating. '
          + 'The play function walks down to the third row and picks it.',
      },
    },
  },
  render: liveScene(menuScene, view),
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.menuTitle)).toBeInTheDocument())
    await userEvent.keyboard('{ArrowDown}{ArrowDown}{Enter}')
    await waitFor(() => expect(lastPost('menu_result')).toBeTruthy())
    expect(lastPost('menu_result').value).toBe(args.items[2].value)
    // The modal closed; the HUD, the toast and the pill are still there.
    await waitFor(() => expect(canvas.queryByText(args.menuTitle)).toBeNull())
    expect(canvas.getByText(args.prompt)).toBeInTheDocument()
    menuScene(args) // reopen the menu for the reader
  },
}

export const Visibility = {
  name: 'Visibility',
  args: {
    prompt: 'Search the vehicle',
    hidden: false,
    reason: 'my_plugin:cutscene',
  },
  argTypes: {
    hidden: {
      control: 'boolean',
      description: 'Sends `shell:visible`. On means the client holds at least one hide reason.',
      table: { category: 'shell:visible' },
    },
    reason: {
      control: 'select',
      options: ['game:pause', 'game:fade', 'game:switch', 'game:warning', 'game:cinematic', 'server:admin', 'my_plugin:cutscene'],
      description: '`reasons[1]` — debug information only; nothing in the shell branches on it.',
      table: { category: 'shell:visible' },
    },
  },
  parameters: {
    lua: {
      message: 'shell:visible',
      call: "-- client, from any plugin: the reason is namespaced with the calling resource\n"
        + "Core.UI.hide('cutscene')            -- stored as my_plugin:cutscene\n"
        + "-- ... play the cutscene ...\n"
        + "Core.UI.show('cutscene')            -- a plugin can only clear its OWN reason\n"
        + "Core.UI.isHidden()                  -- true while any reason is set\n"
        + "Core.UI.hiddenReasons()             -- { 'game:pause', 'my_plugin:cutscene' }\n"
        + "Core.UI.setAutoHide('cinematic', false)   -- turn one watcher off at runtime\n"
        + "\n"
        + "-- server, for one player (pushed through core:client:ui, stored as server:cutscene)\n"
        + "Core.UI.hide(src, 'cutscene')\n"
        + "Core.UI.show(src, 'cutscene')\n"
        + "\n"
        + "-- client hook, on the hidden <-> visible flip only (never per reason)\n"
        + "Core.on('uiVisibility', function(visible, reasons) end)\n"
        + "\n"
        + "-- shared/config.lua: core's own watchers, one thread, six booleans every 200 ms\n"
        + "Config.UI.AutoHide = {\n"
        + "    IntervalMs   = 200,\n"
        + "    PauseMenu    = true,    -- game:pause       IsPauseMenuActive()\n"
        + "    ScreenFade   = true,    -- game:fade        IsScreenFadedOut() / IsScreenFadingOut()\n"
        + "    PlayerSwitch = true,    -- game:switch      IsPlayerSwitchInProgress()\n"
        + "    Warning      = true,    -- game:warning     IsWarningMessageActive()\n"
        + "    HudHidden    = false,   -- game:hud         IsHudHidden() - off, semantics undocumented\n"
        + "    Cinematic    = true,    -- game:cinematic   IsCinematicCamRendering()\n"
        + "}",
      note: 'Fire and forget: `shell:visible` has no NUI callback. The watcher thread sends one '
        + 'message per hidden<->visible flip and re-sends it on `ui_ready`, so a NUI reload while '
        + 'the pause menu is open comes back hidden.',
    },
    docs: {
      description: {
        story: 'The NUI layer is composited above *everything* the game draws — the pause menu, a '
          + 'screen fade, the player-switch cinematic. So core hides the whole shell instead: '
          + '`.core-root` gets `is-hidden` → `visibility: hidden; pointer-events: none`. Flip the '
          + '**hidden** control and watch the HUD, the toast and the pill go together.\n\n'
          + 'Nothing unmounts. The toast keeps its dismiss timer, a progress bar still completes '
          + 'and the HUD still takes `hud:set` while hidden; showing again only flips the flag. '
          + 'The one thing hiding *does* change is a modal: the hidden transition cancels an open '
          + 'menu / input / alert and closes the focused page, because a player must never be '
          + 'stuck behind an invisible element that holds NUI focus. **Hiding with a modal open '
          + 'equals cancelling it.**',
      },
    },
  },
  render: liveScene(visibilityScene, view),
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    const root = () => canvasElement.querySelector('.core-root')
    const vis = () => getComputedStyle(root()).visibility
    await waitFor(() => expect(canvas.getByText(args.prompt)).toBeInTheDocument())
    expect(vis()).toBe('visible')

    send({ action: 'shell:visible', visible: false, reasons: ['game:pause'] })
    await waitFor(() => expect(vis()).toBe('hidden'))
    expect(root().getAttribute('aria-hidden')).toBe('true')
    // Still mounted, merely not painted — getByText reads textContent, not what is on screen.
    expect(canvas.getByText(args.prompt)).toBeInTheDocument()
    expect(canvas.getByText('Dispatch')).toBeInTheDocument()

    send({ action: 'shell:visible', visible: true, reasons: [] })
    await waitFor(() => expect(vis()).toBe('visible'))
    expect(root().getAttribute('aria-hidden')).toBeNull()
    visibilityScene(args) // back to whatever the control says, so the story stays pokeable
  },
}
