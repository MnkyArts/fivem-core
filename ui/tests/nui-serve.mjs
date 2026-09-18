// core UI tests — FiveM's NUI scheme handler, faithfully (DESIGN §38.1, §38.15).
//
// One PORT = one ORIGIN = one RESOURCE, because that is what `https://cfx-nui-<resource>/` is: a
// separate origin per resource, served by the same in-process handler. Everything the CEF does to a
// request before it opens a file is reproduced here, and nothing else:
//
//   * the path is cut at the first `?` or `#` BEFORE the file is opened (a cache-busting query on a
//     module URL therefore re-evaluates NOTHING — the runtime's content-hash rule depends on it),
//   * `..` anywhere is refused,
//   * a miss is 404 with an EMPTY body,
//   * every response carries `access-control-allow-origin: *`, `access-control-allow-methods:
//     GET, OPTIONS` and `cache-control: no-cache, must-revalidate`, and NO etag / last-modified
//     (so the browser can never serve a stale plugin build out of its http cache),
//   * the content type comes from the extension alone, `js`/`mjs` -> application/javascript,
//   * the whole vfs path `resources:/<res>/<path>` is cut at 255 chars — a longer one is unreachable,
//   * only files packed by `files {}` exist: a per-resource allow-list of globs, a miss is a 404
//     exactly like a file that was never packed.
//
// On top of FiveM: a control endpoint (`/__control?op=…`, on the CONTROL resource's port only) that
// swaps the directory a resource serves — that is a `restart <res>` with a new build — plus the
// request log the suites assert on (e.g. "the inspector chunk was never fetched").
//
// What `unmount` is NOT: a plain `stop <res>` keeps serving the last files in FiveM (the client's
// resource stays mounted until a restart re-downloads it, §38.1), so a stopped resource is modelled
// by stopping the Lua side only — the origin answers exactly as before. `unmount` exists for the one
// moment where FiveM really does serve nothing: the window inside a restart, between the old mount
// being destroyed and the new content being mounted.
//
//   node ui/tests/nui-serve.mjs --map core=8821:../.. --map fx_alpha=8822:fixtures/fx_alpha --log
//   node ui/tests/nui-serve.mjs --config servers.json
//
// Programmatic (one process tree — a server started from another shell call gets killed):
//   import { startServers } from './nui-serve.mjs'
//   const farm = await startServers({ resources: [{ name, port, dir, files }] })
//   await farm.close()

import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))

/** `NUISchemeHandler.cpp` maps by extension only — there is no sniffing anywhere. */
const TYPES = {
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.json': 'application/json',
  '.map': 'application/json',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
  '.wav': 'audio/wav',
  '.ogg': 'audio/ogg',
}

/** FiveM cuts the whole vfs path at 255 chars (`NUISchemeHandler.cpp:124-127`). */
export const VFS_MAX = 255

function headers(type) {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, OPTIONS',
    'cache-control': 'no-cache, must-revalidate',
    'content-type': type || 'application/octet-stream',
  }
}

// ---------------------------------------------------------------- `files {}` globs

/** The fxmanifest glob dialect: `**` crosses folders, `*` does not, `?` is one char. */
export function globToRegExp(glob) {
  let out = '^'
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i]
    if (c === '*') {
      if (glob[i + 1] === '*') {
        i++
        if (glob[i + 1] === '/') i++
        out += '(?:.*)'
      } else {
        out += '[^/]*'
      }
    } else if (c === '?') out += '[^/]'
    else if ('\\^$.|+()[]{}'.includes(c)) out += '\\' + c
    else out += c
  }
  return new RegExp(out + '$')
}

function packed(rel, globs) {
  if (!globs || globs.length === 0) return true
  for (const g of globs) if (globToRegExp(g).test(rel)) return true
  return false
}

// ---------------------------------------------------------------- one resource

class Resource {
  constructor(spec) {
    this.name = spec.name
    this.port = Number(spec.port)
    this.dir = path.resolve(spec.dir)
    this.files = Array.isArray(spec.files) && spec.files.length ? spec.files.slice() : ['**']
    this.mounted = spec.mounted !== false
    this.requests = []
    this.server = null
  }

  /** `restart <res>` with a different build: a new directory behind the same origin. */
  swap(dir, files) {
    if (dir) this.dir = path.resolve(dir)
    if (Array.isArray(files) && files.length) this.files = files.slice()
    this.mounted = true
  }
}

// ---------------------------------------------------------------- the handler

function serve(resource, req, res, opts) {
  const started = Date.now()
  // Cut at the first ? or # — the scheme handler does this before it ever touches the vfs.
  let p = req.url || '/'
  const cut = p.search(/[?#]/)
  const query = cut >= 0 ? p.slice(cut) : ''
  if (cut >= 0) p = p.slice(0, cut)
  try {
    p = decodeURIComponent(p)
  } catch {
    /* an undecodable path is used raw, and will simply miss */
  }

  const done = (status, body, type) => {
    const h = headers(type)
    if (body) h['content-length'] = String(body.length)
    res.writeHead(status, h)
    res.end(req.method === 'HEAD' ? undefined : body)
    const entry = { t: Date.now() - started, res: resource.name, method: req.method, path: p, query, status, bytes: body ? body.length : 0 }
    resource.requests.push(entry)
    if (resource.requests.length > 2000) resource.requests.splice(0, resource.requests.length - 2000)
    if (opts.log) process.stdout.write(JSON.stringify(entry) + '\n')
  }

  if (req.method === 'OPTIONS') return done(204, null, 'text/plain; charset=utf-8')
  if (req.method !== 'GET' && req.method !== 'HEAD') return done(405, Buffer.alloc(0), 'text/plain; charset=utf-8')

  // Control first: it lives on ONE origin and its path can never be a real file.
  if (p === '/__control') {
    if (!opts.control) return done(404, Buffer.alloc(0))
    const body = Buffer.from(JSON.stringify(opts.control(new URLSearchParams(query.replace(/^[?#]/, '')))) + '\n')
    return done(200, body, 'application/json')
  }

  if (!resource.mounted) return done(404, Buffer.alloc(0))
  if (p.includes('..')) return done(403, Buffer.alloc(0), 'text/plain; charset=utf-8')

  let rel = p.replace(/^\/+/, '')
  if (rel === '' || rel.endsWith('/')) rel += 'index.html'

  // The vfs budget is measured on the whole path, exactly like §38.1 / the SDK's build check.
  if (('resources:/' + resource.name + '/' + rel).length >= VFS_MAX) return done(404, Buffer.alloc(0))
  // A file that `files {}` does not pack does not exist for the CEF.
  if (!packed(rel, resource.files)) return done(404, Buffer.alloc(0))

  const file = path.resolve(resource.dir, rel)
  if (!file.startsWith(resource.dir + path.sep) && file !== resource.dir) return done(403, Buffer.alloc(0), 'text/plain; charset=utf-8')
  let stat = null
  try {
    stat = fs.statSync(file)
  } catch {
    stat = null
  }
  if (!stat || !stat.isFile()) return done(404, Buffer.alloc(0))
  done(200, fs.readFileSync(file), TYPES[path.extname(file).toLowerCase()])
}

// ---------------------------------------------------------------- the farm

/**
 * @param {{ resources: Array<{name,port,dir,files?}>, control?: string, log?: boolean }} config
 */
export async function startServers(config) {
  const resources = config.resources.map((spec) => new Resource(spec))
  const byName = new Map(resources.map((r) => [r.name, r]))
  const controlName = config.control || (resources[0] && resources[0].name)

  const control = (params) => {
    const op = params.get('op') || 'state'
    const target = params.get('res') ? byName.get(params.get('res')) : null
    if (op === 'ping') return { ok: true, op }
    if (op === 'state') {
      return { ok: true, resources: resources.map((r) => ({ name: r.name, port: r.port, dir: r.dir, files: r.files, mounted: r.mounted, requests: r.requests.length })) }
    }
    if (op === 'requests') {
      const since = Number(params.get('since') || 0)
      const list = target ? target.requests : resources.flatMap((r) => r.requests)
      return { ok: true, requests: list.slice(since) }
    }
    if (op === 'reset-requests') {
      for (const r of target ? [target] : resources) r.requests.length = 0
      return { ok: true, op }
    }
    if (!target) return { ok: false, error: 'unknown resource "' + params.get('res') + '"' }
    if (op === 'swap') {
      const dir = params.get('dir')
      target.swap(dir ? path.resolve(config.root || process.cwd(), dir) : null, params.get('files') ? params.get('files').split(',') : null)
      return { ok: true, op, res: target.name, dir: target.dir, files: target.files }
    }
    if (op === 'unmount') {
      target.mounted = false
      return { ok: true, op, res: target.name }
    }
    if (op === 'mount') {
      target.mounted = true
      if (params.get('dir')) target.swap(path.resolve(config.root || process.cwd(), params.get('dir')), null)
      return { ok: true, op, res: target.name, dir: target.dir }
    }
    return { ok: false, error: 'unknown op "' + op + '"' }
  }

  await Promise.all(
    resources.map(
      (r) =>
        new Promise((resolve, reject) => {
          const opts = { log: !!config.log, control: r.name === controlName ? control : null }
          r.server = http.createServer((req, res) => {
            try {
              serve(r, req, res, opts)
            } catch (err) {
              res.writeHead(500, headers('text/plain; charset=utf-8'))
              res.end(String((err && err.message) || err))
            }
          })
          r.server.on('error', reject)
          r.server.listen(r.port, '127.0.0.1', () => resolve())
        }),
    ),
  )

  return {
    resources,
    byName,
    control,
    origin: (name) => 'http://127.0.0.1:' + byName.get(name).port,
    async close() {
      await Promise.all(resources.map((r) => new Promise((resolve) => r.server.close(resolve))))
    },
  }
}

// ---------------------------------------------------------------- CLI

function parseArgs(argv) {
  const config = { resources: [], log: false, root: process.cwd() }
  const filesFor = new Map()
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--log') config.log = true
    else if (arg === '--config') {
      const raw = JSON.parse(fs.readFileSync(path.resolve(argv[++i]), 'utf8'))
      Object.assign(config, raw)
    } else if (arg === '--control') config.control = argv[++i]
    else if (arg === '--map') {
      // <res>=<port>:<dir>
      const spec = argv[++i]
      const eq = spec.indexOf('=')
      const colon = spec.indexOf(':', eq + 1)
      config.resources.push({ name: spec.slice(0, eq), port: Number(spec.slice(eq + 1, colon)), dir: path.resolve(HERE, spec.slice(colon + 1)) })
    } else if (arg === '--files') {
      // <res>=<glob>[,<glob>…]
      const spec = argv[++i]
      const eq = spec.indexOf('=')
      filesFor.set(spec.slice(0, eq), spec.slice(eq + 1).split(','))
    } else if (arg === '-h' || arg === '--help') {
      process.stdout.write('usage: nui-serve.mjs --map <res>=<port>:<dir> [--files <res>=<glob>,…] [--control <res>] [--log]\n')
      process.exit(0)
    }
  }
  for (const r of config.resources) if (filesFor.has(r.name)) r.files = filesFor.get(r.name)
  return config
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  const config = parseArgs(process.argv.slice(2))
  if (!config.resources.length) {
    process.stderr.write('nui-serve: nothing to serve — pass --map <res>=<port>:<dir>\n')
    process.exit(2)
  }
  const farm = await startServers(config)
  for (const r of farm.resources) {
    process.stderr.write('[nui-serve] ' + r.name + ' -> http://127.0.0.1:' + r.port + '  (' + r.dir + ', files ' + r.files.join(' ') + ')\n')
  }
  const bye = () => {
    void farm.close().then(() => process.exit(0))
  }
  process.on('SIGINT', bye)
  process.on('SIGTERM', bye)
}
