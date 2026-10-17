-- FakeFish 主入口服务脚本
--
-- 生命周期由宿主驱动（见 host/main.cpp）：Main.init 一次 -> Main.update 每帧
-- -> Main.fini 一次。每次 update 是一次独立的顶层 Call，fakelua 借此重置 frame
-- arena 回收帧内临时对象；因此**任何跨帧状态都必须经 Store 落到 C++ 堆**，
-- 不能依赖文件级 local（VarTable 跨帧即失效）。
package "Main"

function load_modules()
    -- All modules (Config, Combat, DB, Auth, World, NetWs, HttpStatic) are pre-compiled by host
end

function init(config_path)
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
    local all_cfg = Config.get()

    -- 1.5 文件日志（fakelua log 模块；任何失败静默降级，不阻断启动）
    local log_cfg = all_cfg["log"]
    if log_cfg ~= nil and log_cfg["enabled"] ~= false then
        local log_path = log_cfg["path"] or "data/logs/server.log"
        local log_dir = os.dirname(log_path)
        if log_dir ~= nil and log_dir ~= "" and log_dir ~= "." then
            os.mkdir(log_dir)
        end
        local okf, ferr = pcall(function() log.set_file(log_path) end)
        if okf then
            local levels = { trace = 0, debug = 1, info = 2, warn = 3, error = 4 }
            local lv = levels[tostring(log_cfg["level"])]
            if lv == nil then lv = 2 end
            pcall(function() log.set_level(lv) end)
            print("[Main] File logging enabled at " .. log_path .. " (level=" .. tostring(lv) .. ")")
        else
            print("[Main] Warning: log.set_file failed: " .. tostring(ferr))
        end
    end

    -- 1.8 游客登录开关（需在 WS 服务启动前就绪：Auth.begin_guest 读它）
    Auth.init(all_cfg["guest"])

    -- 2. 初始化持久层
    DB.init(mysql_cfg)

    -- 2.5 SQLite 事件流水账本（进场/击杀/金币雨；不可用时内部降级）
    Ledger.init(all_cfg["ledger"])

    -- 2.6 防篡改管理操作审计链（SHA-256 哈希链；不可用时内部降级）
    Audit.init(all_cfg["audit"])

    -- 3. 初始化游戏世界与规则
    World.init(game_cfg)

    -- 3.5 生成 AI 机器人
    Bot.init(game_cfg)

    -- 3.6 可选旁路能力（Redis 排行镜像/跨服聊天、出站 Webhook、UDP 指标口）
    -- 均为「配置缺失或连不上就静默降级」，不阻断主服务
    RedisStore.init(all_cfg["redis"])
    Webhook.init(all_cfg["webhook"])
    Metrics.init(all_cfg["metrics"])

    -- 3.7 Phase 17：原生 deque 内存事件 feed、io 持久化登录公告、
    -- process 白名单管理命令（均内部降级/鉴权，不阻断主服务）
    Feed.init(all_cfg["feed"])
    Motd.init(all_cfg["motd"])
    Backup.init(all_cfg["backup"])
    Admin.init(all_cfg["admin"], srv_cfg)

    -- 3.8 初始化热更通道（需在 WS 服务启动前就绪）
    HotReload.init(srv_cfg)

    -- 4. 启动 WebSocket 游戏服务
    if not NetWs.init(srv_cfg) then
        print("[Main] Failed to start WebSocket server! Terminating.")
        return 1
    end

    -- 5. 启动 HTTP 静态前端服务
    HttpStatic.init(srv_cfg, all_cfg["log"])

    local tick_ms = srv_cfg["tick_ms"] or 50
    local dt = tick_ms / 1000.0
    local conn_timeout_s = game_cfg["conn_timeout_s"] or 15
    local feast_interval_s = game_cfg["feast_interval_s"] or 0
    local save_interval_s = game_cfg["save_interval_s"] or 20

    -- 帧间调度状态：跨帧必须由 Store 承载
    Store.set("main.tick_ms", tick_ms)
    Store.set("main.dt", dt)
    Store.set("main.conn_timeout_s", conn_timeout_s)
    Store.set("main.save_interval_s", save_interval_s)
    Store.set("main.frame", 0)
    Store.set("main.kick_acc", 0)
    Store.set("main.save_acc", 0)

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

    -- init 也是一个独立的顶层 Call：它创建的世界（机器人、豆子、道具等）在 init
    -- 帧结束时同样会随 arena 消亡，必须先落库，update 首帧才能 restore 回来。
    persist_all()

    return 0
end

-- 帧边界编排：显式列出模块（fakelua 无法按字符串动态取跨包函数）。
-- Bot 依赖 World：必须先恢复世界，才能按 id 重新绑定机器人实体。
function restore_all()
    Config.restore()
    Auth.restore()
    DB.restore()
    World.restore()
    Bot.restore()
    NetWs.restore()
    Feed.restore()
    Ledger.restore()
    Audit.restore()
    RedisStore.restore()
    Metrics.restore()
    Motd.restore()
    Backup.frame_restore()
    Admin.restore()
    HotReload.restore()
    HttpStatic.restore()
    Webhook.restore()
end

function persist_all()
    Config.persist()
    Auth.persist()
    DB.persist()
    World.persist()
    Bot.persist()
    NetWs.persist()
    Feed.persist()
    Ledger.persist()
    Audit.persist()
    RedisStore.persist()
    Metrics.persist()
    Motd.persist()
    Backup.frame_persist()
    Admin.persist()
    HotReload.persist()
    HttpStatic.persist()
    Webhook.persist()
end

-- 单帧工作。返回 0 继续循环，非 0 让宿主退出（随后调用 fini）。
function update()
    -- 帧初：把上一帧（或 init）持久化的状态解码回帧内
    restore_all()

    local tick_ms = Store.get("main.tick_ms") or 50
    local dt = Store.get("main.dt") or 0.05
    local conn_timeout_s = Store.get("main.conn_timeout_s") or 15
    local save_interval_s = Store.get("main.save_interval_s") or 20
    local frame = (Store.get("main.frame") or 0) + 1
    local kick_acc = Store.get("main.kick_acc") or 0
    local save_acc = Store.get("main.save_acc") or 0

    Store.set("main.frame", frame)

    -- 统一事件泵推进：驱动 socket IO、定时器、MySQL 等
    runtime.tick()

    -- MySQL 握手必须在 update 主循环里驱动（连接池本身也只在 update 帧建立）
    DB.finish_connect()

    -- 异步登录/注册 SELECT 收尾（账号校验、进场必须在主循环上下文完成）
    Auth.tick()

    -- 同账号在别处登录时，通知并断开旧连接
    NetWs.flush_kicks()

    -- 金币雨到期（timer 心跳置位）：主循环里撒豆并发事件——
    -- 奖励豆 table 必须在主循环上下文创建才能跨帧存活，广播也不能进回调。
    -- NetWs/Ledger/Webhook 均订阅 game.feast。
    if World.pop_feast_due() then
        local feast = World.spawn_feast()
        if feast ~= nil then
            pcall(function() event.emit("game.feast", feast.x, feast.y, feast.count) end)
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
        -- Redis 拉取跨服聊天/同步排行（内部自行节流）；UDP 指标推送
        RedisStore.tick()
        Metrics.push()
        -- 定时加密备份（backup.interval_s，0=关闭；周期可经管理口动态调整）
        if Backup.pop_due() then
            local cok, okc, info = pcall(function()
                return Backup.create("scheduled", "scheduler")
            end)
            if not cok or not okc then
                pcall(function() log.error("[backup] scheduled create failed: " .. tostring(info)) end)
            end
        end
    end
    Store.set("main.kick_acc", kick_acc)

    -- 周期落盘在线玩家金币（按累计时间调度，0 或负值关闭）
    save_acc = save_acc + dt
    if save_interval_s > 0 and save_acc >= save_interval_s then
        save_acc = 0
        World.flush_online_gold()
    end
    Store.set("main.save_acc", save_acc)

    -- 发送登录响应（通过 p.connid，与 broadcast 同路径，确保跨平台一致）
    NetWs.flush_login_responses()

    -- 热更请求处理（结果入 World 响应队列，下一行 flush 发出）
    HotReload.process()

    -- flush 其他暂存消息（register_fail, pong, hotfix_result 等）
    NetWs.flush_pending()

    -- 机器人 AI 决策（写移动意图，物理结算仍在 World.update）
    Bot.update(dt)

    -- 物理与规则计算
    local eat_events, died_events, powerup_events = World.update(dt)

    -- 吞噬与复活事件：统一经事件总线派发。
    -- NetWs 负责 WS 广播；Ledger 记 full 击杀流水；Webhook 出站推送 full 击杀。
    for i = 1, #eat_events do
        local ev = eat_events[i]
        local kind = "partial"
        if ev.full then kind = "full" end
        pcall(function() event.emit("game.eat", ev.eater_id, ev.victim_id, ev.gold, kind) end)
    end

    for i = 1, #died_events do
        local dev = died_events[i]
        pcall(function() event.emit("game.death", dev.victim_id, dev.gold, dev.x, dev.y) end)
    end

    -- 道具拾取事件广播
    for i = 1, #powerup_events do
        local pev = powerup_events[i]
        NetWs.notify_powerup(pev.player_id, pev.name, pev.kind)
    end

    -- 快照广播给所有客户端
    NetWs.broadcast_snapshot()

    -- 帧末：把本帧状态持久化，供下一帧 restore
    persist_all()

    -- 控制帧率
    os.sleep(tick_ms)

    return 0
end

function fini()
    print("[Main] Server shutting down")
    return 0
end

-- timer 心跳回调（fakelua 按函数名派发；C++ 上下文，只做世界状态变更）
function on_heartbeat(type, timer_id)
    World.on_heartbeat()
end
