<script setup>
// Root of the core UI shell (DESIGN §7.2).
// Everything is pointer-events: none; only open pages and modals take input.
import Hud from './components/Hud.vue'
import StatsBars from './components/StatsBars.vue'
import Notifications from './components/Notifications.vue'
import TextUI from './components/TextUI.vue'
import Progress from './components/Progress.vue'
import KeyHints from './components/KeyHints.vue'
import Spinner from './components/Spinner.vue'
import Shard from './components/Shard.vue'
import PageHost from './components/PageHost.vue'
import Menu from './components/Menu.vue'
import InputDialog from './components/InputDialog.vue'
import AlertDialog from './components/AlertDialog.vue'
</script>

<template>
  <div class="core-root">
    <!-- top-right rail: HUD, the stat bars under it, then the notification stack -->
    <div class="rail-tr">
      <Hud />
      <StatsBars />
      <Notifications />
    </div>

    <TextUI />
    <Progress />

    <!-- bottom right: instructional buttons with the busy spinner above them (§21) -->
    <KeyHints />
    <Spinner />

    <PageHost />

    <!-- above the HUD, below the modals -->
    <Shard />

    <Menu />
    <InputDialog />
    <AlertDialog />
  </div>
</template>

<style scoped>
.core-root {
  position: fixed;
  inset: 0;
  pointer-events: none;
  color: var(--core-text, #f2f4f8);
  -webkit-font-smoothing: antialiased;
  overflow: hidden;
}

.rail-tr {
  position: absolute;
  top: 16px;
  right: 16px;
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 10px;
  z-index: 40;
  pointer-events: none;
}
</style>
