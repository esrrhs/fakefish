package "NetWs"

local ws_server_obj = nil
-- init() 中重赋值，数值字面量初始化的文件级 local 是 static const（禁止再赋值），声明 nil
local ws_port = nil

-- 吞吐计数（供 Metrics UDP 推送）：运行时在 init() 中创建
local counters = nil

-- WebSocket 事件分发（C++ 回调入口）
-- 注意：在此回调中不能修改本模块的 local upvalue（fakelua const 限制），
-- 也不能直接 ws_server_obj:send()（Linux 上静默丢弃）。
-- login_ok 等响应存储在玩家记录中（World 模块的 runtime table），主循环通过
-- p.connid 发送（与 broadcast 同路径，确保跨平台一致）。
function on_event(type, connid, data, len, reason)
    if type == "conn" then
        print("[NetWs] Client connected, connid=" .. tostring(connid))
        World.mark_conn(connid)

    elseif type == "recv" then
        if data == nil or #data == 0 then return end

        -- 收到任何消息都刷新该连接的活跃时间
        World.touch_player(connid)
        if counters ~= nil then counters.recv = counters.recv + 1 end

        local ok, msg = pcall(function() return json.decode(data) end)
        if not ok or msg == nil or type_of(msg) ~= "table" then
            print("[NetWs] Invalid JSON from connid=" .. tostring(connid))
            return
        end

        -- 整个分发再包一层：恶意/畸形字段（number 传成 string 等）在 C++ 回调
        -- 上下文抛错会中断本次派发，统一兜住并记日志，不能让单个坏包打挂连接处理
        local route_ok, route_err = pcall(function() handle_message(connid, msg) end)
        if not route_ok then
            print("[NetWs] message handling error from connid=" .. tostring(connid)
                  .. ": " .. tostring(route_err))
        end

    elseif type == "close" then
        print("[NetWs] Client disconnected, connid=" .. tostring(connid))
        World.unmark_conn(connid)
        World.remove_player_by_conn(connid)
    end
end

-- 单条已解码消息的路由（仅由 on_event 在 pcall 内调用）
function handle_message(connid, msg)
    local mtype = msg["type"]

    if mtype == "register" then
        -- 类型校验在 Auth.begin_register 内完成
        Auth.begin_register(connid, msg["username"], msg["password"])

    elseif mtype == "login" then
        Auth.begin_login(connid, msg["username"], msg["password"])

    elseif mtype == "move" then
        local dx = msg["dx"]
        local dy = msg["dy"]
        -- 非数值类型直接丢弃，防止字符串进入 set_player_move 做算术；
        -- NaN/Inf 也要拦：NaN 能通过归一化（NaN 比较恒假）并让坐标变 NaN，
        -- 骗过所有边界钳制后经快照广播污染全体客户端。
        -- 用「x==x 排除 NaN，x*0==0 排除 ±Inf（Inf*0 与 NaN*0 都是 NaN）」判定有限数。
        if type_of(dx) == "number" and type_of(dy) == "number"
           and dx == dx and dy == dy
           and dx * 0 == 0 and dy * 0 == 0 then
            World.set_player_move(connid, dx, dy)
        end

    elseif mtype == "split" then
        World.request_split(connid)

    elseif mtype == "chat" then
        local content = msg["content"]
        if content ~= nil and type_of(content) == "string" then
            World.submit_chat(connid, content)
        end

    elseif mtype == "get_rank" then
        -- 历史排行：直接读服务端缓存（DB.tick_refresh 周期从 MySQL/内存刷新）
        -- 响应挂到玩家记录上，主循环经 p.connid 发送（Linux 上队列 connid 路径会静默失败）
        -- 与 HTTP parse_rank_limit 对齐：非数值/NaN 走默认 10，小数向下取整，钳到 1-20。
        -- 不做下限会让 0/负数返回空榜（虽无越界），NaN 则让 i>limit 恒假而放出整个缓存。
        -- 必须先经 tonumber 落到数值局部：fakelua JIT 不承认 type()/type_of() 的
        -- 分支类型窄化，守卫后对同一多态变量做 math.floor/比较会在 TCC/GCC 入口
        -- 被硬守卫拦截（非数值入参直接 abort），见 docs/fakelua-bugs-phase16.md Bug 1。
        local lim = tonumber(msg["limit"])
        if lim == nil or lim ~= lim then lim = 10 end
        lim = math.floor(lim)
        if lim < 1 then lim = 1 end
        if lim > 20 then lim = 20 end
        local p = World.get_player_by_conn(connid)
        if p ~= nil then
            p.pending_rank = { type = "rank", list = DB.get_top(lim) }
        end

    elseif mtype == "ping" then
        World.enqueue_response(connid, { type = "pong" })

    elseif mtype == "get_chat" then
        local p = World.get_player_by_conn(connid)
        if p ~= nil then
            p.pending_chat = { type = "chat_history", list = World.get_recent_chat() }
        end

    elseif mtype == "hotfix" then
        -- 运维通道：token 校验失败直接入队失败响应；通过则只入队请求，
        -- 编译由主循环 HotReload.process() 执行（回调上下文不允许重编译）
        if not HotReload.check_token(msg["token"]) then
            World.enqueue_response(connid, { type = "hotfix_result", ok = false, err = "invalid token" })
        else
            HotReload.request(connid, msg["modules"])
        end
    end
end

function type_of(v)
    return type(v)
end

function init(cfg)
    if cfg == nil then cfg = {} end
    ws_port = cfg["ws_port"] or 8081

    local srv_cfg = {
        port = ws_port,
        maxconn = 200,
        ws_path = "/"
    }

    local ok, srv = pcall(function() return net.ws_server(srv_cfg) end)
    if not ok or not srv then
        print("[NetWs] Failed to create WebSocket server on port " .. tostring(ws_port) .. ": " .. tostring(srv))
        return false
    end

    ws_server_obj = srv
    ws_server_obj:dispatch("NetWs.on_event")

    counters = { recv = 0, sent = 0 }

    ---- 事件总线订阅（init 仅执行一次；热更替换函数地址后自动命中新版）----
    -- 世界规则事件不再由 main 直接调用本模块，统一经 event.emit 派发，
    -- Ledger/Webhook/RedisStore 等旁路能力各自订阅，互不耦合。
    event.on("game.eat", "NetWs.on_ev_eat")
    event.on("game.death", "NetWs.on_ev_death")
    event.on("game.feast", "NetWs.on_ev_feast")

    print("[NetWs] WebSocket server listening on port " .. tostring(ws_port))
    return true
end

-- ---- 事件总线处理器（均在主循环 emit 上下文中同步执行，可直接发送）----

function on_ev_eat(eater_id, victim_id, gold, kind)
    notify_eat(eater_id, victim_id, gold, kind == "full", kind == "partial")
end

function on_ev_death(victim_id, gold, x, y)
    notify_died(victim_id, gold, x, y)
end

function on_ev_feast(x, y, count)
    notify_feast(x, y, count)
end

-- 发送玩家暂存消息（通过 p.connid，与 broadcast 同路径）
-- 在主循环中调用，不在 C++ 回调上下文中
function flush_login_responses()
    if ws_server_obj == nil then return end
    local all_players = World.get_all_players()
    for pid, p in pairs(all_players) do
        if p.pending_login_ok ~= nil then
            local json_str = json.encode(p.pending_login_ok)
            ws_server_obj:send(p.connid, json_str)
            p.pending_login_ok = nil
        end
        if p.pending_rank ~= nil then
            local json_str = json.encode(p.pending_rank)
            ws_server_obj:send(p.connid, json_str)
            p.pending_rank = nil
        end
        if p.pending_chat ~= nil then
            local json_str = json.encode(p.pending_chat)
            ws_server_obj:send(p.connid, json_str)
            p.pending_chat = nil
        end
    end
end

-- flush World 中暂存的其他消息（register_fail, pong 等）
function flush_pending()
    local responses = World.drain_responses()
    if responses == nil then return end
    for i = 1, #responses do
        local item = responses[i]
        if item.connid == -1 then
            -- 世界广播（聊天等）：与 broadcast 同路径，遍历所有在线连接
            broadcast(item.tbl)
            -- 本地聊天同时上事件总线：RedisStore 订阅后跨服转发。
            -- emit 在主循环上下文；旁路订阅者自行 pcall 兜底。
            if item.tbl ~= nil and item.tbl.type == "chat" then
                pcall(function()
                    event.emit("game.chat", item.tbl.name, item.tbl.content, "")
                end)
            end
        else
            send(item.connid, item.tbl)
        end
    end
end

-- 通知并断开被同账号新会话顶替的旧连接（主循环调用，两阶段）：
-- 先断开上一帧已通知的连接（给错误帧留出一个 IO 泵周期），再对本帧新入队的
-- 旧连接下发 error 并排队到下一帧断开。
-- close_connection 会同步派发 close 事件；add_player 已先解除旧 conn 的映射，
-- 故事件里的 remove_player_by_conn 是 no-op，不会波及新会话。
function flush_kicks()
    if ws_server_obj == nil then return end

    local closes = World.drain_pending_closes()
    if closes ~= nil then
        for i = 1, #closes do
            ws_server_obj:close_connection(closes[i])
        end
    end

    local kicks = World.drain_pending_kicks()
    if kicks ~= nil then
        for i = 1, #kicks do
            local connid = kicks[i]
            ws_server_obj:send(connid, json.encode({
                type = "error",
                reason = "账号已在别处登录"
            }))
            World.enqueue_pending_close(connid)
        end
    end

    -- 运维口主动下线：error 帧携带管理员指定原因，同帧排队到下一帧断开
    local akicks = World.drain_pending_admin_kicks()
    if akicks ~= nil then
        for i = 1, #akicks do
            local item = akicks[i]
            ws_server_obj:send(item["connid"], json.encode({
                type = "error",
                reason = item["reason"]
            }))
            World.enqueue_pending_close(item["connid"])
        end
    end
end

function send(connid, tbl)
    if ws_server_obj == nil then return end
    local json_str = json.encode(tbl)
    ws_server_obj:send(connid, json_str)
    if counters ~= nil then counters.sent = counters.sent + 1 end
end

function broadcast(tbl)
    if ws_server_obj == nil then return end
    local json_str = json.encode(tbl)
    local all_players = World.get_all_players()
    for pid, p in pairs(all_players) do
        if p.connid ~= nil then
            ws_server_obj:send(p.connid, json_str)
            if counters ~= nil then counters.sent = counters.sent + 1 end
        end
    end
end

-- 跨服聊天（RedisStore 从其他实例拉到后调用）：只广播、不再上事件总线，
-- 避免「拉到自己发出的消息」造成回环（from 过滤之外的双保险）
function broadcast_remote_chat(name, content, from)
    broadcast({
        type = "chat",
        name = name,
        content = content,
        from = from
    })
end

-- 吞吐计数器（Metrics 周期读取）
function get_counters()
    if counters == nil then return { recv = 0, sent = 0 } end
    return { recv = counters.recv, sent = counters.sent }
end

function broadcast_snapshot()
    local snap, foods, powerups = World.get_snapshot()
    if #snap == 0 then return end
    local msg = {
        type = "snapshot",
        players = snap,
        foods = foods,
        powerups = powerups,
        zone = World.get_zone_info()
    }
    broadcast(msg)
end

function notify_powerup(player_id, name, kind)
    broadcast({
        type = "powerup",
        player_id = player_id,
        name = name,
        kind = kind
    })
end

function notify_feast(x, y, count)
    broadcast({
        type = "feast",
        x = x,
        y = y,
        count = count
    })
end

-- 安全区收缩/重置事件（zi 为 World.get_zone_info 返回表）
function notify_zone(zi)
    if zi == nil then return end
    local m = {
        type = "zone",
        x = zi.x,
        y = zi.y,
        r = zi.r,
        phase = zi.phase,
        holding = zi.holding,
        next_in = zi.next_in
    }
    if zi.phase == 0 then
        m.reset = true
    end
    broadcast(m)
end

function notify_eat(eater_id, victim_id, gold, full, partial)
    -- 附带双方昵称供前端击杀播报直接展示（回调外的主循环上下文，读玩家表安全）
    local all_players = World.get_all_players()
    local eater = all_players[eater_id]
    local victim = all_players[victim_id]
    local m = {
        type = "eat",
        eater_id = eater_id,
        victim_id = victim_id,
        eater_name = eater ~= nil and eater.name or tostring(eater_id),
        victim_name = victim ~= nil and victim.name or tostring(victim_id),
        gold = gold
    }
    if full then m.full = true end
    if partial then m.partial = true end
    broadcast(m)
end

-- 踢掉超时连接（主循环周期调用）：
--  1. 已登录玩家：超过 timeout_s 秒没有任何消息；
--  2. 只建连未登录：建连超过 timeout_s 仍未进场（防止挂连接占满 maxconn）。
-- close_connection 会同步触发 close 事件 → 走 unmark/remove_player_by_conn 正常清场
function kick_idle(timeout_s)
    if ws_server_obj == nil then return end
    if timeout_s == nil or timeout_s <= 0 then return end
    local now = os.time()
    local all_players = World.get_all_players()
    for pid, p in pairs(all_players) do
        if p.connid ~= nil and p.last_seen ~= nil and (now - p.last_seen) > timeout_s then
            print("[NetWs] Kicking idle connection connid=" .. tostring(p.connid)
                  .. " player=" .. tostring(p.name) .. " (idle " .. tostring(now - p.last_seen) .. "s)")
            ws_server_obj:close_connection(p.connid)
        end
    end

    local unauth = World.get_idle_unauth_conns(timeout_s, now)
    for i = 1, #unauth do
        print("[NetWs] Kicking unauthenticated connection connid=" .. tostring(unauth[i])
              .. " (no login within " .. tostring(timeout_s) .. "s)")
        ws_server_obj:close_connection(unauth[i])
    end
end

function notify_died(victim_id, gold, x, y)
    if ws_server_obj == nil then return end
    local all_players = World.get_all_players()
    local p = all_players[victim_id]
    if p ~= nil and p.connid ~= nil then
        local json_str = json.encode({
            type = "you_died",
            gold = gold,
            x = x,
            y = y
        })
        ws_server_obj:send(p.connid, json_str)
    end
end
