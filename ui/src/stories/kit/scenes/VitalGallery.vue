<script setup>
// VitalGallery — the vitals HUD of DESIGN §39. Open it with `?bg=game` or `?bg=keyart`: the
// plates are white over the live game and the tile is translucent ink, so neither can be judged
// on a flat background.
//
// The STRIP is the shell's job (§39.4), not the kit's: a flex row with one `--core-hud-unit` and
// a 0.19em gap — the 0.18em cut seen across a 20deg edge. It is plain markup here for the same
// reason StatBarGallery's plate is: the page owns the box, the kit owns the plate.
import { onBeforeUnmount, onMounted, reactive } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

/** @param {string} [unit] a CSS length for --core-hud-unit (1em = 100 px of the mockup).
 *  Omitted = leave the variable alone, so the row and the components both take the kit's own
 *  24 px default — which is what the strip really runs at. */
const strip = (unit) => {
  const style = {
    display: 'flex',
    alignItems: 'flex-start',
    gap: '0.19em',
    fontSize: 'var(--core-hud-unit, 24px)',
  }
  if (unit) style['--core-hud-unit'] = unit
  return style
}

const TONES = [
  ['health', 'hud-heart', 'Health', 82],
  ['armour', 'hud-shield', 'Armor', 64],
  ['stamina', 'bolt', 'Stamina', 47],
  ['oxygen', 'lungs', 'Oxygen', 30],
]

/** The three sizes a server can really run: `Config.Hud.Scale` clamps to 0.5 .. 2 of the 24px
 *  default, so 12px and 48px are the two ends and nothing outside them ever ships. */
const UNITS = [
  ['12px', 'Config.Hud.Scale = 0.5'],
  ['24px', 'the default'],
  ['48px', 'Config.Hud.Scale = 2.0'],
]

// §39.3.1 is motion: a still plate shows nothing of it, so this scene drives one row itself.
// One step every 1.4 s — a hair over the 900 ms the direction class lives — so every step starts
// from rest and each direction is seen alone. Plate and bar move on different steps on purpose:
// the two chunks have their own direction state and never borrow each other's timings.
const DEMO_STEPS = [
  { value: 100, sub: 80 },
  { value: 45, sub: 80 },   // the plate loses 55 — red, shrinking into the fill's edge
  { value: 45, sub: 30 },   // now the bar loses, with the plate at rest
  { value: 90, sub: 30 },   // the plate gains — green shoots ahead, white catches up
  { value: 100, sub: 95 },  // both gain
]
const DEMO_MS = 1400

const demo = reactive({ value: DEMO_STEPS[0].value, sub: DEMO_STEPS[0].sub })
let demoTimer = null
let demoStep = 0

onMounted(() => {
  demoTimer = setInterval(() => {
    demoStep = (demoStep + 1) % DEMO_STEPS.length
    demo.value = DEMO_STEPS[demoStep].value
    demo.sub = DEMO_STEPS[demoStep].sub
  }, DEMO_MS)
})

onBeforeUnmount(() => {
  if (demoTimer) clearInterval(demoTimer)
  demoTimer = null
})
</script>

<template>
  <KitStage
    title="CoreVital"
    :width="1600"
    description="One vital of the HUD strip: Liam's mockup as a single rounded parallelogram whose
      bottom slice is cut off and used as the food / drink bar. The value is never a width — it is a
      0..1 custom property, and the white plate is clipped inside the skewed shape, so the progress
      edge comes out at the parallelogram's own 20deg. The icon and label exist twice, pixel-identical,
      which is what splits the label into two tones along that edge."
  >
    <KitSection
      label="The strip, at mockup size"
      layout="column"
      :gap="8"
      note="unit = 100px, i.e. 1em = 100 px of the mockup. Top: full. Bottom: drained, with the
        food bar under its warning threshold and the drink bar under its danger one."
    >
      <div :style="strip('100px')">
        <CoreHudTile icon="hud-mic" label="Voice" />
        <CoreVital
          label="Health" icon="hud-heart" tone="health" :value="100"
          :sub-value="80" sub-icon="hud-food" sub-label="Hunger"
        />
        <CoreVital
          label="Armor" icon="hud-shield" tone="armour" :value="100"
          :sub-value="78" sub-icon="hud-drink" sub-label="Thirst"
        />
      </div>
      <div :style="strip('100px')">
        <CoreHudTile icon="hud-mic" label="Voice" active dimmed />
        <CoreVital
          label="Health" icon="hud-heart" tone="health" :value="40"
          :sub-value="18" sub-icon="hud-food" sub-label="Hunger"
        />
        <CoreVital
          label="Armor" icon="hud-shield" tone="armour" :value="55"
          :sub-value="7" sub-icon="hud-drink" sub-label="Thirst"
        />
      </div>
    </KitSection>

    <KitSection
      label="The strip, at the size it really runs"
      layout="column"
      :gap="18"
      note="The default unit is 24px — about 351 x 76 px, fixed px like the rest of the shell,
        next to the minimap (§39.4). Config.Hud.Scale multiplies it (0.5 .. 2)."
    >
      <div :style="strip()">
        <CoreHudTile icon="hud-mic" label="Voice" />
        <CoreVital
          label="Health" icon="hud-heart" tone="health" :value="81"
          :sub-value="80" sub-icon="hud-food" sub-label="Hunger"
        />
        <CoreVital
          label="Armor" icon="hud-shield" tone="armour" :value="46"
          :sub-value="62" sub-icon="hud-drink" sub-label="Thirst"
        />
      </div>
      <div :style="strip('48px')">
        <CoreHudTile icon="hud-mic" label="Voice" />
        <CoreVital
          label="Health" icon="hud-heart" tone="health" :value="81"
          :sub-value="80" sub-icon="hud-food" sub-label="Hunger"
        />
        <CoreVital
          label="Armor" icon="hud-shield" tone="armour" :value="46"
          :sub-value="62" sub-icon="hud-drink" sub-label="Thirst"
        />
      </div>
      <p class="text-ui-xs text-fg-faint" style="max-width: 420px">
        Top: the default. Bottom: <code>Config.Hud.Scale = 2.0</code> — the same markup at
        <code>unit = 48px</code>. Nothing is written in px inside the components: the unit IS
        their font size, so one number moves the whole strip.
      </p>
    </KitSection>

    <KitSection
      label="Loss and gain"
      layout="column"
      :gap="18"
      note="§39.3.1 — the plate has two edges that travel to the new value at two speeds, and the
        span between them is a solid chunk that hides the label. Losing: the white fill drops in
        0.3s and the red chunk follows in 0.65s. Gaining: the green chunk shoots ahead in 0.15s and
        the white fill eats it from the left over 0.55s. This row drives itself, one step every
        1.4s."
    >
      <div :style="strip('100px')">
        <CoreVital
          label="Health" icon="hud-heart" tone="health" :value="demo.value"
          :sub-value="demo.sub" sub-icon="hud-food" sub-label="Hunger"
        />
      </div>
      <div :style="strip()">
        <CoreHudTile icon="hud-mic" label="Voice" />
        <CoreVital
          label="Health" icon="hud-heart" tone="health" :value="demo.value"
          :sub-value="demo.sub" sub-icon="hud-food" sub-label="Hunger"
        />
        <CoreVital
          label="Armor" icon="hud-shield" tone="armour" :value="demo.value"
          :sub-value="demo.sub" sub-icon="hud-drink" sub-label="Thirst"
        />
      </div>
      <p class="text-ui-xs text-fg-faint" style="max-width: 520px">
        The chunk is one more layer under the white fill with the same
        <code>clip-path</code> target, so it needs no geometry of its own — it leans at the
        parallelogram's 20° like everything else in the shape. The direction class
        (<code>is-loss</code> / <code>is-gain</code>) lands in the same render as the new value and
        is dropped 900 ms after the last change, which makes the chunk transparent again.
      </p>
    </KitSection>

    <KitSection
      label="Sub bar thresholds"
      :gap="36"
      note="Plate white while healthy, warning under subWarnBelow (25), error under subDangerBelow
        (10) — fill and sub glyph together, and the glyph pulses on danger."
    >
      <div v-for="sub in [62, 20, 5]" :key="sub" :style="strip('56px')">
        <CoreVital
          label="Health" icon="hud-heart" tone="health" :value="78"
          :sub-value="sub" sub-icon="hud-food" sub-label="Hunger"
        />
      </div>
    </KitSection>

    <KitSection
      label="Low, and solo"
      :gap="36"
      note="Under lowBelow the GLYPH pulses and nothing else moves. subValue = null drops the cut,
        the bar and the sub glyph: a --solo plate wears all four outer radii."
    >
      <div :style="strip('56px')">
        <CoreVital
          label="Health" icon="hud-heart" tone="health" :value="12"
          :sub-value="44" sub-icon="hud-food" sub-label="Hunger"
        />
      </div>
      <div :style="strip('56px')">
        <CoreVital label="Health" icon="hud-heart" tone="health" :value="12" :low-below="0" />
      </div>
      <div :style="strip('56px')">
        <CoreHudTile icon="hud-mic-off" label="Voice muted" dimmed style="--core-hudtile-h: 1.57em" />
        <CoreVital label="Armor" icon="hud-shield" tone="armour" :value="70" />
      </div>
    </KitSection>

    <KitSection
      label="Tones"
      :gap="36"
      note="Health and armour own a plate colour (§39.2) for the glyph on the white fill; every
        other meter tone keeps --tone on both sides."
    >
      <div v-for="[tone, icon, label, value] in TONES" :key="tone" :style="strip('48px')">
        <CoreVital
          :label="label" :icon="icon" :tone="tone" :value="value"
          :sub-value="55" sub-icon="hud-drink" sub-label="Thirst"
        />
      </div>
    </KitSection>

    <KitSection label="Unit" layout="column" :gap="10" note="unit takes a number (px) or any CSS length.">
      <div v-for="[unit, caption] in UNITS" :key="unit" style="display: flex; align-items: center; gap: 22px">
        <CoreVital
          label="Health" icon="hud-heart" tone="health" :value="66" :unit="unit"
          :sub-value="41" sub-icon="hud-food" sub-label="Hunger"
        />
        <span class="text-ui-xs text-fg-faint">:unit="{{ unit }}" — {{ caption }}</span>
      </div>
    </KitSection>
  </KitStage>
</template>
