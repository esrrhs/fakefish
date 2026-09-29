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
function check_eat(x1, y1, r1, g1, x2, y2, r2, g2, eat_ratio)
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
    end

    return 0
end
