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

    -- 自身最大/最小细胞与总金币
    local my_big = p.parts[1]
    local my_small = p.parts[1]
    local my_total = 0
    for k = 1, #p.parts do
        local c = p.parts[k]
        my_total = my_total + c.gold
        if c.r > my_big.r then my_big = c end
        if c.r < my_small.r then my_small = c end
    end

    -- 0) 安全区优先：任一细胞贴近/超出圈边 → 该细胞朝圈心移动
    local zone = World.get_zone_info()
    if zone ~= nil then
        for k = 1, #p.parts do
            local c = p.parts[k]
            local zd = dist(c.x, c.y, zone.x, zone.y)
            if zd > zone.r - (c.r + 40) then
                if zd < 1 then zd = 1 end
                p.ai_dx = (zone.x - c.x) / zd
                p.ai_dy = (zone.y - c.y) / zd
                return
            end
        end
    end

    -- 已吃撑的机器人不再主动觅食/猎杀，只游荡，避免一家独大
    if my_total >= bot_max_gold then
        local a = math.random() * 6.28318
        p.ai_dx = math.cos(a)
        p.ai_dy = math.sin(a)
        return
    end

    local all = World.get_all_players()

    -- 1) 威胁/猎物按细胞判定：对方最大细胞能吃我的最小细胞 → 威胁；
    --    我的最大细胞能吃对方最小细胞 → 猎物
    local threat = nil
    local threat_dist = sight_player
    local prey = nil
    local prey_dist = sight_player
    local prey_total_gold = 0
    for oid, other in pairs(all) do
        if other.id ~= p.id then
            local obig = other.parts[1]
            local osmall = other.parts[1]
            for k = 1, #other.parts do
                local oc = other.parts[k]
                if oc.r > obig.r then obig = oc end
                if oc.r < osmall.r then osmall = oc end
            end

            local td = dist(my_small.x, my_small.y, obig.x, obig.y)
            if td < sight_player and obig.gold > my_small.gold
               and obig.r >= my_small.r * 1.05 then
                if td < threat_dist then
                    threat = obig
                    threat_dist = td
                end
            end

            local pd = dist(my_big.x, my_big.y, osmall.x, osmall.y)
            if pd < sight_player and my_big.gold > osmall.gold
               and my_big.r >= osmall.r * 1.05 then
                if pd < prey_dist then
                    prey = osmall
                    prey_dist = pd
                    local ptot = 0
                    for k = 1, #other.parts do ptot = ptot + other.parts[k].gold end
                    prey_total_gold = ptot
                end
            end
        end
    end

    if threat ~= nil and (threat_dist < prey_dist or prey == nil) then
        local d = threat_dist
        if d < 1 then d = 1 end
        p.ai_dx = (my_small.x - threat.x) / d
        p.ai_dy = (my_small.y - threat.y) / d
        return
    end

    -- 2) 有可吞噬的猎物 → 追击；距离很近且优势明显时分裂扑杀
    if prey ~= nil then
        local d = prey_dist
        if d < 1 then d = 1 end
        p.ai_dx = (prey.x - my_big.x) / d
        p.ai_dy = (prey.y - my_big.y) / d
        if prey_dist < 250 and my_total > prey_total_gold * 1.6 then
            p.pending_split = true
        end
        return
    end

    -- 3) 顺路捡道具（半径 350 内最近的）
    local nearest_pw = nil
    local nearest_pw_d = 350
    local powerups = World.get_powerups()
    for i = 1, #powerups do
        local pw = powerups[i]
        local d = dist(my_big.x, my_big.y, pw.x, pw.y)
        if d < nearest_pw_d then
            nearest_pw_d = d
            nearest_pw = pw
        end
    end

    if nearest_pw ~= nil then
        local d = nearest_pw_d
        if d < 1 then d = 1 end
        p.ai_dx = (nearest_pw.x - my_big.x) / d
        p.ai_dy = (nearest_pw.y - my_big.y) / d
        return
    end

    -- 4) 觅食：找离最大细胞最近的金币豆
    local nearest = nil
    local nearest_d = sight_food
    local foods = World.get_foods()
    for i = 1, #foods do
        local f = foods[i]
        local d = dist(my_big.x, my_big.y, f.x, f.y)
        if d < nearest_d then
            nearest_d = d
            nearest = f
        end
    end

    if nearest ~= nil then
        local d = nearest_d
        if d < 1 then d = 1 end
        p.ai_dx = (nearest.x - my_big.x) / d
        p.ai_dy = (nearest.y - my_big.y) / d
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
