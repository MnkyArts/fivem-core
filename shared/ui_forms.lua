-- Bounded Lua-driven form/menu schemas; no natives. Internal to the UI bridge.
local Forms, Utils = {}, Core.Utils
local checkValue
local TYPES = { text = true, number = true, checkbox = true, select = true, textarea = true,
    password = true, slider = true, multiselect = true, date = true, time = true, color = true }
local function finite(v)
    return type(v) == 'number' and v == v and math.abs(v) < math.huge
end
local function scalar(v)
    return type(v) == 'string' or type(v) == 'boolean' or finite(v)
end
local function optionValue(option)
    if type(option) == 'table' then return option.value end
    return option
end
local function member(options, value)
    for i = 1, #options do if optionValue(options[i]) == value then return true end end
    return false
end
function Forms.fields(raw)
    if type(raw) ~= 'table' or #raw < 1 or #raw > 32 then return nil end
    local fields, names = {}, {}
    for i = 1, #raw do
        local f = raw[i]
        if type(f) ~= 'table' then return nil end
        local kind = f.type or 'text'
        if kind == 'multi-select' or (kind == 'select' and f.multiple == true) then kind = 'multiselect' end
        if not TYPES[kind] or not Core.Validate.value('id', f.name) or names[f.name] then return nil end
        names[f.name] = true
        local out = { name = f.name, type = kind, required = f.required == true,
            label = type(f.label) == 'string' and Utils.sanitize(f.label, 96) or f.name,
            placeholder = type(f.placeholder) == 'string' and Utils.sanitize(f.placeholder, 64) or nil,
            searchable = f.searchable == true }
        for _, key in ipairs({ 'min', 'max', 'step', 'minLength', 'maxLength' }) do
            local n = f[key]
            if n ~= nil then
                if not finite(n) or math.abs(n) > 1000000000 then return nil end
                if (key == 'minLength' or key == 'maxLength') and (n % 1 ~= 0 or n < 0 or n > 4096) then return nil end
                if key == 'step' and n <= 0 then return nil end
                out[key] = n
            end
        end
        if out.min and out.max and out.min > out.max then return nil end
        if out.minLength and out.maxLength and out.minLength > out.maxLength then return nil end
        if kind == 'select' or kind == 'multiselect' then
            if type(f.options) ~= 'table' or #f.options < 1 or #f.options > 200 then return nil end
            out.options = {}
            for j = 1, #f.options do
                local option, value = f.options[j], optionValue(f.options[j])
                if not scalar(value) or (type(value) == 'string' and #value > 256) then return nil end
                if member(out.options, value) then return nil end
                out.options[j] = type(option) == 'table'
                    and { label = Utils.sanitize(tostring(option.label or value), 96), value = value } or value
            end
        end
        if f.default ~= nil then
            -- Initial values may still need user completion; types, bounds and membership still apply.
            local valid, value = checkValue(out, f.default, true)
            if not valid then return nil end
            out.default = value
        end
        fields[i] = out
    end
    return fields
end
-- fxlint-disable-next-line C003 -- checkValue is forward-declared local above Forms.fields
checkValue = function(field, value, initial)
    local required = field.required and not initial
    if value == nil then return not required, nil end
    local kind = field.type
    if kind == 'checkbox' then return type(value) == 'boolean' and (not required or value == true), value end
    if kind == 'number' or kind == 'slider' then
        if not finite(value) or (field.min and value < field.min) or (field.max and value > field.max) then return false end
        if field.step then
            local steps = (value - (field.min or 0)) / field.step
            if math.abs(steps - math.floor(steps + 0.5)) > 0.000001 then return false end
        end
        return true, value
    end
    if kind == 'select' then return member(field.options, value), value end
    if kind == 'multiselect' then
        if type(value) ~= 'table' or getmetatable(value) ~= nil or #value > #field.options
            or (required and #value == 0) then return false end
        local out, seen, count = {}, {}, 0
        for key, item in pairs(value) do
            if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > #value
                or not scalar(item) or not member(field.options, item) or seen[item] then return false end
            out[key], seen[item], count = item, true, count + 1
        end
        if count ~= #value then return false end
        return true, out
    end
    if type(value) ~= 'string' or #value > (field.maxLength or field.max or 256)
        or (not initial and #value < (field.minLength or 0)) or (required and value == '') then return false end
    if value == '' and not required then return true, value end
    if kind == 'color' and not value:match('^#%x%x%x%x%x%x$') then return false end
    if kind == 'time' then
        local hour, minute = value:match('^(%d%d):(%d%d)$')
        if not hour or tonumber(hour) > 23 or tonumber(minute) > 59 then return false end
    end
    if kind == 'date' then
        local year, month, day = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
        year, month, day = tonumber(year), tonumber(month), tonumber(day)
        if not year or year < 1 or month < 1 or month > 12 or day < 1 then return false end
        local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
        local days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
        if day > days[month] then return false end
    end
    return true, value
end
function Forms.answer(fields, raw)
    if type(fields) ~= 'table' or type(raw) ~= 'table' then return nil end
    local out, names = {}, {}
    for i = 1, #fields do
        local f = fields[i]
        names[f.name] = true
        local ok, value = checkValue(f, raw[f.name])
        if not ok then return nil end
        out[f.name] = value
    end
    for key in pairs(raw) do if not names[key] then return nil end end
    return out
end

-- Public row values and callbacks stay in Lua; only numeric ids reach the browser/client.
function Forms.menu(raw)
    if type(raw) ~= 'table' then return nil end
    local records, total = {}, 0
    local function walk(items, depth, parentDisabled)
        if depth > 8 or type(items) ~= 'table' then return nil end
        local sent = {}
        for i = 1, #items do
            local item = items[i]
            if type(item) ~= 'table' or type(item.label) ~= 'string' or item.label == '' then return nil end
            total = total + 1
            if total > 200 then return nil end
            local id = total
            local value = item.value
            if value == nil then value = item.label end
            local row = { value = id, label = Utils.sanitize(item.label, 128),
                description = type(item.description) == 'string' and Utils.sanitize(item.description, 256) or nil,
                icon = type(item.icon) == 'string' and Utils.sanitize(item.icon, 64) or nil,
                disabled = parentDisabled or item.disabled == true }
            local entry = { value = value, row = row, onChange = item.onChange }
            if entry.onChange ~= nil and not Utils.isCallable(entry.onChange) then return nil end
            records[id] = entry
            if type(item.checked) == 'boolean' then row.checked = item.checked end
            if item.values ~= nil then
                if type(item.values) ~= 'table' or #item.values < 1 or #item.values > 100 then return nil end
                row.values, entry.values = {}, {}
                for j = 1, #item.values do
                    local option = item.values[j]
                    local selected = option
                    if type(option) == 'table' then
                        selected = option.value
                        if selected == nil then selected = option.label end
                    end
                    row.values[j] = Utils.sanitize(tostring(type(option) == 'table' and option.label or option), 96)
                    entry.values[j] = selected
                end
                row.selected = item.selected or 1
                if not finite(row.selected) or row.selected % 1 ~= 0 or row.selected < 1 or row.selected > #row.values then return nil end
            end
            if row.checked ~= nil and row.values then return nil end
            if item.progress ~= nil then
                if not finite(item.progress) or item.progress < 0 or item.progress > 100 then return nil end
                row.progress = item.progress
            end
            if type(item.metadata) == 'table' then
                row.metadata = {}
                for j = 1, math.min(#item.metadata, 16) do
                    local meta = item.metadata[j]
                    if type(meta) == 'table' and scalar(meta.value) then
                        row.metadata[#row.metadata + 1] = { label = Utils.sanitize(tostring(meta.label or ''), 96),
                            value = Utils.sanitize(tostring(meta.value), 256) }
                    end
                end
            end
            if item.items ~= nil then
                row.items = walk(item.items, depth + 1, row.disabled)
                if not row.items or #row.items == 0 then return nil end
            end
            sent[#sent + 1] = row
        end
        return sent
    end
    local sent = walk(raw, 1, false)
    if not sent or #sent == 0 then return nil end
    return sent, records
end
function Forms.menuValue(records, id)
    local entry = type(id) == 'number' and id % 1 == 0 and records[id]
    if not entry or entry.row.disabled or entry.row.items then return nil end
    return entry.value
end
function Forms.menuChange(records, data)
    if type(data) ~= 'table' then return false end
    local entry = finite(data.value) and data.value % 1 == 0 and records[data.value]
    if not entry or entry.row.disabled or entry.row.items then return false end
    local row, selected = entry.row, nil
    if row.checked ~= nil then
        if type(data.checked) ~= 'boolean' or data.selected ~= nil then return false end
        row.checked, selected = data.checked, data.checked
    elseif row.values then
        local index = data.selected
        if not finite(index) or index % 1 ~= 0 or index < 1 or index > #row.values or data.checked ~= nil then return false end
        row.selected, selected = index, entry.values[index]
    else return false end
    return true, entry, selected
end
Core.UIForms = Forms
