// Progress bar (DESIGN §6.10 `progress:start`) — bottom-centre label + fill.
//
// Lua side: `local completed = Core.UI.progress({ label, duration, canCancel })` blocks the
// calling thread and returns `true` when the bar ran out (the NUI posts `progress_done`) or
// `false` when the player pressed X / Backspace (`progress_cancel`) or a second progress
// started. The NUI owns the clock — Lua only starts and awaits.
import { h } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import Progress from '../shell/Progress.vue'
import { send, liveScene, store } from './storeHelpers.js'
import { lastPost } from './luaBridge.js'

const view = () => h(Progress)

let seq = 0
const rid = () => 'sb-progress-' + ++seq

/** Start a bar, then rewind `startedAt` so the fill is already part way across: Progress.vue
 *  seeds its CSS transition from that stamp, the same way a late NUI mount catches up with a
 *  bar Lua started earlier. */
const build = (args) => {
  send({
    action: 'progress:start',
    id: rid(),
    label: args.label,
    duration: args.duration,
    canCancel: args.canCancel,
  })
  store.progress.startedAt = Date.now() - (Number(args.elapsed) || 0)
}

const run = liveScene(build, view)

const resolve = (name, body) => {
  if (name === 'progress_cancel') return 'Core.UI.progress{...}  ->  false     -- cancelled with X / Backspace'
  if (name === 'progress_done') return 'Core.UI.progress{...}  ->  true      -- the bar ran out'
  return null
}

const call = (a) => 'local completed = Core.UI.progress({\n'
  + "    label = '" + a.label + "',\n"
  + '    duration = ' + a.duration + ',\n'
  + '    canCancel = ' + (a.canCancel ? 'true' : 'false') + ',\n'
  + '})\nif not completed then return end   -- player cancelled, or another progress took over'

export default {
  title: 'Built-ins/Progress',
  component: Progress,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'One bar at a time. `progress:start` replaces whatever is running (the old '
          + 'promise resolves `false`), `progress:stop` hides it without a callback, and the store '
          + 'fires `progress_done` itself when `duration` elapses — Lua never polls.',
      },
    },
  },
  argTypes: {
    label: { control: 'text', description: 'Left-hand caption (ellipsised, one line).', table: { category: 'progress:start' } },
    duration: {
      control: { type: 'number', min: 500, step: 500 },
      description: 'Total ms. The store auto-completes at the end; stories use 4 min so the bar stays.',
      table: { category: 'progress:start' },
    },
    canCancel: {
      control: 'boolean',
      description: 'Shows the `X to cancel` hint and lets x / Backspace post `progress_cancel`.',
      table: { category: 'progress:start' },
    },
    elapsed: {
      control: { type: 'number', min: 0, step: 1000 },
      description: 'Story-only: rewinds `startedAt`, so the fill starts part way across.',
      table: { category: 'story' },
    },
  },
  args: { duration: 4 * 60 * 1000 },
}

export const Running = {
  name: 'Running (cancellable)',
  args: { label: 'Hotwiring the ignition', canCancel: true, elapsed: 42000 },
  parameters: {
    lua: {
      message: 'progress:start',
      callback: 'progress_cancel / progress_done',
      resolve,
      call: call({ label: 'Hotwiring the ignition', duration: 20000, canCancel: true }),
      note: 'The play function presses x, so the cancel callback below is already in.',
    },
    docs: {
      description: {
        story: 'A cancellable bar shows the `X to cancel` hint, and x / Backspace really do cancel '
          + 'it here: `store.handleKeydown` → `progressCancel()` → `post(\'progress_cancel\', { id })`, '
          + 'which makes the awaiting `Core.UI.progress{...}` return **false**. Text inputs are '
          + 'excluded from the cancel keys (`isTextTarget`), so typing an "x" in a dialog is safe.',
      },
    },
  },
  render: run,
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.label)).toBeInTheDocument())
    expect(canvas.getByText(/to cancel/i)).toBeInTheDocument()
    await userEvent.keyboard('x')
    await waitFor(() => expect(lastPost('progress_cancel')).toBeTruthy())
    expect(lastPost('progress_cancel').id).toMatch(/^sb-progress-/)
    expect(lastPost('progress_done')).toBeUndefined()
    await waitFor(() => expect(canvas.queryByText(args.label)).toBeNull())
    build(args) // restart the bar, so the story is still something you can cancel by hand
  },
}

export const NoCancel = {
  name: 'Running (no cancel)',
  args: { label: 'Repairing the engine block', canCancel: false, elapsed: 150000 },
  parameters: {
    lua: {
      message: 'progress:start',
      callback: 'progress_done',
      resolve,
      call: call({ label: 'Repairing the engine block', duration: 30000, canCancel: false }),
    },
    docs: {
      description: {
        story: 'Without `canCancel` the hint disappears and the cancel keys are ignored '
          + '(`progressCancel()` returns early), so the only possible answer is `true` — unless a '
          + 'second `Core.UI.progress` starts, which resolves this one `false`.',
      },
    },
  },
  render: run,
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.label)).toBeInTheDocument())
    expect(canvas.queryByText(/to cancel/i)).toBeNull()
    await userEvent.keyboard('x') // ignored: canCancel is false
    expect(lastPost('progress_cancel')).toBeUndefined()
    expect(canvas.getByText(args.label)).toBeInTheDocument()
  },
}

export const LongLabel = {
  name: 'Long label',
  args: {
    label: 'Transferring the contents of the evidence locker into the patrol vehicle',
    canCancel: true,
    elapsed: 20000,
  },
  parameters: {
    lua: {
      message: 'progress:start',
      callback: 'progress_cancel / progress_done',
      resolve,
      call: call({ label: 'Transferring the contents of the evidence locker…', duration: 45000, canCancel: true }),
    },
    docs: { description: { story: 'The label is `nowrap` + ellipsis in a fixed 340 px panel; the hint never shrinks.' } },
  },
  render: run,
}
