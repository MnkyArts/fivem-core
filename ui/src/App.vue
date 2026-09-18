<script setup>
// Root of the core UI shell (DESIGN §7.2).
// Everything is pointer-events: none; only open pages and modals take input.
import Hud from './shell/Hud.vue'
import StatsBars from './shell/StatsBars.vue'
import Notifications from './shell/Notifications.vue'
import TextUI from './shell/TextUI.vue'
import Progress from './shell/Progress.vue'
import KeyHints from './shell/KeyHints.vue'
import Spinner from './shell/Spinner.vue'
import Shard from './shell/Shard.vue'
import Chat from './shell/Chat.vue'
import PageHost from './shell/PageHost.vue'
import Menu from './shell/Menu.vue'
import InputDialog from './shell/InputDialog.vue'
import AlertDialog from './shell/AlertDialog.vue'
import { store } from './store.js'
</script>

<template>
  <!-- §31: the client hides the whole shell behind the pause menu, a screen fade or a
       cutscene. `is-hidden` only stops the paint (styles.css) — nothing unmounts, so every
       timer, the progress bar and the HUD keep running underneath. -->
  <div
    class="core-root pointer-events-none fixed inset-0 overflow-hidden text-fg antialiased"
    :class="{ 'is-hidden': !store.shell.visible }"
    :aria-hidden="store.shell.visible ? null : 'true'"
  >
    <!-- top-right rail: HUD, the stat bars under it, then the notification stack (z 40) -->
    <div class="rail-tr pointer-events-none absolute top-4 right-4 z-40 flex flex-col items-end gap-2.5">
      <Hud />
      <StatsBars />
      <Notifications />
    </div>

    <TextUI />
    <Progress />

    <!-- top left: the CEF chat feed and input (DESIGN §30.3) -->
    <Chat />

    <!-- bottom right: instructional buttons with the busy spinner above them (§21) -->
    <KeyHints />
    <Spinner />

    <PageHost />

    <!-- above the HUD, below the modals -->
    <Shard />

    <Menu />
    <InputDialog />
    <AlertDialog />

    <!-- §37.3: Teleport target of every kit popup (select, popover, context menu, dialog, drawer,
         tooltip) — inside .core-root, so §31 hides it with the shell. -->
    <div id="core-overlays" class="core-overlays"></div>
  </div>
</template>
