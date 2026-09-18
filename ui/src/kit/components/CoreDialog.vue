<script setup>
// CoreDialog — the modal of the kit (DESIGN §37.5, Feedback; the skin of AlertDialog / InputDialog
// / Menu, §37.6). Three non-obvious decisions:
//   * one wrapper, two jobs — it is the `.core-backdrop` when there is a scrim, a click-through
//     centring layer when there is not, and an unstyled div when the dialog renders in flow
//     (`:teleport="false" :backdrop="false"`), so the panel markup exists exactly once;
//   * Escape goes through the kit's layer stack (use.js), never through a window listener of its
//     own: a popover opened inside the dialog must eat the first Escape (§37.4);
//   * `persistent` and `closable: false` still REGISTER the layer — swallowing Escape is the
//     point, otherwise the store would close the page behind the modal.
// `escape: false` / `trap: false` / `role` exist for the shell's built-ins (§37.6), where store.js
// owns Escape and the widget owns focus and Tab; all three default to today's behaviour.
import { computed, onMounted, ref, useAttrs, useSlots } from 'vue'
import { TONES, oneOf, toneClass, blurAttr, overlayTarget, useEscapeLayer, useFocusTrap, useId } from '../use.js'

defineOptions({ inheritAttrs: false })

const props = defineProps({
  /** `v-model:open`. */
  open: { type: Boolean, default: false },
  /** Display-voice headline. */
  title: { type: String, default: '' },
  /** Eyebrow-voice line under the title. */
  subtitle: { type: String, default: '' },
  /** Registry name or raw path — drawn in a 40 px tone tile in front of the title. */
  icon: { type: String, default: '' },
  /** Colours the top line and the icon tile. */
  tone: { type: String, default: 'accent', validator: oneOf(TONES) },
  /** 360 / 460 / 640 / 860 px. */
  size: { type: String, default: 'md', validator: oneOf(['sm', 'md', 'lg', 'xl']) },
  /** false: no ✕, no Escape, no backdrop click — the footer buttons are the only way out. */
  closable: { type: Boolean, default: true },
  /** Keeps Escape and the backdrop click from closing it; the ✕ and the footer still work. */
  persistent: { type: Boolean, default: false },
  /** false: no scrim (the dialog floats over a page that stays usable). */
  backdrop: { type: Boolean, default: true },
  /** §32 glass: `true` or a blur radius in px. */
  blur: { type: [Boolean, Number, String], default: true },
  /** false: render where it is written instead of in `#core-overlays`. */
  teleport: { type: Boolean, default: true },
  /** false: register no Escape layer at all — someone else (store.js, §7.3) owns the key. */
  escape: { type: Boolean, default: true },
  /** false: no focus trap — the caller focuses and cycles Tab itself (the shell's modals). */
  trap: { type: Boolean, default: true },
  /** `dialog` | `alertdialog` — the ARIA role of the panel. */
  role: { type: String, default: 'dialog', validator: oneOf(['dialog', 'alertdialog']) },
})

const emit = defineEmits(['update:open', 'close'])
const slots = useSlots()
const attrs = useAttrs()

// One v-bind per element: the caller's attrs and the §32 glass attribute travel together.
const panelBind = computed(() => Object.assign({}, attrs, blurAttr(props.blur)))

const panelRef = ref(null)
const titleId = useId('core-dialog-title')
const isOpen = computed(() => props.open)

/** A wrapper is needed for anything that floats; only the fully inline case goes without one. */
const layered = computed(() => props.backdrop || props.teleport)

// The Teleport target, resolved as early as it can honestly be. `#core-overlays` is the LAST child
// of `.core-root` (§37.3), so calling overlayTarget() during the first render would CREATE a second
// element with that id — hence a lookup-only read here, with overlayTarget() kept as the mounted
// fallback for the case where the element really was not there yet. Resolving at setup matters for
// a popup that is created already open: swapping the target after mount MOVES the panel, and moving
// a focused node blurs it.
const teleportTo = ref(typeof document === 'undefined' ? 'body' : document.getElementById('core-overlays') || 'body')
onMounted(() => { if (teleportTo.value === 'body') teleportTo.value = overlayTarget() || 'body' })
const hasHeader = computed(() => Boolean(slots.header || props.title || props.subtitle || props.icon || props.closable))

function close (reason) {
  emit('update:open', false)
  emit('close', reason)
}

/** Escape and the backdrop are the "soft" ways out; `persistent` blocks both, the ✕ is exempt. */
function requestClose (reason) {
  if (!props.closable || props.persistent) return
  close(reason)
}

function onBackdropDown (event) {
  if (!props.backdrop) return
  if (event.button !== undefined && event.button !== 0) return
  requestClose('backdrop')
}

// Both layers are opt-out (never conditional calls: the flags stay reactive this way).
useEscapeLayer(computed(() => props.escape && isOpen.value), () => requestClose('escape'))
useFocusTrap(panelRef, computed(() => props.trap && isOpen.value))
</script>

<template>
  <Teleport :to="teleportTo" :disabled="!teleport">
    <Transition name="core-fade">
      <div
        v-if="open"
        :class="layered ? ['core-backdrop', backdrop ? null : 'core-backdrop--clear'] : null"
        @pointerdown.self="onBackdropDown"
      >
        <Transition name="core-pop" appear>
          <div
            ref="panelRef"
            v-bind="panelBind"
            class="core-dialog"
            :class="[toneClass(tone), 'core-dialog--' + size]"
            :role="role"
            aria-modal="true"
            :aria-labelledby="title ? titleId : undefined"
          >
            <div v-if="hasHeader" class="core-dialog__header">
              <slot name="header">
                <span v-if="icon" class="core-dialog__icontile">
                  <CoreIcon :name="icon" size="lg" />
                </span>
                <div class="core-dialog__titles">
                  <h2 v-if="title" :id="titleId" class="core-dialog__title">{{ title }}</h2>
                  <p v-if="subtitle" class="core-dialog__subtitle">{{ subtitle }}</p>
                </div>
              </slot>
              <button
                v-if="closable"
                type="button"
                class="core-dialog__close"
                aria-label="Close"
                @click="close('button')"
              >
                <CoreIcon name="close" size="sm" />
              </button>
            </div>

            <div class="core-dialog__body core-scroll">
              <slot />
            </div>

            <div v-if="$slots.footer" class="core-dialog__footer">
              <slot name="footer" />
            </div>
          </div>
        </Transition>
      </div>
    </Transition>
  </Teleport>
</template>
