<script setup>
// Notification stack, top-right under the HUD (DESIGN §7.2).
// Entries are pushed/removed by the store; this component only renders them.
import { store } from '../store.js'

const TYPES = ['info', 'success', 'error', 'warning']

// Per-type accents as theme utilities; `is-<type>` stays on the card as a hook class.
const BAR = {
  info: 'bg-accent',
  success: 'bg-success',
  error: 'bg-error',
  warning: 'bg-warning',
}
const TITLE = {
  info: 'text-accent',
  success: 'text-success',
  error: 'text-error',
  warning: 'text-warning',
}

function typeOf (t) {
  return TYPES.indexOf(t) === -1 ? 'info' : t
}
</script>

<template>
  <TransitionGroup
    name="notif"
    tag="div"
    class="notifs relative w-[300px] flex flex-col items-stretch gap-[8px] pointer-events-none"
  >
    <div
      v-for="n in store.notifications"
      :key="n.id"
      class="notif flex items-stretch gap-[9px] py-[8px] pr-[10px] pl-0
             bg-panel border border-border rounded-ui overflow-hidden text-[13px] leading-[1.35]"
      :class="'is-' + typeOf(n.type)"
    >
      <span class="bar flex-[0_0_3px] w-[3px] rounded-l-[3px]" :class="BAR[typeOf(n.type)]"></span>
      <div class="body flex-auto min-w-0">
        <div
          v-if="n.title"
          class="title text-[11px] font-bold tracking-[0.05em] uppercase mb-[2px]"
          :class="TITLE[typeOf(n.type)]"
        >{{ n.title }}</div>
        <div class="msg text-fg [overflow-wrap:anywhere]">{{ n.message }}</div>
      </div>
      <span
        v-if="n.count > 1"
        class="count flex-none self-center px-[6px] py-px border border-border rounded-full
               text-[11px] tabular-nums text-fg-dim"
      >&times;{{ n.count }}</span>
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
