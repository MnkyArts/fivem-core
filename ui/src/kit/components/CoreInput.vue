<script>
// CoreInput — the single-line text field (DESIGN §37.5, Forms — text).
// The ROOT wears the box look and the focus ring, the `<input>` inside is stripped bare, so icon,
// prefix, suffix and the clear button share one well: `is-focused` follows the inner element and a
// click anywhere in the box lands on the input (mousedown is prevented, so the wrapper never takes
// focus and the clear button still gets its click). `inheritAttrs: false` — a caller's `type`,
// `aria-*` or `@keydown` belongs on the input, not on the div around it.
export default { inheritAttrs: false }
</script>

<script setup>
import { computed, onMounted, ref } from 'vue'
import { oneOf, SIZES } from '../use.js'

const ICON_PX = { sm: 14, md: 16, lg: 18 }

const props = defineProps({
  /** `text` | `password` | `search` | `email` | `tel` | … — anything a native input takes. */
  type: { type: String, default: 'text' },
  placeholder: { type: String, default: '' },
  /** Registry name or raw path, drawn before the text. */
  icon: { type: String, default: '' },
  /** Static text before the value (a dial code, a unit). The `prefix` slot overrides it. */
  prefix: { type: String, default: '' },
  /** Static text after the value (`$`, `KG`). The `suffix` slot overrides it. */
  suffix: { type: String, default: '' },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  /** Shows a clear button while there is a value. */
  clearable: { type: Boolean, default: false },
  maxlength: { type: [String, Number], default: null },
  invalid: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  readonly: { type: Boolean, default: false },
  autofocus: { type: Boolean, default: false },
  id: { type: String, default: '' },
  name: { type: String, default: '' },
})

const emit = defineEmits(['enter', 'clear', 'focus', 'blur'])
const model = defineModel({ type: [String, Number], default: '' })

const inputEl = ref(null)
const focused = ref(false)

const iconSize = computed(() => ICON_PX[props.size] || ICON_PX.md)
const showClear = computed(() => props.clearable && !props.disabled && !props.readonly
  && model.value !== '' && model.value !== null && model.value !== undefined)

function focus () {
  if (inputEl.value) inputEl.value.focus()
}

function onInput (event) {
  model.value = event.target.value
}

function onKeydown (event) {
  if (event.key === 'Enter') emit('enter', model.value)
}

function clear () {
  model.value = ''
  emit('clear')
  focus()
}

// A click on the padding, the icon or an affix must feel like a click on the field itself.
function onRootMousedown (event) {
  if (props.disabled || !inputEl.value || event.target === inputEl.value) return
  event.preventDefault()
  inputEl.value.focus()
}

onMounted(() => {
  if (props.autofocus) focus()
})

defineExpose({ focus })
</script>

<template>
  <div
    class="core-inputbox"
    :class="['core-inputbox--' + size, { 'is-focused': focused, 'is-invalid': invalid, 'is-disabled': disabled }]"
    @mousedown="onRootMousedown"
  >
    <CoreIcon v-if="icon" class="core-inputbox__icon" :name="icon" :size="iconSize" />
    <span v-if="prefix || $slots.prefix" class="core-inputbox__prefix">
      <slot name="prefix">{{ prefix }}</slot>
    </span>

    <input
      ref="inputEl"
      v-bind="$attrs"
      class="core-inputbox__el"
      :id="id || undefined"
      :name="name || undefined"
      :type="type"
      :value="model"
      :placeholder="placeholder"
      :maxlength="maxlength === null ? undefined : maxlength"
      :disabled="disabled"
      :readonly="readonly"
      :aria-invalid="invalid ? 'true' : undefined"
      @input="onInput"
      @keydown="onKeydown"
      @focus="focused = true; emit('focus', $event)"
      @blur="focused = false; emit('blur', $event)"
    />

    <span v-if="suffix || $slots.suffix" class="core-inputbox__suffix">
      <slot name="suffix">{{ suffix }}</slot>
    </span>
    <button
      v-if="showClear"
      type="button"
      class="core-inputbox__clear"
      aria-label="Clear"
      tabindex="-1"
      @click="clear"
    >
      <CoreIcon name="close" size="xs" />
    </button>
  </div>
</template>
