<script setup>
// CoreTooltip — hover / focus hint (DESIGN §37.5, Feedback).
// The default slot is wrapped in an inline-flex span so useFloating has a rect to place against
// (Chromium 103 has no anchor positioning, §37.4). Escape deliberately does NOT go through the
// kit's Escape layer: a layer SWALLOWS the key, and a tooltip lying over an open dialog must not
// eat the Escape that was meant to close the dialog — so it listens without stopping the event.
import { computed, onMounted, onScopeDispose, ref, useSlots } from 'vue'
import { overlayTarget, useFloating, useId } from '../use.js'

defineOptions({ inheritAttrs: false })

const props = defineProps({
  /** The hint. Ignored when the `content` slot is used. */
  text: { type: String, default: '' },
  /** `top|bottom|left|right` with an optional `-start` / `-end`; flipped and clamped on the fly. */
  placement: { type: String, default: 'top' },
  /** How long the pointer has to rest on the trigger, in ms. Focus shows it at once. */
  delay: { type: Number, default: 350 },
  /** Keeps it from ever showing (a disabled control's tooltip, a tooltip with nothing to say). */
  disabled: { type: Boolean, default: false },
})

const slots = useSlots()
const anchorRef = ref(null)
const bubbleRef = ref(null)
const visible = ref(false)
const tipId = useId('core-tooltip')
let timer = null

const hasContent = computed(() => Boolean(slots.content) || Boolean(props.text))

function clear () {
  if (timer === null) return
  clearTimeout(timer)
  timer = null
}

function hide () {
  clear()
  if (!visible.value) return
  visible.value = false
  listen(false)
}

function show (immediate) {
  clear()
  if (props.disabled || !hasContent.value || visible.value) return
  if (immediate || props.delay <= 0) {
    visible.value = true
    listen(true)
    return
  }
  timer = setTimeout(() => { timer = null; visible.value = true; listen(true) }, props.delay)
}

/** Escape and any press anywhere dismiss it — neither listener stops the event for anyone else. */
function onKey (event) {
  if (event.key === 'Escape' || event.key === 'Esc') hide()
}

function listen (on) {
  if (typeof window === 'undefined') return
  const fn = on ? window.addEventListener : window.removeEventListener
  fn.call(window, 'keydown', onKey)
  fn.call(window, 'pointerdown', hide, true)
}

// The Teleport target, resolved as early as it can honestly be. `#core-overlays` is the LAST child
// of `.core-root` (§37.3), so calling overlayTarget() during the first render would CREATE a second
// element with that id — hence a lookup-only read here, with overlayTarget() kept as the mounted
// fallback for the case where the element really was not there yet. Resolving at setup matters for
// a popup that is created already open: swapping the target after mount MOVES the panel, and moving
// a focused node blurs it.
const teleportTo = ref(typeof document === 'undefined' ? 'body' : document.getElementById('core-overlays') || 'body')
onMounted(() => { if (teleportTo.value === 'body') teleportTo.value = overlayTarget() || 'body' })
const floating = useFloating(anchorRef, bubbleRef, visible, () => ({ placement: props.placement, offset: 8 }))

onScopeDispose(() => { clear(); listen(false) })
</script>

<template>
  <span
    ref="anchorRef"
    v-bind="$attrs"
    class="core-tooltip__anchor"
    :aria-describedby="visible ? tipId : null"
    @mouseenter="show(false)"
    @mouseleave="hide"
    @focusin="show(true)"
    @focusout="hide"
  >
    <slot />
  </span>

  <Teleport :to="teleportTo">
    <Transition name="core-fade">
      <div
        v-if="visible"
        :id="tipId"
        ref="bubbleRef"
        class="core-tooltip"
        :class="[{ 'core-tooltip--rich': !!$slots.content }, 'core-tooltip--' + floating.placement.value]"
        :style="floating.style"
        role="tooltip"
      >
        <slot name="content">{{ text }}</slot>
      </div>
    </Transition>
  </Teleport>
</template>
