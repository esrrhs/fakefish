package "Metrics"

-- UDP 指标推送口（fakelua net.udp_server）。
--
-- 采集模型（拉式注册 + 周期推送）：
--   1. 采集器向本口发送任意 UDP 数据报（建议 {"type":"register"}）即登记为接收方；
--   2. 服务端每隔 interval_s 向所有已登记 peer 推送一帧 JSON 指标；
--   3. 采集器发送 {"type":"unregister"} 注销。
-- UDP 无连接，服务端不需要知道采集器存在——用入站数据报的来源 ip:port 作为推送目标。
--
-- net 回调运行于 C++ 派发上下文：只能写运行时 table(peers) 的字段，
-- 不能改文件级 upvalue；推送(send)全部在主循环 push() 中完成。

local udp_obj = nil
local udp_port = nil
local peers = nil          -- 运行时：key "ip:port" -> { ip=, port= }
local tick_count = nil
local interval_s = nil

function init(cfg)
    peers = {}
    tick_count = 0
    interval_s = 5
    if cfg == nil then cfg = {} end

    if cfg["enabled"] == false then
        print("[Metrics] disabled by config (metrics.enabled=false)")
        return
    end

    local ip = cfg["ip"] or "127.0.0.1"
    local port = cfg["port"] or 8092
    interval_s = cfg["interval_s"] or 5
    if interval_s < 1 then interval_s = 1 end

    local ok, obj = pcall(function()
        return net.udp_server({ ip = ip, port = port })
    end)
    if not ok or obj == nil then
        print("[Metrics] udp server bind failed, metrics disabled: " .. tostring(obj))
        return
    end

    udp_obj = obj
    udp_obj:dispatch("Metrics.on_event")
    udp_port = udp_obj:get_port()
    print("[Metrics] UDP metrics endpoint listening on " .. ip .. ":" .. tostring(udp_port)
          .. " (push every " .. tostring(interval_s) .. "s)")
end

-- net UDP 事件回调（C++ 派发上下文）
function on_event(typ, connid, data, len, reason)
    if typ ~= "recv" then return end
    if udp_obj == nil or peers == nil then return end

    local ip, port = udp_obj:get_peer()
    if ip == nil or port == nil then return end
    local key = tostring(ip) .. ":" .. tostring(port)

    -- 默认「任意入站包即注册」；显式 unregister 则移除
    local action = "register"
    if data ~= nil and #data > 0 then
        local ok, msg = pcall(function() return json.decode(data) end)
        if ok and type(msg) == "table" and msg["type"] == "unregister" then
            action = "unregister"
        end
    end

    if action == "unregister" then
        peers[key] = nil
    else
        peers[key] = { ip = tostring(ip), port = port }
    end
end

function is_ready()
    return udp_obj ~= nil
end

function peer_count()
    if peers == nil then return 0 end
    local n = 0
    for _ in pairs(peers) do n = n + 1 end
    return n
end

-- 主循环每秒调用；内部按 interval_s 节流，无 peer 时不组包
function push()
    if udp_obj == nil or peers == nil then return end
    tick_count = tick_count + 1
    if tick_count % interval_s ~= 0 then return end

    local n = peer_count()
    if n == 0 then return end

    local st = World.get_stats()
    local cnt = NetWs.get_counters()
    local payload = json.encode({
        ts = os.time(),
        online = st.online,
        bots = st.bots,
        uptime_s = st.uptime_s,
        map = { width = st.map_width, height = st.map_height },
        ws_recv = cnt.recv,
        ws_sent = cnt.sent,
        metric_peers = n
    })

    for key, peer in pairs(peers) do
        local ok, err = pcall(function() udp_obj:send(payload, peer.ip, peer.port) end)
        if not ok then
            print("[Metrics] push failed to " .. key .. ": " .. tostring(err))
            peers[key] = nil
        end
    end
end

-- ---- 帧边界持久化 ----
-- udp socket 是 NativeObject；peers 以 "ip:port" 字符串为键，JSON 编码安全。
function persist()
    Store.set("metrics.udp", udp_obj)
    Store.set("metrics.port", udp_port)
    Store.set("metrics.interval_s", interval_s)
    Store.set("metrics.tick_count", tick_count)
    Store.set_json("metrics.peers", peers)
end

function restore()
    udp_obj = Store.get("metrics.udp")
    udp_port = Store.get("metrics.port")
    interval_s = Store.get("metrics.interval_s")
    tick_count = Store.get("metrics.tick_count")
    peers = Store.get_json("metrics.peers")
    if peers == nil then peers = {} end
end
