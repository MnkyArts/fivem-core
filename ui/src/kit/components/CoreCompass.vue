<script>
// CoreCompass — the heading band of mockup 2 (DESIGN §37.5, Game).
// ONE strip covering -180 to 540 degrees is built once (ticks every 15, labels every 45, every
// marker repeated a turn either side so a wrap-around never pops) and a single translateX slides
// it, so a heading update is one composited move: the two v-memo wrappers below keep Vue from
// re-rendering 66 static nodes per frame, which is the whole point on a HUD (§37.4 performance).
// `labels: 'cardinal'` keeps only N/E/S/W (the ticks stay) — what mockup 2 draws at 560 px.
const NAMES = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW']
const FROM = -180
const TO = 540
</script>

<script setup>
import { computed } from 'vue'
import { oneOf, toneClass } from '../use.js'

const props = defineProps({
  /** Where the player is looking, 0-360 (0 = north). Anything else is wrapped into range. */
  heading: { type: Number, default: 0 },
  /** Band width in px. */
  width: { type: Number, default: 560 },
  /** How many degrees the band shows end to end. 270 is the field of view of mockup 2, which
   *  puts W, N and E on the band at once. */
  fov: { type: Number, default: 270 },
  /** `[{ heading, icon?, tone?, label? }]` — waypoints, blips, teammates. */
  markers: { type: Array, default: () => [] },
  /** `'all'` labels every 45 degrees; `'cardinal'` only N/E/S/W, the ticks unchanged. */
  labels: { type: String, default: 'all', validator: oneOf(['all', 'cardinal']) },
  /** Prints the numeric bearing (`042`) under the band. */
  showBearing: { type: Boolean, default: false },
})

const ppd = computed(() => props.width / Math.max(1, props.fov))
const x = (deg) => (deg - FROM) * ppd.value

const stripStyle = computed(() => {
  const h = ((Number(props.heading) || 0) % 360 + 360) % 360
  return {
    width: (TO - FROM) * ppd.value + 'px',
    transform: 'translateX(' + (props.width / 2 - x(h)) + 'px)',
  }
})

const ticks = computed(() => {
  const out = []
  for (let deg = FROM; deg <= TO; deg += 15) {
    out.push({ deg, major: deg % 45 === 0, style: { left: x(deg) + 'px' } })
  }
  return out
})

const names = computed(() => {
  const cardinalOnly = props.labels === 'cardinal'
  const out = []
  for (let deg = FROM; deg <= TO; deg += 45) {
    const i = ((deg % 360) + 360) % 360 / 45
    const cardinal = i % 2 === 0
    if (cardinalOnly && !cardinal) continue
    out.push({ deg, name: NAMES[i], cardinal, style: { left: x(deg) + 'px' } })
  }
  return out
})

// Three copies of every marker (-360 / 0 / +360) cover the whole strip, so a waypoint behind the
// player slides in from the correct side instead of jumping when the heading crosses north.
const placed = computed(() => {
  const list = Array.isArray(props.markers) ? props.markers : []
  const out = []
  for (let i = 0; i < list.length; i += 1) {
    const marker = list[i] || {}
    const base = ((Number(marker.heading) || 0) % 360 + 360) % 360
    for (let turn = -1; turn <= 1; turn += 1) {
      const deg = base + turn * 360
      if (deg < FROM || deg > TO) continue
      out.push({
        key: i + ':' + turn,
        icon: marker.icon || 'map-marker',
        label: marker.label || '',
        tone: toneClass(marker.tone || 'accent'),
        style: { left: x(deg) + 'px' },
      })
    }
  }
  return out
})

const bearing = computed(() => {
  const h = Math.round(((Number(props.heading) || 0) % 360 + 360) % 360) % 360
  return String(h).padStart(3, '0')
})
</script>

<template>
  <div class="core-compass" :style="{ width: width + 'px' }" role="img" :aria-label="'Heading ' + bearing">
    <div class="core-compass__band">
      <div class="core-compass__strip" :style="stripStyle">
        <div class="core-compass__marks" v-memo="[width, fov, labels]">
          <span
            v-for="tick in ticks"
            :key="'t' + tick.deg"
            class="core-compass__tick"
            :class="{ 'is-major': tick.major }"
            :style="tick.style"
          ></span>
          <span
            v-for="label in names"
            :key="'l' + label.deg"
            class="core-compass__label"
            :class="{ 'is-inter': !label.cardinal }"
            :style="label.style"
          >{{ label.name }}</span>
        </div>

        <div class="core-compass__markers" v-memo="[placed]">
          <span v-for="marker in placed" :key="marker.key" class="core-compass__marker" :class="marker.tone" :style="marker.style">
            <CoreIcon :name="marker.icon" :size="14" />
            <span v-if="marker.label" class="core-compass__marker-label">{{ marker.label }}</span>
          </span>
        </div>
      </div>
    </div>

    <span class="core-compass__needle"></span>
    <span v-if="showBearing" class="core-compass__bearing">{{ bearing }}</span>
  </div>
</template>
