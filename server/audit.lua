package "Audit"

-- 管理操作防篡改审计链（fakelua sqlite + crypto.sha256）：
--   每条记录 hash = sha256(prev_hash | ts | actor | action | target | detail)，
--   首条以前一条的 hash 为 prev_hash，形成只增哈希链。
--   任何对 records 表的外部改动（改字段/删行/插行）都会在 Audit.verify() 重放时断裂。
--   与 Ledger 一样全同步 sqlite，可安全在 HTTP 派发上下文调用；失败仅记录，不阻断管理动作。

local db = nil
local db_path = nil

local SCHEMA_SQL =
"CREATE TABLE IF NOT EXISTS records ("
.. "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
.. "  ts INTEGER NOT NULL,"
.. "  actor TEXT NOT NULL,"
.. "  action TEXT NOT NULL,"
.. "  target TEXT,"
.. "  detail TEXT,"
.. "  prev_hash TEXT NOT NULL,"
.. "  hash TEXT NOT NULL"
.. ")"

local GENESIS = "0"

function init(cfg)
    if cfg == nil then cfg = {} end
    if cfg["enabled"] == false then
        print("[Audit] disabled by config (audit.enabled=false)")
        return
    end

    local path = cfg["path"] or "data/audit.db"
    db_path = path

    local dir = os.dirname(path)
    if dir ~= nil and dir ~= "" and dir ~= "." then
        os.mkdir(dir)
    end

    local ok, res = pcall(function() return sqlite.open(path) end)
    if not ok or res == nil then
        print("[Audit] sqlite open failed, audit disabled: " .. tostring(res))
        return
    end
    db = res

    -- 审计库刻意用 DELETE 回滚日志而非 WAL：
    -- 1) verify() 的价值是察觉【其它进程】（sqlite3 CLI/DBA 工具）对库文件的篡改，
    --    WAL 下长连接持有读快照时外部提交不可见；DELETE 模式每次读都取最新已提交页；
    -- 2) 数据目录可能位于不支持 WAL 共享内存(mmap) 的虚拟共享卷（virtiofs），
    --    多连接会直接 SQLITE_IOERR。审计低频低并发，读写互斥 + busy_timeout 足够。
    pcall(function() db:exec("PRAGMA journal_mode=DELETE") end)
    pcall(function() db:exec("PRAGMA busy_timeout=3000") end)

    local ok2, err2 = pcall(function() db:exec(SCHEMA_SQL) end)
    if not ok2 then
        print("[Audit] schema init failed, audit disabled: " .. tostring(err2))
        pcall(function() db:close() end)
        db = nil
        return
    end

    print("[Audit] tamper-evident audit chain ready at " .. path)
end

function is_ready()
    return db ~= nil
end

-- 查询用短连接（现开现关）：长连接的读视图会冻结在它自己最近一次写事务的时点，
-- 看不到外部进程（sqlite3 CLI/DBA 工具）已提交的改动；DELETE 日志模式下短连接
-- 不依赖共享内存，可在 virtiofs 等虚拟共享卷上正常工作。
local function open_view()
    if db_path == nil then return nil end
    local ok, vdb = pcall(function() return sqlite.open(db_path) end)
    if not ok or vdb == nil then return nil end
    pcall(function() vdb:exec("PRAGMA busy_timeout=3000") end)
    return vdb
end

-- 计算一条记录的链式哈希；所有字段空值归一空串，分隔符用 '|'
local function hash_of(prev, ts, actor, action, target, detail)
    local parts = {
        prev or GENESIS,
        tostring(ts),
        tostring(actor),
        tostring(action),
        target ~= nil and tostring(target) or "",
        detail ~= nil and tostring(detail) or ""
    }
    return crypto.sha256(table.concat(parts, "|"))
end

-- 追加一条审计。actor 缺省 "admin"；detail 只接受字符串（调用方自行 json.encode）。
-- 返回 true；未启用/失败静默返回 false，绝不阻断主操作。
function record(action, target, detail, actor)
    if db == nil then return false end
    if type(action) ~= "string" or action == "" then return false end
    if actor == nil or actor == "" then actor = "admin" end
    if target ~= nil and type(target) ~= "string" then target = tostring(target) end
    if detail ~= nil and type(detail) ~= "string" then detail = tostring(detail) end

    -- 限制字段长度，避免异常输入撑大审计库
    if detail ~= nil and #detail > 2000 then
        detail = string.sub(detail, 1, 2000)
    end

    local ts = os.time()
    local prev = GENESIS
    local rows = nil
    local okq, qerr = pcall(function()
        return db:exec("SELECT hash FROM records ORDER BY id DESC LIMIT 1")
    end)
    if okq and type(qerr) == "table" and #qerr > 0 and qerr[1]["hash"] ~= nil then
        prev = tostring(qerr[1]["hash"])
    end

    local h = hash_of(prev, ts, actor, action, target, detail)

    local ok, err = pcall(function()
        local stmt = db:prepare(
            "INSERT INTO records (ts, actor, action, target, detail, prev_hash, hash)"
            .. " VALUES (?, ?, ?, ?, ?, ?, ?)")
        stmt:bind(ts, actor, action, target, detail, prev, h)
        stmt:step()
        -- 立即 finalize：残留 prepared statement 会让连接持有读快照，
        -- 导致外部进程对库文件的篡改在本连接上不可见（verify 失去意义）
        stmt:close()
    end)
    if not ok then
        print("[Audit] insert failed: " .. tostring(err))
        return false
    end

    local lok, lerr = pcall(function() log.info("[audit] " .. actor .. " " .. action
        .. (target ~= nil and (" " .. target) or "")) end)
    return true
end

-- 最近记录（新→旧），limit 钳 1..200，默认 20
function list(limit)
    local out = {}
    if db == nil then return out end

    local lim = tonumber(limit)
    if lim == nil or lim ~= lim then lim = 20 end
    lim = math.floor(lim)
    if lim < 1 then lim = 1 end
    if lim > 200 then lim = 200 end

    local vdb = open_view()
    if vdb == nil then return out end
    local ok, rows = pcall(function()
        return vdb:exec("SELECT id, ts, actor, action, target, detail, prev_hash, hash"
            .. " FROM records ORDER BY id DESC LIMIT " .. tostring(lim))
    end)
    pcall(function() vdb:close() end)
    if not ok or type(rows) ~= "table" then return out end

    for i = 1, #rows do
        local r = rows[i]
        table.insert(out, {
            id = tonumber(r["id"]) or 0,
            ts = tonumber(r["ts"]) or 0,
            actor = tostring(r["actor"]),
            action = tostring(r["action"]),
            target = r["target"] ~= nil and tostring(r["target"]) or nil,
            detail = r["detail"] ~= nil and tostring(r["detail"]) or nil,
            prev_hash = tostring(r["prev_hash"]),
            hash = tostring(r["hash"])
        })
    end
    return out
end

-- 从最早记录重放哈希链。
-- 返回 ok(bool), count(number), broken(string|nil 描述首个断裂点)
function verify()
    if db == nil then return false, 0, "audit disabled" end

    local vdb = open_view()
    if vdb == nil then return false, 0, "cannot open audit db for verification" end

    local ok, rows = pcall(function()
        return vdb:exec("SELECT id, ts, actor, action, target, detail, prev_hash, hash"
            .. " FROM records ORDER BY id ASC")
    end)
    pcall(function() vdb:close() end)
    if not ok or type(rows) ~= "table" then
        return false, 0, "cannot read records: " .. tostring(rows)
    end

    local prev = GENESIS
    for i = 1, #rows do
        local r = rows[i]
        local id = tonumber(r["id"]) or 0
        local rp = r["prev_hash"] ~= nil and tostring(r["prev_hash"]) or ""
        if rp ~= prev then
            return false, #rows, "prev_hash mismatch at id=" .. tostring(id)
        end
        local expect = hash_of(prev, tonumber(r["ts"]) or 0, r["actor"], r["action"],
                               r["target"], r["detail"])
        if tostring(r["hash"]) ~= expect then
            return false, #rows, "hash mismatch at id=" .. tostring(id)
        end
        prev = tostring(r["hash"])
    end
    return true, #rows, nil
end

-- ---- 热更支持 ----
-- db 是 NativeObject，随快照交出挂回新模块 upvalue（同 Feed/Ledger 模式）
function hotfix_save()
    local s = {}
    s["db"] = db
    s["db_path"] = db_path
    return s
end

function hotfix_restore(s)
    if s == nil then return end
    db = s["db"]
    db_path = s["db_path"]
end

-- ---- 帧边界持久化 ----
-- sqlite 连接是 NativeObject；审计链本身在库里，跨帧只需保住连接与路径。
function persist()
    Store.set("audit.db", db)
    Store.set("audit.db_path", db_path)
end

function restore()
    db = Store.get("audit.db")
    db_path = Store.get("audit.db_path")
end
