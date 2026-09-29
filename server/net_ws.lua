package "NetWs"

local ws_server_obj = nil
local ws_port = 8081

-- 待发送消息队列：on_event 回调（C++调Lua）中不能直接 ws_server_obj:send()，
-- 因为部分平台（Linux）的 WebSocket 实现在回调上下文中 send 会被静默丢弃。
-- 改为在回调中入队，主循环 tick() 后统一 flush。
local pending_sends = {}

-- WebSocket 事件分发（C++ 回调入口）
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
                local resp = {
                    type = "login_ok",
                    player_id = p.id,
                    gold = p.gold,
                    map = World.get_map_info()
                }
                queue_send(connid, resp)
            else
                queue_send(connid, { type = "register_fail", reason = tostring(res) })
            end

        elseif mtype == "login" then
            local username = msg["username"]
            local password = msg["password"]
            local success, res = Auth.handle_login(username, password)
            if success then
                local p = World.add_player(connid, res)
                local resp = {
                    type = "login_ok",
                    player_id = p.id,
                    gold = p.gold,
                    map = World.get_map_info()
                }
                queue_send(connid, resp)
            else
                queue_send(connid, { type = "login_fail", reason = tostring(res) })
            end

        elseif mtype == "move" then
            local dx = msg["dx"] or 0
            local dy = msg["dy"] or 0
            World.set_player_move(connid, dx, dy)

        elseif mtype == "ping" then
            queue_send(connid, { type = "pong" })
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

-- 入队待发送消息（用于回调上下文）
function queue_send(connid, tbl)
    table.insert(pending_sends, { connid = connid, tbl = tbl })
end

-- flush 所有待发送消息（在主循环 tick() 之后调用）
function flush_pending()
    if #pending_sends == 0 then return end
    for i = 1, #pending_sends do
        local item = pending_sends[i]
        send(item.connid, item.tbl)
    end
    pending_sends = {}
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
    local connid = World.get_conn_by_pid(victim_id)
    if connid ~= nil then
        send(connid, {
            type = "you_died",
            gold = gold,
            x = x,
            y = y
        })
    end
end
