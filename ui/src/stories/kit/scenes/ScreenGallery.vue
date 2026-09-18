<script setup>
// ScreenGallery — CoreScreen as the inventory frame of mockup 3, rebuilt with plain placeholders
// (DESIGN §37.5, Surfaces). The nav row is deliberately spans and not CoreTabs: a gallery only
// depends on its own group plus CoreIcon, so what is on screen is this component and nothing else.
// CoreScreen is absolute/inset-0, so each demo lives in a relative box of a fixed size.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'
import keyart from '../assets/keyart.jpg'

const TABS = ['Map', 'Inventory', 'Character', 'Skills', 'Journal']
const ACTIVE = 'Inventory'

const FRAME = 'position: relative; width: 1500px; height: 820px; overflow: hidden; '
  + 'border-radius: var(--radius-ui); border: 1px solid var(--color-border)'
const SMALL = 'position: relative; width: 560px; height: 300px; overflow: hidden; '
  + 'border-radius: var(--radius-ui); border: 1px solid var(--color-border)'
// A header-only strip, with a coral hairline drawn down the middle so `center` can be checked
// against the real centre of the box rather than against the eye.
const STRIP = 'position: relative; width: 100%; height: 78px; overflow: hidden; '
  + 'border-radius: var(--radius-ui); border: 1px solid var(--color-border)'

const TAB = 'font-family: var(--font-display); font-weight: 600; font-size: 15px; text-transform: uppercase; '
  + 'letter-spacing: var(--tracking-label); padding: 8px 2px'
</script>

<template>
  <KitStage
    title="CoreScreen"
    :width="1560"
    description="The full-page scaffold: a CoreBackground at z 0 and header / body / footer above it. The header
      is 76 px with brand, nav and status; the body takes the rest; the footer is 64 px over 90 % ink. Both bars
      only exist when one of their slots is filled, so a page pays for what it uses."
  >
    <KitSection label="Mockup 3 — the inventory frame" layout="column" :gap="0"
      note="brand / nav / status in the header, three panels in the body, footer text left and right.">
      <div :style="FRAME">
        <CoreScreen background="scrim" :image="keyart" :dim="0.7" nav-align="center">
          <template #brand>
            <CoreBrand size="sm" name="Wayfinder">
              <template #logo>
                <svg viewBox="0 0 24 24" aria-hidden="true">
                  <path d="M12 2 23 21 1 21Z M12 9.6 6.4 19.2 17.6 19.2Z" fill="currentColor" fill-rule="evenodd" />
                  <path d="M15.2 9.4 23 21 7.4 21Z" style="fill: var(--color-ink)" opacity="0.62" />
                </svg>
              </template>
            </CoreBrand>
            <CoreTagline
              style="margin-left: 26px"
              :lines="['Explore  Drive', 'Survive  Belong']"
            />
          </template>

          <template #nav>
            <div class="flex items-center" style="gap: 34px">
              <span
                v-for="tab in TABS"
                :key="tab"
                :style="TAB + '; color: ' + (tab === ACTIVE ? 'var(--color-fg)' : 'var(--color-fg-dim)')"
              >
                {{ tab }}
                <CoreDash v-if="tab === ACTIVE" :width="'100%'" style="margin-top: 8px" />
              </span>
            </div>
          </template>

          <template #status>
            <CoreTagline rule="accent" :lines="['Worlds', 'Are better', 'With stories.']" />
          </template>

          <div class="flex" style="gap: 20px; height: 100%; min-height: 0">
            <CorePanel title="Filters" heading-size="sm" padding="sm" style="width: 268px">
              <p class="core-text">Sidebar placeholder.</p>
            </CorePanel>

            <CorePanel title="Inventory" subtitle="Gear up for what's next." heading-size="lg" padding="lg" style="flex: 1 1 auto">
              <p class="core-text">Grid placeholder — CoreSlotGrid lives in the Game group.</p>
              <template #footer>
                <CoreIcon name="backpack" size="sm" />
                <span class="core-label">Inventory capacity</span>
                <span class="core-num text-ui-sm" style="margin-left: auto; color: var(--color-fg)">18.5 / 30.0</span>
              </template>
            </CorePanel>

            <CorePanel title="Med Kit" subtitle="Common &middot; Consumable" padding="lg" accent style="width: 380px">
              <template #actions>
                <div style="text-align: right">
                  <p class="core-num" style="font-size: 22px; color: var(--color-fg)">3 / 10</p>
                  <p class="core-label" style="margin-top: 4px">In inventory</p>
                </div>
              </template>
              <p class="core-text">Detail placeholder.</p>
            </CorePanel>
          </div>

          <template #footer-start>
            <span class="core-label" style="color: var(--color-fg)">Wayfinder</span>
            <CoreDivider vertical style="height: 14px" />
            <span class="text-ui-sm text-fg-faint">v1.0</span>
          </template>
          <template #footer-end>
            <span class="core-label">Built for worlds yet to be explored.</span>
            <CoreDash :width="34" />
          </template>
        </CoreScreen>
      </div>
    </KitSection>

    <KitSection label="navAlign" layout="column" :gap="16"
      note="space shares the leftover room (the nav centres BETWEEN brand and status) · center pins the nav to
        the middle of the screen however wide the two ends are (mockup 3) · start hangs it off the brand (mockup 4).">
      <div v-for="align in ['space', 'center', 'start']" :key="align" style="width: 100%">
        <div :style="STRIP">
          <CoreScreen background="top" :image="keyart" :dim="0.92" :fade="1" :nav-align="align">
            <template #brand><CoreBrand size="sm" name="Wayfinder" /></template>
            <template #nav>
              <div class="flex items-center" style="gap: 28px">
                <span v-for="tab in TABS" :key="tab" :style="TAB + '; color: var(--color-fg-dim)'">{{ tab }}</span>
              </div>
            </template>
            <template #status><CoreTagline rule="accent" :lines="['Worlds']" /></template>
          </CoreScreen>
          <div style="position: absolute; left: 50%; top: 0; bottom: 0; z-index: 2; width: 1px; background: var(--color-accent); opacity: 0.5"></div>
        </div>
        <p class="core-label" style="margin-top: 10px; color: var(--color-fg)">nav-align="{{ align }}"</p>
      </div>
    </KitSection>

    <KitSection label="Bars only when a slot is filled" layout="row" :gap="20"
      note="No brand/nav/status = no header; no footer-start/-end = no footer. padded=false is full bleed.">
      <div :style="SMALL">
        <CoreScreen background="vignette" :image="keyart">
          <CorePanel title="Body only" subtitle="No header, no footer">
            <p class="core-text">A dialog page, a shard, a prompt screen.</p>
          </CorePanel>
        </CoreScreen>
      </div>

      <div :style="SMALL">
        <CoreScreen background="bars" :image="keyart" :padded="false">
          <template #brand><CoreBrand size="sm" name="Wayfinder" /></template>
          <template #footer-end>
            <span class="core-label">padded=false — the body bleeds to the edges</span>
          </template>
          <div style="flex: 1 1 auto; background: var(--color-panel-sunken)"></div>
        </CoreScreen>
      </div>
    </KitSection>
  </KitStage>
</template>
