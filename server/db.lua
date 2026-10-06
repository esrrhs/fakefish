package "DB"

local pool = nil
local is_db_connected = false
local in_memory_accounts = nil
local db_state = nil

-- 异步鉴权流水线（登录/注册前的账号 SELECT）。
-- fakelua 的 conn:query 无法给回调传递闭包上下文（内联函数会被转成空串），
-- 因此用「单飞 + 队列」串行化：同一时刻只有一条在途查询，回调把结果写在 current 上，
-- 主循环 Auth.tick 取走处理后再 pump 下一条。
-- current/queue 都是 init() 中创建的运行时 table，C++ 回调只能写它们的字段。
local auth_pipe = nil

-- 历史排行缓存（服务端周期刷新，get_rank 直接读缓存应答）
-- 注意：fakelua 的 conn:query 回调参数是【函数名字符串】（如 "DB.on_top_result"），
-- 传内联闭包会被 CVarToString 转成空串、回调静默不触发。所有回调必须是包内全局函数。
-- 回调运行在 C++ 派发上下文：只能写运行时创建的 table 的字段，不能改模块级 upvalue。
local top_cache = nil

function ensure_inited()
    if in_memory_accounts == nil then
        in_memory_accounts = {}
    end
    if db_state == nil then
        -- 内存账号 id 段从 900000 起：与 MySQL 自增 id（[1, 800000)）、
        -- 机器人 id（[800000, 900000)）区隔，避免同服会话内 id 碰撞
        db_state = { next_id = 900000 }
    end
    if auth_pipe == nil then
        auth_pipe = { current = nil, queue = {} }
    end
end

-- 初始化数据库
function init(cfg)
    ensure_inited()
    -- 刷新节奏由 timer 心跳驱动（Main.on_heartbeat 每 5s 调 tick_refresh）
    top_cache = { list = {} }

    if cfg == nil then
        cfg = {}
    end

    local host = cfg["host"] or "127.0.0.1"
    local port = cfg["port"] or 3306
    local user = cfg["user"] or "root"
    local password = cfg["password"] or ""
    local db_name = cfg["db"] or "fakefish"
    local pool_size = cfg["pool_size"] or 2
    local heartbeat_ms = cfg["heartbeat_ms"] or 5000

    print("[DB] Initializing MySQL pool at " .. host .. ":" .. tostring(port) .. ", db=" .. db_name)

    local ok, res = pcall(function()
        return mysql_pool.create({
            host = host,
            port = port,
            user = user,
            password = password,
            db = db_name,
            pool_size = pool_size,
            heartbeat_ms = heartbeat_ms
        })
    end)

    if ok and res then
        pool = res
        print("[DB] MySQL connection pool created.")
    else
        print("[DB] MySQL pool create skipped or failed, fallback to in-memory mode: " .. tostring(res))
    end
end

-- 检查数据库连接状态
function is_connected()
    if pool == nil then return false end
    local conn = pool:acquire()
    if conn ~= nil then
        pool:release(conn)
        return true
    end
    return false
end

-- ---- 账号内存表原语 ----

-- 读内存账号（本进程会话内已登录/已注册过）
function memory_account(username)
    ensure_inited()
    return in_memory_accounts[username]
end

-- 登录 SELECT 命中后回填内存表，之后本会话直接走内存快路径
function put_memory_account(acc)
    ensure_inited()
    in_memory_accounts[acc.username] = acc
end

-- 在内存表创建账号并返回（MySQL 模式下注册 SELECT 确认不重名后调用）
function create_memory_account(username, password_hash, initial_gold)
    ensure_inited()
    if initial_gold == nil then initial_gold = 100 end
    db_state.next_id = db_state.next_id + 1
    local account = {
        id = db_state.next_id,
        username = username,
        password_hash = password_hash,
        gold = initial_gold,
        best_gold = initial_gold,
        kills = 0,
        deaths = 0
    }
    in_memory_accounts[username] = account
    return account
end

function has_pool()
    return pool ~= nil
end

-- 鉴权查询等待可用连接的最长秒数：超时按数据库故障降级，避免登录请求永久挂起
local auth_connect_timeout_s = 2

-- 异步 INSERT 新账号（不依赖回调结果；落盘按 username 定位，
-- MySQL 自增 id 与内存分配的 id 不保证一致，读取一律以 SELECT 为准）
function async_insert_account(username, password_hash, initial_gold)
    if pool == nil then return end
    local conn = pool:acquire()
    if conn == nil then return end
    local sql = "INSERT INTO accounts (username, password_hash, gold, best_gold) VALUES ('"
                .. username .. "', '" .. password_hash .. "', " .. tostring(initial_gold)
                .. ", " .. tostring(initial_gold) .. ")"
    conn:query(sql, "DB.on_exec_result")
    pool:release(conn)
end

-- ---- 异步鉴权流水线（登录/注册共用） ----
-- entry: { kind="login"|"register", connid, username, password_hash }
-- 调用方（recv 回调）入队后立即尝试 pump；连接暂不可用时由主循环每帧重试。
function enqueue_auth(entry)
    ensure_inited()
    entry.t0 = os.time()
    table.insert(auth_pipe.queue, entry)
    pump_auth()
end

-- 同一连接已有在途（含正在执行）鉴权查询时返回 true。
-- MySQL 变慢时单连接狂发登录包会把队列灌到无界；按 connid 去重后
-- 队列长度天然不超过 maxconn（200）。命中后调用方应立即拒绝并提示稍后重试。
function has_pending_auth(connid)
    if auth_pipe == nil then return false end
    if auth_pipe.current ~= nil and auth_pipe.current.connid == connid then
        return true
    end
    for i = 1, #auth_pipe.queue do
        if auth_pipe.queue[i].connid == connid then
            return true
        end
    end
    return false
end

-- 若当前无在途查询且队列非空，发起队首 SELECT
function pump_auth()
    if auth_pipe == nil then return end
    if auth_pipe.current ~= nil then return end
    if #auth_pipe.queue == 0 then return end
    if pool == nil then return end

    local conn = pool:acquire()
    if conn == nil then
        -- 连接持续拿不到（MySQL 中途宕机等）：超时后按查询故障收尾，
        -- 由 Auth.tick 走内存降级，不让登录请求无限排队
        local entry0 = auth_pipe.queue[1]
        if entry0.t0 ~= nil and (os.time() - entry0.t0) >= auth_connect_timeout_s then
            table.remove(auth_pipe.queue, 1)
            entry0.done = true
            entry0.db_err = "connect timeout"
            auth_pipe.current = entry0
        end
        return
    end

    local entry = auth_pipe.queue[1]
    table.remove(auth_pipe.queue, 1)
    auth_pipe.current = entry

    -- username 已由 Auth 限定为字母/数字/下划线，无注入风险
    local sql = "SELECT id, password_hash, gold, best_gold, kills, deaths FROM accounts"
                .. " WHERE username = '" .. entry.username .. "'"
    conn:query(sql, "DB.on_auth_result")
    pool:release(conn)
end

-- 主循环调用：当前查询已完成则取出（同时清空 current），否则返回 nil
function take_done_auth()
    if auth_pipe == nil then return nil end
    local cur = auth_pipe.current
    if cur == nil or not cur.done then return nil end
    auth_pipe.current = nil
    return cur
end

-- SELECT 结果回调（C++ 派发上下文）：只把结果行写进 current，校验/进场全部留给主循环
function on_auth_result(c, err, result)
    if auth_pipe == nil or auth_pipe.current == nil then return end
    local cur = auth_pipe.current

    if err ~= nil and #err > 0 then
        cur.done = true
        cur.db_err = err
        return
    end

    if result ~= nil and result[1] == true and result[3] ~= nil then
        local rows = result[3]
        if #rows > 0 then
            local row = rows[1]
            cur.done = true
            cur.row_id = tonumber(row[1])
            cur.row_hash = tostring(row[2])
            cur.row_gold = tonumber(row[3])
            cur.row_best = tonumber(row[4])
            cur.row_kills = tonumber(row[5])
            cur.row_deaths = tonumber(row[6])
            return
        end
    end

    -- 无行：用户名不存在（注册继续，登录报账号不存在）
    cur.done = true
end

-- 更新金币数据（同时维护历史最高金币 best_gold）
function update_gold(username, account_id, gold)
    local acc = in_memory_accounts[username]
    if acc ~= nil then
        acc.gold = gold
        if acc.best_gold == nil or gold > acc.best_gold then
            acc.best_gold = gold
        end
    end

    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "UPDATE accounts SET gold = " .. tostring(gold)
                        .. ", best_gold = GREATEST(IFNULL(best_gold, 0), " .. tostring(gold) .. ")"
                        .. " WHERE username = '" .. username .. "'"
            conn:query(sql, "DB.on_exec_result")
            pool:release(conn)
        end
    end
end

-- 记击杀数
function add_kill(username)
    local acc = in_memory_accounts[username]
    if acc ~= nil then
        acc.kills = (acc.kills or 0) + 1
    end

    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "UPDATE accounts SET kills = kills + 1 WHERE username = '" .. username .. "'"
            conn:query(sql, "DB.on_exec_result")
            pool:release(conn)
        end
    end
end

-- 记死亡数
function add_death(username)
    local acc = in_memory_accounts[username]
    if acc ~= nil then
        acc.deaths = (acc.deaths or 0) + 1
    end

    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "UPDATE accounts SET deaths = deaths + 1 WHERE username = '" .. username .. "'"
            conn:query(sql, "DB.on_exec_result")
            pool:release(conn)
        end
    end
end

-- ---- 历史排行 ----

-- 内存模式排行：简单插入排序（不依赖 table.sort 的自定义比较器）
local function sort_top(limit)
    local items = {}
    for _, acc in pairs(in_memory_accounts) do
        table.insert(items, {
            name = acc.username,
            best_gold = acc.best_gold or acc.gold or 0,
            kills = acc.kills or 0
        })
    end

    local sorted = {}
    for i = 1, #items do
        local it = items[i]
        local pos = #sorted + 1
        for j = 1, #sorted do
            if sorted[j].best_gold < it.best_gold then
                pos = j
                break
            end
        end
        table.insert(sorted, pos, it)
    end

    local top = {}
    for i = 1, #sorted do
        if i > limit then break end
        table.insert(top, sorted[i])
    end
    return top
end

-- 刷新排行缓存（由 timer 心跳每 5s 调用；SELECT 结果由 DB.on_top_result 写回）
function tick_refresh()
    if top_cache == nil then return end

    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "SELECT username, best_gold, kills FROM accounts ORDER BY best_gold DESC, kills DESC LIMIT 20"
            conn:query(sql, "DB.on_top_result")
            pool:release(conn)
            return
        end
    end

    -- 无 MySQL 或无可用连接：直接用内存数据刷新
    top_cache.list = sort_top(20)
    print("[DB] Rank cache refreshed from memory: " .. tostring(#top_cache.list) .. " entries")
end

-- SELECT 结果回调（fakelua 按函数名调用；运行在 C++ 派发上下文）
-- 结果表格式: result[1]=true, result[2]=列信息, result[3]=行表（按列序索引，值均为字符串）
function on_top_result(c, err, result)
    if top_cache == nil then return end
    if err ~= nil and #err > 0 then
        -- 查询失败（连接不可用等）：回退内存排行，保证排行面板始终有数据
        top_cache.list = sort_top(20)
        return
    end
    if result == nil or result[1] ~= true or result[3] == nil then return end

    local list = {}
    local rows = result[3]
    for i = 1, #rows do
        local row = rows[i]
        table.insert(list, {
            name = tostring(row[1]),
            best_gold = tonumber(row[2]) or 0,
            kills = tonumber(row[3]) or 0
        })
    end
    if #list > 0 then
        top_cache.list = list
        print("[DB] Rank cache refreshed from MySQL: " .. tostring(#list) .. " entries")
    end
end

-- INSERT/UPDATE 结果回调：仅记录错误
function on_exec_result(c, err, result)
    if err ~= nil and #err > 0 then
        print("[DB] Async exec error: " .. tostring(err))
    end
end

-- 供 NetWs 应答 get_rank：返回缓存的 top N（截断副本）
function get_top(limit)
    if top_cache == nil then return {} end
    local out = {}
    for i = 1, #top_cache.list do
        if i > limit then break end
        table.insert(out, top_cache.list[i])
    end
    return out
end
