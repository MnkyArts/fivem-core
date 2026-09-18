--- core / shared/ui_manifest.lua — the UI-plugin manifest validator (DESIGN §38.4).
--- Pure Lua: it calls no native at all, so the same rules run on the client
--- (discovery, client/ui_plugins.lua) and on the server (start-up validation,
--- server/ui_plugins.lua) and can be unit-tested offline.
--- Natives: none. Runtime helpers: none.
--- `UIManifest` is a deliberate global (shared_scripts reaches both VMs, §2.0).

local API_VERSION <const> = 1     -- the SDK contract this core implements (§38.3)
local MAX_CSS <const> = 8
local MAX_PRELOAD <const> = 16
local MAX_PAGES <const> = 64
local MAX_BUILD <const> = 64
local MAX_ID <const> = 64
local MAX_VFS_PATH <const> = 255  -- FiveM cuts `resources:/<res>/<path>` at 255 (§38.1)
local PATH_CHARS <const> = '^[%w%._%-/]+$'
local LOAD_MODES <const> = { eager = true, lazy = true }

UIManifest = { API_VERSION = API_VERSION }

--- True for a relative folder inside a resource: the `core_ui '<dir>'` charset
--- (§38.4). An absolute URL or a traversal would let a plugin point the CEF at
--- an arbitrary origin, so both are refused here, once, for every caller.
---@param dir any
---@return boolean
function UIManifest.dirOk(dir)
    return type(dir) == 'string' and dir ~= '' and #dir <= 128
        and dir:find(PATH_CHARS) ~= nil
        and not dir:find('..', 1, true)
        and dir:sub(1, 1) ~= '/' and dir:sub(-1) ~= '/'
        and not dir:find('://', 1, true)
end

--- Why `path` is not a shippable file of `suffix` kind, or nil when it is fine.
local function pathProblem(path, suffix, label)
    if type(path) ~= 'string' or path == '' then
        return ('%s must be a string'):format(label)
    end
    if #path > MAX_VFS_PATH or not path:find(PATH_CHARS) then
        return ("%s '%s' is not a relative path of [%%w%%._%%-/]"):format(label, path)
    end
    if path:find('..', 1, true) or path:sub(1, 1) == '/' then
        return ("%s '%s' must not be absolute or contain '..'"):format(label, path)
    end
    if not path:find(suffix) then
        return ("%s '%s' does not end in %s"):format(label, path, suffix:gsub('%%', ''):gsub('%$', ''))
    end
    return nil
end

--- The vfs path a file gets inside the CEF; longer than 255 chars is served as
--- a 404 by the NUI scheme handler, so it is a build error, not a mystery.
local function vfsTooLong(prefix, path)
    return #(prefix .. path) >= MAX_VFS_PATH
end

--- Reads an optional array of paths (`css`, `preload`) into a fresh, bounded list.
local function readPaths(value, label, suffix, max, prefix)
    if value == nil then return {} end
    if type(value) ~= 'table' then return nil, ("'%s' must be an array"):format(label) end
    local out = {}
    for i = 1, math.min(#value, max + 1) do
        if i > max then return nil, ("'%s' has more than %d entries"):format(label, max) end
        local entry = value[i]
        local problem = pathProblem(entry, suffix, ("'%s[%d]'"):format(label, i))
        if problem then return nil, problem end
        if vfsTooLong(prefix, entry) then
            return nil, ("'%s' is longer than %d characters inside the CEF"):format(entry, MAX_VFS_PATH)
        end
        out[i] = entry
    end
    return out
end

--- A plain id: the same charset page ids use, so a manifest can never name a
--- page core would refuse to register.
local function isPlainId(value)
    return type(value) == 'string' and #value >= 1 and #value <= MAX_ID
        and value:find('^[%w_%-]+$') ~= nil
end

--- UIManifest.validate(resource, m, dir?) -> ok, normalized|error, state?
--- `state` is only set on failure: 'incompatible' for an apiVersion mismatch
--- (the plugin is fine, this core is the wrong one), 'failed' for everything
--- else. `dir` is the `core_ui` folder; it is only needed for the 255-char vfs
--- budget and may be omitted by callers that do not know it yet.
---@param resource string
---@param m any decoded manifest.json
---@param dir? string
---@return boolean ok, table|string normalizedOrError, string|nil state
function UIManifest.validate(resource, m, dir)
    if type(resource) ~= 'string' or resource == '' then
        return false, 'validate() needs the resource name', 'failed'
    end
    if type(m) ~= 'table' then
        return false, 'manifest.json is not a JSON object', 'failed'
    end
    if m.id ~= resource then
        return false, ("'id' must be the resource name ('%s'), got %s"):format(resource, tostring(m.id)), 'failed'
    end
    if math.type(m.apiVersion) ~= 'integer' then
        return false, ("'apiVersion' must be an integer, got %s"):format(tostring(m.apiVersion)), 'failed'
    end
    if m.apiVersion ~= API_VERSION then
        return false, ('%s was built for core UI API %d, this core provides %d — rebuild the plugin with this core\'s @core/ui or update core')
            :format(resource, m.apiVersion, API_VERSION), 'incompatible'
    end

    local prefix = ('resources:/%s/%s'):format(resource, (dir and dir ~= '') and (dir .. '/') or '')
    local problem = pathProblem(m.entry, '%.m?js$', "'entry'")
    if problem then return false, problem, 'failed' end
    if vfsTooLong(prefix, m.entry) then
        return false, ("'%s' is longer than %d characters inside the CEF"):format(m.entry, MAX_VFS_PATH), 'failed'
    end

    local css, err = readPaths(m.css, 'css', '%.css$', MAX_CSS, prefix)
    if not css then return false, err, 'failed' end
    local preload
    preload, err = readPaths(m.preload, 'preload', '%.m?js$', MAX_PRELOAD, prefix)
    if not preload then return false, err, 'failed' end

    if m.build ~= nil and (type(m.build) ~= 'string' or #m.build > MAX_BUILD) then
        return false, ("'build' must be a string of at most %d characters"):format(MAX_BUILD), 'failed'
    end
    local load = m.load
    if load == nil then load = 'eager' end
    if not LOAD_MODES[load] then
        return false, ("'load' must be 'eager' or 'lazy', got %s"):format(tostring(load)), 'failed'
    end

    local pages = {}
    if m.pages ~= nil then
        if type(m.pages) ~= 'table' then return false, "'pages' must be an array", 'failed' end
        if #m.pages > MAX_PAGES then
            return false, ("'pages' has more than %d entries"):format(MAX_PAGES), 'failed'
        end
        for i = 1, #m.pages do
            if not isPlainId(m.pages[i]) then
                return false, ("'pages[%d]' is not a plain id (%s)"):format(i, tostring(m.pages[i])), 'failed'
            end
            pages[i] = m.pages[i]
        end
    end

    return true, {
        id = resource, apiVersion = m.apiVersion, entry = m.entry, css = css,
        build = m.build or '', load = load, preload = preload, pages = pages,
        -- free-form build stamps the shell shows in its diagnostics (§38.14)
        sdk = type(m.sdk) == 'string' and #m.sdk <= 32 and m.sdk or nil,
        vue = type(m.vue) == 'string' and #m.vue <= 32 and m.vue or nil,
    }
end

-- end of file
