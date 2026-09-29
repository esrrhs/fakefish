-- FakeFish 主入口服务脚本
package "Main"

function load_modules()
    -- All modules (Config, Combat, DB, Auth, World, NetWs, HttpStatic) are pre-compiled by host
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

    -- 3.5 生成 AI 机器人
    Bot.init(game_cfg)

    -- 4. 启动 WebSocket 游戏服务
    if not NetWs.init(srv_cfg) then
        print("[Main] Failed to start WebSocket server! Terminating.")
        return 1
    end

    -- 5. 启动 HTTP 静态前端服务
    HttpStatic.init(srv_cfg)

    local tick_ms = srv_cfg["tick_ms"] or 50
    local dt = tick_ms / 1000.0
    local conn_timeout_s = game_cfg["conn_timeout_s"] or 15

    print("[Main] Server loop started: " .. tostring(1000 / tick_ms) .. "Hz (tick=" .. tostring(tick_ms) .. "ms)")
    print("[Main] Access game at: http://127.0.0.1:" .. tostring(srv_cfg["http_port"] or 8080))

    -- 6. 主事件循环驱动
    local frame = 0
    while true do
        frame = frame + 1

        -- 统一事件泵推进：驱动 socket IO、定时器、MySQL 等
        runtime.tick()

        -- 每秒一次：踢掉心跳超时的空闲连接
        if frame % 20 == 0 then
            NetWs.kick_idle(conn_timeout_s)
        end

        -- 发送登录响应（通过 p.connid，与 broadcast 同路径，确保跨平台一致）
        NetWs.flush_login_responses()

        -- flush 其他暂存消息（register_fail, pong 等）
        NetWs.flush_pending()

        -- 排行缓存周期刷新（SELECT 结果经命名回调写回 DB 缓存）
        DB.tick_refresh()

        -- 机器人 AI 决策（写移动意图，物理结算仍在 World.update）
        Bot.update(dt)

        -- 物理与规则计算
        local eat_events, died_events, powerup_events = World.update(dt)

        -- 吞噬与复活事件广播
        for i = 1, #eat_events do
            local ev = eat_events[i]
            NetWs.notify_eat(ev.eater_id, ev.victim_id, ev.gold)
        end

        for i = 1, #died_events do
            local dev = died_events[i]
            NetWs.notify_died(dev.victim_id, dev.gold, dev.x, dev.y)
        end

        -- 道具拾取事件广播
        for i = 1, #powerup_events do
            local pev = powerup_events[i]
            NetWs.notify_powerup(pev.player_id, pev.name, pev.kind)
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
