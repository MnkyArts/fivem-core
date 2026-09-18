<script setup lang="ts">
// The inventory-shaped benchmark page: 200 slots, one child component each. Registered twice —
// `fx_alpha_bench` (deep-reactive props) and `fx_alpha_bench_shallow` (`reactivity: 'shallow'`) —
// so bench.mjs can measure the same payload through both patch modes.
import { usePage } from '@core/ui'
import BenchSlot from './BenchSlot.vue'

defineOptions({ name: 'FxAlphaBench', inheritAttrs: false })

const page = usePage<{ slots?: Array<{ id: number; name: string; count: number }>; weight?: number }>()
</script>

<template>
  <div class="fx-alpha-bench text-fg-dim fixed inset-0 overflow-hidden p-2">
    <span class="fx-alpha-bench-weight">{{ page.props.weight }}</span>
    <BenchSlot v-for="s in page.props.slots || []" :key="s.id" :slot="s" />
  </div>
</template>
