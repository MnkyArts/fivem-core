// hls.js ships no declaration for its `./light` export (only dist/hls.d.mts for "."), so the lazy
// `import('hls.js/light')` in index.ts borrows the full build's types — the class API is the same.
declare module 'hls.js/light' {
  import Hls from 'hls.js'
  export default Hls
}
