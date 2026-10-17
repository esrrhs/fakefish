package "DB"

local pool = nil
-- 是否已连上由 Store 的 "db.connected" 记录（跨帧存活），不设文件级标记：
-- 文件级 local 若在 init 帧被写入运行期值，跨帧后就是悬垂内容。
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
    -- pending：单飞标记，见 tick_refresh 的乱序回调说明
    top_cache = { list = {}, pending = false, pending_t0 = 0 }

    if cfg == nil then
        cfg = {}
    end

    -- 连接池不在 init 帧创建：init 是首个顶层 Call，在那里发起的 MySQL 异步握手
    -- 跨帧后再也推进不了（连接卡在 Connecting，且池不会重连），acquire 永远返回 nil。
    -- 实测把创建放到 update 帧即可正常连上，因此这里只登记配置。
    Store.set_json("db.cfg", cfg)
    Store.set("db.pool_tries", 0)
    pool = nil
end

-- 在 update 帧建立连接池（带节流重试，MySQL 后启动时也能自行连上）。
function ensure_pool()
    if pool ~= nil then return end
    if Store.get("db.pool_tries") == nil then return end

    local tries = Store.get("db.pool_tries") or 0
    if tries >= 10 then return end

    local now = os.time()
    local last = Store.get("db.pool_try_ts") or 0
    if tries > 0 and now - last < 2 then return end
    Store.set("db.pool_try_ts", now)

    local cfg = Store.get_json("db.cfg")
    if cfg == nil then return end

    local host = cfg["host"] or "127.0.0.1"
    local port = cfg["port"] or 3306
    local user = cfg["user"] or "root"
    local password = cfg["password"] or ""
    local db_name = cfg["db"] or "fakefish"
    local pool_size = cfg["pool_size"] or 2
    local heartbeat_ms = cfg["heartbeat_ms"] or 5000

    Store.set("db.pool_tries", tries + 1)
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
        Store.set("db.pool", res)
        print("[DB] MySQL connection pool created.")
    else
        print("[DB] MySQL pool create skipped or failed, fallback to in-memory mode: " .. tostring(res))
    end
end

-- 在 update 主体（runtime.tick 之后）驱动握手。
-- fakelua 的 MySQL 握手由共享 IO 上下文推进，实测在跨模块 restore 的调用上下文里
-- tick 推不动它，必须放在 update 主循环的 tick 之后。
-- 握手重试预算：连接池握手是异步的，必须靠 runtime.tick() 推进，单次 acquire
-- 基本拿不到，所以要有界循环「tick + acquire + 让出」。但绝不能每帧都跑满这个
-- 循环——MySQL 根本不存在时 db.connected 永远为 false，100 次循环会逐帧重跑，
-- 把帧时间顶到秒级（CI 的 macOS job 不启 MySQL，实测帧率掉到约 0.5fps），
-- 帧率一崩，踢空闲连接、缩圈、吞噬等所有时序用例连锁超时。
-- 故给「有界握手」设次数上限，超预算后降级为每帧一次轻量探测。
local MAX_HANDSHAKE_ATTEMPTS = 10

function finish_connect()
    if pool == nil then return end
    if Store.get("db.connected") == true then return end

    local tries = Store.get("db.connect_tries") or 0
    if tries >= MAX_HANDSHAKE_ATTEMPTS then
        -- 超预算：只做一次 acquire 探测（不 tick、不 sleep），
        -- MySQL 后续上线仍能接上，但不再拖慢帧率。
        local c = pool:acquire()
        if c ~= nil then
            pool:release(c)
            Store.set("db.connected", true)
            print("[DB] MySQL connection established.")
        end
        return
    end

    Store.set("db.connect_tries", tries + 1)

    local c = nil
    for i = 1, 100 do
        runtime.tick()
        c = pool:acquire()
        if c ~= nil then break end
        os.sleep(2)
    end

    if c ~= nil then
        pool:release(c)
        Store.set("db.connected", true)
        print("[DB] MySQL connection established.")
    elseif tries + 1 >= MAX_HANDSHAKE_ATTEMPTS then
        print("[DB] MySQL unreachable after " .. tostring(MAX_HANDSHAKE_ATTEMPTS)
              .. " handshake attempts, running in memory-only mode.")
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
-- entry:
--   register: { kind="register", connid, username, new_hash }  —— 随机盐哈希，注册落库
--   login:    { kind="login",    connid, username, password }  —— 明文，SELECT 回行后验密
-- 随机盐方案下盐存在库里，无法在入队前预算哈希，故登录队列传明文（仅进程内存短暂持有）。
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

-- 升级密码哈希（旧版固定盐 → 每账号随机盐；登录成功后透明调用）
-- 哈希串仅含 v2:/hex/连字符/'：（分隔符），冒号不出现在盐或 digest 中，拼接安全
function update_password(username, new_hash)
    if pool == nil then return end
    local conn = pool:acquire()
    if conn == nil then return end
    local sql = "UPDATE accounts SET password_hash = '" .. new_hash
                .. "' WHERE username = '" .. username .. "'"
    conn:query(sql, "DB.on_exec_result")
    pool:release(conn)
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

-- 在途排行 SELECT 的最长等待秒数：超时视为回调丢失，放弃这一轮并改用内存兜底，
-- 避免单飞标记被一条永不返回的查询永久卡死
local rank_inflight_timeout_s = 15

-- 刷新排行缓存（由 timer 心跳每 5s 调用；SELECT 结果由 DB.on_top_result 写回）
--
-- 单飞（同一时刻只允许一条排行 SELECT 在途）是必须的：conn:query 是异步的，
-- 而 fakelua 的 mysql_pool 没有租约语义——query 之后立刻 release，连接马上被
-- 别的查询（update_gold/add_kill/登录 SELECT…）拿去复用，于是排行查询会在连接
-- 上排队，回调按【完成顺序】而非【发起顺序】返回。实测（CI run 38656504187）
-- 先发起的旧快照晚到、把已经刷新的新快照覆盖回去，榜上条目数出现
-- 9 → 16 → 17 → 9 的非单调跳变，刚注册的账号（含游客）在榜上忽隐忽现。
-- 单飞 + 「非预期的回调直接丢弃」保证缓存只会前进、不会回退。
function tick_refresh()
    if top_cache == nil then return end

    if pool ~= nil then
        if top_cache.pending then
            if os.time() - top_cache.pending_t0 < rank_inflight_timeout_s then
                return
            end
            -- 在途超时：放弃这条查询，本轮改走内存，下一轮重新发起
            top_cache.pending = false
            print("[DB] Rank refresh in-flight timed out, fallback to memory")
        else
            local conn = pool:acquire()
            if conn ~= nil then
                top_cache.pending = true
                top_cache.pending_t0 = os.time()
                local sql = "SELECT username, best_gold, kills FROM accounts ORDER BY best_gold DESC, kills DESC LIMIT 20"
                conn:query(sql, "DB.on_top_result")
                pool:release(conn)
                return
            end
        end
    end

    -- 无 MySQL、无可用连接或在途超时：直接用内存数据刷新，保证榜上始终有数据
    top_cache.list = sort_top(20)
    print("[DB] Rank cache refreshed from memory: " .. tostring(#top_cache.list) .. " entries")
end

-- SELECT 结果回调（fakelua 按函数名调用；运行在 C++ 派发上下文）
-- 结果表格式: result[1]=true, result[2]=列信息, result[3]=行表（按列序索引，值均为字符串）
function on_top_result(c, err, result)
    if top_cache == nil then return end
    -- 非预期的回调（在途超时后姗姗来迟的旧快照、重复派发）：直接丢弃，
    -- 否则会把已经刷新的新榜覆盖回旧榜（见 tick_refresh 的乱序回调说明）
    if not top_cache.pending then return end
    top_cache.pending = false

    if err ~= nil and #err > 0 then
        -- 查询失败（连接不可用等）：回退内存排行，保证排行面板始终有数据
        print("[DB] Rank query error: " .. tostring(err))
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

-- ---- 帧边界持久化 ----
-- 连接池是 NativeObject：壳跨帧失效，必须存对象本身。内存账号表与登录流水线是
-- VarTable，跨帧随 arena 消亡，走 JSON 桥接（账号以用户名字符串为键，编码安全）。
function persist()
    Store.set("db.pool", pool)
    Store.set_json("db.in_memory_accounts", in_memory_accounts)
    Store.set_json("db.db_state", db_state)
    Store.set_json("db.top_cache", top_cache)
    -- auth_pipe 的 current 持有在途查询上下文（connid / 账号名等纯数据），可安全编码
    Store.set_json("db.auth_pipe", auth_pipe)
end

function restore()
    pool = Store.get("db.pool")
    -- 首帧（以及尚未连上的后续帧）建立连接池：必须发生在 update 上下文
    ensure_pool()
    in_memory_accounts = Store.get_json("db.in_memory_accounts")
    if in_memory_accounts == nil then in_memory_accounts = {} end
    db_state = Store.get_json("db.db_state")
    if db_state == nil then db_state = { next_id = 900000 } end
    top_cache = Store.get_json("db.top_cache")
    auth_pipe = Store.get_json("db.auth_pipe")
    if auth_pipe == nil then auth_pipe = { current = nil, queue = {} } end
end
