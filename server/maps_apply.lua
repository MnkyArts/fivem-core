--[[
    core/server/maps_apply.lua — Core.Maps.apply / invert / clear (DESIGN §52.2), live-map expiry, the
    `core:maps:types` callback and the start of the map system. Last of the four map files (maps_types →
    maps_runtime → maps → maps_apply).

      Maps.apply(id, ops, actor, { source?, expect? = { [elementId] = updatedAt } }) -> true, applied | nil, err, detail
        ops (<= maps.limits.opsPerApply):  { op = 'create', type, pos, rot?, fields?, layer?, cam?, id? }
                                           { op = 'update', id, set = { pos?, rot?, fields?, layer?, cam? }, replace? }
                                           { op = 'delete', id }
        applied = { seq, ops = { { op, id, before?, after? } } }
      Maps.invert(applied) -> ops, expect        the undo of an applied (expect = the after.updatedAt values)
      Maps.clear(id, actor) -> true, applied     every element deleted in one journaled apply
      Maps.journal(id, { limit?, before?, author? }) -> rows   Maps.respawn(id, elementId?) -> count
      Maps.defineType / types / setModelValidator / on / off / records   (delegates to maps_types/_runtime)

    All-or-nothing: every op is validated against a staged view (later ops see earlier ones) before anything
    changes — expect ('conflict'), type ('type'), world bounds ('position' / 'bounds'), rotation restricted by
    transform.rotate ('rotation'), Schema.checkAll on fields ('fields'), the model ('model' / 'no_validator'),
    refs ('ref'), parents ('parents'), per-map / per-type / server-wide limits ('limit'), type.validate
    ('validate', one pcall'ed hop per created or updated element), then the hook `maps:beforeApply` ('hook').
    A limit refuses only an apply that raises a count above it, so lowering a limit never blocks deletes.
    Then memory changes, only the touched element documents are written, one journal row is appended
    and the active contexts re-render the touched ids (maps_runtime.lua).

    `fields` of an update merge into the current fields (`replace = true` replaces them, which invert
    uses); a create may carry the `id` of an element that no longer exists (undo of a delete keeps ids).
    An element whose type version is older than its type's is migrated (type.migrate) when its fields change.

    Natives: none (CreateThread, AddEventHandler are runtime helpers).
]]

local R = Core.MapsRuntime
assert(R and R.ensureLoaded, 'server/maps.lua must load before server/maps_apply.lua')

local Maps = Core.Maps
local Log = Core.Log
local Utils = Core.Utils
local Schema = Core.Schema

local types = R.types
local maps, sets = R.state.maps, R.state.sets

local SOURCES <const> = { editor = true, api = true, palette = true, menu = true, chat = true, console = true,
    core = true }
local MODEL_KINDS <const> = { prop = true, vehicle = true, ped = true, hide = true }
local LAYER_PATTERN <const> = '^[%w_%-]+$'
local LAYER_MAX <const> = 32
local WORLD_XY <const>, WORLD_Z_MIN <const>, WORLD_Z_MAX <const> = 10000, -1000, 3000
local HOOK <const> = 'maps:beforeApply'
local HOOK_OPS_MAX <const> = 200
local EXPIRY_CHECK_MS <const> = 10000
local JOURNAL_PAGE <const>, JOURNAL_PAGE_MAX <const> = 50, 200
local ID_MAX <const> = 999999999          -- R.normId's limit: nextElementId never passes it
local CLEAR_IDS_PER_OP <const> = 100      -- a clear row's journal weight: 1 per this many deleted ids
R.journalOpsTotal = 200000                -- stored journal ops across every map (the oldest rows of the fullest map go)

local function round(v, mult)
    return math.floor(v * mult + 0.5) / mult
end

--- (-180, 180]
local function wrap(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

local function readPos(v)
    local x, y, z = R.xyz(v)
    if not x then return nil, 'position' end
    if x < -WORLD_XY or x > WORLD_XY or y < -WORLD_XY or y > WORLD_XY or z < WORLD_Z_MIN or z > WORLD_Z_MAX then
        return nil, 'bounds'
    end
    return { x = round(x, 1000), y = round(y, 1000), z = round(z, 1000) }
end

--- Euler degrees (rotation order 2), wrapped and rounded; 'yaw' types refuse pitch/roll, 'none' any.
local function readRot(v, rotate)
    if v == nil then return { x = 0, y = 0, z = 0 } end
    local x, y, z = R.xyz(v)
    if not x then return nil end
    x, y, z = round(wrap(x), 100), round(wrap(y), 100), round(wrap(z), 100)
    if rotate == 'yaw' and (x ~= 0 or y ~= 0) then return nil end
    if rotate == 'none' and (x ~= 0 or y ~= 0 or z ~= 0) then return nil end
    return { x = x, y = y, z = z }
end

local function readLayer(v)
    if v == nil then return 'default' end
    if type(v) ~= 'string' or #v == 0 or #v > LAYER_MAX or not v:find(LAYER_PATTERN) then return nil end
    return v
end

--- Optional camera pose of the author (editor "frame" helper): a finite vector, or nil.
local function readCam(v)
    local x, y, z = R.xyz(v)
    return x and { x = round(x, 1000), y = round(y, 1000), z = round(z, 1000) } or nil
end

--- Schema.checkAll over the type's fields (defaults filled) -> out | nil, errs. No fields: none allowed.
local function checkFields(def, values)
    if values ~= nil and type(values) ~= 'table' then return nil, { ['*'] = 'type' } end
    if def.fields then
        local ok, res = Schema.checkAll(def.fields, values or {})
        if not ok then return nil, res end
        return res
    end
    if values ~= nil and next(values) ~= nil then return nil, { ['*'] = 'unknown' } end
    return {}
end

--- The fields of `el` at its type's current version (type.migrate, one pcall'ed hop) -> table | nil.
local function migrated(def, el)
    if el.typeVersion >= def.version or not def.migrate then return el.fields end
    local ok, res = pcall(def.migrate, Utils.deepCopy(el.fields), el.typeVersion)
    if ok and type(res) == 'table' then return res end
    Log.warn('maps: migrate of %s from version %d failed: %s', def.id, el.typeVersion, tostring(res))
    return nil
end

local function copyCounts(c)
    local out = { total = c.total, networked = c.networked, unique = c.unique, byModel = {}, byType = {} }
    for k, v in pairs(c.byModel) do out.byModel[k] = v end
    for k, v in pairs(c.byType) do out.byType[k] = v end
    return out
end

--- A raw record for a restore (undo, maps.invert): type, fields, typeVersion, info and by are kept as they
--- were — no type or schema check, so a placeholder of an undefined type can be restored too. Only the
--- transform and layer are checked. -> element | nil, err
local function readRestore(rec, id)
    if type(rec) ~= 'table' or type(rec.type) ~= 'string' or #rec.type > 64 then return nil, 'restore' end
    if rec.fields ~= nil and type(rec.fields) ~= 'table' then return nil, 'fields' end
    local pos, perr = readPos(rec.pos)
    if not pos then return nil, perr end
    local rot = readRot(rec.rot, 'full')
    if not rot then return nil, 'rotation' end
    local layer = readLayer(rec.layer)
    if not layer then return nil, 'layer' end
    local info = type(rec.info) == 'table' and rec.info or {}
    local vt = type(info.vehicleType) == 'string' and info.vehicleType:sub(1, 16) or nil
    local lod = math.tointeger(info.lod)
    return { id = id, type = rec.type, typeVersion = math.tointeger(rec.typeVersion) or 1, pos = pos, rot = rot,
        fields = Utils.deepCopy(rec.fields or {}), layer = layer, cam = readCam(rec.cam), updatedAt = 0,
        by = type(rec.by) == 'string' and rec.by:sub(1, 64) or nil,
        info = (lod or vt) and { lod = lod, vehicleType = vt } or nil }
end

--------------------------------------------------------------------------------
-- The staged view: later ops of one apply see the earlier ones
--------------------------------------------------------------------------------

local function current(stage, id)
    local v = stage.staged[id]
    if v ~= nil then return v or nil end
    return stage.set.els[id]
end

--- Stage `el` (false = deleted) for `id`, remembering the original element on first touch.
local function put(stage, id, el)
    if stage.before[id] == nil then
        stage.before[id] = stage.set.els[id] or false
        stage.order[#stage.order + 1] = id
    end
    stage.staged[id] = el
end

--- The model of a prop / vehicle / ped / hide element through R.checkModel, cached per apply.
local function checkModelOf(def, fields, cx)
    if not MODEL_KINDS[def.kind] then return true, nil end
    local model = def.model or fields.model
    local key = def.kind .. ':' .. tostring(model)
    local hit = cx.models[key]
    if not hit then
        local ok, res = R.checkModel(def, model)
        hit = { ok, res }
        cx.models[key] = hit
    end
    return hit[1], hit[2]
end

--- An explicit create id: free, and never one that would push nextElementId past ID_MAX (the next
--- automatic id would then be an id R.normId refuses).
local function explicitId(stage, i, op, cx)
    local id = R.normId(op.id)
    if not id or (tonumber(id) >= cx.nextId and tonumber(id) >= ID_MAX) then return nil, 'id', { index = i } end
    if current(stage, id) then return nil, 'exists', { index = i, id = id } end
    return id
end

local function opCreate(stage, i, op, cx)
    if op.restore ~= nil then                  -- undo of a delete: the raw record under its own id
        local id, ierr, idetail = explicitId(stage, i, op, cx)
        if not id then return ierr, idetail end
        local el, rerr = readRestore(op.restore, id)
        if not el then return rerr, { index = i } end
        el.by = el.by or cx.info.by
        if tonumber(id) >= cx.nextId then cx.nextId = tonumber(id) + 1 end
        put(stage, id, el)
        R.countAdd(cx.counts, el, 1)
        stage.restored[id] = true
        stage.results[i] = { op = 'create', id = id, after = el, restore = true }
        return
    end
    local def = type(op.type) == 'string' and types[op.type]
    if not def then return 'type', { index = i, type = op.type } end
    local pos, perr = readPos(op.pos)
    if not pos then return perr, { index = i } end
    local rot = readRot(op.rot, def.rotate)
    if not rot then return 'rotation', { index = i } end
    local fields, errs = checkFields(def, op.fields)
    if not fields then return 'fields', { index = i, fields = errs } end
    local layer = readLayer(op.layer)
    if not layer then return 'layer', { index = i } end
    local ok, info = checkModelOf(def, fields, cx)
    if not ok then return info, { index = i, model = def.model or fields.model } end
    local id
    if op.id ~= nil then                       -- a chosen id that is free again
        local ierr, idetail
        id, ierr, idetail = explicitId(stage, i, op, cx)
        if not id then return ierr, idetail end
    else
        if cx.nextId > ID_MAX then return 'id', { index = i } end
        id = tostring(cx.nextId)
    end
    if tonumber(id) >= cx.nextId then cx.nextId = tonumber(id) + 1 end
    local el = { id = id, type = def.id, typeVersion = def.version, pos = pos, rot = rot, fields = fields,
        layer = layer, cam = readCam(op.cam), by = cx.info.by, updatedAt = 0, info = info }
    put(stage, id, el)
    R.countAdd(cx.counts, el, 1)
    stage.results[i] = { op = 'create', id = id, after = el }
end

local function opUpdate(stage, i, op, cx)
    local id = R.normId(op.id)
    local cur = id and current(stage, id)
    if not cur then return 'not_found', { index = i, id = op.id } end
    if op.restore ~= nil then                  -- undo of an update: the raw earlier record, creator kept
        local el, rerr = readRestore(op.restore, id)
        if not el then return rerr, { index = i } end
        if el.type ~= cur.type then return 'type', { index = i, type = el.type } end
        el.by = cur.by
        R.countAdd(cx.counts, cur, -1)
        R.countAdd(cx.counts, el, 1)
        put(stage, id, el)
        stage.restored[id] = true
        stage.results[i] = { op = 'update', id = id, before = cur, after = el, restore = true }
        return
    end
    local set = op.set
    if type(set) ~= 'table' then return 'op', { index = i } end
    local def = types[cur.type]
    local el = {}
    for k, v in pairs(cur) do el[k] = v end    -- nested tables are replaced below, never mutated
    if set.pos ~= nil then
        local pos, perr = readPos(set.pos)
        if not pos then return perr, { index = i } end
        el.pos = pos
    end
    if set.rot ~= nil then
        el.rot = readRot(set.rot, def and def.rotate or 'full')
        if not el.rot then return 'rotation', { index = i } end
    end
    if set.layer ~= nil then
        el.layer = readLayer(set.layer)
        if not el.layer then return 'layer', { index = i } end
    end
    if set.cam ~= nil then el.cam = readCam(set.cam) end
    if set.fields ~= nil then
        if not def then return 'type', { index = i, type = cur.type } end
        if type(set.fields) ~= 'table' then return 'fields', { index = i, fields = { ['*'] = 'type' } } end
        local base = op.replace == true and {} or migrated(def, cur)
        if not base then return 'migrate', { index = i } end
        local merged = {}
        for k, v in pairs(base) do merged[k] = v end
        for k, v in pairs(set.fields) do merged[k] = v end
        local fields, errs = checkFields(def, merged)
        if not fields then return 'fields', { index = i, fields = errs } end
        local ok, info = checkModelOf(def, fields, cx)
        if not ok then return info, { index = i, model = def.model or fields.model } end
        el.fields, el.typeVersion, el.info = fields, def.version, info
    end
    R.countAdd(cx.counts, cur, -1)
    R.countAdd(cx.counts, el, 1)
    put(stage, id, el)
    stage.results[i] = { op = 'update', id = id, before = cur, after = el }
end

local function opDelete(stage, i, op, cx)
    local id = R.normId(op.id)
    local cur = id and current(stage, id)
    if not cur then return 'not_found', { index = i, id = op.id } end
    R.countAdd(cx.counts, cur, -1)
    put(stage, id, false)
    stage.results[i] = { op = 'delete', id = id, before = cur }
end

--------------------------------------------------------------------------------
-- Whole-apply checks (after every op staged)
--------------------------------------------------------------------------------

--- Ref fields of touched (not restored) elements point at an element of the staged map, of refType.
local function checkRefs(stage)
    for i = 1, #stage.order do
        local id = stage.order[i]
        local el = stage.staged[id]
        local def = el and not stage.restored[id] and types[el.type]
        local refs = def and def.refFields
        for j = 1, refs and #refs or 0 do
            local f = refs[j]
            local v = el.fields[f.name]
            if v ~= nil then
                local target = type(v) == 'string' and current(stage, v)
                if not target or (f.refType and target.type ~= f.refType) then
                    return 'ref', { id = el.id, field = f.name }
                end
            end
        end
    end
end

--- An element deleted here must not stay referenced by an untouched element ('referenced'); touched
--- referrers are covered by checkRefs. Scans only when this apply deletes and the map has ref types.
local function checkReferenced(stage, cx)
    local deleted
    for i = 1, #stage.order do
        local id = stage.order[i]
        if stage.staged[id] == false and stage.before[id] then
            deleted = deleted or {}
            deleted[id] = true
        end
    end
    if not deleted then return nil end
    local any = false
    for typeId in pairs(cx.base.byType) do
        if types[typeId] and types[typeId].refFields then any = true break end
    end
    if not any then return nil end
    for id, el in pairs(stage.set.els) do
        local def = stage.staged[id] == nil and types[el.type]
        local refs = def and def.refFields
        for j = 1, refs and #refs or 0 do
            local v = el.fields[refs[j].name]
            if type(v) == 'string' and deleted[v] then return 'referenced', { id = v, by = id } end
        end
    end
end

--- A type with `parents` needs an element of one of them in the map; only a new violation is refused.
local function checkParents(cx)
    local after, before = cx.counts.byType, cx.base.byType
    for typeId, n in pairs(after) do
        local def = types[typeId]
        if def and def.parents then
            local a, b = 0, 0
            for _, p in ipairs(def.parents) do
                a, b = a + (after[p] or 0), b + (before[p] or 0)
            end
            if a == 0 and (n > (before[typeId] or 0) or b > 0) then
                return 'parents', { type = typeId, parents = def.parents }
            end
        end
    end
end

local function checkLimits(cx, lim)
    local a, b = cx.counts, cx.base
    if a.total > lim.elements and a.total > b.total then return 'limit', { limit = 'elements', max = lim.elements } end
    if a.unique > lim.uniqueModels and a.unique > b.unique then
        return 'limit', { limit = 'uniqueModels', max = lim.uniqueModels }
    end
    if a.networked > lim.networked and a.networked > b.networked then
        return 'limit', { limit = 'networked', max = lim.networked }
    end
    for model, n in pairs(a.byModel) do
        if n > lim.perModel and n > (b.byModel[model] or 0) then
            return 'limit', { limit = 'perModel', model = model, max = lim.perModel }
        end
    end
    for typeId, n in pairs(a.byType) do
        local def = types[typeId]
        local cap = def and def.limits and def.limits.perMap
        if cap and n > cap and n > (b.byType[typeId] or 0) then
            return 'limit', { limit = 'perMap', type = typeId, max = cap }
        end
    end
    local delta = a.networked - b.networked
    if delta > 0 then                          -- server-wide, counted only where this set is shown
        local shown = 0
        for _, ctx in pairs(R.contextsOf(cx.mapId)) do
            if ctx.source == cx.source then shown = shown + 1 end
        end
        if shown > 0 and R.netTotal() + delta * shown > lim.networkedTotal then
            return 'limit', { limit = 'networkedTotal', max = lim.networkedTotal }
        end
    end
end

--- Rollback (maps.lua) re-checks an old snapshot against today's model validator and limits (per map,
--- increase-only against what is published now; networkedTotal is publish's own check) -> nil | err, detail.
function R.checkSnapshot(map, els)
    local lim = R.readLimits(map)
    local bad, cx, verdict = {}, { models = {} }, nil
    for id, el in pairs(els) do
        local def = types[el.type]
        if def and MODEL_KINDS[def.kind] then
            local ok, err = checkModelOf(def, el.fields or {}, cx)
            if not ok then
                bad[#bad + 1] = id
                verdict = verdict or err
            end
        end
    end
    if verdict then
        table.sort(bad, function(a, b) return tonumber(a) < tonumber(b) end)
        for i = #bad, 51, -1 do bad[i] = nil end
        return verdict, { ids = bad }
    end
    local published = R.state.snaps[map.id]
    local base = R.countSet(published and published.els or {})
    return checkLimits({ mapId = map.id, counts = R.countSet(els), base = base }, lim)
end

--- type.validate(record, { mapId, actor, op }) for every created / updated element (one hop each).
local function runValidators(stage, cx)
    for i = 1, #stage.results do
        local r = stage.results[i]
        local def = r.after and not r.restore and types[r.after.type]
        if def and def.validate then
            local ok, res, msg = pcall(def.validate, Utils.deepCopy(r.after),
                { mapId = cx.mapId, actor = cx.actor, op = r.op })
            if not ok then
                Log.warn('maps: validate of %s failed: %s', def.id, tostring(res))
                return 'validate', { index = i, reason = 'error' }
            end
            if not res then
                return 'validate', { index = i, reason = type(msg) == 'string' and msg:sub(1, 128) or 'refused' }
            end
        end
    end
end

--- Core.Hooks.run('maps:beforeApply', { mapId, mode, actor, source, count, ops = first 200 }) — a veto
--- (or a failing / yielding hook, fail-closed) refuses the whole apply.
local function runHook(stage, cx, map, source, count)
    local Hooks = rawget(Core, 'Hooks')
    if not (Hooks and Hooks.run) then return nil end
    local list = {}
    for i = 1, math.min(#stage.results, HOOK_OPS_MAX) do
        local r = stage.results[i]
        local el = r.after or r.before
        list[i] = { op = r.op, id = r.id, type = el.type, model = R.modelOf(types[el.type], el),
            pos = { x = el.pos.x, y = el.pos.y, z = el.pos.z } }
    end
    local allowed, reason = Hooks.run(HOOK, { mapId = map.id, mode = map.mode, actor = cx.info.by, source = source,
        count = count, ops = list })
    if not allowed then return 'hook', { reason = reason } end
end

--------------------------------------------------------------------------------
-- The journal: bounded per map (rows, stored ops) and server-wide (R.journalOpsTotal)
--------------------------------------------------------------------------------

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

local DIFF_KEYS <const> = { 'pos', 'rot', 'layer', 'cam', 'typeVersion', 'info' }

--- A stored journal op: creates and deletes keep the element, updates only what changed (fields by name;
--- a key missing on one side was nil there). The caller's `applied` keeps the full records.
local function journalOp(r)
    if r.op ~= 'update' then return r end
    local b, a = r.before, r.after
    local db, da = {}, { updatedAt = a.updatedAt }
    for _, key in ipairs(DIFF_KEYS) do
        if not same(b[key], a[key]) then db[key], da[key] = b[key], a[key] end
    end
    local fb, fa = b.fields or {}, a.fields or {}
    local cb, ca, changed = {}, {}, false
    for k, v in pairs(fb) do
        if not same(v, fa[k]) then cb[k], ca[k], changed = v, fa[k], true end
    end
    for k, v in pairs(fa) do
        if fb[k] == nil then ca[k], changed = v, true end
    end
    if changed then db.fields, da.fields = cb, ca end
    return { op = 'update', id = r.id, before = db, after = da }
end

local function dropOldest(S, mapId)
    local old = table.remove(S.journalIdx[mapId], 1)
    Core.DB.delete('map_journal', mapId .. ':j' .. old.seq)
    local w = old.w or 1
    S.journalOps[mapId] = (S.journalOps[mapId] or w) - w
    S.journalTotal = S.journalTotal - w
end

--- Appends one row (the caller persists the map) and prunes: per map to journalMax rows and journalMaxOps
--- weight (the newest row always stays), then server-wide to R.journalOpsTotal, the fullest map first.
local function journalAppend(map, info, source, row, lim)
    local S = R.state
    map.journalSeq = map.journalSeq + 1
    local seq, at = map.journalSeq, os.time()
    row.mapId, row.seq, row.at, row.by, row.source = map.id, seq, at, info.by, source
    row.actor = { kind = info.kind, src = info.src, name = info.name }
    if not Core.DB.set('map_journal', map.id .. ':j' .. seq, row) then
        Log.warn('maps: could not write journal row %s:%d', map.id, seq)
        return seq
    end
    local idx = S.journalIdx[map.id] or {}
    S.journalIdx[map.id] = idx
    idx[#idx + 1] = { seq = seq, at = at, by = info.by, w = row.w }
    S.journalOps[map.id] = (S.journalOps[map.id] or 0) + row.w
    S.journalTotal = S.journalTotal + row.w
    while #idx > 1 and (#idx > lim.journalMax or S.journalOps[map.id] > lim.journalMaxOps) do
        dropOldest(S, map.id)
    end
    while S.journalTotal > R.journalOpsTotal do
        local worst, most = nil, 0
        for id, n in pairs(S.journalOps) do
            local list = S.journalIdx[id]
            if n > most and list and #list > 1 then worst, most = id, n end
        end
        if not worst then break end
        dropOldest(S, worst)
    end
    return seq
end

--- Memory, then the touched documents, then one journal row, then the world.
local function commit(map, stage, cx, lim, source)
    local set, order = stage.set, stage.order
    for i = 1, #order do
        local el = stage.staged[order[i]]
        if el then el.updatedAt = R.stamp() end
    end
    for i = 1, #order do
        local id = order[i]
        local el = stage.staged[id]
        set.els[id] = el or nil
        if el then
            R.writeElement(map.id, el)
        elseif stage.before[id] then
            R.removeElement(map.id, id)
        end
    end
    map.nextElementId = cx.nextId
    map.updatedAt = os.time()
    local results = {}
    for i = 1, #stage.results do
        local r = stage.results[i]
        results[i] = { op = r.op, id = r.id, before = r.before and Utils.deepCopy(r.before) or nil,
            after = r.after and Utils.deepCopy(r.after) or nil }
    end
    local row
    if cx.clearing then                         -- a clear stores a summary, not every element
        local ids = {}
        for i = 1, #results do ids[i] = results[i].id end
        row = { clear = true, count = #ids, ids = ids, w = math.max(1, math.ceil(#ids / CLEAR_IDS_PER_OP)) }
    else
        local ops = {}
        for i = 1, #results do ops[i] = journalOp(results[i]) end
        row = { count = #ops, ops = ops, w = #ops }
    end
    local seq = journalAppend(map, cx.info, source, row, lim)
    R.persistMap(map)
    R.applyChanges(map.id, cx.source, order, stage.before)
    return true, { seq = seq, ops = results }
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local OP_HANDLERS <const> = { create = opCreate, update = opUpdate, delete = opDelete }

--- The pipeline behind apply and clear. `clearing` skips opsPerApply and journals a summary.
local function run(id, ops, actor, opts, clearing)
    if not R.ensureLoaded() then return nil, 'unavailable' end
    if type(id) ~= 'string' or not maps[id] then return nil, 'not_found' end
    if opts ~= nil and type(opts) ~= 'table' then return nil, 'opts' end
    opts = opts or {}
    local lim = R.readLimits(maps[id])          -- may yield once (settings load): nothing is staged yet
    local map, set = maps[id], sets[id]
    if not map then return nil, 'not_found' end
    if type(ops) ~= 'table' or #ops == 0 then return nil, 'ops' end
    local count = #ops
    if not clearing and count > lim.opsPerApply then return nil, 'too_many_ops', { max = lim.opsPerApply } end
    local source = opts.source == nil and 'api' or opts.source
    if not SOURCES[source] then return nil, 'source' end
    if opts.expect ~= nil then
        if type(opts.expect) ~= 'table' then return nil, 'expect' end
        for key, at in pairs(opts.expect) do
            local eid = R.normId(key)
            local el = eid and set.els[eid]
            if not el or el.updatedAt ~= at then
                return nil, 'conflict', { id = eid or tostring(key), current = el and el.updatedAt or nil }
            end
        end
    end
    if Core.DB.isDegraded('map_elements') then return nil, 'db' end
    local base = R.countSet(set.els)
    local cx = { mapId = id, info = R.actorInfo(actor), actor = actor, nextId = map.nextElementId, models = {},
        base = base, counts = copyCounts(base), source = map.mode == 'live' and 'live' or 'draft', clearing = clearing }
    local stage = { set = set, staged = {}, order = {}, before = {}, results = {}, restored = {} }
    for i = 1, count do
        local op = ops[i]
        local handler = type(op) == 'table' and OP_HANDLERS[op.op]
        if not handler then return nil, 'op', { index = i } end
        local err, detail = handler(stage, i, op, cx)
        if err then return nil, err, detail end
    end
    local err, detail = checkRefs(stage)
    if not err then err, detail = checkReferenced(stage, cx) end
    if not err then err, detail = checkParents(cx) end
    if not err then err, detail = checkLimits(cx, lim) end
    if not err then err, detail = runValidators(stage, cx) end
    if not err then err, detail = runHook(stage, cx, map, source, count) end
    if err then return nil, err, detail end
    return commit(map, stage, cx, lim, source)
end

--- Maps.apply(id, ops, actor, opts) -> true, applied | nil, err, detail (see the header).
function Maps.apply(id, ops, actor, opts)
    return run(id, ops, actor, opts, false)
end

--- Maps.invert(applied) -> ops, expect: apply them (with that expect) to undo `applied` (the value apply
--- returned — journal rows keep update diffs only). Deletes and updates are undone by `restore` ops that
--- bring back the raw earlier record: placeholders of undefined types, removed cams and old typeVersions too.
function Maps.invert(applied)
    if type(applied) ~= 'table' or type(applied.ops) ~= 'table' then return nil end
    local ops, expect = {}, {}
    for i = #applied.ops, 1, -1 do
        local r = applied.ops[i]
        local b, a = type(r) == 'table' and r.before, type(r) == 'table' and r.after
        if r.op == 'create' and a then
            ops[#ops + 1] = { op = 'delete', id = r.id }
            if expect[r.id] == nil then expect[r.id] = a.updatedAt end
        elseif r.op == 'delete' and b then
            ops[#ops + 1] = { op = 'create', id = r.id, restore = b }
        elseif r.op == 'update' and b and a then
            ops[#ops + 1] = { op = 'update', id = r.id, restore = b }
            if expect[r.id] == nil then expect[r.id] = a.updatedAt end
        end
    end
    return Utils.deepCopy(ops), expect
end

--- Maps.clear(id, actor, opts?) -> true, applied | nil, err. One journaled apply of every delete.
function Maps.clear(id, actor, opts)
    if not R.ensureLoaded() then return nil, 'unavailable' end
    local set = type(id) == 'string' and sets[id]
    if not set then return nil, 'not_found' end
    local ids = R.sortedIds(set.els)
    if #ids == 0 then return true, { seq = maps[id].journalSeq, ops = {} } end
    local ops = {}
    for i = 1, #ids do ops[i] = { op = 'delete', id = ids[i] } end
    local ok, applied, detail = run(id, ops, actor, opts, true)
    if ok and maps[id] then R.audit('clear', maps[id], actor, nil, { elements = #ids, seq = applied.seq }) end
    return ok, applied, detail
end

--------------------------------------------------------------------------------
-- Journal, respawn, the type / event delegates
--------------------------------------------------------------------------------

--- Maps.journal(id, { limit? = 50 (<= 200), before? = seq, author? = by }) -> rows, newest first
function Maps.journal(id, filter)
    if not R.ensureLoaded() then return nil end
    if type(id) ~= 'string' or not maps[id] then return nil end
    filter = type(filter) == 'table' and filter or {}
    local limit = math.tointeger(filter.limit) or JOURNAL_PAGE
    limit = math.max(1, math.min(limit, JOURNAL_PAGE_MAX))
    local before = math.tointeger(filter.before)
    local author = type(filter.author) == 'string' and filter.author or nil
    local rows, idx = {}, R.state.journalIdx[id] or {}
    for i = #idx, 1, -1 do
        local e = idx[i]
        if (not before or e.seq < before) and (not author or e.by == author) then
            local row = Core.DB.get('map_journal', id .. ':j' .. e.seq)
            if row then rows[#rows + 1] = row end
            if #rows >= limit then break end
        end
    end
    return rows
end

--- Maps.respawn(id, elementId?) -> how many element nodes were put back to their authored state (spawned again,
--- moved back — a promoted clone is demoted first — or reset; maps_runtime.lua)
function Maps.respawn(id, elementId)
    if not R.ensureLoaded() or type(id) ~= 'string' or not maps[id] then return 0 end
    local eid = elementId ~= nil and R.normId(elementId) or nil
    if elementId ~= nil and not eid then return 0 end
    return R.respawn(id, eid)
end

function Maps.defineType(def) return R.defineType(def) end
function Maps.types() return R.publicTypes() end
function Maps.setModelValidator(fn) return R.setModelValidator(fn) end
function Maps.on(typeId, fn) return R.on(typeId, fn) end
function Maps.off(handle) return R.off(handle) end

function Maps.records(typeId)
    if typeId ~= '*' and type(typeId) ~= 'string' then return {} end
    R.ensureLoaded()
    return R.records(typeId)
end

--- A positive element id (integer or digit string) -> its string form, or nil.
function R.normId(v)
    local n = math.type(v) == 'integer' and v or (type(v) == 'number' and math.tointeger(v))
    if n then return n > 0 and n < 1000000000 and tostring(n) or nil end
    if type(v) == 'string' and #v <= 9 and v:find('^[1-9]%d*$') then return v end
    return nil
end

--------------------------------------------------------------------------------
-- Expiry, the types callback, start
--------------------------------------------------------------------------------

--- Active maps whose expiresAt passed are deactivated (not deleted); expiresAt is cleared with it.
local function checkExpiry()
    if not R.ensureLoaded() then return end
    local now = os.time()
    for id, map in pairs(maps) do
        if map.active and map.expiresAt and map.expiresAt <= now then
            map.active, map.expiresAt, map.updatedAt = false, nil, now
            R.persistMap(map)
            R.syncMap(id)
            R.audit('setActive', map, 'system', { { key = 'active', old = true, new = false } }, { reason = 'expired' })
            Log.info('maps: %s (%s) expired and was deactivated', map.name, id)
        end
    end
end
R.checkExpiry = checkExpiry

-- The editor view's preview descriptors (public data, no permission; cached until a type changes).
Core.Callback.register('core:maps:types', function()
    return R.publicTypes()
end, { cooldownMs = 1000 })

AddEventHandler('onResourceStart', function(resource)
    if resource ~= Core.name then return end
    local Cron = rawget(Core, 'Cron')
    if Cron and Cron.every then
        Cron.every(EXPIRY_CHECK_MS, checkExpiry)
    else
        Log.warn('maps: Core.Cron is missing; live-map expiry is not enforced')
    end
    -- the load (and the activation of every active map) runs once per core start, then the thread ends
    -- fxlint-disable-next-line P004
    CreateThread(function()
        R.ensureLoaded()
        checkExpiry()
    end)
end)
