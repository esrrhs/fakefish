package "DB"

local pool = nil
local is_db_connected = false
local in_memory_accounts = nil
local db_state = nil

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

    -- 异步写入 MySQL
    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "INSERT INTO accounts (username, password_hash, gold, best_gold) VALUES ('"
                        .. username .. "', '" .. password_hash .. "', " .. tostring(initial_gold)
                        .. ", " .. tostring(initial_gold) .. ")"
            conn:query(sql, function(c, err, result)
                pool:release(conn)
                if err and #err > 0 then
                    print("[DB] Async INSERT error: " .. tostring(err))
                elseif result and result[5] then
                    account.id = result[5]
                end
            end)
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
                        .. " WHERE id = " .. tostring(account_id)
            conn:query(sql, function(c, err, result)
                pool:release(conn)
                if err and #err > 0 then
                    print("[DB] Async UPDATE error: " .. tostring(err))
                end
            end)
        end
    end
end

-- 记击杀数
function add_kill(account_id)
    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "UPDATE accounts SET kills = kills + 1 WHERE id = " .. tostring(account_id)
            conn:query(sql, function(c, err, result)
                pool:release(conn)
                if err and #err > 0 then
                    print("[DB] Async UPDATE error: " .. tostring(err))
                end
            end)
        end
    end
end

-- 记死亡数
function add_death(account_id)
    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "UPDATE accounts SET deaths = deaths + 1 WHERE id = " .. tostring(account_id)
            conn:query(sql, function(c, err, result)
                pool:release(conn)
                if err and #err > 0 then
                    print("[DB] Async UPDATE error: " .. tostring(err))
                end
            end)
        end
    end
end

-- 内存模式排行：简单插入排序（fakelua 不保证 table.sort 可用，手写稳妥）
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

-- 查询历史排行 top N（按 best_gold 降序）
-- 结果通过 World.enqueue_response 回给指定连接（回调是 C++ 上下文，不能改模块 upvalue）
function query_top(limit, connid)
    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "SELECT username, best_gold, kills FROM accounts ORDER BY best_gold DESC, kills DESC LIMIT "
                        .. tostring(limit)
            conn:query(sql, function(c, err, result)
                pool:release(conn)
                local list = {}
                -- SELECT 结果格式: result[1]=true, result[2]=列信息, result[3]=行表（值均为字符串）
                if err == nil and result ~= nil and result[1] == true and result[3] ~= nil then
                    local rows = result[3]
                    for i = 1, #rows do
                        local row = rows[i]
                        table.insert(list, {
                            name = tostring(row[1]),
                            best_gold = tonumber(row[2]) or 0,
                            kills = tonumber(row[3]) or 0
                        })
                    end
                end
                if #list == 0 then
                    list = sort_top(limit)
                end
                World.enqueue_response(connid, { type = "rank", list = list })
            end)
            return
        end
    end

    World.enqueue_response(connid, { type = "rank", list = sort_top(limit) })
end
