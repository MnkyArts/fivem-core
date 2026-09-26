// schemaFixtures — `Core.Schema.public` arrays for the CoreSchemaForm stories and gallery (DESIGN §53,
// §43). Shaped exactly like the Lua side emits them: plain JSON, no functions, no secret defaults.

/** An admin action's arguments (§51): the ban. */
export const BAN_FIELDS = [
  { name: 'target', type: 'player', label: 'Player', required: true },
  { name: 'duration', type: 'duration', label: 'Duration', required: true, allowPermanent: true, default: 86400 },
  { name: 'reason', type: 'reason', label: 'Reason', required: true, templates: ['Cheating', 'Harassment', 'Exploiting a bug', 'Fail RP'] },
  { name: 'notify', type: 'boolean', label: 'Tell the player why', default: true },
]

const WEATHERS = ['CLEAR', 'EXTRASUNNY', 'CLOUDS', 'OVERCAST', 'RAIN', 'CLEARING', 'THUNDER', 'SMOG', 'FOGGY', 'XMAS', 'SNOWLIGHT', 'BLIZZARD']

/** A settings section (§45): groups, order, visibleWhen, every scalar type. */
export const SETTINGS_FIELDS = [
  { name: 'serverName', type: 'string', label: 'Server name', group: 'General', order: 1, default: 'Los Santos Life', maxLength: 48 },
  { name: 'maxPlayers', type: 'integer', label: 'Max players', group: 'General', order: 2, min: 1, max: 2048, default: 1024, unit: 'slots' },
  { name: 'motd', type: 'text', label: 'Message of the day', group: 'General', order: 3, maxLength: 280, description: 'Shown once after spawn.' },
  { name: 'apiKey', type: 'password', label: 'Webhook secret', group: 'General', order: 4, secret: true, placeholder: 'unchanged' },
  { name: 'weather', type: 'enum', label: 'Default weather', group: 'World', options: WEATHERS, default: 'CLEAR' },
  { name: 'syncMode', type: 'enum', label: 'Time sync', group: 'World', default: 'real', options: [
    { value: 'real', label: 'Real time' }, { value: 'fixed', label: 'Fixed hour' }, { value: 'cycle', label: 'Fast cycle', description: '48 min per day' },
  ] },
  { name: 'hour', type: 'integer', label: 'Fixed hour', group: 'World', min: 0, max: 23, default: 12, visibleWhen: { field: 'syncMode', equals: 'fixed' } },
  { name: 'cycleSpeed', type: 'number', label: 'Cycle speed', group: 'World', min: 0.5, max: 10, step: 0.5, default: 2, visibleWhen: { field: 'syncMode', in: ['cycle'] } },
  { name: 'features', type: 'enum', label: 'Features', group: 'World', multiple: true, options: ['Traffic', 'Peds', 'Police', 'Wanted'], default: ['Traffic', 'Peds'] },
  { name: 'accent', type: 'color', label: 'HUD accent', group: 'Look', default: '#F6503F' },
  { name: 'markerTint', type: 'color', label: 'Marker tint', group: 'Look', alpha: true, default: '#55B6F780' },
  { name: 'debug', type: 'boolean', label: 'Debug overlay', group: 'Look', readonly: true, default: false, description: 'Read-only: set by a convar.' },
  { name: 'internal', type: 'string', hidden: true, default: 'never shown' },
]

/** A map element type's fields (§52): vectors, heading, a model, a nested object and an array of objects. */
export const ELEMENT_FIELDS = [
  { name: 'model', type: 'model', label: 'Model', kinds: ['prop'], required: true, default: 'prop_barrier_work05' },
  { name: 'position', type: 'vector3', label: 'Position', world: true, default: { x: -1037.52, y: -2738.13, z: 13.76 } },
  { name: 'rotation', type: 'rotation', label: 'Rotation', default: { x: 0, y: 0, z: 90 } },
  { name: 'heading', type: 'heading', label: 'Spawn heading', default: 180 },
  { name: 'owner', type: 'faction', label: 'Owning faction' },
  { name: 'trigger', type: 'object', label: 'Trigger', fields: [
    { name: 'radius', type: 'number', label: 'Radius', min: 0.5, max: 50, step: 0.5, default: 3, unit: 'm' },
    { name: 'once', type: 'boolean', label: 'Fire once', default: false },
  ] },
  { name: 'checkpoints', type: 'array', label: 'Checkpoints', minItems: 1, maxItems: 8, items: {
    type: 'object', fields: [
      { name: 'pos', type: 'vector3', label: 'Position', world: true },
      { name: 'size', type: 'number', label: 'Size', min: 1, max: 20, default: 6, unit: 'm' },
    ],
  }, default: [{ pos: { x: 120.5, y: -560.25, z: 31 }, size: 6 }] },
]

const PLAYERS = ['Ada Byron', 'Travis Kane', 'Mila Ortega', 'Dez', 'Ana Reyes', 'Lamar Davis']
  .map((name, i) => ({ value: 3 + i * 5, label: name, description: 'ID ' + (3 + i * 5) }))
const PROPS = Array.from({ length: 400 }, (_, i) => 'prop_' + ['barrier_work', 'cone', 'crate', 'bench'][i % 4] + String(i).padStart(2, '0'))
const FACTIONS = [{ value: 'lspd', label: 'LSPD' }, { value: 'ems', label: 'EMS' }, { value: 'families', label: 'Families' }]

const match = (list, q) => {
  const n = String(q || '').toLowerCase()
  return list.filter((o) => {
    const label = typeof o === 'string' ? o : o.label
    const value = typeof o === 'string' ? o : o.value
    return !n || String(label).toLowerCase().includes(n) || String(value).startsWith(n)
  }).slice(0, 200)
}

/** `resolvers` for the resolved types, with a little latency like a server round trip. */
export const RESOLVERS = {
  player: (q) => new Promise((resolve) => setTimeout(() => resolve(match(PLAYERS, q)), 200)),
  model: (q) => match(PROPS, q),
  faction: (q) => match(FACTIONS, q),
}
