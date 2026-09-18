<script setup lang="ts">
// fx_beta's page. Its utility (`px-10` = 40 px) is its OWN — fx_alpha's sheet must not contain it
// and removing fx_alpha's <link> must not change this page's layout by one pixel.
import { usePage } from '@core/ui'
import { counters } from './index.ts'
import type { BetaProps } from './index.ts'

defineOptions({ name: 'FxBetaPage', inheritAttrs: false })

const page = usePage<BetaProps, { pong: Record<string, never> }>()
</script>

<template>
  <div class="fx-beta-page bg-panel text-fg-dim fixed right-10 bottom-10 p-4">
    <p class="fx-beta-title">{{ page.props.title || 'beta' }}</p>
    <p class="fx-beta-counts">{{ counters.setups }}</p>
    <CoreButton class="fx-beta-btn px-10" @click="page.emit('pong')">pong</CoreButton>
  </div>
</template>
