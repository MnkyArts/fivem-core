<script setup>
// CorePrompt — the world interaction prompt (DESIGN §37.5, Actions): `[F] (steering) ENTER VEHICLE`
// over the game. A HUD element, so it is click-through until `interactive` turns the mouse back on
// (§37.4) — and only then is the root a real <button> that can be clicked and tabbed to.
// `progress` drives the hold bar on the cap(s), so the caller can animate it per frame.
import { computed } from 'vue'

const props = defineProps({
  /** `'F'`, or `['SHIFT', 'F']` for a combination. */
  keys: { type: [String, Number, Array], default: '' },
  /** The line in display voice. The default slot replaces it. */
  label: { type: String, default: '' },
  /** Registry name or raw path, between cap and label; the `icon` slot wins over it. */
  icon: { type: String, default: '' },
  /** Second line, sans, dim — the cost, the cooldown, why it is blocked. */
  description: { type: String, default: '' },
  /** 0-1 hold-to-confirm, drawn along the bottom of every cap. */
  progress: { type: Number, default: 0 },
  /** Lit: the cap turns coral (the prompt the player is looking at). */
  active: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  /** Takes the mouse and becomes a button. Off by default: a HUD prompt is click-through. */
  interactive: { type: Boolean, default: false },
})

const emit = defineEmits(['click'])

const empty = (v) => v === '' || v === null || v === undefined || (Array.isArray(v) && v.length === 0)

const caps = computed(() => {
  const list = Array.isArray(props.keys) ? props.keys : [props.keys]
  return list.filter((cap) => !empty(cap)).map((cap) => String(cap))
})

function onClick (event) {
  if (!props.interactive || props.disabled) {
    event.preventDefault()
    event.stopPropagation()
    return
  }
  emit('click', event)
}
</script>

<template>
  <component
    :is="interactive ? 'button' : 'div'"
    class="core-prompt"
    :class="{ 'is-active': active, 'is-disabled': disabled, 'is-interactive': interactive }"
    :type="interactive ? 'button' : null"
    :disabled="interactive && disabled ? true : null"
    :aria-disabled="disabled ? 'true' : null"
    @click="onClick"
  >
    <span v-if="caps.length" class="core-prompt__keys">
      <CoreKey
        v-for="(cap, i) in caps"
        :key="cap + '|' + i"
        :label="cap"
        size="lg"
        :progress="progress"
      />
    </span>
    <span class="core-prompt__band">
      <span v-if="icon || $slots.icon" class="core-prompt__icon">
        <slot name="icon"><CoreIcon :name="icon" :size="20" /></slot>
      </span>
      <span class="core-prompt__text">
        <span class="core-prompt__label"><slot>{{ label }}</slot></span>
        <span v-if="description" class="core-prompt__desc">{{ description }}</span>
      </span>
    </span>
  </component>
</template>
