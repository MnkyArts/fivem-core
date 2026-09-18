<script setup>
// SliderGallery — CoreSlider (DESIGN §37.5, Forms — choice).
// Two real jobs side by side: the character creator (a named range with end captions and no
// number) and the audio settings (a percentage read-out). `change` is what a creator would spend a
// ped re-render on, so the scene shows both counters — the live one and the committed one.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const face = ref({ nose: 34, jaw: 62, brow: 50, cheek: 44 })
const audio = ref({ master: 80, music: 45, radio: 65, voice: 90 })

const fov = ref(55)
const draw = ref(3)
const bounty = ref(2500)
const tones = ref(60)
const locked = ref(35)

const committed = ref(34)
const live = ref(34)

const FACE = [
  { key: 'nose', label: 'Nose width', min: 'Narrow', max: 'Wide' },
  { key: 'jaw', label: 'Jaw line', min: 'Soft', max: 'Square' },
  { key: 'brow', label: 'Brow height', min: 'Low', max: 'High' },
  { key: 'cheek', label: 'Cheek bones', min: 'Flat', max: 'Sharp' },
]

const AUDIO = [
  { key: 'master', label: 'Master' },
  { key: 'music', label: 'Music' },
  { key: 'radio', label: 'Car radio' },
  { key: 'voice', label: 'Voice chat' },
]

const TONES = ['accent', 'success', 'warning', 'danger', 'info', 'neutral']
const QUALITY = ['Lowest', 'Low', 'Normal', 'High', 'Ultra']
const money = (n) => '$' + Number(n).toLocaleString('en-US')

function onCommit(value) {
  committed.value = value
}
</script>

<template>
  <KitStage
    title="Slider"
    description="A real <input type='range'> painted through the ::-webkit-slider-* pseudo-elements. The fill is
      a two-stop gradient on the track cut at --core-slider-pct; the thumb is a 10 x 20 white tile that grows a
      tone-coloured halo on hover and while dragging."
  >
    <KitSection label="Character creator" layout="grid" :columns="2" :gap="30" note="minLabel / maxLabel under the ends, no number — the value is the face, not the digits">
      <CoreSlider
        v-for="f in FACE"
        :key="f.key"
        v-model="face[f.key]"
        :label="f.label"
        :min-label="f.min"
        :max-label="f.max"
      />
    </KitSection>

    <KitSection label="Audio settings" layout="column" :gap="22" note="showValue + suffix='%' — display 600, tabular, so the number never jitters while you drag">
      <CoreSlider
        v-for="a in AUDIO"
        :key="a.key"
        v-model="audio[a.key]"
        :label="a.label"
        show-value
        suffix="%"
        style="width: 520px"
      />
    </KitSection>

    <KitSection label="Ticks and formats" layout="column" :gap="26" note="ticks=true marks every step while there are at most 20 of them; `format` owns the read-out">
      <CoreSlider
        v-model="draw"
        :min="0"
        :max="4"
        :step="1"
        label="Draw distance"
        show-value
        ticks
        :format="(v) => QUALITY[v]"
        min-label="Lowest"
        max-label="Ultra"
        style="width: 520px"
      />
      <CoreSlider
        v-model="fov"
        :min="40"
        :max="90"
        label="Field of view"
        show-value
        :ticks="6"
        suffix="°"
        style="width: 520px"
      />
      <CoreSlider
        v-model="bounty"
        :min="500"
        :max="10000"
        :step="500"
        label="Bounty"
        show-value
        :format="money"
        min-label="$500"
        max-label="$10,000"
        style="width: 520px"
      />
    </KitSection>

    <KitSection label="Tones" layout="column" :gap="20" note="`tone` puts core-tone-* on the root; the fill and the thumb halo read var(--tone)">
      <CoreSlider
        v-for="t in TONES"
        :key="t"
        v-model="tones"
        :tone="t"
        :label="t"
        show-value
        suffix="%"
        style="width: 420px"
      />
    </KitSection>

    <KitSection label="input vs change" layout="column" :gap="12" note="update:modelValue fires on every pixel of the drag, `change` once on release — the expensive one">
      <CoreSlider
        v-model="live"
        label="Nose width"
        show-value
        min-label="Narrow"
        max-label="Wide"
        style="width: 520px"
        @change="onCommit"
      />
      <p class="core-label">live {{ live }} &nbsp;·&nbsp; committed {{ committed }}</p>
    </KitSection>

    <KitSection label="Disabled" layout="column" :gap="12" note="0.45 opacity, no halo, not-allowed — the value is still readable">
      <CoreSlider
        v-model="locked"
        label="Engine tuning"
        show-value
        suffix="%"
        disabled
        style="width: 420px"
      />
    </KitSection>
  </KitStage>
</template>
