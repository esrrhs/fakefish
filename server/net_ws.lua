package "NetWs"

local ws_server_obj = nil
-- init() 中重赋值，数值字面量初始化的文件级 local 是 static const（禁止再赋值），声明 nil
local ws_port = nil

-- WebSocket 事件分发（C++ 回调入口）
-- 注意：在此回调中不能修改本模块的 local upvalue（fakelua const 限制），
-- 也不能直接 ws_server_obj:send()（Linux 上静默丢弃）。
-- login_ok 等响应存储在玩家记录中（World 模块的 runtime table），主循环通过
-- p.connid 发送（与 broadcast 同路径，确保跨平台一致）。
function on_event(type, connid, data, len, reason)
    if type == "conn" then
        print("[NetWs] Client connected, connid=" .. tostring(connid))

    elseif type == "recv" then
        if data == nil or #data == 0 then return end

        -- 收到任何消息都刷新该连接的活跃时间
        World.touch_player(connid)

        local ok, msg = pcall(function() return json.decode(data) end)
        if not ok or msg == nil or type_of(msg) ~= "table" then
            print("[NetWs] Invalid JSON from connid=" .. tostring(connid))
            return
        end

        local mtype = msg["type"]

        if mtype == "register" then
            local username = msg["username"]
            local password = msg["password"]
            local success, res = Auth.handle_register(username, password)
            if success then
                -- 注册后自动进场
                local p = World.add_player(connid, res)
                -- 将 login_ok 响应存储在玩家记录上，主循环通过 p.connid 发送
                p.pending_login_ok = {
                    type = "login_ok",
                    player_id = p.id,
                    gold = p.gold,
                    map = World.get_map_info()
                }
            else
                World.enqueue_response(connid, { type = "register_fail", reason = tostring(res) })
            end

        elseif mtype == "login" then
            local username = msg["username"]
            local password = msg["password"]
            local success, res = Auth.handle_login(username, password)
            if success then
                local p = World.add_player(connid, res)
                p.pending_login_ok = {
                    type = "login_ok",
                    player_id = p.id,
                    gold = p.gold,
                    map = World.get_map_info()
                }
            else
                World.enqueue_response(connid, { type = "login_fail", reason = tostring(res) })
            end

        elseif mtype == "move" then
            local dx = msg["dx"] or 0
            local dy = msg["dy"] or 0
            World.set_player_move(connid, dx, dy)

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
            local limit = msg["limit"] or 10
            if limit > 20 then limit = 20 end
            local p = World.get_player_by_conn(connid)
            if p ~= nil then
                p.pending_rank = { type = "rank", list = DB.get_top(limit) }
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

    elseif type == "close" then
        print("[NetWs] Client disconnected, connid=" .. tostring(connid))
        World.remove_player_by_conn(connid)
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
    print("[NetWs] WebSocket server listening on port " .. tostring(ws_port))
    return true
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
        else
            send(item.connid, item.tbl)
        end
    end
end

function send(connid, tbl)
    if ws_server_obj == nil then return end
    local json_str = json.encode(tbl)
    ws_server_obj:send(connid, json_str)
end

function broadcast(tbl)
    if ws_server_obj == nil then return end
    local json_str = json.encode(tbl)
    local all_players = World.get_all_players()
    for pid, p in pairs(all_players) do
        if p.connid ~= nil then
            ws_server_obj:send(p.connid, json_str)
        end
    end
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

-- 踢掉超过 timeout_s 秒没有任何消息的空闲连接（主循环周期调用）
-- close_connection 会同步触发 close 事件 → 走 remove_player_by_conn 正常清场
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
