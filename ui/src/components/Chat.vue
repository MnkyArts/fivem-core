<script setup>
// Top-left chat (DESIGN §30.3). One store-owned open flag, one idle timeout;
// no polling. The server owns routing, permissions and proximity opacity.
import { computed, nextTick, ref, watch } from 'vue'
import { store } from '../store.js'
import { post } from '../bridge.js'
import { commandPool, commandContext, completeCommand, limitBytes } from '../chat.js'

const input = ref(null)
const feedEl = ref(null)
const suggestionsEl = ref(null)
const draft = ref('')
const caret = ref(0)
const selected = ref(0)
const navigated = ref(false)
const history = []
let historyIndex = -1
let savedDraft = ''
const awake = ref(false)
const open = computed(() => store.chat.open)
const lines = computed(() => open.value ? store.chat.lines : store.chat.lines.slice(-store.chat.visibleLines))
const feedVisible = computed(() => lines.value.length > 0 && (open.value || awake.value))
const channels = computed(() => store.chat.channels.length ? store.chat.channels : [{ id: 'local', label: 'Local' }])
const activeChannel = computed(() => channels.value.find(c => c.id === store.chat.channel) || channels.value[0])
const pool = computed(() => commandPool(store.chat.suggestions, channels.value))
const context = computed(() => commandContext(draft.value, caret.value, pool.value))
const matches = computed(() => context.value.matches)
const selectedCommand = computed(() => matches.value[selected.value])
const currentParam = computed(() => context.value.command?.params[context.value.argument])

function colorOf(line) {
  const color = line.color
  return Array.isArray(color) && color.length === 3
    ? `rgb(${color.map(n => Math.min(255, Math.max(0, Number(n) || 0))).join(',')})` : 'var(--color-fg)'
}

function lineOpacity(line) {
  return open.value || !Number.isFinite(line.opacity) ? 1 : Math.min(1, Math.max(0, line.opacity))
}

function scrollEnd() {
  if (feedEl.value) feedEl.value.scrollTop = feedEl.value.scrollHeight
}

watch([open, () => store.chat.activity, () => store.chat.hideDelayMs], (_, __, cleanup) => {
  awake.value = store.chat.lines.length > 0
  if (open.value || !store.chat.hideDelayMs || !awake.value) return
  const timer = setTimeout(() => { awake.value = false }, store.chat.hideDelayMs)
  cleanup(() => clearTimeout(timer))
}, { immediate: true })
watch([open, () => store.chat.activity], scrollEnd, { flush: 'post' })

// Lua refuses focus when another UI owns it. A late reply must not undo a newer close.
watch(open, async (value, _, cleanup) => {
  let current = true
  cleanup(() => { current = false })
  if (value) {
    draft.value = ''
    caret.value = 0
    historyIndex = -1
    savedDraft = ''
  }
  const result = post('chat_focus', { open: value })
  await nextTick()
  if (current && value) input.value?.focus()
  const response = await result
  if (current && value && response?.ok === false) close()
}, { immediate: true })

watch(() => [open.value, store.shell.visible, store.openPage, store.menu.visible, store.input.visible, store.alert.visible], () => {
  if (!store.shell.visible || store.openPage || store.menu.visible || store.input.visible || store.alert.visible) close()
})
watch(matches, () => { selected.value = 0; navigated.value = false })
watch(() => store.chat.history, limit => {
  if (history.length > limit) history.splice(0, history.length - limit)
  historyIndex = -1
})
watch(selected, () => {
  suggestionsEl.value?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
}, { flush: 'post' })

function close() {
  store.chat.open = false
}

function updateCaret() {
  caret.value = input.value?.selectionStart ?? draft.value.length
}

function onInput(event) {
  const value = event.target.value
  const limit = value.startsWith('/') ? 512 : store.chat.maxLength
  draft.value = limitBytes(value, limit)
  if (draft.value !== value) event.target.value = draft.value
  updateCaret()
  historyIndex = -1
}

async function setDraft(value, position = value.length) {
  draft.value = value
  caret.value = position
  await nextTick()
  input.value?.setSelectionRange(position, position)
}

function moveSelection(direction) {
  selected.value = (selected.value + direction + matches.value.length) % matches.value.length
  navigated.value = true
}

function acceptCommand(command = selectedCommand.value) {
  if (!command) return
  const completed = completeCommand(draft.value, command.command)
  setDraft(completed.text, completed.caret)
}

function recall(direction) {
  if (!history.length) return
  if (historyIndex === -1) {
    if (direction > 0) return
    savedDraft = draft.value
    historyIndex = history.length
  }
  historyIndex = Math.max(0, Math.min(history.length, historyIndex + direction))
  if (historyIndex === history.length) {
    historyIndex = -1
    setDraft(savedDraft)
  } else setDraft(history[historyIndex])
}

function cycleChannel(direction = 1) {
  const list = channels.value
  const index = list.findIndex(c => c.id === activeChannel.value.id)
  store.chat.channel = list[(index + direction + list.length) % list.length].id
}

function onKeydown(event) {
  // Enter/Escape during IME composition belong to the IME, not the chat.
  if (event.isComposing || event.keyCode === 229) return
  const key = event.key
  if (!['Escape', 'Enter', 'Tab', 'ArrowUp', 'ArrowDown', 'PageUp', 'PageDown'].includes(key)) return
  event.preventDefault()
  event.stopPropagation()
  if (key === 'Escape') return close()
  if (key === 'Tab') {
    if (event.ctrlKey) return cycleChannel(event.shiftKey ? -1 : 1)
    if (event.shiftKey && matches.value.length) return moveSelection(-1)
    return acceptCommand()
  }
  if (key === 'ArrowUp' || key === 'ArrowDown') {
    const direction = key === 'ArrowUp' ? -1 : 1
    return matches.value.length ? moveSelection(direction) : recall(direction)
  }
  if (key === 'PageUp' || key === 'PageDown') {
    if (feedEl.value) feedEl.value.scrollTop += (key === 'PageUp' ? -1 : 1) * feedEl.value.clientHeight * 0.8
    return
  }
  if (matches.value.length && (navigated.value || !context.value.command)) return acceptCommand()
  submit()
}

function submit() {
  const text = draft.value.trim()
  if (!text) return close()
  if (history.at(-1) !== text) history.push(text)
  if (history.length > store.chat.history) history.splice(0, history.length - store.chat.history)
  close() // release immediately; NUI/server latency must not leave the input stuck
  if (text.startsWith('/')) post('chat_command', { raw: text })
  else post('chat_send', { text, channel: activeChannel.value.id })
}
</script>

<template>
  <section class="chat fixed z-[30] left-[18px] top-[18px] text-ui-sm text-fg"
           :class="{ 'chat-hidden': !store.shell.visible }" aria-label="Chat">
    <div ref="feedEl" class="feed" :class="{ 'feed-visible': feedVisible, 'feed-reading': open }"
         :aria-hidden="!feedVisible" role="log" aria-label="Chat messages" aria-live="polite">
      <div v-for="line in lines" :key="line.id" class="line" :style="{ opacity: lineOpacity(line) }">
        <span v-if="!line.name" :class="{ italic: line.kind === 'me' }" :style="{ color: colorOf(line) }">{{ line.text }}</span>
        <template v-else>
          <span v-if="line.tag" class="tag" :style="{ color: colorOf(line) }">{{ line.tag.trim() + ' ' }}</span><span
            class="name" :class="{ uppercase: line.kind === 'scream' }"
            :style="{ color: colorOf(line) }">{{ line.name + ': ' }}</span><span
            class="message" :class="{ 'font-semibold uppercase': line.kind === 'scream' }">{{ line.text }}</span>
        </template>
      </div>
    </div>

    <div v-if="open" class="composer">
      <div class="row rounded-ui" data-core-blur>
        <button class="chan-btn core-interactive text-fg-dim" tabindex="-1"
                :title="`${activeChannel.description || activeChannel.label || activeChannel.id} · Ctrl+Tab to switch`"
                @mousedown.prevent @click="cycleChannel()">{{ activeChannel.label || activeChannel.id }}</button>
        <input ref="input" :value="draft" class="chat-input core-interactive" placeholder="Message or /command"
               aria-label="Chat message" role="combobox" aria-autocomplete="list" :aria-expanded="matches.length > 0"
               :aria-controls="matches.length ? 'chat-commands' : undefined"
               :aria-activedescendant="matches.length ? `chat-command-${selected}` : undefined"
               :aria-describedby="currentParam ? 'chat-argument-help' : undefined"
               maxlength="512" spellcheck="false" autocomplete="off"
               @input="onInput" @keydown="onKeydown" @keyup="updateCaret" @click="updateCaret" @select="updateCaret" />
      </div>

      <div v-if="matches.length" class="command-help rounded-ui">
        <ul id="chat-commands" ref="suggestionsEl" class="command-list" role="listbox" aria-label="Available commands">
          <li v-for="(command, index) in matches" :id="`chat-command-${index}`" :key="command.command"
              class="command-option" :class="{ selected: selected === index }" role="option"
              :aria-selected="selected === index" @mousedown.prevent="acceptCommand(command)">
            <div class="signature"><span class="font-medium">{{ command.command }}</span><span
              v-for="(param, p) in command.params" :key="p" class="param text-fg-dim">{{ param.name }}</span></div>
            <p v-if="command.description" class="command-description text-fg-dim">{{ command.description }}</p>
          </li>
        </ul>
        <div class="command-keys text-fg-faint">↑ ↓ select <span>Tab complete</span><span>{{ selected + 1 }} / {{ matches.length }}</span></div>
      </div>
      <div v-else-if="context.command" class="argument-help command-help rounded-ui">
        <div class="signature"><span class="text-fg-dim">{{ context.command.command }}</span><span
          v-for="(param, index) in context.command.params" :key="index" class="param"
          :class="index === context.argument ? 'param-active text-accent' : 'text-fg-dim'"
          :aria-current="index === context.argument ? 'step' : undefined">{{ param.name }}</span></div>
        <p v-if="currentParam" id="chat-argument-help" class="argument-description text-fg-dim">
          {{ currentParam.help || currentParam.name }}<span class="param-type text-fg-faint">{{ currentParam.type || 'string' }} · {{ currentParam.optional || currentParam.name.startsWith('[') ? 'optional' : 'required' }}</span>
        </p>
        <p v-else class="command-description text-fg-dim">{{ context.command.description }}</p>
      </div>
    </div>
  </section>
</template>

<style scoped>
.chat { width: min(440px, calc(100vw - 36px)); color-scheme: dark; scrollbar-color: var(--color-border-strong) transparent; }
.feed { max-height: min(250px, 35vh); overflow: hidden; opacity: 0; visibility: hidden; transition: opacity 250ms ease, visibility 250ms; scrollbar-width: thin; padding: 0 2px; }
.feed-visible { opacity: 1; visibility: inherit; transition: opacity 250ms ease; }
.chat-hidden .feed { visibility: hidden; transition: none; }
.feed-reading { overflow-y: auto; pointer-events: auto; }
.feed:empty { display: none; }
.line { line-height: 1.45; margin-bottom: 2px; overflow-wrap: anywhere; white-space: pre-wrap; text-shadow: 0 1px 3px #000, 0 0 2px #000; }
.name, .tag { font-weight: 600; }
.composer { margin-top: 7px; }
.row { display: flex; align-items: center; min-height: 34px; padding: 0 10px; gap: 10px; background: var(--color-panel); border: 1px solid var(--color-border); }
.chan-btn { flex: none; border: 0; background: none; padding: 0; font-size: 11px; cursor: pointer; }
.chat-input { min-width: 0; flex: 1; height: 32px; padding: 0; background: none; border: 0; outline: none; color: inherit; font: inherit; }
.chat-input::placeholder { color: var(--color-fg-faint); }
.command-help { margin-top: 4px; background: var(--color-panel); overflow: hidden; border: 1px solid var(--color-border); }
.command-list { max-height: min(230px, 30vh); overflow-y: auto; scrollbar-width: thin; padding: 3px; margin: 0; list-style: none; }
.command-option { padding: 6px 8px; border-radius: 3px; pointer-events: auto; cursor: pointer; }
.command-option.selected { background: var(--color-panel-raise); }
.signature { display: flex; flex-wrap: wrap; gap: 5px; font-size: 12px; }
.command-description, .argument-description { margin: 3px 0 0; font-size: 11px; line-height: 1.4; overflow-wrap: anywhere; }
.command-keys { display: flex; gap: 14px; padding: 4px 11px 6px; font-size: 10px; }
.command-keys span:last-child { margin-left: auto; }
.argument-help { padding: 8px 11px; }
.param-active { text-decoration: underline; text-underline-offset: 3px; }
.param-type { margin-left: 8px; }
@media (prefers-reduced-motion: reduce) { .feed { transition: none; } }
</style>
