<script setup lang="ts">
// One inventory slot. `onUpdated` is how the benchmark counts RE-RENDERS: a deep patch of one slot
// must re-render one child, a whole-snapshot `page:open` re-renders all 200 (§38.10 is the claim,
// ui/tests/bench.mjs is the measurement).
import { onUpdated } from 'vue'
import { counters } from './state.ts'

defineOptions({ name: 'FxAlphaBenchSlot', inheritAttrs: false })

defineProps<{ slot: { id?: number; name?: string; count?: number } }>()

onUpdated(() => { counters.slotRenders++ })
</script>

<template>
  <span class="fx-slot">{{ slot.name }}:{{ slot.count }}</span>
</template>
