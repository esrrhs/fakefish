package "NetWs"

local ws_server_obj = nil
local ws_port = 8081

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

        elseif mtype == "ping" then
            World.enqueue_response(connid, { type = "pong" })
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

-- 发送玩家登录响应（通过 p.connid，与 broadcast 同路径）
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
    end
end

-- flush World 中暂存的其他消息（register_fail, pong 等）
function flush_pending()
    local responses = World.drain_responses()
    if responses == nil then return end
    for i = 1, #responses do
        local item = responses[i]
        send(item.connid, item.tbl)
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
    local snap, foods = World.get_snapshot()
    if #snap == 0 then return end
    local msg = {
        type = "snapshot",
        players = snap,
        foods = foods
    }
    broadcast(msg)
end

function notify_eat(eater_id, victim_id, gold)
    broadcast({
        type = "eat",
        eater_id = eater_id,
        victim_id = victim_id,
        gold = gold
    })
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
