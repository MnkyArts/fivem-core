<script setup lang="ts">
import { usePage } from '@core/ui'

defineOptions({ name: 'FxLazyPage', inheritAttrs: false })

const page = usePage<{ label?: string }>()
</script>

<template>
  <div class="fx-lazy-page text-fg-dim fixed top-40 left-10 p-4">{{ page.props.label || 'lazy' }}</div>
</template>
