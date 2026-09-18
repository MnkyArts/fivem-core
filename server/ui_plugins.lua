--- core / server/ui_plugins.lua — start-up validation of every UI plugin (DESIGN
--- §38.4, last paragraph). It runs the SAME shared validator the client runs, plus
--- the three checks only the server can make cheaply: that the entry and stylesheet
--- files really exist, that a `files {}` glob packs `<dir>` for the client (an
--- unlisted file is simply not downloadable) and that no `client_script` glob
--- overlaps it (FiveM then serves the module as gameconfig.xml — §38.1).
--- Errors go to the server console, where a developer looks first. This file sends
--- nothing to any client and registers no event of its own.
--- Natives verified with fxref on 2026-09-18 (all apiset shared): GetNumResources,
--- GetResourceByFindIndex, GetResourceState, GetNumResourceMetadata,
--- GetResourceMetadata, LoadResourceFile, GetCurrentResourceName.

local Log = Core.Log

local META_KEY <const> = 'core_ui'
local selfName <const> = GetCurrentResourceName()

--- Every value of one metadata key as a plain array.
local function metaList(res, key)
    local out = {}
    local count = GetNumResourceMetadata(res, key) or 0
    for i = 0, count - 1 do
        local value = GetResourceMetadata(res, key, i)
        if type(value) == 'string' and value ~= '' then out[#out + 1] = value end
    end
    return out
end

--- Everything before the first `*`: the part of a glob that is a literal path.
local function globPrefix(glob)
    local star = glob:find('*', 1, true)
    return star and glob:sub(1, star - 1) or glob
end

--- Does `glob` reach into `dir`? Compared both ways, because 'ui/dist/**' has the
--- prefix 'ui/dist/' while the folder itself is 'ui/dist' — one contains the other
--- whichever is shorter. An empty prefix ('**/…') matches the whole resource.
local function globCovers(glob, dir)
    local prefix = globPrefix(glob)
    if prefix == '' then return true end
    return dir:sub(1, #prefix) == prefix or prefix:sub(1, #dir) == dir
end

--- Reads, validates and reports one resource. Returns true when it is a healthy
--- UI plugin, false for a broken one and nil for a resource that is not one.
local function check(res)
    if type(res) ~= 'string' or res == '' or res == selfName then return nil end
    if (GetNumResourceMetadata(res, META_KEY) or 0) < 1 then return nil end
    local dir = GetResourceMetadata(res, META_KEY, 0)
    if not UIManifest.dirOk(dir) then
        Log.error("%s: core_ui '%s' is not a relative folder inside the resource", res, tostring(dir))
        return false
    end
    local file = dir .. '/manifest.json'
    local raw = LoadResourceFile(res, file)
    if type(raw) ~= 'string' or raw == '' then
        Log.error('%s: %s is missing — run `npm run build` in %s/ui', res, file, res)
        return false
    end
    local decoded
    local ok, err = pcall(function() decoded = json.decode(raw) end)
    if not ok or type(decoded) ~= 'table' then
        Log.error('%s: %s is not valid JSON (%s)', res, file, tostring(err))
        return false
    end
    local valid, manifest, state = UIManifest.validate(res, decoded, dir)
    if not valid then
        Log.error('%s: %s: %s%s', res, file, manifest,
            state == 'incompatible' and ' [incompatible]' or '')
        return false
    end

    local healthy = true
    local wanted = { manifest.entry }
    for i = 1, #manifest.css do wanted[#wanted + 1] = manifest.css[i] end
    for i = 1, #wanted do
        if LoadResourceFile(res, dir .. '/' .. wanted[i]) == nil then
            Log.error('%s: %s/%s is listed in manifest.json but not on disk — rebuild the plugin',
                res, dir, wanted[i])
            healthy = false
        end
    end

    local packed = false
    for _, glob in ipairs(metaList(res, 'file')) do
        if globCovers(glob, dir) then
            packed = true
            break
        end
    end
    if not packed then
        Log.error("%s: no files {} entry covers '%s' — add files { '%s/**' } or the client cannot "
            .. 'download the plugin', res, dir, dir)
        healthy = false
    end
    for _, glob in ipairs(metaList(res, 'client_script')) do
        -- a glob that can only ever match .lua never reaches a dist of js/css/json,
        -- and `client_scripts { '**/*.lua' }` is an ordinary, harmless manifest
        if glob:sub(-4) ~= '.lua' and globCovers(glob, dir) then
            Log.warn("%s: client_script '%s' overlaps '%s' — FiveM would serve those files as "
                .. 'gameconfig.xml; narrow the glob', res, glob, dir)
        end
    end

    if healthy then
        Log.info('%s: UI plugin ok (build %s, %d css)', res,
            manifest.build ~= '' and manifest.build or '?', #manifest.css)
    end
    return healthy
end

AddEventHandler('onResourceStart', function(resource)
    check(resource)
end)

-- Core's own start: everything already running was missed by onResourceStart.
CreateThread(function()
    Wait(0)
    local count = GetNumResources() or 0
    for i = 0, count - 1 do
        local res = GetResourceByFindIndex(i)
        if res and GetResourceState(res) == 'started' then check(res) end
    end
end)

-- end of file
