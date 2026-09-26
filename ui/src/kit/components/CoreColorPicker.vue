<script>
// The default palette is DATA (paint to choose from), not the theme — the kit's own look never
// reads it. Module scope, because defineProps() is hoisted out of setup and may only reference it
// from here. The accent is written out because a swatch must be a concrete colour.
const PALETTE = [
  '#FFFFFF', '#C7CCD2', '#6B7480', '#1A1D21', '#F6503F', '#E0312B', '#F5A623', '#F2D43D',
  '#3FD67F', '#1E9E5A', '#4FD1E8', '#55B6F7', '#2F5FD0', '#B68CFF', '#E056C8', '#8C5A3C',
]
</script>

<script setup>
// CoreColorPicker — hex field + swatches + R/G/B(/A) sliders (DESIGN §53, §37.5 Forms — choice).
// Never `<input type="color">`: its picker is a native popup, and FiveM's CEF renders off-screen,
// so that popup never appears. Everything here is DOM: the channel sliders are real range inputs
// whose tracks are painted with the live gradient of their own channel (`--core-cp-track`), the
// alpha track over a checkerboard. The model is `'#RRGGBB'` — or `'#RRGGBBAA'` with `alpha` when the
// colour is not opaque — upper-case, the §43 `color` shape. The hex field commits on Enter and on
// blur and marks itself invalid instead of guessing; a full 3/6/8-digit value applies live.
// `popover` folds the picker behind a box-look trigger (a form row); otherwise it is inline.
import { computed, ref, watch } from 'vue'
import { normalizeItems, oneOf, SIZES } from '../use.js'

const CHANNELS = ['r', 'g', 'b', 'a']

const props = defineProps({
  /** `false` = no alpha slider and the model stays 6-digit. */
  alpha: { type: Boolean, default: false },
  /** Strings (`'#F6503F'`) or `{ value, label? }`; `[]` hides the row. */
  swatches: { type: Array, default: () => PALETTE },
  /** Fold the picker into a popover behind a box-look trigger. */
  popover: { type: Boolean, default: false },
  /** Trigger size in popover mode. */
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  placeholder: { type: String, default: 'No colour' },
  invalid: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  id: { type: String, default: '' },
})

const model = defineModel({ type: String, default: '' })

const open = ref(false)
const editing = ref(false)
const hexText = ref('')
const hexBad = ref(false)

const hex2 = (n) => Math.round(n).toString(16).padStart(2, '0').toUpperCase()

/**
 * `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa` (the `#` optional) → `{ r, g, b, a }` in 0-255, or null.
 * @param {string} text
 */
function parseHex (text) {
  const s = String(text || '').trim().replace(/^#/, '')
  if (!/^[0-9a-f]+$/i.test(s)) return null
  let full = s
  if (s.length === 3 || s.length === 4) full = s.split('').map((c) => c + c).join('')
  if (full.length !== 6 && full.length !== 8) return null
  const n = (i) => parseInt(full.slice(i, i + 2), 16)
  return { r: n(0), g: n(2), b: n(4), a: full.length === 8 ? n(6) : 255 }
}

const toHex = (c) => '#' + hex2(c.r) + hex2(c.g) + hex2(c.b) + (props.alpha && c.a < 255 ? hex2(c.a) : '')

const rgba = computed(() => parseHex(model.value) || { r: 0, g: 0, b: 0, a: 255 })
const hasValue = computed(() => parseHex(model.value) !== null)
const css = (c, a) => 'rgba(' + c.r + ', ' + c.g + ', ' + c.b + ', ' + (a === undefined ? c.a / 255 : a) + ')'
const fill = computed(() => (hasValue.value ? css(rgba.value) : 'transparent'))
const channels = computed(() => (props.alpha ? CHANNELS : CHANNELS.slice(0, 3)))

/** Each track is the gradient of ITS channel with the other two held where they are. */
function track (ch) {
  const c = rgba.value
  if (ch === 'a') return 'linear-gradient(90deg, ' + css(c, 0) + ', ' + css(c, 1) + ')'
  const lo = Object.assign({}, c, { [ch]: 0 })
  const hi = Object.assign({}, c, { [ch]: 255 })
  return 'linear-gradient(90deg, ' + css(lo, 1) + ', ' + css(hi, 1) + ')'
}

const swatchItems = computed(() => normalizeItems(props.swatches).map((item) => {
  const parsed = parseHex(item.value)
  const value = parsed ? toHex(parsed) : String(item.value)
  return { value, color: parsed ? css(parsed) : String(item.value), label: item.label || value }
}))
const swatchModel = computed(() => (hasValue.value ? toHex(rgba.value) : undefined))

watch(() => model.value, (v) => {
  if (editing.value) return
  const c = parseHex(v)
  hexText.value = c ? toHex(c).slice(1) : ''
  hexBad.value = false
}, { immediate: true })

function set (c) {
  if (props.disabled) return
  model.value = toHex(c)
}

function setChannel (ch, value) {
  const n = Math.max(0, Math.min(255, Math.round(Number(value) || 0)))
  set(Object.assign({}, rgba.value, { [ch]: n }))
}

function onHexInput (text) {
  hexText.value = String(text || '')
  const c = parseHex(hexText.value)
  const len = hexText.value.replace(/^#/, '').length
  hexBad.value = false
  if (c && (len === 6 || len === 8 || len === 3)) set(c)
}

function commitHex () {
  editing.value = false
  const c = parseHex(hexText.value)
  if (!c) {
    hexBad.value = hexText.value.trim() !== ''
    if (!hexBad.value) model.value = ''
    return
  }
  set(c)
  hexText.value = toHex(c).slice(1)
  hexBad.value = false
}
</script>

<template>
  <div
    class="core-colorpicker"
    :class="[popover ? 'core-colorpicker--popover core-colorpicker--' + size : 'core-colorpicker--inline',
             { 'is-disabled': disabled, 'is-invalid': invalid, 'is-open': open, 'has-alpha': alpha }]"
  >
    <!-- One panel, two frames: CorePopover (trigger slot + the panel as its body) or a plain div
         (which renders only the default slot, so the trigger template simply does not exist). -->
    <component
      :is="popover ? 'CorePopover' : 'div'"
      v-bind="popover
        ? { class: 'core-colorpicker__anchor', placement: 'bottom-start', open: open && !disabled, 'onUpdate:open': (v) => (open = v) }
        : { class: 'core-colorpicker__frame' }"
    >
      <template v-if="popover" #trigger>
        <button type="button" class="core-colorpicker__trigger" :id="id || undefined" :disabled="disabled" :aria-expanded="open ? 'true' : 'false'">
          <span class="core-colorpicker__chip"><span class="core-colorpicker__chip-fill" :style="{ background: fill }"></span></span>
          <span class="core-colorpicker__value" :class="{ 'is-placeholder': !hasValue }">{{ hasValue ? toHex(rgba) : placeholder }}</span>
          <CoreIcon class="core-colorpicker__chevron" name="chevron-down" :size="20" />
        </button>
      </template>
      <div class="core-colorpicker__panel">
        <div class="core-colorpicker__top">
          <span class="core-colorpicker__preview"><span class="core-colorpicker__chip-fill" :style="{ background: fill }"></span></span>
          <CoreInput
            :model-value="hexText"
            prefix="#"
            size="sm"
            :id="!popover && id ? id : undefined"
            :maxlength="alpha ? 9 : 7"
            :invalid="hexBad || (!popover && invalid)"
            :disabled="disabled"
            aria-label="Hex colour"
            @update:model-value="onHexInput"
            @focus="editing = true"
            @blur="commitHex"
            @enter="commitHex"
          />
        </div>
        <CoreSwatches
          v-if="swatchItems.length"
          :items="swatchItems"
          size="sm"
          :columns="8"
          :model-value="swatchModel"
          :disabled="disabled"
          @update:model-value="(v) => set(parseHex(v))"
        />
        <div class="core-colorpicker__channels">
          <label v-for="ch in channels" :key="ch" class="core-colorpicker__channel">
            <span class="core-colorpicker__channel-label">{{ ch.toUpperCase() }}</span>
            <input
              class="core-colorpicker__range"
              :class="{ 'core-colorpicker__range--alpha': ch === 'a' }"
              type="range"
              min="0"
              max="255"
              step="1"
              :value="rgba[ch]"
              :disabled="disabled"
              :style="{ '--core-cp-track': track(ch) }"
              @input="setChannel(ch, $event.target.value)"
            />
            <span class="core-colorpicker__channel-value">{{ rgba[ch] }}</span>
          </label>
        </div>
      </div>
    </component>
  </div>
</template>
