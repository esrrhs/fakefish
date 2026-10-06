package "World"

-- 以下数值配置会在 init() 的 apply_config 中重赋值。fakelua 规定文件级「数值字面量
-- 初始化」的 local 是 static const、禁止再赋值，因此一律先声明 nil（非数值初始化，
-- 不进常量表），初值只通过配置/默认值在 apply_config 里设置。
local map_width = nil
local map_height = nil
local initial_gold = nil
local move_speed = nil
local radius_base = nil
local radius_k = nil
local eat_ratio = nil
-- 同金币兜底吞噬（默认开启）：双方金币相等时按 player_id 裁决，
-- 避免双方都被毒圈扣到 0、半径同为下限时 check_eat 恒返回 0 造成的互相卡死。
local eat_tie_equal = nil

-- 在线玩家表: player_id -> player_record
local players = nil
local conn_to_pid = nil
local pid_to_conn = nil

-- 当前仍连着的 connid 集合（含只建连未登录的连接）：
-- 异步登录查询往返期间连接可能已断开，主循环处理结果前据此判定是否还有效。
local live_conns = nil
-- 同账号在别处登录时，被顶替的旧 connid 队列；主循环通知后主动断开
local pending_kicks = nil
-- 已发踢人通知、下一帧再真正断开的 connid（给发送留出一个 IO 泵周期，
-- 否则 send 入队后同帧 close_connection 会让错误帧来不及下发）
local pending_closes = nil

-- 机器人 ID 段（与 MySQL 自增账号 ID 区隔）
-- 注意：不能在模块级赋常量初值（fakelua JIT 会将全常量赋值的标量标记为 const），
-- 必须声明为 nil 并在 init() 中赋值
local next_bot_id = nil

-- 服务器运行时长（秒），由 update(dt) 累加
local world_time = nil

local food_coins = nil
local max_food = 80        -- 常量：普通金币豆数量，不接受配置重赋值
local food_val = 5         -- 常量：每颗金币豆价值

-- 道具：加速 / 护盾 / 磁铁
local powerups = nil
local powerup_count = nil
local fx_speed_s = nil
local fx_shield_s = nil
local fx_magnet_s = nil

-- 金币雨（feast）事件
local bonus_food = nil
local feast_bonus = 30     -- 常量：每次金币雨豆数
local feast_interval_s = nil
-- 心跳世界事件状态（timer 回调只写这里的字段，send 全部留在主循环）
local world_events = nil

-- 聊天：recent 为最近消息表（在 init 创建）；每条 { name, content, t }
local chat_recent = nil

-- 动态安全区（收缩毒圈）
local bot_max_gold = nil   -- 机器人金币软上限（达上限后不再被动拾取）
local zone = nil
local zone_enable = true   -- bool：非常量规则仅约束数值字面量，可保留
local zone_initial_r = nil
local zone_min_r = nil
local zone_shrink_ratio = nil
local zone_shrink_interval_s = nil
local zone_hold_s = nil
local zone_dps = nil

-- 分裂球（多细胞）
local chat_enable = true
local chat_max_len = nil       -- 单条消息最大字节数
local chat_history = nil       -- 保留最近消息条数
local chat_cooldown_s = nil    -- 同一玩家发消息最小间隔
local split_max_cells = nil    -- 每名玩家最多细胞数
local split_min_gold = nil     -- 细胞金币严格大于此值才可分裂
local split_impulse = nil      -- 分裂新细胞初速度（单位/秒）
local split_friction = nil     -- 冲量衰减系数（越大停得越快）
local merge_cooldown_s = nil   -- 分裂后需经过的秒数，细胞间才允许合体

-- 待发送响应队列（由 NetWs.on_event 回调中入队，主循环 drain）
-- 放在 World 模块的 upvalue 中，绕过 NetWs 回调上下文的 const 限制
-- 注意：必须在 init() 中初始化，不能在模块级别直接赋值为 {}，
-- 否则 fakelua JIT 会将其标记为 const table，在 C++ 回调中 table.insert 会报错
local pending_responses = nil

-- 启动时传入的游戏配置表（热更后用于重放配置标量）
local game_cfg = nil

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

-- 应用配置标量（init 与 hotfix_restore 共用）
-- yaml 配置为权威；未配置项取当前（新）代码里的默认值——热更后改 lua 默认值即生效
local function apply_config(cfg)
    map_width = cfg["map_width"] or 2000
    map_height = cfg["map_height"] or 2000
    initial_gold = cfg["initial_gold"] or 100
    move_speed = cfg["move_speed"] or 160
    radius_base = cfg["radius_base"] or 15
    radius_k = cfg["radius_k"] or 2.5
    eat_ratio = cfg["eat_ratio"] or 1.05
    eat_tie_equal = cfg["eat_tie_equal"]
    if eat_tie_equal == nil then eat_tie_equal = true end
    powerup_count = cfg["powerup_count"] or 5
    fx_speed_s = cfg["fx_speed_s"] or 6
    fx_shield_s = cfg["fx_shield_s"] or 5
    fx_magnet_s = cfg["fx_magnet_s"] or 8
    feast_interval_s = cfg["feast_interval_s"] or 0

    chat_enable = cfg["chat_enable"]
    if chat_enable == nil then chat_enable = true end
    chat_max_len = cfg["chat_max_len"] or 80
    chat_history = cfg["chat_history"] or 20
    chat_cooldown_s = cfg["chat_cooldown_s"] or 2

    zone_enable = cfg["zone_enable"]
    if zone_enable == nil then zone_enable = true end
    bot_max_gold = cfg["bot_max_gold"] or 2000
    zone_initial_r = cfg["zone_initial_radius"] or 1500
    zone_min_r = cfg["zone_min_radius"] or 250
    zone_shrink_ratio = cfg["zone_shrink_ratio"] or 0.7
    zone_shrink_interval_s = cfg["zone_shrink_interval_s"] or 60
    zone_hold_s = cfg["zone_hold_s"] or 30
    zone_dps = cfg["zone_dps"] or 20

    split_max_cells = cfg["split_max_cells"] or 8
    split_min_gold = cfg["split_min_gold"] or 100
    split_impulse = cfg["split_impulse"] or 480
    split_friction = cfg["split_friction"] or 3.2
    merge_cooldown_s = cfg["merge_cooldown_s"] or 12
end

function init(cfg)
    players = {}
    conn_to_pid = {}
    pid_to_conn = {}
    live_conns = {}
    pending_kicks = {}
    pending_closes = {}
    pending_responses = {}
    next_bot_id = 800000
    world_time = 0
    if cfg == nil then cfg = {} end
    game_cfg = cfg
    apply_config(cfg)
    bonus_food = {}
    world_events = { sec = 0, feast = nil }
    chat_recent = {}

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

-- 热更：保存全部运行时状态。
-- 注意：必须用「空构造器 + 动态赋值」得到 plain table。静态 key 的构造器会被编译器
-- 特化成 spec 表，其 get 函数在本模块 .so 里——.so 卸载后，新代码读这张快照就会跳进
-- 已卸载的旧代码。快照值里的旧 spec 表，restore 侧只用 pairs 遍历（直接读内部数组，
-- 不触发 spec_get 间接调用）。
function hotfix_save()
    local s = {}
    s["game_cfg"] = game_cfg
    s["players"] = players
    s["conn_to_pid"] = conn_to_pid
    s["pid_to_conn"] = pid_to_conn
    s["live_conns"] = live_conns
    s["pending_kicks"] = pending_kicks
    s["pending_closes"] = pending_closes
    s["next_bot_id"] = next_bot_id
    s["world_time"] = world_time
    s["food_coins"] = food_coins
    s["powerups"] = powerups
    s["bonus_food"] = bonus_food
    s["world_events"] = world_events
    s["chat_recent"] = chat_recent
    s["zone"] = zone
    s["pending_responses"] = pending_responses
    return s
end

-- 深拷贝：在新 .so 上下文重建所有表。空 {} + 动态赋值产出 plain table，
-- 其访问走 hash 路径（内联代码，没有指向旧 .so 的间接调用）。
local function migrate(v)
    if type(v) == "table" then
        local c = {}
        for k, x in pairs(v) do
            c[k] = migrate(x)
        end
        return c
    end
    return v
end

-- 热更：新版本代码把旧世界整体迁移重建后接回，再重放配置标量
function hotfix_restore(s)
    if s == nil then return end
    game_cfg = migrate(s["game_cfg"])
    if game_cfg ~= nil then
        apply_config(game_cfg)
    end
    players = migrate(s["players"])
    conn_to_pid = migrate(s["conn_to_pid"])
    pid_to_conn = migrate(s["pid_to_conn"])
    live_conns = migrate(s["live_conns"])
    if live_conns == nil then live_conns = {} end
    pending_kicks = migrate(s["pending_kicks"])
    if pending_kicks == nil then pending_kicks = {} end
    pending_closes = migrate(s["pending_closes"])
    if pending_closes == nil then pending_closes = {} end
    next_bot_id = s["next_bot_id"]
    world_time = s["world_time"]
    food_coins = migrate(s["food_coins"])
    powerups = migrate(s["powerups"])
    bonus_food = migrate(s["bonus_food"])
    world_events = migrate(s["world_events"])
    chat_recent = migrate(s["chat_recent"])
    zone = migrate(s["zone"])
    pending_responses = migrate(s["pending_responses"])
end

function get_map_info()
    return {
        width = map_width,
        height = map_height
    }
end

-- 合并普通金币豆与金币雨奖励豆（供 Bot AI 觅食感知；快照也用同一视图）
function get_foods()
    local merged = {}
    for i = 1, #food_coins do
        table.insert(merged, food_coins[i])
    end
    if bonus_food ~= nil then
        for i = 1, #bonus_food do
            table.insert(merged, bonus_food[i])
        end
    end
    return merged
end

-- 随机一个空位：优先落在安全区内且不与任何现存细胞交叠，
-- 多次尝试失败则退化为最后一次随机点（极端拥挤时不应卡住进场/复活）
function get_random_spawn()
    local margin = 100
    local sr = Combat.calc_radius(initial_gold, radius_base, radius_k)

    local rx = 0
    local ry = 0
    for try_n = 1, 16 do
        rx = math.random(margin, map_width - margin)
        ry = math.random(margin, map_height - margin)

        if zone_enable and zone ~= nil then
            local zdx = rx - zone.x
            local zdy = ry - zone.y
            if (zdx * zdx + zdy * zdy) > (zone.r - sr - 30) * (zone.r - sr - 30) then
                -- 候选点在安全区外或贴边，重抽
                if try_n < 16 then
                    -- 直接以圈心附近重试，提高收缩后期的命中率
                    local ang = math.random() * 6.28318
                    local rr = math.random(0, math.max(0, math.floor(zone.r - sr - 60)))
                    rx = zone.x + math.floor(math.cos(ang) * rr)
                    ry = zone.y + math.floor(math.sin(ang) * rr)
                    if rx < margin then rx = margin end
                    if rx > map_width - margin then rx = map_width - margin end
                    if ry < margin then ry = margin end
                    if ry > map_height - margin then ry = map_height - margin end
                end
            end
        end

        local clear = true
        for pid, p in pairs(players) do
            for ci = 1, #p.parts do
                local oc = p.parts[ci]
                local dx = rx - oc.x
                local dy = ry - oc.y
                local min_d = oc.r + sr + 24
                if (dx * dx + dy * dy) < min_d * min_d then
                    clear = false
                    break
                end
            end
            if not clear then break end
        end

        if clear then return rx, ry end
    end
    return rx, ry
end

-- 构造一个细胞（必须在主循环上下文调用）
-- gold 为整数；vx/vy 为分裂冲量速度；born 为细胞产生的世界时间（合体冷却依据）
local function make_cell(x, y, gold, vx, vy, born)
    return {
        x = x,
        y = y,
        gold = gold,
        r = Combat.calc_radius(gold, radius_base, radius_k),
        vx = vx or 0,
        vy = vy or 0,
        born = born or world_time,
        zone_acc = 0,
        alive = true
    }
end

-- 玩家全部细胞的金币总和
local function total_gold(p)
    local sum = 0
    for i = 1, #p.parts do
        sum = sum + p.parts[i].gold
    end
    return sum
end

-- 连接建立/断开登记（WS conn/close 事件调用）
function mark_conn(connid)
    if live_conns == nil then live_conns = {} end
    live_conns[connid] = true
end

function unmark_conn(connid)
    if live_conns == nil then return end
    live_conns[connid] = nil
end

function is_conn_alive(connid)
    if live_conns == nil then return false end
    return live_conns[connid] ~= nil
end

-- 同账号在新连接登录时，旧连接进入待踢队列（主循环发通知后主动断开）
function enqueue_kick(connid)
    if pending_kicks == nil then pending_kicks = {} end
    table.insert(pending_kicks, connid)
end

function drain_pending_kicks()
    if pending_kicks == nil or #pending_kicks == 0 then return nil end
    local result = pending_kicks
    pending_kicks = {}
    return result
end

-- 踢人两阶段：本帧发通知入队，下一帧由主循环真正断开
function enqueue_pending_close(connid)
    if pending_closes == nil then pending_closes = {} end
    table.insert(pending_closes, connid)
end

function drain_pending_closes()
    if pending_closes == nil or #pending_closes == 0 then return nil end
    local result = pending_closes
    pending_closes = {}
    return result
end

-- 玩家全部细胞金币总和（供登录响应等外部调用）
function player_total_gold(p)
    if p == nil then return 0 end
    return total_gold(p)
end

function initial_gold_value()
    return initial_gold
end

-- 玩家进场
function add_player(connid, account)
    local pid = account.id
    local spawn_x, spawn_y = get_random_spawn()
    local gold = account.gold or initial_gold

    -- 会话冲突处理 1：同一账号已在另一连接在线 → 旧连接让位（主循环通知并断开），
    -- 不在这里直接操作 ws（recv 回调上下文禁止发送/嵌套派发 close）
    local prev_conn = pid_to_conn[pid]
    if prev_conn ~= nil and prev_conn ~= connid then
        table.insert(pending_kicks, prev_conn)
        conn_to_pid[prev_conn] = nil
    end

    -- 会话冲突处理 2：同一连接此前在玩另一个账号 → 旧账号先落盘离场，
    -- 否则其实体会成为无人控制、永不保存的幽灵
    local prev_pid = conn_to_pid[connid]
    if prev_pid ~= nil and prev_pid ~= pid then
        local prev_p = players[prev_pid]
        if prev_p ~= nil then
            DB.update_gold(prev_p.name, prev_p.id, total_gold(prev_p))
        end
        players[prev_pid] = nil
        pid_to_conn[prev_pid] = nil
    end

    -- 同账号已有实体（旧会话被顶或同连接重登）：覆盖前先把旧实体金币落盘，
    -- 新会话继承最新累计值（DB.update_gold 同时维护 best_gold）
    local existing_p = players[pid]
    if existing_p ~= nil then
        DB.update_gold(existing_p.name, existing_p.id, total_gold(existing_p))
    end

    local p = {
        id = pid,
        connid = connid,
        name = account.username,
        dx = 0,
        dy = 0,
        last_seen = os.time(),
        fx_speed_until = 0,
        fx_shield_until = 0,
        fx_magnet_until = 0,
        pending_split = false,
        last_split = -merge_cooldown_s,
        parts = { make_cell(spawn_x, spawn_y, gold, 0, 0, 0) }
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
        dx = 0,
        dy = 0,
        is_bot = true,
        ai_timer = 0,
        ai_dx = 0,
        ai_dy = 0,
        fx_speed_until = 0,
        fx_shield_until = 0,
        fx_magnet_until = 0,
        pending_split = false,
        last_split = -merge_cooldown_s,
        parts = { make_cell(spawn_x, spawn_y, initial_gold, 0, 0, 0) }
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
        -- 离场落盘金币（全部细胞总和）
        local total = total_gold(p)
        DB.update_gold(p.name, p.id, total)
        print("[World] Player " .. p.name .. " saved gold: " .. tostring(total) .. " and left.")
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

-- 请求分裂（C++ recv 回调中调用：只置标记，真正的分裂在主循环 World.update 完成，
-- 因为新细胞 table 必须在主循环上下文创建才能跨帧存活）
function request_split(connid)
    local pid = conn_to_pid[connid]
    if pid == nil then return end
    local p = players[pid]
    if p ~= nil then
        p.pending_split = true
    end
end

-- ---- 世界聊天 ----

-- 去掉首尾空白
local function trim_chat(s)
    local a = string.gsub(s, "^%s+", "")
    local b = string.gsub(a, "%s+$", "")
    return b
end

-- 提交聊天（C++ recv 回调中调用：校验、节流、写入 recent 并入广播队列，
-- 真正的 ws 发送全部留在主循环，与 feast/zone 同一模式）
function submit_chat(connid, content)
    if not chat_enable or chat_recent == nil then return end
    local pid = conn_to_pid[connid]
    if pid == nil then return end
    local p = players[pid]
    if p == nil then return end

    -- 节流：记录上次发言的世界时间（主循环读 world_time 时为同一个值，安全）
    if p.last_chat ~= nil and (world_time - p.last_chat) < chat_cooldown_s then
        return
    end

    local text = trim_chat(content)
    if #text == 0 then return end
    if #text > chat_max_len then
        text = string.sub(text, 1, chat_max_len)
    end

    p.last_chat = world_time
    local entry = { name = p.name, content = text, t = math.floor(world_time) }
    table.insert(chat_recent, entry)
    if #chat_recent > chat_history then
        table.remove(chat_recent, 1)
    end

    -- 入待广播队列（主循环 drain 后发给所有人）
    table.insert(pending_responses, { connid = -1, tbl = {
        type = "chat",
        name = p.name,
        content = text
    } })
end

-- 新进场玩家读取最近聊天（登录后由前端主动请求，或直接随首帧下发）
function get_recent_chat()
    if chat_recent == nil then return {} end
    local out = {}
    for i = 1, #chat_recent do
        table.insert(out, chat_recent[i])
    end
    return out
end

function get_player_by_conn(connid)
    local pid = conn_to_pid[connid]
    if pid == nil then return nil end
    return players[pid]
end

function get_conn_by_pid(pid)
    return pid_to_conn[pid]
end

-- ---- 分裂 ----

-- 执行分裂（必须在主循环调用）：每个达条件的细胞分出一半金币给新细胞，
-- 新细胞沿当前移动方向获得冲量；受 split_max_cells 上限约束
local function do_split(p)
    local ncells = #p.parts
    if ncells >= split_max_cells then return end

    local sdx = p.dx
    local sdy = p.dy
    if sdx == 0 and sdy == 0 then
        -- 没有移动意图时默认向上分裂
        sdx = 0
        sdy = -1
    end

    local new_cells = {}
    for i = 1, ncells do
        if #p.parts + #new_cells >= split_max_cells then break end
        local c = p.parts[i]
        if c.gold > split_min_gold then
            local half = math.floor(c.gold / 2)
            if half >= 1 then
                c.gold = c.gold - half
                c.r = Combat.calc_radius(c.gold, radius_base, radius_k)
                local nx = c.x + sdx * (c.r + 6)
                local ny = c.y + sdy * (c.r + 6)
                local nc = make_cell(nx, ny, half, sdx * split_impulse, sdy * split_impulse, world_time)
                table.insert(new_cells, nc)
            end
        end
    end

    if #new_cells > 0 then
        for i = 1, #new_cells do
            table.insert(p.parts, new_cells[i])
        end
        p.last_split = world_time
        print("[World] " .. p.name .. " split into " .. tostring(#p.parts) .. " cells")
    end
end

-- 吞噬结算落盘（机器人不落盘；只有完全淘汰才记 kills/deaths）
local function settle_persist(eater_p, victim_p, full)
    if not eater_p.is_bot then
        DB.update_gold(eater_p.name, eater_p.id, total_gold(eater_p))
        if full then DB.add_kill(eater_p.name) end
    end
    if not victim_p.is_bot then
        DB.update_gold(victim_p.name, victim_p.id, total_gold(victim_p))
        if full then DB.add_death(victim_p.name) end
    end
end

-- E（{pp,c}）吃掉 V 的一个细胞；最后一个细胞被吃 → 整人复活，否则只是部分损失
local function eat_one_cell(E, V, eat_events, died_events)
    local eaten_gold = V.c.gold
    local vp = V.pp

    E.c.gold = E.c.gold + eaten_gold
    E.c.r = Combat.calc_radius(E.c.gold, radius_base, radius_k)

    -- 按对象身份定位被吃细胞的下标后移除
    local ri = 0
    for k = 1, #vp.parts do
        if vp.parts[k] == V.c then ri = k end
    end
    if ri > 0 then table.remove(vp.parts, ri) end
    V.c.alive = false

    if #vp.parts == 0 then
        local rx, ry = get_random_spawn()
        vp.parts = { make_cell(rx, ry, initial_gold, 0, 0, world_time) }
        vp.dx = 0
        vp.dy = 0
        table.insert(eat_events, {
            eater_id = E.pp.id, victim_id = vp.id, gold = eaten_gold, full = true
        })
        table.insert(died_events, {
            victim_id = vp.id, gold = initial_gold, x = rx, y = ry
        })
        settle_persist(E.pp, vp, true)
    else
        table.insert(eat_events, {
            eater_id = E.pp.id, victim_id = vp.id, gold = eaten_gold, partial = true
        })
        settle_persist(E.pp, vp, false)
    end
end

-- 逻辑帧更新（update 过大曾触发 "too many registers"，各阶段拆分为独立函数）

-- 阶段 0+1：处理分裂请求 + 拾取金币（每细胞独立）
local function step_split_and_pickup()
    for pid, p in pairs(players) do
        if p.pending_split then
            p.pending_split = false
            do_split(p)
        end
    end

    for pid, p in pairs(players) do
        -- 机器人达到金币软上限后不再被动拾取，避免无限膨胀；吞噬玩家不受影响
        if not (p.is_bot and total_gold(p) >= bot_max_gold) then
          for ci = 1, #p.parts do
            local c = p.parts[ci]
            local pickup_r = c.r
            if world_time < p.fx_magnet_until then
                pickup_r = c.r * 4
            end
            for fi = 1, #food_coins do
                local f = food_coins[fi]
                local fdx = c.x - f.x
                local fdy = c.y - f.y
                if (fdx * fdx + fdy * fdy) < (pickup_r * pickup_r) then
                    c.gold = c.gold + food_val
                    c.r = Combat.calc_radius(c.gold, radius_base, radius_k)
                    f.x = math.random(50, map_width - 50)
                    f.y = math.random(50, map_height - 50)
                end
            end
            -- 金币雨奖励豆：吃掉即移除（while 条件每轮重算 #bonus_food）
            local bi = 1
            while bi <= #bonus_food do
                local f = bonus_food[bi]
                local fdx = c.x - f.x
                local fdy = c.y - f.y
                if (fdx * fdx + fdy * fdy) < (pickup_r * pickup_r) then
                    c.gold = c.gold + food_val
                    c.r = Combat.calc_radius(c.gold, radius_base, radius_k)
                    table.remove(bonus_food, bi)
                else
                    bi = bi + 1
                end
            end
          end
        end
    end
end

-- 阶段 1.5：拾取道具（任一细胞碰到即对整人生效），返回事件列表
local function step_pickup_powerups()
    local powerup_events = {}
    for pid, p in pairs(players) do
        for ci = 1, #p.parts do
            local c = p.parts[ci]
            for pi = 1, #powerups do
                local pw = powerups[pi]
                local pdx = c.x - pw.x
                local pdy = c.y - pw.y
                if (pdx * pdx + pdy * pdy) < (c.r * c.r) then
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
    end
    return powerup_events
end

-- 阶段 2：移动积分（方向 + 分裂冲量衰减）+ 边界
local merge_pull = 2.0  -- 冷却后细胞向群体质心吸附的速率（1/秒）
local function step_movement(dt)
    for pid, p in pairs(players) do
        -- 全部细胞都过合体冷却 → 计算金币加权质心，稍后施加吸附
        local all_old = true
        local gsum = 0
        local wxs = 0
        local wys = 0
        for ci = 1, #p.parts do
            local c0 = p.parts[ci]
            if world_time - c0.born < merge_cooldown_s then
                all_old = false
            end
            gsum = gsum + c0.gold
            wxs = wxs + c0.x * c0.gold
            wys = wys + c0.y * c0.gold
        end
        local ux = 0
        local uy = 0
        if all_old and gsum > 0 then
            ux = wxs / gsum
            uy = wys / gsum
        end

        for ci = 1, #p.parts do
            local c = p.parts[ci]
            local speed_factor = 1.0 / (1.0 + (c.r - radius_base) * 0.003)
            if world_time < p.fx_speed_until then
                speed_factor = speed_factor * 1.5
            end
            if p.dx ~= 0 or p.dy ~= 0 or c.vx ~= 0 or c.vy ~= 0 then
                local cur_speed = move_speed * speed_factor
                c.x = c.x + p.dx * cur_speed * dt + c.vx * dt
                c.y = c.y + p.dy * cur_speed * dt + c.vy * dt

                -- 冲量摩擦衰减
                local decay = math.exp(-split_friction * dt)
                c.vx = c.vx * decay
                c.vy = c.vy * decay
                if math.abs(c.vx) < 1 then c.vx = 0 end
                if math.abs(c.vy) < 1 then c.vy = 0 end
            end

            -- 冷却结束：温和吸附向质心，帮助细胞靠拢合体（Bot 分裂后也靠它回归）
            if all_old and #p.parts > 1 then
                c.x = c.x + (ux - c.x) * merge_pull * dt
                c.y = c.y + (uy - c.y) * merge_pull * dt
            end

            -- 边界限制
            if c.x < c.r then c.x = c.r end
            if c.x > map_width - c.r then c.x = map_width - c.r end
            if c.y < c.r then c.y = c.r end
            if c.y > map_height - c.r then c.y = map_height - c.r end
        end
    end
end

-- 阶段 2.5：安全区伤害（每细胞独立，小数累积掉金币）
local function step_zone_damage(dt)
    if not zone_enable or zone == nil then return end
    for pid, p in pairs(players) do
        for ci = 1, #p.parts do
            local c = p.parts[ci]
            local zdx = c.x - zone.x
            local zdy = c.y - zone.y
            if (zdx * zdx + zdy * zdy) > (zone.r * zone.r) then
                c.zone_acc = c.zone_acc + zone_dps * dt
                if c.zone_acc >= 1.0 then
                    local lose = math.floor(c.zone_acc)
                    c.zone_acc = c.zone_acc - lose
                    c.gold = c.gold - lose
                    if c.gold < 0 then c.gold = 0 end
                    c.r = Combat.calc_radius(c.gold, radius_base, radius_k)
                end
            else
                c.zone_acc = 0
            end
        end
    end
end

-- 阶段 2.6：同体细胞合体（冷却后交叠即合并，金币加权取中心）
local function step_merge()
    for pid, p in pairs(players) do
        local merged_any = true
        while merged_any do
            merged_any = false
            local n = #p.parts
            local found = false
            local i = 1
            while i <= n and not found do
                local j = i + 1
                while j <= n and not found do
                    local a = p.parts[i]
                    local b = p.parts[j]
                    if world_time - a.born >= merge_cooldown_s
                       and world_time - b.born >= merge_cooldown_s then
                        local mdx = a.x - b.x
                        local mdy = a.y - b.y
                        local md = math.sqrt(mdx * mdx + mdy * mdy)
                        if md < a.r + b.r then
                            local g = a.gold + b.gold
                            local mx = 0
                            local my = 0
                            if g > 0 then
                                mx = (a.x * a.gold + b.x * b.gold) / g
                                my = (a.y * a.gold + b.y * b.gold) / g
                            else
                                -- 两细胞金币都被毒圈扣到 0 时，金币加权中心会除零得到 NaN。
                                -- NaN 会骗过后续所有比较（边界钳制、吞噬判定里 NaN < x 恒为
                                -- false），细胞将永久卡死并随快照广播污染所有客户端，
                                -- 因此退化为算术平均。
                                mx = (a.x + b.x) / 2
                                my = (a.y + b.y) / 2
                            end
                            -- 先删大下标，避免小下标移位
                            table.remove(p.parts, j)
                            table.remove(p.parts, i)
                            -- born 继承较早者：两个亲代都已过冷却，合体产物也应立刻
                            -- 满足合体条件，否则 8 细胞连锁合回 1 要逐级再等 merge_cooldown_s
                            local inherited_born = a.born
                            if b.born < inherited_born then inherited_born = b.born end
                            table.insert(p.parts, make_cell(mx, my, g, 0, 0, inherited_born))
                            found = true
                            merged_any = true
                        end
                    end
                    j = j + 1
                end
                i = i + 1
            end
        end
    end
end

-- 阶段 3：跨玩家细胞碰撞检测与吞噬结算，返回 eat_events, died_events
local function step_combat()
    local eat_events = {}
    local died_events = {}

    -- 拍平成细胞列表（在合体之后构建，无陈旧细胞）
    local world_cells = {}
    for pid, p in pairs(players) do
        for i = 1, #p.parts do
            table.insert(world_cells, { pp = p, c = p.parts[i] })
        end
    end

    local cc = #world_cells
    for i = 1, cc do
        local E = world_cells[i]
        if E.c.alive then
            for j = i + 1, cc do
                local V = world_cells[j]
                -- E.c.alive 必须在每次配对时重查：E 可能在上一轮配对中被 V 吃掉，
                -- 此时 E.c 已脱离 p.parts（金币已结算给吃掉它的一方）。若继续拿这个
                -- 死细胞参与判定，它的金币会被第二次计入 → 金币凭空增发或凭空消失。
                if E.c.alive and V.c.alive and E.pp.id ~= V.pp.id then
                    local res = Combat.check_eat(
                        E.c.x, E.c.y, E.c.r, E.c.gold,
                        V.c.x, V.c.y, V.c.r, V.c.gold, eat_ratio,
                        eat_tie_equal, E.pp.id, V.pp.id)
                    -- 护盾生效中的受害者免于吞噬
                    if res == 1 and world_time < V.pp.fx_shield_until then
                        res = 0
                    elseif res == 2 and world_time < E.pp.fx_shield_until then
                        res = 0
                    end

                    if res == 1 then
                        eat_one_cell(E, V, eat_events, died_events)
                    elseif res == 2 then
                        eat_one_cell(V, E, eat_events, died_events)
                    end
                end
            end
        end
    end

    return eat_events, died_events
end

-- 逻辑帧更新
-- dt: 秒 (e.g. 0.05)
-- 返回事件列表: eat_events, died_events, powerup_events
function update(dt)
    world_time = world_time + dt

    step_split_and_pickup()

    local powerup_events = step_pickup_powerups()

    step_movement(dt)

    step_zone_damage(dt)
    step_merge()
    local eat_events, died_events = step_combat()

    return eat_events, died_events, powerup_events
end

-- 生成场景快照数据（每个细胞一条，cell 为细胞序号）
function get_snapshot()
    local snap_list = {}
    for pid, p in pairs(players) do
        -- 当前生效中的道具特效（按护盾 > 加速 > 磁铁优先展示）
        local fx = nil
        if world_time < p.fx_shield_until then
            fx = "shield"
        elseif world_time < p.fx_speed_until then
            fx = "speed"
        elseif world_time < p.fx_magnet_until then
            fx = "magnet"
        end
        for ci = 1, #p.parts do
            local c = p.parts[ci]
            local entry = {
                id = p.id,
                cell = ci,
                name = p.name,
                x = math.floor(c.x * 10) / 10,
                y = math.floor(c.y * 10) / 10,
                gold = c.gold,
                r = math.floor(c.r * 10) / 10
            }
            if p.is_bot then entry.bot = true end
            if fx ~= nil then entry.fx = fx end
            table.insert(snap_list, entry)
        end
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
