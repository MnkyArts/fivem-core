<script setup>
// CompassGallery — CoreCompass (DESIGN §37.5, Game).
// Shoot this one with ?bg=keyart: the band is a translucent strip over the world that fades out
// at both ends, so a flat background hides exactly the thing that has to be judged.
// The plain <input type="range"> is deliberate — the gallery may not lean on another group.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const heading = ref(0)

const markers = [
  { heading: 42, icon: 'quest', tone: 'accent', label: 'Tower' },
  { heading: 300, icon: 'store', tone: 'info' },
]

const many = [
  { heading: 15, icon: 'map-marker', tone: 'warning' },
  { heading: 95, icon: 'car', tone: 'neutral' },
  { heading: 180, icon: 'users', tone: 'success' },
  { heading: 265, icon: 'skull', tone: 'danger' },
]
</script>

<template>
  <KitStage
    title="Compass"
    description="The heading band of mockup 2: one strip of ticks and cardinals, 30 px high, fading out at
      both ends, with a coral triangle over the centre. The default 270 degree field of view is the mockup's —
      it is what puts W, N and E on the band at once. It is built once and moved with a single translateX, so
      turning the camera costs one composited transform and nothing else."
    :width="1000"
  >
    <KitSection label="Mockup 2 — 560 px, 270 degrees" layout="column" :gap="22">
      <CoreCompass :heading="heading" />
      <div class="flex items-center" style="gap: 16px; width: 560px">
        <span class="core-label" style="display: inline">heading</span>
        <input
          v-model.number="heading"
          type="range"
          min="0"
          max="359"
          step="1"
          style="flex: 1"
          aria-label="Heading"
        />
        <span class="core-num text-fg" style="width: 52px; text-align: right; font-size: 17px">{{ heading }}&deg;</span>
      </div>
      <p class="text-fg-dim text-ui-sm" style="max-width: 62ch">
        Drag it past 0 and past 359: the strip covers &minus;180 to 540 degrees and every marker is placed
        three times, a turn apart, so nothing pops when the heading wraps.
      </p>
    </KitSection>

    <KitSection label="Labels" layout="column" :gap="34" note="'cardinal' drops the intercardinals and keeps the ticks — the band of mockup 2 at 560 px">
      <CoreCompass :heading="heading" labels="cardinal" />
      <CoreCompass :heading="heading" labels="cardinal" :markers="markers" show-bearing />
    </KitSection>

    <KitSection label="Markers" layout="column" :gap="34" note="{ heading, icon?, tone?, label? } — placed on the strip, so they slide with it">
      <CoreCompass :heading="heading" :markers="markers" show-bearing />
      <CoreCompass :heading="heading" :markers="many" />
    </KitSection>

    <KitSection label="Width and field of view" layout="column" :gap="34" note="pixels per degree = width / fov — a narrow fov zooms the band in">
      <CoreCompass :heading="heading" :width="760" :fov="360" :markers="markers" />
      <CoreCompass :heading="heading" :width="420" :fov="180" :markers="markers" show-bearing />
      <CoreCompass :heading="heading" :width="300" :fov="90" />
    </KitSection>

    <KitSection label="Fixed headings" layout="column" :gap="34" note="north, north-east, due south — the cardinals are bright, the intercardinals small and dim">
      <CoreCompass :heading="0" :width="480" show-bearing />
      <CoreCompass :heading="45" :width="480" show-bearing />
      <CoreCompass :heading="187" :width="480" :markers="markers" show-bearing />
    </KitSection>
  </KitStage>
</template>
