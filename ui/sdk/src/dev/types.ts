// @core/ui/dev — the few shapes the dev host and its toolbar share (DESIGN §38.11).

/** What sits behind the shell so a translucent panel can be judged (same set as kit-preview). */
export type DevBackground = 'game' | 'ink' | 'none'

/** The same dusk street `src/kit/preview.js` and Storybook paint: cool key light top left, warm
 *  sodium bounce bottom right. The NUI itself is transparent over GTA. */
export const GAME_BG: string = [
  'radial-gradient(1200px 720px at 18% 12%, rgba(108, 138, 184, 0.34), rgba(0, 0, 0, 0) 62%)',
  'radial-gradient(900px 620px at 86% 82%, rgba(198, 128, 68, 0.20), rgba(0, 0, 0, 0) 58%)',
  'radial-gradient(1500px 900px at 50% 118%, rgba(8, 11, 16, 0.88), rgba(0, 0, 0, 0) 68%)',
  'linear-gradient(168deg, #27323f 0%, #1b2330 38%, #131922 68%, #0b0f15 100%) #0b0f15',
].join(', ')

export function paintBackground(el: HTMLElement, bg: DevBackground): void {
  const s = el.style
  s.position = 'fixed'
  s.inset = '0'
  s.zIndex = '0'
  s.pointerEvents = 'none'
  s.background = bg === 'none' ? 'transparent' : bg === 'ink' ? '#060b0f' : GAME_BG
}
