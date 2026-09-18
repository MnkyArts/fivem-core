<script>
// CoreTextarea — the multi-line field (DESIGN §37.5, Forms — text).
// Same well as CoreInput, laid out as a column so the optional character counter sits INSIDE the
// box: a form of stacked fields then keeps exactly one rectangle per control. Resizing is off by
// default — a draggable corner inside a fixed game panel drags the layout apart.
export default { inheritAttrs: false }
</script>

<script setup>
import { computed, onMounted, ref } from 'vue'
import { oneOf } from '../use.js'

const props = defineProps({
  placeholder: { type: String, default: '' },
  /** Visible lines before it scrolls. */
  rows: { type: [String, Number], default: 4 },
  maxlength: { type: [String, Number], default: null },
  /** Shows `used / maxlength` (or just the count without a limit) under the text. */
  counter: { type: Boolean, default: false },
  resize: { type: String, default: 'none', validator: oneOf(['none', 'vertical']) },
  invalid: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  readonly: { type: Boolean, default: false },
  autofocus: { type: Boolean, default: false },
  id: { type: String, default: '' },
  name: { type: String, default: '' },
})

const emit = defineEmits(['focus', 'blur'])
const model = defineModel({ type: String, default: '' })

const areaEl = ref(null)
const focused = ref(false)

const used = computed(() => String(model.value === null || model.value === undefined ? '' : model.value).length)
const limit = computed(() => {
  const n = Number(props.maxlength)
  return Number.isFinite(n) && n > 0 ? n : 0
})
const counterText = computed(() => (limit.value ? used.value + ' / ' + limit.value : String(used.value)))

function focus () {
  if (areaEl.value) areaEl.value.focus()
}

onMounted(() => {
  if (props.autofocus) focus()
})

defineExpose({ focus })
</script>

<template>
  <div
    class="core-textarea"
    :class="[{ 'core-textarea--resize': resize === 'vertical' },
             { 'is-focused': focused, 'is-invalid': invalid, 'is-disabled': disabled }]"
  >
    <textarea
      ref="areaEl"
      v-bind="$attrs"
      v-model="model"
      class="core-textarea__el"
      :id="id || undefined"
      :name="name || undefined"
      :rows="rows"
      :placeholder="placeholder"
      :maxlength="maxlength === null ? undefined : maxlength"
      :disabled="disabled"
      :readonly="readonly"
      :aria-invalid="invalid ? 'true' : undefined"
      @focus="focused = true; emit('focus', $event)"
      @blur="focused = false; emit('blur', $event)"
    ></textarea>
    <span v-if="counter" class="core-textarea__counter" :class="{ 'is-over': limit > 0 && used > limit }">
      {{ counterText }}
    </span>
  </div>
</template>
