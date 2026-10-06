package "Auth"

local SALT = "fakefish_salt_2026"

function hash_password(password)
    if password == nil then password = "" end
    -- 使用 FakeLua 内置 crypto.sha256
    return crypto.sha256(password .. ":" .. SALT)
end

function type_of(v)
    return type(v)
end

-- 用户名只允许字母/数字/下划线，杜绝 SQL 注入与特殊字符问题
local function is_valid_username(username)
    if username == nil or #username < 2 or #username > 20 then return false end
    if string.match(username, "^[%w_]+$") == nil then return false end
    return true
end

-- 进场：校验通过后建实体，login_ok 挂到玩家记录上由主循环发送
local function finish_login(connid, acc)
    local p = World.add_player(connid, acc)
    p.pending_login_ok = {
        type = "login_ok",
        player_id = p.id,
        gold = World.player_total_gold(p),
        map = World.get_map_info()
    }
end

-- 注册入口（WS recv 回调中调用）：
-- 内存命中 / 无 MySQL 时同步落定；否则入队异步 SELECT 查重，由 tick() 在主循环收尾
function begin_register(connid, username, password)
    if type_of(username) ~= "string" or type_of(password) ~= "string" then
        World.enqueue_response(connid, { type = "register_fail", reason = "非法请求" })
        return
    end
    if not is_valid_username(username) then
        World.enqueue_response(connid, { type = "register_fail", reason = "用户名需为2-20位字母、数字或下划线" })
        return
    end
    if #password < 3 then
        World.enqueue_response(connid, { type = "register_fail", reason = "密码至少需要3个字符" })
        return
    end

    local pwd_hash = hash_password(password)

    local mem = DB.memory_account(username)
    if mem ~= nil then
        World.enqueue_response(connid, { type = "register_fail", reason = "用户名已被注册" })
        return
    end

    -- MySQL 不可达（无连接池或 acquire 失败）时立即降级内存模式，不能把请求挂进队列空等
    if not DB.is_connected() then
        local initial = World.initial_gold_value()
        local acc = DB.create_memory_account(username, pwd_hash, initial)
        finish_login(connid, acc)
        return
    end

    DB.enqueue_auth({
        kind = "register",
        connid = connid,
        username = username,
        password_hash = pwd_hash
    })
end

-- 登录入口（WS recv 回调中调用）：
-- 内存命中同步校验；无 MySQL 且内存无记录直接拒绝；否则入队异步 SELECT
function begin_login(connid, username, password)
    if type_of(username) ~= "string" or type_of(password) ~= "string" then
        World.enqueue_response(connid, { type = "login_fail", reason = "非法请求" })
        return
    end
    if #username == 0 then
        World.enqueue_response(connid, { type = "login_fail", reason = "用户名不能为空" })
        return
    end
    if #password == 0 then
        World.enqueue_response(connid, { type = "login_fail", reason = "密码不能为空" })
        return
    end

    local pwd_hash = hash_password(password)

    local mem = DB.memory_account(username)
    if mem ~= nil then
        if mem.password_hash ~= pwd_hash then
            World.enqueue_response(connid, { type = "login_fail", reason = "密码错误" })
            return
        end
        finish_login(connid, mem)
        return
    end

    if not DB.is_connected() then
        World.enqueue_response(connid, { type = "login_fail", reason = "账号不存在，请先注册" })
        return
    end

    -- 登录同样要求用户名合法（防注入 + 避免无意义查询），对外统一报「账号不存在」
    if not is_valid_username(username) then
        World.enqueue_response(connid, { type = "login_fail", reason = "账号不存在，请先注册" })
        return
    end

    DB.enqueue_auth({
        kind = "login",
        connid = connid,
        username = username,
        password_hash = pwd_hash
    })
end

-- 主循环每帧调用：取出已完成的异步鉴权查询收尾，并推动队列继续
function tick()
    local cur = DB.take_done_auth()
    if cur ~= nil then
        -- 查询往返期间连接已断开：直接丢弃，避免向死人连接进场
        if World.is_conn_alive(cur.connid) then
            if cur.db_err ~= nil then
                -- 查询期数据库故障：按内存降级语义处理（与「无 MySQL」一致，
                -- 保证本地试玩与连接抖动不把登录彻底卡死）
                if cur.kind == "register" then
                    local initial = World.initial_gold_value()
                    local acc = DB.create_memory_account(cur.username, cur.password_hash, initial)
                    finish_login(cur.connid, acc)
                else
                    World.enqueue_response(cur.connid, { type = "login_fail", reason = "账号不存在，请先注册" })
                end
            elseif cur.kind == "register" then
                if cur.row_id ~= nil then
                    World.enqueue_response(cur.connid, { type = "register_fail", reason = "用户名已被注册" })
                else
                    local initial = World.initial_gold_value()
                    local acc = DB.create_memory_account(cur.username, cur.password_hash, initial)
                    DB.async_insert_account(cur.username, cur.password_hash, initial)
                    finish_login(cur.connid, acc)
                end
            else
                if cur.row_id == nil then
                    World.enqueue_response(cur.connid, { type = "login_fail", reason = "账号不存在，请先注册" })
                elseif cur.row_hash ~= cur.password_hash then
                    World.enqueue_response(cur.connid, { type = "login_fail", reason = "密码错误" })
                else
                    local acc = {
                        id = cur.row_id,
                        username = cur.username,
                        password_hash = cur.row_hash,
                        gold = cur.row_gold,
                        best_gold = cur.row_best,
                        kills = cur.row_kills or 0,
                        deaths = cur.row_deaths or 0
                    }
                    DB.put_memory_account(acc)
                    finish_login(cur.connid, acc)
                end
            end
        end
    end

    -- 连接暂不可用导致入队时没发出去的查询，这里每帧重试；空闲时立即返回
    DB.pump_auth()
end
