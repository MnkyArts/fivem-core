<script setup>
// DESIGN.md §7.4: usePage(id) -> the reactive props Lua sent to Core.UI.open, plus
// emit(event, data) / on(event, fn) / close() scoped to this page. CoreUI.hud is the
// read-only HUD snapshot (cash, bank, name, serverId, faction). Imports from 'vue' work.
const { props, emit, on, close } = window.CoreUI.usePage('my_plugin')
const hud = window.CoreUI.hud || {}

on('hello', (data) => console.log('my_plugin: from Lua ->', data))   // Core.UI.send(...)
</script>

<template>
    <!-- Styling is Tailwind CSS v4 — nothing to install or configure: core's build scans
         <plugin>/ui/src and emits the utilities this file uses into its one bundle (README §3).
         Core's theme tokens (core/ui/src/styles.css), usable as normal utilities:
           colours  bg-panel bg-panel-solid bg-panel-raise border-border border-border-strong
                    bg-backdrop text-accent bg-accent-soft text-success text-error text-warning
                    text-info text-fg text-fg-dim text-fg-faint
           radius   rounded-ui rounded-ui-sm   shadow shadow-ui   easing ease-ui
           fonts    font-sans font-mono        sizes  text-ui text-ui-sm text-ui-xs
         Shared component classes: core-panel core-modal core-backdrop core-title core-text
         core-label core-btn (--primary/--ghost/--danger) core-field core-input core-select
         core-check core-key core-list core-item core-interactive.
         CSS backdrop filters stay banned (FiveM's CEF paints the filtered area as a solid black
         box). For a glass panel put `data-core-blur` on it instead — core draws a live, blurred
         copy of the game frame behind every element carrying it (README "Game blur (glass
         panels)"). Panels only, never list rows. -->
    <div class="pointer-events-none fixed inset-0 flex items-center justify-center font-sans text-fg">
        <section class="core-panel core-modal core-interactive w-[380px]" data-core-blur>
            <h1 class="core-title">my_plugin</h1>
            <p class="core-text mb-3">{{ hud.name || 'nobody' }} — {{ props.title || 'props from Lua show up here' }}</p>
            <div class="flex gap-2">
                <button class="core-btn core-btn--primary" @click="emit('hello', { at: Date.now() })">Send an
                    event</button>
                <button class="core-btn" @click="close()">Close</button>
            </div>
        </section>
    </div>
</template>
