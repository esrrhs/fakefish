package "DB"

local pool = nil
local is_db_connected = false
local in_memory_accounts = nil
local db_state = nil

-- 历史排行缓存（服务端周期刷新，get_rank 直接读缓存应答）
-- 注意：fakelua 的 conn:query 回调参数是【函数名字符串】（如 "DB.on_top_result"），
-- 传内联闭包会被 CVarToString 转成空串、回调静默不触发。所有回调必须是包内全局函数。
-- 回调运行在 C++ 派发上下文：只能写运行时创建的 table 的字段，不能改模块级 upvalue。
local top_cache = nil

local refresh_interval_ticks = 100 -- 5s @ 50ms tick

function ensure_inited()
    if in_memory_accounts == nil then
        in_memory_accounts = {}
    end
    if db_state == nil then
        db_state = { next_id = 1000 }
    end
end

-- 初始化数据库
function init(cfg)
    ensure_inited()
    top_cache = { list = {}, countdown = refresh_interval_ticks - 20 }

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

-- 注册新用户
-- 返回: success(bool), reason_or_account(table or string)
function register(username, password_hash, initial_gold)
    ensure_inited()
    if initial_gold == nil then initial_gold = 100 end

    -- 先检查内存 fallback
    if in_memory_accounts[username] ~= nil then
        return false, "用户名已被注册"
    end

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

    -- 异步写入 MySQL（不依赖回调查询结果；落盘一律按 username 定位，
    -- 因为 MySQL 自增 id 与内存分配的 id 不保证一致）
    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "INSERT INTO accounts (username, password_hash, gold, best_gold) VALUES ('"
                        .. username .. "', '" .. password_hash .. "', " .. tostring(initial_gold)
                        .. ", " .. tostring(initial_gold) .. ")"
            conn:query(sql, "DB.on_exec_result")
            pool:release(conn)
        end
    end

    return true, account
end

-- 根据用户名获取账号信息
function get_account(username)
    ensure_inited()
    local mem_acc = in_memory_accounts[username]
    if mem_acc ~= nil then
        return true, mem_acc
    end

    return false, "用户不存在"
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

-- 主循环周期调用：刷新排行缓存（SELECT 结果由 DB.on_top_result 写回）
function tick_refresh()
    if top_cache == nil then return end
    top_cache.countdown = top_cache.countdown - 1
    if top_cache.countdown > 0 then return end
    top_cache.countdown = refresh_interval_ticks

    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "SELECT username, best_gold, kills FROM accounts ORDER BY best_gold DESC, kills DESC LIMIT 20"
            conn:query(sql, "DB.on_top_result")
            pool:release(conn)
            return
        end
    end

    -- 无 MySQL：直接用内存数据刷新
    top_cache.list = sort_top(20)
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
