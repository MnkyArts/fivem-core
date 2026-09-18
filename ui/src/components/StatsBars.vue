<script setup>
// Need bars under the HUD (DESIGN §18 + §21 `stats:set`) — one thin bar per
// `Config.Stats` def with `hud = true`. App.vue hangs this in the top-right rail
// directly under Hud.vue, so the component does no positioning of its own.
//
// Skin: the same --color-hud plate as Hud.vue, rows as inline CoreProgress bars
// (label voice · 8 px track) — DESIGN §37.6.
//
// Colour follows the def's thresholds: amber under 25 %, red under 10 % (§18). Above them a
// stat named after one of the kit's vitals (§37.2) wears that vital's tone, anything else the
// neutral ramp.
import { computed } from 'vue'
import { store } from '../store.js'

const WARNING_PCT = 25
const ERROR_PCT = 10

// Threshold tones; `is-ok` / `is-warning` / `is-error` stay on the row as hook classes
// (the stories read them back off `.stats .stat`).
const VITALS = ['health', 'armour', 'stamina', 'hunger', 'thirst', 'oxygen', 'stress']
const LEVEL_TONE = { warning: 'core-tone-warning', error: 'core-tone-danger' }
const LABEL = { ok: 'text-fg-dim', warning: 'text-fg-dim', error: 'text-error' }

function percent (stat) {
  const span = stat.max - stat.min
  if (!(span > 0)) return 0
  return Math.min(100, Math.max(0, ((stat.value - stat.min) / span) * 100))
}

/** A healthy bar is the vital's own colour when the name is one of the kit's seven; anything else
    takes the neutral ramp, which cannot be mistaken for the coral accent or the error red. */
function okTone (name) {
  return VITALS.indexOf(String(name).toLowerCase()) === -1 ? 'core-tone-neutral' : 'core-tone-' + name
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
      toneClass: LEVEL_TONE[level] || okTone(name),
      labelClass: LABEL[level],
    }
  }))
</script>

<template>
  <Transition name="stats">
    <div
      v-if="rows.length"
      class="stats pointer-events-none w-[268px] px-[14px] py-[11px]
             bg-hud border border-border rounded-ui-sm shadow-ui-sm
             [--core-glass-tint:var(--color-hud)] flex flex-col gap-[9px]"
      data-core-blur
    >
      <!-- The right gutter is the width of the HUD's vitals number column, so the bars of the two
           plates end on the same line in the rail — the way the 54 px label column used to line up
           their left edges. -->
      <div
        v-for="row in rows"
        :key="row.name"
        class="stat core-progress core-progress--md core-progress--inline gap-[10px] pr-[45px]"
        :class="['is-' + row.level, row.toneClass]"
      >
        <span
          class="lbl core-progress__label mr-0 flex-[0_0_66px]"
          :class="row.labelClass"
        >{{ row.label }}</span>
        <span class="track core-progress__track flex-auto">
          <span class="fill core-progress__fill" :style="{ width: row.pct + '%' }"></span>
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
