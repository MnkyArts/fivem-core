<script setup>
// CoreField — label + control + hint/error (DESIGN §37.5, Forms — text).
// The field owns the control's DOM id and hands it to the slot together with `invalid`, so a
// caller wires both in one line: `<template #default="{ id, invalid }">`. `inline` is the settings
// row of the mockups (text left, control right-aligned in `controlWidth`, hairline under the row);
// stacked is the form field. An `error` replaces the hint rather than stacking under it — two
// messages under one control read as two problems.
import { computed, useSlots } from 'vue'
import { useId } from '../use.js'

const props = defineProps({
  /** Caption over (stacked) or left of (inline) the control. The `label` slot overrides it. */
  label: { type: String, default: '' },
  /** Quiet help line under the control. Hidden while `error` is set. */
  hint: { type: String, default: '' },
  /** Validation message. Its presence is what makes the field invalid. */
  error: { type: String, default: '' },
  /** Adds the coral asterisk after the label. */
  required: { type: Boolean, default: false },
  /** The settings row: label + hint left, control right, hairline under. */
  inline: { type: Boolean, default: false },
  /** Width of the control column in an inline row. A number is px. */
  controlWidth: { type: [String, Number], default: '50%' },
  /** Explicit id for the control (else one is generated). */
  id: { type: String, default: '' },
})

const slots = useSlots()
const generated = useId('core-field')
const controlId = computed(() => props.id || generated)
const invalid = computed(() => Boolean(props.error))
const hasLabel = computed(() => Boolean(props.label || slots.label))
const hasMessage = computed(() => Boolean(props.error || props.hint || slots.hint))

const controlStyle = computed(() => (props.inline
  ? { width: typeof props.controlWidth === 'number' ? props.controlWidth + 'px' : String(props.controlWidth) }
  : null))
</script>

<template>
  <div class="core-field" :class="{ 'core-field--inline': inline, 'is-invalid': invalid }">
    <!-- Inline keeps the label and its message in one left-hand column; stacked puts the message
         under the control, where the eye lands after reading the value. -->
    <div v-if="inline" class="core-field__text">
      <label v-if="hasLabel" class="core-field__label" :for="controlId">
        <slot name="label">{{ label }}</slot>
        <em v-if="required" class="core-field__required" aria-hidden="true">*</em>
      </label>
      <p v-if="error" class="core-field__error">
        <CoreIcon name="error" size="xs" />
        <span>{{ error }}</span>
      </p>
      <p v-else-if="hasMessage" class="core-field__hint">
        <slot name="hint">{{ hint }}</slot>
      </p>
    </div>

    <label v-else-if="hasLabel" class="core-field__label" :for="controlId">
      <slot name="label">{{ label }}</slot>
      <em v-if="required" class="core-field__required" aria-hidden="true">*</em>
    </label>

    <div class="core-field__control" :style="controlStyle">
      <slot :id="controlId" :invalid="invalid" />
    </div>

    <template v-if="!inline">
      <p v-if="error" class="core-field__error">
        <CoreIcon name="error" size="xs" />
        <span>{{ error }}</span>
      </p>
      <p v-else-if="hasMessage" class="core-field__hint">
        <slot name="hint">{{ hint }}</slot>
      </p>
    </template>
  </div>
</template>
