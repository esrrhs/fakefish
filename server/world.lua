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

-- 当前仍连着的连接（含只建连未登录的连接）：connid -> 建连时间戳。
-- 异步登录查询往返期间连接可能已断开，主循环处理结果前据此判定是否还有效；
-- 建连时间也用于踢除迟迟不登录的挂起连接。
local live_conns = nil
-- 同账号在别处登录时，被顶替的旧 connid 队列；主循环通知后主动断开
local pending_kicks = nil
-- 已发踢人通知、下一帧再真正断开的 connid（给发送留出一个 IO 泵周期，
-- 否则 send 入队后同帧 close_connection 会让错误帧来不及下发）
local pending_closes = nil
-- 运维口主动下线队列：元素 { connid=, reason= }，主循环通知自定义原因后下一帧断开
local pending_admin_kicks = nil

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
local zone_wait_s = nil

-- 一局制（match）：一局内安全区收缩到 0，最后一个存活者「吃鸡」，结算展示后
-- 自动开新局。局状态全部走 Store（数字标量，跨帧安全）：
--   world.match_state      1=进行中 2=结算中
--   world.match_id         局号，从 1 开始
--   world.match_start_at   本局开始的世界时间（秒）
--   world.match_over_at    本局结算开始的世界时间（秒）
--   world.match_winner_id  胜者 pid（0=无胜者，如全员同时出局）
--   world.match_peak_alive 本局存活人数峰值：只有「真的有过对手」的局才判胜，
--                          否则单人测试服一进场就立刻结束、不断重置世界
-- 玩家出局标记 p.alive=false 随 players 表一起 JSON 持久化（布尔值安全）。
-- 注意：开关不用文件级 bool——fakelua 把 `local x = true` 当编译期常量，
-- apply_config 里按配置重赋值不生效，帧内读到的还是声明初值。因此开关以
-- 数字 1/0 存 Store（world.match_enable），读取统一走 match_on()。
local match_duration_s = nil
local match_result_s = nil

-- 分裂球（多细胞）
local chat_enable = true
local chat_max_len = nil       -- 单条消息最大字符数（UTF-8 字符）
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

-- PCG 独立随机流（fakelua random.new，每流 64-bit 独立状态）：
--   rng_spawn：出生点 / 金币豆与道具的生成、换位补给
--   rng_feast：金币雨撒豆
-- Bot 的决策随机由 Bot 模块自持第三路（rng_ai）。
-- 分流避免「一个系统消耗随机数就改变所有其他系统序列」的跨系统关联；
-- 状态经 get_state/set_state(hex) 可随热更快照存取，为确定性回放铺路。
local rng_spawn = nil
local rng_feast = nil

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
        local rx = rng_spawn:int(50, map_width - 50)
        local ry = rng_spawn:int(50, map_height - 50)
        table.insert(food_coins, { x = rx, y = ry })
    end
end

-- 轮转生成三种道具，保证每种都覆盖到
local powerup_kinds = { "speed", "shield", "magnet" }

function spawn_powerups()
    powerups = {}
    for i = 1, powerup_count do
        local rx = rng_spawn:int(60, map_width - 60)
        local ry = rng_spawn:int(60, map_height - 60)
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
    zone_wait_s = cfg["zone_wait_s"] or 15

    local me = cfg["match_enable"]
    if me == nil then
        Store.set("world.match_enable", 1)
    elseif me then
        Store.set("world.match_enable", 1)
    else
        Store.set("world.match_enable", 0)
    end
    match_duration_s = cfg["match_duration_s"] or 90
    match_result_s = cfg["match_result_s"] or 8
    -- 数值标量同样入库一份：热更路径 hotfix_restore 会重放配置，主循环与
    -- timer 回调都可能先于下一帧读到新值
    Store.set("world.match_duration_s", match_duration_s)
    Store.set("world.match_result_s", match_result_s)

    split_max_cells = cfg["split_max_cells"] or 8
    split_min_gold = cfg["split_min_gold"] or 100
    split_impulse = cfg["split_impulse"] or 480
    split_friction = cfg["split_friction"] or 3.2
    merge_cooldown_s = cfg["merge_cooldown_s"] or 12
end

-- ---- 一局制（match）----

-- 一局制开关（1/0，存 Store 避免 bool 常量的跨帧坑）
local function match_on()
    return Store.get("world.match_enable") == 1
end

-- 局时长/结算时长同样从 Store 读：文件级数值标量跨帧的语义不保险
-- （world_time 之类的既有标量也是入库的），统一走 Store 最稳
local function match_duration()
    local v = Store.get("world.match_duration_s")
    if v == nil then return 90 end
    return v
end

local function match_result()
    local v = Store.get("world.match_result_s")
    if v == nil then return 8 end
    return v
end

-- 存活人数与本局峰值（峰值用于判断「这局真的有对手」）
local function count_alive()
    local n = 0
    local last = 0
    for pid, p in pairs(players) do
        if p.alive ~= false then
            n = n + 1
            last = pid
        end
    end
    return n, last
end

-- 淘汰一名玩家：清空细胞、标记出局。本局不再进场，等下一局自动复活。
-- reason 仅用于日志/事件区分（"eaten" 被吞噬 / "zone" 被安全区毒死）。
-- 注意：结算（落盘 + deaths 计数）由调用方在清空 parts 前完成。
local function eliminate_player(p, reason, died_events)
    if p == nil then return end
    if p.alive == false then return end
    p.parts = {}
    p.alive = false
    p.dx = 0
    p.dy = 0
    if died_events ~= nil then
        table.insert(died_events, {
            victim_id = p.id,
            gold = 0,
            x = 0,
            y = 0,
            out = true
        })
    end
    print("[World] " .. tostring(p.name) .. " is OUT (" .. tostring(reason) .. ")")
end

-- 当前存活玩家中金币最高者（到点未分胜负时按它判胜）
local function richest_alive()
    local best_pid = 0
    local best_gold = -1
    for pid, p in pairs(players) do
        if p.alive ~= false then
            local g = total_gold(p)
            if g > best_gold then
                best_gold = g
                best_pid = pid
            end
        end
    end
    return best_pid
end

-- 开新局：重置场景、安全区与全体玩家
function start_match()
    local mid = (Store.get("world.match_id") or 0) + 1
    Store.set("world.match_id", mid)
    Store.set("world.match_state", 1)
    Store.set("world.match_start_at", world_time)
    Store.set("world.match_winner_id", 0)
    Store.set("world.match_peak_alive", 0)

    -- 安全区回到覆盖全图的初始圈
    zone.x = map_width / 2
    zone.y = map_height / 2
    zone.r = zone_initial_r
    zone.phase = 0
    zone.holding = false
    zone.next_in = zone_wait_s

    -- 场景重置：豆子与道具重刷，金币雨残豆清掉
    spawn_foods()
    spawn_powerups()
    bonus_food = {}

    -- 全员复活：金币回到初始值、位置重抽、特效清空
    for pid, p in pairs(players) do
        local sx, sy = get_random_spawn()
        p.parts = { make_cell(sx, sy, initial_gold, 0, 0, world_time) }
        p.alive = true
        p.dx = 0
        p.dy = 0
        p.fx_speed_until = 0
        p.fx_shield_until = 0
        p.fx_magnet_until = 0
        p.pending_split = false
        p.last_split = -merge_cooldown_s
    end

    if world_events ~= nil then
        world_events.match_start_due = true
        world_events.zone_due = true
    end
    print("[World] Match #" .. tostring(mid) .. " started (duration "
          .. tostring(match_duration()) .. "s)")
end

-- 结束本局：置结算态，胜者只存 pid（名字是运行期字符串，跨帧取会变垃圾，
-- 广播时再从 players 表实时读）
function end_match(winner_id)
    if Store.get("world.match_state") ~= 1 then return end
    Store.set("world.match_state", 2)
    Store.set("world.match_over_at", world_time)
    Store.set("world.match_winner_id", winner_id or 0)
    if world_events ~= nil then
        world_events.match_over_due = true
    end
    local wn = "none"
    if winner_id ~= nil and winner_id ~= 0 then
        local wp = players[winner_id]
        if wp ~= nil then wn = wp.name end
    end
    print("[World] Match #" .. tostring(Store.get("world.match_id"))
          .. " over, winner: " .. tostring(wn))
end

-- 每帧局调度：判定结束 / 结算倒计时结束后自动开新局
local function step_match()
    if not match_on() then return end
    local state = Store.get("world.match_state") or 1

    local n, last = count_alive()
    local peak = Store.get("world.match_peak_alive") or 0
    if n > peak then
        Store.set("world.match_peak_alive", n)
        peak = n
    end

    if state == 1 then
        local elapsed = world_time - (Store.get("world.match_start_at") or 0)
        if peak >= 2 and n <= 1 then
            -- 真的有过对手，最后活下来的人吃鸡（n==0 表示同归于尽，无胜者）
            end_match(last)
        elseif peak >= 1 and n == 0 then
            -- 全灭（例如圈缩到 0 后同时被毒死）：收局避免永久空场。
            -- peak<1 说明本局压根没人进场（空服开局），不能算结束。
            end_match(0)
        elseif elapsed >= match_duration() and peak >= 2 then
            -- 到点未分胜负：存活者中金币最高者判胜。
            -- 单人局（peak<2）不在这里收：否则只有一个人的测试服一到点就被
            -- 重置世界，所有时序用例都会被中途打断。
            end_match(richest_alive())
        end
    else
        local over_for = world_time - (Store.get("world.match_over_at") or 0)
        if over_for >= match_result() then
            start_match()
        end
    end
end

-- 快照/广播用的局信息（构造新表，供主循环安全读取与发送）
function get_match_info()
    if not match_on() then return nil end
    local state = Store.get("world.match_state") or 1
    local remain = 0
    if state == 1 then
        remain = match_duration() - (world_time - (Store.get("world.match_start_at") or 0))
        if remain < 0 then remain = 0 end
    else
        remain = match_result() - (world_time - (Store.get("world.match_over_at") or 0))
        if remain < 0 then remain = 0 end
    end
    local info = {
        id = Store.get("world.match_id") or 0,
        state = state,
        remain = math.floor(remain * 10) / 10
    }
    local wid = Store.get("world.match_winner_id") or 0
    if wid ~= 0 then
        info.winner_id = wid
        local wp = players[wid]
        -- 名字只在同帧广播使用，不跨帧保存（运行期字符串会变垃圾）
        if wp ~= nil then info.winner_name = wp.name end
    end
    local alive_n = 0
    for pid, p in pairs(players) do
        if p.alive ~= false then alive_n = alive_n + 1 end
    end
    info.alive = alive_n
    return info
end

-- 主循环读取并清除「本局结束」标记
function pop_match_over()
    if world_events == nil or world_events.match_over_due ~= true then return false end
    world_events.match_over_due = false
    return true
end

-- 主循环读取并清除「新局开始」标记
function pop_match_start()
    if world_events == nil or world_events.match_start_due ~= true then return false end
    world_events.match_start_due = false
    return true
end

-- 创建/重建两路 PCG 随机流。均以当前墙钟时间派生种子（不同常数偏移拉开初态），
-- 保证每局出生点/豆位/金币雨布局不可蹲点复现；热更恢复时改用 set_state 回放原序列。
local function init_rng()
    local now = os.time()
    rng_spawn = random.new(now)
    rng_feast = random.new(now + 2654435761)
end

function init(cfg)
    players = {}
    conn_to_pid = {}
    pid_to_conn = {}
    live_conns = {}
    pending_kicks = {}
    pending_closes = {}
    pending_admin_kicks = {}
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

    -- 随机数：出生点/金币雨各一路独立 PCG，均以当前墙钟时间播种，
    -- 不播种则每次重启豆子/道具/出生点都是同一确定序列，可被玩家记住布局蹲点。
    -- 只在 init 播种一次：热更走 hotfix_restore（set_state 回放），中途重播种会打断序列。
    init_rng()

    spawn_foods()
    spawn_powerups()

    -- 一局制初值；随后 start_match 开出第 1 局（此时玩家表为空，只有机器人随后进场）
    Store.set("world.match_id", 0)
    Store.set("world.match_state", 1)
    Store.set("world.match_start_at", 0)
    Store.set("world.match_over_at", 0)
    Store.set("world.match_winner_id", 0)
    Store.set("world.match_peak_alive", 0)
    if match_on() then
        start_match()
    end

    print("[World] Initialized with map " .. tostring(map_width) .. "x" .. tostring(map_height)
          .. ", " .. tostring(max_food) .. " gold pellets, " .. tostring(powerup_count) .. " powerups")
end

-- ---- 帧边界持久化（flua 式生命周期）----
--
-- 每次 update 都是一次独立的顶层 Call，arena 在帧边界重置，所有 VarTable 随帧消亡。
-- 因此世界状态在帧末编码进 Store（C++ 堆），帧初再解码回来。
--
-- 数字键的坑：players / conn_to_pid 等以 pid、connid 为键，而 JSON 对象键只能是
-- 字符串，直接 encode 会把 12345 变成 "12345"，decode 回来用数字下标就取不到。
-- 所以这类 map 统一转成 {k=键, v=值} 数组，restore 时按 k 重建（k 作为值保持数字）。

local function map_to_arr(m)
    local arr = {}
    if m == nil then return arr end
    local keys = {}
    for k, v in pairs(m) do
        keys[#keys + 1] = k
    end
    for i = 1, #keys do
        local k = keys[i]
        arr[#arr + 1] = { k = k, v = m[k] }
    end
    return arr
end

local function arr_to_map(arr)
    local m = {}
    if arr == nil then return m end
    for i = 1, #arr do
        local e = arr[i]
        if e ~= nil then
            m[e["k"]] = e["v"]
        end
    end
    return m
end

-- 帧末：把本帧世界状态写入 Store
function persist()
    Store.set_json("world.players", map_to_arr(players))
    Store.set_json("world.conn_to_pid", map_to_arr(conn_to_pid))
    Store.set_json("world.pid_to_conn", map_to_arr(pid_to_conn))
    Store.set_json("world.live_conns", map_to_arr(live_conns))
    Store.set_json("world.pending_kicks", pending_kicks)
    Store.set_json("world.pending_closes", pending_closes)
    Store.set_json("world.pending_admin_kicks", pending_admin_kicks)
    Store.set_json("world.pending_responses", pending_responses)
    Store.set_json("world.food_coins", food_coins)
    Store.set_json("world.powerups", powerups)
    Store.set_json("world.bonus_food", bonus_food)
    Store.set_json("world.world_events", world_events)
    Store.set_json("world.chat_recent", chat_recent)
    Store.set_json("world.zone", zone)
    Store.set_json("world.game_cfg", game_cfg)
    -- 标量：arena 不重置时也保留，但统一入库更稳（热更/异常路径都可复用）
    Store.set("world.next_bot_id", next_bot_id)
    Store.set("world.world_time", world_time)
    -- PCG 随机流是 NativeObject，必须存对象本身（壳跨帧失效）
    Store.set("world.rng_spawn", rng_spawn)
    Store.set("world.rng_feast", rng_feast)
end

-- 帧初：把 Store 里的世界状态解码回帧内 table
function restore()
    players = arr_to_map(Store.get_json("world.players"))
    conn_to_pid = arr_to_map(Store.get_json("world.conn_to_pid"))
    pid_to_conn = arr_to_map(Store.get_json("world.pid_to_conn"))
    live_conns = arr_to_map(Store.get_json("world.live_conns"))
    pending_kicks = Store.get_json("world.pending_kicks") or {}
    pending_closes = Store.get_json("world.pending_closes") or {}
    pending_admin_kicks = Store.get_json("world.pending_admin_kicks") or {}
    pending_responses = Store.get_json("world.pending_responses") or {}
    food_coins = Store.get_json("world.food_coins") or {}
    powerups = Store.get_json("world.powerups") or {}
    bonus_food = Store.get_json("world.bonus_food") or {}
    world_events = Store.get_json("world.world_events") or {}
    chat_recent = Store.get_json("world.chat_recent") or {}
    zone = Store.get_json("world.zone")
    game_cfg = Store.get_json("world.game_cfg")
    next_bot_id = Store.get("world.next_bot_id")
    world_time = Store.get("world.world_time") or 0
    rng_spawn = Store.get("world.rng_spawn")
    rng_feast = Store.get("world.rng_feast")
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
    s["pending_admin_kicks"] = pending_admin_kicks
    s["next_bot_id"] = next_bot_id
    s["world_time"] = world_time
    s["food_coins"] = food_coins
    s["powerups"] = powerups
    s["bonus_food"] = bonus_food
    s["world_events"] = world_events
    s["chat_recent"] = chat_recent
    s["zone"] = zone
    s["pending_responses"] = pending_responses
    -- PCG 随机流状态（64-bit hex）：热更后回放同一条随机序列，杜绝热更点后布局跳变
    if rng_spawn ~= nil then
        local ok1, st1 = pcall(function() return rng_spawn:get_state() end)
        if ok1 then s["rng_spawn_state"] = st1 end
    end
    if rng_feast ~= nil then
        local ok2, st2 = pcall(function() return rng_feast:get_state() end)
        if ok2 then s["rng_feast_state"] = st2 end
    end
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
    pending_admin_kicks = migrate(s["pending_admin_kicks"])
    if pending_admin_kicks == nil then pending_admin_kicks = {} end
    next_bot_id = s["next_bot_id"]
    world_time = s["world_time"]
    food_coins = migrate(s["food_coins"])
    powerups = migrate(s["powerups"])
    bonus_food = migrate(s["bonus_food"])
    world_events = migrate(s["world_events"])
    chat_recent = migrate(s["chat_recent"])
    zone = migrate(s["zone"])
    pending_responses = migrate(s["pending_responses"])

    -- 恢复 PCG 随机流到快照时刻的状态（NativeObject 热更后仍在；缺失则先建再恢复）
    if rng_spawn == nil or rng_feast == nil then
        init_rng()
    end
    if s["rng_spawn_state"] ~= nil then
        pcall(function() rng_spawn:set_state(s["rng_spawn_state"]) end)
    end
    if s["rng_feast_state"] ~= nil then
        pcall(function() rng_feast:set_state(s["rng_feast_state"]) end)
    end
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
        rx = rng_spawn:int(margin, map_width - margin)
        ry = rng_spawn:int(margin, map_height - margin)

        if zone_enable and zone ~= nil then
            local zdx = rx - zone.x
            local zdy = ry - zone.y
            if (zdx * zdx + zdy * zdy) > (zone.r - sr - 30) * (zone.r - sr - 30) then
                -- 候选点在安全区外或贴边，重抽
                if try_n < 16 then
                    -- 直接以圈心附近重试，提高收缩后期的命中率
                    local ang = rng_spawn:float(0, 6.28318)
                    local rr = rng_spawn:int(0, math.max(0, math.floor(zone.r - sr - 60)))
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
-- 值为建连时间（秒）：既用于异步鉴权往返的存活判定，也用于清理只建连不登录的连接
function mark_conn(connid)
    if live_conns == nil then live_conns = {} end
    live_conns[connid] = os.time()
end

function unmark_conn(connid)
    if live_conns == nil then return end
    live_conns[connid] = nil
end

function is_conn_alive(connid)
    if live_conns == nil then return false end
    return live_conns[connid] ~= nil
end

-- 收集「已建连超过 timeout_s 仍未登录进场」的连接（无 pid 映射）。
-- 这类连接不在 players 表中，kick_idle 遍历玩家覆盖不到，可永久占住 maxconn 名额；
-- 判定只看建连时间、不因收发消息续期（正常客户端建连后应立刻完成登录）。
function get_idle_unauth_conns(timeout_s, now)
    local out = {}
    if live_conns == nil then return out end
    for connid, ts in pairs(live_conns) do
        if conn_to_pid[connid] == nil and (now - ts) > timeout_s then
            table.insert(out, connid)
        end
    end
    return out
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

-- 运维口下线玩家（HTTP 管理口在 runtime.tick 同线程调用，只入队；
-- NetWs.flush_kicks 在主循环下发 error 帧并排队下一帧断开）
function enqueue_admin_kick(connid, reason)
    if pending_admin_kicks == nil then pending_admin_kicks = {} end
    table.insert(pending_admin_kicks, { connid = connid, reason = reason })
end

function drain_pending_admin_kicks()
    if pending_admin_kicks == nil or #pending_admin_kicks == 0 then return nil end
    local result = pending_admin_kicks
    pending_admin_kicks = {}
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
        -- 必须从 live_conns 摘掉：解除 conn_to_pid 后，这条旧连接在
        -- get_idle_unauth_conns 眼里已经等同于「只建连不登录」，而它往往已建连
        -- 几十秒，会立刻被 kick_idle 当作未登录空闲连接直接 close_connection。
        -- 那样主循环两阶段流程里的 error 帧（账号已在别处登录）会随连接一起被
        -- 丢弃，客户端只收到裸断开——快机器上 flush_kicks 先跑完侥幸不触发，
        -- 慢机器上 kick_idle 与它同帧命中就必现。这里摘除后，旧连接只走
        -- pending_kicks：本帧发 error，下一帧才断开。
        unmark_conn(prev_conn)
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

    -- 一局制：每局都从初始金币开始（历史战绩走 DB 的 best_gold，不继承上局余额）
    if match_on() then
        gold = initial_gold
    end

    local joining = true
    if match_on() and (Store.get("world.match_state") or 1) == 2 then
        joining = false
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
        alive = joining
    }
    if joining then
        p.parts = { make_cell(spawn_x, spawn_y, gold, 0, 0, 0) }
    else
        p.parts = {}
    end

    players[pid] = p
    conn_to_pid[connid] = pid
    pid_to_conn[pid] = connid

    print("[World] Player " .. account.username .. " (ID: " .. tostring(pid) .. ") joined the game.")

    -- 进场事件：Ledger 等旁路模块订阅（可能运行于 C++ recv 回调上下文，
    -- 订阅者只做 sqlite 同步写入等安全操作）；emit 失败不允许影响进场
    pcall(function() event.emit("game.enter", pid, p.name, 0) end)
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
    pcall(function() event.emit("game.enter", pid, p.name, 1) end)
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

-- 周期性落盘全部在线玩家金币（主循环按 save_interval_s 调度）。
-- 吞噬/离场之外的吃豆进度只存在内存里，进程异常退出（SIGTERM/崩溃/-9）会丢失，
-- 用定时批量落盘把损失窗口压到一个周期；机器人不落盘。
function flush_online_gold()
    for pid, p in pairs(players) do
        -- 一局制：已出局的人总金币为 0，写库会把历史余额清成 0（历史战绩走
        -- best_gold，不该被本局的出局状态覆盖），因此跳过
        if not p.is_bot and p.alive ~= false then
            DB.update_gold(p.name, p.id, total_gold(p))
        end
    end
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

    -- 按 UTF-8「字符」限长：旧实现按字节 sub，一个汉字 3 字节会被切成半个乱码。
    -- utf8.len 遇非法字节返回 nil+位置，这种坏内容直接丢弃不予广播。
    local nchar = utf8.len(text)
    if nchar == nil then return end
    if nchar > chat_max_len then
        -- 第 (max_len+1) 个字符的起始字节位置，截到它之前即恰好 max_len 个字符
        local cut = utf8.offset(text, chat_max_len + 1)
        if cut ~= nil then
            text = string.sub(text, 1, cut - 1)
        end
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

-- 运维系统公告（HTTP 管理口调用；固定发送者，不受玩家节流限制，
-- 仍走 UTF-8 校验与限长；只入广播队列，ws 发送留主循环 flush）
local SYSTEM_CHAT_NAME = "[系统]"
function system_chat(content)
    if chat_recent == nil then return false, "chat disabled" end
    if type(content) ~= "string" then return false, "message must be a string" end

    local text = trim_chat(content)
    if #text == 0 then return false, "empty message" end

    local nchar = utf8.len(text)
    if nchar == nil then return false, "invalid utf8" end
    if nchar > chat_max_len then
        local cut = utf8.offset(text, chat_max_len + 1)
        if cut ~= nil then
            text = string.sub(text, 1, cut - 1)
        end
    end

    local entry = { name = SYSTEM_CHAT_NAME, content = text, t = math.floor(world_time) }
    table.insert(chat_recent, entry)
    if #chat_recent > chat_history then
        table.remove(chat_recent, 1)
    end

    enqueue_response(-1, {
        type = "chat",
        name = SYSTEM_CHAT_NAME,
        content = text,
        system = true
    })
    return true, text
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
        -- 一局制：最后一个细胞被吃 = 淘汰出局，不再原地复活，等下一局重新进场
        table.insert(eat_events, {
            eater_id = E.pp.id, victim_id = vp.id, gold = eaten_gold, full = true
        })
        settle_persist(E.pp, vp, true)
        eliminate_player(vp, "eaten", died_events)
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
                    f.x = rng_spawn:int(50, map_width - 50)
                    f.y = rng_spawn:int(50, map_height - 50)
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
                    pw.x = rng_spawn:int(60, map_width - 60)
                    pw.y = rng_spawn:int(60, map_height - 60)
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
-- 圈外持续掉金币；一局制下掉到 0 即「被毒死」出局（否则圈缩到 0 后
-- 全员僵在最小半径上互相吃不掉，永远分不出胜负）
-- 返回本帧因圈伤产生的出局事件，由 update 并入 died_events
local function step_zone_damage(dt)
    local outs = {}
    if not zone_enable or zone == nil then return outs end
    for pid, p in pairs(players) do
        if p.alive ~= false then
            local drained = false
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
                        if c.gold <= 0 then drained = true end
                    end
                else
                    c.zone_acc = 0
                end
            end
            if drained then
                eliminate_player(p, "zone", outs)
            end
        end
    end
    return outs
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

    -- 局调度放在最前：本帧刚被淘汰的人不该再参与后续结算，
    -- 结算倒计时走完则本帧就开出新局（随后所有人已是复活状态）
    step_match()

    step_split_and_pickup()

    local powerup_events = step_pickup_powerups()

    step_movement(dt)

    local zone_outs = step_zone_damage(dt)
    step_merge()
    local eat_events, died_events = step_combat()

    -- 圈伤出局并入死亡事件（与主循环的 game.death 派发同一路径）
    for i = 1, #zone_outs do
        died_events[#died_events + 1] = zone_outs[i]
    end

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
    -- 新一场开始即清空上一场的残豆：奖励豆只在被吃掉时移除，吃剩的会永久残留。
    -- 不清的话 bonus_food 只增不减（默认每 120s +30），快照按 20Hz 全量广播、
    -- Bot 每次决策也全量遍历，长跑下带宽与 CPU 单调膨胀。
    bonus_food = {}

    local cx = rng_feast:int(300, map_width - 300)
    local cy = rng_feast:int(300, map_height - 300)
    for i = 1, feast_bonus do
        local bx = cx + rng_feast:int(-250, 250)
        local by = cy + rng_feast:int(-250, 250)
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

-- 主循环读取并清除「每秒一次」标记：踢空闲连接 / 落盘 / 指标推送等墙钟任务
-- 都由它驱动。用心跳置位而不是主循环里累加 dt —— 慢机器上帧率会掉，
-- dt 累加会让「每秒任务」变成几秒一次。
function pop_sec_tick()
    if world_events == nil or world_events.sec_tick ~= true then return false end
    world_events.sec_tick = false
    return true
end

-- 心跳累计秒数（真实时间，供主循环做周期调度）
function get_sec()
    if world_events == nil then return 0 end
    if world_events.sec == nil then return 0 end
    return world_events.sec
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
    if world_events.sec == nil then world_events.sec = 0 end
    world_events.sec = world_events.sec + 1
    world_events.sec_tick = true

    if world_events.sec % 5 == 0 then
        DB.tick_refresh()
    end

    if feast_interval_s > 0 and world_events.sec % feast_interval_s == 0 then
        world_events.feast_due = true
    end

    -- 一局制下的安全区：开局先给 zone_wait_s 秒发育时间，之后按「本局剩余比例」
    -- 连续收缩到 0——半径每秒平滑变小（客户端从快照即可跟随，不必等事件帧），
    -- 到局末收缩为 0，逼出最后的胜负。旧的分阶收缩 + 最小圈重置已废弃
    -- （zone_shrink_interval_s / zone_hold_s / zone_shrink_ratio / zone_min_radius
    --  不再参与计算，保留读取只为兼容旧配置）。
    if match_on() and zone_enable and zone ~= nil then
        local state = Store.get("world.match_state") or 1
        if state == 1 then
            local elapsed = world_time - (Store.get("world.match_start_at") or 0)
            local span = match_duration() - zone_wait_s
            if span < 1 then span = 1 end
            local nr = zone_initial_r
            if elapsed <= zone_wait_s then
                nr = zone_initial_r
                zone.next_in = math.floor(zone_wait_s - elapsed)
            else
                local prog = (elapsed - zone_wait_s) / span
                if prog > 1 then prog = 1 end
                nr = zone_initial_r * (1.0 - prog)
                zone.next_in = math.floor(match_duration() - elapsed)
            end
            if nr < 0 then nr = 0 end
            zone.r = nr
            -- phase 作为收缩进度档位（每 10% 一档），供客户端/HUD 显示
            local ph = math.floor((1.0 - (nr / zone_initial_r)) * 10 + 0.5)
            if ph ~= zone.phase then
                zone.phase = ph
                world_events.zone_due = true
            end
        else
            -- 结算期保持当前半径，next_in 表示距离下一局
            zone.next_in = math.floor(match_result() - (world_time - (Store.get("world.match_over_at") or 0)))
        end
    elseif zone_enable and zone ~= nil then
        -- 旧行为（match_enable=false）：分阶收缩 → 最小圈保持 → 重置为初始圈循环
        zone.next_in = zone.next_in - 1
        if zone.next_in <= 0 then
            if zone.holding then
                zone.x = map_width / 2
                zone.y = map_height / 2
                zone.r = zone_initial_r
                zone.phase = 0
                zone.holding = false
                zone.next_in = zone_shrink_interval_s
            else
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

-- 按数字 pid 或精确昵称定位在线实体（运维口用；找不到返回 nil）
function find_player(target)
    if players == nil or target == nil then return nil end
    local as_num = tonumber(target)
    if as_num ~= nil then
        local p = players[as_num]
        if p ~= nil then return p end
    end
    local want = tostring(target)
    for _, p in pairs(players) do
        if p.name == want then return p end
    end
    return nil
end

-- 运维口在线玩家清单（精简字段；机器人 connid 为空）
function admin_list_players()
    local out = {}
    if players == nil then return out end
    for _, p in pairs(players) do
        local gx = nil
        local gy = nil
        local cells = 0
        if p.parts ~= nil then
            cells = #p.parts
            if cells > 0 then
                gx = p.parts[1].x
                gy = p.parts[1].y
            end
        end
        table.insert(out, {
            id = p.id,
            name = p.name,
            bot = p.is_bot == true,
            gold = total_gold(p),
            x = gx,
            y = gy,
            cells = cells,
            connid = p.connid,
            last_seen = p.last_seen
        })
    end
    return out
end

-- 按 id 查昵称（事件处理器用；找不到回退 id 字符串）
function get_name_by_id(pid)
    if players == nil then return tostring(pid) end
    local p = players[pid]
    if p ~= nil then return p.name end
    return tostring(pid)
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
