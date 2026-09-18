<script setup>
// Centre-screen shard banner (DESIGN §21 `shard:show`) — GTA's "WASTED" / "MISSION
// PASSED" card. Output only: store.js owns the auto-hide timer (`duration`, 4 s by
// default) and nothing is ever posted back to Lua.
//
// State -> render, nothing else (§37.6): the band, the tinted hairlines, the display-voice
// title and the eyebrow subtitle all live in <CoreShard> now, and so does the enter/leave
// motion (`core-shard-*`, feedback.css). This file only places the band and keys it.
//
// `store.shard.seq` keys the element, so a second shard arriving while the first is still
// up replays the animation instead of silently swapping the text.
import { computed } from 'vue'
import { store } from '../store.js'
import CoreShard from '../kit/components/CoreShard.vue'

const STYLES = ['wasted', 'success', 'info']

const style = computed(() => (STYLES.indexOf(store.shard.style) === -1 ? 'info' : store.shard.style))
</script>

<template>
  <Transition name="core-shard" mode="out-in">
    <!-- The wire field is `style`, the kit prop is `variant` — a prop called `style` would be
         parsed as CSS the moment anything merges props, and a <Transition> merges. `is-<style>`
         rides along as the hook class the stories assert on. -->
    <CoreShard
      v-if="store.shard.visible"
      :key="store.shard.seq"
      class="shard fixed inset-x-0 top-[24vh] z-45"
      :class="'is-' + style"
      :variant="style"
      :title="store.shard.title"
      :subtitle="store.shard.subtitle"
    />
  </Transition>
</template>
