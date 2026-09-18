<script setup>
// CoreEmpty — what a list says when it holds nothing (DESIGN §37.5, Data — display).
// Centred column: a framed glyph, a display-voice line, one sentence and whatever the caller puts in
// the default slot (the actions — a CoreButton, a key hint). The actions row takes the mouse back,
// because an empty state often sits inside a click-through HUD panel.
defineProps({
  /** Registry name or raw path data for the framed glyph. */
  icon: { type: String, default: '' },
  /** Display voice, uppercase — "NO ITEMS". */
  title: { type: String, default: '' },
  /** One sentence of explanation under the title. */
  text: { type: String, default: '' },
})
</script>

<template>
  <div class="core-empty">
    <span v-if="icon" class="core-empty__icon">
      <CoreIcon :name="icon" :size="28" />
    </span>
    <p v-if="title" class="core-empty__title">{{ title }}</p>
    <p v-if="text" class="core-empty__text">{{ text }}</p>
    <div v-if="$slots.default" class="core-empty__actions"><slot /></div>
  </div>
</template>
