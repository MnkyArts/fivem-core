<script setup>
// CoreTooltip gallery (DESIGN §37.5, Feedback). Two shapes: the one-line hint and the rich item
// card the inventory hangs off a slot. The bubble never takes the mouse, so hovering "through" it
// is impossible and it cannot flicker on its own edge; focus shows it without waiting for `delay`.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'
import medkit from '../assets/item-medkit.jpg'

const PLACEMENTS = ['top', 'top-start', 'bottom', 'bottom-end', 'left', 'left-start', 'right', 'right-end']
</script>

<template>
  <KitStage
    title="Tooltip"
    description="Ink 96 %, a strong hairline, 13 px — the smallest surface in the kit. It appears after `delay` on
      hover, at once on focus, and goes away on leave, blur, Escape or any press."
  >
    <KitSection label="Placements" layout="grid" :columns="4" :gap="12" note="delay 0 here so a screenshot can catch one">
      <CoreTooltip
        v-for="p in PLACEMENTS"
        :key="p"
        :placement="p"
        :delay="0"
        :text="'Placed ' + p + ' of its trigger.'"
        style="width: 100%"
      >
        <CoreButton size="sm" variant="secondary" block>{{ p }}</CoreButton>
      </CoreTooltip>
    </KitSection>

    <KitSection label="Delay" :gap="12" note="350 ms is the default: long enough that a pointer crossing the screen never trips it">
      <CoreTooltip :delay="0" text="Instant — for a dense toolbar where the player is already reading.">
        <CoreButton size="sm" variant="ghost" icon="bolt">0 ms</CoreButton>
      </CoreTooltip>
      <CoreTooltip text="The default. Rest on a control and it explains itself.">
        <CoreButton size="sm" variant="ghost" icon="clock">350 ms</CoreButton>
      </CoreTooltip>
      <CoreTooltip :delay="900" text="Almost a deliberate ask — for a hint nobody needs twice.">
        <CoreButton size="sm" variant="ghost" icon="help">900 ms</CoreButton>
      </CoreTooltip>
      <CoreTooltip disabled text="You will never see this.">
        <CoreButton size="sm" variant="ghost" icon="eye-off" disabled>disabled</CoreButton>
      </CoreTooltip>
    </KitSection>

    <KitSection label="On anything" :gap="14" note="the wrapper is an inline-flex span, so it never changes the trigger's layout">
      <CoreTooltip text="Health — regenerates to 50 % out of combat.">
        <CoreIcon name="heart" size="lg" style="color: var(--color-health)" />
      </CoreTooltip>
      <CoreTooltip text="Armour — absorbs damage before health does.">
        <CoreIcon name="shield" size="lg" style="color: var(--color-armour)" />
      </CoreTooltip>
      <CoreTooltip text="Crew rank 4 — quartermaster.">
        <span class="core-label" style="margin: 0; color: var(--color-fg); text-decoration: underline dotted">Marek Novak</span>
      </CoreTooltip>
      <CoreTooltip text="Tab to me: focus shows the bubble without waiting for the delay.">
        <CoreButton size="sm">Keyboard</CoreButton>
      </CoreTooltip>
    </KitSection>

    <KitSection label="Rich content" :gap="12" note="the `content` slot: 12 px padding, 280 px wide — the inventory's item card">
      <CoreTooltip :delay="0" placement="right">
        <button
          type="button"
          class="core-focusable"
          style="width: 92px; height: 92px; padding: 10px; border: 1px solid var(--color-border);
            border-radius: var(--radius-ui-sm); background: var(--color-panel-raise)"
        >
          <img :src="medkit" alt="Med Kit" style="width: 100%; height: 100%; object-fit: contain" />
        </button>
        <template #content>
          <p class="core-title" style="font-size: 18px">Med Kit</p>
          <p class="core-eyebrow" style="margin: 7px 0 10px; font-size: 11px">Common · Consumable</p>
          <div class="flex items-center justify-between" style="padding: 8px 0; border-top: 1px solid var(--color-border)">
            <span class="flex items-center" style="gap: 8px">
              <CoreIcon name="heart" size="sm" style="color: var(--color-health)" />
              <span class="core-label" style="margin: 0">Health restore</span>
            </span>
            <span class="core-num" style="font-size: 16px; color: var(--color-fg)">+75</span>
          </div>
          <div class="flex items-center justify-between" style="padding: 8px 0; border-top: 1px solid var(--color-border)">
            <span class="flex items-center" style="gap: 8px">
              <CoreIcon name="weight" size="sm" style="color: var(--color-fg-faint)" />
              <span class="core-label" style="margin: 0">Weight</span>
            </span>
            <span class="core-num" style="font-size: 16px; color: var(--color-fg)">1.2</span>
          </div>
          <p class="core-flavor" style="margin: 10px 0 0">A small kit. A second chance.</p>
        </template>
      </CoreTooltip>
    </KitSection>
  </KitStage>
</template>
