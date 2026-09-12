<script setup>
// DESIGN.md §7.4: usePage(id) -> the reactive props Lua sent to Core.UI.open, plus
// emit(event, data) / on(event, fn) / close() scoped to this page. CoreUI.hud is the
// read-only HUD snapshot (cash, bank, name, serverId, faction). Imports from 'vue' work.
const { props, emit, on, close } = window.CoreUI.usePage('my_plugin')
const hud = window.CoreUI.hud || {}

on('hello', (data) => console.log('my_plugin: from Lua ->', data))   // Core.UI.send(...)
</script>

<template>
    <div class="panel">
        <h1>my_plugin</h1>
        <p>{{ hud.name || 'nobody' }} — {{ props.title || 'props from Lua show up here' }}</p>
        <button @click="emit('hello', { at: Date.now() })">Send an event</button>
        <button @click="close()">Close</button>
    </div>
</template>

<style scoped>
/* Shell palette: panel rgba(14,16,20,.86), hairline rgba(255,255,255,.08), accent #5b8cff, text #e8eaf0. */
.panel { position: fixed; inset: 0; margin: auto; width: 380px; height: fit-content; padding: 18px;
    border: 1px solid rgba(255, 255, 255, .08); border-radius: 8px; background: rgba(14, 16, 20, .86);
    color: #e8eaf0; font-family: 'Segoe UI', system-ui, sans-serif; pointer-events: auto; }
h1 { margin: 0 0 8px; font-size: 15px; }
button { margin-right: 8px; padding: 7px 11px; border: 0; border-radius: 6px; background: #5b8cff;
    color: #0b0d11; font: inherit; font-weight: 600; cursor: pointer; }
</style>
