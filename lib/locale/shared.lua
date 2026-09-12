--[[
    core / lib/locale/shared.lua  —  Core.Locale (DESIGN §26)

    `Locale.t(key, vars?)` resolves a key in this order:
      1. `<Core.name>/locales/<lang>.json`   -- the calling resource's own strings
      2. `core/locales/<lang>.json`          -- core's strings
      3. `Core.Config.Texts[key]`            -- DESIGN §10 defaults
      4. the key itself
    Each JSON file is read once per VM per language with `LoadResourceFile` (plugins list
    `locales/*.json` in their `files {}`); a missing or malformed file is cached as an empty
    table so it is not re-read on every call. `json.decode` runs inside `pcall`, so nothing
    here can throw in the caller's face — a broken locale file degrades to the next step.

    `{{var}}` placeholders are replaced with `Core.Utils.sanitize(tostring(value), 256)`
    (control characters stripped, DESIGN §3.1); an unknown placeholder is left as written.
    The language is `Core.Config.Locale` (default `'en'`), overridable per VM with
    `Locale.setLanguage(lang)`. `Locale.all()` returns the merged table for the current
    language — inside core that is exactly core's strings, which `client/ui.lua` pushes to
    the NUI via `Core.UI.locale.set` (DESIGN §21).

    Natives: LoadResourceFile (shared).
]]

local ns = ...

local DEFAULT_LANG <const> = 'en'
local CORE_RESOURCE <const> = 'core'
local VALUE_MAX_LEN <const> = 256

local override = nil        -- set by Locale.setLanguage, wins over Core.Config.Locale
local files = {}            -- 'resource:lang' -> strings table (empty table when missing)

--- Lower-cased, path-safe language code; `nil` for anything that is not one.
local function normalizeLang(lang)
    if type(lang) ~= 'string' then return nil end
    -- letters, digits, '_' and '-' only: no '/', '.' or '..' can reach LoadResourceFile
    local clean = lang:lower():match('^%a[%w_%-]*$')
    if not clean or #clean > 16 then return nil end
    return clean
end

local function resourceName()
    return (Core and Core.name) or CORE_RESOURCE
end

--- Reads `<resource>/locales/<lang>.json` once per VM; always returns a table.
local function loadStrings(resource, lang)
    local cacheKey = resource .. ':' .. lang
    local cached = files[cacheKey]
    if cached then return cached end
    local out = {}
    local ok, raw = pcall(LoadResourceFile, resource, ('locales/%s.json'):format(lang))
    if ok and type(raw) == 'string' and raw ~= '' then
        local decoded
        ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == 'table' then out = decoded end
    end
    files[cacheKey] = out
    return out
end

local function configTexts()
    local cfg = Core and Core.Config
    if type(cfg) ~= 'table' or type(cfg.Texts) ~= 'table' then return nil end
    return cfg.Texts
end

--- The raw string for `key`, or nil if no source has it.
local function lookup(key)
    local lang = ns.getLanguage()
    local name = resourceName()
    local value = loadStrings(name, lang)[key]
    if type(value) == 'string' then return value end
    if name ~= CORE_RESOURCE then
        value = loadStrings(CORE_RESOURCE, lang)[key]
        if type(value) == 'string' then return value end
    end
    local texts = configTexts()
    value = texts and texts[key]
    if type(value) == 'string' then return value end
    return nil
end

--- `tostring` + `Core.Utils.sanitize`; falls back to a local strip if Utils is unavailable.
local function valueToText(value)
    local ok, out = pcall(function()
        return Core.Utils.sanitize(value, VALUE_MAX_LEN)
    end)
    if ok and type(out) == 'string' then return out end
    out = tostring(value):gsub('%c', '')
    return out
end

--- Replaces `{{name}}`; a placeholder without a matching var stays in the text.
local function substitute(text, vars)
    if type(vars) ~= 'table' then return text end
    local out = text:gsub('{{%s*([%w_]+)%s*}}', function(name)
        local value = vars[name]
        if value == nil then return nil end
        return valueToText(value)
    end)
    return out
end

--- The language this VM translates into.
--- @return string
function ns.getLanguage()
    if override then return override end
    local cfg = Core and Core.Config
    local lang = type(cfg) == 'table' and cfg.Locale or nil
    return normalizeLang(lang) or DEFAULT_LANG
end

--- Overrides the language inside this VM only (no replication, no file writes).
--- @return boolean accepted
function ns.setLanguage(lang)
    local clean = normalizeLang(lang)
    if not clean then return false end
    override = clean
    return true
end

--- Translated string for `key`, or `key` itself when nothing has it.
--- @return string
function ns.t(key, vars)
    if type(key) ~= 'string' then return tostring(key) end
    local text = lookup(key)
    if not text then return key end
    return substitute(text, vars)
end

--- True when any source (resource file, core file, Config.Texts) knows `key`.
--- @return boolean
function ns.has(key)
    if type(key) ~= 'string' then return false end
    return lookup(key) ~= nil
end

--- Every string of the current language as a flat copy, in lookup precedence
--- (Config.Texts < core's file < the calling resource's file).
--- @return table
function ns.all()
    local lang = ns.getLanguage()
    local out = {}
    local sources = {}
    local texts = configTexts()
    if texts then sources[#sources + 1] = texts end
    sources[#sources + 1] = loadStrings(CORE_RESOURCE, lang)
    local name = resourceName()
    if name ~= CORE_RESOURCE then sources[#sources + 1] = loadStrings(name, lang) end
    for i = 1, #sources do
        for key, value in pairs(sources[i]) do
            if type(key) == 'string' and type(value) == 'string' then out[key] = value end
        end
    end
    return out
end
