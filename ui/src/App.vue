<script setup>
// Root of the core UI shell (DESIGN §7.2).
// Everything is pointer-events: none; only open pages and modals take input.
import WorldPrompts from './shell/WorldPrompts.vue'
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
import SkillCheck from './shell/SkillCheck.vue'
import { defineAsyncComponent } from 'vue'
import { store } from './store.js'

// §38.14: the inspector is a lazy chunk. The `import()` is only issued the first time
// `store.dev.inspector` becomes true (`/uiinspect` -> `inspector:toggle`), so a production shell
// never fetches `assets/inspector.js` and pays nothing for a panel nobody opened.
const Inspector = defineAsyncComponent(() => import('./shell/Inspector.vue'))
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
    <!-- world layer: the §6.7 interaction dots (z 20 — under the HUD rail, prompts and hints) -->
    <WorldPrompts />

    <!-- §39.4: the vitals HUD is no longer a rail plate. It is a strip of its own, placed
         against the minimap (or a screen corner) by `hud.anchor` and sized by
         `--core-hud-unit`, so it carries its own `position: fixed` and sits under the rail's
         z 40 — a toast that grows down must never end up behind it. -->
    <Hud />

    <!-- top-right rail: the stat bars that did NOT claim a vital slot, then the notification
         stack (z 40). With the two defs core ships the plate renders nothing. -->
    <div class="rail-tr pointer-events-none absolute top-4 right-4 z-40 flex flex-col items-end gap-2.5">
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
    <SkillCheck />

    <!-- §37.3: Teleport target of every kit popup (select, popover, context menu, dialog, drawer,
         tooltip) — inside .core-root, so §31 hides it with the shell. -->
    <div id="core-overlays" class="core-overlays"></div>

    <!-- §38.14: dev only, above everything, never focusable -->
    <Inspector v-if="store.dev.inspector" />
  </div>
</template>
