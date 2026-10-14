package "Auth"

-- 旧版固定盐（仅用于识别/校验历史账号哈希；新注册一律使用每账号随机盐）
local LEGACY_SALT = "fakefish_salt_2026"

-- 游客登录（免注册直接进场），由 main 在启动时用 guest 配置段初始化一次。
-- P1-3：模块级可变标量一律 nil 声明、在 init() 里赋运行时值，否则全常量赋值
-- 会被推断成 const，后续赋值点直接编译失败。
local guest_enabled = nil
local guest_auto_enter = nil
local guest_prefix = nil
-- 独立 PCG 流：游客昵称后缀。:int() 推进的是 NativeObject 内部状态，
-- 不写模块级 local，因此在 WS recv 回调上下文里调用也是安全的（P1-6）。
local guest_rng = nil

-- 游客配置初始化（main 启动时调用；绝不能在 WS 回调上下文中执行）
function init(cfg)
    guest_enabled = false
    guest_auto_enter = false
    guest_prefix = "游客"

    if cfg ~= nil then
        local e = cfg["enabled"]
        if e == true or e == "true" then guest_enabled = true end
        local a = cfg["auto_enter"]
        if a == true or a == "true" then guest_auto_enter = true end
        local p = cfg["prefix"]
        if p ~= nil and type_of(p) == "string" and #p > 0 then
            guest_prefix = p
        end
    end

    guest_rng = random.new(os.time() + 12345)

    local state = "disabled"
    if guest_enabled then state = "enabled" end
    print("[Auth] guest login " .. state .. " (auto_enter=" .. tostring(guest_auto_enter)
          .. ", prefix=" .. guest_prefix .. ")")
end

-- 供 HTTP GET /api/guest 暴露给前端（仅这三项开关，不含任何敏感信息）
function guest_info()
    return {
        enabled = guest_enabled,
        auto_enter = guest_auto_enter,
        prefix = guest_prefix
    }
end

-- 哈希存储格式（v2，随机盐）：
--   "v2:<salt>:<sha256(salt .. ':' .. password)>"
-- salt 取 crypto.uuid()（RFC4122 v4，只含 hex 与 '-'，不含 ':'，解析无歧义）
-- 库里不以 "v2:" 开头的 64 hex 一律视为旧版 sha256(password .. ':' .. LEGACY_SALT)

function type_of(v)
    return type(v)
end

-- 为明文生成新的随机盐哈希（注册时使用）
function hash_password(password)
    if password == nil then password = "" end
    local salt = crypto.uuid()
    return "v2:" .. salt .. ":" .. crypto.sha256(salt .. ":" .. password)
end

-- 校验密码；返回 (ok, is_legacy)
--   ok=true 且 is_legacy=true 表示命中旧版固定盐哈希，调用方应透明升级
local function verify_password(stored, password)
    if stored == nil then return false, false end
    local s = tostring(stored)
    if password == nil then password = "" end

    local salt, digest = string.match(s, "^v2:([^:]+):([0-9a-f]+)$")
    if salt ~= nil then
        if crypto.sha256(salt .. ":" .. password) == digest then
            return true, false
        end
        return false, false
    end

    -- 旧版固定盐哈希：长度 64 hex
    if #s == 64 and string.match(s, "^[0-9a-f]+$") ~= nil then
        if crypto.sha256(password .. ":" .. LEGACY_SALT) == s then
            return true, true
        end
    end
    return false, false
end

-- 旧哈希命中后透明升级：重算随机盐哈希，回写内存账号并异步落库
local function upgrade_hash(acc, password)
    if acc == nil then return end
    acc.password_hash = hash_password(password)
    DB.update_password(acc.username, acc.password_hash)
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
    local login_ok = {
        type = "login_ok",
        player_id = p.id,
        -- 游客昵称由服务端生成，前端必须用它而不是自己输入的（游客没有输入框）
        name = acc.username,
        gold = World.player_total_gold(p),
        map = World.get_map_info()
    }
    -- 有登录公告时随登录帧下发（io 持久化的 data/motd.txt）
    local motd = Motd.get()
    if motd ~= nil then
        login_ok.motd = motd
    end
    p.pending_login_ok = login_ok
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

    -- 注册时生成随机盐哈希，后续 MySQL INSERT / 内存账号都用它
    local new_hash = hash_password(password)

    local mem = DB.memory_account(username)
    if mem ~= nil then
        World.enqueue_response(connid, { type = "register_fail", reason = "用户名已被注册" })
        return
    end

    -- MySQL 不可达（无连接池或 acquire 失败）时立即降级内存模式，不能把请求挂进队列空等
    if not DB.is_connected() then
        local initial = World.initial_gold_value()
        local acc = DB.create_memory_account(username, new_hash, initial)
        finish_login(connid, acc)
        return
    end

    -- 同一连接上一条鉴权请求尚未返回：直接拒绝，避免慢库下队列被单连接灌爆
    if DB.has_pending_auth(connid) then
        World.enqueue_response(connid, { type = "register_fail", reason = "操作过于频繁，请稍候再试" })
        return
    end

    DB.enqueue_auth({
        kind = "register",
        connid = connid,
        username = username,
        new_hash = new_hash
    })
end

-- 游客入口（WS recv 回调中调用）：免注册直接进场。
-- 游客账号只在内存表创建：不写 MySQL、不进历史排行榜，断开即随账号一起释放，
-- 因此公网部署不会被游客刷爆 accounts 表。
-- 昵称冲突时用同一 PCG 流换号重试；刻意不做自增序号——那需要写模块级 local，
-- 在回调上下文里会静默失效（P1-6）。
function begin_guest(connid)
    if not guest_enabled then
        World.enqueue_response(connid, { type = "login_fail", reason = "游客登录已关闭，请先注册账号" })
        return
    end

    local name = nil
    for i = 1, 50 do
        local cand = guest_prefix .. tostring(guest_rng:int(1000, 9999))
        if DB.memory_account(cand) == nil then
            name = cand
            break
        end
    end
    if name == nil then
        World.enqueue_response(connid, { type = "login_fail", reason = "游客名额已满，请稍后再试" })
        return
    end

    local initial = World.initial_gold_value()
    local acc = DB.create_memory_account(name, "", initial)
    acc.is_guest = true
    finish_login(connid, acc)
end

-- 登录入口（WS recv 回调中调用）：
-- 内存命中同步校验；无 MySQL 且内存无记录直接拒绝；否则入队异步 SELECT。
-- 随机盐方案下不能在入队前预算哈希（盐存在库里），队列传明文、SELECT 回行后校验。
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

    local mem = DB.memory_account(username)
    if mem ~= nil then
        local ok, is_legacy = verify_password(mem.password_hash, password)
        if not ok then
            World.enqueue_response(connid, { type = "login_fail", reason = "密码错误" })
            return
        end
        -- 旧版固定盐哈希：本次登录成功后透明升级为随机盐
        if is_legacy then
            upgrade_hash(mem, password)
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

    -- 同一连接上一条鉴权请求尚未返回：直接拒绝，避免慢库下队列被单连接灌爆
    if DB.has_pending_auth(connid) then
        World.enqueue_response(connid, { type = "login_fail", reason = "操作过于频繁，请稍候再试" })
        return
    end

    DB.enqueue_auth({
        kind = "login",
        connid = connid,
        username = username,
        password = password
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
                    local acc = DB.create_memory_account(cur.username, cur.new_hash, initial)
                    finish_login(cur.connid, acc)
                else
                    World.enqueue_response(cur.connid, { type = "login_fail", reason = "账号不存在，请先注册" })
                end
            elseif cur.kind == "register" then
                if cur.row_id ~= nil then
                    World.enqueue_response(cur.connid, { type = "register_fail", reason = "用户名已被注册" })
                else
                    local initial = World.initial_gold_value()
                    local acc = DB.create_memory_account(cur.username, cur.new_hash, initial)
                    DB.async_insert_account(cur.username, cur.new_hash, initial)
                    finish_login(cur.connid, acc)
                end
            else
                if cur.row_id == nil then
                    World.enqueue_response(cur.connid, { type = "login_fail", reason = "账号不存在，请先注册" })
                else
                    local ok, is_legacy = verify_password(cur.row_hash, cur.password)
                    if not ok then
                        World.enqueue_response(cur.connid, { type = "login_fail", reason = "密码错误" })
                    else
                        -- 旧版固定盐哈希：登录成功即透明升级随机盐（内存 + 异步落库）
                        local stored_hash = cur.row_hash
                        if is_legacy then
                            local salt = crypto.uuid()
                            stored_hash = "v2:" .. salt .. ":" .. crypto.sha256(salt .. ":" .. cur.password)
                            DB.update_password(cur.username, stored_hash)
                        end
                        local acc = {
                            id = cur.row_id,
                            username = cur.username,
                            password_hash = stored_hash,
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
    end

    -- 连接暂不可用导致入队时没发出去的查询，这里每帧重试；空闲时立即返回
    DB.pump_auth()
end
