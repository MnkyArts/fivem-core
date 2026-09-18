<script setup>
// KeyGallery — CoreKey and CoreKeyHint: both cap variants, the three sizes, wide labels, the
// mouse glyphs, the pressed state and a hold-to-confirm cap that really runs (rAF, so the
// progress binding is exercised the way a client drives it — per frame, with no transition).
import { onBeforeUnmount, onMounted, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const hold = ref(0)
let raf = 0
let start = 0

function tick (now) {
  if (!start) start = now
  hold.value = ((now - start) % 2000) / 1600
  if (hold.value > 1) hold.value = 1
  raf = window.requestAnimationFrame(tick)
}

onMounted(() => { raf = window.requestAnimationFrame(tick) })
onBeforeUnmount(() => { if (raf) window.cancelAnimationFrame(raf) })

const MOUSE = ['mouse', 'mouse-left', 'mouse-right', 'mouse-middle', 'mouse-scroll']
const WIDE = ['F', 'R', 'TAB', 'ESC', 'SHIFT', 'SPACE', 'ENTER', 'LEFT ALT']

const label = { display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '9px', width: '112px' }
</script>

<template>
  <KitStage
    title="CoreKey · CoreKeyHint"
    description="A key cap is a solid near-white tile with dark condensed text; a mouse button is a line glyph
      at the same height, with no tile at all. A wide label grows the cap sideways — the height never changes."
  >
    <KitSection label="Variants" :gap="26">
      <div :style="label">
        <CoreKey label="F" />
        <span class="text-ui-xs text-fg-faint">solid — the default</span>
      </div>
      <div :style="label">
        <CoreKey label="F" variant="outline" />
        <span class="text-ui-xs text-fg-faint">outline</span>
      </div>
      <div :style="label">
        <CoreKey label="F" pressed />
        <span class="text-ui-xs text-fg-faint">pressed</span>
      </div>
      <div :style="label">
        <span class="core-key">F</span>
        <span class="text-ui-xs text-fg-faint">bare class</span>
      </div>
    </KitSection>

    <KitSection label="Sizes" :gap="26" note="20 / 26 / 32 px cap height; the lg cap is the one a prompt uses.">
      <div v-for="size in ['sm', 'md', 'lg']" :key="size" :style="label">
        <CoreKey label="E" :size="size" />
        <span class="text-ui-xs text-fg-faint">{{ size }}</span>
      </div>
      <div v-for="size in ['sm', 'md', 'lg']" :key="'esc-' + size" :style="label">
        <CoreKey label="ESC" :size="size" />
        <span class="text-ui-xs text-fg-faint">ESC · {{ size }}</span>
      </div>
    </KitSection>

    <KitSection label="Wide labels" :gap="12" note="min-width keeps the square; the padding does the rest.">
      <CoreKey v-for="key in WIDE" :key="key" :label="key" />
    </KitSection>

    <KitSection label="Mouse glyphs" :gap="26" note="These five labels draw the glyph instead of a cap.">
      <div v-for="name in MOUSE" :key="name" :style="label">
        <CoreKey :label="name" />
        <span class="text-ui-xs text-fg-faint">{{ name }}</span>
      </div>
      <div :style="label">
        <CoreKey label="mouse-scroll" size="lg" />
        <span class="text-ui-xs text-fg-faint">lg</span>
      </div>
    </KitSection>

    <KitSection label="Hold to confirm" :gap="26"
                note="progress is bound straight to a transform — no transition, so a per-frame caller stays smooth.">
      <div v-for="p in [0.15, 0.4, 0.75, 1]" :key="p" :style="label">
        <CoreKey label="E" size="lg" :progress="p" />
        <span class="text-ui-xs text-fg-faint">{{ Math.round(p * 100) }} %</span>
      </div>
      <div :style="label">
        <CoreKey label="E" size="lg" :progress="hold" data-role="hold" />
        <span class="text-ui-xs text-fg-faint">running</span>
      </div>
      <div :style="label">
        <CoreKey label="E" size="lg" :progress="hold" pressed />
        <span class="text-ui-xs text-fg-faint">running · pressed</span>
      </div>
    </KitSection>

    <KitSection label="CoreKeyHint" layout="column" :gap="14"
                note="Cap(s) plus a caption in display voice — `keys` takes one key or a list.">
      <CoreKeyHint keys="ESC" label="Back" />
      <CoreKeyHint keys="F" label="Enter vehicle" />
      <CoreKeyHint :keys="['SHIFT', 'F']" label="Enter as passenger" />
      <CoreKeyHint keys="mouse-right" label="Aim" />
      <CoreKeyHint k="G" label="Holster weapon" />
      <CoreKeyHint keys="TAB" label="Inventory" variant="outline" />
    </KitSection>

    <KitSection label="CoreKeyHint sizes" :gap="30">
      <CoreKeyHint keys="R" label="Recenter" size="sm" />
      <CoreKeyHint keys="R" label="Recenter" size="md" />
      <CoreKeyHint keys="R" label="Recenter" size="lg" />
    </KitSection>
  </KitStage>
</template>
