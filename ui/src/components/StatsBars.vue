<script setup>
// Need bars under the HUD (DESIGN §18 + §21 `stats:set`) — one thin bar per
// `Config.Stats` def with `hud = true`. App.vue hangs this in the top-right rail
// directly under Hud.vue, so the component does no positioning of its own.
//
// Colour follows the def's thresholds: amber under 25 %, red under 10 % (§18).
import { computed } from 'vue'
import { store } from '../store.js'

const WARNING_PCT = 25
const ERROR_PCT = 10

// Threshold colours as theme utilities; `is-ok` / `is-warning` / `is-error` stay on the
// row as hook classes (the stories read them back off `.stats .stat`).
const FILL = { ok: 'bg-accent', warning: 'bg-warning', error: 'bg-error' }
const LABEL = { ok: 'text-fg-dim', warning: 'text-fg-dim', error: 'text-error' }

function percent (stat) {
  const span = stat.max - stat.min
  if (!(span > 0)) return 0
  return Math.min(100, Math.max(0, ((stat.value - stat.min) / span) * 100))
}

// Lua tables have no order, so the bars are sorted by name: the stack never reshuffles
// between two `stats:set` messages.
const rows = computed(() => Object.keys(store.stats)
  .sort()
  .map((name) => {
    const stat = store.stats[name]
    const pct = percent(stat)
    const level = pct < ERROR_PCT ? 'error' : pct < WARNING_PCT ? 'warning' : 'ok'
    return {
      name,
      label: stat.label || name,
      pct,
      level,
      fillClass: FILL[level],
      labelClass: LABEL[level],
    }
  }))
</script>

<template>
  <Transition name="stats">
    <div
      v-if="rows.length"
      class="stats pointer-events-none min-w-[176px] px-[12px] py-[8px]
             bg-panel border border-border rounded-ui flex flex-col gap-[6px]"
      data-core-blur
    >
      <div
        v-for="row in rows"
        :key="row.name"
        class="stat flex items-center gap-[9px]"
        :class="'is-' + row.level"
      >
        <span
          class="lbl flex-[0_0_54px] text-ui-xs font-semibold tracking-[0.08em] uppercase
                 overflow-hidden text-ellipsis whitespace-nowrap"
          :class="row.labelClass"
        >{{ row.label }}</span>
        <span class="track flex-auto h-[4px] rounded-[3px] bg-[rgba(255,255,255,0.08)] overflow-hidden">
          <span
            class="fill block h-full rounded-[3px] [transition:width_0.25s_var(--ease-ui),background_0.2s_ease]"
            :class="row.fillClass"
            :style="{ width: row.pct + '%' }"
          ></span>
        </span>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
/* Vue transition classes — not expressible as utilities. */
.stats-enter-active,
.stats-leave-active { transition: opacity 0.18s ease, transform 0.18s ease; }

.stats-enter-from,
.stats-leave-to { opacity: 0; transform: translateY(-6px); }
</style>
