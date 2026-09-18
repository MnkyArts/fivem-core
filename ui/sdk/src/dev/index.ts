// @core/ui/dev — the browser dev loop of DESIGN §38.11 path 1.
//
//   npm run dev   ->  coreUI() serves ui/index.html -> ui/dev/host.ts -> createDevHost({ … })
//
// core's real shell, the real kit, the real focus stack and a typed fake Lua, all inside the
// PLUGIN's Vite server: one module graph, one Vue, native HMR. Nothing in this folder is ever
// built into `ui/dist` — it exists only while `vite` is running.

export { createMockTransport } from './mock.ts'
export type {
  LuaMock, MockMessage, MockOptions, MockPageDecl, MockPost, MockRequestOptions, MockTransport,
  PagePropsMap,
} from './mock.ts'

export { createDevHost } from './host.ts'
export type { DevHost, DevHostOptions } from './host.ts'

export { GAME_BG, paintBackground } from './types.ts'
export type { DevBackground } from './types.ts'
