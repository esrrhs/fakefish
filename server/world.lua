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

local food_coins = nil
local max_food = 80
local food_val = 5

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

function init(cfg)
    players = {}
    conn_to_pid = {}
    pid_to_conn = {}
    pending_responses = {}
    if cfg == nil then cfg = {} end
    map_width = cfg["map_width"] or 2000
    map_height = cfg["map_height"] or 2000
    initial_gold = cfg["initial_gold"] or 100
    move_speed = cfg["move_speed"] or 160
    radius_base = cfg["radius_base"] or 15
    radius_k = cfg["radius_k"] or 2.5
    eat_ratio = cfg["eat_ratio"] or 1.05

    spawn_foods()
    print("[World] Initialized with map " .. tostring(map_width) .. "x" .. tostring(map_height) .. ", " .. tostring(max_food) .. " gold pellets")
end

function get_map_info()
    return {
        width = map_width,
        height = map_height
    }
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
        r = r
    }

    players[pid] = p
    conn_to_pid[connid] = pid
    pid_to_conn[pid] = connid

    print("[World] Player " .. account.username .. " (ID: " .. tostring(pid) .. ") joined the game.")
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

-- 逻辑帧更新
-- dt: 秒 (e.g. 0.05)
-- 返回事件列表: eat_events, died_events
function update(dt)
    -- 1. 拾取地面积分金币
    for pid, p in pairs(players) do
        for fi = 1, #food_coins do
            local f = food_coins[fi]
            local fdx = p.x - f.x
            local fdy = p.y - f.y
            if (fdx * fdx + fdy * fdy) < (p.r * p.r) then
                p.gold = p.gold + food_val
                p.r = Combat.calc_radius(p.gold, radius_base, radius_k)
                f.x = math.random(50, map_width - 50)
                f.y = math.random(50, map_height - 50)
            end
        end
    end

    -- 2. 玩家移动积分与边界约束
    for pid, p in pairs(players) do
        if p.dx ~= 0 or p.dy ~= 0 then
            -- 大球移动略慢，体验更平衡：实际速度 = base_speed / (1 + r * 0.005)
            local speed_factor = 1.0 / (1.0 + (p.r - radius_base) * 0.003)
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

                        DB.update_gold(p1.name, p1.id, p1.gold)
                        DB.update_gold(p2.name, p2.id, p2.gold)

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

                        DB.update_gold(p1.name, p1.id, p1.gold)
                        DB.update_gold(p2.name, p2.id, p2.gold)
                    end
                end
            end
        end
    end

    return eat_events, died_events
end

-- 生成场景快照数据
function get_snapshot()
    local snap_list = {}
    for pid, p in pairs(players) do
        table.insert(snap_list, {
            id = p.id,
            name = p.name,
            x = math.floor(p.x * 10) / 10,
            y = math.floor(p.y * 10) / 10,
            gold = p.gold,
            r = math.floor(p.r * 10) / 10
        })
    end
    return snap_list, food_coins
end

function get_all_players()
    return players
end
