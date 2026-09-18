<script setup>
// Top-right HUD: cash / bank / vitals / location / faction / name + server id
// (DESIGN §7.2, hud:set in §6.10, health / armour / speed / street / zone in §21).
//
// Skin: the kit's HUD plate (DESIGN §37.6) — a --color-hud plate with a hairline and the
// 4 px radius, money in the display voice, the vitals as CoreStatBar rows (mockup 2's
// icon · chunky bar · big number) and hairline-separated rows under them.
//
// The §21 fields are optional: `client/hudfeed.lua` pushes them at most every 250 ms and
// only on change, so a server that never sends them renders exactly the v1 HUD.
import { computed } from 'vue'
import { store } from '../store.js'
import CoreIcon from '../kit/components/CoreIcon.vue'
import CoreTag from '../kit/components/CoreTag.vue'

const WARNING_PCT = 25
const ERROR_PCT = 10

// Health thresholds as kit tones; `is-ok` / `is-warning` / `is-error` stay on the row as hook
// classes (the stories read them back off `.hud .bar`). Health is the `health` vital until it
// crosses a threshold, then it borrows the warning / danger tone.
const HEALTH_TONE = { ok: 'core-tone-health', warning: 'core-tone-warning', error: 'core-tone-danger' }
const HEALTH_VALUE = { ok: 'text-fg', warning: 'text-warning', error: 'text-error' }

function money (n) {
  const v = Math.round(Number(n) || 0)
  return '$' + v.toLocaleString('en-US')
}

/** 0..100 for a bar, or null when Lua has not sent the field (so the row stays hidden). */
function pct (n) {
  return typeof n === 'number' && isFinite(n) ? Math.min(100, Math.max(0, n)) : null
}

/** `#f5a623` -> `245 166 35`, the triplet kit CSS writes its alphas with (Chromium 103, §37.4). */
function triplet (hex) {
  const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(String(hex || '').trim())
  if (!m) return null
  let h = m[1]
  if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]
  const n = parseInt(h, 16)
  return ((n >> 16) & 255) + ' ' + ((n >> 8) & 255) + ' ' + (n & 255)
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
const healthText = computed(() => Math.round(health.value || 0))
const armourText = computed(() => Math.round(armour.value || 0))

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
// A faction brands its own chip: the colour becomes the tag's --tone, so the kit's soft fill,
// hairline and label are all in it. An unparseable colour falls back to the accent tone.
const factionStyle = computed(() => {
  const rgb = faction.value ? triplet(faction.value.color) : null
  return rgb ? { '--tone': faction.value.color, '--tone-rgb': rgb } : null
})
</script>

<template>
  <Transition name="hud">
    <div
      v-if="store.hud.visible"
      class="hud pointer-events-none w-[268px] px-[14px] pt-[11px] pb-[10px]
             bg-hud border border-border rounded-ui-sm shadow-ui-sm
             [--core-glass-tint:var(--color-hud)]"
      data-core-blur
    >
      <div class="line flex items-baseline justify-between gap-[12px]">
        <span class="lbl core-label">Cash</span>
        <span class="val cash core-num text-[21px] leading-none text-success">{{ cash }}</span>
      </div>
      <div class="line mt-[7px] flex items-baseline justify-between gap-[12px]">
        <span class="lbl core-label">Bank</span>
        <span class="val bank core-num text-[17px] leading-none text-fg">{{ bank }}</span>
      </div>

      <div
        v-if="health !== null || armour !== null"
        class="vitals mt-[11px] pt-[11px] border-t border-border flex flex-col gap-[9px]"
      >
        <div
          v-if="health !== null"
          class="bar core-statbar gap-[11px]"
          :class="['is-' + healthLevel, HEALTH_TONE[healthLevel], { 'is-low': healthLevel !== 'ok' }]"
        >
          <CoreIcon name="heart" :size="18" class="core-statbar__icon" />
          <span class="track core-statbar__track flex-auto">
            <span class="fill core-statbar__fill" :style="{ width: health + '%' }"></span>
          </span>
          <span
            class="num core-statbar__value min-w-[34px] text-right text-[17px]"
            :class="HEALTH_VALUE[healthLevel]"
          >{{ healthText }}</span>
        </div>
        <div v-if="armour !== null" class="bar is-armour core-statbar core-tone-armour gap-[11px]">
          <CoreIcon name="shield" :size="18" class="core-statbar__icon" />
          <span class="track core-statbar__track flex-auto">
            <span class="fill core-statbar__fill" :style="{ width: armour + '%' }"></span>
          </span>
          <span class="num core-statbar__value min-w-[34px] text-right text-[17px] text-fg">{{ armourText }}</span>
        </div>
      </div>

      <div v-if="hasMeta" class="meta mt-[11px] pt-[10px] border-t border-border">
        <div v-if="speed !== null" class="line flex items-baseline justify-between gap-[12px]">
          <span class="lbl core-label">Speed</span>
          <span class="val speed core-num text-[17px] leading-none text-fg">{{ speed }}<i
            class="ml-[4px] not-italic font-display text-ui-xs font-semibold tracking-label uppercase text-fg-dim"
          >km/h</i></span>
        </div>
        <div
          v-if="street || zone"
          class="place flex items-baseline justify-end gap-[9px] overflow-hidden"
          :class="speed !== null ? 'mt-[8px] pt-[8px] border-t border-border' : ''"
        >
          <span class="street min-w-0 flex-auto truncate text-right text-ui-sm text-fg">{{ street }}</span>
          <span v-if="zone" class="zone core-label flex-none max-w-[104px] truncate text-fg-faint">{{ zone }}</span>
        </div>
      </div>

      <div
        v-if="faction"
        class="line faction mt-[10px] pt-[10px] border-t border-border flex items-center justify-end gap-[9px]"
      >
        <span class="fname min-w-0 flex-auto truncate text-right text-ui-sm text-fg-dim">{{ faction.name }}</span>
        <CoreTag
          class="tag flex-none"
          size="sm"
          variant="soft"
          tone="accent"
          :style="factionStyle"
          :label="faction.tag || '?'"
        />
      </div>

      <div
        class="ident mt-[10px] pt-[9px] border-t border-border flex items-baseline justify-end
               gap-[9px] text-ui-xs"
      >
        <span class="name min-w-0 flex-auto truncate text-right text-fg-dim">{{ store.hud.name }}</span>
        <span v-if="store.hud.serverId" class="sid core-num flex-none text-accent">#{{ store.hud.serverId }}</span>
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
