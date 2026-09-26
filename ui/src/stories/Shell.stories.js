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

/** §39.4: the HUD is the bottom-left strip now, and its food / drink bars are `stats:set`
 *  entries with a `slot` — so "the HUD" is two messages, exactly as in game. `stress` has no
 *  slot and is what keeps the top-right rail plate in the picture. */
function hud (args) {
  send({
    action: 'hud:set',
    visible: true,
    health: args.health,
    armour: args.armour,
    talking: args.talking,
    // Still in the store for `useHud()`, still not drawn by core (§39.4).
    cash: 4238,
    bank: 182450,
    name: 'Liam Robinson',
    serverId: 12,
  })
  send({
    action: 'stats:set',
    hunger: { value: 72, min: 0, max: 100, label: 'Hunger', slot: 'health', icon: 'hud-food' },
    thirst: { value: 41, min: 0, max: 100, label: 'Thirst', slot: 'armour', icon: 'hud-drink' },
    stress: { value: 58, min: 0, max: 100 },
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

/** §54: the HUD layer stepping aside for an editor. Exactly what client/ui.lua sends for
 *  `Core.UI.hideHud('editor')` called by the `admin` resource: one `shell:hud`, then the text UI
 *  of a resource that holds no reason goes (core's interaction prompt here); the toast stays. */
function hudHideScene (args) {
  hud(args)
  if (!store.notifications.length) {
    send({
      action: 'notify',
      id: rid('n'),
      type: 'info',
      title: 'Editor',
      message: 'Toasts, pages and modals stay while an editor hides the HUD.',
      duration: HOLD_MS,
    })
  }
  send({ action: 'shell:hud', hidden: !!args.hudHidden, keep: args.hudHidden ? [args.holder] : [] })
  if (args.hudHidden) send({ action: 'textui:hide' })
  else send({ action: 'textui:show', key: args.promptKey, text: args.prompt, position: 'bottom' })
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
        component: 'App.vue mounts every built-in at once: `<Hud>` as the ~351 × 76 px vitals strip '
          + 'next to the minimap (§39.4, z 35), `<StatsBars>` and `<Notifications>` in the top-right '
          + 'rail (268px wide, z 40), '
          + '`<TextUI>` and `<Progress>` bottom centre, `<PageHost>` in the middle and the three '
          + 'modals on top (z-index 50). Everything is `pointer-events: none` except an open modal '
          + 'or page, which is what lets the player keep playing while a toast is up.',
      },
    },
  },
  argTypes: {
    health: { control: { type: 'range', min: 0, max: 100, step: 1 }, table: { category: 'hud:set' } },
    armour: { control: { type: 'range', min: 0, max: 100, step: 1 }, table: { category: 'hud:set' } },
    talking: { control: 'boolean', description: 'Lights the mic tile. `null` would remove it.', table: { category: 'hud:set' } },
    prompt: { control: 'text', description: '`textui:show.text`.', table: { category: 'textui:show' } },
    promptKey: { control: 'text', description: '`textui:show.key`.', table: { category: 'textui:show' } },
  },
  args: { health: 86, armour: 64, talking: false, promptKey: 'E' },
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
      message: 'hud:set + stats:set + notify ×2 + textui:show + progress:start',
      callback: 'progress_cancel / progress_done',
      resolve: (name, body) => (name === 'progress_cancel'
        ? 'Core.UI.progress{...}  ->  false    -- the player pressed X'
        : (name === 'progress_done' ? 'Core.UI.progress{...}  ->  true' : null)),
      call: "Core.UI.hud.setVisible(true)   -- client/hudfeed.lua fills the plates by itself\n"
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
      message: 'hud:set + stats:set + notify + textui:show + menu:open',
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

export const HudHidden = {
  name: 'HUD hidden (editor focus)',
  args: {
    prompt: 'Open the door',
    hudHidden: false,
    holder: 'admin',
  },
  argTypes: {
    hudHidden: {
      control: 'boolean',
      description: 'Sends `shell:hud`. On means some resource holds a `Core.UI.hideHud` reason.',
      table: { category: 'shell:hud' },
    },
    holder: {
      control: 'text',
      description: '`keep[1]` — the resource holding the reason; ITS overlays stay, everybody else\'s hide.',
      table: { category: 'shell:hud' },
    },
  },
  parameters: {
    lua: {
      message: 'shell:hud (+ textui:hide for a prompt of another resource)',
      call: "-- client, from the editor's resource (reached through the proxy, owner-tracked)\n"
        + "Core.UI.hideHud('editor')     -- vitals, stat bars, world prompts, other overlays, radar + GTA HUD\n"
        + "Core.Keys.capture('editor')   -- other resources' Core.Keys presses are swallowed\n"
        + "-- ... the editor runs ...\n"
        + "Core.Keys.release('editor')\n"
        + "Core.UI.showHud('editor')     -- everything comes back as it was; the radar only if §54 hid it\n"
        + "Core.UI.isHudHidden()         -- true while any reason is held\n"
        + "\n"
        + "-- client hook, on the hidden <-> visible flip only\n"
        + "Core.on('hudHiddenChanged', function(hidden) end)",
      note: 'Fire and forget, re-sent on `ui_ready` while hidden (before the overlays re-open). Unlike '
        + '`shell:visible` nothing is closed or cancelled: pages, modals and toasts are not the HUD.',
    },
    docs: {
      description: {
        story: 'An editor wants the screen to itself without hiding its own page. `Core.UI.hideHud` hides '
          + "the HUD layer only: core's vitals strip, the stat bars and the world prompts, plus every "
          + '**overlay** page whose owner holds no reason (the inventory hotbar goes, the admin HUD of the '
          + 'holder stays). The GTA radar and native HUD are switched off in Lua. Flip **hudHidden**: the '
          + 'toast stays, the strip and the prompt go, and nothing unmounts.',
      },
    },
  },
  render: liveScene(hudHideScene, view),
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    const part = (name) => canvasElement.querySelector('[data-core-hud="' + name + '"]')
    const display = (name) => getComputedStyle(part(name)).display
    await waitFor(() => expect(canvas.getByText(args.prompt)).toBeInTheDocument())
    expect(display('vitals')).toBe('contents')

    send({ action: 'shell:hud', hidden: true, keep: ['admin'] })
    send({ action: 'textui:hide' })
    await waitFor(() => expect(display('vitals')).toBe('none'))
    expect(display('stats')).toBe('none')
    expect(display('worldprompts')).toBe('none')
    // the toast is not the HUD
    expect(canvas.getByText('Editor')).toBeInTheDocument()
    expect(getComputedStyle(canvasElement.querySelector('.core-root')).visibility).toBe('visible')

    send({ action: 'shell:hud', hidden: false, keep: [] })
    await waitFor(() => expect(display('vitals')).toBe('contents'))
    hudHideScene(args) // back to whatever the controls say
  },
}
