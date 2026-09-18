<script setup>
// Top-right HUD: cash / bank / vitals / location / faction / name + server id
// (DESIGN §7.2, hud:set in §6.10, health / armour / speed / street / zone in §21).
//
// State -> render (§37.6): the plate is a <CorePanel variant="hud">, the money / place /
// faction / identity rows are <CoreKeyValue> lists (label voice left, display voice right, one
// hairline per row), the vitals are <CoreStatBar> rows (mockup 2's icon · chunky bar · big
// number) and the faction chip is a <CoreTag> wearing the faction's own colour. Nothing here
// paints: every hairline, size and colour belongs to the kit.
//
// The §21 fields are optional: `client/hudfeed.lua` pushes them at most every 250 ms and
// only on change, so a server that never sends them renders exactly the v1 HUD.
import { computed } from 'vue'
import { store } from '../store.js'
import CorePanel from '../kit/components/CorePanel.vue'
import CoreKeyValue from '../kit/components/CoreKeyValue.vue'
import CoreStatBar from '../kit/components/CoreStatBar.vue'
import CoreTag from '../kit/components/CoreTag.vue'

const WARNING_PCT = 25
const ERROR_PCT = 10

// The plate is 268 px wide with 12 px of padding: icon 20 + gap 14 + BAR + gap 14 + value 44
// fills the 242 px content box exactly, and StatsBars aligns its own tracks to the same end.
const BAR_WIDTH = 150

// Health thresholds as kit tones; `is-ok` / `is-warning` / `is-error` stay on the row as hook
// classes (the stories read them back off `.hud .bar`). Health is the `health` vital until it
// crosses a threshold, then it borrows the warning / danger tone.
const HEALTH_TONE = { ok: 'health', warning: 'warning', error: 'danger' }

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

const moneyItems = computed(() => [
  { label: 'Cash', value: money(store.hud.cash), tone: 'success' },
  { label: 'Bank', value: money(store.hud.bank) },
])

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

// The place row reads as a key/value pair of its own: the zone is the label, the street the
// value — which is exactly how the mockups' read-out rows are built.
const placeItems = computed(() => [{ label: zone.value, value: street.value }])

// faction is { name, tag, color } or false/null
const faction = computed(() => (store.hud.faction ? store.hud.faction : null))
const factionItems = computed(() => (faction.value ? [{ label: faction.value.name || '' }] : []))
// A faction brands its own chip: the colour becomes the tag's --tone, so the kit's soft fill,
// hairline and label are all in it. An unparseable colour falls back to the accent tone.
const factionStyle = computed(() => {
  const rgb = faction.value ? triplet(faction.value.color) : null
  return rgb ? { '--tone': faction.value.color, '--tone-rgb': rgb } : null
})

const identItems = computed(() => [{
  label: store.hud.name || '',
  value: store.hud.serverId ? '#' + store.hud.serverId : '',
  tone: 'accent',
}])
</script>

<template>
  <Transition name="core-slide-down">
    <CorePanel
      v-if="store.hud.visible"
      tag="div"
      variant="hud"
      padding="sm"
      blur
      class="hud w-[268px]"
    >
      <CoreKeyValue class="money" :items="moneyItems" />

      <div v-if="health !== null || armour !== null" class="vitals flex flex-col gap-[10px] py-[11px]">
        <CoreStatBar
          v-if="health !== null"
          class="bar"
          :class="'is-' + healthLevel"
          icon="heart"
          :tone="HEALTH_TONE[healthLevel]"
          :value="health"
          :width="BAR_WIDTH"
          :low-below="WARNING_PCT"
        />
        <!-- Mockup 2 draws the shield white over the blue bar, and armour never pulses. -->
        <CoreStatBar
          v-if="armour !== null"
          class="bar is-armour"
          icon="shield"
          icon-tone="fg"
          tone="armour"
          :value="armour"
          :width="BAR_WIDTH"
          :low-below="0"
        />
      </div>

      <CoreKeyValue v-if="speed !== null" class="meta" :items="[{ label: 'Speed', value: speed }]">
        <template #value-0>
          <span class="speed">{{ speed }}</span>
          <span class="core-label inline-block ml-[4px]">km/h</span>
        </template>
      </CoreKeyValue>

      <CoreKeyValue v-if="street || zone" class="place" :items="placeItems" />

      <CoreKeyValue v-if="faction" class="faction" :items="factionItems">
        <!-- A faction name is as long as its owner made it; the label column is what gives. -->
        <template #label-0>
          <span class="fname block min-w-0 truncate">{{ faction.name }}</span>
        </template>
        <template #value-0>
          <CoreTag
            class="tag"
            size="sm"
            variant="soft"
            tone="accent"
            :style="factionStyle"
            :label="faction.tag || '?'"
          />
        </template>
      </CoreKeyValue>

      <CoreKeyValue class="ident" :items="identItems" :last-rule="false">
        <template #label-0>
          <span class="name block min-w-0 truncate">{{ store.hud.name }}</span>
        </template>
      </CoreKeyValue>
    </CorePanel>
  </Transition>
</template>
