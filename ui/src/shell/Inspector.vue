<script>
// The panel and `window.__core.inspect()` (the offline suites' seam) must be ONE lazy chunk, so
// both import THIS module: a named re-export from the plain <script> block keeps the snapshot
// reachable without a second dynamic entry point (DESIGN §38.14).
export { snapshot } from '../runtime/inspector.ts'
</script>

<script setup>
// The UI platform inspector (DESIGN §38.14) — dev only, lazily imported.
//
// Read-only by construction: `pointer-events: none` on the whole panel, no control, no focus, so it
// can never steal a click from the page it is watching. It refreshes twice a second WHILE VISIBLE
// and nothing at all when it is not — it is only mounted while `store.dev.inspector` is true, and
// `runtime/inspector.ts` arms its PerformanceObserver and the transport's byte counting on mount.
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { snapshot, start, stop } from '../runtime/inspector.ts'

const REFRESH_MS = 500
const data = ref(snapshot())
let timer = null

const tick = () => { data.value = snapshot() }

onMounted(() => {
  start()
  tick()
  timer = setInterval(tick, REFRESH_MS)
})

onBeforeUnmount(() => {
  if (timer) clearInterval(timer)
  timer = null
  stop()
})

const TONE = { ready: 'text-success', loading: 'text-info', registered: 'text-fg-dim', failed: 'text-error', incompatible: 'text-warning' }
const tone = (state) => TONE[state] || 'text-fg-dim'
const short = (url) => String(url || '').split('/').pop() || '—'
const bytes = (n) => (n >= 1024 ? Math.round(n / 102.4) / 10 + ' kB/s' : Math.round(n) + ' B/s')
</script>

<template>
  <!-- z 70: above #core-overlays (60), so a kit popup cannot hide the panel that explains it -->
  <section
    class="core-inspector pointer-events-none fixed top-4 left-4 z-[70] max-h-[86vh] w-[440px] overflow-hidden rounded-ui border border-border bg-panel-solid font-mono text-ui-xs text-fg-dim shadow-ui"
    aria-hidden="true"
  >
    <header class="flex items-baseline justify-between border-b border-border px-3 py-2">
      <span class="font-display text-ui-sm tracking-label text-fg uppercase">UI inspector</span>
      <span>{{ data.traffic.outPerSec }}↑ {{ data.traffic.inPerSec }}↓ msg/s · {{ bytes(data.traffic.bytesOutPerSec) }}</span>
    </header>

    <div class="max-h-[78vh] overflow-y-auto px-3 py-2">
      <p class="mt-0 mb-1 tracking-label text-fg-faint uppercase">plugins</p>
      <table class="w-full border-collapse">
        <tr v-for="p in data.plugins" :key="p.id" class="align-top">
          <td class="pr-2 text-fg">{{ p.id }}</td>
          <td class="pr-2" :class="tone(p.state)">{{ p.state }}</td>
          <td class="pr-2">gen {{ p.generation }}</td>
          <td class="pr-2">{{ p.build || '—' }}</td>
          <td class="pr-2">{{ p.ms == null ? '—' : p.ms + ' ms' }}</td>
          <td>{{ p.dev ? 'dev' : short(p.url) }}</td>
        </tr>
        <tr v-if="!data.plugins.length"><td class="text-fg-faint">no plugin registered</td></tr>
      </table>
      <p v-for="p in data.plugins.filter((x) => x.error)" :key="p.id + ':err'" class="my-1 break-words text-error">
        {{ p.id }}: {{ p.error }}
      </p>

      <p class="mt-3 mb-1 tracking-label text-fg-faint uppercase">pages</p>
      <table class="w-full border-collapse">
        <tr v-for="p in data.pages" :key="p.id">
          <td class="pr-2 text-fg">{{ p.id }}</td>
          <td class="pr-2">{{ p.owner || 'core' }}</td>
          <td class="pr-2">{{ p.type }}</td>
          <td class="pr-2" :class="p.mounted ? 'text-success' : p.open ? 'text-warning' : ''">
            {{ p.mounted ? 'mounted' : p.open ? 'open' : 'declared' }}
          </td>
          <td>{{ p.crashed ? 'crashed' : p.keepAlive ? 'keep-alive' : p.reactivity }}</td>
        </tr>
        <tr v-if="!data.pages.length"><td class="text-fg-faint">no page declared</td></tr>
      </table>

      <p class="mt-3 mb-1 tracking-label text-fg-faint uppercase">focus stack (top last)</p>
      <p class="my-0 text-fg">{{ data.focus.map((f) => f.key).join('  ›  ') || 'empty' }}</p>

      <p class="mt-3 mb-1 tracking-label text-fg-faint uppercase">scopes</p>
      <table class="w-full border-collapse">
        <tr v-for="s in data.scopes" :key="s.label">
          <td class="pr-2 text-fg">{{ s.label }}</td>
          <td class="pr-2">{{ s.listeners }} lis</td>
          <td class="pr-2">{{ s.timers }} tim</td>
          <td class="pr-2">{{ s.rafs }} raf</td>
          <td>{{ s.hooks }} hook</td>
        </tr>
        <tr v-if="!data.scopes.length"><td class="text-fg-faint">none</td></tr>
      </table>

      <p class="mt-3 mb-1 tracking-label text-fg-faint uppercase">requests · feeds · modules</p>
      <p v-for="c in data.channels" :key="c.channel" class="my-0">
        {{ c.channel }}: {{ c.handlers }} handler(s), {{ c.pending }} pending
      </p>
      <p class="my-0">
        feeds: {{ data.feeds.channels }} channel(s), {{ data.feeds.writesPerSec }} writes/s,
        {{ data.feeds.flushesPerSec }} flush/s
      </p>
      <p v-for="m in data.modules" :key="m.url" class="my-0 break-words">{{ short(m.url) }} — {{ m.state }}</p>

      <p v-if="data.longTasks.length" class="mt-3 mb-1 tracking-label text-fg-faint uppercase">long tasks</p>
      <p v-for="(t, i) in data.longTasks" :key="i" class="my-0 text-warning">{{ t.duration }} ms</p>

      <p v-if="data.errors.length" class="mt-3 mb-1 tracking-label text-fg-faint uppercase">
        errors ({{ data.errors.length }})
      </p>
      <p v-for="(e, i) in data.errors.slice(-8)" :key="i" class="my-0 break-words text-error">
        {{ e.plugin || 'shell' }}{{ e.page ? '/' + e.page : '' }}: {{ e.message }}
      </p>
    </div>
  </section>
</template>
