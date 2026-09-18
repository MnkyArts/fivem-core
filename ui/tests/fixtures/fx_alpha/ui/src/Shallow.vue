<script setup lang="ts">
// The `reactivity: 'shallow'` page (§38.10): its props are `shallowReactive`, so a patch cannot
// mutate a nested object in place — the runtime copies along the path and re-assigns the top-level
// key. The test reads the rendered value AND the identity of `props.nested` to tell the two modes
// apart: deep keeps the object, shallow replaces it.
import { usePage } from '@core/ui'

defineOptions({ name: 'FxAlphaShallow', inheritAttrs: false })

const page = usePage<{ nested?: { a?: unknown }; slots?: unknown[] }>()
</script>

<template>
  <div class="fx-alpha-shallow text-fg-dim fixed right-10 top-10 p-4">
    <span class="fx-alpha-shallow-a">{{ page.props.nested?.a ?? '-' }}</span>
    <span class="fx-alpha-shallow-n">{{ (page.props.slots || []).length }}</span>
  </div>
</template>
