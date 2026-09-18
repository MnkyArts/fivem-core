<script setup>
// BrandGallery — CoreBrand and CoreTagline (DESIGN §37.5, Surfaces): the main-menu lockup of
// mockup 1 and the stacked, widely tracked words that sit beside a vertical rule in every screen
// header. The mark is the mockups' coral triangle, passed in as an inline SVG through the slot —
// that is how a server ships its own logo without a file in the bundle.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const SIZES = [
  ['sm', '22 px name, 32 px mark — a screen header'],
  ['md', '30 px name, 44 px mark — the default'],
  ['lg', '48 px name, 70 px mark — the main menu'],
  ['xl', '64 px name, 90 px mark — a splash screen'],
]
</script>

<template>
  <KitStage
    title="CoreBrand &amp; CoreTagline"
    :width="1080"
    description="The logo lockup and the stacked tagline. The brand renders no mark box at all when there is
      neither a logo nor a slot, so a server with no art still gets a clean wordmark; the tagline puts its words
      on a 0.3 em track at line-height 1.75 beside a hairline or the coral rule of mockups 3 and 4."
  >
    <KitSection label="Mockup 1 — the main menu lockup" layout="column" :gap="0">
      <CoreBrand size="lg" name="Wayfinder" tagline="Explore a larger tomorrow">
        <template #logo>
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M12 2 23 21 1 21Z M12 9.6 6.4 19.2 17.6 19.2Z" fill="currentColor" fill-rule="evenodd" />
            <path d="M15.2 9.4 23 21 7.4 21Z" style="fill: var(--color-ink)" opacity="0.62" />
          </svg>
        </template>
      </CoreBrand>
    </KitSection>

    <KitSection label="Brand sizes" layout="column" :gap="28" note="The mark scales with the wordmark.">
      <div v-for="[size, note] in SIZES" :key="size" class="flex items-center" style="gap: 28px">
        <CoreBrand :size="size" name="Wayfinder" tagline="Explore a larger tomorrow">
          <template #logo>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M12 2 23 21 1 21Z M12 9.6 6.4 19.2 17.6 19.2Z" fill="currentColor" fill-rule="evenodd" />
              <path d="M15.2 9.4 23 21 7.4 21Z" style="fill: var(--color-ink)" opacity="0.62" />
            </svg>
          </template>
        </CoreBrand>
        <span class="text-ui-xs text-fg-faint">{{ note }}</span>
      </div>
    </KitSection>

    <KitSection label="Without a mark, without a tagline" layout="row" :gap="46"
      note="No logo and no slot: only the name, flush with its column.">
      <CoreBrand name="Wayfinder" tagline="Explore a larger tomorrow" />
      <CoreBrand name="Wayfinder" />
      <CoreBrand size="sm" name="Wayfinder" />
    </KitSection>

    <KitSection label="Tagline" layout="row" :gap="64" note="lines · rule · dash · align.">
      <div>
        <CoreTagline :lines="['Explore', 'Survive', 'Belong']" />
        <p class="text-ui-xs text-fg-faint" style="margin-top: 14px">bare</p>
      </div>
      <div>
        <CoreTagline rule :lines="['Explore', 'Survive', 'Belong']" />
        <p class="text-ui-xs text-fg-faint" style="margin-top: 14px">rule — a hairline (mockup 1)</p>
      </div>
      <div>
        <CoreTagline rule="accent" :lines="['Worlds', 'Are better', 'With stories.']" />
        <p class="text-ui-xs text-fg-faint" style="margin-top: 14px">rule="accent" (mockups 3 and 4)</p>
      </div>
      <div>
        <CoreTagline rule dash :lines="['Explore', 'Survive', 'Belong']" />
        <p class="text-ui-xs text-fg-faint" style="margin-top: 14px">rule + dash</p>
      </div>
    </KitSection>

    <KitSection label="Tagline align" layout="grid" :columns="3" :gap="20"
      note="The tracking leaves a gap after the last letter; center and right pull it back so the block lines up.">
      <div v-for="align in ['left', 'center', 'right']" :key="align" class="core-panel" style="padding: 18px">
        <CoreTagline :align="align" dash :lines="['Explore', 'Survive', 'Belong']" />
        <p class="text-ui-xs text-fg-faint" style="margin-top: 14px">align="{{ align }}"</p>
      </div>
    </KitSection>

    <KitSection label="In place — the menu footer" layout="column" :gap="0">
      <div class="core-panel flex flex-row items-center justify-between" style="padding: 18px 24px; width: 100%">
        <CoreBrand size="sm" name="Wayfinder" tagline="v1.0" />
        <CoreTagline align="right" :lines="['Worlds are better with stories.']" dash />
      </div>
    </KitSection>
  </KitStage>
</template>
