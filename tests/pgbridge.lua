--[[
    core/tests/pgbridge.lua — the Lua half of the test bridge (DESIGN §56.10.2).

    Offline suites run the REAL core_db code against the throwaway test database
    (CORE_TEST_PG_URL, default postgres://core_test:core_test@127.0.0.1:5432/core_test;
    `scripts/test-db.sh up` creates it). `node ../core_db/tests/bridge.mjs <in> <out>` hosts
    `createCoreDb(fakeFivem, { testMode = true })`; Lua and Node talk over two FIFOs in
    `tests/.bridge-<pid>/`, one JSON object per line:

        Lua → Node   { "id": n, "invoker": "core", "fn": "query", "args": [ ..., { "$cb": k } ] }
        Node → Lua   { "cb": k, "args": [...] }        a callback firing (invoked right here)
                     { "event": name, "args": [...] }  a local event core_db emitted (every installed VM)
                     { "done": n, "ret": value }        the call returned and all its callbacks fired

    Lua reads until `done`, so every call is synchronous from Lua's point of view: suites keep
    calling DB-backed code from their main chunk. The `exports.core_db` object `install` puts
    into a VM carries `synchronous = true`; lib/db/server.lua reads that raw field to allow an
    awaited call outside a coroutine (FiveM's own `exports` never holds it).

        local bridge = stubs.bridge        -- tests/stubs.lua loads this file and installs it in every server VM
        bridge.install(env, 'core', isLive) -- exports.core_db + GetResourceState('core_db') == 'started';
                                           -- isLive() = still in the current test world (events go there)
        bridge.running()                   -- has the Node process been started
        bridge.reset()                     -- TRUNCATE every table but core_migrations, reset queue/catalog/barriers
        bridge.recreate()                  -- DROP and re-create the public schema (legacy-import suite)
        bridge.sql(sql, params)            -- rows | nil, err — a direct query as the invoker `tests`
        bridge.fail(pattern, err) / bridge.unfail()   -- statements matching the Lua pattern answer `err`
        bridge.mapResource(res, dir)       -- LoadResourceFile(res, p) reads <dir>/<p>
        bridge.stop()

    The bridge starts on the first call through it (a suite that never touches core_db needs no
    database) and resets the database once when it starts. Cleanup: the FIFO directory is removed by
    the spawning shell as soon as Node exits, and Node exits on EOF — i.e. when this process exits,
    however it exits. Lua opens the request FIFO read-write (never blocks, never SIGPIPEs) and then
    the answer FIFO read-only, so the opens cannot deadlock whichever order Node opens them in; if Node
    dies before opening its end, the shell opens it once so this process sees EOF instead of hanging.
]]

local bridge = {}

local selfPath = debug.getinfo(1, 'S').source:sub(2)
local TESTS_DIR = selfPath:match('^(.*)[/\\][^/\\]*$') or '.'
local BRIDGE_JS = TESTS_DIR .. '/../../core_db/tests/bridge.mjs'
local UNREACHABLE = 'the test database is unreachable — run scripts/test-db.sh up'

--------------------------------------------------------------------------------
-- JSON (what JSON.stringify / JSON.parse on the Node side expect)
--------------------------------------------------------------------------------

local ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n',
    ['\r'] = '\\r', ['\t'] = '\\t' }

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c) return ESCAPES[c] or ('\\u%04x'):format(c:byte()) end) .. '"'
end

--- The shortest decimal text that reads back as exactly `v` (floats), integers as they are.
local function encodeNumber(v)
    if math.type(v) == 'integer' then return tostring(v) end
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end
    for digits = 14, 17 do
        local text = ('%.' .. digits .. 'g'):format(v)
        if tonumber(text) == v then return text end
    end
    return ('%.17g'):format(v)
end

--- A sequence = integer keys exactly 1..n (n ≥ 1), plus at most an `n` key that is dropped the way
--- FiveM's msgpack drops it; the empty table is `[]` (msgpack sends {} as an empty array too).
local function sequenceLength(t)
    local count, extra = 0, false
    for key in pairs(t) do
        if math.type(key) == 'integer' and key >= 1 then
            count = count + 1
        elseif key == 'n' then
            extra = true
        else
            return nil
        end
    end
    if count == 0 then return (not extra) and 0 or nil end
    for i = 1, count do
        if t[i] == nil then return nil end
    end
    return count
end

--- Appends the JSON text of `v` to `buf`.
local function encodeValue(v, buf, depth)
    local kind = type(v)
    if v == nil then
        buf[#buf + 1] = 'null'
    elseif kind == 'boolean' then
        buf[#buf + 1] = v and 'true' or 'false'
    elseif kind == 'number' then
        buf[#buf + 1] = encodeNumber(v)
    elseif kind == 'string' then
        buf[#buf + 1] = encodeString(v)
    elseif kind ~= 'table' then
        error('pgbridge: cannot encode a ' .. kind, 0)
    elseif depth > 64 then
        error('pgbridge: table nested too deeply (a cycle?)', 0)
    else
        local n = sequenceLength(v)
        if n then
            buf[#buf + 1] = '['
            for i = 1, n do
                if i > 1 then buf[#buf + 1] = ',' end
                encodeValue(v[i], buf, depth + 1)
            end
            buf[#buf + 1] = ']'
            return
        end
        buf[#buf + 1] = '{'
        local first = true
        for key, value in pairs(v) do
            if not first then buf[#buf + 1] = ',' end
            first = false
            buf[#buf + 1] = encodeString(tostring(key))
            buf[#buf + 1] = ':'
            encodeValue(value, buf, depth + 1)
        end
        buf[#buf + 1] = '}'
    end
end

local function encode(v)
    local buf = {}
    encodeValue(v, buf, 0)
    return table.concat(buf)
end

-- array -> its element count (JSON nulls leave holes, so `#` cannot tell the length of `args`)
local arrayLength = setmetatable({}, { __mode = 'k' })
local UNESCAPES = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function decodeString(s, i)
    local parts, count, at = nil, 0, i + 1
    while true do
        local stop = s:find('["\\]', at)
        if not stop then error('pgbridge: unterminated string in a bridge line', 0) end
        if s:byte(stop) == 34 then -- the closing quote
            if not parts then return s:sub(at, stop - 1), stop + 1 end
            count = count + 1
            parts[count] = s:sub(at, stop - 1)
            return table.concat(parts), stop + 1
        end
        parts = parts or {}
        count = count + 1
        parts[count] = s:sub(at, stop - 1)
        local c = s:sub(stop + 1, stop + 1)
        if c == 'u' then
            local code = tonumber(s:sub(stop + 2, stop + 5), 16) or 63
            at = stop + 6
            if code >= 0xD800 and code <= 0xDBFF then -- a surrogate pair from JSON.stringify
                local low = s:match('^\\u(%x%x%x%x)', at)
                local lo = low and tonumber(low, 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                    code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
                    at = at + 6
                end
            end
            count = count + 1
            parts[count] = utf8.char(code)
        else
            count = count + 1
            parts[count] = UNESCAPES[c] or c
            at = stop + 2
        end
    end
end

local function skip(s, i)
    return s:find('[^ \t\r\n]', i) or #s + 1
end

local function decodeValue(s, i)
    i = skip(s, i)
    local c = s:byte(i)
    if c == 34 then return decodeString(s, i) end
    if c == 123 then -- {
        local out = {}
        i = skip(s, i + 1)
        if s:byte(i) == 125 then return out, i + 1 end
        while true do
            local key
            key, i = decodeString(s, skip(s, i))
            i = skip(s, i) + 1 -- ':'
            out[key], i = decodeValue(s, i)
            i = skip(s, i)
            local sep = s:byte(i)
            i = i + 1
            if sep == 125 then return out, i end
            if sep ~= 44 then error('pgbridge: malformed object in a bridge line', 0) end
        end
    end
    if c == 91 then -- [
        local out, n = {}, 0
        i = skip(s, i + 1)
        if s:byte(i) == 93 then
            arrayLength[out] = 0
            return out, i + 1
        end
        while true do
            n = n + 1
            out[n], i = decodeValue(s, i)
            i = skip(s, i)
            local sep = s:byte(i)
            i = i + 1
            if sep == 93 then
                arrayLength[out] = n
                return out, i
            end
            if sep ~= 44 then error('pgbridge: malformed array in a bridge line', 0) end
        end
    end
    local word = s:match('^[%w%.%+%-]+', i)
    if not word then error(('pgbridge: unexpected character at %d in a bridge line'):format(i), 0) end
    local value
    if word == 'true' then
        value = true
    elseif word == 'false' then
        value = false
    elseif word ~= 'null' then
        value = tonumber(word)
        if value == nil then error('pgbridge: bad number ' .. word, 0) end
        if math.type(value) == 'float' and value == math.floor(value) then
            value = math.tointeger(value) or value  -- JSON has one number type: integral → integer
        end
    end
    return value, i + #word
end

local function decode(s)
    local value = decodeValue(s, 1)
    return value
end

local function unpackArgs(args)
    if type(args) ~= 'table' then return end
    return table.unpack(args, 1, arrayLength[args] or #args)
end

bridge.encode, bridge.decode = encode, decode

--------------------------------------------------------------------------------
-- the Node process and the line protocol
--------------------------------------------------------------------------------

local proc = nil          -- { input = file (Lua → Node), output = file (Node → Lua), dir = path } while running
local nextRequest, nextCallback = 0, 0
local callbacks = {}      -- k -> Lua function, until it fired or its request is done
local finished = {}       -- request id -> { ret = value } (a `done` read while another call was pumping)
local installed = {}      -- { env = env, isLive = fn|nil } for every VM the bridge was installed into
bridge.errors = {}        -- errors raised by Lua callbacks / event handlers invoked from the bridge

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function fileExists(path)
    local fh = io.open(path, 'rb')
    if fh then fh:close() end
    return fh ~= nil
end

local function processId()
    -- fxlint-disable-next-line S006 -- offline test harness: the shell's parent is this Lua process
    local pipe = io.popen('echo $PPID')
    local pid = pipe and pipe:read('l')
    if pipe then pipe:close() end
    return tonumber(pid) or os.time()
end

local function report(what, err)
    local line = ('[pgbridge] %s: %s'):format(what, tostring(err))
    bridge.errors[#bridge.errors + 1] = line
    io.stderr:write(line, '\n')
end

--- The bridge process went away: close our ends and raise the one clear error.
local function lost(detail)
    if proc then
        pcall(proc.input.close, proc.input)
        pcall(proc.output.close, proc.output)
        proc = nil
    end
    error(('pgbridge: %s — %s'):format(detail, UNREACHABLE), 0)
end

local function dispatchEvent(name, args)
    local live = {}
    for i = 1, #installed do
        local entry = installed[i]
        if entry.isLive == nil or entry.isLive() then live[#live + 1] = entry end
    end
    installed = live
    for i = 1, #live do
        local ok, err = pcall(live[i].env.TriggerEvent, name, unpackArgs(args))
        if not ok then report('event ' .. tostring(name), err) end
    end
end

--- Reads answer lines until request `id` is done; callbacks and events are handled on the way.
local function pump(id)
    while not finished[id] do
        local line = proc.output:read('l')
        if not line then lost('the bridge process exited (its output is above)') end
        local ok, msg = pcall(decode, line)
        if not ok or type(msg) ~= 'table' then
            lost('unreadable bridge line: ' .. line:sub(1, 200))
        end
        if msg.cb ~= nil then
            local fn = callbacks[msg.cb]
            callbacks[msg.cb] = nil
            if fn then
                local cbOk, err = pcall(fn, unpackArgs(msg.args))
                if not cbOk then report('callback', err) end
            end
        elseif msg.event ~= nil then
            dispatchEvent(msg.event, msg.args)
        elseif msg.done ~= nil then
            finished[msg.done] = { ret = msg.ret }
        end
    end
    local result = finished[id]
    finished[id] = nil
    return result
end

--- One request: `fn(...)` as `invoker`. Lua functions among the arguments become callbacks.
local function request(invoker, fn, ...)
    if not proc then bridge.start() end
    nextRequest = nextRequest + 1
    local id = nextRequest
    local args = table.pack(...)
    local parts, owned = {}, {}
    for i = 1, args.n do
        local value = args[i]
        if type(value) == 'function' then
            nextCallback = nextCallback + 1
            callbacks[nextCallback] = value
            owned[#owned + 1] = nextCallback
            parts[i] = ('{"$cb":%d}'):format(nextCallback)
        else
            parts[i] = encode(value)
        end
    end
    local line = ('{"id":%d,"invoker":%s,"fn":%s,"args":[%s]}\n')
        :format(id, encode(invoker), encode(fn), table.concat(parts, ',', 1, args.n))
    local ok, err = proc.input:write(line)
    if ok then ok, err = proc.input:flush() end
    if not ok then lost('write failed: ' .. tostring(err)) end
    local result = pump(id)
    for i = 1, #owned do callbacks[owned[i]] = nil end   -- a callback that never fired is dropped with its call
    return result
end
bridge.request = request

--------------------------------------------------------------------------------
-- lifecycle
--------------------------------------------------------------------------------

-- the bridge's own commands (answered by bridge.mjs with `done` only, never by core_db's exports)
local CONTROL = { reset = '$reset', recreate = '$recreate', sql = '$sql', fail = '$fail', mapResource = '$mapResource' }
local TESTS_INVOKER = 'tests'

--- A `ret` that is the bridge's own failure (not an export's `{ error }` answer such as enqueue's).
local function bridgeFailure(ret)
    local e = type(ret) == 'table' and ret.error or nil
    if type(e) ~= 'string' then return nil end
    if e:find('^bridge: ') or e:find('^unknown function ') or e:find('^unknown bridge function ') then return e end
    return nil
end

function bridge.running()
    return proc ~= nil
end

--- Spawns `node bridge.mjs`, opens the FIFOs and resets the database once.
function bridge.start()
    if proc then return end
    if not fileExists(BRIDGE_JS) then
        error('pgbridge: ' .. BRIDGE_JS .. ' is missing (the core_db resource is not next to core)', 0)
    end
    local dir = ('%s/.bridge-%d'):format(TESTS_DIR, processId())
    local inPath, outPath = dir .. '/in', dir .. '/out'
    -- the node job runs in the background; when it exits for any reason the shell opens the answer
    -- FIFO once (so a Lua still blocked in its open sees EOF instead of hanging) and removes the directory
    local command = ('rm -rf %s && mkdir -p %s && mkfifo %s %s && { ( node %s %s %s </dev/null; '
        .. 'exec 4<>%s; exec 4>&-; rm -rf %s ) & }')
        :format(shellQuote(dir), shellQuote(dir), shellQuote(inPath), shellQuote(outPath),
            shellQuote(BRIDGE_JS), shellQuote(inPath), shellQuote(outPath), shellQuote(outPath), shellQuote(dir))
    -- fxlint-disable-next-line S006 -- offline test harness: fixed command, every path shell-quoted
    if not os.execute(command) then error('pgbridge: could not create the FIFOs in ' .. dir, 0) end
    local input = io.open(inPath, 'r+')     -- read-write: never blocks, and a dead reader never SIGPIPEs us
    if not input then error('pgbridge: could not open ' .. inPath, 0) end
    local output = io.open(outPath, 'r')    -- blocks until Node (or the fallback shell) opens the write end
    if not output then
        input:close()
        error('pgbridge: could not open ' .. outPath, 0)
    end
    input:setvbuf('full')
    proc = { input = input, output = output, dir = dir }
    local ok, err = pcall(bridge.reset)
    if not ok then
        bridge.stop()
        err = tostring(err)
        if not err:find(UNREACHABLE, 1, true) then err = ('pgbridge: %s — %s'):format(err:gsub('^pgbridge: ', ''), UNREACHABLE) end
        error(err, 0)
    end
end

--- Closes the request FIFO (Node exits on EOF) and drains the answers until Node is gone.
function bridge.stop()
    if not proc then return end
    local current = proc
    proc = nil
    pcall(current.input.close, current.input)
    while current.output:read('l') do end
    pcall(current.output.close, current.output)
end

--- `exports.core_db` for one VM: every name is an export called as `resourceName`, colon syntax.
local function exportsObject(resourceName)
    return setmetatable({ synchronous = true }, {
        __index = function(t, fnName)
            if type(fnName) ~= 'string' then return nil end
            local fn = function(_self, ...)
                local ret = request(resourceName, fnName, ...).ret
                local failure = bridgeFailure(ret)
                if failure then error('pgbridge: ' .. failure, 2) end   -- like FiveM's "No such export"
                return ret
            end
            rawset(t, fnName, fn)
            return fn
        end,
    })
end

--- Puts `exports.core_db` into a VM's env and makes GetResourceState('core_db') answer 'started'
--- (unless the suite set another state for it). `isLive()` (optional) = is this VM still part of
--- the current test world — events are delivered only to live VMs. Does not start the bridge.
function bridge.install(env, resourceName, isLive)
    rawset(env.exports, 'core_db', exportsObject(resourceName))
    local previous = env.GetResourceState
    env.GetResourceState = function(res)
        local state = previous(res)
        if res == 'core_db' and state == 'missing' then return 'started' end
        return state
    end
    installed[#installed + 1] = { env = env, isLive = isLive }
end

local function control(name, ...)
    local ret = request(TESTS_INVOKER, CONTROL[name], ...).ret
    if type(ret) == 'table' and ret.error ~= nil then
        error(('pgbridge: %s failed: %s'):format(name, tostring(ret.error)), 0)
    end
    return ret
end

--- TRUNCATE every table except core_migrations (RESTART IDENTITY); reset queue, catalog, barriers.
function bridge.reset()
    return control('reset')
end

--- DROP and re-create the public schema (for the legacy-import suite).
function bridge.recreate()
    return control('recreate')
end

--- A direct query as the invoker `tests` → rows | nil, err.
function bridge.sql(sql, params)
    local ret = request(TESTS_INVOKER, CONTROL.sql, sql, params or {}).ret
    if type(ret) == 'table' and ret.error ~= nil then return nil, tostring(ret.error) end
    return ret or {}
end

--- Every later statement whose SQL text matches the Lua pattern answers `err` (default
--- 'XX000 simulated failure') until bridge.unfail(); a connection-class SQLSTATE (08xxx) also
--- flips core_db's health. core_db matches a JS RegExp, so the pattern is translated here.
function bridge.fail(pattern, err)
    return control('fail', bridge.patternToRegExp(pattern), err)
end

function bridge.unfail()
    return control('fail', nil, nil)
end

-- Lua pattern classes → RegExp (outside a set / inside one)
local CLASSES = { a = 'A-Za-z', c = '\\x00-\\x1f\\x7f', d = '0-9', g = '!-~', l = 'a-z', p = '!-/:-@\\[-`{-~',
    s = ' \\t\\n\\r\\f\\v', u = 'A-Z', w = 'A-Za-z0-9', x = 'A-Fa-f0-9' }

local function patternClass(k, inSet)
    local body = CLASSES[k]
    local negated = body == nil and CLASSES[k:lower()] ~= nil
    if negated then body = CLASSES[k:lower()] end
    if body then
        if inSet then
            if negated then error('pgbridge.fail: a negated %' .. k .. ' inside [] is not supported', 0) end
            return body
        end
        return (negated and '[^' or '[') .. body .. ']'
    end
    if k:find('%w') then error('pgbridge.fail: %' .. k .. ' is not supported', 0) end
    return '\\' .. k                                  -- an escaped literal
end

--- A Lua pattern as JS RegExp source (what core_db's pool matches statement texts with).
function bridge.patternToRegExp(pattern)
    if pattern == nil then return nil end
    local out, i, n = {}, 1, #pattern
    while i <= n do
        local c = pattern:sub(i, i)
        if c == '%' then
            out[#out + 1] = patternClass(pattern:sub(i + 1, i + 1), false)
            i = i + 2
        elseif c == '[' then
            local set, j = { '[' }, i + 1
            if pattern:sub(j, j) == '^' then
                set[2] = '^'
                j = j + 1
            end
            local first = true
            while true do
                local d = pattern:sub(j, j)
                if d == '' then error('pgbridge.fail: unterminated [ in the pattern', 0) end
                if d == ']' and not first then break end
                if d == '%' then
                    set[#set + 1] = patternClass(pattern:sub(j + 1, j + 1), true)
                    j = j + 2
                else
                    set[#set + 1] = (d == '\\' or d == ']' or d == '[') and ('\\' .. d) or d
                    j = j + 1
                end
                first = false
            end
            set[#set + 1] = ']'
            out[#out + 1] = table.concat(set)
            i = j + 1
        elseif c == '-' then
            out[#out + 1] = '*?'                          -- Lua's lazy repetition
            i = i + 1
        elseif c == '.' then
            out[#out + 1] = '[\\s\\S]'                    -- Lua's `.` matches a newline too
            i = i + 1
        elseif (c == '^' and i == 1) or (c == '$' and i == n) or c == '*' or c == '+' or c == '?'
            or c == '(' or c == ')' then
            out[#out + 1] = c
            i = i + 1
        elseif c:find('[\\{}|/^$]') then
            out[#out + 1] = '\\' .. c                     -- literal in Lua, special in a RegExp
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

--- LoadResourceFile(res, p) inside core_db reads `<dir>/<p>` (a fixture resource).
function bridge.mapResource(res, dir)
    return control('mapResource', res, dir)
end

return bridge
