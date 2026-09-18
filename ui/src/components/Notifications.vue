<script setup>
// Notification stack, top-right under the HUD (DESIGN §7.2).
// Entries are pushed/removed by the store; this component only renders them.
//
// Skin: CoreToast cards (DESIGN §37.6) — tone bar, tone glyph, display-voice kicker and the
// `count` pill. `is-<type>` stays on the card as the hook class the stories read.
import { store } from '../store.js'
import CoreIcon from '../kit/components/CoreIcon.vue'

const TYPES = ['info', 'success', 'error', 'warning']

// notify's four types -> the kit's six tones (§37.4) and the tone glyph of CoreToast.
const TONE = {
  info: 'core-tone-info',
  success: 'core-tone-success',
  error: 'core-tone-danger',
  warning: 'core-tone-warning',
}
const ICON = { info: 'info', success: 'success', error: 'error', warning: 'warning' }

function typeOf (t) {
  return TYPES.indexOf(t) === -1 ? 'info' : t
}
</script>

<template>
  <TransitionGroup
    name="notif"
    tag="div"
    class="notifs relative w-[340px] flex flex-col items-stretch gap-[8px] pointer-events-none"
  >
    <div
      v-for="n in store.notifications"
      :key="n.id"
      class="notif core-toast"
      :class="['is-' + typeOf(n.type), TONE[typeOf(n.type)]]"
      role="status"
      aria-live="polite"
      data-core-blur
    >
      <span class="bar core-toast__bar" aria-hidden="true"></span>
      <div class="core-toast__main">
        <CoreIcon class="core-toast__icon" :name="ICON[typeOf(n.type)]" size="md" />
        <div class="body core-toast__body">
          <div v-if="n.title" class="title core-toast__title">{{ n.title }}</div>
          <div class="msg core-toast__message">{{ n.message }}</div>
        </div>
        <span v-if="n.count > 1" class="count core-toast__count">&times;{{ n.count }}</span>
      </div>
    </div>
  </TransitionGroup>
</template>

<style scoped>
/* Vue transition classes — slide in/out from the right; not expressible as utilities. */
.notif-enter-active,
.notif-leave-active { transition: opacity 0.18s ease, transform 0.22s cubic-bezier(0.2, 0.8, 0.2, 1); }

.notif-enter-from,
.notif-leave-to { opacity: 0; transform: translateX(120%); }

.notif-leave-active { position: absolute; left: 0; right: 0; }

.notif-move { transition: transform 0.22s cubic-bezier(0.2, 0.8, 0.2, 1); }
</style>
