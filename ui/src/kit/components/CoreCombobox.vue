<script setup>
// CoreCombobox — the filterable select (DESIGN §53, §37.5 Forms — text).
// A text field in the box look with a teleported option list, like CoreSelect — but the FOCUS
// stays in the input: the list is a `listbox` driven by aria-activedescendant, the options prevent
// their mousedown so a click never blurs the field. Local `options` are filtered here (label,
// value, description; case-insensitive); an async `search(query)` replaces them — debounced, and
// an answer that arrives after a newer query is dropped. Every option ever seen is remembered, so a
// selected value keeps its label after the list it came from is gone. `multiple` renders the
// picks as removable tags in the well (Backspace on an empty field drops the last one);
// `creatable` offers the typed text as a first "Create" row. Past `virtualThreshold` rows the list
// renders through CoreVirtualList.
import { computed, nextTick, onBeforeUnmount, onMounted, ref, shallowReactive, watch } from 'vue'
import {
  normalizeItems, nextEnabledIndex, oneOf, onClickOutside, overlayTarget, SIZES, useEscapeLayer,
  useFloating, useId,
} from '../use.js'

const ROW = 36
const ROW_DESC = 54

const props = defineProps({
  /** Strings/numbers or `{ value, label, description?, icon?, disabled? }`. */
  options: { type: Array, default: () => [] },
  /** `(query) => Option[] | Promise<Option[]>` — replaces the local filter when set. */
  search: { type: Function, default: null },
  /** ms between the last keystroke and `search(query)`. */
  debounce: { type: Number, default: 200 },
  /** The model is an array of values; picks render as tags. */
  multiple: { type: Boolean, default: false },
  /** Offer the typed text as a new value (emits `create`). */
  creatable: { type: Boolean, default: false },
  placeholder: { type: String, default: 'Search…' },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  /** A ✕ that empties the value. */
  clearable: { type: Boolean, default: false },
  /** Popup height before it scrolls, in px. */
  maxHeight: { type: Number, default: 280 },
  /** Rows beyond which the list is virtualised. */
  virtualThreshold: { type: Number, default: 100 },
  /** Shown when nothing matches. */
  emptyText: { type: String, default: 'No matches.' },
  invalid: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  id: { type: String, default: '' },
})

const emit = defineEmits(['open', 'close', 'create', 'focus', 'blur'])
const model = defineModel({ type: null, default: null })

const open = ref(false)
const focused = ref(false)
const typing = ref(false)
const query = ref('')
const activeIndex = ref(-1)
const loading = ref(false)
const remote = ref([])
const boxRef = ref(null)
const inputRef = ref(null)
const popupRef = ref(null)
const vlistRef = ref(null)
const listId = useId('core-combobox-list')
const known = shallowReactive(new Map())

const teleportTo = ref((typeof document !== 'undefined' && document.getElementById('core-overlays')) || 'body')
onMounted(() => { teleportTo.value = overlayTarget() || 'body' })

const remember = (list) => { for (const item of list) if (!item.create) known.set(item.value, item) }
const local = computed(() => normalizeItems(props.options))
watch(local, remember, { immediate: true })

const needle = computed(() => query.value.trim().toLowerCase())
const filtered = computed(() => {
  if (props.search) return remote.value
  const n = needle.value
  if (!n) return local.value
  return local.value.filter((item) => String(item.label).toLowerCase().indexOf(n) !== -1
    || String(item.value).toLowerCase().indexOf(n) !== -1
    || (item.description && String(item.description).toLowerCase().indexOf(n) !== -1))
})
const rows = computed(() => {
  const q = query.value.trim()
  if (!props.creatable || !q) return filtered.value
  const lower = q.toLowerCase()
  const exists = filtered.value.some((item) => String(item.label).toLowerCase() === lower
    || String(item.value).toLowerCase() === lower)
  return exists ? filtered.value : [{ value: q, label: q, create: true }].concat(filtered.value)
})

const selectedValues = computed(() => {
  if (props.multiple) return Array.isArray(model.value) ? model.value : []
  return model.value === null || model.value === undefined || model.value === '' ? [] : [model.value]
})
const isSelected = (item) => selectedValues.value.indexOf(item.value) !== -1
const labelOf = (value) => {
  const hit = known.get(value)
  return hit ? String(hit.label) : String(value)
}
const inputValue = computed(() => {
  if (props.multiple || typing.value) return query.value
  return selectedValues.value.length ? labelOf(selectedValues.value[0]) : ''
})

const virtual = computed(() => rows.value.length > props.virtualThreshold)
const rowHeight = computed(() => (rows.value.some((item) => item.description) ? ROW_DESC : ROW))
const vlistStyle = computed(() => ({ height: Math.min(rows.value.length * rowHeight.value, props.maxHeight - 10) + 'px' }))
const popupStyleOwn = computed(() => ({ maxHeight: props.maxHeight + 'px' }))
const showClear = computed(() => props.clearable && !props.disabled && selectedValues.value.length > 0)

const { style: floatStyle } = useFloating(boxRef, popupRef, open, () => ({
  placement: 'bottom-start',
  offset: 6,
  matchWidth: true,
}))
useEscapeLayer(open, () => close())
onClickOutside(() => [boxRef, popupRef], () => close(false), open)

// ---- remote search ---------------------------------------------------------------------------
let seq = 0
let timer = null
function runSearch (q, delay) {
  if (!props.search) return
  if (timer !== null) clearTimeout(timer)
  timer = setTimeout(async () => {
    timer = null
    seq += 1
    const mine = seq
    loading.value = true
    try {
      const answer = await props.search(q)
      if (mine !== seq) return
      const list = normalizeItems(answer)
      remember(list)
      remote.value = list
    } catch (e) {
      if (mine === seq) remote.value = []
    } finally {
      if (mine === seq) loading.value = false
    }
  }, delay === undefined ? props.debounce : delay)
}
onBeforeUnmount(() => { if (timer !== null) clearTimeout(timer) })

// ---- open / move / pick ----------------------------------------------------------------------
function scrollActiveIntoView () {
  if (activeIndex.value < 0) return
  if (virtual.value) {
    if (vlistRef.value) vlistRef.value.scrollToIndex(activeIndex.value)
    return
  }
  const popup = popupRef.value
  const el = popup && popup.querySelector('[data-index="' + activeIndex.value + '"]')
  if (!el) return
  const top = el.offsetTop - 4
  const bottom = el.offsetTop + el.offsetHeight + 4
  if (top < popup.scrollTop) popup.scrollTop = top
  else if (bottom > popup.scrollTop + popup.clientHeight) popup.scrollTop = bottom - popup.clientHeight
}

function firstActive () {
  if (!props.multiple && selectedValues.value.length && !typing.value) {
    const at = rows.value.findIndex((item) => item.value === selectedValues.value[0])
    if (at !== -1) return at
  }
  return nextEnabledIndex(rows.value, -1, 1, false)
}

function openList () {
  if (props.disabled || open.value) return
  open.value = true
  activeIndex.value = firstActive()
  emit('open')
  if (props.search && !typing.value) runSearch('', 0)
  nextTick(scrollActiveIntoView)
}

function close (refocus = true) {
  if (!open.value) return
  open.value = false
  typing.value = false
  query.value = ''
  emit('close')
  if (refocus && inputRef.value) inputRef.value.focus()
}

function move (dir) {
  activeIndex.value = nextEnabledIndex(rows.value, activeIndex.value, dir, true)
  nextTick(scrollActiveIntoView)
}

function pick (item) {
  if (!item || item.disabled) return
  if (item.create) {
    known.set(item.value, { value: item.value, label: item.value })
    emit('create', item.value)
  }
  if (!props.multiple) {
    model.value = item.value
    close()
    return
  }
  const next = selectedValues.value.slice()
  const at = next.indexOf(item.value)
  if (at === -1) next.push(item.value)
  else next.splice(at, 1)
  model.value = next
  query.value = ''
  typing.value = false
  if (props.search) runSearch('', 0)
  if (inputRef.value) inputRef.value.focus()
}

function remove (value) {
  if (props.disabled) return
  model.value = selectedValues.value.filter((v) => v !== value)
}

function clear () {
  model.value = props.multiple ? [] : null
  query.value = ''
  typing.value = false
  if (inputRef.value) inputRef.value.focus()
}

// ---- input events ------------------------------------------------------------------------------
function onInput (event) {
  query.value = event.target.value
  typing.value = true
  if (!open.value) openList()
  activeIndex.value = nextEnabledIndex(rows.value, -1, 1, false)
  runSearch(query.value)
}

function onKeydown (event) {
  if (props.disabled) return
  const key = event.key
  if (key === 'ArrowDown' || key === 'ArrowUp') {
    event.preventDefault()
    if (!open.value) { openList(); if (key === 'ArrowUp') move(-1); return }
    move(key === 'ArrowDown' ? 1 : -1)
  } else if (key === 'Enter') {
    if (!open.value) return
    event.preventDefault()
    pick(rows.value[activeIndex.value])
  } else if (key === 'Tab') close(false)
  else if (key === 'Backspace' && props.multiple && query.value === '' && selectedValues.value.length) {
    remove(selectedValues.value[selectedValues.value.length - 1])
  }
}

function onFocus (event) {
  focused.value = true
  emit('focus', event)
  if (!props.multiple && inputRef.value) inputRef.value.select()
}

function onBlur (event) {
  focused.value = false
  emit('blur', event)
  close(false)
  typing.value = false
  query.value = ''
}

/** A click anywhere in the well lands on the input and opens the list. */
function onBoxMousedown (event) {
  if (props.disabled || !inputRef.value) return
  if (event.target !== inputRef.value) event.preventDefault()
  inputRef.value.focus()
  if (open.value) {
    if (event.target !== inputRef.value) close()
  } else openList()
}

watch(() => props.disabled, (off) => { if (off) close(false) })
// A list that changed under the cursor (search results arriving, a filter narrowing) puts the cursor
// on its first enabled row, so Enter always has something to pick.
watch(rows, () => {
  if (!open.value) return
  if (activeIndex.value < 0 || activeIndex.value >= rows.value.length) {
    activeIndex.value = nextEnabledIndex(rows.value, -1, 1, false)
  }
})

defineExpose({ focus: () => inputRef.value && inputRef.value.focus(), open: openList, close })
</script>

<template>
  <div
    class="core-combobox"
    :class="['core-combobox--' + size, {
      'is-open': open, 'is-focused': focused, 'is-invalid': invalid, 'is-disabled': disabled,
      'is-multiple': multiple, 'is-loading': loading,
    }]"
  >
    <div ref="boxRef" class="core-combobox__box" @mousedown="onBoxMousedown">
      <template v-if="multiple">
        <CoreTag
          v-for="value in selectedValues"
          :key="String(value)"
          class="core-combobox__tag"
          size="sm"
          :label="labelOf(value)"
          :removable="!disabled"
          @mousedown.stop.prevent
          @remove="remove(value)"
        />
      </template>
      <input
        ref="inputRef"
        class="core-combobox__input"
        role="combobox"
        type="text"
        autocomplete="off"
        spellcheck="false"
        aria-autocomplete="list"
        :id="id || undefined"
        :value="inputValue"
        :placeholder="multiple && selectedValues.length ? '' : placeholder"
        :disabled="disabled"
        :aria-expanded="open ? 'true' : 'false'"
        :aria-controls="open ? listId : undefined"
        :aria-activedescendant="open && activeIndex >= 0 ? listId + '-' + activeIndex : undefined"
        :aria-invalid="invalid ? 'true' : undefined"
        @input="onInput"
        @keydown="onKeydown"
        @focus="onFocus"
        @blur="onBlur"
      />
      <CoreSpinner v-if="loading" class="core-combobox__spinner" :size="14" />
      <button
        v-if="showClear"
        type="button"
        class="core-combobox__clear"
        aria-label="Clear"
        tabindex="-1"
        @mousedown.stop.prevent
        @click="clear"
      >
        <CoreIcon name="close" size="xs" />
      </button>
      <CoreIcon class="core-combobox__chevron" name="chevron-down" :size="20" />
    </div>

    <Teleport :to="teleportTo">
      <Transition name="core-pop">
        <div
          v-if="open"
          ref="popupRef"
          :id="listId"
          class="core-combobox__popup"
          :class="{ 'core-scroll': !virtual, 'is-virtual': virtual }"
          role="listbox"
          :aria-multiselectable="multiple ? 'true' : undefined"
          :style="[floatStyle, popupStyleOwn]"
          @mousedown.prevent
        >
          <CoreVirtualList
            v-if="virtual"
            ref="vlistRef"
            role="presentation"
            :items="rows"
            :item-height="rowHeight"
            key-field="value"
            :style="vlistStyle"
          >
            <template #default="{ item, index }">
              <div
                :id="listId + '-' + index"
                class="core-combobox__option"
                :class="{ 'is-active': index === activeIndex, 'is-selected': isSelected(item),
                          'is-disabled': item.disabled, 'is-create': item.create }"
                :style="{ height: rowHeight + 'px' }"
                :data-index="index"
                role="option"
                :aria-selected="isSelected(item) ? 'true' : 'false'"
                @click="pick(item)"
                @mousemove="!item.disabled && (activeIndex = index)"
              >
                <slot name="option" :item="item" :selected="isSelected(item)" :active="index === activeIndex">
                  <CoreIcon v-if="item.create || item.icon" class="core-combobox__option-icon" :name="item.create ? 'plus' : item.icon" size="sm" />
                  <span class="core-combobox__option-body">
                    <span class="core-combobox__option-label">{{ item.create ? 'Create “' + item.label + '”' : item.label }}</span>
                    <span v-if="item.description" class="core-combobox__option-desc">{{ item.description }}</span>
                  </span>
                  <CoreIcon v-if="isSelected(item)" class="core-combobox__check" name="check" size="xs" />
                </slot>
              </div>
            </template>
          </CoreVirtualList>
          <template v-else>
            <div
              v-for="(item, index) in rows"
              :key="(item.create ? 'create:' : '') + String(item.value)"
              :id="listId + '-' + index"
              class="core-combobox__option"
              :class="{ 'is-active': index === activeIndex, 'is-selected': isSelected(item),
                        'is-disabled': item.disabled, 'is-create': item.create }"
              :data-index="index"
              role="option"
              :aria-selected="isSelected(item) ? 'true' : 'false'"
              :aria-disabled="item.disabled ? 'true' : undefined"
              @click="pick(item)"
              @mousemove="!item.disabled && (activeIndex = index)"
            >
              <slot name="option" :item="item" :selected="isSelected(item)" :active="index === activeIndex">
                <CoreIcon v-if="item.create || item.icon" class="core-combobox__option-icon" :name="item.create ? 'plus' : item.icon" size="sm" />
                <span class="core-combobox__option-body">
                  <span class="core-combobox__option-label">{{ item.create ? 'Create “' + item.label + '”' : item.label }}</span>
                  <span v-if="item.description" class="core-combobox__option-desc">{{ item.description }}</span>
                </span>
                <CoreIcon v-if="isSelected(item)" class="core-combobox__check" name="check" size="xs" />
              </slot>
            </div>
          </template>
          <p v-if="!rows.length" class="core-combobox__empty">{{ loading ? 'Searching…' : emptyText }}</p>
        </div>
      </Transition>
    </Teleport>
  </div>
</template>
