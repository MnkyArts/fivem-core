// core UI runtime — scopes: the disposable bag every plugin/page owns (DESIGN §38.6, contract `Scope`).
//
// Everything the SDK hands a plugin (listeners, timers, rAF loops, request handlers, feed
// subscriptions) is registered in the scope of whoever asked for it, so a resource stop is one
// `dispose()` and never a leak hunt. Dispose is idempotent and LIFO, and every hook runs in its own
// try/catch — one bad disposer must not strand the ones after it.
//
// No DOM at module scope: `listen` takes its target, `raf` falls back to a timer when
// requestAnimationFrame is missing, so `node --test` can drive this file with no browser.

import { getCurrentScope, onScopeDispose } from 'vue'
import type { Off, Scope } from '../../sdk/src/contract.ts'

export interface ScopeCounts {
  listeners: number
  timers: number
  rafs: number
  hooks: number
}

export interface OwnedScope extends Scope {
  readonly label: string
  dispose(): void
  counts(): ScopeCounts
}

const NOOP: Off = () => {}

interface Env {
  raf: ((cb: (now: number) => void) => number) | null
  cancelRaf: ((handle: number) => void) | null
  now(): number
}

const env: Env = {
  raf: typeof requestAnimationFrame === 'function' ? requestAnimationFrame.bind(globalThis) : null,
  cancelRaf: typeof cancelAnimationFrame === 'function' ? cancelAnimationFrame.bind(globalThis) : null,
  now: () => (typeof performance !== 'undefined' && performance.now ? performance.now() : Date.now()),
}

/** Test seam: swap rAF/now. `configure({})` leaves everything as it is. */
export function configureScopes(partial: Partial<Env>): void {
  if (partial.raf !== undefined) env.raf = partial.raf
  if (partial.cancelRaf !== undefined) env.cancelRaf = partial.cancelRaf
  if (partial.now !== undefined) env.now = partial.now
}

let active: OwnedScope | null = null

/** The scope currently being set up (plugin `setup`, a component's `setup`). */
export function currentScope(): OwnedScope | null {
  return active
}

/** Runs `fn` with `scope` as `currentScope()`; restores the previous one even when `fn` throws. */
export function withScope<T>(scope: OwnedScope | null, fn: () => T): T {
  const prev = active
  active = scope
  try {
    return fn()
  } finally {
    active = prev
  }
}

/**
 * Ties a release to whoever owns the call: the COMPONENT being set up (Vue's effect scope), the
 * page scope that was injected into it, and the plugin scope of a running `setup`. It binds to every
 * owner that exists rather than the first one — the release is idempotent, so the earliest death
 * wins and `plugin:unregister` can never leave a subscription behind a component that is still
 * waiting to unmount.
 *
 * Returns false when there was no owner at all: the caller then keeps the resource forever and says
 * so (§38.12's module-scope rule).
 */
export function bindRelease(off: Off, fallback?: OwnedScope | null): boolean {
  let bound = false
  if (getCurrentScope()) {
    onScopeDispose(off)
    bound = true
  }
  if (fallback && !fallback.disposed) {
    fallback.onDispose(off)
    bound = true
  }
  const scope = active
  if (scope && !scope.disposed) {
    scope.onDispose(off)
    bound = true
  }
  return bound
}

/**
 * A fresh scope. `label` is what the inspector and the `[UI] … cleaned n listeners` line print.
 *
 * After `dispose()` every method is a no-op that returns a no-op, so a plugin that keeps a
 * reference to a dead scope degrades quietly instead of re-arming a timer nobody owns.
 */
export function createScope(label: string): OwnedScope {
  let disposed = false
  const hooks: Array<() => void> = []
  const counts: ScopeCounts = { listeners: 0, timers: 0, rafs: 0, hooks: 0 }

  /** Registers a hook and returns the remover. Every public method funnels through this. */
  function add(fn: () => void, kind: keyof ScopeCounts): Off {
    if (disposed) {
      try {
        fn()
      } catch (err) {
        console.error('[core:ui] scope ' + label + ': late disposer failed', err)
      }
      return NOOP
    }
    counts[kind]++
    let live = true
    const wrapped = () => {
      if (!live) return
      live = false
      counts[kind]--
      fn()
    }
    hooks.push(wrapped)
    return () => {
      if (!live) return
      const i = hooks.indexOf(wrapped)
      if (i !== -1) hooks.splice(i, 1)
      wrapped()
    }
  }

  const scope: OwnedScope = {
    label,
    get disposed() {
      return disposed
    },

    onDispose(fn: () => void): Off {
      if (typeof fn !== 'function') return NOOP
      return add(fn, 'hooks')
    },

    listen(target: EventTarget, type: string, fn: (e: never) => void, opts?: AddEventListenerOptions | boolean): Off {
      if (!target || typeof target.addEventListener !== 'function' || typeof fn !== 'function') return NOOP
      const handler = fn as unknown as EventListener
      target.addEventListener(type, handler, opts as AddEventListenerOptions)
      return add(() => target.removeEventListener(type, handler, opts as AddEventListenerOptions), 'listeners')
    },

    timeout(fn: () => void, ms: number): Off {
      if (typeof fn !== 'function') return NOOP
      let off: Off = NOOP
      const handle = setTimeout(() => {
        off()
        fn()
      }, ms)
      off = add(() => clearTimeout(handle), 'timers')
      return off
    },

    interval(fn: () => void, ms: number): Off {
      if (typeof fn !== 'function') return NOOP
      const handle = setInterval(fn, ms)
      return add(() => clearInterval(handle), 'timers')
    },

    raf(fn: (now: number) => boolean | void): Off {
      if (typeof fn !== 'function') return NOOP
      let stopped = false
      let handle: number | ReturnType<typeof setTimeout> | null = null
      const schedule = () => {
        if (env.raf) handle = env.raf(step)
        else handle = setTimeout(() => step(env.now()), 16)
      }
      const step = (now: number) => {
        handle = null
        if (stopped) return
        let again: boolean | void = true
        try {
          again = fn(now)
        } catch (err) {
          console.error('[core:ui] scope ' + label + ': rAF callback failed', err)
          again = false
        }
        if (again === false) {
          off()
          return
        }
        schedule()
      }
      const off = add(() => {
        stopped = true
        if (handle == null) return
        if (env.raf && env.cancelRaf) env.cancelRaf(handle as number)
        else clearTimeout(handle as ReturnType<typeof setTimeout>)
        handle = null
      }, 'rafs')
      schedule()
      return off
    },

    dispose(): void {
      if (disposed) return
      disposed = true
      // LIFO: a plugin's `setup` disposer runs before the things it created underneath it.
      for (let i = hooks.length - 1; i >= 0; i--) {
        const hook = hooks[i]
        try {
          hook()
        } catch (err) {
          console.error('[core:ui] scope ' + label + ': disposer failed', err)
        }
      }
      hooks.length = 0
      counts.listeners = 0
      counts.timers = 0
      counts.rafs = 0
      counts.hooks = 0
      if (active === scope) active = null
    },

    counts(): ScopeCounts {
      return { listeners: counts.listeners, timers: counts.timers, rafs: counts.rafs, hooks: counts.hooks }
    },
  }

  return scope
}
