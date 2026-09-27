--[[
    core/server/maps_runtime.lua — the world side of Core.Maps (DESIGN §52.2, §55.21.1): a PROJECTOR onto Core.Scene.
    Internal: extends `Core.MapsRuntime` (R, created by maps_types.lua, which loads first and holds the node
    definitions: R.nodeDef — the kind mapping, the per-uid paint, the promotion policy of editor / target buckets).

      contexts     one per (map, bucket) whose content is ACTIVE: a live map's elements or a draft's published
                   snapshot in its targetBucket, a draft's working copy in its editor bucket
      projection   every shown element is ONE Core.Scene node owned by core, persist = false (the map documents
                   are the truth; nodes are rebuilt at start), in the context's bucket, fields.mapEl = the uid
                   '<mapId>:<elementId>', fields.mapType = the type id. A change keeps the node id per (bucket,
                   uid): Scene.move when the pose changed, Scene.set with the changed fields (a promoted node is
                   demoted by Scene first); only another scene kind (or policy) re-creates it (remove + spawn).
                   Every Scene call runs AS CORE (Registry.withCaller), whoever called Core.Maps.
      slicing      what is shown, the counts and the events change synchronously; the NODES follow through
                   reconcile(ctx, id) — idempotent: the element as it is now against the node that exists. A change
                   of <= SLICE elements (an apply, a small swap or context) is reconciled inline; anything larger (an
                   activation, a first publish, openDraft, a context closing, the boot projection, a type refresh,
                   a clear) is queued per (context, element id) — a later change or a deactivation supersedes a
                   queued entry — and ONE worker thread (alive only while the queue holds work) makes <= SLICE Scene
                   calls per server tick inside Scene.batch, Wait(0) between slices. A closed context keeps its
                   nodes until the worker removed them; re-opening it (same map and bucket) adopts the nodes still
                   standing instead of making them again. R.stats() counts what exists and what is queued.
      removals     an element an apply deleted, everything of a draft's editor bucket and a node re-created for
                   another kind fade out on the clients (Scene.remove(id, { fade = true })); a live / published
                   context switched off, expired or swapped by a publish leaves visibility-safely (the default)
      capacity     a spawn refused 'limit' (core's owner cap, the global node cap) waits in its context's retry
                   set: one thread (alive only while something waits) queues them again after 5 s, doubling to
                   60 s while nothing gets placed (back to 5 s once something is); for 1 s after a 'limit' answer
                   spawns are not tried (they would be refused too) unless one of our nodes was removed meanwhile
      readiness    nothing is projected before the Scene store loaded (R.store.loaded()): the bookkeeping, the
                   counts and the events go on, the queue waits, and one waiter thread (bounded waits, only while
                   something waits) starts the worker once the store is there. While a worker run lasts
                   PUBLISH_AFTER slices or more, GlobalState['core:mapsPending'] = { { bucket, x1, y1, x2, y2 }, … }
                   boxes the queued work per bucket (client/maps.lua: isAreaReady / waitAreaReady say not ready
                   inside a box of the player's bucket); cleared when the run ends, at core start and stop
      respawn      Maps.respawn puts nodes back to their authored state: a promoted, displaced or changed node gets
                   Scene.move / Scene.set (a promoted clone is demoted); a missing one is reconciled (queued when
                   more than SLICE are missing)
      events       Maps.on(typeId|'*', fn) listeners get 'added'|'changed'|'removed' for active content (queued
                   here while the bookkeeping changes, delivered by maps_types.lua's drain); Maps.records(typeId)

    A context holds a REFERENCE to its element table ({ [elementId] = element }); maps.lua replaces element
    tables on change (never mutates one in place), so a context always sees the current content and a diff
    only compares updatedAt. The `networked` / `networkedTotal` limits count the vehicle, ped and networked-prop
    elements of every active context (ctx.netCount, R.netTotal()) whether their node exists or not.
    Core.Scene and Core.SceneRuntime are looked up at call time: the scene files load after the map files.

    Natives: GetGameTimer (server, CFX). GlobalState, CreateThread, Wait and AddEventHandler are runtime helpers.
]]

local R = Core.MapsRuntime
assert(R and R.types and R.nodeDef and R.emit, 'server/maps_types.lua must load before server/maps_runtime.lua')

local Log = Core.Log
local Utils = Core.Utils
local Registry = Core.Registry

local type, pairs, next, tonumber, tostring, mtype = type, pairs, next, tonumber, tostring, math.type

local types, defOf, uidOf = R.types, R.nodeDef, R.uidOf
local emit, flushEvents, recordOf = R.emit, R.flushEvents, R.recordOf   -- the event queue (maps_types.lua)
local DATA_KIND <const> = R.DATA_KIND           -- point, zone, placeholder: the editor view's previews

local DATA_RADIUS <const> = 150                 -- the editor view distance (metres)
local LABELS_MAX <const> = 16
local WAIT_FAST_MS <const>, WAIT_SLOW_MS <const>, WAIT_FAST_FOR_MS <const> = 100, 1000, 5000
local WAIT_WARN_MS <const> = 30000
local LOG_EVERY_MS <const> = 60000
local TOL_M <const>, TOL_DEG <const> = 0.001, 0.01   -- respawn: "at its authored pose"
local SLICE <const> = 200                       -- Scene calls per worker slice; the largest change reconciled inline
local SLICE_ITEMS <const> = 4000                -- queue entries one slice looks at (stale ones, deferred spawns)
local RETRY_MIN_MS <const>, RETRY_MAX_MS <const> = 5000, 60000   -- 'limit' refusals: the retry backoff
local LIMIT_HOLD_MS <const> = 1000              -- after a 'limit' answer spawns wait this long (or for a removal)
local PENDING_KEY <const> = 'core:mapsPending'  -- GlobalState: the boxes of a long projection, per bucket
local PUBLISH_AFTER <const> = 3                 -- slices a worker run lasts before its boxes are published
local FADE <const> = { fade = true }
R.SLICE = SLICE

local loggedAt = {}                             -- key -> GetGameTimer() of its last line

--- One line per key per minute: a map of 3,000 elements that all fail must not print 3,000 lines.
local function logLimited(level, key, fmt, ...)
    local now = GetGameTimer()
    local last = loggedAt[key]
    if last and now - last < LOG_EVERY_MS then return end
    loggedAt[key] = now
    Log[level](fmt, ...)
end

local function warnLimited(key, fmt, ...) logLimited('warn', key, fmt, ...) end

--------------------------------------------------------------------------------
-- The Scene bridge: readiness, calls as core, the map:data kind
--------------------------------------------------------------------------------

--- Core.Scene once the scene files loaded AND its store loaded (persistent nodes in, ids settled), else nil.
local function scene()
    local Scene = Core.Scene
    local SR = rawget(Core, 'SceneRuntime')
    local store = type(SR) == 'table' and SR.store or nil
    if type(Scene) ~= 'table' or type(Scene.spawn) ~= 'function' or type(store) ~= 'table'
        or type(store.loaded) ~= 'function' or store.loaded() ~= true then
        return nil
    end
    return Scene
end

local calls = 0                                 -- Scene calls made (a worker slice counts its budget in them)

--- Scene[name](...) as core — the owner of every map node, whoever called Core.Maps — -> its results; a Lua
--- error inside Scene is logged (once a minute per function) and answers false, 'error'.
local function asCore(Scene, name, ...)
    calls = calls + 1
    local res = table.pack(Registry.withCaller('core', Scene[name], ...))
    if not res[1] then
        logLimited('error', 'error:' .. name, 'maps: Scene.%s failed: %s (further errors of it are not logged for a '
            .. 'minute)', name, tostring(res[2]))
        return false, 'error'
    end
    return table.unpack(res, 2, res.n)
end

--- `f` of a map:data node: <= 16 label values keyed by field name, strings <= 64 characters.
local function labelsOk(v)
    if type(v) ~= 'table' then return false, 'labels' end
    local n = 0
    for k, s in pairs(v) do
        n = n + 1
        if n > LABELS_MAX or type(k) ~= 'string' or #k > 48 or not k:find('^[%a_][%w_]*$')
            or type(s) ~= 'string' or #s > 64 then
            return false, 'labels'
        end
    end
    return true
end

-- The editor-only data kind (§55.21.1): t = type id, k = element kind ('point' | 'zone' | 'placeholder'),
-- size = a zone's box, f = the values its type's '$field' label previews show. client/maps_preview.lua draws it.
local DATA_DEF <const> = { id = DATA_KIND, class = 'data', radius = DATA_RADIUS, fields = {
    { name = 't', type = 'string', maxLength = 64, required = true },
    { name = 'k', type = 'string', maxLength = 16, pattern = '^%a+$', required = true },
    { name = 'size', type = 'vector3', min = 0.1, max = 1000 },
    { name = 'f', type = 'table', validate = labelsOk },
    { name = 'mapEl', type = 'string', maxLength = 48 },
    { name = 'mapType', type = 'string', maxLength = 64 },
} }

local kindDefined = false

--- Defines map:data (as core) once. core's start does it before any plugin could take the id; a map:data
--- spawn tries again when that failed.
local function defineDataKind()
    if kindDefined then return true end
    local Scene = Core.Scene
    if type(Scene) ~= 'table' or type(Scene.defineKind) ~= 'function' then return false end
    local ok, err = asCore(Scene, 'defineKind', DATA_DEF)
    if ok then
        kindDefined = true
    else
        warnLimited('kind', 'maps: the scene kind %s was refused: %s', DATA_KIND, tostring(err))
    end
    return kindDefined
end

--------------------------------------------------------------------------------
-- Projection state: contexts, the queue of pending reconciles, the retry set, the pending boxes
--------------------------------------------------------------------------------

local contexts = {}         -- [ctxKey] = ctx (active)
local closing = {}          -- [ctxKey] = ctx: closed, the worker still removes its nodes
local byMap = {}            -- [mapId] = { [bucket] = ctx }
local netTotal = 0          -- networked elements shown in every context (their nodes may not exist yet)
-- the queue: (context, element id) entries, FIFO; an entry whose flag ctx.queued[id] was cleared meanwhile is stale
local qc, qi, qh, qn = {}, {}, 1, 0
local nQueued = 0           -- flags set (reconciles still due)
local working, waiting, stopping, unavailable = false, false, false, false
local retryN, retrying, backoff, roundMark = 0, false, RETRY_MIN_MS, 0
local placed = 0            -- successful spawns (the retry thread's progress mark)
local heldUntil = 0         -- GetGameTimer() until which spawns are not tried after a 'limit' answer
local pend = {}             -- [bucket] = { n = flags set, x1, y1, x2, y2 = the box of their elements / nodes }
local pendDirty, published = false, false
local kick, whenReady, reconcile            -- forward declarations

local function failed(ctx, id, what, err)
    warnLimited(what .. ':' .. tostring(err), 'maps: %s of %s in bucket %d failed: %s (further %s failures of this '
        .. 'kind are not logged for a minute)', what, uidOf(ctx.mapId, id), ctx.bucket, tostring(err), what)
end

--- Numeric element ids in ascending order (deterministic passes and event order).
local function byId(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb and na ~= nb then return na < nb end
    return a < b
end

--- The keys of `t` sorted by byId. Element ids are canonical digit strings: they sort as integers (native
--- comparisons, ~5x faster than the comparator on 20,000 ids); anything else falls back to the comparator.
local function sortedIds(t)
    local ids, n = {}, 0
    for id in pairs(t) do
        local v = type(id) == 'string' and tonumber(id) or nil
        if mtype(v) ~= 'integer' then
            n = -1
            break
        end
        n = n + 1
        ids[n] = v
    end
    if n >= 0 then
        table.sort(ids)
        for i = 1, n do
            local s = tostring(ids[i])
            if t[s] == nil then                 -- not canonical ('007'): the comparator decides
                n = -1
                break
            end
            ids[i] = s
        end
        if n >= 0 then return ids end
    end
    ids = {}
    for id in pairs(t) do ids[#ids + 1] = id end
    table.sort(ids, byId)
    return ids
end
R.sortedIds = sortedIds

--- The box of a bucket's queued work grows by the element's position (else its node's: a removal).
local function pendAdd(ctx, id)
    local b = ctx.bucket
    local p = pend[b]
    if not p then
        p = { n = 0 }
        pend[b] = p
    end
    p.n = p.n + 1
    local el, have = ctx.els[id], ctx.nodes[id]
    local pos = el and el.pos or (have and have.def.pos)
    if not pos then return end
    local x, y = pos.x, pos.y
    if not p.x1 then
        p.x1, p.y1, p.x2, p.y2, pendDirty = x, y, x, y, true
        return
    end
    if x < p.x1 then p.x1, pendDirty = x, true elseif x > p.x2 then p.x2, pendDirty = x, true end
    if y < p.y1 then p.y1, pendDirty = y, true elseif y > p.y2 then p.y2, pendDirty = y, true end
end

local function pendSub(b)
    local p = pend[b]
    if not p then return end
    p.n = p.n - 1
    if p.n <= 0 then
        pend[b] = nil
        pendDirty = true
    end
end

--- GlobalState[PENDING_KEY]: the boxes of the queued work, written only when they changed (a long run's start,
--- a bucket finished, the run's end) — never for inline work.
local function publish()
    if not pendDirty then return end
    pendDirty = false
    local list
    for b, p in pairs(pend) do
        if p.x1 then
            list = list or {}
            list[#list + 1] = { b, p.x1, p.y1, p.x2, p.y2 }
        end
    end
    if list == nil and not published then return end
    published = list ~= nil
    GlobalState[PENDING_KEY] = list
end

--- Queues the reconcile of element `id` of `ctx` (once: a queued id is not queued again).
local function dirty(ctx, id)
    local q = ctx.queued
    if q[id] then return end
    q[id] = true
    nQueued = nQueued + 1
    qn = qn + 1
    qc[qn], qi[qn] = ctx, id
    pendAdd(ctx, id)
end

--- Clears the flag of a queued id (its queue entry turns stale) -> whether it was queued.
local function undirty(ctx, id)
    if not ctx.queued[id] then return false end
    ctx.queued[id] = nil
    nQueued = nQueued - 1
    pendSub(ctx.bucket)
    return true
end

local function dropRetry(ctx, id)
    if ctx.retry[id] then
        ctx.retry[id] = nil
        retryN = retryN - 1
    end
end

--- One thread while elements wait for scene capacity: queues them again after `backoff`, which doubles (<= 60 s)
--- while no spawn succeeded since the round before and falls back to 5 s once one did.
local function startRetry()
    if retrying or stopping then return end
    retrying = true
    roundMark = placed
    CreateThread(function()
        while retryN > 0 and not stopping do
            Wait(backoff)
            if stopping then break end
            warnLimited('retry', 'maps: %d element(s) wait for scene capacity (limit); retrying them (next try in '
                .. 'at most %d s)', retryN, RETRY_MAX_MS // 1000)
            heldUntil = 0
            local list = {}
            for _, ctx in pairs(contexts) do list[#list + 1] = ctx end
            for i = 1, #list do
                local ctx = list[i]
                for id in pairs(ctx.retry) do
                    ctx.retry[id] = nil
                    retryN = retryN - 1
                    dirty(ctx, id)
                end
            end
            kick()
            backoff = placed > roundMark and RETRY_MIN_MS or math.min(backoff * 2, RETRY_MAX_MS)
            roundMark = placed
        end
        retrying = false
    end)
end

--- The element waits for capacity (its spawn was refused 'limit', or would be).
local function deferLimit(ctx, id)
    if not ctx.retry[id] then
        ctx.retry[id] = true
        retryN = retryN + 1
    end
    startRetry()
end

--- Removes the element's node, if it has one (faded out on the clients when `fade`).
local function unproject(ctx, id, fade)
    local have = ctx.nodes[id]
    if not have then return end
    ctx.nodes[id] = nil
    local Scene = scene()
    if Scene then
        local ok, err = asCore(Scene, 'remove', have.id, fade and FADE or nil)
        if ok then
            heldUntil = 0                       -- one of core's nodes is gone: a spawn may pass again
        elseif err ~= 'missing' then
            failed(ctx, id, 'remove', err)
        end
    end
    if ctx.closed and closing[ctx.key] == ctx and next(ctx.nodes) == nil then closing[ctx.key] = nil end
end

local function samePose(a, b)
    local p, q, r, s = a.pos, b.pos, a.rot, b.rot
    return p.x == q.x and p.y == q.y and p.z == q.z and r.x == s.x and r.y == s.y and r.z == s.z
end

--- Deep equality of plain data (node fields).
local function same(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do
        if not same(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- The fields of `want` that differ from `have` -> patch | nil, removed names (sorted) | nil.
local function fieldDiff(have, want)
    local patch, removed
    for k, v in pairs(want) do
        if not same(v, have[k]) then
            patch = patch or {}
            patch[k] = v
        end
    end
    for k in pairs(have) do
        if want[k] == nil then
            removed = removed or {}
            removed[#removed + 1] = k
        end
    end
    if removed then table.sort(removed) end
    return patch, removed
end

--- Brings the node of a SHOWN element in line with it: spawn; Scene.move / Scene.set on the same node (a
--- promoted one is demoted by Scene first); remove (faded) + spawn when the scene kind or the policy changed. A
--- node that went missing is spawned again.
local function project(ctx, el)
    local Scene = scene()
    if not Scene then                           -- (callers checked it; should the store go, the waiter starts over)
        unavailable = true
        return dirty(ctx, el.id)
    end
    local have = ctx.nodes[el.id]
    if not have and GetGameTimer() < heldUntil then return deferLimit(ctx, el.id) end
    local want = defOf(ctx, el)
    if have and want and have.def.kind == want.kind and have.def.authority == want.authority then
        if not samePose(have.def, want) then
            local ok, err = asCore(Scene, 'move', have.id, want.pos, want.rot)
            if ok then
                have.def.pos, have.def.rot = want.pos, want.rot
            elseif err == 'missing' then
                ctx.nodes[el.id], have = nil, nil
            else
                failed(ctx, el.id, 'move', err)
            end
        end
        if have then
            local patch, removed = fieldDiff(have.def.fields, want.fields)
            if patch or removed then
                local ok, err = asCore(Scene, 'set', have.id, patch or {}, removed and { remove = removed } or nil)
                if ok then
                    have.def.fields = want.fields
                elseif err == 'missing' then
                    ctx.nodes[el.id], have = nil, nil
                else
                    failed(ctx, el.id, 'set', err)
                end
            end
            if have then return dropRetry(ctx, el.id) end
        end
    elseif have then
        unproject(ctx, el.id, true)             -- another kind: the old copy fades while the new one comes
    end
    if not want then return end
    if GetGameTimer() < heldUntil then return deferLimit(ctx, el.id) end
    if want.kind == DATA_KIND then defineDataKind() end
    local id, err = asCore(Scene, 'spawn', want)
    if id then
        ctx.nodes[el.id] = { id = id, def = want }
        placed = placed + 1
        dropRetry(ctx, el.id)
    elseif err == 'limit' then
        heldUntil = GetGameTimer() + LIMIT_HOLD_MS
        failed(ctx, el.id, 'spawn', err)
        deferLimit(ctx, el.id)
    elseif err == 'unavailable' then            -- the store went away under us: the waiter starts over
        unavailable = true
        dirty(ctx, el.id)
    else
        failed(ctx, el.id, 'spawn', err)
    end
end

-- fxlint-disable-next-line C003 -- assigns the forward-declared local `reconcile` (settle and the worker call it)
reconcile = function(ctx, id)
    local fade = ctx.fading[id]
    if fade then ctx.fading[id] = nil end
    local el = ctx.reps[id] and ctx.els[id]
    if el then return project(ctx, el) end
    dropRetry(ctx, id)
    unproject(ctx, id, fade or ctx.source == 'draft')
end

--- The worker's unit of work: <= SLICE Scene calls, <= SLICE_ITEMS queue entries.
local function runSlice()
    local budget, seen = calls + SLICE, 0
    while qh <= qn and calls < budget and seen < SLICE_ITEMS and not (stopping or unavailable) do
        local ctx, id = qc[qh], qi[qh]
        qc[qh], qi[qh] = nil, nil
        qh = qh + 1
        seen = seen + 1
        if undirty(ctx, id) then reconcile(ctx, id) end
    end
end

--- ONE thread while the queue holds work: a slice per server tick (inside Scene.batch: one flush), Wait(0) between.
local function worker()
    local slices = 0
    while qh <= qn and not stopping do
        local Scene = scene()
        if not Scene or unavailable then break end
        local batch = Scene.batch
        if type(batch) == 'function' then
            batch(runSlice)
        else
            local ok, err = pcall(runSlice)
            if not ok then logLimited('error', 'slice', 'maps: a projection slice failed: %s', tostring(err)) end
        end
        slices = slices + 1
        if slices >= PUBLISH_AFTER then publish() end
        -- fxlint-disable-next-line P002 -- only while the queue holds work: the thread ends when it drained
        if qh <= qn and not (stopping or unavailable) then Wait(0) end
    end
    working = false
    if qh > qn then
        qc, qi, qh, qn = {}, {}, 1, 0
        if not stopping then publish() end      -- the run is over: its boxes go
    elseif unavailable or not scene() then
        whenReady()
    end
end

-- fxlint-disable-next-line C003 -- assigns the forward-declared local `kick`
kick = function()
    if working or stopping or qh > qn then return end
    if unavailable or not scene() then return whenReady() end
    working = true
    CreateThread(worker)
end

--- One thread, only while the queue waits for the Scene store: bounded waits (100 ms for 5 s, then 1 s), one
--- warning after 30 s; once the store is there the worker takes the queue.
-- fxlint-disable-next-line C003 -- assigns the forward-declared local `whenReady`
whenReady = function()
    if waiting or stopping then return end
    waiting = true
    CreateThread(function()
        local waited, warned = 0, false
        repeat
            local ms = waited < WAIT_FAST_FOR_MS and WAIT_FAST_MS or WAIT_SLOW_MS
            Wait(ms)
            waited = waited + ms
            if not warned and waited >= WAIT_WARN_MS and not scene() then
                warned = true
                Log.warn('maps: the Core.Scene store has not loaded after %d s; map content waits for it',
                    waited // 1000)
            end
        until stopping or scene()
        waiting, unavailable = false, false
        kick()
    end)
end

--- The nodes of `ids` (an array, `n` long) of a context follow their elements: inline when they are few and the
--- store is there, else through the queue.
local function settle(ctx, ids, n)
    n = n or #ids
    if n == 0 then return end
    if n <= SLICE and not unavailable and scene() then
        for i = 1, n do
            undirty(ctx, ids[i])
            reconcile(ctx, ids[i])
        end
    else
        for i = 1, n do dirty(ctx, ids[i]) end
    end
    kick()
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= Core.name then return end
    if GlobalState[PENDING_KEY] ~= nil then GlobalState[PENDING_KEY] = nil end   -- a crashed run's boxes: gone
    defineDataKind()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    stopping = true                             -- the worker, the waiter and the retry thread end on their next wake
    if published then
        published = false
        GlobalState[PENDING_KEY] = nil
    end
end)

--------------------------------------------------------------------------------
-- Respawn: nodes back to their authored state
--------------------------------------------------------------------------------

local function near(a, b) return math.abs(a - b) <= TOL_M end

local function nearDeg(a, b)
    local d = (a - b) % 360
    return math.min(d, 360 - d) <= TOL_DEG
end

--- Maps.respawn for one shown element -> true (moved back / reset), 'missing' (no node, or one of another kind:
--- removed; the caller reconciles it) or false (as authored).
local function respawnOne(Scene, ctx, el)
    local want = defOf(ctx, el)
    if not want then return false end
    local have = ctx.nodes[el.id]
    local node = have and asCore(Scene, 'get', have.id) or nil
    if type(node) ~= 'table' or node.kind ~= want.kind then
        unproject(ctx, el.id, true)             -- (a node that is really gone answers 'missing': fine)
        return 'missing'
    end
    local p, r, w, v = node.pos, node.rot, want.pos, want.rot
    local displaced = node.promoted ~= nil or not (near(p.x, w.x) and near(p.y, w.y) and near(p.z, w.z)
        and nearDeg(r.x, v.x) and nearDeg(r.y, v.y) and nearDeg(r.z, v.z))
    local patch
    for k, value in pairs(want.fields) do
        if not same(value, node.fields and node.fields[k]) then
            patch = patch or {}
            patch[k] = value
        end
    end
    if not displaced and not patch then
        have.def = want
        return false
    end
    if displaced then                           -- Scene demotes a promoted node at the authored pose first
        local ok, err = asCore(Scene, 'move', have.id, want.pos, want.rot)
        if not ok then
            failed(ctx, el.id, 'respawn', err)
            return false
        end
        have.def.pos, have.def.rot = want.pos, want.rot
    end
    if patch then
        local ok, err = asCore(Scene, 'set', have.id, patch)
        if not ok then
            failed(ctx, el.id, 'respawn', err)
            return displaced
        end
    end
    have.def = want
    return true
end

--------------------------------------------------------------------------------
-- Contexts: active content per (map, bucket)
--------------------------------------------------------------------------------

local function ctxKeyOf(mapId, bucket)
    return mapId .. '@' .. bucket
end

--- 'net' for what the networked limits count (vehicle, ped, networked prop), 'node' for everything else
--- (placeholders included).
local function repOf(el)
    return R.isNetworked(types[el.type]) and 'net' or 'node'
end

local function count(ctx, rep, d)
    if rep == 'net' then ctx.netCount, netTotal = ctx.netCount + d, netTotal + d end
end

--- A changed element (or type): the counts follow its representation (its node follows through settle).
local function reshow(ctx, el)
    local was, now = ctx.reps[el.id], repOf(el)
    if was ~= now then
        ctx.reps[el.id] = now
        count(ctx, was, -1)
        count(ctx, now, 1)
    end
end

--- A new element (an element that is shown already is only re-shown: never counted twice).
local function show(ctx, el)
    if ctx.reps[el.id] then return reshow(ctx, el) end
    local rep = repOf(el)
    ctx.reps[el.id] = rep
    count(ctx, rep, 1)
end

local function hide(ctx, id)
    local rep = ctx.reps[id]
    if not rep then return false end
    ctx.reps[id] = nil
    count(ctx, rep, -1)
    return true
end

--- The nodes a context that closed moments ago still has standing: the new context of the same map and bucket
--- takes them over (reconciled like any change: kept, moved, set or removed) instead of making them again. The ids
--- of adopted nodes whose element this content lacks are appended to `ids` (they go).
local function adopt(ctx, old, ids)
    closing[old.key] = nil
    for id in pairs(old.queued) do undirty(old, id) end     -- its queue entries turn stale
    ctx.nodes, old.nodes = old.nodes, {}
    local extra = {}
    for id in pairs(ctx.nodes) do
        if not ctx.els[id] then extra[#extra + 1] = id end
    end
    table.sort(extra, byId)
    for i = 1, #extra do ids[#ids + 1] = extra[i] end
end

--- Activates `els` of `mapId` in `bucket`. source: 'live' | 'published' | 'draft' (the editor bucket).
function R.openContext(mapId, bucket, source, els)
    local key = ctxKeyOf(mapId, bucket)
    if contexts[key] then return contexts[key] end
    local ctx = { key = key, mapId = mapId, bucket = bucket, source = source, els = els, reps = {}, nodes = {},
        queued = {}, fading = {}, retry = {}, netCount = 0, closed = false }
    contexts[key] = ctx
    byMap[mapId] = byMap[mapId] or {}
    byMap[mapId][bucket] = ctx
    local ids = sortedIds(els)
    for i = 1, #ids do
        local el = els[ids[i]]
        if el then
            show(ctx, el)
            emit('added', ctx, el)
        end
    end
    local old = closing[key]
    if old then adopt(ctx, old, ids) end
    settle(ctx, ids)
    flushEvents()
    return ctx
end

--- Deactivates a context: what it showed leaves at once (counts, events), its nodes follow (inline, or sliced by
--- the worker; faded for a draft's editor bucket).
function R.closeContext(mapId, bucket)
    local key = ctxKeyOf(mapId, bucket)
    local ctx = contexts[key]
    if not ctx then return false end
    local ids = sortedIds(ctx.reps)
    for i = 1, #ids do
        local id = ids[i]
        hide(ctx, id)
        local el = ctx.els[id]
        if el then emit('removed', ctx, el) end
    end
    contexts[key] = nil
    byMap[mapId][bucket] = nil
    if next(byMap[mapId]) == nil then byMap[mapId] = nil end
    ctx.closed = true
    for id in pairs(ctx.retry) do dropRetry(ctx, id) end
    local gone, have = {}, 0
    for i = 1, #ids do
        if ctx.nodes[ids[i]] then gone[#gone + 1] = ids[i] end
    end
    for _ in pairs(ctx.nodes) do have = have + 1 end
    if have > #gone then gone = sortedIds(ctx.nodes) end   -- nodes of elements hidden before (their removal queued)
    if #gone > 0 then
        closing[key] = ctx
        settle(ctx, gone)
    end
    flushEvents()
    return true
end

--- Replaces a context's content (publish / rollback): only what differs (id, type, updatedAt) is touched.
function R.swapContext(mapId, bucket, els)
    local ctx = contexts[ctxKeyOf(mapId, bucket)]
    if not ctx then return false end
    local old = ctx.els
    ctx.els = els
    local touched = {}
    local gone = sortedIds(old)
    for i = 1, #gone do
        local id = gone[i]
        if not els[id] and hide(ctx, id) then
            emit('removed', ctx, old[id])
            touched[#touched + 1] = id
        end
    end
    local ids = sortedIds(els)
    for i = 1, #ids do
        local el, prev = els[ids[i]], old[ids[i]]
        if el and not ctx.reps[el.id] then
            show(ctx, el)
            emit('added', ctx, el)
            touched[#touched + 1] = el.id
        elseif el and (not prev or prev.updatedAt ~= el.updatedAt or prev.type ~= el.type) then
            reshow(ctx, el)
            emit('changed', ctx, el)
            touched[#touched + 1] = el.id
        end
    end
    settle(ctx, touched)
    flushEvents()
    return true
end

--- After an apply on a map's working set: every context showing it (`source` 'live' or 'draft') re-renders the
--- touched ids. ids = ordered array, before = { [id] = element|false } (false: new). An element the apply deleted
--- fades out (an editor watches it go).
function R.applyChanges(mapId, source, ids, before)
    local ctxs = byMap[mapId]
    if not ctxs then return end
    local list = {}
    for _, ctx in pairs(ctxs) do
        if ctx.source == source then list[#list + 1] = ctx end
    end
    for c = 1, #list do
        local ctx = list[c]
        local touched = {}
        for i = 1, #ids do
            local id = ids[i]
            local el, shown = ctx.els[id], ctx.reps[id] ~= nil
            if el and shown then
                reshow(ctx, el)
                emit('changed', ctx, el)
                touched[#touched + 1] = id
            elseif el then
                show(ctx, el)
                emit('added', ctx, el)
                touched[#touched + 1] = id
            elseif shown then
                hide(ctx, id)
                ctx.fading[id] = true
                if before[id] then emit('removed', ctx, before[id]) end
                touched[#touched + 1] = id
            end
        end
        settle(ctx, touched)
    end
    flushEvents()
end

--- A type was (re)defined or removed: its active elements are projected again — a removed type's become
--- placeholders, a returning one's their kind again (no events: the content did not change, only its form).
function R.refreshType(typeId)
    local list = {}
    for _, ctx in pairs(contexts) do list[#list + 1] = ctx end
    for c = 1, #list do
        local ctx, ids = list[c], {}
        for id in pairs(ctx.reps) do
            local el = ctx.els[id]
            if el and el.type == typeId then ids[#ids + 1] = id end
        end
        if #ids > 0 then
            table.sort(ids, byId)
            for i = 1, #ids do
                local el = ctx.els[ids[i]]
                if el then reshow(ctx, el) end
            end
            settle(ctx, ids)
        end
    end
end

function R.contextsOf(mapId) return byMap[mapId] or {} end
function R.getContext(mapId, bucket) return contexts[ctxKeyOf(mapId, bucket)] end
function R.netTotal() return netTotal end

--- Maps.respawn: the shown elements of a map's active contexts (all, or one element id) back to their authored
--- state — a promoted, displaced or changed node is moved back and reset (Scene demotes a promoted clone first), a
--- missing one is made again (inline, or queued past SLICE). -> how many nodes it touched (queued ones included).
--- Nothing before the Scene store loaded. A spawn held back after a 'limit' answer is tried again.
function R.respawn(mapId, elementId)
    local Scene = scene()
    if not Scene then return 0 end
    heldUntil = 0
    local list, n = {}, 0
    for _, ctx in pairs(byMap[mapId] or {}) do list[#list + 1] = ctx end
    for c = 1, #list do
        local ctx = list[c]
        local ids = elementId ~= nil and { elementId } or sortedIds(ctx.reps)
        local missing = {}
        for i = 1, #ids do
            local el = ctx.reps[ids[i]] and ctx.els[ids[i]]
            local r = el and respawnOne(Scene, ctx, el)
            if r == 'missing' then missing[#missing + 1] = el.id end
            if r then n = n + 1 end
        end
        settle(ctx, missing)
    end
    return n
end

--- Every active record of a type (all types with '*'): editor buckets included (record.editor = true).
function R.records(typeId)
    local out = {}
    for _, ctx in pairs(contexts) do
        local ids = sortedIds(ctx.els)
        for i = 1, #ids do
            local el = ctx.els[ids[i]]
            if typeId == '*' or el.type == typeId then out[#out + 1] = Utils.deepCopy(recordOf(ctx, el)) end
        end
    end
    return out
end

--- { contexts, closing (closed, nodes still going), networked (shown), nodes (existing: active + closing), pending
--- (reconciles queued), retrying (elements waiting for capacity), projecting (the worker runs), waiting (for the
--- Scene store), listeners }
function R.stats()
    local n, nodes, nClosing = 0, 0, 0
    for _, ctx in pairs(contexts) do
        n = n + 1
        for _ in pairs(ctx.nodes) do nodes = nodes + 1 end
    end
    for _, ctx in pairs(closing) do
        nClosing = nClosing + 1
        for _ in pairs(ctx.nodes) do nodes = nodes + 1 end
    end
    return { contexts = n, closing = nClosing, networked = netTotal, nodes = nodes, pending = nQueued,
        retrying = retryN, projecting = working, waiting = waiting, listeners = R.listenerCount() }
end
