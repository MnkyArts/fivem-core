<script setup>
// The vitals HUD (DESIGN §39.4): the mic tile, the HEALTH plate and the ARMOR plate as ONE
// horizontal strip, bottom-left by default (or next to the minimap rect when the config says so).
// §39 replaces the top-right HUD plate of §7.2 / §21 —
// cash, bank, speed, street, zone, faction, name and server id are no longer DRAWN by core;
// they stay in `store.hud` because `useHud()` hands them to plugin pages.
//
// This file is a §37.6 shell widget: store bindings, hook classes and layout, nothing else.
// Every pixel belongs to <CoreVital> and <CoreHudTile>; the only geometry here is WHERE the
// strip sits and HOW BIG one `em` is:
//
//   * `--core-hud-unit` is the strip's font size (1em = 100 px of Liam's mockup), so the whole
//     strip scales with one number. It is set as BOTH the custom property and `font-size`: the
//     kit components read the variable, and the root's own `gap` / `left` offsets are in the
//     same `em`. 24 px is the default, and it is FIXED px — the rest of the shell is fixed px
//     too (the rail is 268px, the progress panel 340px), so a strip that grew with the screen
//     height would be the one element that stops matching them. `Config.Hud.Scale` is the knob
//     for a player who wants it bigger.
//   * `--core-hudtile-h` is how the tile matches the plates next to it. It is a variable, not a
//     prop: 2.05em beside full vitals, 1.57em beside `--solo` ones (no slotted stat at all).
//
// The sub bars are the `stats:set` entries carrying a `slot` — those rows are NOT in the rail
// (StatsBars.vue skips them), so every stat has exactly one home.
import { computed } from 'vue'
import { store } from '../store.js'
import CoreHudTile from '../kit/components/CoreHudTile.vue'
import CoreVital from '../kit/components/CoreVital.vue'

/** 24 px from the screen edge for the fixed anchor (§39.4). */
const EDGE = 24

/** The TWO placements client/ui.lua lets through; anything else falls back to the default
 *  (`'bottom-left'`). A bottom-centre or bottom-right strip was cut from the contract: it lands
 *  on the progress bar and the text UI in the middle, and on the key hints and the spinner on
 *  the right. */
const ANCHORS = ['minimap', 'bottom-left']

/** Vanilla 16:9 minimap at the default safe zone — assumed until a `minimap` rect arrives, so
 *  the strip never starts in the wrong corner and then jumps (§39.4). */
const DEFAULT_MINIMAP = { x: 0.025, y: 0.779, w: 0.141, h: 0.176 }

/** The default `--core-hud-unit` in px (1em = 100 px of the mockup): the strip is 14.63em, so
 *  24 px puts it at about 351 px of layout (≈ 369 px of ink once the skew overhangs) and 76 px
 *  tall. Liam's ruling after seeing it at 13 px: "the 200 width was way too small, make it like
 *  365" — same look, one number. */
const UNIT_PX = 24

/** `Config.Hud.Scale` is validated in Lua; a bad value from anywhere else is clamped here.
 *  0.5..2 of the 24 px unit = 12 px .. 48 px. */
const SCALE_MIN = 0.5
const SCALE_MAX = 2

/** core's locale table, with the English fallback the contract names (§39.4). */
function t (key, fallback) {
  const strings = store.locale && store.locale.strings
  const value = strings ? strings[key] : null
  return typeof value === 'string' && value !== '' ? value : fallback
}

/** 0..100 for a plate, or null when Lua has not sent the field (so the plate stays hidden). */
function pct (n) {
  return typeof n === 'number' && isFinite(n) ? Math.min(100, Math.max(0, n)) : null
}

/** A stat's 0..100 over its own span — the same maths StatsBars.vue uses for a rail row. */
function percent (stat) {
  const span = stat.max - stat.min
  if (!(span > 0)) return 0
  return Math.min(100, Math.max(0, ((stat.value - stat.min) / span) * 100))
}

/** Trims the float noise out of a computed vw / vh so the inline style stays readable. */
const round = (n) => Math.round(n * 10000) / 10000

const health = computed(() => pct(store.hud.health))
const armour = computed(() => pct(store.hud.armour))

// `talking` is null while no voice feed is running (`Config.Hud.ShowVoice = false` and no
// voice resource pushing its own state): null means NO TILE, false means an idle one.
const talking = computed(() => (store.hud.talking === null || store.hud.talking === undefined
  ? null
  : !!store.hud.talking))
const muted = computed(() => !!store.hud.muted)

const anchor = computed(() => (ANCHORS.indexOf(store.hud.anchor) === -1 ? 'bottom-left' : store.hud.anchor))
const scale = computed(() => {
  const n = Number(store.hud.scale)
  return isFinite(n) && n > 0 ? Math.min(SCALE_MAX, Math.max(SCALE_MIN, n)) : 1
})

/** Lua tables have no order, so "first by name" is the sorted one: two defs claiming the same
 *  slot always resolve to the same bar instead of flapping between two `stats:set` messages. */
function slotStat (slot) {
  const names = Object.keys(store.stats).sort()
  for (const name of names) {
    const stat = store.stats[name]
    if (stat && stat.slot === slot) return stat
  }
  return null
}

const healthStat = computed(() => slotStat('health'))
const armourStat = computed(() => slotStat('armour'))

/** `null` = the plate has no cut and goes `--solo` (CoreVital's own prop contract). */
const subValue = (stat) => (stat ? percent(stat) : null)

// A tile next to `--solo` plates has to shrink with them. "Solo" is a property of the STRIP:
// the tile only drops to 1.57em when at least one plate is rendered and NONE of the rendered
// plates has a bar under it — a mixed strip keeps the full height so the tops still line up.
const soloStrip = computed(() => {
  const plates = []
  if (health.value !== null) plates.push(healthStat.value)
  if (armour.value !== null) plates.push(armourStat.value)
  return plates.length > 0 && plates.every((stat) => !stat)
})

const place = computed(() => {
  // 24 px of real air under the GLYPHS: CoreVital's box is 3.17em and contains everything it
  // paints, so the offset means what it says (§39.1).
  if (anchor.value === 'bottom-left') return { left: EDGE + 'px', bottom: EDGE + 'px' }
  const r = store.hud.minimap && typeof store.hud.minimap === 'object' ? store.hud.minimap : DEFAULT_MINIMAP
  const x = Number(r.x), y = Number(r.y), w = Number(r.w), h = Number(r.h)
  const rect = [x, y, w, h].every((n) => isFinite(n)) ? { x, y, w, h } : DEFAULT_MINIMAP
  return {
    // The right edge of the minimap plus a little air (0.6em = 14.4 px at the default unit; it
    // is `em` so the gap grows with `Config.Hud.Scale`), and its bottom edge — the strip lines
    // up with the map however the player moved their safe zone. Since the vital's box ends
    // under the sub glyph, that bottom edge is the GLYPHS' baseline, which is what makes the
    // strip and the map read as one band.
    left: 'calc(' + round((rect.x + rect.w) * 100) + 'vw + 0.6em)',
    bottom: 'max(' + EDGE + 'px, ' + round((1 - (rect.y + rect.h)) * 100) + 'vh)',
  }
})

const rootStyle = computed(() => {
  const style = {
    '--core-hud-unit': 'calc(' + UNIT_PX + 'px * ' + scale.value + ')',
    fontSize: 'var(--core-hud-unit)',
  }
  if (soloStrip.value) style['--core-hudtile-h'] = '1.57em'
  return Object.assign(style, place.value)
})
</script>

<template>
  <Transition name="core-slide-up">
    <div
      v-if="store.hud.visible"
      class="hud fixed z-[35] flex items-start gap-[0.19em] pointer-events-none"
      :class="'hud--' + anchor"
      :style="rootStyle"
    >
      <!-- The label has to stay non-empty: CoreHudTile hides the tile from the a11y tree
           without one. It goes through the locale table like the two plate labels do. -->
      <CoreHudTile
        v-if="talking !== null"
        class="hud__tile"
        :icon="muted ? 'hud-mic-off' : 'hud-mic'"
        :active="talking === true && !muted"
        :dimmed="muted"
        :label="muted ? t('hud_voice_muted', 'Microphone muted') : t('hud_voice', 'Microphone')"
      />

      <CoreVital
        v-if="health !== null"
        class="hud__vital is-health"
        tone="health"
        icon="hud-heart"
        :label="t('hud_health', 'Health')"
        :value="health"
        :sub-value="subValue(healthStat)"
        :sub-icon="(healthStat && healthStat.icon) || 'hud-food'"
        :sub-label="healthStat ? healthStat.label : ''"
      />

      <!-- Armour never pulses: an empty vest is the normal state, not a warning (§39.3). -->
      <CoreVital
        v-if="armour !== null"
        class="hud__vital is-armour"
        tone="armour"
        icon="hud-shield"
        :label="t('hud_armour', 'Armor')"
        :value="armour"
        :low-below="0"
        :sub-value="subValue(armourStat)"
        :sub-icon="(armourStat && armourStat.icon) || 'hud-drink'"
        :sub-label="armourStat ? armourStat.label : ''"
      />
    </div>
  </Transition>
</template>
