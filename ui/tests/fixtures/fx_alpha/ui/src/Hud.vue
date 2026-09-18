<script setup lang="ts">
// fx_alpha's overlay: the layer that never takes the cursor. It reads the plugin's FEED channel,
// so mounting it is what makes Lua's `ui_feed { active = true }` fire, and unmounting it is what
// makes the last-unsubscribe message fire (§38.10).
import { useFeed, useHud } from '@core/ui'

defineOptions({ name: 'FxAlphaHud', inheritAttrs: false })

const feed = useFeed<{ speed?: number; rpm?: number }>()
const hud = useHud()
</script>

<template>
  <div class="fx-alpha-hud text-fg-dim fixed top-0 right-0 p-2">
    <span class="fx-alpha-speed">{{ feed.speed ?? '-' }}</span>
    <span class="fx-alpha-cash">{{ hud.cash }}</span>
  </div>
</template>
