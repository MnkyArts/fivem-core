--- core / client/ui_plugins.lua — discovery and lifecycle of resource-owned UI
--- plugins (DESIGN §38.4). A resource opts in with `core_ui '<dir>'` in its
--- fxmanifest; core reads `<dir>/manifest.json` with LoadResourceFile, validates it
--- with the shared UIManifest rules and tells the shell where the module lives.
--- A resource WITHOUT the key is never probed, so a missing or unreadable manifest
--- in one WITH it is always a loud, one-line error — never silence.
--- Loaded after client/ui.lua: it talks to it through `Core.UIInternal` (blocked
--- from the export) and adds only `UI.plugins` / `UI.isPluginReady` to the API.
--- Natives verified with fxref on 2026-09-18: GetNumResourceMetadata,
--- GetResourceMetadata, LoadResourceFile, GetNumResources, GetResourceByFindIndex,
--- GetResourceState, GetCurrentResourceName, RegisterCommand (shared),
--- GetGameTimer (client+server).
--- Runtime helpers: RegisterNuiCallback, SetTimeout, json.

local UI = Core.UI
local UIInternal = Core.UIInternal
local Registry = Core.Registry
local Log = Core.Log
local Utils = Core.Utils

local META_KEY <const> = 'core_ui'
local MAX_ERRORS_PER_SECOND <const> = 5
local DEV_ORIGIN_PATTERNS <const> = { '^https?://localhost:%d+$', '^https?://127%.0%.0%.1:%d+$' }
local SHELL_STATES <const> = { loading = true, ready = true, failed = true, incompatible = true }

local selfName <const> = GetCurrentResourceName()
local send = UIInternal.send

local plugins = {}          -- resource -> { id, dir, base, manifest, generation, state, sent, error?, ms? }
local generations = {}      -- resource -> last generation handed to the shell (survives a stop)
local devOrigins = {}       -- resource -> dev server origin for THIS session
local errorWindowAt = 0
local errorPrinted = 0
local errorDropped = 0

-- ------------------------------------------------------------- config ----

--- Config.UI value with a default (Core.Config is core's own config, §2.0).
local function uiCfg(key, default)
    local cfg = Core.Config or Config
    local value = cfg and cfg.UI and cfg.UI[key]
    if value == nil then return default end
    return value
end

--- Config.UI.Dev value with a default; the whole table may be absent and
--- production never reads any of it (§38.11).
local function devCfg(key, default)
    local dev = uiCfg('Dev', nil)
    if type(dev) ~= 'table' then return default end
    local value = dev[key]
    if value == nil then return default end
    return value
end

local function devEnabled()
    return devCfg('Enabled', false) == true
end

-- --------------------------------------------------------- discovery ----

--- Records a rejected manifest without telling the shell: the plugin stays in the
--- table so `/uiplugins` and Core.UI.plugins() can explain it, and prints ONE line
--- that names the resource, the file and the fix.
local function fail(res, dir, message, state)
    plugins[res] = {
        id = res, dir = dir, generation = generations[res] or 0,
        state = state or 'failed', sent = false, error = message,
    }
    Log.error('%s: %s', res, message)
    Core.emitHook('uiPluginFailed', res, message)
    return false
end

--- Tells the shell about one registered plugin. A manifest core itself rejected is
--- never sent — the shell would only reject it a second time.
local function sendRegister(res)
    local entry = plugins[res]
    if not entry or not entry.sent then return false end
    send({
        action = 'plugin:register', id = entry.id, generation = entry.generation,
        base = entry.base, manifest = entry.manifest, dev = entry.dev,
    })
    return true
end

--- Reads `<dir>/manifest.json` of one started resource and registers it (§38.4).
--- Returns false for every resource that is not a UI plugin, silently.
local function discover(res)
    if type(res) ~= 'string' or res == '' or res == selfName then return false end
    if (GetNumResourceMetadata(res, META_KEY) or 0) < 1 then return false end
    local dir = GetResourceMetadata(res, META_KEY, 0)
    if not UIManifest.dirOk(dir) then
        return fail(res, nil, ("core_ui '%s' is not a relative folder inside the resource")
            :format(tostring(dir)))
    end
    local file = dir .. '/manifest.json'
    local raw = LoadResourceFile(res, file)
    if type(raw) ~= 'string' or raw == '' then
        return fail(res, dir, ("%s is not readable on the client — build it (npm run build in %s/ui) "
            .. "and list '%s/**' in files {}"):format(file, res, dir))
    end
    local decoded
    local ok, err = pcall(function() decoded = json.decode(raw) end)
    if not ok or type(decoded) ~= 'table' then
        return fail(res, dir, ('%s is not valid JSON (%s)'):format(file, tostring(err)))
    end
    local valid, manifest, state = UIManifest.validate(res, decoded, dir)
    if not valid then
        return fail(res, dir, ('%s: %s'):format(file, manifest), state)
    end
    local generation = (generations[res] or 0) + 1
    generations[res] = generation
    local origin = devEnabled() and devOrigins[res] or nil
    plugins[res] = {
        id = res, dir = dir, base = ('https://cfx-nui-%s/%s/'):format(res, dir),
        manifest = manifest, generation = generation, state = 'registered', sent = true,
        dev = origin and { origin = origin } or nil,
    }
    sendRegister(res)
    return true
end

--- Drops a plugin: the shell disposes the activation (scope, pages, CSS, requests)
--- while the imported module stays cached in the document (§38.2).
local function unregister(res)
    local entry = plugins[res]
    if not entry then return false end
    plugins[res] = nil
    if entry.sent then send({ action = 'plugin:unregister', id = res }) end
    return true
end

-- ---------------------------------------------- seam + public API (§38.4) ----

--- The dev switches the shell needs; sent on ui_ready and whenever one changes.
local function sendDevSet()
    send({
        action = 'dev:set', enabled = devEnabled(), log = devCfg('Log', false) == true,
        inspector = devCfg('Inspector', false) == true,
        loadTimeoutMs = tonumber(uiCfg('PluginLoadTimeoutMs', 8000)) or 8000,
    })
end

--- Replayed by client/ui.lua on `ui_ready`, BEFORE the page registrations: the
--- shell must know which module owns a page before that page is declared. The
--- reloaded document lost every activation, so each one starts over at
--- 'registered' — the generation does NOT move, it is the same activation.
function UIInternal.replayPlugins()
    sendDevSet()
    for res, entry in pairs(plugins) do
        if entry.sent then
            entry.state, entry.ms, entry.error = 'registered', nil, nil
            sendRegister(res)
        end
    end
end

--- Is `id` a UI plugin core told the shell about (a valid channel for UI.send /
--- UI.request, even before its module finished loading).
function UIInternal.hasPlugin(id)
    local entry = type(id) == 'string' and plugins[id] or nil
    return entry ~= nil and entry.sent == true
end

--- Core.UI.plugins() — one row per known UI plugin, sorted, for tooling.
function UI.plugins()
    local list = {}
    for res, entry in pairs(plugins) do
        list[#list + 1] = {
            id = res, state = entry.state, generation = entry.generation,
            build = entry.manifest and entry.manifest.build or '',
            error = entry.error, ms = entry.ms,
            dev = entry.dev and entry.dev.origin or nil,   -- which origin it is served from
        }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

--- Core.UI.isPluginReady(resource?) — defaults to the CALLING resource, so a
--- plugin can ask `if Core.UI.isPluginReady() then` about its own frontend.
function UI.isPluginReady(resource)
    if resource == nil then resource = Registry.getCaller() end
    local entry = type(resource) == 'string' and plugins[resource] or nil
    return entry ~= nil and entry.state == 'ready'
end

-- ------------------------------------------------------------ NUI → Lua ----
-- Every callback answers cb(...) — a missing cb hangs the page's fetch().

--- The shell's load result for one activation. A stale generation (the resource
--- restarted while its module was importing) is dropped on the floor.
RegisterNuiCallback('ui_plugin', function(data, cb)
    cb({ ok = true })
    if type(data) ~= 'table' or type(data.id) ~= 'string' then return end
    local entry = plugins[data.id]
    if not entry or not entry.sent then return end
    if math.tointeger(tonumber(data.generation) or -1) ~= entry.generation then return end
    local state = SHELL_STATES[data.state] and data.state or nil
    if not state then return end
    entry.state = state
    entry.ms = math.tointeger(tonumber(data.ms) or 0)
    entry.error = type(data.error) == 'string' and Utils.sanitize(data.error, 256) or nil
    local pageCount = type(data.pages) == 'table' and #data.pages or 0
    if state == 'ready' then
        Log.info('%s: UI plugin ready in %d ms (%d page%s)', data.id, entry.ms or 0,
            pageCount, pageCount == 1 and '' or 's')
        Core.emitHook('uiPluginReady', data.id)
    elseif state ~= 'loading' then
        Log.error('%s: UI plugin %s — %s', data.id, state, entry.error or 'no reason given')
        Core.emitHook('uiPluginFailed', data.id, entry.error or state)
    end
end)

--- Prints the dropped-error summary of the window that just rolled over.
local function reportDroppedErrors()
    if errorDropped <= 0 then return end
    Log.warn('UI: %d more page error(s) in that second', errorDropped)
    errorDropped = 0
end

--- Page/plugin exceptions the shell caught (§38.12). Rate-limited to five lines a
--- second: one crashing render loop must not drown the console.
RegisterNuiCallback('ui_error', function(data, cb)
    cb({ ok = true })
    if type(data) ~= 'table' or type(data.message) ~= 'string' then return end
    local now = GetGameTimer()
    if now - errorWindowAt >= 1000 then
        errorWindowAt, errorPrinted = now, 0
        reportDroppedErrors()
    end
    if errorPrinted >= MAX_ERRORS_PER_SECOND then
        if errorDropped == 0 then SetTimeout(1000, reportDroppedErrors) end
        errorDropped = errorDropped + 1
        return
    end
    errorPrinted = errorPrinted + 1
    local where = type(data.plugin) == 'string' and data.plugin or 'shell'
    if type(data.page) == 'string' then where = where .. '/' .. data.page end
    if type(data.component) == 'string' then where = where .. ' <' .. data.component .. '>' end
    Log.error('UI error in %s: %s', where, Utils.sanitize(data.message, 512))
    if type(data.stack) == 'string' and devCfg('Log', false) == true then
        print(Utils.sanitize(data.stack, 2048))
    end
end)

--- First subscriber / last unsubscribe of a feed, for Core.UI.isFeedActive (§38.10).
RegisterNuiCallback('ui_feed', function(data, cb)
    cb({ ok = true })
    if type(data) ~= 'table' then return end
    UIInternal.setFeedActive(data.channel, data.active == true)
end)

-- ------------------------------------------------- dev commands (§38.11) ----

--- Only a local Vite server is accepted: the CEF's secure-context rules make
--- anything else useless, and an arbitrary origin would be a remote code path
--- into the NUI. A second machine forwards the port.
local function devOriginOk(origin)
    if type(origin) ~= 'string' or #origin > 64 then return false end
    for i = 1, #DEV_ORIGIN_PATTERNS do
        if origin:find(DEV_ORIGIN_PATTERNS[i]) then return true end
    end
    return false
end

--- Re-registers one plugin with (or without) its dev origin: unregister first, then
--- discover again, which hands the shell generation n+1 and a fresh activation.
local function setDevOrigin(res, origin)
    devOrigins[res] = origin
    unregister(res)
    if not discover(res) then
        Log.warn("%s: no UI plugin to re-register (no core_ui '<dir>' in its fxmanifest?)", res)
        return false
    end
    Log.info('%s: UI plugin re-registered %s', res, origin and ('from ' .. origin) or 'from its build')
    return true
end

--- /uidev <resource> <origin|off> — point one plugin at its Vite dev server.
RegisterCommand('uidev', function(_, args)
    if not devEnabled() then
        Log.error('/uidev needs Config.UI.Dev.Enabled = true')
        return
    end
    local res, origin = args and args[1], args and args[2]
    if type(res) ~= 'string' or type(origin) ~= 'string' then
        Log.info('usage: /uidev <resource> <http://localhost:5173|off>')
        return
    end
    if origin == 'off' then
        setDevOrigin(res, nil)
        return
    end
    if not devOriginOk(origin) then
        Log.error("/uidev: '%s' is not a localhost origin (http://localhost:<port>)", origin)
        return
    end
    setDevOrigin(res, origin)
end, false)

--- /uiinspect — toggles the shell's inspector panel (§38.14), dev only.
RegisterCommand('uiinspect', function()
    if not devEnabled() then
        Log.error('/uiinspect needs Config.UI.Dev.Enabled = true')
        return
    end
    send({ action = 'inspector:toggle' })
end, false)

--- /uiplugins — one line per known UI plugin; always available, it is the first
--- thing to look at when a page stays blank.
RegisterCommand('uiplugins', function()
    local list = UI.plugins()
    if #list == 0 then
        print('[core] no UI plugins registered')
        return
    end
    for i = 1, #list do
        local row = list[i]
        print(('[core] %-20s %-12s gen %-3d %-12s %s%s'):format(row.id, row.state, row.generation,
            row.build ~= '' and row.build or '-', row.error or '',
            row.dev and ('dev=' .. row.dev) or ''))
    end
end, false)

-- ---------------------------------------------------------- lifecycle ----

AddEventHandler('onClientResourceStart', function(resource)
    discover(resource)
end)

-- Same event as the registry sweep in client/api.lua, so the ordering of the two
-- is fixed; neither depends on the other having run (§38.4).
-- The dev origin is SESSION state and deliberately survives this: restarting a
-- plugin to pick up a Lua change must not silently drop its frontend back to the
-- built bundle. Only `/uidev <res> off` clears it (§38.11).
AddEventHandler('onResourceStop', function(resource)
    if type(resource) ~= 'string' or resource == selfName then return end
    unregister(resource)
end)

-- Core's own start: every resource that is already running was missed by
-- onClientResourceStart. One pass, one tick after load, never again.
CreateThread(function()
    Wait(0)
    local seeded = uiCfg('Dev', nil)
    seeded = type(seeded) == 'table' and seeded.Servers or nil
    if devEnabled() and type(seeded) == 'table' then
        for res, origin in pairs(seeded) do
            if type(res) == 'string' and devOriginOk(origin) then devOrigins[res] = origin end
        end
    end
    local count = GetNumResources() or 0
    for i = 0, count - 1 do
        local res = GetResourceByFindIndex(i)
        -- a resource that started in this same tick already came through
        -- onClientResourceStart; discovering it twice would burn a generation
        if res and not plugins[res] and GetResourceState(res) == 'started' then discover(res) end
    end
end)

-- end of file
