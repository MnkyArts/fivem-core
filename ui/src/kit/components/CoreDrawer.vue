<script setup>
// CoreDrawer — side sheet (DESIGN §37.5, Feedback). Same mechanics as CoreDialog (one wrapper,
// the kit's Escape layer, a focus trap) with two differences: the panel is fixed to an edge over
// the full height, and it enters with the base.css slide that travels TOWARDS its own side —
// `core-slide-left` comes in from the right, so a right-hand drawer uses it.
// It has no `tone` prop (§37.5), so the coral top line is pinned to the accent tone class.
import { computed, onMounted, ref, useAttrs, useSlots } from 'vue'
import { oneOf, blurAttr, overlayTarget, useEscapeLayer, useFocusTrap, useId } from '../use.js'

defineOptions({ inheritAttrs: false })

const props = defineProps({
  /** `v-model:open`. */
  open: { type: Boolean, default: false },
  /** Which edge the sheet is pinned to. */
  side: { type: String, default: 'right', validator: oneOf(['right', 'left']) },
  /** Sheet width in px (or any CSS length as a string). */
  width: { type: [Number, String], default: 420 },
  /** Display-voice headline. */
  title: { type: String, default: '' },
  /** Eyebrow-voice line under the title. */
  subtitle: { type: String, default: '' },
  /** false: no ✕, no Escape, no backdrop click. */
  closable: { type: Boolean, default: true },
  /** false: no scrim — the page behind the sheet stays usable. */
  backdrop: { type: Boolean, default: true },
  /** §32 glass: `true` or a blur radius in px. */
  blur: { type: [Boolean, Number, String], default: true },
  /** false: render where it is written instead of in `#core-overlays`. */
  teleport: { type: Boolean, default: true },
})

const emit = defineEmits(['update:open', 'close'])
const slots = useSlots()
const attrs = useAttrs()

// One v-bind per element: the caller's attrs and the §32 glass attribute travel together.
const panelBind = computed(() => Object.assign({}, attrs, blurAttr(props.blur)))

const panelRef = ref(null)
const titleId = useId('core-drawer-title')
const isOpen = computed(() => props.open)

// The Teleport target, resolved as early as it can honestly be. `#core-overlays` is the LAST child
// of `.core-root` (§37.3), so calling overlayTarget() during the first render would CREATE a second
// element with that id — hence a lookup-only read here, with overlayTarget() kept as the mounted
// fallback for the case where the element really was not there yet. Resolving at setup matters for
// a popup that is created already open: swapping the target after mount MOVES the panel, and moving
// a focused node blurs it.
const teleportTo = ref(typeof document === 'undefined' ? 'body' : document.getElementById('core-overlays') || 'body')
onMounted(() => { if (teleportTo.value === 'body') teleportTo.value = overlayTarget() || 'body' })
const transitionName = computed(() => (props.side === 'left' ? 'core-slide-right' : 'core-slide-left'))
const panelStyle = computed(() => ({ width: typeof props.width === 'number' ? props.width + 'px' : String(props.width) }))
const hasHeader = computed(() => Boolean(slots.header || props.title || props.subtitle || props.closable))

function close (reason) {
  emit('update:open', false)
  emit('close', reason)
}

function requestClose (reason) {
  if (!props.closable) return
  close(reason)
}

function onBackdropDown (event) {
  if (!props.backdrop) return
  if (event.button !== undefined && event.button !== 0) return
  requestClose('backdrop')
}

useEscapeLayer(isOpen, () => requestClose('escape'))
useFocusTrap(panelRef, isOpen)
</script>

<template>
  <Teleport :to="teleportTo" :disabled="!teleport">
    <Transition name="core-fade">
      <div
        v-if="open"
        :class="['core-backdrop', backdrop ? null : 'core-backdrop--clear']"
        @pointerdown.self="onBackdropDown"
      >
        <Transition :name="transitionName" appear>
          <div
            ref="panelRef"
            v-bind="panelBind"
            class="core-drawer core-tone-accent"
            :class="'core-drawer--' + side"
            :style="panelStyle"
            role="dialog"
            aria-modal="true"
            :aria-labelledby="title ? titleId : undefined"
          >
            <div v-if="hasHeader" class="core-drawer__header">
              <slot name="header">
                <div class="core-drawer__titles">
                  <h2 v-if="title" :id="titleId" class="core-drawer__title">{{ title }}</h2>
                  <p v-if="subtitle" class="core-drawer__subtitle">{{ subtitle }}</p>
                </div>
              </slot>
              <button
                v-if="closable"
                type="button"
                class="core-drawer__close"
                aria-label="Close"
                @click="close('button')"
              >
                <CoreIcon name="close" size="sm" />
              </button>
            </div>

            <div class="core-drawer__body core-scroll">
              <slot />
            </div>

            <div v-if="$slots.footer" class="core-drawer__footer">
              <slot name="footer" />
            </div>
          </div>
        </Transition>
      </div>
    </Transition>
  </Teleport>
</template>
