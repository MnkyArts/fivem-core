<script>
// Module scope: a `defineProps()` validator cannot reference a setup-local binding.
const STATUSES = ['online', 'away', 'busy', 'offline']
</script>

<script setup>
// CorePlayerChip — avatar · name · level · XP · presence (DESIGN §37.5; mockup 1, top right).
// It draws its own 4 px XP rail instead of embedding CoreProgress: the rail has to share a flex row
// with the level and must not inherit a meter's label/value chrome. `progress` is 0–1 (a fraction of
// the current level), not 0–100. HUD element, so the root is click-through (§37.4).
import { computed } from 'vue'
import { clamp } from '../use.js'

const props = defineProps({
  /** Player name — display voice, uppercase, ellipsised. */
  name: { type: String, default: '' },
  /** Portrait url. Without one the chip shows the initials of `name`. */
  avatar: { type: String, default: '' },
  /** Level number (or any short string). */
  level: { type: [String, Number], default: '' },
  /** The caption before the level. */
  levelLabel: { type: String, default: 'Lv.' },
  /** Progress through the level, 0–1. */
  progress: { type: Number, default: 0 },
  /** Presence dot at the end of the name row. */
  status: { type: String, default: '', validator: (v) => v === '' || STATUSES.indexOf(v) !== -1 },
  /** Optional third line under the XP rail (faction, job, phone number). */
  subtitle: { type: String, default: '' },
})

const initials = computed(() => String(props.name || '')
  .trim()
  .split(/\s+/)
  .filter(Boolean)
  .slice(0, 2)
  .map((word) => word.charAt(0))
  .join(''))

const fillStyle = computed(() => ({ width: (clamp(props.progress, 0, 1) * 100).toFixed(2) + '%' }))
const levelText = computed(() => [props.levelLabel, props.level].filter((p) => p !== '' && p !== null && p !== undefined).join(' '))
</script>

<template>
  <div class="core-playerchip">
    <div class="core-playerchip__avatar">
      <slot name="avatar">
        <img v-if="avatar" :src="avatar" :alt="name || ''">
        <span v-else aria-hidden="true">{{ initials }}</span>
      </slot>
    </div>

    <div class="core-playerchip__body">
      <div class="core-playerchip__top">
        <span class="core-playerchip__name">{{ name }}</span>
        <span v-if="status" class="core-playerchip__status" :class="'is-' + status" :title="status"></span>
      </div>

      <!-- `meta` replaces the level + XP row; a wanted level or a faction rank goes here. -->
      <div class="core-playerchip__meta">
        <slot name="meta">
          <span v-if="levelText" class="core-playerchip__level">{{ levelText }}</span>
          <span class="core-playerchip__xp">
            <span class="core-playerchip__xpfill" :style="fillStyle"></span>
          </span>
        </slot>
      </div>

      <div v-if="subtitle" class="core-playerchip__subtitle">{{ subtitle }}</div>
    </div>
  </div>
</template>
