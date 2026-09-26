// core UI kit — the pure helpers behind CoreSchemaForm (DESIGN §53, the §43 field vocabulary).
//
// `Core.Schema.public(fields)` is the JSON a page receives: an array of field definitions with no
// functions and no secret defaults. Everything here reads that shape. The checks below are an
// ADVISORY mirror of §43 so a form can say "required" before a round-trip — the server's
// `Core.Schema.checkAll` stays the authority, and its error codes (`'required'`, `'min'`,
// `'custom:<text>'`, …) come back through the form's `errors` prop and are worded by `messageFor`.
// No Vue import: the module is plain data in, plain data out.

/** The §43 types CoreSchemaForm knows how to draw. */
export const FIELD_TYPES = [
  'boolean', 'integer', 'number', 'string', 'text', 'password', 'reason', 'enum', 'array', 'object',
  'color', 'duration', 'vector3', 'heading', 'rotation', 'model', 'player', 'ref', 'faction', 'item',
]

/** Types whose options come from the `resolvers` prop (`{ [type]: (query, field) => options }`). */
export const RESOLVED_TYPES = ['model', 'player', 'ref', 'faction', 'item']

/** `duration` presets, in seconds; `0` is only offered with `allowPermanent`. */
export const DURATION_PRESETS = [900, 3600, 86400, 604800]

/** §43 `world = true` bounds of a vector3. */
export const WORLD_MIN = { x: -10000, y: -10000, z: -1000 }
export const WORLD_MAX = { x: 10000, y: 10000, z: 3000 }

/** English wording of the §43 error codes; `{min}`-style holes are filled from the field. */
export const DEFAULT_MESSAGES = {
  required: 'Required.',
  type: 'Not a valid value.',
  min: 'Must be at least {min}.',
  max: 'Must be at most {max}.',
  step: 'Must be a multiple of {step}.',
  pattern: 'Not in the expected format.',
  option: 'Not one of the allowed options.',
  length: 'Must be {minLength}–{maxLength} characters.',
  items: 'Needs {minItems}–{maxItems} entries.',
  unknown: 'Unknown field.',
}

const UNITS = [['w', 604800], ['d', 86400], ['h', 3600], ['m', 60], ['s', 1]]

/** `maxPlayers` / `max_players` → `Max players`. */
export function humanize (name) {
  const words = String(name || '')
    .replace(/[_-]+/g, ' ')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .trim()
    .toLowerCase()
  return words ? words.charAt(0).toUpperCase() + words.slice(1) : ''
}

/** A field's caption: its `label`, else its humanised `name`. */
export const labelOf = (field) => (field && field.label ? String(field.label) : humanize(field && field.name))

/** Deep copy of plain JSON data (defaults must never be shared between two forms). */
export function clone (value) {
  if (value === null || typeof value !== 'object') return value
  if (Array.isArray(value)) return value.map(clone)
  const out = {}
  for (const k of Object.keys(value)) out[k] = clone(value[k])
  return out
}

/** Drops `hidden` fields and orders the rest by `order` (stable; no order = declaration order after). */
export function sortFields (fields) {
  const list = Array.isArray(fields) ? fields.filter((f) => f && typeof f === 'object' && !f.hidden) : []
  return list
    .map((field, index) => ({ field, index, order: Number.isFinite(field.order) ? field.order : Infinity }))
    .sort((a, b) => (a.order === b.order ? a.index - b.index : a.order < b.order ? -1 : 1))
    .map((entry) => entry.field)
}

/** `[{ name, fields }]` in order of each group's first field; ungrouped fields form group `''`. */
export function groupFields (fields) {
  const groups = []
  const byName = new Map()
  for (const field of sortFields(fields)) {
    const name = field.group ? String(field.group) : ''
    if (!byName.has(name)) {
      const group = { name, fields: [] }
      byName.set(name, group)
      groups.push(group)
    }
    byName.get(name).fields.push(field)
  }
  return groups
}

/** `visibleWhen = { field, equals } | { field, in: [...] }`, read against the sibling values. */
export function isVisible (field, values) {
  const rule = field && field.visibleWhen
  if (!rule || typeof rule !== 'object' || !rule.field) return true
  const v = values ? values[rule.field] : undefined
  if (Array.isArray(rule.in)) return rule.in.some((x) => x === v)
  if (Object.prototype.hasOwnProperty.call(rule, 'equals')) return v === rule.equals
  return true
}

/** The value a field starts with: its `default` (copied), else a neutral value for the type. */
export function defaultFor (field) {
  if (!field) return undefined
  if (field.default !== undefined && field.default !== null) return clone(field.default)
  switch (field.type) {
    case 'boolean': return false
    case 'integer':
    case 'number': return Number.isFinite(field.min) ? field.min : 0
    case 'heading': return 0
    case 'string': case 'text': case 'password': case 'reason': case 'color': return ''
    case 'enum': return field.multiple ? [] : null
    case 'array': return []
    case 'object': return fillDefaults(field.fields, {})
    case 'vector3': case 'rotation': return { x: 0, y: 0, z: 0 }
    default: return null
  }
}

/** A copy of `values` with every declared field present (missing ones get `defaultFor`). */
export function fillDefaults (fields, values) {
  const src = values && typeof values === 'object' ? values : {}
  const out = Object.assign({}, src)
  for (const field of Array.isArray(fields) ? fields : []) {
    if (!field || !field.name) continue
    if (out[field.name] === undefined) out[field.name] = defaultFor(field)
    else if (field.type === 'object') out[field.name] = fillDefaults(field.fields, out[field.name])
  }
  return out
}

/** `enum` options as `{ value, label, description? }`. */
export function enumOptions (field) {
  const list = field && Array.isArray(field.options) ? field.options : []
  return list.map((o) => (o !== null && typeof o === 'object'
    ? { value: o.value, label: o.label !== undefined ? String(o.label) : String(o.value), description: o.description }
    : { value: o, label: String(o) }))
}

const isEmpty = (v) => v === undefined || v === null || v === '' || (Array.isArray(v) && v.length === 0)

/**
 * Advisory client check of one value against its field (§43). Returns an error CODE or null.
 * Nested object / array members are checked by their own SchemaField, not here.
 */
export function checkField (field, value) {
  if (!field) return null
  if (isEmpty(value)) return field.required ? 'required' : null
  const t = field.type
  if (t === 'integer' || t === 'number') {
    if (typeof value !== 'number' || !Number.isFinite(value)) return 'type'
    if (t === 'integer' && Math.floor(value) !== value) return 'step'
    if (Number.isFinite(field.min) && value < field.min) return 'min'
    if (Number.isFinite(field.max) && value > field.max) return 'max'
    if (Number.isFinite(field.step) && field.step > 0) {
      const k = (value - (Number.isFinite(field.min) ? field.min : 0)) / field.step
      if (Math.abs(k - Math.round(k)) > 1e-6) return 'step'
    }
  } else if (t === 'string' || t === 'text' || t === 'password' || t === 'reason') {
    const len = String(value).length
    const lo = Number.isFinite(field.minLength) ? field.minLength : t === 'reason' ? 3 : 0
    const hi = Number.isFinite(field.maxLength) ? field.maxLength : 256
    if (len < lo || len > hi) return 'length'
  } else if (t === 'enum') {
    const allowed = enumOptions(field).map((o) => o.value)
    const list = field.multiple ? (Array.isArray(value) ? value : [value]) : [value]
    if (list.some((v) => allowed.indexOf(v) === -1)) return 'option'
  } else if (t === 'array') {
    const n = Array.isArray(value) ? value.length : 0
    if ((Number.isFinite(field.minItems) && n < field.minItems) || (Number.isFinite(field.maxItems) && n > field.maxItems)) return 'items'
  } else if (t === 'color') {
    const re = field.alpha ? /^#[0-9a-f]{6}([0-9a-f]{2})?$/i : /^#[0-9a-f]{6}$/i
    if (!re.test(String(value))) return 'pattern'
  } else if (t === 'duration') {
    // Mirrors lib/schema CHECK.duration: 0 with allowPermanent is always fine, bounds apply otherwise.
    if (!Number.isInteger(value)) return 'type'
    if (value < 0) return 'min'
    if (value === 0 && field.allowPermanent) return null
    if (Number.isFinite(field.min) && value < field.min) return 'min'
    if (Number.isFinite(field.max) && value > field.max) return 'max'
  }
  return null
}

/**
 * Words an error code (§43) for a field. `custom:<text>` shows the text; an unknown code is shown
 * as it stands; `messages` (the form's prop) overrides the English defaults.
 */
export function messageFor (code, field, messages) {
  if (!code) return ''
  const s = String(code)
  if (s.indexOf('custom:') === 0) return s.slice(7)
  if (s === 'pattern' && field && field.patternMessage) return String(field.patternMessage)
  const table = Object.assign({}, DEFAULT_MESSAGES, messages || {})
  const template = table[s]
  if (!template) return s
  const f = field || {}
  const duration = f.type === 'duration'
  const holes = {
    min: duration ? formatDuration(Number.isFinite(f.min) ? f.min : 0) : f.min,
    max: duration && Number.isFinite(f.max) ? formatDuration(f.max) : f.max,
    step: f.step,
    minLength: Number.isFinite(f.minLength) ? f.minLength : f.type === 'reason' ? 3 : 0,
    maxLength: Number.isFinite(f.maxLength) ? f.maxLength : 256,
    minItems: Number.isFinite(f.minItems) ? f.minItems : 0,
    maxItems: Number.isFinite(f.maxItems) ? f.maxItems : '∞',
  }
  return template.replace(/\{(\w+)\}/g, (m, k) => (holes[k] === undefined ? m : String(holes[k])))
}

/** `90` (seconds) · `15m` · `2h30m` · `1d 12h` · `perm` → seconds, or null when unreadable. */
export function parseDuration (text) {
  const s = String(text === undefined || text === null ? '' : text).trim().toLowerCase()
  if (!s) return null
  if (s === 'perm' || s === 'permanent' || s === '0') return 0
  if (/^\d+$/.test(s)) return Number(s)
  const re = /(\d+(?:\.\d+)?)\s*([wdhms])/g
  let total = 0
  let used = ''
  let m = re.exec(s)
  while (m) {
    total += Number(m[1]) * UNITS.find((u) => u[0] === m[2])[1]
    used += m[0]
    m = re.exec(s)
  }
  if (!used || used.replace(/\s+/g, '') !== s.replace(/\s+/g, '')) return null
  return Math.round(total)
}

/** Seconds → `1d 2h`, `15m`, `45s`; `0` → `Permanent` (with `allowPermanent`). */
export function formatDuration (seconds, allowPermanent) {
  const n = Math.max(0, Math.floor(Number(seconds) || 0))
  if (n === 0) return allowPermanent ? 'Permanent' : '0s'
  const parts = []
  let rest = n
  for (const [unit, size] of UNITS) {
    if (rest >= size) {
      parts.push(Math.floor(rest / size) + unit)
      rest %= size
    }
  }
  return parts.join(' ')
}

/** The error-map key of a nested member: `pos.x`, `list.2` (array indexes 1-based, as Lua counts). */
export const joinPath = (path, name) => (path === '' || path === undefined || path === null ? String(name) : path + '.' + name)

const SEGMENT = /^(\d+|[A-Za-z_]\w*)$/

/**
 * Flattens the server's error map. `Core.Schema.checkAll` keys errors by the TOP-LEVEL name and puts
 * a nested member's path in front of the code (`{ checkpoints = '2.pos.min' }`, §43); the form keys
 * them by path (`{ 'checkpoints.2.pos': 'min' }`). Leading `name.` / `index.` segments move into the
 * key until the rest is the code — `custom:<text>` stops the walk at its colon, so a sentence with
 * dots in it survives. Keys that are already paths pass through.
 * @param {Record<string, string>} errors
 * @returns {Record<string, string>}
 */
export function normalizeErrors (errors) {
  const out = {}
  if (!errors || typeof errors !== 'object') return out
  for (const key of Object.keys(errors)) {
    let path = key
    let rest = String(errors[key])
    for (;;) {
      const dot = rest.indexOf('.')
      if (dot <= 0 || !SEGMENT.test(rest.slice(0, dot))) break
      path = joinPath(path, rest.slice(0, dot))
      rest = rest.slice(dot + 1)
    }
    out[path] = rest
  }
  return out
}
