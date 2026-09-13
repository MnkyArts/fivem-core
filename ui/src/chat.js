// Pure presentation helpers for Chat.vue. No command execution or permission decisions.
export const CHAT_DEFAULTS = { history: 80, hideDelayMs: 8000, visibleLines: 8, maxLength: 200 }

export function bounded(value, fallback, min, max) {
  return typeof value === 'number' && Number.isFinite(value)
    ? Math.min(max, Math.max(min, Math.floor(value))) : fallback
}

export function commandPool(items, channels = []) {
  const entries = new Map()
  for (const item of [...items, ...channels.filter(c => c.command).map(c => ({
    command: '/' + c.command, description: c.description || c.label || c.id,
    params: [{ name: '<message>', type: 'rest', help: 'Message' }],
  }))]) {
    if (!item || typeof item.command !== 'string' || !/^\/[^\s/]+$/.test(item.command)) continue
    const key = item.command.toLowerCase()
    const previous = entries.get(key)
    const params = Array.isArray(item.params) ? item.params.filter(p => p && typeof p.name === 'string') : []
    entries.set(key, {
      command: item.command,
      description: previous?.description || item.description || '',
      params: previous?.params.length ? previous.params : params,
    })
  }
  return [...entries.values()].sort((a, b) => a.command.localeCompare(b.command))
}

// Keep offsets rather than splitting at spaces: moving the caret back into an earlier
// argument must move its hint too. An unfinished quoted token is still one argument.
export function tokensOf(text) {
  const tokens = []
  let start = -1
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const char = text[i]
    if (!quoted && /\s/.test(char)) {
      if (start !== -1) tokens.push({ start, end: i, text: text.slice(start, i) })
      start = -1
      continue
    }
    if (start === -1) start = i
    if (quoted && char === '\\' && i + 1 < text.length) { i++; continue }
    if (char === '"') quoted = !quoted
  }
  if (start !== -1) tokens.push({ start, end: text.length, text: text.slice(start) })
  return tokens
}

export function commandContext(text, caret, pool) {
  const tokens = tokensOf(text)
  const head = tokens[0]
  if (!text.startsWith('/') || !head) return { matches: [], command: null, argument: -1 }
  const command = pool.find(item => item.command.toLowerCase() === head.text.toLowerCase()) || null
  const inCommand = caret <= head.end
  const matches = inCommand ? pool.filter(item => item.command.toLowerCase().startsWith(head.text.toLowerCase())) : []
  let argument = -1
  if (!inCommand && command) {
    const before = tokens.slice(1).filter(token => token.end < caret)
    argument = before.length
    const rest = command.params.findIndex(p => p.type === 'rest')
    if (rest !== -1 && argument >= rest) argument = rest
    if (argument >= command.params.length) argument = -1
  }
  return { matches, command, argument, head }
}

export function completeCommand(text, command) {
  const end = tokensOf(text)[0]?.end || 0
  const suffix = text.slice(end)
  return { text: command + (suffix || ' '), caret: command.length + 1 }
}

// Lua's #string counts UTF-8 bytes. Never cut a code point in half or silently let
// multibyte text hit the bridge's rejection path while appearing below the limit.
export function limitBytes(text, limit) {
  let bytes = 0
  let result = ''
  for (const char of text) {
    const cp = char.codePointAt(0)
    bytes += cp <= 0x7f ? 1 : cp <= 0x7ff ? 2 : cp <= 0xffff ? 3 : 4
    if (bytes > limit) break
    result += char
  }
  return result
}
