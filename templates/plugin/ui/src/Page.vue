<script setup lang="ts">
// my_plugin page — core DESIGN §38 (the UI platform) and §37 (the UI kit).
//
// usePage() with no id resolves the page being rendered: `props` is the ONE reactive object Lua's
// open/update/patch write into, plus emit(event, data) / on(event, fn) / close() scoped to this
// page. useHud() is the read-only reactive HUD (cash, bank, name, serverId, faction). A listener
// made here dies with the page — the SDK binds it to the page scope, so there is nothing to undo
// in onUnmounted. `vue` resolves to the shell's one Vue, never to a second copy.
import { ref } from 'vue'
import { useHud, usePage } from '@core/ui'
import type { MyPluginEvents, MyPluginIncoming, MyPluginProps } from './index.ts'

// The shell renders <YourPage :props="…">, so the attribute must not fall through to the root.
defineOptions({ name: 'MyPluginPage', inheritAttrs: false })

const { props, emit, on, close } = usePage<MyPluginProps, MyPluginEvents, MyPluginIncoming>()
const hud = useHud()

const note = ref('')

on('greeting', (data) => { note.value = data?.text || '' })   // Core.UI.send('my_plugin', 'greeting', …)
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

                <!-- The other half of the kit rule: never a literal colour, font or radius here —
                     `class="mt-4 flex gap-2"` is fine, `class="bg-[#131722]"` is not. -->


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
