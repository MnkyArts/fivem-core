<script setup>
// Need bars in the top-right rail (DESIGN §18 + §21 `stats:set`, §39.4) — one thin bar per
// `Config.Stats` def with `hud = true`. App.vue hangs this in the rail, so the component does
// no positioning of its own.
//
// §39.4 split the stats in two: a def whose `hud` is `'health'` or `'armour'` arrives with a
// `slot` and is drawn by Hud.vue as the bar cut out of that vital plate, so it is SKIPPED here.
// What is left is a plugin's extra need, which still gets a rail row — and with the two defs
// core ships (hunger -> health, thirst -> armour) that leaves nothing, so the plate renders
// nothing at all.
//
// State -> render (§37.6): the plate is a <CorePanel variant="hud">, every row an inline
// <CoreProgress>. The thresholds of §18 are the kit's own (`warnBelow` / `dangerBelow` swap the
// tone at 25 % and 10 %); `is-ok` / `is-warning` / `is-error` stay on the row as the hook
// classes the stories read off `.stats .stat`. Above the thresholds a stat named after one of
// the kit's vitals (§37.2) wears that vital's tone, anything else the neutral ramp.
import { computed } from 'vue'
import { store } from '../store.js'
import CorePanel from '../kit/components/CorePanel.vue'
import CoreProgress from '../kit/components/CoreProgress.vue'

const WARNING_PCT = 25
const ERROR_PCT = 10

const VITALS = ['health', 'armour', 'stamina', 'hunger', 'thirst', 'oxygen', 'stress']

function percent (stat) {
  const span = stat.max - stat.min
  if (!(span > 0)) return 0
  return Math.min(100, Math.max(0, ((stat.value - stat.min) / span) * 100))
}

/** A healthy bar is the vital's own colour when the name is one of the kit's seven; anything else
    takes the neutral ramp, which cannot be mistaken for the coral accent or the error red. */
function okTone (name) {
  return VITALS.indexOf(String(name).toLowerCase()) === -1 ? 'neutral' : String(name).toLowerCase()
}

// Lua tables have no order, so the bars are sorted by name: the stack never reshuffles
// between two `stats:set` messages.
const rows = computed(() => Object.keys(store.stats)
  .sort()
  .filter((name) => !(store.stats[name] && store.stats[name].slot))
  .map((name) => {
    const stat = store.stats[name]
    const pct = percent(stat)
    return {
      name,
      label: stat.label || name,
      pct,
      level: pct < ERROR_PCT ? 'error' : pct < WARNING_PCT ? 'warning' : 'ok',
      tone: okTone(name),
    }
  }))
</script>

<template>
  <Transition name="core-slide-down">
    <CorePanel
      v-if="rows.length"
      tag="div"
      variant="hud"
      padding="sm"
      blur
      class="stats w-[268px]"
    >
      <div class="flex flex-col gap-[9px]">
        <!-- The right gutter is the width of the HUD's vitals number column plus its gap, so the
             bars of the two plates end on the same line in the rail, and the label column is
             fixed so the tracks all start on one line however long a stat name is. -->
        <CoreProgress
          v-for="row in rows"
          :key="row.name"
          class="stat pr-[58px]"
          :class="'is-' + row.level"
          inline
          :tone="row.tone"
          :value="row.pct"
          :warn-below="WARNING_PCT"
          :danger-below="ERROR_PCT"
        >
          <template #label>
            <span class="block w-[66px] truncate">{{ row.label }}</span>
          </template>
        </CoreProgress>
      </div>
    </CorePanel>
  </Transition>
</template>
