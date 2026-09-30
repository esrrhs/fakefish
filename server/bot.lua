package "Bot"

-- AI 机器人：让单人试玩时世界有生命感。
-- 机器人是 World 里的普通玩家实体（is_bot=true），
-- 本模块只负责每帧写 p.dx/p.dy 移动意图，物理与吞噬由 World/Combat 统一结算。

local bot_count = nil
local bot_max_gold = nil

-- AI 感知参数（只读常量，模块级赋值安全）
local sight_food = 500      -- 觅食感知半径
local sight_player = 400    -- 玩家感知半径
local decision_min = 0.8    -- 决策间隔下限（秒）
local decision_max = 2.5    -- 决策间隔上限（秒）

local bot_names = { "泡泡", "小鱼干", "大胃王", "闪电球", "夜行者", "贪吃鬼", "小钢炮", "软糖", "浪里白条", "深海刺客" }

-- 注意：模块级 table 会被 fakelua JIT 标记为 const，必须运行时在 init() 中创建
local bots = nil

function init(cfg)
    bots = {}
    if cfg == nil then cfg = {} end
    bot_count = cfg["bot_count"] or 3
    bot_max_gold = cfg["bot_max_gold"] or 2000
    if bot_count <= 0 then return end
    if bot_count > #bot_names then bot_count = #bot_names end

    for i = 1, bot_count do
        local p = World.add_bot(bot_names[i])
        if p ~= nil then
            table.insert(bots, p)
        end
    end
    print("[Bot] Spawned " .. tostring(#bots) .. " bots")
end

local function dist(x1, y1, x2, y2)
    local dx = x1 - x2
    local dy = y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

-- 为单个机器人做一次决策，写入 ai_dx/ai_dy 与 ai_timer
local function decide(p)
    p.ai_timer = decision_min + math.random() * (decision_max - decision_min)

    -- 0) 安全区优先：球心在圈外、或距圈边不足自身半径+余量 → 朝圈心移动
    local zone = World.get_zone_info()
    if zone ~= nil then
        local zd = dist(p.x, p.y, zone.x, zone.y)
        if zd > zone.r - (p.r + 40) then
            if zd < 1 then zd = 1 end
            p.ai_dx = (zone.x - p.x) / zd
            p.ai_dy = (zone.y - p.y) / zd
            return
        end
    end

    -- 已吃撑的机器人不再主动觅食/猎杀，只游荡，避免一家独大
    if p.gold >= bot_max_gold then
        local a = math.random() * 6.28318
        p.ai_dx = math.cos(a)
        p.ai_dy = math.sin(a)
        return
    end

    local players = World.get_all_players()

    -- 1) 威胁优先：附近有能吃掉自己的大球 → 远离它
    local threat = nil
    local threat_dist = sight_player
    local prey = nil
    local prey_dist = sight_player
    for oid, other in pairs(players) do
        if other.id ~= p.id then
            local d = dist(p.x, p.y, other.x, other.y)
            if d < sight_player then
                -- 对方金币严格更大且半径满足吞噬比 → 是威胁
                if other.gold > p.gold and other.r >= p.r * 1.05 then
                    if d < threat_dist then
                        threat = other
                        threat_dist = d
                    end
                -- 自己能吃掉对方（半径满足吞噬比）→ 是猎物
                elseif p.r >= other.r * 1.05 then
                    if d < prey_dist then
                        prey = other
                        prey_dist = d
                    end
                end
            end
        end
    end

    if threat ~= nil and (threat_dist < prey_dist or prey == nil) then
        local d = threat_dist
        if d < 1 then d = 1 end
        p.ai_dx = (p.x - threat.x) / d
        p.ai_dy = (p.y - threat.y) / d
        return
    end

    -- 2) 有可吞噬的猎物 → 追击
    if prey ~= nil then
        local d = prey_dist
        if d < 1 then d = 1 end
        p.ai_dx = (prey.x - p.x) / d
        p.ai_dy = (prey.y - p.y) / d
        return
    end

    -- 3) 顺路捡道具（半径 350 内最近的）
    local nearest_pw = nil
    local nearest_pw_d = 350
    local powerups = World.get_powerups()
    for i = 1, #powerups do
        local pw = powerups[i]
        local d = dist(p.x, p.y, pw.x, pw.y)
        if d < nearest_pw_d then
            nearest_pw_d = d
            nearest_pw = pw
        end
    end

    if nearest_pw ~= nil then
        local d = nearest_pw_d
        if d < 1 then d = 1 end
        p.ai_dx = (nearest_pw.x - p.x) / d
        p.ai_dy = (nearest_pw.y - p.y) / d
        return
    end

    -- 4) 觅食：找最近的金币豆
    local nearest = nil
    local nearest_d = sight_food
    local foods = World.get_foods()
    for i = 1, #foods do
        local f = foods[i]
        local d = dist(p.x, p.y, f.x, f.y)
        if d < nearest_d then
            nearest_d = d
            nearest = f
        end
    end

    if nearest ~= nil then
        local d = nearest_d
        if d < 1 then d = 1 end
        p.ai_dx = (nearest.x - p.x) / d
        p.ai_dy = (nearest.y - p.y) / d
        return
    end

    -- 5) 游荡
    local a = math.random() * 6.28318
    p.ai_dx = math.cos(a)
    p.ai_dy = math.sin(a)
end

-- 每帧更新机器人意图（在 World.update 之前调用）
function update(dt)
    if bots == nil then return end
    for i = 1, #bots do
        local p = bots[i]
        p.ai_timer = p.ai_timer - dt
        if p.ai_timer <= 0 then
            decide(p)
        end
        p.dx = p.ai_dx
        p.dy = p.ai_dy
    end
end
