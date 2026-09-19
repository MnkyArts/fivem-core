<script setup>
// HudTileGallery — the voice tile of the vitals strip (DESIGN §39). Open it with `?bg=game`: the
// tile is translucent ink with a hairline, so it only tells the truth over the game.
//
// The strip around it belongs to the shell (§39.4): a flex row, one `--core-hud-unit`, a 0.19em
// gap — the 0.18em cut seen across a 20deg edge.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

/** @param {string} unit a CSS length for --core-hud-unit (1em = 100 px of the mockup) */
const strip = (unit) => ({
  '--core-hud-unit': unit,
  display: 'flex',
  alignItems: 'flex-start',
  gap: '0.19em',
  fontSize: 'var(--core-hud-unit)',
})

const STATES = [
  [{}, 'idle — connected, not transmitting'],
  [{ active: true }, ':active — you are transmitting'],
  [{ dimmed: true }, ':dimmed — glyph at 40 %'],
  [{ icon: 'hud-mic-off', dimmed: true }, 'icon="hud-mic-off" :dimmed — muted'],
]

/** The three sizes a server can really run: `Config.Hud.Scale` clamps to 0.5 .. 2 of the 24px
 *  default, so 12px and 48px are the two ends and nothing outside them ever ships. */
const UNITS = [
  ['12px', 'Config.Hud.Scale = 0.5'],
  ['24px', 'the default'],
  ['48px', 'Config.Hud.Scale = 2.0'],
]
</script>

<template>
  <KitStage
    title="CoreHudTile"
    :width="1600"
    description="The slanted dark tile that opens the vitals strip: core's voice read-out. It shares
      CoreVital's unit system and its 20deg lean, but only the SHAPE is skewed — the glyph is a sibling,
      centred and upright, because a sheared mic reads as a broken one. Height follows
      --core-hudtile-h, so the same tile fits next to a full vital (2.05em) and next to a --solo one
      (1.57em) with no prop for it. Click-through, like every HUD read-out."
  >
    <KitSection
      label="In the strip, at mockup size"
      layout="column"
      :gap="8"
      note="unit = 100px. The tile is 2.25 x 2.05 em — exactly as tall as the vital next to it."
    >
      <div :style="strip('100px')">
        <CoreHudTile icon="hud-mic" label="Voice" active />
        <CoreVital
          label="Health" icon="hud-heart" tone="health" :value="100"
          :sub-value="80" sub-icon="hud-food" sub-label="Hunger"
        />
        <CoreVital
          label="Armor" icon="hud-shield" tone="armour" :value="100"
          :sub-value="78" sub-icon="hud-drink" sub-label="Thirst"
        />
      </div>
    </KitSection>

    <KitSection
      label="States"
      :gap="40"
      note="active = a max(2px, 0.04em) fg ring and a soft white glow. dimmed = the glyph at 40 %.
        The muted twin is the same glyph knocked out by a slash (hud-mic-off)."
    >
      <div v-for="[props, caption] in STATES" :key="caption" style="display: flex; flex-direction: column; align-items: center; gap: 14px">
        <div :style="strip('90px')">
          <CoreHudTile v-bind="props" label="Voice" />
        </div>
        <span class="text-ui-xs text-fg-faint" style="max-width: 190px; text-align: center">{{ caption }}</span>
      </div>
    </KitSection>

    <KitSection
      label="Height"
      :gap="40"
      note="--core-hudtile-h, not a prop: the caller decides what the tile stands next to."
    >
      <div :style="strip('60px')">
        <CoreHudTile icon="hud-mic" label="Voice" />
        <CoreVital
          label="Health" icon="hud-heart" tone="health" :value="74"
          :sub-value="52" sub-icon="hud-food" sub-label="Hunger"
        />
      </div>
      <div :style="strip('60px')">
        <CoreHudTile icon="hud-mic" label="Voice" style="--core-hudtile-h: 1.57em" />
        <CoreVital label="Armor" icon="hud-shield" tone="armour" :value="74" />
      </div>
      <p class="text-ui-xs text-fg-faint" style="max-width: 240px">
        Left: the default 2.05em next to a full vital. Right: 1.57em next to a --solo one.
      </p>
    </KitSection>

    <KitSection label="Unit" layout="column" :gap="12" note="unit takes a number (px) or any CSS length.">
      <div v-for="[unit, caption] in UNITS" :key="unit" style="display: flex; align-items: center; gap: 22px">
        <CoreHudTile icon="hud-mic" label="Voice" :unit="unit" active />
        <CoreHudTile icon="hud-mic-off" label="Voice muted" :unit="unit" dimmed />
        <span class="text-ui-xs text-fg-faint">:unit="{{ unit }}" — {{ caption }}</span>
      </div>
    </KitSection>
  </KitStage>
</template>
