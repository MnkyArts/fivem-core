<script setup>
// CorePopover — anchored floating panel (DESIGN §37.5, Feedback).
// The trigger slot is wrapped in an inline-flex span because Chromium 103 has no anchor
// positioning: useFloating needs a real rect to measure (§37.4). The wrapper owns the click /
// hover handling, so the slot's `toggle` is only meant for `trigger="manual"` — wiring both to
// the same element toggles twice. Escape always closes (the layer must swallow the key so the
// store does not close the page behind the popover); an outside click closes click/hover popovers.
import { onMounted, onScopeDispose, ref, watch } from 'vue'
import { blurAttr, oneOf, onClickOutside, overlayTarget, useEscapeLayer, useFloating } from '../use.js'

defineOptions({ inheritAttrs: false })

const props = defineProps({
  /** `v-model:open`. */
  open: { type: Boolean, default: false },
  /** `top|bottom|left|right` with an optional `-start` / `-end`; flipped and clamped on the fly. */
  placement: { type: String, default: 'bottom-start' },
  /** Gap between the anchor and the panel, in px. */
  offset: { type: Number, default: 8 },
  /** What opens it: a click on the trigger, hovering it, or nothing but `v-model:open`. */
  trigger: { type: String, default: 'click', validator: oneOf(['click', 'hover', 'manual']) },
  /** Makes the panel at least as wide as the anchor (a dropdown under a full-width field). */
  matchWidth: { type: Boolean, default: false },
  /** §32 glass: `true` or a blur radius in px. */
  blur: { type: [Boolean, Number, String], default: false },
})

const emit = defineEmits(['update:open'])

const anchorRef = ref(null)
const panelRef = ref(null)
const openRef = ref(props.open)
let leaveTimer = null

watch(() => props.open, (value) => { openRef.value = value })

function setOpen (value) {
  if (openRef.value === value) return
  openRef.value = value
  emit('update:open', value)
}

function toggle () { setOpen(!openRef.value) }

function onAnchorClick () {
  if (props.trigger !== 'click') return
  toggle()
}

/** Hover: the 120 ms grace lets the pointer travel the `offset` gap without the panel vanishing. */
function cancelLeave () {
  if (leaveTimer === null) return
  clearTimeout(leaveTimer)
  leaveTimer = null
}

function onEnter () {
  if (props.trigger !== 'hover') return
  cancelLeave()
  setOpen(true)
}

function onLeave () {
  if (props.trigger !== 'hover') return
  cancelLeave()
  leaveTimer = setTimeout(() => { leaveTimer = null; setOpen(false) }, 120)
}

// The Teleport target, resolved as early as it can honestly be. `#core-overlays` is the LAST child
// of `.core-root` (§37.3), so calling overlayTarget() during the first render would CREATE a second
// element with that id — hence a lookup-only read here, with overlayTarget() kept as the mounted
// fallback for the case where the element really was not there yet. Resolving at setup matters for
// a popup that is created already open: swapping the target after mount MOVES the panel, and moving
// a focused node blurs it.
const teleportTo = ref(typeof document === 'undefined' ? 'body' : document.getElementById('core-overlays') || 'body')
onMounted(() => { if (teleportTo.value === 'body') teleportTo.value = overlayTarget() || 'body' })
const floating = useFloating(anchorRef, panelRef, openRef, () => ({
  placement: props.placement,
  offset: props.offset,
  matchWidth: props.matchWidth,
}))

useEscapeLayer(openRef, () => setOpen(false))
onClickOutside(() => [anchorRef, panelRef], () => {
  if (props.trigger === 'manual') return
  setOpen(false)
}, openRef)

onScopeDispose(cancelLeave)
defineExpose({ toggle, open: () => setOpen(true), close: () => setOpen(false) })
</script>

<template>
  <span
    ref="anchorRef"
    v-bind="$attrs"
    class="core-popover__anchor"
    @click="onAnchorClick"
    @mouseenter="onEnter"
    @mouseleave="onLeave"
  >
    <slot name="trigger" :open="openRef" :toggle="toggle" />
  </span>

  <Teleport :to="teleportTo">
    <Transition name="core-pop">
      <div
        v-if="openRef"
        ref="panelRef"
        class="core-popover"
        :class="'core-popover--' + floating.placement.value"
        :style="floating.style"
        v-bind="blurAttr(blur)"
        @mouseenter="onEnter"
        @mouseleave="onLeave"
      >
        <slot />
      </div>
    </Transition>
  </Teleport>
</template>
