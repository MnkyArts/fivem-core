<script setup>
// Notification stack, top-right under the HUD (DESIGN §7.2).
// Entries are pushed/removed by the store; this component only renders them.
//
// State -> render (§37.6): every card is a <CoreToast> (tone bar, tone glyph, display-voice
// kicker, the `count` pill and the §32 glass), so the only thing left here is the stack — the
// TransitionGroup and its layout. `is-<type>` stays on the card as the hook class.
import { store } from '../store.js'
import CoreToast from '../kit/components/CoreToast.vue'

const TYPES = ['info', 'success', 'error', 'warning']

// notify's four types -> the kit's six tones (§37.4); CoreToast picks the glyph from the tone.
const TONE = { info: 'info', success: 'success', error: 'danger', warning: 'warning' }

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
    <CoreToast
      v-for="n in store.notifications"
      :key="n.id"
      class="notif"
      :class="'is-' + typeOf(n.type)"
      :tone="TONE[typeOf(n.type)]"
      :title="n.title"
      :message="n.message"
      :count="n.count"
      blur
    />
  </TransitionGroup>
</template>

<style scoped>
/* Vue transition classes — slide in/out from the right. The kit's `core-slide-left` set is the
   same motion, but a stack also needs the leave to leave the flow (`position: absolute`) and a
   `-move` transition, or the cards below jump when one is dismissed. */
.notif-enter-active,
.notif-leave-active { transition: opacity 0.18s ease, transform 0.22s cubic-bezier(0.2, 0.8, 0.2, 1); }

.notif-enter-from,
.notif-leave-to { opacity: 0; transform: translateX(120%); }

.notif-leave-active { position: absolute; left: 0; right: 0; }

.notif-move { transition: transform 0.22s cubic-bezier(0.2, 0.8, 0.2, 1); }
</style>
