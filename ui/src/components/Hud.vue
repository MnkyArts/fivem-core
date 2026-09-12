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
    <div v-if="store.hud.visible" class="hud">
      <div class="line">
        <span class="lbl">Cash</span>
        <span class="val cash">{{ cash }}</span>
      </div>
      <div class="line">
        <span class="lbl">Bank</span>
        <span class="val bank">{{ bank }}</span>
      </div>

      <div v-if="health !== null || armour !== null" class="vitals">
        <div v-if="health !== null" class="bar" :class="'is-' + healthLevel">
          <span class="blbl">Health</span>
          <span class="track"><span class="fill" :style="{ width: health + '%' }"></span></span>
        </div>
        <div v-if="armour !== null" class="bar is-armour">
          <span class="blbl">Armour</span>
          <span class="track"><span class="fill" :style="{ width: armour + '%' }"></span></span>
        </div>
      </div>

      <div v-if="hasMeta" class="meta">
        <div v-if="speed !== null" class="line">
          <span class="lbl">Speed</span>
          <span class="val speed">{{ speed }}<i>km/h</i></span>
        </div>
        <div v-if="street || zone" class="place">
          <span class="street">{{ street }}</span>
          <span v-if="zone" class="zone">{{ zone }}</span>
        </div>
      </div>

      <div v-if="faction" class="line faction">
        <span class="tag" :style="{ borderColor: factionColor, color: factionColor }">
          {{ faction.tag || '?' }}
        </span>
        <span class="fname">{{ faction.name }}</span>
      </div>

      <div class="ident">
        <span class="name">{{ store.hud.name }}</span>
        <span v-if="store.hud.serverId" class="sid">#{{ store.hud.serverId }}</span>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
.hud {
  pointer-events: none;
  min-width: 176px;
  padding: 10px 12px 8px;
  background: var(--core-panel, rgba(14, 16, 20, 0.86));
  border: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  border-radius: var(--core-radius, 8px);
  font-size: 13px;
  line-height: 1.35;
  text-align: right;
}

.line {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
}

.lbl {
  font-size: 10px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
}

.val {
  font-variant-numeric: tabular-nums;
  font-weight: 600;
}

.cash { color: var(--core-success, #3ddc84); }
.bank { color: var(--core-text, #f2f4f8); }

.vitals,
.meta {
  margin-top: 7px;
  padding-top: 7px;
  border-top: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
}

.vitals {
  display: flex;
  flex-direction: column;
  gap: 5px;
}

.bar {
  display: flex;
  align-items: center;
  gap: 9px;
}

/* same 54 px label column as StatsBars.vue, so both stacks line up in the rail */
.blbl {
  flex: 0 0 54px;
  text-align: left;
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
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
  background: var(--core-success, #3ddc84);
  transition: width 0.2s var(--core-ease, ease), background 0.2s ease;
}

.is-warning .fill { background: var(--core-warning, #ffb347); }
.is-error .fill { background: var(--core-error, #ff5d5d); }
.is-error .blbl { color: var(--core-error, #ff5d5d); }
.is-armour .fill { background: var(--core-accent, #5b8cff); }

.speed i {
  margin-left: 3px;
  font-style: normal;
  font-size: 10px;
  font-weight: 500;
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
}

.place {
  display: flex;
  align-items: baseline;
  justify-content: flex-end;
  gap: 7px;
  margin-top: 3px;
  font-size: 11px;
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
  overflow: hidden;
}

.street {
  color: var(--core-text, #f2f4f8);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.zone {
  flex: 0 0 auto;
  max-width: 92px;
  font-size: 10px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--core-text-faint, rgba(242, 244, 248, 0.38));
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.faction {
  margin-top: 6px;
  padding-top: 6px;
  border-top: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  justify-content: flex-end;
  gap: 8px;
}

.tag {
  padding: 1px 5px;
  border: 1px solid var(--core-accent, #5b8cff);
  border-radius: 4px;
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.fname {
  font-size: 12px;
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
  max-width: 150px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.ident {
  margin-top: 6px;
  padding-top: 6px;
  border-top: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  display: flex;
  align-items: baseline;
  justify-content: flex-end;
  gap: 8px;
  font-size: 11px;
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
}

.name {
  max-width: 150px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.sid {
  font-variant-numeric: tabular-nums;
  color: var(--core-accent, #5b8cff);
}

.hud-enter-active,
.hud-leave-active { transition: opacity 0.18s ease, transform 0.18s ease; }

.hud-enter-from,
.hud-leave-to { opacity: 0; transform: translateY(-6px); }
</style>
