package "World"

local map_width = 2000
local map_height = 2000
local initial_gold = 100
local move_speed = 160
local radius_base = 15
local radius_k = 2.5
local eat_ratio = 1.05

-- 在线玩家表: player_id -> player_record
local players = nil
local conn_to_pid = nil
local pid_to_conn = nil

-- 机器人 ID 段（与 MySQL 自增账号 ID 区隔）
-- 注意：不能在模块级赋常量初值（fakelua JIT 会将全常量赋值的标量标记为 const），
-- 必须声明为 nil 并在 init() 中赋值
local next_bot_id = nil

-- 服务器运行时长（秒），由 update(dt) 累加
local world_time = nil

local food_coins = nil
local max_food = 80
local food_val = 5

-- 道具：加速 / 护盾 / 磁铁
local powerups = nil
local powerup_count = 5
local fx_speed_s = 6
local fx_shield_s = 5
local fx_magnet_s = 8

-- 金币雨（feast）事件
local bonus_food = nil
local feast_bonus = 30
local feast_interval_s = 0
-- 心跳世界事件状态（timer 回调只写这里的字段，send 全部留在主循环）
local world_events = nil

-- 动态安全区（收缩毒圈）
local zone = nil
local zone_enable = true
local zone_initial_r = 1500
local zone_min_r = 250
local zone_shrink_ratio = 0.7
local zone_shrink_interval_s = 60
local zone_hold_s = 30
local zone_dps = 20

-- 待发送响应队列（由 NetWs.on_event 回调中入队，主循环 drain）
-- 放在 World 模块的 upvalue 中，绕过 NetWs 回调上下文的 const 限制
-- 注意：必须在 init() 中初始化，不能在模块级别直接赋值为 {}，
-- 否则 fakelua JIT 会将其标记为 const table，在 C++ 回调中 table.insert 会报错
local pending_responses = nil

-- 入队待发送消息（供 NetWs.on_event 回调调用）
function enqueue_response(connid, tbl)
    table.insert(pending_responses, { connid = connid, tbl = tbl })
end

-- 取出并清空待发送队列（供 NetWs.flush_pending 主循环调用）
function drain_responses()
    if #pending_responses == 0 then return nil end
    local result = pending_responses
    pending_responses = {}
    return result
end

function spawn_foods()
    food_coins = {}
    for i = 1, max_food do
        local rx = math.random(50, map_width - 50)
        local ry = math.random(50, map_height - 50)
        table.insert(food_coins, { x = rx, y = ry })
    end
end

-- 轮转生成三种道具，保证每种都覆盖到
local powerup_kinds = { "speed", "shield", "magnet" }

function spawn_powerups()
    powerups = {}
    for i = 1, powerup_count do
        local rx = math.random(60, map_width - 60)
        local ry = math.random(60, map_height - 60)
        table.insert(powerups, { x = rx, y = ry, kind = powerup_kinds[(i - 1) % 3 + 1] })
    end
end

function init(cfg)
    players = {}
    conn_to_pid = {}
    pid_to_conn = {}
    pending_responses = {}
    next_bot_id = 800000
    world_time = 0
    if cfg == nil then cfg = {} end
    map_width = cfg["map_width"] or 2000
    map_height = cfg["map_height"] or 2000
    initial_gold = cfg["initial_gold"] or 100
    move_speed = cfg["move_speed"] or 160
    radius_base = cfg["radius_base"] or 15
    radius_k = cfg["radius_k"] or 2.5
    eat_ratio = cfg["eat_ratio"] or 1.05
    powerup_count = cfg["powerup_count"] or 5
    fx_speed_s = cfg["fx_speed_s"] or 6
    fx_shield_s = cfg["fx_shield_s"] or 5
    fx_magnet_s = cfg["fx_magnet_s"] or 8
    feast_interval_s = cfg["feast_interval_s"] or 0
    bonus_food = {}
    world_events = { sec = 0, feast = nil }

    zone_enable = cfg["zone_enable"]
    if zone_enable == nil then zone_enable = true end
    zone_initial_r = cfg["zone_initial_radius"] or 1500
    zone_min_r = cfg["zone_min_radius"] or 250
    zone_shrink_ratio = cfg["zone_shrink_ratio"] or 0.7
    zone_shrink_interval_s = cfg["zone_shrink_interval_s"] or 60
    zone_hold_s = cfg["zone_hold_s"] or 30
    zone_dps = cfg["zone_dps"] or 20
    -- 初始安全区居中、覆盖整张地图（phase 0；next_in 为距下次收缩秒数）
    zone = {
        x = map_width / 2,
        y = map_height / 2,
        r = zone_initial_r,
        phase = 0,
        holding = false,
        next_in = zone_shrink_interval_s
    }

    spawn_foods()
    spawn_powerups()
    print("[World] Initialized with map " .. tostring(map_width) .. "x" .. tostring(map_height)
          .. ", " .. tostring(max_food) .. " gold pellets, " .. tostring(powerup_count) .. " powerups")
end

function get_map_info()
    return {
        width = map_width,
        height = map_height
    }
end

function get_foods()
    return food_coins
end

function get_random_spawn()
    local margin = 100
    local rx = math.random(margin, map_width - margin)
    local ry = math.random(margin, map_height - margin)
    return rx, ry
end

-- 玩家进场
function add_player(connid, account)
    local pid = account.id
    local spawn_x, spawn_y = get_random_spawn()
    local gold = account.gold or initial_gold
    local r = Combat.calc_radius(gold, radius_base, radius_k)

    local p = {
        id = pid,
        connid = connid,
        name = account.username,
        x = spawn_x,
        y = spawn_y,
        dx = 0,
        dy = 0,
        gold = gold,
        r = r,
        last_seen = os.time(),
        fx_speed_until = 0,
        fx_shield_until = 0,
        fx_magnet_until = 0,
        zone_dmg_acc = 0
    }

    players[pid] = p
    conn_to_pid[connid] = pid
    pid_to_conn[pid] = connid

    print("[World] Player " .. account.username .. " (ID: " .. tostring(pid) .. ") joined the game.")
    return p
end

-- 机器人进场（无连接，仅世界内实体；不进 conn 映射，不落盘）
function add_bot(name)
    local pid = next_bot_id
    next_bot_id = next_bot_id + 1
    local spawn_x, spawn_y = get_random_spawn()

    local p = {
        id = pid,
        connid = nil,
        name = name,
        x = spawn_x,
        y = spawn_y,
        dx = 0,
        dy = 0,
        gold = initial_gold,
        r = Combat.calc_radius(initial_gold, radius_base, radius_k),
        is_bot = true,
        ai_timer = 0,
        ai_dx = 0,
        ai_dy = 0,
        fx_speed_until = 0,
        fx_shield_until = 0,
        fx_magnet_until = 0,
        zone_dmg_acc = 0
    }

    players[pid] = p
    print("[World] Bot " .. name .. " (ID: " .. tostring(pid) .. ") joined the game.")
    return p
end

-- 玩家离场
function remove_player_by_conn(connid)
    local pid = conn_to_pid[connid]
    if pid == nil then return nil end

    local p = players[pid]
    if p ~= nil then
        -- 离场落盘金币
        DB.update_gold(p.name, p.id, p.gold)
        print("[World] Player " .. p.name .. " saved gold: " .. tostring(p.gold) .. " and left.")
    end

    players[pid] = nil
    conn_to_pid[connid] = nil
    pid_to_conn[pid] = nil

    return p
end

-- 设置移动方向（附带归一化防作弊）
function set_player_move(connid, in_dx, in_dy)
    local pid = conn_to_pid[connid]
    if pid == nil then return end
    local p = players[pid]
    if p == nil then return end

    if in_dx == nil or in_dy == nil then
        return
    end

    local mx = in_dx
    local my = in_dy
    local len = math.sqrt(mx * mx + my * my)
    if len > 1.0 then
        -- 归一化，防止客户端上报超速方向向量
        mx = mx / len
        my = my / len
    end

    p.dx = mx
    p.dy = my
end

function get_player_by_conn(connid)
    local pid = conn_to_pid[connid]
    if pid == nil then return nil end
    return players[pid]
end

function get_conn_by_pid(pid)
    return pid_to_conn[pid]
end

-- 吞噬结算落盘（机器人不落盘、不计战绩）
function persist_settlement(eater, victim)
    if not eater.is_bot then
        DB.update_gold(eater.name, eater.id, eater.gold)
        DB.add_kill(eater.name)
    end
    if not victim.is_bot then
        DB.update_gold(victim.name, victim.id, victim.gold)
        DB.add_death(victim.name)
    end
end

-- 逻辑帧更新
-- dt: 秒 (e.g. 0.05)
-- 返回事件列表: eat_events, died_events, powerup_events
function update(dt)
    world_time = world_time + dt

    -- 1. 拾取地面积分金币（磁铁生效时拾取半径 x4；奖励豆吃掉即移除）
    for pid, p in pairs(players) do
        local pickup_r = p.r
        if world_time < p.fx_magnet_until then
            pickup_r = p.r * 4
        end
        for fi = 1, #food_coins do
            local f = food_coins[fi]
            local fdx = p.x - f.x
            local fdy = p.y - f.y
            if (fdx * fdx + fdy * fdy) < (pickup_r * pickup_r) then
                p.gold = p.gold + food_val
                p.r = Combat.calc_radius(p.gold, radius_base, radius_k)
                f.x = math.random(50, map_width - 50)
                f.y = math.random(50, map_height - 50)
            end
        end
        -- 奖励豆：吃掉即移除（n 为显式维护的长度，吃豆后手动 -1）。
        -- 不能直接写 `while bi <= #bonus_food`：fakelua CGen 会把原生 while 条件里的
        -- #t 取到函数级临时变量只算一次，循环内 table.remove 缩短表后条件仍用旧长度，
        -- 导致读到越界 nil（详见 docs/fakelua-pitfalls.md P1-9）。
        local n = #bonus_food
        local bi = 1
        while bi <= n do
            local f = bonus_food[bi]
            local fdx = p.x - f.x
            local fdy = p.y - f.y
            if (fdx * fdx + fdy * fdy) < (pickup_r * pickup_r) then
                p.gold = p.gold + food_val
                p.r = Combat.calc_radius(p.gold, radius_base, radius_k)
                table.remove(bonus_food, bi)
                n = n - 1
            else
                bi = bi + 1
            end
        end
    end

    -- 1.5 拾取道具并应用效果
    local powerup_events = {}
    for pid, p in pairs(players) do
        for pi = 1, #powerups do
            local pw = powerups[pi]
            local pdx = p.x - pw.x
            local pdy = p.y - pw.y
            if (pdx * pdx + pdy * pdy) < (p.r * p.r) then
                if pw.kind == "speed" then
                    p.fx_speed_until = world_time + fx_speed_s
                elseif pw.kind == "shield" then
                    p.fx_shield_until = world_time + fx_shield_s
                elseif pw.kind == "magnet" then
                    p.fx_magnet_until = world_time + fx_magnet_s
                end
                table.insert(powerup_events, { player_id = p.id, name = p.name, kind = pw.kind })

                -- 道具随机换位补给
                pw.x = math.random(60, map_width - 60)
                pw.y = math.random(60, map_height - 60)
            end
        end
    end

    -- 2. 玩家移动积分与边界约束
    for pid, p in pairs(players) do
        if p.dx ~= 0 or p.dy ~= 0 then
            -- 大球移动略慢，体验更平衡：实际速度 = base_speed / (1 + r * 0.005)
            local speed_factor = 1.0 / (1.0 + (p.r - radius_base) * 0.003)

            -- 加速道具生效中 x1.5
            if world_time < p.fx_speed_until then
                speed_factor = speed_factor * 1.5
            end
            local cur_speed = move_speed * speed_factor

            p.x = p.x + p.dx * cur_speed * dt
            p.y = p.y + p.dy * cur_speed * dt

            -- 边界限制
            if p.x < p.r then p.x = p.r end
            if p.x > map_width - p.r then p.x = map_width - p.r end
            if p.y < p.r then p.y = p.r end
            if p.y > map_height - p.r then p.y = map_height - p.r end
        end
    end

    -- 2.5 安全区伤害：球心在安全圈外持续流失金币（小数累积，保证低 dps 也生效）
    if zone_enable and zone ~= nil then
        for pid, p in pairs(players) do
            local zdx = p.x - zone.x
            local zdy = p.y - zone.y
            if (zdx * zdx + zdy * zdy) > (zone.r * zone.r) then
                p.zone_dmg_acc = p.zone_dmg_acc + zone_dps * dt
                if p.zone_dmg_acc >= 1.0 then
                    local lose = math.floor(p.zone_dmg_acc)
                    p.zone_dmg_acc = p.zone_dmg_acc - lose
                    p.gold = p.gold - lose
                    if p.gold < 0 then p.gold = 0 end
                    p.r = Combat.calc_radius(p.gold, radius_base, radius_k)
                end
            else
                p.zone_dmg_acc = 0
            end
        end
    end

    -- 2. 碰撞检测与吞噬结算
    local eat_events = {}
    local died_events = {}

    local pid_list = {}
    for pid, _ in pairs(players) do
        table.insert(pid_list, pid)
    end

    local count = #pid_list
    for i = 1, count do
        local id1 = pid_list[i]
        local p1 = players[id1]

        if p1 ~= nil then
            for j = i + 1, count do
                local id2 = pid_list[j]
                local p2 = players[id2]

                if p2 ~= nil then
                    local res = Combat.check_eat(p1.x, p1.y, p1.r, p1.gold, p2.x, p2.y, p2.r, p2.gold, eat_ratio)
                    -- 护盾生效中的受害者免于吞噬
                    if res == 1 and world_time < p2.fx_shield_until then
                        res = 0
                    elseif res == 2 and world_time < p1.fx_shield_until then
                        res = 0
                    end

                    if res == 1 then
                        -- p1 吃掉 p2
                        local eaten_gold = p2.gold
                        p1.gold = p1.gold + eaten_gold
                        p1.r = Combat.calc_radius(p1.gold, radius_base, radius_k)

                        -- p2 复活重置
                        p2.gold = initial_gold
                        p2.r = Combat.calc_radius(p2.gold, radius_base, radius_k)
                        local rx, ry = get_random_spawn()
                        p2.x = rx
                        p2.y = ry
                        p2.dx = 0
                        p2.dy = 0

                        table.insert(eat_events, { eater_id = p1.id, victim_id = p2.id, gold = eaten_gold })
                        table.insert(died_events, { victim_id = p2.id, gold = p2.gold, x = p2.x, y = p2.y })

                        persist_settlement(p1, p2)

                    elseif res == 2 then
                        -- p2 吃掉 p1
                        local eaten_gold = p1.gold
                        p2.gold = p2.gold + eaten_gold
                        p2.r = Combat.calc_radius(p2.gold, radius_base, radius_k)

                        -- p1 复活重置
                        p1.gold = initial_gold
                        p1.r = Combat.calc_radius(p1.gold, radius_base, radius_k)
                        local rx, ry = get_random_spawn()
                        p1.x = rx
                        p1.y = ry
                        p1.dx = 0
                        p1.dy = 0

                        table.insert(eat_events, { eater_id = p2.id, victim_id = p1.id, gold = eaten_gold })
                        table.insert(died_events, { victim_id = p1.id, gold = p1.gold, x = p1.x, y = p1.y })

                        persist_settlement(p2, p1)
                    end
                end
            end
        end
    end

    return eat_events, died_events, powerup_events
end

-- 生成场景快照数据
function get_snapshot()
    local snap_list = {}
    for pid, p in pairs(players) do
        local entry = {
            id = p.id,
            name = p.name,
            x = math.floor(p.x * 10) / 10,
            y = math.floor(p.y * 10) / 10,
            gold = p.gold,
            r = math.floor(p.r * 10) / 10
        }
        if p.is_bot then entry.bot = true end
        -- 当前生效中的道具特效（按护盾 > 加速 > 磁铁优先展示）
        if world_time < p.fx_shield_until then
            entry.fx = "shield"
        elseif world_time < p.fx_speed_until then
            entry.fx = "speed"
        elseif world_time < p.fx_magnet_until then
            entry.fx = "magnet"
        end
        table.insert(snap_list, entry)
    end

    -- 合并普通金币豆与金币雨奖励豆（奖励豆吃掉即消失）
    local merged_foods = {}
    for i = 1, #food_coins do
        table.insert(merged_foods, food_coins[i])
    end
    for i = 1, #bonus_food do
        table.insert(merged_foods, bonus_food[i])
    end
    return snap_list, merged_foods, powerups
end

function get_powerups()
    return powerups
end

-- ---- 金币雨（由 timer 心跳驱动） ----

-- 撒落一簇奖励金币豆（必须在主循环调用：回调上下文创建的 table 不能跨帧存活）；
-- 返回事件信息供主循环广播
function spawn_feast()
    local cx = math.random(300, map_width - 300)
    local cy = math.random(300, map_height - 300)
    for i = 1, feast_bonus do
        local bx = cx + math.random(-250, 250)
        local by = cy + math.random(-250, 250)
        if bx < 20 then bx = 20 end
        if bx > map_width - 20 then bx = map_width - 20 end
        if by < 20 then by = 20 end
        if by > map_height - 20 then by = map_height - 20 end
        table.insert(bonus_food, { x = bx, y = by })
    end
    print("[World] Feast! " .. tostring(feast_bonus) .. " bonus pellets around (" .. tostring(cx) .. ", " .. tostring(cy) .. ")")
    return { x = cx, y = cy, count = feast_bonus }
end

-- 主循环读取并清除金币雨到期标记
function pop_feast_due()
    if world_events == nil or world_events.feast_due ~= true then return false end
    world_events.feast_due = false
    return true
end

-- ---- 安全区收缩（由 timer 心跳驱动） ----

-- 主循环读取并清除安全区变化标记
function pop_zone_due()
    if world_events == nil or world_events.zone_due ~= true then return false end
    world_events.zone_due = false
    return true
end

-- 快照/广播用的安全区信息（构造新表，供 C++ 回调与主循环安全读取）
function get_zone_info()
    if zone == nil or not zone_enable then return nil end
    return {
        x = zone.x,
        y = zone.y,
        r = math.floor(zone.r * 10) / 10,
        phase = zone.phase,
        holding = zone.holding,
        next_in = zone.next_in
    }
end

-- timer 心跳（每秒）：排行缓存刷新 + 金币雨 + 安全区调度
-- 回调上下文只做运行时表的字段写（已验证类别），不创建跨帧 table、不做 ws 发送
function on_heartbeat()
    if world_events == nil then return end
    world_events.sec = world_events.sec + 1

    if world_events.sec % 5 == 0 then
        DB.tick_refresh()
    end

    if feast_interval_s > 0 and world_events.sec % feast_interval_s == 0 then
        world_events.feast_due = true
    end

    -- 安全区倒计时（只写字段，事件广播由主循环完成）
    if zone_enable and zone ~= nil then
        zone.next_in = zone.next_in - 1
        if zone.next_in <= 0 then
            if zone.holding then
                -- 最小圈保持结束 → 重置为覆盖全图的初始圈，开始新一轮
                zone.x = map_width / 2
                zone.y = map_height / 2
                zone.r = zone_initial_r
                zone.phase = 0
                zone.holding = false
                zone.next_in = zone_shrink_interval_s
            else
                -- 收缩一阶：半径按比例缩小（圆心固定在地图中央）
                local nr = math.floor(zone.r * zone_shrink_ratio)
                if nr <= zone_min_r then
                    nr = zone_min_r
                    zone.holding = true
                    zone.next_in = zone_hold_s
                else
                    zone.next_in = zone_shrink_interval_s
                end
                zone.r = nr
                zone.phase = zone.phase + 1
            end
            world_events.zone_due = true
        end
    end
end

-- 收到该连接任何消息时刷新活跃时间（心跳超时踢人依据）
function touch_player(connid)
    local pid = conn_to_pid[connid]
    if pid == nil then return end
    local p = players[pid]
    if p ~= nil then
        p.last_seen = os.time()
    end
end

function get_all_players()
    return players
end

-- 服务器统计（HTTP /api/stats 用）
function get_stats()
    local online = 0
    local bots = 0
    for pid, p in pairs(players) do
        if p.is_bot then
            bots = bots + 1
        else
            online = online + 1
        end
    end
    return {
        online = online,
        bots = bots,
        map_width = map_width,
        map_height = map_height,
        uptime_s = math.floor(world_time)
    }
end
