<script setup>
// BackgroundGallery — every CoreBackground variant as a 16:9 tile over the key art, so the shape
// of each scrim is visible against a real picture (DESIGN §37.5, Surfaces).
// The component is absolute/inset-0, so each tile is a relative box it fills.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'
import keyart from '../assets/keyart.jpg'
import map from '../assets/map.jpg'

const VARIANTS = [
  ['vignette', 'the default — radial ink 25 % to 88 %'],
  ['left', 'the main menu: ink 94 % to 0 at 62 % of the width'],
  ['right', 'mirrored — a sidebar on the right'],
  ['top', 'under a screen header'],
  ['bottom', 'over a footer or a HUD'],
  ['bars', 'cinematic bands top and bottom'],
  ['scrim', 'flat — behind a dialog'],
  ['solid', '--color-ink, no game at all'],
  ['none', 'nothing: only the image layer and the slot'],
]

const DIMS = [0.25, 0.5, 0.75, 1]
const FADES = [0.25, 0.52, 0.75, 1]

const TILE = 'position: relative; overflow: hidden; border: 1px solid var(--color-border); '
  + 'border-radius: var(--radius-ui); height: 152px; background-size: cover; background-position: center'
</script>

<template>
  <KitStage
    title="CoreBackground"
    :width="1180"
    description="The scrim between the game and a full screen: absolute, inset 0, click-through, z 0. Every
      variant reads one number — the dim prop — so a page darkens with a single value, and the optional image
      layer sits under the scrim for key art, a map or a blurred still."
  >
    <KitSection label="Variants" layout="grid" :columns="3" :gap="16" note="Each tile is the key art with one variant over it.">
      <div v-for="[variant, note] in VARIANTS" :key="variant">
        <div :style="TILE + '; background-image: url(' + keyart + ')'">
          <CoreBackground :variant="variant" />
        </div>
        <p class="core-label" style="margin-top: 10px; color: var(--color-fg)">{{ variant }}</p>
        <p class="text-ui-xs text-fg-faint" style="margin-top: 4px">{{ note }}</p>
      </div>
    </KitSection>

    <KitSection label="dim" layout="grid" :columns="4" :gap="16" note="0-1 scales the variant's own strength.">
      <div v-for="d in DIMS" :key="d">
        <div :style="TILE + '; background-image: url(' + keyart + ')'">
          <CoreBackground variant="left" :dim="d" />
        </div>
        <p class="core-label" style="margin-top: 10px; color: var(--color-fg)">:dim="{{ d }}"</p>
      </div>
    </KitSection>

    <KitSection label="image and pattern" layout="grid" :columns="2" :gap="16"
      note="image paints under the scrim; pattern=&quot;grid&quot; lays a 40 px hairline grid over it.">
      <div>
        <div :style="TILE">
          <CoreBackground variant="vignette" :image="map" />
        </div>
        <p class="core-label" style="margin-top: 10px; color: var(--color-fg)">:image + vignette</p>
      </div>
      <div>
        <div :style="TILE">
          <CoreBackground variant="solid" pattern="grid" />
        </div>
        <p class="core-label" style="margin-top: 10px; color: var(--color-fg)">solid + pattern="grid"</p>
      </div>
    </KitSection>

    <KitSection label="fade" layout="grid" :columns="4" :gap="16"
      note="Where top / bottom / left / right reach transparent, as a fraction of the box — a short strip can
        dissolve over its whole height. Unset keeps the variant's own value (0.52; 0.62 for left and right).">
      <div v-for="f in FADES" :key="f">
        <div :style="TILE + '; background-image: url(' + keyart + ')'">
          <CoreBackground variant="top" :fade="f" />
        </div>
        <p class="core-label" style="margin-top: 10px; color: var(--color-fg)">:fade="{{ f }}"</p>
      </div>
    </KitSection>

    <KitSection label="Framing the picture" layout="grid" :columns="3" :gap="16"
      note="The image always covers, so position is what keeps a 4:3 key art's subject in view on a 16:9 page.">
      <div v-for="pos in ['center', 'center 18%', 'right center']" :key="pos">
        <div :style="TILE">
          <CoreBackground variant="vignette" :image="keyart" :position="pos" :dim="0.55" />
        </div>
        <p class="core-label" style="margin-top: 10px; color: var(--color-fg)">:position="{{ pos }}"</p>
      </div>
    </KitSection>

    <KitSection label="Extra layers" layout="column" :gap="12"
      note="The default slot goes over the scrim: a glow, a logo watermark, a second gradient.">
      <div :style="TILE + '; width: 100%; height: 190px; background-image: url(' + keyart + ')'">
        <CoreBackground variant="left" :dim="0.9">
          <div style="position: absolute; left: 40px; top: 44px">
            <CoreBrand size="md" name="Wayfinder" tagline="Explore a larger tomorrow" />
          </div>
        </CoreBackground>
      </div>
    </KitSection>
  </KitStage>
</template>
