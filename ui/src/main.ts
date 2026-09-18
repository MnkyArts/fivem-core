// core UI — the page entry (DESIGN §7.1, §7.2, §38.6).
//
// Everything that used to live here is `src/shell.ts` now, so the SDK's dev host and the
// integration tests can mount the very same shell with a mock transport. This file is the part
// that only the real `html/index.html` needs: the stylesheets and one call.
import './styles.css'
import './kit/fonts.css'
import { createShell } from './shell.ts'

createShell('#app')
