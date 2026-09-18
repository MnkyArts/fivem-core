<script setup lang="ts">
// Lazily imported page: proves a dynamic import lands in chunks/ and keeps the plugin's origin.
import { ref } from 'vue'

const hits = ref(0)
</script>

<template>
  <p class="alpha-lazy text-fg-faint">lazy {{ hits }}</p>
</template>
