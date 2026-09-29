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
        gold = initial_gold
    }
    in_memory_accounts[username] = account

    -- 异步写入 MySQL
    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "INSERT INTO accounts (username, password_hash, gold) VALUES ('" 
                        .. username .. "', '" .. password_hash .. "', " .. tostring(initial_gold) .. ")"
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

-- 更新金币数据
function update_gold(username, account_id, gold)
    local acc = in_memory_accounts[username]
    if acc ~= nil then
        acc.gold = gold
    end

    if pool ~= nil then
        local conn = pool:acquire()
        if conn ~= nil then
            local sql = "UPDATE accounts SET gold = " .. tostring(gold) .. " WHERE id = " .. tostring(account_id)
            conn:query(sql, function(c, err, result)
                pool:release(conn)
                if err and #err > 0 then
                    print("[DB] Async UPDATE error: " .. tostring(err))
                end
            end)
        end
    end
end
