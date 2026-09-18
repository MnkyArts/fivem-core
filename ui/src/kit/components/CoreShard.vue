<script>
// Module scope: a `defineProps()` validator cannot reference a setup-local binding.
const STYLES = ['wasted', 'success', 'info']

// Each style is only a TONE (§37.4): the band, the two hairlines and the title all read
// `var(--tone)`, so a re-themed server re-colours the shard with everything else.
const STYLE_TONE = { wasted: 'danger', success: 'success', info: 'accent' }
</script>

<script setup>
// CoreShard — the centre-screen banner of the base game ("WASTED", "MISSION PASSED"), DESIGN
// §37.5 Feedback and the skin of the shell's Shard (§21 `shard:show`, §37.6).
//
// It is a BAND, not a screen: full-bleed horizontally, no position of its own, so the caller
// places it (the shell hangs it at `top-[24vh] z-45`) and a gallery can stack three of them.
// Output only and click-through — the game keeps running underneath it (§37.4).
//
// The wire field of `shard:show` is called `style`, but the PROP cannot be: Vue turns a `style`
// entry into a style object wherever props are merged (`mergeProps` normalises it as
// `normalizeStyle([…])`, which parses the string as a CSS declaration list — and a `<Transition>`
// merges, which is exactly how the shell mounts this). So the prop is `variant`, the shell maps
// `store.shard.style` onto it, and the class stays `core-shard--<variant>`.
import { computed } from 'vue'
import { toneClass } from '../use.js'

const props = defineProps({
  /** The big line, display voice, tinted by the variant. */
  title: { type: String, default: '' },
  /** The spaced-out line under it (eyebrow voice); empty leaves the row out. */
  subtitle: { type: String, default: '' },
  /** `wasted` (danger) · `success` · `info` (the accent) — anything else falls back to `info`. */
  variant: { type: String, default: 'info', validator: (v) => STYLES.indexOf(v) !== -1 },
})

const kind = computed(() => (STYLES.indexOf(props.variant) === -1 ? 'info' : props.variant))
const rootClass = computed(() => ['core-shard--' + kind.value, toneClass(STYLE_TONE[kind.value])])
</script>

<template>
  <div class="core-shard" :class="rootClass">
    <div class="core-shard__band">
      <div class="core-shard__title">{{ title }}</div>
      <div v-if="subtitle" class="core-shard__subtitle">{{ subtitle }}</div>
    </div>
  </div>
</template>
