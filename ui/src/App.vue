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
  <div class="core-root pointer-events-none fixed inset-0 overflow-hidden text-fg antialiased">
    <!-- top-right rail: HUD, the stat bars under it, then the notification stack (z 40) -->
    <div class="rail-tr pointer-events-none absolute top-4 right-4 z-40 flex flex-col items-end gap-2.5">
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
