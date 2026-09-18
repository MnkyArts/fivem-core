// Shard banner (DESIGN §21 `shard:show`) — the centre-screen "WASTED" / "MISSION PASSED"
// card, in three styles.
//
// Lua side: `Core.UI.shard({ title, subtitle, duration, style })` on the client, or
// `Core.UI.shard(src, opts)` on the server (it forwards through `core:client:ui`). Fire
// and forget: the banner owns its own life (store.js arms the auto-hide timer from
// `duration`, 4 s when Lua omits it) and no callback ever comes back.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import Shard from '../shell/Shard.vue'
import { resetExtras } from '../store.js'
import { send, liveScene, HOLD_MS } from './storeHelpers.js'

// Shard.vue positions itself across the middle of the screen, so the story just mounts it.
const view = () => h(Shard)

const show = liveScene((args) => {
  resetExtras()
  send({
    action: 'shard:show',
    title: args.title,
    subtitle: args.subtitle,
    style: args.style,
    duration: args.duration,
  })
}, view)

const call = (a) => 'Core.UI.shard({\n'
  + "    title = '" + a.title + "',\n"
  + (a.subtitle ? "    subtitle = '" + a.subtitle + "',\n" : '')
  + "    style = '" + a.style + "',\n"
  + '    duration = ' + (a.duration >= HOLD_MS ? '4000' : a.duration) + ',\n'
  + '})\n-- server side, for one player:\n'
  + "-- Core.UI.shard(src, { title = '" + a.title + "', style = '" + a.style + "' })"

const base = {
  parameters: {
    lua: {
      message: 'shard:show',
      note: 'Output only. There is no `shard:hide` — `duration` is the whole contract.',
    },
  },
  render: show,
}

export default {
  title: 'Built-ins/Shard',
  component: Shard,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The loud one: a full-bleed band with a huge title and a spaced-out subtitle, '
          + 'z-index 45 — above the HUD, below every modal. A second `shard:show` while one is up '
          + 'bumps `store.shard.seq`, which re-keys the element so the animation replays instead of '
          + 'the text silently swapping.',
      },
    },
  },
  argTypes: {
    title: { control: 'text', description: 'Big line. Rendered uppercase, wraps if it has to.', table: { category: 'shard:show' } },
    subtitle: { control: 'text', description: 'Optional second line; omitted when empty.', table: { category: 'shard:show' } },
    style: {
      control: 'inline-radio',
      options: ['wasted', 'success', 'info'],
      description: 'Tints title + hairlines. Anything else falls back to `info`.',
      table: { category: 'shard:show', defaultValue: { summary: 'info' } },
    },
    duration: {
      control: { type: 'number', step: 500 },
      description: 'Auto-hide in ms (Lua default 4000). The stories hold it open on purpose.',
      table: { category: 'shard:show', defaultValue: { summary: '4000' } },
    },
  },
  args: { duration: HOLD_MS },
}

export const Wasted = {
  ...base,
  name: 'Wasted (death)',
  args: { title: 'Wasted', subtitle: 'You lost $500', style: 'wasted' },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: call({ title: 'Wasted', subtitle: 'You lost $500', style: 'wasted', duration: HOLD_MS }),
    },
    docs: {
      description: {
        story: 'What `Core.Player` fires on the `playerDied` hook. Red (`--core-error`), the one '
          + 'style players already know from the base game.',
      },
    },
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.title)).toBeInTheDocument())
    expect(canvas.getByText(args.subtitle)).toBeInTheDocument()
    const shard = canvasElement.querySelector('.shard')
    expect(shard.classList.contains('is-wasted')).toBe(true)
    // It must never eat a click: the game is still running underneath.
    expect(getComputedStyle(shard).pointerEvents).toBe('none')
  },
}

export const Success = {
  ...base,
  name: 'Success (job done)',
  args: { title: 'Mission passed', subtitle: 'Respect +  $1,250', style: 'success' },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: call({ title: 'Mission passed', subtitle: 'Respect +  $1,250', style: 'success', duration: HOLD_MS }),
    },
    docs: { description: { story: 'Green (`--core-success`) — the end of a delivery run, a heist payout, a licence passed.' } },
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.title)).toBeInTheDocument())
    expect(canvasElement.querySelector('.shard').classList.contains('is-success')).toBe(true)
  },
}

export const Info = {
  ...base,
  name: 'Info (default style)',
  args: { title: 'Wanted level increased', subtitle: 'Lose the cops to stay free', style: 'info' },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: call({ title: 'Wanted level increased', subtitle: 'Lose the cops to stay free', style: 'info', duration: HOLD_MS }),
    },
    docs: {
      description: {
        story: 'The accent-blue fallback. A long title stays on one line down to ~34 px '
          + '(`clamp(34px, 6.2vw, 66px)`) before it wraps.',
      },
    },
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.title)).toBeInTheDocument())
    expect(canvasElement.querySelector('.shard').classList.contains('is-info')).toBe(true)
  },
}

export const TitleOnly = {
  ...base,
  name: 'Title only',
  args: { title: 'Busted', subtitle: '', style: 'wasted' },
  parameters: {
    ...base.parameters,
    lua: { ...base.parameters.lua, call: call({ title: 'Busted', subtitle: '', style: 'wasted', duration: HOLD_MS }) },
    docs: { description: { story: '`subtitle` is optional — the row is not rendered at all, so the band keeps its proportions.' } },
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText(args.title)).toBeInTheDocument())
    expect(canvasElement.querySelector('.shard .core-shard__subtitle')).toBeNull()
  },
}

export const Replaced = {
  ...base,
  name: 'Replaced by a second shard',
  args: { title: 'Mission passed', subtitle: 'Respect +  $1,250', style: 'success' },
  parameters: {
    ...base.parameters,
    lua: {
      ...base.parameters.lua,
      call: "Core.UI.shard({ title = 'Mission passed', style = 'success' })\n"
        + "-- 900 ms later, while the first one is still up:\n"
        + "Core.UI.shard({ title = 'Wanted level increased', style = 'info' })",
      note: 'The second message wins immediately; the first one\'s timer is dropped with it.',
    },
    docs: {
      description: {
        story: 'Two shards in a row. `mode="out-in"` on the Transition plays the first one out '
          + 'before the second enters, so they never overlap — and the second `duration` replaces '
          + 'the first timer instead of stacking with it.',
      },
    },
  },
  render: liveScene((args) => {
    resetExtras()
    send({ action: 'shard:show', title: args.title, subtitle: args.subtitle, style: args.style, duration: args.duration })
    setTimeout(() => send({
      action: 'shard:show',
      title: 'Wanted level increased',
      subtitle: 'Lose the cops to stay free',
      style: 'info',
      duration: args.duration,
    }), 900)
  }, view),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Wanted level increased')).toBeInTheDocument(), { timeout: 4000 })
    expect(canvasElement.querySelectorAll('.shard').length).toBe(1)
  },
}
