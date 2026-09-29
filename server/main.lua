-- FakeFish 主入口服务脚本
package "Main"

function load_modules()
    dofile("server/config.lua")
    dofile("server/combat.lua")
    dofile("server/db.lua")
    dofile("server/auth.lua")
    dofile("server/world.lua")
    dofile("server/net_ws.lua")
    dofile("server/http_static.lua")
end

function start(config_path)
    load_modules()

    print("========================================")
    print("      🐟 FakeFish PVP Game Server       ")
    print("========================================")

    if config_path == nil or config_path == "" then
        config_path = "config.yaml"
    end

    -- 1. 加载配置
    if not Config.load(config_path) then
        print("[Main] Warning: Failed to load config, using defaults.")
    end

    local srv_cfg = Config.get_server()
    local mysql_cfg = Config.get_mysql()
    local game_cfg = Config.get_game()

    -- 2. 初始化持久层
    DB.init(mysql_cfg)

    -- 3. 初始化游戏世界与规则
    World.init(game_cfg)

    -- 4. 启动 WebSocket 游戏服务
    if not NetWs.init(srv_cfg) then
        print("[Main] Failed to start WebSocket server! Terminating.")
        return 1
    end

    -- 5. 启动 HTTP 静态前端服务
    HttpStatic.init(srv_cfg)

    local tick_ms = srv_cfg["tick_ms"] or 50
    local dt = tick_ms / 1000.0

    print("[Main] Server loop started: " .. tostring(1000 / tick_ms) .. "Hz (tick=" .. tostring(tick_ms) .. "ms)")
    print("[Main] Access game at: http://127.0.0.1:" .. tostring(srv_cfg["http_port"] or 8080))

    -- 6. 主事件循环驱动
    while true do
        -- 统一事件泵推进：驱动 socket IO、定时器、MySQL 等
        runtime.tick()

        -- 物理与规则计算
        local eat_events, died_events = World.update(dt)

        -- 吞噬与复活事件广播
        for i = 1, #eat_events do
            local ev = eat_events[i]
            NetWs.notify_eat(ev.eater_id, ev.victim_id, ev.gold)
        end

        for i = 1, #died_events do
            local dev = died_events[i]
            NetWs.notify_died(dev.victim_id, dev.gold, dev.x, dev.y)
        end

        -- 快照广播给所有客户端
        NetWs.broadcast_snapshot()

        -- 控制帧率
        os.sleep(tick_ms)
    end

    return 0
end

function run()
    return start("config.yaml")
end
