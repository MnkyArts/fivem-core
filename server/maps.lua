--[[
    core/server/maps.lua — Core.Maps (DESIGN §52.2): map documents, modes, publish / versions / rollback,
    the journal, editor buckets and the load barrier. Third of the four map files (maps_types →
    maps_runtime → maps → maps_apply); `Maps.apply` / `invert` / `clear` live in server/maps_apply.lua.

      Maps.create({ name, mode, targetBucket?, meta?, expiresAt?, limits?, active? }, actor) -> map|nil, err
      Maps.get(id) / Maps.list({ mode?, active?, text? }) / Maps.elements(id)
      Maps.update(id, { name?, meta?, expiresAt?, targetBucket?, limits? }, actor) -> map|nil, err
      Maps.delete(id, actor) / Maps.setActive(id, on, actor) -> bool, err
      Maps.publish(id, actor, note?) -> version / Maps.versions(id) / Maps.rollback(id, version, actor) -> version
      Maps.openDraft(id, actor) -> bucket / Maps.closeDraft(id) -> bool
      Maps.apply / invert / clear / journal / respawn and the type / event delegates: maps_apply.lua

    Collections: `maps` (one document per map), `map_elements` (one per element, id '<mapId>:<elementId>',
    so an apply writes only what changed), `map_versions` (id '<mapId>:v<n>', published snapshots, the
    newest VERSIONS_KEEP kept), `map_journal` (id '<mapId>:j<seq>', pruned per map to `maps.journalMax` rows and
    `maps.journalMaxOps` stored ops, and server-wide to R.journalOpsTotal — maps_apply.lua).
    Everything is read once behind the async barrier of server/globals.lua (§22): the first caller parks a
    promise while Core.DB loads (it yields on postgres/mysql) and every caller arriving meanwhile waits.
    The journal and version indexes are built through a DB.find predicate that copies nothing.

    Activation (which content is in which bucket) is recomputed per map by R.syncMap: a live map's elements
    in targetBucket while active, a draft's published snapshot in targetBucket while active, a draft's
    working copy in its editor bucket while open (Core.Buckets, owner core, population off, lockdown
    strict). Live maps with `expiresAt` (unix seconds) are deactivated — not deleted — by a Cron job.

    Core.Maps is a trusted server API: callers authorise their users (§52.2). create / update / delete /
    setActive / publish / rollback / clear are audited (Core.Audit, action 'maps.<op>'); applies are
    journaled instead.

    Natives: GetPlayerName (server), GetGameTimer (shared). os.time, promise and Citizen.Await are runtime helpers.
]]

local R = Core.MapsRuntime
assert(R and R.openContext, 'server/maps_types.lua and server/maps_runtime.lua must load before server/maps.lua')

local Maps = {}
Core.Maps = Maps

local Log = Core.Log
local Utils = Core.Utils
local Registry = Core.Registry

local S = R.state
local maps, sets, snaps, editorBuckets = S.maps, S.sets, S.snaps, S.editorBuckets
-- [mapId] = ascending { seq, at, by } / { version, by, byName, note, at, count, from }
local journalIdx, versionIdx = {}, {}
local journalOps = {}                   -- [mapId] = stored journal weight (ops) of that map; S.journalTotal = sum
S.journalIdx, S.versionIdx, S.journalOps, S.journalTotal = journalIdx, versionIdx, journalOps, 0

local C_MAPS <const> = 'maps'
local C_ELEMENTS <const> = 'map_elements'
local C_VERSIONS <const> = 'map_versions'
local C_JOURNAL <const> = 'map_journal'
local DRAFT_KIND <const> = 'mapsDraft'
local MAP_ID_PATTERN <const> = '^[%w_%-]+$'
local MAP_ID_MAX <const> = 24
local NAME_MAX <const> = 64
local DESCRIPTION_MAX <const> = 1024
local NOTE_MAX <const> = 256
local VERSIONS_KEEP <const> = 20
local EXPIRY_CHECK_MS <const> = 10000
local LOAD_RETRY_S <const> = 10
local BUCKET_MAX <const> = 0x7FFFFFFF
local LIMIT_RANGE <const> = {             -- per-map overrides of the maps.limits.* settings (same bounds)
    elements = { 1, 100000 }, perModel = { 1, 10000 }, uniqueModels = { 1, 5000 }, networked = { 0, 500 },
}
local SETTING_DEFAULTS <const> = {
    elements = 3000, perModel = 300, uniqueModels = 200, networked = 20, networkedTotal = 200, opsPerApply = 200,
}

local loaded, loading, failedAt = false, nil, nil
local lastStamp, stampBase, timerBase = 0, nil, nil

--------------------------------------------------------------------------------
-- Shared helpers (also used by maps_apply.lua through R)
--------------------------------------------------------------------------------

--- Strictly increasing wall-clock milliseconds: element `updatedAt`, the `expect` token of §52.2.
function R.stamp()
    if not stampBase then stampBase, timerBase = os.time() * 1000, GetGameTimer() end
    local t = stampBase + (GetGameTimer() - timerBase)
    if t <= lastStamp then t = lastStamp + 1 end
    lastStamp = t
    return t
end

--- actor (src | 0 | 'system' | nil) -> { kind, src?, accountId?, name?, by } where `by` is what an element
--- records: the account id of a player, 'console' or 'system'.
function R.actorInfo(actor)
    if actor == 0 or actor == 'console' then return { kind = 'console', by = 'console', name = 'console' } end
    local src = math.type(actor) == 'integer' and actor or (type(actor) == 'number' and math.tointeger(actor))
    if src and src > 0 then
        local info
        local Player = rawget(Core, 'Player')
        if Player and Player.getInfo then
            local ok, res = pcall(Player.getInfo, src)
            if ok and type(res) == 'table' then info = res end
        end
        local accountId = info and info.accountId
        return { kind = 'player', src = src, accountId = accountId, name = info and info.name or GetPlayerName(src),
            by = accountId and tostring(accountId) or ('src:' .. src) }
    end
    return { kind = 'system', by = 'system', resource = Registry.getCaller() }
end

--- One audit row (§46). Core.Audit may be missing: the change still happens.
function R.audit(action, map, actor, changes, ctx)
    local Audit = rawget(Core, 'Audit')
    if not (Audit and Audit.record) then return end
    local who = (type(actor) == 'number' or actor == 'console') and actor or 'system'
    local ok, err = pcall(Audit.record, {
        actor = who, action = 'maps.' .. action, targets = { { type = 'map', id = map.id, name = map.name } },
        changes = changes, ctx = ctx,
    })
    if not ok then Log.warn('maps: audit record %s failed: %s', action, tostring(err)) end
end

--- Effective limits of a map: its own overrides, else the maps.limits.* settings (may yield once while
--- the settings load — call it before staging anything).
function R.readLimits(map)
    local Settings = rawget(Core, 'Settings')
    local out = {}
    for key, fallback in pairs(SETTING_DEFAULTS) do
        local v = Settings and Settings.get('maps.limits.' .. key)
        out[key] = math.tointeger(v) or fallback
    end
    out.journalMax = math.tointeger(Settings and Settings.get('maps.journalMax')) or 5000
    out.journalMaxOps = math.tointeger(Settings and Settings.get('maps.journalMaxOps')) or 20000
    if map and type(map.limits) == 'table' then
        for key in pairs(LIMIT_RANGE) do
            if math.tointeger(map.limits[key]) then out[key] = map.limits[key] end
        end
    end
    return out
end

--- Counts of an element table: total, networked, distinct models (hides excluded), per model, per type.
function R.countAdd(c, el, d)
    local def = R.types[el.type]
    c.total = c.total + d
    local nt = (c.byType[el.type] or 0) + d
    c.byType[el.type] = nt ~= 0 and nt or nil
    if R.isNetworked(def) then c.networked = c.networked + d end
    local model = (not def or def.kind ~= 'hide') and R.modelOf(def, el) or nil
    if model then
        local n = (c.byModel[model] or 0) + d
        if n <= 0 then
            if c.byModel[model] then c.unique = c.unique - 1 end
            c.byModel[model] = nil
        else
            if not c.byModel[model] then c.unique = c.unique + 1 end
            c.byModel[model] = n
        end
    end
end

function R.countSet(els)
    local c = { total = 0, networked = 0, unique = 0, byModel = {}, byType = {} }
    for _, el in pairs(els) do R.countAdd(c, el, 1) end
    return c
end

function R.persistMap(map)
    if Core.DB.set(C_MAPS, map.id, map) then return true end
    Log.error('maps: could not persist map %s', map.id)
    return false
end

--- The stored form of an element: its fields plus mapId. Core.DB forces `id` to the document id and
--- `updatedAt` to the write time in seconds, so the element's own stamp is stored as `rev`.
local function elementDocId(mapId, elementId)
    return mapId .. ':' .. elementId
end

function R.writeElement(mapId, el)
    local doc = { mapId = mapId, type = el.type, typeVersion = el.typeVersion, pos = el.pos, rot = el.rot,
        fields = el.fields, layer = el.layer, cam = el.cam, by = el.by, rev = el.updatedAt, info = el.info }
    if Core.DB.set(C_ELEMENTS, elementDocId(mapId, el.id), doc) then return true end
    Log.error('maps: could not write element %s:%s', mapId, el.id)
    return false
end

function R.removeElement(mapId, elementId)
    Core.DB.delete(C_ELEMENTS, elementDocId(mapId, elementId))
end

local function vec(v, fallback)
    local x, y, z = R.xyz(v)
    if not x then return fallback end
    return { x = x, y = y, z = z }
end

--- A stored element document (or a snapshot entry) -> the in-memory element, or nil when unusable.
local function toElement(doc, elementId)
    if type(doc) ~= 'table' or type(doc.type) ~= 'string' then return nil end
    local pos = vec(doc.pos)
    if not pos or not elementId then return nil end
    local info = type(doc.info) == 'table' and Utils.deepCopy(doc.info) or nil
    return {
        id = elementId, type = doc.type, typeVersion = math.tointeger(doc.typeVersion) or 1, pos = pos,
        rot = vec(doc.rot, { x = 0, y = 0, z = 0 }),
        fields = type(doc.fields) == 'table' and Utils.deepCopy(doc.fields) or {},
        layer = type(doc.layer) == 'string' and doc.layer or 'default', cam = vec(doc.cam),
        by = type(doc.by) == 'string' and doc.by or 'system', info = info,
        updatedAt = math.tointeger(doc.rev) or math.tointeger(doc.updatedAt) or 0,
    }
end

--- Snapshot array (map_versions) -> { [id] = element }.
local function fromArray(list)
    local els = {}
    if type(list) ~= 'table' then return els end
    for i = 1, #list do
        local item = list[i]
        local id = type(item) == 'table' and (math.tointeger(item.id) and tostring(math.tointeger(item.id)) or item.id)
        local el = type(id) == 'string' and toElement(item, id) or nil
        if el then els[id] = el end
    end
    return els
end

local function toArray(els)
    local ids = R.sortedIds(els)
    local out = {}
    for i = 1, #ids do out[i] = els[ids[i]] end
    return out
end

--------------------------------------------------------------------------------
-- Activation: which content is shown in which bucket
--------------------------------------------------------------------------------

--- { [bucket] = { source, els } } a map should have right now.
local function desired(map)
    local want = {}
    if map.active then
        if map.mode == 'live' then
            want[map.targetBucket] = { 'live', sets[map.id].els }
        elseif snaps[map.id] then
            want[map.targetBucket] = { 'published', snaps[map.id].els }
        end
    end
    local editor = editorBuckets[map.id]
    if editor then want[editor] = { 'draft', sets[map.id].els } end
    return want
end

--- Brings a map's contexts in line with desired(): close, swap (same bucket, other content), open.
function R.syncMap(id)
    local map = maps[id]
    local want = map and desired(map) or {}
    local have = {}
    for bucket, ctx in pairs(R.contextsOf(id)) do have[bucket] = ctx end
    for bucket, ctx in pairs(have) do
        local w = want[bucket]
        if not w or w[1] ~= ctx.source then
            R.closeContext(id, bucket)
        elseif w[2] ~= ctx.els then
            R.swapContext(id, bucket, w[2])
        end
    end
    for bucket, w in pairs(want) do
        if not R.getContext(id, bucket) then R.openContext(id, bucket, w[1], w[2]) end
    end
end

--- Would the map's desired content (as the state is NOW) raise the server-wide networked total above
--- `limit`? Only an increase is refused, so lowering the limit never blocks switching content off.
local function exceedsNetworked(map, limit)
    local current = 0
    for _, ctx in pairs(R.contextsOf(map.id)) do current = current + ctx.netCount end
    local after = 0
    for _, w in pairs(desired(map)) do after = after + R.countSet(w[2]).networked end
    return after > current and R.netTotal() - current + after > limit
end
R.exceedsNetworked = exceedsNetworked

--- A bucket in use as some draft's editor bucket cannot be a target (their contents would mix).
local function isEditorBucket(bucket)
    for _, b in pairs(editorBuckets) do
        if b == bucket then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Loading (async barrier, DESIGN §22)
--------------------------------------------------------------------------------

local function int(v, lo, fallback)
    local n = math.tointeger(v)
    if n and n >= lo then return n end
    return fallback
end

--- A stored map document -> the in-memory map (normalised), or nil.
local function normalizeMap(doc)
    local id = doc.id
    if type(id) ~= 'string' or #id > MAP_ID_MAX or not id:find(MAP_ID_PATTERN) then return nil end
    if doc.mode ~= 'draft' and doc.mode ~= 'live' then return nil end
    local meta = type(doc.meta) == 'table' and doc.meta or {}
    return {
        id = id, name = type(doc.name) == 'string' and doc.name or id, mode = doc.mode, active = doc.active == true,
        targetBucket = int(doc.targetBucket, 0, 0), publishedVersion = int(doc.publishedVersion, 0, 0),
        publishedSeq = int(doc.publishedSeq, -1, 0), nextElementId = int(doc.nextElementId, 1, 1),
        journalSeq = int(doc.journalSeq, 0, 0),
        meta = { description = type(meta.description) == 'string' and meta.description or nil },
        limits = type(doc.limits) == 'table' and doc.limits or nil, expiresAt = int(doc.expiresAt, 1, nil),
        createdAt = doc.createdAt, createdBy = doc.createdBy, updatedAt = doc.updatedAt,
    }
end

local function loadAll()
    local DB = Core.DB
    local docs = DB.all(C_MAPS)
    if DB.isDegraded(C_MAPS) then return false, C_MAPS end
    for i = 1, #docs do
        local map = normalizeMap(docs[i])
        if map then
            maps[map.id], sets[map.id] = map, { els = {} }
        else
            Log.warn('maps: skipping unreadable map document %s', tostring(docs[i].id))
        end
    end
    local orphans = 0
    -- predicates read the stored documents and copy only what is kept (returning false: DB copies nothing)
    DB.find(C_ELEMENTS, function(doc)
        local mapId, elementId = tostring(doc.id):match('^([%w_%-]+):(%d+)$')
        local set = mapId and sets[mapId]
        local el = set and toElement(doc, elementId)
        if el then
            set.els[elementId] = el
            if el.updatedAt > lastStamp then lastStamp = el.updatedAt end
            local map = maps[mapId]
            local n = tonumber(elementId)
            if n >= map.nextElementId then map.nextElementId = n + 1 end
        else
            orphans = orphans + 1
        end
        return false
    end)
    if DB.isDegraded(C_ELEMENTS) then return false, C_ELEMENTS end
    if orphans > 0 then Log.warn('maps: ignored %d element document(s) without a readable map', orphans) end
    DB.find(C_VERSIONS, function(doc)
        local list = maps[doc.mapId] and (versionIdx[doc.mapId] or {})
        local version = math.tointeger(doc.version)
        if list and version then
            versionIdx[doc.mapId] = list
            list[#list + 1] = { version = version, by = doc.by, byName = doc.byName, note = doc.note, at = doc.at,
                count = doc.count, from = doc.from }
        end
        return false
    end)
    DB.find(C_JOURNAL, function(doc)
        local list = maps[doc.mapId] and (journalIdx[doc.mapId] or {})
        local seq = math.tointeger(doc.seq)
        if list and seq then
            journalIdx[doc.mapId] = list
            local w = math.tointeger(doc.w) or (type(doc.ops) == 'table' and #doc.ops) or 1
            list[#list + 1] = { seq = seq, at = doc.at, by = doc.by, w = w }
            journalOps[doc.mapId] = (journalOps[doc.mapId] or 0) + w
            S.journalTotal = S.journalTotal + w
        end
        return false
    end)
    for _, list in pairs(versionIdx) do table.sort(list, function(a, b) return a.version < b.version end) end
    for _, list in pairs(journalIdx) do table.sort(list, function(a, b) return a.seq < b.seq end) end
    for id, map in pairs(maps) do
        if map.mode == 'draft' and map.publishedVersion > 0 then
            local doc = DB.get(C_VERSIONS, id .. ':v' .. map.publishedVersion)
            if doc then
                snaps[id] = { version = map.publishedVersion, els = fromArray(doc.elements) }
            else
                Log.warn('maps: published version %d of %s is missing; nothing is shown for it',
                    map.publishedVersion, id)
            end
        end
    end
    return true
end

--- Loads every map once; true when the documents are in memory. A failed load (degraded collection) is
--- retried at most every LOAD_RETRY_S seconds. The first successful load activates every map.
local function ensureLoaded()
    if loaded then return true end
    if loading then
        local ok, err = pcall(Citizen.Await, loading)
        if not ok then Log.error('maps: waiting for the load failed: %s', tostring(err)) end
        return loaded
    end
    if failedAt and os.time() - failedAt < LOAD_RETRY_S then return false end
    local barrier = promise.new()
    loading = barrier
    local ok, done, which = pcall(loadAll)
    if ok and done then
        loaded, failedAt = true, nil
    else
        Log.error('maps: could not load (%s); maps are unavailable until it loads',
            ok and ('collection ' .. tostring(which) .. ' is degraded') or tostring(done))
        for id in pairs(maps) do
            maps[id], sets[id], snaps[id], journalIdx[id], versionIdx[id], journalOps[id] = nil, nil, nil, nil, nil, nil
        end
        S.journalTotal = 0
        failedAt = os.time()
    end
    loading = nil
    barrier:resolve(true)
    if loaded then
        local count = 0
        for id in pairs(maps) do
            R.syncMap(id)
            count = count + 1
        end
        Log.debug('maps: loaded %d map(s)', count)
    end
    return loaded
end
R.ensureLoaded = ensureLoaded

--------------------------------------------------------------------------------
-- Input checks for create / update
--------------------------------------------------------------------------------

local function readName(v)
    if type(v) ~= 'string' then return nil end
    v = v:match('^%s*(.-)%s*$')
    if #v == 0 or #v > NAME_MAX then return nil end
    return v
end

--- A target bucket: 0..2^31-1 but never inside Config.Buckets.Range, where Core.Buckets hands out editor
--- and plugin instances (their content would mix with the map's).
local function readBucket(v)
    local n = math.tointeger(v)
    if not n or n < 0 or n > BUCKET_MAX then return nil end
    local range = Config.Buckets and Config.Buckets.Range
    local lo = range and math.tointeger(range[1]) or 10000
    local hi = range and math.tointeger(range[2]) or 60000
    if n >= lo and n <= hi then return nil end
    return n
end

--- meta = { description? } -> copy | nil, 'meta'
local function readMeta(v)
    if v == nil then return {} end
    if type(v) ~= 'table' then return nil, 'meta' end
    local d = v.description
    if d ~= nil and (type(d) ~= 'string' or #d > DESCRIPTION_MAX) then return nil, 'meta' end
    return { description = d }
end

--- expiresAt: unix seconds in the future; false/0 clears (update only) -> value|false, or nil, 'expiresAt'.
local function readExpiry(v)
    if v == false or v == 0 then return false end
    local n = math.tointeger(v)
    if not n or n <= os.time() then return nil, 'expiresAt' end
    return n
end

--- limits = { elements?, perModel?, uniqueModels?, networked? } within the settings' bounds; false clears.
local function readMapLimits(v)
    if v == false then return false end
    if type(v) ~= 'table' then return nil, 'limits' end
    local out, any = {}, false
    for key, value in pairs(v) do
        local range, n = LIMIT_RANGE[key], math.tointeger(value)
        if not range or not n or n < range[1] or n > range[2] then return nil, 'limits' end
        out[key], any = n, true
    end
    return any and out or false
end

--- A copy of a map for callers: the document plus counts, editorBucket and dirty.
local function summary(map, withModels)
    local out = Utils.deepCopy(map)
    local c = R.countSet(sets[map.id].els)
    out.counts = { elements = c.total, networked = c.networked, uniqueModels = c.unique }
    if withModels then
        local list = {}
        for model, n in pairs(c.byModel) do list[#list + 1] = { model = model, count = n } end
        table.sort(list, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.model < b.model
        end)
        for i = #list, 6, -1 do list[i] = nil end
        out.counts.topModels = list
    end
    out.editorBucket = editorBuckets[map.id]
    out.dirty = map.mode == 'draft' and map.journalSeq ~= map.publishedSeq
    return out
end

local function newMapId()
    local n = Core.DB.nextId('maps')
    local id = n and ('m' .. n)
    if id and not maps[id] then return id end
    for _ = 1, 8 do
        id = 'm' .. Utils.randomString(10, 'abcdefghijklmnopqrstuvwxyz0123456789')
        if not maps[id] then return id end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Documents
--------------------------------------------------------------------------------

--- Maps.create(input, actor) -> map|nil, err. Live maps start active unless `active = false`.
function Maps.create(input, actor)
    if type(input) ~= 'table' then return nil, 'input' end
    if not ensureLoaded() then return nil, 'unavailable' end
    local name = readName(input.name)
    if not name then return nil, 'name' end
    local mode = input.mode
    if mode ~= 'draft' and mode ~= 'live' then return nil, 'mode' end
    local bucket = input.targetBucket == nil and 0 or readBucket(input.targetBucket)
    if not bucket or isEditorBucket(bucket) then return nil, 'targetBucket' end
    local meta = readMeta(input.meta)
    if not meta then return nil, 'meta' end
    local expiresAt, limits = false, false
    if input.expiresAt ~= nil then
        expiresAt = readExpiry(input.expiresAt)
        if expiresAt == nil then return nil, 'expiresAt' end
    end
    if input.limits ~= nil then
        limits = readMapLimits(input.limits)
        if limits == nil then return nil, 'limits' end
    end
    local active = input.active
    if active == nil then active = mode == 'live' end
    if type(active) ~= 'boolean' then return nil, 'active' end
    if Core.DB.isDegraded(C_MAPS) or Core.DB.isDegraded(C_ELEMENTS) then return nil, 'db' end
    local id = newMapId()
    if not id then return nil, 'db' end
    local info, t = R.actorInfo(actor), os.time()
    local map = {
        id = id, name = name, mode = mode, active = active, targetBucket = bucket, publishedVersion = 0,
        publishedSeq = 0, nextElementId = 1, journalSeq = 0, meta = meta, limits = limits or nil,
        expiresAt = expiresAt or nil, createdAt = t, updatedAt = t,
        createdBy = { kind = info.kind, accountId = info.accountId, name = info.name },
    }
    maps[id], sets[id] = map, { els = {} }
    if not R.persistMap(map) then
        maps[id], sets[id] = nil, nil
        return nil, 'db'
    end
    R.syncMap(id)
    R.audit('create', map, actor, nil, { mode = mode, targetBucket = bucket, active = active })
    return summary(map)
end

--- Maps.get(id) -> map copy (+ counts with the top 5 models, editorBucket, dirty) | nil
function Maps.get(id)
    if not ensureLoaded() then return nil end
    local map = type(id) == 'string' and maps[id]
    return map and summary(map, true) or nil
end

--- Maps.list({ mode?, active?, text? }) -> array sorted by name.
function Maps.list(filter)
    if not ensureLoaded() then return {} end
    filter = type(filter) == 'table' and filter or {}
    local text = type(filter.text) == 'string' and filter.text ~= '' and filter.text:lower() or nil
    local out = {}
    for _, map in pairs(maps) do
        local hit = (filter.mode == nil or map.mode == filter.mode)
            and (filter.active == nil or map.active == filter.active)
        if hit and text then
            hit = map.name:lower():find(text, 1, true) ~= nil or map.id == filter.text
                or (map.meta.description and map.meta.description:lower():find(text, 1, true) ~= nil) or false
        end
        if hit then out[#out + 1] = summary(map) end
    end
    table.sort(out, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    return out
end

--- Maps.elements(id) -> array of element copies (the draft / live working set), ascending ids.
function Maps.elements(id)
    if not ensureLoaded() then return nil end
    local set = type(id) == 'string' and sets[id]
    if not set then return nil end
    return Utils.deepCopy(toArray(set.els))
end

--- Flat equality (meta and limits are one level deep).
local function sameValue(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end
    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- Maps.update(id, { name?, meta?, expiresAt?, targetBucket?, limits? }, actor) -> map|nil, err.
--- expiresAt / limits = false clear them. Every key is checked before anything changes.
function Maps.update(id, patch, actor)
    if type(patch) ~= 'table' then return nil, 'input' end
    if not ensureLoaded() then return nil, 'unavailable' end
    local map = type(id) == 'string' and maps[id]
    if not map then return nil, 'not_found' end
    local want, changes = {}, {}
    if patch.name ~= nil then
        want.name = readName(patch.name)
        if not want.name then return nil, 'name' end
    end
    if patch.meta ~= nil then
        want.meta = readMeta(patch.meta)
        if not want.meta then return nil, 'meta' end
    end
    if patch.expiresAt ~= nil then
        want.expiresAt = readExpiry(patch.expiresAt)
        if want.expiresAt == nil then return nil, 'expiresAt' end
    end
    if patch.targetBucket ~= nil then
        want.targetBucket = readBucket(patch.targetBucket)
        if not want.targetBucket or (want.targetBucket ~= map.targetBucket and isEditorBucket(want.targetBucket)) then
            return nil, 'targetBucket'
        end
    end
    if patch.limits ~= nil then
        want.limits = readMapLimits(patch.limits)
        if want.limits == nil then return nil, 'limits' end
    end
    for key, value in pairs(want) do
        local stored = value or nil               -- false clears
        local old = map[key]
        if not sameValue(old, stored) then
            changes[#changes + 1] = { key = key, old = type(old) == 'table' and json.encode(old) or old,
                new = type(stored) == 'table' and json.encode(stored) or stored }
            map[key] = stored
        end
    end
    if #changes == 0 then return summary(map) end
    map.updatedAt = os.time()
    R.persistMap(map)
    if want.targetBucket ~= nil then R.syncMap(id) end
    R.audit('update', map, actor, changes)
    return summary(map)
end

--- Maps.setActive(id, on, actor) -> true | false, err, detail
function Maps.setActive(id, on, actor)
    if type(on) ~= 'boolean' then return false, 'active' end
    if not ensureLoaded() then return false, 'unavailable' end
    local map = type(id) == 'string' and maps[id]
    if not map then return false, 'not_found' end
    if map.active == on then return true end
    local limits = R.readLimits(map)
    local expiresAt = map.expiresAt
    map.active = on
    if on and expiresAt and expiresAt <= os.time() then map.expiresAt = nil end
    if on and exceedsNetworked(map, limits.networkedTotal) then
        map.active, map.expiresAt = false, expiresAt
        return false, 'limit', { limit = 'networkedTotal', max = limits.networkedTotal }
    end
    map.updatedAt = os.time()
    R.persistMap(map)
    R.syncMap(id)
    R.audit('setActive', map, actor, { { key = 'active', old = not on, new = on } })
    return true
end

--- Runs fn as core (the owner of editor buckets), inside or outside a coroutine -> pcall results.
local function asCore(fn, ...)
    local before = Registry.getCaller()
    Registry.setCaller('core')
    local res = table.pack(Registry.withCaller('core', fn, ...))
    Registry.setCaller(before)
    return table.unpack(res, 1, res.n)
end

--- Maps.openDraft(id, actor) -> bucket | nil, err. Several editors share one open draft's bucket.
function Maps.openDraft(id, _actor)
    if not ensureLoaded() then return nil, 'unavailable' end
    local map = type(id) == 'string' and maps[id]
    if not map then return nil, 'not_found' end
    if map.mode ~= 'draft' then return nil, 'mode' end
    if editorBuckets[id] then return editorBuckets[id] end
    local limits = R.readLimits(map)
    local Buckets = rawget(Core, 'Buckets')
    if not Buckets then return nil, 'bucket' end
    local caller = Registry.getCaller()
    local ok, bucket = asCore(Buckets.allocate, { label = ('map %s'):format(map.name):sub(1, 64),
        population = false, lockdown = 'strict' })
    if not ok or not bucket then return nil, 'bucket' end
    editorBuckets[id] = bucket
    if exceedsNetworked(map, limits.networkedTotal) then
        editorBuckets[id] = nil
        asCore(Buckets.release, bucket)
        return nil, 'limit', { limit = 'networkedTotal', max = limits.networkedTotal }
    end
    Registry.track(DRAFT_KIND, id, caller)
    R.syncMap(id)
    return bucket
end

--- Maps.closeDraft(id) -> bool. The editor bucket's content goes, then the bucket is released (players
--- still inside are moved to bucket 0 by Core.Buckets; the editor returns its users before this).
local function closeDraft(id)
    local bucket = editorBuckets[id]
    if not bucket then return false end
    editorBuckets[id] = nil
    Registry.untrack(DRAFT_KIND, id)
    R.syncMap(id)
    local Buckets = rawget(Core, 'Buckets')
    if Buckets then
        local ok, released = asCore(Buckets.release, bucket)
        if not ok or not released then Log.warn('maps: could not release editor bucket %d of %s', bucket, id) end
    end
    return true
end

function Maps.closeDraft(id)
    if type(id) ~= 'string' then return false end
    return closeDraft(id)
end

-- The resource that opened a draft stopped: the draft closes with it.
Registry.onOwnerStop(DRAFT_KIND, closeDraft)

--- Maps.delete(id, actor) -> true | false, err. Elements, versions and journal go with the map.
function Maps.delete(id, actor)
    if not ensureLoaded() then return false, 'unavailable' end
    local map = type(id) == 'string' and maps[id]
    if not map then return false, 'not_found' end
    closeDraft(id)
    map.active = false
    R.syncMap(id)
    local count = 0
    for elementId in pairs(sets[id].els) do
        R.removeElement(id, elementId)
        count = count + 1
    end
    for _, v in ipairs(versionIdx[id] or {}) do Core.DB.delete(C_VERSIONS, id .. ':v' .. v.version) end
    for _, j in ipairs(journalIdx[id] or {}) do Core.DB.delete(C_JOURNAL, id .. ':j' .. j.seq) end
    Core.DB.delete(C_MAPS, id)
    S.journalTotal = S.journalTotal - (journalOps[id] or 0)
    maps[id], sets[id], snaps[id], versionIdx[id], journalIdx[id], journalOps[id] = nil, nil, nil, nil, nil, nil
    R.audit('delete', map, actor, nil, { mode = map.mode, elements = count })
    return true
end

--------------------------------------------------------------------------------
-- Publish, versions, rollback (drafts)
--------------------------------------------------------------------------------

--- Snapshots `els` as the next version and shows it in targetBucket while the map is active. Element
--- tables are never mutated in place, so a shallow copy of the id map is a stable snapshot.
local function publishSet(map, els, actor, note, action, from)
    local limits = R.readLimits(map)
    local version = map.publishedVersion + 1
    local copy = {}
    for id, el in pairs(els) do copy[id] = el end
    local previous = snaps[map.id]
    snaps[map.id] = { version = version, els = copy }
    local over = map.active and exceedsNetworked(map, limits.networkedTotal)
    snaps[map.id] = previous
    if over then return nil, 'limit', { limit = 'networkedTotal', max = limits.networkedTotal } end
    local info, at = R.actorInfo(actor), os.time()
    local list = toArray(copy)
    if not Core.DB.set(C_VERSIONS, map.id .. ':v' .. version, { mapId = map.id, version = version,
        elements = list, by = info.by, byName = info.name, note = note, at = at, count = #list, from = from }) then
        return nil, 'db'
    end
    snaps[map.id] = { version = version, els = copy }
    local old = map.publishedVersion
    map.publishedVersion, map.updatedAt = version, at
    map.publishedSeq = action == 'publish' and map.journalSeq or -1   -- a rollback leaves the draft dirty
    R.persistMap(map)
    local idx = versionIdx[map.id] or {}
    versionIdx[map.id] = idx
    idx[#idx + 1] = { version = version, by = info.by, byName = info.name, note = note, at = at, count = #list,
        from = from }
    local excess = #idx - VERSIONS_KEEP
    for i = excess, 1, -1 do
        if idx[i].version ~= version then
            Core.DB.delete(C_VERSIONS, map.id .. ':v' .. idx[i].version)
            table.remove(idx, i)
        end
    end
    R.syncMap(map.id)
    R.audit(action, map, actor, { { key = 'publishedVersion', old = old, new = version } },
        { note = note, from = from, elements = #list })
    return version
end

local function readNote(note)
    if note == nil then return true, nil end
    if type(note) ~= 'string' then return false end
    return true, note:sub(1, NOTE_MAX)
end

--- Maps.publish(id, actor, note?) -> version | nil, err
function Maps.publish(id, actor, note)
    if not ensureLoaded() then return nil, 'unavailable' end
    local map = type(id) == 'string' and maps[id]
    if not map then return nil, 'not_found' end
    if map.mode ~= 'draft' then return nil, 'mode' end
    local ok, text = readNote(note)
    if not ok then return nil, 'note' end
    return publishSet(map, sets[id].els, actor, text, 'publish', nil)
end

--- Maps.rollback(id, version, actor) -> new version | nil, err, detail. Publishes a copy of an older
--- snapshot after re-checking it (model validator, limits); the draft itself is left as it is.
function Maps.rollback(id, version, actor)
    if not ensureLoaded() then return nil, 'unavailable' end
    local map = type(id) == 'string' and maps[id]
    if not map then return nil, 'not_found' end
    if map.mode ~= 'draft' then return nil, 'mode' end
    local v = math.tointeger(version)
    local doc = v and Core.DB.get(C_VERSIONS, id .. ':v' .. v)
    if not doc then return nil, 'version' end
    local els = fromArray(doc.elements)
    local err, detail = R.checkSnapshot(map, els)     -- today's model validator and limits (maps_apply.lua)
    if err then return nil, err, detail end
    return publishSet(map, els, actor, ('rollback to v%d'):format(v), 'rollback', v)
end

--- Maps.versions(id) -> newest first { version, by, byName, note, at, count, from?, current }
function Maps.versions(id)
    if not ensureLoaded() then return nil end
    local map = type(id) == 'string' and maps[id]
    if not map then return nil end
    local out, idx = {}, versionIdx[id] or {}
    for i = #idx, 1, -1 do
        local e = Utils.deepCopy(idx[i])
        e.current = e.version == map.publishedVersion
        out[#out + 1] = e
    end
    return out
end
