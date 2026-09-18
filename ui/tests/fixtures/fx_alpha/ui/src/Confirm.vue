<script setup lang="ts">
// fx_alpha's modal: `type = 'modal'` in Lua, so the shell stacks it above the page and marks every
// lower focusable layer `inert` (§38.9). The button and the input exist for exactly that check —
// a Tab must not reach them from the page underneath.
import { usePage } from '@core/ui'

defineOptions({ name: 'FxAlphaConfirm', inheritAttrs: false })

const page = usePage<{ question?: string }>()
</script>

<template>
  <div class="fx-alpha-confirm bg-panel fixed inset-0 flex items-center justify-center">
    <div class="p-6">
      <p class="fx-alpha-question">{{ page.props.question || 'sure?' }}</p>
      <input class="fx-alpha-input" type="text" />
      <CoreButton class="fx-alpha-ok" @click="page.close()">ok</CoreButton>
    </div>
  </div>
</template>
