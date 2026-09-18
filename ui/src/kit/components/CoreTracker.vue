<script setup>
// CoreTracker — the HUD quest card of mockup 2 (DESIGN §37.5, Game).
// Click-through (§37.4): it is painted over the world and never takes the mouse, so nothing in
// here is focusable. The left rail is the motif of the mockup — the tone pin with a hairline
// running down out of it and fading away beside the copy — and `bloom` is the other one: the plate
// lets the world through in two soft spots on its left instead of being a flat fill (mask in game.css).
import { computed } from 'vue'
import { oneOf, toneClass, METER_TONES } from '../use.js'

const props = defineProps({
  title: { type: String, default: '' },
  /** One line of "what to do now". */
  text: { type: String, default: '' },
  /** Distance row under the text, with its own pin (`'842 m'`). */
  distance: { type: [String, Number], default: '' },
  /** The rail glyph. */
  icon: { type: String, default: 'map-marker' },
  /** Colour of the rail glyph — amber in the mockup. */
  tone: { type: String, default: 'warning', validator: oneOf(METER_TONES) },
  /** `[{ text, state?, trailing?, optional? }]`, rendered as CoreObjectives under the text. */
  objectives: { type: Array, default: () => [] },
  /** The mockup's plate: the world bleeds through two soft spots on the left instead of the fill
   *  being flat. false is the plain --color-hud plate. */
  bloom: { type: Boolean, default: true },
})

const rootClass = computed(() => ['core-tracker', toneClass(props.tone), { 'has-bloom': props.bloom }])
const list = computed(() => (Array.isArray(props.objectives) ? props.objectives : []))
</script>

<template>
  <div :class="rootClass">
    <span class="core-tracker__rail">
      <CoreIcon class="core-tracker__pin" :name="icon" :size="22" />
    </span>

    <div class="core-tracker__body">
      <p v-if="title" class="core-tracker__title">{{ title }}</p>
      <p v-if="text" class="core-tracker__text">{{ text }}</p>

      <p v-if="distance !== ''" class="core-tracker__distance">
        <CoreIcon name="map-marker" :size="16" />
        <span>{{ distance }}</span>
      </p>

      <div v-if="list.length" class="core-tracker__objectives">
        <CoreObjective
          v-for="(objective, i) in list"
          :key="objective.id !== undefined ? objective.id : i"
          v-bind="objective"
        />
      </div>

      <slot />
    </div>
  </div>
</template>
