package "RedisStore"

-- 可选 Redis 能力（fakelua redis，基于 hiredis 异步客户端，runtime.tick 驱动）：
--   1. 全局排行 ZSET 镜像：周期把本服 top20 ZADD 进共享 zset，裁剪保留 20 名，
--      再 ZREVRANGE 拉回全局榜缓存（HTTP /api/rank?scope=global）；
--   2. 跨服世界聊天：LPUSH + LTRIM 写共享 list，各实例每秒 LRANGE 拉取，
--      按消息 id 去重后把「其他实例」发出的聊天广播给本服玩家。
--
-- 为什么不用 SUBSCRIBE/PUBLISH：本封装的 command 回调是一次性的（见
-- fakelua native_redis.cpp 的 CmdOp 模型），SUBSCRIBE 后续推送会复用已释放的
-- 命令上下文；LPUSH/LRANGE 拉模型在该封装下语义明确、也天然支持断线补拉最近消息。
--
-- 连接失败/未配置：全部方法静默降级（全局榜回退本服榜，跨服聊天关闭）。

local state = nil

local CHAT_KEY = "fakefish:chat"
local RANK_KEY = "fakefish:rank"
local CHAT_KEEP = 50
local SEEN_LIMIT = 300

function init(cfg)
    state = {
        ready = false,
        enabled = false,
        conn = nil,
        server_id = string.sub(crypto.uuid(), 1, 8),
        seq = 0,
        seen = {},
        seen_count = 0,
        chat_pending = false,
        rank_pending = false,
        poll_tick = 0,
        global_list = {}
    }

    if cfg == nil then cfg = {} end
    if cfg["enabled"] == false then
        print("[RedisStore] disabled by config (redis.enabled=false)")
        return
    end
    local host = cfg["host"]
    if host == nil or host == "" then
        print("[RedisStore] disabled (no redis.host configured)")
        return
    end
    state.enabled = true

    -- 聊天事件始终登记；未就绪时处理器直接 no-op
    event.on("game.chat", "RedisStore.on_ev_chat")

    local port = cfg["port"] or 6379
    local connect_cfg = {
        host = host,
        port = port,
        timeout_ms = cfg["timeout_ms"] or 3000
    }
    if cfg["password"] ~= nil and cfg["password"] ~= "" then
        connect_cfg["password"] = cfg["password"]
    end
    if cfg["db"] ~= nil then
        connect_cfg["db"] = cfg["db"]
    end

    local ok, err = pcall(function()
        redis.connect(connect_cfg, "RedisStore.on_connect")
    end)
    if not ok then
        print("[RedisStore] connect launch failed: " .. tostring(err))
        return
    end
    print("[RedisStore] connecting to Redis at " .. host .. ":" .. tostring(port)
          .. " (server_id=" .. state.server_id .. ")")
end

function is_ready()
    return state ~= nil and state.ready and state.conn ~= nil
end

-- 连接结果回调（C++ 派发上下文：只写 state 运行时表的字段）
function on_connect(conn, err, success)
    if state == nil then return end
    if err ~= nil or success ~= 1 then
        state.ready = false
        state.conn = nil
        print("[RedisStore] connect failed, cross-server features disabled: " .. tostring(err))
        return
    end
    state.conn = conn
    state.ready = true
    print("[RedisStore] connected; global rank + cross-server chat enabled")
end

-- 发送一条命令（就绪检查 + pcall 兜底）
local function send_cmd(argv, cb_name)
    if not is_ready() then return false end
    local ok, err = pcall(function() state.conn:command(argv, cb_name) end)
    if not ok then
        print("[RedisStore] command failed: " .. tostring(err))
        return false
    end
    return true
end

-- 本服产生聊天 → LPUSH 共享 list（argv 数组二进制安全，无需转义）
function on_ev_chat(name, content, from)
    if not is_ready() then return end
    state.seq = state.seq + 1
    local msg_id = state.server_id .. ":" .. tostring(state.seq)
    local payload = nil
    local ok, enc = pcall(function()
        return json.encode({
            id = msg_id,
            origin = state.server_id,
            ts = os.time(),
            name = name,
            content = content
        })
    end)
    if not ok then return end
    payload = enc

    send_cmd({ "LPUSH", CHAT_KEY, payload }, "RedisStore.on_write")
    -- 顺手裁剪（独立命令，失败无所谓）
    send_cmd({ "LTRIM", CHAT_KEY, "0", tostring(CHAT_KEEP - 1) }, "RedisStore.on_write")
end

-- 只写命令的通用回调（LPUSH/LTRIM/ZADD/TRIM）：仅记错误
function on_write(conn, err, result)
    if err ~= nil then
        print("[RedisStore] write command error: " .. tostring(err))
    end
end

local function note_seen(id)
    if state.seen[id] == nil then
        state.seen[id] = true
        state.seen_count = state.seen_count + 1
        -- 去重表只需要覆盖最近一个拉取窗口；超限时整体重建（最多重复广播一次）
        if state.seen_count > SEEN_LIMIT then
            state.seen = {}
            state.seen_count = 0
        end
    end
end

-- LRANGE 结果回调（数组，元素为聊天 JSON 字符串，最新在前）
function on_lrange(conn, err, result)
    if state ~= nil then state.chat_pending = false end
    if err ~= nil then
        print("[RedisStore] chat poll error: " .. tostring(err))
        return
    end
    if type(result) ~= "table" or state == nil then return end

    -- result 最新在前；为让跨服消息按时间正序广播，先倒序收集再正序播
    local incoming = {}
    for i = #result, 1, -1 do
        local raw = result[i]
        if type(raw) == "string" then
            local ok, msg = pcall(function() return json.decode(raw) end)
            if ok and type(msg) == "table" and msg["id"] ~= nil then
                local id = tostring(msg["id"])
                local is_new = state.seen[id] == nil
                note_seen(id)
                if is_new and msg["origin"] ~= state.server_id
                   and type(msg["name"]) == "string" and type(msg["content"]) == "string" then
                    table.insert(incoming, msg)
                end
            end
        end
    end

    for i = 1, #incoming do
        local m = incoming[i]
        NetWs.broadcast_remote_chat(m["name"], m["content"], tostring(m["origin"]))
    end
end

-- ---- 全局排行镜像（ZADD → TRIM → ZREVRANGE 三级流水线）----

local function start_rank_mirror()
    if state == nil or state.rank_pending then return end
    local top = DB.get_top(20)

    local argv = { "ZADD", RANK_KEY }
    for i = 1, #top do
        -- member 只用账号名（注册限定 [A-Za-z0-9_]），score 为历史最高金币
        table.insert(argv, tostring(top[i].best_gold))
        table.insert(argv, tostring(top[i].name))
    end

    state.rank_pending = true
    if #top == 0 then
        -- 本服空榜：跳过 ZADD，直接进入裁剪
        if not send_cmd({ "ZREMRANGEBYRANK", RANK_KEY, "0", "-21" }, "RedisStore.on_trim") then
            state.rank_pending = false
        end
    else
        if not send_cmd(argv, "RedisStore.on_zadd") then
            state.rank_pending = false
        end
    end
end

function on_zadd(conn, err, result)
    if err ~= nil then
        print("[RedisStore] rank ZADD error: " .. tostring(err))
        if state ~= nil then state.rank_pending = false end
        return
    end
    if not send_cmd({ "ZREMRANGEBYRANK", RANK_KEY, "0", "-21" }, "RedisStore.on_trim") then
        if state ~= nil then state.rank_pending = false end
    end
end

function on_trim(conn, err, result)
    if err ~= nil then
        print("[RedisStore] rank TRIM error: " .. tostring(err))
        if state ~= nil then state.rank_pending = false end
        return
    end
    if not send_cmd({ "ZREVRANGE", RANK_KEY, "0", "19", "WITHSCORES" }, "RedisStore.on_zrange") then
        if state ~= nil then state.rank_pending = false end
    end
end

-- ZREVRANGE WITHSCORES：{name1, score1, name2, score2, ...}，score 为字符串
function on_zrange(conn, err, result)
    if state ~= nil then state.rank_pending = false end
    if err ~= nil then
        print("[RedisStore] rank ZRANGE error: " .. tostring(err))
        return
    end
    if type(result) ~= "table" or state == nil then return end

    local list = {}
    local i = 1
    while i + 1 <= #result do
        table.insert(list, {
            name = tostring(result[i]),
            best_gold = tonumber(result[i + 1]) or 0,
            kills = 0
        })
        i = i + 2
    end
    state.global_list = list
end

-- 主循环每秒调用：拉跨服聊天；每 10s 镜像/刷新全局榜
function tick()
    if state == nil or not state.enabled then return end
    if not is_ready() then return end

    state.poll_tick = state.poll_tick + 1

    if not state.chat_pending then
        state.chat_pending = send_cmd({ "LRANGE", CHAT_KEY, "0", tostring(CHAT_KEEP - 1) },
                                     "RedisStore.on_lrange")
    end

    if state.poll_tick % 10 == 0 and not state.rank_pending then
        start_rank_mirror()
    end
end

-- 全局榜读取（HTTP API 用）；Redis 不可用时回退本服榜
function global_top(limit)
    if limit == nil then limit = 10 end
    if not is_ready() or state == nil or #state.global_list == 0 then
        return DB.get_top(limit)
    end
    local out = {}
    for i = 1, #state.global_list do
        if i > limit then break end
        table.insert(out, state.global_list[i])
    end
    return out
end

-- ---- 帧边界持久化 ----
-- conn 是 NativeObject，不能进 JSON；seen 是「消息 id -> true」集合，转成数组保住键。
function persist()
    if state == nil then return end
    Store.set("redis.conn", state.conn)
    local seen = {}
    if state.seen ~= nil then
        for k, v in pairs(state.seen) do
            seen[#seen + 1] = { k = k, v = v }
        end
    end
    Store.set_json("redis.state", {
        ready = state.ready,
        enabled = state.enabled,
        server_id = state.server_id,
        seq = state.seq,
        seen_count = state.seen_count,
        chat_pending = state.chat_pending,
        rank_pending = state.rank_pending,
        poll_tick = state.poll_tick,
        global_list = state.global_list,
        seen_arr = seen
    })
end

function restore()
    local s = Store.get_json("redis.state")
    -- 必须显式清空：跨帧后 state 是悬垂但非 nil 的指针，留着它后续访问会崩
    if s == nil then
        state = nil
        return
    end
    local seen = {}
    local arr = s["seen_arr"]
    if arr ~= nil then
        for i = 1, #arr do
            local e = arr[i]
            if e ~= nil then seen[e["k"]] = e["v"] end
        end
    end
    state = {
        ready = s["ready"],
        enabled = s["enabled"],
        conn = Store.get("redis.conn"),
        server_id = s["server_id"],
        seq = s["seq"],
        seen = seen,
        seen_count = s["seen_count"],
        chat_pending = s["chat_pending"],
        rank_pending = s["rank_pending"],
        poll_tick = s["poll_tick"],
        global_list = s["global_list"]
    }
    if state.global_list == nil then state.global_list = {} end
end
