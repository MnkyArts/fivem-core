<script setup lang="ts">
// Fixture page: one token utility on the tag, one bundled asset, one scoped block that reaches the
// tokens through @core/ui/reference.css, one Vue import (the shim must carry it) and one kit tag
// (which resolves against core's app at render time — no import, no CSS of our own).
import { computed, ref } from 'vue'
import { usePage } from '@core/ui'
import logo from './logo.png'

const page = usePage<{ label: string; items?: { id: string; count: number }[] }>()
const count = ref(3)
const doubled = computed(() => count.value * 2)
</script>

<template>
  <div class="alpha-panel bg-panel rounded-ui px-8 py-2 font-display text-fg-dim shadow-ui">
    <img class="alpha-logo block" :src="logo" alt="">
    <span class="alpha-count">{{ page.props.label }} {{ count }} {{ doubled }}</span>
    <b class="alpha-marker">ALPHA-TEXT-1</b>
    <i class="alpha-items">{{ (page.props.items || []).map((i) => i.id + ':' + i.count).join(',') }}</i>
    <CoreButton @click="count++">bump</CoreButton>
  </div>
</template>

<style scoped>
@reference "@core/ui/reference.css";

.alpha-panel {
  @apply bg-panel rounded-ui text-fg-dim;
  letter-spacing: 3px;
}
.alpha-logo {
  background-image: url(./logo.png);
}
</style>
