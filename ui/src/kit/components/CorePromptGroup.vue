<script setup>
// CorePromptGroup — the stack of prompts a single interaction point offers (DESIGN §37.5,
// Actions): enter, open the trunk, call the owner. Click-through like every prompt; `interactive`
// travels per item, so one row of the stack can take the mouse while the rest stay HUD.
import { computed } from 'vue'
import { oneOf } from '../use.js'

const props = defineProps({
  /** `[{ keys, label, icon?, description?, progress?, active?, disabled?, interactive? }]`. */
  items: { type: Array, default: () => [] },
  align: { type: String, default: 'start', validator: oneOf(['start', 'end']) },
})

const emit = defineEmits(['select'])

const prompts = computed(() => (Array.isArray(props.items) ? props.items : [])
  .filter((item) => item && typeof item === 'object'))
</script>

<template>
  <div class="core-prompts" :class="'core-prompts--' + align">
    <slot>
      <CorePrompt
        v-for="(item, i) in prompts"
        :key="(item.id !== undefined ? item.id : i) + '|' + (item.label || '')"
        :keys="item.keys !== undefined ? item.keys : item.key"
        :label="item.label"
        :icon="item.icon"
        :description="item.description"
        :progress="Number(item.progress) || 0"
        :active="!!item.active"
        :disabled="!!item.disabled"
        :interactive="!!item.interactive"
        @click="emit('select', item, i)"
      />
    </slot>
  </div>
</template>
