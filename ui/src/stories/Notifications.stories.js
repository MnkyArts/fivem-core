// Toast stack (DESIGN §6.10 `notify`) — info / success / warning / error, titles,
// the `count` badge an identical repeat coalesces into, and a full stack.
//
// Lua side: `Core.UI.notify{ message, type, title, duration }` (or `Core.UI.notify(msg, type)`)
// returns nothing — it queues. client/ui.lua flushes at most `Config.UI.MaxNotifyPerSecond`
// messages per second on a 100 ms timer and coalesces the overflow into `count`, so a loop
// that spams notify cannot flood the NUI. There is no callback: nothing comes back.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import Notifications from '../shell/Notifications.vue'
import { send, liveScene, rail, HOLD_MS, clone } from './storeHelpers.js'

// Notifications.vue is the lower half of App.vue's top-right rail.
const view = () => rail(h(Notifications))

let seq = 0
const rid = () => 'sb-toast-' + ++seq

/** One toast per arg change. The store dismisses after `duration`, so stories hold theirs. */
const toast = liveScene((args) => {
  for (let i = 0; i < (Number(args.repeat) || 1); i++) {
    send({
      action: 'notify',
      id: rid(),
      type: args.type,
      title: args.title,
      message: args.message,
      duration: args.duration,
    })
  }
}, view)

const call = (a) => 'Core.UI.notify({\n'
  + (a.title ? "    title = '" + a.title + "',\n" : '')
  + "    message = '" + a.message + "',\n"
  + "    type = '" + a.type + "',\n"
  + '    duration = ' + (a.duration >= HOLD_MS ? 'Config.UI.NotifyDurationMs' : a.duration) + ',\n'
  + '})\n-- fire and forget: no promise, no NUI callback'

const base = {
  parameters: {
    lua: { message: 'notify', note: '`notify` is the only built-in with no callback — nothing is awaited.' },
  },
  render: toast,
}

export default {
  title: 'Built-ins/Notifications',
  component: Notifications,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Top-right stack under the HUD. The store keeps at most 6 toasts, drops the '
          + 'oldest beyond that, and restarts the dismiss timer of an identical toast instead of '
          + 'pushing a duplicate (`count` badge). A page can raise one without Lua through '
          + '`window.CoreUI.notify(message, type)`.',
      },
    },
  },
  argTypes: {
    type: {
      control: 'select',
      options: ['info', 'success', 'warning', 'error'],
      description: 'Colour of the 3 px bar. Anything unknown falls back to `info`.',
      table: { category: 'notify' },
    },
    title: { control: 'text', description: 'Optional bold first line.', table: { category: 'notify' } },
    message: { control: 'text', description: 'Body text (`String(message)`).', table: { category: 'notify' } },
    duration: {
      control: { type: 'number', min: 300, step: 250 },
      description: 'Auto-dismiss in ms; ≤ 0 falls back to 5000. Stories use an hour so the toast stays put.',
      table: { category: 'notify' },
    },
    repeat: {
      control: { type: 'number', min: 1, max: 9, step: 1 },
      description: 'Story-only: how many identical `notify` messages to send (watch `count`).',
      table: { category: 'story' },
    },
  },
  args: { duration: HOLD_MS, repeat: 1 },
}

export const Info = {
  ...base,
  args: { type: 'info', title: 'Dispatch', message: 'A new job is available at the docks.' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call({ type: 'info', title: 'Dispatch', message: 'A new job is available at the docks.', duration: HOLD_MS }) },
    docs: { description: { story: 'The default type. `Core.UI.notify(\'…\', \'info\')` is shorthand for the table form.' } },
  },
}

export const Success = {
  ...base,
  args: { type: 'success', title: 'Paid', message: 'You received $1,250 from Benny.' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call({ type: 'success', title: 'Paid', message: 'You received $1,250 from Benny.', duration: HOLD_MS }) },
    docs: { description: { story: 'Server-side money changes reach the player through `Core.Notify` → this same action.' } },
  },
}

export const Warning = {
  ...base,
  args: { type: 'warning', title: 'Fuel low', message: 'The tank is almost empty — find a station.' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call({ type: 'warning', title: 'Fuel low', message: 'The tank is almost empty — find a station.', duration: HOLD_MS }) },
  },
}

export const Error = {
  ...base,
  args: { type: 'error', title: 'Denied', message: 'You do not have the keys for this vehicle.' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call({ type: 'error', title: 'Denied', message: 'You do not have the keys for this vehicle.', duration: HOLD_MS }) },
  },
}

export const Untitled = {
  ...base,
  name: 'No title',
  args: { type: 'info', title: '', message: 'Saved.' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: "Core.UI.notify('Saved.')   -- shorthand: message only, type defaults to 'info'" },
    docs: { description: { story: 'Without `title` the toast is a single line — the shorthand `Core.UI.notify(msg)` form.' } },
  },
}

export const Repeated = {
  ...base,
  name: 'Repeated (count badge)',
  args: { type: 'warning', title: 'Locked', message: 'This door is locked.', repeat: 4 },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: 'for _ = 1, 4 do\n'
        + "    Core.UI.notify({ title = 'Locked', message = 'This door is locked.', type = 'warning' })\n"
        + 'end\n-- the client queue coalesces the repeats into one message with count = 4',
    },
    docs: {
      description: {
        story: 'Four identical `notify` messages. The store bumps `count` on the visible toast and '
          + 'restarts its timer instead of stacking duplicates — that is the ×4 badge. Lua does the '
          + 'same coalescing one layer earlier when the per-second budget is exceeded.',
      },
    },
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('×' + args.repeat)).toBeInTheDocument())
    expect(canvas.getAllByText(args.message)).toHaveLength(1)
  },
}

export const AutoDismiss = {
  ...base,
  name: 'Auto-dismiss (900 ms)',
  args: { type: 'success', title: 'Saved', message: 'Vehicle stored in the garage.', duration: 900 },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: "Core.UI.notify({\n    title = 'Saved',\n    message = 'Vehicle stored in the garage.',\n"
        + "    type = 'success',\n    duration = 900,\n})\n-- the NUI owns the timer; Lua never sends a 'dismiss'",
    },
    docs: {
      description: {
        story: 'A real `duration` instead of the hour the other stories use: the toast appears and '
          + 'the store drops it 900 ms later (`setTimer` → `dismissNotification`). The play function '
          + 'waits for both halves, which is why this story looks empty once it has run.',
      },
    },
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.message)).toBeInTheDocument())
    await waitFor(() => expect(canvas.queryByText(args.message)).toBeNull(), { timeout: args.duration + 4000 })
  },
}

export const Stack = {
  name: 'Stack of 5',
  args: {
    duration: HOLD_MS,
    toasts: [
      { type: 'info', title: 'Dispatch', message: 'A new job is available at the docks.' },
      { type: 'success', message: 'Vehicle stored in the garage.' },
      { type: 'warning', title: 'Fuel low', message: 'The tank is almost empty.' },
      { type: 'error', title: 'Denied', message: 'You do not have the keys for this vehicle.' },
      { type: 'info', message: 'Press E to talk to the mechanic — he closes at 22:00 sharp.' },
    ],
  },
  argTypes: {
    toasts: { control: 'object', description: 'One `notify` message per entry.', table: { category: 'notify' } },
    type: { table: { disable: true } },
    title: { table: { disable: true } },
    message: { table: { disable: true } },
    repeat: { table: { disable: true } },
  },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: 'for _, n in ipairs(queue) do\n    Core.UI.notify(n)\nend\n'
        + '-- 7+ at once and the oldest fall off the stack (NOTIFY_MAX_VISIBLE = 6)',
    },
    docs: { description: { story: 'Five at once, newest at the bottom. The 7th would push the oldest out.' } },
  },
  render: liveScene((args) => {
    for (const t of clone(args.toasts)) send({ action: 'notify', id: rid(), duration: args.duration, ...t })
  }, view),
}
