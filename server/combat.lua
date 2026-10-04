package "Combat"

-- 计算金币对应的球体半径
function calc_radius(gold, radius_base, radius_k)
    if gold == nil or gold < 0 then gold = 0 end
    if radius_base == nil then radius_base = 15 end
    if radius_k == nil then radius_k = 2.5 end
    return radius_base + radius_k * math.sqrt(gold)
end

-- 检测两个球体之间的吞噬关系
-- 返回：
-- 0: 无吞噬
-- 1: p1 吃掉 p2
-- 2: p2 吃掉 p1
--
-- eat_ratio: 吞噬半径阈值（默认 1.05）
-- tie_equal: 同金币兜底开关（默认 false）。开启后双方金币相等时按 id 裁决，
--            用于解决「双方金币都被扣到 0 → 半径同为下限 → 常规条件永不成立」的僵局。
-- id1/id2: 兜底裁决用的稳定标识（通常是 player_id）。仅在 tie_equal 且金币相等时生效。
function check_eat(x1, y1, r1, g1, x2, y2, r2, g2, eat_ratio, tie_equal, id1, id2)
    if eat_ratio == nil then eat_ratio = 1.05 end

    local dx = x1 - x2
    local dy = y1 - y2
    local dist = math.sqrt(dx * dx + dy * dy)

    -- 碰撞且有明显交叠：两球圆心距离必须小于较大球的半径
    if r1 >= r2 * eat_ratio and g1 > g2 then
        -- p1 明显大于 p2，且 p2 的中心或大部分体积被 p1 覆盖
        if dist < r1 then
            return 1
        end
    elseif r2 >= r1 * eat_ratio and g2 > g1 then
        -- p2 明显大于 p1，且 p1 的中心或大部分体积被 p2 覆盖
        if dist < r2 then
            return 2
        end
    elseif tie_equal and g1 == g2 and r1 == r2 then
        -- 同金币兜底：常规的两个条件在此同时失效——
        --   r1 >= r2 * ratio：金币相等时半径相等（r 是 gold 的单调函数），
        --     除非双方都已归零、半径同为下限 radius_base，此时 ratio 判定恒不成立；
        --   g1 > g2 / g2 > g1：金币相等时两者皆假。
        -- 结果是即使两球圆心重合也永远返回 0（毒圈 dps 会把圈外玩家金币扣到 0，
        -- 双方在圈内相遇即互相卡死，见 docs/fakelua-pitfalls.md 的 combat 超时记录）。
        -- 裁决用 id 而非坐标：坐标每帧变化，用它裁决会让两个玩家互相反复吞噬。
        if dist < r1 then
            if id1 < id2 then
                return 1
            end
            return 2
        end
    end

    return 0
end
