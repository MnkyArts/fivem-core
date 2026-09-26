<script setup lang="ts">
// fx_lazy's `reactivity: 'shallow'` page. A lazy plugin has no definition when Lua declares its
// pages, so this is the page whose props start deep and must be re-wrapped shallow once the module
// loads (§38.10) — the runtime suite checks the wrapper and that a nested patch still renders.
import { usePage } from '@core/ui'

defineOptions({ name: 'FxLazyShallow', inheritAttrs: false })

const page = usePage<{ nested?: { a?: unknown } }>()
</script>

<template>
  <div class="fx-lazy-shallow text-fg-dim fixed top-60 left-10 p-4">{{ page.props.nested?.a ?? '-' }}</div>
</template>
