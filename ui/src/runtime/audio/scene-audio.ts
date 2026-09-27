// core UI — the audio engine's lazy entry (DESIGN §55.16): index.ts imports THIS module on the first
// `audio:*` message, so the engine is its own chunk (assets/scene-audio.js) and a shell without
// scene audio never loads, parses or runs a byte of it. hls.js is a second lazy chunk behind it.

export { AudioEngine } from './engine.ts'
export { engineStats, inspectEmitter, probeLevel } from './debug.ts'
