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
    return {
      name,
      label: stat.label || name,
      pct,
      level: pct < ERROR_PCT ? 'error' : pct < WARNING_PCT ? 'warning' : 'ok',
    }
  }))
</script>

<template>
  <Transition name="stats">
    <div v-if="rows.length" class="stats">
      <div v-for="row in rows" :key="row.name" class="stat" :class="'is-' + row.level">
        <span class="lbl">{{ row.label }}</span>
        <span class="track">
          <span class="fill" :style="{ width: row.pct + '%' }"></span>
        </span>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
.stats {
  pointer-events: none;
  min-width: 176px;
  padding: 8px 12px;
  background: var(--core-panel, rgba(14, 16, 20, 0.86));
  border: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  border-radius: var(--core-radius, 8px);
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.stat {
  display: flex;
  align-items: center;
  gap: 9px;
}

.lbl {
  flex: 0 0 54px;
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.track {
  flex: 1 1 auto;
  height: 4px;
  border-radius: 3px;
  background: rgba(255, 255, 255, 0.08);
  overflow: hidden;
}

.fill {
  display: block;
  height: 100%;
  border-radius: 3px;
  background: var(--core-accent, #5b8cff);
  transition: width 0.25s var(--core-ease, ease), background 0.2s ease;
}

.is-warning .fill { background: var(--core-warning, #ffb347); }
.is-error .fill { background: var(--core-error, #ff5d5d); }
.is-error .lbl { color: var(--core-error, #ff5d5d); }

.stats-enter-active,
.stats-leave-active { transition: opacity 0.18s ease, transform 0.18s ease; }

.stats-enter-from,
.stats-leave-to { opacity: 0; transform: translateY(-6px); }
</style>
