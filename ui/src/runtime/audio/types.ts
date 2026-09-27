// core UI — the Core.Scene audio engine: shared shapes and constants (DESIGN §55.16).
//
// Types and plain constants ONLY: every audio module and the unit tests import this file, so it
// must never touch the DOM, Web Audio or a timer. The wire (Lua -> NUI) is INTERFACES §6:
//   audio:source  { id, type, url?, file?, items?, loop, t0, rate, paused, pausedAt, offset, volume,
//                   category, codec?, kind?, hosts?, trusted? }   (hosts: the allow-listed host patterns
//                   the page may also fetch from — redirects, HLS variants/segments/keys; absent = the
//                   URL's own. trusted = false (a play on a player's behalf, a URL off core's resources):
//                   never decoded — clips/loops play through media elements only; absent = true)
//   audio:emitter { id, source, x, y, z, range, volume, curve, ref, cone?, priority, zone?, occlusion,
//                   rx?, ry?, rz? }      (the node's rotation, degrees: a cone faces rz/rx; absent = +Y)
//   audio:remove  { ids, fadeMs }
//   audio:feed    { t, lx, ly, lz, fx, fy, fz, ux, uy, uz, vx, vy, vz, env, moving, occl,
//                   master, music, sfx, ambience, paused }   (moving entries may carry rx/rz too)
//   audio:prefs   { hrtf, maxVoices, offsetMs, streams }          audio:debug { on }
// NUI -> Lua goes through the `ui_event` bridge as page `audio`: `audio:stats`, `audio:error {id, code}`.
// Units: metres, degrees, milliseconds; `t`, `t0`, `pausedAt` are Core.Clock u32 milliseconds.

import type { HlsCtor } from './media.ts'

export type SourceType = 'clip' | 'loop' | 'timeline' | 'stream' | 'voice'
export type Category = 'music' | 'sfx' | 'ambience' | 'voice'
export type CurveName = 'game' | 'inverse' | 'linear'
export type StreamKind = 'mp3' | 'ogg' | 'hls'

export interface Vec3 {
  x: number
  y: number
  z: number
}

export interface TimelineItem {
  url: string
  /** milliseconds (> 0) — the server's durations are the timeline's authority, not the file's */
  duration: number
}

/** A validated `audio:source`. URLs are already resolved (`file` → `https://cfx-nui-<res>/<path>`). */
export interface SourceSpec {
  id: number
  type: SourceType
  url: string | null
  items: TimelineItem[] | null
  loop: boolean
  /** u32 clock ms; null = "when the page first saw it" */
  t0: number | null
  rate: number
  paused: boolean
  pausedAt: number | null
  /** ms added to the play head */
  offset: number
  volume: number
  category: Category
  codec: string | null
  kind: StreamKind | null
  /** extra hosts (exact or `*.suffix`) the page may fetch from for this source; null = only the URL's own */
  hosts: string[] | null
  /**
   * false: content an attacker may control (a play on a player's behalf, a URL that is not one of
   * core's resource files) — never handed to decodeAudioData, whose PCM allocation follows the
   * file's own (possibly lying) headers; clips/loops play through media elements. Default true.
   */
  trusted: boolean
}

export interface Cone {
  /** degrees, full angle (Web Audio semantics) */
  inner: number
  outer: number
  outerGain: number
}

export type ZoneShape =
  | { type: 'sphere'; x: number; y: number; z: number; radius: number }
  | { type: 'box'; x: number; y: number; z: number; sx: number; sy: number; sz: number; rotation: number }
  | { type: 'polygon'; xs: number[]; ys: number[]; minZ: number; maxZ: number }

export interface EmitterSpec {
  id: number
  source: number
  x: number
  y: number
  z: number
  range: number
  volume: number
  curve: CurveName
  ref: number
  cone: Cone | null
  /** unit forward vector of the emitter (from rx/rz); only a cone reads it */
  dir: Vec3
  /** 1..5, higher = more important (±6 dB per class around 3) */
  priority: number
  zone: ZoneShape | null
  occlusion: boolean
}

export interface RemoveSpec {
  ids: number[]
  fadeMs: number
}

export interface EnvSpec {
  interior: number
  room: number
  vehicle: boolean
  underwater: boolean
}

/**
 * A validated `audio:feed`. `moving` is flat `[id, x, y, z, rx, rz, …]` (rx/rz NaN when absent), `occl`
 * flat `[id, value, …]`.
 */
export interface FeedSpec {
  t: number | null
  pos: Vec3 | null
  fwd: Vec3 | null
  up: Vec3 | null
  vel: Vec3 | null
  env: EnvSpec | null
  moving: number[] | null
  occl: number[] | null
  master: number | null
  music: number | null
  sfx: number | null
  ambience: number | null
  voice: number | null
  paused: boolean | null
}

/** A validated `audio:prefs` — only the keys that were present and valid. */
export interface PrefsSpec {
  hrtf?: boolean
  maxVoices?: number
  offsetMs?: number
  /** false = no `stream` sources at all; a number = the stream/timeline decoder budget */
  streams?: boolean | number
  /** optional Config.Scene.Audio mirrors (defaults below match shared/config.lua) */
  decoders?: number
  clipCacheMb?: number
  hrtfVoices?: number
}

/** Fades in ms (R6 §8): cuts ≥ 5, music edges 30–100, LOD/steal 300–500; `stop()` only after them. */
export const FADE = { cut: 5, edge: 50, lod: 400, stop: 60, dip: 50, lock: 300 } as const

/**
 * Retries (RV3 F15): a failed fetch / media error is retried with backoff 1, 2, 4, 8 s and reported once
 * per streak; after `max` consecutive failures the source fails. `okMs` of locked playback ends a streak.
 */
export const RETRY = { max: 4, okMs: 10000 } as const

/** Config.Scene.Audio defaults (DESIGN §55.20) — the page has no config of its own. */
export const AUDIO_DEFAULTS = {
  voices: 32,
  decoders: 4,
  clipCacheMb: 64,
  hrtfVoices: 8,
  listenerHz: 20,
} as const

/** What the engine needs from the page (index.ts builds the real one, the unit tests a fake). */
export interface EngineEnv {
  createContext(): AudioContext | null
  now(): number
  setTimeout(fn: () => void, ms: number): unknown
  clearTimeout(h: unknown): void
  fetch: typeof fetch
  createAudio(): HTMLAudioElement
  MediaSource: typeof MediaSource | null
  createObjectURL(o: Blob | MediaSource): string
  revokeObjectURL(u: string): void
  importHls(): Promise<HlsCtor>
  report: AudioReport
  /** a plain browser (the suites, `npm run dev`): http/blob/data URLs pass, headers may be hidden */
  dev: boolean
  /** dev only: resume a context the browser's autoplay policy holds, on the first user gesture */
  onUserGesture?(fn: () => void): () => void
}

/** The engine's live preferences (defaults = Config.Scene.Audio, then `audio:prefs`). */
export interface EnginePrefs {
  hrtf: boolean
  maxVoices: number
  offsetMs: number
  streams: boolean | number
  decoders: number
  clipCacheMb: number
  hrtfVoices: number
}

/** Error codes posted as `audio:error { id, code }`. */
export type AudioErrorCode =
  | 'no_webaudio'
  | 'bad_url'
  | 'fetch_failed'
  | 'decode_failed'
  | 'too_large'
  | 'unsupported'
  | 'media_error'
  | 'stream_failed'
  | 'hls_failed'
  | 'suspended'

/** The page hands errors and stats to Lua through this (index.ts wires it to `post('ui_event')`). */
export type AudioReport = (event: 'error' | 'stats', data: Record<string, unknown>) => void
