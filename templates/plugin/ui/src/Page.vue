<script setup>
// my_plugin page — DESIGN.md §7.4 (the page protocol) and §37 (the UI kit).
//
// usePage(id) -> the reactive props Lua sent to Core.UI.open, plus emit(event, data) /
// on(event, fn) / close() scoped to this page. CoreUI.hud is the read-only HUD snapshot
// (cash, bank, name, serverId, faction). Imports from 'vue' resolve to the shell's one Vue.
import { ref } from 'vue'

// PageHost renders <YourPage :props="…">, so the attribute must not fall through to the root.
defineOptions({ name: 'MyPluginPage', inheritAttrs: false })

const { props, emit, on, close } = window.CoreUI.usePage('my_plugin')
const hud = window.CoreUI.hud || {}

const note = ref('')

on('hello', (data) => { note.value = (data && data.text) || '' })   // Core.UI.send(…)
</script>

<template>
    <!-- Every `<Core…>` tag is a UI kit component (DESIGN §37.5, README "Design system"):
         registered globally on the shell's Vue app, so a page imports nothing. Compose the
         page from them instead of styling your own boxes — that is what makes every plugin
         look like one product. Custom CSS only for what the kit lacks, and then with the
         theme tokens (`bg-panel`, `text-fg-dim`, `rounded-ui`, `text-ui-sm`, `font-display`),
         never a literal colour, font or radius.
         Layout utilities (flex, gap-*, w-*) are fine on a kit tag: the kit classes live in the
         components layer, so a utility next to them always wins.
         Glass is the `blur` prop (-> `data-core-blur`, DESIGN §32): panels only, never rows. -->
    <CoreScreen background="scrim">
        <div class="flex h-full items-center justify-center">
            <CorePanel class="w-[440px] max-w-[86vw]" eyebrow="Plugin page" title="my_plugin"
                subtitle="Your page starts here" accent blur>
                <!-- `actions` is the header's right-hand side. -->
                <template #actions>
                    <CoreIconButton icon="close" label="Close (ESC)" variant="ghost" @click="close()" />
                </template>

                <!-- Label/value rows, hairline-framed: `items` is data, not markup. -->
                <CoreKeyValue :items="[
                    { label: 'Player', value: hud.name || '—', icon: 'user' },
                    { label: 'From Lua', value: props.title || 'props of Core.UI.open show up here' },
                ]" />

                <CoreAlert v-if="note" class="mt-4" tone="success" title="Core.UI.send" :text="note" />

                <!-- The footer sits under a hairline on a slightly darker fill. -->
                <template #footer>
                    <div class="flex items-center justify-between gap-4">
                        <CoreKeyHints bare align="start" :items="[{ key: 'ESC', label: 'Close' }]" />
                        <div class="flex gap-2">
                            <CoreButton icon="bolt" @click="emit('hello', { at: Date.now() })">Send an event</CoreButton>
                            <CoreButton variant="primary" @click="close()">Done</CoreButton>
                        </div>
                    </div>
                </template>
            </CorePanel>
        </div>
    </CoreScreen>
</template>
