<script setup>
// CorePanel — the bordered dark panel every screen is built from (DESIGN §37.5, Surfaces).
// The heading is delegated to CoreHeading so a panel title and a standalone one are the same
// object; `header` replaces it entirely. Padding lives on the PARTS, never on the root, so a bare
// `<div class="core-panel">` works and a full-bleed grid can sit in a `padding="none"` body.
// `blur` is only the `data-core-blur` attribute: gameblur.js inserts the `.core-glass` wrapper
// that paints the tint over the blurred copy of the game (§32), so the root does nothing for it.
// `variant="hud"` is the flat 4 px plate for a surface that lives ON the game — no sheen, brighter
// hairline — and it never takes `blur`: the HUD is up all the time (§32.1 glass budget).
import { computed, useSlots } from 'vue'
import { oneOf, blurAttr } from '../use.js'

const props = defineProps({
  /**
   * `default` translucent slate · `solid` opaque · `flat` white 2 %, no shadow · `ghost` padding
   * only · `hud` the HUD plate: `--color-hud` fill, 4 px radius, small shadow, no sheen and the
   * brighter hairline, for a surface that lives on the game rather than over a scrim.
   */
  variant: { type: String, default: 'default', validator: oneOf(['default', 'solid', 'flat', 'ghost', 'hud']) },
  /** Padding of header, body and footer: 0 / 12 / 20 / 28 px. */
  padding: { type: String, default: 'md', validator: oneOf(['none', 'sm', 'md', 'lg']) },
  /** Heading title. Any of title/subtitle/eyebrow (or a header/actions slot) renders the header. */
  title: { type: String, default: '' },
  /** Eyebrow voice, under the title. */
  subtitle: { type: String, default: '' },
  /** Label voice, above the title. */
  eyebrow: { type: String, default: '' },
  /** The `//` marker + italic title. */
  slash: { type: Boolean, default: false },
  /** CoreHeading size: `sm` 18 | `md` 24 | `lg` 34 | `xl` 48. */
  headingSize: { type: String, default: 'md' },
  /** A 2 px coral line fading out along the top edge. */
  accent: { type: Boolean, default: false },
  /** The body scrolls instead of growing (the kit's thin scrollbar). */
  scroll: { type: Boolean, default: false },
  /** Glass: `true` for the default strength, a number for that blur radius in px (§32). */
  blur: { type: [Boolean, Number, String], default: false },
  /** The element to render — `section`, `article`, `aside`, … */
  tag: { type: String, default: 'section' },
})

const slots = useSlots()

const hasHeader = computed(() => Boolean(
  props.title || props.subtitle || props.eyebrow || slots.header || slots.actions,
))

const rootClass = computed(() => [
  'core-panel',
  'core-panel--' + props.variant,
  'core-panel--pad-' + props.padding,
  { 'has-accent': props.accent },
])
</script>

<template>
  <component :is="tag" :class="rootClass" v-bind="blurAttr(blur)">
    <div v-if="hasHeader" class="core-panel__header">
      <slot name="header">
        <CoreHeading
          class="core-panel__heading"
          :title="title"
          :subtitle="subtitle"
          :eyebrow="eyebrow"
          :slash="slash"
          :size="headingSize"
          tag="h2"
        />
      </slot>
      <div v-if="$slots.actions" class="core-panel__actions">
        <slot name="actions" />
      </div>
    </div>

    <div class="core-panel__body" :class="{ 'core-scroll': scroll }">
      <slot />
    </div>

    <div v-if="$slots.footer" class="core-panel__footer">
      <slot name="footer" />
    </div>
  </component>
</template>
