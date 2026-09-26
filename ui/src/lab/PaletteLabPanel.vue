<script setup>
// PaletteLabPanel — the floating control of the palette lab in kit-preview.html (DEV ONLY).
//
//   kit-preview.html?scene=ShowcaseMainMenu&palette=teal&roles=split
//   kit-preview.html?scene=ShowcaseInventory&palette=19b8a6&roles=select,controls,focus
//
// Applies to <html>, so teleported popups (select lists, context menus, dialogs) follow it too.
// Every change is mirrored into the URL with replaceState: a reload, a screenshot or a link you
// send keeps the exact palette. The panel's own checkboxes are kit components, so they re-tone
// with the "controls" role like everything else.
import { computed, onMounted, reactive, watch } from 'vue'
import { MIXES, PRESETS, ROLES, applyLab, installLab, isHex, mixOf, paletteVars, resolvePalette, resolveRoles } from './palette.js'

const params = new URLSearchParams(window.location.search)
const state = reactive({
  palette: params.get('palette') || 'teal',
  roles: resolveRoles(params.get('roles')),
  custom: '#19b8a6',
  open: params.get('lab') !== 'min',
})
if (isHex(state.palette)) state.custom = '#' + state.palette.replace(/^#/, '')

const palette = computed(() => (state.palette === 'off' ? null : resolvePalette(state.palette)))
const mix = computed(() => MIXES.find((m) => m.id === mixOf(state.roles)) || null)
const ratio = computed(() => (palette.value ? paletteVars(palette.value).contrast.toFixed(1) : ''))

function sync () {
  applyLab(document.documentElement, state.palette, state.roles)
  const url = new URL(window.location.href)
  url.searchParams.set('palette', state.palette.replace(/^#/, ''))
  url.searchParams.set('roles', mixOf(state.roles) || state.roles.join(','))
  window.history.replaceState(null, '', url)
}

function pickCustom (event) {
  state.custom = event.target.value
  state.palette = state.custom
}

onMounted(() => { installLab(); sync() })
watch(() => [state.palette, state.roles.slice()], sync)

const box = {
  position: 'fixed',
  right: '16px',
  bottom: '16px',
  zIndex: '2147483000',
  width: '316px',
  maxHeight: 'calc(100vh - 32px)',
  overflowY: 'auto',
  padding: '14px 16px 16px',
  border: '1px solid var(--color-border-strong)',
  borderRadius: 'var(--radius-ui)',
  background: 'var(--color-panel-popup)',
  boxShadow: 'var(--shadow-ui-lg)',
  color: 'var(--color-fg)',
  pointerEvents: 'auto',
}
const chip = (active) => ({
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  gap: '5px',
  padding: '6px 2px 5px',
  border: '1px solid ' + (active ? 'var(--color-fg)' : 'var(--color-border)'),
  borderRadius: 'var(--radius-ui-sm)',
  background: active ? 'rgba(255, 255, 255, 0.08)' : 'transparent',
  color: active ? 'var(--color-fg)' : 'var(--color-fg-dim)',
  font: '600 11px/1 var(--font-display)',
  letterSpacing: '0.08em',
  textTransform: 'uppercase',
  cursor: 'pointer',
})
const dot = (color) => ({
  width: '22px',
  height: '22px',
  borderRadius: '50%',
  background: color,
  boxShadow: 'inset 0 0 0 1px rgba(255, 255, 255, 0.18)',
})
const label = { margin: '14px 0 8px' }
const note = { margin: '10px 0 0', fontSize: 'var(--text-ui-sm)', lineHeight: '1.45', color: 'var(--color-fg-dim)' }
</script>

<template>
  <div v-if="!state.open" :style="box" style="width: auto; padding: 8px 12px; cursor: pointer" @click="state.open = true">
    <span class="core-label">Palette lab ▸</span>
  </div>
  <div v-else :style="box">
    <div style="display: flex; align-items: center; justify-content: space-between">
      <span class="core-label" style="color: var(--color-fg)">Palette lab</span>
      <button
        type="button"
        class="core-label"
        style="background: none; border: 0; cursor: pointer; color: var(--color-fg-dim)"
        @click="state.open = false"
      >hide</button>
    </div>

    <p class="core-label" :style="label">Second colour</p>
    <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 6px">
      <button type="button" :style="chip(state.palette === 'off')" @click="state.palette = 'off'">
        <span :style="dot('var(--lab1, var(--color-accent))')"></span>Off
      </button>
      <button
        v-for="p in PRESETS"
        :key="p.id"
        type="button"
        :style="chip(state.palette === p.id)"
        @click="state.palette = p.id"
      >
        <span :style="dot(p.base)"></span>{{ p.name }}
      </button>
      <label :style="chip(palette && palette.id === 'custom')" style="position: relative">
        <span :style="dot(state.custom)"></span>Custom
        <input
          type="color"
          :value="state.custom"
          style="position: absolute; inset: 0; width: 100%; height: 100%; opacity: 0; cursor: pointer"
          @input="pickCustom"
        >
      </label>
    </div>
    <p v-if="palette" :style="note">
      <b style="color: var(--color-fg)">{{ palette.name }}</b> {{ palette.base }} — {{ palette.note }}
      Text on a fill: {{ ratio }}:1.
    </p>
    <p v-else :style="note">The kit as it ships: coral for every job.</p>

    <p class="core-label" :style="label">How much it takes over</p>
    <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 6px">
      <button
        v-for="m in MIXES"
        :key="m.id"
        type="button"
        :style="chip(mix && mix.id === m.id)"
        style="padding: 9px 2px"
        @click="state.roles = m.roles.slice()"
      >{{ m.name }}</button>
    </div>
    <p :style="note">{{ mix ? mix.note : 'Custom mix.' }}</p>

    <p class="core-label" :style="label">Roles on the second colour</p>
    <div style="display: flex; flex-direction: column; gap: 8px">
      <CoreCheckbox
        v-for="r in ROLES"
        :key="r.id"
        v-model="state.roles"
        :value="r.id"
        size="sm"
        :label="r.name"
        :description="r.hint"
      />
    </div>
    <p :style="note">Always coral: the brand marks — dash, <b>//</b> heading marker, tagline rule, panel top line, logo.</p>
  </div>
</template>
