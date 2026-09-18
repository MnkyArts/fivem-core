<script setup lang="ts">
// Throws while RENDERING (Vue error code 1), which §38.12 calls fatal: the PluginBoundary replaces
// this subtree, reports once with { plugin, page, component }, and — on a focus-holding layer —
// posts `ui_close`. The component NAME is what the report has to carry, and an explicit
// `defineOptions({ name })` has to WIN over the file name the SFC compiler infers — hence a name
// that is deliberately nothing like `Crash.vue`.
defineOptions({ name: 'FxCrashChild' })

function boom(): string {
  throw new Error('fx_alpha: render crash on purpose')
}
</script>

<template>
  <span class="fx-alpha-crash">{{ boom() }}</span>
</template>
