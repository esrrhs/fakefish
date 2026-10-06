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

    -- 3.8 初始化热更通道（需在 WS 服务启动前就绪）
    HotReload.init(srv_cfg)

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
    local feast_interval_s = game_cfg["feast_interval_s"] or 0

    print("[Main] Server loop started: " .. tostring(1000 / tick_ms) .. "Hz (tick=" .. tostring(tick_ms) .. "ms)")
    print("[Main] Access game at: http://127.0.0.1:" .. tostring(srv_cfg["http_port"] or 8080))
    if feast_interval_s > 0 then
        print("[Main] Feast (gold rain) every " .. tostring(feast_interval_s) .. "s")
    end

    -- timer 心跳（fakelua 全局唯一心跳）：每秒调度排行刷新与金币雨
    -- 注意：timer.set_heartbeat 传函数名字符串，回调由 runtime.tick 泵出
    local hb_ok, hb_err = pcall(function()
        timer.set_heartbeat(1000, "Main.on_heartbeat")
    end)
    if hb_ok then
        print("[Main] Timer heartbeat registered (1s)")
    else
        print("[Main] Warning: timer heartbeat failed: " .. tostring(hb_err))
    end

    -- 6. 主事件循环驱动
    local frame = 0
    local kick_acc = 0
    while true do
        frame = frame + 1

        -- 统一事件泵推进：驱动 socket IO、定时器、MySQL 等
        runtime.tick()

        -- 异步登录/注册 SELECT 收尾（账号校验、进场必须在主循环上下文完成）
        Auth.tick()

        -- 同账号在别处登录时，通知并断开旧连接
        NetWs.flush_kicks()

        -- 金币雨到期（timer 心跳置位）：主循环里撒豆并广播——
        -- 奖励豆 table 必须在主循环上下文创建才能跨帧存活，广播也不能进回调
        if World.pop_feast_due() then
            local feast = World.spawn_feast()
            if feast ~= nil then
                NetWs.notify_feast(feast.x, feast.y, feast.count)
            end
        end

        -- 安全区变化（收缩/重置）：读当前 zone 信息并广播
        if World.pop_zone_due() then
            local zi = World.get_zone_info()
            if zi ~= nil then
                NetWs.notify_zone(zi)
            end
        end

        -- 每秒一次：踢掉心跳超时的空闲连接（按累计时间判定，不依赖固定帧率）
        kick_acc = kick_acc + dt
        if kick_acc >= 1.0 then
            kick_acc = 0
            NetWs.kick_idle(conn_timeout_s)
        end

        -- 发送登录响应（通过 p.connid，与 broadcast 同路径，确保跨平台一致）
        NetWs.flush_login_responses()

        -- 热更请求处理（结果入 World 响应队列，下一行 flush 发出）
        HotReload.process()

        -- flush 其他暂存消息（register_fail, pong, hotfix_result 等）
        NetWs.flush_pending()

        -- 排行缓存刷新已改由 timer 心跳调度（Main.on_heartbeat 每 5s 一次）

        -- 机器人 AI 决策（写移动意图，物理结算仍在 World.update）
        Bot.update(dt)

        -- 物理与规则计算
        local eat_events, died_events, powerup_events = World.update(dt)

        -- 吞噬与复活事件广播
        for i = 1, #eat_events do
            local ev = eat_events[i]
            NetWs.notify_eat(ev.eater_id, ev.victim_id, ev.gold, ev.full, ev.partial)
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

-- timer 心跳回调（fakelua 按函数名派发；C++ 上下文，只做世界状态变更）
function on_heartbeat(type, timer_id)
    World.on_heartbeat()
end
