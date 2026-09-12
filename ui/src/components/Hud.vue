<script setup>
// Top-right HUD: cash / bank / vitals / location / faction / name + server id
// (DESIGN §7.2, hud:set in §6.10, health / armour / speed / street / zone in §21).
//
// The §21 fields are optional: `client/hudfeed.lua` pushes them at most every 250 ms and
// only on change, so a server that never sends them renders exactly the v1 HUD.
import { computed } from 'vue'
import { store } from '../store.js'

const WARNING_PCT = 25
const ERROR_PCT = 10

// Health thresholds as theme utilities; `is-ok` / `is-warning` / `is-error` stay on the
// row as hook classes (the stories read them back off `.hud .bar`).
const HEALTH_FILL = { ok: 'bg-success', warning: 'bg-warning', error: 'bg-error' }
const HEALTH_LABEL = { ok: 'text-fg-dim', warning: 'text-fg-dim', error: 'text-error' }

function money (n) {
  const v = Math.round(Number(n) || 0)
  return '$' + v.toLocaleString('en-US')
}

/** 0..100 for a bar, or null when Lua has not sent the field (so the row stays hidden). */
function pct (n) {
  return typeof n === 'number' && isFinite(n) ? Math.min(100, Math.max(0, n)) : null
}

const cash = computed(() => money(store.hud.cash))
const bank = computed(() => money(store.hud.bank))

const health = computed(() => pct(store.hud.health))
const armour = computed(() => pct(store.hud.armour))
const healthLevel = computed(() => {
  const v = health.value
  if (v === null || v >= WARNING_PCT) return 'ok'
  return v < ERROR_PCT ? 'error' : 'warning'
})

const speed = computed(() => (
  typeof store.hud.speed === 'number' && isFinite(store.hud.speed)
    ? Math.max(0, Math.round(store.hud.speed))
    : null
))
const street = computed(() => store.hud.street || '')
const zone = computed(() => store.hud.zone || '')
const hasMeta = computed(() => speed.value !== null || !!street.value || !!zone.value)

// faction is { name, tag, color } or false/null
const faction = computed(() => (store.hud.faction ? store.hud.faction : null))
const factionColor = computed(() => (faction.value && faction.value.color) || 'var(--core-accent, #5b8cff)')
</script>

<template>
  <Transition name="hud">
    <div
      v-if="store.hud.visible"
      class="hud pointer-events-none min-w-[176px] pt-[10px] px-[12px] pb-[8px]
             bg-panel border border-border rounded-ui text-[13px] leading-[1.35] text-right"
    >
      <div class="line flex items-baseline justify-between gap-[12px]">
        <span class="lbl text-ui-xs tracking-[0.08em] uppercase text-fg-dim">Cash</span>
        <span class="val cash tabular-nums font-semibold text-success">{{ cash }}</span>
      </div>
      <div class="line flex items-baseline justify-between gap-[12px]">
        <span class="lbl text-ui-xs tracking-[0.08em] uppercase text-fg-dim">Bank</span>
        <span class="val bank tabular-nums font-semibold text-fg">{{ bank }}</span>
      </div>

      <div
        v-if="health !== null || armour !== null"
        class="vitals mt-[7px] pt-[7px] border-t border-border flex flex-col gap-[5px]"
      >
        <div
          v-if="health !== null"
          class="bar flex items-center gap-[9px]"
          :class="'is-' + healthLevel"
        >
          <!-- same 54 px label column as StatsBars.vue, so both stacks line up in the rail -->
          <span
            class="blbl flex-[0_0_54px] text-left text-ui-xs font-semibold tracking-[0.08em] uppercase"
            :class="HEALTH_LABEL[healthLevel]"
          >Health</span>
          <span class="track flex-auto h-[4px] rounded-[3px] bg-[rgba(255,255,255,0.08)] overflow-hidden">
            <span
              class="fill block h-full rounded-[3px] [transition:width_0.2s_var(--ease-ui),background_0.2s_ease]"
              :class="HEALTH_FILL[healthLevel]"
              :style="{ width: health + '%' }"
            ></span>
          </span>
        </div>
        <div v-if="armour !== null" class="bar is-armour flex items-center gap-[9px]">
          <span class="blbl flex-[0_0_54px] text-left text-ui-xs font-semibold tracking-[0.08em] uppercase text-fg-dim">Armour</span>
          <span class="track flex-auto h-[4px] rounded-[3px] bg-[rgba(255,255,255,0.08)] overflow-hidden">
            <span
              class="fill block h-full rounded-[3px] bg-accent [transition:width_0.2s_var(--ease-ui),background_0.2s_ease]"
              :style="{ width: armour + '%' }"
            ></span>
          </span>
        </div>
      </div>

      <div v-if="hasMeta" class="meta mt-[7px] pt-[7px] border-t border-border">
        <div v-if="speed !== null" class="line flex items-baseline justify-between gap-[12px]">
          <span class="lbl text-ui-xs tracking-[0.08em] uppercase text-fg-dim">Speed</span>
          <span class="val speed tabular-nums font-semibold">{{ speed }}<i class="ml-[3px] not-italic text-ui-xs font-medium text-fg-dim">km/h</i></span>
        </div>
        <div
          v-if="street || zone"
          class="place flex items-baseline justify-end gap-[7px] mt-[3px] text-[11px] text-fg-dim overflow-hidden"
        >
          <span class="street text-fg truncate">{{ street }}</span>
          <span
            v-if="zone"
            class="zone flex-none max-w-[92px] text-ui-xs tracking-[0.06em] uppercase text-fg-faint truncate"
          >{{ zone }}</span>
        </div>
      </div>

      <div
        v-if="faction"
        class="line faction mt-[6px] pt-[6px] border-t border-border
               flex items-baseline justify-end gap-[8px]"
      >
        <span
          class="tag px-[5px] py-px border border-accent rounded-[4px] text-ui-xs font-bold
                 tracking-[0.06em] uppercase text-accent"
          :style="{ borderColor: factionColor, color: factionColor }"
        >
          {{ faction.tag || '?' }}
        </span>
        <span class="fname max-w-[150px] truncate text-ui-sm text-fg-dim">{{ faction.name }}</span>
      </div>

      <div
        class="ident mt-[6px] pt-[6px] border-t border-border flex items-baseline justify-end
               gap-[8px] text-[11px] text-fg-dim"
      >
        <span class="name max-w-[150px] truncate">{{ store.hud.name }}</span>
        <span v-if="store.hud.serverId" class="sid tabular-nums text-accent">#{{ store.hud.serverId }}</span>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
/* Vue transition classes — not expressible as utilities. */
.hud-enter-active,
.hud-leave-active { transition: opacity 0.18s ease, transform 0.18s ease; }

.hud-enter-from,
.hud-leave-to { opacity: 0; transform: translateY(-6px); }
</style>
