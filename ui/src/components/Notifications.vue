<script setup>
// Notification stack, top-right under the HUD (DESIGN §7.2).
// Entries are pushed/removed by the store; this component only renders them.
import { store } from '../store.js'

const TYPES = ['info', 'success', 'error', 'warning']

function typeOf (t) {
  return TYPES.indexOf(t) === -1 ? 'info' : t
}
</script>

<template>
  <TransitionGroup name="notif" tag="div" class="notifs">
    <div
      v-for="n in store.notifications"
      :key="n.id"
      class="notif"
      :class="'is-' + typeOf(n.type)"
    >
      <span class="bar"></span>
      <div class="body">
        <div v-if="n.title" class="title">{{ n.title }}</div>
        <div class="msg">{{ n.message }}</div>
      </div>
      <span v-if="n.count > 1" class="count">&times;{{ n.count }}</span>
    </div>
  </TransitionGroup>
</template>

<style scoped>
.notifs {
  position: relative;
  width: 300px;
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 8px;
  pointer-events: none;
}

.notif {
  display: flex;
  align-items: stretch;
  gap: 9px;
  padding: 8px 10px 8px 0;
  background: var(--core-panel, rgba(14, 16, 20, 0.86));
  border: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  border-radius: var(--core-radius, 8px);
  overflow: hidden;
  font-size: 13px;
  line-height: 1.35;
}

.bar {
  flex: 0 0 3px;
  width: 3px;
  border-radius: 3px 0 0 3px;
  background: var(--core-accent, #5b8cff);
}

.is-success .bar { background: var(--core-success, #3ddc84); }
.is-error .bar { background: var(--core-error, #ff5d5d); }
.is-warning .bar { background: var(--core-warning, #ffb347); }

.body {
  flex: 1 1 auto;
  min-width: 0;
}

.title {
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  margin-bottom: 2px;
  color: var(--core-accent, #5b8cff);
}

.is-success .title { color: var(--core-success, #3ddc84); }
.is-error .title { color: var(--core-error, #ff5d5d); }
.is-warning .title { color: var(--core-warning, #ffb347); }

.msg {
  color: var(--core-text, #f2f4f8);
  word-wrap: break-word;
  overflow-wrap: anywhere;
}

.count {
  flex: 0 0 auto;
  align-self: center;
  padding: 1px 6px;
  border: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  border-radius: 999px;
  font-size: 11px;
  font-variant-numeric: tabular-nums;
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
}

/* slide in/out from the right */
.notif-enter-active,
.notif-leave-active { transition: opacity 0.18s ease, transform 0.22s cubic-bezier(0.2, 0.8, 0.2, 1); }

.notif-enter-from,
.notif-leave-to { opacity: 0; transform: translateX(120%); }

.notif-leave-active { position: absolute; left: 0; right: 0; }

.notif-move { transition: transform 0.22s cubic-bezier(0.2, 0.8, 0.2, 1); }
</style>
