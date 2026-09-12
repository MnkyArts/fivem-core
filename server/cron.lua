--- core/server/cron.lua — Core.Cron (DESIGN §17): interval jobs and wall-clock jobs.
--- Two threads at most, both lazy: one sorted-queue thread for `every` (never one thread per job)
--- and one wall-clock thread that wakes just before each minute boundary and evaluates every
--- `at` / `schedule` job once per minute with os.date('*t') (server VM: os is available).
--- Both threads exit by themselves when the last job of their kind is removed.
---
--- Time base: `at` and `schedule` run on the HOST's LOCAL time (os.date('*t'), i.e. the server
--- machine's timezone), not UTC and not the in-game clock (that is Core.World). A DST transition
--- therefore skips one hour (jobs scheduled inside it never fire that day) or replays it (jobs in
--- that hour fire twice, once per real minute); pick UTC on the host, or an interval job, when a
--- run must happen exactly once.
--- Natives: GetGameTimer (shared) for interval timing; nothing else.

local Log = Core.Log

local Cron = {}
Core.Cron = Cron

local MIN_INTERVAL_MS <const> = 1000
local MAX_SLEEP_MS <const> = 1000
local MIN_SLEEP_MS <const> = 50
local MINUTE_MIN_SLEEP_MS <const> = 250

-- minute, hour, day-of-month, month, day-of-week (0 and 7 both mean Sunday)
local FIELDS <const> = {
    { min = 0, max = 59 }, { min = 0, max = 23 }, { min = 1, max = 31 },
    { min = 1, max = 12 }, { min = 0, max = 7 },
}

local jobs = {}             -- [id] = job (every kind)
local clockJobs = {}        -- [id] = job, the 'at' / 'cron' subset
local queue = {}            -- interval jobs, ascending by nextRun
local nextId = 0
local clockThread = false
local queueThread = false
local running = true

--------------------------------------------------------------------------------
-- 5-field cron parser: `*`, `a`, `a,b`, `a-b`, `*/n`, `a-b/n`, `a/n`
--------------------------------------------------------------------------------

--- One field -> a set of allowed values, or nil when the field is malformed.
local function parseField(text, min, max)
    local set = {}
    for part in text:gmatch('[^,]+') do
        local range, step = part:match('^(.+)/(%d+)$')
        if not range then range, step = part, '1' end
        local stepN = tonumber(step)
        if not stepN or stepN < 1 then return nil end
        local lo, hi
        if range == '*' then
            lo, hi = min, max
        else
            local a, b = range:match('^(%d+)%-(%d+)$')
            if a then
                lo, hi = tonumber(a), tonumber(b)
            elseif range:match('^%d+$') then
                lo = tonumber(range)
                -- Vixie cron: `5/10` means 5,15,25,... while a bare `5` is just 5.
                hi = stepN > 1 and max or lo
            else
                return nil
            end
        end
        if not lo or not hi or lo < min or hi > max or lo > hi then return nil end
        for value = lo, hi, stepN do set[value] = true end
    end
    if next(set) == nil then return nil end
    return set
end

--- '*/5 * * * *' -> { [1..5] = set, domAny = bool, dowAny = bool } | nil, err
local function parseExpr(expr)
    if type(expr) ~= 'string' or #expr == 0 or #expr > 128 then return nil, 'expression must be a string' end
    local parts = {}
    for token in expr:gmatch('%S+') do parts[#parts + 1] = token end
    if #parts ~= 5 then return nil, ('expected 5 fields, got %d'):format(#parts) end
    local fields = { domAny = parts[3] == '*', dowAny = parts[5] == '*' }
    for i = 1, 5 do
        local set = parseField(parts[i], FIELDS[i].min, FIELDS[i].max)
        if not set then return nil, ('field %d (%s) is invalid'):format(i, parts[i]) end
        fields[i] = set
    end
    if fields[5][7] then fields[5][0] = true end    -- 7 and 0 are both Sunday
    return fields
end

--- Vixie cron semantics: with both day fields restricted, either one matching is enough.
local function matches(fields, t)
    if not fields[1][t.min] or not fields[2][t.hour] or not fields[4][t.month] then return false end
    local domOk, dowOk = fields[3][t.day] == true, fields[5][t.wday - 1] == true
    if fields.domAny and fields.dowAny then return true end
    if fields.domAny then return dowOk end
    if fields.dowAny then return domOk end
    return domOk or dowOk
end

--------------------------------------------------------------------------------
-- Execution and the two lazy threads
--------------------------------------------------------------------------------

--- Every run gets its own short-lived thread: a job that Waits (DB, HTTP, a fade) must not
--- delay the scheduler or the other jobs. `busy` makes a long run skip its next tick rather
--- than stacking runs on top of each other.
local function runJob(job)
    if job.busy then
        Log.debug('cron %s: previous run still active, tick skipped', job.id)
        return
    end
    job.busy = true
    job.runs = job.runs + 1
    job.lastRun = os.time()
    CreateThread(function()
        local ok, err = pcall(job.fn)
        job.busy = false
        if not ok then Log.error('cron %s errored: %s', job.id, tostring(err)) end
    end)
end

--- Keep `queue` ascending by nextRun (binary insert), so the thread only ever reads queue[1].
local function enqueue(job)
    local lo, hi = 1, #queue + 1
    while lo < hi do
        local mid = (lo + hi) // 2
        if queue[mid].nextRun <= job.nextRun then lo = mid + 1 else hi = mid end
    end
    table.insert(queue, lo, job)
end

local function dequeue(id)
    for i = 1, #queue do
        if queue[i].id == id then
            table.remove(queue, i)
            return
        end
    end
end

--- Interval jobs: started with the first `every`, exits when the queue runs dry.
local function startQueueThread()
    if queueThread then return end
    queueThread = true
    CreateThread(function()
        while running and queue[1] do
            local now = GetGameTimer()
            local job = queue[1]
            while job and job.nextRun <= now do
                table.remove(queue, 1)
                job.nextRun = now + job.intervalMs      -- always > now: the minimum interval is 1 s
                enqueue(job)
                runJob(job)
                job = queue[1]
            end
            local sleep = MAX_SLEEP_MS
            if job then
                sleep = math.max(MIN_SLEEP_MS, math.min(job.nextRun - GetGameTimer(), MAX_SLEEP_MS))
            end
            Wait(sleep)
        end
        queueThread = false
    end)
end

--- Wall-clock jobs: one evaluation per minute, waking just before the next minute boundary.
--- `lastKey` guards against a double evaluation when a wake lands in the same minute.
local function startClockThread()
    if clockThread then return end
    clockThread = true
    CreateThread(function()
        local lastKey = nil
        while running and next(clockJobs) do
            local t = os.date('*t')
            local key = ((t.year * 366 + t.yday) * 24 + t.hour) * 60 + t.min
            if key ~= lastKey then
                lastKey = key
                for _, job in pairs(clockJobs) do
                    if matches(job.fields, t) then runJob(job) end
                end
            end
            local sleep = (60 - t.sec) * 1000
            Wait(sleep < MINUTE_MIN_SLEEP_MS and MINUTE_MIN_SLEEP_MS or sleep)
        end
        clockThread = false
    end)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Hour/minute argument -> integer in 0..max, or nil.
local function toUnit(value, max)
    if math.type(value) ~= 'integer' then
        if type(value) ~= 'number' or value ~= value or value % 1 ~= 0 then return nil end
        value = math.floor(value)
    end
    if value < 0 or value > max then return nil end
    return value
end

local function newJob(kind, fn)
    nextId = nextId + 1
    return {
        id = 'cron:' .. nextId, seq = nextId, kind = kind, fn = fn, runs = 0, busy = false,
        owner = Core.Registry.getCaller(),
    }
end

local function addClockJob(kind, fields, fn, label)
    local job = newJob(kind, fn)
    job.fields, job.label = fields, label
    jobs[job.id], clockJobs[job.id] = job, job
    Core.Registry.track('cron', job.id, job.owner)
    startClockThread()
    return job.id
end

--- Cron.every(intervalMs, fn, opts?) -> id. opts.runNow runs it once right away.
--- Intervals below 1000 ms are raised to 1000 ms.
function Cron.every(intervalMs, fn, opts)
    if not Core.Utils.isCallable(fn) then
        Log.error('Cron.every: handler is not a function')
        return nil
    end
    if type(intervalMs) ~= 'number' or intervalMs ~= intervalMs then
        Log.error('Cron.every: interval must be a number, got %s', type(intervalMs))
        return nil
    end
    local interval = math.floor(intervalMs)
    if interval < MIN_INTERVAL_MS then
        Log.warn('Cron.every: interval %d ms raised to the %d ms minimum', interval, MIN_INTERVAL_MS)
        interval = MIN_INTERVAL_MS
    end
    local job = newJob('every', fn)
    job.intervalMs = interval
    job.nextRun = GetGameTimer() + interval
    jobs[job.id] = job
    Core.Registry.track('cron', job.id, job.owner)
    enqueue(job)
    startQueueThread()
    if type(opts) == 'table' and opts.runNow == true then runJob(job) end
    return job.id
end

--- Cron.at(hour, minute, fn) -> id — daily, on the server's wall clock.
function Cron.at(hour, minute, fn)
    local h, m = toUnit(hour, 23), toUnit(minute, 59)
    if not h or not m or not Core.Utils.isCallable(fn) then
        Log.error('Cron.at: invalid arguments (%s, %s)', tostring(hour), tostring(minute))
        return nil
    end
    local expr = ('%d %d * * *'):format(m, h)
    return addClockJob('at', parseExpr(expr), fn, expr)
end

--- Cron.schedule('*/5 * * * *', fn) -> id — evaluated once a minute.
function Cron.schedule(expr, fn)
    if not Core.Utils.isCallable(fn) then
        Log.error('Cron.schedule: handler is not a function')
        return nil
    end
    local fields, err = parseExpr(expr)
    if not fields then
        Log.error('Cron.schedule: %s (%s)', tostring(err), tostring(expr))
        return nil
    end
    return addClockJob('cron', fields, fn, expr)
end

--- Cron.remove(id) -> boolean removed. A run already in flight finishes.
function Cron.remove(id)
    local job = jobs[id]
    if not job then return false end
    jobs[id], clockJobs[id] = nil, nil
    if job.kind == 'every' then dequeue(id) end
    Core.Registry.untrack('cron', id)
    return true
end

--- Cron.list() -> array of { id, kind, owner, runs, lastRun, interval?, expr? } in creation order.
--- Sorted on the numeric `seq`, not the id string: 'cron:10' sorts before 'cron:2' lexicographically.
function Cron.list()
    local ordered = {}
    for _, job in pairs(jobs) do ordered[#ordered + 1] = job end
    table.sort(ordered, function(a, b) return a.seq < b.seq end)
    local out = {}
    for i = 1, #ordered do
        local job = ordered[i]
        out[i] = {
            id = job.id, kind = job.kind, owner = job.owner, runs = job.runs,
            lastRun = job.lastRun, interval = job.intervalMs, expr = job.label,
            nextRun = job.nextRun,
        }
    end
    return out
end

-- A plugin that stops takes its jobs with it (DESIGN §2.3): its funcrefs are dead.
Core.Registry.onOwnerStop('cron', function(id)
    Cron.remove(id)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    running = false             -- synchronous: both threads exit on their next wake
    jobs, clockJobs, queue = {}, {}, {}
end)

-- end of file
