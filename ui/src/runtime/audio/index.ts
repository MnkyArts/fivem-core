/// <reference path="./hls-light.d.ts" />
// core UI — the Core.Scene audio engine: install and message routing (DESIGN §55.16, INTERFACES §6).
//
// `installAudio()` subscribes the six `audio:*` actions on the transport's dispatch (`onMessage` —
// the same path every SendNUIMessage takes, so the dev host's mock transport and the suites drive it
// too) and does nothing else. The first `audio:*` message imports the engine chunk
// (`scene-audio.ts` → assets/scene-audio.js; messages that arrive meanwhile are queued and replayed in
// order); the AudioContext appears only with the first source or emitter. Returns the disposer.
//
// NUI → Lua: `post('ui_event', { page: 'audio', event: 'error' | 'stats', data })`, i.e. Lua hears
// `core:ui:audio:error { id, code }` and `core:ui:audio:stats {…}` (`Core.UI.on('audio', …)`); page and
// event are plain ids because the ui_event bridge refuses anything else (AGENTS §8).
//
// Dev only (a plain browser, `isDev`): `window.__core.audio = { ready(), stats(), inspect(emitterId),
// level(ms) }` for the runtime suite and the console; a context the browser's autoplay policy holds
// is resumed on the first click or key (FiveM's CEF runs with autoplay-policy=no-user-gesture-required).

import { isDev, onMessage, post } from '../transport.ts'
import type { AudioEngine, EngineEnv } from './engine.ts'
import type { HlsCtor } from './media.ts'

type AudioModule = typeof import('./scene-audio.ts')

export const AUDIO_ACTIONS = ['audio:source', 'audio:emitter', 'audio:remove', 'audio:feed', 'audio:prefs', 'audio:debug'] as const

/** Messages held while the engine chunk loads (a feed burst beyond this drops its oldest entries). */
const MAX_QUEUE = 256
const RETRY_MS = 5000

/** The page's real environment; the unit tests build their own. */
export function browserEnv(): EngineEnv {
  return {
    createContext: () => (typeof AudioContext === 'function' ? new AudioContext({ latencyHint: 'playback' }) : null),
    now: () => performance.now(),
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
    fetch: (input, init) => fetch(input, init),
    createAudio: () => new Audio(),
    MediaSource: typeof MediaSource === 'function' ? MediaSource : null,
    createObjectURL: (o) => URL.createObjectURL(o),
    revokeObjectURL: (u) => URL.revokeObjectURL(u),
    // its own chunk (assets/hls.light.js): fetched the first time an HLS stream plays, never before
    importHls: () => import('hls.js/light').then((m) => m.default as unknown as HlsCtor),
    report: (event, data) => {
      void post('ui_event', { page: 'audio', event, data })
    },
    dev: isDev,
    onUserGesture: isDev ? onFirstGesture : undefined,
  }
}

function onFirstGesture(fn: () => void): () => void {
  const handler = (): void => fn()
  window.addEventListener('pointerdown', handler, true)
  window.addEventListener('keydown', handler, true)
  return () => {
    window.removeEventListener('pointerdown', handler, true)
    window.removeEventListener('keydown', handler, true)
  }
}

export interface AudioInstallOptions {
  /** builds the environment when the engine starts (tests pass a fake) */
  env?: () => EngineEnv
  /** imports the engine module (default: the lazy chunk) */
  importEngine?: () => Promise<AudioModule>
}

/** Wires the engine to the transport; returns the disposer. Nothing loads before a message. */
export function installAudio(opts?: AudioInstallOptions): () => void {
  const makeEnv = opts && opts.env ? opts.env : browserEnv
  const importEngine = opts && opts.importEngine ? opts.importEngine : () => import('./scene-audio.ts')
  let mod: AudioModule | null = null
  let engine: AudioEngine | null = null
  let queue: Array<[string, Record<string, unknown>]> | null = null
  let loading: Promise<void> | null = null
  let failedAt = -Infinity
  let disposed = false

  const start = (): void => {
    queue = []
    loading = importEngine().then(
      (m) => {
        if (disposed) return
        mod = m
        engine = new m.AudioEngine(makeEnv())
        const held = queue || []
        queue = null
        for (const [action, msg] of held) engine.handle(action, msg)
      },
      (err: unknown) => {
        queue = null
        loading = null
        failedAt = Date.now()
        console.error('[core:ui] the audio engine failed to load', err)
      },
    )
  }

  const offs = AUDIO_ACTIONS.map((action) => onMessage(action, (msg) => {
    if (engine) {
      engine.handle(action, msg)
      return
    }
    if (disposed || Date.now() - failedAt < RETRY_MS) return
    if (!queue) start()
    const q = queue as Array<[string, Record<string, unknown>]>
    q.push([action, msg])
    if (q.length > MAX_QUEUE) {
      const i = q.findIndex((entry) => entry[0] === 'audio:feed')
      q.splice(i === -1 ? 0 : i, 1)
    }
  }))

  const removeSeam = installSeam({
    ready: () => (loading ? loading.then(() => !!engine) : Promise.resolve(!!engine)),
    stats: () => (engine && mod ? mod.engineStats(engine) : { context: null, loaded: false }),
    inspect: (id: number) => (engine && mod ? mod.inspectEmitter(engine, id) : null),
    level: (ms?: number) => (engine && mod ? mod.probeLevel(engine, ms || 300) : Promise.resolve(null)),
  })

  return () => {
    disposed = true
    for (const off of offs) off()
    removeSeam()
    if (engine) engine.dispose()
    engine = null
    queue = null
  }
}

function installSeam(seam: Record<string, unknown>): () => void {
  if (!isDev || typeof window === 'undefined') return () => {}
  const shim = (window as unknown as { __core?: Record<string, unknown> }).__core
  if (!shim) return () => {}
  shim.audio = seam
  return () => {
    if (shim.audio === seam) delete shim.audio
  }
}
